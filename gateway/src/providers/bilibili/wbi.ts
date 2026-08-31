/**
 * B 站 WBI 签名（docs/03 §2.2）。
 * Web 端搜索类接口要求 w_rid + wts 签名，混淆密钥每日更新，需缓存并定期刷新。
 */

import { createHash } from 'node:crypto';
import { ErrorCode, GatewayError } from '../../errors.js';
import type { ProviderContext } from '../types.js';

/** 官方 JS 中固定的字节重排表 */
const MIXIN_KEY_ENC_TAB = [
  46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
  28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25,
  54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
];

/** 混淆密钥缓存有效期：1 小时 */
const KEY_TTL_MS = 60 * 60 * 1000;

/** BiliDroid 公共请求参数，用于 WBI 搜索被风控为空时的移动端兜底。 */
export const BILIBILI_MOBILE_APP_KEY = '1d8b6e7d45233436';
const BILIBILI_MOBILE_APP_SECRET = '560c52ccd288fed045859ed18bffd973';

let cachedMixinKey = '';
let cachedAt = 0;

/** 从图片 URL 中截出密钥部分，例如 .../7cd084941338484aae1ad9425b84077c.png → 前 32 位十六进制 */
function extractKey(url: string): string {
  const name = url.split('/').pop() ?? '';
  return name.split('.')[0] ?? '';
}

/**
 * 获取（并缓存）WBI 混淆密钥。
 * 通过 nav 接口拿到 img_key 与 sub_key，按固定重排表取前 32 位。
 */
export async function getMixinKey(ctx: ProviderContext): Promise<string> {
  if (cachedMixinKey && Date.now() - cachedAt < KEY_TTL_MS) return cachedMixinKey;

  const response = await ctx.fetch('https://api.bilibili.com/x/web-interface/nav', {
    headers: { Referer: 'https://www.bilibili.com' },
  });
  const data = (await response.json()) as {
    data?: { wbi_img?: { img_url?: string; sub_url?: string } };
  };
  const imgUrl = data.data?.wbi_img?.img_url;
  const subUrl = data.data?.wbi_img?.sub_url;
  if (!imgUrl || !subUrl) {
    throw new GatewayError(ErrorCode.SCHEMA_CHANGED, 'B 站 nav 接口未返回 wbi_img');
  }

  const raw = extractKey(imgUrl) + extractKey(subUrl);
  cachedMixinKey = MIXIN_KEY_ENC_TAB.map((index) => raw[index] ?? '')
    .join('')
    .slice(0, 32);
  cachedAt = Date.now();
  return cachedMixinKey;
}

/**
 * 为查询参数追加 WBI 签名。
 * @param params 原始查询参数
 * @param mixinKey 混淆密钥
 * @returns 已排序并附带 wts 与 w_rid 的查询字符串
 */
export function signWbi(params: Record<string, string>, mixinKey: string): string {
  const wts = Math.floor(Date.now() / 1000).toString();
  const signed: Record<string, string> = { ...params, wts };
  const query = Object.keys(signed)
    .sort()
    .map((key) => {
      // 官方实现会过滤掉这几个字符再参与签名
      const value = (signed[key] ?? '').replace(/[!'()*]/g, '');
      return `${encodeURIComponent(key)}=${encodeURIComponent(value)}`;
    })
    .join('&');
  const wRid = createHash('md5').update(query + mixinKey).digest('hex');
  return `${query}&w_rid=${wRid}`;
}

/**
 * 按移动端接口规则排序、编码并追加 sign。
 * @param params 已包含 appkey 与 ts 的请求参数
 * @returns 可直接拼接到 URL 的查询串
 */
export function signBilibiliMobile(params: Record<string, string>): string {
  const query = Object.keys(params)
    .sort()
    .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(params[key] ?? '')}`)
    .join('&');
  const sign = createHash('md5').update(query + BILIBILI_MOBILE_APP_SECRET).digest('hex');
  return `${query}&sign=${sign}`;
}
