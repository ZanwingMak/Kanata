import Foundation
import KanataCore
import KanataRender
import Observation
import Security

/// 应用级设置。M0 用 UserDefaults 持久化，后续接入 iCloud 同步（FR-SET-004）。
@Observable
final class AppSettings {
    /// 网关地址，例如 http://192.168.1.7:9321
    var gatewayURLString: String {
        didSet { defaults.set(gatewayURLString, forKey: Keys.gatewayURL) }
    }

    /// 网关访问令牌
    var gatewayToken: String {
        didSet { KeychainStore.setString(gatewayToken, account: KeychainAccounts.gatewayToken) }
    }

    /// B 站登录 Cookie 中的核心会话字段。
    var bilibiliSESSDATA: String { didSet { persistBilibiliCredential() } }
    var bilibiliJct: String { didSet { persistBilibiliCredential() } }
    var bilibiliUserID: String { didSet { persistBilibiliCredential() } }
    var bilibiliBuvid3: String { didSet { persistBilibiliCredential() } }

    /// 弹幕渲染配置，播放页直接读写
    var danmakuConfig: DanmakuRenderConfig {
        didSet { persistDanmakuConfig() }
    }

    /// 在线弹幕设备缓存上限，单位 MB。
    var onlineDanmakuCacheLimitMB: Int {
        didSet { defaults.set(onlineDanmakuCacheLimitMB, forKey: Keys.onlineDanmakuCacheLimitMB) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let gatewayURL = "gateway.url"
        static let gatewayToken = "gateway.token"
        static let fontScale = "danmaku.fontScale"
        static let opacity = "danmaku.opacity"
        static let displayArea = "danmaku.displayArea"
        static let scrollDuration = "danmaku.scrollDuration"
        static let enabled = "danmaku.enabled"
        static let onlineDanmakuCacheLimitMB = "danmaku.onlineCacheLimitMB"
    }

    private enum KeychainAccounts {
        static let gatewayToken = "gateway.token"
        static let bilibiliCredential = "credential.bilibili"
    }

    private struct StoredBilibiliCredential: Codable {
        let SESSDATA: String
        let biliJct: String
        let userID: String
        let buvid3: String
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.gatewayURLString = defaults.string(forKey: Keys.gatewayURL) ?? "http://127.0.0.1:9321"
        let legacyGatewayToken = defaults.string(forKey: Keys.gatewayToken)
        self.gatewayToken = KeychainStore.string(account: KeychainAccounts.gatewayToken)
            ?? legacyGatewayToken
            ?? "87654321"
        let storedCredential = KeychainStore.data(account: KeychainAccounts.bilibiliCredential)
            .flatMap { try? JSONDecoder().decode(StoredBilibiliCredential.self, from: $0) }
        self.bilibiliSESSDATA = storedCredential?.SESSDATA ?? ""
        self.bilibiliJct = storedCredential?.biliJct ?? ""
        self.bilibiliUserID = storedCredential?.userID ?? ""
        self.bilibiliBuvid3 = storedCredential?.buvid3 ?? ""
        self.onlineDanmakuCacheLimitMB = max(
            defaults.object(forKey: Keys.onlineDanmakuCacheLimitMB) as? Int ?? 250,
            50
        )

        var config = DanmakuRenderConfig()
        if let scale = defaults.object(forKey: Keys.fontScale) as? Double { config.fontScale = scale }
        if let opacity = defaults.object(forKey: Keys.opacity) as? Double { config.opacity = opacity }
        if let area = defaults.string(forKey: Keys.displayArea),
           let parsed = DanmakuDisplayArea(rawValue: area) { config.displayArea = parsed }
        if let duration = defaults.object(forKey: Keys.scrollDuration) as? Double { config.scrollDuration = duration }
        if let enabled = defaults.object(forKey: Keys.enabled) as? Bool { config.enabled = enabled }
        self.danmakuConfig = config

        if let legacyGatewayToken {
            KeychainStore.setString(legacyGatewayToken, account: KeychainAccounts.gatewayToken)
            defaults.removeObject(forKey: Keys.gatewayToken)
        }
    }

    /// 按当前设置构建网关客户端，地址非法时返回 nil
    func makeClient() -> GatewayClient? {
        guard let url = URL(string: gatewayURLString), url.scheme != nil else { return nil }
        var credential: [String: [String: String]]?
        if !bilibiliSESSDATA.isEmpty {
            credential = [
                "bilibili": [
                    "SESSDATA": bilibiliSESSDATA,
                    "bili_jct": bilibiliJct,
                    "DedeUserID": bilibiliUserID,
                    "buvid3": bilibiliBuvid3,
                ].filter { !$0.value.isEmpty },
            ]
        }
        return GatewayClient(baseURL: url, token: gatewayToken, credential: credential)
    }

    /// 当前设备是否已保存 B 站会话凭证。
    var hasBilibiliCredential: Bool { !bilibiliSESSDATA.isEmpty }

    /// 从完整 Cookie 文本提取并保存 B 站必要字段。
    @discardableResult
    func importBilibiliCookie(_ cookie: String) -> Bool {
        var fields: [String: String] = [:]
        for component in cookie.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            fields[String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines)] = String(pair[1])
        }
        guard let sessdata = fields["SESSDATA"], !sessdata.isEmpty else { return false }
        bilibiliSESSDATA = sessdata
        bilibiliJct = fields["bili_jct"] ?? ""
        bilibiliUserID = fields["DedeUserID"] ?? ""
        bilibiliBuvid3 = fields["buvid3"] ?? ""
        return true
    }

    /// 清除当前设备保存的全部 B 站会话字段。
    func clearBilibiliCredential() {
        bilibiliSESSDATA = ""
        bilibiliJct = ""
        bilibiliUserID = ""
        bilibiliBuvid3 = ""
        KeychainStore.remove(account: KeychainAccounts.bilibiliCredential)
    }

    /// 把弹幕配置中需要跨会话保留的项写入存储
    private func persistDanmakuConfig() {
        defaults.set(danmakuConfig.fontScale, forKey: Keys.fontScale)
        defaults.set(danmakuConfig.opacity, forKey: Keys.opacity)
        defaults.set(danmakuConfig.displayArea.rawValue, forKey: Keys.displayArea)
        defaults.set(danmakuConfig.scrollDuration, forKey: Keys.scrollDuration)
        defaults.set(danmakuConfig.enabled, forKey: Keys.enabled)
    }

    /// 把 B 站会话字段编码后写入 Keychain；SESSDATA 为空时删除记录。
    private func persistBilibiliCredential() {
        guard !bilibiliSESSDATA.isEmpty else {
            KeychainStore.remove(account: KeychainAccounts.bilibiliCredential)
            return
        }
        let credential = StoredBilibiliCredential(
            SESSDATA: bilibiliSESSDATA,
            biliJct: bilibiliJct,
            userID: bilibiliUserID,
            buvid3: bilibiliBuvid3
        )
        guard let data = try? JSONEncoder().encode(credential) else { return }
        KeychainStore.set(data, account: KeychainAccounts.bilibiliCredential)
    }
}

