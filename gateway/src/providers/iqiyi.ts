/**
 * 爱奇艺弹幕适配器。
 * 搜索使用公开网页接口，弹幕使用每 300 秒一个 zlib XML 分片的接口。
 */

import { inflateSync } from 'node:zlib';
import { ErrorCode, GatewayError } from '../errors.js';
import { mapWithLimit } from '../http.js';
import { titleSimilarity } from '../normalize/title.js';
import type { DanmakuItem, DanmakuMode, ProviderCandidate, ResolveRequest } from '../types.js';
import type { DanmakuProvider, HealthResult, ProviderContext } from './types.js';

const SEGMENT_SECONDS = 300;
const MAX_SEGMENTS = 48;
const SEGMENT_CONCURRENCY = 5;
const COMMON_HEADERS = {
  Referer: 'https://www.iqiyi.com/',
  Origin: 'https://www.iqiyi.com',
};
const HEALTH_CHECK_ID = '3493131456125200@300';

interface IqiyiSearchVideo {
  tvId?: number;
  itemNumber?: number;
  timeLength?: number;
  subTitle?: string;
}

interface IqiyiAlbum {
  albumId?: number;
  albumTitle?: string;
  videoinfos?: IqiyiSearchVideo[];
}

interface IqiyiEpisode {
  tvId?: number;
  subtitle?: string;
  name?: string;
  duration?: string;
  order?: number;
}

/** 把 XML 实体还原为弹幕原文。 */
function decodeXml(value: string): string {
  return value
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Number.parseInt(code, 10)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code: string) =>
      String.fromCodePoint(Number.parseInt(code, 16)),
    )
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/** 从单个 XML 节点中读取文本字段。 */
function xmlValue(block: string, tag: string): string {
  const match = block.match(new RegExp(`<${tag}>([\\s\\S]*?)<\\/${tag}>`));
  return match ? decodeXml(match[1] ?? '') : '';
}

/** 将爱奇艺 position 映射到统一弹幕模式。 */
function mapPosition(position: number): DanmakuMode {
  if (position === 2) return 5;
  if (position === 3) return 4;
  return 1;
}

