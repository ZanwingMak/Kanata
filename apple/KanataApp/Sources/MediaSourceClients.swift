import Foundation

/// WebDAV 中的一项文件或目录。
struct WebDAVEntry: Identifiable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let contentType: String?

    var id: String { url.absoluteString }
}

/// WebDAV PROPFIND 客户端。
actor WebDAVClient {
    let headers: [String: String]
    private let session: URLSession

    /// 创建 WebDAV 客户端，账号为空时使用匿名访问。
    /// - Parameters:
    ///   - username: WebDAV 用户名。
    ///   - password: WebDAV 密码。
    init(username: String, password: String) {
        if username.isEmpty {
            self.headers = [:]
        } else {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            self.headers = ["Authorization": "Basic \(token)"]
        }
        self.session = Self.makeSession()
    }

    /// 从已保存的媒体源历史创建客户端。
    /// - Parameter profile: WebDAV 媒体源配置。
    init(profile: MediaSourceProfile) {
        self.headers = MediaSourceProfileStore.playbackHeaders(for: profile)
        self.session = Self.makeSession()
    }

    /// 列出 WebDAV 目录的直接子项。
    /// - Parameter directory: 要发送 Depth: 1 请求的目录。
    /// - Returns: 已过滤为文件夹和常见视频格式的条目。
    func list(directory: URL) async throws -> [WebDAVEntry] {
        var request = URLRequest(url: directory)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontenttype/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MediaSourceError.invalidResponse }
        if http.statusCode == 401 { throw MediaSourceError.authenticationFailed }
        guard http.statusCode == 207 || (200..<300).contains(http.statusCode) else {
            throw MediaSourceError.http(http.statusCode)
        }
        let delegate = WebDAVXMLDelegate(baseURL: directory)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { throw MediaSourceError.invalidResponse }
        let root = Self.normalizedPath(directory.path)
        return delegate.entries
            .filter { Self.normalizedPath($0.url.path) != root }
            .filter { $0.isDirectory || Self.isVideo($0.url) }
            .sorted(by: Self.sortEntries)
    }

    /// 创建短超时、无持久 Cookie 的网络会话。
    /// - Returns: 适合局域网目录浏览的 URLSession。
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }

    /// 判断文件扩展名是否属于播放器支持的视频范围。
    /// - Parameter url: WebDAV 文件地址。
    /// - Returns: 常见视频或 HLS 扩展名时返回 true。
    private static func isVideo(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m3u8", "flv"]
            .contains(url.pathExtension.lowercased())
    }

    /// 先显示目录，再按自然语言文件名排序。
    /// - Parameters:
    ///   - left: 左侧条目。
    ///   - right: 右侧条目。
    /// - Returns: 左侧应排在前面时返回 true。
    private static func sortEntries(_ left: WebDAVEntry, _ right: WebDAVEntry) -> Bool {
        if left.isDirectory != right.isDirectory { return left.isDirectory }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    /// 去掉目录路径末尾斜杠，便于排除 PROPFIND 返回的目录本身。
    /// - Parameter value: URL 路径。
    /// - Returns: 可比较的路径。
    private static func normalizedPath(_ value: String) -> String {
        value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}

/// 解析 WebDAV Multi-Status XML。
private final class WebDAVXMLDelegate: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var href = ""
    private var displayName = ""
    private var contentType = ""
    private var currentElement = ""
    private var isDirectory = false
    var entries: [WebDAVEntry] = []

    /// 创建相对地址解析器。
    /// - Parameter baseURL: 当前 PROPFIND 目录。
    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// 进入 XML 元素并初始化单条 response 状态。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        if currentElement == "response" {
            href = ""
            displayName = ""
            contentType = ""
            isDirectory = false
        } else if currentElement == "collection" {
            isDirectory = true
        }
    }

    /// 收集当前属性元素的文本。
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "href": href += string
        case "displayname": displayName += string
        case "getcontenttype": contentType += string
        default: break
        }
    }

    /// 在 response 结束时生成统一目录项。
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName.lowercased() == "response",
           let url = URL(
               string: href.trimmingCharacters(in: .whitespacesAndNewlines),
               relativeTo: baseURL
           )?.absoluteURL {
            let fallback = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(WebDAVEntry(
                url: url,
                name: name.isEmpty ? fallback : name,
                isDirectory: isDirectory,
                contentType: contentType.isEmpty ? nil : contentType
            ))
        }
        currentElement = ""
    }
}

