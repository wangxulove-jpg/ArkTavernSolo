# SillyTavern + 酒馆助手角色卡驱动机制调研报告（面向 ArkTavernSolo 重构）

> **文档性质**：重构前期调研，一次性写成、长期参考。项目尚未启动重构时，接手者应先读完本文再讨论方案。
> **调查日期**：2026-10-03
> **调查人**：AI Agent（GLM-5.3 @ TRAE）
> **调查方法**：直接阅读本地源码 + 解包用户真实角色卡 + 官方文档网络核对。所有关键结论均有源码行号佐证（见附录 A）。
> **结论等级**：未标注"未确认"的内容均为源码/实测验证过的事实。

---

## 0. 执行摘要（一分钟版本）

1. **ArkTavernSolo 角色卡兼容性差的根因不是"解析"，而是"运行时"**。项目解析器（`parser/CharacterCardJsonParser.ets`）已正确保留 V3 全部字段和未知 extensions，但 ST 中文卡生态真正依赖的是四件运行时基础件：
   - **正则脚本引擎**（卡内 `extensions.regex_scripts`，显示层/prompt 层双管线）
   - **世界书激活算法**（character_book + extensions 超集字段，递归/sticky/组/预算）
   - **TavernHelper API**（酒馆助手注入 iframe 的约 20 组 JS API：变量/消息/世界书/事件/生成）
   - **代码块 → iframe 渲染器**（酒馆助手把消息里的 HTML 代码块变成可交互网页界面）
2. 用户的 5 张主力卡**全部是 chara_card_v3**，灵魂基本不在标准字段里：`first_mes` 可以只有 7 个字符（怪奇录），界面和逻辑全在卡内正则（3 万字符 HTML 替换串）、`tavern_helper.scripts`（UserScript）、`depth_prompt`、世界书（最多 184 条）里。
3. **鸿蒙原生可以实现约 80% 的兼容性**。前三件是纯 ArkTS 逻辑；第四件项目已有 60% 基础（CardFrontendWeb + Bridge + FrontendCardHost）。**整个重构的核心技术决策只有一个：TavernHelper shim —— 用 postMessage/javaScriptProxy RPC 仿真 ST 的"同源 iframe 直取 window.parent"机制，把 API 形状做成和酒馆助手一模一样。**
4. 不可行的部分：依赖其他 ST 插件（表情/数据库/翻译/MEM）的卡、`SillyTavern.getContext()` 深度写操作、群聊特性。

---

## 1. 调查环境

| 项 | 值 |
|---|---|
| SillyTavern 版本 | **1.18.0**（`SillyTavern/package.json`） |
| SillyTavern 根目录 | `D:\ArkProject\ArkTavernSolo\APK-reference\SillyTavern-Launcher\SillyTavern`（下文简写 `ST/`） |
| 酒馆助手 | **已安装**，v4.9.5，源码完整位于 `ST/public/scripts/extensions/third-party/JS-Slash-Runner/`（GitHub 仓库名 JS-Slash-Runner，display_name "酒馆助手"，作者 KAKAA / N0VI028，主页 https://github.com/N0VI028/JS-Slash-Runner） |
| 用户角色卡样本 | `ST/data/default-user/characters/` 下 5 张中文卡（怪奇录、凡人修仙传 V10.91、林霖、诸天重置 1.3.0、雾津市播种计划） |
| 酒馆助手官方文档 | https://n0vi028.github.io/JS-Slash-Runner-Doc/ |
| 上游最新版本参考 | 酒馆助手已发布到 4.11.2（本地 4.9.5；更新日志见官方文档"更新日志"页） |

注意：用户级扩展目录 `ST/data/default-user/extensions/` 为空，酒馆助手装在**全局** third-party 目录。

---

## 2. ST 角色卡体系（数据层）

### 2.1 物理格式

| 格式 | 说明 |
|---|---|
| `.png` | **主流**。卡数据嵌在 PNG `tEXt` chunk 中：关键字 `ccv3`（V3，优先读取）或 `chara`（V2 兼容），值为 base64 编码的 JSON。实测怪奇录.png 同时含两个 chunk（各约 98KB）。服务端读写逻辑在 `ST/src/character-card-parser.js` L15-L78 |
| `.json` | 直接导入 JSON（V1/V2/V3 结构） |
| `.charx` | V3 新格式，zip 包裹 |
| `.yaml` | V3 序列化格式 |
| `.byaf` | BYAF 世界书类格式（`ST/src/byaf.js` 有转换器，loreItems → character_book.entries） |

PNG tEXt chunk 结构（鸿蒙实现 PNG 解析时照此办理）：

```
[4字节大端长度][4字节类型 'tEXt'][keyword\0base64文本][4字节CRC]
```

解析顺序：先找 `ccv3` 关键字，找不到回退 `chara`。

### 2.2 字段规范（V1 → V2 → V3）

**V1（顶层平铺）**：`name / description / personality / scenario / first_mes / mes_example`

**V2（新增，位于 `data` 下）**：
`creator / creator_notes / system_prompt / post_history_instructions / alternate_greetings[] / tags[] / character_version / character_book{} / extensions{} / spec="chara_card_v2" / spec_version="2.0"`

**V3（新增）**：
`spec="chara_card_v3" / spec_version="3.0"`、`assets[]`（头像/背景等多资源，含 uri/type/name）、`nickname`、`group_only_greetings[]`（群聊用）、多语言字段（`creator_notes_multilingual` 等）、`character_avatar`。

**实测用户卡顶层结构**（怪奇录 ccv3 解包）：V1 平铺字段（name/description/.../spec/spec_version/data/create_date）与 `data` 内字段**双份并存**——V3 规范要求兼容 V1 读取器，导出时两处都写。ST 导入时以 `data` 为准（见 §2.3）。

### 2.3 导入链路与字段映射

前端入口 `ST/public/script.js` L10476-L10528 `importCharacter`（接受 `.json/.png/.yaml/.charx/.byaf`），提交 `/api/characters/import`。

服务端 `ST/src/endpoints/characters.js`：

**L513-L552（V2→内部迁移 fieldMappings）**：

```
name ← data.name            description ← data.description
personality ← data.personality    scenario ← data.scenario
first_mes ← data.first_mes        mes_example ← data.mes_example
talkativeness ← data.extensions.talkativeness（缺省回填 0.5）
fav ← data.extensions.fav（缺省回填 false）
tags ← data.tags
```

V1 平铺字段与 data 内字段不一致时，**以 data 为准并告警**。

**L565-L657（charaFormatData，保存/规范化）**要点：

- `data.extensions.world`：角色关联的世界书名（导入时会把该世界书内容写进 `data.character_book`）
- `depth_prompt` 默认值：`depth=4, role='system'`（位于 `data.extensions.depth_prompt`）
- **未知 extensions 字段原样保留 + deepMerge**（L646-L654）——这是整个第三方生态（酒馆助手/Mvu/骰子系统）的挂载点，**兼容实现必须同样原样保留**

### 2.4 character_book → ST 世界书转换

`ST/public/scripts/world-info.js` L5498-L5525 `convertCharacterBook(characterBook)`：

| V3 规范字段 | ST 内部字段 | 备注 |
|---|---|---|
| `id`（无则用数组下标） | `uid` | |
| `keys[]` | `key[]` | |
| `secondary_keys[]` | `keysecondary[]` | |
| `comment` | `comment` | |
| `content` | `content` | |
| `constant` | `constant` | 蓝灯常驻 |
| `selective` | `selective` | |
| `insertion_order` | `order` | |
| `position`（'before_char'/'after_char'） | `position` | **被 `extensions.position` 覆盖** |
| `enabled` | `disable = !enabled` | **注意取反** |
| `extensions.position` | `position` | 数值枚举，见 §4.3 |
| `extensions.exclude_recursion` | `excludeRecursion` | |
| `extensions.prevent_recursion` | `preventRecursion` | |
| `extensions.delay_until_recursion` | `delayUntilRecursion` | |
| `extensions.probability` / `useProbability` | `probability` / `useProbability` | |
| `extensions.scan_depth` / `case_sensitive` / `match_whole_words` / `useGroupScoring` / `automation_id` / `role` / `sticky` / `cooldown` / `delay` / `display_index` / `group` / `groupOverride` / `groupWeight` / `triggers` / `ignoreBudget` | 同名驼峰 | **激活行为参数全在 extensions 里，规范本体只有少数字段** |

`originalData` 一并保留在结果对象上（`{entries, originalData}`）。

同文件还有 Agnai / Risu / NovelAI 世界书转换器（L5357-L5496），字段模板 `newWorldInfoEntryTemplate` 即 ST 世界书条目全集。

### 2.5 运行时数据结构

**characters 数组元素（ST 内存）**：V1 平铺字段 + `data`（V2/V3 完整结构）+ `avatar`（重命名后的 PNG 文件名，作为唯一 ID 使用）+ `chat`（当前聊天文件名）。

**chat 数组元素（一条消息）**：

```
{
  name, is_user, is_system,
  mes,                        // 正文
  send_date,
  swipes: string[],           // swipe 候选串
  swipe_id: number,
  extra: {
    display_text,             // 显示覆盖文本（显示与存储分离，正则/变量处理用）
    reasoning,                // 思维链
    type,                     // 'narrator' / system_message_types 等
    token_count, bias, append_title, title, media[], tool_invocations[]...
  },
  variables: Object[],        // 楼层变量，按 swipe 分版本（Mvu 依赖）
  force_avatar
}
```

