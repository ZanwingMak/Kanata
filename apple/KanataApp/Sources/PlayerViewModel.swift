import AVFoundation
import Foundation
import KanataCore
import Observation

/// 播放页状态机：打开文件 → 识别 → 匹配弹幕 → 播放。
/// M0 只覆盖本地文件与 AVPlayer 内核，VLCKit 兜底在 M1 接入（FR-PLY-001）。
@MainActor
@Observable
final class PlayerViewModel {

    enum LoadState: Equatable {
        case idle
        case preparing(String)
        case ready
        case failed(String)
    }

    private(set) var player: AVPlayer?
    private(set) var state: LoadState = .idle
    /// 在线与本地弹幕合并后的原始数据，偏移在客户端本地应用。
    private(set) var rawItems: [DanmakuItem] = []
    private(set) var candidates: [ProviderCandidate] = []
    private(set) var parsed: ParsedTitle?
    private(set) var danmakuStats: String = ""
    private(set) var currentBinding: ProviderCandidate?
    private(set) var localDanmakuFileName: String?
    private(set) var localDanmakuCount = 0
    /// 匹配到多个候选且置信度不足时，交由用户选择（FR-MATCH-003）
    var isShowingCandidates = false

    /// 弹幕整体偏移，正值表示弹幕延后（FR-SYNC-001）
    var offset: Double = 0 {
        didSet {
            let clampedOffset = TimelineResolver.clamp(offset)
            guard clampedOffset == offset else {
                offset = clampedOffset
                return
            }
            if let seasonKey { OffsetStore.save(offset: offset, seasonKey: seasonKey) }
            onItemsChanged?(shiftedItems)
        }
    }

    /// 弹幕列表变化时的回调，由播放页把数据交给渲染视图
    var onItemsChanged: (([DanmakuItem]) -> Void)?
    /// 播放时间变化时的回调
    var onTimeChanged: ((Double, Double) -> Void)?

    private var client: GatewayClient?
    private var timeObserver: Any?
    private var securityScopedURL: URL?
    private var seasonKey: String?
    private var localDuration: Double = 0
    private var currentFingerprint: MediaFingerprint?
    private var onlineItems: [DanmakuItem] = []
    private var localItems: [DanmakuItem] = []
    private var onlineCacheLimitBytes: Int64 = 250 * 1024 * 1024

    /// 当前视频是否已关联本地弹幕文件。
    var hasLocalDanmaku: Bool { !localItems.isEmpty }

    /// 应用偏移后的弹幕，供渲染层使用
    var shiftedItems: [DanmakuItem] {
        guard offset != 0 else { return rawItems }
        return rawItems.compactMap { item in
            let time = item.time + offset
            guard time >= 0 else { return nil }
            return DanmakuItem(
                id: item.id, time: time, mode: item.mode, fontSize: item.fontSize,
                color: item.color, content: item.content, source: item.source,
                senderHash: item.senderHash, createdAt: item.createdAt,
                weight: item.weight, dupCount: item.dupCount
            )
        }
    }

    /// 释放播放资源与文件访问权。
    /// Swift 6 的 nonisolated deinit 无法访问主线程隔离状态，改由播放页在消失时显式调用。
    func teardown() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player?.pause()
        player = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    /// 打开一个本地视频并尝试自动匹配弹幕
    /// - Parameters:
    ///   - url: 视频文件地址，来自文件选择器
    ///   - settings: 应用设置，提供网关配置
    func open(url: URL, settings: AppSettings) async {
        resetDanmakuState()
        state = .preparing("正在读取视频…")
        client = settings.makeClient()
        onlineCacheLimitBytes = Int64(settings.onlineDanmakuCacheLimitMB) * 1024 * 1024

        // 文件选择器返回的地址需要显式申请访问权（FR-IMP-001）
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            localDuration = duration.seconds.isFinite ? duration.seconds : 0
        } catch {
            state = .failed("无法读取视频信息：\(error.localizedDescription)")
            return
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        self.player = player
        installTimeObserver(on: player)
        state = .ready

        await matchDanmaku(url: url)
    }

