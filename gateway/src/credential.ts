/**
 * 凭证透传（FR-GW-010 / FR-AUTH-005）。
 * 凭证由客户端按请求携带，网关只在当次请求的内存生命周期内使用，
 * 禁止写入日志、缓存键与任何持久化存储。
 */

import type { CredentialPayload } from './types.js';

/** 客户端携带凭证的请求头 */
export const CREDENTIAL_HEADER = 'x-kanata-credential';

/**
 * 解析请求头中的凭证。
 * 头部为 base64 编码的 JSON，解析失败时返回 undefined 并不抛错，
 * 以免因凭证格式问题阻断不需要凭证的源。
 */
export function parseCredential(headerValue: string | undefined): CredentialPayload | undefined {
  if (!headerValue) return undefined;
  try {
    const json = Buffer.from(headerValue, 'base64').toString('utf8');
    const parsed = JSON.parse(json) as CredentialPayload;
    return typeof parsed === 'object' && parsed !== null ? parsed : undefined;
  } catch {
    return undefined;
  }
}