/// 群晖 DSM File Station 登录、目录浏览与原文件下载客户端。
actor SynologyFileStationClient {
    private let session: URLSession

    /// 创建不保留网页 Cookie 的 DSM API 会话。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    /// 登录 DSM 并返回只保存在 Keychain 的 File Station 会话。
    /// - Parameters:
    ///   - server: DSM 根地址，例如 https://nas.local:5001。
    ///   - username: DSM 用户名。
    ///   - password: DSM 密码。
    ///   - otp: 可选的两步验证码。
    /// - Returns: token 字段为 DSM sid 的敏感信息。
    func login(
        server: URL,
        username: String,
        password: String,
        otp: String? = nil
    ) async throws -> MediaSourceSecret {
        var fields = [
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "Login",
            "account": username,
            "passwd": password,
            "session": "FileStation",
            "format": "sid",
        ]
        if let otp, !otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields["otp_code"] = otp.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let data = try await request(
            server: server,
            path: "entry.cgi",
            fields: fields
        )
        let response = try JSONDecoder().decode(SynologyLoginEnvelope.self, from: data)
        guard response.success, let sid = response.data?.sid, !sid.isEmpty else {
            throw Self.error(code: response.error?.code)
        }
        return MediaSourceSecret(password: password, token: sid, userID: nil)
    }

    /// 列出 DSM 共享文件夹或指定目录的直接子项。
    /// - Parameters:
    ///   - profile: 已保存的 DSM 连接。
    ///   - parentPath: nil 表示共享文件夹根列表。
    /// - Returns: 已过滤为文件夹与常见视频格式的媒体条目。
    func items(profile: MediaSourceProfile, parentPath: String?) async throws -> [MediaSourceEntry] {
        guard let server = profile.serverURL,
              let sid = MediaSourceProfileStore.secret(for: profile)?.token,
              !sid.isEmpty else { throw MediaSourceError.missingCredential }
        var fields = [
            "api": "SYNO.FileStation.List",
            "version": "2",
            "method": parentPath == nil ? "list_share" : "list",
            "_sid": sid,
        ]
        if let parentPath { fields["folder_path"] = parentPath }
        let data = try await request(server: server, path: "entry.cgi", fields: fields)
        let response = try JSONDecoder().decode(SynologyListEnvelope.self, from: data)
        guard response.success, let payload = response.data else {
            throw Self.error(code: response.error?.code)
        }
        let values = payload.shares ?? payload.files ?? []
        return values.compactMap { item in
            guard item.isdir || Self.isVideo(path: item.path) else { return nil }
            return MediaSourceEntry(
                id: "synology:\(item.path)",
                name: item.name,
                type: item.isdir ? "folder" : "video",
                isDirectory: item.isdir,
                navigationKey: item.isdir ? item.path : nil,
                streamPath: item.isdir ? nil : item.path,
                index: nil,
                seasonIndex: nil,
                artworkPath: nil
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 构建不含 sid 的 File Station 下载地址，播放时由 LibraryItem 动态注入会话。
    /// - Parameters:
    ///   - profile: DSM 媒体源。
    ///   - path: File Station 文件绝对路径。
    /// - Returns: 可交给 AVPlayer 的下载端点。
    func streamURL(profile: MediaSourceProfile, path: String) throws -> URL {
        guard let server = profile.serverURL else { throw MediaSourceError.invalidResponse }
        var components = URLComponents(
            url: server.appendingPathComponent("webapi/entry.cgi"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "open"),
        ]
        guard let url = components?.url else { throw MediaSourceError.invalidResponse }
        return url
    }

    /// 向 DSM webapi 发送表单请求并校验 HTTP 状态。
    /// - Parameters:
    ///   - server: DSM 根地址。
    ///   - path: webapi 下的 CGI 文件。
    ///   - fields: 表单字段。
    /// - Returns: DSM JSON 响应体。
    private func request(server: URL, path: String, fields: [String: String]) async throws -> Data {
        let url = server.appendingPathComponent("webapi/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MediaSourceError.invalidResponse }
        if http.statusCode == 401 { throw MediaSourceError.authenticationFailed }
        guard (200..<300).contains(http.statusCode) else { throw MediaSourceError.http(http.statusCode) }
        return data
    }

    /// 判断 File Station 路径是否是播放器支持的视频扩展名。
    /// - Parameter path: DSM 文件路径。
    /// - Returns: 常见视频格式时返回 true。
    private static func isVideo(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "flv"].contains(ext)
    }

    /// 把 DSM API 错误码转换为可操作提示。
    /// - Parameter code: DSM 返回的错误码。
    /// - Returns: 认证失败或通用响应错误。
    private static func error(code: Int?) -> MediaSourceError {
        guard let code else { return .invalidResponse }
        if [105, 106, 107, 400, 401, 402, 403, 404].contains(code) {
            return .authenticationFailed
        }
        return .http(code)
    }
}

/// DSM 登录响应。
private struct SynologyLoginEnvelope: Decodable {
    struct Payload: Decodable { let sid: String? }
    struct Failure: Decodable { let code: Int }
    let success: Bool
    let data: Payload?
    let error: Failure?
}

/// DSM File Station 列表响应。
private struct SynologyListEnvelope: Decodable {
    struct FileValue: Decodable {
        let name: String
        let path: String
        let isdir: Bool
    }
    struct Payload: Decodable {
        let shares: [FileValue]?
        let files: [FileValue]?
    }
    struct Failure: Decodable { let code: Int }
    let success: Bool
    let data: Payload?
    let error: Failure?
}

/// Jellyfin、Emby 与 Plex 浏览器使用的统一媒体条目。
struct MediaSourceEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let type: String
    let isDirectory: Bool
    let navigationKey: String?
    let streamPath: String?
    let index: Int?
    let seasonIndex: Int?
    let artworkPath: String?

    var isPlayable: Bool { !isDirectory && streamPath != nil }
}

/// Jellyfin 与 Emby 共用的 MediaBrowser API 客户端。
actor MediaBrowserClient {
    private let session: URLSession

    /// 创建短超时的媒体服务器网络会话。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    /// 使用用户名和密码登录 Jellyfin 或 Emby。
    /// - Parameters:
    ///   - server: 服务器根地址。
    ///   - username: 用户名。
    ///   - password: 密码。
    /// - Returns: 用户 ID 与访问令牌。
    func login(server: URL, username: String, password: String) async throws -> MediaSourceSecret {
        let url = server.appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            MediaSourceProfileStore.mediaBrowserAuthorization(),
            forHTTPHeaderField: "X-Emby-Authorization"
        )
        request.httpBody = try JSONEncoder().encode(MediaBrowserLoginRequest(Username: username, Pw: password))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let value = try JSONDecoder().decode(MediaBrowserLoginResponse.self, from: data)
        guard !value.AccessToken.isEmpty, !value.User.Id.isEmpty else {
            throw MediaSourceError.invalidResponse
        }
        return MediaSourceSecret(password: password, token: value.AccessToken, userID: value.User.Id)
    }

    /// 读取根媒体库或指定文件夹的直接子项。
    /// - Parameters:
    ///   - profile: Jellyfin 或 Emby 连接。
    ///   - parentID: nil 表示媒体库视图，否则为父项目 ID。
    /// - Returns: 已自然排序的文件夹、电影、剧集和视频。
    func items(profile: MediaSourceProfile, parentID: String?) async throws -> [MediaSourceEntry] {
        guard let server = profile.serverURL,
              let secret = MediaSourceProfileStore.secret(for: profile),
              let userID = secret.userID,
              let token = secret.token else {
            throw MediaSourceError.missingCredential
        }
        let endpoint: URL
        if let parentID {
            var components = URLComponents(
                url: server.appendingPathComponent("Users/\(userID)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "Fields", value: "MediaSources,IndexNumber,ParentIndexNumber"),
            ]
            guard let value = components?.url else { throw MediaSourceError.invalidResponse }
            endpoint = value
        } else {
            endpoint = server.appendingPathComponent("Users/\(userID)/Views")
        }
        var request = URLRequest(url: endpoint)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(
            MediaSourceProfileStore.mediaBrowserAuthorization(token: token),
            forHTTPHeaderField: "X-Emby-Authorization"
        )
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let value = try JSONDecoder().decode(MediaBrowserItemsResponse.self, from: data)
        return value.Items.compactMap { item in
            let directories = ["CollectionFolder", "Folder", "Series", "Season", "BoxSet", "UserView"]
            let playable = ["Movie", "Episode", "Video", "MusicVideo"]
            let isDirectory = item.isFolder == true || directories.contains(item.type)
            guard isDirectory || playable.contains(item.type) else { return nil }
            return MediaSourceEntry(
                id: item.id,
                name: item.name,
                type: item.type,
                isDirectory: isDirectory,
                navigationKey: isDirectory ? item.id : nil,
                streamPath: isDirectory ? nil : item.id,
                index: item.indexNumber,
                seasonIndex: item.parentIndexNumber,
                artworkPath: "/Items/\(item.id)/Images/Primary?maxWidth=640&quality=85"
            )
        }
        .sorted(by: Self.sortEntries)
    }

    /// 构建 Jellyfin 或 Emby 静态原文件播放地址。
    /// - Parameters:
    ///   - profile: 媒体服务器配置。
    ///   - itemID: 电影或剧集 ID。
    /// - Returns: 不在 URL 中暴露令牌的播放地址。
    func streamURL(profile: MediaSourceProfile, itemID: String) throws -> URL {
        guard let server = profile.serverURL else { throw MediaSourceError.invalidResponse }
        var components = URLComponents(
            url: server.appendingPathComponent("Videos/\(itemID)/stream"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "static", value: "true")]
        guard let url = components?.url else { throw MediaSourceError.invalidResponse }
        return url
    }

    /// 先显示文件夹，再按显式集号和自然语言名称排序。
    /// - Parameters:
    ///   - left: 左侧条目。
    ///   - right: 右侧条目。
    /// - Returns: 左侧应排在前面时返回 true。
    private static func sortEntries(_ left: MediaSourceEntry, _ right: MediaSourceEntry) -> Bool {
        if left.isDirectory != right.isDirectory { return left.isDirectory }
        if let leftIndex = left.index, let rightIndex = right.index, leftIndex != rightIndex {
            return leftIndex < rightIndex
        }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }

    /// 校验 MediaBrowser HTTP 响应并映射认证错误。
    /// - Parameter response: URLSession 响应。
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw MediaSourceError.invalidResponse }
        if http.statusCode == 401 { throw MediaSourceError.authenticationFailed }
        guard (200..<300).contains(http.statusCode) else { throw MediaSourceError.http(http.statusCode) }
    }
}

