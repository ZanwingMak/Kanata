import AVFoundation
import AVKit
import KanataCore
import KanataRender
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 管理 AVPlayerLayer 关联的画中画控制器，避免 SwiftUI 重建时丢失引用。
@MainActor
final class PlayerSurfaceController {
    private weak var containerView: VideoSurface.PlayerContainerView?

    /// 绑定当前承载视频图层的 UIKit 视图。
    /// - Parameter view: SwiftUI 当前创建的容器。
    func attach(_ view: VideoSurface.PlayerContainerView) {
        containerView = view
        view.preparePictureInPicture()
    }

    /// 启动或停止系统画中画；设备不支持时安全忽略。
    func togglePictureInPicture() {
        containerView?.togglePictureInPicture()
    }

    /// 当前设备是否支持画中画。
    var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }
}

/// 在 SwiftUI 状态与 UIKit 弹幕画布之间转发数据，并处理两者创建顺序不确定的问题。
@MainActor
final class DanmakuCanvasBridge {
    private weak var canvas: DanmakuCanvasView?
    private var items: [DanmakuItem] = []
    private var time: Double = 0
    private var rate: Double = 0

    /// 绑定新创建的画布，并立即补发最新弹幕与播放时间。
    /// - Parameter canvas: SwiftUI 当前承载的弹幕画布。
    func attach(_ canvas: DanmakuCanvasView) {
        self.canvas = canvas
        canvas.load(items: items)
        canvas.sync(time: time, rate: rate)
    }

    /// 保存并转发整集弹幕；画布尚未创建时仅缓存数据。
    /// - Parameter items: 已按时间升序排列的弹幕列表。
    func load(items: [DanmakuItem]) {
        self.items = items
        canvas?.load(items: items)
    }

    /// 保存并转发播放器时间，保证后创建的画布能恢复到当前进度。
    /// - Parameters:
    ///   - time: 当前播放时间，单位秒。
    ///   - rate: 当前播放速率，暂停时为 0。
    func sync(time: Double, rate: Double) {
        self.time = time
        self.rate = rate
        canvas?.sync(time: time, rate: rate)
    }
}

/// 承载 AVPlayerLayer 的视频画面层
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer?
    let videoGravity: AVLayerVideoGravity
    let controller: PlayerSurfaceController

    /// 内部视图：让 AVPlayerLayer 成为 layerClass，随视图自动布局
    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var pictureInPictureController: AVPictureInPictureController?

        /// 在图层已有播放器后创建系统画中画控制器。
        func preparePictureInPicture() {
            guard AVPictureInPictureController.isPictureInPictureSupported(),
                  pictureInPictureController == nil else { return }
            guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return }
#if os(iOS)
            controller.canStartPictureInPictureAutomaticallyFromInline = true
#endif
            pictureInPictureController = controller
        }

        /// 切换系统画中画状态。
        func togglePictureInPicture() {
            preparePictureInPicture()
            guard let pictureInPictureController else { return }
            if pictureInPictureController.isPictureInPictureActive {
                pictureInPictureController.stopPictureInPicture()
            } else if pictureInPictureController.isPictureInPicturePossible {
                pictureInPictureController.startPictureInPicture()
            }
        }
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = videoGravity
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != videoGravity {
            uiView.playerLayer.videoGravity = videoGravity
        }
        uiView.preparePictureInPicture()
    }
}

#if os(iOS)
/// 系统 AirPlay 路由选择按钮。
struct AirPlayRouteButton: UIViewRepresentable {
    /// 创建原生路由选择器并使用浅色图标适配播放器背景。
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemCyan
        view.prioritizesVideoDevices = true
        return view
    }

    /// 路由状态由系统维护，无需额外同步。
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

/// 弹幕渲染层的 SwiftUI 包装。
/// 时间同步不走 SwiftUI 的状态更新，而是由 ViewModel 持有画布引用后直接调用，
/// 避免每 0.1 秒触发一次视图 diff。
struct DanmakuOverlay: UIViewRepresentable {
    let config: DanmakuRenderConfig
    /// 画布创建后回传，供上层直接驱动
    let onCreate: (DanmakuCanvasView) -> Void

    func makeUIView(context: Context) -> DanmakuCanvasView {
        let view = DanmakuCanvasView()
        view.config = config
        onCreate(view)
        return view
    }

    func updateUIView(_ uiView: DanmakuCanvasView, context: Context) {
        if uiView.config != config {
            uiView.config = config
        }
    }
}

