/**
 * 业务编排层：跨源解析与弹幕聚合。
 * 路由层只做参数校验与格式转换，平台差异全部封装在适配器内。
 */

import { TtlCache } from './cache.js';
import type { AppConfig } from './config.js';
import { toGatewayError } from './errors.js';
import { createFetch } from './http.js';
import { createConsoleLogger, type Logger } from './logger.js';
import { applyTimeline, dedupe } from './normalize/danmaku.js';
import { durationPenalty } from './normalize/title.js';
import type { ProviderRegistry } from './providers/registry.js';
import type { ProviderContext } from './providers/types.js';
import type {
  CredentialPayload,
  DanmakuItem,
  DanmakuResponse,
  DanmakuSourceId,
  MediaFingerprint,
  ProviderCandidate,
  ResolveRequest,
  ResolveResponse,
} from './types.js';

/** 一次弹幕请求中对单个来源的引用 */
export interface DanmakuRef {
  source: DanmakuSourceId;
  platformEpisodeId: string;
  /** 该来源独立的时间偏移，单位秒（FR-SYNC-005） */
  offset: number;
  /** 时长比缩放（FR-SYNC-003） */
  scale: number;
}

export class DanmakuService {
  private readonly danmakuCache: TtlCache<DanmakuItem[]>;
  private readonly searchCache: TtlCache<ProviderCandidate[]>;
  private readonly logger: Logger;

  constructor(
    private readonly config: AppConfig,
    private readonly registry: ProviderRegistry,
  ) {
    this.danmakuCache = new TtlCache<DanmakuItem[]>(config.cache.maxEntries);
    this.searchCache = new TtlCache<ProviderCandidate[]>(config.cache.maxEntries);
    this.logger = createConsoleLogger('service');
  }

  /** 构建适配器上下文。凭证只在本次请求内传递，不做任何存储 */
  createContext(credential: CredentialPayload | undefined, signal: AbortSignal): ProviderContext {
    return {
      credential,
      fetch: createFetch(this.config.requestTimeoutMs, this.logger),
      logger: this.logger,
      signal,
    };
  }

  /** 判断某个源当前是否持有凭证，供 /kanata/v1/sources 输出 */
  hasCredential(credential: CredentialPayload | undefined, id: DanmakuSourceId): boolean {
    if (!credential) return false;
    return Object.prototype.hasOwnProperty.call(credential, id);
  }

  /**
   * 跨平台剧集解析（FR-MATCH-004）。
   * 有文件指纹时优先走精确匹配，否则按标题检索；
   * 单个源失败不影响其余源，失败的源记入 degraded（NFR-REL-001）。
   */
  async resolve(query: ResolveRequest, ctx: ProviderContext): Promise<ResolveResponse> {
    const providers = this.registry.available(query.sources);
    const degraded: DanmakuSourceId[] = [];
    const candidates: ProviderCandidate[] = [];

    await Promise.all(
      providers.map(async (provider) => {
        const startedAt = Date.now();
        try {
          const cacheKey = this.searchKey(provider.id, query);
          const cached = this.searchCache.get(cacheKey);
          if (cached) {
            candidates.push(...cached);
            return;
          }
          let found: ProviderCandidate[] = [];
          if (query.fingerprint && provider.match) {
            found = await provider.match(query.fingerprint, ctx);
          }
          if (found.length === 0) {
            found = await provider.search(query, ctx);
          }
          // 时长校验：差异超过 10% 的候选直接剔除（FR-MATCH-006）
          const scored = found
            .map((item) => ({
              ...item,
              confidence: Number(
                (item.confidence * durationPenalty(query.duration, item.duration)).toFixed(3),
              ),
            }))
            .filter((item) => item.confidence > 0);
          this.searchCache.set(cacheKey, scored, this.config.cache.searchTtlMs);
          candidates.push(...scored);
          this.registry.markSuccess(provider.id, Date.now() - startedAt);
        } catch (err) {
          const error = toGatewayError(err);
          this.registry.markFailure(provider.id, error.message);
          this.logger.warn('源解析失败，已降级', { source: provider.id, message: error.message });
          degraded.push(provider.id);
        }
      }),
    );

    candidates.sort((a, b) => b.confidence - a.confidence);
    return { candidates, degraded };
  }

