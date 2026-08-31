import Compression
import Foundation
import KanataCore

/// App 内置的爱奇艺与腾讯视频弹幕客户端，无需配置网关即可搜索和加载弹幕。
actor BuiltInPublicDanmakuClient {
    private static let iqiyiSegmentSeconds = 300
    private static let segmentConcurrency = 5
    private static let maximumIqiyiSegments = 48
    private let session: URLSession

    /// 创建使用临时会话的内置公共来源客户端。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// 同时搜索爱奇艺与腾讯视频，并返回按置信度排序的逐集候选。
    /// - Parameter request: 标题、可选集号和本地视频时长。
    /// - Returns: 两个平台合并后的候选列表。
    func search(_ request: ResolveRequest) async -> [ProviderCandidate] {
        var candidates: [ProviderCandidate] = []
        if let iqiyi = try? await searchIqiyi(request) { candidates.append(contentsOf: iqiyi) }
        if let qq = try? await searchQQ(request) { candidates.append(contentsOf: qq) }
        return candidates.sorted { left, right in
            if left.confidence == right.confidence {
                return (left.episodeTitle ?? "") < (right.episodeTitle ?? "")
            }
            return left.confidence > right.confidence
        }
    }

    /// 按候选来源拉取完整弹幕。
    /// - Parameter candidate: 爱奇艺或腾讯视频候选。
    /// - Returns: 已按时间排序的统一弹幕。
    func danmaku(for candidate: ProviderCandidate) async throws -> [DanmakuItem] {
        switch candidate.source {
        case .iqiyi:
            return try await loadIqiyiDanmaku(candidate.platformEpisodeId)
        case .qq:
            return try await loadQQDanmaku(candidate.platformEpisodeId)
        default:
            throw PublicDanmakuError.unsupportedSource
        }
    }

    /// 轻量探测爱奇艺和腾讯视频弹幕分片是否可访问。
    /// - Returns: 每个内置公共来源的可用状态。
    func health() async -> [DanmakuSourceId: Bool] {
        var result: [DanmakuSourceId: Bool] = [:]
        result[.iqiyi] = ((try? await loadIqiyiSegment(tvID: "3493131456125200", index: 1).count) ?? 0) > 20
        let qqSegments = try? await loadQQSegmentNames(vid: "q4100dpkd26")
        if let name = qqSegments?.first {
            result[.qq] = ((try? await loadQQSegment(vid: "q4100dpkd26", name: name).count) ?? 0) > 20
        } else {
            result[.qq] = false
        }
        return result
    }

    /// 搜索爱奇艺专辑并展开最相似的两部作品。
    private func searchIqiyi(_ request: ResolveRequest) async throws -> [ProviderCandidate] {
        if request.title.range(of: "^\\d+@\\d+$", options: .regularExpression) != nil {
            return [ProviderCandidate(
                source: .iqiyi,
                sourceInstanceName: "爱奇艺（App 内置）",
                platformEpisodeId: request.title,
                title: "爱奇艺视频",
                episodeTitle: request.episode.map { "第 \($0) 集" } ?? "指定视频",
                confidence: 1
            )]
        }
        var components = URLComponents(string: "https://search.video.iqiyi.com/o")
        components?.queryItems = [
            URLQueryItem(name: "if", value: "html5"),
            URLQueryItem(name: "key", value: request.title),
            URLQueryItem(name: "pageNum", value: "1"),
            URLQueryItem(name: "pageSize", value: "12"),
        ]
        guard let url = components?.url else { throw PublicDanmakuError.invalidURL }
        let envelope: IqiyiSearchEnvelope = try await loadJSON(makeRequest(url: url, referer: "https://www.iqiyi.com/"))
        guard envelope.code == "A00000" else { throw PublicDanmakuError.invalidResponse }
        let ranked = (envelope.data?.docinfos ?? [])
            .compactMap(\.albumDocInfo)
            .filter { $0.albumId != nil && !($0.albumTitle ?? "").isEmpty }
            .map { ($0, Self.titleSimilarity(request.title, $0.albumTitle ?? "")) }
            .sorted { $0.1 > $1.1 }
            .prefix(2)

        var candidates: [ProviderCandidate] = []
        for (album, score) in ranked {
            guard let albumID = album.albumId else { continue }
            let episodes = try await loadIqiyiEpisodes(albumID: albumID)
            for (index, episode) in episodes.enumerated() {
                guard let tvID = episode.tvId else { continue }
                let number = episode.order ?? index + 1
                if let expected = request.episode, number != expected { continue }
                let duration = Self.parseClock(episode.duration)
                let confidence = Self.adjustedConfidence(
                    titleScore: score,
                    localDuration: request.duration,
                    remoteDuration: duration
                )
                guard confidence > 0 else { continue }
                candidates.append(ProviderCandidate(
                    source: .iqiyi,
                    sourceInstanceName: "爱奇艺（App 内置）",
                    platformEpisodeId: duration.map { "\(tvID)@\(Int($0))" } ?? String(tvID),
                    title: album.albumTitle ?? "爱奇艺视频",
                    episodeTitle: Self.episodeLabel(number: number, subtitle: episode.subtitle),
                    duration: duration,
                    confidence: confidence
                ))
            }
        }
        return candidates
    }

    /// 获取爱奇艺专辑的完整分集列表。
    private func loadIqiyiEpisodes(albumID: Int) async throws -> [IqiyiEpisode] {
        guard let url = URL(string: "https://pcw-api.iqiyi.com/albums/album/avlistinfo?aid=\(albumID)&page=1&size=200") else {
            throw PublicDanmakuError.invalidURL
        }
        let envelope: IqiyiEpisodeEnvelope = try await loadJSON(makeRequest(url: url, referer: "https://www.iqiyi.com/"))
        guard envelope.code == "A00000", let episodes = envelope.data?.epsodelist else {
            throw PublicDanmakuError.invalidResponse
        }
        return episodes
    }

    /// 拉取并合并爱奇艺指定 tvid 的全部 300 秒弹幕分片。
    private func loadIqiyiDanmaku(_ platformEpisodeID: String) async throws -> [DanmakuItem] {
        let parts = platformEpisodeID.split(separator: "@", maxSplits: 1).map(String.init)
        guard let tvID = parts.first, tvID.allSatisfy(\.isNumber),
              parts.count > 1, let duration = Int(parts[1]), duration > 0 else {
            throw PublicDanmakuError.iqiyiDurationRequired
        }
        let count = min(
            Int(ceil(Double(duration) / Double(Self.iqiyiSegmentSeconds))),
            Self.maximumIqiyiSegments
        )
        var items: [DanmakuItem] = []
        for start in stride(from: 1, through: count, by: Self.segmentConcurrency) {
            let end = min(start + Self.segmentConcurrency - 1, count)
            let batch = try await withThrowingTaskGroup(of: [DanmakuItem].self) { group in
                for index in start...end {
                    group.addTask { try await self.loadIqiyiSegment(tvID: tvID, index: index) }
                }
                var values: [[DanmakuItem]] = []
                for try await value in group { values.append(value) }
                return values
            }
            for value in batch { items.append(contentsOf: value) }
        }
        return items.sorted { $0.time < $1.time }
    }

    /// 下载、解压并解析单个爱奇艺弹幕分片。
    private func loadIqiyiSegment(tvID: String, index: Int) async throws -> [DanmakuItem] {
        guard tvID.count >= 4 else { throw PublicDanmakuError.invalidEpisodeID }
        let bucketA = String(tvID.suffix(4).prefix(2))
        let bucketB = String(tvID.suffix(2))
        guard let url = URL(string: "https://cmts.iqiyi.com/bullet/\(bucketA)/\(bucketB)/\(tvID)_300_\(index).z") else {
            throw PublicDanmakuError.invalidURL
        }
        let compressed = try await loadData(makeRequest(url: url, referer: "https://www.iqiyi.com/"))
        let xml = try Self.inflateZlib(compressed)
        let delegate = IqiyiBulletXMLDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse() else { throw PublicDanmakuError.invalidResponse }
        return delegate.items
    }

    /// 搜索腾讯视频并展开最相似的两部作品。
    private func searchQQ(_ request: ResolveRequest) async throws -> [ProviderCandidate] {
        if let direct = Self.qqVID(from: request.title) {
            return [ProviderCandidate(
                source: .qq,
                sourceInstanceName: "腾讯视频（App 内置）",
                platformEpisodeId: direct,
                title: "腾讯视频",
                episodeTitle: request.episode.map { "第 \($0) 集" } ?? "指定视频",
                confidence: 1
            )]
        }
        guard let url = URL(string: "https://pbaccess.video.qq.com/trpc.videosearch.mobile_search.HttpMobileRecall/MbSearchHttp") else {
            throw PublicDanmakuError.invalidURL
        }
        let body: [String: Any] = [
            "version": "8.2.96", "clientType": 1, "filterValue": "", "uuid": "kanata-search",
            "retry": 0, "query": request.title, "pagenum": 0, "pagesize": 12, "queryFrom": 0,
            "isneedQc": true, "preQid": "", "adClientInfo": "",
            "extraInfo": ["isNewMarkLabel": "1", "multi_terminal_pc": "1", "themeType": "0"],
            "featureList": ["DEFAULT_FEFEATURE", "PC_WANT_EPISODE_V2", "PC_WANT_EPISODE"],
        ]
        let envelope: QQSearchEnvelope = try await loadJSON(jsonRequest(url: url, body: body))
        guard envelope.data?.errcode == 0 else { throw PublicDanmakuError.invalidResponse }
        let ranked = (envelope.data?.normalList?.itemList ?? [])
            .compactMap { item -> (String, QQVideoInfo)? in
                guard let coverID = item.doc?.id, let video = item.videoInfo, !(video.title ?? "").isEmpty else { return nil }
                return (coverID, video)
            }
            .map { ($0.0, $0.1, Self.titleSimilarity(request.title, $0.1.title ?? "")) }
            .sorted { $0.2 > $1.2 }
            .prefix(2)

        var candidates: [ProviderCandidate] = []
        for (coverID, video, score) in ranked {
            let site = video.episodeSites?.first { $0.enName == "qq" }
            let episodes = try await loadQQEpisodes(
                coverID: coverID,
                total: site?.totalEpisode ?? site?.episodeInfoList?.count ?? 1,
                initial: site?.episodeInfoList ?? []
            )
            for (index, episode) in episodes.enumerated() {
                guard let vid = episode.id, !vid.isEmpty else { continue }
                let number = Int(episode.title ?? "") ?? index + 1
                if let expected = request.episode, number != expected { continue }
                let duration = episode.duration.flatMap(Double.init)
                let confidence = Self.adjustedConfidence(
                    titleScore: score,
                    localDuration: request.duration,
                    remoteDuration: duration
                )
                guard confidence > 0 else { continue }
                candidates.append(ProviderCandidate(
                    source: .qq,
                    sourceInstanceName: "腾讯视频（App 内置）",
                    platformEpisodeId: vid,
                    title: video.title ?? "腾讯视频",
                    episodeTitle: Self.episodeLabel(number: number, subtitle: episode.titleSuffix),
                    duration: duration,
                    confidence: confidence
                ))
            }
        }
        return candidates
    }

    /// 展开腾讯视频首屏和分页剧集并按 vid 去重。
    private func loadQQEpisodes(
        coverID: String,
        total: Int,
        initial: [QQEpisode]
    ) async throws -> [QQEpisode] {
        guard let url = URL(string: "https://pbaccess.video.qq.com/trpc.videosearch.search_cgi.http/load_playsource_list_info") else {
            throw PublicDanmakuError.invalidURL
        }
        let pageCount = min(max(Int(ceil(Double(total) / 10)), 1), 12)
        var requests = [(scene: 8, page: 0)]
        requests.append(contentsOf: (0..<pageCount).map { (scene: 3, page: $0) })
        var episodes = initial
        for requestValue in requests {
            let body: [String: Any] = [
                "pageNum": requestValue.page, "platform": 2, "site": "qq", "appId": "10718",
                "dataType": 2, "id": coverID, "scene": requestValue.scene, "pageContext": "",
                "features": [], "themeType": "0",
            ]
            let envelope: QQEpisodeEnvelope = try await loadJSON(jsonRequest(url: url, body: body))
            let values = envelope.data?.normalList?.itemList?.first?.videoInfo?
                .firstBlockSites?.first?.episodeInfoList ?? []
            episodes.append(contentsOf: values)
        }
        var byID: [String: QQEpisode] = [:]
        for episode in episodes {
            if let id = episode.id, !id.isEmpty { byID[id] = episode }
        }
        return byID.values.sorted {
            (Int($0.title ?? "") ?? Int.max) < (Int($1.title ?? "") ?? Int.max)
        }
    }

    /// 按 base 索引并发拉取腾讯视频的全部弹幕分片。
    private func loadQQDanmaku(_ platformEpisodeID: String) async throws -> [DanmakuItem] {
        guard let vid = Self.qqVID(from: platformEpisodeID) else {
            throw PublicDanmakuError.invalidEpisodeID
        }
        let names = try await loadQQSegmentNames(vid: vid)
        var items: [DanmakuItem] = []
        for start in stride(from: 0, to: names.count, by: Self.segmentConcurrency) {
            let end = min(start + Self.segmentConcurrency, names.count)
            let batch = Array(names[start..<end])
            let values = try await withThrowingTaskGroup(of: [DanmakuItem].self) { group in
                for name in batch {
                    group.addTask { try await self.loadQQSegment(vid: vid, name: name) }
                }
                var result: [[DanmakuItem]] = []
                for try await value in group { result.append(value) }
                return result
            }
            for value in values { items.append(contentsOf: value) }
        }
        return items.sorted { $0.time < $1.time }
    }

    /// 获取腾讯视频弹幕分片名称列表。
    private func loadQQSegmentNames(vid: String) async throws -> [String] {
        guard let url = URL(string: "https://dm.video.qq.com/barrage/base/\(vid)") else {
            throw PublicDanmakuError.invalidURL
        }
        let envelope: QQBarrageBase = try await loadJSON(makeRequest(url: url, referer: "https://v.qq.com/"))
        let names = (envelope.segmentIndex ?? [:]).values.compactMap(\.segmentName)
        guard !names.isEmpty else { throw PublicDanmakuError.invalidResponse }
        return names
    }

    /// 下载并归一化单个腾讯视频弹幕分片。
    private func loadQQSegment(vid: String, name: String) async throws -> [DanmakuItem] {
        guard let url = URL(string: "https://dm.video.qq.com/barrage/segment/\(vid)/\(name)") else {
            throw PublicDanmakuError.invalidURL
        }
        let envelope: QQBarrageSegment = try await loadJSON(makeRequest(url: url, referer: "https://v.qq.com/"))
        return (envelope.barrageList ?? []).enumerated().compactMap { index, barrage in
            guard let milliseconds = barrage.timeOffset.flatMap(Int.init),
                  let content = barrage.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { return nil }
            let style = Self.qqStyle(barrage.contentStyle)
            return DanmakuItem(
                id: "qq:\(barrage.id ?? "\(name)-\(index)")",
                time: Double(milliseconds) / 1_000,
                mode: style.mode,
                fontSize: 25,
                color: style.color,
                content: content,
                source: .qq,
                senderHash: barrage.vuid?.isEmpty == false ? barrage.vuid : nil,
                createdAt: barrage.createTime.flatMap(Int.init),
                weight: max(0, min(10, Int(((barrage.contentScore ?? 50) / 10).rounded())))
            )
        }
    }

    /// 创建带来源页请求头的 GET 请求。
    private func makeRequest(url: URL, referer: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Kanata/0.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 创建腾讯视频 JSON POST 请求。
    private func jsonRequest(url: URL, body: [String: Any]) throws -> URLRequest {
        var request = makeRequest(url: url, referer: "https://v.qq.com/")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://v.qq.com", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 执行请求并校验 HTTP 状态码。
    private func loadData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PublicDanmakuError.invalidResponse
        }
        return data
    }

    /// 执行请求并解码 JSON。
    private func loadJSON<T: Decodable>(_ request: URLRequest) async throws -> T {
        try JSONDecoder().decode(T.self, from: await loadData(request))
    }

    /// 解压爱奇艺 zlib 弹幕数据，并按需扩大输出缓冲区。
    private static func inflateZlib(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var capacity = max(data.count * 16, 2 * 1_024 * 1_024)
        while capacity <= 32 * 1_024 * 1_024 {
            var output = Data(count: capacity)
            let decoded = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    guard let destinationAddress = destination.bindMemory(to: UInt8.self).baseAddress,
                          let sourceAddress = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        destinationAddress,
                        capacity,
                        sourceAddress,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if decoded > 0 {
                output.count = decoded
                return output
            }
            capacity *= 2
        }
        throw PublicDanmakuError.decompressionFailed
    }

    /// 从腾讯视频 URL 或纯 vid 中提取剧集标识。
    private static func qqVID(from value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "^[A-Za-z]\\d+[A-Za-z0-9]+$", options: .regularExpression) != nil {
            return text
        }
        guard let range = text.range(
            of: "/x/(?:cover|page)/(?:[^/]+/)?([A-Za-z]\\d+[A-Za-z0-9]+)(?:\\.html)?",
            options: .regularExpression
        ) else { return nil }
        let match = String(text[range])
        return match.split(separator: "/").last.map { String($0).replacingOccurrences(of: ".html", with: "") }
    }

    /// 解析腾讯视频弹幕颜色和位置样式。
    private static func qqStyle(_ value: String?) -> (mode: DanmakuMode, color: Int) {
        guard let value, let data = value.data(using: .utf8),
              let style = try? JSONDecoder().decode(QQBarrageStyle.self, from: data) else {
            return (.scroll, 16_777_215)
        }
        let color = style.color.flatMap { Int($0.replacingOccurrences(of: "#", with: ""), radix: 16) }
            ?? 16_777_215
        let mode: DanmakuMode = style.position == 2 ? .top : style.position == 3 ? .bottom : .scroll
        return (mode, color)
    }

    /// 将平台时长与本地时长差异纳入候选置信度。
    private static func adjustedConfidence(
        titleScore: Double,
        localDuration: Double?,
        remoteDuration: Double?
    ) -> Double {
        guard let localDuration, localDuration > 0,
              let remoteDuration, remoteDuration > 0 else { return titleScore }
        let difference = abs(localDuration - remoteDuration) / localDuration
        if difference > 0.1 { return 0 }
        return titleScore * (1 - difference * 2)
    }

    /// 计算适合候选排序的简化标题相似度。
    private static func titleSimilarity(_ left: String, _ right: String) -> Double {
        let a = normalizedTitle(left)
        let b = normalizedTitle(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) {
            return 0.85 + 0.1 * Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        }
        let common = Set(a).intersection(Set(b)).count
        return Double(common) / Double(max(Set(a).union(Set(b)).count, 1))
    }

    /// 移除标题中的空白和标点用于模糊比较。
    private static func normalizedTitle(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 把 mm:ss 或 hh:mm:ss 转换为秒。
    private static func parseClock(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 ? seconds : nil
    }

    /// 生成始终显示集号的分集标题。
    private static func episodeLabel(number: Int, subtitle: String?) -> String {
        let value = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "第 \(number) 集" : "第 \(number) 集 · \(value)"
    }
}

