/**
 * 多实例弹弹play兼容 API 池（FR-DMK-007）。
 * 实例 Token 只用于请求头，不进入候选缓存键、日志或响应。
 */

import type { CustomProviderInstanceConfig } from '../config.js';
import { ErrorCode, GatewayError, toGatewayError } from '../errors.js';
import { mapWithLimit } from '../http.js';
import { dedupe, fromDandanComment } from '../normalize/danmaku.js';
import { titleSimilarity } from '../normalize/title.js';
import type {
  DandanCommentResponse,
  DandanMatchResponse,
  DanmakuItem,
  MediaFingerprint,
  ProviderCandidate,
  ResolveRequest,
} from '../types.js';
import type { DanmakuProvider, HealthResult, ProviderContext } from './types.js';

interface CompatibleEpisode {
  episodeId: number | string;
  episodeTitle?: string;
}

interface CompatibleAnime {
  animeTitle?: string;
  episodes?: CompatibleEpisode[];
}

interface CompatibleSearchResponse {
  animes?: CompatibleAnime[];
}

interface AggregateReference {
  instanceId: string;
  episodeId: string;
}

interface CustomProviderOptions {
  strategy: 'fallback' | 'race' | 'aggregate';
  instances: CustomProviderInstanceConfig[];
}

export class CustomProvider implements DanmakuProvider {
  readonly id = 'custom' as const;
  readonly requiresCredential = false;
  private readonly instances: CustomProviderInstanceConfig[];

  constructor(private readonly options: CustomProviderOptions) {
    this.instances = options.instances.filter((instance) => instance.enabled);
  }

  /** 按配置策略查询各兼容实例，并标记实际命中的实例。 */
  async search(query: ResolveRequest, ctx: ProviderContext): Promise<ProviderCandidate[]> {
    return this.resolveCandidates(
      (instance) => this.searchInstance(instance, query, ctx),
      ctx,
    );
  }

  /** 按配置策略执行文件指纹匹配。 */
  async match(
    fingerprint: MediaFingerprint,
    ctx: ProviderContext,
  ): Promise<ProviderCandidate[]> {
    return this.resolveCandidates(
      (instance) => this.matchInstance(instance, fingerprint, ctx),
      ctx,
    );
  }

  /** 按候选中编码的实例读取弹幕；聚合候选会并发读取并去重。 */
  async fetch(platformEpisodeId: string, ctx: ProviderContext): Promise<DanmakuItem[]> {
    const decoded = this.decodeEpisodeId(platformEpisodeId);
    if (decoded.instanceId === 'aggregate') {
      const references = this.decodeAggregateReferences(decoded.episodeId);
      const results = await mapWithLimit(references, 3, async (reference) => {
        const instance = this.instances.find((item) => item.id === reference.instanceId);
        if (!instance) return [];
        try {
          return await this.fetchInstance(instance, reference.episodeId, ctx);
        } catch (error) {
          ctx.logger.warn('自定义来源聚合实例失败，已跳过', {
            instanceId: instance.id,
            message: toGatewayError(error).message,
          });
          return [];
        }
      });
      const merged = results.flat();
      return dedupe(merged).items;
    }

    const preferred = decoded.instanceId
      ? this.instances.find((instance) => instance.id === decoded.instanceId)
      : undefined;
    const ordered = preferred
      ? [preferred, ...this.instances.filter((instance) => instance.id !== preferred.id)]
      : this.instances;
    let lastError: GatewayError | undefined;
    for (const instance of ordered) {
      try {
        const items = await this.fetchInstance(instance, decoded.episodeId, ctx);
        if (items.length > 0) return items;
      } catch (error) {
        lastError = toGatewayError(error);
        ctx.logger.warn('自定义来源实例取弹幕失败，尝试下一实例', {
          instanceId: instance.id,
          message: lastError.message,
        });
      }
    }
    if (lastError) throw lastError;
    return [];
  }

