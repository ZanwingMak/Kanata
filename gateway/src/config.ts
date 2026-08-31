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
  customProviders: {
    strategy: 'fallback' | 'race' | 'aggregate';
    instances: CustomProviderInstanceConfig[];
  };
  cache: {
    danmakuTtlMs: number;
    danmakuStaleTtlMs: number;
    searchTtlMs: number;
    maxEntries: number;
    maxBytes: number;
    persistToDisk: boolean;
    directory: string;
  };
  requestTimeoutMs: number;
  proxyUrl: string;
  logLevel: string;
  corsOrigins: string[];
}

/** 一个弹弹play兼容自定义服务实例的运行配置。 */
export interface CustomProviderInstanceConfig {
  id: string;
  name: string;
  baseUrl: string;
  token: string;
  enabled: boolean;
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

/** 读取布尔环境变量，支持 true/false、1/0、yes/no。 */
function envBool(key: string, fallback: boolean): boolean {
  const raw = process.env[key]?.trim().toLowerCase();
  if (!raw) return fallback;
  if (['true', '1', 'yes', 'on'].includes(raw)) return true;
  if (['false', '0', 'no', 'off'].includes(raw)) return false;
  return fallback;
}

/** 解析并验证自定义兼容 API 实例列表，配置错误时启动即失败。 */
function customProviderInstances(): CustomProviderInstanceConfig[] {
  const raw = process.env.CUSTOM_PROVIDERS_JSON?.trim();
  if (!raw) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error('CUSTOM_PROVIDERS_JSON 必须是合法 JSON 数组');
  }
  if (!Array.isArray(parsed)) throw new Error('CUSTOM_PROVIDERS_JSON 必须是数组');
  const ids = new Set<string>();
  return parsed.map((value, index) => {
    if (!value || typeof value !== 'object') {
      throw new Error(`CUSTOM_PROVIDERS_JSON[${index}] 必须是对象`);
    }
    const item = value as Record<string, unknown>;
    const id = typeof item.id === 'string' ? item.id.trim() : '';
    const name = typeof item.name === 'string' ? item.name.trim() : id;
    const baseUrl = typeof item.baseUrl === 'string' ? item.baseUrl.trim().replace(/\/$/, '') : '';
    const token = typeof item.token === 'string' ? item.token : '';
    const enabled = item.enabled !== false;
    if (!/^[a-zA-Z0-9_-]{1,40}$/.test(id)) {
      throw new Error(`CUSTOM_PROVIDERS_JSON[${index}].id 只能包含字母、数字、_、-`);
    }
    if (ids.has(id)) throw new Error(`自定义来源实例 ID 重复：${id}`);
    ids.add(id);
    let url: URL;
    try {
      url = new URL(baseUrl);
    } catch {
      throw new Error(`自定义来源 ${id} 的 baseUrl 无效`);
    }
    if (!['http:', 'https:'].includes(url.protocol)) {
      throw new Error(`自定义来源 ${id} 只支持 http/https`);
    }
    return { id, name: name || id, baseUrl, token, enabled };
  });
}

/** 解析自定义来源访问策略，非法值回落到顺序模式。 */
function customProviderStrategy(): 'fallback' | 'race' | 'aggregate' {
  const value = envStr('CUSTOM_PROVIDER_STRATEGY', 'fallback');
  return value === 'race' || value === 'aggregate' ? value : 'fallback';
}

/** 读取逗号分隔的 Web 跨域白名单，原生客户端不受此限制。 */
function corsOrigins(): string[] {
  const raw = envStr(
    'CORS_ORIGINS',
    'http://localhost:3000,http://127.0.0.1:3000,http://localhost:5173,http://127.0.0.1:5173',
  );
  const origins = raw.split(',').map((item) => item.trim()).filter(Boolean);
  if (origins.includes('*')) throw new Error('CORS_ORIGINS 不允许使用通配符 *');
  return origins;
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
    customProviders: {
      strategy: customProviderStrategy(),
      instances: customProviderInstances(),
    },
    cache: {
      danmakuTtlMs: envInt('DANMAKU_CACHE_TTL_SEC', 43200) * 1000,
      danmakuStaleTtlMs: envInt('DANMAKU_STALE_TTL_SEC', 604800) * 1000,
      searchTtlMs: envInt('SEARCH_CACHE_TTL_SEC', 21600) * 1000,
      maxEntries: envInt('CACHE_MAX_ENTRIES', 500),
      maxBytes: envInt('CACHE_MAX_MB', 2048) * 1024 * 1024,
      persistToDisk: envBool('CACHE_PERSIST', true),
      directory: envStr('CACHE_DIR', './data/cache'),
    },
    requestTimeoutMs: envInt('REQUEST_TIMEOUT_MS', 8000),
    proxyUrl: envStr('PROXY_URL', ''),
    logLevel: envStr('LOG_LEVEL', 'info'),
    corsOrigins: corsOrigins(),
  };
}
