import Foundation

/// 用户成功使用并确认的作品搜索词与平台来源；分集仍按当前视频重新查找。
public struct ConfirmedDanmakuMatch: Codable, Sendable {
    public let searchTitle: String
    public let candidate: ProviderCandidate

    /// 创建作品级确认记录，不把已选择的集号作为后续分集的搜索条件。
    public init(searchTitle: String, candidate: ProviderCandidate) {
        self.searchTitle = searchTitle
        self.candidate = candidate
    }

    /// 仅接受同一平台实例与作品，允许标题中的集号变化，但不跨季或年份复用。
    public func matches(_ result: ProviderCandidate) -> Bool {
        guard result.source == candidate.source,
              result.sourceInstanceId == candidate.sourceInstanceId else { return false }
        let expected = TitleParser.parse(candidate.title)
        let actual = TitleParser.parse(result.title)
        return !expected.title.isEmpty && actual.title == expected.title
            && actual.season == expected.season && actual.year == expected.year
    }
}

/// 用户已确认或成功使用的弹幕匹配绑定，只保存在当前设备。
public enum DanmakuBindingStore {
    private static let storageKey = "kanata.danmaku.bindings.v1"

    /// 读取同一合集或单个视频此前手动搜索的作品名。
    public static func searchTitle(for mediaKey: String) -> String? {
        UserDefaults.standard.string(forKey: "kanata.danmaku.searchTitle.v1.\(mediaKey)")
    }

    /// 保存作品级搜索名称，供后续分集使用自己的季集号重新匹配。
    public static func saveSearchTitle(_ title: String, for mediaKey: String) {
        UserDefaults.standard.set(title, forKey: "kanata.danmaku.searchTitle.v1.\(mediaKey)")
    }

    /// 读取同一合集季度或电影的手动确认记录，旧的未确认搜索词不自动升级为绑定。
    public static func confirmedMatch(for mediaKey: String) -> ConfirmedDanmakuMatch? {
        guard let data = UserDefaults.standard.data(forKey: "kanata.danmaku.confirmedMatch.v1.\(mediaKey)") else { return nil }
        return try? JSONDecoder().decode(ConfirmedDanmakuMatch.self, from: data)
    }

    /// 成功加载用户选择的来源后保存确认记录，搜索失败或只输入关键词不会覆盖它。
    public static func saveConfirmedMatch(_ match: ConfirmedDanmakuMatch, for mediaKey: String) {
        guard let data = try? JSONEncoder().encode(match) else { return }
        UserDefaults.standard.set(data, forKey: "kanata.danmaku.confirmedMatch.v1.\(mediaKey)")
    }

    /// 解除手动作品偏好，让后续播放恢复默认自动匹配。
    public static func removeConfirmedMatch(for mediaKey: String) {
        UserDefaults.standard.removeObject(forKey: "kanata.danmaku.confirmedMatch.v1.\(mediaKey)")
    }

    /// 根据视频指纹读取已保存的候选；没有绑定或数据损坏时返回 nil。
    public static func candidate(for fingerprint: MediaFingerprint) -> ProviderCandidate? {
        loadAll()[key(for: fingerprint)]
    }

    /// 保存一次已成功加载弹幕的匹配结果，下次播放同一文件时直接复用。
    public static func save(_ candidate: ProviderCandidate, for fingerprint: MediaFingerprint) {
        var bindings = loadAll()
        bindings[key(for: fingerprint)] = candidate
        persist(bindings)
    }

    /// 删除指定视频指纹的绑定；当前已加载弹幕不受影响。
    public static func remove(for fingerprint: MediaFingerprint) {
        var bindings = loadAll()
        bindings.removeValue(forKey: key(for: fingerprint))
        persist(bindings)
    }

    /// 导出弹幕匹配绑定供 Apple 设备间同步。
    /// - Returns: 绑定表 JSON；编码失败时返回 nil。
    public static func exportData() -> Data? {
        try? JSONEncoder().encode(loadAll())
    }

    /// 用 iCloud 快照替换本机弹幕匹配绑定。
    /// - Parameter data: JSON 编码的绑定表。
    public static func importData(_ data: Data?) {
        guard let data,
              let bindings = try? JSONDecoder().decode([String: ProviderCandidate].self, from: data) else { return }
        persist(bindings)
    }

    /// 从 UserDefaults 解码全部绑定，读取失败时安全回退为空表。
    private static func loadAll() -> [String: ProviderCandidate] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let bindings = try? JSONDecoder().decode([String: ProviderCandidate].self, from: data) else {
            return [:]
        }
        return bindings
    }

    /// 编码并写入全部绑定，编码失败时保留已有数据。
    private static func persist(_ bindings: [String: ProviderCandidate]) {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// 使用前 16MB 指纹与文件大小组成稳定键，文件改名后仍能命中。
    private static func key(for fingerprint: MediaFingerprint) -> String {
        "\(fingerprint.fileHash):\(fingerprint.fileSize)"
    }
}
