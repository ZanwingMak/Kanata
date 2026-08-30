/**
 * 弹幕源探活脚本（docs/05 §7）。
 * CI 每日执行，产出各源可用性报告；任一 P0 源失败时以非零码退出，用于阻断发版。
 *
 * 用法：npm run health
 */

import { loadConfig } from '../src/config.js';
import { createFetch } from '../src/http.js';
import { createConsoleLogger } from '../src/logger.js';
import { createRegistry } from '../src/providers/registry.js';
import type { ProviderContext } from '../src/providers/types.js';

/** P0 源：探活失败会阻断发版 */
const CRITICAL_SOURCES = new Set(['bilibili']);

/** 依次探活全部已注册的源并打印报告 */
async function main(): Promise<void> {
  const config = loadConfig();
  const registry = createRegistry(config);
  const logger = createConsoleLogger('health');
  const ctx: ProviderContext = {
    fetch: createFetch(config.requestTimeoutMs, logger),
    logger,
    signal: AbortSignal.timeout(120_000),
  };

  const rows: string[] = [];
  let criticalFailed = false;

  for (const provider of registry.all()) {
    const result = await provider.healthCheck(ctx);
    const status = result.ok ? 'OK' : 'FAIL';
    rows.push(
      `| ${provider.id} | ${status} | ${result.latencyMs}ms | ${result.count ?? '-'} | ${result.error ?? ''} |`,
    );
    if (!result.ok && CRITICAL_SOURCES.has(provider.id)) criticalFailed = true;
  }

  console.log(`\n# 弹幕源探活报告 ${new Date().toISOString()}\n`);
  console.log('| 源 | 状态 | 耗时 | 条数 | 错误 |');
  console.log('| --- | --- | --- | --- | --- |');
  for (const row of rows) console.log(row);
  console.log('');

  if (criticalFailed) {
    console.error('P0 源探活失败，需要修复适配器后才能发版');
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('探活执行失败', err);
  process.exit(1);
});
