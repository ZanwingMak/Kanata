import AVFoundation
import KanataCore
import KanataRender
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// 播放画面的缩放方式。
enum PlayerScalingMode: String, CaseIterable, Identifiable {
    case fit
    case fill
    case stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: "适应"
        case .fill: "填充"
        case .stretch: "拉伸"
        }
    }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }

    /// 返回通用解码内核对应的 UIKit 缩放模式。
    var contentMode: UIView.ContentMode {
        switch self {
        case .fit: .scaleAspectFit
        case .fill: .scaleAspectFill
        case .stretch: .scaleToFill
        }
    }
}

/// 当前视频使用的读取路径；自动模式会在原始流失败后切换服务器兼容流。
enum PlaybackRouteMode: String, CaseIterable, Identifiable {
    case automatic
    case direct
    case compatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "自动（推荐）"
        case .direct: "原始流"
        case .compatible: "兼容流"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "依次尝试系统解码、通用解码与媒体服务器兼容流"
        case .direct: "直接读取原始文件，MKV 等格式自动使用通用解码器"
        case .compatible: "直接请求 Jellyfin、Emby 或 Plex 的兼容 HLS"
        }
    }
}

/// 合集播放结束后的处理方式。
enum PlaybackQueueMode: String, CaseIterable, Identifiable {
    case continuous
    case stop
    case repeatOne
    case repeatAll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continuous: "自动下一集"
        case .stop: "播完暂停"
        case .repeatOne: "单集循环"
        case .repeatAll: "列表循环"
        }
    }
}

/// 播放器睡眠定时器选项。
enum SleepTimerMode: String, CaseIterable, Identifiable {
    case off
    case minutes15
    case minutes30
    case minutes60
    case endOfEpisode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .minutes15: "15 分钟"
        case .minutes30: "30 分钟"
        case .minutes60: "60 分钟"
        case .endOfEpisode: "播完本集"
        }
    }

    var seconds: Double? {
        switch self {
        case .minutes15: 15 * 60
        case .minutes30: 30 * 60
        case .minutes60: 60 * 60
        case .off, .endOfEpisode: nil
        }
    }
}

/// 播放器专用按钮样式；保留按压反馈但不改变尺寸，避免焦点或触控造成画面缩放。
private struct PlayerControlButtonStyle: ButtonStyle {
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    /// 构建不带缩放动画的播放器按钮。
    /// - Parameter configuration: SwiftUI 按钮按压状态。
    /// - Returns: 仅改变透明度的按钮内容。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            #if os(tvOS)
            .focusEffectDisabled()
            .foregroundStyle(isFocused ? KanataTheme.accent : Color.white)
            .shadow(color: .black.opacity(0.82), radius: 4, y: 2)
            .shadow(color: KanataTheme.accent.opacity(isFocused ? 0.72 : 0), radius: 12)
            .scaleEffect(isFocused ? 1.12 : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
            #else
            .scaleEffect(1)
            .animation(nil, value: configuration.isPressed)
            #endif
    }
}

#if os(tvOS)
/// 把 Siri Remote 触控区的连续平移手势转发给 SwiftUI 时间轴。
private struct TVRemotePanGestureView: UIViewRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    /// 创建负责接收 tvOS 间接触控事件的协调器。
    /// - Returns: 保存最新回调并处理平移状态的协调器。
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// 创建透明手势承载视图并注册遥控器平移识别器。
    /// - Parameter context: SwiftUI 表示层上下文。
    /// - Returns: 不参与绘制、只接收触控区手势的视图。
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        recognizer.allowedPressTypes = []
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        context.coordinator.recognizer = recognizer
        return view
    }

    /// 同步暂停状态和最新 SwiftUI 回调。
    /// - Parameters:
    ///   - uiView: 当前透明手势视图。
    ///   - context: SwiftUI 表示层上下文。
    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    /// 管理遥控器连续平移识别与滑动速度投影。
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TVRemotePanGestureView
        weak var recognizer: UIPanGestureRecognizer?

        /// 保存首次创建时的 SwiftUI 表示层参数。
        /// - Parameter parent: 当前手势视图配置。
        init(parent: TVRemotePanGestureView) {
            self.parent = parent
        }

        /// 连续转发横向位移，并在松手时加入轻量速度投影。
        /// - Parameter recognizer: 当前遥控器平移识别器。
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            let translation = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .began, .changed:
                parent.onChanged(translation)
            case .ended:
                let velocity = recognizer.velocity(in: recognizer.view).x
                parent.onEnded(translation + velocity * 0.12)
            case .cancelled, .failed:
                parent.onEnded(translation)
            default:
                break
            }
        }

        /// 仅接管暂停状态下的横向滑动，纵向手势继续交给焦点系统。
        /// - Parameter gestureRecognizer: 即将开始识别的平移手势。
        /// - Returns: 横向速度占优且当前允许拖动时返回 true。
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard parent.isEnabled,
                  let recognizer = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = recognizer.velocity(in: recognizer.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        /// 允许遥控器平移与 SwiftUI 的确认点击共存。
        /// - Parameters:
        ///   - gestureRecognizer: 当前平移识别器。
        ///   - otherGestureRecognizer: 同一视图层级中的其他识别器。
        /// - Returns: 始终允许并行识别。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// Apple TV 专用进度控件；获得焦点后可用遥控器左右键跳转。
private struct TVSeekBar: View {
    let value: Double
    let duration: Double
    let isPlaying: Bool
    let onScrubChanged: (Double) -> Void
    let onSeek: (Double) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onTogglePlayback: () -> Void
    @Environment(\.isFocused) private var isFocused
    @State private var scrubStartValue: Double?
    @State private var directionalSeekTarget: Double?
    @State private var directionalRepeatCount = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(isFocused ? 0.32 : 0.24))
                Capsule()
                    .fill(KanataTheme.accent)
                    .frame(width: width * progress)
                Circle()
                    .fill(.white)
                    .frame(width: isFocused ? 24 : 16, height: isFocused ? 24 : 16)
                    .offset(x: max(0, width * progress - (isFocused ? 12 : 8)))
                    .opacity(isFocused ? 1 : 0.82)
            }
            .frame(height: isFocused ? 14 : 8)
            .frame(maxHeight: .infinity, alignment: .center)
            .overlay {
                TVRemotePanGestureView(
                    isEnabled: isFocused && !isPlaying,
                    onChanged: { updatePausedScrub(translation: $0, width: width) },
                    onEnded: { finishPausedScrub(translation: $0, width: width) }
                )
            }
        }
        .frame(height: 38)
        .contentShape(Rectangle())
        .focusable()
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isFocused ? KanataTheme.accent.opacity(0.9) : .clear, lineWidth: 2)
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .all, action: handleDirectionalKeyPress)
        .onMoveCommand(perform: handleMove)
        .onTapGesture(perform: onTogglePlayback)
        .onChange(of: isFocused) { _, focused in
            if !focused { finishDirectionalSeek() }
        }
        .onDisappear(perform: finishDirectionalSeek)
        .accessibilityLabel("播放进度")
        .accessibilityValue("已播放 \(Int(value)) 秒，共 \(Int(duration)) 秒")
        .accessibilityAdjustableAction(adjustAccessibilityValue)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    /// 返回限制在 0 到 1 之间的播放进度。
    private var progress: CGFloat {
        guard duration.isFinite, duration > 0 else { return 0 }
        return CGFloat(min(max(value / duration, 0), 1))
    }

    /// 暂停时根据遥控器横向滑动持续更新进度预览。
    /// - Parameters:
    ///   - translation: 当前累计水平位移。
    ///   - width: 时间轴可用宽度。
    private func updatePausedScrub(translation: CGFloat, width: CGFloat) {
        guard isFocused, !isPlaying else { return }
        let start = scrubStartValue ?? value
        if scrubStartValue == nil { scrubStartValue = start }
        onScrubChanged(scrubTarget(from: start, translation: translation, width: width))
    }

    /// 遥控器滑动结束后提交带速度投影的目标进度。
    /// - Parameters:
    ///   - translation: 已包含松手速度投影的水平位移。
    ///   - width: 时间轴可用宽度。
    private func finishPausedScrub(translation: CGFloat, width: CGFloat) {
        guard let start = scrubStartValue, isFocused, !isPlaying else {
            scrubStartValue = nil
            return
        }
        scrubStartValue = nil
        onSeek(scrubTarget(from: start, translation: translation, width: width))
    }

    /// 按时间轴宽度和滑动距离计算加速后的目标时间。
    /// - Parameters:
    ///   - start: 本次滑动开始时的播放时间。
    ///   - translation: 遥控器触控区的水平位移。
    ///   - width: 时间轴可用宽度。
    /// - Returns: 限制在媒体时长内的目标时间。
    private func scrubTarget(from start: Double, translation: CGFloat, width: CGFloat) -> Double {
        let acceleratedProgress = Double(translation / max(width, 1)) * 1.8
        return min(max(start + duration * acceleratedProgress, 0), duration)
    }

    /// 处理遥控器方向键的按下、连发与松开阶段，长按时连续加速预览进度。
    /// - Parameter press: SwiftUI 转发的左右方向按键事件。
    /// - Returns: 焦点在时间轴上时接管事件，否则交回系统。
    private func handleDirectionalKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard isFocused else { return .ignored }
        let direction = press.key == .leftArrow ? -1.0 : 1.0
        if press.phase.contains(.down) {
            directionalRepeatCount = 0
            updateDirectionalSeek(direction: direction, isRepeated: false)
        } else if press.phase.contains(.repeat) {
            directionalRepeatCount += 1
            updateDirectionalSeek(direction: direction, isRepeated: true)
        } else if press.phase.contains(.up) {
            finishDirectionalSeek()
        }
        return .handled
    }

    /// 更新方向键连续拖动的预览位置，按住时间越长步进越快。
    /// - Parameters:
    ///   - direction: -1 表示后退，1 表示前进。
    ///   - isRepeated: 当前是否为系统产生的按键连发事件。
    private func updateDirectionalSeek(direction: Double, isRepeated: Bool) {
        let baseStep = duration >= 7_200 ? 30.0 : 10.0
        let acceleration = isRepeated ? min(0.5 + Double(directionalRepeatCount) / 10, 3) : 1
        let start = directionalSeekTarget ?? value
        let target = min(max(start + direction * baseStep * acceleration, 0), duration)
        directionalSeekTarget = target
        onScrubChanged(target)
    }

    /// 在方向键松开或时间轴失焦时统一提交最终播放位置。
    private func finishDirectionalSeek() {
        guard let target = directionalSeekTarget else { return }
        directionalSeekTarget = nil
        directionalRepeatCount = 0
        onSeek(target)
    }

    /// 处理遥控器方向键，短视频每次十秒，长视频每次三十秒。
    /// - Parameter direction: Siri Remote 当前移动方向。
    private func handleMove(_ direction: MoveCommandDirection) {
        let step = duration >= 7_200 ? 30.0 : 10.0
        switch direction {
        case .left:
            onSeek(max(0, value - step))
        case .right:
            onSeek(min(duration, value + step))
        case .up:
            onMoveUp()
        case .down:
            onMoveDown()
        @unknown default:
            break
        }
    }

    /// 支持辅助功能的增减手势调整播放位置。
    /// - Parameter direction: 辅助功能请求的增减方向。
    private func adjustAccessibilityValue(_ direction: AccessibilityAdjustmentDirection) {
        let step = duration >= 7_200 ? 30.0 : 10.0
        switch direction {
        case .increment:
            onSeek(min(duration, value + step))
        case .decrement:
            onSeek(max(0, value - step))
        @unknown default:
            break
        }
    }
}

