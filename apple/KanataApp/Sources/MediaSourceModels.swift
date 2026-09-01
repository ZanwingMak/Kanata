import Foundation

/// Kanata 可持久化的网络媒体源类型。
enum MediaSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case webDAV
    case jellyfin
    case emby
    case plex
    case synology

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webDAV: "WebDAV"
        case .jellyfin: "Jellyfin"
        case .emby: "Emby"
        case .plex: "Plex"
        case .synology: "群晖 DSM"
        }
    }

    var symbol: String {
        switch self {
        case .webDAV: "externaldrive.connected.to.line.below"
        case .jellyfin: "play.tv"
        case .emby: "rectangle.stack.badge.play"
        case .plex: "play.square.stack"
        case .synology: "externaldrive.badge.wifi"
        }
    }

    var defaultPortHint: String {
        switch self {
        case .webDAV: "http://nas.local:5005"
        case .jellyfin: "http://nas.local:8096"
        case .emby: "http://nas.local:8096"
        case .plex: "http://nas.local:32400"
        case .synology: "https://nas.local:5001"
        }
    }
}

/// 首页频道和添加媒体源历史中展示的一条服务器连接。
struct MediaSourceProfile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var kind: MediaSourceKind
    var name: String
    var serverURLString: String
    var username: String
    var rootPath: String?
    let credentialAccount: String
    var updatedAt: Date

    /// 返回规范化的服务器根地址。
    var serverURL: URL? { URL(string: serverURLString) }

    /// 返回用于频道卡片的服务器主机说明。
    var subtitle: String {
        let host = serverURL?.host ?? serverURLString
        return username.isEmpty ? host : "\(username) · \(host)"
    }
}

/// 网络媒体源的敏感信息，只编码进 Keychain。
struct MediaSourceSecret: Codable, Sendable {
    var password: String?
    var token: String?
    var userID: String?
}

/// 网络媒体源历史记录；元数据存 UserDefaults，密码和令牌存 Keychain。
enum MediaSourceProfileStore {
    private static let storageKey = "media.source.profiles.v1"

    /// 读取按最近使用时间排序的全部连接记录。
    /// - Returns: 无记录或数据损坏时返回空数组。
    static func load() -> [MediaSourceProfile] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profiles = try? JSONDecoder().decode([MediaSourceProfile].self, from: data) else {
            return []
        }
        return profiles.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 保存或更新一条连接，并把敏感信息写入对应 Keychain 项。
    /// - Parameters:
    ///   - kind: 媒体源类型。
    ///   - name: 用户可见的频道名称。
    ///   - serverURL: 已规范化的服务器地址。
    ///   - username: 登录用户名，Plex 可为空。
    ///   - rootPath: WebDAV 起始路径。
    ///   - secret: 密码、访问令牌和媒体服务器用户 ID。
    /// - Returns: 可直接加入首页的媒体源配置。
    static func upsert(
        kind: MediaSourceKind,
        name: String,
        serverURL: URL,
        username: String,
        rootPath: String? = nil,
        secret: MediaSourceSecret
    ) -> MediaSourceProfile {
        var profiles = load()
        let normalizedServer = normalizedServerString(serverURL)
        let existingIndex = profiles.firstIndex {
            $0.kind == kind
                && $0.serverURLString.caseInsensitiveCompare(normalizedServer) == .orderedSame
                && $0.username.caseInsensitiveCompare(username) == .orderedSame
        }
        let id = existingIndex.map { profiles[$0].id } ?? UUID().uuidString
        let account = existingIndex.map { profiles[$0].credentialAccount }
            ?? "media.source.\(kind.rawValue).\(UUID().uuidString)"
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = MediaSourceProfile(
            id: id,
            kind: kind,
            name: displayName.isEmpty ? kind.title : displayName,
            serverURLString: normalizedServer,
            username: username,
            rootPath: rootPath,
            credentialAccount: account,
            updatedAt: Date()
        )
        if let data = try? JSONEncoder().encode(secret) {
            KeychainStore.set(data, account: account)
        }
        if let existingIndex {
            profiles[existingIndex] = profile
        } else {
            profiles.append(profile)
        }
        persist(profiles)
        return profile
    }

