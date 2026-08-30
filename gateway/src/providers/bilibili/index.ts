/**
 * 哔哩哔哩适配器（docs/03 §2）。
 *
 * 弹幕走 protobuf 分片接口 dm/web/seg.so，每片 360 秒。
 * 无 Cookie 时为半匿名访问，只能拿到部分弹幕且无港澳台内容；
 * 携带 SESSDATA 可获取完整弹幕（FR-DMK-002 / FR-AUTH-001）。
 */

import { ErrorCode, GatewayError } from '../../errors.js';
import { mapWithLimit } from '../../http.js';
import { toDanmakuMode } from '../../normalize/danmaku.js';
import { titleSimilarity } from '../../normalize/title.js';
import type { DanmakuItem, ProviderCandidate, ResolveRequest } from '../../types.js';
import type { DanmakuProvider, HealthResult, ProviderContext } from '../types.js';
import { parseDmSegment } from './protobuf.js';
import { getMixinKey, signWbi } from './wbi.js';

/** 单片时长（秒） */
const SEGMENT_SECONDS = 360;
/** 未知时长时最多拉取的分片数，对应 6 小时 */
const MAX_SEGMENTS = 60;
/** 分片并发上限（docs/03 §9 规范 3） */
const SEGMENT_CONCURRENCY = 5;

const COMMON_HEADERS = {
  Referer: 'https://www.bilibili.com',
  Origin: 'https://www.bilibili.com',
};

interface SeasonEpisode {
  cid: number;
  title?: string;
  long_title?: string;
  duration?: number;
}

/** 探活用的固定视频 cid，弹幕量稳定在数千条 */
const HEALTH_CHECK_CID = '144541892';

export class BilibiliProvider implements DanmakuProvider {
  readonly id = 'bilibili' as const;
  readonly requiresCredential = false;

  /**
   * 匿名指纹 cookie 缓存。
   * 实测搜索接口只带 buvid3 会被风控静默返回空结果，必须同时携带 buvid4 与 b_nut。
   */
  private buvid3 = '';
  private buvid4 = '';

  /** 组装请求头，有凭证时附带 Cookie */
  private headers(ctx: ProviderContext): Record<string, string> {
    const credential = ctx.credential?.bilibili;
    const parts: string[] = [];
    if (credential?.SESSDATA) parts.push(`SESSDATA=${credential.SESSDATA}`);
    if (credential?.bili_jct) parts.push(`bili_jct=${credential.bili_jct}`);
    if (credential?.DedeUserID) parts.push(`DedeUserID=${credential.DedeUserID}`);
    const buvid3 = credential?.buvid3 ?? this.buvid3;
    if (buvid3) parts.push(`buvid3=${buvid3}`);
    if (this.buvid4) parts.push(`buvid4=${this.buvid4}`);
    if (buvid3 || this.buvid4) parts.push(`b_nut=${Math.floor(Date.now() / 1000)}`);
    const headers: Record<string, string> = { ...COMMON_HEADERS };
    if (parts.length > 0) headers.Cookie = parts.join('; ');
    return headers;
  }

  /** 获取并缓存匿名设备指纹，用于通过搜索接口的风控 */
  private async ensureBuvid(ctx: ProviderContext): Promise<void> {
    if (this.buvid3 && this.buvid4) return;
    try {
      const response = await ctx.fetch('https://api.bilibili.com/x/frontend/finger/spi', {
        headers: COMMON_HEADERS,
      });
      const data = (await response.json()) as { data?: { b_3?: string; b_4?: string } };
      this.buvid3 = data.data?.b_3 ?? '';
      this.buvid4 = data.data?.b_4 ?? '';
    } catch (err) {
      ctx.logger.warn('获取设备指纹失败，搜索可能被风控拦截', { message: String(err) });
    }
  }

  /**
   * 从播放页 URL 解析出可用标识。
   * 支持 BV 号、ep_id、ss_id 与纯 cid，返回值可直接作为 platformEpisodeId 传给 fetch。
   */
  parseUrl(url: string): string | null {
    const bv = url.match(/\/video\/(BV[0-9A-Za-z]+)/);
    if (bv) return `bv:${bv[1]}`;
    const ep = url.match(/\/bangumi\/play\/ep(\d+)/);
    if (ep) return `ep:${ep[1]}`;
    const ss = url.match(/\/bangumi\/play\/ss(\d+)/);
    if (ss) return `ss:${ss[1]}`;
    const cid = url.match(/^\d+$/);
    if (cid) return url;
    return null;
  }

