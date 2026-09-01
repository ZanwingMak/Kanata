import CryptoKit
import Foundation
import KanataCore

/// App 内置的弹弹play开放平台客户端；仅在本机构建注入凭证且用户主动启用时工作。
actor BuiltInDandanplayClient {
    private let baseURL = URL(string: "https://api.dandanplay.net")!
    private let appID: String
    private let appSecret: String
    private let session: URLSession

    /// 从 App 的构建配置读取凭证；仓库和运行日志均不保存密钥。
    /// - Returns: 当前构建未注入完整凭证时返回 nil。
    static func configured() -> BuiltInDandanplayClient? {
        let appID = (Bundle.main.object(forInfoDictionaryKey: "DandanplayAppId") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appSecret = (Bundle.main.object(forInfoDictionaryKey: "DandanplayAppSecret") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !appID.isEmpty,
              !appSecret.isEmpty,
              !appID.contains("$("),
              !appSecret.contains("$(") else { return nil }
        return BuiltInDandanplayClient(appID: appID, appSecret: appSecret)
    }

    /// 创建签名客户端，并使用不落盘 Cookie 的短超时会话。
    /// - Parameters:
    ///   - appID: 开放平台应用 ID。
    ///   - appSecret: 仅存在于已签名 App 二进制中的应用密钥。
    private init(appID: String, appSecret: String) {
        self.appID = appID
        self.appSecret = appSecret
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: configuration)
    }

    /// 优先使用文件指纹匹配，无法计算指纹时按标题与集数搜索。
    /// - Parameter query: 播放页的统一匹配请求。
    /// - Returns: 可与其他内置来源合并的候选列表。
    func resolve(_ query: ResolveRequest) async throws -> [ProviderCandidate] {
        if let fingerprint = query.fingerprint {
            let matches = try await match(fingerprint)
            if matches.contains(where: { $0.confidence >= 0.9 }) { return matches }
        }
        return try await search(query)
    }

    /// 按作品标题和可选集数搜索弹弹play剧集。
    /// - Parameter query: 标题、集数和时长。
    /// - Returns: 按标题相似度排序的候选列表。
    func search(_ query: ResolveRequest) async throws -> [ProviderCandidate] {
        let response: SearchResponse = try await request(
            path: "/api/v2/search/episodes",
            query: [
                URLQueryItem(name: "anime", value: query.title),
                URLQueryItem(name: "episode", value: query.episode.map(String.init)),
            ]
        )
        guard response.success != false else {
            throw DandanplayClientError.upstream(response.errorMessage ?? "搜索失败")
        }
        return (response.animes ?? []).flatMap { anime in
            (anime.episodes ?? []).map { episode in
                ProviderCandidate(
                    source: .dandanplay,
                    sourceInstanceName: "弹弹play（低额度备用）",
                    platformEpisodeId: String(episode.episodeId),
                    title: anime.animeTitle,
                    episodeTitle: episode.episodeTitle,
                    confidence: Self.titleConfidence(query.title, anime.animeTitle)
                )
            }
        }
        .sorted { $0.confidence > $1.confidence }
    }

    /// 使用官方前 16MB MD5 指纹执行精确文件匹配。
    /// - Parameter fingerprint: 本地视频指纹。
    /// - Returns: 命中项置信度为 1，文件名候选为 0.6。
    private func match(_ fingerprint: MediaFingerprint) async throws -> [ProviderCandidate] {
        let body = MatchBody(
            fileName: fingerprint.fileName,
            fileHash: fingerprint.fileHash,
            fileSize: fingerprint.fileSize,
            videoDuration: fingerprint.videoDuration,
            matchMode: "hashAndFileName"
        )
        let response: MatchResponse = try await request(path: "/api/v2/match", body: body)
        guard response.success != false else {
            throw DandanplayClientError.upstream(response.errorMessage ?? "文件匹配失败")
        }
        return (response.matches ?? []).map { match in
            ProviderCandidate(
                source: .dandanplay,
                sourceInstanceName: "弹弹play（低额度备用）",
                platformEpisodeId: "\(match.episodeId)@\(match.shift ?? 0)",
                title: match.animeTitle,
                episodeTitle: match.episodeTitle,
                confidence: response.isMatched == true ? 1 : 0.6
            )
        }
    }

    /// 拉取一个剧集的关联弹幕并转换为统一渲染模型。
    /// - Parameter platformEpisodeID: 剧集 ID，可带 `@时轴偏移`。
    /// - Returns: 已应用官方时轴修正并排序的普通弹幕。
    func danmaku(platformEpisodeID: String) async throws -> [DanmakuItem] {
        let parts = platformEpisodeID.split(separator: "@", maxSplits: 1).map(String.init)
        guard let episodeID = parts.first, episodeID.allSatisfy(\.isNumber) else {
            throw DandanplayClientError.invalidResponse
        }
        let shift = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
        let response: CommentResponse = try await request(
            path: "/api/v2/comment/\(episodeID)",
            query: [
                URLQueryItem(name: "withRelated", value: "true"),
                URLQueryItem(name: "chConvert", value: "0"),
            ]
        )
        return (response.comments ?? []).compactMap { comment in
            Self.makeDanmaku(comment, shift: shift)
        }
        .sorted { $0.time < $1.time }
    }

    /// 用一次标题搜索验证签名与搜索额度是否可用。
    /// - Returns: 能获得至少一个剧集候选时返回 true。
    func health() async -> Bool {
        let request = ResolveRequest(title: "孤独摇滚", episode: 1)
        return ((try? await search(request))?.isEmpty == false)
    }

    /// 发起一个签名 GET 请求并解码 JSON。
    /// - Parameters:
    ///   - path: 不含 query 的官方 API 路径。
    ///   - query: URL 查询参数。
    /// - Returns: 指定响应模型。
    private func request<Response: Decodable>(
        path: String,
        query: [URLQueryItem]
    ) async throws -> Response {
        try await request(path: path, query: query, bodyData: nil)
    }

    /// 发起一个签名 POST 请求并解码 JSON。
    /// - Parameters:
    ///   - path: 不含 query 的官方 API 路径。
    ///   - body: 可编码请求正文。
    /// - Returns: 指定响应模型。
    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        body: Body
    ) async throws -> Response {
        try await request(path: path, query: [], bodyData: JSONEncoder().encode(body))
    }

    /// 统一构建签名请求、校验 HTTP 状态并解码响应。
    /// - Parameters:
    ///   - path: 不含 query 的官方 API 路径。
    ///   - query: URL 查询参数。
    ///   - bodyData: POST JSON；nil 表示 GET。
    /// - Returns: 指定响应模型。
    private func request<Response: Decodable>(
        path: String,
        query: [URLQueryItem],
        bodyData: Data?
    ) async throws -> Response {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw DandanplayClientError.invalidResponse
        }
        components.queryItems = query.filter { $0.value != nil }
        guard let url = components.url else { throw DandanplayClientError.invalidResponse }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let digest = SHA256.hash(data: Data((appID + timestamp + path + appSecret).utf8))
        let signature = Data(digest).base64EncodedString()
        var request = URLRequest(url: url)
        request.httpMethod = bodyData == nil ? "GET" : "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if bodyData != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(appID, forHTTPHeaderField: "X-AppId")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Signature")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DandanplayClientError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw DandanplayClientError.credentialRejected }
        guard (200..<300).contains(http.statusCode) else { throw DandanplayClientError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DandanplayClientError.invalidResponse
        }
    }

    /// 把弹弹play `p` 字段转换成统一弹幕，并过滤高级或非法模式。
    /// - Parameters:
    ///   - comment: 官方弹幕条目。
    ///   - shift: 文件匹配给出的时轴修正秒数。
    /// - Returns: 普通弹幕模型；格式无效时返回 nil。
    private static func makeDanmaku(_ comment: Comment, shift: Double) -> DanmakuItem? {
        let parts = comment.p.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              let rawTime = Double(parts[0]),
              let rawMode = Int(parts[1]),
              let mode = normalizedMode(rawMode) else { return nil }
        let time = rawTime + shift
        guard time >= 0 else { return nil }
        return DanmakuItem(
            id: "dandanplay:\(comment.cid)",
            time: time,
            mode: mode,
            color: Int(parts[2]) ?? 16_777_215,
            content: comment.m,
            source: .dandanplay,
            senderHash: parts.count > 3 ? parts[3] : nil,
            weight: 5
        )
    }

    /// 把官方弹幕模式映射为播放器支持的四种基础模式。
    /// - Parameter raw: 官方模式数字。
    /// - Returns: 高级弹幕模式返回 nil。
    private static func normalizedMode(_ raw: Int) -> DanmakuMode? {
        switch raw {
        case 1, 2, 3: .scroll
        case 4: .bottom
        case 5: .top
        case 6: .reverse
        default: nil
        }
    }

    /// 计算轻量标题置信度，避免低额度来源抢占明显不相关的候选。
    /// - Parameters:
    ///   - query: 用户或文件名解析出的标题。
    ///   - candidate: 平台作品标题。
    /// - Returns: 0.45 到 0.96 的保守置信度。
    private static func titleConfidence(_ query: String, _ candidate: String) -> Double {
        let left = normalizedTitle(query)
        let right = normalizedTitle(candidate)
        if left == right { return 0.96 }
        if left.contains(right) || right.contains(left) { return 0.86 }
        let overlap = Set(left).intersection(Set(right)).count
        let total = max(Set(left).union(Set(right)).count, 1)
        return min(max(Double(overlap) / Double(total), 0.45), 0.78)
    }

    /// 移除标题中的空白和标点以供轻量比较。
    /// - Parameter value: 原始标题。
    /// - Returns: 小写字母数字与中日韩字符组成的标题。
    private static func normalizedTitle(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0.value > 0x2E7F }
            .map(String.init)
            .joined()
    }

    private struct SearchResponse: Decodable {
        let animes: [Anime]?
        let success: Bool?
        let errorMessage: String?
    }

    private struct Anime: Decodable {
        let animeTitle: String
        let episodes: [Episode]?
    }

    private struct Episode: Decodable {
        let episodeId: Int
        let episodeTitle: String
    }

    private struct MatchBody: Encodable {
        let fileName: String
        let fileHash: String
        let fileSize: Int
        let videoDuration: Int
        let matchMode: String
    }

    private struct MatchResponse: Decodable {
        let isMatched: Bool?
        let matches: [Match]?
        let success: Bool?
        let errorMessage: String?
    }

    private struct Match: Decodable {
        let episodeId: Int
        let animeTitle: String
        let episodeTitle: String
        let shift: Double?
    }

    private struct CommentResponse: Decodable {
        let comments: [Comment]?
    }

    private struct Comment: Decodable {
        let cid: Int
        let p: String
        let m: String
    }
}

/// 弹弹play内置客户端的安全、网络与响应错误。
private enum DandanplayClientError: LocalizedError {
    case credentialRejected
    case http(Int)
    case upstream(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .credentialRejected: "弹弹play拒绝了当前 AppId 或签名"
        case .http(let code): "弹弹play请求失败（HTTP \(code)）"
        case .upstream(let message): message
        case .invalidResponse: "弹弹play响应格式异常"
        }
    }
}
