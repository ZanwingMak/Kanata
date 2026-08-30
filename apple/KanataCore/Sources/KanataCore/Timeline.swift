import Foundation

/// 弹幕时轴换算（FR-SYNC-001 ~ FR-SYNC-005）。
/// 最终显示时间：displayTime = item.time * scale + offset

/// 偏移规则的生效范围，优先级由细到粗：episode > season > series > global
public enum OffsetScope: String, Codable, Sendable {
    case global, series, season, episode
}

/// 一条偏移规则
public struct OffsetRule: Codable, Sendable, Hashable {
    public let scope: OffsetScope
    /// 该范围的标识，global 时为空
    public let key: String
    /// 为空表示对所有来源生效
    public let source: DanmakuSourceId?
    /// 秒，正值表示弹幕延后
    public var offset: Double
    /// 时长比缩放，默认 1
    public var scale: Double

    public init(
        scope: OffsetScope,
        key: String = "",
        source: DanmakuSourceId? = nil,
        offset: Double,
        scale: Double = 1
    ) {
        self.scope = scope
        self.key = key
        self.source = source
        self.offset = offset
        self.scale = scale
    }
}

/// 描述当前播放条目在剧集层级中的位置，用于匹配偏移规则
public struct TimelineContext: Sendable {
    public let seriesKey: String
    public let seasonKey: String
    public let episodeKey: String

    public init(seriesKey: String, seasonKey: String, episodeKey: String) {
        self.seriesKey = seriesKey
        self.seasonKey = seasonKey
        self.episodeKey = episodeKey
    }
}

public enum TimelineResolver {
    /// 偏移范围上限（秒）。平台版本差异最大可达一整段片头或广告
    public static let offsetLimit: Double = 600
    /// 手动调节步进（秒）
    public static let offsetStep: Double = 0.5

    /// 解析某个来源当前生效的偏移与缩放。
    /// 规则按 episode → season → series → global 逐级查找，命中即返回；
    /// 同级中指定了来源的规则优先于通配规则（FR-SYNC-005）。
    /// - Returns: (偏移秒数, 缩放系数)，无规则时为 (0, 1)
    public static func resolve(
        rules: [OffsetRule],
        context: TimelineContext,
        source: DanmakuSourceId
    ) -> (offset: Double, scale: Double) {
        let ordered: [(OffsetScope, String)] = [
            (.episode, context.episodeKey),
            (.season, context.seasonKey),
            (.series, context.seriesKey),
            (.global, "")
        ]
        for (scope, key) in ordered {
            let matched = rules.filter { $0.scope == scope && $0.key == key }
            if let exact = matched.first(where: { $0.source == source }) {
                return (exact.offset, exact.scale)
            }
            if let wildcard = matched.first(where: { $0.source == nil }) {
                return (wildcard.offset, wildcard.scale)
            }
        }
        return (0, 1)
    }

    /// 按本地与平台时长差计算缩放系数（FR-SYNC-003）。
    /// 差异小于 1% 时返回 1，不做无谓缩放。
    public static func scale(localDuration: Double, remoteDuration: Double) -> Double {
        guard localDuration > 0, remoteDuration > 0 else { return 1 }
        let ratio = localDuration / remoteDuration
        return abs(ratio - 1) < 0.01 ? 1 : ratio
    }

    /// 把偏移值夹到合法范围并对齐到步进
    public static func clamp(_ offset: Double) -> Double {
        let stepped = (offset / offsetStep).rounded() * offsetStep
        return min(max(stepped, -offsetLimit), offsetLimit)
    }
}
