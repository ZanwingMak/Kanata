/**
 * 契约类型定义。
 * 唯一事实来源为 docs/02-架构与接口契约.md，本文件必须与之保持一致；
 * 任何字段变更都要先改文档再改这里。
 */

/** 弹幕显示模式：1 滚动 / 4 底部 / 5 顶部 / 6 逆向。7(高级) 与 8(代码) 在解析阶段丢弃 */
export type DanmakuMode = 1 | 4 | 5 | 6;

/** 弹幕来源标识 */
export type DanmakuSourceId =
  | 'dandanplay'
  | 'bilibili'
  | 'iqiyi'
  | 'qq'
  | 'youku'
  | 'mgtv'
  | 'bahamut'
  | 'local'
  | 'custom';

/** 统一弹幕条目：所有平台数据归一化后的唯一形态 */
export interface DanmakuItem {
  /** 稳定唯一 ID，格式 `${source}:${平台内 ID}` */
  id: string;
  /** 相对视频起点的秒数，已应用平台侧修正 */
  time: number;
  mode: DanmakuMode;
  /** 平台原始字号，25 为标准值，渲染端做归一化 */
  fontSize: number;
  /** RGB 十进制，16777215 为白色 */
  color: number;
  content: string;
  source: DanmakuSourceId;
  /** 发送者 hash，用于「屏蔽此用户」 */
  senderHash?: string;
  /** 发送时间的 Unix 秒 */
  createdAt?: number;
  /** 0 普通 / 1 字幕池 / 2 特殊 */
  pool?: 0 | 1 | 2;
  /** 0-10，密度限流时的保留优先级 */
  weight?: number;
  /** 去重后合并的条数，用于「×N」显示 */
  dupCount?: number;
}

/** 文件识别指纹（弹弹play 规范） */
export interface MediaFingerprint {
  /** 不含扩展名的文件名 */
  fileName: string;
  /** 文件前 16MB 的 MD5，小写十六进制 */
  fileHash: string;
  fileSize: number;
  /** 视频时长（秒，取整） */
  videoDuration: number;
}

/** 跨平台剧集解析请求 */
export interface ResolveRequest {
  title: string;
  season?: number;
  episode?: number;
  /** 本地文件时长（秒），用于候选的时长校验 */
  duration?: number;
  year?: number;
  /** 为空表示使用全部已启用的源 */
  sources?: DanmakuSourceId[];
  fingerprint?: MediaFingerprint;
}

/** 平台侧候选剧集 */
export interface ProviderCandidate {
  source: DanmakuSourceId;
  /** custom 来源实际命中的实例 ID */
  sourceInstanceId?: string;
  /** 实例面向用户的显示名称 */
  sourceInstanceName?: string;
  /** 平台内剧集标识（episodeId / cid / tvid / vid …） */
  platformEpisodeId: string;
  title: string;
  episodeTitle?: string;
  /** 平台侧时长（秒） */
  duration?: number;
  /** 0-1，综合标题相似度与时长差 */
  confidence: number;
  danmakuCount?: number;
}

export interface ResolveResponse {
  candidates: ProviderCandidate[];
  /** 本次不可用的源 */
  degraded: DanmakuSourceId[];
}

/** 统一模型弹幕响应 */
export interface DanmakuResponse {
  items: DanmakuItem[];
  stats: {
    total: number;
    bySource: Partial<Record<DanmakuSourceId, number>>;
    deduped: number;
    elapsedMs: number;
  };
  degraded: Array<{ source: DanmakuSourceId; reason: string; code: number }>;
}

/** 单个源的健康状态 */
export interface SourceStatus {
  id: DanmakuSourceId;
  available: boolean;
  requiresCredential: boolean;
  hasCredential: boolean;
  lastCheckedAt: number;
  lastError?: string;
  avgLatencyMs?: number;
}

/** 平台凭证载荷，仅在单次请求的内存生命周期内存在 */
export interface CredentialPayload {
  bilibili?: {
    SESSDATA: string;
    bili_jct?: string;
    DedeUserID?: string;
    buvid3?: string;
  };
}

/** 平台凭证校验结果，不返回任何原始凭证内容。 */
export interface CredentialVerification {
  source: DanmakuSourceId;
  valid: boolean;
  displayName?: string;
  message?: string;
}

/* ---------- 弹弹play v2 兼容格式 ---------- */

/** 弹弹play 弹幕条目：p 为 "时间(秒),模式,颜色,用户ID" */
export interface DandanComment {
  cid: number;
  p: string;
  m: string;
}

export interface DandanCommentResponse {
  count: number;
  comments: DandanComment[];
}

export interface DandanMatchRequest {
  fileName: string;
  fileHash: string;
  fileSize: number;
  videoDuration: number;
  matchMode?: 'hashAndFileName' | 'fileNameOnly' | 'hashOnly';
}

export interface DandanMatchItem {
  episodeId: number;
  animeId: number;
  animeTitle: string;
  episodeTitle: string;
  type: string;
  /** 官方给出的时轴修正（秒），必须应用到 DanmakuItem.time */
  shift: number;
}

export interface DandanMatchResponse {
  isMatched: boolean;
  matches: DandanMatchItem[];
  errorCode: number;
  success: boolean;
  errorMessage: string;
}