/// 弹幕设置面板（FR-DMK-103 / FR-SYNC-001）。
/// 字号与延迟是使用频率最高的两项，放在最上方。
struct DanmakuSettingsPanel: View {
    @Binding var config: DanmakuRenderConfig
    @Binding var offset: Double
    let onOffsetChanged: () -> Void
    @State private var fontOptions = DanmakuFontRegistry.availableFonts()
    @State private var isImportingFont = false
    @State private var fontImportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("清晰样式") {
                    Button {
                        applyReadableDanmakuStyle()
                    } label: {
                        KanataRowLabel(
                            title: "应用清晰细描边样式",
                            detail: "常规字重、白字、细黑边与柔和阴影",
                            symbol: "textformat"
                        )
                    }
                    .buttonStyle(KanataSecondaryButtonStyle())
                }

                Section("字体大小") {
                    #if os(tvOS)
                    TVValueAdjuster(
                        title: "字号比例",
                        value: "\(Int(config.fontScale * 100))%",
                        onDecrement: { config.fontScale = max(0.5, config.fontScale - 0.05) },
                        onIncrement: { config.fontScale = min(2, config.fontScale + 0.05) }
                    )
                    #else
                    HStack {
                        Text("\(Int(config.fontScale * 100))%")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $config.fontScale, in: 0.5...2.0, step: 0.05)
                    }
                    #endif
                    Picker("快捷档位", selection: $config.fontScale) {
                        Text("小").tag(0.75)
                        Text("清晰").tag(0.9)
                        Text("中").tag(1.1)
                        Text("大").tag(1.35)
                    }
                    .pickerStyle(.segmented)
                }

                Section("弹幕字体") {
                    Picker("字体", selection: selectedFontName) {
                        ForEach(fontOptions) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    #if !os(tvOS)
                    Button {
                        isImportingFont = true
                    } label: {
                        Label("导入字体文件", systemImage: "text.badge.plus")
                    }
                    Text("支持 TTF、OTF 和 TTC；字体仅保存在本机应用目录，不会上传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #else
                    Text("Apple TV 支持上方内置字体；字体文件导入目前仅在 iPhone 和 iPad 提供。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }

                Section("弹幕延迟") {
                    HStack {
                        Text(offsetLabel)
                            .monospacedDigit()
                            .frame(width: 80, alignment: .leading)
                        Spacer()
                        Button {
                            offset -= TimelineResolver.offsetStep
                            onOffsetChanged()
                        } label: {
                            Image(systemName: "minus.circle.fill").font(.title2)
                        }
                        Button {
                            offset += TimelineResolver.offsetStep
                            onOffsetChanged()
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.title2)
                        }
                        Button("归零") {
                            offset = 0
                            onOffsetChanged()
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    #if !os(tvOS)
                    Slider(value: $offset, in: -120...120, step: TimelineResolver.offsetStep) { editing in
                        if !editing { onOffsetChanged() }
                    }
                    #endif
                    Text("正值表示弹幕延后播放。设置会按季记住，同季其他集自动沿用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("显示") {
                    Toggle("显示弹幕", isOn: $config.enabled)
                    #if os(tvOS)
                    TVValueAdjuster(
                        title: "不透明度",
                        value: "\(Int(config.opacity * 100))%",
                        onDecrement: { config.opacity = max(0.1, config.opacity - 0.05) },
                        onIncrement: { config.opacity = min(1, config.opacity + 0.05) }
                    )
                    #else
                    HStack {
                        Text("不透明度")
                        Slider(value: $config.opacity, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(config.opacity * 100))%").monospacedDigit().frame(width: 50)
                    }
                    #endif
                    Picker("显示区域", selection: $config.displayArea) {
                        Text("1/4 屏").tag(DanmakuDisplayArea.quarter)
                        Text("半屏").tag(DanmakuDisplayArea.half)
                        Text("3/4 屏").tag(DanmakuDisplayArea.threeQuarters)
                        Text("全屏").tag(DanmakuDisplayArea.full)
                        Text("仅顶部").tag(DanmakuDisplayArea.topOnly)
                        Text("仅底部").tag(DanmakuDisplayArea.bottomOnly)
                    }
                    #if os(tvOS)
                    TVValueAdjuster(
                        title: "滚动速度",
                        value: String(format: "%.1f 秒", config.scrollDuration),
                        onDecrement: { config.scrollDuration = max(3, config.scrollDuration - 0.5) },
                        onIncrement: { config.scrollDuration = min(15, config.scrollDuration + 0.5) }
                    )
                    #else
                    HStack {
                        Text("滚动速度")
                        Slider(value: $config.scrollDuration, in: 3...15, step: 0.5)
                        Text("\(config.scrollDuration, specifier: "%.1f")s").monospacedDigit().frame(width: 50)
                    }
                    #endif
                    Toggle("加粗", isOn: $config.bold)
                    Toggle("合并重复弹幕", isOn: $config.mergeDuplicates)
                    #if os(tvOS)
                    TVValueAdjuster(
                        title: "描边宽度",
                        value: String(format: "%.1f", config.strokeWidth),
                        onDecrement: { config.strokeWidth = max(0, config.strokeWidth - 0.25) },
                        onIncrement: { config.strokeWidth = min(3, config.strokeWidth + 0.25) }
                    )
                    TVValueAdjuster(
                        title: "同屏上限",
                        value: "\(config.densityLimit) 条",
                        onDecrement: { config.densityLimit = max(50, config.densityLimit - 50) },
                        onIncrement: { config.densityLimit = min(500, config.densityLimit + 50) }
                    )
                    #else
                    HStack {
                        Text("描边")
                        Slider(value: $config.strokeWidth, in: 0...3, step: 0.25)
                        Text("\(config.strokeWidth, specifier: "%.2g")").monospacedDigit().frame(width: 36)
                    }
                    HStack {
                        Text("同屏上限")
                        Slider(
                            value: Binding(
                                get: { Double(config.densityLimit) },
                                set: { config.densityLimit = Int($0) }
                            ),
                            in: 50...500,
                            step: 50
                        )
                        Text("\(config.densityLimit)").monospacedDigit().frame(width: 40)
                    }
                    #endif
                }

                Section("弹幕类型") {
                    modeToggle("滚动", mode: .scroll)
                    modeToggle("顶部", mode: .top)
                    modeToggle("底部", mode: .bottom)
                    modeToggle("逆向", mode: .reverse)
                }

                Section("屏蔽") {
                    Toggle("屏蔽彩色弹幕", isOn: $config.blockRules.blockColorful)
                    Toggle("相同内容只显示一次", isOn: $config.blockRules.blockRepeated)
                    TextField("屏蔽关键词，用逗号分隔", text: keywordsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("关键词会立即应用到当前视频；可同时填写中文逗号和英文逗号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("恢复默认弹幕样式", role: .destructive) {
                        config = DanmakuRenderConfig()
                        offset = 0
                        onOffsetChanged()
                    }
                }
            }
            .kanataFormBackground()
            .navigationTitle("弹幕设置")
            .kanataInlineNavigationTitle()
            .kanataFileImporter(
                isPresented: $isImportingFont,
                allowedContentTypes: fontFileTypes,
                allowsMultipleSelection: false,
                onCompletion: handleFontImport
            )
            .alert(
                "无法导入字体",
                isPresented: Binding(
                    get: { fontImportError != nil },
                    set: { if !$0 { fontImportError = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(fontImportError ?? "未知错误")
            }
        }
    }

    /// 把可空字体名映射成 Picker 使用的字符串。
    private var selectedFontName: Binding<String> {
        Binding(
            get: { config.fontName ?? "" },
            set: { config.fontName = $0.isEmpty ? nil : $0 }
        )
    }

    /// 应用参考主流视频网站观感的常规字重、细描边和柔和阴影配置。
    private func applyReadableDanmakuStyle() {
        config.fontName = nil
        config.fontScale = 0.9
        config.opacity = 1
        config.lineSpacing = 7
        config.bold = false
        config.strokeWidth = 0.6
    }

    /// 返回字体文件选择器允许显示的类型。
    private var fontFileTypes: [UTType] {
        ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }
    }

    /// 读取安全作用域字体文件、注册字体并立刻切换为新字体。
    /// - Parameter result: 系统文件选择器结果。
    private func handleFontImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let fontName = try DanmakuFontRegistry.importFont(from: url)
            fontOptions = DanmakuFontRegistry.availableFonts()
            config.fontName = fontName
        } catch {
            fontImportError = error.localizedDescription
        }
    }

    /// 当前偏移的显示文案，带正负号
    private var offsetLabel: String {
        String(format: "%@%.1fs", offset >= 0 ? "+" : "", offset)
    }

    /// 把屏蔽关键词数组映射成逗号分隔的可编辑文本。
    private var keywordsText: Binding<String> {
        Binding(
            get: { config.blockRules.keywords.joined(separator: "，") },
            set: { value in
                config.blockRules.keywords = value
                    .split(whereSeparator: { $0 == "," || $0 == "，" })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    /// 单个弹幕模式的开关
    private func modeToggle(_ title: String, mode: DanmakuMode) -> some View {
        Toggle(title, isOn: Binding(
            get: { config.modeFilter.contains(mode) },
            set: { isOn in
                if isOn { config.modeFilter.insert(mode) } else { config.modeFilter.remove(mode) }
            }
        ))
    }
}

#if os(tvOS)
/// tvOS 使用可聚焦的加减按钮替代系统未提供的 Slider 与 Stepper。
private struct TVValueAdjuster: View {
    let title: String
    let value: String
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
            Button(action: onDecrement) {
                Image(systemName: "minus")
            }
            .accessibilityLabel("减小\(title)")
            Button(action: onIncrement) {
                Image(systemName: "plus")
            }
            .accessibilityLabel("增大\(title)")
        }
    }
}
#endif
