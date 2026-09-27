# 2026-09-27 全项目审计报告与重构路线图

> 类型：**只读审计**（本次未修改任何 .ets 代码）· 基线：`refactor-baseline` @ `8dbd9df` · 工作区：干净
> 执行：AI 会话（全量扫描 + 双层深挖 + 交叉验证）· 状态：沿 §6 路线图**分步执行**（一次一操作 → 编译 → 提交）

## 0. TL;DR

1. **不需要整体重构。** 分层主干成立（models 零违规、services 不反向依赖 pages/components、viewmodels 不碰 pages/database）；痛点集中在 6 个巨型文件 + 2 组跨文件重复实现 + 文档失修。
2. 最大单点是 **`ChatService.ets`（6,770 行）**：拆成「瘦门面 + 若干控制器」是最有价值的动作（P2，与 2026-09 早期蓝图一致）。
3. **`ChatPage.ets`（6,239 行）** 的 5 个巨型 @Builder 可先抽成组件（P1，纯搬运，风险低）。
4. 两组高价值重复消灭：`ChatSessionRootView ↔ ChatSessionListPanel`（近乎全量重复）、`ChatViewModel ↔ ChatSessionListViewModel`（世界分组 API 双份）。
5. 危险区（**最后动或不动**）：ChatService 流式核心（`doStream` / `activeGeneration` / `handle` / `messages` 四者共享可变状态）。

## 1. 审计方法与范围

- **全量扫描**：286 个 .ets / 112,801 行（entry/src，行数口径与旧文档一致：非空行）
- **分层依赖**：对 components / models / services / pages / viewmodels / database 逐层做 import 违规扫描（Grep 全量）
- **深度审计**：ChatService.ets、ChatPage.ets 全文通读 + 方法体量测量（两套独立测量交叉验证）
- **中级速查**：DatabaseSchema / ChatSessionRootView / MemoryService / ChatViewModel
- **辅助核对**：路由表 vs 页面文件、git 跟踪状态、.gitignore、全仓引用关系

## 2. 规模全景

### 2.1 分层统计（entry/src）

| 层 | 文件数 | 行数 |
|---|---|---|
| pages | 34 | 29,852 |
| services | 50 | 29,135 |
| viewmodels | 21 | 10,107 |
| repositories | 21 | 7,785 |
| models | 55 | 7,166 |
| parser | 14 | 6,546 |
| database | 4 | 5,314 |
| components | 27 | 5,108 |
| network | 16 | 4,477 |
| storage | 15 | 3,005 |
| utils | 12 | 1,731 |
| theme | 1 | 373 |
| bridge | 1 | 367 |
| entryability | 2 | 267 |
| entrybackupability | 2 | 40 |
| 其他（根级/测试） | 11 | 1,528 |
| **合计** | **286** | **112,801** |

### 2.2 巨型文件（全量行数，2026-09-27 实测）

| 文件 | 实测 | 旧记录 | 备注 |
|---|---|---|---|
| services/ChatService.ets | **6,770** | 6,370 | P2 核心；1 类 / 4 接口 / 2 枚举 / 15 顶层函数 / ~167 方法 |
| pages/ChatPage.ets | **6,239** | 5,848 | 41 个 @Builder；P1 组件抽取 |
| database/DatabaseSchema.ets | **2,879** | 2,673 | L1-503 全量 import + 44 段 if 分发链 |
| pages/tabs/ChatSessionRootView.ets | **2,786** | 2,615 | 66 方法 / ~40 状态字段；与 ChatSessionListPanel 重复 |
| services/MemoryService.ets | **2,014** | 1,874 | 5 类职责 / 8 个可空依赖 |
| viewmodels/ChatViewModel.ets | **1,952** | 1,793 | 124 方法 / ~35 公开字段 |
| pages/LorebookPage.ets | 1,653 | — | 次级 |
| pages/tabs/CharacterRootView.ets | 1,627 | — | 次级 |
| services/ConversationBranchPersistenceService.ets | 1,551 | — | 次级 |
| parser/ChatTextParser.ets | 1,439 | — | 次级 |
| services/ai/AiCharacterGenerationService.ets | 1,403 | — | 次级 |
| pages/CharacterEditPage.ets | 1,401 | — | 次级 |
| database/DatabaseMigration.ets | 1,383 | — | 次级 |

