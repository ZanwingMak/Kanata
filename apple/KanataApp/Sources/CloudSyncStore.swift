import Foundation
import KanataCore
import KanataRender
import Observation

extension Notification.Name {
    static let kanataCloudDataDidChange = Notification.Name("kanata.cloud.dataDidChange")
}

/// iCloud KVS 中保存的非敏感跨设备快照。
private struct CloudSyncPayload: Codable {
    let version: Int
    let updatedAt: Date
    let playbackProgress: Data?
    let collectionLayouts: Data?
    let danmakuOffsets: Data?
    let favoriteIDs: [String]
    let danmakuConfig: DanmakuRenderConfig?
    let mediaLibrary: Data?
    let mediaSourceProfiles: Data?
    let danmakuBindings: Data?
}

/// 在 iPhone、iPad 与 Apple TV 间同步媒体索引、播放状态和显示偏好。
@MainActor
@Observable
final class CloudSyncStore {
    static let shared = CloudSyncStore()

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: enabledKey)
            if !isApplyingCloudFlag {
                cloudStore.set(isEnabled, forKey: cloudEnabledKey)
                cloudStore.synchronize()
            }
            if isEnabled {
                Task { await syncNow() }
            } else {
                pushTask?.cancel()
                statusMessage = "iCloud 同步已关闭"
            }
        }
    }
    private(set) var statusMessage: String?
    private(set) var lastSyncAt: Date?
    private(set) var isSyncing = false

    private weak var settings: AppSettings?
    private let defaults = UserDefaults.standard
    private let cloudStore = NSUbiquitousKeyValueStore.default
    private let enabledKey = "icloud.sync.enabled.v1"
    private let cloudEnabledKey = "kanata.sync.enabled.v1"
    private let payloadKey = "kanata.sync.payload.v1"
    private let localUpdatedAtKey = "icloud.sync.localUpdatedAt.v1"
    private let lastSyncAtKey = "icloud.sync.lastSyncAt.v1"
    private var isApplyingCloudValue = false
    private var isApplyingCloudFlag = false
    private var pushTask: Task<Void, Never>?
    private var notificationToken: NSObjectProtocol?

    /// 初始化同步状态、请求 KVS 更新并监听其他设备写入。
    private init() {
        cloudStore.synchronize()
        if let localEnabled = defaults.object(forKey: enabledKey) as? Bool {
            isEnabled = localEnabled
        } else if cloudStore.object(forKey: cloudEnabledKey) != nil {
            isEnabled = cloudStore.bool(forKey: cloudEnabledKey)
        } else {
            isEnabled = false
        }
        let lastSyncValue = defaults.double(forKey: lastSyncAtKey)
        lastSyncAt = lastSyncValue > 0 ? Date(timeIntervalSince1970: lastSyncValue) : nil
        notificationToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            Task { @MainActor in
                await self?.handleExternalChange(reason: reason, changedKeys: changedKeys)
            }
        }
    }

    /// 绑定应用设置，并在云端开关刷新后安排启动同步。
    /// - Parameter settings: 当前应用设置实例。
    func configure(settings: AppSettings) {
        self.settings = settings
        Task { await reconcileCloudPreferenceAndSync() }
    }

    /// 启动后等待 KVS 返回云端开关，修复旧设备保留关闭状态而不再拉取的问题。
    private func reconcileCloudPreferenceAndSync() async {
        cloudStore.synchronize()
        try? await Task.sleep(for: .milliseconds(900))
        if cloudStore.object(forKey: cloudEnabledKey) != nil {
            let cloudEnabled = cloudStore.bool(forKey: cloudEnabledKey)
            if cloudEnabled != isEnabled {
                isApplyingCloudFlag = true
                isEnabled = cloudEnabled
                isApplyingCloudFlag = false
                return
            }
        }
        guard isEnabled else { return }
        await syncNow()
    }

    /// 记录本机发生了可同步变化，并在短暂防抖后上传。
    func noteLocalChange() {
        guard !isApplyingCloudValue else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: localUpdatedAtKey)
        guard isEnabled else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.pushCurrentSnapshot()
        }
    }

    /// 立即执行同步：先等待云端刷新，只有本机更新时才反向上传。
    func syncNow() async {
        guard isEnabled, !isSyncing, settings != nil else { return }
        isSyncing = true
        statusMessage = "正在从 iCloud 检查更新…"
        defer { isSyncing = false }
        cloudStore.synchronize()
        try? await Task.sleep(for: .milliseconds(900))
        if await pullIfNewer() { return }
        let localUpdatedAt = localModificationDate
        guard let cloudPayload = decodedCloudPayload() else {
            await pushCurrentSnapshot()
            return
        }
        if localUpdatedAt > cloudPayload.updatedAt {
            await pushCurrentSnapshot()
        } else {
            rememberSync(at: Date())
            statusMessage = "iCloud 数据已是最新"
        }
    }

    /// 处理 KVS 外部变化、同步开关与配额错误。
    /// - Parameters:
    ///   - reason: 系统提供的变更原因。
    ///   - changedKeys: 本次发生变化的 KVS 键。
    private func handleExternalChange(reason: Int?, changedKeys: [String]) async {
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            statusMessage = "iCloud 同步空间不足，请减少媒体库索引后重试"
            return
        }
        if changedKeys.isEmpty || changedKeys.contains(cloudEnabledKey),
           cloudStore.object(forKey: cloudEnabledKey) != nil {
            let cloudEnabled = cloudStore.bool(forKey: cloudEnabledKey)
            if cloudEnabled != isEnabled {
                isApplyingCloudFlag = true
                isEnabled = cloudEnabled
                isApplyingCloudFlag = false
            }
        }
        guard isEnabled else { return }
        _ = await pullIfNewer()
    }

    /// 从云端应用比本机更新的快照。
    /// - Returns: 成功应用了云端快照时返回 true。
    private func pullIfNewer() async -> Bool {
        guard isEnabled,
              let settings,
              let payload = decodedCloudPayload(),
              payload.updatedAt > localModificationDate else { return false }
        isApplyingCloudValue = true
        let profileIDMap = MediaSourceProfileStore.importCloudData(payload.mediaSourceProfiles)
        LibraryStore.importCloudData(payload.mediaLibrary, profileIDMap: profileIDMap)
        PlaybackProgressStore.importData(payload.playbackProgress)
        CollectionLayoutStore.importData(payload.collectionLayouts)
        OffsetStore.importData(payload.danmakuOffsets)
        DanmakuBindingStore.importData(payload.danmakuBindings)
        LibraryFavoriteStore.applyCloudValue(Set(payload.favoriteIDs))
        if let config = payload.danmakuConfig {
            settings.applyCloudDanmakuConfig(config)
        }
        isApplyingCloudValue = false
        defaults.set(payload.updatedAt.timeIntervalSince1970, forKey: localUpdatedAtKey)
        rememberSync(at: Date())
        let itemCount = LibraryStore.load().filter { $0.remoteURLString != nil }.count
        statusMessage = "已从 iCloud 更新 · \(itemCount) 个网络视频"
        NotificationCenter.default.post(name: .kanataCloudDataDidChange, object: nil)
        return true
    }

    /// 把本机最新非敏感资料写入 iCloud KVS。
    private func pushCurrentSnapshot() async {
        guard isEnabled else { return }
        let now = Date()
        let payload = CloudSyncPayload(
            version: 2,
            updatedAt: now,
            playbackProgress: PlaybackProgressStore.exportData(),
            collectionLayouts: CollectionLayoutStore.exportData(),
            danmakuOffsets: OffsetStore.exportData(),
            favoriteIDs: Array(LibraryFavoriteStore.load()).sorted(),
            danmakuConfig: settings?.danmakuConfig,
            mediaLibrary: LibraryStore.exportCloudData(),
            mediaSourceProfiles: MediaSourceProfileStore.exportCloudData(),
            danmakuBindings: DanmakuBindingStore.exportData()
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            statusMessage = "iCloud 同步失败：无法编码同步资料"
            return
        }
        guard data.count <= 900_000 else {
            statusMessage = "iCloud 同步资料过大，请减少网络媒体库条目"
            return
        }
        cloudStore.set(true, forKey: cloudEnabledKey)
        cloudStore.set(data, forKey: payloadKey)
        cloudStore.synchronize()
        defaults.set(now.timeIntervalSince1970, forKey: localUpdatedAtKey)
        rememberSync(at: now)
        let itemCount = LibraryStore.load().filter { $0.remoteURLString != nil }.count
        statusMessage = "已同步到 iCloud · \(itemCount) 个网络视频"
    }

    /// 解码当前设备已取得的 iCloud 快照。
    /// - Returns: 尚未取得数据或格式损坏时返回 nil。
    private func decodedCloudPayload() -> CloudSyncPayload? {
        guard let data = cloudStore.data(forKey: payloadKey) else { return nil }
        return try? JSONDecoder().decode(CloudSyncPayload.self, from: data)
    }

    /// 返回本机最后一次内容修改时间。
    private var localModificationDate: Date {
        Date(timeIntervalSince1970: defaults.double(forKey: localUpdatedAtKey))
    }

    /// 保存最近同步时间。
    /// - Parameter date: 同步完成时间。
    private func rememberSync(at date: Date) {
        lastSyncAt = date
        defaults.set(date.timeIntervalSince1970, forKey: lastSyncAtKey)
    }
}
