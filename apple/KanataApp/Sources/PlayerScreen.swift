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
    let url: URL
    var requestHeaders: [String: String] = [:]
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel = PlayerViewModel()
    @State private var canvasBridge = DanmakuCanvasBridge()
    @State private var surfaceController = PlayerSurfaceController()
    @State private var isShowingControls = true
    @State private var isShowingDanmakuPanel = false
    @State private var isShowingPlaybackPanel = false
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var isSeeking = false
    @State private var isImportingDanmaku = false
    @State private var danmakuOperationError: String?
    /// 短暂显示的操作反馈（FR-PLY-403）
    @State private var osdText: String?
    @State private var osdTask: Task<Void, Never>?
    @State private var controlsTask: Task<Void, Never>?
    @State private var scalingMode = PlayerScalingMode.fit
    #if os(iOS)
    @State private var gestureMode: PlayerGestureMode?
    @State private var gestureStartValue: Double = 0
    @State private var isLandscapeFullscreen = false
    #endif

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

            DanmakuOverlay(config: settings.danmakuConfig) { view in
                canvasBridge.attach(view)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            interactionLayer

            if isShowingControls {
                controlsLayer
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
        .task {
            wireCallbacks()
            await viewModel.open(url: url, settings: settings, requestHeaders: requestHeaders)
            if case .ready = viewModel.state {
                viewModel.play()
                isPlaying = true
                if let resumePosition = viewModel.resumePosition {
                    currentTime = resumePosition
                    showOSD("继续播放 · \(timeLabel(resumePosition))")
                }
                scheduleControlsHide()
            }
        }
        .onDisappear {
            osdTask?.cancel()
            controlsTask?.cancel()
            viewModel.teardown()
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
                onImportDanmaku: {
                    isShowingPlaybackPanel = false
                    isImportingDanmaku = true
                },
                onMatchDanmaku: {
                    isShowingPlaybackPanel = false
                    viewModel.isShowingCandidates = true
                },
                onPictureInPicture: { surfaceController.togglePictureInPicture() }
            )
            .presentationDetents([.medium, .large])
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
    }

    /// 覆盖在视频与弹幕之上的手势层；控制按钮出现时仍由上层按钮优先响应。
    @ViewBuilder
    private var interactionLayer: some View {
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
                Button("返回媒体库") { dismiss() }
                    .buttonStyle(.borderedProminent)
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
                    dismiss()
                } label: {
                    controlSymbol("chevron.left", prominent: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回媒体库")
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.parsed?.title ?? url.lastPathComponent)
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
                .buttonStyle(.plain)
                .accessibilityLabel(isLandscapeFullscreen ? "退出横屏全屏" : "横屏全屏")
                #endif
                Button {
                    isShowingPlaybackPanel = true
                } label: {
                    controlSymbol("ellipsis", prominent: false)
                }
                .buttonStyle(.plain)
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

                HStack(spacing: 10) {
                    Button {
                        viewModel.seek(to: max(currentTime - 10, 0))
                        showOSD("后退 10 秒")
                    } label: {
                        controlSymbol("gobackward.10", prominent: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("后退 10 秒")
                    Button {
                        togglePlayback()
                    } label: {
                        controlSymbol(isPlaying ? "pause.fill" : "play.fill", prominent: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPlaying ? "暂停" : "播放")
                    Button {
                        viewModel.seek(to: min(currentTime + 10, viewModel.duration))
                        showOSD("前进 10 秒")
                    } label: {
                        controlSymbol("goforward.10", prominent: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("前进 10 秒")
                    Spacer()
                    Button {
                        settings.danmakuConfig.enabled.toggle()
                        showOSD(settings.danmakuConfig.enabled ? "弹幕已开启" : "弹幕已关闭")
                    } label: {
                        controlSymbol(
                            settings.danmakuConfig.enabled ? "captions.bubble.fill" : "captions.bubble",
                            prominent: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settings.danmakuConfig.enabled ? "关闭弹幕" : "开启弹幕")
                    Button {
                        isShowingDanmakuPanel = true
                    } label: {
                        controlSymbol("slider.horizontal.3", prominent: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("弹幕设置")
                    Button {
                        viewModel.isShowingCandidates = true
                    } label: {
                        controlSymbol("text.magnifyingglass", prominent: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("手动匹配弹幕")
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
        .transition(.opacity)
    }

    /// 统一播放器控制按钮的尺寸、材质与高对比度。
    /// - Parameters:
    ///   - name: SF Symbol 名称。
    ///   - prominent: 是否为中心播放主按钮。
    /// - Returns: 可直接放进 Button label 的图标视图。
    private func controlSymbol(_ name: String, prominent: Bool) -> some View {
        Image(systemName: name)
            .font(prominent ? .title2.weight(.semibold) : .body.weight(.semibold))
            .frame(width: prominent ? 52 : 44, height: prominent ? 52 : 44)
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
            isPlaying = false
            currentTime = viewModel.duration
            setControlsVisible(true)
            showOSD("播放结束")
        }
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
        let target = !isLandscapeFullscreen
        isLandscapeFullscreen = target
        PlayerOrientationController.requestLandscape(target) { error in
            isLandscapeFullscreen.toggle()
            danmakuOperationError = "无法切换屏幕方向：\(error.localizedDescription)"
        }
        showOSD(target ? "横屏全屏" : "退出横屏")
    }
    #endif

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

    /// 返回文件选择器允许显示的本地弹幕类型。
    private var danmakuFileTypes: [UTType] {
        [.xml, .json, UTType(filenameExtension: "ass") ?? .plainText]
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
    let onImportDanmaku: () -> Void
    let onMatchDanmaku: () -> Void
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
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                            Text(rate == 1 ? "正常" : "\(rate.formatted())×").tag(rate)
                        }
                    }
                    Picker("画面比例", selection: $scalingMode) {
                        ForEach(PlayerScalingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
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
}
