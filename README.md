# Kanata

Kanata 是一款面向 iPhone、iPad、Apple TV 与浏览器的自有媒体弹幕播放器。它不提供影视内容；用户连接自己的本地文件、NAS 或媒体服务器，应用负责整理剧集、播放视频，并为当前分集匹配和渲染弹幕。

项目正在通过 TestFlight 持续进行真机迭代。Apple 端使用 SwiftUI 与 AVPlayer，Web 端使用 React 与 ArtPlayer，并附带一个可自托管的弹幕网关。

## 主要能力

### 媒体库与导入

- 支持本地文件、系统文件夹、iCloud Drive、系统 Files 中已连接的 SMB、HTTP/HTTPS 直链与 HLS。
- 支持 WebDAV、Jellyfin、Emby、Plex 和群晖 DSM File Station；账号、密码与令牌只保存在本机 Keychain。
- 目录导入前提供确认页，可按当前列表或全部内容多选，支持拖动排序、去重、忽略、恢复及手工修改季号和集号。
- 可把多个季度或目录合并为一个合集，也可保留独立合集；首页会聚合显示“最近添加”，不会用大量单集卡片淹没媒体库。
- 合集支持重命名、剧集排序、忽略、恢复和移出媒体库。移除只删除 Kanata 索引，不删除 NAS 或服务器上的原文件。
- 文件名识别覆盖常见的 `S01E02`、`1x02`、`EP02`、中文季集、绝对集数、特别篇与季度目录；无法可靠判断时允许用户手工覆盖。

### 播放器

- 支持播放/暂停、精确进度拖动、快进后退、0.25×–4× 倍速、画面适应/填充/拉伸、音轨与内封字幕选择。
- 支持导入 SRT、VTT、ASS、SSA 字幕，支持字幕延迟、睡眠定时器、连续播放、单集/列表循环及片头片尾标记。
- iOS 支持画中画、AirPlay、横屏全屏、亮度/音量/进度手势与防误触。
- 向系统发布节目名、集数、时长、队列和进度；锁屏、控制中心、耳机与 Apple TV 遥控器可控制播放、暂停、跳转、上一集和下一集。
- Jellyfin、Emby、Plex 可在“自动、原始流、兼容流”之间切换。自动模式优先直放，原始流不兼容时改用媒体服务器 HLS 转码。
- 播放失败会区分容器、网络与解码问题，并在可用时直接提供“兼容播放”。

### 弹幕

- Apple 端内置哔哩哔哩、爱奇艺、腾讯视频、巴哈姆特动画疯和弹弹play来源；每个来源可单独启用与测试。
- 弹弹play开放平台由于基础额度有限，默认作为低频备用来源，不是应用运行的必需依赖。
- 支持作品搜索、候选分集选择、重新匹配、持久绑定，并明确显示“视频第几集”和“弹幕源第几集”是否一致。
- 支持导入本地 XML、JSON 与 ASS 弹幕，与在线弹幕合并、去重和持久缓存；断网时可使用最近缓存。
- 支持字号、透明度、描边、阴影、速度、密度、显示区域、字体和时间偏移调整。Apple TV 使用更适合观看距离的独立默认字号。
- 可选自托管网关提供统一接口、来源故障回退、缓存和弹弹play v2 兼容路由。

### 跨设备与电视体验

- iCloud KVS 同步网络媒体库索引、非敏感媒体源配置、播放进度、收藏、合集编排、弹幕绑定与显示偏好。
- 密码、令牌、Cookie、本地文件书签、视频内容和弹幕缓存不会上传 iCloud。
- Apple TV 使用十英尺界面、电视安全边距、遥控器焦点样式和大字号控件；也可显示一次性二维码，由手机浏览器辅助填写媒体源。
- 支持跟随系统、浅色和深色外观，多套强调色，以及 iOS 备用 App 图标。

## 播放兼容性

Kanata 当前以 Apple 原生 AVPlayer 为播放内核。MP4、MOV 和 HLS，以及设备硬件支持的 H.264/HEVC 通常可直接播放。Jellyfin、Emby 与 Plex 可把不兼容媒体转换为 HLS，因此更适合包含多种封装和编码的媒体库。

WebDAV、DSM 直链和系统文件夹没有服务端转码能力。MKV、WebM、AVI、FLV，或 HEVC 10-bit + FLAC 等组合是否能播放，仍受 AVPlayer 与具体设备能力限制；失败时应用会说明原因，但目前不会假装已经通过第三方内核解码。

## 架构

