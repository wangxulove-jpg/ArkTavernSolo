# ArkTavern 世界观构建能力增强路线图

## 1. 现状问题

### 1.1 角色卡只能扮演"一个人"

当前 `buildDefaultCharacterSystemContent()` 硬编码了 `你是{角色名}` 句式：

```
你是酒馆老板     ← 强制第一人称角色扮演
一个矮人酒吧老板...
性格: 粗鲁
```

这导致：
- 叙述者/DM 类角色卡会生成 "你是Narrator" 这种不自然的 prompt
- 场景类角色卡（如"破旧酒馆"包含多个NPC）无法正常工作
- 用户无法定义自己的身份（无 Persona 系统）

### 1.2 世界书能力受限

| 能力 | 当前状态 | 问题 |
|------|---------|------|
| 全局世界书 | 仅能激活 1 个 | 无法同时构建多层世界观 |
| 角色世界书 | 每角色仅绑定 1 个 | 角色不能引用多个知识库 |
| 对话级世界书 | 不存在 | 每个聊天不能独立绑定世界 |
| 插入位置 | 仅 Before/After Character | 无法精细控制注入点 |
| 扫描深度 | 硬编码 10 条 | 不可配置 |
| Token 预算 | 字符数限制 (12000) | 不感知实际 token 消耗 |
| 递归扫描 | 不支持 | 条目不能连锁触发 |

### 1.3 无多角色交互

当前仅支持 1 对 1 聊天，无群组聊天能力。

---

## 2. 行业调研：各 App 世界构建方案

### 2.1 角色卡模型——所有人用的是同一套

**核心发现：没有任何主流 App 区分"角色类型"。** 叙述者、DM、场景、多人卡都用同一个 Character 数据模型，区别仅在 prompt 内容。

#### 叙述者/DM 卡

| 字段 | 内容 |
|------|------|
| Name | Narrator / 地牢主 / Storyteller |
| Description | 你是一个叙事者，以第三人称推进故事，扮演所有 NPC |
| System Prompt | 以叙述者身份推进故事。根据 {{user}} 的行动描写场景、控制 NPC 对话、推动情节。不要替 {{user}} 说话。 |
| First Message | *故事开始...* |

`{{char}}` 宏直接替换为 "Narrator"，无特殊逻辑。

#### 多角色场景卡

| 字段 | 内容 |
|------|------|
| Name | 破旧酒馆 |
| Description | 破旧酒馆坐落在三国交汇的十字路口。店员包括：甘德伦（矮人酒保，粗鲁寡言）、艾拉拉（半精灵服务员，爱八卦）、老马修（人类厨师，退休冒险者）、玛拉（提夫林吟游诗人，妖艳戏剧性）|
| System Prompt | 扮演场景中所有角色。每个角色的对话和行动单独标注名字。不要替 {{user}} 说话。 |
| Scenario | {{user}} 在一个雨夜踏入了破旧酒馆。 |
| First Message | *酒馆的门被推开，带着一阵冷雨。甘德伦从吧台后抬起头，擦拭着酒杯。* "又一个湿透的旅人，" *他嘟囔道，* "艾拉拉，给这位拿条毛巾和热汤。" |

#### 关键结论

Character 模型**无需新增字段**。只需：
1. 修改 `buildDefaultCharacterSystemContent()` 去掉"你是{name}"的硬编码
2. 用户通过 system prompt 字段自行定义角色行为模式
3. 新增 Persona 系统让用户定义自身身份

### 2.2 各平台对比