/** 把十六进制颜色转换为 RGB 十进制。 */
function parseColor(value: string): number {
  const color = Number.parseInt(value.replace(/^#/, ''), 16);
  return Number.isFinite(color) ? color : 16777215;
}

/** 把 mm:ss 或 hh:mm:ss 时长转换为秒。 */
function parseDuration(value?: string): number | undefined {
  if (!value) return undefined;
  const parts = value.split(':').map((part) => Number.parseInt(part, 10));
  if (parts.some((part) => !Number.isFinite(part))) return undefined;
  const seconds = parts.reduce((total, part) => total * 60 + part, 0);
  return seconds > 0 ? seconds : undefined;
}

/** 生成始终带集号的候选标题。 */
function episodeLabel(number: number, subtitle?: string): string {
  const suffix = subtitle?.trim();
  return suffix ? `第 ${number} 集 · ${suffix}` : `第 ${number} 集`;
}

export class IqiyiProvider implements DanmakuProvider {
  readonly id = 'iqiyi' as const;
  readonly requiresCredential = false;

  /** 解析带时长的 `tvid@秒数` 高级输入。 */
  parseUrl(url: string): string | null {
    const numeric = url.trim().match(/^\d+@\d+$/);
    if (numeric) return numeric[0];
    return null;
  }

  /** 搜索作品并展开最相似的两部作品为逐集候选。 */
  async search(query: ResolveRequest, ctx: ProviderContext): Promise<ProviderCandidate[]> {
    const direct = this.parseUrl(query.title);
    if (direct) {
      return [{
        source: this.id,
        platformEpisodeId: direct,
        title: '爱奇艺视频',
        episodeTitle: query.episode ? `第 ${query.episode} 集` : '指定视频',
        confidence: 1,
      }];
    }

    const url = new URL('https://search.video.iqiyi.com/o');
    url.searchParams.set('if', 'html5');
    url.searchParams.set('key', query.title);
    url.searchParams.set('pageNum', '1');
    url.searchParams.set('pageSize', '12');
    const response = await ctx.fetch(url.toString(), { headers: COMMON_HEADERS });
    const data = (await response.json()) as {
      code?: string;
      data?: { docinfos?: Array<{ albumDocInfo?: IqiyiAlbum }> };
    };
    if (data.code !== 'A00000') {
      throw new GatewayError(ErrorCode.PROVIDER_ERROR, '爱奇艺搜索失败', data.code);
    }

    const ranked = (data.data?.docinfos ?? [])
      .map((item) => item.albumDocInfo)
      .filter((album): album is IqiyiAlbum => Boolean(album?.albumId && album.albumTitle))
      .map((album) => ({
        album,
        score: titleSimilarity(query.title, album.albumTitle ?? ''),
      }))
      .sort((a, b) => b.score - a.score)
      .slice(0, 2);

    const candidates: ProviderCandidate[] = [];
    for (const item of ranked) {
      const episodes = await this.fetchEpisodes(item.album.albumId as number, ctx);
      for (const [index, episode] of episodes.entries()) {
        if (!episode.tvId) continue;
        const number = episode.order ?? index + 1;
        if (query.episode !== undefined && number !== query.episode) continue;
        const duration = parseDuration(episode.duration);
        candidates.push({
          source: this.id,
          platformEpisodeId: duration ? `${episode.tvId}@${duration}` : String(episode.tvId),
          title: item.album.albumTitle ?? '爱奇艺视频',
          episodeTitle: episodeLabel(number, episode.subtitle),
          duration,
          confidence: Number(item.score.toFixed(3)),
        });
      }
    }
    return candidates.sort((a, b) => b.confidence - a.confidence);
  }

  /** 获取指定专辑的完整分集列表。 */
  private async fetchEpisodes(albumId: number, ctx: ProviderContext): Promise<IqiyiEpisode[]> {
    const response = await ctx.fetch(
      `https://pcw-api.iqiyi.com/albums/album/avlistinfo?aid=${albumId}&page=1&size=200`,
      { headers: COMMON_HEADERS },
    );
    const data = (await response.json()) as {
      code?: string;
      data?: { epsodelist?: IqiyiEpisode[] };
    };
    if (data.code !== 'A00000' || !Array.isArray(data.data?.epsodelist)) {
      throw new GatewayError(ErrorCode.SCHEMA_CHANGED, '爱奇艺分集接口结构已变化');
    }
    return data.data.epsodelist;
  }

  /** 拉取并合并指定 tvid 的全部 zlib XML 弹幕分片。 */
  async fetch(platformEpisodeId: string, ctx: ProviderContext): Promise<DanmakuItem[]> {
    const [tvId = '', durationPart] = platformEpisodeId.split('@');
    if (!/^\d+$/.test(tvId)) {
      throw new GatewayError(ErrorCode.BAD_REQUEST, '非法的爱奇艺 tvid', platformEpisodeId);
    }
    const duration = Number.parseInt(durationPart ?? '', 10);
    if (!Number.isFinite(duration) || duration <= 0) {
      throw new GatewayError(ErrorCode.BAD_REQUEST, '爱奇艺弹幕需要视频时长', platformEpisodeId);
    }
    const segmentCount = Math.min(Math.ceil(duration / SEGMENT_SECONDS), MAX_SEGMENTS);
    const indexes = Array.from({ length: segmentCount }, (_, index) => index + 1);
    const segments = await mapWithLimit(indexes, SEGMENT_CONCURRENCY, (index) =>
      this.fetchSegment(tvId, index, ctx),
    );
    const items = segments.flat().sort((a, b) => a.time - b.time);
    ctx.logger.debug('爱奇艺弹幕拉取完成', { tvId, segments: segmentCount, count: items.length });
    return items;
  }

  /** 下载并解析单个 300 秒弹幕分片。 */
  private async fetchSegment(
    tvId: string,
    segmentIndex: number,
    ctx: ProviderContext,
  ): Promise<DanmakuItem[]> {
    const bucketA = tvId.slice(-4, -2);
    const bucketB = tvId.slice(-2);
    const response = await ctx.fetch(
      `https://cmts.iqiyi.com/bullet/${bucketA}/${bucketB}/${tvId}_300_${segmentIndex}.z`,
      { headers: COMMON_HEADERS },
    );
    if (response.status === 404) return [];
    if (!response.ok) {
      throw new GatewayError(ErrorCode.PROVIDER_ERROR, '爱奇艺弹幕分片请求失败', String(response.status));
    }
    const compressed = Buffer.from(await response.arrayBuffer());
    if (compressed.length === 0) return [];
    let xml: string;
    try {
      xml = inflateSync(compressed).toString('utf8');
    } catch (error) {
      throw new GatewayError(ErrorCode.SCHEMA_CHANGED, '爱奇艺弹幕解压失败', String(error));
    }
    const blocks = xml.match(/<bulletInfo>[\s\S]*?<\/bulletInfo>/g) ?? [];
    const items: DanmakuItem[] = [];
    for (const block of blocks) {
      const content = xmlValue(block, 'content').trim();
      const time = Number.parseFloat(xmlValue(block, 'showTime'));
      if (!content || !Number.isFinite(time)) continue;
      const id = xmlValue(block, 'contentId') || `${segmentIndex}-${items.length}`;
      const font = Number.parseInt(xmlValue(block, 'font'), 10);
      const position = Number.parseInt(xmlValue(block, 'position'), 10);
      items.push({
        id: `iqiyi:${id}`,
        time,
        mode: mapPosition(position),
        fontSize: Number.isFinite(font) ? Math.max(18, Math.round(font * 1.6)) : 25,
        color: parseColor(xmlValue(block, 'color')),
        content,
        source: this.id,
        senderHash: xmlValue(block, 'uid') || undefined,
        weight: Number.parseInt(xmlValue(block, 'scoreLevel'), 10) || 5,
      });
    }
    return items;
  }

  /** 用稳定剧集的首个分片验证接口和解压格式。 */
  async healthCheck(ctx: ProviderContext): Promise<HealthResult> {
    const startedAt = Date.now();
    try {
      const items = await this.fetch(HEALTH_CHECK_ID, ctx);
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
