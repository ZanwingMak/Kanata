# 06 · Skill 评估与 AI 协作协议

> 目标：让**不同的 AI / 不同的会话**都能接手本项目的任意一块，产出风格一致、契约一致的成果。

---

## 1. 现有 Skill 评估

按当前环境中可用的 Skill 逐一评估适用性：

### 1.1 直接采用

| Skill | 用于 | 说明 |
| --- | --- | --- |
| **ios-application-dev** | Apple 端全部 UI 开发 | 覆盖 SwiftUI/UIKit、安全区、Dynamic Type、Dark Mode、无障碍、HIG。是 iOS/iPadOS 开发的主 Skill。**注意：它对 tvOS 焦点引擎覆盖不足**，需补自建 Skill（见 §2） |
| **web-design-engineer** | Web 端界面与交互实现 | HTML/CSS/JS/React 视觉与交互产物，适合 Web 播放页与媒体库页 |
| **fullstack-dev** | 弹幕网关 | 后端服务分层、错误处理、配置与鉴权、API 客户端、SSE/WebSocket、生产加固，正好对应网关需求 |
| **security-review** | 每次涉及凭证/网络的改动 | 对照 `NFR-SEC-*` 做安全走查 |
| **simplify** | 每个里程碑收尾 | 对应 CLAUDE.md「代码简洁、避免过度设计」 |
| **run** | 验证改动 | 启动 App / 网关并截图确认 |
| **update-config** | 配置 CI 钩子、权限白名单 | 例如探活任务的自动化 |

### 1.2 部分适用

| Skill | 适用点 | 局限 |
| --- | --- | --- |
| **shader-dev** | 弹幕渲染的着色思路、批渲染、性能优化模式 | 内容以 GLSL 为主，Apple 端需转写为 Metal(MSL)，只能作思路参考 |
| **frontend-dev** | Web 端动效与视觉打磨 | 偏营销页/落地页，本项目是工具型应用，节制使用 |
| **dataviz** | 弹幕密度曲线、源健康看板 | 仅用于诊断面板与探活报告 |
| **vision-analysis** | UI 走查、弹幕蒙版效果比对 | 辅助验收，非开发主线 |
| **find-skills** | 发现新的可用 Skill | 需要时再用 |

### 1.3 明确不用

| Skill | 原因 |
| --- | --- |
| flutter-dev / react-native-dev | tvOS 支持不足，与 DEC-03 冲突 |
| android-native-dev | 当前不含 Android 端 |
| claude-api | 本项目不涉及 LLM 调用 |
| minimax-docx / pdf / xlsx、ppt 系列、gif-sticker-maker、music 系列、web-video-presentation | 与项目产出物无关 |
| kb-retriever、google-trends、color-font-skill、design-style-skill | 非本项目工作流 |

---

## 2. Skill 缺口（需要自建项目级 Skill）

现有 Skill 无法覆盖本项目最关键的几块领域知识。建议在 `.claude/skills/` 下自建以下 6 个，**每个都以本仓库文档为唯一事实来源**：

| Skill 名 | 触发场景 | 内容要点 | 依据文档 |
| --- | --- | --- | --- |
| `kanata-contract` | 任何跨模块数据结构/接口改动 | 契约先行流程；类型定义清单；错误码表；改动后必须同步的文档 | `02` |
| `danmaku-provider` | 新增或修复平台适配器 | `DanmakuProvider` 接口、字段映射表、分片规则、凭证隔离、探活断言、失效降级、脱敏日志、更新「最后验证日期」 | `03` `05§7` |
| `player-core` | 播放内核相关开发 | 双内核择一策略、VLCKit 集成注意点、音频/字幕延迟实现、多轨枚举、错误码分级、信息面板字段 | `08` `01§G` |
| `danmaku-render` | 渲染引擎开发与调优 | 轨道分配算法、字号自适应、密度限流、CADisplayLink 插值、Metal 批渲染、性能阈值与测量方法 | `01§D2` `05§4` |
| `media-source` | 接入新的片源协议 | `MediaSourceProvider` 接口、各协议要点、Range 取 hash、端能力差异、错误码 SRC-* | `04` |
| `tvos-focus` | tvOS 界面开发 | 焦点引擎、遥控器手势、无文件系统的替代输入、4K 性能与内存约束、Top Shelf | `01§H` |

> 建立顺序建议：`kanata-contract` → `danmaku-provider` → `player-core` → 其余。前两个不建，多 AI 协作必然产生契约漂移。

---

## 3. AI 分工建议

| 角色 | 负责范围 | 主用 Skill |
| --- | --- | --- |
| 网关工程 | `gateway/` 全部：路由、适配器、归一化、缓存、探活 | fullstack-dev + `danmaku-provider` + `kanata-contract` |
| Apple 端工程 | `apple/KanataCore` + `KanataApp` | ios-application-dev + `media-source` + `player-core` |
| tvOS 工程 | `apple/KanataTV` | ios-application-dev + `tvos-focus` |
| 渲染工程 | `apple/KanataRender` | `danmaku-render`（+ shader-dev 作思路参考） |
| Web 工程 | `web/` | web-design-engineer + `kanata-contract` |
| 质量 | `05` 文档用例执行、探活 CI、性能测量 | security-review + run |

**并行安全边界**：网关、Apple 端、Web 端可完全并行，因为三者只通过 `02` 文档的契约耦合。渲染引擎与播放内核也可并行（前者只依赖 `DanmakuItem[]` + 时间）。

---

## 4. 任务交接协议

### 4.1 任务卡格式（派活时使用）

```markdown
## 任务：<一句话目标>
- 关联需求：FR-DMK-002, FR-AUTH-001
- 关联用例：TC-DMK-002, TC-AUTH-001
- 涉及文件：gateway/src/providers/bilibili.ts
- 契约影响：无 / 有（若有，先改 docs/02 并说明）
- 前置依赖：<已完成的任务或已存在的能力>
- 完成定义：
  1. 关联用例全部 PASS（附执行记录）
  2. healthCheck 通过
  3. docs/03「最后验证日期」已更新
```

### 4.2 交付说明必须包含

1. 实现了哪些 `FR-*`，执行了哪些 `TC-*`，结果分别是什么；
2. **未完成/未验证的部分及原因**（不得含糊带过，不得把未验证说成已完成）；
3. 契约是否变更，变更了哪些字段；
4. 新增的外部依赖及其许可证；
5. 已知风险与后续建议。

### 4.3 硬性禁止

- ❌ 不读 `CLAUDE.md` 与 `02` 文档就动手；
- ❌ 绕过 `DanmakuProvider` / `MediaSourceProvider` 抽象写平台专有分支；
- ❌ 在业务层硬编码 AppId/AppSecret/Cookie；
- ❌ 声称未经运行验证的功能「已完成」；
- ❌ 擅自把功能拆成「基础版/增强版/Pro 版」；
- ❌ 实现任何视频流解析、DRM 绕过相关代码（见 `07`）。

---

## 5. 上下文引导（新 AI 接手时的最短阅读路径）

```
1. CLAUDE.md                （2 分钟，硬约束）
2. README.md §3 决策点       （1 分钟，知道哪些还没定）
3. docs/02 §2 数据模型 + §3 API（5 分钟，契约）
4. 按角色读对应领域文档：
   - 适配器 → docs/03
   - 片源   → docs/04
   - 播放器 → docs/08 + docs/01 §G
   - 测试   → docs/05
```

其余文档按需查阅，不必通读。