**chat_metadata**（聊天级）：`variables`（局部变量）、`timedWorldInfo`（sticky/cooldown 状态恢复）、世界书绑定、extension 字段等。

**swipe 与 variables 绑定**：每个 swipe 一份独立变量快照（`variables[swipe_id]`）。回退 swipe = 回退变量状态。

### 2.6 extensions 生态字段（实测中文卡）

| 字段 | 用途 | 消费者 |
|---|---|---|
| `talkativeness` / `fav` | ST 基础 | ST |
| `world` | 关联世界书名 | ST |
| `depth_prompt` | `{prompt, depth, role}` 深度注入 | ST prompt 组装 |
| `regex_scripts[]` | 卡内正则脚本（见 §5） | ST regex 扩展 |
| `tavern_helper.scripts[]` / `tavern_helper.variables` | 卡内 UserScript 与初始变量 | 酒馆助手 |
| `quick-response-force` | 快速回复强制 | 第三方（雾津市卡有） |

---

## 3. ST 显示管线（消息从文本到屏幕）

### 3.1 messageFormatting 全流程

`ST/public/script.js` L1753-L1912，**顺序严格**：

1. 楼层 0（非系统/用户/reasoning）→ `substituteParams(mes, undefined, ch_name)` 宏替换（只有第一条消息做显示层宏替换，且结果**写回 chat[0].mes**）
2. 注释消息（ch_name === COMMENT_NAME_DEFAULT）强制按非 system 格式化；隐藏消息（isSystem 且非系统用户名）给 markdown
3. prompt bias 前缀移除
4. **应用正则**（`getRegexedString(mes, placement, {characterOverride, isMarkdown: true, depth})`；placement 分流：isReasoning→REASONING、isUser→USER_INPUT、narrator→SLASH_COMMAND、其余→AI_OUTPUT；depth 按排除 is_system 后的楼层倒数计数）
5. `fixMarkdown`（可选，power_user.auto_fix_generated_markdown）
6. `encode_tags` 选项（可选 HTML 转义）
7. reasoning 前后缀字符串首现转义保护
8. 标签内双引号保护（`"` → `\ufffe`）
9. 引号智能转换：正则匹配 `<style>...</style>`、```` ```...``` ````、`~~~`、`` `` ``、`` ` ``（**这些块整体被保护，不参与引号替换**）与 6 种引号 → `<q>` 标签
10. `\begin{align*}` → `$$`（LaTeX）
11. **`converter.makeHtml(mes)`**（showdown markdown → HTML；代码块 → `<pre><code>`，这是酒馆助手渲染器的挂载点）
12. `<code>` 内换行修复（\u0000 占位往返）、`&amp;` 还原
13. 角色名前缀移除（`name:` 开头，可配）
14. **`DOMPurify.sanitize`**（config：`MESSAGE_SANITIZE: true`，`ADD_TAGS: ['custom-style']`；`extra.uses_system_ui` 时收紧）
15. `encodeStyleTags` → sanitize → `decodeStyleTags({prefix: '.mes_text '})`：**`<style>` 被转成 custom-style 并给每条选择器加 `.mes_text ` 前缀**——这就是"无脚本美化 HTML 卡"（状态栏）能在消息内直接生效的机制

### 3.2 渲染入口

- `addOneMessage`（L2492-L2531）→ `updateMessageElement`（L2559-L2637）→ `getMessageTextHTML`（L2464-L2477，取 `message.mes` 或 `extra.display_text`）→ `.mes_text').html(messageHTML)`
- 流式：`STREAM_TOKEN_RECEIVED` / smooth stream 增量更新同一 DOM
- 代码高亮：hljs（`highlight_code`）

### 3.3 对兼容实现的含义

- **显示用 HTML 白名单语义要对齐 DOMPurify 默认 + custom-style**，否则美化卡渲染结果不同
- **showdown 的具体输出格式（`<q>`、代码块结构、换行）是正则脚本的隐性契约**——中文卡的正则 replaceString 按 ST 的 HTML 结构写，markdown 引擎行为不同会导致替换错位
- `<style>` 作用域机制（`.mes_text` 前缀）决定了内联样式只影响本楼消息

---

## 4. 世界书（World Info）系统

### 4.1 激活算法（checkWorldInfo 主循环）

`ST/public/scripts/world-info.js` L4597 起。伪代码：

```
buffer = 最近 scanDepth 层消息（全局默认 2 层；条目可自带 scan_depth 覆盖）
       + 带 scan=true 的 extension prompt 注入（getExtensionPromptByName → buffer.addInject）
       + 递归缓冲（后续轮次追加已激活条目的 content）

budget = world_info_budget% × maxContext（可被 world_info_budget_cap 截断）
sortedEntries = getSortedEntries()（按 order 等排序）
timedEffects.checkTimedEffects()  // sticky/cooldown/delay 状态机，从 chat_metadata.timedWorldInfo 恢复

while (还有可激活的) && (递归步数 < max_recursion_steps):
    for entry in sortedEntries:
        已激活/已失败概率 → 跳过
        disable → 跳过
        entry.triggers 非空且不含本次生成类型 → 跳过
        characterFilter（角色名/标签 include/exclude）→ 跳过
        constant(蓝灯) → 直接激活
        否则主键匹配 buffer（大小写/全词可配；matchWholeWords 默认 CJK 感知）
        有 keysecondary 时按 selectiveLogic 判定：
            AND_ANY(0) / AND_ALL(1) / NOT_ANY(2) / NOT_ALL(3)
        useProbability → 概率 roll（失败进 failedProbabilityChecks 本轮不再重试）
        scan_depth / minActivations（最小激活数，不含递归缓冲）
    本轮激活条目：
        互斥组处理（group：groupOverride 优先者胜，否则 groupWeight 加权随机，组内只留一个）
        sticky 条目占组时跳过组内竞争
        delayUntilRecursion 分级（true=1 或数值）：低于当前递归级别不激活
    激活 content 追加进递归缓冲 → 下一轮
    令牌预算超限 → 停（ignoreBudget 条目豁免）

输出分拣（按 position）：
    worldInfoBefore / worldInfoAfter（@char 前后）
    WIDepthEntries（atDepth）
    EMEntries（@D 系统注入示例）
    ANBeforeEntries / ANAfterEntries（作者注上下）
    outletEntries（world_info_outlet 插槽）
```

### 4.2 关键参数（全局设置，存 settings）

`world_info_depth`（默认 2）、`world_info_max_recursion_steps`（默认 0=无限直到无新激活）、`world_info_budget`（%）、`world_info_budget_cap`、`world_info_case_sensitive`、`world_info_match_whole_words`。

### 4.3 注入位置枚举（world_info_position，L855-L864）

```
0 before  —— @char 前（世界书前）
1 after   —— @char 后（世界书后）
2 ANTop   —— 作者注上方
3 ANBottom—— 作者注下方
4 atDepth —— 按深度注入（WIDepthEntries，配 depth + role）
5 EMTop   —— 示例消息顶
6 EMBottom—— 示例消息底
7 outlet  —— 世界书插座（配 outletName）
```

条目级 role（system/user/assistant）仅 atDepth 等位置生效。

### 4.4 兼容要点

- 184 条条目（诸天卡）全扫是纯字符串匹配，ArkTS 性能可接受，但要防递归爆炸（必须实现 max_recursion_steps）
- timedWorldInfo 状态必须持久化到聊天元数据（跨会话恢复 sticky/cooldown）
- `triggers`（生成类型过滤）与 `automation_id`（外部触发）是卡作者常用高级特性

---

## 5. 正则脚本系统（Regex Scripts）

### 5.1 数据结构（卡内 `extensions.regex_scripts[]` 元素，实测字段）

```
{
  id: string(uuid),
  scriptName: string,
  findRegex: string,        // 含 /pattern/flags 形式或裸 pattern
  replaceString: string,    // 可为 3 万字符 HTML；支持 {{match}}/$1/$<name>
  trimStrings: string[],
  placement: number,        // 位掩码，见 5.2
  disabled: boolean,
  markdownOnly: boolean,    // 仅显示层
  promptOnly: boolean,      // 仅 prompt 层
  runOnEdit: boolean,       // 编辑消息时是否重跑
  substituteRegex: number,  // 0=无 1=RAW 2=ESCAPED（findRegex 里的宏替换方式）
  minDepth: number|null,    // 楼层深度下限
  maxDepth: number|null,
}
```

### 5.2 placement 枚举（`ST/public/scripts/extensions/regex/engine.js` L281-L292）

```
MD_DISPLAY = 0   // 已废弃
USER_INPUT = 1
AI_OUTPUT  = 2
SLASH_COMMAND = 3
WORLD_INFO = 5
REASONING  = 6
```

（placement 是数组，一条脚本可同时勾选多个位置。）

### 5.3 三个来源与安全模型（L98-L133）

```
GLOBAL —— extension_settings.regex（用户全局）
SCOPED —— characters[this_chid].data.extensions.regex_scripts（卡内）
          ★ 默认不生效！需要用户对每张卡"允许正则"白名单（character_allowed_regex 存 avatar 名）
PRESET —— 预设 JSON 内 regex_scripts 字段（preset_allowed_regex 白名单）
```

**鸿蒙实现必须带导入时授权 UI**（对齐 ST 的白名单语义），否则等于任意卡自带代码直接进 App。

