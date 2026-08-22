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
| 数据库 | `arktavern_solo.db`，当前版本 35 |
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
│   ├── BranchMapNode.ets         # 分支地图节点
│   ├── ChatMessageBubble.ets     # 聊天气泡（含 narratorBubble/impersonateBubble/TTS 按钮）
│   ├── ChatSessionListPanel.ets  # 聊天会话列表面板
│   ├── PressableCard.ets
│   └── ...
├── database/            # 数据库层
│   ├── DatabaseConstants.ets     # 表名/列名/索引名常量（版本 35）
│   ├── DatabaseMigration.ets     # 迁移框架（v1→v35）
│   ├── DatabaseSchema.ets        # 建表/建索引 SQL
│   └── DbHelper.ets              # RDB 辅助工具
├── entryability/
├── models/              # 纯数据模型
│   ├── Character.ets
│   ├── Chat.ets
│   ├── ChatMessage.ets           # MessageSenderType: 'user'|'character'|'narrator'
│   ├── ChatMessageRenderState.ets # 含 senderType 字段
│   ├── ChatMessageSource.ets     # 含 NarratorInstruction source
│   ├── ChatGenerationKind.ets    # 含 Impersonate/AutoContinue/Narrator/ContinueGeneration
│   ├── TtsReadMode.ets           # Off/All/QuotesOnly
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
│   ├── ChatPage.ets              # 聊天主页面（含代写/续写/旁白/继续按钮 + TTS + 旁白输入模式）
│   ├── AppSettingsPage.ets       # 含 TTS 设置区
│   └── ...
├── repositories/
├── services/
│   ├── ChatService.ets           # 含 impersonate/autoContinue/narratorMessage/continueGeneration
│   ├── PromptBuilder.ets         # 含 narrator→NarratorInstruction source 分发
│   ├── TtsService.ets            # TTS 引擎封装
│   ├── DeepSeekBalanceService.ets
│   └── ...
├── storage/
├── theme/
├── utils/
├── viewmodels/
│   ├── ChatViewModel.ets         # 含 impersonate/autoContinue/sendNarrator/continueGeneration
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

### Persona + WebDAV 同步
- Persona 系统（用户身份管理）
- WebDAV 增量同步（坚果云）
- 同步设置持久化修复
- DeepSeek 余额查询

### AI 续写功能（刚完成）
- **ChatGenerationKind 枚举扩展**：新增 `Impersonate` / `AutoContinue` / `Narrator` / `ContinueGeneration`
- **ChatService 四个新方法**：
  - `impersonate()`：AI 代写用户消息（`role=User, senderType='character'`）
  - `autoContinue()`：两步串行生成（先 impersonate 再 response）
  - `narratorMessage()`：旁白叙述（`role=System, senderType='narrator'`）
  - `continueGeneration()`：续写最后一条 AI 消息
- **doStream 指令注入**：Impersonate/AutoContinue 注入代写 System 指令；ContinueGeneration 注入续写指令
- **PromptBuilder narrator 处理**：`senderType='narrator'` 消息标记为 `NarratorInstruction` source（受保护不可裁剪）
- **ChatMessageBubble 渲染扩展**：
  - `narratorBubble`：居中/灰色/装饰线/NARRATOR 标签
  - `impersonateBubble`：左对齐/角色头像/[U] 标签/淡蓝背景
- **ChatPage 专用按钮**：🎭代写 / ⚡续写 / 📖旁白 / ▶继续
- **旁白输入模式**：placeholder 变为"输入旁白叙述…"，上方显示 [旁白模式] 标签
- **System=narrator 消息**：不再隐藏，正常渲染
- **senderCharacterId 修复**：所有 `senderType='character'` 消息正确填入 `senderCharacterId`

### TTS 语音朗读（刚完成）
- **TtsService**：基于 `@kit.CoreSpeechKit` 离线引擎
  - `ensureEngine()` 异步创建引擎
  - `speak()` / `stop()` / `shutdown()`
  - `processText()` / `extractQuotedText()` 文本处理
  - 语速/音量/音调/音色/language 配置
- **三种朗读模式**：Off / All / QuotesOnly（提取 `"..."` `「...」` 文本）
- **ChatMessageBubble TTS 按钮**：助手气泡内播放按钮
- **TTS 设置持久化**：Preferences 存储 tts_mode/tts_speed/tts_volume/tts_pitch/tts_voice_person
- **AppSettingsPage TTS 设置区**：模式/语速/音色选择
- **WebDAV 同步支持**：SyncDataExporter/Importer 包含 TTS 设置 keys

---

## 5. 关键修复记录

### senderCharacterId 校验失败修复
- **问题**：impersonate/autoContinue 创建 `senderType='character'` 消息时未填 `senderCharacterId`，导致 `DbHelper | transaction rollback cause=sender_character_id empty for character message`
- **修复**：所有 4 处 `senderType: 'character'` 消息添加 `senderCharacterId: this.character !== null ? this.character.id : ''`
- **影响文件**：`ChatService.ets` 4 处

