/**
 * 适配器注册表（FR-GW-003）。
 * 新增平台只需在 createRegistry 中注册实例，路由与业务层零改动。
 */

import type { AppConfig } from '../config.js';
import type { DanmakuSourceId, SourceStatus } from '../types.js';
import { BilibiliProvider } from './bilibili/index.js';
import { BahamutProvider } from './bahamut.js';
import { CustomProvider } from './custom.js';
import { DandanplayProvider } from './dandanplay.js';
import { IqiyiProvider } from './iqiyi.js';
import { QQProvider } from './qq.js';
import type { DanmakuProvider } from './types.js';

/** 单个源的运行时状态，由探活与实际请求结果更新 */
interface RuntimeStatus {
  available: boolean;
  lastCheckedAt: number;
  lastError?: string;
  avgLatencyMs?: number;
  /** 连续失败次数，达到阈值后进入冷却（FR-GW-005） */
  consecutiveFailures: number;
  cooldownUntil: number;
}

/** 连续失败多少次后进入冷却 */
const FAILURE_THRESHOLD = 5;
/** 冷却时长（毫秒） */
const COOLDOWN_MS = 5 * 60 * 1000;

export class ProviderRegistry {
  private readonly providers = new Map<DanmakuSourceId, DanmakuProvider>();
  private readonly status = new Map<DanmakuSourceId, RuntimeStatus>();

  /** 注册一个适配器 */
  register(provider: DanmakuProvider): void {
    this.providers.set(provider.id, provider);
    this.status.set(provider.id, {
      available: true,
      lastCheckedAt: 0,
      consecutiveFailures: 0,
      cooldownUntil: 0,
    });
  }

  /** 按 ID 取适配器，不存在时返回 undefined */
  get(id: DanmakuSourceId): DanmakuProvider | undefined {
    return this.providers.get(id);
  }

  /** 全部已注册的适配器 */
  all(): DanmakuProvider[] {
    return [...this.providers.values()];
  }

  /** 判断指定来源是否已结束冷却，可以访问上游 */
  isAvailable(id: DanmakuSourceId): boolean {
    const status = this.status.get(id);
    return !status || status.cooldownUntil <= Date.now();
  }

  /**
   * 取当前可用的适配器列表。
   * 处于冷却期的源会被跳过，避免拖垮整体响应（FR-GW-005）。
   * @param wanted 期望使用的源，为空表示全部
   */
  available(wanted?: DanmakuSourceId[]): DanmakuProvider[] {
    return this.all().filter((provider) => {
      if (wanted && wanted.length > 0 && !wanted.includes(provider.id)) return false;
      return this.isAvailable(provider.id);
    });
  }

  /** 记录一次成功调用，重置失败计数并更新平均耗时 */
  markSuccess(id: DanmakuSourceId, latencyMs: number): void {
    const status = this.status.get(id);
    if (!status) return;
    status.available = true;
    status.consecutiveFailures = 0;
    status.cooldownUntil = 0;
    status.lastCheckedAt = Date.now();
    status.lastError = undefined;
    status.avgLatencyMs =
      status.avgLatencyMs === undefined
        ? latencyMs
        : Math.round(status.avgLatencyMs * 0.7 + latencyMs * 0.3);
  }

  /** 记录一次失败调用，连续失败达到阈值时进入冷却 */
  markFailure(id: DanmakuSourceId, error: string): void {
    const status = this.status.get(id);
    if (!status) return;
    status.available = false;
    status.lastCheckedAt = Date.now();
    status.lastError = error;
    status.consecutiveFailures += 1;
    if (status.consecutiveFailures >= FAILURE_THRESHOLD) {
      status.cooldownUntil = Date.now() + COOLDOWN_MS;
    }
  }

  /** 汇总各源状态，供 /kanata/v1/sources 输出（FR-GW-007） */
  snapshot(hasCredential: (id: DanmakuSourceId) => boolean): SourceStatus[] {
    return this.all().map((provider) => {
      const status = this.status.get(provider.id);
      return {
        id: provider.id,
        available: status?.available ?? true,
        requiresCredential: provider.requiresCredential,
        hasCredential: hasCredential(provider.id),
        lastCheckedAt: status?.lastCheckedAt ?? 0,
        lastError: status?.lastError,
        avgLatencyMs: status?.avgLatencyMs,
      };
    });
  }
}

/** 按配置构建注册表。新增平台在此处追加一行注册即可 */
export function createRegistry(config: AppConfig): ProviderRegistry {
  const registry = new ProviderRegistry();
  registry.register(
    new DandanplayProvider({
      baseUrl: config.dandanplay.baseUrl,
      appId: config.dandanplay.appId,
      appSecret: config.dandanplay.appSecret,
    }),
  );
  registry.register(new BilibiliProvider());
  registry.register(new BahamutProvider());
  registry.register(new IqiyiProvider());
  registry.register(new QQProvider());
  if (config.customProviders.instances.some((instance) => instance.enabled)) {
    registry.register(new CustomProvider(config.customProviders));
  }
  return registry;
}