/// Apple 平台本地 Keychain 最小封装，凭证不可同步到 iCloud。
private enum KeychainStore {
    private static let service = "com.kanata.app.credentials"

    /// 读取指定账号的原始凭证数据。
    static func data(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// 读取指定账号的 UTF-8 字符串。
    static func string(account: String) -> String? {
        data(account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 保存 UTF-8 字符串；空值会删除对应记录。
    static func setString(_ value: String, account: String) {
        guard !value.isEmpty, let data = value.data(using: .utf8) else {
            remove(account: account)
            return
        }
        set(data, account: account)
    }

    /// 更新或新增指定账号的凭证数据。
    static func set(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    /// 删除指定账号的 Keychain 记录。
    static func remove(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 弹幕偏移的持久化（FR-SYNC-002）。
/// M0 支持剧集与全局两级，键由解析出的剧名与季集号构成。
enum OffsetStore {
    private static let key = "danmaku.offsets"

    /// 读取某个剧集的偏移，没有记录时回落到全局值
    static func offset(seriesKey: String, seasonKey: String) -> Double {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return map[seasonKey] ?? map[seriesKey] ?? map["global"] ?? 0
    }

    /// 保存某个季的偏移，同季其他集自动继承
    static func save(offset: Double, seasonKey: String) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        map[seasonKey] = offset
        UserDefaults.standard.set(map, forKey: key)
    }
}
