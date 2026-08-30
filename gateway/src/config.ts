/**
 * 运行配置。全部来自环境变量，字段含义见 .env.example。
 * Node 20+ 会自动加载 --env-file，这里不引入 dotenv 依赖。
 */

export interface AppConfig {
  port: number;
  host: string;
  /** 访问令牌，支持路径形式 /{token}/... 或 Authorization: Bearer */
  token: string;
  dandanplay: {
    appId: string;
    appSecret: string;
    baseUrl: string;
  };
  cache: {
    danmakuTtlMs: number;
    searchTtlMs: number;
    maxEntries: number;
  };
  requestTimeoutMs: number;
  proxyUrl: string;
  logLevel: string;
}

/** 读取整型环境变量，缺省或非法时回落到默认值 */
function envInt(key: string, fallback: number): number {
  const raw = process.env[key];
  if (!raw) return fallback;
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) ? value : fallback;
}

/** 读取字符串环境变量，缺省时回落到默认值 */
function envStr(key: string, fallback: string): string {
  const raw = process.env[key];
  return raw && raw.length > 0 ? raw : fallback;
}

/** 从当前进程环境构建配置对象 */
export function loadConfig(): AppConfig {
  return {
    port: envInt('PORT', 9321),
    host: envStr('HOST', '0.0.0.0'),
    token: envStr('TOKEN', '87654321'),
    dandanplay: {
      appId: envStr('DANDANPLAY_APP_ID', ''),
      appSecret: envStr('DANDANPLAY_APP_SECRET', ''),
      baseUrl: envStr('DANDANPLAY_BASE_URL', 'https://api.dandanplay.net'),
    },
    cache: {
      danmakuTtlMs: envInt('DANMAKU_CACHE_TTL_SEC', 43200) * 1000,
      searchTtlMs: envInt('SEARCH_CACHE_TTL_SEC', 21600) * 1000,
      maxEntries: envInt('CACHE_MAX_ENTRIES', 500),
    },
    requestTimeoutMs: envInt('REQUEST_TIMEOUT_MS', 8000),
    proxyUrl: envStr('PROXY_URL', ''),
    logLevel: envStr('LOG_LEVEL', 'info'),
  };
}
