# FEATURE_MAP — 功能 → 文件 → 约束（权威定位表）

> **这是 agent 接手后的第二站**（第一站 `AGENTS.md`）。目的：**改单个功能时不必检索全仓**。
> 路径省略 `entry/src/main/ets/` 前缀。**下钻顺序**：Page → ViewModel → Service → Repository → Db。
> **维护**：功能增删 / 文件搬迁时**同一次提交**内更新本表。本表与代码冲突时**以代码为准**并当场改本表。
> 最后核对：2026-09-27（P3 收官后，逐条路径已按实际目录校验）。

## 0. 分层与红线（先看这条）

```
pages/ → viewmodels/ → services/ → repositories/ → database/
                          ↓                ↓
                     storage/          network/
components/ 与 models/：无网络、无数据库、无业务副作用
bridge/：仅承载「页面 ↔ 组件」的宿主契约（例：FrontendCardHost）
```

- `services/AppServices.ets` 是**唯一组合根**；页面可通过 `AppServices.getXxx()` 取服务（允许）
- `ModelService` 是**所有 AI 请求的唯一出口**
- 已知偏差：`ChatPage` / `LorebookPage` 直连具体服务属**冻结项**（T3，见 `CURRENT.md` P3-4）；**新增页面一律走 VM**

## 1. 核心功能定位

