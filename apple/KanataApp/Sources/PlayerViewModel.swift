import AVFoundation
import Foundation
import KanataCore
@preconcurrency import KSPlayer
import MediaPlayer
import Observation

/// 发布到系统“正在播放”界面的节目与队列信息。
struct PlaybackNowPlayingMetadata {
    let title: String
    let collectionTitle: String?
    let subtitle: String?
    let sourceName: String?
    let queueIndex: Int
    let queueCount: Int
    let identifier: String
}

/// 当前媒体集数与弹幕来源集数的对应状态。
enum DanmakuEpisodeAlignment: Equatable {
    case unavailable
    case unverified(local: Int?)
    case matched(local: Int, remote: Int)
    case mismatched(local: Int, remote: Int)

    var title: String {
        switch self {
        case .unavailable: "尚未绑定弹幕分集"
        case .unverified(let local):
            local.map { "当前第 \($0) 集 · 弹幕源未提供集号" } ?? "弹幕集数待确认"
        case .matched(let local, _): "集数一致 · 第 \(local) 集"
        case .mismatched(let local, let remote): "集数不一致 · 视频第 \(local) 集 / 弹幕第 \(remote) 集"
        }
    }

    var symbol: String {
        switch self {
        case .unavailable: "link.badge.plus"
        case .unverified: "questionmark.circle"
        case .matched: "checkmark.circle.fill"
        case .mismatched: "exclamationmark.triangle.fill"
        }
    }
}

