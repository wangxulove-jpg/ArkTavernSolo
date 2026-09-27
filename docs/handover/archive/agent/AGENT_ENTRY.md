# AGENT_ENTRY — Agent 快速入口

> 新 Agent 接手本项目的第一份文档。请先读本文件，再按需跳转。
> 本目录是「Agent 导航层」，只做定位索引；完整交接/业务细节见 `docs/HANDOVER.md`。

---

## 1. 项目一句话

原生 **HarmonyOS NEXT (ArkTS)** 实现的**单人 AI 角色扮演聊天客户端**「ArkTavernSolo」，复刻 SillyTavern 单人聊天核心（角色卡、AI 对话、世界书、记忆、Persona、分支、云同步）。

## 2. 目录速览

| 代码主题 | 去哪里 |
|---------|--------|
| UI 页面 | `entry/src/main/ets/pages/`（含 `pages/tabs/` 4 个首页 Tab 根视图） |
| 可复用组件 | `entry/src/main/ets/components/` |
| 状态/交互逻辑 | `entry/src/main/ets/viewmodels/`（`ChatViewModel` 为聊天核心） |
| 业务编排 | `entry/src/main/ets/services/`（`ChatService` / `ModelService` / `PromptBuilder` / `LorebookService`） |
| 数据模型 | `entry/src/main/ets/models/` |
| 数据库 | `entry/src/main/ets/database/`（版本 **38**） |
| 数据访问 | `entry/src/main/ets/repositories/` |
| KV/密钥/选择态存储 | `entry/src/main/ets/storage/` |
| 网络/流式/WebDAV | `entry/src/main/ets/network/` |
| 角色卡/PNG/归档解析 | `entry/src/main/ets/parser/` |
| 工具/主题 | `entry/src/main/ets/utils/`、`theme/` |

## 3. 入口链

```
EntryAbility.ets (onCreate)
   └─ AppServices.initialize(context)  ← 组装全部底层依赖
        └─ loadContent('pages/Index')   ← 首页 4 Tab (角色卡/对话记录/市场/设置)
             └─ 各 Tab RootView → router.pushUrl 到二级页面
```

## 4. 修改某类功能 → 定位（详见 04_FEATURE_LOCATOR.md）

| 想改 | 第一定位文件 |
|------|------------|
| 首页/聊天 UI | `pages/Index.ets` / `pages/ChatPage.ets` / `components/` |
| AI 对话逻辑 | `services/ChatService.ets` + `viewmodels/ChatViewModel.ets` |
| Prompt 如何组装 | `services/PromptBuilder.ets` |
| 选模型/连接测试 | `services/ModelService.ets` + `network/providers/` |
| 数据库表/迁移 | `database/Database*.ets` + `repositories/` |
| 新增设置项 | `storage/XXStore.ets` + `pages/tabs/SettingsRootView.ets` |
| 云同步 | `services/sync/` + `storage/SyncConfigStore.ets` |

## 5. 必须先读的核心文件（3–10 个）

1. `entry/src/main/ets/services/AppServices.ets` — 组合根，理解依赖如何装配
2. `entry/src/main/ets/pages/Index.ets` — 首页 Tab 架构
3. `entry/src/main/ets/services/ChatService.ets` — 聊天业务核心（超大，>1300 行方法）
4. `entry/src/main/ets/viewmodels/ChatViewModel.ets` — 聊天状态管理
5. `entry/src/main/ets/pages/ChatPage.ets` — 聊天 UI（约 4400+ 行，改时注意花括号）
6. `entry/src/main/ets/services/PromptBuilder.ets` — prompt 组装
7. `entry/src/main/ets/database/DatabaseConstants.ets` — 数据库版本与表/列常量
8. `entry/src/main/ets/models/ChatMessage.ets`、`models/Character.ets` — 核心数据模型
9. `docs/HANDOVER.md` — 架构约束、已知陷阱、关键索引

## 6. 推荐的调查路径

```
AGENT_ENTRY → 00_PROJECT_OVERVIEW → 01_ARCHITECTURE_MAP
            → 04_FEATURE_LOCATOR(按功能跳到模块) → 06_CALL_GRAPH/05_DATA_FLOW → 读具体代码
```

## 7. 修改任何代码前必须检查

- 分层依赖约束（见 `docs/HANDOVER.md` §3.1）：
  `pages/ → viewmodels/ → services/ → repositories/ → database/`，禁止跨层直连
- 编码规则：不用 barrel export、不用 `any`/`unknown`/`as`、迁移只增不改、`@Builder` 内禁 `const/let`
- 本功能的上游调用者、下游依赖（`03_MODULE_INDEX.md`）
- 是否存在相关 TODO / 已知问题（`09_KNOWN_ISSUES.md`）
- 数据库当前版本 **38**，新增列需迁移 `v38→v39`

## 8. 索引文档清单

| 文档 | 解决什么问题 |
|------|-----------|
| [00_PROJECT_OVERVIEW.md](00_PROJECT_OVERVIEW.md) | 项目是什么、技术栈、历史 |
| [01_ARCHITECTURE_MAP.md](01_ARCHITECTURE_MAP.md) | 整体架构与分层 |
| [02_DIRECTORY_GUIDE.md](02_DIRECTORY_GUIDE.md) | 目录职责分类 |
| [03_MODULE_INDEX.md](03_MODULE_INDEX.md) | 每个文件职责/接口/依赖/风险 |
| [04_FEATURE_LOCATOR.md](04_FEATURE_LOCATOR.md) | 功能→文件定位表（最重要） |
| [05_DATA_FLOW.md](05_DATA_FLOW.md) | 数据如何流动 |
| [06_CALL_GRAPH.md](06_CALL_GRAPH.md) | 核心调用链 |
| [07_DEPENDENCY_MAP.md](07_DEPENDENCY_MAP.md) | 内外部依赖 |
| [08_PROJECT_STATUS.md](08_PROJECT_STATUS.md) | 各功能当前状态矩阵 |
| [09_KNOWN_ISSUES.md](09_KNOWN_ISSUES.md) | 已知问题/技术债 |