| 我想改… | 第一定位 | 继续追踪 | 层 |
|---|---|---|---|
| 首页 4 Tab / 底部导航 | `pages/Index.ets` | `pages/tabs/{Character,ChatSession,Market,Settings}RootView.ets` | UI |
| 角色卡列表 / 新建 / 删除 | `pages/tabs/CharacterRootView.ets` | `CharacterListPage` → `viewmodels/CharacterListViewModel` → `services/CharacterService` | UI→VM→S |
| 角色编辑 / 导入导出 | `pages/CharacterEditPage.ets` | `viewmodels/{CharacterEdit,CharacterExport}ViewModel` → `services/CharacterService` → `parser/CharacterCardJsonParser` | UI→VM→S→parser |
| 添加角色 / 导入卡（含 PNG 卡） | `pages/AddCharacterPage.ets` | `parser/{CharacterCardJsonParser,PngCharacterCardParser}` | UI→parser |
| **聊天主界面** | `pages/ChatPage.ets`（4,884 行，**改动风险最高**） | `viewmodels/ChatViewModel` → `services/ChatService` | UI→VM→S |
| **AI 对话 / 流式核心** | `services/ChatService.ets`（**不授权勿动**：`doStream` / `finalizeAssistantTurn` / delta 持久化 / 句柄定时器） | `services/ModelService` → `network/providers/OpenAIProvider` | S→network |
| 消息发送入口 | `services/ChatMessageSender.ets` | `ChatService.doStream`（委托） | S |
| 代写 / 性格提取与总结 / 续写 ⚡ | `services/ChatOneShotGenerator.ets` | `services/ChatService`（薄包装） | S |
| 角色状态（面板 / AI 生成字段 / 状态块合并） | `services/ChatStatusService.ets` | `models/ChatStatusState` / `parser/ChatStatusBlockParser` | S→parser |
| 消息 Swipe（候选切换 / 重新生成候选） | `services/ChatSwipeController.ets` | `components/MessageSwipeControls` / `services/MessageSwipePersistenceService` | UI→S→Repo |
| 对话分支（判定 / 切换 / 生成族 / fork） | `services/ConversationBranchService.ets` | `services/ForkChatService` / `repo:ConversationBranchRepository` / `components/BranchMapNode` | S→Repo |
| 会话生命周期（新建/切换/删除/新建章节） | `services/ChatSessionService.ets` | `services/ChatPersistenceService` / `services/WorldGroupService` | S |
| 消息删除 / 编辑 | `services/ChatMessageService.ets` | — | S |
| 上下文维护（记忆总结触发 / 记忆失效 / 世界书激活刷新） | `services/ChatContextMaintenanceService.ets` | `services/MemoryService` / `services/LorebookPinService` | S |
| 用户称呼 / Persona 注入 | `services/ChatUserIdentityService.ets` | `services/PersonaService` | S |
| **Prompt 如何拼装** | `services/PromptBuilder.ets` | `services/MacroReplacer` / `RecentMessageSelector` / `HistoryTrimmer` / `PromptSegment` 段序 | S |
| 请求构建与注入（世界书 / 按需记忆 / 粘滞 / 锚点） | `services/ChatRequestBuilder.ets` | `services/ChatRequestPlan`（Token 预算 + 裁剪） | S |
| 选模型 / 密钥 / 连接测试 | `services/ModelService.ets` → `pages/ModelSettingsPage.ets` / `ModelConfigEditPage.ets` | `storage/ProviderConfigStore` / `ProviderKeyStore` / `services/ProviderFactory` / `network/providers/` | UI→VM→S→storage→network |
| 聊天记录 / 会话管理（分组/拖拽/归档） | `pages/tabs/ChatSessionRootView.ets`（2,786 行） | `viewmodels/ChatSessionListViewModel` → `services/ChatPersistenceService`；分组弹窗 `components/SessionGroupDialogs` | UI→VM→S |
| 世界书 Lorebook（业务） | `pages/LorebookPage.ets` → `viewmodels/LorebookViewModel` | `services/LorebookService` → `repositories/LorebookRepository` | UI→VM→S→Repo |
| 世界书面板（聊天页状态/世界书浮层） | `viewmodels/LorebookPanelVM.ets` + `components/ChatStatusWorldPanel.ets` | 类型 `models/LorebookPanel.ets` | VM |
| 世界书按需锁定 / 粘滞命中 | `services/LorebookPinService.ets` / `LorebookStickyService.ets` | `repositories/ChatLorebook{Pin,Sticky}Repository` | S→Repo |
| AI 世界书（修改/提取） | `services/ai/AiLorebookService.ets` | `models/LorebookAiTypes` | S |
| 提示词预设 | `pages/PromptPreset{List,Edit}Page.ets` | `viewmodels/PromptPreset{List,Edit}ViewModel` → `services/PromptPresetService` → `repositories/PromptPresetRepository` | UI→VM→S→Repo |
| **多层记忆 / 记忆管理** | `services/MemoryService.ets`（触发/生成/CRUD） | `MemoryPromptBuilder`（提示词）/ `WorldMemoryStore`（世界手工记忆+召回）/ `MemoryTriggerPolicy`（阈值+归档边界）/ `MemoryLoadRefService`（按需加载）/ `ChapterMemoryIndexer`（实体索引） | S |
| 记忆管理页 / 世界记忆页 | `pages/MemoryManagementPage.ets` / `pages/WorldMemory{Page,DetailPage}.ets` / `WorldChapterListPage.ets` | `viewmodels/{MemoryManagement,WorldMemory}ViewModel` | UI→VM |
| 上下文预算 | `pages/ContextBudgetPage.ets` | `viewmodels/ContextBudgetViewModel` → `services/ContextBudgetService` / `Estimator` / `SnapshotStore` | UI→VM→S |
| 用户身份 Persona | `pages/Persona{List,Edit}Page.ets` | `viewmodels/PersonaViewModel` → `services/PersonaService` → `repositories/PersonaRepository` / `storage/PersonaSelectionStore` | UI→VM→S→Repo |
| 聊天归档导入/导出 | `pages/tabs/ChatSessionRootView.ets`（归档区） | `viewmodels/ChatArchiveViewModel` → `services/ChatArchive{Service,ImportService}` → `parser/ChatArchiveSchema` | UI→VM→S→parser |
| 聊天背景 / 字体外观 | `pages/ChatBackgroundSettingsPage.ets` / `components/ChatAppearancePanel.ets` | `services/ChatBackgroundService` / `utils/ChatText{ColorTheme,StyleSettings}` | UI→S→utils |
| 主题切换 | 全页 `@StorageProp effectiveTheme` | `services/ThemeManager` → `theme/ThemePalette` | UI→S |
| Chub 角色卡市场 | `pages/tabs/MarketPage.ets` / `pages/MarketDetailPage.ets` | `viewmodels/{Market,MarketDetail}ViewModel` → `services/market/` | UI→VM→S→network |
| AI 生成角色卡 | `pages/AiCharacterMakerPage.ets` / `AiCharacterPreviewPage.ets` / `AiCardRevisePage.ets` | `viewmodels/AiCharacter*ViewModel` → `services/ai/AiCharacterGenerationService` | UI→VM→S |
| 角色卡前端页面（卡片自带 UI） | `pages/FrontendCardPage.ets` / `components/CardFrontendWeb.ets` | 宿主契约 `bridge/CardFrontendBridge.ets`（`FrontendCardHost`） | UI→bridge |
| 云同步 WebDAV | `pages/SyncSettingsPage.ets` | `viewmodels/SyncViewModel` → `services/sync/` → `network/webdav/WebDavClient` / `storage/SyncConfigStore` | UI→VM→S→network |
| TTS 朗读 | `pages/TtsSettingsPage.ets` / 聊天页朗读按钮 | `services/TtsService`（离线）/ `EdgeTtsService`（在线） | UI→S |
| DeepSeek 余额 | `pages/ModelSettingsPage.ets` | `services/DeepSeekBalanceService` | UI→S |
| **错误提示文案** | `viewmodels/ChatErrorMapper.ets`（`toUserError` / `toSessionOpError`） | — | VM（纯函数） |
| 日志 | `utils/Logger.ets` | 诊断缓冲 `utils/LogBuffer.ets` | utils |

## 2. 基础设施定位（含"新增 X 该仿谁"）

