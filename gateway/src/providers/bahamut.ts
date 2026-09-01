/** 巴哈姆特动画疯弹幕适配器。 */

import { ErrorCode, GatewayError } from '../errors.js';
import { titleSimilarity } from '../normalize/title.js';
import type { DanmakuItem, DanmakuMode, ProviderCandidate, ResolveRequest } from '../types.js';
import type { DanmakuProvider, HealthResult, ProviderContext } from './types.js';

const BASE_URL = 'https://ani.gamer.com.tw';
const COMMON_HEADERS = {
  Referer: `${BASE_URL}/`,
  Origin: BASE_URL,
};
const HEALTH_CHECK_ID = '31599';

interface BahamutBullet {
  text?: string;
  color?: string;
  size?: number;
  position?: number;
  time?: number;
  sn?: number;
  userid?: string;
}

/** 移除 HTML 标签并还原搜索标题中的常见实体。 */
function decodeHtml(value: string): string {
  return value
    .replace(/<[^>]+>/g, '')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .trim();
}

/** 将动画疯 position 转换为统一弹幕模式。 */
function mapPosition(position?: number): DanmakuMode {
  if (position === 1) return 5;
  if (position === 2) return 4;
  return 1;
}

/** 将网页十六进制颜色转换为 RGB 十进制。 */
function parseColor(value?: string): number {
  const parsed = Number.parseInt((value ?? '').replace(/^#/, ''), 16);
  return Number.isFinite(parsed) ? parsed : 16777215;
}

/** 从播放页 JSON-LD 读取 ISO 8601 视频时长。 */
function parseDuration(html: string): number | undefined {
  const match = html.match(/"duration":"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?"/i);
  if (!match) return undefined;
  const total = Number(match[1] ?? 0) * 3600 + Number(match[2] ?? 0) * 60 + Number(match[3] ?? 0);
  return total > 0 ? total : undefined;
}

/** 把本地和平台时长差异纳入候选置信度。 */
function adjustedConfidence(score: number, local?: number, remote?: number): number {
  if (!local || !remote) return score;
  const difference = Math.abs(local - remote) / local;
  if (difference > 0.1) return 0;
  return score * (1 - difference * 2);
}

/** 生成始终显示集号的候选标题。 */
function episodeLabel(number: number): string {
  return `第 ${number} 集`;
}

export class BahamutProvider implements DanmakuProvider {
  readonly id = 'bahamut' as const;
  readonly requiresCredential = false;

  /** 从动画疯播放页或纯数字输入中提取视频 sn。 */
  parseUrl(url: string): string | null {
    const value = url.trim();
    if (/^\d+$/.test(value)) return value;
    return value.match(/animeVideo\.php\?sn=(\d+)/i)?.[1] ?? null;
  }

  /** 搜索动画疯作品并展开最相似的两个作品为逐集候选。 */
  async search(query: ResolveRequest, ctx: ProviderContext): Promise<ProviderCandidate[]> {
    const direct = this.parseUrl(query.title);
    if (direct) {
      return [{
        source: this.id,
        platformEpisodeId: direct,
        title: '巴哈姆特动画疯',
        episodeTitle: query.episode ? episodeLabel(query.episode) : '指定视频',
        confidence: 1,
      }];
    }

    const response = await ctx.fetch(`${BASE_URL}/search.php`, {
      method: 'POST',
      headers: {
        ...COMMON_HEADERS,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      },
      body: new URLSearchParams({ keyword: query.title }).toString(),
    });
    if (!response.ok) {
      throw new GatewayError(ErrorCode.PROVIDER_ERROR, '巴哈姆特搜索失败', String(response.status));
    }
    const html = await response.text();
    const results = [...html.matchAll(
      /animeRef\.php\?sn=(\d+)[^>]*>[\s\S]*?<p class=['"]theme-name['"]>([\s\S]*?)<\/p>/gi,
    )]
      .map((match) => ({
        referenceId: match[1] ?? '',
        title: decodeHtml(match[2] ?? ''),
      }))
      .filter((item) => item.referenceId && item.title)
      .map((item) => ({ ...item, score: titleSimilarity(query.title, item.title) }))
      .sort((a, b) => b.score - a.score)
      .slice(0, 2);

    const candidates: ProviderCandidate[] = [];
    for (const result of results) {
      const pageResponse = await ctx.fetch(`${BASE_URL}/animeRef.php?sn=${result.referenceId}`, {
        headers: COMMON_HEADERS,
      });
      if (!pageResponse.ok) continue;
      const page = await pageResponse.text();
      const duration = parseDuration(page);
      const episodes = [...page.matchAll(/data-ani-video-sn=['"](\d+)['"][^>]*>([^<]+)<\/a>/gi)];
      for (const [index, match] of episodes.entries()) {
        const number = Number.parseInt(decodeHtml(match[2] ?? ''), 10) || index + 1;
        if (query.episode !== undefined && number !== query.episode) continue;
        const confidence = adjustedConfidence(result.score, query.duration, duration);
        if (confidence <= 0) continue;
        candidates.push({
          source: this.id,
          platformEpisodeId: match[1] ?? '',
          title: result.title,
          episodeTitle: episodeLabel(number),
          duration,
          confidence: Number(confidence.toFixed(3)),
        });
      }
    }
    return candidates.sort((a, b) => b.confidence - a.confidence);
  }

  /** 拉取并归一化指定动画疯剧集的完整弹幕。 */
  async fetch(platformEpisodeId: string, ctx: ProviderContext): Promise<DanmakuItem[]> {
    const sn = this.parseUrl(platformEpisodeId);
    if (!sn) {
      throw new GatewayError(ErrorCode.BAD_REQUEST, '非法的巴哈姆特视频 sn', platformEpisodeId);
    }
    const response = await ctx.fetch(`${BASE_URL}/ajax/danmuGet.php`, {
      method: 'POST',
      headers: {
        ...COMMON_HEADERS,
        Referer: `${BASE_URL}/animeVideo.php?sn=${sn}`,
        'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      },
      body: new URLSearchParams({ sn }).toString(),
    });
    if (!response.ok) {
      throw new GatewayError(ErrorCode.PROVIDER_ERROR, '巴哈姆特弹幕请求失败', String(response.status));
    }
    const values = (await response.json()) as BahamutBullet[];
    if (!Array.isArray(values)) {
      throw new GatewayError(ErrorCode.SCHEMA_CHANGED, '巴哈姆特弹幕接口结构已变化');
    }
    return values
      .map((bullet, index): DanmakuItem | null => {
        const content = bullet.text?.trim() ?? '';
        const time = Number(bullet.time);
        if (!content || !Number.isFinite(time) || time < 0) return null;
        const sizes = [20, 25, 30];
        const sizeIndex = Math.min(Math.max(Number(bullet.size) || 0, 0), sizes.length - 1);
        return {
          id: `bahamut:${bullet.sn ?? index}`,
          time,
          mode: mapPosition(bullet.position),
          fontSize: sizes[sizeIndex] ?? 25,
          color: parseColor(bullet.color),
          content,
          source: this.id,
          senderHash: bullet.userid || undefined,
          weight: 5,
        };
      })
      .filter((item): item is DanmakuItem => item !== null)
      .sort((a, b) => a.time - b.time);
  }

  /** 用稳定剧集验证动画疯弹幕接口结构和条数。 */
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
