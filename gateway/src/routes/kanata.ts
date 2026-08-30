/**
 * Kanata 扩展路由（FR-GW-002）。
 * 统一弹幕模型、多源聚合、源健康与密度曲线都在这里对外暴露。
 */

import type { FastifyInstance } from 'fastify';
import { CREDENTIAL_HEADER, parseCredential } from '../credential.js';
import { ErrorCode, GatewayError } from '../errors.js';
import { densityCurve } from '../normalize/danmaku.js';
import type { ProviderRegistry } from '../providers/registry.js';
import type { DanmakuRef, DanmakuService } from '../service.js';
import type { DanmakuSourceId, ResolveRequest } from '../types.js';

/** 解析 refs 参数：`dandanplay:123,bilibili:456` */
function parseRefs(raw: string | undefined): DanmakuRef[] {
  if (!raw) return [];
  const refs: DanmakuRef[] = [];
  for (const chunk of raw.split(',')) {
    const index = chunk.indexOf(':');
    if (index <= 0) continue;
    refs.push({
      source: chunk.slice(0, index) as DanmakuSourceId,
      platformEpisodeId: chunk.slice(index + 1),
      offset: 0,
      scale: 1,
    });
  }
  return refs;
}

/** 解析每源偏移参数：`dandanplay:-12.5,bilibili:3`，单位秒 */
function parseOffsets(raw: string | undefined): Map<string, number> {
  const map = new Map<string, number>();
  if (!raw) return map;
  for (const chunk of raw.split(',')) {
    const index = chunk.lastIndexOf(':');
    if (index <= 0) continue;
    const value = Number.parseFloat(chunk.slice(index + 1));
    if (Number.isFinite(value)) map.set(chunk.slice(0, index), value);
  }
  return map;
}

export function registerKanataRoutes(
  app: FastifyInstance,
  service: DanmakuService,
  registry: ProviderRegistry,
  version: string,
): void {
  /** 存活与版本，供监控探测；该端点豁免 Token 鉴权 */
  app.get('/kanata/v1/health', async () => ({
    ok: true,
    version,
    uptimeSec: Math.round(process.uptime()),
  }));

  /** 各源可用性与最近探活结果 */
  app.get('/kanata/v1/sources', async (req) => {
    const credential = parseCredential(req.headers[CREDENTIAL_HEADER] as string | undefined);
    return {
      sources: registry.snapshot((id) => service.hasCredential(credential, id)),
    };
  });

  /** 跨平台剧集映射 */
  app.post<{ Body: ResolveRequest }>('/kanata/v1/resolve', async (req) => {
    const body = req.body;
    if (!body?.title && !body?.fingerprint) {
      throw new GatewayError(ErrorCode.BAD_REQUEST, 'title 与 fingerprint 至少提供一项');
    }
    const ctx = service.createContext(
      parseCredential(req.headers[CREDENTIAL_HEADER] as string | undefined),
      AbortSignal.timeout(30_000),
    );
    return service.resolve({ ...body, title: body.title ?? body.fingerprint?.fileName ?? '' }, ctx);
  });

  /** 取统一模型弹幕，支持多源聚合、去重与每源偏移 */
  app.get<{ Querystring: { refs?: string; offsets?: string; dedup?: string } }>(
    '/kanata/v1/danmaku',
    async (req) => {
      const refs = parseRefs(req.query.refs);
      if (refs.length === 0) {
        throw new GatewayError(ErrorCode.BAD_REQUEST, 'refs 不能为空，格式为 source:episodeId');
      }
      const offsets = parseOffsets(req.query.offsets);
      for (const ref of refs) {
        ref.offset = offsets.get(ref.source) ?? 0;
      }
      const ctx = service.createContext(
        parseCredential(req.headers[CREDENTIAL_HEADER] as string | undefined),
        AbortSignal.timeout(60_000),
      );
      return service.aggregate(refs, { dedup: req.query.dedup !== 'false' }, ctx);
    },
  );

  /** 弹幕密度曲线（1Hz 采样），供自动时轴对齐与诊断面板使用 */
  app.get<{ Querystring: { refs?: string; duration?: string } }>(
    '/kanata/v1/density',
    async (req) => {
      const refs = parseRefs(req.query.refs);
      if (refs.length === 0) {
        throw new GatewayError(ErrorCode.BAD_REQUEST, 'refs 不能为空');
      }
      const duration = req.query.duration ? Number.parseFloat(req.query.duration) : undefined;
      const ctx = service.createContext(
        parseCredential(req.headers[CREDENTIAL_HEADER] as string | undefined),
        AbortSignal.timeout(60_000),
      );
      const result = await service.aggregate(refs, { dedup: false }, ctx);
      return {
        curve: densityCurve(result.items, Number.isFinite(duration) ? duration : undefined),
        total: result.items.length,
        degraded: result.degraded,
      };
    },
  );
}
