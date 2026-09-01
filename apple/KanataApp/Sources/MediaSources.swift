import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 媒体源表单的非敏感草稿；避免 Apple TV 误触返回后重复输入。
private struct MediaSourceConnectionDraft: Codable {
    var name = ""
    var server = ""
    var rootPath = "/"
    var username = ""
}

/// 只持久化服务器等非敏感字段，密码、令牌与验证码绝不写入 UserDefaults。
private enum MediaSourceDraftStore {
    /// 读取指定类型上次未完成的连接草稿。
    /// - Parameter kind: 媒体源类型。
    /// - Returns: 已保存草稿；不存在时返回空草稿。
    static func load(for kind: MediaSourceKind) -> MediaSourceConnectionDraft {
        guard let data = UserDefaults.standard.data(forKey: key(for: kind)),
              let value = try? JSONDecoder().decode(MediaSourceConnectionDraft.self, from: data) else {
            return MediaSourceConnectionDraft()
        }
        return value
    }

    /// 保存指定类型的非敏感连接草稿。
    /// - Parameters:
    ///   - draft: 当前表单内容。
    ///   - kind: 媒体源类型。
    static func save(_ draft: MediaSourceConnectionDraft, for kind: MediaSourceKind) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        UserDefaults.standard.set(data, forKey: key(for: kind))
    }

    /// 连接成功后清除该类型草稿。
    /// - Parameter kind: 媒体源类型。
    static func clear(for kind: MediaSourceKind) {
        UserDefaults.standard.removeObject(forKey: key(for: kind))
    }

    /// 返回媒体源类型隔离的存储键。
    /// - Parameter kind: 媒体源类型。
    /// - Returns: UserDefaults 键。
    private static func key(for kind: MediaSourceKind) -> String {
        "mediaSource.connectionDraft.\(kind.rawValue)"
    }
}

/// 统一媒体源入口，展示历史连接并支持添加四类网络媒体源。
struct MediaSourceSheet: View {
    let onAdd: ([LibraryItem]) -> Void
    let onSourcesChanged: () -> Void
    let usesParentNavigation: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var profiles = MediaSourceProfileStore.load()
    @State private var isImportingFolder = false
    @State private var importError: String?
    @State private var pendingImport: MediaImportDraft?

    /// 创建媒体源入口；Apple TV 可复用首页导航栈以获得完整页面式流程。
    /// - Parameters:
    ///   - onAdd: 选中视频或合集后的回调。
    ///   - onSourcesChanged: 历史媒体源变化后的刷新回调。
    ///   - usesParentNavigation: 是否由外层 NavigationStack 管理返回层级。
    init(
        onAdd: @escaping ([LibraryItem]) -> Void,
        onSourcesChanged: @escaping () -> Void,
        usesParentNavigation: Bool = false
    ) {
        self.onAdd = onAdd
        self.onSourcesChanged = onSourcesChanged
        self.usesParentNavigation = usesParentNavigation
    }

    @ViewBuilder
    var body: some View {
        if usesParentNavigation {
            content
        } else {
            NavigationStack { content }
        }
    }

