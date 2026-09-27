# 03 — Module Index 模块索引（文件→职责→依赖→风险）

> 所有路径省略 `entry/src/main/ets/` 前缀。风险等级：🚨高（核心/大文件/易踩坑）、⚠️中、·低。

## 1. 核心文件 Top（Core Files）

| 文件 | 职责 | 关键符号 | 上游调用者 | 下游依赖 | 风险 |
|------|------|---------|-----------|---------|------|
| `entryability/EntryAbility.ets` | App 生命周期、初始化、加载首页 | `EntryAbility extends UIAbility` | 系统 | AppServices | 🚨入口 |
| `services/AppServices.ets` | 全依赖组合根（唯一）| `initialize/whenReady/getInstance/createChatService` | 所有页面/VM | 全部 services/repo/storage | 🚨装配中心 |
| `pages/Index.ets` | 首页 4 Tab | `struct Index`（HdsTabs）| EntryAbility | 4 个 tabs/RootView | 🚨 |
| `services/ChatService.ets` | 聊天全流程编排 | `ChatService.sendMessage/sendImpersonate/narratorMessage/doStream/sendMessage` | ChatViewModel | ModelService、PromptBuilder、各持久化服务 | 🚨超大 |
| `viewmodels/ChatViewModel.ets` | 聊天页面状态 | `ChatViewModel`（@Observed）| ChatPage | ChatService、ModelService、Character/Lorebook/PromptPresetService | 🚨 |
| `pages/ChatPage.ets` | 聊天 UI | `struct ChatPage` | Index/router | ChatViewModel、components | 🚨约4400行 |
| `services/PromptBuilder.ets` | prompt 组装 | `PromptBuilder.buildPrompt` | ChatService | LorebookService、MacroReplacer、models | 🚨 |
| `services/ModelService.ets` | AI 请求唯一出口 | `ModelService.createConfig/updateConfig/.../streamChat` | 聊天/翻译/生成 | ProviderConfig/KeyStore/Factory | 🚨 |
| `services/ProviderFactory.ets` | Provider 工厂 | `DefaultProviderFactory` | ModelService | OpenAIProvider | ⚠️ |
| `database/DatabaseConstants.ets` | DB 常量 | `DATABASE_VERSION=38`、表/列常量 | 全部 database/repo | — | 🚨版本权威 |
| `database/DatabaseMigration.ets` | 迁移框架 | `v1→v38` 迁移类 | DbHelper | DatabaseSchema | 🚨只增不改 |
| `models/ChatMessage.ets` | 消息模型 | `ChatMessage`、`MessageSenderType`、`createChatMessage/mergeChatMessage` | 全层 | — | 🚨 |
| `models/Character.ets` | 角色模型 | `Character`、`buildDefaultCharacterSystemContent` | 全层 | — | ⚠️ |

## 2. ChatService 核心方法速查（成员行号）

- `initializeSession(character, forceNew)` / `sendMessage(userContent, callbacks)` → 普通消息
- `sendImpersonate`（代写）/ `generateImpersonateCandidates()` → 代写候选
- `narratorMessage` / `narratorMessageOnly` → 旁白（仅插入 / 插入+生成）
- `autoContinue` / `continueFromAssistant` / `regenerate*` → 续写/重生成
- `extractUserFromCharacter` / `summarizeUserPersona` → 用户性格总结
- `stopGeneration` / `clearConversation` / `switchSession` / `deleteSession`
- `activatePrevious/NextCandidate` / `generateAlternativeCandidate` → Swipe
- `switchBranch` / `forkChat`（经 ForkChatService）→ 分支
- `dispose` → 页面销毁

## 3. ViewModel 索引（33 个）

