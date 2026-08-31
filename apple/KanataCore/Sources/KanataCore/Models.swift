import Foundation

/// 数据模型。与 docs/02-架构与接口契约.md 的 TypeScript 定义一一对应，
/// 字段名保持一致以便直接 Codable 解码，不使用自定义 CodingKeys。

/// 弹幕显示模式：1 滚动 / 4 底部 / 5 顶部 / 6 逆向
public enum DanmakuMode: Int, Codable, Sendable {
    case scroll = 1
    case bottom = 4
    case top = 5
    case reverse = 6
}

/// 弹幕来源标识
public enum DanmakuSourceId: String, Codable, Sendable, CaseIterable {
    case dandanplay, bilibili, iqiyi, qq, youku, mgtv, bahamut, local, custom

    /// 面向用户展示的完整来源名称，避免暴露内部标识或使用不合规简称
    public var displayName: String {
        switch self {
        case .dandanplay: "弹弹play开放弹幕网络"
        case .bilibili: "哔哩哔哩"
        case .iqiyi: "爱奇艺"
        case .qq: "腾讯视频"
        case .youku: "优酷"
        case .mgtv: "芒果TV"
        case .bahamut: "巴哈姆特动画疯"
        case .local: "本地弹幕"
        case .custom: "自定义弹幕源"
        }
    }
}

/// 统一弹幕条目
public struct DanmakuItem: Codable, Sendable, Identifiable {
    public let id: String
    /// 相对视频起点的秒数
    public let time: Double
    public let mode: DanmakuMode
    /// 平台原始字号，25 为标准值
    public let fontSize: Double
    /// RGB 十进制，16777215 为白色
    public let color: Int
    public let content: String
    public let source: DanmakuSourceId
    public let senderHash: String?
    public let createdAt: Int?
    public let weight: Int?
    /// 去重后合并的条数，用于「×N」显示
    public let dupCount: Int?

    public init(
        id: String,
        time: Double,
        mode: DanmakuMode,
        fontSize: Double = 25,
        color: Int = 16_777_215,
        content: String,
        source: DanmakuSourceId,
        senderHash: String? = nil,
        createdAt: Int? = nil,
        weight: Int? = nil,
        dupCount: Int? = nil
    ) {
        self.id = id
        self.time = time
        self.mode = mode
        self.fontSize = fontSize
        self.color = color
        self.content = content
        self.source = source
        self.senderHash = senderHash
        self.createdAt = createdAt
        self.weight = weight
        self.dupCount = dupCount
    }
}

/// 文件识别指纹（弹弹play 规范）
public struct MediaFingerprint: Codable, Sendable {
    /// 不含扩展名的文件名
    public let fileName: String
    /// 文件前 16MB 的 MD5，小写十六进制
    public let fileHash: String
    public let fileSize: Int
    /// 视频时长（秒，取整）
    public let videoDuration: Int

    public init(fileName: String, fileHash: String, fileSize: Int, videoDuration: Int) {
        self.fileName = fileName
        self.fileHash = fileHash
        self.fileSize = fileSize
        self.videoDuration = videoDuration
    }
}

/// 跨平台剧集解析请求
public struct ResolveRequest: Codable, Sendable {
    public let title: String
    public let season: Int?
    public let episode: Int?
    public let duration: Double?
    public let year: Int?
    public let sources: [DanmakuSourceId]?
    public let fingerprint: MediaFingerprint?

    public init(
        title: String,
        season: Int? = nil,
        episode: Int? = nil,
        duration: Double? = nil,
        year: Int? = nil,
        sources: [DanmakuSourceId]? = nil,
        fingerprint: MediaFingerprint? = nil
    ) {
        self.title = title
        self.season = season
        self.episode = episode
        self.duration = duration
        self.year = year
        self.sources = sources
        self.fingerprint = fingerprint
    }
}

/// 平台侧候选剧集
public struct ProviderCandidate: Codable, Sendable, Identifiable {
    public let source: DanmakuSourceId
    /// custom 来源实际命中的实例 ID。
    public let sourceInstanceId: String?
    /// 实例面向用户的显示名称。
    public let sourceInstanceName: String?
    public let platformEpisodeId: String
    public let title: String
    public let episodeTitle: String?
    public let duration: Double?
    /// 0-1，综合标题相似度与时长差
    public let confidence: Double
    public let danmakuCount: Int?

    /// 由来源与平台 ID 组合出的稳定标识，供 SwiftUI 列表使用
    public var id: String { "\(source.rawValue):\(platformEpisodeId)" }

    /// 创建一个可供网关或客户端内置来源使用的候选剧集。
    /// - Parameters:
    ///   - source: 弹幕来源。
    ///   - sourceInstanceId: 自定义来源实例标识，内置来源传 nil。
    ///   - sourceInstanceName: 面向用户展示的实例名称。
    ///   - platformEpisodeId: 平台剧集标识。
    ///   - title: 作品标题。
    ///   - episodeTitle: 分集标题。
    ///   - duration: 平台视频时长，单位秒。
    ///   - confidence: 匹配置信度，范围 0 到 1。
    ///   - danmakuCount: 已知弹幕数量，未知时传 nil。
    public init(
        source: DanmakuSourceId,
        sourceInstanceId: String? = nil,
        sourceInstanceName: String? = nil,
        platformEpisodeId: String,
        title: String,
        episodeTitle: String? = nil,
        duration: Double? = nil,
        confidence: Double,
        danmakuCount: Int? = nil
    ) {
        self.source = source
        self.sourceInstanceId = sourceInstanceId
        self.sourceInstanceName = sourceInstanceName
        self.platformEpisodeId = platformEpisodeId
        self.title = title
        self.episodeTitle = episodeTitle
        self.duration = duration
        self.confidence = confidence
        self.danmakuCount = danmakuCount
    }
}

public struct ResolveResponse: Codable, Sendable {
    public let candidates: [ProviderCandidate]
    public let degraded: [DanmakuSourceId]
}

/// 弹幕聚合响应
public struct DanmakuResponse: Codable, Sendable {
    public struct Stats: Codable, Sendable {
        public let total: Int
        public let bySource: [String: Int]
        public let deduped: Int
        public let elapsedMs: Int
    }

    public struct Degraded: Codable, Sendable {
        public let source: DanmakuSourceId
        public let reason: String
        public let code: Int
    }

    public let items: [DanmakuItem]
    public let stats: Stats
    public let degraded: [Degraded]
}

/// 单个源的健康状态
public struct SourceStatus: Codable, Sendable, Identifiable {
    public let id: DanmakuSourceId
    public let available: Bool
    public let requiresCredential: Bool
    public let hasCredential: Bool
    public let lastCheckedAt: Double
    public let lastError: String?
    public let avgLatencyMs: Double?
}

/// 平台凭证校验结果，不包含任何原始凭证。
public struct CredentialVerification: Codable, Sendable {
    public let source: DanmakuSourceId
    public let valid: Bool
    public let displayName: String?
    public let message: String?
}

/// 一次弹幕请求中对单个来源的引用
public struct DanmakuRef: Sendable, Hashable {
    public let source: DanmakuSourceId
    public let platformEpisodeId: String
    /// 该来源独立的时间偏移，单位秒
    public var offset: Double

    public init(source: DanmakuSourceId, platformEpisodeId: String, offset: Double = 0) {
        self.source = source
        self.platformEpisodeId = platformEpisodeId
        self.offset = offset
    }
}
