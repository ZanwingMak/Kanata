/**
 * Fastify 实例组装：Token 鉴权、CORS、路由注册与统一错误处理。
 */

import cors from '@fastify/cors';
import Fastify, { type FastifyInstance } from 'fastify';
import type { AppConfig } from './config.js';
import { ErrorCode, GatewayError, toGatewayError } from './errors.js';
import { redact } from './logger.js';
import { createRegistry } from './providers/registry.js';
import { registerKanataRoutes } from './routes/kanata.js';
import { registerV2Routes } from './routes/v2.js';
import { DanmakuService } from './service.js';

export const VERSION = '0.1.0';

/** 内部标记头：由 rewriteUrl 写入，表示请求已通过路径 Token 校验 */
const PATH_TOKEN_HEADER = 'x-kanata-path-token';

/** 豁免 Token 鉴权的路径，仅限不泄露信息的存活探测 */
const PUBLIC_PATHS = new Set(['/kanata/v1/health']);

/**
 * 构造 URL 重写函数，支持 `/{token}/api/v2/...` 的路径鉴权形式。
 * 先删除客户端可能伪造的标记头，再按实际前缀写入，避免绕过鉴权。
 */
function buildRewriteUrl(token: string) {
  const prefix = `/${token}`;
  return (req: { url?: string; headers: Record<string, unknown> }): string => {
    delete req.headers[PATH_TOKEN_HEADER];
    const url = req.url ?? '/';
    if (url === prefix) {
      req.headers[PATH_TOKEN_HEADER] = token;
      return '/';
    }
    if (url.startsWith(`${prefix}/`)) {
      req.headers[PATH_TOKEN_HEADER] = token;
      return url.slice(prefix.length);
    }
    return url;
  };
}

/**
 * 创建并配置 Fastify 应用。
 * @param config 运行配置
 * @returns 已注册全部路由的 Fastify 实例
 */
export async function createServer(config: AppConfig): Promise<FastifyInstance> {
  const app = Fastify({
    logger: { level: config.logLevel },
    rewriteUrl: buildRewriteUrl(config.token) as never,
    bodyLimit: 1024 * 1024,
  });

  // Web 端凭证走自定义头而非 cookie，只允许配置中的明确来源。
  const allowedOrigins = new Set(config.corsOrigins);
  await app.register(cors, {
    origin: (origin, callback) => {
      callback(null, !origin || allowedOrigins.has(origin));
    },
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Kanata-Credential'],
  });

  // 基础响应安全头，避免浏览器 MIME 猜测与非预期嵌入。
  app.addHook('onSend', async (_req, reply, payload) => {
    reply.header('X-Content-Type-Options', 'nosniff');
    reply.header('X-Frame-Options', 'DENY');
    reply.header('Referrer-Policy', 'no-referrer');
    return payload;
  });

  const registry = createRegistry(config);
  const service = new DanmakuService(config, registry);
  await service.initialize();
  app.addHook('onClose', async () => service.close());

  // Token 鉴权（FR-GW-004）：路径 Token 或 Authorization: Bearer 二选一
  app.addHook('onRequest', async (req) => {
    if (PUBLIC_PATHS.has(req.url.split('?')[0] ?? '')) return;
    const pathToken = req.headers[PATH_TOKEN_HEADER];
    const bearer = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '');
    if (pathToken === config.token || bearer === config.token) return;
    throw new GatewayError(ErrorCode.UNAUTHORIZED, 'Token 无效');
  });

  registerV2Routes(app, service);
  registerKanataRoutes(app, service, registry, VERSION);

  // 统一错误响应：对外只暴露错误码与文案，detail 仅写日志
  app.setErrorHandler((err, req, reply) => {
    const error = toGatewayError(err);
    if (error.detail) {
      req.log.warn({ code: error.code, detail: redact(error.detail) }, '请求处理失败');
    }
    reply.status(error.httpStatus).send({
      success: false,
      errorCode: error.code,
      errorMessage: error.message,
    });
  });

  app.setNotFoundHandler((_req, reply) => {
    reply.status(404).send({
      success: false,
      errorCode: ErrorCode.BAD_REQUEST,
      errorMessage: '接口不存在',
    });
  });

  return app;
}