### 5.4 应用时机（三类，getRegexedString 的过滤逻辑 L334-L381）

| 脚本标志 | 生效调用点 | 说明 |
|---|---|---|
| `markdownOnly=true` | 显示时（messageFormatting，isMarkdown=true） | **美化/界面替换类**（把 XML 标签换成 HTML 代码块） |
| `promptOnly=true` | 发给 AI 前（main 组装循环，isPrompt=true） | **隐藏/裁剪类**（如"只发送最新3楼变量更新"） |
| 两者皆 false | 中性时机：编辑消息（isEdit=true，需 runOnEdit）、开新聊天写 first_mes/swipes、welcomScreen | **存储层清理类**（替换为空=从存储删除） |

### 5.5 全部调用点清单（grep 验证，21 处）

```
script.js:1809    显示 messageFormatting（isMarkdown）
script.js:4447    发 AI 前 main 循环（isPrompt，对每条历史消息）
script.js:4486    reasoning 合并进消息（isPrompt）
script.js:5444    reasoning 显示
script.js:5816    用户输入显示
script.js:6422    impersonate/生成消息（USER_INPUT 或 AI_OUTPUT）
script.js:7660    开新聊天 first_mes → swipe 初始化（中性）
script.js:7665    alternate_greetings → swipes 初始化（中性）
script.js:8100    消息编辑保存（isEdit）
reasoning.js:409/1009/1188/1506/1555    reasoning 各环节（REASONING placement）
slash-commands.js:4715/5716/5943/6086   斜杠命令路径（SLASH_COMMAND）
world-info.js:5086 世界书内容（WORLD_INFO，isPrompt）
welcome-screen.js:277 欢迎页
```

### 5.6 替换语义（runRegexScript L391-L448）

- `findRegex` 按 `substituteRegex` 先做宏替换（RAW 或 ESCAPED 转义）
- 替换串支持：`{{match}}`→整段匹配、`$1`、`$<name>`（命名组）、`trimStrings` 过滤匹配内容
- **替换结果最后再过一遍 `substituteParams`（宏）** —— 正则与宏系统耦合，实现顺序不能反

---

## 6. 提示词组装（Chat Completion 模式）

### 6.1 最终消息数组顺序（populateChatCompletion，openai.js L1176-L1254 + 后续）

```
1. worldInfoBefore        （世界书 @char 前激活内容）
2. main                   （系统提示；卡 system_prompt 非空则覆盖预设 main）
3. worldInfoAfter         （世界书 @char 后）
4. charDescription        （卡 description）
5. charPersonality        （卡 personality）
6. scenario               （卡 scenario）
7. personaDescription     （用户 persona）
8. enhanceDefinitions     （可选）
9. 对话历史               （每条先过 promptOnly 正则 → 附件/媒体标题追加 → reasoning 合并
                            （PromptReasoning.addToMessage，从后往前直到限额））
10. atDepth 世界书条目 + depth_prompt + injectPrompts 产物
    （in-chat 绝对深度注入：按 depth 排序 splice 进历史消息之间，role 可选）
11. 作者注（ANTop/ANBottom 位）
12. nsfw / jailbreak       （post_history_instructions 覆盖 jailbreak）
13. quietPrompt            （无回显指令，永远最后）
14. bias / impersonate     （条件性）
```

### 6.2 系统提示优先级（preparePromptsForChatCompletion，L1358-L1507）

```
卡 data.system_prompt 非空 → 覆盖预设 main
卡 data.post_history_instructions 非空 → 覆盖预设 jailbreak
预设内 20+ 条 prompt（PromptManager 管理，可逐条禁用/排序）
```

### 6.3 历史裁剪

`getMaxPromptTokens()` → 预算 → 从旧到新丢弃（keep 条数保护）；`is_system` 消息默认全部排除（工具调用消息除外）；swipe 生成时 pop 最后一条。

### 6.4 instruct 模式（text completion 用）

`ST/public/scripts/instruct-mode.js` L317-L444：user/system/assistant 模板包装（prefix/suffix/stop sequence），模板内宏替换（`{{name}}` 等）。中文卡主要走 chat completion，此项优先级低。

---

## 7. 宏系统

### 7.1 机制

新版注册式宏引擎：`ST/public/scripts/macros/macro-system.js` L61-L84 按顺序注册 core/env/state/chat/time/variable/instruct 各组定义（`macros/definitions/*.js`）。支持嵌套（内层先解析）、作用域语法（`{{macro arg}}content{{/macro}}`）、`::` 与空格分隔参数、宏标志（flags）。

### 7.2 常用宏（卡片实测用到 + 文档全集）

```
{{user}} {{char}} {{persona}}
{{random:a,b,c}} {{pick:a,b}} {{roll:1d20}} {{roll:d100}}
{{time}} {{date}} {{weekday}} {{idle_duration}} {{time_utc}}
{{lastMessage}} {{lastUserMessage}} {{lastCharMessage}}
{{firstIncludedMessageId}} {{allChatRange}}
{{getvar::x}} {{setvar::x::y}} {{addvar::x::y}} {{incvar::x}} {{decvar::x}}
{{getglobalvar::x}} {{setglobalvar::x::y}}
{{// 注释}}（移除）
{{original}}{{systemPrompt}}... 等系统类
```

### 7.3 替换时机（substituteParams / substituteParamsExtended 调用面）

发给 AI 前的每段文本（卡字段/世界书/作者注/历史消息/预设）；显示层楼层 0；正则 findRegex（substituteRegex）与 replaceString 尾部；instruct 模板；世界书 content（world-info.js:5086）。

---

## 8. 事件系统

`ST/public/scripts/events.js` L2-L110，约 80 个事件。消息生命周期主干：

```
GENERATION_AFTER_COMMANDS → GENERATION_STARTED
→ STREAM_TOKEN_RECEIVED（流式增量）
→ MESSAGE_RECEIVED（收到完整消息）
→ MESSAGE_UPDATED / MESSAGE_EDITED
→ USER_MESSAGE_RENDERED / CHARACTER_MESSAGE_RENDERED（DOM 就绪）
→ GENERATION_ENDED
```

其他关键：`CHAT_CHANGED(chat_id_changed) / CHAT_CREATED / CHAT_DELETED / MORE_MESSAGES_LOADED / MESSAGE_SWIPED / MESSAGE_DELETED / MESSAGE_SENT / IMPERSONATE_READY / GENERATION_STOPPED / CHARACTER_EDITED / WORLDINFO_UPDATED / SETTINGS_UPDATED / CHAT_COMPLETION_PROMPT_READY(generate_before/after_combine_prompts) ...`

酒馆助手在其上再加 6 个 iframe 专属事件（见 §9.7）。

---

## 9. 酒馆助手（TavernHelper）架构

### 9.1 概况

- Vue3 + Pinia + vite 构建的 ST 扩展；manifest：`loading_order: 100`，入口 `dist/index.js`
- 四大职责：**渲染器**（代码块→iframe）、**脚本运行时**（UserScript 库）、**TavernHelper API 面**、**变量/事件桥**
- 渲染器设置：启用开关、**渲染深度**（只渲染最近 N 楼，0=全部）、忽略隐藏楼层、代码折叠、Blob URL 渲染、取消前端代码高亮（性能）、流式渲染（实验，默认关）、兜底清理（实验）

### 9.2 渲染器全流程（消息 → iframe）

1. 监听 ST 事件：`chatLoaded / CHARACTER_MESSAGE_RENDERED / USER_MESSAGE_RENDERED / MESSAGE_UPDATED / MESSAGE_SWIPED / MESSAGE_DELETED / MORE_MESSAGES_LOADED`（`src/store/iframe_runtimes/message.ts` L111-L148）
2. 扫描 `#chat > .mes` DOM 中的 `pre` 元素，判据 `isFrontend(text)`：**内容包含 `html>` / `<head>` / `<body` 任一即算前端**（`src/util/is_frontend.ts` L1-L8）
   - 官方文档口径：需要"代码在 ```` ``` ```` 代码块中"且"同时存在 `<body>` 和 `</body>`"（文档口径更严，代码实现更宽）
3. 命中的 pre 包进 `<div class="TH-render">`，作为 Vue `<Teleport>` 目标（`src/panel/Render.vue` L96-L100），iframe id = `TH-message--{mesid}--{index}`
4. 按渲染深度窗口管理 runtimes（超出深度的销毁、新增的创建；`auditRuntimes`）
5. iframe 用 **srcdoc 或 Blob URL（同源）** 加载，**无 sandbox 属性**
6. 渲染完成隐藏原 pre（折叠按钮兼容）；卸载时恢复
7. 高度自适应：iframe 内 `adjust_iframe_height.js` + 父窗口 resize 时 `postMessage({type:'TH_UPDATE_VIEWPORT_HEIGHT'})`
8. 事件：`message_iframe_render_started / message_iframe_render_ended`（emit 到 ST eventSource）

### 9.3 iframe 内容构造（createSrcContent，`src/panel/render/iframe.ts` L78-L103）

对代码块文本做如下包装：

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<base href="${window.location.origin}"/>        <!-- 仅 blob url 模式 -->
<style>
  *,*::before,*::after{box-sizing:border-box;}
  html,body{margin:0!important;padding:0;overflow:hidden!important;max-width:100%!important;}
  .user_avatar,.user-avatar{background-image:url('${getUserAvatarPath()}')}
  .char_avatar,.char-avatar{background-image:url('${getCharAvatarPath()}')}
