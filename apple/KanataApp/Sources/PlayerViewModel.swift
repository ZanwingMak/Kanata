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
    private(set) var isSearchingCandidates = false
    private(set) var isBuffering = false
    private(set) var playbackRate: Double = 1
    private(set) var audioTracks: [MediaTrackOption] = []
    private(set) var subtitleTracks: [MediaTrackOption] = [MediaTrackOption(id: "off", title: "关闭")]
    private(set) var selectedAudioTrackID: String?
    private(set) var selectedSubtitleTrackID = "off"
    private(set) var mediaInfo = PlaybackMediaInfo()
    private(set) var resumePosition: Double?
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
    /// 播放、暂停或缓冲状态变化时通知界面同步按钮状态。
    var onPlaybackStateChanged: ((Bool) -> Void)?
    /// 播放自然结束时通知界面恢复控制层。
    var onPlaybackEnded: (() -> Void)?

    private var client: GatewayClient?
    private var builtInClient: BuiltInBilibiliClient?
    private var builtInPublicClient: BuiltInPublicDanmakuClient?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var matchingTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var securityScopedURL: URL?
    private var seasonKey: String?
    private var localDuration: Double = 0
    private var currentFingerprint: MediaFingerprint?
    private var onlineItems: [DanmakuItem] = []
    private var localItems: [DanmakuItem] = []
    private var onlineCacheLimitBytes: Int64 = 250 * 1024 * 1024
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioOptions: [String: AVMediaSelectionOption] = [:]
    private var subtitleOptions: [String: AVMediaSelectionOption] = [:]
    private var mediaKey = ""
    private var lastProgressSaveTime: Double = 0

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
        matchingTask?.cancel()
        mediaTask?.cancel()
        matchingTask = nil
        mediaTask = nil
        saveProgressIfNeeded(force: true)
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        timeControlObservation = nil
        itemStatusObservation = nil
        player?.pause()
        player = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    /// 打开一个本地或网络视频并尝试自动匹配弹幕。
    /// - Parameters:
    ///   - url: 视频文件地址，来自文件选择器
    ///   - settings: 应用设置，提供网关配置。
    ///   - requestHeaders: WebDAV 或媒体服务器播放所需的临时请求头。
    func open(url: URL, settings: AppSettings, requestHeaders: [String: String] = [:]) async {
        resetDanmakuState()
        state = .preparing("正在读取视频…")
        client = settings.makeClient()
        builtInClient = settings.makeBuiltInBilibiliClient()
        builtInPublicClient = settings.makeBuiltInPublicDanmakuClient()
        onlineCacheLimitBytes = Int64(settings.onlineDanmakuCacheLimitMB) * 1024 * 1024
        mediaKey = url.absoluteString
        mediaInfo.source = url.isFileURL ? "本地文件" : (url.host ?? "网络视频")

        // 文件选择器返回的地址需要显式申请访问权（FR-IMP-001）
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        let assetOptions: [String: Any]? = requestHeaders.isEmpty
            ? nil
            : ["AVURLAssetHTTPHeaderFieldsKey": requestHeaders]
        let asset = AVURLAsset(url: url, options: assetOptions)
        do {
            let duration = try await asset.load(.duration)
            localDuration = duration.seconds.isFinite ? duration.seconds : 0
        } catch {
            state = .failed("无法读取视频信息：\(error.localizedDescription)")
            return
        }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player
        installTimeObserver(on: player)
        installPlaybackObservers(on: player, item: item)
        resumePosition = PlaybackProgressStore.position(for: mediaKey, duration: localDuration)
        if let resumePosition {
            await player.seek(to: CMTime(seconds: resumePosition, preferredTimescale: 600))
        }
        state = .ready
        mediaInfo.duration = Self.timeLabel(localDuration)

        mediaTask = Task { [weak self] in
            await self?.loadMediaOptions(asset: asset, item: item)
        }
        matchingTask = Task { [weak self] in
            await self?.matchDanmaku(url: url)
        }
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

        guard client != nil || builtInClient != nil || builtInPublicClient != nil else {
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

        let result = await resolveCandidates(
            ResolveRequest(
                title: parsedTitle.title,
                season: parsedTitle.season,
                episode: parsedTitle.isCollection ? nil : parsedTitle.episode,
                duration: localDuration,
                fingerprint: fingerprint
            )
        )
        candidates = result.candidates
        guard let best = result.candidates.first else {
            let detail = result.errors.isEmpty ? "" : "（\(result.errors.joined(separator: "；"))）"
            danmakuStats = failureMessage("未匹配到弹幕\(detail)，可输入剧名、集数或平台链接搜索")
            isShowingCandidates = true
            return
        }
        // 置信度足够高时直接采用，否则让用户确认。
        if best.confidence >= 0.9 {
            await loadDanmaku(for: best)
        } else {
            danmakuStats = "找到 \(result.candidates.count) 个候选，请选择"
            isShowingCandidates = true
        }
    }

    /// 合并 App 内置来源与用户网关候选，任一来源失败都不会阻塞播放。
    /// - Parameter request: 标题、季集号、时长与可选指纹。
    /// - Returns: 候选列表与可展示的降级原因。
    private func resolveCandidates(
        _ request: ResolveRequest
    ) async -> (candidates: [ProviderCandidate], errors: [String]) {
        var errors: [String] = []
        var merged: [String: ProviderCandidate] = [:]

        /// 追加候选并按来源与剧集 ID 去重，重复时保留置信度更高的一项。
        func append(_ candidates: [ProviderCandidate]) {
            for candidate in candidates {
                if let existing = merged[candidate.id], existing.confidence >= candidate.confidence { continue }
                merged[candidate.id] = candidate
            }
        }

        if let builtInClient {
            do {
                append(try await builtInClient.search(request))
            } catch {
                errors.append("哔哩哔哩：\(error.localizedDescription)")
            }
        }
        if let builtInPublicClient {
            let candidates = await builtInPublicClient.search(request)
            append(candidates)
            if candidates.isEmpty {
                errors.append("爱奇艺、腾讯视频未找到匹配结果")
            }
        }
        if let client {
            do {
                let response = try await client.resolve(request)
                append(response.candidates)
                errors.append(contentsOf: response.degraded.map { "\($0.displayName)暂不可用" })
            } catch let error as GatewayError {
                errors.append(error.requiresLogin ? "网关来源需要登录" : error.errorMessage)
            } catch {
                errors.append("网关连接失败")
            }
        }
        let candidates = merged.values.sorted { left, right in
            if left.confidence == right.confidence { return left.id < right.id }
            return left.confidence > right.confidence
        }
        return (candidates, errors)
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
        danmakuStats = "正在加载弹幕…"
        var errors: [String] = []
        if candidate.source == .bilibili, let builtInClient {
            let startedAt = Date()
            do {
                let items = try await builtInClient.danmaku(platformEpisodeID: candidate.platformEpisodeId)
                if !items.isEmpty {
                    await applyLoadedDanmaku(
                        items,
                        candidate: candidate,
                        elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                        fallback: false,
                        persistBinding: persistBinding
                    )
                    return true
                }
                errors.append("内置来源返回空弹幕")
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if [.iqiyi, .qq].contains(candidate.source), let builtInPublicClient {
            let startedAt = Date()
            do {
                let items = try await builtInPublicClient.danmaku(for: candidate)
                if !items.isEmpty {
                    await applyLoadedDanmaku(
                        items,
                        candidate: candidate,
                        elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                        fallback: false,
                        persistBinding: persistBinding
                    )
                    return true
                }
                errors.append("内置\(candidate.source.displayName)来源返回空弹幕")
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if let client {
            do {
                let response = try await client.danmaku(
                    refs: [DanmakuRef(source: candidate.source, platformEpisodeId: candidate.platformEpisodeId)]
                )
                if response.items.isEmpty {
                    errors.append("网关来源返回空弹幕")
                } else {
                    await applyLoadedDanmaku(
                        response.items,
                        candidate: candidate,
                        elapsedMs: response.stats.elapsedMs,
                        fallback: response.degraded.contains { $0.source == candidate.source },
                        persistBinding: persistBinding
                    )
                    return true
                }
            } catch let error as GatewayError {
                errors.append(error.errorMessage)
            } catch {
                errors.append("网关连接失败")
            }
        }
        danmakuStats = failureMessage("弹幕加载失败：\(errors.joined(separator: "；"))")
        isShowingCandidates = true
        return false
    }

    /// 应用已获取的在线弹幕，并写入绑定与离线缓存。
    /// - Parameters:
    ///   - items: 统一弹幕条目。
    ///   - candidate: 当前来源候选。
    ///   - elapsedMs: 获取耗时。
    ///   - fallback: 是否来自旧缓存或来源降级。
    ///   - persistBinding: 是否保存本次绑定。
    private func applyLoadedDanmaku(
        _ items: [DanmakuItem],
        candidate: ProviderCandidate,
        elapsedMs: Int,
        fallback: Bool,
        persistBinding: Bool
    ) async {
        onlineItems = items
        rebuildRawItems()
        if persistBinding, let currentFingerprint {
            DanmakuBindingStore.save(candidate, for: currentFingerprint)
        }
        if let currentFingerprint {
            try? await DanmakuCacheStore.shared.save(
                items: items,
                candidate: candidate,
                for: currentFingerprint,
                maximumBytes: onlineCacheLimitBytes
            )
        }
        currentBinding = candidate
        isShowingCandidates = false
        let hint = shouldHintTimeline(remote: candidate.duration) ? " · 时长差异较大，建议校正" : ""
        let fallbackText = fallback ? " · 缓存兜底" : ""
        let count = localItems.isEmpty
            ? "\(items.count) 条"
            : "\(items.count) 条在线 + \(localItems.count) 条本地"
        let sourceName = candidate.sourceInstanceName ?? candidate.source.displayName
        danmakuStats = "\(count) · \(sourceName) · \(elapsedMs)ms\(fallbackText)\(hint)"
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
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, client != nil || builtInClient != nil || builtInPublicClient != nil else {
            danmakuStats = "没有启用可用的在线弹幕来源"
            return
        }
        isSearchingCandidates = true
        defer { isSearchingCandidates = false }
        danmakuStats = "正在搜索…"
        // 手动搜索不强制文件名解析出的集号，避免错误集号把全部候选过滤掉。
        let result = await resolveCandidates(
            ResolveRequest(title: query, duration: localDuration)
        )
        candidates = result.candidates
        danmakuStats = result.candidates.isEmpty
            ? "没有找到结果\(result.errors.isEmpty ? "" : "：\(result.errors.joined(separator: "；"))")"
            : "找到 \(result.candidates.count) 个候选"
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
        isSearchingCandidates = false
        onItemsChanged?([])
    }

    // MARK: - 播放控制

    /// 按当前倍速继续播放。
    func play() {
        guard let player else { return }
        player.playImmediately(atRate: Float(playbackRate))
        onPlaybackStateChanged?(true)
    }

    /// 暂停视频并保存当前断点。
    func pause() {
        player?.pause()
        saveProgressIfNeeded(force: true)
        onPlaybackStateChanged?(false)
    }

    /// 设置播放倍速；播放中立即生效，暂停时只记住选择。
    /// - Parameter rate: 0.5 到 2.0 的播放倍率。
    func setPlaybackRate(_ rate: Double) {
        playbackRate = min(max(rate, 0.5), 2)
        if player?.rate ?? 0 > 0 {
            player?.rate = Float(playbackRate)
        }
    }

    /// 设置播放器输出音量。
    /// - Parameter volume: 0 到 1 的音量值。
    func setVolume(_ volume: Double) {
        player?.volume = Float(min(max(volume, 0), 1))
    }

    /// 读取播放器当前输出音量。
    var volume: Double { Double(player?.volume ?? 1) }

    /// 选择一条内封音轨。
    /// - Parameter id: 音轨稳定标识。
    func selectAudioTrack(id: String) {
        guard let item = player?.currentItem,
              let audioGroup,
              let option = audioOptions[id] else { return }
        item.select(option, in: audioGroup)
        selectedAudioTrackID = id
    }

    /// 选择或关闭一条内封字幕轨。
    /// - Parameter id: 字幕轨标识；off 表示关闭。
    func selectSubtitleTrack(id: String) {
        guard let item = player?.currentItem, let subtitleGroup else { return }
        item.select(id == "off" ? nil : subtitleOptions[id], in: subtitleGroup)
        selectedSubtitleTrackID = id
    }

    /// 跳转到指定时间，弹幕层会在下一次同步时重建（FR-PLY-012）
    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), max(localDuration, 0))
        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        lastProgressSaveTime = target
        PlaybackProgressStore.save(position: target, duration: localDuration, for: mediaKey)
    }

    var duration: Double { localDuration }

    /// 每 0.1 秒把播放时间同步给弹幕层，两次同步之间由渲染层自行插值
    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onTimeChanged?(time.seconds, Double(player.rate))
                self.saveProgressIfNeeded(currentTime: time.seconds)
            }
        }
    }

    /// 监听播放缓冲、失败和自然结束状态。
    /// - Parameters:
    ///   - player: 当前 AVPlayer。
    ///   - item: 当前播放项。
    private func installPlaybackObservers(on player: AVPlayer, item: AVPlayerItem) {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.onPlaybackStateChanged?(player.timeControlStatus == .playing)
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.state = .failed(item.error?.localizedDescription ?? "播放器无法解码该视频")
                self?.onPlaybackStateChanged?(false)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                PlaybackProgressStore.remove(for: self.mediaKey)
                self.onPlaybackStateChanged?(false)
                self.onPlaybackEnded?()
            }
        }
    }

    /// 枚举内封音频、字幕与视频分辨率，供播放控制面板展示。
    /// - Parameters:
    ///   - asset: 当前媒体资源。
    ///   - item: 当前播放项。
    private func loadMediaOptions(asset: AVAsset, item: AVPlayerItem) async {
        do {
            let group = try await asset.loadMediaSelectionGroup(for: .audible)
            audioGroup = group
            if let group {
                audioOptions = Dictionary(uniqueKeysWithValues: group.options.enumerated().map { index, option in
                    ("audio-\(index)", option)
                })
                audioTracks = group.options.enumerated().map { index, option in
                    MediaTrackOption(id: "audio-\(index)", title: option.displayName)
                }
                if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
                   let index = group.options.firstIndex(of: selected) {
                    selectedAudioTrackID = "audio-\(index)"
                } else {
                    selectedAudioTrackID = audioTracks.first?.id
                }
            }
        } catch {
            audioTracks = []
        }

        do {
            let group = try await asset.loadMediaSelectionGroup(for: .legible)
            subtitleGroup = group
            if let group {
                subtitleOptions = Dictionary(uniqueKeysWithValues: group.options.enumerated().map { index, option in
                    ("subtitle-\(index)", option)
                })
                subtitleTracks = [MediaTrackOption(id: "off", title: "关闭")] + group.options.enumerated().map { index, option in
                    MediaTrackOption(id: "subtitle-\(index)", title: option.displayName)
                }
            }
        } catch {
            subtitleTracks = [MediaTrackOption(id: "off", title: "关闭")]
        }

        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let naturalSize = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let transformed = naturalSize.applying(transform)
            mediaInfo.resolution = "\(Int(abs(transformed.width))) × \(Int(abs(transformed.height)))"
        }
    }

    /// 定期保存断点，避免每 0.1 秒写入 UserDefaults。
    /// - Parameters:
    ///   - currentTime: 可选的当前秒数，缺省时读取播放器。
    ///   - force: 是否忽略五秒节流。
    private func saveProgressIfNeeded(currentTime: Double? = nil, force: Bool = false) {
        guard !mediaKey.isEmpty else { return }
        let value = currentTime ?? player?.currentTime().seconds ?? 0
        guard force || abs(value - lastProgressSaveTime) >= 5 else { return }
        lastProgressSaveTime = value
        PlaybackProgressStore.save(position: value, duration: localDuration, for: mediaKey)
    }

    /// 把秒数转换为播放信息面板使用的时间文本。
    /// - Parameter seconds: 秒数。
    /// - Returns: mm:ss 或 h:mm:ss。
    private static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let value = Int(seconds.rounded())
        let hours = value / 3_600
        let minutes = value % 3_600 / 60
        let remaining = value % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%02d:%02d", minutes, remaining)
    }
}
