# Kanata — 跨端弹幕播放器

> 项目代号 **Kanata**（可替换）。一款支持 **iOS / iPadOS / tvOS / Web** 的自有片源播放器：
> 用户导入自己的视频资源（本地文件、NAS、媒体库服务器），应用自动从 B 站 / 爱奇艺 / 腾讯 / 优酷 / 芒果 / 弹弹play
> 等来源匹配并拉取同一集内容的弹幕，边播边显示。定位类似「弹弹play」，但覆盖 Apple 全端 + Web。

---

## 0. 本仓库是什么

这是**方案与文档仓库**（当前阶段无代码）。所有文档按「可被不同 AI 接手」的标准编写：

- 每条需求有唯一 ID（`FR-*` / `NFR-*`），每条测试用例有唯一 ID（`TC-*`）并**反向映射需求 ID**；
- 所有跨模块交互都以**接口契约**（JSON Schema / TypeScript 类型 / HTTP 端点表）定义，而非自然语言描述；
- 所有待定事项集中在 `#决策点` 表，不散落在正文；
- 任何 AI 接手前，**先读 `CLAUDE.md`**（项目级硬约束），再读本文件的文档索引。

## 1. 文档索引

| 文件 | 内容 | 主要读者 |
| --- | --- | --- |
| [`CLAUDE.md`](CLAUDE.md) | 项目级硬约束、命名规范、AI 协作规则 | 所有 AI / 开发者 |
| [`docs/00-方案总览.md`](docs/00-方案总览.md) | 需求扩展后的完整方案、技术选型、里程碑 | 产品 / 架构 |
| [`docs/01-需求文档-PRD.md`](docs/01-需求文档-PRD.md) | 完整功能需求（FR）与非功能需求（NFR） | 开发 / 测试 |
| [`docs/02-架构与接口契约.md`](docs/02-架构与接口契约.md) | 分层架构、统一数据模型、网关 API、SDK 接口 | 开发 |
| [`docs/03-弹幕源适配矩阵.md`](docs/03-弹幕源适配矩阵.md) | 各平台弹幕获取方式、参数、凭证、登录流程 | 后端 / 适配器开发 |
| [`docs/04-视频源接入矩阵.md`](docs/04-视频源接入矩阵.md) | 本地 / NAS / 媒体库 / 直链 的接入方式与端上差异 | 客户端开发 |
| [`docs/05-测试文档.md`](docs/05-测试文档.md) | 测试策略、用例库、性能阈值、源探活自动化 | 测试 / CI |
| [`docs/06-Skill评估与AI协作.md`](docs/06-Skill评估与AI协作.md) | 需要哪些 Skill、缺口、AI 分工与交接协议 | 编排者 |
| [`docs/07-合规与风险.md`](docs/07-合规与风险.md) | 法务红线、平台协议、分发策略、风险登记册 | 全员 |
| [`docs/08-播放器功能基准.md`](docs/08-播放器功能基准.md) | 市面播放器对标、视频/音频/字幕/弹幕完整能力清单 | 产品 / 客户端开发 |

## 2. 一句话架构

```
┌──────────── 客户端（同一套契约） ────────────┐
│  iOS / iPadOS / tvOS (Swift, 共享 Core)     │
│  Web (TypeScript + React + ArtPlayer)      │
└───────────────┬────────────────────────────┘
                │  Kanata Gateway API（弹弹play v2 兼容 + 扩展）
┌───────────────▼────────────────────────────┐
│  Danmaku Gateway（Node/TS，可自托管 Docker） │
│  ├─ 识别层：文件 hash / 文件名 / TMDB 归一   │
│  ├─ 适配器：bilibili / iqiyi / qq / youku…  │
│  ├─ 归一化：统一弹幕模型 + 时轴对齐          │
│  └─ 缓存：内存 + Redis（可选）+ 客户端本地   │
└────────────────────────────────────────────┘
```

**关键设计**：所有平台差异（接口逆向、签名、分片、加解压）收敛在 **网关**，客户端永远只面对一套稳定契约。
平台接口一改，只需更新网关，客户端不必发版。

## 3. 决策点（需用户确认，未确认则按「推荐值」执行）

| ID | 决策 | 推荐值 | 影响面 |
| --- | --- | --- | --- |
| DEC-01 | 网关部署形态 | **双模式**：默认内置「用户自填 API 地址」，同时提供官方 Docker 镜像供自托管 | 架构 / 合规 / 成本 |
| DEC-02 | 分发渠道 | App Store 上架版本**不内置**平台抓取逻辑（只带弹弹play 官方源 + 自定义 API 入口）；自托管网关承载全部平台适配器 | 合规 / 功能可见性 |
| DEC-03 | 客户端技术栈 | Apple 端原生 Swift/SwiftUI 多平台；Web 独立 TS 栈（**不用** Flutter/RN，tvOS 支持不足） | 全部 |
| DEC-04 | 播放内核 | 双内核：AVPlayer（原生格式，享硬解/PiP/AirPlay）+ VLCKit（MKV/特殊编码兜底） | 客户端 |
| DEC-05 | 凭证存储位置 | 存客户端 Keychain，按请求加密透传给网关；网关**默认不落盘**用户凭证 | 安全 / 合规 |
| DEC-06 | 是否支持发送弹幕 | 一期只读（不回传弹幕到第三方平台） | 合规 |

## 4. 红线（不做）

- ❌ 不解析 / 不下载 / 不播放第三方平台的**视频流**，不破解 DRM，不做 VIP 去广告解析；
- ❌ 不做规模化、商业化的弹幕抓取与转售；
- ❌ 不代管用户第三方平台账号密码（仅走扫码 / Cookie 授权，且本地存储）。

应用只承担两件事：**播放用户自己合法拥有的视频** + **拉取公开弹幕数据用于个人观看**。详见 `docs/07-合规与风险.md`。

## 5. 参考资料

- [弹弹play 开放弹幕网络文档](https://doc.dandanplay.com/open/)
- [huangxd-/danmu_api（多平台弹幕聚合，弹弹play 接口兼容）](https://github.com/huangxd-/danmu_api)
- [SocialSisterYi/bilibili-API-collect（protobuf 弹幕）](https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/danmaku/danmaku_proto.md)
- [ArtPlayer + artplayer-plugin-danmuku](https://artplayer.org/document/plugin/danmuku.html)
- [virtualox/vlckit-spm（VLCKit 全 Apple 平台 SPM 包）](https://github.com/virtualox/vlckit-spm)
- [OpenDanmakuCommunity/awesome-danmaku](https://github.com/OpenDanmakuCommunity/awesome-danmaku)
