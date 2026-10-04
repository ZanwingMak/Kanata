import Compression
import CryptoKit
import Foundation
import KanataCore

/// App 内置的平台弹幕客户端，单个来源失败不会阻塞其他来源。
actor BuiltInPublicDanmakuClient {
    private static let iqiyiSegmentSeconds = 300
    private static let segmentConcurrency = 5
    private static let maximumIqiyiSegments = 48
    private let session: URLSession
    private let enabledSources: Set<DanmakuSourceId>

    /// 创建使用临时会话的内置公共来源客户端。
    /// - Parameter enabledSources: 用户允许参与搜索和探活的来源集合。
    init(enabledSources: Set<DanmakuSourceId> = [.iqiyi, .qq, .bahamut, .acfun, .youku]) {
        self.enabledSources = enabledSources
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// 搜索已启用的平台弹幕来源，并返回按置信度排序的候选。
    /// - Parameter request: 标题、可选集号和本地视频时长。
    /// - Returns: 各平台合并后的候选列表。
    func search(_ request: ResolveRequest) async -> [ProviderCandidate] {
        var candidates: [ProviderCandidate] = []
        if enabledSources.contains(.iqiyi), let iqiyi = try? await searchIqiyi(request) {
            candidates.append(contentsOf: iqiyi)
        }
        if enabledSources.contains(.qq), let qq = try? await searchQQ(request) {
            candidates.append(contentsOf: qq)
        }
        if enabledSources.contains(.bahamut), let bahamut = try? await searchBahamut(request) {
            candidates.append(contentsOf: bahamut)
        }
        if enabledSources.contains(.acfun), let acfun = try? await searchAcfun(request) {
            candidates.append(contentsOf: acfun)
        }
        if enabledSources.contains(.youku), let youku = try? await searchYouku(request) {
            candidates.append(contentsOf: youku)
        }
        return candidates.sorted { left, right in
            if left.confidence == right.confidence {
                return (left.episodeTitle ?? "") < (right.episodeTitle ?? "")
            }
            return left.confidence > right.confidence
        }
    }

    /// 按候选来源拉取完整弹幕。
    /// - Parameter candidate: 已启用平台返回的候选。
    /// - Returns: 已按时间排序的统一弹幕。
    func danmaku(for candidate: ProviderCandidate) async throws -> [DanmakuItem] {
        switch candidate.source {
        case .iqiyi:
            return try await loadIqiyiDanmaku(candidate.platformEpisodeId)
        case .qq:
            return try await loadQQDanmaku(candidate.platformEpisodeId)
        case .bahamut:
            return try await loadBahamutDanmaku(candidate.platformEpisodeId)
        case .acfun:
            return try await loadAcfunDanmaku(candidate.platformEpisodeId)
        case .youku:
            return try await loadYoukuDanmaku(candidate.platformEpisodeId)
        default:
            throw PublicDanmakuError.unsupportedSource
        }
    }

    /// 轻量探测已启用的平台弹幕是否可访问。
    /// - Returns: 每个已启用平台的可用状态。
    func health() async -> [DanmakuSourceId: Bool] {
        var result: [DanmakuSourceId: Bool] = [:]
        if enabledSources.contains(.iqiyi) {
            result[.iqiyi] = ((try? await loadIqiyiSegment(tvID: "3493131456125200", index: 1).count) ?? 0) > 20
        }
        if enabledSources.contains(.qq) {
            let qqSegments = try? await loadQQSegmentNames(vid: "q4100dpkd26")
            if let name = qqSegments?.first {
                result[.qq] = ((try? await loadQQSegment(vid: "q4100dpkd26", name: name).count) ?? 0) > 20
            } else {
                result[.qq] = false
            }
        }
        if enabledSources.contains(.bahamut) {
            result[.bahamut] = ((try? await loadBahamutDanmaku("31599").count) ?? 0) > 20
        }
        if enabledSources.contains(.acfun) {
            result[.acfun] = ((try? await loadAcfunPage(videoID: "11137579", cursor: "1").danmakus?.count) ?? 0) > 0
        }
        if enabledSources.contains(.youku) {
            result[.youku] = ((try? await loadYoukuDanmaku("XNTE3ODIxMDEzNg==@120").count) ?? 0) > 0
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

    /// 搜索巴哈姆特动画疯作品并展开逐集候选。
    /// - Parameter request: 作品标题、可选集号和本地时长。
    /// - Returns: 最相似的两个作品的分集列表。
    private func searchBahamut(_ request: ResolveRequest) async throws -> [ProviderCandidate] {
        if let direct = Self.bahamutVideoSN(from: request.title) {
            return [ProviderCandidate(
                source: .bahamut,
                sourceInstanceName: "巴哈姆特动画疯（App 内置）",
                platformEpisodeId: direct,
                title: "巴哈姆特动画疯",
                episodeTitle: request.episode.map { "第 \($0) 集" } ?? "指定视频",
                confidence: 1
            )]
        }
        guard let url = URL(string: "https://ani.gamer.com.tw/search.php") else {
            throw PublicDanmakuError.invalidURL
        }
        var requestValue = makeRequest(url: url, referer: "https://ani.gamer.com.tw/")
        requestValue.httpMethod = "POST"
        requestValue.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "keyword", value: request.title)]
        requestValue.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let html = String(decoding: try await loadData(requestValue), as: UTF8.self)
        let results = Self.regexMatches(
            pattern: #"animeRef\.php\?sn=(\d+)[^>]*>[\s\S]*?<p class=['\"]theme-name['\"]>([\s\S]*?)</p>"#,
            text: html
        )
        .compactMap { values -> (String, String, Double)? in
            guard values.count >= 3 else { return nil }
            let title = Self.decodeHTML(values[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return (values[1], title, Self.titleSimilarity(request.title, title))
        }
        .sorted { $0.2 > $1.2 }
        .prefix(2)

        var candidates: [ProviderCandidate] = []
        for (referenceID, title, score) in results {
            guard let pageURL = URL(string: "https://ani.gamer.com.tw/animeRef.php?sn=\(referenceID)") else {
                continue
            }
            let page = String(
                decoding: try await loadData(makeRequest(url: pageURL, referer: "https://ani.gamer.com.tw/")),
                as: UTF8.self
            )
            let duration = Self.bahamutDuration(from: page)
            let episodes = Self.regexMatches(
                pattern: #"data-ani-video-sn=['\"](\d+)['\"][^>]*>([^<]+)</a>"#,
                text: page
            )
            for (offset, values) in episodes.enumerated() where values.count >= 3 {
                let number = Int(Self.decodeHTML(values[2]).trimmingCharacters(in: .whitespacesAndNewlines))
                    ?? offset + 1
                if let expected = request.episode, number != expected { continue }
                let confidence = Self.adjustedConfidence(
                    titleScore: score,
                    localDuration: request.duration,
                    remoteDuration: duration
                )
                guard confidence > 0 else { continue }
                candidates.append(ProviderCandidate(
                    source: .bahamut,
                    sourceInstanceName: "巴哈姆特动画疯（App 内置）",
                    platformEpisodeId: values[1],
                    title: title,
                    episodeTitle: Self.episodeLabel(number: number, subtitle: nil),
                    duration: duration,
                    confidence: confidence
                ))
            }
        }
        return candidates
    }

    /// 拉取并归一化巴哈姆特动画疯指定剧集的全部弹幕。
    /// - Parameter platformEpisodeID: animeVideo.php 的数字 sn。
    /// - Returns: 已按时间排序的统一弹幕。
    private func loadBahamutDanmaku(_ platformEpisodeID: String) async throws -> [DanmakuItem] {
        guard let sn = Self.bahamutVideoSN(from: platformEpisodeID),
              let url = URL(string: "https://ani.gamer.com.tw/ajax/danmuGet.php") else {
            throw PublicDanmakuError.invalidEpisodeID
        }
        var request = makeRequest(
            url: url,
            referer: "https://ani.gamer.com.tw/animeVideo.php?sn=\(sn)"
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("sn=\(sn)".utf8)
        let values: [BahamutBullet] = try await loadJSON(request)
        return values.compactMap { bullet in
            let content = bullet.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty, bullet.time >= 0 else { return nil }
            let mode: DanmakuMode = bullet.position == 1 ? .top : bullet.position == 2 ? .bottom : .scroll
            let fontSizes = [20.0, 25.0, 30.0]
            let fontSize = fontSizes[min(max(bullet.size, 0), fontSizes.count - 1)]
            let color = Int(bullet.color.replacingOccurrences(of: "#", with: ""), radix: 16)
                ?? 16_777_215
            return DanmakuItem(
                id: "bahamut:\(bullet.sn)",
                time: Double(bullet.time),
                mode: mode,
                fontSize: fontSize,
                color: color,
                content: content,
                source: .bahamut,
                senderHash: bullet.userid.isEmpty ? nil : bullet.userid,
                weight: 5
            )
        }
        .sorted { $0.time < $1.time }
    }

    /// 搜索 AcFun 视频；只有标题和集号明确相符的结果才进入候选。
    private func searchAcfun(_ request: ResolveRequest) async throws -> [ProviderCandidate] {
        if let contentID = Self.regexMatches(pattern: #"(?:acfun\.cn/v/ac|^ac)(\d+)"#, text: request.title).first?.last,
           let page = URL(string: "https://www.acfun.cn/v/ac\(contentID)") {
            let html = String(decoding: try await loadData(makeRequest(url: page, referer: "https://www.acfun.cn/")), as: UTF8.self)
            guard let videoID = Self.regexMatches(pattern: #"\"videoList\":\[\{[^}]*\"id\":\"(\d+)\""#, text: html).first?.last else {
                throw PublicDanmakuError.invalidResponse
            }
            return [ProviderCandidate(source: .acfun, sourceInstanceName: "AcFun（App 内置）",
                                      platformEpisodeId: videoID, title: "AcFun 视频",
                                      episodeTitle: request.episode.map { "第 \($0) 集" } ?? "指定视频", confidence: 1)]
        }
        var components = URLComponents(string: "https://www.acfun.cn/rest/pc-direct/search/video")
        components?.queryItems = [URLQueryItem(name: "keyword", value: request.title),
                                  URLQueryItem(name: "page", value: "1"),
                                  URLQueryItem(name: "pageSize", value: "20")]
        guard let url = components?.url else { throw PublicDanmakuError.invalidURL }
        let result: AcfunSearchEnvelope = try await loadJSON(makeRequest(url: url, referer: "https://www.acfun.cn/"))
        guard result.result == 0 else { throw PublicDanmakuError.invalidResponse }
        return (result.videoList ?? []).compactMap { video in
            guard let videoID = video.videoId, let title = video.title, !title.isEmpty else { return nil }
            let score = Self.titleSimilarity(request.title, title)
            guard score >= 0.45 else { return nil }
            let numbers = Self.regexMatches(pattern: #"(?:第\s*(\d+)\s*[集话]|(?:EP|E)\s*0*(\d+))"#, text: title)
            let episode = numbers.first?.dropFirst().first(where: { !$0.isEmpty }).flatMap(Int.init)
            if let expected = request.episode, episode != expected { return nil }
            return ProviderCandidate(source: .acfun, sourceInstanceName: "AcFun（App 内置）",
                                     platformEpisodeId: videoID, title: title,
                                     episodeTitle: episode.map { "第 \($0) 集" } ?? "单个视频",
                                     confidence: min(score, 0.88), danmakuCount: video.danmuCount)
        }
        .sorted { $0.confidence > $1.confidence }
        .prefix(12)
        .map { $0 }
    }

    /// 按 AcFun 分页游标拉取一页视频弹幕。
    private func loadAcfunPage(videoID: String, cursor: String) async throws -> AcfunDanmakuEnvelope {
        guard let url = URL(string: "https://www.acfun.cn/rest/pc-direct/new-danmaku/list") else {
            throw PublicDanmakuError.invalidURL
        }
        var request = makeRequest(url: url, referer: "https://www.acfun.cn/")
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "resourceId", value: videoID),
                           URLQueryItem(name: "resourceType", value: "9"),
                           URLQueryItem(name: "enableAdvanced", value: "true"),
                           URLQueryItem(name: "pcursor", value: cursor),
                           URLQueryItem(name: "count", value: "200"),
                           URLQueryItem(name: "sortType", value: "2"),
                           URLQueryItem(name: "asc", value: "true")]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let result: AcfunDanmakuEnvelope = try await loadJSON(request)
        guard result.result == 0 else { throw PublicDanmakuError.invalidResponse }
        return result
    }

    /// 拉取 AcFun 全部分页并转换为统一弹幕模型。
    private func loadAcfunDanmaku(_ videoID: String) async throws -> [DanmakuItem] {
        guard !videoID.isEmpty, videoID.allSatisfy(\.isNumber) else { throw PublicDanmakuError.invalidEpisodeID }
        var cursor = "1"
        var seen = Set<String>()
        var items: [DanmakuItem] = []
        for _ in 0..<100 {
            guard seen.insert(cursor).inserted else { break }
            let page = try await loadAcfunPage(videoID: videoID, cursor: cursor)
            items.append(contentsOf: (page.danmakus ?? []).compactMap { bullet in
                guard let position = bullet.position, position >= 0,
                      let content = bullet.body?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
                let mode: DanmakuMode = bullet.mode == 4 ? .bottom : bullet.mode == 5 ? .top : .scroll
                return DanmakuItem(id: "acfun:\(bullet.danmakuId ?? 0)", time: Double(position) / 1_000,
                                   mode: mode, fontSize: Double(bullet.size ?? 25),
                                   color: bullet.color ?? 16_777_215, content: content, source: .acfun,
                                   senderHash: bullet.userId.map(String.init),
                                   createdAt: bullet.createTime.map { $0 / 1_000 }, weight: bullet.rank)
            })
            guard let next = page.pcursor, next != "no_more", next != cursor else { break }
            cursor = next
        }
        return items.sorted { $0.time < $1.time }
    }

    /// 优酷公开搜索接口当前不可用；仅对用户粘贴的视频链接或 vid 建立准确候选。
    private func searchYouku(_ request: ResolveRequest) async throws -> [ProviderCandidate] {
        let value = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("youku.com") || value.hasPrefix("XN") else { return [] }
        let path = URLComponents(string: value)?.url?.path ?? value
        let videoID = Self.regexMatches(pattern: #"(?:v_show/id_|^)([A-Za-z0-9]+={0,2})(?:\.html)?$"#, text: path).first?.last
        guard let videoID, videoID.count >= 12 else { return [] }
        let duration = request.duration.flatMap { $0 > 0 ? Int($0) : nil } ?? 1_800
        return [ProviderCandidate(source: .youku, sourceInstanceName: "优酷（App 内置）",
                                  platformEpisodeId: "\(videoID)@\(duration)", title: "优酷视频",
                                  episodeTitle: request.episode.map { "第 \($0) 集" } ?? "指定视频",
                                  duration: request.duration, confidence: 1)]
    }

    /// 获取优酷 MTOP 临时令牌；仅在内存中使用，不持久化 Cookie。
    private func youkuToken() async throws -> (token: String, encoded: String) {
        guard let url = URL(string: "https://acs.youku.com/h5/mtop.com.youku.aplatform.weakget/1.0/?jsv=2.5.1&appKey=24679788") else {
            throw PublicDanmakuError.invalidURL
        }
        let (_, response) = try await session.data(for: makeRequest(url: url, referer: "https://v.youku.com/"))
        guard let http = response as? HTTPURLResponse else { throw PublicDanmakuError.invalidResponse }
        let headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let key = key as? String, let value = value as? String else { return nil }
            return (key, value)
        })
        let cookies = session.configuration.httpCookieStorage?.cookies(for: url)
            ?? HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        guard let token = cookies.first(where: { $0.name == "_m_h5_tk" })?.value,
              let encoded = cookies.first(where: { $0.name == "_m_h5_tk_enc" })?.value else {
            throw PublicDanmakuError.invalidResponse
        }
        return (token, encoded)
    }

    /// 请求一个 60 秒优酷弹幕分片，并解析双层 JSON 响应。
    private func loadYoukuSegment(videoID: String, minute: Int, token: String, encoded: String) async throws -> [DanmakuItem] {
        var message: [String: Any] = ["ctime": Int(Date().timeIntervalSince1970 * 1_000),
                                      "ctype": 10004, "cver": "v1.0", "guid": UUID().uuidString,
                                      "mat": minute, "mcount": 1, "pid": 0, "sver": "3.1.0",
                                      "type": 1, "vid": videoID]
        let encodedMessage = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]).base64EncodedString()
        message["msg"] = encodedMessage
        message["sign"] = Self.md5(encodedMessage + "MkmC9SoIw6xCkSKHhJ7b5D2r51kBiREr")
        let data = String(decoding: try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), as: UTF8.self)
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1_000))
        let prefix = String(token.prefix(while: { $0 != "_" }))
        var components = URLComponents(string: "https://acs.youku.com/h5/mopen.youku.danmu.list/1.0/")
        components?.queryItems = [URLQueryItem(name: "jsv", value: "2.5.6"),
                                  URLQueryItem(name: "appKey", value: "24679788"),
                                  URLQueryItem(name: "t", value: timestamp),
                                  URLQueryItem(name: "sign", value: Self.md5("\(prefix)&\(timestamp)&24679788&\(data)")),
                                  URLQueryItem(name: "api", value: "mopen.youku.danmu.list"),
                                  URLQueryItem(name: "v", value: "1.0"),
                                  URLQueryItem(name: "type", value: "originaljson"),
                                  URLQueryItem(name: "dataType", value: "jsonp")]
        guard let url = components?.url else { throw PublicDanmakuError.invalidURL }
        var request = makeRequest(url: url, referer: "https://v.youku.com/")
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("_m_h5_tk=\(token); _m_h5_tk_enc=\(encoded)", forHTTPHeaderField: "Cookie")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "data", value: data)]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let outer: YoukuEnvelope = try await loadJSON(request)
        guard let inner = outer.data?.result?.data(using: .utf8),
              let result = try? JSONDecoder().decode(YoukuResult.self, from: inner), result.code == 1 else {
            throw PublicDanmakuError.invalidResponse
        }
        return (result.data?.result ?? []).compactMap { bullet in
            guard let milliseconds = bullet.playat,
                  let content = bullet.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return nil }
            let style = bullet.propertis?.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode(YoukuBulletStyle.self, from: $0) }
            let mode: DanmakuMode = style?.pos == 2 ? .top : style?.pos == 3 ? .bottom : .scroll
            return DanmakuItem(id: "youku:\(bullet.id ?? 0)", time: Double(milliseconds) / 1_000,
                               mode: mode, color: style?.color ?? 16_777_215,
                               content: content, source: .youku, senderHash: bullet.uid)
        }
    }

    /// 按本地片长获取优酷所有分钟分片，单个空分片不影响其余结果。
    private func loadYoukuDanmaku(_ platformEpisodeID: String) async throws -> [DanmakuItem] {
        let parts = platformEpisodeID.split(separator: "@", maxSplits: 1).map(String.init)
        guard let videoID = parts.first, videoID.count >= 12 else { throw PublicDanmakuError.invalidEpisodeID }
        let duration = parts.count > 1 ? Int(parts[1]) ?? 1_800 : 1_800
        let segments = min(max(Int(ceil(Double(duration) / 60)), 1), 120)
        let credential = try await youkuToken()
        var items: [DanmakuItem] = []
        for start in stride(from: 0, to: segments, by: Self.segmentConcurrency) {
            let batch = await withTaskGroup(of: [DanmakuItem].self) { group in
                for minute in start..<min(start + Self.segmentConcurrency, segments) {
                    group.addTask {
                        (try? await self.loadYoukuSegment(videoID: videoID, minute: minute,
                                                         token: credential.token, encoded: credential.encoded)) ?? []
                    }
                }
                var values: [DanmakuItem] = []
                for await value in group { values.append(contentsOf: value) }
                return values
            }
            items.append(contentsOf: batch)
        }
        return items.sorted { $0.time < $1.time }
    }

    /// 计算优酷请求使用的小写 MD5 十六进制签名。
    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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
        if let output = decodeDeflate(data) { return output }
        guard data.count > 6,
              data[0] & 0x0F == 8 else {
            throw PublicDanmakuError.decompressionFailed
        }
        let headerSize = data[1] & 0x20 == 0 ? 2 : 6
        guard data.count > headerSize + 4 else { throw PublicDanmakuError.decompressionFailed }
        let rawDeflate = Data(data.dropFirst(headerSize).dropLast(4))
        guard let output = decodeDeflate(rawDeflate) else {
            throw PublicDanmakuError.decompressionFailed
        }
        return output
    }

    /// 使用 Apple Compression 解码 DEFLATE，并在输出空间不足时逐步扩容。
    /// - Parameter data: 完整 zlib 或已剥离 RFC 1950 包装的 DEFLATE 数据。
    /// - Returns: 解码成功的数据；格式不受支持时返回 nil。
    private static func decodeDeflate(_ data: Data) -> Data? {
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
        return nil
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

    /// 从动画疯播放页或纯数字文本提取剧集 sn。
    /// - Parameter value: 用户输入或平台候选 ID。
    /// - Returns: 数字剧集标识。
    private static func bahamutVideoSN(from value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text.allSatisfy(\.isNumber) { return text }
        let values = regexMatches(pattern: #"animeVideo\.php\?sn=(\d+)"#, text: text)
        return values.first.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    /// 从页面 JSON-LD 的 ISO 8601 duration 读取秒数。
    /// - Parameter html: 动画疯播放页 HTML。
    /// - Returns: 可识别的分钟和秒数之和。
    private static func bahamutDuration(from html: String) -> Double? {
        guard let value = regexMatches(
            pattern: #"\"duration\":\"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?\""#,
            text: html
        ).first else { return nil }
        let hours = value.count > 1 ? Double(value[1]) ?? 0 : 0
        let minutes = value.count > 2 ? Double(value[2]) ?? 0 : 0
        let seconds = value.count > 3 ? Double(value[3]) ?? 0 : 0
        let total = hours * 3_600 + minutes * 60 + seconds
        return total > 0 ? total : nil
    }

    /// 返回正则表达式每个命中的完整文本和捕获组。
    /// - Parameters:
    ///   - pattern: ICU 正则表达式。
    ///   - text: 要搜索的 HTML 或 URL。
    /// - Returns: 每项第一个元素为完整命中，后续元素为捕获组。
    private static func regexMatches(pattern: String, text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                let value = match.range(at: index)
                guard value.location != NSNotFound, let range = Range(value, in: text) else { return "" }
                return String(text[range])
            }
        }
    }

    /// 解码搜索结果标题中常见的 HTML 实体并移除标签。
    /// - Parameter value: HTML 片段。
    /// - Returns: 适合匹配和展示的纯文本。
    private static func decodeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
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

/// 巴哈姆特动画疯弹幕 JSON 条目。
private struct BahamutBullet: Decodable {
    let text: String
    let color: String
    let size: Int
    let position: Int
    let time: Int
    let sn: Int
    let userid: String
}

private struct AcfunSearchEnvelope: Decodable {
    let result: Int?
    let videoList: [AcfunSearchVideo]?
}

private struct AcfunSearchVideo: Decodable {
    let videoId: String?
    let title: String?
    let danmuCount: Int?
}

private struct AcfunDanmakuEnvelope: Decodable {
    let result: Int?
    let danmakus: [AcfunBullet]?
    let pcursor: String?
}

private struct AcfunBullet: Decodable {
    let danmakuId: Int?
    let position: Int?
    let body: String?
    let mode: Int?
    let size: Int?
    let color: Int?
    let userId: Int?
    let createTime: Int?
    let rank: Int?
}

private struct YoukuEnvelope: Decodable {
    let data: YoukuEnvelopeData?
}

private struct YoukuEnvelopeData: Decodable {
    let result: String?
}

private struct YoukuResult: Decodable {
    let code: Int?
    let data: YoukuResultData?
}

private struct YoukuResultData: Decodable {
    let result: [YoukuBullet]?
}

private struct YoukuBullet: Decodable {
    let id: Int?
    let playat: Int?
    let content: String?
    let propertis: String?
    let uid: String?
}

private struct YoukuBulletStyle: Decodable {
    let color: Int?
    let pos: Int?
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
