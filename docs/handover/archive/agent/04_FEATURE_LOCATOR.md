# 04 — Feature Locator 功能 → 文件定位

> **本文件是未来 Agent 最重要的定位表。** 路径省略 `entry/src/main/ets/` 前缀。
> 规则：先定位P(页面)→VM(ViewModel)→S(Service)→Repo/Db→...，层层下钻。

## 1. 核心功能定位

| 我想改… | 第一定位文件 | 继续追踪 | 相关层 |
|--------|------------|---------|--------|
| 首页 Tab / 底部导航 | `pages/Index.ets` | `pages/tabs/*RootView.ets`, `MarketPage.ets` | UI |
| 角色卡列表 / 新建 / 删除 | `pages/tabs/CharacterRootView.ets` | `pages/CharacterListPage`→`viewmodels/CharacterListViewModel`→`services/CharacterService` | UI→VM→S |
| 角色编辑 / 导入导出 | `pages/CharacterEditPage.ets` | `viewmodels/CharacterEditViewModel` / `CharacterExportViewModel`→`services/CharacterService`→`parser/CharacterCardJsonParser` | UI→VM→S→parser |
| 添加角色 / 导入角色卡 | `pages/AddCharacterPage.ets` | `parser/CharacterCardJsonParser`/`PngCharacterCardParser` | UI→parser |
| 聊天主界面 / 发消息 | `pages/ChatPage.ets` | `viewmodels/ChatViewModel`→`services/ChatService.sendMessage` | UI→VM→S |
| AI 对话生成 / 流式 | `services/ChatService.ets` | `services/ModelService`→`network/providers/OpenAIProvider` | S→network |
| Prompt 如何拼装 | `services/PromptBuilder.ets` | `services/MacroReplacer`, `services/LorebookService`, `services/RecentMessageSelector/HistoryTrimmer` | S |
| 选模型 Provider / 密钥 / 连接测试 | `services/ModelService.ets` | `storage/ProviderConfigStore`,`storage/ProviderKeyStore`,`services/ProviderFactory`,`network/providers/` | S→storage→network |
| 模型配置编辑页 | `pages/ModelSettingsPage.ets`, `pages/ModelConfigEditPage.ets` | `viewmodels/ModelSettingsViewModel` | UI→VM |
| 聊天记录 / 会话管理 | `pages/tabs/ChatSessionRootView.ets` | `viewmodels/ChatSessionListViewModel`→`services/ChatPersistenceService` | UI→VM→S |
| 世界书 Lorebook | `pages/LorebookPage.ets` | `viewmodels/LorebookViewModel`→`services/LorebookService`→`repositories/LorebookRepository` | UI→VM→S→Repo |
| 提示词预设 | `pages/PromptPresetListPage.ets`/`PromptPresetEditPage.ets` | `viewmodels/PromptPreset*ViewModel`→`services/PromptPresetService`→`repositories/PromptPresetRepository` | UI→VM→S→Repo |
| 记忆系统 / 记忆管理 | `pages/MemoryManagementPage.ets` | `viewmodels/MemoryManagementViewModel`→`services/MemoryService` | UI→VM→S |
| 上下文预算 | `pages/ContextBudgetPage.ets` | `viewmodels/ContextBudgetViewModel`→`services/ContextBudgetService` | UI→VM→S |
| 对话分支 / 分支地图 | `pages/BranchMapPage.ets` | `viewmodels/BranchMapViewModel`→`services/ConversationBranchPersistenceService` / `ForkChatService` | UI→VM→S |
| 消息 Swipe | `pages/ChatPage.ets`(+`components/MessageSwipeControls`) | `services/ChatService` swipe 方法→`services/MessageSwipePersistenceService` | UI→S |
| 代写 Impersonate | `pages/ChatPage.ets`(+`components/ImpersonateCandidatesPanel`) | `viewmodels/ChatViewModel`→`services/ChatService.generateImpersonateCandidates` | UI→VM→S |
| 旁白 Narrator | `pages/ChatPage.ets` | `services/ChatService.narratorMessage/narratorMessageOnly` | UI→VM→S |
| 用户性格总结 | `pages/ChatPage.ets`(personaPickerSheet) | `services/ChatService.extractUserFromCharacter/summarizeUserPersona`→`markMessageIncludeInMemory` | UI→VM→S |
| AI 续写/重生成 | `pages/ChatPage.ets`(+`components/ChatMessageActionSheet`) | `services/ChatService.regenerate*`/`continueFromAssistant` | UI→S |
| 用户身份 Persona | `pages/PersonaListPage.ets`/`PersonaEditPage.ets` | `viewmodels/PersonaViewModel`→`services/PersonaService`→`repositories/PersonaRepository`/`storage/PersonaSelectionStore` | UI→VM→S→Repo |
| 聊天归档导入/导出 | `pages/ChatPage.ets`(菜单) | `viewmodels/ChatArchiveViewModel`→`services/ChatArchiveService`/`ChatArchiveImportService`→`parser/ChatArchiveSchema` | UI→VM→S→parser |
| 聊天背景 | `pages/ChatBackgroundSettingsPage.ets` | `services/ChatBackgroundService` | UI→S |
| 应用设置 / 姓氏称呼 | `pages/AppSettingsPage.ets` | `storage/AppPreferences` | UI→storage |
| 主题切换 | 全页面(@StorageProp effectiveTheme) | `services/ThemeManager`→`theme/ThemePalette` | UI→S |
| Chub 角色卡市场 | `pages/tabs/MarketPage.ets`,`pages/MarketDetailPage.ets` | `viewmodels/Market*/MarketDetailViewModel`→`services/market/` | UI→VM→S→network |
| AI 角色卡生成 | `pages/AiCharacterMakerPage.ets`/`AiCharacterPreviewPage.ets` | `viewmodels/AiCharacter*ViewModel`→`services/ai/AiCharacterGenerationService`→`models/AiCharacterInput` | UI→VM→S |
| AI 世界书 | `pages/LorebookPage.ets` | `services/ai/AiLorebookService`→`models/LorebookAiTypes` | UI→S |
| 云同步 WebDAV | `pages/SyncSettingsPage.ets` | `viewmodels/SyncViewModel`→`services/sync/`→`network/webdav/WebDavClient`→`storage/SyncConfigStore` | UI→VM→S→network |
| DeepSeek 余额 | `pages/ModelSettingsPage.ets`(?) | `services/DeepSeekBalanceService` | UI→S |

