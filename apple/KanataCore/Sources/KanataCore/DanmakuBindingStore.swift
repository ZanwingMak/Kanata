import Foundation

/// 用户已确认或成功使用的弹幕匹配绑定，只保存在当前设备。
public enum DanmakuBindingStore {
    private static let storageKey = "kanata.danmaku.bindings.v1"

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
