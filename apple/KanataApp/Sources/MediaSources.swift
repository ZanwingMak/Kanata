import Foundation
import SwiftUI

/// 统一的媒体源入口，提供直链、WebDAV 和 Jellyfin 三种可立即使用的方式。
struct MediaSourceSheet: View {
    let onAdd: (LibraryItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("添加视频") {
                    NavigationLink {
                        DirectMediaSourceView(onAdd: finish)
                    } label: {
                        sourceLabel("网络直链 / HLS", detail: "HTTP、HTTPS、m3u8", symbol: "link")
                    }
                    NavigationLink {
                        WebDAVSourceView(onAdd: finish)
                    } label: {
                        sourceLabel("WebDAV", detail: "浏览 NAS 与网盘目录", symbol: "externaldrive.connected.to.line.below")
                    }
                    NavigationLink {
                        JellyfinSourceView(onAdd: finish)
                    } label: {
                        sourceLabel("Jellyfin", detail: "登录并浏览媒体库", symbol: "play.tv")
                    }
                }
                Section {
                    Text("WebDAV 密码和 Jellyfin 令牌只保存在本机 Keychain；选中的视频保存为媒体库条目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("添加媒体源")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    /// 生成带说明的媒体来源列表标签。
    /// - Parameters:
    ///   - title: 来源名称。
    ///   - detail: 能力说明。
    ///   - symbol: SF Symbol 名称。
    /// - Returns: 统一样式的标签视图。
    private func sourceLabel(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.cyan)
        }
    }

    /// 保存新媒体条目并关闭整个添加媒体源窗口。
    /// - Parameter item: 用户选择的可播放视频。
    private func finish(_ item: LibraryItem) {
        onAdd(item)
        dismiss()
    }
}

/// 添加普通 HTTP(S) 视频或 HLS 直链。
private struct DirectMediaSourceView: View {
    let onAdd: (LibraryItem) -> Void
    @State private var name = ""
    @State private var urlString = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("视频地址") {
                TextField("名称（可选）", text: $name)
                TextField("https://…/video.mp4 或 playlist.m3u8", text: $urlString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            Button("添加并播放") { addVideo() }
                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("网络直链")
        .kanataInlineNavigationTitle()
    }

    /// 校验直链并创建媒体库条目。
    private func addVideo() {
        let value = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS 地址"
            return
        }
        onAdd(LibraryItem(remoteURL: url, name: name, sourceName: "网络直链"))
    }
}

/// WebDAV 中的一项文件或目录。
private struct WebDAVEntry: Identifiable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let contentType: String?

    var id: String { url.absoluteString }
}