## 2. 基础设施定位

| 我想改… | 第一定位文件 |
|--------|-----------|
| 数据库表结构 / 列 | `database/DatabaseConstants.ets` + `database/DatabaseSchema.ets` |
| 新增数据库迁移 | `database/DatabaseMigration.ets`（只增不改，需逐版连续到 v38→v39） |
| 新增 Repository | 仿 `repositories/CharacterRepository.ets`（+同名 Mapper） |
| KV 设置持久化 | 仿 `storage/AppPreferences.ets` / `storage/XXStore.ets` |
| 密钥存取 | `storage/AssetStoreKeyStore.ets` / `storage/ProviderKeyStore.ets` |
| 新增 UI 组件 | `components/`（纯 UI，禁访问网络/DB/安全存储） |
| 路由注册新页面 | `main_pages.json` + `EntryAbility`(首页时才改 loadContent) |
| HTTP 请求 | `network/core/HarmonyHttpClient.ets` |
| SSE 流式解析 | `network/streaming/SseParser.ets`+`OpenAiSseDeltaParser.ets`+`Utf8StreamDecoder.ets` |
| 角色卡 V1/V2/V3 解析 | `parser/CharacterCardJsonParser.ets` |
| PNG 内嵌卡 | `parser/PngCharacterCardParser.ets` |
| 日志 | `utils/Logger.ets` |
| 宏替换 | `services/MacroReplacer.ets` |
| Token 估算 | `services/TokenCounter.ets` |

## 3. 数据模型定位

| 找什么 | 文件 |
|--------|------|
| ChatMessage / MessageSenderType | `models/ChatMessage.ets` |
| Chat / CreateChatOptions | `models/Chat.ets` |
| Character / 默认 system 构建 | `models/Character.ets` |
| ChatRole | `models/ChatRole.ets` |
| ChatGenerationKind（生成类型）| `services/ChatService.ets`（enum 定义在其中） |
| ChatMessageSource / ChatStreamTypes | `models/ChatMessageSource.ets` / `models/ChatStreamTypes.ets` |
| ProviderType / ProviderConfig / ProviderPreset | `models/ProviderType.ets`/`ProviderConfig.ets`/`ProviderPreset.ets` |
| Lorebook / LorebookEntry / LorebookPosition | `models/Lorebook.ets` |
| ChatMemory / MacroContext | `models/ChatMemory.ets`/`MacroContext.ets` |
| PromptSegment / PromptSegmentPosition | `models/PromptSegment.ets` |
| Persona / PersonaPosition | `models/Persona.ets`/`PersonaPosition.ets` |
| ConversationBranch / ChatStatusState | `models/ConversationBranch.ets`/`ChatStatusState.ets` |
| TtsReadMode / TtsEngine | `models/TtsReadMode.ets`/`TtsEngine.ets` |
| AiCharacterInput / AiGenerationResult | `models/AiCharacterInput.ets`/`AiGenerationResult.ets` |
| MarketCharacter* | `models/MarketCharacter*.ets` |
| TokenBudget / ContextBudgetConfig | `models/TokenBudget.ets`/`ContextBudgetConfig.ets` |