    /// 识别文件并向网关请求候选
    private func matchDanmaku(url: URL) async {
        let parsedTitle = TitleParser.parse(url.lastPathComponent)
        parsed = parsedTitle
        seasonKey = "\(parsedTitle.title)|S\(parsedTitle.season ?? 1)"
        offset = OffsetStore.offset(
            seriesKey: parsedTitle.title,
            seasonKey: seasonKey ?? parsedTitle.title
        )

        danmakuStats = "正在匹配弹幕…"
        let fingerprint = try? FingerprintCalculator.compute(fileURL: url, duration: localDuration)
        currentFingerprint = fingerprint

        if let fingerprint {
            await loadPersistedLocalDanmaku(for: fingerprint)
        }

        let savedCandidate = fingerprint.flatMap { DanmakuBindingStore.candidate(for: $0) }
        currentBinding = savedCandidate

        guard let client else {
            if let fingerprint, let savedCandidate,
               await restoreCachedDanmaku(for: savedCandidate, fingerprint: fingerprint) {
                return
            }
            danmakuStats = localItems.isEmpty
                ? "未配置网关地址，可导入本地弹幕"
                : "\(localItems.count) 条本地弹幕 · 离线可用"
            return
        }

        if let fingerprint, let savedCandidate {
            danmakuStats = "正在加载已保存的弹幕匹配…"
            if await loadDanmaku(for: savedCandidate, persistBinding: false) {
                return
            }
            if await restoreCachedDanmaku(for: savedCandidate, fingerprint: fingerprint) {
                return
            }
            isShowingCandidates = false
            danmakuStats = "已保存来源不可用，正在重新匹配…"
        }

        do {
            let response = try await client.resolve(
                ResolveRequest(
                    title: parsedTitle.title,
                    season: parsedTitle.season,
                    episode: parsedTitle.isCollection ? nil : parsedTitle.episode,
                    duration: localDuration,
                    fingerprint: fingerprint
                )
            )
            candidates = response.candidates
            guard let best = response.candidates.first else {
                let message = response.degraded.isEmpty
                    ? "未匹配到弹幕，可手动搜索"
                    : "未匹配到弹幕（\(response.degraded.map(\.displayName).joined(separator: "、")) 不可用）"
                danmakuStats = failureMessage(message)
                isShowingCandidates = true
                return
            }
            // 置信度足够高时直接采用，否则让用户确认
            if best.confidence >= 0.9 {
                await loadDanmaku(for: best)
            } else {
                danmakuStats = "找到 \(response.candidates.count) 个候选，请选择"
                isShowingCandidates = true
            }
        } catch let error as GatewayError {
            let message = error.requiresLogin ? "需要登录后才能获取弹幕" : "匹配失败：\(error.errorMessage)"
            danmakuStats = failureMessage(message)
            isShowingCandidates = true
        } catch {
            danmakuStats = failureMessage("匹配失败：\(error.localizedDescription)")
            isShowingCandidates = true
        }
    }

    /// 拉取指定候选的弹幕，并在成功后保存文件指纹绑定。
    /// - Parameters:
    ///   - candidate: 用户选择或自动命中的平台候选
    ///   - persistBinding: 是否保存为下次播放优先使用的绑定
    /// - Returns: 是否成功获得弹幕响应
    @discardableResult
    func loadDanmaku(
        for candidate: ProviderCandidate,
        persistBinding: Bool = true
    ) async -> Bool {
        guard let client else { return false }
        danmakuStats = "正在加载弹幕…"
        do {
            let response = try await client.danmaku(
                refs: [DanmakuRef(source: candidate.source, platformEpisodeId: candidate.platformEpisodeId)]
            )
            onlineItems = response.items
            rebuildRawItems()
            if persistBinding, let currentFingerprint {
                DanmakuBindingStore.save(candidate, for: currentFingerprint)
            }
            if let currentFingerprint {
                try? await DanmakuCacheStore.shared.save(
                    items: response.items,
                    candidate: candidate,
                    for: currentFingerprint,
                    maximumBytes: onlineCacheLimitBytes
                )
            }
            currentBinding = candidate
            isShowingCandidates = false
            // 本地与平台时长差异较大时提示用户校正（FR-SYNC-003）
            let hint = shouldHintTimeline(remote: candidate.duration) ? "，时长差异较大建议校正" : ""
            let fallback = response.degraded.contains { $0.source == candidate.source }
                ? " · 缓存兜底"
                : ""
            let count = localItems.isEmpty
                ? "\(response.items.count) 条"
                : "\(response.items.count) 条在线 + \(localItems.count) 条本地"
            let sourceName = candidate.sourceInstanceName ?? candidate.source.displayName
            danmakuStats = "\(count) · \(sourceName) · \(response.stats.elapsedMs)ms\(fallback)\(hint)"
            return true
        } catch let error as GatewayError {
            danmakuStats = failureMessage("弹幕加载失败：\(error.errorMessage)")
        } catch {
            danmakuStats = failureMessage("弹幕加载失败：\(error.localizedDescription)")
        }
        isShowingCandidates = true
        return false
    }

    /// 导入本地弹幕并按当前视频指纹持久化。
    func importLocalDanmaku(data: Data, fileName: String) async throws {
        guard let currentFingerprint else {
            throw LocalDanmakuError.invalidData("视频尚未完成识别，请稍后重试")
        }
        let items = try await Task.detached(priority: .userInitiated) {
            try LocalDanmakuParser.parse(data: data, fileName: fileName)
        }.value
        try await LocalDanmakuStore.shared.save(
            items: items,
            fileName: fileName,
            for: currentFingerprint
        )
        localItems = items
        localDanmakuFileName = fileName
        localDanmakuCount = items.count
        rebuildRawItems()
        danmakuStats = onlineItems.isEmpty
            ? "已导入 \(items.count) 条本地弹幕"
            : "\(onlineItems.count) 条在线 + \(items.count) 条本地"
    }