  /** 用第一个可用实例的搜索接口执行轻量探活。 */
  async healthCheck(ctx: ProviderContext): Promise<HealthResult> {
    const startedAt = Date.now();
    if (this.instances.length === 0) {
      return { ok: false, latencyMs: 0, error: '未配置自定义兼容 API 实例' };
    }
    try {
      const candidates = await this.search({ title: '进击的巨人', episode: 1 }, ctx);
      return {
        ok: candidates.length > 0,
        latencyMs: Date.now() - startedAt,
        count: candidates.length,
        error: candidates.length > 0 ? undefined : '搜索返回空结果',
      };
    } catch (error) {
      return {
        ok: false,
        latencyMs: Date.now() - startedAt,
        error: toGatewayError(error).message,
      };
    }
  }

  /** 按顺序回退、有限竞速或聚合策略编排候选查询。 */
  private async resolveCandidates(
    operation: (
      instance: CustomProviderInstanceConfig,
    ) => Promise<ProviderCandidate[]>,
    ctx: ProviderContext,
  ): Promise<ProviderCandidate[]> {
    if (this.instances.length === 0) return [];
    if (this.options.strategy === 'fallback') {
      return this.fallbackCandidates(operation, ctx);
    }
    if (this.options.strategy === 'race') {
      return this.raceCandidates(operation, ctx);
    }
    const results = await mapWithLimit(this.instances, 3, async (instance) => {
      try {
        return await operation(instance);
      } catch (error) {
        ctx.logger.warn('自定义来源聚合实例搜索失败，已跳过', {
          instanceId: instance.id,
          message: toGatewayError(error).message,
        });
        return [];
      }
    });
    return this.mergeAggregateCandidates(results.flat());
  }

  /** 顺序访问实例，首个非空结果胜出。 */
  private async fallbackCandidates(
    operation: (
      instance: CustomProviderInstanceConfig,
    ) => Promise<ProviderCandidate[]>,
    ctx: ProviderContext,
  ): Promise<ProviderCandidate[]> {
    let lastError: GatewayError | undefined;
    let hadSuccessfulResponse = false;
    for (const instance of this.instances) {
      try {
        const candidates = await operation(instance);
        hadSuccessfulResponse = true;
        if (candidates.length > 0) return candidates;
      } catch (error) {
        lastError = toGatewayError(error);
        ctx.logger.warn('自定义来源实例搜索失败，尝试下一实例', {
          instanceId: instance.id,
          message: lastError.message,
        });
      }
    }
    if (!hadSuccessfulResponse && lastError) throw lastError;
    return [];
  }

  /** 每批最多并发三个实例，返回最先完成的非空结果。 */
  private async raceCandidates(
    operation: (
      instance: CustomProviderInstanceConfig,
    ) => Promise<ProviderCandidate[]>,
    ctx: ProviderContext,
  ): Promise<ProviderCandidate[]> {
    let lastError: GatewayError | undefined;
    let hadSuccessfulResponse = false;
    for (let index = 0; index < this.instances.length; index += 3) {
      const batch = this.instances.slice(index, index + 3);
      try {
        return await Promise.any(batch.map(async (instance) => {
          try {
            const candidates = await operation(instance);
            hadSuccessfulResponse = true;
            if (candidates.length === 0) throw new Error('EMPTY_RESULT');
            return candidates;
          } catch (error) {
            if (!(error instanceof Error && error.message === 'EMPTY_RESULT')) {
              lastError = toGatewayError(error);
              ctx.logger.warn('自定义来源竞速实例失败', {
                instanceId: instance.id,
                message: lastError.message,
              });
            }
            throw error;
          }
        }));
      } catch {
        // 当前批次没有非空结果，继续下一批。
      }
    }
    if (!hadSuccessfulResponse && lastError) throw lastError;
    return [];
  }

