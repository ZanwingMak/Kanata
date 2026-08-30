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
    /// 网关返回的原始弹幕，偏移在客户端本地应用，调节时无需重新请求
    private(set) var rawItems: [DanmakuItem] = []
    private(set) var candidates: [ProviderCandidate] = []
    private(set) var parsed: ParsedTitle?
    private(set) var danmakuStats: String = ""
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
        state = .preparing("正在读取视频…")
        client = settings.makeClient()

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
        guard let client else {
            danmakuStats = "未配置网关地址"
            return
        }
        let parsedTitle = TitleParser.parse(url.lastPathComponent)
        parsed = parsedTitle
        seasonKey = "\(parsedTitle.title)|S\(parsedTitle.season ?? 1)"
        offset = OffsetStore.offset(
            seriesKey: parsedTitle.title,
            seasonKey: seasonKey ?? parsedTitle.title
        )

        danmakuStats = "正在匹配弹幕…"
        let fingerprint = try? FingerprintCalculator.compute(fileURL: url, duration: localDuration)

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
                danmakuStats = response.degraded.isEmpty
                    ? "未匹配到弹幕，可手动搜索"
                    : "未匹配到弹幕（\(response.degraded.map(\.rawValue).joined(separator: "、")) 不可用）"
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
            danmakuStats = error.requiresLogin ? "需要登录后才能获取弹幕" : "匹配失败：\(error.errorMessage)"
        } catch {
            danmakuStats = "匹配失败：\(error.localizedDescription)"
        }
    }

    /// 拉取指定候选的弹幕
    func loadDanmaku(for candidate: ProviderCandidate) async {
        guard let client else { return }
        isShowingCandidates = false
        danmakuStats = "正在加载弹幕…"
        do {
            let response = try await client.danmaku(
                refs: [DanmakuRef(source: candidate.source, platformEpisodeId: candidate.platformEpisodeId)]
            )
            rawItems = response.items
            // 本地与平台时长差异较大时提示用户校正（FR-SYNC-003）
            let hint = shouldHintTimeline(remote: candidate.duration) ? "，时长差异较大建议校正" : ""
            danmakuStats = "\(response.items.count) 条 · \(candidate.source.rawValue) · \(response.stats.elapsedMs)ms\(hint)"
            onItemsChanged?(shiftedItems)
        } catch let error as GatewayError {
            danmakuStats = "弹幕加载失败：\(error.errorMessage)"
        } catch {
            danmakuStats = "弹幕加载失败：\(error.localizedDescription)"
        }
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
