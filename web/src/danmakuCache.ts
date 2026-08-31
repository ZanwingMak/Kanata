import type { DanmakuItem, PreparedVideo, ProviderCandidate } from './types';

const DATABASE_NAME = 'kanata-web';
const STORE_NAME = 'online-danmaku';
const MAX_ENTRIES = 50;
const MAX_AGE_MS = 8 * 24 * 60 * 60 * 1000;

export interface WebDanmakuArchive {
  key: string;
  candidate: ProviderCandidate;
  items: DanmakuItem[];
  savedAt: number;
}

/** 用指纹和文件大小生成不包含文件名的浏览器缓存键。 */
export function webDanmakuCacheKey(video: PreparedVideo): string {
  return `${video.fingerprint.fileHash}:${video.fingerprint.fileSize}`;
}

/** 打开并按需创建在线弹幕对象仓库。 */
function openDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DATABASE_NAME, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(STORE_NAME)) {
        request.result.createObjectStore(STORE_NAME, { keyPath: 'key' });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('无法打开浏览器弹幕缓存'));
  });
}

/** 等待 IndexedDB 事务完成，并把异常转换为 Promise 拒绝。 */
function waitForTransaction(transaction: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error ?? new Error('浏览器缓存事务失败'));
    transaction.onabort = () => reject(transaction.error ?? new Error('浏览器缓存事务已取消'));
  });
}

/** 从浏览器持久缓存恢复未超过兜底窗口的在线弹幕。 */
export async function loadWebDanmakuCache(key: string): Promise<WebDanmakuArchive | undefined> {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(STORE_NAME, 'readonly');
    const request = transaction.objectStore(STORE_NAME).get(key);
    const archive = await new Promise<WebDanmakuArchive | undefined>((resolve, reject) => {
      request.onsuccess = () => resolve(request.result as WebDanmakuArchive | undefined);
      request.onerror = () => reject(request.error ?? new Error('读取浏览器弹幕缓存失败'));
    });
    await waitForTransaction(transaction);
    if (!archive) return undefined;
    if (archive.savedAt + MAX_AGE_MS > Date.now()) return archive;
    await removeWebDanmakuCache(key);
    return undefined;
  } finally {
    database.close();
  }
}

/** 保存在线弹幕并裁剪为最近使用的 50 个视频。 */
export async function saveWebDanmakuCache(
  key: string,
  candidate: ProviderCandidate,
  items: DanmakuItem[],
): Promise<void> {
  const database = await openDatabase();
  try {
    const write = database.transaction(STORE_NAME, 'readwrite');
    write.objectStore(STORE_NAME).put({ key, candidate, items, savedAt: Date.now() } satisfies WebDanmakuArchive);
    await waitForTransaction(write);

    const read = database.transaction(STORE_NAME, 'readonly');
    const request = read.objectStore(STORE_NAME).getAll();
    const archives = await new Promise<WebDanmakuArchive[]>((resolve, reject) => {
      request.onsuccess = () => resolve(request.result as WebDanmakuArchive[]);
      request.onerror = () => reject(request.error ?? new Error('枚举浏览器弹幕缓存失败'));
    });
    await waitForTransaction(read);
    const expiredKeys = archives
      .sort((left, right) => right.savedAt - left.savedAt)
      .slice(MAX_ENTRIES)
      .map((archive) => archive.key);
    if (expiredKeys.length === 0) return;
    const trim = database.transaction(STORE_NAME, 'readwrite');
    const store = trim.objectStore(STORE_NAME);
    expiredKeys.forEach((expiredKey) => store.delete(expiredKey));
    await waitForTransaction(trim);
  } finally {
    database.close();
  }
}

/** 清空浏览器中的全部在线弹幕归档，不影响当前页面已加载内容。 */
export async function clearWebDanmakuCache(): Promise<void> {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(STORE_NAME, 'readwrite');
    transaction.objectStore(STORE_NAME).clear();
    await waitForTransaction(transaction);
  } finally {
    database.close();
  }
}

/** 删除一个过期或用户不再需要的浏览器弹幕归档。 */
async function removeWebDanmakuCache(key: string): Promise<void> {
  const database = await openDatabase();
  try {
    const transaction = database.transaction(STORE_NAME, 'readwrite');
    transaction.objectStore(STORE_NAME).delete(key);
    await waitForTransaction(transaction);
  } finally {
    database.close();
  }
}
