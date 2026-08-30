import AVFoundation
import KanataCore
import KanataRender
import SwiftUI
import UIKit

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

    /// 内部视图：让 AVPlayerLayer 成为 layerClass，随视图自动布局
    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

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

    var body: some View {
        NavigationStack {
            Form {
                Section("字体大小") {
                    HStack {
                        Text("\(Int(config.fontScale * 100))%")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $config.fontScale, in: 0.5...2.0, step: 0.05)
                    }
                    Picker("快捷档位", selection: $config.fontScale) {
                        Text("小").tag(0.75)
                        Text("中").tag(1.0)
                        Text("大").tag(1.35)
                        Text("超大").tag(1.7)
                    }
                    .pickerStyle(.segmented)
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
                    Slider(value: $offset, in: -120...120, step: TimelineResolver.offsetStep) { editing in
                        if !editing { onOffsetChanged() }
                    }
                    Text("正值表示弹幕延后播放。设置会按季记住，同季其他集自动沿用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("显示") {
                    Toggle("显示弹幕", isOn: $config.enabled)
                    HStack {
                        Text("不透明度")
                        Slider(value: $config.opacity, in: 0.1...1.0, step: 0.05)
                        Text("\(Int(config.opacity * 100))%").monospacedDigit().frame(width: 50)
                    }
                    Picker("显示区域", selection: $config.displayArea) {
                        Text("1/4 屏").tag(DanmakuDisplayArea.quarter)
                        Text("半屏").tag(DanmakuDisplayArea.half)
                        Text("3/4 屏").tag(DanmakuDisplayArea.threeQuarters)
                        Text("全屏").tag(DanmakuDisplayArea.full)
                        Text("仅顶部").tag(DanmakuDisplayArea.topOnly)
                        Text("仅底部").tag(DanmakuDisplayArea.bottomOnly)
                    }
                    HStack {
                        Text("滚动速度")
                        Slider(value: $config.scrollDuration, in: 3...15, step: 0.5)
                        Text("\(config.scrollDuration, specifier: "%.1f")s").monospacedDigit().frame(width: 50)
                    }
                    Toggle("加粗", isOn: $config.bold)
                    Toggle("合并重复弹幕", isOn: $config.mergeDuplicates)
                }

                Section("弹幕类型") {
                    modeToggle("滚动", mode: .scroll)
                    modeToggle("顶部", mode: .top)
                    modeToggle("底部", mode: .bottom)
                    modeToggle("逆向", mode: .reverse)
                }
            }
            .navigationTitle("弹幕设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// 当前偏移的显示文案，带正负号
    private var offsetLabel: String {
        String(format: "%@%.1fs", offset >= 0 ? "+" : "", offset)
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
