/**
 * 弹弹play v2 兼容路由（FR-GW-001）。
 * 响应结构必须能被 Senplayer / EPlayerX 等第三方播放器直接消费，
 * 字段不得增删；Kanata 自有的扩展信息一律走 /kanata/v1/*。
 */

import type { FastifyInstance } from 'fastify';
import { parseCredential, CREDENTIAL_HEADER } from '../credential.js';
import { ErrorCode, GatewayError } from '../errors.js';
import { toDandanComments } from '../normalize/danmaku.js';
import type { DanmakuService } from '../service.js';
import type { DandanMatchRequest, DanmakuSourceId, ProviderCandidate } from '../types.js';

/**
 * 把候选按作品聚合成弹弹play 的 animes 结构。
 * episodeId 直接使用平台侧数字 ID；接入非数字 ID 的平台时再引入映射表。
 */
function toAnimes(candidates: ProviderCandidate[]) {
  const animes = new Map<string, {
    animeId: number;
    animeTitle: string;
    type: string;
    episodes: Array<{ episodeId: number; episodeTitle: string }>;
  }>();
  for (const candidate of candidates) {
    const episodeId = Number.parseInt(candidate.platformEpisodeId, 10);
    if (!Number.isFinite(episodeId)) continue;
    const key = candidate.title;
    let anime = animes.get(key);
    if (!anime) {
      // 作品 ID 用首个剧集 ID 的高位近似，兼容播放器对数字 ID 的期待
      anime = {
        animeId: Math.floor(episodeId / 10000),
        animeTitle: candidate.title,
        type: 'tvseries',
        episodes: [],
      };
      animes.set(key, anime);
    }
    anime.episodes.push({
      episodeId,
      episodeTitle: candidate.episodeTitle ?? '',
    });
  }
  return [...animes.values()];
}

/** 从 commentId 解析出来源与平台剧集 ID，纯数字时默认走弹弹play */
function parseCommentId(raw: string): { source: DanmakuSourceId; platformEpisodeId: string } {
  const index = raw.indexOf(':');
  if (index > 0) {
    return {
      source: raw.slice(0, index) as DanmakuSourceId,
      platformEpisodeId: raw.slice(index + 1),
    };
  }
  return { source: 'dandanplay', platformEpisodeId: raw };
}

export function registerV2Routes(app: FastifyInstance, service: DanmakuService): void {
  /** 按关键词搜索作品 */
  app.get<{ Querystring: { keyword?: string } }>('/api/v2/search/anime', async (req) => {
    const keyword = req.query.keyword?.trim();
    if (!keyword) {
      throw new GatewayError(ErrorCode.BAD_REQUEST, 'keyword 不能为空');
    }
    const ctx = service.createContext(
      parseCredential(req.headers[CREDENTIAL_HEADER] as string | undefined),
      AbortSignal.timeout(30_000),
    );
    const result = await service.resolve({ title: keyword }, ctx);
    return {
      animes: toAnimes(result.candidates),
      errorCode: 0,
      success: true,
      errorMessage: '',
    };
  });

  /** 搜索作品及其分集 */
  app.get<{ Querystring: { anime?: string; episode?: string } }>(
    '/api/v2/search/episodes',
    async (req) => {
      const anime = req.query.anime?.trim();
      if (!anime) {
        throw new GatewayError(ErrorCode.BAD_REQUEST, 'anime 不能为空');
      }
      const episode = req.query.episode ? Number.parseInt(req.query.episode, 10) : undefined;
      const ctx = service.createContext(
        parseCredential(req.headers[CREDENTIAL_HEADER] as string | undefined),
        AbortSignal.timeout(30_000),
      );
      const result = await service.resolve(
        { title: anime, episode: Number.isFinite(episode) ? episode : undefined },
        ctx,
      );
      return {
        hasMore: false,
        animes: toAnimes(result.candidates),
        errorCode: 0,
        success: true,
        errorMessage: '',
      };
    },
  );

  /** 文件指纹匹配 */
  app.post<{ Body: DandanMatchRequest }>('/api/v2/match', async (req) => {
    const body = req.body;
    if (!body?.fileName && !body?.fileHash) {
      throw new GatewayError(ErrorCode.BAD_REQUEST, 'fileName 与 fileHash 至少提供一项');
    }
    const ctx = service.createContext(
      parseCredential(req.headers[CREDENTIAL_HEADER] as string | undefined),
      AbortSignal.timeout(30_000),
    );
    const result = await service.match(
      {
        fileName: body.fileName ?? '',
        fileHash: body.fileHash ?? '',
        fileSize: body.fileSize ?? 0,
        videoDuration: body.videoDuration ?? 0,
      },
      ctx,
    );
    const matches = result.candidates
      .filter((item) => Number.isFinite(Number.parseInt(item.platformEpisodeId, 10)))
      .map((item) => ({
        episodeId: Number.parseInt(item.platformEpisodeId, 10),
        animeId: Math.floor(Number.parseInt(item.platformEpisodeId, 10) / 10000),
        animeTitle: item.title,
        episodeTitle: item.episodeTitle ?? '',
        type: 'tvseries',
        shift: 0,
      }));
    return {
      isMatched: matches.length === 1,
      matches,
      errorCode: 0,
      success: true,
      errorMessage: '',
    };
  });

  /** 取指定剧集的弹幕 */
  app.get<{ Params: { commentId: string }; Querystring: { withRelated?: string } }>(
    '/api/v2/comment/:commentId',
    async (req) => {
      const { source, platformEpisodeId } = parseCommentId(req.params.commentId);
      const ctx = service.createContext(
        parseCredential(req.headers[CREDENTIAL_HEADER] as string | undefined),
        AbortSignal.timeout(60_000),
      );
      const result = await service.aggregate(
        [{ source, platformEpisodeId, offset: 0, scale: 1 }],
        { dedup: false },
        ctx,
      );
      if (result.items.length === 0 && result.degraded.length > 0) {
        const first = result.degraded[0];
        throw new GatewayError(
          (first?.code ?? ErrorCode.PROVIDER_ERROR) as never,
          first?.reason ?? '弹幕获取失败',
        );
      }
      return {
        count: result.items.length,
        comments: toDandanComments(result.items),
      };
    },
  );
}