/// 电视播放器内可由 Siri Remote 到达的焦点目标。
private enum TVPlayerFocus: Hashable {
    case background
    case back
    case more
    case progress
    case rewind
    case previousEpisode
    case playPause
    case forward
    case nextEpisode
    case playlist
    case danmakuToggle
    case danmakuSettings
    case manualMatch
    case failureCompatibility
    case failureRetry
    case failureBack
}
#endif

#if os(iOS)
/// iPhone 与 iPad 播放画面的连续手势类型。
private enum PlayerGestureMode {
    case seek
    case brightness
    case volume
}
#endif

/// 播放页。视频、弹幕、控制三层叠加。
struct PlayerScreen: View {
    let items: [LibraryItem]
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel = PlayerViewModel()
    @State private var canvasBridge = DanmakuCanvasBridge()
    @State private var surfaceController = PlayerSurfaceController()
    @State private var isShowingControls = true
    @State private var isShowingDanmakuPanel = false
    @State private var isShowingPlaybackPanel = false
    @State private var isShowingPlaylist = false
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var isSeeking = false
    @State private var pendingSeekTarget: Double?
    @State private var isImportingDanmaku = false
    @State private var isImportingSubtitle = false
    @State private var danmakuOperationError: String?
    /// 短暂显示的操作反馈（FR-PLY-403）
    @State private var osdText: String?
    @State private var osdTask: Task<Void, Never>?
    @State private var controlsTask: Task<Void, Never>?
    @State private var sleepTask: Task<Void, Never>?
    @State private var scalingMode = PlayerScalingMode.fit
    @State private var activeIndex: Int
    @State private var queueMode = PlaybackQueueMode.continuous
    @State private var sleepMode = SleepTimerMode.off
    @State private var isInteractionLocked = false
    @State private var externalSubtitleCues: [ExternalSubtitleCue] = []
    @State private var externalSubtitleName: String?
    @State private var externalSubtitleResources: [ExternalSubtitleResource] = []
    @State private var selectedExternalSubtitleID: String?
    @State private var externalSubtitleOffset = 0.0
    @State private var isExternalSubtitleEnabled = true
    @State private var isFetchingExternalSubtitles = false
    @State private var subtitleFetchTask: Task<Void, Never>?
    @State private var skipSegment = PlaybackSkipSegment()
    @State private var isConfirmingExit = false
    @State private var resumesAfterExitCancellation = false
    @State private var isUsingCompatibilityStream = false
    @State private var forcesUniversalPlayer = false
    @State private var playbackRouteMode = PlaybackRouteMode.automatic
    #if os(tvOS)
    @FocusState private var tvFocusedControl: TVPlayerFocus?
    #endif
    #if os(iOS)
    @State private var gestureMode: PlayerGestureMode?
    @State private var gestureStartValue: Double = 0
    @State private var isLandscapeFullscreen = false
    @State private var isChangingOrientation = false
    #endif

    /// 创建单视频或合集播放器，并定位用户点击的起始条目。
    /// - Parameters:
    ///   - items: 同一合集的有序媒体条目，单视频时只有一项。
    ///   - initialItemID: 用户点击的起始条目 ID。
    init(items: [LibraryItem], initialItemID: String) {
        let playable = items.filter { $0.resolveURL() != nil }
        let values = playable.isEmpty ? items : playable
        self.items = values
        let index = values.firstIndex(where: { $0.id == initialItemID }) ?? 0
        self._activeIndex = State(initialValue: index)
    }

    /// 当前正在播放的媒体库条目。
    private var activeItem: LibraryItem { items[min(max(activeIndex, 0), max(items.count - 1, 0))] }

