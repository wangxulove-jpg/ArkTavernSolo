# ArkTavernSolo 交接文档

> 本文档供新会话的 Agent 快速理解项目全貌，接续未完成的目标。

---

## 1. 项目概览

| 项目 | 值 |
|------|-----|
| 名称 | ArkTavernSolo |
| 路径 | `D:\DevEco_studio\ArkTavernSolo` |
| 包名 | `com.example.arktavernsolo` |
| 平台 | HarmonyOS NEXT (API 24 / SDK 6.1.1) |
| 语言 | ArkTS |
| 框架 | ArkUI |
| IDE | DevEco Studio 6+ |
| 数据库 | `arktavern_solo.db`，当前版本 36 |
| 用途 | 原生 HarmonyOS AI 角色扮演客户端（单人聊天），参考 SillyTavern 逻辑 |

**与 ArkTavern 的关系**：ArkTavern 是完整版（含群聊/世界/AvatarAI/VRM），ArkTavernSolo 是精简版（仅单人聊天）。两者可同设备共存，数据隔离（所有存储前缀 `arktavern_solo`）。

---

## 2. 目录结构

```
entry/src/main/ets/
├── components/          # 可复用 UI 组件（禁止访问网络/数据库/安全存储）
│   ├── common/          # 通用小组件
│   ├── home/            # 首页 Tab 子组件
│   ├── navigation/      # 导航栏组件
│   ├── AppPageHeader.ets
│   ├── BranchMapNode.ets
│   ├── ChatMessageBubble.ets     # 聊天气泡（含 narratorBubble/impersonateBubble/TTS 按钮）
│   ├── ChatSessionListPanel.ets  # 聊天会话列表面板
│   ├── ImpersonateCandidatesPanel.ets  # 代写候选面板（竖向布局，悬浮于输入区上方）
│   ├── PressableCard.ets
│   └── ...
├── database/            # 数据库层
│   ├── DatabaseConstants.ets     # 表名/列名/索引名常量（版本 36）
│   ├── DatabaseMigration.ets     # 迁移框架（v1→v36）
│   ├── DatabaseSchema.ets        # 建表/建索引 SQL
│   └── DbHelper.ets              # RDB 辅助工具
├── entryability/
├── models/              # 纯数据模型
│   ├── Character.ets
│   ├── Chat.ets                   # 含 userPersonaSummary / userPersonaSummaryUpdatedAt
│   ├── ChatMessage.ets            # MessageSenderType: 'user'|'character'|'narrator'
│   ├── ChatMessageRenderState.ets # 含 senderType 字段
│   ├── ChatMessageSource.ets      # 含 NarratorInstruction source
│   ├── ChatGenerationKind.ets     # 含 Impersonate/AutoContinue/Narrator/ContinueGeneration
│   ├── ImpersonateCandidate.ets   # { index: number, content: string }
│   ├── TtsReadMode.ets            # Off/All/QuotesOnly
│   ├── Lorebook.ets
│   ├── PromptSegment.ets
│   ├── MacroContext.ets
│   ├── PromptPreset.ets
│   └── ...
├── network/             # 网络层
│   ├── core/
│   ├── providers/
│   └── streaming/
├── pages/
│   ├── ChatPage.ets              # 聊天主页面（含代写候选面板 + TTS + 旁白 + 用户性格总结UI）
│   ├── AppSettingsPage.ets       # 含 TTS 设置区
│   └── ...
├── repositories/
├── services/
│   ├── ChatService.ets           # 含 generateImpersonateCandidates/extractUserFromCharacter/summarizeUserPersona
│   ├── ChatPersistenceService.ets # 含 updateUserPersonaSummary
│   ├── PromptBuilder.ets         # 含 narrator→NarratorInstruction source 分发
│   ├── TtsService.ets            # TTS 引擎封装
│   └── ...
├── storage/
├── theme/
├── utils/
├── viewmodels/
│   ├── ChatViewModel.ets         # 含 impersonate/persona summary 状态与方法
│   └── ...
└── docs/
```

---

## 3. 核心架构约束

### 3.1 分层依赖方向

```
pages/ → viewmodels/ → services/ → repositories/ → database/
                              ↓              ↓
                         storage/        network/
```