/// WebDAV PROPFIND 客户端。
private actor WebDAVClient {
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
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
        guard http.statusCode == 207 || (200..<300).contains(http.statusCode) else {
            throw MediaSourceError.http(http.statusCode)
        }
        let parserDelegate = WebDAVXMLDelegate(baseURL: directory)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = parserDelegate
        guard parser.parse() else { throw MediaSourceError.invalidResponse }
        let root = Self.normalizedPath(directory.path)
        return parserDelegate.entries
            .filter { Self.normalizedPath($0.url.path) != root }
            .filter { $0.isDirectory || Self.isVideo($0.url) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    /// 判断文件扩展名是否属于播放器支持的视频范围。
    /// - Parameter url: WebDAV 文件地址。
    /// - Returns: 常见视频或 HLS 扩展名时返回 true。
    private static func isVideo(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m3u8", "flv"]
            .contains(url.pathExtension.lowercased())
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
           let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: baseURL)?.absoluteURL {
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

/// WebDAV 登录和目录浏览界面。
private struct WebDAVSourceView: View {
    let onAdd: (LibraryItem) -> Void
    @State private var server = ""
    @State private var path = "/"
    @State private var username = ""
    @State private var password = ""
    @State private var client: WebDAVClient?
    @State private var directoryStack: [URL] = []
    @State private var entries: [WebDAVEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if client == nil {
                Form {
                    Section("服务器") {
                        TextField("http://nas.local:5005", text: $server)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("起始路径，例如 /Movies", text: $path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("用户名（可选）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码（可选）", text: $password)
                    }
                    Button("连接并浏览") { Task { await connect() } }
                        .disabled(server.isEmpty || isLoading)
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
                }
            } else {
                mediaList
            }
        }
        .navigationTitle("WebDAV")
        .kanataInlineNavigationTitle()
        .toolbar {
            if directoryStack.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("上一级") { Task { await goBack() } }
                }
            }
        }
    }

    /// 当前 WebDAV 目录的可浏览列表。
    private var mediaList: some View {
        List {
            if isLoading { ProgressView("正在读取目录…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            ForEach(entries) { entry in
                Button {
                    Task { await select(entry) }
                } label: {
                    Label(entry.name, systemImage: entry.isDirectory ? "folder.fill" : "play.rectangle")
                }
            }
            if !isLoading && entries.isEmpty && errorMessage == nil {
                ContentUnavailableView("没有视频", systemImage: "film", description: Text("该目录没有支持的视频文件"))
            }
        }
    }

    /// 校验服务器地址并读取首个目录。
    private func connect() async {
        guard var base = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme?.lowercased()) else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS WebDAV 地址"
            return
        }
        if !base.absoluteString.hasSuffix("/") { base.appendPathComponent("") }
        guard let start = URL(string: path.isEmpty ? "/" : path, relativeTo: base)?.absoluteURL else {
            errorMessage = "起始路径无效"
            return
        }
        let value = WebDAVClient(username: username, password: password)
        client = value
        directoryStack = [start]
        await load(start, client: value)
    }

    /// 打开目录，或把视频及其认证请求头保存到媒体库。
    /// - Parameter entry: 用户选择的 WebDAV 项。
    private func select(_ entry: WebDAVEntry) async {
        guard let client else { return }
        if entry.isDirectory {
            directoryStack.append(entry.url)
            await load(entry.url, client: client)
        } else {
            let headers = client.headers
            let account = MediaCredentialStore.save(headers: headers, prefix: "webdav")
            onAdd(LibraryItem(
                remoteURL: entry.url,
                name: entry.name,
                sourceName: "WebDAV",
                credentialAccount: account
            ))
        }
    }

    /// 返回 WebDAV 上一级目录并重新加载。
    private func goBack() async {
        guard directoryStack.count > 1, let client else { return }
        directoryStack.removeLast()
        if let directory = directoryStack.last { await load(directory, client: client) }
    }

    /// 读取并显示指定 WebDAV 目录。
    /// - Parameters:
    ///   - directory: 当前目录。
    ///   - client: 已认证客户端。
    private func load(_ directory: URL, client: WebDAVClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            entries = try await client.list(directory: directory)
        } catch {
            errorMessage = error.localizedDescription
            entries = []
        }
    }
}

/// 已登录的 Jellyfin 会话。
private struct JellyfinSession: Sendable {
    let server: URL
    let userID: String
    let token: String
}

/// Jellyfin 媒体库的一项。
private struct JellyfinEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let type: String

    var isDirectory: Bool {
        ["CollectionFolder", "Folder", "Series", "Season", "BoxSet"].contains(type)
    }
}