    /// 编辑已保存媒体源的可见名称、地址和账号，并在需要时替换 Keychain 凭证。
    /// - Parameters:
    ///   - profile: 原媒体源配置。
    ///   - name: 新显示名称。
    ///   - serverURL: 新服务器地址。
    ///   - username: 新用户名。
    ///   - rootPath: WebDAV 新起始目录。
    ///   - secret: 新凭证；传 nil 时沿用原 Keychain 内容。
    /// - Returns: 保持原 ID 的更新后配置。
    static func update(
        _ profile: MediaSourceProfile,
        name: String,
        serverURL: URL,
        username: String,
        rootPath: String?,
        secret: MediaSourceSecret?
    ) -> MediaSourceProfile {
        var profiles = load()
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = MediaSourceProfile(
            id: profile.id,
            kind: profile.kind,
            name: displayName.isEmpty ? profile.kind.title : displayName,
            serverURLString: normalizedServerString(serverURL),
            username: username,
            rootPath: rootPath,
            credentialAccount: profile.credentialAccount,
            updatedAt: Date()
        )
        if let secret, let data = try? JSONEncoder().encode(secret) {
            KeychainStore.set(data, account: profile.credentialAccount)
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = updated
        } else {
            profiles.append(updated)
        }
        persist(profiles)
        return updated
    }

    /// 更新媒体源最近使用时间，让常用频道排在前面。
    /// - Parameter profile: 刚刚打开的媒体源。
    static func touch(_ profile: MediaSourceProfile) {
        var profiles = load()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].updatedAt = Date()
        persist(profiles)
    }

    /// 删除连接历史和对应 Keychain 凭证，不删除已经加入媒体库的视频。
    /// - Parameter profile: 要删除的媒体源。
    static func remove(_ profile: MediaSourceProfile) {
        var profiles = load()
        profiles.removeAll { $0.id == profile.id }
        persist(profiles)
        KeychainStore.remove(account: profile.credentialAccount)
    }

    /// 从 Keychain 解码指定媒体源的登录信息。
    /// - Parameter profile: 媒体源配置。
    /// - Returns: 凭证不存在或损坏时返回 nil。
    static func secret(for profile: MediaSourceProfile) -> MediaSourceSecret? {
        KeychainStore.data(account: profile.credentialAccount)
            .flatMap { try? JSONDecoder().decode(MediaSourceSecret.self, from: $0) }
    }

    /// 按稳定 ID 查找首页频道配置。
    /// - Parameter id: LibraryItem 保存的媒体源 ID。
    /// - Returns: 历史记录已删除时返回 nil。
    static func profile(id: String) -> MediaSourceProfile? {
        load().first { $0.id == id }
    }

    /// 生成 AVURLAsset 播放该媒体源时需要的认证请求头。
    /// - Parameter profile: 视频所属媒体源。
    /// - Returns: WebDAV Basic、MediaBrowser 或 Plex 请求头。
    static func playbackHeaders(for profile: MediaSourceProfile) -> [String: String] {
        guard let secret = secret(for: profile) else { return [:] }
        switch profile.kind {
        case .webDAV:
            guard !profile.username.isEmpty, let password = secret.password else { return [:] }
            let value = Data("\(profile.username):\(password)".utf8).base64EncodedString()
            return ["Authorization": "Basic \(value)"]
        case .jellyfin, .emby:
            guard let token = secret.token, !token.isEmpty else { return [:] }
            return [
                "X-Emby-Token": token,
                "X-Emby-Authorization": mediaBrowserAuthorization(token: token),
            ]
        case .plex:
            guard let token = secret.token, !token.isEmpty else { return [:] }
            return [
                "X-Plex-Token": token,
                "X-Plex-Client-Identifier": "com.kanata.app",
                "X-Plex-Product": "Kanata",
                "X-Plex-Version": "0.1.0",
            ]
        case .synology:
            return [:]
        }
    }

    /// 生成 Jellyfin 与 Emby 通用的 MediaBrowser 授权头。
    /// - Parameter token: 可选访问令牌。
    /// - Returns: 服务端识别客户端所需的授权字符串。
    static func mediaBrowserAuthorization(token: String? = nil) -> String {
        var value = "MediaBrowser Client=\"Kanata\", Device=\"Apple\", DeviceId=\"kanata-apple\", Version=\"0.1.0\""
        if let token { value += ", Token=\"\(token)\"" }
        return value
    }

    /// 去掉服务器地址末尾斜杠，避免拼接 API 时产生双斜杠。
    /// - Parameter url: 用户输入的服务器地址。
    /// - Returns: 可稳定比较和保存的地址字符串。
    private static func normalizedServerString(_ url: URL) -> String {
        let value = url.absoluteString
        return value.count > 1
            ? value.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
            : value
    }

    /// 编码并持久化媒体源元数据。
    /// - Parameter profiles: 最新连接列表。
    private static func persist(_ profiles: [MediaSourceProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