/// 播放页状态机：打开文件 → 识别 → 匹配弹幕 → 播放。
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
    private(set) var universalPlayerLayer: KSPlayerLayer?
    private(set) var usesUniversalPlayer = false
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
    /// 原始播放流失败时通知播放页尝试媒体服务器兼容流。
    var onPlaybackFailed: ((String) -> Void)?
    /// 系统遥控器请求播放上一集时通知播放页更新队列。
    var onPreviousTrackRequested: (() -> Void)?
    /// 系统遥控器请求播放下一集时通知播放页更新队列。
    var onNextTrackRequested: (() -> Void)?

    private var client: GatewayClient?
    private var builtInClient: BuiltInBilibiliClient?
    private var builtInPublicClient: BuiltInPublicDanmakuClient?
    private var builtInDandanplayClient: BuiltInDandanplayClient?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var matchingTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var playbackHasFailed = false
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
    private var universalAudioOptions: [String: any MediaPlayerTrack] = [:]
    private var universalSubtitleOptions: [String: any MediaPlayerTrack] = [:]
    private var mediaKey = ""
    private var currentPlaybackURL: URL?
    private var currentDisplayName = ""
    private var lastProgressSaveTime: Double = 0
    private var nowPlayingMetadata: PlaybackNowPlayingMetadata?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var lastNowPlayingUpdateTime: Double = 0

    /// 当前视频是否已关联本地弹幕文件。
    var hasLocalDanmaku: Bool { !localItems.isEmpty }

    /// 当前绑定与本地解析集数的对应结果。
    var episodeAlignment: DanmakuEpisodeAlignment {
        guard let currentBinding else { return .unavailable }
        return episodeAlignment(for: currentBinding)
    }

    /// 比较一个候选弹幕分集与当前视频的集数。
    /// - Parameter candidate: 待比较的弹幕候选。
    /// - Returns: 明确一致、不一致或无法确认。
    func episodeAlignment(for candidate: ProviderCandidate) -> DanmakuEpisodeAlignment {
        let localEpisode = parsed?.episode
        let remoteEpisode = Self.episodeNumber(
            from: [candidate.episodeTitle, candidate.title].compactMap { $0 }.joined(separator: " ")
        )
        guard let localEpisode else { return .unverified(local: nil) }
        guard let remoteEpisode else { return .unverified(local: localEpisode) }
        return localEpisode == remoteEpisode
            ? .matched(local: localEpisode, remote: remoteEpisode)
            : .mismatched(local: localEpisode, remote: remoteEpisode)
    }

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
        universalPlayerLayer?.delegate = nil
        universalPlayerLayer?.stop()
        universalPlayerLayer = nil
        usesUniversalPlayer = false
        currentPlaybackURL = nil
        currentDisplayName = ""
        uninstallSystemPlaybackControls()
        nowPlayingMetadata = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    /// 打开一个本地或网络视频并尝试自动匹配弹幕。
    /// - Parameters:
    ///   - url: 视频文件地址，来自文件选择器
    ///   - displayName: 媒体库保存的原始文件名或剧集名。
    ///   - settings: 应用设置，提供网关配置。
    ///   - requestHeaders: WebDAV 或媒体服务器播放所需的临时请求头。
    ///   - mediaFileName: 保留扩展名的原始文件名，用于选择兼容容器的播放内核。
    ///   - forceUniversalPlayer: 系统内核失败后强制改用 FFmpeg 重试。
    ///   - progressKey: 不含临时令牌的稳定断点标识。
    ///   - nowPlaying: 发布给锁屏、控制中心与遥控器的节目队列信息。
    func open(
        url: URL,
        displayName: String,
        settings: AppSettings,
        requestHeaders: [String: String] = [:],
        mediaFileName: String? = nil,
        forceUniversalPlayer: Bool = false,
        progressKey: String? = nil,
        nowPlaying: PlaybackNowPlayingMetadata? = nil
    ) async {
        configurePlaybackAudioSession()
        playbackHasFailed = false
        resetDanmakuState()
        localDuration = 0
        resumePosition = nil
        audioTracks = []
        subtitleTracks = [MediaTrackOption(id: "off", title: "关闭")]
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = "off"
        universalAudioOptions.removeAll()
        universalSubtitleOptions.removeAll()
        state = .preparing("正在读取视频…")
        client = settings.makeClient()
        builtInClient = settings.makeBuiltInBilibiliClient()
        builtInPublicClient = settings.makeBuiltInPublicDanmakuClient()
        builtInDandanplayClient = settings.makeBuiltInDandanplayClient()
        onlineCacheLimitBytes = Int64(settings.onlineDanmakuCacheLimitMB) * 1024 * 1024
        mediaKey = progressKey ?? url.absoluteString
        currentPlaybackURL = url
        currentDisplayName = displayName
        nowPlayingMetadata = nowPlaying
        mediaInfo.source = url.isFileURL ? "本地文件" : (url.host ?? "网络视频")
        usesUniversalPlayer = forceUniversalPlayer
            || Self.requiresUniversalPlayer(url: url, fileName: mediaFileName ?? displayName)

        // 文件选择器返回的地址需要显式申请访问权（FR-IMP-001）
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        if usesUniversalPlayer {
            openUniversalPlayer(url: url, requestHeaders: requestHeaders)
        } else {
            let assetOptions: [String: Any]? = requestHeaders.isEmpty
                ? nil
                : ["AVURLAssetHTTPHeaderFieldsKey": requestHeaders]
            let asset = AVURLAsset(url: url, options: assetOptions)
            if let duration = try? await asset.load(.duration) {
                localDuration = duration.seconds.isFinite ? duration.seconds : 0
            }

            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            player.allowsExternalPlayback = true
            player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
            self.player = player
            installTimeObserver(on: player)
            installPlaybackObservers(on: player, item: item)
            resumePosition = PlaybackProgressStore.position(for: mediaKey, duration: localDuration)
            if let resumePosition {
                await player.seek(to: CMTime(seconds: resumePosition, preferredTimescale: 600))
            }
            mediaTask = Task { [weak self] in
                await self?.loadMediaOptions(asset: asset, item: item)
            }
        }
        installSystemPlaybackControls()
        state = .ready
        mediaInfo.duration = Self.timeLabel(localDuration)
        updateNowPlayingInfo(elapsedTime: resumePosition ?? 0, playbackRate: 0)
        matchingTask = Task { [weak self] in
            await self?.matchDanmaku(url: url, displayName: displayName)
        }
    }

    /// 为系统播放器不稳定支持的容器创建 FFmpeg 播放层，并保留请求头与断点。
    /// - Parameters:
    ///   - url: 原始媒体地址。
    ///   - requestHeaders: WebDAV 或媒体服务器鉴权请求头。
    private func openUniversalPlayer(url: URL, requestHeaders: [String: String]) {
        let options = KSOptions()
        options.registerRemoteControll = false
        options.isAccurateSeek = true
        options.isSecondOpen = true
        options.autoSelectEmbedSubtitle = true
        options.appendHeader(requestHeaders)
        if let snapshot = PlaybackProgressStore.snapshot(for: mediaKey) {
            resumePosition = snapshot.position
            localDuration = snapshot.duration
            options.startPlayTime = snapshot.position
        }
        let previousPlayerType = KSOptions.firstPlayerType
        KSOptions.firstPlayerType = KSMEPlayer.self
        let layer = KSPlayerLayer(url: url, isAutoPlay: false, options: options, delegate: self)
        KSOptions.firstPlayerType = previousPlayerType
        layer.player.allowsExternalPlayback = true
        universalPlayerLayer = layer
        loadUniversalMediaOptions(from: layer)
    }

    /// 判断媒体容器是否应跳过 AVPlayer 并直接使用 FFmpeg 内核。
    /// - Parameters:
    ///   - url: 实际播放地址。
    ///   - fileName: 保留扩展名的媒体文件名。
    /// - Returns: 容器需要通用解码时返回 true。
    private static func requiresUniversalPlayer(url: URL, fileName: String) -> Bool {
        let urlExtension = url.pathExtension.lowercased()
        let nameExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        let container = urlExtension.isEmpty ? nameExtension : urlExtension
        return ["mkv", "webm", "avi", "flv", "rm", "rmvb", "ts", "m2ts", "mts",
                "mpg", "mpeg", "vob", "wmv", "ogv", "3gp", "3g2", "mxf"].contains(container)
    }

    /// 激活影视播放音频会话，让静音模式、后台音频、画中画与 AirPlay 使用系统媒体路径。
    private func configurePlaybackAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            // 音频会话失败不阻断本地播放，系统输出功能会按当前可用路由降级。
        }
    }

    /// 识别文件并向网关请求候选
    /// - Parameters:
    ///   - url: 用于指纹计算的实际播放地址。
    ///   - displayName: 用户可见的原始名称，避免媒体服务器的 `/file` 路径污染关键词。
    private func matchDanmaku(url: URL, displayName: String) async {
        let keywordSource = Self.preferredMatchName(displayName: displayName, url: url)
        let parsedTitle = TitleParser.parse(keywordSource)
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
        guard canContinueDanmakuWork else { return }

        let savedCandidate = fingerprint.flatMap { DanmakuBindingStore.candidate(for: $0) }
        currentBinding = savedCandidate

        guard client != nil
                || builtInClient != nil
                || builtInPublicClient != nil
                || builtInDandanplayClient != nil else {
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
            if await restoreCachedDanmaku(for: savedCandidate, fingerprint: fingerprint) {
                return
            }
            if await loadDanmaku(for: savedCandidate, persistBinding: false) {
                return
            }
            guard canContinueDanmakuWork else { return }
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
        guard canContinueDanmakuWork else { return }
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

    /// 选择自动匹配弹幕使用的名称，过滤媒体服务器常见的无意义路径段。
    /// - Parameters:
    ///   - displayName: 媒体库保存的原始名称。
    ///   - url: 实际播放地址。
    /// - Returns: 可交给标题解析器的稳定名称。
    private static func preferredMatchName(displayName: String, url: URL) -> String {
        let visibleName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericNames: Set<String> = ["file", "stream", "download", "original", "video", "play"]
        let visibleStem = URL(fileURLWithPath: visibleName).deletingPathExtension().lastPathComponent
        if !visibleName.isEmpty, !genericNames.contains(visibleStem.lowercased()) { return visibleName }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryName = components.queryItems?.first(where: {
               ["name", "title", "filename"].contains($0.name.lowercased())
           })?.value,
           !queryName.isEmpty {
            return queryName
        }
        let urlName = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? ""
        return genericNames.contains(urlName.lowercased()) ? "未命名视频" : url.lastPathComponent
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
                errors.append("爱奇艺、腾讯视频、巴哈姆特未找到匹配结果")
            }
        }
        if let builtInDandanplayClient {
            do {
                append(try await builtInDandanplayClient.resolve(request))
            } catch {
                errors.append("弹弹play备用：\(error.localizedDescription)")
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
            let leftEpisodePriority = candidateEpisodePriority(left)
            let rightEpisodePriority = candidateEpisodePriority(right)
            if leftEpisodePriority != rightEpisodePriority {
                return leftEpisodePriority > rightEpisodePriority
            }
            if left.confidence == right.confidence { return left.id < right.id }
            return left.confidence > right.confidence
        }
        return (candidates, errors)
    }

    /// 返回候选分集排序优先级，当前视频集数一致的结果始终排在前面。
    /// - Parameter candidate: 待排序的弹幕候选。
    /// - Returns: 一致为 2、无法确认集数为 1、不一致为 0。
    private func candidateEpisodePriority(_ candidate: ProviderCandidate) -> Int {
        switch episodeAlignment(for: candidate) {
        case .matched: 2
        case .unverified, .unavailable: 1
        case .mismatched: 0
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
        guard canContinueDanmakuWork else { return false }
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
        if [.iqiyi, .qq, .bahamut].contains(candidate.source), let builtInPublicClient {
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
        if candidate.source == .dandanplay, let builtInDandanplayClient {
            let startedAt = Date()
            do {
                let items = try await builtInDandanplayClient.danmaku(
                    platformEpisodeID: candidate.platformEpisodeId
                )
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
                errors.append("弹弹play备用来源返回空弹幕")
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
        guard canContinueDanmakuWork else { return false }
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
        guard canContinueDanmakuWork else { return }
        onlineItems = items
        rebuildRawItems()
        if persistBinding, let currentFingerprint {
            DanmakuBindingStore.save(candidate, for: currentFingerprint)
            CloudSyncStore.shared.noteLocalChange()
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
        danmakuStats = "\(count) · \(sourceName) · \(episodeAlignment(for: candidate).title) · \(elapsedMs)ms\(fallbackText)\(hint)"
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
        CloudSyncStore.shared.noteLocalChange()
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
        guard canContinueDanmakuWork,
              !query.isEmpty,
              client != nil
                || builtInClient != nil
                || builtInPublicClient != nil
                || builtInDandanplayClient != nil else {
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
        guard canContinueDanmakuWork else { return }
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

    /// 从平台分集标题中提取“第 N 集”、EP N 或开头数字。
    /// - Parameter value: 来源标题与分集标题组合文本。
    /// - Returns: 无明确数字时返回 nil。
    private static func episodeNumber(from value: String) -> Int? {
        let patterns = [#"第\s*(\d+)\s*[集话]"#, #"\b(?:EP|E)\s*0*(\d+)\b"#, #"^\s*0*(\d+)\b"#]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = expression.firstMatch(in: value, range: range),
                  match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: value),
                  let number = Int(value[numberRange]) else { continue }
            return number
        }
        return nil
    }

    // MARK: - 播放控制

    /// 按当前倍速继续播放。
    func play() {
        if let universalPlayerLayer {
            universalPlayerLayer.player.playbackRate = Float(playbackRate)
            universalPlayerLayer.play()
        } else {
            guard let player else { return }
            player.playImmediately(atRate: Float(playbackRate))
        }
        updateNowPlayingInfo(elapsedTime: currentPlaybackTime, playbackRate: playbackRate)
        onPlaybackStateChanged?(true)
    }

    /// 暂停视频并保存当前断点。
    func pause() {
        player?.pause()
        universalPlayerLayer?.pause()
        saveProgressIfNeeded(force: true)
        updateNowPlayingInfo(elapsedTime: currentPlaybackTime, playbackRate: 0)
        onPlaybackStateChanged?(false)
    }

    /// 设置播放倍速；播放中立即生效，暂停时只记住选择。
    /// - Parameter rate: 0.25 到 4.0 的播放倍率。
    func setPlaybackRate(_ rate: Double) {
        playbackRate = min(max(rate, 0.25), 4)
        if player?.rate ?? 0 > 0 {
            player?.rate = Float(playbackRate)
        }
        if let universalPlayerLayer {
            universalPlayerLayer.player.playbackRate = Float(playbackRate)
        }
        updateNowPlayingInfo(
            elapsedTime: currentPlaybackTime,
            playbackRate: isPlaybackActive ? playbackRate : 0
        )
    }

    /// 设置播放器输出音量。
    /// - Parameter volume: 0 到 1 的音量值。
    func setVolume(_ volume: Double) {
        let value = Float(min(max(volume, 0), 1))
        player?.volume = value
        universalPlayerLayer?.player.playbackVolume = value
    }

    /// 读取播放器当前输出音量。
    var volume: Double {
        if let universalPlayerLayer { return Double(universalPlayerLayer.player.playbackVolume) }
        return Double(player?.volume ?? 1)
    }

    /// 选择一条内封音轨。
    /// - Parameter id: 音轨稳定标识。
    func selectAudioTrack(id: String) {
        if let track = universalAudioOptions[id], let universalPlayerLayer {
            universalPlayerLayer.player.select(track: track)
            selectedAudioTrackID = id
            return
        }
        guard let item = player?.currentItem,
              let audioGroup,
              let option = audioOptions[id] else { return }
        item.select(option, in: audioGroup)
        selectedAudioTrackID = id
    }

    /// 选择或关闭一条内封字幕轨。
    /// - Parameter id: 字幕轨标识；off 表示关闭。
    func selectSubtitleTrack(id: String) {
        if let universalPlayerLayer {
            universalSubtitleOptions.values.forEach { $0.isEnabled = false }
            if let track = universalSubtitleOptions[id] {
                universalPlayerLayer.player.select(track: track)
            }
            selectedSubtitleTrackID = id
            return
        }
        guard let item = player?.currentItem, let subtitleGroup else { return }
        item.select(id == "off" ? nil : subtitleOptions[id], in: subtitleGroup)
        selectedSubtitleTrackID = id
    }

    /// 跳转到指定时间，弹幕层会在下一次同步时重建（FR-PLY-012）
    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), max(localDuration, 0))
        if let universalPlayerLayer {
            universalPlayerLayer.seek(time: target, autoPlay: isPlaybackActive) { _ in }
        } else {
            player?.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        lastProgressSaveTime = target
        PlaybackProgressStore.save(position: target, duration: localDuration, for: mediaKey)
        updateNowPlayingInfo(
            elapsedTime: target,
            playbackRate: isPlaybackActive ? playbackRate : 0
        )
    }

    var duration: Double { localDuration }

    /// 切换通用播放内核的系统画中画状态。
    /// - Returns: 当前由通用内核处理画中画时返回 true。
    func toggleUniversalPictureInPicture() -> Bool {
        guard let universalPlayerLayer else { return false }
        universalPlayerLayer.isPipActive.toggle()
        return true
    }

    /// 当前播放内核报告的实际时间。
    private var currentPlaybackTime: Double {
        if let universalPlayerLayer { return universalPlayerLayer.player.currentPlaybackTime }
        return player?.currentTime().seconds ?? 0
    }

    /// 当前任一播放内核是否正在播放。
    private var isPlaybackActive: Bool {
        if let universalPlayerLayer { return universalPlayerLayer.player.isPlaying }
        return player?.rate ?? 0 > 0
    }

    /// 把 FFmpeg 内核识别到的音轨和字幕轨转换成设置面板选项。
    /// - Parameter layer: 已创建的通用播放层。
    private func loadUniversalMediaOptions(from layer: KSPlayerLayer) {
        let audio = layer.player.tracks(mediaType: .audio)
        universalAudioOptions = Dictionary(uniqueKeysWithValues: audio.map { track in
            ("audio-\(track.trackID)", track)
        })
        audioTracks = audio.map { track in
            MediaTrackOption(id: "audio-\(track.trackID)", title: track.name)
        }
        selectedAudioTrackID = audio.first(where: \.isEnabled).map { "audio-\($0.trackID)" }

        let subtitles = layer.player.tracks(mediaType: .subtitle)
        universalSubtitleOptions = Dictionary(uniqueKeysWithValues: subtitles.map { track in
            ("subtitle-\(track.trackID)", track)
        })
        subtitleTracks = [MediaTrackOption(id: "off", title: "关闭")] + subtitles.map { track in
            MediaTrackOption(id: "subtitle-\(track.trackID)", title: track.name)
        }
        selectedSubtitleTrackID = subtitles.first(where: \.isEnabled).map { "subtitle-\($0.trackID)" } ?? "off"
    }

    /// 每 0.1 秒把播放时间同步给弹幕层，两次同步之间由渲染层自行插值
    private func installTimeObserver(on player: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onTimeChanged?(time.seconds, Double(player.rate))
                self.saveProgressIfNeeded(currentTime: time.seconds)
                self.updateNowPlayingInfoIfNeeded(elapsedTime: time.seconds, playbackRate: Double(player.rate))
            }
        }
    }

    /// 注册锁屏、控制中心、耳机与 Apple TV 遥控器的播放命令。
    private func installSystemPlaybackControls() {
        uninstallSystemPlaybackControls()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.nextTrackCommand.isEnabled = (nowPlayingMetadata?.queueIndex ?? 0) + 1 < (nowPlayingMetadata?.queueCount ?? 0)
        center.previousTrackCommand.isEnabled = (nowPlayingMetadata?.queueIndex ?? 0) > 0

        let playTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.play() }
            return .success
        }
        remoteCommandTargets.append((center.playCommand, playTarget))

        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        remoteCommandTargets.append((center.pauseCommand, pauseTarget))

        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isPlaybackActive {
                    self.pause()
                } else {
                    self.play()
                }
            }
            return .success
        }
        remoteCommandTargets.append((center.togglePlayPauseCommand, toggleTarget))

        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor [weak self] in self?.seek(to: event.positionTime) }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, seekTarget))

        let forwardTarget = center.skipForwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seek(to: self.currentPlaybackTime + interval)
            }
            return .success
        }
        remoteCommandTargets.append((center.skipForwardCommand, forwardTarget))

        let backwardTarget = center.skipBackwardCommand.addTarget { [weak self] event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.seek(to: self.currentPlaybackTime - interval)
            }
            return .success
        }
        remoteCommandTargets.append((center.skipBackwardCommand, backwardTarget))

        let nextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onNextTrackRequested?() }
            return .success
        }
        remoteCommandTargets.append((center.nextTrackCommand, nextTarget))

        let previousTarget = center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.onPreviousTrackRequested?() }
            return .success
        }
        remoteCommandTargets.append((center.previousTrackCommand, previousTarget))
    }

    /// 移除当前播放器注册的系统命令，避免切集后重复响应。
    private func uninstallSystemPlaybackControls() {
        remoteCommandTargets.forEach { entry in
            entry.command.removeTarget(entry.target)
        }
        remoteCommandTargets.removeAll()
    }

    /// 把节目、集数、队列、进度与倍速同步到系统“正在播放”。
    /// - Parameters:
    ///   - elapsedTime: 当前播放秒数。
    ///   - playbackRate: 当前实际播放倍率，暂停时为零。
    private func updateNowPlayingInfo(elapsedTime: Double, playbackRate: Double) {
        guard let metadata = nowPlayingMetadata else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: metadata.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(elapsedTime.isFinite ? elapsedTime : 0, 0),
            MPNowPlayingInfoPropertyPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: self.playbackRate,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: metadata.queueIndex,
            MPNowPlayingInfoPropertyPlaybackQueueCount: metadata.queueCount,
            MPNowPlayingInfoPropertyExternalContentIdentifier: metadata.identifier,
        ]
        if localDuration > 0 { info[MPMediaItemPropertyPlaybackDuration] = localDuration }
        if let collectionTitle = metadata.collectionTitle { info[MPMediaItemPropertyAlbumTitle] = collectionTitle }
        if let subtitle = metadata.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        if let sourceName = metadata.sourceName { info[MPMediaItemPropertyComments] = sourceName }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 每五秒刷新一次系统进度，其余时间由系统根据倍速自行推算。
    /// - Parameters:
    ///   - elapsedTime: 当前播放秒数。
    ///   - playbackRate: 当前实际播放倍率。
    private func updateNowPlayingInfoIfNeeded(elapsedTime: Double, playbackRate: Double) {
        guard abs(elapsedTime - lastNowPlayingUpdateTime) >= 5 else { return }
        lastNowPlayingUpdateTime = elapsedTime
        updateNowPlayingInfo(elapsedTime: elapsedTime, playbackRate: playbackRate)
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
                guard let self else { return }
                let message = self.playbackFailureMessage(error: item.error)
                self.stopDanmakuMatchingForPlaybackFailure()
                self.state = .failed(message)
                self.onPlaybackStateChanged?(false)
                self.onPlaybackFailed?(message)
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

    /// 标记媒体不可播放，并终止所有可能再次打开候选弹窗的弹幕任务。
    private func stopDanmakuMatchingForPlaybackFailure() {
        playbackHasFailed = true
        matchingTask?.cancel()
        matchingTask = nil
        candidates = []
        isShowingCandidates = false
    }

    /// 返回当前弹幕异步任务是否仍属于可播放媒体。
    private var canContinueDanmakuWork: Bool {
        !playbackHasFailed && !Task.isCancelled
    }

    /// 把底层 AVPlayer 错误转换为用户可执行的播放建议，避免只显示 Cannot Open。
    /// - Parameter error: AVPlayerItem 返回的底层错误。
    /// - Returns: 不包含播放地址或认证信息的错误说明。
    private func playbackFailureMessage(error: Error?) -> String {
        let urlExtension = currentPlaybackURL?.pathExtension.lowercased() ?? ""
        let nameExtension = URL(fileURLWithPath: currentDisplayName).pathExtension.lowercased()
        let container = urlExtension.isEmpty ? nameExtension : urlExtension
        let unsupportedContainers: Set<String> = ["mkv", "webm", "avi", "flv", "rm", "rmvb"]
        if unsupportedContainers.contains(container) {
            return "该视频是 \(container.uppercased()) 容器，Apple 系统播放器无法稳定解析。Jellyfin、Emby 或 Plex 媒体源会自动尝试服务端兼容流；WebDAV 直连请换用 MP4 / MOV / HLS，或先在服务器端转码。"
        }
        if let networkError = error as? URLError {
            return "读取媒体源失败（\(networkError.localizedDescription)）。请检查服务器是否在线、账号是否仍有效，以及视频地址是否允许分段读取。"
        }
        let detail = error?.localizedDescription ?? "当前编码或媒体流无法由系统播放器解码"
        return "\(detail)。请确认视频编码受 Apple 设备支持；媒体服务器来源可尝试开启转码后重试。"
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
        let value = currentTime ?? currentPlaybackTime
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

/// 接收通用 FFmpeg 播放内核的状态与时间回调。
extension PlayerViewModel: KSPlayerLayerDelegate {
    /// 同步准备、缓冲、暂停与结束状态到统一播放器界面。
    /// - Parameters:
    ///   - layer: 当前通用播放层。
    ///   - state: 内核播放状态。
    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        guard layer === universalPlayerLayer else { return }
        switch state {
        case .readyToPlay:
            localDuration = max(layer.player.duration, localDuration)
            mediaInfo.duration = Self.timeLabel(localDuration)
            loadUniversalMediaOptions(from: layer)
            self.state = .ready
            isBuffering = true
        case .buffering, .preparing:
            isBuffering = true
            onPlaybackStateChanged?(true)
        case .bufferFinished:
            localDuration = max(layer.player.duration, localDuration)
            mediaInfo.duration = Self.timeLabel(localDuration)
            isBuffering = false
            self.state = .ready
            onPlaybackStateChanged?(true)
        case .paused:
            isBuffering = false
            onPlaybackStateChanged?(false)
        case .playedToTheEnd:
            isBuffering = false
            PlaybackProgressStore.remove(for: mediaKey)
            onPlaybackStateChanged?(false)
            onPlaybackEnded?()
        case .error, .initialized:
            break
        }
    }

    /// 同步 FFmpeg 内核进度并保存断点，继续驱动弹幕时间轴。
    /// - Parameters:
    ///   - layer: 当前通用播放层。
    ///   - currentTime: 当前播放秒数。
    ///   - totalTime: 媒体总时长。
    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        guard layer === universalPlayerLayer else { return }
        if totalTime.isFinite, totalTime > 0 {
            localDuration = totalTime
            mediaInfo.duration = Self.timeLabel(totalTime)
        }
        let rate = layer.player.isPlaying ? Double(layer.player.playbackRate) : 0
        onTimeChanged?(currentTime, rate)
        saveProgressIfNeeded(currentTime: currentTime)
        updateNowPlayingInfoIfNeeded(elapsedTime: currentTime, playbackRate: rate)
    }

    /// 在系统播放器与 FFmpeg 内核均失败后显示可执行的错误，并允许媒体服务器转码兜底。
    /// - Parameters:
    ///   - layer: 当前通用播放层。
    ///   - error: 最终解码或读取错误。
    func player(layer: KSPlayerLayer, finish error: Error?) {
        guard layer === universalPlayerLayer, let error, !playbackHasFailed else { return }
        let detail = error.localizedDescription
        let message = "通用解码器无法读取该媒体：\(detail)。请检查文件是否完整，以及服务器是否允许 Range 分段读取。"
        stopDanmakuMatchingForPlaybackFailure()
        state = .failed(message)
        isBuffering = false
        onPlaybackStateChanged?(false)
        onPlaybackFailed?(message)
    }

    /// 接收缓冲统计；界面只展示统一的缓冲指示器，无需额外处理。
    /// - Parameters:
    ///   - layer: 当前通用播放层。
    ///   - bufferedCount: 已完成的缓冲次数。
    ///   - consumeTime: 本次缓冲耗时。
    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {
        guard layer === universalPlayerLayer else { return }
    }
}
