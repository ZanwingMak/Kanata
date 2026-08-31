import Artplayer from 'artplayer';
import artplayerPluginDanmuku, {
  type Danmu,
  type Result as DanmukuPlugin,
} from 'artplayer-plugin-danmuku';
import { useEffect, useRef } from 'react';
import type { DanmakuItem } from '../types';

interface VideoPlayerProps {
  url: string;
  title: string;
  items: DanmakuItem[];
  offset: number;
  enabled: boolean;
  onError: (message: string) => void;
}

/** 将统一弹幕模型映射为 ArtPlayer 插件格式。 */
function toPluginDanmaku(items: DanmakuItem[], offset: number): Danmu[] {
  return items.flatMap((item) => {
    const time = item.time + offset;
    if (time < 0) return [];
    const mode = item.mode === 5 ? 1 : item.mode === 4 ? 2 : 0;
    return [{
      text: item.content,
      time,
      mode,
      color: `#${item.color.toString(16).padStart(6, '0')}`,
      style: { fontSize: `${Math.max(item.fontSize, 12)}px` },
    } satisfies Danmu];
  });
}

/** 承载 ArtPlayer，并在弹幕数组或偏移变化时热更新插件。 */
export function VideoPlayer({
  url,
  title,
  items,
  offset,
  enabled,
  onError,
}: VideoPlayerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const playerRef = useRef<Artplayer | null>(null);
  const pluginRef = useRef<DanmukuPlugin | null>(null);
  const latestDanmakuRef = useRef<Danmu[]>([]);

  latestDanmakuRef.current = toPluginDanmaku(items, offset);

  useEffect(() => {
    if (!containerRef.current) return undefined;
    const player = new Artplayer({
      container: containerRef.current,
      url,
      theme: '#7f9a78',
      autoplay: false,
      hotkey: true,
      pip: true,
      setting: true,
      playbackRate: true,
      aspectRatio: true,
      fullscreen: true,
      fullscreenWeb: true,
      miniProgressBar: true,
      playsInline: true,
      plugins: [
        artplayerPluginDanmuku({
          danmuku: latestDanmakuRef.current,
          speed: 6,
          opacity: 0.86,
          fontSize: '100%',
          antiOverlap: true,
          synchronousPlayback: true,
          emitter: false,
          visible: enabled,
        }),
      ],
    });
    playerRef.current = player;
    player.on('ready', () => {
      pluginRef.current = player.plugins.artplayerPluginDanmuku as DanmukuPlugin;
      void pluginRef.current.load(latestDanmakuRef.current);
    });
    player.on('error', () => onError('浏览器无法解码该视频，请改用 Apple 客户端或兼容格式'));
    return () => {
      pluginRef.current = null;
      playerRef.current = null;
      player.destroy(false);
    };
  }, [onError, title, url]);

  useEffect(() => {
    if (!pluginRef.current) return;
    void pluginRef.current.load(latestDanmakuRef.current);
  }, [items, offset]);

  useEffect(() => {
    if (!pluginRef.current) return;
    if (enabled) pluginRef.current.show(); else pluginRef.current.hide();
  }, [enabled]);

  return (
    <div
      ref={containerRef}
      className="h-full min-h-[280px] w-full"
      aria-label={`${title} 播放器`}
    />
  );
}
