import Foundation
import KanataCore
import KanataRender
import Observation

/// 应用级设置。M0 用 UserDefaults 持久化，后续接入 iCloud 同步（FR-SET-004）。
@Observable
final class AppSettings {
    /// 网关地址，例如 http://192.168.1.7:9321
    var gatewayURLString: String {
        didSet { defaults.set(gatewayURLString, forKey: Keys.gatewayURL) }
    }

    /// 网关访问令牌
    var gatewayToken: String {
        didSet { defaults.set(gatewayToken, forKey: Keys.gatewayToken) }
    }

    /// 弹幕渲染配置，播放页直接读写
    var danmakuConfig: DanmakuRenderConfig {
        didSet { persistDanmakuConfig() }
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
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.gatewayURLString = defaults.string(forKey: Keys.gatewayURL) ?? "http://127.0.0.1:9321"
        self.gatewayToken = defaults.string(forKey: Keys.gatewayToken) ?? "87654321"

        var config = DanmakuRenderConfig()
        if let scale = defaults.object(forKey: Keys.fontScale) as? Double { config.fontScale = scale }
        if let opacity = defaults.object(forKey: Keys.opacity) as? Double { config.opacity = opacity }
        if let area = defaults.string(forKey: Keys.displayArea),
           let parsed = DanmakuDisplayArea(rawValue: area) { config.displayArea = parsed }
        if let duration = defaults.object(forKey: Keys.scrollDuration) as? Double { config.scrollDuration = duration }
        if let enabled = defaults.object(forKey: Keys.enabled) as? Bool { config.enabled = enabled }
        self.danmakuConfig = config
    }

    /// 按当前设置构建网关客户端，地址非法时返回 nil
    func makeClient() -> GatewayClient? {
        guard let url = URL(string: gatewayURLString), url.scheme != nil else { return nil }
        return GatewayClient(baseURL: url, token: gatewayToken)
    }

    /// 把弹幕配置中需要跨会话保留的项写入存储
    private func persistDanmakuConfig() {
        defaults.set(danmakuConfig.fontScale, forKey: Keys.fontScale)
        defaults.set(danmakuConfig.opacity, forKey: Keys.opacity)
        defaults.set(danmakuConfig.displayArea.rawValue, forKey: Keys.displayArea)
        defaults.set(danmakuConfig.scrollDuration, forKey: Keys.scrollDuration)
        defaults.set(danmakuConfig.enabled, forKey: Keys.enabled)
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