  /** 查询单个兼容实例的分集候选。 */
  private async searchInstance(
    instance: CustomProviderInstanceConfig,
    query: ResolveRequest,
    ctx: ProviderContext,
  ): Promise<ProviderCandidate[]> {
    const data = await this.request<CompatibleSearchResponse>(
      instance,
      '/api/v2/search/episodes',
      {
        anime: query.title,
        episode: query.episode === undefined ? undefined : String(query.episode),
      },
      ctx,
    );
    if (!Array.isArray(data.animes)) {
      throw new GatewayError(ErrorCode.SCHEMA_CHANGED, '兼容 API 搜索响应缺少 animes');
    }
    const candidates: ProviderCandidate[] = [];
    for (const anime of data.animes) {
      const title = anime.animeTitle ?? '';
      const confidence = Number(titleSimilarity(query.title, title).toFixed(3));
      for (const episode of anime.episodes ?? []) {
        candidates.push(this.tagCandidate(instance, {
          source: this.id,
          platformEpisodeId: String(episode.episodeId),
          title,
          episodeTitle: episode.episodeTitle,
          confidence,
        }));
      }
    }
    return candidates.sort((left, right) => right.confidence - left.confidence);
  }

  /** 调用单个兼容实例的文件指纹匹配接口。 */
  private async matchInstance(
    instance: CustomProviderInstanceConfig,
    fingerprint: MediaFingerprint,
    ctx: ProviderContext,
  ): Promise<ProviderCandidate[]> {
    const data = await this.request<DandanMatchResponse>(
      instance,
      '/api/v2/match',
      {},
      ctx,
      {
        method: 'POST',
        body: {
          fileName: fingerprint.fileName,
          fileHash: fingerprint.fileHash,
          fileSize: fingerprint.fileSize,
          videoDuration: fingerprint.videoDuration,
          matchMode: 'hashAndFileName',
        },
      },
    );
    if (!Array.isArray(data.matches)) {
      throw new GatewayError(ErrorCode.SCHEMA_CHANGED, '兼容 API 匹配响应缺少 matches');
    }
    return data.matches.map((match) => this.tagCandidate(instance, {
      source: this.id,
      platformEpisodeId: String(match.episodeId),
      title: match.animeTitle,
      episodeTitle: match.episodeTitle,
      confidence: data.isMatched ? 1 : 0.6,
    }));
  }

  /** 从单个兼容实例读取并归一化弹幕。 */
  private async fetchInstance(
    instance: CustomProviderInstanceConfig,
    episodeId: string,
    ctx: ProviderContext,
  ): Promise<DanmakuItem[]> {
    const data = await this.request<DandanCommentResponse>(
      instance,
      `/api/v2/comment/${encodeURIComponent(episodeId)}`,
      { withRelated: 'true', chConvert: '0' },
      ctx,
    );
    if (!Array.isArray(data.comments)) {
      throw new GatewayError(ErrorCode.SCHEMA_CHANGED, '兼容 API 弹幕响应缺少 comments');
    }
    return data.comments.flatMap((comment) => {
      const item = fromDandanComment(comment);
      if (!item) return [];
      return [{
        ...item,
        id: `custom:${instance.id}:${comment.cid}`,
        source: this.id,
      }];
    });
  }

  /** 给候选写入实例元数据，并把实例 ID 编入平台剧集标识。 */
  private tagCandidate(
    instance: CustomProviderInstanceConfig,
    candidate: ProviderCandidate,
  ): ProviderCandidate {
    return {
      ...candidate,
      source: this.id,
      sourceInstanceId: instance.id,
      sourceInstanceName: instance.name,
      platformEpisodeId: `${instance.id}~${encodeURIComponent(candidate.platformEpisodeId)}`,
    };
  }

