/**
 * 统一出网客户端（docs/03 §9 规范 2）。
 * 适配器不得自行创建 HTTP 客户端，一律使用注入的 FetchLike，
 * 以保证超时、重试、UA、并发与日志脱敏的一致性。
 */

import { ErrorCode, GatewayError } from './errors.js';
import type { Logger } from './logger.js';

/** 桌面浏览器 UA，多数平台接口会校验 */
export const DESKTOP_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

export interface FetchOptions {
  method?: 'GET' | 'POST';
  headers?: Record<string, string>;
  body?: string;
  /** 单次请求超时，缺省取全局配置 */
  timeoutMs?: number;
  /** 重试次数上限，默认 2 次 */
  retries?: number;
}

export type FetchLike = (url: string, options?: FetchOptions) => Promise<Response>;

/** 判断该响应是否值得重试：限流与服务端错误可重试，客户端错误不重试 */
function shouldRetry(status: number): boolean {
  return status === 429 || status >= 500;
}

/** 指数退避等待，第 n 次重试等待 250ms * 3^n */
function backoff(attempt: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 250 * Math.pow(3, attempt)));
}

/**
 * 创建带超时与重试的 fetch 函数。
 * @param defaultTimeoutMs 默认超时毫秒数
 * @param logger 日志器，请求失败时输出脱敏诊断
 * @returns 供适配器使用的 FetchLike
 */
export function createFetch(defaultTimeoutMs: number, logger: Logger): FetchLike {
  return async function kanataFetch(url: string, options: FetchOptions = {}): Promise<Response> {
    const retries = options.retries ?? 2;
    const timeoutMs = options.timeoutMs ?? defaultTimeoutMs;
    let lastError: unknown;

    for (let attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) await backoff(attempt - 1);
      try {
        const response = await fetch(url, {
          method: options.method ?? 'GET',
          headers: { 'User-Agent': DESKTOP_UA, ...options.headers },
          body: options.body,
          signal: AbortSignal.timeout(timeoutMs),
        });
        if (shouldRetry(response.status) && attempt < retries) {
          logger.warn('上游返回可重试状态码，准备重试', { url, status: response.status, attempt });
          continue;
        }
        if (response.status === 429) {
          throw new GatewayError(ErrorCode.RATE_LIMITED, '上游限流', url);
        }
        return response;
      } catch (err) {
        lastError = err;
        const name = err instanceof Error ? err.name : 'Unknown';
        if (name === 'TimeoutError' || name === 'AbortError') {
          logger.warn('上游请求超时', { url, attempt });
          if (attempt >= retries) {
            throw new GatewayError(ErrorCode.UPSTREAM_TIMEOUT, '上游请求超时', url);
          }
          continue;
        }
        if (err instanceof GatewayError) throw err;
        logger.warn('上游请求失败', { url, attempt, message: String(err) });
        if (attempt >= retries) break;
      }
    }
    throw new GatewayError(
      ErrorCode.PROVIDER_ERROR,
      '上游请求失败',
      `${url} ${String(lastError)}`,
    );
  };
}

/**
 * 以并发上限执行一批异步任务（docs/03 §9 规范 3：单集分片并发 ≤5）。
 * @param items 任务输入
 * @param limit 并发上限
 * @param worker 单个任务的处理函数
 * @returns 与输入顺序一致的结果数组
 */
export async function mapWithLimit<T, R>(
  items: T[],
  limit: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let cursor = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++;
      results[index] = await worker(items[index] as T, index);
    }
  });
  await Promise.all(runners);
  return results;
}