**禁止**：
- `pages/` 直接调用 `AssetStoreKeyStore`、`HttpStreamTransport`、任何 `network/` 模块
- `pages/` 直接调用任何 `services/` 或 `repositories/`
- `viewmodels/` 直接依赖 `@ohos.net.http` 或 `@ohos.security.asset`
- `components/` 访问网络、数据库、安全存储
- `services/` 引用具体页面类
- Provider 直接操作 UI 状态

### 3.2 编码规则

- 不使用 barrel export（禁止 `index.ets`），直接相对路径导入
- 不使用 `any` / `unknown` / `as` 类型断言
- 数据库迁移只增不改（禁止 DROP TABLE）
- `@Builder` 方法内禁止 `const`/`let`
- 保持 State Management V1
- 对象字面量需显式类型上下文（typed variable 或 typed parameter）

---

## 4. 已完成功能

### 基础功能
- 角色卡导入/编辑（V1/V2/V3 规范）
- 聊天会话管理（创建/删除/重命名/归档/导出）
- OpenAI 兼容 API 对接 + SSE 流式生成
- 世界书关键词匹配注入
- 提示词预设系统
- 多层记忆系统
- 对话分支 + 分支地图
- 消息 Swipe
- Token 预算估算 + 对话上下文预算管理
- Persona 系统（用户身份管理）
- WebDAV 增量同步（坚果云）
- DeepSeek 余额查询

### 代写功能重设计（v2 — 已完成）
- **废弃旧版内嵌气泡方案**：不再将代写结果渲染为聊天气泡
- **ImpersonateCandidatesPanel**：竖向候选面板，悬浮于输入区上方
  - 竖向排列 3 个候选，自适应高度
  - `.clip(false)` 允许溢出，`.hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)` 拦截点击
  - 父容器 Column 设 `HitTestMode.None`（空白区域穿透到消息列表）
- **generateImpersonateCandidates()**：独立轻量请求
  - 只取最近 6 条消息，不调用 `buildRequestMessages()`（避免角色卡污染）
  - User/Assistant 角色互换（让模型自然以用户视角写）
  - 专用 system prompt：强调 3 条独立的不同回复，非同一段落
  - 不使用 `responseFormatJson`（部分国产模型 JSON 模式返回空 `[]`）
  - `maxTokens` 跟随 effectiveSettings（默认 4096），不再硬编码
- **parseImpersonateCandidates()**：解析 `1.\n2.\n3.` 格式，逐行提取
- **ChatPage 布局**：
  - 面板位于外层 Column（不在 inputArea 的 borderRadius 容器内）
  - 底部 spacer 动态计算：`120 + navBar + keyboardHeight + (panelVisible ? 150 : 0)`

### 用户性格总结系统（已完成）
- **数据库 v36 迁移**：
  - `chats` 表新增 `user_persona_summary TEXT DEFAULT ''` 和 `user_persona_summary_updated_at INTEGER DEFAULT 0`
  - `V35ToV36Migration` 类，ALTER TABLE 增量迁移，安全不影响现有数据
- **Chat 模型**：`userPersonaSummary: string` + `userPersonaSummaryUpdatedAt: number`
- **ChatRepository**：`chatFromRow()` 用 `getColumnIndex >= 0` 安全回退兼容旧 schema
- **ChatService 三个新方法**：
  - `extractUserFromCharacter()`：分析角色卡提取用户身份特征（temperature 0.3, maxTokens 512, stream false）
  - `summarizeUserPersona()`：总结用户发言性格风格（同上参数，读取全部用户消息，超 4000 字符截断）
  - `updateCurrentChatUserPersonaSummary(summary)`：持久化并更新 currentChat
- **ChatPersistenceService**：`updateUserPersonaSummary(chatId, summary)` — 读取现有 chat → updateChat → repository.update
- **ChatViewModel**：
  - `isExtractingUserPersona` / `isSummarizingUserPersona` 状态
  - `extractUserFromCharacter()` / `summarizeUserPersona()` — 两次提取结果**合并追加**（非覆盖），去重检测
  - `clearUserPersonaSummary()` — 清空总结
  - `userPersonaSummary` getter — 通过 `chatService.getCurrentChat()` 读取
- **代写 prompt 注入**：当 `userPersonaSummary` 非空时，注入 `{{userName}}的性格特征：{summary}`
- **personaPickerSheet UI**：
  - Persona 描述 `maxLines(3)`（原 maxLines(1) 看不到完整内容，已修复）
  - 底部新增"用户性格总结"区域：显示摘要（maxLines(8)）+ 操作按钮
  - "从角色卡提取" / "从对话总结" / "清除"（红色 app_danger 色，仅在有摘要时显示）
  - LoadingProgress 指示器