  /** 把多个实例指向同一标题和分集的候选合并为一个聚合候选。 */
  private mergeAggregateCandidates(candidates: ProviderCandidate[]): ProviderCandidate[] {
    const groups = new Map<string, ProviderCandidate[]>();
    for (const candidate of candidates) {
      const key = `${candidate.title.trim().toLowerCase()}|${candidate.episodeTitle?.trim().toLowerCase() ?? ''}`;
      groups.set(key, [...(groups.get(key) ?? []), candidate]);
    }
    return [...groups.values()].map((group) => {
      const first = group[0] as ProviderCandidate;
      if (group.length === 1) return first;
      const references: AggregateReference[] = group.flatMap((candidate) => {
        const decoded = this.decodeEpisodeId(candidate.platformEpisodeId);
        return decoded.instanceId
          ? [{ instanceId: decoded.instanceId, episodeId: decoded.episodeId }]
          : [];
      });
      return {
        ...first,
        sourceInstanceId: 'aggregate',
        sourceInstanceName: group.map((item) => item.sourceInstanceName).filter(Boolean).join(' + '),
        platformEpisodeId: `aggregate~${encodeURIComponent(JSON.stringify(references))}`,
        confidence: Math.max(...group.map((item) => item.confidence)),
        danmakuCount: group.reduce((sum, item) => sum + (item.danmakuCount ?? 0), 0) || undefined,
      };
    }).sort((left, right) => right.confidence - left.confidence);
  }

  /** 解码实例前缀和原始平台剧集标识。 */
  private decodeEpisodeId(value: string): { instanceId?: string; episodeId: string } {
    const separator = value.indexOf('~');
    if (separator <= 0) return { episodeId: value };
    const instanceId = value.slice(0, separator);
    const encodedEpisodeId = value.slice(separator + 1);
    try {
      return { instanceId, episodeId: decodeURIComponent(encodedEpisodeId) };
    } catch {
      return { instanceId, episodeId: encodedEpisodeId };
    }
  }

  /** 解码聚合候选内的实例引用列表。 */
  private decodeAggregateReferences(value: string): AggregateReference[] {
    try {
      const parsed = JSON.parse(value) as unknown;
      if (!Array.isArray(parsed)) return [];
      return parsed.filter((item): item is AggregateReference => Boolean(
        item
        && typeof item === 'object'
        && typeof (item as AggregateReference).instanceId === 'string'
        && typeof (item as AggregateReference).episodeId === 'string',
      ));
    } catch {
      return [];
    }
  }

  /** 请求一个兼容实例并执行状态码与 JSON 结构的基础校验。 */
  private async request<T>(
    instance: CustomProviderInstanceConfig,
    apiPath: string,
    query: Record<string, string | undefined>,
    ctx: ProviderContext,
    init?: { method: 'POST'; body: unknown },
  ): Promise<T> {
    const url = new URL(`${instance.baseUrl}${apiPath}`);
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined && value !== '') url.searchParams.set(key, value);
    }
    const headers: Record<string, string> = { Accept: 'application/json' };
    if (instance.token) headers.Authorization = `Bearer ${instance.token}`;
    if (init) headers['Content-Type'] = 'application/json';
    const response = await ctx.fetch(url.toString(), {
      method: init?.method ?? 'GET',
      headers,
      body: init ? JSON.stringify(init.body) : undefined,
    });
    if (response.status === 401 || response.status === 403) {
      throw new GatewayError(ErrorCode.CREDENTIAL_REQUIRED, `自定义来源 ${instance.name} 鉴权失败`);
    }
    if (!response.ok) {
      throw new GatewayError(ErrorCode.PROVIDER_ERROR, `自定义来源 ${instance.name} 返回 ${response.status}`);
    }
    const text = await response.text();
    try {
      return JSON.parse(text) as T;
    } catch {
      throw new GatewayError(
        ErrorCode.SCHEMA_CHANGED,
        `自定义来源 ${instance.name} 响应不是合法 JSON`,
        text.slice(0, 512),
      );
    }
  }
}
