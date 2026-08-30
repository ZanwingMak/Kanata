/**
 * 弹弹play 开放平台适配器（docs/03 §1）。
 * 官方文档 https://doc.dandanplay.com/open/
 *
 * 使用约束：禁止商业使用、批量抓取与规模下载；返回数据须缓存 2-24 小时。
 * 未配置 AppId/AppSecret 时以匿名方式请求，部分接口可能受限。
 */

import { createHash } from 'node:crypto';
import { ErrorCode, GatewayError } from '../errors.js';
import { fromDandanComment } from '../normalize/danmaku.js';
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

interface DandanEpisode {
  episodeId: number;
  episodeTitle: string;
}

interface DandanAnime {
  animeId: number;
  animeTitle: string;
  type?: string;
  episodes?: DandanEpisode[];
}

interface DandanSearchResponse {
  animes?: DandanAnime[];
  success?: boolean;
  errorCode?: number;
  errorMessage?: string;
}

export interface DandanplayOptions {
  baseUrl: string;
  appId: string;
  appSecret: string;
}

export class DandanplayProvider implements DanmakuProvider {
  readonly id = 'dandanplay' as const;
  readonly requiresCredential = false;

  constructor(private readonly options: DandanplayOptions) {}

  /**
   * 构造签名认证头（签名验证模式）。
   * 签名算法 base64(sha256(AppId + Timestamp + Path + AppSecret))，
   * Path 不含域名与 query，例如 /api/v2/comment/123450001。
   * 未配置密钥时返回空头，以匿名方式请求。
   */
  private authHeaders(path: string): Record<string, string> {
    const { appId, appSecret } = this.options;
    if (!appId || !appSecret) return {};
    const timestamp = Math.floor(Date.now() / 1000).toString();
    const signature = createHash('sha256')
      .update(appId + timestamp + path + appSecret)
      .digest('base64');
    return {
      'X-AppId': appId,
      'X-Timestamp': timestamp,
      'X-Signature': signature,
    };
  }

  /**
   * 发起一次开放平台请求并解析 JSON。
   * @param path 不含 query 的接口路径，用于签名
   * @param query 查询参数
   * @param init 请求方法与请求体
   */
  private async request<T>(
    path: string,
    query: Record<string, string | undefined>,
    ctx: ProviderContext,
    init?: { method: 'POST'; body: unknown },
  ): Promise<T> {
    const url = new URL(this.options.baseUrl + path);
    for (const [key, value] of Object.entries(query)) {
      if (value !== undefined && value !== '') url.searchParams.set(key, value);
    }
    const headers: Record<string, string> = {
      Accept: 'application/json',
      ...this.authHeaders(path),
    };
    if (init) headers['Content-Type'] = 'application/json';

    const response = await ctx.fetch(url.toString(), {
      method: init?.method ?? 'GET',
      headers,
      body: init ? JSON.stringify(init.body) : undefined,
    });

    if (response.status === 401 || response.status === 403) {
      throw new GatewayError(
        ErrorCode.CREDENTIAL_REQUIRED,
        '弹弹play 开放平台拒绝访问，请检查 AppId/AppSecret 配置',
        `${path} ${response.status}`,
      );
    }
    if (!response.ok) {
      throw new GatewayError(
        ErrorCode.PROVIDER_ERROR,
        `弹弹play 返回 ${response.status}`,
        path,
      );
    }
    const text = await response.text();
    try {
      return JSON.parse(text) as T;
    } catch {
      // 结构断言失败：记录响应前 512 字节供排查（docs/03 §9 规范 4）
      throw new GatewayError(
        ErrorCode.SCHEMA_CHANGED,
        '弹弹play 响应不是合法 JSON',
        text.slice(0, 512),
      );
    }
  }

