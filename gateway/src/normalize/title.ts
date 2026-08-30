/**
 * 标题归一与相似度（FR-MATCH-005）。
 * 用于跨平台剧集映射时给候选打分。
 */

/** 全角字符转半角，覆盖常见的中文输入残留 */
function toHalfWidth(text: string): string {
  return text.replace(/[！-～]/g, (ch) =>
    String.fromCharCode(ch.charCodeAt(0) - 0xfee0),
  ).replace(/　/g, ' ');
}

/**
 * 归一化标题：转半角、转小写、去除标点与空白、剥离常见修饰词。
 * 归一化后的字符串仅用于比较，不用于展示。
 */
export function normalizeTitle(title: string): string {
  return toHalfWidth(title)
    .toLowerCase()
    .replace(/第[一二三四五六七八九十\d]+[季期部]/g, '')
    .replace(/\b(season|part)\s*\d+\b/g, '')
    .replace(/[\s\-_~·:：,，.。!！?？'"'"()（）\[\]【】]/g, '');
}

/** 计算两个字符串的编辑距离（Levenshtein），用于相似度评分 */
function editDistance(a: string, b: string): number {
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    const curr = [i];
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      curr[j] = Math.min(
        (curr[j - 1] as number) + 1,
        (prev[j] as number) + 1,
        (prev[j - 1] as number) + cost,
      );
    }
    prev = curr;
  }
  return prev[b.length] as number;
}

/**
 * 计算标题相似度，返回 0-1。
 * 完全包含关系给高分，其余按编辑距离折算。
 */
export function titleSimilarity(a: string, b: string): number {
  const na = normalizeTitle(a);
  const nb = normalizeTitle(b);
  if (na.length === 0 || nb.length === 0) return 0;
  if (na === nb) return 1;
  if (na.includes(nb) || nb.includes(na)) {
    return 0.85 + 0.1 * (Math.min(na.length, nb.length) / Math.max(na.length, nb.length));
  }
  const distance = editDistance(na, nb);
  return Math.max(0, 1 - distance / Math.max(na.length, nb.length));
}

/**
 * 用平台时长校验候选（FR-MATCH-006）。
 * 差异超过 10% 判为不匹配，其余按差异比例线性折减置信度。
 * @returns 置信度乘数，0 表示应当剔除该候选
 */
export function durationPenalty(localSec?: number, remoteSec?: number): number {
  if (!localSec || !remoteSec || localSec <= 0 || remoteSec <= 0) return 1;
  const diff = Math.abs(localSec - remoteSec) / localSec;
  if (diff > 0.1) return 0;
  return 1 - diff * 2;
}
