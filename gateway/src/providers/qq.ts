/**
 * 腾讯视频弹幕适配器。
 * 搜索与分集来自腾讯视频网页接口，弹幕按 base 返回的 30 秒索引并发拉取。
 */

import { ErrorCode, GatewayError } from '../errors.js';
import { mapWithLimit } from '../http.js';
import { titleSimilarity } from '../normalize/title.js';
import type { DanmakuItem, DanmakuMode, ProviderCandidate, ResolveRequest } from '../types.js';
import type { DanmakuProvider, HealthResult, ProviderContext } from './types.js';

const SEARCH_URL =
  'https://pbaccess.video.qq.com/trpc.videosearch.mobile_search.HttpMobileRecall/MbSearchHttp';
const EPISODE_URL =
  'https://pbaccess.video.qq.com/trpc.videosearch.search_cgi.http/load_playsource_list_info';
const SEGMENT_CONCURRENCY = 5;
const COMMON_HEADERS = {
  Referer: 'https://v.qq.com/',
  Origin: 'https://v.qq.com',
  'Content-Type': 'application/json',
};
const HEALTH_CHECK_VID = 'q4100dpkd26';

interface QQEpisode {
  id?: string;
  title?: string;
  titleSuffix?: string;
  duration?: string;
  url?: string;
}

interface QQSite {
  enName?: string;
  totalEpisode?: number;
  episodeInfoList?: QQEpisode[];
}

interface QQVideoInfo {
  title?: string;
  year?: number;
  episodeSites?: QQSite[];
  firstBlockSites?: QQSite[];
}

interface QQSearchItem {
  doc?: {
    id?: string;
    dataType?: number;
  };
  videoInfo?: QQVideoInfo;
}

interface QQBarrage {
  id?: string;
  time_offset?: string;
  content?: string;
  content_style?: string;
  vuid?: string;
  create_time?: string;
  content_score?: number;
}

/** 生成腾讯视频搜索请求体。 */
function searchBody(keyword: string): string {
  return JSON.stringify({
    version: '8.2.96',
    clientType: 1,
    filterValue: '',
    uuid: 'kanata-search',
    retry: 0,
    query: keyword,
    pagenum: 0,
    pagesize: 12,
    queryFrom: 0,
    isneedQc: true,
    preQid: '',
    adClientInfo: '',
    extraInfo: { isNewMarkLabel: '1', multi_terminal_pc: '1', themeType: '0' },
    featureList: ['DEFAULT_FEFEATURE', 'PC_WANT_EPISODE_V2', 'PC_WANT_EPISODE'],
  });
}

/** 生成腾讯视频分集翻页请求体。 */
function episodeBody(coverId: string, scene: number, pageNum: number): string {
  return JSON.stringify({
    pageNum,
    platform: 2,
    site: 'qq',
    appId: '10718',
    dataType: 2,
    id: coverId,
    scene,
    pageContext: '',
    features: [],
    themeType: '0',
  });
}

