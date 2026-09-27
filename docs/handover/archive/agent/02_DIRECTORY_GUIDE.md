# 02 — Directory Guide 目录职责

> 所有路径相对项目根 `D:\DevEco_studio\ArkTavernSolo`。

## 1. 源码根：`entry/src/main/ets/`

| 目录 | 职责 | 说明 |
|------|------|------|
| `entryability/` | App/Ability 入口 | `EntryAbility.ets`（主）+ `entrybackupability/EntryBackupAbility.ets` |
| `pages/` | 全部二级 UI 页面 | @Entry @Component 结构 |
| `pages/tabs/` | 首页 4 Tab 根视图 | 被 `Index.ets` 内嵌，非独立路由 |
| `components/` | 可复用 UI 组件 | 纯 UI，禁访问网络/DB/安全存储 |
| `viewmodels/` | 页面状态管理 | @Observed 类，页面唯一业务桥梁 |
| `services/` | 业务编排 | 含 `ai/`、`market/`、`sync/` 子域 |
| `models/` | 纯数据模型 | interface/enum + 少量工厂/工具函数 |
| `database/` | RDB 层 | Constants / Schema / Migration / DbHelper |
| `repositories/` | 表级仓储 + 映射 | 直接操作 DbHelper |
| `storage/` | 非关系存储 | Preferences / Asset KeyStore / 内存选择态 |
| `network/` | 网络 | `core/`、`providers/`、`streaming/`、`webdav/` |
| `parser/` | 文件解析 | 角色卡/PNG 卡/聊天归档/文本 |
| `theme/` | 主题令牌 | `ThemePalette.ets` |
| `utils/` | 无状态工具 | Logger/Uuid/Time/Crypto 等 |

## 2. 子域详解

- `services/ai/`：AI 角色卡生成（`AiCharacterGenerationService`）、AI 世界书（`AiLorebookService`）
- `services/market/`：Chub 角色卡市场（`MarketService`/`ChubProvider`/`MarketImportService`/`MarketTranslationService`/缓存 store）
- `services/sync/`：WebDAV 云同步（`WebDavSyncService`/`SyncDataExporter`/`SyncDataImporter`）
- `network/providers/`：AI Provider 抽象 + OpenAI 兼容实现（`AiProvider`/`OpenAIProvider`/`OpenAIStreamSession`/`OpenAITypes`）
- `network/streaming/`：SSE 流式传输与解析（`HttpStreamTransport`/`SseParser`/`OpenAiSseDeltaParser`/`Utf8StreamDecoder`/`OpenAiUrlBuilder`）
- `network/webdav/`：WebDAV 协议客户端（`WebDavClient`/`WebDavModels`）
- `storage/`：
  - Preferences：`AppPreferences`、`ProviderConfigStore`、`Lorebook/PromptPreset/Persona/Character *SelectionStore`、`SyncConfigStore`
  - 密钥：`AssetStoreKeyStore`、`KeyStore`、`ProviderKeyStore`
  - 内存/旧版：`CharacterStore`、`LorebookStore`（仅迁移源）、`CharacterAssetStore`、`CharacterSelectionStore`

## 3. 页面路由（`entry/src/main/resources/base/profile/main_pages.json`，23 条）

| 路由 | 页面 | 主要 ViewModel |
|------|------|--------------|
| `pages/Index` | 首页 4 Tab | （各 Tab ViewModel） |
| `pages/ChatPage` | 聊天主界面 | ChatViewModel |
| `pages/CharacterListPage` | 角色列表 | CharacterListViewModel |
| `pages/CharacterEditPage` | 角色编辑 | CharacterEditViewModel |
| `pages/AddCharacterPage` | 添加角色/导入 | — |
| `pages/LorebookPage` | 世界书 | LorebookViewModel |
| `pages/ModelSettingsPage` | 模型设置 | ModelSettingsViewModel |
| `pages/ModelConfigEditPage` | 模型配置编辑 | ModelSettingsViewModel |
| `pages/AppSettingsPage` | 应用设置 | — |
| `pages/PromptPresetListPage` | 预设列表 | PromptPresetListViewModel |
| `pages/PromptPresetEditPage` | 预设编辑 | PromptPresetEditViewModel |
| `pages/BranchMapPage` | 分支地图 | BranchMapViewModel |
| `pages/ChatBackgroundSettingsPage` | 聊天背景 | ChatBackgroundService |
| `pages/MemoryManagementPage` | 记忆管理 | MemoryManagementViewModel |
| `pages/ContextBudgetPage` | 上下文预算 | ContextBudgetViewModel |
| `pages/MarketDetailPage` | 市场详情 | MarketDetailViewModel |
| `pages/AiCharacterMakerPage` | AI 角色卡生成 | AiCharacterMakerViewModel |
| `pages/AiCharacterPreviewPage` | AI 卡预览 | AiCharacterPreviewViewModel |
| `pages/PersonaListPage` | 用户身份列表 | PersonaViewModel |
| `pages/PersonaEditPage` | 用户身份编辑 | PersonaViewModel |
| `pages/SyncSettingsPage` | 云同步设置 | SyncViewModel |
| `pages/TtsSettingsPage` | TTS 设置 | — |
| `pages/EdgeTtsTestPage` | Edge TTS 测试 | — |

> ⚠ 4 个首页 Tab（`CharacterRootView`/`ChatSessionRootView`/`MarketPage`/`SettingsRootView`）不在 main_pages.json（非路由），由 Index.ets 内嵌。

## 4. 资源

- `AppScope/resources/`：应用级（app_name、icon）
- `entry/src/main/resources/base/`：默认资源（element: color/float/string；profile: main_pages/backup_config；media）
- `entry/src/main/resources/dark/`：深色色板

## 5. 非代码目录

| 路径 | 用途 |
|------|------|
| `docs/` | 文档（`HANDOVER.md` 交接 + `AGENT/` 导航层） |
| `spec/` | 单个 feature 的 spec/plan/tasks（历史较旧） |
| `screenshots/` | 截图 |
| `.deveco/plans/` | DevEco 本地计划（非交付物，勿依赖） |
| `hvigor/`、`build-profile*.json5` | 构建配置 |
| `build_solo_*.log` | 历史构建日志 |