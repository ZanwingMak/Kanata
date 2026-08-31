import AVFoundation
import KanataCore
import KanataRender
import SwiftUI
import UniformTypeIdentifiers

/// 播放页。视频、弹幕、控制三层叠加。
struct PlayerScreen: View {
    let url: URL
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel = PlayerViewModel()
    @State private var canvasBridge = DanmakuCanvasBridge()
    @State private var isShowingControls = true
    @State private var isShowingDanmakuPanel = false
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var isSeeking = false
    @State private var isImportingDanmaku = false
    @State private var danmakuOperationError: String?
    /// 短暂显示的操作反馈（FR-PLY-403）
    @State private var osdText: String?
    @State private var osdTask: Task<Void, Never>?
    @State private var controlsTask: Task<Void, Never>?

    var body: some View {
        @Bindable var settings = settings

        ZStack {
            Color.black.ignoresSafeArea()
            VideoSurface(player: viewModel.player).ignoresSafeArea()

            DanmakuOverlay(config: settings.danmakuConfig) { view in
                canvasBridge.attach(view)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if isShowingControls {
                controlsLayer
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
        .contentShape(Rectangle())
        .onTapGesture {
            setControlsVisible(!isShowingControls)
        }
        .kanataStatusBarHidden()
        .task {
            wireCallbacks()
            await viewModel.open(url: url, settings: settings)
            if case .ready = viewModel.state {
                viewModel.play()
                isPlaying = true
                scheduleControlsHide()
            }
        }
        .onDisappear {
            osdTask?.cancel()
            controlsTask?.cancel()
            viewModel.teardown()
        }
        .sheet(isPresented: $isShowingDanmakuPanel) {
            DanmakuSettingsPanel(
                config: $settings.danmakuConfig,
                offset: $viewModel.offset,
                onOffsetChanged: { showOSD(String(format: "弹幕延迟 %@%.1fs", viewModel.offset >= 0 ? "+" : "", viewModel.offset)) }
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
                    Image(systemName: "chevron.left").font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("返回媒体库")
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.parsed?.title ?? url.lastPathComponent)
                        .font(.headline).lineLimit(1)
                    Text(viewModel.danmakuStats)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
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

                HStack(spacing: 28) {
                    Button {
                        viewModel.seek(to: max(currentTime - 10, 0))
                    } label: {
                        Image(systemName: "gobackward.10").font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("后退 10 秒")
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.largeTitle)
                            .frame(minWidth: 52, minHeight: 52)
                    }
                    .accessibilityLabel(isPlaying ? "暂停" : "播放")
                    Button {
                        viewModel.seek(to: min(currentTime + 10, viewModel.duration))
                    } label: {
                        Image(systemName: "goforward.10").font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("前进 10 秒")
                    Spacer()
                    // 弹幕开关与设置入口：从播放画面 1 步可达（FR-PLY-406）
                    Button {
                        settings.danmakuConfig.enabled.toggle()
                        showOSD(settings.danmakuConfig.enabled ? "弹幕已开启" : "弹幕已关闭")
                    } label: {
                        Image(systemName: settings.danmakuConfig.enabled ? "captions.bubble.fill" : "captions.bubble")
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(settings.danmakuConfig.enabled ? "关闭弹幕" : "开启弹幕")
                    Button {
                        isShowingDanmakuPanel = true
                    } label: {
                        Image(systemName: "slider.horizontal.3").font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("弹幕设置")
                    #if !os(tvOS)
                    Button {
                        isImportingDanmaku = true
                    } label: {
                        Image(systemName: "doc.badge.plus").font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("导入本地弹幕")
                    #endif
                    Button {
                        viewModel.isShowingCandidates = true
                    } label: {
                        Image(systemName: "magnifyingglass").font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("手动匹配弹幕")
                }
            }
            .padding()
            .background(.black.opacity(0.5))
        }
        .foregroundStyle(.white)
        .transition(.opacity)
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
                                    Text(episodeTitle)
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
                    HStack {
                        TextField("手动搜索剧名", text: $keyword)
                        Button("搜索") {
                            Task { await viewModel.search(keyword: keyword) }
                        }
                        .disabled(keyword.isEmpty)
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
                                        Text(episodeTitle)
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
}
