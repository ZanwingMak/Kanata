#if canImport(UIKit)
import KanataCore
import UIKit

/// 弹幕渲染视图。
///
/// 设计要点：
/// - 只接收「弹幕数组 + 播放时间 + 配置」，不做任何网络与业务逻辑（docs/02 §4.4）；
/// - 播放内核的时间回调较稀疏，这里用 CADisplayLink 在两次回调之间做插值，避免抖动；
/// - 文本预光栅化并缓存，每帧只改图层位置，保证高密度下的帧率（NFR-PERF-002）。
@MainActor
public final class DanmakuCanvasView: UIView {

    /// 屏幕上正在显示的一条弹幕
    private struct ActiveDanmaku {
        let layer: CALayer
        let mode: DanmakuMode
        /// 进入屏幕的播放时间
        let enterTime: Double
        /// 完全离开屏幕的播放时间
        let endTime: Double
        let width: Double
        let y: CGFloat
        /// 滚动速度（点/秒），静止弹幕为 0
        let speed: Double
    }

    /// 渲染配置。赋值后立即生效（FR-DMK-103 等要求实时生效）
    public var config = DanmakuRenderConfig() {
        didSet { applyConfigChange(previous: oldValue) }
    }

    private var allItems: [DanmakuItem] = []
    /// 经过模式、来源与屏蔽规则过滤后的弹幕
    private var visibleItems: [DanmakuItem] = []
    /// 下一条待上屏弹幕的下标
    private var cursor = 0
    private var active: [ActiveDanmaku] = []

    private var allocator = TrackAllocator()
    private let rasterizer = TextRasterizer()
    private var displayLink: CADisplayLink?
    private var lastLayoutSize = CGSize.zero

    /// 最近一次由播放器同步的时间
    private var lastSyncTime: Double = 0
    /// 同步发生时的宿主时钟，用于插值
    private var lastSyncHost: CFTimeInterval = 0
    private var rate: Double = 1
    private var isPlaying = false