/// 爱奇艺 XML 解析代理，将单个分片直接转换为统一弹幕模型。
private final class IqiyiBulletXMLDelegate: NSObject, XMLParserDelegate {
    private var element = ""
    private var text = ""
    private var fields: [String: String] = [:]
    private(set) var items: [DanmakuItem] = []

    /// 在新元素开始时准备收集文本，进入 bulletInfo 时清空字段。
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        element = elementName
        text = ""
        if elementName == "bulletInfo" { fields.removeAll(keepingCapacity: true) }
    }

    /// 累积 XMLParser 可能分批提供的字段文本。
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    /// 在字段结束时保存值，在 bulletInfo 结束时生成弹幕条目。
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "bulletInfo" {
            appendCurrentItem()
        } else if !elementName.isEmpty {
            fields[elementName] = text
        }
        element = ""
        text = ""
    }

    /// 把当前 bulletInfo 字段转换为统一弹幕条目。
    private func appendCurrentItem() {
        guard let time = fields["showTime"].flatMap(Double.init),
              let content = fields["content"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return }
        let position = fields["position"].flatMap(Int.init) ?? 0
        let mode: DanmakuMode = position == 2 ? .top : position == 3 ? .bottom : .scroll
        let color = fields["color"].flatMap { Int($0.replacingOccurrences(of: "#", with: ""), radix: 16) }
            ?? 16_777_215
        let font = fields["font"].flatMap(Double.init).map { max(18, ($0 * 1.6).rounded()) } ?? 25
        items.append(DanmakuItem(
            id: "iqiyi:\(fields["contentId"] ?? UUID().uuidString)",
            time: time,
            mode: mode,
            fontSize: font,
            color: color,
            content: content,
            source: .iqiyi,
            senderHash: fields["uid"],
            weight: fields["scoreLevel"].flatMap(Int.init) ?? 5
        ))
    }
}