  /**
   * 搜索番剧并展开到分集。
   * 先用 WBI 签名搜索拿 season_id，再取该季的分集列表得到每集 cid。
   */
  async search(query: ResolveRequest, ctx: ProviderContext): Promise<ProviderCandidate[]> {
    await this.ensureBuvid(ctx);
    const mixinKey = await getMixinKey(ctx);
    const signed = signWbi(
      { search_type: 'media_bangumi', keyword: query.title, page: '1' },
      mixinKey,
    );
    const response = await ctx.fetch(
      `https://api.bilibili.com/x/web-interface/wbi/search/type?${signed}`,
      { headers: this.headers(ctx) },
    );
    const data = (await response.json()) as {
      code?: number;
      message?: string;
      data?: { result?: Array<{ season_id?: number; title?: string }> };
    };
    if (data.code !== 0) {
      throw new GatewayError(
        ErrorCode.PROVIDER_ERROR,
        `B 站搜索失败：${data.message ?? data.code}`,
      );
    }

    const results = data.data?.result ?? [];
    const candidates: ProviderCandidate[] = [];
    // 只展开相似度最高的两部作品，避免为每个搜索结果都拉一次分集列表
    const ranked = results
      .filter((item) => item.season_id)
      .map((item) => ({
        seasonId: item.season_id as number,
        // 搜索结果标题含 <em> 高亮标签，需要先剥离
        title: (item.title ?? '').replace(/<[^>]+>/g, ''),
      }))
      .map((item) => ({ ...item, score: titleSimilarity(query.title, item.title) }))
      .sort((a, b) => b.score - a.score)
      .slice(0, 2);

    for (const item of ranked) {
      const episodes = await this.fetchSeasonEpisodes(item.seasonId, ctx);
      for (const [index, episode] of episodes.entries()) {
        const episodeNumber = Number.parseInt(episode.title ?? '', 10);
        const number = Number.isFinite(episodeNumber) ? episodeNumber : index + 1;
        if (query.episode !== undefined && number !== query.episode) continue;
        candidates.push({
          source: this.id,
          platformEpisodeId: episode.duration
            ? `${episode.cid}@${Math.round(episode.duration / 1000)}`
            : String(episode.cid),
          title: item.title,
          episodeTitle: episode.long_title || `第 ${number} 话`,
          duration: episode.duration ? Math.round(episode.duration / 1000) : undefined,
          confidence: Number(item.score.toFixed(3)),
        });
      }
    }
    return candidates.sort((a, b) => b.confidence - a.confidence);
  }

  /** 取指定季的分集列表 */
  private async fetchSeasonEpisodes(
    seasonId: number,
    ctx: ProviderContext,
  ): Promise<SeasonEpisode[]> {
    const response = await ctx.fetch(
      `https://api.bilibili.com/pgc/view/web/season?season_id=${seasonId}`,
      { headers: this.headers(ctx) },
    );
    const data = (await response.json()) as {
      code?: number;
      result?: { episodes?: SeasonEpisode[] };
    };
    if (data.code !== 0 || !Array.isArray(data.result?.episodes)) {
      throw new GatewayError(
        ErrorCode.SCHEMA_CHANGED,
        'B 站季度接口未返回 episodes',
        JSON.stringify(data).slice(0, 512),
      );
    }
    return data.result.episodes;
  }

  /** 把 bv/ep/ss 标识解析成 `cid@时长` 形式 */
  private async resolveCid(platformEpisodeId: string, ctx: ProviderContext): Promise<string> {
    if (platformEpisodeId.startsWith('bv:')) {
      const response = await ctx.fetch(
        `https://api.bilibili.com/x/web-interface/view?bvid=${platformEpisodeId.slice(3)}`,
        { headers: this.headers(ctx) },
      );
      const data = (await response.json()) as {
        code?: number;
        data?: { cid?: number; duration?: number };
      };
      if (data.code !== 0 || !data.data?.cid) {
        throw new GatewayError(ErrorCode.NOT_MATCHED, '未找到该视频的 cid', platformEpisodeId);
      }
      return `${data.data.cid}@${data.data.duration ?? 0}`;
    }
    if (platformEpisodeId.startsWith('ep:') || platformEpisodeId.startsWith('ss:')) {
      const key = platformEpisodeId.startsWith('ep:') ? 'ep_id' : 'season_id';
      const response = await ctx.fetch(
        `https://api.bilibili.com/pgc/view/web/season?${key}=${platformEpisodeId.slice(3)}`,
        { headers: this.headers(ctx) },
      );
      const data = (await response.json()) as {
        result?: { episodes?: SeasonEpisode[] };
      };
      const episodes = data.result?.episodes ?? [];
      const target =
        platformEpisodeId.startsWith('ep:')
          ? episodes.find((e) => String((e as { id?: number }).id) === platformEpisodeId.slice(3))
          : episodes[0];
      if (!target?.cid) {
        throw new GatewayError(ErrorCode.NOT_MATCHED, '未找到该剧集的 cid', platformEpisodeId);
      }
      return `${target.cid}@${Math.round((target.duration ?? 0) / 1000)}`;
    }
    return platformEpisodeId;
  }