> 旧记录来自早期交接文档，口径与版本略旧；**一律以实测为准**。

## 3. 分层依赖审计

### 3.1 结论

- ✅ **models 零违规**；**services 不 import pages/components**；**viewmodels 不 import pages/database**
- ⚠️ **components 越层**：2 文件 3 处（违反"components 纯 UI"）
- ⚠️ **pages 直连服务**：17 个页面文件 import 了具体服务（含仅导入常量/枚举的 3 个）。注意：页面经 `AppServices.getXxx()` 静态取用是**架构允许**的（组合根设计）；真正越线的是绕过 ViewModel 直调业务服务
- ⚠️ **services 直连 DbHelper**：10 个文件 15 处，多为 `*PersistenceService` 与 `sync/`。**口径待拍板**：若认可"持久化服务 ≈ 仓储"这一层，建议正式记为 persistence 层；否则后续补 Repository 收口

### 3.2 违规明细

| 位置 | 违规 | 说明 |
|---|---|---|
| components/CardFrontendWeb.ets:23 | import ChatViewModel | 组件直连 VM |
| components/ChatSessionListPanel.ets:25,30 | import ChatViewModel / AppServices | 组件内含业务逻辑 |
| pages/ChatPage.ets | import 8 个具体服务 | TtsService / EdgeTtsService / MacroReplacer / ContextBudget* / ChatBackgroundConfig / AiLorebookMode / ChatMemoryMode（最重） |
| pages（另 16 文件） | import 具体服务 | AiCharacter* / Tts / Persona / Model / Memory / ChapterMemoryIndexer / Sync / Market 等，多为薄页面 |
| pages/LorebookPage.ets:18 | import CharacterRepository | 页面直连仓库 |
| services/（10 文件） | import DbHelper / DatabaseConstants | AppServices、ChatPersistence、Fork、BranchPersistence、MemoryPersistence、SwipePersistence、ArchiveImport、sync/* |
| 常量导入 | pages import ChatService / MemoryService 常量 | 常量应下沉（如 models/constants），轻微问题 |

### 3.3 路由核对

- 页面文件 34（含 `tabs/` 4 个组件式根视图）vs `main_pages.json` 注册 30：**无孤儿页面**
- 观察项：`EdgeTtsTestPage`（测试页）已注册进正式路由表

## 4. 坏味道清单

### 4.1 ChatService.ets（6,770 行）

**功能簇（按文件顺序）**：

| 行号 | 内容 | 行数 |
|---|---|---|
| 1-421 | 契约常量 + 15 个顶层纯函数（状态文本 / 前端交互记录） | ~421 |
| 423-831 | 类型、29 个实例字段、**17 参构造函数** | ~409 |
| 833-1050 | 会话初始化（initContext / initializeSession / createNewSession） | 218 |
| 1051-1238 | 开场白与章节（buildGreetingPool / createChapter） | 188 |
| 1240-1370 | 称呼 / Persona 解析 | 130 |
| 1372-1970 | 发送与一次性生成（sendMessage / impersonate / autoContinue） | 598 |
| 1970-2147 | 旁白（narratorMessage / narratorMessageOnly） | 177 |
| 2149-2441 | 重生成 / Branch fork / stopGeneration | 292 |
| 2483-2734 | 多会话 CRUD | 251 |
| 2736-3230 | **角色状态**（syncStatus* / generateStatusFieldsNow / modifyStatusWithPrompt） | ~494 |
| 3216-3540 | 偏好加载 / 世界书记忆刷新 | ~324 |
| 3546-3628 | 只读查询 / 估算 / dispose | 82 |
| 3630-4037 | **流式核心**（doStream / finalizeAssistantTurn） | 407 |
| 4037-4721 | **请求构建 + 上下文注入**（buildRequestMessages / 记忆 / 粘滞锚点） | 684 |
| 4727-4980 | 记忆总结后台 + Token 预算 | 253 |
| 4982-5466 | 回调 / 增量 / 持久化工具 | 484 |
| 5468-5858 | **Swipe** | 390 |
| 5860-6660 | **Branch 操作** | 800 |
| 6665-6770 | 消息删除 / 编辑 | 105 |

**坏味道 Top（两套测量交叉验证，行号为起点、长度为估算）**：

| # | 位置 | 问题 |
|---|---|---|
| 1 | `buildRequestMessages` L4116（≈310 行） | 超长方法：内嵌 5 类注入 + 3 层日志 |
| 2 | `doStream` L3697（≈236 行） | 超长方法；闭包套闭包 |
| 3 | `editUserMessageAndGenerate` L6393（≈163 行） | 超长方法 |
| 4 | `generateAlternativeCandidate` L5637（≈133 行） | 超长方法 |
| 5 | `autoContinue` L1773（≈132 行） | 超长方法 |
| 6 | `updateRequestPlan` L4848（≈109）/ `generateImpersonateCandidates` L1580（≈109） | 超长方法 |
| 7 | L3712-3745 / L3805-3830 / L5014-5037 / L2421-2439 | **失败收尾逻辑重复 4 份**（mark→emit→persistFinalAssistant().then()） |
| 8 | L5522-5538 / L5565-5581 / L5609-5624 | **Swipe 三方法近乎逐字重复** |
| 9 | L4548-4599 vs L4622-4670 | 锚点插入重复（按需记忆 vs 粘滞世界书） |
| 10 | L2983-3019 vs L3088-3129 | 状态一次性请求重复（同 settled/finish/callbacks） |
| 11 | `findLastAssistantIndex()` L2140 | **死代码**（已核实全项目 0 调用） |
| 12 | L3811-3830 / L3987-4020 / L4552-4581 | 深层嵌套（callback→then→if→if/loop） |
| 13 | L892 forceNew / L318 regenerate / L2111 include / L1100 activate | 布尔标志参数 |
| 14 | `deleteMessage` L6709 / `editNarratorMessage` L6731 / `editAssistantMessage` L6763 | **原地改数组（splice 等）且不 emitMessages**，与文件头"不可变更新"矛盾 |
| 15 | — | TODO / 注释掉代码：0 命中（干净） |

**拆分接缝（供 P2）**：

| 目标类 | 搬运范围 | 风险 |
|---|---|---|
| `ChatRequestBuilder` | L4037-4425、L4436-4721、L4848-4980（请求构建 / 注入 / 预算计划） | 低（共享状态只读） |
| `ChatOneShotGenerator` | L1456-1968（impersonate / persona 提取 / autoContinue 及其 parser） | 低 |
| `ChatStatusService` | L2736-3538（角色状态簇） | 中（自带状态，依赖 persistence + modelService） |
| `ChatSwipeController` | L5468-5858 | 中高（与 messages / lastAssistantMessageId / activeGeneration 强耦合） |
| `ConversationBranchService` 门面 | 先搬 L5865-6160 纯判定与查询；fork+stream 部分暂留 | 中 |
| （暂不动）流式核心 | L3630-4010、L5079-5374 | **高**：`activeGeneration` / `state` / `currentHandle` / `messages` 四者共享可变状态 |

**其他风险**：无类内 static 字段（符合声明），但经 AppServices 拿单例、写全局 `AppStorage('chatMemoryVersion')`；并发互斥靠 4 个布尔 + operationId（无统一锁）；`persistStatusConfig` / `persistChatActivity` 为 fire-and-forget，可能与 `reloadCurrentSession` 交错覆盖；`emitMessages` 未 try 包裹用户回调；`dispose` 未清 `*InProgress` 标志。

### 4.2 ChatPage.ets（6,239 行 · 1 struct · 41 @Builder · 80+ @State · 60+ 私有字段）

**坏味道 Top**：

| 位置 | 问题 |
|---|---|
| `build` L952（≈362 行） | 巨型 build（背景 / 状态 / 列表 / 浮层全在内） |
| `appearanceSheetContent` L2732（≈360 行） | 外观面板巨型 Builder |
| `personaPickerSheet` L4746（≈207 行） | 巨型 Builder |
| `inputArea` L3808（≈160）/ `messageList` L3456（≈159） | 巨型 Builder |
| L101-387 | 状态变量集中区（数百个字段，页面过肥核心症状） |
| L487-860 | 持久化配置读写 + 系统监听混杂（Preferences / TTS / 键盘 / 深色模式） |
| L4950-5490 | 辅助业务逻辑区（发送判断 / 预算 / 快照刷新），应上移 ViewModel |
| L2644-2708 | 世界书 AI 操作入口（页面直接处理 AI 建议与变更集） |
| L5214-5266 | 直接操作 window / display / scroller |

**抽取接缝（供 P1-3）**：

| 目标组件 | 源 Builder（行号） | 入参/回调要点 |
|---|---|---|
| `ChatMessageList` | `messageList` L3456（≈160 行） | renderStates / dataSource / 交互与 TTS 回调 |
| `ChatInputArea` | `inputArea` L3808（≈160 行） | inputText / canSend / isGenerating / send / stop / 旁白 |
| `ChatAppearancePanel` | `appearanceSheetContent` L2732（≈360 行） | 气泡透明度 / 显示范围 / 字体配色 / 预览 |
| `ChatStatusWorldPanel` | L2104-2453 | 世界书 / AI 操作 / 变更预览 |
| `ChatForkPicker` | `forkModePickerDialog` L5623（≈80 行） | 目标消息 + 确认/取消 |

**引用方**：ChatSessionRootView、CharacterRootView、MarketDetailPage（均经 `router.pushUrl` + `AppStorage.pendingChatId/pendingCharacterId` 跳入）；页面自身在 aboutToAppear 读取 pending 参数。

### 4.3 次级大文件速查

| 文件 | 结构 | 坏味道 Top | 拆分建议 |
|---|---|---|---|
| DatabaseSchema（2,879） | L1-503 import；DDL 常量 V1..V47；`getSchemaStatements` L2579-2713（44 段 if）；建表 L2715-2755（37 表）；索引 L2757-2879（~120） | ①500 行 import ②巨型 if 链（**V38→39 / V39→40 映射疑点，待核查**）③逐版重复声明 ④纯数据文件混函数 ⑤V6/V5 定义顺序乱 | DDL 按域拆文件；版本映射改 Map Registry |
| ChatSessionRootView（2,786） | L179-350 生命周期；L494-1380 拖拽重排（13 个 @State）；L1522-2024 分组弹窗；L2056-2777 归档导入导出 | ①上帝组件（列表/拖拽/分组/归档 4 职责）②moveChatDialog ≈178 行 / importPreviewContent ≈131 行 ③与 ChatSessionListPanel 重复 | 拖拽控制器 / 归档弹窗 / 分组弹窗（P1-4 一并做） |
| MemoryService（2,014） | L67-195 构造（8 可空依赖）；L198-450 加载+多层注入；L450-634 触发判定；L634-1035 生成；L1305-1507 会话记忆；L1507-1898 CRUD；L1900-2014 纯函数 | ①5 类职责 God Service ②generateSessionMemory ≈143 / updateCoreMemory ≈134 / doGenerateChapter ≈132 ③旧兼容 API 疑死代码（L249/273/657，待深查）④大量内联 prompt 字符串 | MemoryPromptBuilder / WorldMemoryStore / MemoryTriggerPolicy（P3） |
| ChatViewModel（1,952） | L61-153 状态；L217-580 初始化与消息；L699-979 会话/分组；L1047-1350 分支+编辑；L1356-1523 记忆/persona/状态；L1527-1736 估算/lorebook | ①God VM（124 方法）②~35 公开字段全暴露 ③错误映射双份（toUserError L1910 / toSessionOpError L1005）④世界分组与 ChatSessionListViewModel 双份 ⑤直连 ModelService/LorebookService（越层，待深查） | LorebookPanelVM / ChatErrorMapper / 会话分组桥（P3） |

### 4.4 跨文件重复实现（专章）

**① `ChatSessionRootView` ↔ `ChatSessionListPanel`（近乎全量重复，高优先级）**

| 功能 | RootView 行 | Panel 行 |
|---|---|---|
| buildRows（世界分组/排序/折叠） | L554 | L297 |
| isWorldCollapsed / toggleWorldCollapsed | L738 / L743 | L366 / L371 |
| persistCollapsedWorldIds | L771 | L399 |
| groupHeaderRow | L632 | L407 |
| create/rename/deleteGroupDialog | L1522+ | 对应区 |
| moveChatDialog | L1724 | L858 |
| 折叠态常量 | L46 | L34 |

→ 建议合并为单组件 + 布局模式参数（P1-4）。

**② `ChatViewModel` ↔ `ChatSessionListViewModel`（世界分组 API 双份）**
`getWorldName` L840/L314、`getChapterLabel` L849/L327、`createWorldGroup` L916/L359、`renameWorldGroup` L932/L403、`deleteWorldGroup` L948/L423、`moveChatToWorld` L964/L443。

**③ 其他**：ChatViewModel 错误映射双份（见 4.3）；MemoryService 旧兼容 API 疑死代码。

### 4.5 死代码与注释码

- `ChatService.findLastAssistantIndex()` L2140 —— **已核实 0 调用**（P1-1 删除）
- MemoryService `getEffectiveMemory` / `getInjectionContext` / `trySummarize` —— 疑死代码，待复核（P1-1）
- ChatService 内 TODO / 注释掉代码：0 命中（干净）；ChatPage 未见大规模注释码

## 5. 与历史蓝图的对齐

2026-09 早期的拆分蓝图（`archive/agent/10_REFACTOR_HANDOVER.md`）主张「瘦门面 + 5 控制器」，与本次独立审计高度吻合：

| 历史蓝图 | 本次审计对应 |
|---|---|
| `GenerationController` | 流式核心（暂不动）+ 失败收尾/状态机归并 |
| `ModifierAgent` | `ChatOneShotGenerator`（impersonate/旁白/续写/persona 提取） |
| `SessionStore` | 会话生命周期簇（833-1050 / 2483-2734）+ 上下文解析（1240-1370） |
| `SwipeController` | `ChatSwipeController`（5468-5858） |
| `BranchController` | `ConversationBranchService`（5860-6660，含吸收 ForkChatService） |

结论一致：**不整体重构、不动底层服务、逐控制器抽取、边拆边验证**。

## 6. 重构路线图（执行清单）

> 通用纪律：**一次一操作 → 编译验证（最多 3 次）→ 提交**；任一步失败立刻 `git checkout -- <file>` 回滚。
> 每步提交信息：`refactor(scope): 中文描述`；改动前 `git status` 确认工作区干净。

### P1 清理与低风险重构（不改行为）

- [ ] **P1-1 死代码清理**：删 `findLastAssistantIndex`；复核 MemoryService 旧 API（确认无引用后删）
- [ ] **P1-2 ChatService 重复逻辑消除**（4 组）：Swipe 三方法 → 一；失败收尾 4 处 → 一（私有方法收口）；锚点插入两处 → 一（参数区分）；状态一次性请求两处 → 一
- [ ] **P1-3 ChatPage 组件抽取**（5 个，逐个搬运 + 编译 + 提交；只移动代码不改行为）
- [ ] **P1-4 会话列表去重**：RootView / Panel 合并（先合并纯函数与常量，再合并 UI）
- [ ] **P1-5 组件越层修复**：`CardFrontendWeb`、`ChatSessionListPanel` 的 VM 依赖上提或改造为纯展示 + 回调
- [ ] **P1-6 不可变性修复**：3 个编辑方法返回新数组 + 补 `emitMessages`（行为等价为前提）

### P2 ChatService 瘦身（按 §4.1 接缝，风险从低到高）

- [ ] P2-1 `ChatRequestBuilder`（低） → P2-2 `ChatOneShotGenerator`（低） → P2-3 `ChatStatusService`（中） → P2-4 `ChatSwipeController`（中高） → P2-5 Branch 门面（中）
- [ ] 每步前后跑「聊天主路径冒烟清单」：发送/流式/停止 → 重生成 → 分支切换 → Swipe → 旁白 → 代写 → 记忆生成/查看 → 世界书注入 → 会话增删切换 → 归档导出导入 → 深浅色
- [ ] 目标：`ChatService` 从 6,770 行降到千行级门面（流式核心保持不动）

### P3 中风险拆分与治理

- [ ] ChatViewModel：LorebookPanelVM / ChatErrorMapper / 会话分组桥
- [ ] MemoryService：MemoryPromptBuilder / WorldMemoryStore / MemoryTriggerPolicy
- [ ] DatabaseSchema：DDL 按域拆文件 + 版本映射改 Map Registry（附带核查 V38→39/39→40 疑点）
- [ ] pages → services 分级治理（先定口径：哪些薄页面可接受直连，哪些必须走 VM）
- [ ] services → DbHelper 口径拍板（persistence 层正式化 or 补 Repository）

### P4 观察项（缓做 / 需 ROI 评估）

- [ ] State V1 → V2 迁移（面大，最后评估）
- [ ] `router` → `Navigation` 现代化（新页面优先，旧页面不动）
- [ ] ChatPage `@ObjectLink` 赋值警告
- [ ] `EdgeTtsTestPage` 是否撤出正式路由
- [ ] 自动化测试基建（当前以编译 + 真机冒烟为主）

## 7. 文档与文件治理记录（2026-09-27 决策）

| 动作 | 对象 | 说明 |
|---|---|---|
| ✅ 新建 | `AGENTS.md` + `docs/handover/`（README / CURRENT / 本文档） | 进版本库（用户决策） |
| ✅ 归档 | `docs/AGENT/`、`docs/HANDOVER.md`、`docs` 杂项、`spec/`、`.trae/specs`、根 `AGENT.md`（模板）、`.trae/documents/重构工作交接.md` | → `docs/handover/archive/`（用户决策：合并后归档） |
| ✅ 删除 | `tools/`（64 文件，card-studio）、`启动制卡软件.bat`、根 `screenshots/`（21 张）、`.tools/uitree`（2 dump） | 用户确认；备份在用户侧 |
| ⏸ 保留 | `APK-reference/`（~100MB 反编译参考）、`.trae/documents/`（19 份功能方案）、`docs/archify/`、`docs/design/`、契约文档与 samples | 待后续需要时再议 |

## 8. 风险清单与"不做"清单

**不做**：① 整体重构；② 提前动 ChatService 流式核心；③ 重建数据库 / 改历史迁移；④ 为分层洁癖给 30+ 薄页面强造 ViewModel；⑤ 重构与修 bug 混在一个提交里。

**风险**：① 无自动化回归，靠编译 + 手动冒烟（P2 前先把冒烟清单跑通一遍做基线）；② `operationId` + 4 布尔互斥的重入风险（抽控制器时保持原语义，不加新锁）；③ 存档类逻辑（归档导入导出）无测试覆盖，改动需真机验证；④ 文档易腐化——按 `AGENTS.md` §10 纪律当场更新。

## 附录 A：方法体量 Top（估算，两文件）

**ChatService.ets**（total 6,770 / ~158 方法）：buildRequestMessages 320 · doStream 240 · editUserMessageAndGenerate 176 · generateAlternativeCandidate 139 · autoContinue 137 · updateRequestPlan 110 · generateImpersonateCandidates 110 · modifyStatusWithPrompt 101 · finalizeAssistantTurn 100 · forkAndStreamFromUser 99 · generateStatusFieldsNow 98 · autoLoadOnDemandMemories 97 · doInitializeSession 94 · regenerateAssistantMessage 94 · regenerateAsBranch 90 · parseImpersonateCandidates 83 · injectOnDemandMemories 83 · continueFromAssistant 81 · narratorMessage 79 · createPresetRequestSnapshot 79

**ChatPage.ets**（total 6,239 / ~181 方法）：build 362 · appearanceSheetContent 360 · personaPickerSheet 207 · inputArea 160 · messageList 159 · memoryModeDialog 144 · topBar 137 · frontendPanel 125 · aboutToAppear 102 · chapterGreetingPickerDialog 97 · sendStopButton 93 · statusFloatingPanel 88 · aiPreviewArea 83 · fontColorPreviewArea 82 · forkModePickerDialog 80 · colorPickerOverlay 77 · userNameOverrideDialog 75 · loadTtsSettings 73 · colorSwatchRow 72 · emptyStateView 71