/// 内置公共弹幕来源的用户可读错误。
private enum PublicDanmakuError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidEpisodeID
    case iqiyiDurationRequired
    case decompressionFailed
    case unsupportedSource

    /// 返回播放页可直接展示的错误说明。
    var errorDescription: String? {
        switch self {
        case .invalidURL: "弹幕接口地址无效"
        case .invalidResponse: "平台弹幕接口返回异常"
        case .invalidEpisodeID: "平台剧集标识无效"
        case .iqiyiDurationRequired: "爱奇艺弹幕候选缺少视频时长，请重新搜索选择"
        case .decompressionFailed: "爱奇艺弹幕解压失败"
        case .unsupportedSource: "该来源不属于内置公共弹幕源"
        }
    }
}

private struct IqiyiSearchEnvelope: Decodable {
    let code: String?
    let data: IqiyiSearchData?
}

private struct IqiyiSearchData: Decodable {
    let docinfos: [IqiyiSearchDocument]?
}

private struct IqiyiSearchDocument: Decodable {
    let albumDocInfo: IqiyiAlbum?
}

private struct IqiyiAlbum: Decodable {
    let albumId: Int?
    let albumTitle: String?
}

private struct IqiyiEpisodeEnvelope: Decodable {
    let code: String?
    let data: IqiyiEpisodeData?
}

