import CryptoKit
import Foundation
import KanataCore

/// App 内置的哔哩哔哩弹幕客户端，让 TestFlight 在没有自建网关时仍可搜索和加载弹幕。
actor BuiltInBilibiliClient {
    private static let segmentSeconds = 360
    private static let maximumSegments = 60
    private static let segmentConcurrency = 5
    private static let mobileAppKey = "1d8b6e7d45233436"
    private static let mobileAppSecret = "560c52ccd288fed045859ed18bffd973"
    private static let mixinKeyTable = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
        27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
        37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
        22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    ]

    private let session: URLSession
    private let credentialCookie: String
    private var buvid3 = ""
    private var buvid4 = ""
    private var cachedMixinKey = ""
    private var mixinKeyDate = Date.distantPast

    /// 创建内置来源客户端；Cookie 为空时使用匿名访问。
    /// - Parameter cookie: 已经移除换行的 B 站 Cookie 字符串。
    init(cookie: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.credentialCookie = cookie
    }

    /// 按剧名或 B 站链接搜索弹幕候选。
    /// - Parameter request: 标题、季集号与本地时长信息。
    /// - Returns: 可直接交给播放页选择的候选列表。
    func search(_ request: ResolveRequest) async throws -> [ProviderCandidate] {
        if let direct = directCandidate(from: request.title) {
            return [direct]
        }

        try await ensureAnonymousFingerprint()
        let ranked = try await searchSeasons(title: request.title).prefix(3)

        var candidates: [ProviderCandidate] = []
        for result in ranked {
            let episodes = try await loadSeasonEpisodes(seasonID: result.seasonID)
            for (index, episode) in episodes.enumerated() {
                let number = Int(episode.title ?? "") ?? index + 1
                if let requestedEpisode = request.episode, requestedEpisode != number { continue }
                guard let cid = episode.cid else { continue }
                let duration = episode.duration.map { Double($0) / 1_000 }
                let confidence = Self.adjustedConfidence(
                    titleScore: result.score,
                    localDuration: request.duration,
                    remoteDuration: duration
                )
                candidates.append(ProviderCandidate(
                    source: .bilibili,
                    sourceInstanceName: "哔哩哔哩（App 内置）",
                    platformEpisodeId: duration.map { "\(cid)@\(Int($0.rounded()))" } ?? String(cid),
                    title: result.title,
                    episodeTitle: episode.longTitle?.isEmpty == false
                        ? episode.longTitle
                        : "第 \(number) 话",
                    duration: duration,
                    confidence: confidence
                ))
            }
        }
        return candidates.sorted { left, right in
            if left.confidence == right.confidence {
                return (left.episodeTitle ?? "") < (right.episodeTitle ?? "")
            }
            return left.confidence > right.confidence
        }
    }

    /// 拉取指定候选的全部普通弹幕。
    /// - Parameter platformEpisodeID: cid、cid@时长、BV、ep 或 ss 标识。
    /// - Returns: 已按播放时间排序的统一弹幕条目。
    func danmaku(platformEpisodeID: String) async throws -> [DanmakuItem] {
        try await ensureAnonymousFingerprint()
        let resolved = try await resolveCID(platformEpisodeID)
        let parts = resolved.split(separator: "@", maxSplits: 1).map(String.init)
        guard let cid = parts.first, cid.allSatisfy(\.isNumber) else {
            throw BuiltInBilibiliError.invalidEpisodeID
        }
        let duration = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let segmentCount = duration > 0
            ? min(Int(ceil(Double(duration) / Double(Self.segmentSeconds))), Self.maximumSegments)
            : 0

        var items: [DanmakuItem] = []
        if segmentCount > 0 {
            for start in stride(from: 1, through: segmentCount, by: Self.segmentConcurrency) {
                let end = min(start + Self.segmentConcurrency - 1, segmentCount)
                let batch = try await withThrowingTaskGroup(of: [DanmakuItem].self) { group in
                    for index in start...end {
                        group.addTask { try await self.loadSegment(cid: cid, index: index) }
                    }
                    var values: [[DanmakuItem]] = []
                    for try await value in group { values.append(value) }
                    return values
                }
                for value in batch { items.append(contentsOf: value) }
            }
        } else {
            for index in 1...Self.maximumSegments {
                let segment = try await loadSegment(cid: cid, index: index)
                if segment.isEmpty { break }
                items.append(contentsOf: segment)
            }
        }
        return items.sorted { $0.time < $1.time }
    }

    /// 校验当前客户端保存的 B 站 Cookie 是否仍然有效。
    /// - Returns: 登录有效性、昵称与失败说明。
    func verifyCredential() async throws -> (valid: Bool, displayName: String?, message: String?) {
        guard !credentialCookie.isEmpty else { return (false, nil, "未保存 Cookie") }
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            throw BuiltInBilibiliError.invalidResponse
        }
        let response: NavigationEnvelope = try await loadJSON(url)
        let valid = response.code == 0 && response.data?.isLogin == true
        return (valid, valid ? response.data?.uname : nil, valid ? nil : (response.message ?? "登录态已失效"))
    }

    /// 用稳定视频的第一片弹幕检查内置来源是否可访问。
    /// - Returns: 是否获得了有效弹幕数据。
    func health() async -> Bool {
        let count = (try? await loadSegment(cid: "144541892", index: 1).count) ?? 0
        return count > 20
    }

    /// 把 BV/ep/ss 标识解析为 cid@时长。
    /// - Parameter platformEpisodeID: 用户选择的来源标识。
    /// - Returns: cid 与可选时长。
    private func resolveCID(_ platformEpisodeID: String) async throws -> String {
        if platformEpisodeID.hasPrefix("bv:") {
            let value = String(platformEpisodeID.dropFirst(3))
            guard let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(value)") else {
                throw BuiltInBilibiliError.invalidEpisodeID
            }
            let response: VideoEnvelope = try await loadJSON(url)
            guard response.code == 0, let cid = response.data?.cid else {
                throw BuiltInBilibiliError.notFound
            }
            return "\(cid)@\(response.data?.duration ?? 0)"
        }
        if platformEpisodeID.hasPrefix("ep:") || platformEpisodeID.hasPrefix("ss:") {
            let isEpisode = platformEpisodeID.hasPrefix("ep:")
            let value = String(platformEpisodeID.dropFirst(3))
            let key = isEpisode ? "ep_id" : "season_id"
            guard let url = URL(string: "https://api.bilibili.com/pgc/view/web/season?\(key)=\(value)") else {
                throw BuiltInBilibiliError.invalidEpisodeID
            }
            let response: SeasonEnvelope = try await loadJSON(url)
            let episodes = response.result?.episodes ?? []
            let target = isEpisode
                ? episodes.first { String($0.id ?? 0) == value }
                : episodes.first
            guard let target, let cid = target.cid else { throw BuiltInBilibiliError.notFound }
            return "\(cid)@\(Int((Double(target.duration ?? 0) / 1_000).rounded()))"
        }
        return platformEpisodeID
    }

    /// 搜索季度条目；优先使用移动端签名接口，空结果时回退到 WBI 网页接口。
    /// - Parameter title: 用户输入的作品标题。
    /// - Returns: 按标题相似度排序的季度结果。
    private func searchSeasons(title: String) async throws -> [(seasonID: Int, title: String, score: Double)] {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let mobileQuery = signMobile([
            "appkey": Self.mobileAppKey,
            "build": "8000300",
            "c_locale": "zh_CN",
            "device": "android",
            "keyword": title,
            "mobi_app": "android",
            "platform": "android",
            "pn": "1",
            "ps": "20",
            "s_locale": "zh_CN",
            "ts": timestamp,
            "type": "7",
        ])
        if let url = URL(string: "https://app.bilibili.com/x/v2/search/type?\(mobileQuery)"),
           let response: MobileSearchEnvelope = try? await loadJSON(url),
           response.code == 0 {
            let values = (response.data?.items ?? []).compactMap { item -> (Int, String, Double)? in
                guard let seasonID = item.seasonID else { return nil }
                let cleanTitle = Self.removeHTML(item.title ?? "")
                return (seasonID, cleanTitle, Self.titleSimilarity(title, cleanTitle))
            }
            if !values.isEmpty { return values.sorted { $0.2 > $1.2 } }
        }

        let mixinKey = try await loadMixinKey()
        let webQuery = signWBI([
            "keyword": title,
            "page": "1",
            "search_type": "media_bangumi",
        ], mixinKey: mixinKey)
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/wbi/search/type?\(webQuery)") else {
            throw BuiltInBilibiliError.invalidResponse
        }
        let response: SearchEnvelope = try await loadJSON(url)
        guard response.code == 0 else {
            throw BuiltInBilibiliError.upstream(response.message ?? "搜索请求失败")
        }
        return (response.data?.result ?? [])
            .compactMap { result -> (Int, String, Double)? in
                guard let seasonID = result.seasonID else { return nil }
                let cleanTitle = Self.removeHTML(result.title ?? "")
                return (seasonID, cleanTitle, Self.titleSimilarity(title, cleanTitle))
            }
            .sorted { $0.2 > $1.2 }
    }

    /// 读取一个季度的全部分集。
    /// - Parameter seasonID: B 站季度 ID。
    /// - Returns: 平台分集数组。
    private func loadSeasonEpisodes(seasonID: Int) async throws -> [SeasonEpisode] {
        guard let url = URL(string: "https://api.bilibili.com/pgc/view/web/season?season_id=\(seasonID)") else {
            throw BuiltInBilibiliError.invalidResponse
        }
        let response: SeasonEnvelope = try await loadJSON(url)
        guard response.code == 0, let episodes = response.result?.episodes else {
            throw BuiltInBilibiliError.upstream(response.message ?? "季度信息读取失败")
        }
        return episodes
    }

    /// 拉取并解析一个 6 分钟弹幕分片。
    /// - Parameters:
    ///   - cid: B 站视频 cid。
    ///   - index: 从 1 开始的分片序号。
    /// - Returns: 当前分片中的普通弹幕。
    private func loadSegment(cid: String, index: Int) async throws -> [DanmakuItem] {
        guard let url = URL(string: "https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=\(cid)&segment_index=\(index)") else {
            throw BuiltInBilibiliError.invalidResponse
        }
        let (data, response) = try await loadData(url)
        if response.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true {
            return []
        }
        return Self.parseSegment(data)
    }

    /// 获取匿名设备指纹，减少搜索接口被静默返回空结果的概率。
    private func ensureAnonymousFingerprint() async throws {
        guard buvid3.isEmpty || buvid4.isEmpty else { return }
        guard let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") else {
            throw BuiltInBilibiliError.invalidResponse
        }
        let response: FingerprintEnvelope = try await loadJSON(url)
        buvid3 = response.data?.buvid3 ?? ""
        buvid4 = response.data?.buvid4 ?? ""
    }

    /// 读取并缓存 WBI 混淆密钥。
    /// - Returns: 32 位签名密钥。
    private func loadMixinKey() async throws -> String {
        if !cachedMixinKey.isEmpty, Date().timeIntervalSince(mixinKeyDate) < 3_600 {
            return cachedMixinKey
        }
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            throw BuiltInBilibiliError.invalidResponse
        }
        let response: NavigationEnvelope = try await loadJSON(url)
        guard let imageURL = response.data?.wbiImage?.imageURL,
              let subURL = response.data?.wbiImage?.subURL else {
            throw BuiltInBilibiliError.upstream("WBI 签名信息缺失")
        }
        let raw = Self.keyPart(imageURL) + Self.keyPart(subURL)
        let characters = Array(raw)
        cachedMixinKey = Self.mixinKeyTable
            .compactMap { characters.indices.contains($0) ? characters[$0] : nil }
            .prefix(32)
            .map(String.init)
            .joined()
        mixinKeyDate = Date()
        guard cachedMixinKey.count == 32 else {
            throw BuiltInBilibiliError.upstream("WBI 签名密钥无效")
        }
        return cachedMixinKey
    }

    /// 请求 JSON 并解码为指定类型。
    /// - Parameter url: HTTPS API 地址。
    /// - Returns: 解码后的响应。
    private func loadJSON<Value: Decodable>(_ url: URL) async throws -> Value {
        let (data, _) = try await loadData(url)
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw BuiltInBilibiliError.upstream("平台响应格式已变化")
        }
    }

    /// 发起带来源头与 Cookie 的网络请求。
    /// - Parameter url: HTTPS API 地址。
    /// - Returns: 原始数据与 HTTP 响应。
    private func loadData(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 BiliDroid/8.0.0 (Kanata Apple Client)",
            forHTTPHeaderField: "User-Agent"
        )
        let cookie = cookieHeader()
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BuiltInBilibiliError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BuiltInBilibiliError.upstream("平台返回 HTTP \(http.statusCode)")
        }
        return (data, http)
    }

    /// 拼接登录 Cookie 与匿名设备指纹。
    /// - Returns: 可安全写入请求头的 Cookie 文本。
    private func cookieHeader() -> String {
        var parts = credentialCookie
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !buvid3.isEmpty, !parts.contains(where: { $0.hasPrefix("buvid3=") }) {
            parts.append("buvid3=\(buvid3)")
        }
        if !buvid4.isEmpty { parts.append("buvid4=\(buvid4)") }
        if !buvid3.isEmpty || !buvid4.isEmpty {
            parts.append("b_nut=\(Int(Date().timeIntervalSince1970))")
        }
        return parts.joined(separator: "; ")
    }

    /// 从用户输入中识别 BV、ep、ss、cid 或播放页链接。
    /// - Parameter text: 搜索框内容。
    /// - Returns: 可直接加载的候选，普通剧名返回 nil。
    private func directCandidate(from text: String) -> ProviderCandidate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns: [(String, String)] = [
            (#"(?:/video/|^)(BV[0-9A-Za-z]+)"#, "bv:"),
            (#"(?:/bangumi/play/|^)(ep\d+)"#, "ep:"),
            (#"(?:/bangumi/play/|^)(ss\d+)"#, "ss:"),
        ]
        for (pattern, prefix) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let valueRange = Range(match.range(at: 1), in: trimmed) else { continue }
            var value = String(trimmed[valueRange])
            if prefix == "ep:" || prefix == "ss:" { value = String(value.dropFirst(2)) }
            return ProviderCandidate(
                source: .bilibili,
                sourceInstanceName: "哔哩哔哩（App 内置）",
                platformEpisodeId: prefix + value,
                title: trimmed,
                confidence: 1
            )
        }
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) {
            return ProviderCandidate(
                source: .bilibili,
                sourceInstanceName: "哔哩哔哩（App 内置）",
                platformEpisodeId: trimmed,
                title: "B 站视频 cid \(trimmed)",
                confidence: 1
            )
        }
        return nil
    }

    /// 为 WBI 查询追加时间戳和 MD5 签名。
    /// - Parameters:
    ///   - parameters: 原始查询参数。
    ///   - mixinKey: 32 位混淆密钥。
    /// - Returns: 可直接拼到 URL 后的查询串。
    private func signWBI(_ parameters: [String: String], mixinKey: String) -> String {
        var values = parameters
        values["wts"] = String(Int(Date().timeIntervalSince1970))
        let query = values.keys.sorted().map { key in
            let value = values[key, default: ""].filter { !"!'()*".contains($0) }
            return "\(Self.percentEncode(key))=\(Self.percentEncode(value))"
        }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(query)&w_rid=\(digest)"
    }

    /// 使用移动端公开请求格式为参数追加 app sign。
    /// - Parameter parameters: 已包含 appkey 与时间戳的参数。
    /// - Returns: 排序、编码并签名后的查询串。
    private func signMobile(_ parameters: [String: String]) -> String {
        let query = parameters.keys.sorted().map { key in
            "\(Self.percentEncode(key))=\(Self.percentEncode(parameters[key, default: ""]))"
        }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + Self.mobileAppSecret).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(query)&sign=\(digest)"
    }

    /// 解析 B 站 protobuf 弹幕分片。
    /// - Parameter data: seg.so 返回的二进制数据。
    /// - Returns: 统一弹幕数组。
    private static func parseSegment(_ data: Data) -> [DanmakuItem] {
        var reader = ProtobufReader(data: data)
        var values: [DanmakuItem] = []
        while let tag = reader.readVarint() {
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x07)
            if field == 1, wire == 2, let bytes = reader.readBytes() {
                if let item = parseElement(bytes) { values.append(item) }
            } else if !reader.skip(wireType: wire) {
                break
            }
        }
        return values
    }

    /// 解析单条 protobuf DanmakuElem。
    /// - Parameter data: 单条消息的字节。
    /// - Returns: 支持的普通弹幕，高级弹幕返回 nil。
    private static func parseElement(_ data: Data) -> DanmakuItem? {
        var reader = ProtobufReader(data: data)
        var id: UInt64 = 0
        var progress: UInt64 = 0
        var mode = 1
        var fontSize = 25
        var color = 16_777_215
        var senderHash = ""
        var content = ""
        var createdAt = 0
        var weight = 0

        while let tag = reader.readVarint() {
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x07)
            switch field {
            case 1: id = reader.readVarint() ?? 0
            case 2: progress = reader.readVarint() ?? 0
            case 3: mode = Int(reader.readVarint() ?? 1)
            case 4: fontSize = Int(reader.readVarint() ?? 25)
            case 5: color = Int(reader.readVarint() ?? 16_777_215)
            case 6: senderHash = reader.readString() ?? ""
            case 7: content = reader.readString() ?? ""
            case 8: createdAt = Int(reader.readVarint() ?? 0)
            case 9: weight = Int(reader.readVarint() ?? 0)
            default:
                if !reader.skip(wireType: wire) { return nil }
            }
        }
        guard let danmakuMode = DanmakuMode(rawValue: mode), !content.isEmpty else { return nil }
        return DanmakuItem(
            id: "bilibili:\(id)",
            time: Double(progress) / 1_000,
            mode: danmakuMode,
            fontSize: Double(fontSize),
            color: color,
            content: content,
            source: .bilibili,
            senderHash: senderHash.isEmpty ? nil : senderHash,
            createdAt: createdAt > 0 ? createdAt : nil,
            weight: weight > 0 ? weight : nil
        )
    }

    /// 从 WBI 图片 URL 中截取无扩展名的密钥片段。
    /// - Parameter url: 图片 URL。
    /// - Returns: 文件名中的十六进制部分。
    private static func keyPart(_ url: String) -> String {
        URL(string: url)?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// 使用与 encodeURIComponent 一致的字符集编码查询参数。
    /// - Parameter value: 原始字符串。
    /// - Returns: 百分号编码后的字符串。
    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 移除搜索结果标题中的 HTML 高亮标签。
    /// - Parameter value: 平台标题。
    /// - Returns: 纯文本标题。
    private static func removeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }

    /// 计算两段标题的近似匹配程度。
    /// - Parameters:
    ///   - left: 用户标题。
    ///   - right: 平台标题。
    /// - Returns: 0 到 1 的置信度。
    private static func titleSimilarity(_ left: String, _ right: String) -> Double {
        let a = normalizeTitle(left)
        let b = normalizeTitle(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) {
            return 0.85 + 0.1 * Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        }
        let distance = editDistance(a, b)
        return max(0, 1 - Double(distance) / Double(max(a.count, b.count)))
    }

    /// 结合标题与时长差计算最终置信度。
    /// - Parameters:
    ///   - titleScore: 标题匹配分。
    ///   - localDuration: 本地视频时长。
    ///   - remoteDuration: 平台视频时长。
    /// - Returns: 调整后的置信度。
    private static func adjustedConfidence(
        titleScore: Double,
        localDuration: Double?,
        remoteDuration: Double?
    ) -> Double {
        guard let localDuration, let remoteDuration, localDuration > 0, remoteDuration > 0 else {
            return titleScore
        }
        let difference = abs(localDuration - remoteDuration) / localDuration
        let durationScore = difference > 0.15 ? 0.7 : max(0.75, 1 - difference * 1.5)
        return min(max(titleScore * durationScore, 0), 1)
    }

    /// 归一化标题用于近似比较。
    /// - Parameter value: 原始标题。
    /// - Returns: 去掉常见修饰符与标点的标题。
    private static func normalizeTitle(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"第[一二三四五六七八九十\d]+[季期部]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(season|part)\s*\d+\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\-_~·:：,，.。!！?？'\"()（）\[\]【】]"#, with: "", options: .regularExpression)
    }

    /// 计算两个字符串的编辑距离。
    /// - Parameters:
    ///   - left: 左侧字符串。
    ///   - right: 右侧字符串。
    /// - Returns: Levenshtein 距离。
    private static func editDistance(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            for j in 1...b.count {
                current.append(min(
                    current[j - 1] + 1,
                    previous[j] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// 内置 B 站请求的用户可读错误。
private enum BuiltInBilibiliError: LocalizedError {
    case invalidResponse
    case invalidEpisodeID
    case notFound
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "内置弹幕来源响应无效"
        case .invalidEpisodeID: "无法识别该 B 站视频标识"
        case .notFound: "没有找到对应的 B 站视频"
        case .upstream(let message): "内置弹幕来源：\(message)"
        }
    }
}

/// 最小 protobuf 游标，只实现 B 站弹幕分片使用的线类型。
private struct ProtobufReader {
    private let bytes: [UInt8]
    private var offset = 0

    /// 从 Data 创建顺序读取器。
    /// - Parameter data: protobuf 字节。
    init(data: Data) {
        self.bytes = Array(data)
    }

    /// 读取一个 varint。
    /// - Returns: 无符号整数，数据结束或非法时返回 nil。
    mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    /// 读取长度前缀字节串。
    /// - Returns: 完整字段数据，越界时返回 nil。
    mutating func readBytes() -> Data? {
        guard let rawLength = readVarint(), rawLength <= UInt64(Int.max) else { return nil }
        let length = Int(rawLength)
        guard length >= 0, offset + length <= bytes.count else { return nil }
        defer { offset += length }
        return Data(bytes[offset..<(offset + length)])
    }

    /// 读取 UTF-8 长度前缀字符串。
    /// - Returns: 字符串，编码无效时返回 nil。
    mutating func readString() -> String? {
        readBytes().flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 跳过一个不关心的 protobuf 字段。
    /// - Parameter wireType: protobuf 线类型。
    /// - Returns: 是否成功跳过。
    mutating func skip(wireType: Int) -> Bool {
        switch wireType {
        case 0:
            return readVarint() != nil
        case 1:
            guard offset + 8 <= bytes.count else { return false }
            offset += 8
            return true
        case 2:
            return readBytes() != nil
        case 5:
            guard offset + 4 <= bytes.count else { return false }
            offset += 4
            return true
        default:
            return false
        }
    }
}

private struct SearchEnvelope: Decodable {
    let code: Int
    let message: String?
    let data: SearchData?
}

private struct SearchData: Decodable {
    let result: [SearchResult]?
}

private struct SearchResult: Decodable {
    let seasonID: Int?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case seasonID = "season_id"
        case title
    }
}

private struct MobileSearchEnvelope: Decodable {
    let code: Int
    let message: String?
    let data: MobileSearchData?
}

private struct MobileSearchData: Decodable {
    let items: [MobileSearchItem]?
}

private struct MobileSearchItem: Decodable {
    let title: String?
    let seasonID: Int?

    enum CodingKeys: String, CodingKey {
        case title
        case seasonID = "season_id"
    }
}

private struct SeasonEnvelope: Decodable {
    let code: Int?
    let message: String?
    let result: SeasonResult?
}

private struct SeasonResult: Decodable {
    let episodes: [SeasonEpisode]?
}

private struct SeasonEpisode: Decodable {
    let id: Int?
    let cid: Int?
    let title: String?
    let longTitle: String?
    let duration: Int?

    enum CodingKeys: String, CodingKey {
        case id, cid, title, duration
        case longTitle = "long_title"
    }
}

private struct FingerprintEnvelope: Decodable {
    let data: FingerprintData?
}

private struct FingerprintData: Decodable {
    let buvid3: String?
    let buvid4: String?

    enum CodingKeys: String, CodingKey {
        case buvid3 = "b_3"
        case buvid4 = "b_4"
    }
}

private struct NavigationEnvelope: Decodable {
    let code: Int?
    let message: String?
    let data: NavigationData?
}

private struct NavigationData: Decodable {
    let isLogin: Bool?
    let uname: String?
    let wbiImage: WBIImage?

    enum CodingKeys: String, CodingKey {
        case isLogin, uname
        case wbiImage = "wbi_img"
    }
}

private struct WBIImage: Decodable {
    let imageURL: String?
    let subURL: String?

    enum CodingKeys: String, CodingKey {
        case imageURL = "img_url"
        case subURL = "sub_url"
    }
}

private struct VideoEnvelope: Decodable {
    let code: Int?
    let data: VideoData?
}

private struct VideoData: Decodable {
    let cid: Int?
    let duration: Int?
}