/// MediaBrowser 登录请求模型。
private struct MediaBrowserLoginRequest: Encodable {
    let Username: String
    let Pw: String
}

/// MediaBrowser 登录响应模型。
private struct MediaBrowserLoginResponse: Decodable {
    struct UserValue: Decodable { let Id: String }
    let User: UserValue
    let AccessToken: String
}

/// MediaBrowser 媒体列表响应模型。
private struct MediaBrowserItemsResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let type: String
        let isFolder: Bool?
        let indexNumber: Int?
        let parentIndexNumber: Int?

        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case type = "Type"
            case isFolder = "IsFolder"
            case indexNumber = "IndexNumber"
            case parentIndexNumber = "ParentIndexNumber"
        }
    }
    let Items: [Item]
}

/// 一次 Plex 官方网页授权会话。
struct PlexAuthorizationPin: Sendable {
    let id: Int
    let code: String
    let authorizationURL: URL
}

/// Plex 账号下可直接连接的一台媒体服务器地址。
struct PlexDiscoveredConnection: Identifiable, Sendable {
    let id: String
    let serverName: String
    let serverURL: URL
    let token: String
    let isLocal: Bool
    let isRelay: Bool

    var detail: String {
        let route = isRelay ? "中继" : (isLocal ? "局域网" : "远程直连")
        return "\(route) · \(serverURL.host ?? serverURL.absoluteString)"
    }
}

