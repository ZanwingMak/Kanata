/**
 * 弹幕归一化：格式转换、去重、时轴换算（FR-DMK-010 / FR-SYNC-003）。
 */

import type { DandanComment, DanmakuItem, DanmakuMode } from '../types.js';

/** 平台原始模式值到统一模式的映射，未知模式回落为滚动 */
export function toDanmakuMode(raw: number): DanmakuMode | null {
  switch (raw) {
    case 1:
    case 2:
    case 3:
      return 1;
    case 4:
      return 4;
    case 5:
      return 5;
    case 6:
      return 6;
    // 7 高级弹幕、8 代码弹幕、9 BAS 弹幕：不解析，由调用方丢弃（FR-DMK-109）
    default:
      return null;
  }
}

/**
 * 把弹弹play 格式的单条弹幕转成统一模型。
 * p 字段格式为 "时间(秒),模式,颜色,用户ID"，字段缺失或非法时返回 null。
 */
export function fromDandanComment(comment: DandanComment): DanmakuItem | null {
  const parts = comment.p?.split(',');
  if (!parts || parts.length < 3) return null;
  const time = Number.parseFloat(parts[0] as string);
  const mode = toDanmakuMode(Number.parseInt(parts[1] as string, 10));
  const color = Number.parseInt(parts[2] as string, 10);
  if (!Number.isFinite(time) || mode === null) return null;
  return {
    id: `dandanplay:${comment.cid}`,
    time,
    mode,
    fontSize: 25,
    color: Number.isFinite(color) ? color : 16777215,
    content: comment.m ?? '',
    source: 'dandanplay',
    senderHash: parts[3],
    weight: 5,
  };
}

/**
 * 把统一模型转回弹弹play 格式，供 /api/v2/comment 兼容接口输出。
 * cid 用序号填充，第三方播放器只要求其唯一。
 */
export function toDandanComments(items: DanmakuItem[]): DandanComment[] {
  return items.map((item, index) => ({
    cid: index + 1,
    p: `${item.time.toFixed(2)},${item.mode},${item.color},${item.senderHash ?? '0'}`,
    m: item.content,
  }));
}

/**
 * 应用时轴换算：displayTime = time * scale + offset（docs/02 §2.3）。
 * 结果小于 0 的弹幕会被丢弃，避免开头堆积。
 */
export function applyTimeline(items: DanmakuItem[], offset: number, scale = 1): DanmakuItem[] {
  if (offset === 0 && scale === 1) return items;
  const result: DanmakuItem[] = [];
  for (const item of items) {
    const time = item.time * scale + offset;
    if (time >= 0) result.push({ ...item, time });
  }
  return result;
}

/**
 * 跨源去重（FR-DMK-010）：内容相同且时间差小于 2 秒判为重复，保留首条。
 * 被合并的条数记录在 dupCount，供渲染端显示「×N」。
 * @returns 去重后的弹幕与被合并的条数
 */
export function dedupe(items: DanmakuItem[]): { items: DanmakuItem[]; removed: number } {
  const buckets = new Map<string, DanmakuItem>();
  let removed = 0;
  for (const item of items) {
    // 以 2 秒为一格分桶，同时检查相邻桶，避免边界处漏判
    const slot = Math.floor(item.time / 2);
    const keys = [`${item.content}#${slot - 1}`, `${item.content}#${slot}`];
    const hit = keys.map((k) => buckets.get(k)).find((v) => v !== undefined);
    if (hit && Math.abs(hit.time - item.time) < 2) {
      hit.dupCount = (hit.dupCount ?? 1) + 1;
      removed++;
      continue;
    }
    buckets.set(`${item.content}#${slot}`, item);
  }
  const result = [...buckets.values()].sort((a, b) => a.time - b.time);
  return { items: result, removed };
}

/**
 * 计算弹幕密度曲线（1Hz 采样），用于自动时轴对齐与诊断面板。
 * @param durationSec 视频时长，缺省时取最后一条弹幕的时间
 */
export function densityCurve(items: DanmakuItem[], durationSec?: number): number[] {
  const last = items.length > 0 ? (items[items.length - 1] as DanmakuItem).time : 0;
  const length = Math.ceil(durationSec ?? last) + 1;
  const curve = new Array<number>(Math.max(length, 1)).fill(0);
  for (const item of items) {
    const index = Math.floor(item.time);
    if (index >= 0 && index < curve.length) curve[index] = (curve[index] as number) + 1;
  }
  return curve;
}
