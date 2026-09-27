# 05 — Data Flow 数据流地图

> 路径省略 `entry/src/main/ets/`。Examine 全局状态、单例、存储、事件总线。

## 1. 核心聊天数据流（发消息→生成→持久化→UI）

```
用户输入 chatInputText (ChatPage @State)
   ↓ ChatViewModel.inputText（@Observed）
   ↓ viewModel.sendMessage()
   ↓ ChatService.sendMessage(userContent, callbacks)
   ↓     ├─ 校验/防重/空输入
   ↓     ├─ buildEstimateMessages() 预算估算
   ↓     ├─ PromptBuilder.buildPrompt(...)
   │           └─ 读取角色/世界书/记忆/Preset/Persona → 组装 ChatMessage[]
   ↓     ├─ RecentMessageSelector 选取历史窗口
   ↓     └─ ModelService.streamChat(...)   ← AI 唯一出口
   │            └─ OpenAIProvider → OpenAIStreamSession → HttpStreamTransport
   │                 └─ SseParser→OpenAiSseDeltaParser→Utf8StreamDecoder → delta
   ↓ 流式 delta → ChatService 不可变更新 messages
   ↓ callbacks.onMessagesChanged → ChatViewModel.flushMessages
   ↓ ChatPage @State messages/messageStates ← UI 刷新（MaterialAwareness 节流 16ms）
   ↓ 持久化：ChatPersistenceService / MessageSwipePersistenceService（节流 400ms/64字符）
   ↓ 生成完成 → generateStatusFields(状态栏) + 可触发记忆总结
```

## 2. 状态管理（State Management V1）

- `@State`：页面私有（ChatPage 的 messages/messageStates/viewModel）
- `@Observed`：ViewModel（`ChatViewModel` 等），实例由页面持有
- `AppStorage`：全局轻量 KV（App 级、跨页）：
  - `systemDark`（EntryAbility 写入）
  - `statusBarHeight` / `navigationBarHeight`（EntryAbility 计算写入）
  - `effectiveTheme`（@StorageProp 各页面读取，ThemeManager 维护）
  - `characterListVersion` / `chatListVersion`：刷新信号，Index.ets onPageShow 递增
  - `pendingChatId`/`pendingCharacterId`：Tab 间传递会话跳转
- 无 EventBus/Context 全局状态容器；**全局业务状态集中在 AppServices 持有的单例 service/store**。

## 3. 全局状态/单例归属

| 全局对象 | 持有方 | 类型 | 说明 |
|---------|--------|------|------|
| ModelService | AppServices（单例）| 服务 | AI 请求唯一出口 |
| CharacterService/LorebookService/PersonaService/PromptPresetService | AppServices | 服务 | 单例 |
| ChatService | AppServices.createChatService() 新建 | 服务 | 非单例，page 级生命周期 |
| DbHelper（RDB）| AppServices（单例）| 数据库 | 所有 Repository 共享 |
| AppPreferences | AppServices | KV | settings |
| ThemeManager | 单例 | 主题 | 全局主题权威 |
| ProviderKeyStore/AssetStoreKeyStore | AppServices | 密钥 | API Key |

## 4. 数据库写入路径

```
ViewModel → Service → Repository → DbHelper.store → RDB
  例：ChatService → ChatPersistenceService → ChatRepository/MessageRepository → DbHelper
```

数据流转规范：
- Repository 不做业务逻辑、不熟 UI
- 事务操作集中在 `ChatPersistenceOperations` / `ConversationBranchPersistenceService` / `MemoryPersistenceService`
- 迁移统一经 `DbHelper.initialize` → `buildMigrationPath` 逐版执行

## 5. 密钥流（安全存储）

```
ModelService → ProviderKeyStore → AssetStoreKeyStore(@ohos.security.asset)
   写入见 ModelService createConfig/updateConfig（先配后密钥，失败回滚）
```

## 6. 云同步数据流（WebDAV）

```
SyncSettingsPage → SyncViewModel
  → WebDavSyncService（upload/download/sync）
       ├─ SyncDataExporter：导表+prefs+keys+图片 → 计算 hash → 比对 manifest
       ├─ SyncDataImporter：latest-wins 导入（本地缓存 manifest 增量）
       └─ WebDavClient（PUT/PROPFIND/MKCOL/GET/DELETE/MOVE）
  配置在 syncConfigStore（Preferences），密钥走 ProviderKeyStore
  触发：EntryAbility.onCreate autoSync()（见 services/sync）
```

## 7. 谁读/谁写/谁更新 UI（核心数据）

| 数据 | 产生 | 修改 | 保存 | 读取 | 更新 UI |
|------|------|------|------|------|---------|
| 用户消息内容 | ChatPage inputText | ChatViewModel | ChatPersistenceService | ChatService | ChatPage |
| AI 回复 | ModelService(stream) | ChatService(不可变) | Swipe/Persistence | ChatService | ChatPage(+stateMap) |
| 角色卡 | CharacterService/解析器 | CharacterEditViewModel | CharacterRepository | CharacterService | CharacterListVM |
| 世界书 | LorebookService | LorebookViewModel | LorebookRepository | PromptBuilder | LorebookVM |
| 记忆 | MemoryService(总结) | MemoryManagementVM | MemoryPersistenceService | PromptBuilder | MemoryVM |
| 主题 | ThemeManager | 设置/系统 | AppPreferences | 各页面@StorageProp | 全 UI |
| Persona | PersonaService | PersonaViewModel | PersonaRepository | PromptBuilder/MacroReplacer | PersonaVM |