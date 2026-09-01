import AVFoundation
import KanataCore
import KanataRender
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
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
    /// 构建不带缩放动画的播放器按钮。
    /// - Parameter configuration: SwiftUI 按钮按压状态。
    /// - Returns: 仅改变透明度的按钮内容。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(1)
            .animation(nil, value: configuration.isPressed)
    }
}

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
    @State private var externalSubtitleOffset = 0.0
    @State private var isExternalSubtitleEnabled = true
    @State private var skipSegment = PlaybackSkipSegment()
    @State private var isConfirmingExit = false
    @State private var resumesAfterExitCancellation = false
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
            VideoSurface(
                player: viewModel.player,
                videoGravity: scalingMode.gravity,
                controller: surfaceController
            )
                .ignoresSafeArea()

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

            if isShowingControls {
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
        .kanataStatusBarHidden()
        .interactiveDismissDisabled()
        .onAppear { setIdleTimerDisabled(true) }
        .task(id: activeItem.id) { await openActiveItem() }
        .onChange(of: sleepMode) { _, value in
            configureSleepTimer(value)
        }
        .onDisappear {
            osdTask?.cancel()
            controlsTask?.cancel()
            sleepTask?.cancel()
            viewModel.teardown()
            setIdleTimerDisabled(false)
            #if os(iOS)
            if isLandscapeFullscreen {
                PlayerOrientationController.requestLandscape(false) { _ in }
            }
            #endif
        }
        .sheet(isPresented: $isShowingDanmakuPanel) {
            DanmakuSettingsPanel(
                config: $settings.danmakuConfig,
                offset: $viewModel.offset,
                onOffsetChanged: { showOSD(String(format: "弹幕延迟 %@%.1fs", viewModel.offset >= 0 ? "+" : "", viewModel.offset)) }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingPlaybackPanel) {
            PlaybackOptionsPanel(
                viewModel: viewModel,
                scalingMode: $scalingMode,
                queueMode: $queueMode,
                sleepMode: $sleepMode,
                hasExternalSubtitle: !externalSubtitleCues.isEmpty,
                externalSubtitleName: externalSubtitleName,
                externalSubtitleEnabled: $isExternalSubtitleEnabled,
                externalSubtitleOffset: $externalSubtitleOffset,
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
                onMarkIntro: { updateSkipSegment(introEnd: currentTime) },
                onMarkOutro: { updateSkipSegment(outroStart: currentTime) },
                onClearSkipSegment: { clearSkipSegment() },
                onPictureInPicture: { surfaceController.togglePictureInPicture() }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingPlaylist) {
            PlaylistPicker(
                items: items,
                currentItemID: activeItem.id,
                onSelect: selectItem
            )
        }
        .sheet(isPresented: $viewModel.isShowingCandidates) {
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
            "弹幕操作失败",
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
                        viewModel.seek(to: introEnd)
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
                            viewModel.seek(to: viewModel.duration)
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
        } else {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    togglePlayback()
                    showOSD(isPlaying ? "播放" : "暂停")
                }
                .onTapGesture {
                    setControlsVisible(!isShowingControls)
                }
                #if os(iOS)
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
                    viewModel.seek(to: currentTime)
                    canvasBridge.sync(time: currentTime, rate: isPlaying ? viewModel.playbackRate : 0)
                }
                gestureMode = nil
                isSeeking = false
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
            ContentUnavailableView {
                Label("无法播放视频", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") {
                    Task { await openActiveItem() }
                }
                    .buttonStyle(.borderedProminent)
                Button("返回") { handleBack() }
                    .buttonStyle(.bordered)
            }
            .foregroundStyle(.white)
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
                .accessibilityLabel(isFullscreenBackAction ? "退出横屏全屏" : "返回媒体库")
                VStack(alignment: .leading, spacing: 3) {
                    Text(activeItem.collectionTitle ?? viewModel.parsed?.title ?? activeItem.displayName)
                        .font(.headline).lineLimit(1)
                    Text(viewModel.danmakuStats)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }
                Spacer()
                #if os(iOS)
                Button {
                    toggleLandscapeFullscreen()
                } label: {
                    controlSymbol(
                        isLandscapeFullscreen
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right",
                        prominent: false
                    )
                }
                .buttonStyle(PlayerControlButtonStyle())
                .accessibilityLabel(isLandscapeFullscreen ? "退出横屏全屏" : "横屏全屏")
                #endif
                Button {
                    isShowingPlaybackPanel = true
                } label: {
                    controlSymbol("ellipsis", prominent: false)
                }
                .buttonStyle(PlayerControlButtonStyle())
                .accessibilityLabel("更多播放设置")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
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
                    ProgressView(value: currentTime, total: max(viewModel.duration, 1))
                    #else
                    Slider(
                        value: $currentTime,
                        in: 0...max(viewModel.duration, 1),
                        onEditingChanged: { editing in
                            isSeeking = editing
                            if !editing {
                                viewModel.seek(to: currentTime)
                                scheduleControlsHide()
                            } else {
                                controlsTask?.cancel()
                            }
                        }
                    )
                    #endif
                    Text(timeLabel(viewModel.duration)).font(.caption.monospacedDigit())
                }

                ViewThatFits(in: .horizontal) {
                    playbackControlRow(showAllActions: true, compact: false)
                    playbackControlRow(showAllActions: false, compact: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 12)
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
        HStack(spacing: compact ? 6 : 10) {
                    Button {
                        viewModel.seek(to: max(currentTime - 10, 0))
                        showOSD("后退 10 秒")
                    } label: {
                        controlSymbol("gobackward.10", prominent: false, compact: compact)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .accessibilityLabel("后退 10 秒")
                    if items.count > 1 {
                        Button {
                            moveEpisode(by: -1)
                        } label: {
                            controlSymbol("backward.end.fill", prominent: false, compact: compact)
                        }
                        .buttonStyle(PlayerControlButtonStyle())
                        .disabled(activeIndex == 0)
                        .accessibilityLabel("上一集")
                    }
                    Button {
                        togglePlayback()
                    } label: {
                        controlSymbol(isPlaying ? "pause.fill" : "play.fill", prominent: true, compact: compact)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .accessibilityLabel(isPlaying ? "暂停" : "播放")
                    Button {
                        viewModel.seek(to: min(currentTime + 10, viewModel.duration))
                        showOSD("前进 10 秒")
                    } label: {
                        controlSymbol("goforward.10", prominent: false, compact: compact)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .accessibilityLabel("前进 10 秒")
                    if items.count > 1 {
                        Button {
                            moveEpisode(by: 1)
                        } label: {
                            controlSymbol("forward.end.fill", prominent: false, compact: compact)
                        }
                        .buttonStyle(PlayerControlButtonStyle())
                        .disabled(activeIndex >= items.count - 1)
                        .accessibilityLabel("下一集")
                    }
                    if showAllActions { Spacer() }
                    if items.count > 1 {
                        Button {
                            isShowingPlaylist = true
                        } label: {
                            controlSymbol("rectangle.stack", prominent: false, compact: compact)
                        }
                        .buttonStyle(PlayerControlButtonStyle())
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
                        .accessibilityLabel(settings.danmakuConfig.enabled ? "关闭弹幕" : "开启弹幕")
                    }
                    Button {
                        isShowingDanmakuPanel = true
                    } label: {
                        controlSymbol("slider.horizontal.3", prominent: false, compact: compact)
                    }
                    .buttonStyle(PlayerControlButtonStyle())
                    .accessibilityLabel("弹幕设置")
                    if showAllActions {
                        Button {
                            viewModel.isShowingCandidates = true
                        } label: {
                            controlSymbol("text.magnifyingglass", prominent: false, compact: compact)
                        }
                        .buttonStyle(PlayerControlButtonStyle())
                        .accessibilityLabel("手动匹配弹幕")
                        #if os(iOS)
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
        let regularSize: CGFloat = compact ? 38 : 44
        let primarySize: CGFloat = compact ? 46 : 52
        return Image(systemName: name)
            .font(prominent ? .title2.weight(.semibold) : .body.weight(.semibold))
            .frame(
                width: prominent ? primarySize : regularSize,
                height: prominent ? primarySize : regularSize
            )
            .background(
                prominent ? Color.white.opacity(0.24) : Color.black.opacity(0.34),
                in: Circle()
            )
            .overlay(Circle().stroke(.white.opacity(prominent ? 0.25 : 0.12), lineWidth: 1))
            .contentShape(Circle())
    }

    /// 把 ViewModel 的数据与时间回调接到渲染层
    private func wireCallbacks() {
        let bridge = canvasBridge
        viewModel.onItemsChanged = { items in
            bridge.load(items: items)
        }
        viewModel.onTimeChanged = { time, rate in
            if !isSeeking { currentTime = time }
            bridge.sync(time: time, rate: rate)
        }
        viewModel.onPlaybackStateChanged = { playing in
            isPlaying = playing
            if playing {
                scheduleControlsHide()
            } else {
                setControlsVisible(true)
            }
        }
        viewModel.onPlaybackEnded = {
            handlePlaybackEnded()
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
        setControlsVisible(true)
        showOSD(message)
    }

    /// 释放上一集资源、打开当前条目并恢复其断点进度。
    private func openActiveItem() async {
        viewModel.teardown()
        canvasBridge.load(items: [])
        externalSubtitleCues = []
        externalSubtitleName = nil
        externalSubtitleOffset = 0
        skipSegment = PlaybackSkipSegmentStore.segment(for: skipSegmentKey)
        currentTime = 0
        isPlaying = false
        guard let url = activeItem.resolveURL() else {
            danmakuOperationError = "无法访问 \(activeItem.displayName)，请重新连接媒体源"
            return
        }
        await autoLoadSiblingSubtitle(for: url)
        wireCallbacks()
        await viewModel.open(
            url: url,
            displayName: automaticMatchName,
            settings: settings,
            requestHeaders: activeItem.requestHeaders()
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
            canvasBridge.sync(time: currentTime, rate: 0)
        } else {
            viewModel.play()
        }
        isPlaying.toggle()
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

    /// 为本地视频自动查找并载入同目录、同文件名的外挂字幕。
    /// - Parameter videoURL: 当前本地视频地址；网络视频不会扫描。
    private func autoLoadSiblingSubtitle(for videoURL: URL) async {
        guard videoURL.isFileURL else { return }
        let hasAccess = videoURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { videoURL.stopAccessingSecurityScopedResource() } }
        let directory = videoURL.deletingLastPathComponent()
        let stem = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        let supported = Set(["srt", "vtt", "ass", "ssa"])
        guard let candidate = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first(where: {
            supported.contains($0.pathExtension.lowercased())
                && $0.deletingPathExtension().lastPathComponent.lowercased() == stem
        }), let data = try? Data(contentsOf: candidate) else { return }
        do {
            let cues = try await Task.detached(priority: .utility) {
                try ExternalSubtitleParser.parse(data: data, fileName: candidate.lastPathComponent)
            }.value
            externalSubtitleCues = cues
            externalSubtitleName = candidate.lastPathComponent
            isExternalSubtitleEnabled = true
        } catch {
            danmakuOperationError = "同名字幕读取失败：\(error.localizedDescription)"
        }
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
                                    .foregroundStyle(.cyan)
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
                }
            }
        }
    }
}

/// 弹幕来源候选选择（FR-MATCH-003）
struct CandidatePicker: View {
    let viewModel: PlayerViewModel
    @State private var keyword = ""
    @State private var operationError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                            Task {
                                do {
                                    try await viewModel.removeLocalDanmaku()
                                } catch {
                                    operationError = error.localizedDescription
                                }
                            }
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
                                .onSubmit { Task { await viewModel.search(keyword: keyword) } }
                            if viewModel.isSearchingCandidates { ProgressView() }
                        }
                        Button("搜索") {
                            Task { await viewModel.search(keyword: keyword) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSearchingCandidates)
                        Text("搜索不会再强制使用文件名推断的集号；选择正确分集后会记住，下次自动加载。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("候选（\(viewModel.candidates.count)）") {
                    if viewModel.candidates.isEmpty {
                        Text(viewModel.danmakuStats.isEmpty ? "输入作品关键词开始搜索" : viewModel.danmakuStats)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(viewModel.candidates) { candidate in
                        Button {
                            Task {
                                if await viewModel.loadDanmaku(for: candidate) {
                                    dismiss()
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title).font(.body)
                                HStack(spacing: 8) {
                                    Text(candidate.sourceInstanceName ?? candidate.source.displayName)
                                    if let episodeTitle = candidate.episodeTitle, !episodeTitle.isEmpty {
                                        Text(normalizedEpisodeTitle(episodeTitle))
                                    }
                                    Text("匹配度 \(Int(candidate.confidence * 100))%")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择弹幕来源")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { keyword = viewModel.parsed?.title ?? "" }
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
}

/// 播放器二级控制面板，集中放置低频但重要的画面、音轨、字幕与媒体信息。
struct PlaybackOptionsPanel: View {
    let viewModel: PlayerViewModel
    @Binding var scalingMode: PlayerScalingMode
    @Binding var queueMode: PlaybackQueueMode
    @Binding var sleepMode: SleepTimerMode
    let hasExternalSubtitle: Bool
    let externalSubtitleName: String?
    @Binding var externalSubtitleEnabled: Bool
    @Binding var externalSubtitleOffset: Double
    let skipSegment: PlaybackSkipSegment
    let onImportDanmaku: () -> Void
    let onMatchDanmaku: () -> Void
    let onImportSubtitle: () -> Void
    let onMarkIntro: () -> Void
    let onMarkOutro: () -> Void
    let onClearSkipSegment: () -> Void
    let onPictureInPicture: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Picker(
                        "播放速度",
                        selection: Binding(
                            get: { viewModel.playbackRate },
                            set: { viewModel.setPlaybackRate($0) }
                        )
                    ) {
                        ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4], id: \.self) { rate in
                            Text(rate == 1 ? "正常" : "\(rate.formatted())×").tag(rate)
                        }
                    }
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
                    #if !os(tvOS)
                    Button(action: onImportSubtitle) {
                        Label("导入 SRT / VTT / ASS / SSA", systemImage: "captions.bubble")
                    }
                    #endif
                    if hasExternalSubtitle {
                        Toggle("显示外挂字幕", isOn: $externalSubtitleEnabled)
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
                    HStack {
                        Label("AirPlay", systemImage: "airplayvideo")
                        Spacer()
                        AirPlayRouteButton()
                            .frame(width: 44, height: 44)
                    }
                }
                #endif

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

                Section("媒体信息") {
                    LabeledContent("分辨率", value: viewModel.mediaInfo.resolution)
                    LabeledContent("时长", value: viewModel.mediaInfo.duration)
                    LabeledContent("来源", value: viewModel.mediaInfo.source)
                    LabeledContent("弹幕", value: viewModel.danmakuStats.isEmpty ? "尚未加载" : viewModel.danmakuStats)
                }
            }
            .navigationTitle("播放设置")
            .kanataInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
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
}