  /** 按标题与集数检索候选剧集 */
  async search(query: ResolveRequest, ctx: ProviderContext): Promise<ProviderCandidate[]> {
    const data = await this.request<DandanSearchResponse>(
      '/api/v2/search/episodes',
      {
        anime: query.title,
        episode: query.episode !== undefined ? String(query.episode) : undefined,
      },
      ctx,
    );
    if (!Array.isArray(data.animes)) {
      throw new GatewayError(
        ErrorCode.SCHEMA_CHANGED,
        '弹弹play 搜索响应缺少 animes 字段',
        JSON.stringify(data).slice(0, 512),
      );
    }

    const candidates: ProviderCandidate[] = [];
    for (const anime of data.animes) {
      const similarity = titleSimilarity(query.title, anime.animeTitle ?? '');
      for (const episode of anime.episodes ?? []) {
        candidates.push({
          source: this.id,
          platformEpisodeId: String(episode.episodeId),
          title: anime.animeTitle,
          episodeTitle: episode.episodeTitle,
          confidence: Number(similarity.toFixed(3)),
        });
      }
    }
    return candidates.sort((a, b) => b.confidence - a.confidence);
  }

  /** 用文件指纹做精确匹配，命中时返回置信度为 1 的候选 */
  async match(
    fingerprint: MediaFingerprint,
    ctx: ProviderContext,
  ): Promise<ProviderCandidate[]> {
    const data = await this.request<DandanMatchResponse>(
      '/api/v2/match',
      {},
      ctx,
      {
        method: 'POST',
        body: {
          fileName: fingerprint.fileName,
          fileHash: fingerprint.fileHash,
          fileSize: fingerprint.fileSize,
          videoDuration: Math.round(fingerprint.videoDuration),
          matchMode: 'hashAndFileName',
        },
      },
    );
    if (!Array.isArray(data.matches)) {
      throw new GatewayError(
        ErrorCode.SCHEMA_CHANGED,
        '弹弹play 匹配响应缺少 matches 字段',
        JSON.stringify(data).slice(0, 512),
      );
    }
    return data.matches.map((item) => ({
      source: this.id,
      platformEpisodeId: String(item.episodeId),
      title: item.animeTitle,
      episodeTitle: item.episodeTitle,
      confidence: data.isMatched ? 1 : 0.6,
    }));
  }

  /**
   * 拉取指定剧集的全量弹幕。
   * withRelated=true 会带回其他站点的关联弹幕，是多源聚合的最低成本入口。
   */
  async fetch(platformEpisodeId: string, ctx: ProviderContext): Promise<DanmakuItem[]> {
    const data = await this.request<DandanCommentResponse>(
      `/api/v2/comment/${encodeURIComponent(platformEpisodeId)}`,
      { withRelated: 'true', chConvert: '0' },
      ctx,
    );
    if (!Array.isArray(data.comments)) {
      throw new GatewayError(
        ErrorCode.SCHEMA_CHANGED,
        '弹弹play 弹幕响应缺少 comments 字段',
        JSON.stringify(data).slice(0, 512),
      );
    }
    const items: DanmakuItem[] = [];
    for (const comment of data.comments) {
      const item = fromDandanComment(comment);
      // 高级弹幕与格式异常条目在此静默丢弃（FR-DMK-109）
      if (item) items.push(item);
    }
    ctx.logger.debug('弹弹play 弹幕解析完成', {
      episodeId: platformEpisodeId,
      raw: data.comments.length,
      parsed: items.length,
    });
    return items.sort((a, b) => a.time - b.time);
  }

  /**
   * 探活（docs/05 §7）：先搜索一部常见番剧拿到 episodeId，再拉一次弹幕。
   * 两步串联可同时验证搜索与弹幕两个接口的结构未变。
   */
  async healthCheck(ctx: ProviderContext): Promise<HealthResult> {
    const startedAt = Date.now();
    try {
      const candidates = await this.search({ title: '进击的巨人', episode: 1 }, ctx);
      if (candidates.length === 0) {
        return { ok: false, latencyMs: Date.now() - startedAt, error: '搜索返回空结果' };
      }
      const items = await this.fetch((candidates[0] as ProviderCandidate).platformEpisodeId, ctx);
      return {
        ok: items.length > 100,
        latencyMs: Date.now() - startedAt,
        count: items.length,
        error: items.length > 100 ? undefined : '弹幕条数低于阈值 100',
      };
    } catch (err) {
      return {
        ok: false,
        latencyMs: Date.now() - startedAt,
        error: err instanceof Error ? err.message : String(err),
      };
    }
  }
}