    /// 构建可由弹窗或独立导航页面共同复用的媒体源列表。
    private var content: some View {
        List {
                #if os(tvOS)
                Section("手机辅助配置") {
                    NavigationLink {
                        TVMediaSourcePairingView(onSaved: reloadProfiles)
                    } label: {
                        sourceLabel(
                            "扫码在手机上配置",
                            detail: "同一 Wi‑Fi 下用手机浏览器填写地址、账号与密码",
                            symbol: "qrcode.viewfinder"
                        )
                    }
                }
                #endif
                if !profiles.isEmpty {
                    Section("最近使用") {
                        ForEach(profiles) { profile in
                            NavigationLink {
                                MediaSourceChannelView(profile: profile, onAdd: finish)
                            } label: {
                                sourceLabel(
                                    profile.name,
                                    detail: "\(profile.kind.title) · \(profile.subtitle)",
                                    symbol: profile.kind.symbol
                                )
                            }
                            .contextMenu {
                                Button("删除登录记录", systemImage: "trash", role: .destructive) {
                                    MediaSourceProfileStore.remove(profile)
                                    reloadProfiles()
                                }
                            }
                        }
                    }
                }

                Section("添加视频") {
                    NavigationLink {
                        DirectMediaSourceView { finish([$0]) }
                    } label: {
                        sourceLabel("网络直链 / HLS", detail: "HTTP、HTTPS、m3u8", symbol: "link")
                    }
                    #if !os(tvOS)
                    Button {
                        isImportingFolder = true
                    } label: {
                        sourceLabel(
                            "文件夹 / SMB",
                            detail: "通过系统文件 App 选择本机、iCloud 或已连接的 SMB 目录",
                            symbol: "folder.badge.plus"
                        )
                    }
                    #endif
                    ForEach(MediaSourceKind.allCases) { kind in
                        NavigationLink {
                            MediaSourceConnectionView(
                                kind: kind,
                                onSaved: { _ in reloadProfiles() },
                                onAdd: finish
                            )
                        } label: {
                            sourceLabel(kind.title, detail: sourceDetail(kind), symbol: kind.symbol)
                        }
                    }
                }

                Section {
                    Text("服务器、用户名和最近目录会保留为历史记录；密码与令牌只存放在本机 Keychain。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
        .kanataFormBackground()
        .navigationTitle("添加媒体源")
        .kanataInlineNavigationTitle()
        .toolbar {
            if !usesParentNavigation {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .kanataFileImporter(
            isPresented: $isImportingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: importFolder
        )
        .alert(
            "文件夹导入失败",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(item: $pendingImport) { draft in
            MediaImportPreview(draft: draft, onConfirm: finish)
        }
    }

    /// 生成带说明的媒体来源列表标签。
    /// - Parameters:
    ///   - title: 来源名称。
    ///   - detail: 能力说明。
    ///   - symbol: SF Symbol 名称。
    /// - Returns: 统一样式的标签视图。
    private func sourceLabel(_ title: String, detail: String, symbol: String) -> some View {
        KanataRowLabel(title: title, detail: detail, symbol: symbol)
    }

    /// 返回媒体源在添加列表中的能力说明。
    /// - Parameter kind: 媒体源类型。
    /// - Returns: 一行简短说明。
    private func sourceDetail(_ kind: MediaSourceKind) -> String {
        switch kind {
        case .webDAV: "浏览目录、单文件或整目录合集"
        case .jellyfin: "按媒体库、剧集与文件夹浏览"
        case .emby: "按媒体库、剧集与文件夹浏览"
        case .plex: "浏览电影、剧集和媒体库分区"
        case .synology: "登录 DSM，浏览 File Station 视频"
        }
    }

    /// 把选中的单个视频或合集交给首页并关闭添加窗口。
    /// - Parameter items: 已带来源和合集信息的媒体条目。
    private func finish(_ items: [LibraryItem]) {
        guard !items.isEmpty else { return }
        onAdd(items)
        dismiss()
    }

    /// 重新读取媒体源历史并通知首页刷新频道。
    private func reloadProfiles() {
        profiles = MediaSourceProfileStore.load()
        onSourcesChanged()
    }

    /// 递归读取系统文件选择器返回的目录并生成按第一层子目录分组的导入预览。
    /// - Parameter result: 目录选择结果；已连接的 SMB 会由系统文件提供器暴露。
    private func importFolder(_ result: Result<[URL], Error>) {
        do {
            guard let root = try result.get().first else { return }
            let accessing = root.startAccessingSecurityScopedResource()
            defer { if accessing { root.stopAccessingSecurityScopedResource() } }
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw MediaSourceError.invalidResponse
            }
            let videos = enumerator.compactMap { value -> URL? in
                guard let url = value as? URL,
                      Self.isVideoFile(url) else { return nil }
                return url
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(2_000)
            guard !videos.isEmpty else {
                importError = "该目录中没有找到支持的视频文件"
                return
            }
            let title = root.lastPathComponent.removingPercentEncoding ?? root.lastPathComponent
            let grouped = Dictionary(grouping: videos) { url in
                Self.relativeGroupName(for: url, root: root) ?? title
            }
            let items = grouped.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).flatMap { groupTitle in
                let groupVideos = (grouped[groupTitle] ?? []).sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                let collectionID = "folder:\(root.standardizedFileURL.absoluteString)#\(groupTitle)"
                return groupVideos.enumerated().compactMap { offset, url in
                    LibraryItem(
                        url: url,
                        collectionID: collectionID,
                        collectionTitle: groupTitle,
                        collectionIndex: offset + 1
                    )
                }
            }
            guard !items.isEmpty else {
                importError = "系统没有授予该目录的持久访问权限，请重新选择"
                return
            }
            pendingImport = MediaImportDraft(
                title: title,
                items: items,
                prefersMergedCollection: grouped.count == 1
            )
        } catch {
            importError = error.localizedDescription
        }
    }

    /// 判断文件扩展名是否属于本地播放器支持范围。
    /// - Parameter url: 文件提供器返回的文件 URL。
    /// - Returns: 常见视频格式时返回 true。
    private static func isVideoFile(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts", "flv"]
            .contains(url.pathExtension.lowercased())
    }

    /// 返回视频相对所选根目录的第一层分组名称。
    /// - Parameters:
    ///   - url: 扫描到的视频文件。
    ///   - root: 用户选择的根目录。
    /// - Returns: 第一层子目录名；根目录直放文件时返回 nil。
    private static func relativeGroupName(for url: URL, root: URL) -> String? {
        let rootCount = root.standardizedFileURL.pathComponents.count
        let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(rootCount))
        guard relative.count > 1 else { return nil }
        return relative[0].removingPercentEncoding ?? relative[0]
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
            Button {
                addVideo()
            } label: {
                Label("加入媒体库", systemImage: "plus.circle.fill")
            }
                .buttonStyle(KanataPrimaryButtonStyle())
                .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .kanataFormBackground()
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

/// 新媒体源登录界面；连接成功后直接切换到频道浏览器。
private struct MediaSourceConnectionView: View {
    let kind: MediaSourceKind
    let onSaved: (MediaSourceProfile) -> Void
    let onAdd: ([LibraryItem]) -> Void
    @State private var name = ""
    @State private var serverScheme = "http"
    @State private var serverHost = ""
    @State private var serverPort = ""
    @State private var serverPath = ""
    @State private var rootPath = "/"
    @State private var username = ""
    @State private var password = ""
    @State private var otp = ""
    @State private var plexToken = ""
    @State private var profile: MediaSourceProfile?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isShowingPlexAuthorization = false
    @State private var plexLoginMode = PlexLoginMode.account

    /// Plex 支持的两种登录入口。
    private enum PlexLoginMode: String, CaseIterable, Identifiable {
        case account
        case token

        var id: String { rawValue }

        var title: String {
            switch self {
            case .account: "Plex 账号"
            case .token: "地址与 Token"
            }
        }
    }

    var body: some View {
        Group {
            if let profile {
                MediaSourceChannelView(profile: profile, onAdd: onAdd)
            } else {
                connectionForm
            }
        }
        .navigationTitle(profile?.name ?? "添加 \(kind.title)")
        .kanataInlineNavigationTitle()
        .onAppear { restoreDraft() }
        .onChange(of: name) { _, _ in saveDraft() }
        .onChange(of: serverScheme) { _, _ in saveDraft() }
        .onChange(of: serverHost) { _, _ in saveDraft() }
        .onChange(of: serverPort) { _, _ in saveDraft() }
        .onChange(of: serverPath) { _, _ in saveDraft() }
        .onChange(of: rootPath) { _, _ in saveDraft() }
        .onChange(of: username) { _, _ in saveDraft() }
        .sheet(isPresented: $isShowingPlexAuthorization) {
            PlexAuthorizationView { connection in
                let currentName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                name = currentName.isEmpty ? connection.serverName : currentName
                applyServerURL(connection.serverURL)
                plexToken = connection.token
                isShowingPlexAuthorization = false
                Task { await connect() }
            }
        }
    }

    /// 根据媒体源类型生成分步骤登录表单。
    private var connectionForm: some View {
        Form {
            if kind == .plex {
                Section("连接方式") {
                    Picker("登录模式", selection: $plexLoginMode) {
                        ForEach(PlexLoginMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(plexLoginMode == .account
                        ? "登录 Plex 账号后自动发现服务器、测试连接并选择最快线路。"
                        : "仅在你已经知道服务器地址和 X-Plex-Token 时使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if kind != .plex || plexLoginMode == .token {
                Section("服务器地址") {
                    LabeledContent("显示名称") {
                        TextField("例如：客厅 NAS", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("协议", selection: $serverScheme) {
                        Text("HTTP").tag("http")
                        Text("HTTPS").tag("https")
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("域名或 IP 地址")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("例如 nas.local 或 192.168.1.20", text: $serverHost)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("端口")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField(defaultPort, text: $serverPort)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numberPad)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("基础路径（可选）")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("例如 /jellyfin", text: $serverPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    if kind == .webDAV {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("媒体起始目录")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("例如 /Movies", text: $rootPath)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        }
                    }
                    Text("将连接到：\(serverPreview)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if kind == .plex, plexLoginMode == .account {
                Section {
                    Button {
                        isShowingPlexAuthorization = true
                    } label: {
                        Label("登录并自动发现服务器", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .buttonStyle(KanataPrimaryButtonStyle())
                    Text("Kanata 会优先测试局域网直连，其次远程直连，最后才使用 Plex Relay。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("登录") {
                    if kind == .plex {
                        SecureField("X-Plex-Token", text: $plexToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        TextField(kind == .webDAV ? "用户名（可选）" : "用户名", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(kind == .webDAV ? "密码（可选）" : "密码", text: $password)
                        if kind == .synology {
                            TextField("两步验证码（如已开启）", text: $otp)
                                .textContentType(.oneTimeCode)
                                .keyboardType(.numberPad)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Label("测试连接并保存", systemImage: "network.badge.shield.half.filled")
                            if isLoading { Spacer(); ProgressView() }
                        }
                    }
                    .buttonStyle(KanataPrimaryButtonStyle())
                    .disabled(serverHost.isEmpty || isLoading || (kind == .plex && plexToken.isEmpty))
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
        }
        .kanataFormBackground()
    }

    /// 校验服务器和凭证，保存历史记录并进入频道浏览器。
    private func connect() async {
        guard let serverURL = normalizedServerURL() else {
            errorMessage = "请输入有效的 HTTP 或 HTTPS 服务器地址"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let secret: MediaSourceSecret
            switch kind {
            case .webDAV:
                let start = try webDAVStartURL(server: serverURL)
                let client = WebDAVClient(username: username, password: password)
                _ = try await client.list(directory: start)
                secret = MediaSourceSecret(password: password, token: nil, userID: nil)
            case .jellyfin, .emby:
                secret = try await MediaBrowserClient().login(
                    server: serverURL,
                    username: username,
                    password: password
                )
            case .plex:
                _ = try await PlexClient().verify(server: serverURL, token: plexToken)
                secret = MediaSourceSecret(password: nil, token: plexToken, userID: nil)
            case .synology:
                secret = try await SynologyFileStationClient().login(
                    server: serverURL,
                    username: username,
                    password: password,
                    otp: otp
                )
            }
            let value = MediaSourceProfileStore.upsert(
                kind: kind,
                name: resolvedName(server: serverURL),
                serverURL: serverURL,
                username: username,
                rootPath: kind == .webDAV ? normalizedRootPath : nil,
                secret: secret
            )
            profile = value
            MediaSourceDraftStore.clear(for: kind)
            onSaved(value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 恢复当前媒体源未完成的非敏感表单字段。
    private func restoreDraft() {
        guard profile == nil, name.isEmpty, serverHost.isEmpty, username.isEmpty else { return }
        let draft = MediaSourceDraftStore.load(for: kind)
        name = draft.name
        if let url = URL(string: draft.server), url.host != nil {
            applyServerURL(url)
        } else {
            serverScheme = kind == .synology ? "https" : "http"
            serverPort = defaultPort
        }
        rootPath = draft.rootPath
        username = draft.username
    }

    /// 持久化当前媒体源的非敏感表单字段，供误触返回后恢复。
    private func saveDraft() {
        guard profile == nil else { return }
        MediaSourceDraftStore.save(
            MediaSourceConnectionDraft(
                name: name,
                server: serverPreview,
                rootPath: rootPath,
                username: username
            ),
            for: kind
        )
    }

    /// 规范化用户输入的服务器根地址。
    /// - Returns: 合法 HTTP(S) URL，非法时返回 nil。
    private func normalizedServerURL() -> URL? {
        var components = URLComponents()
        components.scheme = serverScheme
        components.host = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = Int(serverPort.trimmingCharacters(in: .whitespacesAndNewlines))
        let path = serverPath.trimmingCharacters(in: .whitespacesAndNewlines)
        components.path = path.isEmpty ? "" : (path.hasPrefix("/") ? path : "/\(path)")
        guard let url = components.url,
              components.host?.isEmpty == false,
              ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url
    }

    /// 把自动发现或历史记录中的完整 URL 拆回结构化表单字段。
    /// - Parameter url: 已验证的服务器地址。
    private func applyServerURL(_ url: URL) {
        serverScheme = url.scheme?.lowercased() == "https" ? "https" : "http"
        serverHost = url.host ?? ""
        serverPort = url.port.map(String.init) ?? ""
        serverPath = url.path == "/" ? "" : url.path
    }

    /// 返回当前媒体源的常用端口，作为明确的输入提示与初始值。
    private var defaultPort: String {
        switch kind {
        case .webDAV: "5005"
        case .jellyfin, .emby: "8096"
        case .plex: "32400"
        case .synology: "5001"
        }
    }

    /// 返回结构化服务器字段合成后的只读预览地址。
    private var serverPreview: String {
        var value = "\(serverScheme)://\(serverHost.isEmpty ? "服务器地址" : serverHost)"
        if !serverPort.isEmpty { value += ":\(serverPort)" }
        let path = serverPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { value += path.hasPrefix("/") ? path : "/\(path)" }
        return value
    }

    /// 把 WebDAV 起始路径拼接到服务器根地址。
    /// - Parameter server: WebDAV 根地址。
    /// - Returns: 可用于 PROPFIND 的目录地址。
    private func webDAVStartURL(server: URL) throws -> URL {
        guard let url = URL(string: normalizedRootPath, relativeTo: server.appendingPathComponent(""))?.absoluteURL else {
            throw MediaSourceError.invalidResponse
        }
        return url
    }

    /// 返回带前导斜杠的 WebDAV 起始路径。
    private var normalizedRootPath: String {
        let value = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return "/" }
        return value.hasPrefix("/") ? value : "/\(value)"
    }

    /// 生成频道显示名称，用户未填写时使用类型和主机名。
    /// - Parameter server: 已校验的服务器 URL。
    /// - Returns: 首页频道标题。
    private func resolvedName(server: URL) -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "\(kind.title) · \(server.host ?? "服务器")" : value
    }
}

/// Plex 官方网页登录与服务器选择界面。
private struct PlexAuthorizationView: View {
    let onSelect: (PlexDiscoveredConnection) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var pin: PlexAuthorizationPin?
    @State private var connections: [PlexDiscoveredConnection] = []
    @State private var statusText = "正在创建 Plex 登录会话…"
    @State private var errorMessage: String?
    @State private var didOpenBrowser = false
    private let client = PlexAccountClient()

    var body: some View {
        NavigationStack {
            List {
                if let pin, connections.isEmpty, errorMessage == nil {
                    Section("网页登录") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("授权码")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            #if os(tvOS)
                            Text(pin.code)
                                .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                            #else
                            Text(pin.code)
                                .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                                .textSelection(.enabled)
                            #endif
                            Label(statusText, systemImage: "person.badge.key")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            #if !os(tvOS)
                            Button {
                                didOpenBrowser = true
                                statusText = "登录成功后请返回 Kanata"
                                openURL(pin.authorizationURL)
                            } label: {
                                Label("打开 Plex 官方登录页", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            ShareLink(item: pin.authorizationURL) {
                                Label("发送登录链接到其他设备", systemImage: "square.and.arrow.up")
                            }
                            #else
                            Text("请在手机或电脑打开 plex.tv/link，登录同一账号并输入上方授权码。")
                                .font(.callout)
                            #endif
                        }
                        .padding(.vertical, 8)
                    }
                }

                if !connections.isEmpty {
                    Section("选择服务器") {
                        ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
                            Button {
                                onSelect(connection)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(connection.serverName)
                                        if index == 0 {
                                            Text("推荐")
                                                .font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(KanataTheme.accent.opacity(0.18), in: Capsule())
                                        }
                                    }
                                    Text(connection.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if index == 0 {
                                        Text("已完成连通性测试，优先使用此线路")
                                            .font(.caption2)
                                            .foregroundStyle(KanataTheme.success)
                                    }
                                }
                            }
                        }
                    }
                }

                if errorMessage == nil && pin == nil {
                    ProgressView(statusText)
                }
                if let errorMessage {
                    Section {
                        ContentUnavailableView {
                            Label("Plex 登录失败", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage)
                        } actions: {
                            Button("重新生成") { Task { await beginAuthorization() } }
                        }
                    }
                }
            }
            .navigationTitle("登录 Plex")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task { await beginAuthorization() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, didOpenBrowser else { return }
                statusText = "已返回 Kanata，正在发现服务器…"
            }
        }
    }

    /// 创建 PIN 并持续轮询，直到授权成功、失败或界面关闭。
    private func beginAuthorization() async {
        pin = nil
        connections = []
        errorMessage = nil
        didOpenBrowser = false
        statusText = "正在创建 Plex 登录会话…"
        do {
            let value = try await client.createPin()
            pin = value
            statusText = "等待在 Plex 官方页面授权"
            for _ in 0..<150 where !Task.isCancelled {
                if let values = try await client.check(value) {
                    statusText = "登录成功，正在测试最快连接…"
                    let recommendedServers = await client.recommendedServerConnections(in: values)
                    if recommendedServers.count == 1, let recommended = recommendedServers.first {
                        statusText = "已自动选择 \(recommended.serverName)"
                        onSelect(recommended)
                        return
                    }
                    connections = recommendedServers.isEmpty ? values : recommendedServers
                    statusText = "请选择要加入首页的 Plex 服务器"
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            if !Task.isCancelled { errorMessage = "授权已超时，请重新生成" }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 已保存媒体源的统一频道入口。
struct MediaSourceChannelView: View {
    let profile: MediaSourceProfile
    let onAdd: ([LibraryItem]) -> Void

    var body: some View {
        Group {
            switch profile.kind {
            case .webDAV:
                WebDAVChannelView(profile: profile, onAdd: onAdd)
            case .jellyfin, .emby, .plex, .synology:
                MediaServerChannelView(profile: profile, onAdd: onAdd)
            }
        }
        .navigationTitle(profile.name)
        .kanataInlineNavigationTitle()
        .task { MediaSourceProfileStore.touch(profile) }
    }
}

/// WebDAV 频道浏览器，支持单文件、当前目录或子目录合集。
private struct WebDAVChannelView: View {
    let profile: MediaSourceProfile
    let onAdd: ([LibraryItem]) -> Void
    @State private var directoryStack: [(url: URL, name: String)] = []
    @State private var entries: [WebDAVEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingImport: MediaImportDraft?
    private let client: WebDAVClient

    /// 从历史记录创建带认证信息的 WebDAV 浏览器。
    /// - Parameters:
    ///   - profile: WebDAV 媒体源。
    ///   - onAdd: 选择媒体后的回调。
    init(profile: MediaSourceProfile, onAdd: @escaping ([LibraryItem]) -> Void) {
        self.profile = profile
        self.onAdd = onAdd
        self.client = WebDAVClient(profile: profile)
    }

    var body: some View {
        List {
            Section("当前位置") {
                VStack(alignment: .leading, spacing: 5) {
                    Label(directoryStack.last?.name ?? profile.name, systemImage: "folder")
                        .font(.headline)
                    Text(directoryStack.map(\.name).joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button {
                    addCurrentDirectory()
                } label: {
                    Label("选择整个当前目录", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(KanataSecondaryButtonStyle())
                .disabled(entries.isEmpty || isLoading)
            }
            if isLoading { ProgressView("正在读取目录…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            Section("目录内容") {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Button {
                            Task { await select(entry) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "play.rectangle")
                                    .foregroundStyle(entry.isDirectory ? KanataTheme.accent : .secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name)
                                        .lineLimit(2)
                                    Text(entry.isDirectory ? "打开文件夹" : "选择单个视频")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if entry.isDirectory {
                            Button {
                                Task { await addDirectory(url: entry.url, title: entry.name) }
                            } label: {
                                Image(systemName: "rectangle.stack.badge.plus")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("把 \(entry.name) 添加为合集")
                        }
                    }
                }
            }
            if !isLoading && entries.isEmpty && errorMessage == nil {
                ContentUnavailableView("没有视频", systemImage: "film", description: Text("该目录没有支持的视频文件"))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if directoryStack.count > 1 {
                    Button("上一级") { Task { await goBack() } }
                }
            }
        }
        .task { await loadInitialDirectory() }
        .sheet(item: $pendingImport) { draft in
            MediaImportPreview(draft: draft, onConfirm: onAdd)
        }
    }

    /// 读取配置中的 WebDAV 起始目录。
    private func loadInitialDirectory() async {
        guard directoryStack.isEmpty,
              let server = profile.serverURL,
              let url = URL(
                  string: profile.rootPath ?? "/",
                  relativeTo: server.appendingPathComponent("")
              )?.absoluteURL else { return }
        directoryStack = [(url, profile.name)]
        await load(url)
    }

    /// 进入目录，或把单个视频交给导入预览确认。
    /// - Parameter entry: 用户选择的 WebDAV 项。
    private func select(_ entry: WebDAVEntry) async {
        if entry.isDirectory {
            directoryStack.append((entry.url, entry.name))
            await load(entry.url)
        } else {
            pendingImport = MediaImportDraft(
                title: entry.name,
                items: [makeItem(entry: entry, collectionID: nil, collectionTitle: nil, index: nil)],
                prefersMergedCollection: false
            )
        }
    }

    /// 把当前目录中所有直接视频作为一个有序合集加入媒体库。
    private func addCurrentDirectory() {
        guard let current = directoryStack.last else { return }
        Task { await prepareDirectoryImport(url: current.url, title: current.name, prefersMerged: false) }
    }

    /// 读取子目录并把其中的直接视频作为合集加入媒体库。
    /// - Parameters:
    ///   - url: 子目录地址。
    ///   - title: 合集标题。
    private func addDirectory(url: URL, title: String) async {
        await prepareDirectoryImport(url: url, title: title, prefersMerged: true)
    }

    /// 创建带合集 ID 和自然顺序的 WebDAV 媒体库条目。
    /// - Parameters:
    ///   - videos: 当前目录的直接视频。
    ///   - directoryURL: 用于生成稳定合集 ID 的目录。
    ///   - title: 合集标题。
    private func addEntries(_ videos: [WebDAVEntry], directoryURL: URL, title: String) {
        guard !videos.isEmpty else { return }
        let collectionID = "webdav:\(profile.id):\(directoryURL.absoluteString)"
        let items = videos.enumerated().map { offset, entry in
            makeItem(
                entry: entry,
                collectionID: collectionID,
                collectionTitle: title,
                index: offset + 1
            )
        }
        onAdd(items)
    }

    /// 扫描目录并按第一层子目录生成可合并或分组的导入预览。
    /// - Parameters:
    ///   - url: 用户选择的目录地址。
    ///   - title: 目录显示名称。
    ///   - prefersMerged: 是否默认合并为一个合集。
    private func prepareDirectoryImport(url: URL, title: String, prefersMerged: Bool) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let firstLevel = try await client.list(directory: url)
            var groups: [(id: String, title: String, videos: [WebDAVEntry])] = []
            let directVideos = firstLevel.filter { !$0.isDirectory }
            if !directVideos.isEmpty {
                groups.append((url.absoluteString, title, directVideos))
            }
            for directory in firstLevel where directory.isDirectory {
                guard groups.reduce(0, { $0 + $1.videos.count }) < 500 else { break }
                let videos = try await collectWebDAVVideos(url: directory.url, depth: 0)
                if !videos.isEmpty {
                    groups.append((directory.url.absoluteString, directory.name, videos))
                }
            }
            if groups.isEmpty {
                let videos = try await collectWebDAVVideos(url: url, depth: 0)
                if !videos.isEmpty { groups = [(url.absoluteString, title, videos)] }
            }
            let items = groups.flatMap { group in
                group.videos.prefix(500).enumerated().map { offset, entry in
                    makeItem(
                        entry: entry,
                        collectionID: "webdav:\(profile.id):\(group.id)",
                        collectionTitle: group.title,
                        index: offset + 1
                    )
                }
            }
            guard !items.isEmpty else {
                errorMessage = "\(title) 中没有找到可播放视频"
                return
            }
            pendingImport = MediaImportDraft(
                title: title,
                items: items,
                prefersMergedCollection: prefersMerged || groups.count == 1
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 递归收集 WebDAV 子目录视频并限制扫描规模。
    /// - Parameters:
    ///   - url: 当前目录。
    ///   - depth: 当前递归深度。
    /// - Returns: 最多 500 个自然排序的视频条目。
    private func collectWebDAVVideos(url: URL, depth: Int) async throws -> [WebDAVEntry] {
        guard depth <= 5 else { return [] }
        let values = try await client.list(directory: url)
        var result = values.filter { !$0.isDirectory }
        for directory in values where directory.isDirectory {
            guard result.count < 500 else { break }
            result.append(contentsOf: try await collectWebDAVVideos(url: directory.url, depth: depth + 1))
        }
        return Array(result.prefix(500)).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 把 WebDAV 文件转换为可播放媒体库条目。
    /// - Parameters:
    ///   - entry: 视频文件。
    ///   - collectionID: 可选合集标识。
    ///   - collectionTitle: 可选合集名称。
    ///   - index: 合集内顺序。
    /// - Returns: 不在条目中保存明文密码的网络视频。
    private func makeItem(
        entry: WebDAVEntry,
        collectionID: String?,
        collectionTitle: String?,
        index: Int?
    ) -> LibraryItem {
        LibraryItem(
            remoteURL: entry.url,
            name: entry.name,
            sourceName: profile.kind.title,
            sourceProfileID: profile.id,
            collectionID: collectionID,
            collectionTitle: collectionTitle,
            collectionIndex: index
        )
    }

    /// 返回上一级 WebDAV 目录并重新加载。
    private func goBack() async {
        guard directoryStack.count > 1 else { return }
        directoryStack.removeLast()
        if let directory = directoryStack.last?.url { await load(directory) }
    }

    /// 读取并显示指定 WebDAV 目录。
    /// - Parameter directory: 当前目录。
    private func load(_ directory: URL) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            entries = try await client.list(directory: directory)
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }
}

/// 媒体服务器频道的分类方式。
private enum MediaChannelFilter: String, CaseIterable, Identifiable {
    case all
    case movies
    case episodes
    case folders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .movies: "电影"
        case .episodes: "剧集"
        case .folders: "文件夹"
        }
    }
}

/// Jellyfin、Emby 与 Plex 共用的频道化浏览器。
private struct MediaServerChannelView: View {
    let profile: MediaSourceProfile
    let onAdd: ([LibraryItem]) -> Void
    @State private var stack: [(key: String?, name: String)] = []
    @State private var entries: [MediaSourceEntry] = []
    @State private var filter = MediaChannelFilter.all
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingImport: MediaImportDraft?
    private let mediaBrowserClient = MediaBrowserClient()
    private let plexClient = PlexClient()

    /// 按搜索关键词和内容类型过滤当前目录。
    private var visibleEntries: [MediaSourceEntry] {
        entries.filter { entry in
            let matchesSearch = searchText.isEmpty
                || entry.name.localizedCaseInsensitiveContains(searchText)
            guard matchesSearch else { return false }
            switch filter {
            case .all: return true
            case .movies: return ["Movie", "movie"].contains(entry.type)
            case .episodes: return ["Series", "Season", "Episode", "show", "season", "episode"].contains(entry.type)
            case .folders: return entry.isDirectory
            }
        }
    }

    var body: some View {
        List {
            Section("浏览方式") {
                Picker("分类", selection: $filter) {
                    ForEach(MediaChannelFilter.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    Label(stack.last?.name ?? profile.name, systemImage: "folder")
                        .font(.headline)
                    Text(stack.map(\.name).joined(separator: " / "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button {
                    Task { await addCurrentDirectory() }
                } label: {
                    Label("选择当前内容", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(KanataSecondaryButtonStyle())
                .disabled(entries.isEmpty || isLoading)
            }
            if isLoading { ProgressView("正在读取 \(profile.kind.title)…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            Section(stack.last?.name ?? profile.name) {
                ForEach(visibleEntries) { entry in
                    HStack(spacing: 12) {
                        Button {
                            Task { await select(entry) }
                        } label: {
                            HStack(spacing: 12) {
                                MediaServerArtworkView(
                                    url: artworkURL(for: entry),
                                    headers: MediaSourceProfileStore.playbackHeaders(for: profile),
                                    fallbackSymbol: symbol(for: entry)
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name)
                                        .lineLimit(2)
                                    Text(entry.typeLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                        .contentShape(Rectangle())
                        .buttonStyle(.plain)
                        if entry.isDirectory {
                            Button {
                                Task { await addDirectory(entry) }
                            } label: {
                                Image(systemName: "rectangle.stack.badge.plus")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("把 \(entry.name) 添加为合集")
                        }
                    }
                }
            }
            if !isLoading && visibleEntries.isEmpty && errorMessage == nil {
                ContentUnavailableView("没有匹配内容", systemImage: "film.stack", description: Text("切换分类或搜索其他名称"))
            }
        }
        .searchable(text: $searchText, prompt: "搜索当前频道")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if stack.count > 1 {
                    Button("上一级") { Task { await goBack() } }
                }
            }
        }
        .task { await loadInitialContent() }
        .sheet(item: $pendingImport) { draft in
            MediaImportPreview(draft: draft, onConfirm: onAdd)
        }
    }

    /// 首次进入频道时读取根媒体库。
    private func loadInitialContent() async {
        guard stack.isEmpty else { return }
        stack = [(nil, profile.name)]
        await load(key: nil)
    }

    /// 打开文件夹，或把单个视频交给导入预览确认。
    /// - Parameter entry: 当前媒体服务器条目。
    private func select(_ entry: MediaSourceEntry) async {
        if entry.isDirectory, let key = entry.navigationKey {
            stack.append((key, entry.name))
            await load(key: key)
        } else if let item = await makeItem(entry: entry, collectionID: nil, collectionTitle: nil, index: nil) {
            pendingImport = MediaImportDraft(
                title: entry.name,
                items: [item],
                prefersMergedCollection: false
            )
        }
    }

    /// 递归读取一个剧集或文件夹，并把其中视频添加为合集。
    /// - Parameter entry: 用户点击合集按钮的目录。
    private func addDirectory(_ entry: MediaSourceEntry) async {
        guard let key = entry.navigationKey else { return }
        await addCollection(key: key, title: entry.name, prefersMerged: true)
    }

    /// 把当前频道目录的全部可播放项目添加为合集。
    private func addCurrentDirectory() async {
        await addCollection(
            key: stack.last?.key,
            title: stack.last?.name ?? profile.name,
            prefersMerged: false
        )
    }

    /// 收集目录下最多 500 个视频并生成有序媒体库合集。
    /// - Parameters:
    ///   - key: MediaBrowser 项目 ID 或 Plex API 路径。
    ///   - title: 合集显示名称。
    private func addCollection(key: String?, title: String, prefersMerged: Bool) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let firstLevel = try await fetchEntries(key: key)
            var groups: [(key: String, title: String, entries: [MediaSourceEntry])] = []
            let directPlayable = firstLevel.filter(\.isPlayable)
            if !directPlayable.isEmpty {
                groups.append((key ?? "root", title, directPlayable))
            }
            for directory in firstLevel where directory.isDirectory {
                guard groups.reduce(0, { $0 + $1.entries.count }) < 500,
                      let childKey = directory.navigationKey else { continue }
                let playable = try await collectPlayable(key: childKey, depth: 0)
                if !playable.isEmpty {
                    groups.append((childKey, directory.name, playable))
                }
            }
            if groups.isEmpty {
                let playable = try await collectPlayable(key: key, depth: 0)
                if !playable.isEmpty { groups = [(key ?? "root", title, playable)] }
            }
            guard !groups.isEmpty else {
                errorMessage = "\(title) 中没有可播放视频"
                return
            }
            var items: [LibraryItem] = []
            for group in groups {
                let collectionID = "\(profile.kind.rawValue):\(profile.id):\(group.key)"
                for (offset, entry) in group.entries.enumerated() where items.count < 500 {
                    if let item = await makeItem(
                        entry: entry,
                        collectionID: collectionID,
                        collectionTitle: group.title,
                        index: entry.index ?? offset + 1
                    ) {
                        items.append(item)
                    }
                }
            }
            guard !items.isEmpty else { throw MediaSourceError.invalidResponse }
            pendingImport = MediaImportDraft(
                title: title,
                items: items,
                prefersMergedCollection: prefersMerged || groups.count == 1
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 递归收集剧集、季度或文件夹中的可播放条目。
    /// - Parameters:
    ///   - key: 当前目录标识。
    ///   - depth: 递归深度，最多四层以避免扫描整台服务器。
    /// - Returns: 按服务端顺序排列的可播放项目。
    private func collectPlayable(key: String?, depth: Int) async throws -> [MediaSourceEntry] {
        guard depth <= 4 else { return [] }
        let values = try await fetchEntries(key: key)
        var result = values.filter(\.isPlayable)
        for directory in values where directory.isDirectory {
            guard result.count < 500, let childKey = directory.navigationKey else { continue }
            result.append(contentsOf: try await collectPlayable(key: childKey, depth: depth + 1))
        }
        return result
    }

    /// 把统一媒体条目转换为带认证引用的 LibraryItem。
    /// - Parameters:
    ///   - entry: 可播放媒体条目。
    ///   - collectionID: 可选合集 ID。
    ///   - collectionTitle: 可选合集名称。
    ///   - index: 合集顺序。
    /// - Returns: 地址无效时返回 nil。
    private func makeItem(
        entry: MediaSourceEntry,
        collectionID: String?,
        collectionTitle: String?,
        index: Int?
    ) async -> LibraryItem? {
        guard let streamPath = entry.streamPath else { return nil }
        do {
            let url: URL
            if profile.kind == .plex {
                url = try await plexClient.streamURL(profile: profile, streamPath: streamPath)
            } else if profile.kind == .synology {
                url = try await SynologyFileStationClient().streamURL(
                    profile: profile,
                    path: streamPath
                )
            } else {
                url = try await mediaBrowserClient.streamURL(profile: profile, itemID: streamPath)
            }
            return LibraryItem(
                remoteURL: url,
                name: entry.name,
                sourceName: profile.kind.title,
                artworkURL: artworkURL(for: entry),
                sourceProfileID: profile.id,
                collectionID: collectionID,
                collectionTitle: collectionTitle,
                collectionIndex: index
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// 把媒体服务器返回的相对海报路径转换成完整 URL。
    /// - Parameter entry: 当前媒体条目。
    /// - Returns: 可带认证头下载的海报地址。
    private func artworkURL(for entry: MediaSourceEntry) -> URL? {
        guard let server = profile.serverURL,
              let path = entry.artworkPath,
              !path.isEmpty else { return nil }
        return URL(string: path, relativeTo: server)?.absoluteURL
    }

    /// 返回当前媒体类型适合的 SF Symbol。
    /// - Parameter entry: 媒体服务器条目。
    /// - Returns: 文件夹、剧集、电影或普通视频图标。
    private func symbol(for entry: MediaSourceEntry) -> String {
        if entry.isDirectory { return entry.type.lowercased().contains("series") || entry.type == "show" ? "tv" : "folder.fill" }
        if entry.type.lowercased().contains("episode") { return "play.square" }
        if entry.type.lowercased().contains("movie") { return "film" }
        return "play.rectangle"
    }

    /// 返回上一级媒体服务器目录。
    private func goBack() async {
        guard stack.count > 1 else { return }
        stack.removeLast()
        await load(key: stack.last?.key)
    }

    /// 读取指定媒体服务器目录并更新界面。
    /// - Parameter key: MediaBrowser 项目 ID 或 Plex API 路径。
    private func load(key: String?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            entries = try await fetchEntries(key: key)
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    /// 根据媒体源类型调用 MediaBrowser JSON 或 Plex XML 客户端。
    /// - Parameter key: 当前目录标识。
    /// - Returns: 统一媒体条目列表。
    private func fetchEntries(key: String?) async throws -> [MediaSourceEntry] {
        if profile.kind == .plex {
            return try await plexClient.items(profile: profile, navigationKey: key)
        }
        if profile.kind == .synology {
            return try await SynologyFileStationClient().items(profile: profile, parentPath: key)
        }
        return try await mediaBrowserClient.items(profile: profile, parentID: key)
    }
}

private extension MediaSourceEntry {
    /// 把服务端类型转换成用户可读的中文分类。
    var typeLabel: String {
        switch type.lowercased() {
        case "movie": "电影"
        case "episode": "剧集"
        case "series", "show": "电视剧 / 动画"
        case "season": "季度"
        case "collectionfolder", "userview": "媒体库"
        default: isDirectory ? "文件夹" : "视频"
        }
    }
}

/// 下载带媒体服务器认证头的频道海报。
private struct MediaServerArtworkView: View {
    let url: URL?
    let headers: [String: String]
    let fallbackSymbol: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbol)
                    .foregroundStyle(KanataTheme.accent)
            }
        }
        .frame(width: 54, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .task(id: url) { await load() }
    }

    /// 下载海报并校验 HTTP 与图片数据。
    private func load() async {
        guard let url else { return }
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let value = UIImage(data: data) else { return }
        image = value
    }
}
