# Kanata Gateway

弹幕网关：把各平台的弹幕接口差异收敛在服务端，对外提供**弹弹play v2 兼容接口**与 **Kanata 扩展接口**。

## 快速开始

```bash
npm install
cp .env.example .env          # 按需修改 TOKEN 与弹弹play 密钥
TOKEN=mytoken npm run dev     # 开发模式
npm run build
node --env-file=.env dist/index.js  # 生产模式
```

弹幕正常缓存默认 12 小时；上游故障时可在额外 7 天窗口内使用旧缓存。缓存默认写入 `./data/cache`，网关重启后仍可恢复；可通过 `DANMAKU_CACHE_TTL_SEC`、`DANMAKU_STALE_TTL_SEC`、`CACHE_PERSIST` 与 `CACHE_DIR` 调整。

Docker：

```bash
docker compose up -d          # 默认监听 9321
```

## 接口

访问方式二选一：路径 Token `http://host:9321/{TOKEN}/...`，或请求头 `Authorization: Bearer {TOKEN}`。

### 弹弹play v2 兼容（可直接填进 Senplayer / EPlayerX 等播放器）

| 方法 | 路径 |
| --- | --- |
| GET | `/api/v2/search/anime?keyword=` |
| GET | `/api/v2/search/episodes?anime=&episode=` |
| POST | `/api/v2/match` |
| GET | `/api/v2/comment/:commentId` |

`commentId` 支持纯数字（弹弹play episodeId）或 `source:平台ID` 复合形式，例如 `bilibili:1339446971@1560`。

### Kanata 扩展

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/kanata/v1/health` | 存活探测（免鉴权） |
| GET | `/kanata/v1/sources` | 各源可用性 |
| POST | `/kanata/v1/resolve` | 跨平台剧集映射 |
| GET | `/kanata/v1/danmaku?refs=&offsets=&dedup=` | 统一模型弹幕，多源聚合 |
| GET | `/kanata/v1/density?refs=&duration=` | 1Hz 弹幕密度曲线 |

示例：

```bash
# 按剧名解析候选
curl -X POST http://127.0.0.1:9321/mytoken/kanata/v1/resolve \
  -H 'Content-Type: application/json' \
  -d '{"title":"葬送的芙莉莲","episode":1}'

# 多源聚合 + 去重 + 每源偏移
curl "http://127.0.0.1:9321/mytoken/kanata/v1/danmaku?refs=bilibili:1339446971@1560&offsets=bilibili:-12.5&dedup=true"
```

## 已接入的源

| 源 | 状态 | 说明 |
| --- | --- | --- |
| bilibili | ✅ 可用 | protobuf 分片，匿名可取；配置 SESSDATA 可取完整弹幕 |
| dandanplay | ⚠️ 需密钥 | 匿名访问返回 403，需申请 AppId/AppSecret |
| custom | 可选 | 通过 `CUSTOM_PROVIDERS_JSON` 配置多个弹弹play兼容实例，支持顺序回退、3 路竞速或同集聚合 |

其余平台（爱奇艺 / 腾讯 / 优酷 / 芒果）按 `docs/03-弹幕源适配矩阵.md` 在 M2 接入。

自定义实例配置示例：

```bash
CUSTOM_PROVIDER_STRATEGY=fallback
CUSTOM_PROVIDERS_JSON='[{"id":"home","name":"家庭服务","baseUrl":"http://nas:9321/mytoken","token":"","enabled":true}]'
```

实例按数组顺序确定优先级。`fallback` 遇到错误或空结果继续下一实例；`race` 每批最多并发 3 个；`aggregate` 会把同标题、同分集候选合并并对弹幕去重。实例 Token 不写日志、不进入缓存键。

## 凭证

客户端按请求携带 `X-Kanata-Credential`（base64 编码的 JSON），网关只在当次请求的内存中使用，
**不落盘、不进缓存键、不写日志**。

```json
{ "bilibili": { "SESSDATA": "...", "bili_jct": "...", "DedeUserID": "..." } }
```

## 探活

```bash
npm run health    # 输出各源可用性报告；P0 源失败时以非零码退出
```

## 新增一个平台适配器

1. 在 `src/providers/` 下实现 `DanmakuProvider`（见 `src/providers/types.ts`）；
2. 在 `src/providers/registry.ts` 的 `createRegistry` 中注册一行；
3. 更新 `docs/03-弹幕源适配矩阵.md` 的「最后验证日期」。

路由层与业务层无需任何改动。
