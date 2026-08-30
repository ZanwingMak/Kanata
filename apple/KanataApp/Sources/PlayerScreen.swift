import AVFoundation
import KanataCore
import KanataRender
import SwiftUI

/// 播放页。视频、弹幕、控制三层叠加。
struct PlayerScreen: View {
    let url: URL
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel = PlayerViewModel()
    @State private var canvasBridge = DanmakuCanvasBridge()
    @State private var isShowingControls = true
    @State private var isShowingDanmakuPanel = false
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    /// 短暂显示的操作反馈（FR-PLY-403）
    @State private var osdText: String?
    @State private var osdTask: Task<Void, Never>?

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
            withAnimation(.easeInOut(duration: 0.2)) { isShowingControls.toggle() }
        }
        .statusBarHidden()
        .task {
            wireCallbacks()
            await viewModel.open(url: url, settings: settings)
            viewModel.play()
            isPlaying = true
        }
        .onDisappear { viewModel.teardown() }
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
    }

    /// 播放控制层：顶部信息 + 底部进度与按钮
    private var controlsLayer: some View {
        VStack {
            HStack(alignment: .top) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left").font(.title2).padding(8)
                }
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
                    Slider(
                        value: $currentTime,
                        in: 0...max(viewModel.duration, 1),
                        onEditingChanged: { editing in
                            if !editing { viewModel.seek(to: currentTime) }
                        }
                    )
                    Text(timeLabel(viewModel.duration)).font(.caption.monospacedDigit())
                }

                HStack(spacing: 28) {
                    Button {
                        viewModel.seek(to: max(currentTime - 10, 0))
                    } label: {
                        Image(systemName: "gobackward.10").font(.title2)
                    }
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.largeTitle)
                    }
                    Button {
                        viewModel.seek(to: min(currentTime + 10, viewModel.duration))
                    } label: {
                        Image(systemName: "goforward.10").font(.title2)
                    }
                    Spacer()
                    // 弹幕开关与设置入口：从播放画面 1 步可达（FR-PLY-406）
                    Button {
                        settings.danmakuConfig.enabled.toggle()
                        showOSD(settings.danmakuConfig.enabled ? "弹幕已开启" : "弹幕已关闭")
                    } label: {
                        Image(systemName: settings.danmakuConfig.enabled ? "captions.bubble.fill" : "captions.bubble")
                            .font(.title2)
                    }
                    Button {
                        isShowingDanmakuPanel = true
                    } label: {
                        Image(systemName: "slider.horizontal.3").font(.title2)
                    }
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
            currentTime = time
            bridge.sync(time: time, rate: rate)
        }
    }

    private func togglePlayback() {
        if isPlaying {
            viewModel.pause()
            canvasBridge.sync(time: currentTime, rate: 0)
        } else {
            viewModel.play()
        }
        isPlaying.toggle()
    }

    /// 显示一条 1.5 秒后自动淡出的操作反馈
    private func showOSD(_ text: String) {
        osdTask?.cancel()
        withAnimation { osdText = text }
        osdTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation { osdText = nil }
        }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                    ForEach(viewModel.candidates) { candidate in
                        Button {
                            Task { await viewModel.loadDanmaku(for: candidate) }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.title).font(.body)
                                HStack(spacing: 8) {
                                    Text(candidate.source.rawValue)
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
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { keyword = viewModel.parsed?.title ?? "" }
        }
    }
}
