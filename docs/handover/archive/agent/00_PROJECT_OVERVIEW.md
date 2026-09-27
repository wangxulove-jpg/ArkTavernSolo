# 00 — Project Overview 项目总览

> 给新 Agent 的项目一句话 + 技术栈 + 历史脉络。

---

## 1. 项目是什么

- **名称**：ArkTavernSolo
- **类型**：原生 HarmonyOS NEXT 单人 AI 角色扮演（RP / Chat）客户端
- **定位**：精简版 SillyTavern —— 只做「一人一角色」聊天，不做群聊/世界复杂度
- **包名**：`com.example.arktavernsolo`
- **路径**：`D:\DevEco_studio\ArkTavernSolo`
- **关联项目**：`ArkTavern`（完整版，含群聊/世界/AvatarAI/VRM）。ArkTavernSolo 与其可同设备共存，所有存储前缀 `arktavern_solo` 隔离。

## 2. 技术栈

| 维度 | 选型 |
|------|------|
| 语言 | ArkTS（严格模式：禁 `any`/`unknown`/`as`、不用 barrel export） |
| UI 框架 | ArkUI（State Management **V1**：`@State`/`@StorageProp`/`@Observed`） |
| 产品目标 | HarmonyOS NEXT，API 24 / SDK 6.1.1（modelVersion 6.1.1） |
| 数据库 | 关系型 RDB `@kit.ArkData` → `arktavern_solo.db`，版本 **38** |
| KV 存储 | Preferences `@ohos.data.preferences`（存储前缀 `arktavern_solo_settings`） |
| 密钥存储 | Asset Store `@ohos.security.asset`（仅存 API Key） |
| HTTP | `@ohos.net.http`（`HarmonyHttpClient` 封装） |
| 流式 | `requestInStream + dataReceive`，自定义 SSE 解析 |
| 语音 | `@kit.CoreSpeechKit`（离线 TTS）+ Edge TTS（在线，WebSocket） |
| 构建 | DevEco Studio / hvigor，`build-profile.json5` 已配置 debug sign（本机 `.ohos/config`） |
| 第三方 | 无运行时第三方依赖（`oh-package.json5` 依赖为空，仅 dev 依赖 hypium/hamock） |

> 关键：**项目几乎无第三方运行时依赖**，网络/SSE/加密/解析全部自研（见 `07_DEPENDENCY_MAP.md`）。

## 3. 历史与脉络（只提取影响理解的信息）

产品演进自一个 SymphonyAI 掌控的茶室场景，「用户进入小酒馆、蓄势待发的冒险叙事 + 采取理性协作博弈策略」的定位。开发按 Phase 推进：

- **基础设施阶段**：RDB 迁移框架（v1→v38）、仓库层、存储层
- **聊天核心**：OpenAI 兼容 API、SSE 流式、PromptBuilder、上下文预算
- **内容系统**：角色卡（V1/V2/V3）、世界书（Lorebook）、提示词预设、记忆系统、Persona（用户身份）
- **交互增强**：对话分支（Branch）/分支地图、消息 Swipe、AI 续写/代写/旁白、用户性格总结（DB v36）
- **工程增强**：聊天归档导出/导入、Chub 角色卡市场、AI 角色卡生成、WebDAV 云同步（坚果云）、TTS
- **最近进展**（git log）：V3 角色卡完整支持 + reasoning_content 思考模型修复（HEAD）→ 旁白功能重构 → Edge 在线 TTS 集成

> 详细交接、已实现功能清单、关键设计决策见 `docs/HANDOVER.md`。

## 4. 完整目录结构（顶部）

```
ArkTavernSolo/
├── AppScope/                 # 应用级资源/配置 (app.json5, icon)
├── entry/                    # 唯一 module（name="entry", type="entry"）
│   └── src/main/
│       ├── ets/              # 全部源码（见 02_DIRECTORY_GUIDE）
│       ├── resources/        # base + dark 资源
│       └── module.json5      # Ability/权限/入口声明
├── docs/                     # 文档（HANDOVER + AGENT 导航层）
├── spec/persona-system/      # 某期 feature 的 spec/plan/tasks
├── screenshots/
├── .deveco/plans/            # DevEco 本地计划文件（历史，非交付物）
├── build-profile.json5       # 签名/产物
├── hvigor/                   # 构建配置
└── oh-package.json5          # 三方依赖（运行时为空）
```