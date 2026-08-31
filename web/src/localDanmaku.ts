import type { DanmakuItem, DanmakuMode } from './types';

/** 把平台模式编号收敛到 Kanata 四种基础模式。 */
function normalizeMode(value: number): DanmakuMode {
  if (value === 4) return 4;
  if (value === 5) return 5;
  if (value === 6) return 6;
  return 1;
}

/** 解析 bilibili XML 弹幕。 */
function parseXML(text: string): DanmakuItem[] {
  const documentNode = new DOMParser().parseFromString(text, 'application/xml');
  if (documentNode.querySelector('parsererror')) throw new Error('XML 文件格式错误');
  return [...documentNode.querySelectorAll('d')].flatMap((node, index) => {
    const parts = (node.getAttribute('p') ?? '').split(',');
    const time = Number(parts[0]);
    const content = node.textContent?.trim() ?? '';
    if (!Number.isFinite(time) || !content) return [];
    return [{
      id: `local:xml:${parts[7] || index}`,
      time,
      mode: normalizeMode(Number(parts[1])),
      fontSize: Number(parts[2]) || 25,
      color: Number(parts[3]) || 0xffffff,
      content,
      source: 'local' as const,
      senderHash: parts[6] || undefined,
    }];
  });
}

/** 解析 dandanplay 或 DPlayer JSON 弹幕。 */
function parseJSON(text: string): DanmakuItem[] {
  const root = JSON.parse(text) as {
    comments?: Array<{ cid?: number | string; p?: string; m?: string }>;
    data?: unknown[][];
  } | unknown[][];
  if (!Array.isArray(root) && Array.isArray(root.comments)) {
    return root.comments.flatMap((comment, index) => {
      const parts = comment.p?.split(',') ?? [];
      const time = Number(parts[0]);
      if (!Number.isFinite(time) || !comment.m?.trim()) return [];
      return [{
        id: `local:json:${comment.cid ?? index}`,
        time,
        mode: normalizeMode(Number(parts[1])),
        fontSize: 25,
        color: Number(parts[2]) || 0xffffff,
        content: comment.m,
        source: 'local' as const,
        senderHash: parts[3] || undefined,
      }];
    });
  }
  const rows = Array.isArray(root) ? root : root.data;
  if (!Array.isArray(rows)) throw new Error('无法识别 JSON 弹幕结构');
  return rows.flatMap((row, index) => {
    const time = Number(row[0]);
    const mode = Number(row[1]) === 1 ? 5 : Number(row[1]) === 2 ? 4 : 1;
    const content = typeof row[4] === 'string' ? row[4].trim() : '';
    if (!Number.isFinite(time) || !content) return [];
    const colorText = String(row[2] ?? '#ffffff').replace(/^#/, '');
    return [{
      id: `local:dplayer:${index}`,
      time,
      mode: mode as DanmakuMode,
      fontSize: 25,
      color: Number.parseInt(colorText, colorText.length === 6 ? 16 : 10) || 0xffffff,
      content,
      source: 'local' as const,
    }];
  });
}

/** 把 ASS 时间转换为秒数。 */
function assTime(value: string): number | undefined {
  const parts = value.trim().split(':').map(Number);
  if (parts.length !== 3 || parts.some((part) => !Number.isFinite(part))) return undefined;
  return (parts[0] ?? 0) * 3600 + (parts[1] ?? 0) * 60 + (parts[2] ?? 0);
}

/** 解析 ASS Events 中的 Dialogue 文本。 */
function parseASS(text: string): DanmakuItem[] {
  const items: DanmakuItem[] = [];
  for (const line of text.split(/\r?\n/)) {
    if (!line.toLowerCase().startsWith('dialogue:')) continue;
    const fields = line.slice(line.indexOf(':') + 1).split(',');
    const time = assTime(fields[1] ?? '');
    const content = fields.slice(9).join(',')
      .replace(/\{[^}]*}/g, '')
      .replace(/\\[Nn]/g, ' ')
      .trim();
    if (time === undefined || !content) continue;
    items.push({
      id: `local:ass:${items.length}`,
      time,
      mode: 1,
      fontSize: 25,
      color: 0xffffff,
      content,
      source: 'local',
    });
  }
  return items;
}

/** 按文件扩展名解析本地弹幕，并按时间排序。 */
export async function parseLocalDanmaku(file: File): Promise<DanmakuItem[]> {
  const text = await file.text();
  const extension = file.name.split('.').pop()?.toLowerCase();
  const items = extension === 'xml'
    ? parseXML(text)
    : extension === 'json'
      ? parseJSON(text)
      : extension === 'ass'
        ? parseASS(text)
        : [];
  if (items.length === 0) throw new Error('文件中没有可导入的弹幕');
  return items.sort((left, right) => left.time - right.time);
}

/** 合并本地和在线弹幕，并去除两秒内的跨来源相同文本。 */
export function mergeDanmaku(localItems: DanmakuItem[], onlineItems: DanmakuItem[]): DanmakuItem[] {
  const sorted = [...localItems, ...onlineItems].sort((left, right) => left.time - right.time);
  const recent = new Map<string, { time: number; source: string }>();
  return sorted.filter((item) => {
    const key = item.content.trim().toLowerCase();
    const previous = recent.get(key);
    if (previous && previous.source !== item.source && Math.abs(item.time - previous.time) <= 2) {
      return false;
    }
    recent.set(key, { time: item.time, source: item.source });
    return true;
  });
}