```text
自有媒体
├─ 本地 / iCloud Drive / Files 中的 SMB
├─ HTTP / HLS / WebDAV / DSM
└─ Jellyfin / Emby / Plex
              │
              ▼
┌─────────────────────────────────────┐
│ Apple App                           │
│ SwiftUI 媒体库 + AVPlayer + 弹幕渲染 │
│ 内置来源 / 本地缓存 / Keychain / iCloud│
└──────────────────┬──────────────────┘
                   │ 可选
                   ▼
┌─────────────────────────────────────┐
│ Kanata Gateway（Node.js / TypeScript）│
│ 来源适配、统一模型、故障回退、持久缓存 │
└──────────────────┬──────────────────┘
                   │
                   ▼
┌─────────────────────────────────────┐
│ Web App（React + ArtPlayer）          │
└─────────────────────────────────────┘
```

Apple App 可以直接使用内置弹幕来源，也可以连接自托管网关。网关不是播放代理，不接收或转存用户的视频文件。

## 仓库结构

```text
apple/
  KanataApp/       iOS、iPadOS、tvOS 应用
  KanataCore/      标题识别、指纹、模型、缓存与时间轴
  KanataRender/    Apple 端弹幕布局与绘制
gateway/           可自托管弹幕网关
web/               浏览器播放器
docs/              产品、架构、来源矩阵、测试与开发记录
```

## 本地运行

### Apple App

需要 Xcode 16 或更高版本。打开 `apple/KanataApp/KanataApp.xcodeproj`，选择：

- `KanataApp`：iOS / iPadOS
- `KanataTV`：tvOS

最低系统版本为 iOS 17 与 tvOS 17。若需要跨设备同步，请在自己的 Apple Developer App ID 和签名描述文件中启用 iCloud Key-Value Storage。

### 弹幕网关

```bash
cd gateway
npm ci
cp .env.example .env
npm run build
npm start
```

网关要求 Node.js 20 或更高版本。令牌、平台 Cookie 和第三方密钥只应写入本机 `.env` 或部署平台的 Secret，不要提交到 Git。

### Web App

```bash
cd web
npm ci
npm run dev
```

浏览器只能访问符合 CORS、Range 与浏览器编解码限制的媒体地址。本地文件通过浏览器文件选择器读取，不会上传到网关。

## 安全与隐私

- Kanata 不提供、解析或下载第三方视频平台的影视流，不绕过 DRM，也不提供 VIP 内容解析。
- Apple 端敏感凭证存放在 Keychain；媒体库和 iCloud 快照只保存必要的非敏感索引。
- 弹弹play AppSecret、App Store Connect 私钥、媒体服务器令牌和平台 Cookie 均不得写入源码、README、构建日志或提交历史。
- 公共弹幕接口可能随平台规则变化而失效；单个来源失败不应阻断视频播放。

## 开发状态与文档

当前重点是 Apple TV 实机焦点和 4K 性能、真实 NAS 与媒体服务器兼容性、iCloud 跨设备到达时序，以及平台来源变化后的稳定降级。完整记录见：

- [`docs/09-开发记录与功能计划.md`](docs/09-开发记录与功能计划.md)：已实现内容、验证结果、限制与下一步
- [`docs/01-需求文档-PRD.md`](docs/01-需求文档-PRD.md)：功能需求与验收口径
- [`docs/02-架构与接口契约.md`](docs/02-架构与接口契约.md)：客户端、网关与统一数据模型
- [`docs/03-弹幕源适配矩阵.md`](docs/03-弹幕源适配矩阵.md)：来源能力、凭证与风险
- [`docs/04-视频源接入矩阵.md`](docs/04-视频源接入矩阵.md)：媒体源协议与平台差异
- [`docs/05-测试文档.md`](docs/05-测试文档.md)：验证矩阵与性能阈值
- [`docs/07-合规与风险.md`](docs/07-合规与风险.md)：能力边界与风险登记
- [`docs/08-播放器功能基准.md`](docs/08-播放器功能基准.md)：播放器能力对标

## 参考资料

- [Apple：Becoming a now playable app](https://developer.apple.com/documentation/MediaPlayer/becoming-a-now-playable-app)
- [Apple：MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)
- [Apple：AVPlayerItem](https://developer.apple.com/documentation/avfoundation/avplayeritem)
- [Jellyfin：Transcoding](https://jellyfin.org/docs/general/post-install/transcoding/)
- [弹弹play 开放弹幕网络](https://doc.dandanplay.com/open/)
- [ArtPlayer 弹幕插件](https://artplayer.org/document/plugin/danmuku.html)