| App | 世界构建机制 | 角色卡灵活性 | 群组聊天 | 用户身份 |
|-----|------------|------------|---------|---------|
| **SillyTavern** | Lorebook (关键词/正则/递归/粘滞/冷却) + 群组聊天 | 完全自由，无类型约束 | 支持 (SWAP/APPEND 模式) | 独立 Persona 系统，可锁定到聊天/角色 |
| **Character.AI** | Lorebook (刚上线)，共享世界书多角色共用 | 同一套模型 | 暂无 | 用户名 |
| **NovelAI** | Lorebook + AI 生成条目 + 短语偏好 | 默认就是叙述模式 | 无 | 无独立 Persona，靠故事文本 |
| **Chub.ai** | V2 规范内嵌 Lorebook | 同一套模型 | 无 | 用户名 |
| **Kindroid** | 记忆系统替代 Lorebook (日志/关键记忆/长时记忆) | 同一套模型 | 支持 (多 Kin) | 独立 Persona 系统 |
| **Backyard AI** | 基础 Lorebook + 文法规则 | 同一套模型 | 支持 (4 角色) | 用户名 |

### 2.3 SillyTavern 的 Persona 系统

SillyTavern 将用户身份和 AI 角色完全分离：

| 概念 | 变量 | 来源 |
|------|------|------|
| Persona (用户) | `name1` | 用户定义的自身身份 |
| Character (AI) | `name2` | 角色卡 |

Persona 字段：
- **Name** → 替换 `{{user}}`
- **Description** → 用户自我描述（外貌、性格、背景等）
- **Avatar** → 用户消息头像
- **Position** → 描述注入位置（system段/Author's Note/指定深度）

锁定机制：
- **默认 Persona** — 无锁定时使用
- **角色锁定** — 绑定到特定 AI 角色（如：和吸血鬼聊天时用"猎人"身份）
- **聊天锁定** — 绑定到特定聊天会话

---

## 3. 实施路线

### Phase 2A：角色卡灵活性修复（最小改动，最大收益）

**目标：让角色卡不再局限于"扮演一个人"**

#### 3A.1 修改 buildDefaultCharacterSystemContent

**当前**：
```
你是{角色名}
{描述}
性格: {性格}
场景: {场景}
```

**改为**：
```
{角色名}
{描述}
性格: {性格}
场景: {场景}
```

去掉"你是"前缀。当角色名是"Narrator"时不会出现"你是Narrator"。
用户需要第一人称时，在 system prompt 中自行写"你是{角色名}"。

**影响范围**：
- `Character.ets:251-266` — `buildDefaultCharacterSystemContent()`
- `Character.ets:275-280` — `buildCharacterSystemContent()` 无需改动（有 systemPrompt 时直接返回）
- `PromptBuilder.ets` — 引用该函数的地方无需改动

#### 3A.2 新增 Persona（用户身份）系统

**数据模型**：
```typescript
interface Persona {
  id: string;
  name: string;          // 替换 {{user}}
  description: string;   // 用户自我描述
  avatarUri: string;     // 用户头像
  position: PersonaPosition;  // 注入位置
  createdAt: number;
  updatedAt: number;
}

enum PersonaPosition {
  Disabled = 0,           // 不注入
  BeforeCharacter = 1,    // 角色定义之前
  AfterCharacter = 2,     // 角色定义之后
  AtDepth = 3,            // 聊天历史指定深度
}
```

**存储**：
- 数据库新增 `personas` 表
- `chats` 表新增 `chat_persona_id` 字段（聊天级锁定）
- `characters` 表新增 `character_default_persona_id` 字段（角色级锁定）
- Preferences 新增 `default_persona_id` key（全局默认）

**注入逻辑**（PromptBuilder）：
1. 查找优先级：聊天锁定 > 角色锁定 > 全局默认
2. 按 PersonaPosition 注入 description
3. Persona.name 替换 `{{user}}` 宏

**UI**：
- 设置页新增"用户身份"分区：创建/编辑/删除 Persona
- 聊天页面"更多菜单"新增"切换身份"选项
- 角色编辑页新增"默认身份"选择

#### 3A.3 角色卡编辑页提示优化

在 system prompt 字段旁增加提示文本：
- 无 systemPrompt 时显示："留空时使用默认组合（角色名+描述+性格+场景）。叙述者或多人场景卡建议自定义。"
- 提供 prompt 模板快捷填入按钮：
  - "叙述者模式" → `你是{{char}}，一个叙事者。以第三人称推进故事，扮演场景中的所有角色。`
  - "多人场景" → `扮演{{char}}中的所有角色。每个角色的对话单独标注名字。不要替{{user}}说话。`

