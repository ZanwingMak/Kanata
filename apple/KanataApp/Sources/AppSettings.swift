import Foundation
import KanataCore
import KanataRender
import Observation
import Security

/// 应用级设置。使用 UserDefaults 持久化，非敏感播放偏好可通过 CloudSyncStore 同步。
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

    /// 无需部署网关即可使用的内置 B 站来源开关。
    var builtInBilibiliEnabled: Bool {
        didSet { defaults.set(builtInBilibiliEnabled, forKey: Keys.builtInBilibiliEnabled) }
    }

    /// 无需部署网关即可使用的爱奇艺、腾讯视频与巴哈姆特来源开关。
    var builtInPublicSourcesEnabled: Bool {
        didSet { defaults.set(builtInPublicSourcesEnabled, forKey: Keys.builtInPublicSourcesEnabled) }
    }

    /// 独立启用爱奇艺内置弹幕来源。
    var builtInIqiyiEnabled: Bool {
        didSet { defaults.set(builtInIqiyiEnabled, forKey: Keys.builtInIqiyiEnabled) }
    }

    /// 独立启用腾讯视频内置弹幕来源。
    var builtInQQEnabled: Bool {
        didSet { defaults.set(builtInQQEnabled, forKey: Keys.builtInQQEnabled) }
    }

    /// 独立启用巴哈姆特动画疯内置弹幕来源。
    var builtInBahamutEnabled: Bool {
        didSet { defaults.set(builtInBahamutEnabled, forKey: Keys.builtInBahamutEnabled) }
    }

    /// 低额度弹弹play开放平台备用来源，默认关闭以避免无意消耗配额。
    var builtInDandanplayEnabled: Bool {
        didSet { defaults.set(builtInDandanplayEnabled, forKey: Keys.builtInDandanplayEnabled) }
    }

    /// 全局强调色主题。
    var accentTheme: KanataAccentTheme {
        didSet { defaults.set(accentTheme.rawValue, forKey: Keys.accentTheme) }
    }

    /// 全局浅色、深色或跟随系统外观。
    var appearance: KanataAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

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
        static let fontName = "danmaku.fontName"
        static let opacity = "danmaku.opacity"
        static let displayArea = "danmaku.displayArea"
        static let scrollDuration = "danmaku.scrollDuration"
        static let enabled = "danmaku.enabled"
        static let bold = "danmaku.bold"
        static let strokeWidth = "danmaku.strokeWidth"
        static let lineSpacing = "danmaku.lineSpacing"
        static let visualStyleVersion = "danmaku.visualStyleVersion"
        static let densityLimit = "danmaku.densityLimit"
        static let mergeDuplicates = "danmaku.mergeDuplicates"
        static let blockColorful = "danmaku.blockColorful"
        static let blockRepeated = "danmaku.blockRepeated"
        static let blockKeywords = "danmaku.blockKeywords"
        static let onlineDanmakuCacheLimitMB = "danmaku.onlineCacheLimitMB"
        static let builtInBilibiliEnabled = "source.bilibili.builtInEnabled"
        static let builtInPublicSourcesEnabled = "source.public.builtInEnabled"
        static let builtInIqiyiEnabled = "source.iqiyi.builtInEnabled"
        static let builtInQQEnabled = "source.qq.builtInEnabled"
        static let builtInBahamutEnabled = "source.bahamut.builtInEnabled"
        static let builtInDandanplayEnabled = "source.dandanplay.builtInEnabled"
        static let accentTheme = KanataTheme.accentStorageKey
        static let appearance = "appearance.mode"
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
        self.gatewayURLString = defaults.string(forKey: Keys.gatewayURL) ?? ""
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
        self.builtInBilibiliEnabled = defaults.object(forKey: Keys.builtInBilibiliEnabled) as? Bool ?? true
        self.builtInPublicSourcesEnabled = defaults.object(forKey: Keys.builtInPublicSourcesEnabled) as? Bool ?? true
        self.builtInIqiyiEnabled = defaults.object(forKey: Keys.builtInIqiyiEnabled) as? Bool ?? true
        self.builtInQQEnabled = defaults.object(forKey: Keys.builtInQQEnabled) as? Bool ?? true
        self.builtInBahamutEnabled = defaults.object(forKey: Keys.builtInBahamutEnabled) as? Bool ?? true
        self.builtInDandanplayEnabled = defaults.object(forKey: Keys.builtInDandanplayEnabled) as? Bool ?? false
        self.accentTheme = KanataAccentTheme(
            rawValue: defaults.string(forKey: Keys.accentTheme) ?? ""
        ) ?? .galaxy
        self.appearance = KanataAppearance(
            rawValue: defaults.string(forKey: Keys.appearance) ?? ""
        ) ?? .system
        self.onlineDanmakuCacheLimitMB = max(
            defaults.object(forKey: Keys.onlineDanmakuCacheLimitMB) as? Int ?? 250,
            50
        )

        var config = DanmakuRenderConfig()
        if let scale = defaults.object(forKey: Keys.fontScale) as? Double { config.fontScale = scale }
        config.fontName = defaults.string(forKey: Keys.fontName)
        if let opacity = defaults.object(forKey: Keys.opacity) as? Double { config.opacity = opacity }
        if let area = defaults.string(forKey: Keys.displayArea),
           let parsed = DanmakuDisplayArea(rawValue: area) { config.displayArea = parsed }
        if let duration = defaults.object(forKey: Keys.scrollDuration) as? Double { config.scrollDuration = duration }
        if let enabled = defaults.object(forKey: Keys.enabled) as? Bool { config.enabled = enabled }
        if let bold = defaults.object(forKey: Keys.bold) as? Bool { config.bold = bold }
        if let stroke = defaults.object(forKey: Keys.strokeWidth) as? Double { config.strokeWidth = stroke }
        if let spacing = defaults.object(forKey: Keys.lineSpacing) as? Double { config.lineSpacing = spacing }
        if let density = defaults.object(forKey: Keys.densityLimit) as? Int { config.densityLimit = density }
        if let merge = defaults.object(forKey: Keys.mergeDuplicates) as? Bool { config.mergeDuplicates = merge }
        if let colorful = defaults.object(forKey: Keys.blockColorful) as? Bool {
            config.blockRules.blockColorful = colorful
        }
        if let repeated = defaults.object(forKey: Keys.blockRepeated) as? Bool {
            config.blockRules.blockRepeated = repeated
        }
        config.blockRules.keywords = defaults.stringArray(forKey: Keys.blockKeywords) ?? []
        let requiresVisualMigration = defaults.integer(forKey: Keys.visualStyleVersion) < 5
        if requiresVisualMigration {
            config.fontScale = 0.9
            config.opacity = 1
            config.scrollDuration = 9
            config.lineSpacing = 7
            config.bold = false
            config.strokeWidth = 0.6
            config.densityLimit = 100
        }
        self.danmakuConfig = config

        if let legacyGatewayToken {
            KeychainStore.setString(legacyGatewayToken, account: KeychainAccounts.gatewayToken)
            defaults.removeObject(forKey: Keys.gatewayToken)
        }
        if requiresVisualMigration {
            defaults.set(5, forKey: Keys.visualStyleVersion)
            persistDanmakuConfig()
        }
    }

    /// 按当前设置构建网关客户端，地址非法时返回 nil
    func makeClient() -> GatewayClient? {
        let value = gatewayURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        return GatewayClient(
            baseURL: url,
            token: gatewayToken,
            credential: credential,
            session: URLSession(configuration: configuration)
        )
    }

    /// 按当前凭证创建无需自建网关的内置 B 站客户端。
    /// - Returns: 用户关闭内置来源时返回 nil。
    func makeBuiltInBilibiliClient() -> BuiltInBilibiliClient? {
        guard builtInBilibiliEnabled else { return nil }
        return BuiltInBilibiliClient(cookie: bilibiliCookieHeader)
    }

    /// 创建无需网关的爱奇艺、腾讯视频与巴哈姆特弹幕客户端。
    /// - Returns: 用户关闭内置公共来源时返回 nil。
    func makeBuiltInPublicDanmakuClient() -> BuiltInPublicDanmakuClient? {
        guard builtInPublicSourcesEnabled else { return nil }
        var enabledSources = Set<DanmakuSourceId>()
        if builtInIqiyiEnabled { enabledSources.insert(.iqiyi) }
        if builtInQQEnabled { enabledSources.insert(.qq) }
        if builtInBahamutEnabled { enabledSources.insert(.bahamut) }
        guard !enabledSources.isEmpty else { return nil }
        return BuiltInPublicDanmakuClient(enabledSources: enabledSources)
    }

    /// 创建低额度弹弹play备用客户端；未启用或构建未注入密钥时返回 nil。
    /// - Returns: 已签名的开放平台客户端。
    func makeBuiltInDandanplayClient() -> BuiltInDandanplayClient? {
        guard builtInDandanplayEnabled else { return nil }
        return BuiltInDandanplayClient.configured()
    }

    /// 当前 App 构建是否已注入弹弹play开放平台凭证。
    var hasDandanplayConfiguration: Bool { BuiltInDandanplayClient.configured() != nil }

    /// 组装供内置来源使用的 B 站 Cookie，请求日志不会输出该值。
    private var bilibiliCookieHeader: String {
        [
            ("SESSDATA", bilibiliSESSDATA),
            ("bili_jct", bilibiliJct),
            ("DedeUserID", bilibiliUserID),
            ("buvid3", bilibiliBuvid3),
        ]
        .filter { !$0.1.isEmpty }
        .map { "\($0.0)=\($0.1)" }
        .joined(separator: "; ")
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
        if let fontName = danmakuConfig.fontName {
            defaults.set(fontName, forKey: Keys.fontName)
        } else {
            defaults.removeObject(forKey: Keys.fontName)
        }
        defaults.set(danmakuConfig.opacity, forKey: Keys.opacity)
        defaults.set(danmakuConfig.displayArea.rawValue, forKey: Keys.displayArea)
        defaults.set(danmakuConfig.scrollDuration, forKey: Keys.scrollDuration)
        defaults.set(danmakuConfig.enabled, forKey: Keys.enabled)
        defaults.set(danmakuConfig.bold, forKey: Keys.bold)
        defaults.set(danmakuConfig.strokeWidth, forKey: Keys.strokeWidth)
        defaults.set(danmakuConfig.lineSpacing, forKey: Keys.lineSpacing)
        defaults.set(danmakuConfig.densityLimit, forKey: Keys.densityLimit)
        defaults.set(danmakuConfig.mergeDuplicates, forKey: Keys.mergeDuplicates)
        defaults.set(danmakuConfig.blockRules.blockColorful, forKey: Keys.blockColorful)
        defaults.set(danmakuConfig.blockRules.blockRepeated, forKey: Keys.blockRepeated)
        defaults.set(danmakuConfig.blockRules.keywords, forKey: Keys.blockKeywords)
        Task { @MainActor in CloudSyncStore.shared.noteLocalChange() }
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
enum KeychainStore {
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
        Task { @MainActor in CloudSyncStore.shared.noteLocalChange() }
    }

    /// 导出所有剧集弹幕偏移。
    /// - Returns: JSON 编码失败时返回 nil。
    static func exportData() -> Data? {
        let map = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return try? JSONEncoder().encode(map)
    }

    /// 从 iCloud 快照替换弹幕偏移。
    /// - Parameter data: JSON 编码的偏移字典。
    static func importData(_ data: Data?) {
        guard let data,
              let map = try? JSONDecoder().decode([String: Double].self, from: data) else { return }
        UserDefaults.standard.set(map, forKey: key)
    }
}
