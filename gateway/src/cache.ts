/**
 * 带 TTL 的 LRU 缓存（FR-GW-006）。
 * 仅进程内存实现，Redis 为后续可选增强。
 * 约束：缓存键中禁止出现任何凭证或用户标识（docs/02 §5）。
 */

interface CacheEntry<T> {
  value: T;
  expiresAt: number;
}

export class TtlCache<T> {
  private readonly store = new Map<string, CacheEntry<T>>();

  constructor(private readonly maxEntries: number) {}

  /** 读取缓存，未命中或已过期时返回 undefined，并顺带清理过期项 */
  get(key: string): T | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) {
      this.store.delete(key);
      return undefined;
    }
    // 命中后移到末尾，维持 LRU 顺序
    this.store.delete(key);
    this.store.set(key, entry);
    return entry.value;
  }

  /** 写入缓存并在超出容量时淘汰最久未使用的条目 */
  set(key: string, value: T, ttlMs: number): void {
    if (this.store.has(key)) this.store.delete(key);
    this.store.set(key, { value, expiresAt: Date.now() + ttlMs });
    while (this.store.size > this.maxEntries) {
      const oldest = this.store.keys().next();
      if (oldest.done) break;
      this.store.delete(oldest.value);
    }
  }

  /** 当前有效条目数（含尚未清理的过期项） */
  get size(): number {
    return this.store.size;
  }

  /** 清空全部缓存 */
  clear(): void {
    this.store.clear();
  }
}
