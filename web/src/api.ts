import type {
  DanmakuResponse,
  ProviderCandidate,
  ResolveRequest,
  ResolveResponse,
} from './types';

export class GatewayApiError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly code?: number,
  ) {
    super(message);
  }
}

/** 拼接网关根地址与接口路径，同时保留根地址中的路径 Token。 */
function endpoint(baseURL: string, path: string): string {
  return `${baseURL.trim().replace(/\/$/, '')}/${path.replace(/^\//, '')}`;
}

/** 发起带 Token 的网关请求，并把网络、CORS 与业务错误转换为可读提示。 */
async function request<T>(
  baseURL: string,
  token: string,
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set('Accept', 'application/json');
  if (token.trim()) headers.set('Authorization', `Bearer ${token.trim()}`);
  try {
    const response = await fetch(endpoint(baseURL, path), { ...init, headers });
    const body = await response.json().catch(() => null) as {
      errorCode?: number;
      errorMessage?: string;
    } | null;
    if (!response.ok) {
      throw new GatewayApiError(
        body?.errorMessage ?? `网关返回 ${response.status}`,
        response.status,
        body?.errorCode,
      );
    }
    return body as T;
  } catch (error) {
    if (error instanceof GatewayApiError) throw error;
    throw new GatewayApiError('无法连接网关，请检查地址、HTTPS 与 CORS 白名单');
  }
}

/** 请求跨平台匹配候选。 */
export async function resolveDanmaku(
  baseURL: string,
  token: string,
  query: ResolveRequest,
): Promise<ResolveResponse> {
  return request(baseURL, token, '/kanata/v1/resolve', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(query),
  });
}

/** 拉取一个候选对应的统一弹幕数组。 */
export async function fetchDanmaku(
  baseURL: string,
  token: string,
  candidate: ProviderCandidate,
): Promise<DanmakuResponse> {
  const refs = `${candidate.source}:${candidate.platformEpisodeId}`;
  const query = new URLSearchParams({ refs, dedup: 'true' });
  return request(baseURL, token, `/kanata/v1/danmaku?${query.toString()}`);
}

/** 探测网关是否可访问，并通过受保护接口验证 Token。 */
export async function checkGateway(baseURL: string, token: string): Promise<boolean> {
  const response = await request<{ sources: unknown[] }>(baseURL, token, '/kanata/v1/sources');
  return Array.isArray(response.sources);
}