    /// 移除当前视频关联的本地弹幕文件与已加载数据。
    func removeLocalDanmaku() async throws {
        guard let currentFingerprint else { return }
        try await LocalDanmakuStore.shared.remove(for: currentFingerprint)
        localItems = []
        localDanmakuFileName = nil
        localDanmakuCount = 0
        rebuildRawItems()
        danmakuStats = onlineItems.isEmpty
            ? "已移除本地弹幕"
            : "\(onlineItems.count) 条在线弹幕"
    }

    /// 删除当前视频保存的在线来源绑定，下次播放将重新自动匹配。
    func removeCurrentBinding() {
        guard let currentFingerprint else { return }
        DanmakuBindingStore.remove(for: currentFingerprint)
        currentBinding = nil
        danmakuStats = "已解除绑定，当前弹幕继续播放"
    }

    /// 判断本地时长与平台时长是否差异过大
    private func shouldHintTimeline(remote: Double?) -> Bool {
        guard let remote, remote > 0, localDuration > 0 else { return false }
        return abs(localDuration - remote) / localDuration > 0.05
    }

    /// 手动搜索并刷新候选列表
    func search(keyword: String) async {
        guard let client else { return }
        danmakuStats = "正在搜索…"
        do {
            let response = try await client.resolve(
                ResolveRequest(title: keyword, episode: parsed?.episode, duration: localDuration)
            )
            candidates = response.candidates
            danmakuStats = "找到 \(response.candidates.count) 个候选"
        } catch {
            danmakuStats = "搜索失败：\(error.localizedDescription)"
        }
    }

    /// 读取当前视频此前导入的本地弹幕归档。
    private func loadPersistedLocalDanmaku(for fingerprint: MediaFingerprint) async {
        do {
            guard let archive = try await LocalDanmakuStore.shared.load(for: fingerprint) else { return }
            localItems = archive.items
            localDanmakuFileName = archive.fileName
            localDanmakuCount = archive.items.count
            rebuildRawItems()
        } catch {
            danmakuStats = "本地弹幕读取失败：\(error.localizedDescription)"
        }
    }

    /// 从设备端持久化缓存恢复在线弹幕，并标明缓存年龄。
    private func restoreCachedDanmaku(
        for candidate: ProviderCandidate,
        fingerprint: MediaFingerprint
    ) async -> Bool {
        guard let archive = try? await DanmakuCacheStore.shared.load(
            for: fingerprint,
            candidate: candidate
        ), !archive.items.isEmpty else {
            return false
        }
        onlineItems = archive.items
        currentBinding = archive.candidate
        rebuildRawItems()
        let days = max(Int(Date().timeIntervalSince(archive.cachedAt) / 86_400), 0)
        let age = days == 0 ? "近期缓存" : "\(days) 天前缓存"
        let count = localItems.isEmpty
            ? "\(archive.items.count) 条"
            : "\(archive.items.count) 条缓存 + \(localItems.count) 条本地"
        let sourceName = candidate.sourceInstanceName ?? candidate.source.displayName
        danmakuStats = "\(count) · \(sourceName) · \(age)兜底"
        isShowingCandidates = false
        return true
    }

    /// 合并在线与本地弹幕，并去除两种来源在两秒内出现的相同文本。
    private func rebuildRawItems() {
        let sortedItems = (localItems + onlineItems).sorted { left, right in
            if left.time == right.time {
                return left.source == .local && right.source != .local
            }
            return left.time < right.time
        }
        var lastItemByContent: [String: (time: Double, source: DanmakuSourceId)] = [:]
        rawItems = sortedItems.filter { item in
            let key = item.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { return false }
            if let previous = lastItemByContent[key],
               previous.source != item.source,
               abs(item.time - previous.time) <= 2 {
                return false
            }
            lastItemByContent[key] = (item.time, item.source)
            return true
        }
        onItemsChanged?(shiftedItems)
    }

    /// 在在线来源失败提示后补充本地弹幕仍可使用的信息。
    private func failureMessage(_ message: String) -> String {
        localItems.isEmpty ? message : "\(message)；仍显示 \(localItems.count) 条本地弹幕"
    }

    /// 打开新视频前清理上一视频的弹幕与绑定状态。
    private func resetDanmakuState() {
        rawItems = []
        onlineItems = []
        localItems = []
        candidates = []
        currentBinding = nil
        localDanmakuFileName = nil
        localDanmakuCount = 0
        currentFingerprint = nil
        isShowingCandidates = false
        onItemsChanged?([])
    }

    // MARK: - 播放控制

    func play() { player?.play() }
    func pause() { player?.pause() }

    /// 跳转到指定时间，弹幕层会在下一次同步时重建（FR-PLY-012）
    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    var duration: Double { localDuration }

    /// 每 0.1 秒把播放时间同步给弹幕层，两次同步之间由渲染层自行插值
    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onTimeChanged?(time.seconds, Double(player.rate))
            }
        }
    }
}