    var body: some View {
        @Bindable var settings = settings

        ZStack {
            Color.black.ignoresSafeArea()
            if viewModel.usesUniversalPlayer {
                UniversalVideoSurface(
                    playerLayer: viewModel.universalPlayerLayer,
                    contentMode: scalingMode.contentMode
                )
                .ignoresSafeArea()
            } else {
                VideoSurface(
                    player: viewModel.player,
                    videoGravity: scalingMode.gravity,
                    controller: surfaceController
                )
                .ignoresSafeArea()
            }

            GeometryReader { proxy in
                let viewport = danmakuViewport(
                    size: proxy.size,
                    safeAreaInsets: proxy.safeAreaInsets
                )
                DanmakuOverlay(config: settings.danmakuConfig) { view in
                    canvasBridge.attach(view)
                }
                .frame(width: viewport.width, height: viewport.height)
                .position(x: viewport.midX, y: viewport.midY)
            }
            .ignoresSafeArea(.container, edges: .horizontal)
            .allowsHitTesting(false)

            externalSubtitleOverlay

            interactionLayer

            skipSegmentOverlay

            if shouldShowPlayerControls {
                if isInteractionLocked {
                    lockedControlsLayer
                } else {
                    controlsLayer
                }
            }
            if viewModel.isBuffering, case .ready = viewModel.state {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(16)
                    .background(.black.opacity(0.55), in: Circle())
                    .allowsHitTesting(false)
            }
            stateOverlay
            if let osdText {
                Text(osdText)
                    .font(.title3.monospacedDigit())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        #if os(tvOS)
        .onPlayPauseCommand {
            togglePlayback()
            setControlsVisible(true)
        }
        .onExitCommand(perform: handleTVExitCommand)
        .onChange(of: shouldShowPlayerControls) { _, visible in
            synchronizeTVPlayerFocus(isVisible: visible)
        }
        .onChange(of: viewModel.state) { _, state in
            synchronizeTVPlayerFocus(for: state)
        }
        .onChange(of: tvFocusedControl) { _, focus in
            handleTVControlFocusChange(focus)
        }
        #endif
        .kanataStatusBarHidden()
        .interactiveDismissDisabled()
        .onAppear { setIdleTimerDisabled(true) }
        .task(id: activeItem.id) {
            isUsingCompatibilityStream = playbackRouteMode == .compatible
            forcesUniversalPlayer = false
            await openActiveItem()
        }
        .onChange(of: sleepMode) { _, value in
            configureSleepTimer(value)
        }
        .onDisappear {
            osdTask?.cancel()
            controlsTask?.cancel()
            sleepTask?.cancel()
            subtitleFetchTask?.cancel()
            viewModel.teardown()
            setIdleTimerDisabled(false)
            #if os(iOS)
            if isLandscapeFullscreen {
                PlayerOrientationController.requestLandscape(false) { _ in }
            }
            #endif
        }
        .kanataModal(isPresented: $isShowingDanmakuPanel) {
            DanmakuSettingsPanel(
                config: $settings.danmakuConfig,
                offset: $viewModel.offset,
                onOffsetChanged: { showOSD(String(format: "弹幕延迟 %@%.1fs", viewModel.offset >= 0 ? "+" : "", viewModel.offset)) }
            )
            .presentationDetents([.medium, .large])
        }
        .kanataModal(isPresented: $isShowingPlaybackPanel) {
            PlaybackOptionsPanel(
                viewModel: viewModel,
                scalingMode: $scalingMode,
                queueMode: $queueMode,
                sleepMode: $sleepMode,
                playbackRouteMode: playbackRouteMode,
                playbackPathLabel: playbackPathLabel,
                isCompatibilityAvailable: isCompatibilityAvailable,
                hasExternalSubtitle: !externalSubtitleCues.isEmpty,
                externalSubtitleName: externalSubtitleName,
                externalSubtitleResources: externalSubtitleResources,
                selectedExternalSubtitleID: selectedExternalSubtitleID,
                externalSubtitleEnabled: $isExternalSubtitleEnabled,
                externalSubtitleOffset: $externalSubtitleOffset,
                isFetchingExternalSubtitles: isFetchingExternalSubtitles,
                skipSegment: skipSegment,
                onImportDanmaku: {
                    isShowingPlaybackPanel = false
                    isImportingDanmaku = true
                },
                onMatchDanmaku: {
                    isShowingPlaybackPanel = false
                    viewModel.isShowingCandidates = true
                },
                onImportSubtitle: {
                    isShowingPlaybackPanel = false
                    isImportingSubtitle = true
                },
                onFetchExternalSubtitles: fetchExternalSubtitles,
                onSelectExternalSubtitle: selectExternalSubtitle,
                onMarkIntro: { updateSkipSegment(introEnd: currentTime) },
                onMarkOutro: { updateSkipSegment(outroStart: currentTime) },
                onClearSkipSegment: { clearSkipSegment() },
                onSelectPlaybackRoute: selectPlaybackRoute,
                onPictureInPicture: {
                    if !viewModel.toggleUniversalPictureInPicture() {
                        surfaceController.togglePictureInPicture()
                    }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .kanataModal(isPresented: $isShowingPlaylist) {
            PlaylistPicker(
                items: items,
                currentItemID: activeItem.id,
                onSelect: selectItem
            )
        }
        .kanataModal(isPresented: $viewModel.isShowingCandidates) {
            CandidatePicker(viewModel: viewModel)
        }
        .kanataFileImporter(
            isPresented: $isImportingDanmaku,
            allowedContentTypes: danmakuFileTypes,
            allowsMultipleSelection: false,
            onCompletion: handleDanmakuImport
        )
        .kanataFileImporter(
            isPresented: $isImportingSubtitle,
            allowedContentTypes: subtitleFileTypes,
            allowsMultipleSelection: false,
            onCompletion: handleSubtitleImport
        )
        .alert(
            "播放操作失败",
            isPresented: Binding(
                get: { danmakuOperationError != nil },
                set: { if !$0 { danmakuOperationError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(danmakuOperationError ?? "未知错误")
        }
        .alert("退出播放器？", isPresented: $isConfirmingExit) {
            Button("继续观看", role: .cancel) { cancelExitConfirmation() }
            Button("退出并返回首页", role: .destructive) { dismiss() }
        } message: {
            Text("当前播放进度会自动保存，下次可以继续观看。")
        }
    }

    /// 仅在播放器已经准备完成时显示控制层，避免错误页底部残留不可用按钮。
    private var shouldShowPlayerControls: Bool {
        guard isShowingControls else { return false }
        if case .ready = viewModel.state { return true }
        return false
    }

    /// 当前是否正在显示播放失败操作，供 tvOS 排除透明画面焦点。
    private var isPlaybackFailed: Bool {
        if case .failed = viewModel.state { return true }
        return false
    }

    /// 计算弹幕可用画布；竖屏避开顶部栏，横屏只保留上下间距且不改变左右范围。
    /// - Parameters:
    ///   - size: 播放器容器尺寸。
    ///   - safeAreaInsets: 当前方向的系统安全区。
    /// - Returns: 弹幕允许显示的本地坐标矩形。
    private func danmakuViewport(
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        let portrait = size.height > size.width
        let protectedTop = safeAreaInsets.top + (portrait ? 14 : 12)
        let protectedBottom = size.height - safeAreaInsets.bottom - (portrait ? 6 : 12)
        let left = bounds.minX
        let right = bounds.maxX
        let top = max(bounds.minY, protectedTop)
        let bottom = min(bounds.maxY, protectedBottom)
        guard right - left > 1, bottom - top > 1 else { return bounds }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// 在画面底部显示当前外挂字幕，避免遮挡系统安全区和播放控制。
    @ViewBuilder
    private var externalSubtitleOverlay: some View {
        if isExternalSubtitleEnabled,
           let cue = activeSubtitleCue(at: currentTime - externalSubtitleOffset) {
            VStack {
                Spacer()
                Text(cue.text)
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 1.5, x: 0, y: 1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.horizontal, 24)
                    .padding(.bottom, isShowingControls ? 112 : 38)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// 在片头或片尾区间显示清晰的一键跳过操作。
    @ViewBuilder
    private var skipSegmentOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if let introEnd = skipSegment.introEnd,
                   currentTime >= 0.5,
                   currentTime < introEnd - 0.5 {
                    Button("跳过片头") {
                        commitSeek(to: introEnd)
                        showOSD("已跳过片头")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.72))
                } else if let outroStart = skipSegment.outroStart,
                          currentTime >= outroStart,
                          currentTime < viewModel.duration - 1 {
                    Button(activeIndex < items.count - 1 ? "播放下一集" : "结束播放") {
                        if activeIndex < items.count - 1 {
                            moveEpisode(by: 1)
                        } else {
                            commitSeek(to: viewModel.duration)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.72))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, isShowingControls ? 106 : 30)
        }
    }

    /// 使用二分查找定位当前时间覆盖的外挂字幕。
    /// - Parameter time: 已扣除字幕延迟的播放秒数。
    /// - Returns: 当前应显示的字幕；空档时返回 nil。
    private func activeSubtitleCue(at time: Double) -> ExternalSubtitleCue? {
        guard !externalSubtitleCues.isEmpty else { return nil }
        var lower = 0
        var upper = externalSubtitleCues.count - 1
        var candidate: ExternalSubtitleCue?
        while lower <= upper {
            let middle = (lower + upper) / 2
            let cue = externalSubtitleCues[middle]
            if cue.start <= time {
                candidate = cue
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        guard let candidate, time <= candidate.end else { return nil }
        return candidate
    }

    /// 覆盖在视频与弹幕之上的手势层；控制按钮出现时仍由上层按钮优先响应。
    @ViewBuilder
    private var interactionLayer: some View {
        if isInteractionLocked {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { setControlsVisible(!isShowingControls) }
                #if os(tvOS)
                .focusable(!shouldShowPlayerControls && !isPlaybackFailed)
                .focused($tvFocusedControl, equals: .background)
                .onMoveCommand(perform: handleTVRemoteMove)
                #endif
        } else {
            Color.clear
                .contentShape(Rectangle())
                #if os(tvOS)
                .onTapGesture(perform: handleTVBackgroundConfirm)
                .focusable(!shouldShowPlayerControls && !isPlaybackFailed)
                .focused($tvFocusedControl, equals: .background)
                .onMoveCommand(perform: handleTVRemoteMove)
                #else
                .onTapGesture(count: 2) {
                    togglePlayback()
                    showOSD(isPlaying ? "播放" : "暂停")
                }
                .onTapGesture {
                    setControlsVisible(!isShowingControls)
                }
                .gesture(playerDragGesture)
                #endif
        }
    }

    /// 锁屏状态只保留解锁入口，避免其他触控误操作。
    private var lockedControlsLayer: some View {
        HStack {
            Button {
                isInteractionLocked = false
                showOSD("操作已解锁")
            } label: {
                VStack(spacing: 6) {
                    controlSymbol("lock.fill", prominent: true)
                    Text("防误触已开启\n点此解锁")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("解锁播放器操作")
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(.black.opacity(0.08))
    }

    #if os(iOS)
    /// 横向拖动快进/后退，纵向拖动左侧亮度、右侧音量。
    private var playerDragGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                if gestureMode == nil {
                    controlsTask?.cancel()
                    if abs(value.translation.width) >= abs(value.translation.height) {
                        gestureMode = .seek
                        gestureStartValue = currentTime
                        isSeeking = true
                    } else if value.startLocation.x < UIScreen.main.bounds.width / 2 {
                        gestureMode = .brightness
                        gestureStartValue = Double(UIScreen.main.brightness)
                    } else {
                        gestureMode = .volume
                        gestureStartValue = viewModel.volume
                    }
                }
                switch gestureMode {
                case .seek:
                    let span = min(max(viewModel.duration / 8, 30), 300)
                    currentTime = min(
                        max(gestureStartValue + Double(value.translation.width / 280) * span, 0),
                        max(viewModel.duration, 0)
                    )
                    osdText = "\(value.translation.width >= 0 ? "快进" : "后退") · \(timeLabel(currentTime))"
                case .brightness:
                    let value = min(max(gestureStartValue - Double(value.translation.height / 300), 0.05), 1)
                    UIScreen.main.brightness = CGFloat(value)
                    osdText = "亮度 · \(Int(value * 100))%"
                case .volume:
                    let volume = min(max(gestureStartValue - Double(value.translation.height / 300), 0), 1)
                    viewModel.setVolume(volume)
                    osdText = "音量 · \(Int(volume * 100))%"
                case nil:
                    break
                }
            }
            .onEnded { _ in
                let finalText = osdText
                if gestureMode == .seek {
                    commitSeek(to: currentTime)
                }
                gestureMode = nil
                if let finalText { showOSD(finalText) }
                scheduleControlsHide()
            }
    }
    #endif

    /// 根据播放器加载状态显示进度或可恢复的错误提示。
    @ViewBuilder
    private var stateOverlay: some View {
        switch viewModel.state {
        case .preparing(let message):
            VStack(spacing: 12) {
                ProgressView()
                Text(message).font(.callout)
            }
            .padding(20)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
        case .failed(let message):
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(KanataTheme.warning)
                Text("无法播放视频")
                    .font(.title.bold())
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.74))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)
                HStack(spacing: 16) {
                    if !isUsingCompatibilityStream, isCompatibilityAvailable {
                        Button("兼容播放") { retryWithCompatibilityStream() }
                            .buttonStyle(KanataPrimaryButtonStyle())
                            .frame(width: 220)
                            #if os(tvOS)
                            .focused($tvFocusedControl, equals: .failureCompatibility)
                            #endif
                    }
                    Button("重试") {
                        Task { await openActiveItem() }
                    }
                    .buttonStyle(KanataSecondaryButtonStyle())
                    .frame(width: 220)
                    #if os(tvOS)
                    .focused($tvFocusedControl, equals: .failureRetry)
                    #endif
                    Button("返回") { handleBack() }
                        .buttonStyle(KanataSecondaryButtonStyle())
                        .frame(width: 220)
                        #if os(tvOS)
                        .focused($tvFocusedControl, equals: .failureBack)
                        #endif
                }
                #if os(tvOS)
                .focusSection()
                #endif
            }
            .padding(.horizontal, 46)
            .padding(.vertical, 38)
            .foregroundStyle(.white)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        case .idle, .ready:
            EmptyView()
        }
    }

    /// 播放控制层：顶部信息 + 底部进度与按钮
    private var controlsLayer: some View {
        VStack {
            HStack(alignment: .top) {
                Button {
                    handleBack()
                } label: {
                    controlSymbol("chevron.left", prominent: false)
                }
                .buttonStyle(PlayerControlButtonStyle())
                #if os(tvOS)
                .focused($tvFocusedControl, equals: .back)
                #endif
                .accessibilityLabel(isFullscreenBackAction ? "退出横屏全屏" : "返回媒体库")
                VStack(alignment: .leading, spacing: 3) {
                    Text(playerDisplayTitle)
                        .font(.headline).lineLimit(1)
                    if viewModel.currentBinding != nil {
                        Label(viewModel.episodeAlignment.title, systemImage: viewModel.episodeAlignment.symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(episodeAlignmentColor)
                            .lineLimit(1)
                    }
                    Text(viewModel.danmakuStats)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                Spacer()
                #if os(iOS)
                if settings.isFullFeatureAccessEnabled {
                    Button {
                        viewModel.isShowingCandidates = true
                    } label: {
                        controlSymbol("text.magnifyingglass", prominent: false)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .accessibilityLabel("选择弹幕来源")
                }
                #endif
                Button {
                    isShowingPlaybackPanel = true
                } label: {
                    controlSymbol("ellipsis", prominent: false)
                }
                .buttonStyle(PlayerControlButtonStyle())
                #if os(tvOS)
                .focused($tvFocusedControl, equals: .more)
                #endif
                .accessibilityLabel("更多播放设置")
            }
            #if os(tvOS)
            .focusSection()
            #endif
            .frame(maxWidth: 1660)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, playerControlHorizontalPadding)
            .padding(.top, playerControlTopPadding)
            .padding(.bottom, 30)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.78), .black.opacity(0.35), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(timeLabel(currentTime)).font(.caption.monospacedDigit())
                    #if os(tvOS)
                    TVSeekBar(
                        value: currentTime,
                        duration: max(viewModel.duration, 1),
                        isPlaying: isPlaying,
                        onScrubChanged: { target in
                            isSeeking = true
                            pendingSeekTarget = nil
                            controlsTask?.cancel()
                            currentTime = target
                        },
                        onSeek: { target in
                            currentTime = target
                            commitSeek(to: target)
                            showOSD("跳转至 \(timeLabel(target))")
                            setControlsVisible(true)
                        },
                        onMoveUp: { tvFocusedControl = .back },
                        onMoveDown: { tvFocusedControl = .playPause },
                        onTogglePlayback: togglePlayback
                    )
                    .focused($tvFocusedControl, equals: .progress)
                    #else
                    Slider(
                        value: $currentTime,
                        in: 0...max(viewModel.duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                isSeeking = true
                                pendingSeekTarget = nil
                                controlsTask?.cancel()
                            } else {
                                commitSeek(to: currentTime)
                            }
                        }
                    )
                    #endif
                    Text(timeLabel(viewModel.duration)).font(.caption.monospacedDigit())
                }

                #if os(tvOS)
                playbackControlRow(showAllActions: true, compact: false)
                    .focusSection()
                #else
                ViewThatFits(in: .horizontal) {
                    playbackControlRow(showAllActions: true, compact: false)
                    playbackControlRow(showAllActions: false, compact: true)
                }
                #endif
            }
            #if os(tvOS)
            .focusSection()
            #endif
            .frame(maxWidth: 1660)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, playerControlHorizontalPadding)
            .padding(.top, 28)
            .padding(.bottom, playerControlBottomPadding)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.4), .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .foregroundStyle(.white)
        .transaction { transaction in transaction.animation = nil }
    }

    /// 根据可用宽度生成完整或紧凑的播放器按钮行。
    /// - Parameters:
    ///   - showAllActions: 是否展示弹幕开关、手动匹配与锁定等次要操作。
    ///   - compact: 是否使用更小的触控图标尺寸。
    /// - Returns: 不会超出安全宽度的控制按钮行。
    private func playbackControlRow(showAllActions: Bool, compact: Bool) -> some View {
        #if os(tvOS)
        let spacing: CGFloat = 22
        #else
        let spacing: CGFloat = compact ? 6 : 10
        #endif
        return HStack(spacing: spacing) {
                    Button {
                        commitSeek(to: currentTime - 10)
                        showOSD("后退 10 秒")
                    } label: {
                        controlSymbol("gobackward.10", prominent: false, compact: compact)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    #if os(tvOS)
                    .focused($tvFocusedControl, equals: .rewind)
                    #endif
                    .accessibilityLabel("后退 10 秒")
                    if items.count > 1 {
                        Button {
                            moveEpisode(by: -1)
                        } label: {
                            controlSymbol("backward.end.fill", prominent: false, compact: compact)
                        }
                        .buttonStyle(PlayerControlButtonStyle())
                        #if os(tvOS)
                        .focused($tvFocusedControl, equals: .previousEpisode)
                        #endif
                        .disabled(activeIndex == 0)
                        .accessibilityLabel("上一集")
                    }
                    Button {
                        togglePlayback()
                    } label: {
                        controlSymbol(isPlaying ? "pause.fill" : "play.fill", prominent: true, compact: compact)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    #if os(tvOS)
                    .focused($tvFocusedControl, equals: .playPause)
                    #endif
                    .accessibilityLabel(isPlaying ? "暂停" : "播放")
                    Button {
                        commitSeek(to: currentTime + 10)
                        showOSD("前进 10 秒")
                    } label: {
                        controlSymbol("goforward.10", prominent: false, compact: compact)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    #if os(tvOS)
                    .focused($tvFocusedControl, equals: .forward)
                    #endif
                    .accessibilityLabel("前进 10 秒")
                    if items.count > 1 {
                        Button {
                            moveEpisode(by: 1)
                        } label: {
                            controlSymbol("forward.end.fill", prominent: false, compact: compact)
                        }
                        .buttonStyle(PlayerControlButtonStyle())
                        #if os(tvOS)
                        .focused($tvFocusedControl, equals: .nextEpisode)
                        #endif
                        .disabled(activeIndex >= items.count - 1)
                        .accessibilityLabel("下一集")
                    }
                    if showAllActions { Spacer() }
                    if items.count > 1 {
                        Button {
                            isShowingPlaylist = true
                        } label: {
                            controlSymbol("list.number", prominent: false, compact: compact)
                        }
                        .buttonStyle(PlayerControlButtonStyle())
                        #if os(tvOS)
                        .focused($tvFocusedControl, equals: .playlist)
                        #endif
                        .accessibilityLabel("选择分集")
                    }
                    if showAllActions {
                        Button {
                            settings.danmakuConfig.enabled.toggle()
                            showOSD(settings.danmakuConfig.enabled ? "弹幕已开启" : "弹幕已关闭")
                        } label: {
                            controlSymbol(
                                settings.danmakuConfig.enabled ? "captions.bubble.fill" : "captions.bubble",
                                prominent: false,
                                compact: compact
                            )
                        }
                        .buttonStyle(PlayerControlButtonStyle())
                        #if os(tvOS)
                        .focused($tvFocusedControl, equals: .danmakuToggle)
                        #endif
                        .accessibilityLabel(settings.danmakuConfig.enabled ? "关闭弹幕" : "开启弹幕")
                    }
                    Button {
                        isShowingDanmakuPanel = true
                    } label: {
                        controlSymbol("slider.horizontal.3", prominent: false, compact: compact)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    #if os(tvOS)
                    .focused($tvFocusedControl, equals: .danmakuSettings)
                    #endif
                    .accessibilityLabel("弹幕设置")
                    #if os(iOS)
                    Button {
                        toggleLandscapeFullscreen()
                    } label: {
                        controlSymbol(
                            isLandscapeFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right",
                            prominent: false,
                            compact: compact
                        )
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .accessibilityLabel(isLandscapeFullscreen ? "退出横屏全屏" : "横屏全屏")
                    #endif
                    if showAllActions {
                        #if os(tvOS)
                        if settings.isFullFeatureAccessEnabled {
                            Button {
                                viewModel.isShowingCandidates = true
                            } label: {
                                controlSymbol("text.magnifyingglass", prominent: false, compact: compact)
                            }
                            .buttonStyle(PlayerControlButtonStyle())
                            .focused($tvFocusedControl, equals: .manualMatch)
                            .accessibilityLabel("选择弹幕来源")
                        }
                        #else
                        Button {
                            isInteractionLocked = true
                            setControlsVisible(true)
                            showOSD("操作已锁定")
                        } label: {
                            controlSymbol("lock.open", prominent: false, compact: compact)
                        }
                        .buttonStyle(PlayerControlButtonStyle())
                        .accessibilityLabel("锁定播放器操作")
                        #endif
                    }
        }
    }

    /// 统一播放器控制按钮的尺寸、材质与高对比度。
    /// - Parameters:
    ///   - name: SF Symbol 名称。
    ///   - prominent: 是否为中心播放主按钮。
    /// - Returns: 可直接放进 Button label 的图标视图。
    private func controlSymbol(_ name: String, prominent: Bool, compact: Bool = false) -> some View {
        #if os(tvOS)
        let regularSize: CGFloat = 68
        let primarySize: CGFloat = 82
        return Image(systemName: name)
            .font(prominent ? .title.weight(.semibold) : .title2.weight(.semibold))
            .frame(
                width: prominent ? primarySize : regularSize,
                height: prominent ? primarySize : regularSize
            )
            .contentShape(RoundedRectangle(cornerRadius: prominent ? 22 : 17, style: .continuous))
        #else
        let regularSize: CGFloat = compact ? 38 : 44
        let primarySize: CGFloat = compact ? 46 : 52
        return Image(systemName: name)
            .font(prominent ? .title2.weight(.semibold) : .body.weight(.semibold))
            .frame(
                width: prominent ? primarySize : regularSize,
                height: prominent ? primarySize : regularSize
            )
            .background(
                playerControlBackground(prominent: prominent),
                in: RoundedRectangle(cornerRadius: prominent ? 22 : 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: prominent ? 22 : 17, style: .continuous)
                    .strokeBorder(.white.opacity(prominent ? 0.22 : 0.10), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: prominent ? 22 : 17, style: .continuous))
        #endif
    }

    /// 返回 iPhone 与 iPad 播放按钮的默认背景。
    /// - Parameter prominent: 是否为中央播放或暂停按钮。
    /// - Returns: 播放主按钮或普通工具按钮的背景色。
    private func playerControlBackground(prominent: Bool) -> Color {
        prominent ? .white.opacity(0.23) : .black.opacity(0.42)
    }

    #if os(tvOS)
    /// 控件隐藏时响应遥控器中间确认键，切换播放状态并显示控制层。
    private func handleTVBackgroundConfirm() {
        guard !shouldShowPlayerControls, !isPlaybackFailed else { return }
        togglePlayback()
        setControlsVisible(true)
        showOSD(isPlaying ? "播放" : "暂停")
    }

    /// 控制层隐藏时只负责唤出控件，后续方向事件交给 tvOS 焦点引擎。
    /// - Parameter direction: Siri Remote 当前移动方向。
    private func handleTVRemoteMove(_ direction: MoveCommandDirection) {
        guard !shouldShowPlayerControls, !isPlaybackFailed else { return }
        switch direction {
        case .left:
            seekFromTVRemote(by: -10)
        case .right:
            seekFromTVRemote(by: 10)
        case .up, .down:
            setControlsVisible(true)
        @unknown default:
            setControlsVisible(true)
        }
    }

    /// 菜单键第一次隐藏播放控件，控件已隐藏时再执行返回。
    private func handleTVExitCommand() {
        if shouldShowPlayerControls {
            setControlsVisible(false)
        } else {
            handleBack()
        }
    }

    /// 控制层出现后把焦点交给时间轴，隐藏后交回透明视频层。
    /// - Parameter isVisible: 控制层当前是否可见且可操作。
    private func synchronizeTVPlayerFocus(isVisible: Bool) {
        Task { @MainActor in
            await Task.yield()
            guard !isPlaybackFailed else {
                focusPlaybackFailureActions()
                return
            }
            if isVisible {
                if tvFocusedControl == nil || tvFocusedControl == .background {
                    tvFocusedControl = .progress
                }
            } else {
                tvFocusedControl = .background
            }
        }
    }

    /// 用户在控件之间移动时刷新自动隐藏计时，避免操作过程中控制层消失。
    /// - Parameter focus: 当前获得焦点的播放器控件。
    private func handleTVControlFocusChange(_ focus: TVPlayerFocus?) {
        guard shouldShowPlayerControls, focus != nil, focus != .background else { return }
        scheduleControlsHide()
    }

    /// 播放状态变化时把焦点交给错误操作或播放时间轴。
    /// - Parameter state: 播放器最新加载状态。
    private func synchronizeTVPlayerFocus(for state: PlayerViewModel.LoadState) {
        Task { @MainActor in
            await Task.yield()
            switch state {
            case .failed:
                controlsTask?.cancel()
                focusPlaybackFailureActions()
            case .ready:
                tvFocusedControl = .progress
            case .idle, .preparing:
                tvFocusedControl = nil
            }
        }
    }

    /// 选择播放失败弹窗中最合适的默认操作。
    private func focusPlaybackFailureActions() {
        tvFocusedControl = !isUsingCompatibilityStream && isCompatibilityAvailable
            ? .failureCompatibility
            : .failureRetry
    }

    /// 在画面焦点下响应遥控器左右操作，并显示最新时间轴位置。
    /// - Parameter seconds: 正数快进，负数快退。
    private func seekFromTVRemote(by seconds: Double) {
        let target = min(max(currentTime + seconds, 0), max(viewModel.duration, 0))
        currentTime = target
        commitSeek(to: target)
        setControlsVisible(true)
        tvFocusedControl = .progress
        showOSD("\(seconds < 0 ? "后退" : "前进") \(Int(abs(seconds))) 秒 · \(timeLabel(target))")
    }
    #endif

    /// 返回播放器控制层在电视与触控设备上的水平安全间距。
    private var playerControlHorizontalPadding: CGFloat {
        #if os(tvOS)
        72
        #else
        16
        #endif
    }

    /// 返回播放器顶部信息与电视边框之间的安全间距。
    private var playerControlTopPadding: CGFloat {
        #if os(tvOS)
        42
        #else
        8
        #endif
    }

    /// 返回播放器底部控制与电视边框之间的安全间距。
    private var playerControlBottomPadding: CGFloat {
        #if os(tvOS)
        46
        #else
        12
        #endif
    }

    /// 当前集数对应状态使用的高对比度提示色。
    private var episodeAlignmentColor: Color {
        switch viewModel.episodeAlignment {
        case .matched: KanataTheme.success
        case .mismatched: KanataTheme.warning
        case .unavailable, .unverified: .white.opacity(0.72)
        }
    }

    /// 把 ViewModel 的数据与时间回调接到渲染层
    private func wireCallbacks() {
        let bridge = canvasBridge
        viewModel.onItemsChanged = { items in
            bridge.load(items: items)
        }
        viewModel.onTimeChanged = { time, rate in
            if let target = pendingSeekTarget {
                guard abs(time - target) <= 0.75 else { return }
                pendingSeekTarget = nil
            }
            if !isSeeking { currentTime = time }
            bridge.sync(time: time, rate: rate)
        }
        viewModel.onPlaybackStateChanged = { playing in
            isPlaying = playing
            bridge.sync(time: currentTime, rate: playing ? viewModel.playbackRate : 0)
            if playing {
                scheduleControlsHide()
            } else {
                setControlsVisible(true)
            }
        }
        viewModel.onPlaybackEnded = {
            handlePlaybackEnded()
        }
        viewModel.onPlaybackFailed = { message in
            handlePlaybackFailure(message)
        }
        viewModel.onPreviousTrackRequested = {
            if currentTime > 5 {
                commitSeek(to: 0)
            } else {
                moveEpisode(by: -1)
            }
        }
        viewModel.onNextTrackRequested = {
            moveEpisode(by: 1)
        }
    }

    /// 按睡眠定时器与队列模式决定播完后的下一步。
    private func handlePlaybackEnded() {
        if sleepMode == .endOfEpisode {
            sleepMode = .off
            finishPlayback(message: "已播完本集")
            return
        }
        switch queueMode {
        case .continuous:
            if activeIndex < items.count - 1 {
                moveEpisode(by: 1)
            } else {
                finishPlayback(message: "播放结束")
            }
        case .stop:
            finishPlayback(message: "播放结束")
        case .repeatOne:
            viewModel.seek(to: 0)
            viewModel.play()
            isPlaying = true
            showOSD("重新播放本集")
        case .repeatAll:
            if activeIndex < items.count - 1 {
                moveEpisode(by: 1)
            } else if items.count > 1 {
                activeIndex = 0
            } else {
                viewModel.seek(to: 0)
                viewModel.play()
                isPlaying = true
            }
        }
    }

    /// 把播放器恢复为播完暂停状态并显示控制层。
    /// - Parameter message: 播放画面中央显示的反馈文案。
    private func finishPlayback(message: String) {
        isPlaying = false
        currentTime = viewModel.duration
        canvasBridge.sync(time: currentTime, rate: 0)
        setControlsVisible(true)
        showOSD(message)
    }

    /// 释放上一集资源、打开当前条目并恢复其断点进度。
    private func openActiveItem() async {
        viewModel.teardown()
        canvasBridge.load(items: [])
        externalSubtitleCues = []
        externalSubtitleName = nil
        externalSubtitleResources = []
        selectedExternalSubtitleID = nil
        externalSubtitleOffset = 0
        subtitleFetchTask?.cancel()
        skipSegment = PlaybackSkipSegmentStore.segment(for: skipSegmentKey)
        currentTime = 0
        pendingSeekTarget = nil
        isSeeking = false
        isPlaying = false
        let directURL = activeItem.resolveURL()
        let compatibilityURL = activeItem.compatibilityPlaybackURL()
        let url: URL?
        switch playbackRouteMode {
        case .automatic:
            url = isUsingCompatibilityStream ? (compatibilityURL ?? directURL) : directURL
        case .direct:
            isUsingCompatibilityStream = false
            url = directURL
        case .compatible:
            isUsingCompatibilityStream = compatibilityURL != nil
            url = compatibilityURL
        }
        guard let url else {
            if playbackRouteMode == .compatible {
                danmakuOperationError = "当前视频源不提供服务器兼容流，请切换为自动或原始流"
            } else {
                danmakuOperationError = "无法访问 \(activeItem.displayName)，请重新连接媒体源"
            }
            return
        }
        scheduleExternalSubtitleDiscovery(for: directURL ?? url)
        wireCallbacks()
        await viewModel.open(
            url: url,
            displayName: automaticMatchName,
            settings: settings,
            requestHeaders: activeItem.requestHeaders(),
            mediaFileName: activeItem.displayName,
            forceUniversalPlayer: forcesUniversalPlayer,
            progressKey: activeItem.mediaKey,
            nowPlaying: PlaybackNowPlayingMetadata(
                title: activeItem.libraryTitle,
                collectionTitle: activeItem.collectionTitle,
                subtitle: activeItem.episodeLabel,
                sourceName: activeItem.sourceName,
                queueIndex: activeIndex,
                queueCount: items.count,
                identifier: activeItem.id
            )
        )
        if case .ready = viewModel.state {
            viewModel.play()
            isPlaying = true
            if let resumePosition = viewModel.resumePosition {
                currentTime = resumePosition
                showOSD("继续播放 · \(timeLabel(resumePosition))")
            } else if items.count > 1 {
                showOSD("第 \(activeIndex + 1) / \(items.count) 集")
            }
            scheduleControlsHide()
        }
    }

    /// 原始媒体流失败时自动切换 Jellyfin、Emby 或 Plex 的服务端兼容 HLS。
    /// - Parameter message: 原始播放器返回的错误说明。
    private func handlePlaybackFailure(_ message: String) {
        if !viewModel.usesUniversalPlayer {
            forcesUniversalPlayer = true
            showOSD("系统解码失败，正在切换通用解码器…")
            Task { await openActiveItem() }
            return
        }
        guard playbackRouteMode == .automatic,
              !isUsingCompatibilityStream,
              activeItem.compatibilityPlaybackURL() != nil else { return }
        isUsingCompatibilityStream = true
        showOSD("原始文件不兼容，正在切换服务器转码…")
        Task { await openActiveItem() }
    }

    /// 当前媒体是否提供由媒体服务器生成的兼容播放地址。
    private var isCompatibilityAvailable: Bool {
        activeItem.compatibilityPlaybackURL() != nil
    }

    /// 设置面板显示的实际播放路径。
    private var playbackPathLabel: String {
        switch playbackRouteMode {
        case .automatic:
            if isUsingCompatibilityStream { return "自动 · 服务器兼容流" }
            return viewModel.usesUniversalPlayer ? "自动 · 通用解码" : "自动 · 系统解码"
        case .direct:
            return "原始流"
        case .compatible:
            return isCompatibilityAvailable ? "兼容流" : "不可用"
        }
    }

    /// 应用用户选择的播放路径，并从当前集的断点重新打开视频。
    /// - Parameter mode: 自动、原始流或服务器兼容流。
    private func selectPlaybackRoute(_ mode: PlaybackRouteMode) {
        guard mode != .compatible || isCompatibilityAvailable else {
            showOSD("当前视频源不提供兼容流")
            return
        }
        guard mode != playbackRouteMode || (mode == .automatic && isUsingCompatibilityStream) else { return }
        playbackRouteMode = mode
        isUsingCompatibilityStream = mode == .compatible
        forcesUniversalPlayer = false
        showOSD("播放路径 · \(mode.title)")
        Task { await openActiveItem() }
    }

    /// 在播放失败页直接改用媒体服务器兼容流。
    private func retryWithCompatibilityStream() {
        playbackRouteMode = .compatible
        isUsingCompatibilityStream = true
        forcesUniversalPlayer = false
        showOSD("正在请求服务器兼容流…")
        Task { await openActiveItem() }
    }

    /// 返回当前节目各分集共享的片头片尾存储键。
    private var skipSegmentKey: String {
        activeItem.collectionID ?? activeItem.collectionTitle ?? activeItem.title
    }

    /// 生成自动弹幕匹配名称；合集优先使用作品名与显式集号，避免服务器播放路径中的 `file`。
    private var automaticMatchName: String {
        guard let collectionTitle = activeItem.collectionTitle,
              !collectionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return activeItem.displayName
        }
        let episode = activeItem.episode ?? activeItem.collectionIndex
        return episode.map { "\(collectionTitle) E\($0)" } ?? collectionTitle
    }

    /// 播放器顶部同时显示作品名和当前集数。
    private var playerDisplayTitle: String {
        let title = activeItem.collectionTitle ?? viewModel.parsed?.title ?? activeItem.displayName
        guard let episodeLabel = activeItem.episodeLabel else { return title }
        return "\(title) · \(episodeLabel)"
    }

    /// 修改当前合集的一项跳过位置并立即持久化。
    /// - Parameters:
    ///   - introEnd: 新片头结束秒数；nil 表示保持不变。
    ///   - outroStart: 新片尾开始秒数；nil 表示保持不变。
    private func updateSkipSegment(introEnd: Double? = nil, outroStart: Double? = nil) {
        if let introEnd { skipSegment.introEnd = max(introEnd, 0) }
        if let outroStart { skipSegment.outroStart = max(outroStart, 0) }
        PlaybackSkipSegmentStore.save(skipSegment, for: skipSegmentKey)
        showOSD(introEnd != nil ? "已记住片头结束位置" : "已记住片尾开始位置")
    }

    /// 清除当前合集保存的片头与片尾位置。
    private func clearSkipSegment() {
        skipSegment = PlaybackSkipSegment()
        PlaybackSkipSegmentStore.save(skipSegment, for: skipSegmentKey)
        showOSD("已清除片头片尾位置")
    }

    /// 选择播放队列中的指定媒体条目。
    /// - Parameter item: 分集列表中点击的媒体。
    private func selectItem(_ item: LibraryItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), index != activeIndex else {
            isShowingPlaylist = false
            return
        }
        isShowingPlaylist = false
        activeIndex = index
    }

    /// 从当前分集向前或向后移动一集。
    /// - Parameter delta: -1 表示上一集，1 表示下一集。
    private func moveEpisode(by delta: Int) {
        let target = min(max(activeIndex + delta, 0), items.count - 1)
        guard target != activeIndex else { return }
        activeIndex = target
    }

    /// 按选项创建或取消睡眠倒计时。
    /// - Parameter mode: 用户选择的睡眠模式。
    private func configureSleepTimer(_ mode: SleepTimerMode) {
        sleepTask?.cancel()
        guard let seconds = mode.seconds else {
            if mode == .off { showOSD("睡眠定时器已关闭") }
            return
        }
        showOSD("将在 \(mode.title)后暂停")
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            viewModel.pause()
            isPlaying = false
            sleepMode = .off
            setControlsVisible(true)
            showOSD("睡眠定时器已暂停播放")
        }
    }

    /// 播放期间保持屏幕常亮，退出播放器后恢复系统策略。
    /// - Parameter disabled: true 表示禁用系统自动熄屏。
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    /// 切换播放或暂停，并同步弹幕插值状态。
    private func togglePlayback() {
        if isPlaying {
            viewModel.pause()
            isPlaying = false
            canvasBridge.sync(time: currentTime, rate: 0)
        } else {
            viewModel.play()
            isPlaying = true
            canvasBridge.sync(time: currentTime, rate: viewModel.playbackRate)
        }
        scheduleControlsHide()
    }

    /// 提交一次进度跳转，并在播放器确认目标时间前屏蔽旧周期回调。
    /// - Parameter time: 用户期望跳转到的播放秒数。
    private func commitSeek(to time: Double) {
        let upperBound = max(viewModel.duration, 0)
        let target = min(max(time, 0), upperBound)
        currentTime = target
        pendingSeekTarget = target
        isSeeking = false
        viewModel.seek(to: target)
        canvasBridge.sync(time: target, rate: isPlaying ? viewModel.playbackRate : 0)
        scheduleControlsHide()
    }

    #if os(iOS)
    /// 切换横屏全屏状态，并在系统拒绝时恢复按钮状态。
    private func toggleLandscapeFullscreen() {
        guard !isChangingOrientation else { return }
        let target = !isLandscapeFullscreen
        isChangingOrientation = true
        PlayerOrientationController.requestLandscape(target) { result in
            isChangingOrientation = false
            switch result {
            case .success:
                isLandscapeFullscreen = target
                showOSD(target ? "已进入横屏全屏" : "已退出横屏全屏")
            case .failure(let error):
                isLandscapeFullscreen = PlayerOrientationController.isLandscape()
                danmakuOperationError = "无法切换屏幕方向：\(error.localizedDescription)"
            }
        }
    }
    #endif

    /// 处理播放器返回动作；横屏全屏时优先恢复竖屏，再次点击才关闭播放器。
    private func handleBack() {
        #if os(iOS)
        if isLandscapeFullscreen || PlayerOrientationController.isLandscape() {
            guard !isChangingOrientation else { return }
            isChangingOrientation = true
            PlayerOrientationController.requestLandscape(false) { result in
                isChangingOrientation = false
                switch result {
                case .success:
                    isLandscapeFullscreen = false
                    showOSD("已退出横屏全屏")
                case .failure(let error):
                    isLandscapeFullscreen = PlayerOrientationController.isLandscape()
                    danmakuOperationError = "无法退出横屏：\(error.localizedDescription)"
                }
            }
            return
        }
        #endif
        resumesAfterExitCancellation = isPlaying
        viewModel.pause()
        isPlaying = false
        setControlsVisible(true)
        isConfirmingExit = true
    }

    /// 取消退出确认，并在弹窗出现前处于播放状态时继续播放。
    private func cancelExitConfirmation() {
        guard resumesAfterExitCancellation else { return }
        resumesAfterExitCancellation = false
        viewModel.play()
        isPlaying = true
        canvasBridge.sync(time: currentTime, rate: viewModel.playbackRate)
        scheduleControlsHide()
    }

    /// 返回按钮当前是否执行退出全屏动作。
    private var isFullscreenBackAction: Bool {
        #if os(iOS)
        isLandscapeFullscreen || PlayerOrientationController.isLandscape()
        #else
        false
        #endif
    }

    /// 显示一条 1.5 秒后自动淡出的操作反馈
    private func showOSD(_ text: String) {
        osdTask?.cancel()
        if reduceMotion { osdText = text } else { withAnimation { osdText = text } }
        osdTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            if reduceMotion { osdText = nil } else { withAnimation { osdText = nil } }
        }
    }

    /// 显示或隐藏控制层，并遵守“减少动态效果”辅助功能设置。
    private func setControlsVisible(_ visible: Bool) {
        controlsTask?.cancel()
        if reduceMotion {
            isShowingControls = visible
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { isShowingControls = visible }
        }
        if visible { scheduleControlsHide() }
    }

    /// 播放时在四秒无操作后自动隐藏控制层。
    private func scheduleControlsHide() {
        controlsTask?.cancel()
        guard isPlaying, !isSeeking else { return }
        controlsTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                isShowingControls = false
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { isShowingControls = false }
            }
        }
    }

    /// 处理文件选择结果，并在安全作用域内读取本地弹幕。
    private func handleDanmakuImport(_ result: Result<[URL], Error>) {
        do {
            guard let fileURL = try result.get().first else { return }
            let hasAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { fileURL.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: fileURL)
            Task {
                do {
                    try await viewModel.importLocalDanmaku(data: data, fileName: fileURL.lastPathComponent)
                    showOSD("已导入 \(viewModel.localDanmakuCount) 条本地弹幕")
                } catch {
                    danmakuOperationError = error.localizedDescription
                }
            }
        } catch {
            danmakuOperationError = error.localizedDescription
        }
    }

    /// 读取并解析用户选择的 SRT、VTT、ASS 或 SSA 外挂字幕。
    /// - Parameter result: 系统文件选择结果。
    private func handleSubtitleImport(_ result: Result<[URL], Error>) {
        do {
            guard let fileURL = try result.get().first else { return }
            let hasAccess = fileURL.startAccessingSecurityScopedResource()
            defer { if hasAccess { fileURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: fileURL)
            let fileName = fileURL.lastPathComponent
            Task {
                do {
                    let cues = try await Task.detached(priority: .utility) {
                        try ExternalSubtitleParser.parse(data: data, fileName: fileName)
                    }.value
                    externalSubtitleCues = cues
                    externalSubtitleName = fileName
                    externalSubtitleResources = []
                    selectedExternalSubtitleID = nil
                    isExternalSubtitleEnabled = true
                    showOSD("已载入 \(cues.count) 条外挂字幕")
                } catch {
                    danmakuOperationError = error.localizedDescription
                }
            }
        } catch {
            danmakuOperationError = error.localizedDescription
        }
    }

    /// 用户主动重新获取当前视频的同目录或媒体服务器字幕。
    private func fetchExternalSubtitles() {
        guard let videoURL = activeItem.resolveURL() else {
            danmakuOperationError = ExternalSubtitleError.notFound.localizedDescription
            return
        }
        scheduleExternalSubtitleDiscovery(for: videoURL, announcesResult: true)
    }

    /// 启动可取消的外挂字幕发现任务，切集时不会把旧结果写入新视频。
    /// - Parameters:
    ///   - videoURL: 当前视频原始地址。
    ///   - announcesResult: 是否向用户反馈未找到、成功或失败。
    private func scheduleExternalSubtitleDiscovery(
        for videoURL: URL,
        announcesResult: Bool = false
    ) {
        subtitleFetchTask?.cancel()
        let item = activeItem
        isFetchingExternalSubtitles = true
        subtitleFetchTask = Task {
            defer {
                if activeItem.id == item.id { isFetchingExternalSubtitles = false }
            }
            do {
                let resources = try await externalSubtitleResources(for: item, videoURL: videoURL)
                guard !Task.isCancelled, activeItem.id == item.id else { return }
                externalSubtitleResources = resources
                guard let preferred = resources.first else {
                    if announcesResult { danmakuOperationError = ExternalSubtitleError.notFound.localizedDescription }
                    return
                }
                _ = await loadExternalSubtitle(preferred, for: item.id, announcesResult: announcesResult)
            } catch {
                guard !Task.isCancelled, activeItem.id == item.id, announcesResult else { return }
                danmakuOperationError = "外挂字幕获取失败：\(error.localizedDescription)"
            }
        }
    }

    /// 汇总本地、WebDAV、DSM、Jellyfin、Emby 与 Plex 提供的外挂字幕。
    /// - Parameters:
    ///   - item: 当前媒体库条目。
    ///   - videoURL: 当前视频原始地址。
    /// - Returns: 已按设备语言优先级排序的可用字幕。
    private func externalSubtitleResources(
        for item: LibraryItem,
        videoURL: URL
    ) async throws -> [ExternalSubtitleResource] {
        let resources: [ExternalSubtitleResource]
        if videoURL.isFileURL {
            resources = try localSubtitleResources(beside: videoURL, videoName: item.displayName)
        } else if let profileID = item.sourceProfileID,
                  let profile = MediaSourceProfileStore.profile(id: profileID) {
            switch profile.kind {
            case .webDAV:
                let values = try await WebDAVClient(profile: profile).subtitleFiles(
                    directory: videoURL.deletingLastPathComponent()
                )
                resources = values.filter {
                    ExternalSubtitlePreference.matches(subtitleName: $0.name, videoName: item.displayName)
                }
            case .synology:
                let storedPath = item.serverItemID?.replacingOccurrences(of: "synology:", with: "")
                    ?? URLComponents(url: videoURL, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "path" })?.value
                guard let storedPath else { return [] }
                let values = try await SynologyFileStationClient().subtitleFiles(
                    profile: profile,
                    videoPath: storedPath
                )
                resources = values.filter {
                    ExternalSubtitlePreference.matches(subtitleName: $0.name, videoName: item.displayName)
                }
            case .jellyfin, .emby:
                guard let itemID = item.serverItemID else { return [] }
                resources = try await MediaBrowserClient().subtitleFiles(
                    profile: profile,
                    itemID: itemID,
                    preferredMediaSourceID: item.serverMediaSourceID
                )
            case .plex:
                guard let rawID = item.serverItemID else { return [] }
                let itemID = rawID.replacingOccurrences(of: "plex-video:", with: "")
                resources = try await PlexClient().subtitleFiles(profile: profile, itemID: itemID)
            }
        } else {
            resources = []
        }
        let unique = Dictionary(resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ExternalSubtitlePreference.sorted(Array(unique.values))
    }

    /// 扫描本地视频同目录并保留同名及带语言后缀的字幕。
    /// - Parameters:
    ///   - videoURL: 本地视频地址。
    ///   - videoName: 媒体库保存的原始视频名。
    /// - Returns: 可在安全作用域内读取的字幕资源。
    private func localSubtitleResources(beside videoURL: URL, videoName: String) throws -> [ExternalSubtitleResource] {
        let hasAccess = videoURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { videoURL.stopAccessingSecurityScopedResource() } }
        return try FileManager.default.contentsOfDirectory(
            at: videoURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter {
            ExternalSubtitlePreference.supportedExtensions.contains($0.pathExtension.lowercased())
                && ExternalSubtitlePreference.matches(subtitleName: $0.lastPathComponent, videoName: videoName)
        }
        .map { ExternalSubtitleResource(url: $0, name: $0.lastPathComponent, requestHeaders: [:]) }
    }

    /// 选择已发现的另一份外挂字幕并立即载入。
    /// - Parameter id: 字幕资源 URL 标识。
    private func selectExternalSubtitle(_ id: String) {
        guard let resource = externalSubtitleResources.first(where: { $0.id == id }) else { return }
        let itemID = activeItem.id
        subtitleFetchTask?.cancel()
        isFetchingExternalSubtitles = true
        subtitleFetchTask = Task {
            defer { if activeItem.id == itemID { isFetchingExternalSubtitles = false } }
            _ = await loadExternalSubtitle(resource, for: itemID, announcesResult: true)
        }
    }

    /// 下载并解析一份外挂字幕，成功后切换当前字幕轨。
    /// - Parameters:
    ///   - resource: 本地或远程字幕资源。
    ///   - itemID: 发起加载时的视频标识。
    ///   - announcesResult: 是否显示成功与失败反馈。
    /// - Returns: 字幕成功应用时返回 true。
    private func loadExternalSubtitle(
        _ resource: ExternalSubtitleResource,
        for itemID: String,
        announcesResult: Bool
    ) async -> Bool {
        do {
            let data = try await externalSubtitleData(from: resource)
            let cues = try await Task.detached(priority: .utility) {
                try ExternalSubtitleParser.parse(data: data, fileName: resource.name)
            }.value
            guard !Task.isCancelled, activeItem.id == itemID else { return false }
            externalSubtitleCues = cues
            externalSubtitleName = resource.name
            selectedExternalSubtitleID = resource.id
            isExternalSubtitleEnabled = true
            if announcesResult { showOSD("已载入 \(resource.name)") }
            return true
        } catch {
            guard !Task.isCancelled, activeItem.id == itemID, announcesResult else { return false }
            danmakuOperationError = "外挂字幕读取失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 从本地安全作用域或带认证头的网络地址读取字幕数据。
    /// - Parameter resource: 待读取字幕资源。
    /// - Returns: 字幕原始数据。
    private func externalSubtitleData(from resource: ExternalSubtitleResource) async throws -> Data {
        if resource.url.isFileURL {
            let hasAccess = resource.url.startAccessingSecurityScopedResource()
            defer { if hasAccess { resource.url.stopAccessingSecurityScopedResource() } }
            return try await Task.detached(priority: .utility) {
                try Data(contentsOf: resource.url)
            }.value
        }
        var request = URLRequest(url: resource.url)
        resource.requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ExternalSubtitleError.http(-1) }
        guard (200..<300).contains(http.statusCode) else { throw ExternalSubtitleError.http(http.statusCode) }
        return data
    }

    /// 返回文件选择器允许显示的本地弹幕类型。
    private var danmakuFileTypes: [UTType] {
        [.xml, .json, UTType(filenameExtension: "ass") ?? .plainText]
    }

    /// 返回外挂字幕文件选择器支持的格式。
    private var subtitleFileTypes: [UTType] {
        ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) }
    }

    /// 秒数转 mm:ss 或 h:mm:ss
    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

/// 播放中的合集选集面板。
private struct PlaylistPicker: View {
    let items: [LibraryItem]
    let currentItemID: String
    let onSelect: (LibraryItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvContent
            #else
            List {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    Button {
                        onSelect(item)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(item.collectionIndex ?? offset + 1)")
                                .font(.caption.monospacedDigit())
                                .frame(width: 34, height: 34)
                                .background(.secondary.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.displayName)
                                    .lineLimit(2)
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if item.id == currentItemID {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(KanataTheme.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle(items.first?.collectionTitle ?? "选择分集")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .kanataToolbarTextButton()
                }
            }
            #endif
        }
    }

    #if os(tvOS)
    /// 构建电视端全屏分集面板，以独立背景和短标题避免文字与视频叠在一起。
    private var tvContent: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.96), KanataTheme.background.opacity(0.98)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(items.first?.collectionTitle ?? "选择分集")
                            .font(.largeTitle.bold())
                        Text("共 \(items.count) 集 · 选择后立即播放")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                    .buttonStyle(KanataTVActionButtonStyle())
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                            Button {
                                onSelect(item)
                                dismiss()
                            } label: {
                                HStack(spacing: 18) {
                                    Text("\(item.episode ?? item.collectionIndex ?? offset + 1)")
                                        .font(.headline.monospacedDigit())
                                        .foregroundStyle(item.id == currentItemID ? Color.black : Color.secondary)
                                        .frame(width: 52, height: 52)
                                        .background(
                                            item.id == currentItemID ? KanataTheme.accent : KanataTheme.elevatedSurface,
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        )
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.episodeLabel ?? "第 \(offset + 1) 集")
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(item.displayName)
                                            .font(.body)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 24)
                                    if item.id == currentItemID {
                                        Label("正在播放", systemImage: "speaker.wave.2.fill")
                                            .font(.headline)
                                            .foregroundStyle(KanataTheme.accent)
                                    } else {
                                        Image(systemName: "play.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                                .padding(.horizontal, 18)
                            }
                            .kanataDirectoryRowStyle(cornerRadius: 16)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
            .frame(maxWidth: 1540, maxHeight: 920)
            .padding(.horizontal, 72)
            .padding(.vertical, 52)
        }
        .navigationBarHidden(true)
    }
    #endif
}

/// 弹幕来源候选选择（FR-MATCH-003）
struct CandidatePicker: View {
    let viewModel: PlayerViewModel
    @State private var keyword = ""
    @State private var operationError: String?
    @Environment(\.dismiss) private var dismiss
    #if os(tvOS)
    @FocusState private var focusedControl: TVCandidateFocus?

    /// Apple TV 弹幕来源弹窗中的可聚焦控件。
    private enum TVCandidateFocus: Hashable {
        case close
        case searchField
        case searchButton
        case removeBinding
        case removeLocal
        case candidate(String)
    }
    #endif

    var body: some View {
        NavigationStack {
            #if os(tvOS)
            tvContent
            #else
            compactContent
            #endif
        }
        .onAppear {
            keyword = viewModel.parsed?.title ?? ""
            #if os(tvOS)
            focusInitialTVControl()
            #endif
        }
        #if os(tvOS)
        .onChange(of: viewModel.candidates.map(\.id)) { _, ids in
            if let id = ids.first { focusedControl = .candidate(id) }
        }
        #endif
        .alert(
            "弹幕操作失败",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(operationError ?? "未知错误")
        }
    }

    #if !os(tvOS)
    /// 构建 iPhone 与 iPad 使用的紧凑分组列表。
    private var compactContent: some View {
        List {
            if let binding = viewModel.currentBinding {
                Section("当前绑定") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(binding.title)
                        HStack(spacing: 8) {
                            Text(binding.sourceInstanceName ?? binding.source.displayName)
                            if let episodeTitle = binding.episodeTitle, !episodeTitle.isEmpty {
                                Text(normalizedEpisodeTitle(episodeTitle))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Label(viewModel.episodeAlignment.title, systemImage: viewModel.episodeAlignment.symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(bindingAlignmentColor)
                    }
                    Button("解除绑定", role: .destructive) {
                        viewModel.removeCurrentBinding()
                    }
                }
            }
            if viewModel.hasLocalDanmaku {
                Section("本地弹幕") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.localDanmakuFileName ?? "已导入文件")
                        Text("\(viewModel.localDanmakuCount) 条 · 离线可用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("移除本地弹幕", role: .destructive) {
                        removeLocalDanmaku()
                    }
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("剧名、集数或平台播放页链接", text: $keyword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { searchCandidates() }
                        if viewModel.isSearchingCandidates { ProgressView() }
                    }
                    Button("搜索") { searchCandidates() }
                        .buttonStyle(KanataPrimaryButtonStyle())
                        .disabled(isSearchDisabled)
                    Text("搜索不会再强制使用文件名推断的集号；选择正确分集后会记住，下次自动加载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("候选（\(viewModel.candidates.count)）") {
                if viewModel.candidates.isEmpty {
                    Text(emptyCandidateMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.candidates) { candidate in
                    Button { selectCandidate(candidate) } label: {
                        candidateDetails(candidate)
                    }
                }
            }
        }
        .navigationTitle("选择弹幕来源")
        .kanataInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") { dismiss() }
                    .kanataToolbarTextButton()
                    }
                }
            }
            #endif

    #if os(tvOS)
    /// 构建 Apple TV 双栏弹幕来源选择界面，减少默认列表的大片高亮与焦点跳跃。
    private var tvContent: some View {
        ZStack {
            LinearGradient(
                colors: [KanataTheme.backgroundTop, KanataTheme.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("选择弹幕来源")
                            .font(.largeTitle.bold())
                        Text("确认当前视频对应的作品与集数")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Label("关闭", systemImage: "xmark")
                    }
                    .buttonStyle(KanataTVActionButtonStyle())
                    .focused($focusedControl, equals: .close)
                }
                .focusSection()

                HStack(alignment: .top, spacing: 30) {
                    tvSearchColumn
                        .frame(width: 520)
                    tvCandidateColumn
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: 1720, maxHeight: 940)
            .padding(.horizontal, 72)
            .padding(.vertical, 50)
        }
        .navigationBarHidden(true)
    }

    /// 构建 Apple TV 左侧搜索、当前绑定与本地弹幕信息栏。
    private var tvSearchColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("搜索作品", systemImage: "magnifyingglass")
                        .font(.title2.bold())
                    HStack(spacing: 12) {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(KanataTheme.accent)
                        TextField("剧名、集数或播放页链接", text: $keyword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
                            .focused($focusedControl, equals: .searchField)
                            .onSubmit { searchCandidates() }
                        if viewModel.isSearchingCandidates { ProgressView() }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 70, alignment: .center)
                    .background(KanataTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(KanataTheme.separator, lineWidth: 1)
                    }
                    Button { searchCandidates() } label: {
                        Label(viewModel.isSearchingCandidates ? "正在搜索" : "搜索弹幕", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(KanataPrimaryButtonStyle())
                    .focused($focusedControl, equals: .searchButton)
                    .disabled(isSearchDisabled)
                    Text("选择正确分集后会保存匹配，下次播放自动加载。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if let binding = viewModel.currentBinding {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("当前绑定", systemImage: "link.circle.fill")
                            .font(.title3.bold())
                            .foregroundStyle(KanataTheme.accent)
                        Text(binding.title)
                            .font(.headline)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Text(binding.sourceInstanceName ?? binding.source.displayName)
                            if let episodeTitle = binding.episodeTitle, !episodeTitle.isEmpty {
                                Text(normalizedEpisodeTitle(episodeTitle))
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Label(viewModel.episodeAlignment.title, systemImage: viewModel.episodeAlignment.symbol)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(bindingAlignmentColor)
                        Button("解除当前绑定", role: .destructive) {
                            viewModel.removeCurrentBinding()
                        }
                        .buttonStyle(KanataSecondaryButtonStyle())
                        .focused($focusedControl, equals: .removeBinding)
                    }
                    .padding(24)
                    .background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }

                if viewModel.hasLocalDanmaku {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("本地弹幕", systemImage: "doc.text.fill")
                            .font(.title3.bold())
                        Text(viewModel.localDanmakuFileName ?? "已导入文件")
                            .font(.headline)
                            .lineLimit(2)
                        Text("\(viewModel.localDanmakuCount) 条 · 离线可用")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("移除本地弹幕", role: .destructive) {
                            removeLocalDanmaku()
                        }
                        .buttonStyle(KanataSecondaryButtonStyle())
                        .focused($focusedControl, equals: .removeLocal)
                    }
                    .padding(24)
                    .background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .padding(6)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .focusSection()
    }

    /// 构建 Apple TV 右侧候选列表与空状态。
    private var tvCandidateColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("匹配结果")
                    .font(.title2.bold())
                Spacer()
                Text("\(viewModel.candidates.count) 个候选")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            if viewModel.candidates.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: viewModel.isSearchingCandidates ? "hourglass" : "text.magnifyingglass")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(KanataTheme.accent)
                    Text(viewModel.isSearchingCandidates ? "正在查找弹幕…" : emptyCandidateMessage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 620)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KanataTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.candidates) { candidate in
                            Button { selectCandidate(candidate) } label: {
                                HStack(spacing: 20) {
                                    Image(systemName: viewModel.episodeAlignment(for: candidate).symbol)
                                        .font(.title2)
                                        .foregroundStyle(candidateAlignmentColor(candidate))
                                        .frame(width: 42)
                                    candidateDetails(candidate)
                                    Spacer(minLength: 16)
                                    VStack(alignment: .trailing, spacing: 6) {
                                        Text("\(Int(candidate.confidence * 100))%")
                                            .font(.title3.monospacedDigit().bold())
                                        Text("匹配度")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 22)
                                .padding(.vertical, 18)
                                .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                                .background(
                                    KanataTheme.elevatedSurface,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                            }
                            .kanataTVFocus(cornerRadius: 22)
                            .focused($focusedControl, equals: .candidate(candidate.id))
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KanataTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .focusSection()
    }

    /// 将 Apple TV 初始焦点放到首个候选；无候选时落到搜索按钮。
    private func focusInitialTVControl() {
        Task { @MainActor in
            await Task.yield()
            focusedControl = viewModel.candidates.first.map { .candidate($0.id) } ?? .searchButton
        }
    }
    #endif

    /// 返回候选列表没有内容时的状态说明。
    private var emptyCandidateMessage: String {
        viewModel.danmakuStats.isEmpty ? "输入作品关键词开始搜索" : viewModel.danmakuStats
    }

    /// 返回搜索按钮当前是否不可用。
    private var isSearchDisabled: Bool {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSearchingCandidates
    }

    /// 发起一次手动弹幕搜索。
    private func searchCandidates() {
        Task { await viewModel.search(keyword: keyword) }
    }

    /// 加载用户选择的弹幕来源，成功后关闭弹窗。
    /// - Parameter candidate: 用户确认的候选分集。
    private func selectCandidate(_ candidate: ProviderCandidate) {
        Task {
            if await viewModel.loadDanmaku(for: candidate) { dismiss() }
        }
    }

    /// 移除当前视频关联的本地弹幕，并显示失败原因。
    private func removeLocalDanmaku() {
        Task {
            do {
                try await viewModel.removeLocalDanmaku()
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    /// 生成 iOS 与 tvOS 共用的候选标题、来源和集数信息。
    /// - Parameter candidate: 要展示的候选弹幕分集。
    /// - Returns: 不包含操作按钮的候选说明视图。
    private func candidateDetails(_ candidate: ProviderCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(candidate.sourceInstanceName ?? candidate.source.displayName)
                if let episodeTitle = candidate.episodeTitle, !episodeTitle.isEmpty {
                    Text(normalizedEpisodeTitle(episodeTitle))
                }
                #if !os(tvOS)
                Text("匹配度 \(Int(candidate.confidence * 100))%")
                #endif
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Label(
                viewModel.episodeAlignment(for: candidate).title,
                systemImage: viewModel.episodeAlignment(for: candidate).symbol
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(candidateAlignmentColor(candidate))
        }
    }

    /// 规范化来源返回的分集标题，确保纯数字结果也明确显示“第几集”。
    /// - Parameter value: 来源返回的原始分集标题。
    /// - Returns: 保留已有集号，或为开头数字追加“第 N 集”。
    private func normalizedEpisodeTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"第\s*\d+\s*[集话]"#, options: .regularExpression) != nil
            || trimmed.range(of: #"\b(?:EP|E)\s*\d+\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return trimmed
        }
        guard let match = trimmed.range(of: #"^\d+(?:\.\d+)?"#, options: .regularExpression) else {
            return trimmed
        }
        let number = String(trimmed[match])
        let remainder = trimmed[match.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? "第 \(number) 集" : "第 \(number) 集 · \(remainder)"
    }

    /// 返回当前绑定集数对应状态的提示色。
    private var bindingAlignmentColor: Color {
        switch viewModel.episodeAlignment {
        case .matched: KanataTheme.success
        case .mismatched: KanataTheme.warning
        case .unavailable, .unverified: .secondary
        }
    }

    /// 返回候选分集对应状态的提示色。
    /// - Parameter candidate: 当前候选。
    /// - Returns: 一致为绿色，不一致为橙色，其余为次级文字色。
    private func candidateAlignmentColor(_ candidate: ProviderCandidate) -> Color {
        switch viewModel.episodeAlignment(for: candidate) {
        case .matched: KanataTheme.success
        case .mismatched: KanataTheme.warning
        case .unavailable, .unverified: .secondary
        }
    }
}

/// 播放器二级控制面板，集中放置低频但重要的画面、音轨、字幕与媒体信息。
struct PlaybackOptionsPanel: View {
    let viewModel: PlayerViewModel
    @Environment(AppSettings.self) private var settings
    @Binding var scalingMode: PlayerScalingMode
    @Binding var queueMode: PlaybackQueueMode
    @Binding var sleepMode: SleepTimerMode
    let playbackRouteMode: PlaybackRouteMode
    let playbackPathLabel: String
    let isCompatibilityAvailable: Bool
    let hasExternalSubtitle: Bool
    let externalSubtitleName: String?
    let externalSubtitleResources: [ExternalSubtitleResource]
    let selectedExternalSubtitleID: String?
    @Binding var externalSubtitleEnabled: Bool
    @Binding var externalSubtitleOffset: Double
    let isFetchingExternalSubtitles: Bool
    let skipSegment: PlaybackSkipSegment
    let onImportDanmaku: () -> Void
    let onMatchDanmaku: () -> Void
    let onImportSubtitle: () -> Void
    let onFetchExternalSubtitles: () -> Void
    let onSelectExternalSubtitle: (String) -> Void
    let onMarkIntro: () -> Void
    let onMarkOutro: () -> Void
    let onClearSkipSegment: () -> Void
    let onSelectPlaybackRoute: (PlaybackRouteMode) -> Void
    let onPictureInPicture: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    NavigationLink {
                        PlaybackRouteSelectionView(
                            selection: playbackRouteMode,
                            isCompatibilityAvailable: isCompatibilityAvailable,
                            onSelect: onSelectPlaybackRoute
                        )
                    } label: {
                        LabeledContent("播放路径", value: playbackPathLabel)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .padding(.horizontal, 14)
                    }
                    .kanataDirectoryRowStyle(cornerRadius: 12)
                    .listRowBackground(Color.clear)
                    NavigationLink {
                        PlaybackRateSelectionView(viewModel: viewModel)
                    } label: {
                        LabeledContent("播放速度", value: playbackRateLabel(viewModel.playbackRate))
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .padding(.horizontal, 14)
                    }
                    .kanataDirectoryRowStyle(cornerRadius: 12)
                    .listRowBackground(Color.clear)
                    Picker("连播方式", selection: $queueMode) {
                        ForEach(PlaybackQueueMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("睡眠定时器", selection: $sleepMode) {
                        ForEach(SleepTimerMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker("画面比例", selection: $scalingMode) {
                        ForEach(PlayerScalingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("片头与片尾") {
                    Button(action: onMarkIntro) {
                        Label("将当前位置设为片头结束", systemImage: "forward.end")
                    }
                    Button(action: onMarkOutro) {
                        Label("将当前位置设为片尾开始", systemImage: "flag.checkered")
                    }
                    if skipSegment.introEnd != nil || skipSegment.outroStart != nil {
                        if let introEnd = skipSegment.introEnd {
                            LabeledContent("片头结束", value: segmentTimeLabel(introEnd))
                        }
                        if let outroStart = skipSegment.outroStart {
                            LabeledContent("片尾开始", value: segmentTimeLabel(outroStart))
                        }
                        Button("清除片头片尾位置", role: .destructive, action: onClearSkipSegment)
                    }
                }

                if !viewModel.audioTracks.isEmpty {
                    Section("音轨") {
                        Picker(
                            "当前音轨",
                            selection: Binding(
                                get: { viewModel.selectedAudioTrackID },
                                set: { id in if let id { viewModel.selectAudioTrack(id: id) } }
                            )
                        ) {
                            ForEach(viewModel.audioTracks) { track in
                                Text(track.title).tag(Optional(track.id))
                            }
                        }
                    }
                }

                Section("字幕") {
                    Picker(
                        "内封字幕",
                        selection: Binding(
                            get: { viewModel.selectedSubtitleTrackID },
                            set: { viewModel.selectSubtitleTrack(id: $0) }
                        )
                    ) {
                        ForEach(viewModel.subtitleTracks) { track in
                            Text(track.title).tag(track.id)
                        }
                    }
                    Button(action: onFetchExternalSubtitles) {
                        Label(
                            isFetchingExternalSubtitles ? "正在获取外挂字幕…" : "获取外部字幕",
                            systemImage: "text.badge.plus"
                        )
                    }
                    .disabled(isFetchingExternalSubtitles)
                    #if !os(tvOS)
                    Button(action: onImportSubtitle) {
                        Label("导入 SRT / VTT / ASS / SSA", systemImage: "captions.bubble")
                    }
                    #endif
                    if hasExternalSubtitle {
                        Toggle("显示外挂字幕", isOn: $externalSubtitleEnabled)
                        if externalSubtitleResources.count > 1 {
                            Picker(
                                "外挂字幕语言",
                                selection: Binding(
                                    get: { selectedExternalSubtitleID ?? externalSubtitleResources[0].id },
                                    set: { value in onSelectExternalSubtitle(value) }
                                )
                            ) {
                                ForEach(externalSubtitleResources) { resource in
                                    Text(resource.name).tag(resource.id)
                                }
                            }
                        }
                        LabeledContent("当前文件", value: externalSubtitleName ?? "已导入")
                        #if !os(tvOS)
                        Stepper(
                            value: $externalSubtitleOffset,
                            in: -30...30,
                            step: 0.1
                        ) {
                            Text(String(
                                format: "字幕延迟 %@%.1f 秒",
                                externalSubtitleOffset >= 0 ? "+" : "",
                                externalSubtitleOffset
                            ))
                        }
                        #else
                        LabeledContent(
                            "字幕延迟",
                            value: String(format: "%@%.1f 秒", externalSubtitleOffset >= 0 ? "+" : "", externalSubtitleOffset)
                        )
                        #endif
                    }
                }

                #if os(iOS)
                Section("输出") {
                    Button {
                        dismiss()
                        onPictureInPicture()
                    } label: {
                        Label("进入画中画", systemImage: "pip.enter")
                    }
                    ZStack {
                        HStack {
                            Label("选择 AirPlay 设备", systemImage: "airplayvideo")
                            Spacer()
                            Image(systemName: "airplayvideo")
                                .foregroundStyle(.tint)
                                .frame(width: 44, height: 44)
                        }
                        .allowsHitTesting(false)
                        AirPlayRouteButton(isVisuallyHidden: true)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .contentShape(Rectangle())
                }
                #endif

                if settings.isFullFeatureAccessEnabled {
                    Section("弹幕来源") {
                        Button(action: onMatchDanmaku) {
                            Label("搜索或重新匹配弹幕", systemImage: "text.magnifyingglass")
                        }
                        #if !os(tvOS)
                        Button(action: onImportDanmaku) {
                            Label("导入本地弹幕文件", systemImage: "doc.badge.plus")
                        }
                        #endif
                    }
                }

                Section("媒体信息") {
                    LabeledContent("播放路径", value: playbackPathLabel)
                    LabeledContent("分辨率", value: viewModel.mediaInfo.resolution)
                    LabeledContent("时长", value: viewModel.mediaInfo.duration)
                    LabeledContent("来源", value: viewModel.mediaInfo.source)
                    LabeledContent("弹幕", value: viewModel.danmakuStats.isEmpty ? "尚未加载" : viewModel.danmakuStats)
                }
            }
            .kanataFormBackground()
            .navigationTitle("播放设置")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .kanataToolbarTextButton()
                }
            }
        }
    }

    /// 把跳过位置秒数格式化为播放器时间标签。
    /// - Parameter seconds: 片头或片尾位置秒数。
    /// - Returns: mm:ss 或 h:mm:ss 文本。
    private func segmentTimeLabel(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%02d:%02d", minutes, remaining)
    }

    /// 把播放倍率格式化为设置页右侧的稳定文案。
    /// - Parameter rate: 当前播放倍率。
    /// - Returns: 1 倍显示“正常”，其他倍率显示数字与乘号。
    private func playbackRateLabel(_ rate: Double) -> String {
        abs(rate - 1) < 0.001 ? "正常" : "\(rate.formatted())×"
    }
}

/// 使用独立页面选择播放路径，并说明直放与服务器兼容流的区别。
private struct PlaybackRouteSelectionView: View {
    let selection: PlaybackRouteMode
    let isCompatibilityAvailable: Bool
    let onSelect: (PlaybackRouteMode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(PlaybackRouteMode.allCases) { mode in
            Button {
                onSelect(mode)
                dismiss()
            } label: {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode.title)
                            .foregroundStyle(.primary)
                        Text(routeDetail(for: mode))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection == mode {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
            }
            .disabled(mode == .compatible && !isCompatibilityAvailable)
            .kanataTVFocus(cornerRadius: 12)
        }
        .navigationTitle("播放路径")
        .kanataInlineNavigationTitle()
    }

    /// 为不可用的兼容流补充明确原因。
    /// - Parameter mode: 当前播放路径选项。
    /// - Returns: 可直接显示在选项下方的说明。
    private func routeDetail(for mode: PlaybackRouteMode) -> String {
        if mode == .compatible, !isCompatibilityAvailable {
            return "当前来源不支持；仅媒体服务器条目可用"
        }
        return mode.detail
    }
}

/// 使用独立页面选择播放倍速，避免弹窗内菜单偶发失焦。
private struct PlaybackRateSelectionView: View {
    let viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    private let rates: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        List(rates, id: \.self) { rate in
            Button {
                viewModel.setPlaybackRate(rate)
                dismiss()
            } label: {
                HStack {
                    Text(rateLabel(rate))
                        .foregroundStyle(.primary)
                    Spacer()
                    if abs(viewModel.playbackRate - rate) < 0.001 {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .kanataTVFocus(cornerRadius: 12)
        }
        .navigationTitle("播放速度")
        .kanataInlineNavigationTitle()
    }

    /// 把候选倍率转换为用户可读的单选项文案。
    /// - Parameter rate: 候选播放倍率。
    /// - Returns: 1 倍显示“正常”，其他倍率显示数字与乘号。
    private func rateLabel(_ rate: Double) -> String {
        abs(rate - 1) < 0.001 ? "正常" : "\(rate.formatted())×"
    }
}