---

### Phase 2B：世界书增强

#### 3B.1 多世界书绑定

**当前**：全局仅 1 个"当前世界书"，角色仅 1 个 `characterBookId`。

**改为**：
- Chat 模型新增 `lorebookIds: string[]` 字段（对话级绑定）
- Character 模型 `characterBookId` 改为 `characterBookIds: string[]`（角色可绑定多个）
- 全局激活列表：LorebookSelectionStore 存储多个已激活的世界书 ID
- PromptBuilder 合并所有来源的世界书条目，按优先级排序

**注入优先级**（参考 SillyTavern）：
1. 对话级世界书（最高优先）
2. 角色专属世界书
3. 全局激活世界书（最低优先）

#### 3B.2 增加插入位置

**当前**：仅 `BeforeCharacter` / `AfterCharacter`

**新增**：
```typescript
enum LorebookPosition {
  BeforeSystem = 0,       // System Prompt 之前
  AfterSystem = 1,        // System Prompt 之后
  BeforeCharacter = 2,    // 角色定义之前 (现有)
  AfterCharacter = 3,     // 角色定义之后 (现有)
  BeforeExamples = 4,     // 对话示例之前
  AfterExamples = 5,      // 对话示例之后
  AtDepth = 6,            // 聊天历史指定深度
}
```

`AtDepth` 位置需要条目新增 `depth: number` 字段（默认 4）和 `role: ChatRole` 字段（默认 System）。

#### 3B.3 扫描深度可配置

**当前**：LorebookService 硬编码扫描最近 10 条消息。

**改为**：
- Lorebook 新增 `scanDepth: number` 字段（默认 10，范围 1-50）
- LorebookPage 新增扫描深度 Slider
- 全局也有一个默认 scanDepth（Preferences），世界书未设置时使用全局值

#### 3B.4 Token 预算

**当前**：`maxInjectionChars = 12000` 字符数硬限制。

**改为**：
- Lorebook 新增 `tokenBudgetPercent: number` 字段（默认 25，表示上下文的 25%）
- Lorebook 新增 `tokenBudgetCap: number` 字段（默认 0 = 无上限）
- PromptBuilder 根据模型的 `maxContextTokens` 计算实际 token 预算
- 条目按优先级排序，超出预算时截断低优先级条目
- 保留字符数限制作为 fallback（无 token 计数时使用）

**数据库变更**：
```sql
-- lorebooks 表新增列
ALTER TABLE lorebooks ADD COLUMN lorebook_scan_depth INTEGER NOT NULL DEFAULT 10;
ALTER TABLE lorebooks ADD COLUMN lorebook_token_budget_percent INTEGER NOT NULL DEFAULT 25;
ALTER TABLE lorebooks ADD COLUMN lorebook_token_budget_cap INTEGER NOT NULL DEFAULT 0;

-- lorebook_entries 表新增列
ALTER TABLE lorebooks ADD COLUMN entry_depth INTEGER NOT NULL DEFAULT 4;
ALTER TABLE lorebooks ADD COLUMN entry_role TEXT NOT NULL DEFAULT 'system';
```

---

### Phase 3：多角色交互

#### 3.1 群组聊天

参考 SillyTavern 的 Group Chat，设计：

**数据模型**：
```typescript
interface ChatGroup {
  id: string;
  name: string;
  memberIds: string[];           // 角色 ID 列表
  disabledMemberIds: string[];   // 被静音的成员
  activationStrategy: GroupActivationStrategy;
  generationMode: GroupGenerationMode;
  sharedLorebookIds: string[];   // 群组共享世界书
  chatId: string;                // 当前活跃聊天 ID
  autoModeDelay: number;         // 自动模式间隔(秒)
}

enum GroupActivationStrategy {
  Natural = 0,    // 根据提及 + 话痨度随机
  RoundRobin = 1, // 轮流发言
  Manual = 2,     // 手动指定
}

enum GroupGenerationMode {
  Swap = 0,       // 替换：仅当前发言角色的卡在上下文
  Append = 1,     // 合并：所有成员的卡合并进上下文
}
```