/// Jellyfin 官方 REST API 的最小客户端。
private actor JellyfinClient {
    private let session: URLSession

    /// 创建短超时、无持久 Cookie 的 Jellyfin 客户端。
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        self.session = URLSession(configuration: configuration)
    }

    /// 使用用户名密码登录 Jellyfin。
    /// - Parameters:
    ///   - server: Jellyfin 服务器根地址。
    ///   - username: 用户名。
    ///   - password: 密码。
    /// - Returns: 用户 ID 与访问令牌。
    func login(server: URL, username: String, password: String) async throws -> JellyfinSession {
        let url = server.appendingPathComponent("Users/AuthenticateByName")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.authorizationHeader(), forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONEncoder().encode(LoginRequest(Username: username, Pw: password))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let value = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard !value.AccessToken.isEmpty, !value.User.Id.isEmpty else { throw MediaSourceError.invalidResponse }
        return JellyfinSession(server: server, userID: value.User.Id, token: value.AccessToken)
    }

    /// 读取 Jellyfin 根媒体库或指定文件夹的直接子项。
    /// - Parameters:
    ///   - login: 已登录会话。
    ///   - parentID: nil 读取用户媒体库视图，否则读取该条目的子项。
    /// - Returns: 文件夹、剧集与电影列表。
    func items(login: JellyfinSession, parentID: String?) async throws -> [JellyfinEntry] {
        let endpoint: URL
        if let parentID {
            var components = URLComponents(
                url: login.server.appendingPathComponent("Users/\(login.userID)/Items"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "Fields", value: "MediaSources"),
            ]
            guard let value = components?.url else { throw MediaSourceError.invalidResponse }
            endpoint = value
        } else {
            endpoint = login.server.appendingPathComponent("Users/\(login.userID)/Views")
        }
        var request = URLRequest(url: endpoint)
        request.setValue(login.token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(Self.authorizationHeader(token: login.token), forHTTPHeaderField: "X-Emby-Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let value = try JSONDecoder().decode(ItemsResponse.self, from: data)
        return value.Items
            .filter { $0.isFolder == true || ["Movie", "Episode", "Video", "MusicVideo"].contains($0.type) }
            .map { JellyfinEntry(id: $0.id, name: $0.name, type: $0.type) }
    }

    /// 构建 Jellyfin 静态原文件播放地址。
    /// - Parameters:
    ///   - login: 已登录会话。
    ///   - itemID: 电影或剧集 ID。
    /// - Returns: 不含明文令牌的播放 URL。
    func streamURL(login: JellyfinSession, itemID: String) -> URL {
        var components = URLComponents(
            url: login.server.appendingPathComponent("Videos/\(itemID)/stream"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "static", value: "true")]
        return components.url!
    }

    /// 生成 Jellyfin 识别客户端所需的授权头。
    /// - Parameter token: 可选访问令牌。
    /// - Returns: MediaBrowser 格式的授权值。
    private static func authorizationHeader(token: String? = nil) -> String {
        var value = "MediaBrowser Client=\"Kanata\", Device=\"Apple\", DeviceId=\"kanata-apple\", Version=\"0.1.0\""
        if let token { value += ", Token=\"\(token)\"" }
        return value
    }

    /// 校验 Jellyfin HTTP 响应并映射认证错误。
    /// - Parameter response: URLSession 响应。
    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw MediaSourceError.invalidResponse }
        if http.statusCode == 401 { throw MediaSourceError.authenticationFailed }
        guard (200..<300).contains(http.statusCode) else { throw MediaSourceError.http(http.statusCode) }
    }
}

/// Jellyfin 登录请求模型。
private struct LoginRequest: Encodable {
    let Username: String
    let Pw: String
}

/// Jellyfin 登录响应模型。
private struct LoginResponse: Decodable {
    struct UserValue: Decodable { let Id: String }
    let User: UserValue
    let AccessToken: String
}

/// Jellyfin 媒体列表响应模型。
private struct ItemsResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let name: String
        let type: String
        let isFolder: Bool?

        private enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case type = "Type"
            case isFolder = "IsFolder"
        }
    }
    let Items: [Item]
}

/// Jellyfin 登录与媒体库浏览界面。
private struct JellyfinSourceView: View {
    let onAdd: (LibraryItem) -> Void
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var login: JellyfinSession?
    @State private var directoryStack: [(id: String?, name: String)] = []
    @State private var entries: [JellyfinEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    private let client = JellyfinClient()

    var body: some View {
        Group {
            if login == nil {
                Form {
                    Section("Jellyfin 服务器") {
                        TextField("http://nas.local:8096", text: $server)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("用户名", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("密码", text: $password)
                    }
                    Button("登录并浏览") { Task { await connect() } }
                        .disabled(server.isEmpty || username.isEmpty || isLoading)
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
                }
            } else {
                mediaList
            }
        }
        .navigationTitle("Jellyfin")
        .kanataInlineNavigationTitle()
        .toolbar {
            if directoryStack.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("上一级") { Task { await goBack() } }
                }
            }
        }
    }