/** 把腾讯视频弹幕样式映射到统一模式和颜色。 */
function parseStyle(value?: string): { mode: DanmakuMode; color: number } {
  if (!value) return { mode: 1, color: 16777215 };
  try {
    const style = JSON.parse(value) as { position?: number; color?: string };
    const parsed = Number.parseInt((style.color ?? '').replace(/^#/, ''), 16);
    const mode: DanmakuMode = style.position === 2 ? 5 : style.position === 3 ? 4 : 1;
    return { mode, color: Number.isFinite(parsed) ? parsed : 16777215 };
  } catch {
    return { mode: 1, color: 16777215 };
  }
}

/** 把分集标题转换为数值集号，不可识别时返回回退序号。 */
function episodeNumber(episode: QQEpisode, fallback: number): number {
  const number = Number.parseInt(episode.title ?? '', 10);
  return Number.isFinite(number) ? number : fallback;
}

/** 生成始终带集号的候选标题。 */
function episodeLabel(number: number, suffix?: string): string {
  const value = suffix?.trim();
  return value ? `第 ${number} 集 · ${value}` : `第 ${number} 集`;
}

export class QQProvider implements DanmakuProvider {
  readonly id = 'qq' as const;
  readonly requiresCredential = false;

  /** 从腾讯视频播放页或纯 vid 中解析剧集标识。 */
  parseUrl(url: string): string | null {
    const direct = url.trim().match(/^[a-z]\d+[a-z0-9]+$/i);
    if (direct) return direct[0];
    const match = url.match(/\/x\/(?:cover|page)\/(?:[^/]+\/)?([a-z]\d+[a-z0-9]+)(?:\.html)?/i);
    return match ? match[1] ?? null : null;
  }

  /** 搜索作品并将最相似的两部结果展开为逐集候选。 */
  async search(query: ResolveRequest, ctx: ProviderContext): Promise<ProviderCandidate[]> {
    const direct = this.parseUrl(query.title);
    if (direct) {
      return [{
        source: this.id,
        platformEpisodeId: direct,
        title: '腾讯视频',
        episodeTitle: query.episode ? `第 ${query.episode} 集` : '指定视频',
        confidence: 1,
      }];
    }

    const response = await ctx.fetch(SEARCH_URL, {
      method: 'POST',
      headers: COMMON_HEADERS,
      body: searchBody(query.title),
    });
    const data = (await response.json()) as {
      data?: {
        errcode?: number;
        normalList?: { itemList?: QQSearchItem[] };
      };
    };
    if (data.data?.errcode !== 0) {
      throw new GatewayError(ErrorCode.PROVIDER_ERROR, '腾讯视频搜索失败');
    }

    const ranked = (data.data.normalList?.itemList ?? [])
      .map((item) => ({ coverId: item.doc?.id, video: item.videoInfo }))
      .filter(
        (item): item is { coverId: string; video: QQVideoInfo } =>
          Boolean(item.coverId && item.video?.title),
      )
      .map((item) => ({
        ...item,
        score: titleSimilarity(query.title, item.video.title ?? ''),
      }))
      .sort((a, b) => b.score - a.score)
      .slice(0, 2);

    const candidates: ProviderCandidate[] = [];
    for (const item of ranked) {
      const site = item.video.episodeSites?.find((entry) => entry.enName === 'qq');
      const episodes = await this.fetchEpisodes(
        item.coverId,
        site?.totalEpisode ?? site?.episodeInfoList?.length ?? 1,
        site?.episodeInfoList ?? [],
        ctx,
      );
      for (const [index, episode] of episodes.entries()) {
        if (!episode.id) continue;
        const number = episodeNumber(episode, index + 1);
        if (query.episode !== undefined && number !== query.episode) continue;
        const duration = Number.parseInt(episode.duration ?? '', 10);
        candidates.push({
          source: this.id,
          platformEpisodeId: episode.id,
          title: item.video.title ?? '腾讯视频',
          episodeTitle: episodeLabel(number, episode.titleSuffix),
          duration: Number.isFinite(duration) && duration > 0 ? duration : undefined,
          confidence: Number(item.score.toFixed(3)),
        });
      }
    }
    return candidates.sort((a, b) => b.confidence - a.confidence);
  }

  /** 展开腾讯视频的首屏与分页分集，按 vid 去重。 */
  private async fetchEpisodes(
    coverId: string,
    total: number,
    initial: QQEpisode[],
    ctx: ProviderContext,
  ): Promise<QQEpisode[]> {
    const pages = Math.min(Math.max(Math.ceil(total / 10), 1), 12);
    const requests: Array<{ scene: number; page: number }> = [{ scene: 8, page: 0 }];
    for (let page = 0; page < pages; page++) requests.push({ scene: 3, page });
    const results = await mapWithLimit(requests, 3, async (request) => {
      const response = await ctx.fetch(EPISODE_URL, {
        method: 'POST',
        headers: COMMON_HEADERS,
        body: episodeBody(coverId, request.scene, request.page),
      });
      const data = (await response.json()) as {
        data?: {
          normalList?: {
            itemList?: Array<{ videoInfo?: QQVideoInfo }>;
          };
        };
      };
      return data.data?.normalList?.itemList?.[0]?.videoInfo?.firstBlockSites?.[0]
        ?.episodeInfoList ?? [];
    });
    const byId = new Map<string, QQEpisode>();
    for (const episode of [...initial, ...results.flat()]) {
      if (episode.id) byId.set(episode.id, episode);
    }
    return [...byId.values()].sort(
      (a, b) => episodeNumber(a, Number.MAX_SAFE_INTEGER) - episodeNumber(b, Number.MAX_SAFE_INTEGER),
    );
  }

  /** 按 base 索引拉取指定 vid 的全部弹幕分片。 */
  async fetch(platformEpisodeId: string, ctx: ProviderContext): Promise<DanmakuItem[]> {
    const vid = this.parseUrl(platformEpisodeId);
    if (!vid) {
      throw new GatewayError(ErrorCode.BAD_REQUEST, '非法的腾讯视频 vid', platformEpisodeId);
    }
    const response = await ctx.fetch(`https://dm.video.qq.com/barrage/base/${vid}`, {
      headers: { Referer: 'https://v.qq.com/' },
    });
    const data = (await response.json()) as {
      segment_index?: Record<string, { segment_name?: string }>;
    };
    const segmentNames = Object.values(data.segment_index ?? {})
      .map((segment) => segment.segment_name)
      .filter((name): name is string => Boolean(name));
    if (segmentNames.length === 0) {
      throw new GatewayError(ErrorCode.SCHEMA_CHANGED, '腾讯视频弹幕索引为空');
    }
    const segments = await mapWithLimit(segmentNames, SEGMENT_CONCURRENCY, (name) =>
      this.fetchSegment(vid, name, ctx),
    );
    const items = segments.flat().sort((a, b) => a.time - b.time);
    ctx.logger.debug('腾讯视频弹幕拉取完成', { vid, segments: segmentNames.length, count: items.length });
    return items;
  }

  /** 下载并归一化单个腾讯视频弹幕分片。 */
  private async fetchSegment(
    vid: string,
    segmentName: string,
    ctx: ProviderContext,
  ): Promise<DanmakuItem[]> {
    const response = await ctx.fetch(
      `https://dm.video.qq.com/barrage/segment/${vid}/${segmentName}`,
      { headers: { Referer: 'https://v.qq.com/' } },
    );
    const data = (await response.json()) as { barrage_list?: QQBarrage[] };
    const items: DanmakuItem[] = [];
    for (const [index, barrage] of (data.barrage_list ?? []).entries()) {
      const content = barrage.content?.trim() ?? '';
      const milliseconds = Number.parseInt(barrage.time_offset ?? '', 10);
      if (!content || !Number.isFinite(milliseconds)) continue;
      const style = parseStyle(barrage.content_style);
      const score = barrage.content_score ?? 50;
      items.push({
        id: `qq:${barrage.id ?? `${segmentName}-${index}`}`,
        time: milliseconds / 1000,
        mode: style.mode,
        fontSize: 25,
        color: style.color,
        content,
        source: this.id,
        senderHash: barrage.vuid || undefined,
        createdAt: Number.parseInt(barrage.create_time ?? '', 10) || undefined,
        weight: Math.max(0, Math.min(10, Math.round(score / 10))),
      });
    }
    return items;
  }

  /** 用稳定 vid 的完整索引验证腾讯视频弹幕接口。 */
  async healthCheck(ctx: ProviderContext): Promise<HealthResult> {
    const startedAt = Date.now();
    try {
      const items = await this.fetch(HEALTH_CHECK_VID, ctx);
      return {
        ok: items.length > 100,
        latencyMs: Date.now() - startedAt,
        count: items.length,
        error: items.length > 100 ? undefined : '弹幕条数低于阈值 100',
      };
    } catch (error) {
      return {
        ok: false,
        latencyMs: Date.now() - startedAt,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }
}