---

## 6. 已知问题 / 待修复

### 代写/续写功能请求失败
- **现象**：用户点击 🎭代写 和 ⚡续写 按钮报"请求失败请重试"
- **senderCharacterId 已修复**（上述修复解决了持久化层校验失败）
- **仍需排查**：修复后尚未真机验证，可能仍有其他问题（如 doStream 指令注入逻辑、请求消息构建）
- **排查方法**：真机运行后查看 hilog 日志，关注 `ChatService` / `doStream` / `provider` 相关错误

### 其他可能的小问题
- 旁白模式输入后发送是否正常工作
- AutoContinue 两步串行是否正确串接（impersonate 完成 → 自动触发 response）
- TTS 引擎在真机上的初始化和播放

---

## 7. 消息三层体系（关键上下文）

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

### doStream 指令注入逻辑

| generationKind | 注入指令 |
|----------------|---------|
| Impersonate | `"Please continue the conversation by writing what the user ({{user}}) would say or do next..."` |
| AutoContinue (impersonate step) | 同 Impersonate |
| ContinueGeneration | `"Continue generating from where you left off. Do not repeat what was already written."` |
| Normal / Narrator | 无额外注入 |

### finalizeAssistantTurn AutoContinue 串接

当 `activeGenerationContext.autoContinueStep === 'impersonate'` 且流式完成时：
1. 检测到 impersonate step 完成
2. 调用 `startAutoContinueResponseStep()` 自动触发 response step
3. response step 完成后正常结束

---

## 8. TTS 技术细节

- **API**: `@kit.CoreSpeechKit`，API 4.1.0+
- **引擎创建**: `textToSpeech.createEngine()` 返回 `Promise<TextToSpeechEngine>`
- **最大文本长度**: `speak()` 单次 10,000 字符
- **可用音色**: 聆小珊(女,默认), 凌飞哲(男,需下载), Laura(女,en,需下载)
- **无需特殊权限**（`SystemCapability.AI.TextToSpeech`）
- **QuotesOnly 模式**: 提取 `"..."` `「...」` `『...』` 内文本朗读

### TTS Preference Keys

| Key | 类型 | 默认值 | 用途 |
|-----|------|--------|------|
| `tts_mode` | number | 0 (Off) | 朗读模式 |
| `tts_speed` | number | 1.0 | 语速 |
| `tts_volume` | number | 1.0 | 音量 |
| `tts_pitch` | number | 1.0 | 音调 |
| `tts_voice_person` | string | '聆小珊' | 音色 |

### TTS 同步

- SyncDataExporter KEYS 含上述 5 个 key
- SyncDataImporter NUMBER_KEYS: tts_mode, tts_speed, tts_volume, tts_pitch, tts_voice_person

---

## 9. 数据库状态

- **版本**: 35
- **关键表**: characters, chats, messages, message_swipe_groups, message_swipe_candidates, conversation_branches, chat_branch_state, conversation_branch_messages, conversation_branch_swipe_selections, chat_participants, lorebooks, lorebook_entries, prompt_presets, chat_memories, personas
- **注意**: worlds 及相关表已从 UI 删除但数据库表仍在（迁移只增不改）

### messages 表 sender 相关列

| 列 | 类型 | 说明 |
|----|------|------|
| `sender_type` | TEXT | 'user' / 'character' / 'narrator' |
| `sender_character_id` | TEXT | senderType='character' 时必填，其他时必须为空 |

---

## 10. 已知陷阱

1. **ChatPage.ets 约 4000+ 行**：编辑时必须严格保持花括号平衡
2. **`@Builder` 方法内禁止 `const`/`let`**：用私有方法或内联表达式替代
3. **数据库迁移只增不改**：已删功能的表仍保留
4. **ArkTS 限制**：禁止 `as` 类型断言、禁止 `any`、禁止动态属性访问、对象字面量需显式类型上下文
5. **senderType='character' 必须填 senderCharacterId**：否则 MessageRepository 校验会抛 `invalid data`
6. **两个 App 共存**：所有存储前缀必须用 `arktavern_solo`

---

## 11. 下一步行动

### 立即：真机验证代写/续写功能
1. 在真机上运行 App
2. 点击 🎭代写 按钮，观察是否成功生成
3. 点击 ⚡续写 按钮，观察是否成功续写
4. 如仍失败，查看 hilog 日志定位错误
5. 验证 📖旁白 和 ▶继续 功能

### 然后：修复发现的小问题
- 根据真机测试结果修复 UI/逻辑问题

### 后续：世界观构建能力增强
- 详见 `docs/WORLD_BUILDING_ROADMAP.md`

---

## 12. 快速验证规则

1. 编码过程中只做静态检查（`arkts_check`）
2. 完成一批相关修改后，执行一次 `entry@default` 增量编译
3. 默认禁止 clean build（仅缓存异常时允许）
4. 同一编译命令最多 3 次
5. 同一设备测试最多 2 次