private struct IqiyiEpisodeData: Decodable {
    let epsodelist: [IqiyiEpisode]?
}

private struct IqiyiEpisode: Decodable {
    let tvId: Int?
    let subtitle: String?
    let duration: String?
    let order: Int?
}

private struct QQSearchEnvelope: Decodable {
    let data: QQSearchData?
}

private struct QQSearchData: Decodable {
    let errcode: Int?
    let normalList: QQNormalList?
}

private struct QQNormalList: Decodable {
    let itemList: [QQSearchItem]?
}

private struct QQSearchItem: Decodable {
    let doc: QQDocument?
    let videoInfo: QQVideoInfo?
}

private struct QQDocument: Decodable {
    let id: String?
}

private struct QQVideoInfo: Decodable {
    let title: String?
    let episodeSites: [QQSite]?
    let firstBlockSites: [QQSite]?
}

private struct QQSite: Decodable {
    let enName: String?
    let totalEpisode: Int?
    let episodeInfoList: [QQEpisode]?
}

private struct QQEpisode: Decodable {
    let id: String?
    let title: String?
    let titleSuffix: String?
    let duration: String?
}

private struct QQEpisodeEnvelope: Decodable {
    let data: QQEpisodeData?
}

private struct QQEpisodeData: Decodable {
    let normalList: QQEpisodeNormalList?
}