### TTS 语音朗读
- TtsService 基于 `@kit.CoreSpeechKit` 离线引擎
- 三种朗读模式：Off / All / QuotesOnly
- ChatMessageBubble TTS 按钮
- TTS 设置持久化 + WebDAV 同步支持

### AI 续写功能（旧版，已被代写重设计替代部分）
- ChatGenerationKind: Impersonate / AutoContinue / Narrator / ContinueGeneration
- ChatService: autoContinue() / narratorMessage() / continueGeneration()
- narratorBubble / impersonateBubble 渲染
- 旁白输入模式

---

## 5. 关键设计决策

### 代写功能
| 决策 | 原因 |
|------|------|
| 废弃 `responseFormatJson` | 很多国产模型 JSON 模式返回空 `[]` |
| 不复用 `buildRequestMessages()` | 完整角色卡 prompt 污染用户视角生成 |
| 角色互换 (User↔Assistant) | 让模型自然以用户视角写 |
| 只取最近 6 条消息 | 轻量、聚焦、节省 token |
| prompt 用实际 userName/charName | 避免 `{{user}}`/`{{char}}` 宏解析问题 |

### 用户性格总结
| 决策 | 原因 |
|------|------|
| Per-chat 存储（Chat 模型字段） | 最简单，分支共享同一 Chat 记录 |
| 手动触发（非自动） | 避免额外 API 开销，用户按需生成 |
| 两次提取合并追加 | 角色卡提取 + 对话总结互补，不互相覆盖 |
| 去重检测 (`includes`) | 防止重复点击导致相同内容重复追加 |
| temperature 0.3, maxTokens 512 | 低温度保证分析质量，512 足够 2-3 句总结 |
| 读取全部用户消息（不限制 20 条） | 更全面的性格分析 |
| 超 4000 字符截断 | 兼顾 token 预算 |

### HitTestMode 布局
| 层级 | HitTestMode | 作用 |
|------|------------|------|
| 外层悬浮 Column | None | 自身不响应点击，不阻挡子组件 |
| ImpersonateCandidatesPanel | BLOCK_HIERARCHY | 拦截面板内所有点击，防止穿透 |

---

## 6. 消息三层体系（关键上下文）

| 层 | 枚举/类型 | 值 |
|----|----------|-----|
| Wire (网络) | `ChatRole` | `system` / `user` / `assistant` |
| DB (数据库) | `MessageSenderType` | `'user'` / `'character'` / `'narrator'` |
| UI (界面) | `ChatSenderType` (ChatRichText.ets) | 对应渲染类型 |

### 各功能消息映射

| 功能 | role | senderType | senderCharacterId | 说明 |
|------|------|-----------|-------------------|------|
| 普通用户消息 | User | 'user' | (空) | 正常 |
| 普通AI回复 | Assistant | 'character' | 角色ID | 正常 |
| Impersonate | User | 'character' | 角色ID | AI 代写用户说的话 |
| AutoContinue-impersonate | User | 'character' | 角色ID | 同 impersonate |
| AutoContinue-response | Assistant | 'character' | 角色ID | 同普通回复 |
| Narrator | System | 'narrator' | (空) | 旁白叙述 |
| ContinueGeneration | Assistant | 'character' | 角色ID | 续写，复用最后一条消息 |

---

## 7. 数据库状态

- **版本**: 36
- **关键表**: characters, chats, messages, message_swipe_groups, message_swipe_candidates, conversation_branches, chat_branch_state, conversation_branch_messages, conversation_branch_swipe_selections, chat_participants, lorebooks, lorebook_entries, prompt_presets, chat_memories, personas
- **注意**: worlds 及相关表已从 UI 删除但数据库表仍在（迁移只增不改）

### chats 表新增列 (v36)

| 列 | 类型 | 默认值 | 说明 |
|----|------|--------|------|
| `user_persona_summary` | TEXT | '' | 用户性格总结文本 |
| `user_persona_summary_updated_at` | INTEGER | 0 | 最后更新时间戳 |

### messages 表 sender 相关列