/// Plex 官方 PIN 授权与服务器发现客户端。
actor PlexAccountClient {
    private let session: URLSession

    /// 创建不共享 Cookie、带短超时的 Plex 账号会话。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        self.session = URLSession(configuration: configuration)
    }

    /// 创建 Plex 网页登录 PIN。
    /// - Returns: PIN、展示码与官方授权地址。
    func createPin() async throws -> PlexAuthorizationPin {
        guard var components = URLComponents(string: "https://plex.tv/api/v2/pins") else {
            throw MediaSourceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "strong", value: "true")]
        guard let url = components.url else { throw MediaSourceError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.applyHeaders(to: &request)
        let data = try await requestData(request)
        let response = try JSONDecoder().decode(PlexPinResponse.self, from: data)
        guard let authorizationURL = Self.authorizationURL(code: response.code) else {
            throw MediaSourceError.invalidResponse
        }
        return PlexAuthorizationPin(
            id: response.id,
            code: response.code,
            authorizationURL: authorizationURL
        )
    }

    /// 检查 PIN 是否完成授权，并在成功后发现账号下的媒体服务器。
    /// - Parameter pin: createPin 返回的授权会话。
    /// - Returns: 未完成时为 nil，完成时返回按局域网优先排序的连接。
    func check(_ pin: PlexAuthorizationPin) async throws -> [PlexDiscoveredConnection]? {
        guard let url = URL(string: "https://plex.tv/api/v2/pins/\(pin.id)") else {
            throw MediaSourceError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.applyHeaders(to: &request)
        let data = try await requestData(request)
        let response = try JSONDecoder().decode(PlexPinResponse.self, from: data)
        guard let accountToken = response.authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountToken.isEmpty else { return nil }
        return try await connections(accountToken: accountToken)
    }

    /// 按局域网、远程直连、中继顺序测试连接并选择首个可访问服务器。
    /// - Parameter connections: 已按推荐顺序排列的 Plex 连接。
    /// - Returns: 当前网络可访问的最佳连接；全部失败时返回 nil。
    func bestReachableConnection(
        in connections: [PlexDiscoveredConnection]
    ) async -> PlexDiscoveredConnection? {
        for connection in connections {
            let url = connection.serverURL.appendingPathComponent("identity")
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            Self.applyHeaders(to: &request, token: connection.token)
            guard (try? await requestData(request)) != nil else { continue }
            return connection
        }
        return nil
    }

    /// 为账号下每台 Plex 服务器选择一条最优可访问线路。
    /// - Parameter connections: 服务器的全部局域网、远程和中继地址。
    /// - Returns: 每台服务器最多一条连接，按局域网和直连优先排序。
    func recommendedServerConnections(
        in connections: [PlexDiscoveredConnection]
    ) async -> [PlexDiscoveredConnection] {
        let grouped = Dictionary(grouping: connections, by: \.serverName)
        var results: [PlexDiscoveredConnection] = []
        for serverName in grouped.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let values = grouped[serverName] else { continue }
            if let reachable = await bestReachableConnection(in: values) {
                results.append(reachable)
            } else if let fallback = values.first {
                results.append(fallback)
            }
        }
        return results.sorted { left, right in
            let leftScore = (left.isRelay ? 4 : 0) + (left.isLocal ? 0 : 1)
            let rightScore = (right.isRelay ? 4 : 0) + (right.isLocal ? 0 : 1)
            if leftScore != rightScore { return leftScore < rightScore }
            return left.serverName.localizedStandardCompare(right.serverName) == .orderedAscending
        }
    }

    /// 拉取 Plex 账号可访问的 Media Server 与连接地址。
    /// - Parameter accountToken: PIN 授权得到的账号令牌。
    /// - Returns: 已过滤 HTTP(S) 地址的服务器连接。
    private func connections(accountToken: String) async throws -> [PlexDiscoveredConnection] {
        guard var components = URLComponents(string: "https://plex.tv/api/resources") else {
            throw MediaSourceError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: accountToken),
        ]
        guard let url = components.url else { throw MediaSourceError.invalidResponse }
        var request = URLRequest(url: url)
        Self.applyHeaders(to: &request, token: accountToken)
        let data = try await requestData(request)
        let delegate = PlexResourcesXMLDelegate(accountToken: accountToken)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw MediaSourceError.invalidResponse }
        let values = delegate.connections.sorted { left, right in
            let leftScore = (left.isRelay ? 4 : 0) + (left.isLocal ? 0 : 1)
            let rightScore = (right.isRelay ? 4 : 0) + (right.isLocal ? 0 : 1)
            if leftScore != rightScore { return leftScore < rightScore }
            return left.serverName.localizedStandardCompare(right.serverName) == .orderedAscending
        }
        guard !values.isEmpty else { throw MediaSourceError.invalidResponse }
        return values
    }

    /// 发送请求并映射 Plex 认证与 HTTP 错误。
    /// - Parameter request: 已构造的 Plex 请求。
    /// - Returns: 成功响应数据。
    private func requestData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MediaSourceError.invalidResponse }
        if http.statusCode == 401 { throw MediaSourceError.authenticationFailed }
        guard (200..<300).contains(http.statusCode) else { throw MediaSourceError.http(http.statusCode) }
        return data
    }

    /// 给 Plex 账号请求附加稳定客户端身份。
    /// - Parameters:
    ///   - request: 待修改的请求。
    ///   - token: 可选账号令牌。
    private static func applyHeaders(to request: inout URLRequest, token: String? = nil) {
        request.setValue("Kanata", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("0.1.0", forHTTPHeaderField: "X-Plex-Version")
        request.setValue(stableDeviceID(), forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("Apple", forHTTPHeaderField: "X-Plex-Platform")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
    }

    /// 生成 Plex 官方网页登录 URL。
    /// - Parameter code: PIN 接口返回的短码。
    /// - Returns: 可由浏览器打开的 app.plex.tv 授权地址。
    private static func authorizationURL(code: String) -> URL? {
        let values = [
            "clientID": stableDeviceID(),
            "code": code,
            "context[device][product]": "Kanata",
            "context[device][platform]": "Apple",
        ]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let fragment = values.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        .joined(separator: "&")
        return URL(string: "https://app.plex.tv/auth/#?\(fragment)")
    }

    /// 返回持久设备 ID，避免 Plex 每次授权都创建新设备。
    /// - Returns: UserDefaults 中复用的 UUID。
    private static func stableDeviceID() -> String {
        let key = "kanata.plex.account.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}

/// Plex PIN JSON 响应。
private struct PlexPinResponse: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

/// 解析 Plex resources XML 并展开每台服务器的连接节点。
private final class PlexResourcesXMLDelegate: NSObject, XMLParserDelegate {
    private let accountToken: String
    private var serverName = ""
    private var serverToken = ""
    private var isServer = false
    var connections: [PlexDiscoveredConnection] = []

    /// 创建带账号令牌兜底的 XML 解析器。
    /// - Parameter accountToken: 服务器未返回专用令牌时使用的账号令牌。
    init(accountToken: String) {
        self.accountToken = accountToken
    }

    /// 读取 Device 与 Connection 开始标签。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "Device" {
            serverName = attributeDict["name"] ?? "Plex Media Server"
            let token = attributeDict["accessToken"] ?? ""
            serverToken = token.isEmpty ? accountToken : token
            let product = attributeDict["product"] ?? ""
            let provides = attributeDict["provides"] ?? ""
            isServer = product == "Plex Media Server" || provides.split(separator: ",").contains("server")
            return
        }
        guard elementName == "Connection", isServer,
              let rawURL = attributeDict["uri"],
              let url = URL(string: rawURL),
              ["http", "https"].contains(url.scheme?.lowercased()) else { return }
        let isLocal = Self.boolValue(attributeDict["local"])
        let isRelay = Self.boolValue(attributeDict["relay"])
        connections.append(PlexDiscoveredConnection(
            id: "\(serverName)|\(rawURL)",
            serverName: serverName,
            serverURL: url,
            token: serverToken,
            isLocal: isLocal,
            isRelay: isRelay
        ))
    }

    /// 在 Device 结束时清空服务器上下文。
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "Device" else { return }
        serverName = ""
        serverToken = ""
        isServer = false
    }

    /// 兼容 Plex XML 的 1/0 与 true/false 布尔值。
    /// - Parameter raw: XML 属性文本。
    /// - Returns: 表示真时返回 true。
    private static func boolValue(_ raw: String?) -> Bool {
        guard let raw = raw?.lowercased() else { return false }
        return raw == "1" || raw == "true"
    }
}

