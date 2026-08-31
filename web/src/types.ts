export type DanmakuSourceId =
  | 'dandanplay'
  | 'bilibili'
  | 'iqiyi'
  | 'qq'
  | 'youku'
  | 'mgtv'
  | 'bahamut'
  | 'local'
  | 'custom';

export type DanmakuMode = 1 | 4 | 5 | 6;

export interface DanmakuItem {
  id: string;
  time: number;
  mode: DanmakuMode;
  fontSize: number;
  color: number;
  content: string;
  source: DanmakuSourceId;
  senderHash?: string;
  createdAt?: number;
  weight?: number;
  dupCount?: number;
}

export interface MediaFingerprint {
  fileName: string;
  fileHash: string;
  fileSize: number;
  videoDuration: number;
}

export interface ProviderCandidate {
  source: DanmakuSourceId;
  sourceInstanceId?: string;
  sourceInstanceName?: string;
  platformEpisodeId: string;
  title: string;
  episodeTitle?: string;
  duration?: number;
  confidence: number;
  danmakuCount?: number;
}

export interface ResolveRequest {
  title: string;
  season?: number;
  episode?: number;
  duration?: number;
  fingerprint?: MediaFingerprint;
}

export interface ResolveResponse {
  candidates: ProviderCandidate[];
  degraded: DanmakuSourceId[];
}

export interface DanmakuResponse {
  items: DanmakuItem[];
  stats: {
    total: number;
    bySource: Partial<Record<DanmakuSourceId, number>>;
    deduped: number;
    elapsedMs: number;
  };
  degraded: Array<{ source: DanmakuSourceId; reason: string; code: number }>;
}

export interface PreparedVideo {
  file: File;
  url: string;
  duration: number;
  title: string;
  season?: number;
  episode?: number;
  fingerprint: MediaFingerprint;
}
