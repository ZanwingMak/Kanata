/**
 * 日志脱敏工具（NFR-SEC-002）。
 * 凭证、密钥、令牌一律不得以明文进入日志、诊断信息或错误响应。
 */

/** 需要脱敏的字段名（大小写不敏感） */
const SENSITIVE_KEYS = [
  'sessdata',
  'bili_jct',
  'dedeuserid',
  'buvid3',
  'cookie',
  'set-cookie',
  'authorization',
  'x-appsecret',
  'appsecret',
  'token',
  'password',
  'passwd',
  'api_key',
  'apikey',
  'x-kanata-credential',
];

/** 形如 `SESSDATA=xxx` 的键值对，直接在字符串中替换值 */
const INLINE_PATTERN = new RegExp(`(${SENSITIVE_KEYS.join('|')})\\s*[=:]\\s*[^;,&\\s"']+`, 'gi');

/** 对任意字符串做脱敏，返回可安全写入日志的版本 */
export function redact(text: string): string {
  return text.replace(INLINE_PATTERN, (_m, key: string) => `${key}=***`);
}

/** 对对象做浅层脱敏，命中敏感键的值替换为 ***，其余保持原样 */
export function redactObject(obj: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (SENSITIVE_KEYS.includes(key.toLowerCase())) {
      result[key] = '***';
    } else if (typeof value === 'string') {
      result[key] = redact(value);
    } else {
      result[key] = value;
    }
  }
  return result;
}

/** 适配器可用的最小日志接口，由网关注入具体实现 */
export interface Logger {
  debug(msg: string, meta?: Record<string, unknown>): void;
  info(msg: string, meta?: Record<string, unknown>): void;
  warn(msg: string, meta?: Record<string, unknown>): void;
  error(msg: string, meta?: Record<string, unknown>): void;
}

/** 基于 console 的默认实现，所有输出都经过脱敏 */
export function createConsoleLogger(scope: string): Logger {
  const emit = (level: string, msg: string, meta?: Record<string, unknown>) => {
    const payload = meta ? ` ${JSON.stringify(redactObject(meta))}` : '';
    console.log(`[${new Date().toISOString()}] ${level} [${scope}] ${redact(msg)}${payload}`);
  };
  return {
    debug: (m, meta) => emit('DEBUG', m, meta),
    info: (m, meta) => emit('INFO', m, meta),
    warn: (m, meta) => emit('WARN', m, meta),
    error: (m, meta) => emit('ERROR', m, meta),
  };
}
