import Foundation
import KanataRender
import Observation

extension Notification.Name {
    static let kanataCloudDataDidChange = Notification.Name("kanata.cloud.dataDidChange")
}

/// iCloud KVS 中保存的非敏感轻量同步快照。
private struct CloudSyncPayload: Codable {
    let version: Int
    let updatedAt: Date
    let playbackProgress: Data?
    let collectionLayouts: Data?
    let danmakuOffsets: Data?
    let favoriteIDs: [String]
    let danmakuConfig: DanmakuRenderConfig?
}

/// 在 iPhone、iPad 与 Apple TV 间同步播放状态和显示偏好。
@MainActor
@Observable
final class CloudSyncStore {
    static let shared = CloudSyncStore()

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: enabledKey)
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
    private let payloadKey = "kanata.sync.payload.v1"
    private let localUpdatedAtKey = "icloud.sync.localUpdatedAt.v1"
    private let lastSyncAtKey = "icloud.sync.lastSyncAt.v1"
    private var isApplyingCloudValue = false
    private var pushTask: Task<Void, Never>?
    private var notificationToken: NSObjectProtocol?

    /// 初始化同步状态并监听其他设备写入的 KVS 变化。
    private init() {
        isEnabled = defaults.bool(forKey: enabledKey)
        let lastSyncValue = defaults.double(forKey: lastSyncAtKey)
        lastSyncAt = lastSyncValue > 0 ? Date(timeIntervalSince1970: lastSyncValue) : nil
        notificationToken = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.pullIfNewer() }
        }
    }

    /// 绑定应用设置，并在已启用时安排启动同步。
    /// - Parameter settings: 当前应用设置实例。
    func configure(settings: AppSettings) {
        self.settings = settings
        guard isEnabled else { return }
        Task { await syncNow() }
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

    /// 立即执行一次双向同步，较新的快照优先。
    func syncNow() async {
        guard isEnabled, !isSyncing else { return }
        isSyncing = true
        statusMessage = "正在同步 iCloud…"
        defer { isSyncing = false }
        cloudStore.synchronize()
        await pullIfNewer()
        await pushCurrentSnapshot()
    }

    /// 从云端应用比本机更新的快照。
    private func pullIfNewer() async {
        guard isEnabled,
              let data = cloudStore.data(forKey: payloadKey),
              let payload = try? JSONDecoder().decode(CloudSyncPayload.self, from: data) else { return }
        let localUpdatedAt = Date(timeIntervalSince1970: defaults.double(forKey: localUpdatedAtKey))
        guard payload.updatedAt > localUpdatedAt else { return }
        isApplyingCloudValue = true
        PlaybackProgressStore.importData(payload.playbackProgress)
        CollectionLayoutStore.importData(payload.collectionLayouts)
        OffsetStore.importData(payload.danmakuOffsets)
        LibraryFavoriteStore.applyCloudValue(Set(payload.favoriteIDs))
        if let config = payload.danmakuConfig {
            settings?.danmakuConfig = config
        }
        isApplyingCloudValue = false
        defaults.set(payload.updatedAt.timeIntervalSince1970, forKey: localUpdatedAtKey)
        rememberSync(at: Date())
        statusMessage = "已从 iCloud 更新播放状态"
        NotificationCenter.default.post(name: .kanataCloudDataDidChange, object: nil)
    }

    /// 把本机最新非敏感资料写入 iCloud KVS。
    private func pushCurrentSnapshot() async {
        guard isEnabled else { return }
        let now = Date()
        let payload = CloudSyncPayload(
            version: 1,
            updatedAt: now,
            playbackProgress: PlaybackProgressStore.exportData(),
            collectionLayouts: CollectionLayoutStore.exportData(),
            danmakuOffsets: OffsetStore.exportData(),
            favoriteIDs: Array(LibraryFavoriteStore.load()).sorted(),
            danmakuConfig: settings?.danmakuConfig
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            statusMessage = "iCloud 同步失败：无法编码同步资料"
            return
        }
        cloudStore.set(data, forKey: payloadKey)
        guard cloudStore.synchronize() else {
            statusMessage = "iCloud 暂不可用，请确认系统已登录 iCloud"
            return
        }
        defaults.set(now.timeIntervalSince1970, forKey: localUpdatedAtKey)
        rememberSync(at: now)
        statusMessage = "已同步到 iCloud"
    }

    /// 保存最近同步时间。
    /// - Parameter date: 同步完成时间。
    private func rememberSync(at date: Date) {
        lastSyncAt = date
        defaults.set(date.timeIntervalSince1970, forKey: lastSyncAtKey)
    }
}