    /// 当前 Jellyfin 目录列表。
    private var mediaList: some View {
        List {
            if isLoading { ProgressView("正在读取媒体库…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            ForEach(entries) { entry in
                Button { Task { await select(entry) } } label: {
                    Label(entry.name, systemImage: entry.isDirectory ? "folder.fill" : "play.rectangle")
                }
            }
            if !isLoading && entries.isEmpty && errorMessage == nil {
                ContentUnavailableView("没有视频", systemImage: "film", description: Text("该目录没有可播放项目"))
            }
        }
    }

    /// 登录 Jellyfin 并读取用户媒体库视图。
    private func connect() async {
        let rawServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServer = rawServer.count > 1
            ? rawServer.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
            : rawServer
        guard let url = URL(string: normalizedServer),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            errorMessage = "请输入有效的 Jellyfin 地址"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let value = try await client.login(server: url, username: username, password: password)
            login = value
            directoryStack = [(nil, "媒体库")]
            entries = try await client.items(login: value, parentID: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 打开 Jellyfin 文件夹或添加可播放视频。
    /// - Parameter entry: 用户选择的媒体项。
    private func select(_ entry: JellyfinEntry) async {
        guard let login else { return }
        if entry.isDirectory {
            directoryStack.append((entry.id, entry.name))
            await load(parentID: entry.id, login: login)
        } else {
            let url = await client.streamURL(login: login, itemID: entry.id)
            let headers = [
                "X-Emby-Token": login.token,
                "X-Emby-Authorization": "MediaBrowser Client=\"Kanata\", Device=\"Apple\", DeviceId=\"kanata-apple\", Version=\"0.1.0\", Token=\"\(login.token)\"",
            ]
            let account = MediaCredentialStore.save(headers: headers, prefix: "jellyfin")
            onAdd(LibraryItem(
                remoteURL: url,
                name: entry.name,
                sourceName: "Jellyfin",
                credentialAccount: account
            ))
        }
    }

    /// 返回 Jellyfin 上一级媒体目录。
    private func goBack() async {
        guard directoryStack.count > 1, let login else { return }
        directoryStack.removeLast()
        await load(parentID: directoryStack.last?.id, login: login)
    }

    /// 读取指定 Jellyfin 父项目的子项。
    /// - Parameters:
    ///   - parentID: 父项目 ID，nil 表示媒体库根视图。
    ///   - login: 已登录会话。
    private func load(parentID: String?, login: JellyfinSession) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            entries = try await client.items(login: login, parentID: parentID)
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}

/// 将媒体请求头安全保存到 Keychain。
private enum MediaCredentialStore {
    /// 保存认证请求头并返回媒体库可引用的账号名。
    /// - Parameters:
    ///   - headers: Authorization 或媒体服务器令牌请求头。
    ///   - prefix: 来源短标识。
    /// - Returns: 空请求头返回 nil，否则返回 Keychain 账号名。
    static func save(headers: [String: String], prefix: String) -> String? {
        guard !headers.isEmpty,
              let data = try? JSONEncoder().encode(MediaRequestCredential(headers: headers)) else { return nil }
        let account = "media.\(prefix).\(UUID().uuidString)"
        KeychainStore.set(data, account: account)
        return account
    }
}

/// 媒体源访问中的可执行错误提示。
private enum MediaSourceError: LocalizedError {
    case invalidResponse
    case authenticationFailed
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务器响应格式无效"
        case .authenticationFailed: "账号或密码不正确"
        case .http(let status): "服务器返回 HTTP \(status)"
        }
    }
}