**Prompt 结构**（Append 模式）：
- Description = 所有成员 description 拼接
- Personality = 所有成员 personality 拼接
- Scenario = 对话级覆盖 或 所有成员 scenario 拼接
- 每条 AI 消息标注角色名

#### 3.2 聊天内世界书浏览

在聊天页面增加世界书面板功能：
- 展示当前已激活的世界书条目列表
- 按激活原因分类（常驻/关键词匹配）
- 条目内容可折叠查看
- 不离开聊天页面

#### 3.3 递归扫描

世界书条目的内容可以触发其他条目：
- LorebookEntry 新增 `excludeRecursion: boolean`（不参与递归）
- LorebookEntry 新增 `preventRecursion: boolean`（内容不触发递归）
- Lorebook 新增 `maxRecursionSteps: number`（默认 0 = 关闭）
- 扫描流程：首轮关键词匹配 → 新激活条目的内容加入扫描缓冲 → 再次扫描 → 直到无新条目或达步数上限

---

### Phase 4：高级特性

| 特性 | 描述 | 优先级 |
|------|------|--------|
| 正则匹配 | 条目关键词支持正则表达式 | 中 |
| 概率触发 | 条目设置激活概率 (0-100%) | 低 |
| 粘滞/冷却/延迟 | 条目激活后持续N条/冷却N条/延迟N条后激活 | 中 |
| 包含组 | 同组条目竞争，随机/加权选择 | 低 |
| 条目角色 | 每个条目可设 System/User/Assistant 角色 | 中 |
| 向量匹配 | 基于 embedding 相似度匹配条目 | 低 |
| AI 生成条目 | 参考 NovelAI 的 Lore Generator | 低 |

---

## 4. 现有模型兼容性评估

### 4.1 无需修改的模型

| 模型 | 原因 |
|------|------|
| ChatMessage | 已支持角色名标注 |
| ChatRole | 已有 System/User/Assistant |
| LorebookEntry | 仅需扩展字段 |
| PromptSegment | 已支持多位置 |

### 4.2 需要扩展的模型

| 模型 | 变更 |
|------|------|
| Character | `characterBookId` → `characterBookIds: string[]`；新增 `defaultPersonaId: string` |
| Chat | 新增 `lorebookIds: string[]`；新增 `personaId: string` |
| Lorebook | 新增 `scanDepth`、`tokenBudgetPercent`、`tokenBudgetCap`、`maxRecursionSteps` |
| LorebookEntry | 新增 `depth`、`role`、`excludeRecursion`、`preventRecursion` |
| LorebookPosition | 从 2 值扩展到 7 值 |

### 4.3 新增的模型

| 模型 | 用途 |
|------|------|
| Persona | 用户身份定义 |
| ChatGroup | 群组聊天 |
| GroupActivationStrategy | 群组发言策略枚举 |
| GroupGenerationMode | 群组生成模式枚举 |
| PersonaPosition | Persona 注入位置枚举 |

---

## 5. 实施顺序建议

```
Phase 2A (角色卡灵活性)  ← 优先，改动小收益大
  ├─ 3A.1 修改 buildDefaultCharacterSystemContent
  ├─ 3A.2 Persona 系统
  └─ 3A.3 角色卡编辑提示优化

Phase 2B (世界书增强)
  ├─ 3B.1 多世界书绑定
  ├─ 3B.2 增加插入位置
  ├─ 3B.3 扫描深度可配置
  └─ 3B.4 Token 预算

Phase 3 (多角色交互)
  ├─ 3.1 群组聊天
  ├─ 3.2 聊天内世界书浏览
  └─ 3.3 递归扫描

Phase 4 (高级特性)
  ├─ 正则匹配 / 概率触发
  ├─ 粘滞/冷却/延迟
  ├─ 包含组 / 条目角色
  └─ 向量匹配 / AI 生成
```

每个 Phase 完成后执行回归编译和实机验证。