| 我想改… | 第一定位 |
|---|---|
| 表名 / 列名 / 索引名（唯一来源） | `database/DatabaseConstants.ets`（`DATABASE_VERSION` = 47） |
| **DDL 常量**（CREATE/ALTER） | `database/schema/Schema{Core,Lorebook,Presets,Swipe,Branch,Memory,World}.ets`（P3-3② 按域拆分） |
| 版本组装 / `getSchemaStatements` | `database/DatabaseSchema.ets`（`SCHEMA_BY_VERSION` Map 注册表，P3-3③） |
| **新增数据库迁移** | `database/DatabaseMigration.ets`（**只增不改、版本连续、禁 DROP**；当前到 v47） |
| 数据库连接 / 事务 | `database/DbHelper.ets`（`runInTransaction` / `getStore` / `getVersion`） |
| **新增 Repository** | 仿 `repositories/CharacterRepository.ets`（+ 同名 `*RepositoryMapper.ets`）；事务内复用传 `store` |
| **跨表事务编排** | 仿 `services/ChatPersistenceService.ets`（`dbHelper.runInTransaction`）；**新服务不得新增 DbHelper 直连**（P3-4 口径 C） |
| KV 设置持久化 | 仿 `storage/AppPreferences.ets` / `storage/*Store.ets`（键前缀 `arktavern_solo`） |
| 密钥存取 | `storage/AssetStoreKeyStore.ets` / `storage/ProviderKeyStore.ets` |
| **新增 UI 组件** | 放 `components/`（纯 UI，禁网络/DB/安全存储）；先查 [INVENTORY](./INVENTORY.md) |
| 路由注册新页面 | `entry/src/main/resources/base/profile/main_pages.json`（+ `entryability/EntryAbility.ets` 仅首页时改） |
| HTTP 请求 | `network/core/{HarmonyHttpClient,HttpClient}.ets` |
| SSE 流式解析 | `network/streaming/{SseParser,OpenAiSseDeltaParser,Utf8StreamDecoder}.ets` |
| 角色卡 V1/V2/V3 解析 / PNG 内嵌卡 | `parser/CharacterCardJsonParser.ets` / `parser/PngCharacterCardParser.ets` |
| 宏替换 / Token 估算 | `services/MacroReplacer.ets` / `services/TokenCounter.ets` |
| 新增可复用纯函数 | 放 `utils/`（无副作用）；契约常量仿 `services/ChatTextContract.ets` |
| 新增纯数据/类型 | 放 `models/`（例：`models/LorebookPanel.ets`、`models/ChatMemory.ets` 的 `ChapterTriggerConfig`） |

## 3. 数据模型定位

| 找什么 | 文件 |
|---|---|
| ChatMessage / MessageSenderType | `models/ChatMessage.ets` |
| Chat / CreateChatOptions | `models/Chat.ets` |
| Character | `models/Character.ets` |
| ChatRole（Wire 层） | `models/ChatRole.ets` |
| **ChatGenerationKind / ActiveGenerationContext** | `models/ChatGenerationContext.ets`（P2-4 起，**不再在 ChatService**） |
| ChatState / ChatServiceCallbacks | `models/ChatServiceContract.ets`（P2-2 起） |
| ChatMessageSource / ChatStreamTypes | `models/ChatMessageSource.ets` / `models/ChatStreamTypes.ets` |
| ProviderType / ProviderConfig / ProviderPreset | `models/ProviderType.ets` / `ProviderConfig.ets` / `ProviderPreset.ets` |
| Lorebook / LorebookEntry / LorebookPosition / LorebookAiTypes | `models/Lorebook.ets` / `LorebookAiTypes.ets` |
| LorebookPanelBook / LorebookPanelData | `models/LorebookPanel.ets`（P3-1② 起） |
| ChatMemory / **ChapterTriggerConfig** / MemorySummaryPoints / MacroContext | `models/ChatMemory.ets` / `MacroContext.ets` |
| PromptSegment / PromptSegmentPosition | `models/PromptSegment.ets` |
| Persona / PersonaPosition | `models/Persona.ets` / `PersonaPosition.ets` |
| ConversationBranch / 分支摘要 / 记录计数 | `models/ConversationBranch.ets` |
| ChatStatusState / 状态 Schema 解析 | `models/ChatStatusState.ets` |
| TokenBudget / ContextBudgetConfig | `models/TokenBudget.ets` / `ContextBudgetConfig.ets` |
| MessageSwipe / 候选上限 | `models/MessageSwipe.ets` |
| 世界分组 | `models/WorldGroup.ets` |
| TTS 模型 | `models/TtsReadMode.ets` / `TtsEngine.ets` |
| 市场模型 | `models/MarketCharacter*.ets` |

> `models/` 共 58 个文件；上表只列高频项。找不到时先 `Glob models/*.ets` 按名找。

## 4. 用本表的一个例子

「用户说：代写候选生成总是同一条」→ 不检索全仓，直接：
1. 本表 → `services/ChatOneShotGenerator.ets`（代写族）
2. 看它的宿主契约 `ChatOneShotHost`（可变状态经函数属性回传）
3. 若涉及请求内容 → `services/ChatRequestBuilder.ets`（`excludeMessageId` 路径）
4. 若涉及界面 → `viewmodels/ChatViewModel.ets` → `components/ImpersonateCandidatesPanel.ets`
