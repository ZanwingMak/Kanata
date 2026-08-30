/**
 * 网关错误码与错误类型。
 * 错误码表定义于 docs/02-架构与接口契约.md §3.4，客户端按码决定行为，不解析文案。
 */

export const ErrorCode = {
  OK: 0,
  /** 参数缺失或非法 */
  BAD_REQUEST: 40001,
  /** Token 无效 */
  UNAUTHORIZED: 40101,
  /** 平台需要凭证 */
  CREDENTIAL_REQUIRED: 40301,
  /** 凭证已失效 */
  CREDENTIAL_EXPIRED: 40302,
  /** 未匹配到剧集 */
  NOT_MATCHED: 40401,
  /** 平台限流 */
  RATE_LIMITED: 42901,
  /** 适配器内部错误 */
  PROVIDER_ERROR: 50001,
  /** 平台接口结构变更 */
  SCHEMA_CHANGED: 50301,
  /** 平台请求超时 */
  UPSTREAM_TIMEOUT: 50401,
} as const;

export type ErrorCodeValue = (typeof ErrorCode)[keyof typeof ErrorCode];

/** 错误码到 HTTP 状态码的映射 */
const HTTP_STATUS: Record<number, number> = {
  [ErrorCode.BAD_REQUEST]: 400,
  [ErrorCode.UNAUTHORIZED]: 401,
  [ErrorCode.CREDENTIAL_REQUIRED]: 403,
  [ErrorCode.CREDENTIAL_EXPIRED]: 403,
  [ErrorCode.NOT_MATCHED]: 404,
  [ErrorCode.RATE_LIMITED]: 429,
  [ErrorCode.PROVIDER_ERROR]: 500,
  [ErrorCode.SCHEMA_CHANGED]: 503,
  [ErrorCode.UPSTREAM_TIMEOUT]: 504,
};

/** 网关统一错误。携带错误码，便于路由层转成标准响应 */
export class GatewayError extends Error {
  readonly code: ErrorCodeValue;
  /** 附加诊断信息，已脱敏，可写入日志但不返回给客户端 */
  readonly detail?: string;

  constructor(code: ErrorCodeValue, message: string, detail?: string) {
    super(message);
    this.name = 'GatewayError';
    this.code = code;
    this.detail = detail;
  }

  /** 返回该错误对应的 HTTP 状态码，未定义时统一按 500 处理 */
  get httpStatus(): number {
    return HTTP_STATUS[this.code] ?? 500;
  }
}

/**
 * 把任意异常归一化为 GatewayError。
 * 用于适配器与路由层的兜底处理，保证错误码始终存在。
 */
export function toGatewayError(err: unknown): GatewayError {
  if (err instanceof GatewayError) return err;
  if (err instanceof Error) {
    // fetch 超时与中断统一归类为上游超时
    if (err.name === 'AbortError' || err.name === 'TimeoutError') {
      return new GatewayError(ErrorCode.UPSTREAM_TIMEOUT, '上游请求超时', err.message);
    }
    return new GatewayError(ErrorCode.PROVIDER_ERROR, err.message, err.stack);
  }
  return new GatewayError(ErrorCode.PROVIDER_ERROR, String(err));
}