/// Plex Media Server XML API 客户端。
actor PlexClient {
    private let session: URLSession

    /// 创建短超时的 Plex 网络会话。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    /// 验证 Plex Token 并读取媒体库分区。
    /// - Parameters:
    ///   - server: Plex Media Server 根地址。
    ///   - token: X-Plex-Token。
    /// - Returns: Plex 媒体库分区。
    func verify(server: URL, token: String) async throws -> [MediaSourceEntry] {
        let temporary = MediaSourceProfile(
            id: "verify",
            kind: .plex,
            name: "Plex",
            serverURLString: server.absoluteString,
            username: "",
            rootPath: nil,
            credentialAccount: "",
            updatedAt: Date()
        )
        return try await load(
            url: server.appendingPathComponent("library/sections"),
            headers: Self.headers(token: token),
            isSections: true,
            profile: temporary
        )
    }

    /// 读取 Plex 媒体库分区或目录子项。
    /// - Parameters:
    ///   - profile: Plex 连接配置。
    ///   - navigationKey: nil 读取分区，否则读取指定 API 路径。
    /// - Returns: 目录与可播放项目。
    func items(profile: MediaSourceProfile, navigationKey: String?) async throws -> [MediaSourceEntry] {
        guard let server = profile.serverURL,
              let token = MediaSourceProfileStore.secret(for: profile)?.token,
              !token.isEmpty else {
            throw MediaSourceError.missingCredential
        }
        let path = navigationKey ?? "/library/sections"
        guard let url = URL(string: path, relativeTo: server)?.absoluteURL else {
            throw MediaSourceError.invalidResponse
        }
        return try await load(
            url: url,
            headers: Self.headers(token: token),
            isSections: navigationKey == nil,
            profile: profile
        )
    }

    /// 把 Plex Part 路径转换为 AVPlayer 可使用的完整地址。
    /// - Parameters:
    ///   - profile: Plex 连接配置。
    ///   - streamPath: XML Part.key。
    /// - Returns: 服务器上的原始视频地址。
    func streamURL(profile: MediaSourceProfile, streamPath: String) throws -> URL {
        guard let server = profile.serverURL,
              let url = URL(string: streamPath, relativeTo: server)?.absoluteURL else {
            throw MediaSourceError.invalidResponse
        }
        return url
    }

    /// 下载并解析 Plex XML 响应。
    /// - Parameters:
    ///   - url: API 地址。
    ///   - headers: Plex 请求头。
    ///   - isSections: 是否正在解析 `/library/sections`。
    ///   - profile: 当前 Plex 配置，仅用于保留调用语义。
    /// - Returns: 统一媒体条目。
    private func load(
        url: URL,
        headers: [String: String],
        isSections: Bool,
        profile: MediaSourceProfile
    ) async throws -> [MediaSourceEntry] {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MediaSourceError.invalidResponse }
        if http.statusCode == 401 { throw MediaSourceError.authenticationFailed }
        guard (200..<300).contains(http.statusCode) else { throw MediaSourceError.http(http.statusCode) }
        let delegate = PlexXMLDelegate(isSections: isSections)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw MediaSourceError.invalidResponse }
        return delegate.entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            if let left = $0.index, let right = $1.index, left != right { return left < right }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 生成 Plex API 的客户端和认证请求头。
    /// - Parameter token: X-Plex-Token。
    /// - Returns: Plex 要求的最小请求头集合。
    private static func headers(token: String) -> [String: String] {
        [
            "Accept": "application/xml",
            "X-Plex-Token": token,
            "X-Plex-Client-Identifier": "com.kanata.app",
            "X-Plex-Product": "Kanata",
            "X-Plex-Version": "0.1.0",
        ]
    }
}

