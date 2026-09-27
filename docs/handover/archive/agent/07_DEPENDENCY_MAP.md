# 07 — Dependency Map 依赖地图

> 内部依赖 + 同机共存隔离 + 外部依赖。路径省略 `entry/src/main/ets/`。

## 1. 分层依赖链（核心）

```
pages → viewmodels → services → repositories → database(DbHelper/RDB)
                      ├──────→ storage (Preferences / KeyStore / 选择态)
                      ├──────→ network (providers / streaming / webdav)
                      └──────→ parser (纯解析)
models ← 全层引用（纯数据，无环）
utils / theme ← 全层引用
```

## 2. 核心枢纽（高耦合）

| 节点 | 被引用/依赖它 | 说明 |
|------|------------|------|
| `services/AppServices.ets` | 几乎所有页面/VM 依赖它取服务 | 装配根，改动需同步各处静态 getter |
| `services/ModelService.ets` | ChatService、翻译、AI 生成、余额、memory | 所有 AI 请求唯一出口 |
| `database/DbHelper.ets` | 全部 Repository | 单例 RDB |
| `models/ChatMessage.ets`/`Character.ets` | 全层 | 字段变化影响面最大 |
| `utils/Logger.ets` | 全层 | 统一日志 |

## 3. 循环依赖 / 高耦合风险

- **无明显硬循环依赖**（分层单向），但因 ChatService/AppServices/PromptBuilder 互相交织，存在**逻辑环**风险：AppServices 创建 ChatService，ChatService 又 import AppServices（`services/ChatService.ets` 引用了 `AppServices`）。改动时注意不要引入正环。
- `ChatService` 同时依赖 PromptBuilder、ModelService、LorebookService、MemoryService、ContextBudgetService 等多个服务 → 职责较重，新增流程时优先考虑拆分为独立 Service（如 `ForkChatService`、`ContextBudgetService` 已是拆出来的范例）。
- `ChatViewModel` 依赖面广（ChatService / ModelService / Character / PromptPreset / Lorebook / AiLorebook），耦合集中。

## 4. 同机共存隔离（ArkTavern vs ArkTavernSolo）

- 数据库名 `arktavern_solo.db`
- Preferences 前缀 `arktavern_solo_settings`
- 存储/KeyStore 等均带 `arktavern_solo` 前缀
- **新增任何持久化键/表必须沿用前缀**，避免与完整版 ArkTavern 冲突

## 5. 外部依赖（运行时不依赖三方库）

| 依赖 | 用途 | 关键程度 | 使用位置 |
|------|------|---------|---------|
| `@kit.ArkUI` | UI 框架 + AppStorage | 高 | 全部页面 |
| `@kit.ArkData` | RDB(`relationalStore`) + Preferences + account/oauth 等 | 高 | database/、storage/AppPreferences |
| `@ohos.net.http` | 网络请求 | 高 | network/core/HarmonyHttpClient、streaming |
| `@ohos.security.asset` | 密钥存储 | 高 | storage/AssetStoreKeyStore/ProviderKeyStore |
| `@ohos.file.*`/`fileIo` | 文件 IO | 中 | 图片/归档/同步 |
| `@kit.AbilityKit` | UIAbility/abilityContext | 高 | EntryAbility/AppServices |
| `@kit.PerformanceAnalysisKit` | hilog 日志 | 低 | EntryAbility 等 |
| `@kit.CoreSpeechKit` | 离线 TTS | 中 | services/TtsService |
| `@kit.UIDesignKit` | HdsTabs 沉浸导航 | 中 | pages/Index |
| `@kit.IMEKit`/`InputKit` | 输入法/电量 | 中 | ChatPage |
| DevEco/hvigor | 构建 | 高 | 工程 |

> `oh-package.json5` 运行时 dependencies 为空；仅 devDependencies: `@ohos/hypium`(1.0.25)、`@ohos/hamock`(1.0.0)。

## 6. 建议

- 新功能优先复用 `ModelService`、`CharacterService` 等现有服务，不自行 new 全套
- 新存储键先加前缀 + 在对应 Store 封装（不散落 Preferences key）
- 大流程新增走「拆分服务」而非堆进 `ChatService`