# 01 — Architecture Map 架构地图

## 1. 分层架构（严格单向依赖）

```
┌──────────────────────────────────────────────────────────────┐
│ pages/  (UI 页面 + tabs/ 根视图)                                │
└──────────────┬───────────────────────────────────────────────┘
               │ 只调用 ViewModel / AppServices 静态方法 + router
┌──────────────▼───────────────────────────────────────────────┐
│ viewmodels/  (@Observed 状态管理，页面唯一业务桥梁)              │
└──────────────┬───────────────────────────────────────────────┘
               │ 只调用 services / 不依赖网络层 / 不依赖 Provider
┌──────────────▼───────────────────────────────────────────────┐
│ services/  (业务编排 + 组合根 AppServices)                      │
└───────┬──────────────────────────┬───────────────────────────┘
        │                          │
┌───────▼──────────┐   ┌──────────▼───────────────┐
│ repositories/    │   │ storage/                  │
│ (仓库→database)  │   │ (Preferences/KeyStore/内存)│
└───────┬──────────┘   └──────────┬────────────────┘
        │                         │
┌───────▼──────────┐   ┌──────────▼───┐   ┌────────────────┐
│ database/ (RDB)   │   │ network/     │   │ parser/ (纯逻辑) │
└──────────────────┘   └──────────────┘   └────────────────┘
```

**禁止跨层**：`pages` 不能直接调 `network/`、`services/repositories`；`viewmodels` 不能碰 `@ohos.net.http` / `@ohos.security.asset`；`components` 默认纯 UI（禁访问网络/DB/安全存储），只能作为展示组件被页面引用。

## 2. 入口与生命周期

```
EntryAbility (UIAbility, module.json5 mainElement)
  onCreate:
    - 读系统深色模式 → AppStorage.setOrCreate('systemDark')
    - AppServices.initialize(context)   ← 完整装配 + 各服务 migrateIfNeeded
    - triggerAutoSync()                 ← WebDAV 自动同步（条件见 services/sync）
  onWindowStageCreate:
    - 计算状态栏/导航栏高度 → AppStorage
    - loadContent('pages/Index')
    - 设置键盘回避模式 / 系统栏颜色
```

## 3. UI 结构

- `pages/Index.ets`：@Entry 首页，用 **HdsTabs**（@kit.UIDesignKit）做沉浸式底部导航，4 个 Tab：
  - Tab1 **角色卡** `tabs/CharacterRootView.ets`
  - Tab2 **对话记录** `tabs/ChatSessionRootView.ets`
  - Tab3 **市场** `tabs/MarketPage.ets`
  - Tab4 **设置** `tabs/SettingsRootView.ets`
- 二级页面用 `router.pushUrl('pages/XXX')`（路由清单见 `main_pages.json`）
- 页面内部结构：`TabContent` 分「不透明背景层」+「内容层」

## 4. 核心数据流分层职责

| 层 | 职责 | 关键文件 |
|----|------|---------|
| components | 纯渲染 UI 单元 | `ChatMessageBubble`、`ChatSessionListPanel` 等 |
| pages | 页面装配、router、事件→ViewModel | `Index`、`ChatPage`、`CharacterListPage`... |
| viewmodels | 绑定 @Observed 状态、调 service、防抖 | `ChatViewModel`、`CharacterListViewModel`... |
| services | 业务编排、AI 生成、记忆、同步、主题 | `ChatService`、`ModelService`、`PromptBuilder`、`AppServices` |
| repositories | 表级 CRUD + 实体映射 | `ChatRepository`、`MessageRepository`、`CharacterRepository` |
| storage | 非关系持久化/密钥/选择态 | `AppPreferences`、`*Store`、`*KeyStore` |
| database | RDB schema + 迁移 + helper | `DatabaseConstants/Schema/Migration/DbHelper` |
| network | HTTP / 流式 / provider / webdav | `HarmonyHttpClient`、`OpenAIProvider`、`SseParser`、`WebDavClient` |
| parser | 角色卡/PNG/归档纯解析 | `CharacterCardJsonParser`、`PngCharacterCardParser`、`ChatArchiveSchema` |
| models | 纯数据模型（无 IO） | `Character`、`ChatMessage`、`Chat`、`Lorebook`... |
| utils | 无状态工具 | `Logger`、`Uuid`、`Time`、`CryptoHelper` |
| theme | 主题令牌 | `ThemePalette` |

## 5. 依赖装配（关键）

`services/AppServices.ets` 是唯一组合根（最小、静态、幂等）：
- 大部分服务为**应用级单例**（ModelService、CharacterService、PromptBuilder、database/repository/storage 共享实例）
- `ChatService` **不是单例**：由 `AppServices.createChatService()` 每次进入 ChatPage 时新建，保证生命周期独立
- 页面通过 `AppServices.getInstance()/getXxx()` 静态方法取用，`whenReady()` 等待初始化
- ChatViewModel/其他 VM 由页面直接 `new` 创建，依赖注入来自 AppServices

## 6. 核心枢纽（依赖集中点）

- `services/AppServices.ets` — 全依赖装配中心
- `services/ModelService.ets` — 所有 AI 请求唯一出口（页面/服务不直接碰 Provider/KeyStore）
- `services/ChatService.ets` — 聊天编排核心（被 ChatViewModel 独占使用，部署最多能力）
- `database/DbHelper.ets` — 所有 Repository 共享同一 RDB 实例
- `utils/Logger.ets` — 全项目日志门面