| ViewModel | 供页面 | 核心依赖 |
|-----------|--------|---------|
| ChatViewModel | ChatPage | ChatService、ModelService、Character/PromptPreset/Lorebook/AiLorebookService |
| CharacterListViewModel | CharacterListPage/CharacterRootView | CharacterService |
| CharacterEditViewModel | CharacterEditPage | CharacterService |
| ModelSettingsViewModel | ModelSettingsPage/ModelConfigEditPage | ModelService |
| PromptPresetList/EditViewModel | Preset 页 | PromptPresetService |
| LorebookViewModel | LorebookPage | LorebookService、AiLorebookService |
| MemoryManagementViewModel | MemoryManagementPage | MemoryService、MemoryPersistenceService |
| ContextBudgetViewModel | ContextBudgetPage | ContextBudgetService、TokenCounter |
| BranchMapViewModel | BranchMapPage | ConversationBranchPersistenceService |
| MarketViewModel/MarketDetailViewModel | MarketPage/MarketDetailPage | MarketService、MarketTranslation/ImportService |
| AiCharacterMakerViewModel/AiCharacterPreviewViewModel | AiCharacter*Page | ModelService、CharacterService |
| PersonaViewModel | PersonaList/EditPage | PersonaService |
| SyncViewModel | SyncSettingsPage | SyncConfigStore、WebDavSyncService |
| ChatSessionListViewModel | ChatSessionRootView | ChatPersistenceService、CharacterService |
| ChatArchiveViewModel | ChatPage(导出/导入) | ChatArchiveService/ImportService |
| CharacterExportViewModel | CharacterEditPage(导出) | CharacterService |
| AiCharacter* | — | ModelService |

## 4. Service 层索引

| 服务 | 职责 |
|------|------|
| `ChatService` | 聊天编排（见上） |
| `ChatPersistenceService` | 会话/消息持久化协调 |
| `MessageSwipePersistenceService` | Swipe 候选持久化 |
| `ConversationBranchPersistenceService` | 分支持久化 |
| `MemoryService` / `MemoryPersistenceService` | 多层记忆 + 持久化 |
| `ContextBudgetService` / `ContextBudgetEstimator` / `ContextBudgetSnapshotStore` | token 预算 |
| `LorebookService` / `LorebookMigrationService` | 世界书 |
| `PromptPresetService` / `PromptPresetRuntimeResolver` | 提示词预设 |
| `CharacterService` / `CharacterMigrationService` | 角色 CRUD/导入迁移 |
| `PersonaService` | 用户身份 |
| `ModelService` | AI 请求（唯一出口） |
| `MacroReplacer` | 宏替换（{{user}}/{{char}} 等） |
| `TokenCounter` / `HistoryTrimmer` / `RecentMessageSelector` | 上下文管理 |
| `ChatBackgroundService` | 聊天背景图 |
| `ChatArchiveService`/`ImportService` | 归档导入导出 |
| `ForumChatService` (`ForkChatService`) | 分支创建独立对话 |
| `ThemeManager` | 全局主题 |
| `DeepSeekBalanceService` | DeepSeek 余额 |
| `TtsService` / `EdgeTtsService` | 离线/在线 TTS |
| `AiCharacterGenerationService` / `AiLorebookService` | AI 生成角色卡/世界书 |
| `MarketService`/`MarketImportService`/`MarketTranslationService` | 市场 |
| `WebDavSyncService`/`SyncDataExporter`/`SyncDataImporter` | 云同步 |

## 5. Repository → 表

| Repository | 对应表 |
|-----------|--------|
| CharacterRepository | characters |
| ChatRepository | chats |
| MessageRepository | messages |
| MessageSwipeRepository | message_swipe_groups / message_swipe_candidates |
| ConversationBranchRepository | conversation_branches / chat_branch_state / conversation_branch_messages / conversation_branch_swipe_selections |
| ChatParticipantRepository | chat_participants |
| ChatMemoryRepository | chat_memories |
| LorebookRepository | lorebooks / lorebook_entries |
| PromptPresetRepository | prompt_presets |
| PersonaRepository | personas |

## 6. 高风险 / 大文件清单

| 文件 | 风险 |
|------|------|
| `services/ChatService.ets` | 超大（5000+ 行），核心逻辑密集，改前必读 `docs/HANDOVER.md` §9 陷阱 |
| `pages/ChatPage.ets` | 约 4400+ 行，改时保持花括号平衡，Relation 复杂 |
| `viewmodels/ChatViewModel.ets` | 状态多、方法多，改状态需同步 ChatService |
| `models/Character.ets`、`models/ChatMessage.ets` | 被全层引用，字段变更影响面大 |
| `services/PromptBuilder.ets` | 消息顺序/来源标记逻辑密集 |
| `database/DatabaseMigration.ets` | 迁移只增不改，新增版本需逐版连续 |

> 完整文件清单即为目录结构本身（见 `02_DIRECTORY_GUIDE.md`），此处列出的是定位关键的高价值文件。