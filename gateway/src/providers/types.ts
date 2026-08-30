/**
 * 平台适配器统一接口（docs/02 §4.1）。
 * 新增平台只需实现本接口并在 registry 注册，
 * 不得在路由层或业务层出现任何平台专有分支（CLAUDE.md 第 9 条）。
 */

import type { FetchLike } from '../http.js';
import type { Logger } from '../logger.js';
import type {
  CredentialPayload,
  DanmakuItem,
  DanmakuSourceId,
  MediaFingerprint,
  ProviderCandidate,
  ResolveRequest,
} from '../types.js';

/** 适配器运行上下文，由网关按请求构建并注入 */
export interface ProviderContext {
  /** 客户端透传的凭证，仅在当次请求内存活，禁止落盘与写日志 */
  credential?: CredentialPayload;
  /** 已注入超时、重试与 UA 的出网函数 */
  fetch: FetchLike;
  /** 已脱敏的日志器 */
  logger: Logger;
  /** 请求取消信号 */
  signal: AbortSignal;
}

/** 探活结果（docs/05 §7） */
export interface HealthResult {
  ok: boolean;
  latencyMs: number;
  /** 探活拉到的弹幕条数，用于阈值断言 */
  count?: number;
  error?: string;
}

export interface DanmakuProvider {
  readonly id: DanmakuSourceId;
  readonly requiresCredential: boolean;

  /** 按标题、季、集检索平台侧候选剧集 */
  search(query: ResolveRequest, ctx: ProviderContext): Promise<ProviderCandidate[]>;

  /** 拉取指定剧集的全量弹幕，内部负责分片、解压与解码 */
  fetch(platformEpisodeId: string, ctx: ProviderContext): Promise<DanmakuItem[]>;

  /** 用文件指纹做精确匹配。仅支持 hash 匹配的平台实现此方法 */
  match?(fingerprint: MediaFingerprint, ctx: ProviderContext): Promise<ProviderCandidate[]>;

  /** 从播放页 URL 解析出平台剧集 ID，供「粘贴链接」入口使用 */
  parseUrl?(url: string): string | null;

  /** 探活：CI 每日调用，验证接口结构未变 */
  healthCheck(ctx: ProviderContext): Promise<HealthResult>;
}