    /// 当前推算出的播放时间
    private var currentTime: Double {
        guard isPlaying else { return lastSyncTime }
        return lastSyncTime + (CACurrentMediaTime() - lastSyncHost) * rate
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    /// 视图移出窗口时停掉渲染循环。
    /// CADisplayLink 会强引用 target，这里配合 DisplayLinkProxy 的弱引用避免视图无法释放。
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            updateDisplayLinkState()
        }
    }

    // MARK: - 对外接口

    /// 一次性装载整集弹幕。调用方负责保证按时间升序
    public func load(items: [DanmakuItem]) {
        allItems = items
        rebuildVisibleItems()
        reset()
        updateDisplayLinkState()
    }

    /// 同步播放器时间与倍速。
    /// 时间跳变超过 1 秒时判定为 seek，重建屏幕内容（FR-PLY-012）
    /// - Parameters:
    ///   - time: 播放器当前时间（秒）
    ///   - rate: 播放倍速，暂停时传 0
    public func sync(time: Double, rate: Double) {
        let drift = abs(time - currentTime)
        self.rate = rate > 0 ? rate : 1
        isPlaying = rate > 0
        lastSyncTime = time
        lastSyncHost = CACurrentMediaTime()
        if drift > 1.0 {
            reset()
        }
        updateDisplayLinkState()
    }

    /// 清空屏幕并把游标重新定位到当前时间
    public func reset() {
        for item in active { item.layer.removeFromSuperlayer() }
        active.removeAll()
        rebuildTracks()
        cursor = firstIndex(afterOrAt: currentTime)
    }

    // MARK: - 配置与过滤

    /// 配置变更后的增量处理：影响过滤的重建列表，影响排版的重置轨道
    private func applyConfigChange(previous: DanmakuRenderConfig) {
        if config.modeFilter != previous.modeFilter
            || config.sourceFilter != previous.sourceFilter
            || config.blockRules != previous.blockRules
            || config.mergeDuplicates != previous.mergeDuplicates {
            rebuildVisibleItems()
            reset()
            return
        }
        if config.fontScale != previous.fontScale
            || config.fontName != previous.fontName
            || config.bold != previous.bold
            || config.strokeWidth != previous.strokeWidth {
            rasterizer.clear()
            reset()
            return
        }
        if config.displayArea != previous.displayArea
            || config.maxTracks != previous.maxTracks
            || config.lineSpacing != previous.lineSpacing {
            reset()
            return
        }
        if config.opacity != previous.opacity {
            for item in active { item.layer.opacity = Float(config.opacity) }
        }
        if !config.enabled {
            for item in active { item.layer.removeFromSuperlayer() }
            active.removeAll()
        }
        updateDisplayLinkState()
    }

    /// 按当前配置重建可见弹幕列表
    private func rebuildVisibleItems() {
        let rules = config.blockRules
        let regexes = rules.regexPatterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var seenContents = Set<String>()
        var seenMergeKeys = Set<String>()
        var duplicateCount: [String: Int] = [:]

        if config.mergeDuplicates {
            for item in allItems {
                let key = "\(Int(item.time / 2))|\(item.content)"
                duplicateCount[key, default: 0] += 1
            }
        }

        visibleItems = allItems.compactMap { item in
            guard config.modeFilter.contains(item.mode) else { return nil }
            if !config.sourceFilter.isEmpty && !config.sourceFilter.contains(item.source) { return nil }
            if let hash = item.senderHash, rules.senderHashes.contains(hash) { return nil }
            if rules.blockColorful && item.color != 16_777_215 { return nil }
            if rules.keywords.contains(where: { !$0.isEmpty && item.content.contains($0) }) { return nil }
            let range = NSRange(item.content.startIndex..., in: item.content)
            if regexes.contains(where: { $0.firstMatch(in: item.content, range: range) != nil }) { return nil }
            if rules.blockRepeated, !seenContents.insert(item.content).inserted {
                return nil
            }
            guard config.mergeDuplicates else { return item }
            let mergeKey = "\(Int(item.time / 2))|\(item.content)"
            guard seenMergeKeys.insert(mergeKey).inserted else { return nil }
            return DanmakuItem(
                id: item.id,
                time: item.time,
                mode: item.mode,
                fontSize: item.fontSize,
                color: item.color,
                content: item.content,
                source: item.source,
                senderHash: item.senderHash,
                createdAt: item.createdAt,
                weight: item.weight,
                dupCount: duplicateCount[mergeKey]
            )
        }
    }

    /// 按显示区域与字号重新计算轨道数量
    private func rebuildTracks() {
        let fontSize = config.resolvedFontSize(itemFontSize: 25, viewWidth: bounds.width)
        let lineHeight = fontSize * 1.15 + config.lineSpacing
        let areaHeight = bounds.height * config.displayArea.heightRatio
        let count = config.maxTracks > 0
            ? config.maxTracks
            : max(Int(areaHeight / max(lineHeight, 1)), 1)
        allocator.reset(trackCount: count)
    }

    /// 二分查找第一条时间不早于给定值的弹幕下标
    private func firstIndex(afterOrAt time: Double) -> Int {
        var low = 0
        var high = visibleItems.count
        while low < high {
            let mid = (low + high) / 2
            if visibleItems[mid].time < time { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - 渲染循环

    /// 仅在画布尺寸变化时重建轨道，避免 SwiftUI 状态刷新导致弹幕被反复清空。
    public override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        reset()
    }

    /// 根据播放状态与开关决定是否运行渲染循环，避免无谓耗电
    private func updateDisplayLinkState() {
        let shouldRun = isPlaying && config.enabled && !visibleItems.isEmpty && window != nil
        if shouldRun, displayLink == nil {
            let proxy = DisplayLinkProxy(target: self)
            let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.handle))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !shouldRun, displayLink != nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc fileprivate func tick() {
        let now = currentTime
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spawn(until: now)
        advance(to: now)
        CATransaction.commit()
    }

    /// 把到达显示时间的弹幕加入屏幕
    private func spawn(until now: Double) {
        let screenWidth = bounds.width
        guard screenWidth > 0 else { return }

        while cursor < visibleItems.count, visibleItems[cursor].time <= now {
            let item = visibleItems[cursor]
            cursor += 1
            // 落后超过一屏时长的弹幕直接跳过，避免 seek 后瞬间堆积
            guard now - item.time < config.scrollDuration else { continue }
            // 密度限流：超过上限时丢弃低权重弹幕（FR-DMK-104）
            if active.count >= config.densityLimit, (item.weight ?? 5) < 5 { continue }
            appendDanmaku(item, at: now, screenWidth: screenWidth)
        }
    }

    /// 为单条弹幕分配轨道并创建图层
    private func appendDanmaku(_ item: DanmakuItem, at now: Double, screenWidth: CGFloat) {
        switch config.displayArea {
        case .topOnly where item.mode != .top,
             .bottomOnly where item.mode != .bottom:
            return
        default:
            break
        }

        let fontSize = config.resolvedFontSize(itemFontSize: item.fontSize, viewWidth: bounds.width)
        var text = item.content
        if config.mergeDuplicates, let count = item.dupCount, count > 1 {
            text += " ×\(count)"
        }
        let image = rasterizer.image(
            text: text,
            fontSize: fontSize,
            color: item.color,
            bold: config.bold,
            strokeWidth: config.strokeWidth,
            fontName: config.fontName
        )
        let width = image.size.width
        let height = image.size.height
        let lineHeight = height + config.lineSpacing

        let track: Int?
        let speed: Double
        let endTime: Double
        switch item.mode {
        case .scroll, .reverse:
            track = allocator.allocateScroll(
                now: now,
                width: width,
                screenWidth: screenWidth,
                duration: config.scrollDuration
            )
            speed = (screenWidth + width) / config.scrollDuration
            endTime = now + config.scrollDuration
        case .top:
            track = allocator.allocateTop(now: now, duration: config.staticDuration)
            speed = 0
            endTime = now + config.staticDuration
        case .bottom:
            track = allocator.allocateBottom(now: now, duration: config.staticDuration)
            speed = 0
            endTime = now + config.staticDuration
        }
        guard let track else { return }

        let y: CGFloat
        if item.mode == .bottom {
            y = bounds.height - CGFloat(track + 1) * lineHeight
        } else {
            y = CGFloat(track) * lineHeight
        }

        let sublayer = CALayer()
        sublayer.contents = image.cgImage
        sublayer.contentsScale = image.scale
        sublayer.opacity = Float(config.opacity)
        sublayer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        sublayer.anchorPoint = CGPoint(x: 0, y: 0)

        let startX: CGFloat
        switch item.mode {
        case .scroll: startX = screenWidth
        case .reverse: startX = -width
        case .top, .bottom: startX = (screenWidth - width) / 2
        }
        sublayer.position = CGPoint(x: startX, y: y)
        layer.addSublayer(sublayer)

        active.append(ActiveDanmaku(
            layer: sublayer,
            mode: item.mode,
            enterTime: now,
            endTime: endTime,
            width: width,
            y: y,
            speed: item.mode == .reverse ? -speed : speed
        ))
    }

    /// 更新在屏弹幕位置并回收已离场的图层
    private func advance(to now: Double) {
        let screenWidth = bounds.width
        var survivors: [ActiveDanmaku] = []
        survivors.reserveCapacity(active.count)

        for item in active {
            if now >= item.endTime || now < item.enterTime {
                item.layer.removeFromSuperlayer()
                continue
            }
            if item.speed != 0 {
                let elapsed = now - item.enterTime
                let origin: CGFloat = item.speed > 0 ? screenWidth : -CGFloat(item.width)
                item.layer.position = CGPoint(x: origin - CGFloat(item.speed * elapsed), y: item.y)
            }
            survivors.append(item)
        }
        active = survivors
    }
}
/// CADisplayLink 的弱引用转发器。
/// CADisplayLink 会强引用 target，直接把视图作为 target 会导致视图无法释放。
@MainActor
private final class DisplayLinkProxy: NSObject {
    private weak var target: DanmakuCanvasView?

    init(target: DanmakuCanvasView) {
        self.target = target
        super.init()
    }

    @objc func handle() {
        target?.tick()
    }
}
#endif