/// 把 Plex 的 Directory、Video 和 Part XML 转成统一媒体条目。
private final class PlexXMLDelegate: NSObject, XMLParserDelegate {
    let isSections: Bool
    var entries: [MediaSourceEntry] = []
    private var currentVideo: [String: String]?
    private var currentPartPath: String?

    /// 创建 Plex XML 解析器。
    /// - Parameter isSections: true 时把数字分区 key 转成 `/library/sections/{key}/all`。
    init(isSections: Bool) {
        self.isSections = isSections
    }

    /// 进入目录时立即生成节点，进入视频时等待内部 Part 路径。
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "Directory":
            guard let title = attributeDict["title"] ?? attributeDict["name"] else { return }
            let rawKey = attributeDict["key"] ?? attributeDict["ratingKey"] ?? title
            let navigationKey = isSections
                ? "/library/sections/\(rawKey)/all"
                : Self.directoryPath(from: attributeDict, fallback: rawKey)
            entries.append(MediaSourceEntry(
                id: "plex-directory:\(rawKey)",
                name: title,
                type: attributeDict["type"] ?? "folder",
                isDirectory: true,
                navigationKey: navigationKey,
                streamPath: nil,
                index: attributeDict["index"].flatMap(Int.init),
                seasonIndex: attributeDict["parentIndex"].flatMap(Int.init),
                artworkPath: attributeDict["thumb"] ?? attributeDict["art"]
            ))
        case "Video":
            currentVideo = attributeDict
            currentPartPath = nil
        case "Part":
            if currentVideo != nil { currentPartPath = attributeDict["key"] }
        default:
            break
        }
    }

    /// 在 Video 结束时把标题、集号和 Part 路径组合成可播放项目。
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "Video", let video = currentVideo else { return }
        let title = video["title"] ?? video["grandparentTitle"] ?? "Plex 视频"
        let id = video["ratingKey"] ?? video["key"] ?? UUID().uuidString
        entries.append(MediaSourceEntry(
            id: "plex-video:\(id)",
            name: title,
            type: video["type"] ?? "video",
            isDirectory: false,
            navigationKey: nil,
            streamPath: currentPartPath,
            index: video["index"].flatMap(Int.init),
            seasonIndex: video["parentIndex"].flatMap(Int.init),
            artworkPath: video["thumb"] ?? video["grandparentThumb"] ?? video["art"]
        ))
        currentVideo = nil
        currentPartPath = nil
    }

    /// 从 Plex Directory 属性生成可继续浏览的 API 路径。
    /// - Parameters:
    ///   - attributes: Directory XML 属性。
    ///   - fallback: 无 key 时的回退值。
    /// - Returns: `/library/metadata/{id}/children` 等路径。
    private static func directoryPath(from attributes: [String: String], fallback: String) -> String {
        if let key = attributes["key"], key.hasPrefix("/") { return key }
        if let ratingKey = attributes["ratingKey"] {
            return "/library/metadata/\(ratingKey)/children"
        }
        return fallback
    }
}

/// 媒体源访问中的可执行错误提示。
enum MediaSourceError: LocalizedError {
    case invalidResponse
    case authenticationFailed
    case missingCredential
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务器响应格式无效"
        case .authenticationFailed: "账号、密码或访问令牌不正确"
        case .missingCredential: "登录记录已失效，请重新添加该媒体源"
        case .http(let status): "服务器返回 HTTP \(status)"
        }
    }
}