</style>
${third_party_message.html}                      <!-- 第三方库（lodash/EjsTemplate/YAML/showdown/toastr/zod） -->
<script src="${predefine_url}"></script>         <!-- API 桥 -->
<script src="https://testingcf.jsdelivr.net/gh/N0VI028/JS-Slash-Runner/src/iframe/node_modules/log.js"></script>
<script src="${adjust_viewport_url}"></script>
<script src="${adjust_iframe_height_url}"></script>
</head>
<body>
${content}
</body>
</html>
```

**vh 改写**（同文件 L5-L75）：`min-height: *vh`（CSS/内联/JS setProperty 四种形态）自动替换为 `var(--TH-viewport-height)` 基准，防止 iframe 高度无限增长。

**头像机制**：卡的 HTML 里放 `<div class="char_avatar"></div>` / `user_avatar` 即自动显示当前角色/用户头像（背景图）。

### 9.4 predefine.js 桥（同源直通，核心机制）

`src/iframe/predefine.js`（全文 48 行）：

```js
window._ = window.parent._;                      // lodash 直取
// iframe id 缓存到 window.name（防 DOM 移除丢失）
result = _(window).merge(_.pick(window.parent,
    ['EjsTemplate', 'TavernHelper', 'YAML', 'showdown', 'toastr', 'z']));
result = result.merge(_.omit(window.parent.TavernHelper, '_bind'));
result = result.merge(...TavernHelper._bind 的 _xxx 方法
    .map(([key, value]) => ({ [key.replace('_','')]: value.bind(window) })));
