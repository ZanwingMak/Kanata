/**
 * 带 TTL 的 LRU 缓存（FR-GW-006）。
 * 约束：缓存键中禁止出现任何凭证或用户标识（docs/02 §5）。
 */

import { createHash } from 'node:crypto';
import { mkdir, readdir, readFile, rename, rm, stat, utimes, writeFile } from 'node:fs/promises';
import path from 'node:path';

interface CacheEntry<T> {
  value: T;
  expiresAt: number;
}

interface PersistentCacheEntry<T> extends CacheEntry<T> {
  key: string;
  lastAccessedAt: number;
}

export class TtlCache<T> {
  private readonly store = new Map<string, CacheEntry<T>>();

  constructor(private readonly maxEntries: number) {}

  /** 读取有效缓存，未命中或已过期时返回 undefined */
  get(key: string): T | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt <= Date.now()) return undefined;
    this.touch(key, entry);
    return entry.value;
  }

  /**
   * 读取刚过期的缓存，供上游故障时应急使用。
   * @param key 缓存键
   * @param maxStaleMs 允许超过正常 TTL 的最长时间
   * @returns 仍在应急窗口内的值，过旧或不存在时返回 undefined
   */
  getStale(key: string, maxStaleMs: number): T | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt + maxStaleMs <= Date.now()) {
      this.store.delete(key);
      return undefined;
    }
    this.touch(key, entry);
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

  /** 把命中的条目移到末尾，维持 LRU 顺序 */
  private touch(key: string, entry: CacheEntry<T>): void {
    this.store.delete(key);
    this.store.set(key, entry);
  }
}

/** 在内存 LRU 基础上按条目落盘，进程重启后可恢复故障兜底缓存。 */
export class PersistentTtlCache<T> {
  private readonly store = new Map<string, PersistentCacheEntry<T>>();
  private writeQueue: Promise<void> = Promise.resolve();

  constructor(
    private readonly maxEntries: number,
    private readonly directory: string,
    private readonly maxStaleMs: number,
    private readonly maxBytes: number,
  ) {}

  /** 创建目录、读取有效归档，并按最近访问时间恢复 LRU 顺序。 */
  async initialize(): Promise<void> {
    await mkdir(this.directory, { recursive: true });
    const names = (await readdir(this.directory)).filter((name) => name.endsWith('.json'));
    const restored: PersistentCacheEntry<T>[] = [];
    await Promise.all(
      names.map(async (name) => {
        const file = path.join(this.directory, name);
        try {
          const entry = JSON.parse(await readFile(file, 'utf8')) as PersistentCacheEntry<T>;
          if (
            typeof entry.key !== 'string'
            || typeof entry.expiresAt !== 'number'
            || entry.expiresAt + this.maxStaleMs <= Date.now()
          ) {
            await rm(file, { force: true });
            return;
          }
          const fileStat = await stat(file);
          entry.lastAccessedAt = Math.max(entry.lastAccessedAt || 0, fileStat.mtimeMs);
          restored.push(entry);
        } catch {
          await rm(file, { force: true });
        }
      }),
    );
    restored.sort((left, right) => left.lastAccessedAt - right.lastAccessedAt);
    for (const entry of restored) this.store.set(entry.key, entry);
    await this.enforceLimit();
  }

  /** 读取有效缓存，过期条目仍保留给故障旧缓存窗口使用。 */
  get(key: string): T | undefined {
    const entry = this.store.get(key);
    if (!entry || entry.expiresAt <= Date.now()) return undefined;
    this.touch(key, entry);
    return entry.value;
  }

  /** 读取仍处于允许旧缓存窗口内的条目。 */
  getStale(key: string, maxStaleMs: number): T | undefined {
    const entry = this.store.get(key);
    if (!entry) return undefined;
    if (entry.expiresAt + maxStaleMs <= Date.now()) {
      this.store.delete(key);
      void this.enqueue(async () => rm(this.filePath(key), { force: true })).catch(() => undefined);
      return undefined;
    }
    this.touch(key, entry);
    return entry.value;
  }

  /** 更新内存缓存并以临时文件加重命名的方式原子落盘。 */
  async set(key: string, value: T, ttlMs: number): Promise<void> {
    if (this.store.has(key)) this.store.delete(key);
    const entry: PersistentCacheEntry<T> = {
      key,
      value,
      expiresAt: Date.now() + ttlMs,
      lastAccessedAt: Date.now(),
    };
    this.store.set(key, entry);
    await this.enqueue(async () => {
      await mkdir(this.directory, { recursive: true });
      const target = this.filePath(key);
      const temporary = `${target}.tmp-${process.pid}-${Date.now()}`;
      await writeFile(temporary, JSON.stringify(entry), 'utf8');
      await rename(temporary, target);
      await this.enforceLimit();
    });
  }

  /** 当前已恢复到内存的缓存条目数量。 */
  get size(): number {
    return this.store.size;
  }

  /** 清空内存与磁盘中的全部持久化缓存。 */
  async clear(): Promise<void> {
    this.store.clear();
    await this.enqueue(async () => {
      await rm(this.directory, { recursive: true, force: true });
      await mkdir(this.directory, { recursive: true });
    });
  }

  /** 等待已经排队的磁盘写入结束，供服务优雅关闭。 */
  async close(): Promise<void> {
    await this.writeQueue;
  }

  /** 更新 LRU 顺序，并异步刷新文件修改时间。 */
  private touch(key: string, entry: PersistentCacheEntry<T>): void {
    entry.lastAccessedAt = Date.now();
    this.store.delete(key);
    this.store.set(key, entry);
    const now = new Date();
    void this.enqueue(async () => utimes(this.filePath(key), now, now)).catch(() => undefined);
  }

  /** 删除超出容量的最旧条目及其磁盘文件。 */
  private async enforceLimit(): Promise<void> {
    let totalBytes = await this.totalBytes();
    while (this.store.size > this.maxEntries || totalBytes > this.maxBytes) {
      const oldest = this.store.keys().next();
      if (oldest.done) return;
      const file = this.filePath(oldest.value);
      const bytes = await this.fileBytes(file);
      this.store.delete(oldest.value);
      await rm(file, { force: true });
      totalBytes -= bytes;
    }
  }

  /** 计算当前持久化条目占用的总字节数。 */
  private async totalBytes(): Promise<number> {
    const sizes = await Promise.all(
      [...this.store.keys()].map((key) => this.fileBytes(this.filePath(key))),
    );
    return sizes.reduce((sum, value) => sum + value, 0);
  }

  /** 读取单个缓存文件大小，文件不存在时返回零。 */
  private async fileBytes(file: string): Promise<number> {
    try {
      return (await stat(file)).size;
    } catch {
      return 0;
    }
  }

  /** 将缓存键哈希成不暴露平台 ID 的安全文件名。 */
  private filePath(key: string): string {
    const name = createHash('sha256').update(key).digest('hex');
    return path.join(this.directory, `${name}.json`);
  }

  /** 串行执行文件写入，避免并发裁剪与重命名互相覆盖。 */
  private enqueue(operation: () => Promise<void>): Promise<void> {
    const next = this.writeQueue.then(operation, operation);
    this.writeQueue = next.catch(() => undefined);
    return next;
  }
}