private struct QQEpisodeNormalList: Decodable {
    let itemList: [QQEpisodeItem]?
}

private struct QQEpisodeItem: Decodable {
    let videoInfo: QQVideoInfo?
}

private struct QQBarrageBase: Decodable {
    let segmentIndex: [String: QQBarrageIndex]?

    private enum CodingKeys: String, CodingKey {
        case segmentIndex = "segment_index"
    }
}

private struct QQBarrageIndex: Decodable {
    let segmentName: String?

    private enum CodingKeys: String, CodingKey {
        case segmentName = "segment_name"
    }
}

private struct QQBarrageSegment: Decodable {
    let barrageList: [QQBarrage]?

    private enum CodingKeys: String, CodingKey {
        case barrageList = "barrage_list"
    }
}

private struct QQBarrage: Decodable {
    let id: String?
    let timeOffset: String?
    let content: String?
    let contentStyle: String?
    let vuid: String?
    let createTime: String?
    let contentScore: Double?

    private enum CodingKeys: String, CodingKey {
        case id, content, vuid
        case timeOffset = "time_offset"
        case contentStyle = "content_style"
        case createTime = "create_time"
        case contentScore = "content_score"
    }
}

private struct QQBarrageStyle: Decodable {
    let color: String?
    let position: Int?
}