// ⇒ iframe window 上直接出现 getVariables / eventOn / updateVariablesWith ... 全局函数
window.SillyTavern = getter 代理父窗口（getContext + writeExtensionField）
window.Mvu = getter 代理（MagVarUpdate 兼容）
window.addEventListener('pagehide', () => eventClearAll())   // 自动清理事件监听
```

**没有 postMessage RPC——同源 iframe 直接访问父窗口对象。** 这是鸿蒙重构必须换机制的地方（见 §12）。

### 9.5 TavernHelper API 全清单（`src/function/index.ts` L210-L470 逐项核对）

| 分组 | API | 说明 |
|---|---|---|
| **消息** | getChatMessages(range, {role, hide_state, include_swipes}) / setChatMessages / setChatMessage / createChatMessages / deleteChatMessages / rotateChatMessages | 楼层 CRUD；ChatMessage 含 swipes / is_system / 隐藏态 |
| **变量** | getVariables / replaceVariables / updateVariablesWith(updater) / insertOrAssignVariables / insertVariables / deleteVariable / registerVariableSchema(zod) | 7 类：chat / character / preset / global / script / extension / **message（per-swipe）** |
| **世界书** | getLorebooks / getLorebookSettings / setLorebookSettings / getCharLorebooks / setCurrentCharLorebooks / getChatLorebook / setChatLorebook / getOrCreateChatLorebook / createLorebook / deleteLorebook / getCurrentCharPrimaryLorebook | 书级绑定管理 |
| **世界书条目** | getLorebookEntries / replaceLorebookEntries / updateLorebookEntriesWith / setLorebookEntries / createLorebookEntry(s) / deleteLorebookEntry(s) | 条目 CRUD（含 enabled 开关——开局选择类卡用） |
| **角色** | getCharacter / getCharacterNames / getCharacterIds / getCurrentCharacterName / getCurrentCharacterId / createCharacter / createOrReplaceCharacter / deleteCharacter / replaceCharacter / updateCharacterWith / getCharData（原始卡 JSON）/ getCharAvatarPath / getChatHistoryBrief / getChatHistoryDetail | 4.11.0 起支持用 avatar 文件名做唯一 ID |
| **生成** | generate / generateRaw / getModelList / getProxyPresetNames / stopGenerationById / stopAllGeneration | 卡内脚本自己发请求；支持代理预设/自定义 API/自定义 body；generateRaw 返回 reasoning |
| **注入** | injectPrompts(prompts, {once}) / uninjectPrompts | InjectionPrompt = {id, position:'in_chat'/'none', depth, role, content, filter, should_scan}；复用 ST setExtensionPrompt；once=生成一次后自动撤销 |
| **事件** | eventOn / eventOnce / eventEmit / eventEmitAndWait / eventMakeFirst / eventMakeLast / eventRemoveListener / eventClearEvent / eventClearAll / eventOnButton / tavern_events / iframe_events | 直接桥接 ST eventSource；消息类事件参数 parseInt |
| **正则** | getTavernRegexes / replaceTavernRegexes / updateTavernRegexesWith / formatAsTavernRegexedString / isCharacterTavernRegexesEnabled | 运行时改卡内正则 |
| **宏** | registerMacroLike / unregisterMacroLike / substitudeMacros | 类宏（macro-like）注册 |
| **斜杠命令** | triggerSlash / triggerSlashWithResult | **执行 STscript**（/setvar /roll /buttons /input...） |
| **预设** | getPresetNames / getLoadedPresetName / loadPreset / getPreset / setPreset / createPreset / createOrReplacePreset / deletePreset / renamePreset / replacePreset / updatePresetWith / isPresetNormalPrompt / isPresetSystemPrompt / isPresetPlaceholderPrompt / default_preset | 预设 CRUD |
| **人设** | getPersonaNames / getPersonaIds / getCurrentPersonaName / getCurrentPersonaId / getPersonaAvatarPath / createPersona / createOrReplacePersona / deletePersona / getPersona / replacePersona / updatePersonaWith | 用户 persona CRUD |
| **显示** | formatAsDisplayedMessage(text, {message_id}) / retrieveDisplayedMessage(id) / refreshOneMessage(id) | 走 ST messageFormatting 管线格式化；返回 jQuery |
| **音频** | playAudio / pauseAudio / getCurrentAudio / getAudioList / replaceAudioList / appendAudioList / getAudioSettings / setAudioSettings / audioEnable / audioImport / audioMode / audioPlay / audioSelect | BGM/音效（斜杠命令版 + 函数版） |
| **脚本** | getScriptTrees / replaceScriptTrees / updateScriptTreesWith / getAllEnabledScriptButtons / _getScriptButtons / _replaceScriptButtons / _updateScriptButtonsWith / _appendInexistentScriptButtons / _getScriptName / _getScriptInfo / _getButtonEvent | 脚本树与**脚本按钮**（卡片底部可点按钮 → 触发脚本事件） |
| **导入** | importRawCharacter / importRawChat / importRawWorldbook / importRawTavernRegex / importRawPreset | 导入原始资产文本 |
| **扩展** | isAdmin / getTavernHelperExtensionId / getExtensionType / getExtensionStatus / isInstalledExtension / installExtension / uninstallExtension / reinstallExtension / updateExtension | 扩展管理 |
| **全局** | initializeGlobal / waitGlobalInitialized（如 waitGlobalInitialized('Mvu')） | 全局初始化握手 |
| **版本** | getTavernHelperVersion / getFrontendVersion / updateTavernHelper / getTavernVersion | 环境探测 |
| **杂项** | builtin / getLastMessageId / getMessageId / errorCatched / _reloadIframe | |

### 9.6 变量系统与 Mvu

**7 类变量存储位置**（`src/function/variables.ts` L56-L94）：

```
message   → chat_message.variables[swipe_id]（楼层变量，Mvu 核心）
chat      → chat_metadata.variables
character → 酒馆助手角色设置存储（卡级）
preset    → 预设设置存储
global    → extension_settings.variables.global
script    → 脚本运行时 data（脚本 iframe 专属）
extension → extension_settings[extension_id]
```

**_getAllVariables 合并顺序**（L106-L126）：`global → character →（script）→ chat → 当前楼层及之前的全部 message 变量`（消息 iframe 时）。后写覆盖先写。

**Mvu（MagVarUpdate）= 约定组合，非独立技术**：

1. 5 个世界书条目：变量清单（schema 描述）/ 更新规则 / 输出格式 / 格式提醒 / 初始化
2. AI 每楼输出 `<UpdateVariable>...</UpdateVariable>` 块（YAML/JSON）
3. 6 个正则脚本：promptOnly 类裁剪"只发送最新 N 楼变量更新"、markdownOnly 类把变量块替换为隐藏或美化 HTML
4. Zod schema 脚本（registerVariableSchema）做类型校验
5. 前端界面（iframe）用 getVariables/getAllVariables 读值渲染状态栏

参考实现：https://github.com/MagicalAstrogy/MagVarUpdate （Mvu 引擎）；st-card-skills npm 包的 `/st:mvu` 命令可给任意卡加装全套。

### 9.7 事件桥接

`src/function/event.ts`：

- `tavern_events`：映射 ST event_types 全表（约 80 个，L181 起）
- `iframe_events`：`MESSAGE_IFRAME_RENDER_STARTED/ENDED`、`GENERATION_STARTED/ENDED(js_*)`、`STREAM_TOKEN_RECEIVED_FULLY/INCREMENTALLY(js_*)`（L170-L177）
- listener 按 iframe 名分组 wrapper 注册到 ST eventSource；pagehide 自动 clearAll
- 4.10.0 新增 `GENERATION_REQUESTED`（generate 调用初期，可改生成配置）

### 9.8 卡内脚本（tavern_helper.scripts）

形态（实测诸天卡）：

```
{
  type: 'iframe'（6字符）, enabled: true,
  name, id(uuid),
  content: '// ==UserScript== ... (function(){...})()'   // JS 全文
  info: string,
  button: { enabled: true, buttons: [...] },             // 底部按钮定义
  data: Object,                                          // 脚本私有变量存储
  export_with: { data: true, button: true }
}
```

脚本常驻（不依附单楼），跑在独立 iframe 运行时（`useScriptIframeRuntimesStore`），可挂悬浮 UI（悬浮球）与底部按钮。示例（诸天"自动掷骰"）：监听消息事件 → `Math.floor(Math.random()*100)+1` → `updateVariablesWith` 写 `dice.rollResult`。

### 9.9 官方文档要点（网络核对）

- 渲染器文档：https://n0vi028.github.io/JS-Slash-Runner-Doc/guide/基本用法/渲染器.html
- generate 文档：https://n0vi028.github.io/JS-Slash-Runner-Doc/guide/功能详情/请求生成.html
- 类型定义打包下载：仓库 `@types/function/*.d.ts`（**重构时可直接作为 API 契约参考**）
- 兼容性提示：TauriTavern 2.2.0+ 聊天 DOM 虚拟化（4.9.0 兼容）；pinia 4.0+ 需要 `__VUE_PROD_DEVTOOLS__` 等 flag（predefine 统一设置）

---

## 10. 用户 5 张真实卡解剖（兼容性金标准候选）

解包方法：PowerShell 读 PNG tEXt chunk（ccv3 关键字）→ base64 → JSON。

### 10.1 怪奇录.png（958KB）

- spec chara_card_v3；description 568 字符；**first_mes 仅 `【biluo】`（7 字符）**；无世界书
- `extensions.regex_scripts` ×5（placement=2 AI_OUTPUT，markdownOnly=true）：
  - `状态栏`：`/<state_bar>([\s\S]*?)<\/state_bar>/gm` → 30852 字符 HTML
  - `新闻`：`/<news>...<\/news>/gm` → HTML
  - `论坛`：`/<forum>...<\/forum>/gm` → HTML
  - `biluo水印`：`【biluo】` → HTML（**这就是 first_mes 的界面来源**）
  - `Status`：`/<open\s*\/?>/gm` → 音频播放 HTML
- `depth_prompt`：{prompt: 剧情引导约 200 字, depth: 3, role: system}
- `tavern_helper.variables`: {}
- **机制依赖**：显示层正则替换 + 代码块 iframe 渲染 + depth_prompt 注入。类脑（biluo）风格典型卡。

### 10.2 《凡人修仙传V10.91》.png（9MB）

- description/personality/scenario/system_prompt 全空；**first_mes = 5865 字符的 ```` ```html ```` 代码块**（完整 HTML 文档直接放开场白）
- alternate_greetings ×1；character_book 11 条；regex_scripts ×3；depth_prompt depth=4（prompt 空）
- **机制依赖**：代码块 iframe 渲染（first_mes 直接是界面）+ 世界书

### 10.3 林霖.png（1.2MB）

- description 1716 字符；first_mes 64 字符：`<Gal>作者声明...<CGv67z8q></Gal>` 自定义标签
- alternate_greetings **×18**；character_book 11 条；**regex_scripts ×15**（多主题状态栏切换、CG 查看器）
- **机制依赖**：正则引擎重度 + 备选开场 UI（18 选 1）+ 世界书

### 10.4 诸天_重置_1.3.0.png（2.4MB）

- first_mes 1743 字符纯文本（"食用提示：左右翻页选择开局，并根据开局开关相应的世界书条目"）
- **character_book 184 条**；alternate_greetings ×10；regex_scripts ×9；tavern_helper.scripts **×4**
- 正则明细（体现三类时机）：
  - `诸天_隐藏状态栏`：`<StatusBlock>` → 空（mdOnly=true，显示层隐藏）
  - `赛博朋克-状态栏美化` 等 4 个主题：`<StatusBlock>` → 1.2~2 万字符 HTML（mdOnly=true）
  - `只发送最新3楼的变量更新`：`<UpdateVariable>` → 空（**mdOnly=false → promptOnly 裁剪**）
  - `仅格式思维链`：`<Analysis>` → 空（mdOnly=true）
  - `对 AI 隐藏状态栏`：`<StatusPlaceHolderImpl/>` → 空（mdOnly=false）
  - `隐藏变量`：`<UpdateVariable>` → 空（mdOnly=true）
- tavern_helper.scripts[0]：`自动掷骰脚本`（UserScript，含按钮）
- **机制依赖**：Mvu 全家桶（世界书+正则双管线+楼层变量）+ 脚本运行时 + 世界书条目 enabled 开关（开局选择）+ 互斥组

### 10.5 雾津市播种计划.png（4.7MB）

- first_mes 空串；alternate_greetings **×54**；character_book 67 条；regex_scripts ×8；tavern_helper（scripts + variables）；**quick-response-force** 扩展
- **机制依赖**：54 开场选择 UI + 世界书 + 快速回复强制

### 10.6 汇总：机制 → 卡覆盖矩阵

| 机制 | 怪奇录 | 凡人 | 林霖 | 诸天 | 雾津 |
|---|:-:|:-:|:-:|:-:|:-:|
| 显示层正则（markdownOnly） | ✅ | ✅ | ✅ | ✅ | ✅ |
| prompt 层正则（promptOnly） | — | — | — | ✅ | ✅ |
| 代码块 → iframe 界面 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 世界书（character_book） | — | ✅ | ✅ | ✅(184) | ✅(67) |
| depth_prompt | ✅(有内容) | ✅(空) | ✅(空) | ✅(空) | ✅(空) |
| alternate_greetings 多开场 | — | ✅ | ✅(18) | ✅(10) | ✅(54) |
| tavern_helper.scripts（UserScript） | — | — | — | ✅(4) | ✅ |
| 楼层变量（Mvu） | — | — | — | ✅ | ✅ |
| 第三方扩展（quick-response-force） | — | — | — | — | ✅ |

---

## 10B. 开源方案与可复用资产调查（2026-10-03 第二轮，网络）

> 目的：不重复造轮子。已核查各项目定位、活跃度、许可证。除标注"未确认"外均为网络多源交叉验证。

### 10B.1 最重要的发现：TauriTavern（路线已被验证）

**仓库**：https://github.com/Darkatse/TauriTavern（文档站 https://tauritavern.github.io/）

- **是什么**：把 SillyTavern 移植为真正的原生应用——**前端完整保留上游 ST 1.18.0，后端从 Node.js 重构为 Rust（Tauri v2）**。Windows/macOS/Linux/**Android/iOS** 全平台。1.7k+ stars，25 contributors，2026-09 仍活跃发版（v2.3.0）
- **它证明了什么**：本报告 §12 推荐的"Web 前端 + 原生壳"混合架构 **已被完整验证可行**，且 ST 前端扩展生态（含酒馆助手）在其上全部兼容——README 明言"你的角色卡、聊天记录、预设、世界书与前端扩展，全部兼容"，内置原生 Git 管理前端扩展的安装/更新
- **关键架构手法（直接可抄的蓝图）**：
  1. **请求拦截管线**：不魔改 ST 前端，而是拦截其 `fetch` / jQuery AJAX 调用，重定向到 Rust 后端命令（模块化注入）
  2. **最小平台 ABI**：`window.__TAURITAVERN__` 暴露给前端
  3. **Clean Architecture 后端分层**：命令边界 / 应用服务 / 领域模型 / 基础设施
  4. **工程纪律**（与我们 §13 防屎山机制几乎一致）：TypeScript strict、依赖边界校验、**禁止 routing 代码直接访问 window**、行数预算；测试 910/910 通过
- **对鸿蒙的直接意义**：理论上可以把"TauriTavern 的前端 + 拦截层"跑在 ArkWeb 里，用 **ArkTS 实现 `window.__TAURITAVERN__` ABI + 拦截管线对应的后端命令**，即"TauriTavern 的鸿蒙壳"。ABI 命令面规模未查（需 PoC 评估）
- **许可证**：**AGPL-3.0**（继承 ST）。fork/衍生必须 AGPL 开源
- **注意**：酒馆助手 4.9.0 起兼容 TauriTavern 的聊天 DOM 虚拟化——两个项目互为上下游

### 10B.2 其他同类项目（架构参考）

| 项目 | 技术栈 | 许可证 | 对本项目的价值 |
|---|---|---|---|
| **RisuAI**（kwaroran/RisuAI） | Svelte + TS + Tauri，多平台 | **GPL-3.0** | `src/ts/characterCards.ts`（1100+ 行）是 V2/V3/PNG/CharX/JPEG 全格式导入导出的成熟 TS 实现，行为参考首选（GPL：抄代码须开源） |
| **airi**（moeru-ai/airi，47k stars） | Vue 3 + TS monorepo；Web PWA / Electron / Capacitor 移动端 | **MIT** | ① `@proj-airi/ccc` 包：V3 角色卡定义/解析/导出（JSON/CharX），**MIT 可直接用**；② pnpm monorepo 分包结构（stage-ui / pipelines / providers）可借鉴；③ `xsai` 轻量 LLM SDK（MIT，40+ provider）可选用于 Web 侧 |
| Tavern Studio（tavernstudio.com） | 闭源桌面客户端 | 闭源 | 仅证明商业闭源做 ST 兼容存在许可证风险，无代码价值 |
| Native Tavern（nativetavern.com） | 闭源 | 闭源 | 同上 |

### 10B.3 npm 可复用库清单（按层）

**卡解析层**：

| 库 | 许可证 | 状态 | 用途 |
|---|---|---|---|
| `@proj-airi/ccc` | MIT | 活跃（airi monorepo 内） | V3 卡定义/解析/导出（JSON/CharX）。**首选** |
| `character-card-utils`（malfoyslastname） | ISC | **3 年未更新** | V2 spec 解析/验证/转换（V2 规范作者的库）；仅 V2、偏老 |
| `@character-foundry/cli` | MIT | 9 个月前 | 角色卡检查/验证/转换 CLI |
| `koishi-plugin-chatluna-character-card` | AGPL-3.0 | 活跃 | koishi 生态的 ST 卡兼容实现，参考 |

**Web 运行时层（ST/酒馆助手同款，全部 npm 直装）**：
`showdown`（markdown，ST 同款）、`dompurify`（消毒，ST 同款）、`lodash`、`yaml`、`zod`、`ejs`（酒馆助手注入 iframe 的全家桶）、`svelte-jsoneditor`（酒馆助手变量管理器同款）。

**PNG 元数据读写**：ST 服务端 `character-card-parser.js` 基于标准 PNG chunk 操作；JS 生态有 `png-chunks-extract` / `png-chunk-text` / `upng-js`（**具体选型 PoC 时定**，未逐一验证）。

**Mvu / 变量生态**：
- `MagVarUpdate`（MagicalAstrogy/MagVarUpdate）：Mvu 引擎本体，**许可证未确认**（用前必查）
- `dsh-muv-engine` / `dsh-muv-table`（npm，中文生态，活跃）：MUV 变量引擎/表格编辑器，**能直接读 ST PNG 卡（含正则/世界书/变量表）**；**PolyForm-Noncommercial**——只能参考行为，不能抄代码
- `st-card-skills`（npm）：卡工程化 CLI + AI skill（含 `/st:mvu` 全家桶模板、`/st:frontend` Vue3 前端卡脚手架）——**开发期工具，模板可参考**

### 10B.4 鸿蒙侧验证（ArkWeb 混合开发的已知答案）

- **华为官方 FAQ 明确支持** ArkWeb 加载 Vue/React 打包产物（`npm run build` → rawfile → `$rawfile()` / `resource://rawfile/` 协议加载）
- 已被社区踩平的坑（有现成方案）：
  1. rawfile 加载 dist 时 JS/CSS 相对路径不解析 → vite `base: './'` 配置或 `resource://rawfile/` 协议
  2. Vue hash 路由（`index.html#/route`）本地加载不跳转 → 官方 FAQ faqs-arkweb-86 有解法（vite 打包配置问题为主）
  3. 富文本/拦截请求：`onInterceptRequest` + `javaScriptOnDocumentEnd` 有成熟模式
- **结论：§12 "ArkWeb 加载 Vue 前端" 的技术风险从"未验证"降级为"已知方案"**。剩余唯一未验证点仍是：srcdoc/blob iframe 同源直取 `window.parent`（PoC 1 首项）

### 10B.5 许可证矩阵（红线汇总）

| 项目/库 | 许可证 | 可否直接复用代码 |
|---|---|---|
| SillyTavern | AGPL-3.0 | fork/衍生须 AGPL 开源（含网络服务） |
| TauriTavern | AGPL-3.0 | 同上 |
| 酒馆助手 JS-Slash-Runner | **PolyForm NonCommercial 1.0.0** | 禁止商业化；非商业场景亦建议仅参考行为、不抄代码（其 4.11.0 从 Aladdin 切换而来） |
| RisuAI | GPL-3.0 | 抄代码须 GPL 开源 |
| dsh-muv-* 系列 | PolyForm-Noncommercial | 只参考行为 |
| airi / @proj-airi/ccc / xsai | **MIT** | **自由复用**（保留版权声明） |
| character-card-utils | ISC | 自由复用 |
| MagVarUpdate | 未确认 | 用前必查 |
| showdown / dompurify / lodash / yaml / zod / ejs | MIT/ISC 等 | 自由复用 |

**决策依赖**：若新项目接受 AGPL-3.0 开源 → 可直接 fork ST 前端/TauriTavern 组件，兼容性天花板最高；若要保持闭源或宽松许可 → 只能用 MIT/ISC 库 + 行为对标（自研），兼容性走 §12 的 80% 路线。

### 10B.6 对新项目路线的影响：A / B 两案修订

| | 路线 A：自研前端 + Core（原方案） | 路线 B：ST 前端 + ArkTS 后端（TauriTavern 鸿蒙版） |
|---|---|---|
| 做法 | Vue3 自研聊天前端 + TS Core 引擎 + ArkTS 哑壳 | ArkWeb 加载 ST 1.18.0 前端 + 拦截管线（fetch→ArkTS 命令）+ 实现 `__TAURITAVERN__` 类 ABI |
| ST 兼容性 | ~80%（长尾逐步磨） | **≈100%**（就是 ST，含酒馆助手等全部前端扩展） |
| 上游跟随 | 自主 | **双上游**：ST 发版要同步、TauriTavern 的适配层要跟随 |
| 代码质量 | 干净、可控、规模红线 | 继承 ST 前端巨型 jQuery 单体（"能用但屎山"）；定制 UI 困难 |
| 许可证 | MIT 库为主，可闭源 | **必须 AGPL 开源** |
| 移动体验 | 自主设计（触摸优先） | ST 前端桌面优先（TauriTavern 已做移动适配，可参考其改动） |
| 工程量 | 前端+Core 全自研 | 拦截管线 + ABI 后端命令实现（TauriTavern 已趟完路，但 ArkTS 重写量未知） |

**建议**：先做一次 **PoC 0（只读调研，半天~一天）**——克隆 TauriTavern 仓库，清点 ① 拦截注入层的文件清单与规模 ② `__TAURITAVERN__` ABI 命令面 ③ 其对 ST 前端的 patch 量。拿到数据后再在 A/B 之间做最终决策；A/B 亦可混合（B 起步验证生态、A 逐步替换模块）。

---

## 10C. ArkSilly 考古与路线终审（2026-10-03 第三轮）

> 背景：用户曾独立完成过一个 ST 鸿蒙封装项目 **ArkSilly**（`D:\DevEco_studio\ArkSilly\ArkSillyApp`），自述痛点"很难按我的想法修改、很卡、界面不好看，希望全新现代化界面 + 性能 + UI 动画"。本轮考古给出根因定性与路线终审。

### 10C.1 ArkSilly 是什么（实证）

**= 完整的"路线 B"实现**：SillyTavern 1.18.0 **前端零改动**（`public/` 打包为 `rawfile/st_public.zip`）+ **后端用 ArkTS 逐端点重写**（`StBackend.ets`，321,759 字符，56+ 端点）+ **App 内 localhost HTTP 服务器**（127.0.0.1:8000）+ ArkWeb 壳。2026-09-04 P0/P1/P2 全部收口（P3 冻结），工程纪律良好（端点级 HTTP 测试、完整踩坑文档、session 交接机制）。

阶段成果：壳加载/核心数据/LLM 代理+加密/角色卡管理（PNG 写入器）/聊天导入导出/插件系统（5C：zip 替代 git，**实测装通 Extension-TopInfoBar**）/附件图片/TTS 15 端点/向量记忆（vectra 引擎 + 7 端点）。

### 10C.2 三大痛点根因定性（含真机诊断数据）

START_HERE.md 2026-09-05 真机卡顿排查结论：**服务端/JS 主线程/渲染均健康**（API 73-107ms、零长任务、**交互 120Hz 零丢帧**）；卡感来自 ① 过滚动位移回弹（已修：overScrollMode NEVER）② 启动白屏闪烁（已修）③ **静止时合成器锁 30fps（系统省电行为，无 API 可控）**。键盘卡顿真因是系统级 + Web 级双重避让（已修：RESIZE_CONTENT + setKeyboardAvoidMode(NONE)）。

| 痛点 | 定性 | 路线 B 可解性 |
|---|---|---|
| 很难按想法修改 | "前端零改动"红线 + ST jQuery 巨型单体；改 UI = fork ST 并放弃上游同步 | **结构性无解** |
| 很卡 | ArkWeb 交互性能实测健康；卡感 = Web UI 质感 + 静止 30fps 合成器锁 + 已修复的回弹/白屏 | 部分系统性残留 |
| 界面丑 | ST 为桌面时代 Web UI，移动端无原生质感/动画 | **结构性无解** |

### 10C.3 关键认知修正

1. **ArkWeb 本身不是性能瓶颈**（交互 120Hz 实测）——自研 Web 前端的性能上限同样有保障，且更轻的前端只会更快。"卡"的教训要记在"Web UI 质感 + 静止帧率锁"头上，而不是"Web 技术栈"头上。
2. **未验证项更新**：ArkSilly 插件系统只实测过 js/css 注入型扩展（TopInfoBar），**酒馆助手的 iframe 渲染器（srcdoc + window.parent 同源直取）仍未在 ArkWeb 上验证**——保持为 PoC 1 首项。

### 10C.4 路线终审

- **路线 B（ST 前端壳）：正式排除**（用户实证否决：三大痛点两个结构性无解）。TauriTavern 的价值保留为"架构蓝图与端点语义参考"，不再作为候选路线。
- **路线 A+（自研现代化前端 + TS Core + ArkTS 哑壳）：确立为唯一路线**——唯一同时满足 ST 兼容（80% 起步长尾磨）+ 现代化 UI/动画 + 性能 + 可自主修改。

### 10C.5 ArkSilly 直接遗产（新项目资产，勿重复造轮子）

1. **`StBackend.ets`（56+ 端点完整语义）**：未来做 ST 扩展兼容层/数据导入时的端点语义权威参考（代码本身亦可择机改造回收）
2. **ArkWeb 成熟坑解法全套**（新项目直接抄）：键盘双重避让（RESIZE_CONTENT + UIContext.setKeyboardAvoidMode(NONE)）、沉浸式 setWindowLayoutFullScreen **必须异步**、返回键分层（关浮层→Web 历史→退出确认）、横屏 UA/布局切换（display.on 防抖 600ms、禁 mobile-styles.css 需改 link.media）、overScrollMode NEVER、CDP 调试（`hdc fport tcp:9222 localabstract:webview_devtools_remote_<pid>`、hilog ARKWEB-CONSOLE）、导出走 DocumentViewPicker
3. **App 内 localhost HTTP server 可行性实证**（通信方案候选）
4. PNG 卡解析/写入器（ArkTS）、LLM 代理+密钥加密、TTS、向量记忆——可改造回收
5. **性能基线数据**（API 73-107ms / 交互 120Hz / 静止 30fps 锁）——新前端的验收基准
6. 端点级移植清单文档（`ArkSillyApp/docs/`）

### 10C.6 "现代化 UI + 性能 + 动画"架构约束（回应用户核心诉求，写进新项目设计）

- 虚拟滚动 + 渲染深度窗口（界卡 iframe 按需创建/销毁）
- 动画仅用 `transform`/`opacity`（合成器友好，交互期 120Hz）；**设计规避"静止持续动画"**（30fps 锁）——呼吸灯类效果用低帧率设计或原生组件承载
- 启动直载 rawfile（免 zip 解压 + server 冷启动，白屏从源头消除）
- 通信默认 `javaScriptProxy`/`postMessage` 桥（省 HTTP 序列化层；PoC 与 localhost 方案实测对比后定）
- 移动优先 UI 设计；ArkUI 设计语言映射到 Web 侧

---

## 11. ArkTavernSolo 现状与差距

### 11.1 已有（对照验证）

| 项 | 现状 | 位置 |
|---|---|---|
| V1/V2/V3 解析 | ✅ 保留未知 extensions 原始数据 | `parser/CharacterCardJsonParser.ets` |
| character_book 解析 | ✅（含 extensions 透传） | 同上 L351/L389-L486 |
| alternate_greetings | ⚠️ 有 **MAX_ALTERNATE_GREETINGS 截断**（雾津 54 个会被截） | 同上 L369 |
| 前端卡 Web 渲染 | ✅ 自有契约 `extensions.arktavern.frontend`（html/mode/title/size/chrome/autoOpen） | `bridge/CardFrontendBridge.ets` |
| Web 桥 | ✅ `window.arktavern.*`：getVersion/getState/getStatusSchema/setState/getCharacter/getMessages/send/appendInteraction/close（契约 v3）；App→页 push：message_update/status_update | 同上 |
| 双指缩放 / 面板浮层 | ✅（四角 44vp 热区、宽度持久化等，见 project memory） | `components/CardFrontendWeb.ets` |

### 11.2 缺失（兼容性根因）

1. **正则脚本引擎**：`extensions.regex_scripts` 完全不消费（数据在但无运行时）
2. **世界书激活算法**：无递归/sticky/cooldown/组/预算/scan_depth/selectiveLogic
3. **TavernHelper API**：自有 `arktavern.*` 契约与生态（`TavernHelper.*` + iframe 全局函数）零交集
4. **代码块渲染器**：消息内 HTML 代码块 → Web 界面的管线（现有 CardFrontendWeb 只服务"整卡一个界面"，不是"每楼一个界面"）
5. **宏系统不全**、depth_prompt、per-swipe 楼层变量、ST 事件总线、STscript、预设 JSON 导入
6. 显示层与 prompt 层没有分离的正则应用点（架构上是单管线）

### 11.3 根因一句话

**项目把"角色卡"当作静态数据 + 单一自有前端契约来支持；而 ST 生态把"角色卡"当作"数据 + 一组声明式插件（正则/世界书/脚本）+ 一个浏览器运行时"来执行。** 兼容性 = 补齐运行时，而不是补齐解析。

---

## 12. 鸿蒙原生可行性清单（重构决策依据）

判定前提：ArkWeb = 完整 Chromium 内核（srcdoc / iframe / blob URL / postMessage / CDN JS 全可用）；聊天列表是 ArkUI 原生渲染，**与 ST "整个聊天是一个网页" 的架构根本不同**。

### 12.1 ✅ 可以实现（机制有对应物）

| 项 | 方案要点 |
|---|---|
| PNG/JSON 卡解析（ccv3/chara 双 chunk） | 手写 PNG chunk 解析（本次调查已验证 PS 可解，ArkTS 同理）；现有 parser 已是基础 |
| 卡内正则脚本引擎（全字段语义） | 纯文本处理。ArkTS RegExp = JS 正则方言（命名组/lookbehind 可用）。**必须建三条应用管线：显示层（isMarkdown）/ prompt 层（isPrompt）/ 编辑-初始化层（isEdit/中性）**，与 ST 调用点一一对齐 |
| 世界书全量（转换 + extensions 超集 + 激活算法） | 纯逻辑。注意 timedWorldInfo 持久化、递归上限、互斥组加权随机、token 预算 |
| 提示词组装顺序 / system_prompt 覆盖 / depth_prompt | 纯逻辑（对照 §6.1 顺序表） |
| 宏系统（注册式 + 嵌套） | 纯文本，逐步补全集 |
| 消息结构（swipes / per-swipe variables / extra.display_text） | DB schema 扩展；variables 按 swipe 分版本 |
| **HTML 界面卡渲染（每楼）** | ArkWeb 组件加载包装 HTML（复刻 createSrcContent：视口变量改写、头像 CSS 类、高度自适应消息、CDN 注入）。渲染深度窗口管理（复刻酒馆助手策略：默认只渲染最近 N 楼） |
| **TavernHelper API 形状兼容** | 注入 shim JS：`postMessage`/`javaScriptProxy` RPC → 包装成同名全局函数（getVariables/eventOn/...）。**API 名字与签名可做到与酒馆助手一致，机制换成 RPC**。现有 CardFrontendBridge 就是该思路雏形，需换契约目标（arktavern.* → TavernHelper.*） |
| 事件桥（tavern_events 子集） | App 内 EventBus，事件名对齐 ST event_types |
| 卡内脚本 + 脚本按钮 | 每卡一个脚本运行时（隐藏 Web 组件或受控 JS 沙箱）+ 聊天页按钮 UI |
| Mvu 全家桶 | = 世界书 + 正则双管线 + 楼层变量 + 前端读变量，全落在基础件上 |
| alternate_greetings 多开场（含 54 个） | 纯数据 + 选择 UI；**放开 MAX_ALTERNATE_GREETINGS 截断** |
| ST 预设 JSON 导入 | 解析 OpenAI Settings 格式（中文卡普遍要求配套预设） |
| 音频（BGM 列表） | Web Audio / AVPlayer |
| 安全授权模型 | 导入时对卡内正则/脚本弹"允许"白名单（对齐 ST character_allowed_regex 语义） |

### 12.2 ⚠️ 能做但有显著工程/体验代价

| 项 | 难点与对策 |
|---|---|
| **每楼一个 Web 组件** | ST 每楼一个 iframe 很轻；ArkWeb 组件实例重。必须做渲染深度窗口 + 组件复用/销毁 + reload 键控（防 swipe/编辑闪烁、保状态）。这是渲染器的核心工程量 |
| Markdown 等价性 | showdown 输出（`<q>` 引号、代码块结构、换行修复）是正则替换串的隐性契约；要么移植 showdown 行为，要么整楼走 Web 渲染 |
| DOMPurify / custom-style 作用域 | 原生侧无 DOM。富文本走 ChatRichText 需补 HTML 白名单语义；`<style>` 作用域限定需在 Web 侧复刻 |
| window.parent 直取（lodash/YAML/showdown/toastr/zod/EjsTemplate） | 不能直通 → 这些库打包进 rawfile 随 shim 注入；直接 `parent.xxx` 的写法会失效（shim 尽量覆盖常见面） |
| STscript（triggerSlash） | 大量卡用 /setvar /buttons /input /roll；需要子集解释器，边界模糊、工作量不小 |
| CDN 依赖（fonts.googleapis / jsdelivr） | 国内可达性差；酒馆助手自己用 testingcf.jsdelivr.net 镜像——需内置镜像/代理策略 + 离线兜底 |
| 3 万字符 HTML 重建 | 正则替换产物每次 swipe/编辑全量重建 Web 内容；闪烁与 iframe 内状态丢失要专门处理（ST 用 reload_memo + 渲染窗口规避） |
| 卡内脚本安全 | 任意 JS 常驻运行；必须导入授权 + 行为审计日志（酒馆助手有 iframe_logs 先例） |

### 12.3 ❌ 原生 App 上实现不了 / 不现实

| 项 | 原因 |
|---|---|
| 依赖其他 ST 插件的卡（表情 Expressions、数据库插件、翻译、MEM/Memory、骰子系统等） | 生态型依赖无对应物；只能按热门插件逐个评估做子集（如骰子系统依赖数据库插件 → 不可行） |
| `SillyTavern.getContext()` 深度写操作 | getContext 暴露 ST 全局可变状态，卡脚本直接改；RPC shim 只能覆盖只读快照 + 白名单写，改不到的静默失效 |
| 群聊特性（group_only_greetings 等） | Solo 定位单聊（预期内放弃） |
| TauriTavern 虚拟化 / MovingUI 等 ST DOM 级特性 | 与 ST DOM 强绑定，无意义复刻 |
| "F12 调试 / Blob URL 便于调试"开发者体验 | App 无对应物（hdc 远程调试可部分替代） |

### 12.4 综合判断

**约 80% 中文卡生态兼容性落在四件基础件：正则引擎（双管线）+ 世界书激活算法 + TavernHelper 变量/事件/消息 API + 代码块 Web 渲染器。** 前三件纯 ArkTS 逻辑；第四件项目已有 60% 基础设施。架构核心决策只有一个：**TavernHelper shim 走 postMessage RPC 仿真同源 window**。其余是体力活与细节对齐。

---

## 13. 重构方向与待决策问题（开工前必须对齐）

按依赖顺序：

1. **契约先行（数据模型）**：是否按"ST 优先"重定——消息表加 `swipes/variables/extra`；正则脚本表（全字段）；世界书表（含 extensions 超集字段）；预设表对齐 ST JSON；宏注册表。这决定所有上层。
2. **TavernHelper shim 的 MVP 范围**：建议只做「显示层正则 + 代码块渲染 + getVariables/getAllVariables/getChatMessages/setChatMessages + 核心事件（MESSAGE_RECEIVED/CHAT_CHANGED/GENERATION_*）」——已能点亮怪奇录/凡人/林霖这类纯界面卡；诸天这类脚本卡放第二批。
3. **Web 组件生命周期策略**：渲染深度默认值（酒馆助手默认 0=全部渲染、TauriTavern 虚拟化后改为窗口）；组件复用；swipe 重建的 reload 键控。
4. **安全授权模型**：导入时白名单 UI（正则/脚本分开授权），对齐 ST 语义。
5. **回归基准**：用本地 5 张卡做兼容性金标准——每张卡先产出"期望行为清单"（§10 矩阵），逐项验收。
6. **放与不放**：STscript 子集、音频系统、预设导入、quick-reply —— 各自独立里程碑，不阻塞主线。

---

## 附录 A：关键源码索引（本地路径 + 行号，均已验证）

| 内容 | 位置 |
|---|---|
| PNG chunk 读写 | `ST/src/character-card-parser.js` L15-L78 |
| V2→内部字段映射 / charaFormatData | `ST/src/endpoints/characters.js` L513-L552, L565-L657 |
| BYAF 转换 | `ST/src/byaf.js` L89-L120, L248-L268 |
| 卡导入前端入口 | `ST/public/script.js` L10476-L10528 |
| messageFormatting 全流程 | `ST/public/script.js` L1753-L1912 |
| getMessageTextHTML / addOneMessage / updateMessageElement | `ST/public/script.js` L2464-L2477, L2492-L2531, L2559-L2637 |
| 发 AI 前正则+reasoning 合并 | `ST/public/script.js` L4430-L4498 |
| 开新聊天 first_mes/swipes 初始化正则 | `ST/public/script.js` L7660-L7665 |
| 消息编辑正则 | `ST/public/script.js` L8085-L8122 |
| 正则 placement 枚举 / getRegexedString / runRegexScript | `ST/public/scripts/extensions/regex/engine.js` L281-L292, L334-L381, L391-L448 |
| 正则三来源+白名单 | `ST/public/scripts/extensions/regex/engine.js` L98-L220 |
| 世界书激活主循环 | `ST/public/scripts/world-info.js` L4597 起 |
| WorldInfoBuffer 评分 / TimedEffects | `ST/public/scripts/world-info.js` L428-L688 |
| 位置枚举 | `ST/public/scripts/world-info.js` L855-L864 |
| 互斥组（inclusion group） | `ST/public/scripts/world-info.js` L5271-L5355 |
| convertCharacterBook | `ST/public/scripts/world-info.js` L5498-L5525 |
| 提示词组装顺序 | `ST/public/scripts/openai.js` L1161-L1254 |
| 系统提示优先级 | `ST/public/scripts/openai.js` L1358-L1507 |
| WI/注入格式化 | `ST/public/scripts/openai.js` L780-L865 |
| 宏引擎注册 | `ST/public/scripts/macros/macro-system.js` L61-L84 |
| 聊天宏定义 | `ST/public/scripts/macros/definitions/chat-macros.js` L8-L81 |
| instruct 模板 | `ST/public/scripts/instruct-mode.js` L317-L444 |
| 事件类型全表 | `ST/public/scripts/events.js` L2-L110 |
| 酒馆助手 manifest | `JS-Slash-Runner/manifest.json`（v4.9.5） |
| iframe 内容构造 / vh 改写 | `JS-Slash-Runner/src/panel/render/iframe.ts` L5-L103 |
| Iframe 组件（srcdoc/blob、Teleport 挂载） | `JS-Slash-Runner/src/panel/render/Iframe.vue`（全文 80 行） |
| predefine 同源桥 | `JS-Slash-Runner/src/iframe/predefine.js`（全文 48 行） |
| 渲染 runtimes store（事件监听/深度窗口） | `JS-Slash-Runner/src/store/iframe_runtimes/message.ts` |
| 渲染器设置面板 | `JS-Slash-Runner/src/panel/Render.vue` |
| isFrontend 判据 | `JS-Slash-Runner/src/util/is_frontend.ts` L1-L8 |
| TavernHelper API 汇总 | `JS-Slash-Runner/src/function/index.ts` L210-L479 |
| 变量 7 类读写/合并 | `JS-Slash-Runner/src/function/variables.ts` L39-L259 |
| 消息 CRUD 实现 | `JS-Slash-Runner/src/function/chat_message.ts` L71-L423 |
| 注入 injectPrompts | `JS-Slash-Runner/src/function/inject.ts`（全文 58 行） |
| 事件桥 / tavern_events / iframe_events | `JS-Slash-Runner/src/function/event.ts` L170 起 |
| 显示格式化工具 | `JS-Slash-Runner/src/function/displayed_message.ts` |

（`ST/` = `D:\ArkProject\ArkTavernSolo\APK-reference\SillyTavern-Launcher\SillyTavern`；`JS-Slash-Runner/` = `ST/public/scripts/extensions/third-party/JS-Slash-Runner/`）

## 附录 B：术语表

| 术语 | 含义 |
|---|---|
| 角色卡 V2/V3 | chara_card_v2 / chara_card_v3 规范（V3 = kwaroran/RisuAI 主导的 spec_v3） |
| 世界书 / World Info / Lorebook | 关键词激活的背景知识注入系统（同义词） |
| character_book | 卡内嵌世界书（V2 规范字段） |
| 正则脚本 / Regex Script | 卡/全局/预设携带的文本替换规则（显示层或 prompt 层） |
| scoped regex | 卡内正则（需用户白名单允许） |
| 楼层 | 一条消息（message floor） |
| swipe | 同一楼的候选回复（左右切换） |
| 楼层变量 | message.variables[swipe_id]，Mvu 的存储单元 |
| Mvu / MagVarUpdate | 变量框架：AI 输出 UpdateVariable 块 → 正则裁剪 → 前端读变量 |
| 前端卡 / 界面卡 | 内嵌 HTML/JS 界面的角色卡（酒馆助手渲染） |
| 类脑 | biluo，前端卡作者生态代称（怪奇录即类脑风格） |
| STscript | ST 斜杠命令脚本语言（/setvar /roll ...） |
| macro / 宏 | {{user}} {{char}} 等模板占位符 |
| depth_prompt | 卡内声明的按深度注入提示（extensions.depth_prompt） |
| 蓝灯 / constant | 世界书常驻条目（无需关键词激活） |
| TavernHelper | 酒馆助手暴露给卡脚本的 API 命名空间（window.TavernHelper） |
| TauriTavern | 酒馆助手的上游项目（Rust 客户端），manifest 中的 activateTauriTavernChatSurface 与之相关 |

## 附录 C：网络参考

- 酒馆助手官方文档：https://n0vi028.github.io/JS-Slash-Runner-Doc/
- 酒馆助手仓库：https://github.com/N0VI028/JS-Slash-Runner
- Mvu 引擎：https://github.com/MagicalAstrogy/MagVarUpdate
- ST 官方文档（宏/STscript/世界书）：https://docs.sillytavern.app/usage/core-concepts/macros/ 、https://docs.sillytavern.app/usage/st-script/
- 角色卡 V3 规范（RisuAI 维护）：https://github.com/kwaroran/RisuAI （spec_v3 文档）
- st-card-skills（卡工程化 CLI + AI skill）：https://www.npmjs.com/package/st-card-skills
- 骰子系统（酒馆助手插件生态复杂度参考）：https://jerryzmtz.github.io/DiceSystemManual/
