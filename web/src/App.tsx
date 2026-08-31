import {
  CheckCircle,
  Database,
  FileArrowUp,
  FilmSlate,
  MagnifyingGlass,
  SlidersHorizontal,
  Trash,
  WifiHigh,
  WifiSlash,
} from '@phosphor-icons/react';
import {
  type ChangeEvent,
  type FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { checkGateway, fetchDanmaku, resolveDanmaku } from './api';
import { VideoPlayer } from './components/VideoPlayer';
import {
  clearWebDanmakuCache,
  loadWebDanmakuCache,
  saveWebDanmakuCache,
  webDanmakuCacheKey,
} from './danmakuCache';
import { prepareVideo } from './fingerprint';
import { mergeDanmaku, parseLocalDanmaku } from './localDanmaku';
import type { DanmakuItem, PreparedVideo, ProviderCandidate } from './types';

type WorkState = 'idle' | 'preparing' | 'matching' | 'loading' | 'ready' | 'error';

/** 返回候选实际命中的来源或实例名称。 */
function sourceName(candidate: ProviderCandidate): string {
  const names: Record<string, string> = {
    dandanplay: '弹弹play开放弹幕网络',
    bilibili: '哔哩哔哩',
    custom: '自定义弹幕源',
  };
  return candidate.sourceInstanceName ?? names[candidate.source] ?? candidate.source;
}

/** Kanata Web 主界面：本地视频、网关匹配、本地弹幕与播放器状态编排。 */
export function App() {
  const [gatewayURL, setGatewayURL] = useState(
    () => localStorage.getItem('kanata.gatewayURL') ?? 'http://127.0.0.1:9321',
  );
  const [gatewayToken, setGatewayToken] = useState('');
  const [gatewayReachable, setGatewayReachable] = useState<boolean | null>(null);
  const [video, setVideo] = useState<PreparedVideo | null>(null);
  const [onlineItems, setOnlineItems] = useState<DanmakuItem[]>([]);
  const [localItems, setLocalItems] = useState<DanmakuItem[]>([]);
  const [candidates, setCandidates] = useState<ProviderCandidate[]>([]);
  const [binding, setBinding] = useState<ProviderCandidate | null>(null);
  const [keyword, setKeyword] = useState('');
  const [offset, setOffset] = useState(0);
  const [danmakuEnabled, setDanmakuEnabled] = useState(true);
  const [workState, setWorkState] = useState<WorkState>('idle');
  const [status, setStatus] = useState('选择一个本地视频开始');
  const [error, setError] = useState<string | null>(null);
  const videoInputRef = useRef<HTMLInputElement>(null);
  const danmakuInputRef = useRef<HTMLInputElement>(null);

  const mergedItems = useMemo(
    () => mergeDanmaku(localItems, onlineItems),
    [localItems, onlineItems],
  );

  useEffect(() => {
    localStorage.setItem('kanata.gatewayURL', gatewayURL.trim());
  }, [gatewayURL]);

  useEffect(() => {
    const currentURL = video?.url;
    return () => {
      if (currentURL) URL.revokeObjectURL(currentURL);
    };
  }, [video?.url]);

  /** 记录播放器自身的解码错误，避免黑屏无提示。 */
  const handlePlayerError = useCallback((message: string) => {
    setError(message);
    setWorkState('error');
  }, []);

  /** 拉取候选弹幕并更新播放器，不影响已经导入的本地弹幕。 */
  const loadCandidate = useCallback(async (
    candidate: ProviderCandidate,
    explicitCacheKey?: string,
  ) => {
    setWorkState('loading');
    setStatus(`正在加载 ${sourceName(candidate)} 弹幕`);
    setError(null);
    try {
      const response = await fetchDanmaku(gatewayURL, gatewayToken, candidate);
      setOnlineItems(response.items);
      setBinding(candidate);
      const cacheKey = explicitCacheKey ?? (video ? webDanmakuCacheKey(video) : undefined);
      if (cacheKey) {
        await saveWebDanmakuCache(cacheKey, candidate, response.items).catch(() => undefined);
      }
      setWorkState('ready');
      const fallback = response.degraded.length > 0 ? ' · 部分来源已降级' : '';
      setStatus(`${response.items.length} 条在线弹幕 · ${response.stats.elapsedMs}ms${fallback}`);
    } catch (caught) {
      setWorkState('error');
      setError(caught instanceof Error ? caught.message : '弹幕加载失败');
    }
  }, [gatewayToken, gatewayURL, video]);

  /** 使用文件指纹和标题自动匹配弹幕，低置信候选交给用户确认。 */
  const matchPreparedVideo = useCallback(async (prepared: PreparedVideo) => {
    /** 在线匹配不可用时恢复当前视频最近保存的弹幕。 */
    const restoreCache = async (): Promise<boolean> => {
      const archive = await loadWebDanmakuCache(webDanmakuCacheKey(prepared)).catch(() => undefined);
      if (!archive) return false;
      setOnlineItems(archive.items);
      setBinding(archive.candidate);
      setWorkState('ready');
      const ageHours = Math.max(0, Math.floor((Date.now() - archive.savedAt) / 3_600_000));
      setStatus(`已恢复 ${archive.items.length} 条浏览器缓存弹幕 · ${ageHours} 小时前`);
      return true;
    };

    if (!gatewayURL.trim()) {
      if (!await restoreCache()) {
        setWorkState('ready');
        setStatus('未配置网关，当前可离线播放或导入本地弹幕');
      }
      return;
    }
    setWorkState('matching');
    setStatus('正在计算并匹配弹幕');
    try {
      const response = await resolveDanmaku(gatewayURL, gatewayToken, {
        title: prepared.title,
        season: prepared.season,
        episode: prepared.episode,
        duration: prepared.duration,
        fingerprint: prepared.fingerprint,
      });
      setCandidates(response.candidates);
      const best = response.candidates[0];
      if (best && best.confidence >= 0.9) {
        await loadCandidate(best, webDanmakuCacheKey(prepared));
      } else {
        if (!await restoreCache()) {
          setWorkState('ready');
          setStatus(best
            ? `找到 ${response.candidates.length} 个候选，请确认来源`
            : '没有自动匹配结果，请修改关键词搜索');
        }
      }
    } catch (caught) {
      if (!await restoreCache()) {
        setWorkState('error');
        setError(caught instanceof Error ? caught.message : '匹配失败');
        setStatus('视频仍可离线播放，也可以导入本地弹幕');
      }
    }
  }, [gatewayToken, gatewayURL, loadCandidate]);

  /** 处理本地视频选择，文件只生成浏览器 Blob URL，不上传服务器。 */
  async function handleVideoSelection(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    setWorkState('preparing');
    setStatus('正在读取视频元数据与前 16MB 指纹');
    setError(null);
    setOnlineItems([]);
    setLocalItems([]);
    setCandidates([]);
    setBinding(null);
    try {
      const prepared = await prepareVideo(file);
      setVideo(prepared);
      setKeyword(prepared.title);
      await matchPreparedVideo(prepared);
    } catch (caught) {
      setWorkState('error');
      setError(caught instanceof Error ? caught.message : '无法打开视频');
    }
  }

  /** 导入浏览器本地弹幕并立即与在线弹幕合并。 */
  async function handleDanmakuSelection(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    try {
      const items = await parseLocalDanmaku(file);
      setLocalItems(items);
      setError(null);
      setWorkState('ready');
      setStatus(`已导入 ${items.length} 条本地弹幕${onlineItems.length > 0 ? '，并与在线弹幕合并' : ''}`);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : '本地弹幕导入失败');
    }
  }

  /** 按用户输入的关键词重新获取候选列表。 */
  async function handleSearch(event: FormEvent) {
    event.preventDefault();
    if (!keyword.trim()) return;
    setWorkState('matching');
    setError(null);
    try {
      const response = await resolveDanmaku(gatewayURL, gatewayToken, {
        title: keyword.trim(),
        episode: video?.episode,
        duration: video?.duration,
      });
      setCandidates(response.candidates);
      setWorkState('ready');
      setStatus(`找到 ${response.candidates.length} 个候选`);
    } catch (caught) {
      setWorkState('error');
      setError(caught instanceof Error ? caught.message : '搜索失败');
    }
  }

  /** 从浏览器验证网关地址、Token 与 CORS 配置。 */
  async function handleGatewayCheck() {
    setGatewayReachable(null);
    setError(null);
    try {
      setGatewayReachable(await checkGateway(gatewayURL, gatewayToken));
    } catch (caught) {
      setGatewayReachable(false);
      setError(caught instanceof Error ? caught.message : '网关连接失败');
    }
  }

  /** 经用户确认后清空 IndexedDB 在线弹幕缓存。 */
  async function handleCacheClear() {
    if (!window.confirm('清空浏览器中保存的全部在线弹幕缓存？')) return;
    try {
      await clearWebDanmakuCache();
      setStatus('浏览器在线弹幕缓存已清空；当前播放内容不受影响');
      setError(null);
    } catch {
      setError('无法清理浏览器弹幕缓存');
    }
  }

  return (
    <main className="min-h-[100dvh] bg-[#111412] text-[#f1f3ee]">
      <div className="mx-auto grid min-h-[100dvh] max-w-[1600px] lg:grid-cols-[320px_minmax(0,1fr)]">
        <aside className="border-b border-white/10 bg-[#171a17] p-5 lg:border-b-0 lg:border-r lg:p-7">
          <div className="mb-8 flex items-center gap-3">
            <span className="grid h-11 w-11 place-items-center rounded-2xl bg-[#7f9a78] text-[#111412]">
              <FilmSlate size={25} weight="fill" />
            </span>
            <div>
              <h1 className="text-xl font-semibold tracking-tight">Kanata</h1>
              <p className="text-xs text-[#9ca69a]">自有片源，全网弹幕</p>
            </div>
          </div>

          <section className="space-y-4" aria-labelledby="gateway-heading">
            <div className="flex items-center gap-2 text-sm font-medium" id="gateway-heading">
              <SlidersHorizontal size={18} />
              弹幕网关
            </div>
            <label className="block space-y-2 text-xs text-[#b6beb3]">
              <span>网关地址</span>
              <input
                value={gatewayURL}
                onChange={(event) => setGatewayURL(event.target.value)}
                className="field"
                inputMode="url"
                placeholder="http://127.0.0.1:9321"
              />
            </label>
            <label className="block space-y-2 text-xs text-[#b6beb3]">
              <span>访问令牌</span>
              <input
                value={gatewayToken}
                onChange={(event) => setGatewayToken(event.target.value)}
                className="field"
                type="password"
                autoComplete="off"
                placeholder="仅保存在当前页面内存"
              />
            </label>
            <button type="button" className="secondary-button w-full" onClick={handleGatewayCheck}>
              {gatewayReachable === true
                ? <CheckCircle size={18} weight="fill" />
                : gatewayReachable === false
                  ? <WifiSlash size={18} />
                  : <WifiHigh size={18} />}
              {gatewayReachable === true ? '连接正常' : gatewayReachable === false ? '连接失败' : '测试连接'}
            </button>
            <p className="text-xs leading-relaxed text-[#7f897d]">
              Token 不写入浏览器存储；本地视频始终留在当前设备。
            </p>
          </section>

          <section className="mt-8 border-t border-white/10 pt-6">
            <div className="mb-3 flex items-center gap-2 text-sm font-medium">
              <Database size={18} />
              当前弹幕
            </div>
            <dl className="space-y-2 text-xs text-[#9ca69a]">
              <div className="flex justify-between"><dt>在线</dt><dd>{onlineItems.length} 条</dd></div>
              <div className="flex justify-between"><dt>本地</dt><dd>{localItems.length} 条</dd></div>
              <div className="flex justify-between"><dt>合并后</dt><dd>{mergedItems.length} 条</dd></div>
            </dl>
            {binding && (
              <p className="mt-4 border-l-2 border-[#7f9a78] pl-3 text-xs leading-relaxed text-[#cbd1c8]">
                {sourceName(binding)}<br />
                <span className="text-[#7f897d]">{binding.episodeTitle || binding.title}</span>
              </p>
            )}
            <button
              type="button"
              className="text-button mt-4 inline-flex items-center gap-2"
              onClick={() => void handleCacheClear()}
            >
              <Trash size={16} />
              清理浏览器弹幕缓存
            </button>
          </section>
        </aside>

        <section className="min-w-0 p-4 md:p-7 lg:p-10">
          <header className="mb-6 flex flex-wrap items-center justify-between gap-4">
            <div className="min-w-0">
              <p className="text-xs uppercase tracking-[0.18em] text-[#7f9a78]">Web Player</p>
              <h2 className="mt-1 truncate text-2xl font-semibold tracking-tight md:text-3xl">
                {video?.file.name ?? '打开你自己的视频'}
              </h2>
            </div>
            <div className="flex flex-wrap gap-2">
              <button type="button" className="secondary-button" onClick={() => videoInputRef.current?.click()}>
                <FileArrowUp size={18} />
                选择视频
              </button>
              <button
                type="button"
                className="secondary-button"
                disabled={!video}
                onClick={() => danmakuInputRef.current?.click()}
              >
                <Database size={18} />
                导入弹幕
              </button>
            </div>
          </header>

          <input ref={videoInputRef} className="hidden" type="file" accept="video/*,.mkv,.ts,.webm" onChange={handleVideoSelection} />
          <input ref={danmakuInputRef} className="hidden" type="file" accept=".xml,.json,.ass" onChange={handleDanmakuSelection} />

          <div className="overflow-hidden rounded-[24px] border border-white/10 bg-[#090b09] shadow-2xl shadow-black/30">
            {video ? (
              <div className="aspect-video min-h-[280px]">
                <VideoPlayer
                  url={video.url}
                  title={video.title}
                  items={mergedItems}
                  offset={offset}
                  enabled={danmakuEnabled}
                  onError={handlePlayerError}
                />
              </div>
            ) : (
              <button
                type="button"
                className="group grid aspect-video min-h-[360px] w-full place-items-center px-6 text-left"
                onClick={() => videoInputRef.current?.click()}
              >
                <span className="max-w-lg">
                  <span className="mb-5 grid h-16 w-16 place-items-center rounded-[22px] border border-white/10 bg-white/5 transition-transform group-active:scale-[0.98]">
                    <FilmSlate size={30} />
                  </span>
                  <span className="block text-2xl font-semibold tracking-tight">视频不上传，直接在浏览器播放</span>
                  <span className="mt-3 block max-w-[52ch] text-sm leading-relaxed text-[#8f998d]">
                    选择本地文件后，Kanata 只读取前 16MB 计算匹配指纹，再从你的网关获取对应弹幕。
                  </span>
                </span>
              </button>
            )}
          </div>

          <div className="mt-4 flex flex-wrap items-center gap-3 border-b border-white/10 pb-5">
            <button
              type="button"
              className={`compact-toggle ${danmakuEnabled ? 'is-active' : ''}`}
              onClick={() => setDanmakuEnabled((value) => !value)}
            >
              弹幕{danmakuEnabled ? '开启' : '关闭'}
            </button>
            <div className="flex min-w-[260px] flex-1 items-center gap-3 text-xs text-[#9ca69a]">
              <label className="whitespace-nowrap" htmlFor="danmaku-offset">
                偏移 {offset >= 0 ? '+' : ''}{offset.toFixed(1)}s
              </label>
              <input
                id="danmaku-offset"
                className="accent-[#7f9a78]"
                type="range"
                min="-120"
                max="120"
                step="0.5"
                value={offset}
                onChange={(event) => setOffset(Number(event.target.value))}
              />
              <button type="button" className="text-button" onClick={() => setOffset(0)}>归零</button>
            </div>
          </div>

          <div className="mt-6 grid gap-6 xl:grid-cols-[minmax(0,1fr)_360px]">
            <section aria-labelledby="status-heading">
              <h3 id="status-heading" className="mb-3 text-sm font-medium">运行状态</h3>
              <div className="min-h-20 border-l-2 border-[#7f9a78] bg-white/[0.025] px-4 py-3" aria-live="polite">
                {(workState === 'preparing' || workState === 'matching' || workState === 'loading') && (
                  <div className="mb-2 h-1 overflow-hidden rounded-full bg-white/5">
                    <div className="loading-line h-full w-1/2 bg-[#7f9a78]" />
                  </div>
                )}
                <p className="text-sm text-[#cbd1c8]">{status}</p>
                {error && <p className="mt-2 text-sm text-[#d69a82]">{error}</p>}
              </div>

              {video && (
                <form className="mt-6" onSubmit={handleSearch}>
                  <label className="mb-2 block text-xs text-[#9ca69a]" htmlFor="keyword">手动重新匹配</label>
                  <div className="flex gap-2">
                    <input id="keyword" className="field" value={keyword} onChange={(event) => setKeyword(event.target.value)} />
                    <button type="submit" className="primary-button" disabled={!keyword.trim()}>
                      <MagnifyingGlass size={18} />
                      搜索
                    </button>
                  </div>
                </form>
              )}
            </section>

            <section aria-labelledby="candidate-heading">
              <div className="mb-3 flex items-center justify-between">
                <h3 id="candidate-heading" className="text-sm font-medium">匹配候选</h3>
                <span className="text-xs text-[#7f897d]">{candidates.length} 个</span>
              </div>
              <div className="max-h-72 divide-y divide-white/10 overflow-y-auto border-y border-white/10">
                {candidates.length === 0 ? (
                  <p className="py-8 text-center text-sm text-[#7f897d]">自动匹配或搜索后显示候选</p>
                ) : candidates.map((candidate) => (
                  <button
                    key={`${candidate.source}:${candidate.platformEpisodeId}`}
                    type="button"
                    className="candidate-row"
                    onClick={() => void loadCandidate(candidate)}
                  >
                    <span className="min-w-0">
                      <span className="block truncate text-sm text-[#eef1eb]">{candidate.title}</span>
                      <span className="mt-1 block truncate text-xs text-[#7f897d]">
                        {sourceName(candidate)} · {candidate.episodeTitle || '未标注分集'}
                      </span>
                    </span>
                    <span className="text-xs tabular-nums text-[#aabcaa]">{Math.round(candidate.confidence * 100)}%</span>
                  </button>
                ))}
              </div>
            </section>
          </div>
        </section>
      </div>
    </main>
  );
}
