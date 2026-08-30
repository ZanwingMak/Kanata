import Foundation
import KanataCore

/// 弹幕显示区域（FR-DMK-111）
public enum DanmakuDisplayArea: String, Codable, Sendable, CaseIterable {
    case quarter        // 上 1/4 屏
    case half           // 上 1/2 屏
    case threeQuarters  // 上 3/4 屏
    case full           // 全屏
    case topOnly        // 仅顶部弹幕
    case bottomOnly     // 仅底部弹幕

    /// 该区域占视图高度的比例
    var heightRatio: Double {
        switch self {
        case .quarter: return 0.25
        case .half: return 0.5
        case .threeQuarters: return 0.75
        case .full, .topOnly, .bottomOnly: return 1.0
        }
    }
}

/// 屏蔽规则（FR-DMK-105）
public struct DanmakuBlockRules: Sendable, Equatable {
    /// 关键词，命中即屏蔽
    public var keywords: [String] = []
    /// 正则表达式源串，非法表达式会被忽略
    public var regexPatterns: [String] = []
    /// 被屏蔽的发送者 hash
    public var senderHashes: Set<String> = []
    /// 屏蔽彩色弹幕，只保留白色
    public var blockColorful = false
    /// 屏蔽重复内容（同一条内容只保留首次出现）
    public var blockRepeated = false

    public init() {}
}

/// 渲染配置。所有可调项都能在播放中实时生效（FR-DMK-103 等）。
public struct DanmakuRenderConfig: Sendable, Equatable {
    /// 弹幕总开关（FR-DMK-107）
    public var enabled = true
    /// 字号缩放，0.5–2.0，对应 UI 上的 50%–200%（FR-DMK-103）
    public var fontScale: Double = 1.0
    /// 不透明度 0.1–1.0（FR-DMK-110）
    public var opacity: Double = 1.0
    /// 显示区域（FR-DMK-111）
    public var displayArea: DanmakuDisplayArea = .half
    /// 滚动弹幕穿屏时长，3–15 秒（FR-DMK-112）
    public var scrollDuration: Double = 8
    /// 顶部/底部弹幕停留时长
    public var staticDuration: Double = 4
    /// 轨道数上限，0 表示按显示区域自动计算
    public var maxTracks = 0
    /// 轨道行距
    public var lineSpacing: Double = 4
    /// 自定义字体名，nil 表示系统字体（FR-DMK-113）
    public var fontName: String?
    public var bold = true
    /// 描边宽度，保证低对比画面下可读
    public var strokeWidth: Double = 2.0
    /// 同屏弹幕上限，超出按权重丢弃（FR-DMK-104）
    public var densityLimit = 300
    /// 合并重复弹幕并显示 ×N（FR-DMK-114）
    public var mergeDuplicates = false
    /// 允许显示的弹幕模式
    public var modeFilter: Set<DanmakuMode> = [.scroll, .top, .bottom, .reverse]
    /// 只显示这些来源，空集表示不限制
    public var sourceFilter: Set<DanmakuSourceId> = []
    public var blockRules = DanmakuBlockRules()

    public init() {}

    /// 基准字号 25pt 是以 1920 宽为基准的，按实际视图宽度换算，
    /// 保证 1080p 与 4K 下视觉大小一致（TC-DMK-104）
    /// - Parameters:
    ///   - itemFontSize: 弹幕自带的平台字号
    ///   - viewWidth: 渲染视图宽度（点）
    func resolvedFontSize(itemFontSize: Double, viewWidth: Double) -> Double {
        let widthRatio = max(viewWidth / 1920.0, 0.5)
        return itemFontSize * fontScale * widthRatio
    }
}
