# 08 — Project Status 项目状态矩阵

> 状态依据代码实际实现判断，非文件名猜测。
> 图例：✅稳定 / 🟢已实现 / 🟡部分 / 🔵接口(stub) / 🧪实验 / 🔴Broken / ☠️废弃 / ❓未知

## 1. 核心功能状态

| 功能 | 状态 | 入口文件 | 备注 |
|------|------|---------|------|
| App 启动/初始化 | ✅ | `entryability/EntryAbility.ets`、`services/AppServices.ets` | 稳定 |
| 首页 4 Tab 底部导航 | ✅ | `pages/Index.ets`→`pages/tabs/*` | 稳定 |
| 角色卡 V1/V2/V3 导入/编辑 | ✅ | `parser/CharacterCardJsonParser.ets`、`services/CharacterService.ets` | HEAD 完成 V3 |
| PNG 内嵌卡解析 | ✅ | `parser/PngCharacterCardParser.ets` | ccv3/chara 优先 |
| AI 对话 + SSE 流式 | ✅ | `services/ChatService.ets`→`network/providers/OpenAIStreamSession.ets` | 稳定 |
| 多 Provider 配置/连接测试 | ✅ | `services/ModelService.ets`、`network/providers/` | 稳定 |
| reasoning_content(思考链) | ✅ | `network/providers/OpenAIStreamSession`(HEAD 修复) | 稳定 |
| 消息 Swipe | ✅ | `pages/ChatPage.ets`、`services/MessageSwipePersistenceService.ets` | 稳定 |
| 对话分支 / 分支地图 | ✅ | `pages/BranchMapPage.ets`、`services/ConversationBranchPersistenceService.ets`、`ForkChatService.ets` | 稳定 |
| 世界书 Lorebook | ✅ | `services/LorebookService.ets`、`pages/LorebookPage.ets` | 稳定 |
| 提示词预设 | ✅ | `services/PromptPresetService.ets` | 稳定 |
| 多层记忆(含 AI 总结) | ✅ | `services/MemoryService.ets`、`pages/MemoryManagementPage.ets` | 稳定 |
| 上下文预算管理 | ✅ | `services/ContextBudgetService.ets`、`ContextBudgetEstimator.ets` | 稳定 |
| Persona 用户身份 | ✅ | `services/PersonaService.ets`、`pages/Persona*` | 稳定(v35) |
| 代写 Impersonate | 🟢已实现/🟡点击待验 | `pages/ChatPage.ets`、`components/ImpersonateCandidatesPanel.ets`、`ChatService.generateImpersonateCandidates` | HitTestMode 待真机验证 |
| 旁白 Narrator | 🟢已实现/🟡部分 | `ChatService.narratorMessage(Only)`、`components/ChatMessageActionSheet` | 记忆过滤/双按钮已实现，综合验证中 |
| AI 续写/重生成 | ✅ | `ChatService.regenerate*/continueFromAssistant` | 稳定 |
| 用户性格总结 | 🟢已实现 | `ChatService.extractUserFromCharacter/summarizeUserPersona`(v36) | prompt 效果待迭代 |
| 消息流的 includeInMemory 过滤 | ✅ | `MemoryService.formatMessages`(v37) | 稳定 |
| 角色 nickname | ✅ | `database/DatabaseSchema`(v38) | 最新迁移 |
| 聊天归档导出/导入 | ✅ | `services/ChatArchiveService(.ets Import)`、`parser/ChatArchiveSchema.ets` | 稳定 |
| 聊天背景 | ✅ | `services/ChatBackgroundService.ets` | 稳定 |
| Chub 角色卡市场 | ✅ | `services/market/`、`pages/tabs/MarketPage.ets` | 依赖外部网络 |
| AI 角色卡生成 | 🟢已实现 | `services/ai/AiCharacterGenerationService.ets`、`pages/AiCharacter*` | 实验性较弱 |
| AI 世界书 | 🟢已实现 | `services/ai/AiLorebookService.ets` | 实验性 |
| WebDAV 云同步(坚果云) | ✅ | `services/sync/WebDavSyncService.ets` | 稳定，见 09 限制 |
| DeepSeek 余额查询 | ✅ | `services/DeepSeekBalanceService.ets` | 稳定 |
| 离线 TTS | ✅ | `services/TtsService.ets` | @kit.CoreSpeechKit |
| Edge 在线 TTS | 🟢已实现/🟡开发中 | `services/EdgeTtsService.ets`、`pages/TtsSettingsPage.ets`、`EdgeTtsTestPage` | **有未提交改动（见下）** |

## 2. 已废弃 / 预留

| 功能 | 状态 | 说明 |
|------|------|------|
| worlds 世界书旧表（goods/worlds） | ☠️已从 UI 移除 | 数据库表仍在（迁移只增不改），勿再依赖 |
| Legacy lorebook 迁移 | 🔵 | `LorebookMigrationService` 迁移 v1 格式兼容保留 |
| 群聊/多人聊天 | ❓预留 | `models/ConversationMode.ets`、`chat_participants` 表、`GroupReplyModeSetting` 已建，UI 未实现（见 ROADMAP Phase 3） |

## 3. 当前开发中（工作区未提交）

`git status` 显示未提交修改：
- `pages/TtsSettingsPage.ets`、`services/EdgeTtsService.ets`（711 insertions / 305 deletions）

→ **最近正在开发 TTS 设置页 + Edge 在线 TTS 引擎**，尚未提交。接手前先 `git diff` 看现有改动再继续。

## 4. 构建健康度

- `build_solo_4.log`：`hvigor BUILD SUCCESSFUL`
- 仅有 deprecation / throw 告警（如 AiCharacterPreviewPage showToast），无阻断错误。
- 编码检查：`arkts_check`；编译：`entry@default` 增量；**同一编译命令最多 3 次**（见 HANDOVER §12）。