| 列 | 类型 | 说明 |
|----|------|------|
| `sender_type` | TEXT | 'user' / 'character' / 'narrator' |
| `sender_character_id` | TEXT | senderType='character' 时必填，其他时必须为空 |

---

## 8. 已知问题 / 待验证

### 代写候选面板点击（待真机验证）
- **现状**：HitTestMode.BLOCK_HIERARCHY 已部署但未在真机验证
- **预期**：面板内按钮可点击，面板外空白区域点击穿透到消息列表
- **如不生效**：检查 ArkUI 版本对 BLOCK_HIERARCHY 的支持，备选方案改用 BindSheet

### 其他待验证
- 旁白模式输入后发送是否正常工作
- AutoContinue 两步串行是否正确串接
- TTS 引擎在真机上的初始化和播放
- 用户性格总结 AI 提取/总结的实际效果（prompt 可能需迭代）
- 两次提取合并后的摘要质量（可能过长需截断）

---

## 9. 已知陷阱

1. **ChatPage.ets 约 4400+ 行**：编辑时必须严格保持花括号平衡
2. **`@Builder` 方法内禁止 `const`/`let`**：用私有方法或内联表达式替代
3. **数据库迁移只增不改**：已删功能的表仍保留
4. **ArkTS 限制**：禁止 `as` 类型断言、禁止 `any`、禁止动态属性访问、对象字面量需显式类型上下文
5. **senderType='character' 必须填 senderCharacterId**：否则 MessageRepository 校验会抛 `invalid data`
6. **两个 App 共存**：所有存储前缀必须用 `arktavern_solo`
7. **ChatService.currentChat 是 private**：外部通过 `getCurrentChat()` 访问
8. **ChatRequest.temperature/topP 是 number（非 optional）**：从 EffectiveGenerationSettings 传入时需提供默认值
9. **ProviderConfig 用 maxTokens / EffectiveGenerationSettings 用 maxOutputTokens**：注意字段名差异
10. **chatFromRow() 用 getColumnIndex >= 0 安全回退**：新增列在旧 schema 上不会崩溃

---

## 10. 关键文件索引

| 文件 | 关键内容 |
|------|---------|
| `models/Chat.ets` | Chat interface + CreateChatOptions + ChatUpdates（含 userPersonaSummary） |
| `models/ImpersonateCandidate.ets` | `{ index: number, content: string }` |
| `components/ImpersonateCandidatesPanel.ets` | 竖向候选面板，BLOCK_HIERARCHY |
| `services/ChatService.ets` | generateImpersonateCandidates / extractUserFromCharacter / summarizeUserPersona / updateCurrentChatUserPersonaSummary |
| `services/ChatPersistenceService.ets` | updateUserPersonaSummary |
| `viewmodels/ChatViewModel.ets` | impersonate 状态 + persona summary 状态与方法 |
| `pages/ChatPage.ets` | 面板布局 + personaPickerSheet 用户性格总结 UI |
| `repositories/ChatRepository.ets` | chatFromRow/chatToBucket 含新列映射 |
| `database/DatabaseConstants.ets` | v36 列常量 + ALTER 语句，DATABASE_VERSION=36 |
| `database/DatabaseSchema.ets` | CREATE_CHATS_TABLE 更新，V35_TO_V36/V36_SCHEMA |
| `database/DatabaseMigration.ets` | V35ToV36Migration 类 |
| `database/DbHelper.ets` | v36 迁移在数组中 |

---

## 11. 下一步行动

### 立即：真机验证
1. 代写候选面板点击是否正常
2. 用户性格总结提取/总结功能是否工作
3. 代写 prompt 注入 userPersonaSummary 后生成效果
4. TTS、旁白、续写功能

### 然后：根据验证结果迭代
- 代写 prompt 迭代（当前版本强调 3 条独立回复，可能仍被模型忽略）
- 用户性格总结 prompt 迭代（实际效果可能需调整）
- 合并后摘要过长时的截断策略

### 后续：世界观构建能力增强
- 详见 `docs/WORLD_BUILDING_ROADMAP.md`

---

## 12. 快速验证规则

1. 编码过程中只做静态检查（`arkts_check`）
2. 完成一批相关修改后，执行一次 `entry@default` 增量编译
3. 默认禁止 clean build（仅缓存异常时允许）
4. 同一编译命令最多 3 次
5. 同一设备测试最多 2 次
