/**
 * 网关启动入口。
 */

import { loadConfig } from './config.js';
import { createServer, VERSION } from './server.js';

/** 注册 SIGINT/SIGTERM 处理，在退出前停止接收请求并等待缓存写入。 */
function installShutdownHandlers(app: Awaited<ReturnType<typeof createServer>>): void {
  let closing = false;
  const shutdown = async (signal: string) => {
    if (closing) return;
    closing = true;
    app.log.info({ signal }, '正在优雅关闭网关');
    await app.close();
  };
  process.once('SIGINT', () => void shutdown('SIGINT'));
  process.once('SIGTERM', () => void shutdown('SIGTERM'));
}

/** 启动 HTTP 服务并输出访问地址；启动失败时以非零码退出 */
async function main(): Promise<void> {
  const config = loadConfig();

  // 代理配置依赖 Node 的环境变量代理支持，需配合 NODE_USE_ENV_PROXY=1 启动
  if (config.proxyUrl) {
    process.env.HTTP_PROXY = config.proxyUrl;
    process.env.HTTPS_PROXY = config.proxyUrl;
  }

  const app = await createServer(config);
  await app.listen({ port: config.port, host: config.host });
  installShutdownHandlers(app);

  app.log.info(
    `Kanata Gateway ${VERSION} 已启动，接口地址 http://${config.host}:${config.port}/${config.token}`,
  );
  if (config.token === '87654321') {
    app.log.warn('正在使用默认 Token，公网部署前请务必修改 TOKEN 环境变量');
  }
}

main().catch((err) => {
  console.error('网关启动失败', err);
  process.exit(1);
});
