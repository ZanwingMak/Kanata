import SparkMD5 from 'spark-md5';
import type { PreparedVideo } from './types';

const HASH_BYTES = 16 * 1024 * 1024;

/** 从常见文件名规则提取标题、季度和集数。 */
function parseFileName(fileName: string): { title: string; season?: number; episode?: number } {
  const base = fileName.replace(/\.[^.]+$/, '');
  const seasonEpisode = base.match(/[Ss](\d{1,2})[ ._-]*[Ee](\d{1,4})/);
  const episode = seasonEpisode ?? base.match(/(?:EP?|第)\s*(\d{1,4})(?:集|话|話)?/i);
  const season = seasonEpisode ? Number(seasonEpisode[1]) : undefined;
  const episodeNumber = seasonEpisode
    ? Number(seasonEpisode[2])
    : episode
      ? Number(episode[1])
      : undefined;
  const title = base
    .replace(/\[[^\]]*]|【[^】]*】|\([^)]*\)/g, ' ')
    .replace(/[Ss]\d{1,2}[ ._-]*[Ee]\d{1,4}/g, ' ')
    .replace(/(?:EP?|第)\s*\d{1,4}(?:集|话|話)?/gi, ' ')
    .replace(/[._-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return { title: title || base, season, episode: episodeNumber };
}

/** 使用临时 video 元素探测浏览器可解码的视频时长。 */
function probeDuration(url: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const video = document.createElement('video');
    video.preload = 'metadata';
    video.onloadedmetadata = () => {
      const duration = Number.isFinite(video.duration) ? video.duration : 0;
      video.removeAttribute('src');
      video.load();
      resolve(duration);
    };
    video.onerror = () => reject(new Error('浏览器无法读取该视频格式，请改用 Apple 客户端'));
    video.src = url;
  });
}

/** 读取文件前 16MB 计算 MD5，并生成可直接提交网关的准备结果。 */
export async function prepareVideo(file: File): Promise<PreparedVideo> {
  const url = URL.createObjectURL(file);
  try {
    const [buffer, duration] = await Promise.all([
      file.slice(0, HASH_BYTES).arrayBuffer(),
      probeDuration(url),
    ]);
    const parsed = parseFileName(file.name);
    return {
      file,
      url,
      duration,
      title: parsed.title,
      season: parsed.season,
      episode: parsed.episode,
      fingerprint: {
        fileName: file.name.replace(/\.[^.]+$/, ''),
        fileHash: SparkMD5.ArrayBuffer.hash(buffer),
        fileSize: file.size,
        videoDuration: Math.round(duration),
      },
    };
  } catch (error) {
    URL.revokeObjectURL(url);
    throw error;
  }
}