  /**
   * 拉取指定视频的全部弹幕。
   * platformEpisodeId 支持 `cid`、`cid@时长秒`、`bv:BV…`、`ep:…`、`ss:…`。
   * 已知时长时按 ceil(时长/360) 计算片数，否则逐片拉取直到出现空片。
   */
  async fetch(platformEpisodeId: string, ctx: ProviderContext): Promise<DanmakuItem[]> {
    const resolved = await this.resolveCid(platformEpisodeId, ctx);
    const [cidPart, durationPart] = resolved.split('@');
    const cid = cidPart ?? '';
    const duration = durationPart ? Number.parseInt(durationPart, 10) : 0;
    if (!/^\d+$/.test(cid)) {
      throw new GatewayError(ErrorCode.BAD_REQUEST, '非法的 B 站 cid', platformEpisodeId);
    }

    const segmentCount =
      duration > 0 ? Math.min(Math.ceil(duration / SEGMENT_SECONDS), MAX_SEGMENTS) : 0;
    const items: DanmakuItem[] = [];

    if (segmentCount > 0) {
      const indexes = Array.from({ length: segmentCount }, (_, i) => i + 1);
      const segments = await mapWithLimit(indexes, SEGMENT_CONCURRENCY, (index) =>
        this.fetchSegment(cid, index, ctx),
      );
      for (const segment of segments) items.push(...segment);
    } else {
      // 时长未知：串行拉取，遇到空片即停止
      for (let index = 1; index <= MAX_SEGMENTS; index++) {
        const segment = await this.fetchSegment(cid, index, ctx);
        if (segment.length === 0) break;
        items.push(...segment);
      }
    }

    ctx.logger.debug('B 站弹幕拉取完成', { cid, segments: segmentCount, count: items.length });
    return items.sort((a, b) => a.time - b.time);
  }

  /** 拉取并解析单个弹幕分片，非 protobuf 响应视为该片无数据 */
  private async fetchSegment(
    cid: string,
    segmentIndex: number,
    ctx: ProviderContext,
  ): Promise<DanmakuItem[]> {
    const url = `https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=${cid}&segment_index=${segmentIndex}`;
    const response = await ctx.fetch(url, { headers: this.headers(ctx) });
    const contentType = response.headers.get('content-type') ?? '';
    if (contentType.includes('json')) {
      // 超出分片范围或被风控时返回 JSON 错误体
      return [];
    }
    const buffer = new Uint8Array(await response.arrayBuffer());
    if (buffer.length === 0) return [];

    const items: DanmakuItem[] = [];
    for (const elem of parseDmSegment(buffer)) {
      const mode = toDanmakuMode(elem.mode);
      // 高级弹幕与代码弹幕静默丢弃（FR-DMK-109）
      if (mode === null || elem.content.length === 0) continue;
      items.push({
        id: `bilibili:${elem.id}`,
        time: elem.progress / 1000,
        mode,
        fontSize: elem.fontsize || 25,
        color: elem.color || 16777215,
        content: elem.content,
        source: this.id,
        senderHash: elem.midHash,
        createdAt: elem.ctime || undefined,
        pool: (elem.pool === 1 || elem.pool === 2 ? elem.pool : 0) as 0 | 1 | 2,
        weight: elem.weight,
      });
    }
    return items;
  }

  /** 探活：用固定 cid 拉第一个分片，验证 protobuf 结构未变（docs/05 §7） */
  async healthCheck(ctx: ProviderContext): Promise<HealthResult> {
    const startedAt = Date.now();
    try {
      const items = await this.fetchSegment(HEALTH_CHECK_CID, 1, ctx);
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