  /**
   * 聚合多个来源的弹幕（FR-DMK-009）。
   * 每个来源独立应用偏移与缩放，合并后可选去重。
   */
  async aggregate(
    refs: DanmakuRef[],
    options: { dedup: boolean },
    ctx: ProviderContext,
  ): Promise<DanmakuResponse> {
    const startedAt = Date.now();
    const degraded: DanmakuResponse['degraded'] = [];
    const bySource: Partial<Record<DanmakuSourceId, number>> = {};
    let merged: DanmakuItem[] = [];

    await Promise.all(
      refs.map(async (ref) => {
        const providerStartedAt = Date.now();
        const provider = this.registry.get(ref.source);
        if (!provider) {
          degraded.push({ source: ref.source, reason: '未注册的来源', code: 40001 });
          return;
        }
        try {
          const items = await this.fetchWithCache(ref, ctx);
          bySource[ref.source] = items.length;
          merged = merged.concat(applyTimeline(items, ref.offset, ref.scale));
          this.registry.markSuccess(ref.source, Date.now() - providerStartedAt);
        } catch (err) {
          const error = toGatewayError(err);
          this.registry.markFailure(ref.source, error.message);
          this.logger.warn('源弹幕获取失败，已降级', {
            source: ref.source,
            message: error.message,
          });
          degraded.push({ source: ref.source, reason: error.message, code: error.code });
        }
      }),
    );

    let deduped = 0;
    if (options.dedup && refs.length > 1) {
      const result = dedupe(merged);
      merged = result.items;
      deduped = result.removed;
    } else {
      merged.sort((a, b) => a.time - b.time);
    }

    return {
      items: merged,
      stats: {
        total: merged.length,
        bySource,
        deduped,
        elapsedMs: Date.now() - startedAt,
      },
      degraded,
    };
  }

  /** 取单个来源的弹幕，命中缓存时直接返回（FR-DMK-012 / FR-GW-006） */
  private async fetchWithCache(ref: DanmakuRef, ctx: ProviderContext): Promise<DanmakuItem[]> {
    const key = `dm:${ref.source}:${ref.platformEpisodeId}`;
    const cached = this.danmakuCache.get(key);
    if (cached) return cached;
    const provider = this.registry.get(ref.source);
    if (!provider) return [];
    const items = await provider.fetch(ref.platformEpisodeId, ctx);
    this.danmakuCache.set(key, items, this.config.cache.danmakuTtlMs);
    return items;
  }

  /** 搜索缓存键。不包含任何凭证或用户标识（docs/02 §5） */
  private searchKey(source: DanmakuSourceId, query: ResolveRequest): string {
    const fingerprint = query.fingerprint ? `h:${query.fingerprint.fileHash}` : '';
    return `search:${source}:${query.title}:${query.season ?? ''}:${query.episode ?? ''}:${fingerprint}`;
  }

  /** 用文件指纹做精确匹配，返回全部支持 hash 匹配的源的候选 */
  async match(
    fingerprint: MediaFingerprint,
    ctx: ProviderContext,
  ): Promise<{ candidates: ProviderCandidate[]; degraded: DanmakuSourceId[] }> {
    const degraded: DanmakuSourceId[] = [];
    const candidates: ProviderCandidate[] = [];
    await Promise.all(
      this.registry.available().map(async (provider) => {
        if (!provider.match) return;
        try {
          candidates.push(...(await provider.match(fingerprint, ctx)));
        } catch (err) {
          const error = toGatewayError(err);
          this.registry.markFailure(provider.id, error.message);
          degraded.push(provider.id);
        }
      }),
    );
    candidates.sort((a, b) => b.confidence - a.confidence);
    return { candidates, degraded };
  }
}
