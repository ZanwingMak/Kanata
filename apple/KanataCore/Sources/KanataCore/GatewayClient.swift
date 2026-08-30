import Foundation

/// 网关错误。errorCode 对应 docs/02 §3.4 的错误码表，UI 按码决定提示与后续动作。
public struct GatewayError: Error, Sendable {
    public let errorCode: Int
    public let errorMessage: String

    /// 是否属于「需要登录」类错误，UI 应引导用户走扫码登录
    public var requiresLogin: Bool {
        errorCode == 40301 || errorCode == 40302
    }
}

/// 网关错误响应体，用于从非 2xx 响应中提取错误码
private struct GatewayErrorBody: Decodable {
    let errorCode: Int?
    let errorMessage: String?
}

/// 网关 HTTP 客户端。
/// 客户端只依赖这一套契约，平台差异全部由网关承担；网关地址与 Token 由用户在设置中配置（FR-SET-002）。
public actor GatewayClient {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// 客户端凭证，按请求加密透传，绝不写入磁盘（FR-AUTH-005）
    private var credentialHeader: String?

    /// - Parameters:
    ///   - baseURL: 网关根地址，例如 http://192.168.1.7:9321
    ///   - token: 访问令牌
    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    /// 设置平台凭证，传 nil 表示清除
    /// - Parameter payload: 形如 ["bilibili": ["SESSDATA": "..."]] 的字典
    public func setCredential(_ payload: [String: [String: String]]?) {
        guard let payload,
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            credentialHeader = nil
            return
        }
        credentialHeader = data.base64EncodedString()
    }

    /// 各源可用性与最近探活结果
    public func sources() async throws -> [SourceStatus] {
        struct Response: Decodable { let sources: [SourceStatus] }
        return try await request(path: "/kanata/v1/sources", method: "GET", body: Optional<Int>.none, as: Response.self).sources
    }

    /// 跨平台剧集解析。有指纹时网关会优先走精确匹配
    public func resolve(_ request: ResolveRequest) async throws -> ResolveResponse {
        try await self.request(path: "/kanata/v1/resolve", method: "POST", body: request, as: ResolveResponse.self)
    }

    /// 拉取聚合弹幕
    /// - Parameters:
    ///   - refs: 一个或多个来源引用，每个可带独立偏移
    ///   - dedup: 是否跨源去重，多源时建议开启
    public func danmaku(refs: [DanmakuRef], dedup: Bool = true) async throws -> DanmakuResponse {
        let refsParam = refs.map { "\($0.source.rawValue):\($0.platformEpisodeId)" }.joined(separator: ",")
        let offsetsParam = refs
            .filter { $0.offset != 0 }
            .map { "\($0.source.rawValue):\($0.offset)" }
            .joined(separator: ",")
        var query = [URLQueryItem(name: "refs", value: refsParam),
                     URLQueryItem(name: "dedup", value: dedup ? "true" : "false")]
        if !offsetsParam.isEmpty {
            query.append(URLQueryItem(name: "offsets", value: offsetsParam))
        }
        return try await request(path: "/kanata/v1/danmaku", method: "GET", query: query, body: Optional<Int>.none, as: DanmakuResponse.self)
    }

    /// 网关存活探测，用于设置页的「测试连接」（FR-SET-001）
    public func health() async throws -> Bool {
        struct Response: Decodable { let ok: Bool }
        return try await request(path: "/kanata/v1/health", method: "GET", body: Optional<Int>.none, as: Response.self).ok
    }

    /// 发起一次网关请求并解码响应
    /// - Throws: 网关返回非 2xx 时抛出携带错误码的 GatewayError
    private func request<Body: Encodable, Result: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Body?,
        as type: Result.Type
    ) async throws -> Result {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw GatewayError(errorCode: 40001, errorMessage: "网关地址非法")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let credentialHeader {
            urlRequest.setValue(credentialHeader, forHTTPHeaderField: "X-Kanata-Credential")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayError(errorCode: 50001, errorMessage: "无效的响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let parsed = try? decoder.decode(GatewayErrorBody.self, from: data)
            throw GatewayError(
                errorCode: parsed?.errorCode ?? http.statusCode,
                errorMessage: parsed?.errorMessage ?? "网关返回 \(http.statusCode)"
            )
        }
        return try decoder.decode(Result.self, from: data)
    }
}
