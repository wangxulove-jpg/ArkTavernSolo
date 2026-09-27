# AGENTS.md — ArkTavernSolo Agent 总指挥

> 任何 Agent / 开发者接手本项目前**必读的唯一入口**。最后更新：2026-09-27。
> 配套：`docs/handover/`（交接文档体系）· `README.md`（面向用户的项目说明）

## 1. 这是什么项目

原生 **HarmonyOS NEXT（ArkTS / ArkUI）** 的 **单人 AI 角色扮演聊天客户端**，复刻 SillyTavern 单人聊天核心（角色卡 V2/V3、AI 对话、世界书、多层记忆、Persona、对话分支、TTS、WebDAV 同步）。

| 项 | 值 |
|---|---|
| 平台 | HarmonyOS NEXT（API 24 / SDK 6.1.1） |
| 语言 / 框架 | ArkTS / ArkUI（State Management **V1**） |
| 存储 | 关系型数据库（RDB，当前 schema 版本 **47**）+ Preferences + Asset KeyStore |
| 与 ArkTavern 关系 | 完整版含群聊/世界/VRM；Solo 是单聊精简版，同设备共存，数据隔离（所有存储键前缀 `arktavern_solo`） |

## 2. 接手流程（新会话按顺序执行）

1. 读本文件（你在这一步）—— 尤其 **§3B 给 AI 的工作约束**
2. 读 `docs/handover/CURRENT.md` —— 当前进度与下一步
3. **按任务类型选读**（避免每次全读）：
   - 改某个功能 → [FEATURE_MAP.md](./docs/handover/FEATURE_MAP.md)（定位，不必检索全仓）
   - 写新组件 / 工具 / 服务 → [INVENTORY.md](./docs/handover/INVENTORY.md)（先查有没有现成的）
   - 重构 / 大改动 / 排障 → [PITFALLS.md](./docs/handover/PITFALLS.md)（§3 分层、§4 验证手法）
4. `git log --oneline -8` 对照进度；`git status` 确认工作区状态
5. 跑一次编译（§5）确认环境可用，再动代码

## 3. 架构与分层（硬约束）

```
pages/ → viewmodels/ → services/ → repositories/ → database/
                          ↓                ↓
                     storage/          network/
components/ 与 models/：无网络、无数据库、无业务副作用
```

- `services/AppServices.ets` 是**唯一组合根**（静态、幂等）；页面**可以**通过 `AppServices.getXxx()` 静态方法取服务（架构允许）
- `ChatService` **不是单例**：每次进入 ChatPage 由 `AppServices.createChatService()` 新建，只被 `ChatViewModel` 独占使用
- `ModelService` 是**所有 AI 请求的唯一出口**（页面/服务不得直接碰 Provider/KeyStore）
- **红线**：pages 不得直接 import 具体 services / repositories / network / database；components 不得 import viewmodels / services / database
- **pages 直连服务：分级口径**（2026-09-27 固化，**具体页面清单见 `CURRENT.md` P3-4，此处不重复**）
  - **T1 允许**：仅 `AppServices.getXxx()`（组合根）、`ThemeManager` / `ThemePalette`（全局主题权威）、`utils/*` 纯工具、以及**纯常量 / 纯函数 / 仅作类型**的服务导入（如 `ChatTextContract` 常量、`ChapterMemoryIndexer` 纯函数、`models/*`、`ChatMemoryMode` / `AiLorebookMode` / `SyncResult` 等类型）
  - **T2 待治理**：直接 import **具体业务服务类**并实例化 / 调用 → **改到哪个页面就顺带补 / 并 VM**，不专门开批次
  - **T3 冻结（勿扩散）**：`ChatPage`、`LorebookPage` 的直连现状；仅在触碰相关功能时顺带上提
  - **新增页面一律走 VM**；不得新增 T2 / T3 同类偏差
- **services → DbHelper：引用白名单口径**（2026-09-27 固化，采"止血"方案）
  - **允许** import `DbHelper` 的仅三类：`repositories/*`（数据访问本职）、`services/AppServices`（组合根）、`*PersistenceService`（跨表事务编排层）
  - **禁止新增**：其余业务服务不得 import `DbHelper`；**新跨表事务放入对应 `*PersistenceService`**（该层用 `dbHelper.runInTransaction`，Repository 方法接收 `store`）
  - **现有偏差（冻结，可择机回收，清单见 `CURRENT.md` P3-4）**：`ChatArchiveImportService` / `ForkChatService` / `sync/*` 三个
- ✅ 组件越层已清零（2026-09-27，P3-1②）：`LorebookPanelBook/Data` 迁至 `models/LorebookPanel.ets`，`ChatStatusWorldPanel` 不再引用 `viewmodels/`
- 组件越层已修复（2026-09-27，P1-5）：`CardFrontendWeb`/`CardFrontendBridge` 依赖 `bridge/CardFrontendBridge.ets` 导出的 `FrontendCardHost` 契约（页面直接传 `host: this.viewModel`）
- 会话列表面板已删除（2026-09-27，P1-4）：原 `components/ChatSessionListPanel.ets` 为不可达死 UI（`ChatViewModel.openSessionList()` 无调用者），连同 ChatViewModel 的会话列表/分组 API 一并移除；**会话切换统一走首页"对话记录"Tab**（`pages/tabs/ChatSessionRootView.ets` + `components/SessionGroupDialogs`）

## 3B. 给 AI 的工作约束（必守 · 2026-09-27 立）

> 目的：把"靠人反复纠正"变成"环境里写死的规则"。规则**只写能改变行为**的条目；细节见 `docs/handover/`。
> 分四组：**设计 / 验证 / 诚实 / 文档**。

### 3B.1 设计（"高内聚低耦合"的可执行版）

1. **复用优先**：写任何新组件 / 工具 / 服务 / 模式前，**先查 [INVENTORY.md](./docs/handover/INVENTORY.md)**；若决定新建，提交说明写一句「**为何不能复用现有 X**」。
2. **不做假想需求**：抽象必须有 **≥2 个真实调用点**；不为"以后可能"加参数层 / 接口层（**高内聚低耦合不是加层的理由**）。
3. **同一份状态只有一个 owner**；跨层用**显式参数 / 回调**传递，不用全局或隐式共享。
4. **依赖方向不可逆**（见 §3 红线）；`components/` 与 `models/` 无副作用。
5. **只在系统边界校验**（用户输入 / 外部 API / DB 读入）；内部调用互相信任，不重复防御。
6. **改动外科化**：最小 diff，不夹带顺手重构、不做未要求的改进；一次只解决一件事。

### 3B.2 验证（没证据不许说"完成"）

7. 声称"完成"前必须给出**证据**：编译输出片段 / 单测计数 / 机械 diff 结论；**没跑过就写"未验证"**。
8. 优先把目标做成**可机械验证**的：搬运 → byte 级 diff；对外 API → 声明面 diff；数据产物 → 全量字符串 diff（手法见 [PITFALLS.md](./docs/handover/PITFALLS.md) §4）。
9. **禁止**在文档 / TODO 里写"真机通过"，除非真机真的跑过。
10. 一次一操作 → 编译 → 提交；失败立即回滚，**不带病继续**。

### 3B.3 诚实（反谄媚）

11. 用户前提有误，**先说错在哪再干活**；不为礼貌而附和。
12. 不确定就标注"**未确认**"；**不得编造**文件路径 / 行号 / 结论 / 验证结果。
13. 文档与代码冲突时**以代码为准**，并当场修正文档。

### 3B.4 文档纪律

14. `AGENTS.md` 只放「**能改变 agent 行为**的规则 + 指针」，细节拆到 `docs/handover/`。不具体 = 无效：`写干净的代码` ✗ / `禁止 console.log，用 utils/Logger` ✓。
15. 具体的文档职责划分、更新时机、"同一事实只允许出现一次"、"不建 changelog" 等，**以 §10 为准**（此处不重复）。

## 4. 编码规则（ArkTS 红线）

- 禁 `any` / `unknown` / `as` 类型断言；禁动态属性访问；禁 `delete`
- 对象字面量需显式类型上下文；深层嵌套对象字面量逐层声明中间变量
- **`@Builder` 方法内禁止 `const` / `let`**
- 不使用 barrel export（无汇总 index.ets），一律相对路径直接导入
- `String.replace` 不支持回调函数（用 `RegExp.exec` 循环）；正则用 `new RegExp()`
- 异步必须配 `.catch()`（未捕获的 Promise 会 Crash）；`aboutToDisappear` 中清理定时器与监听（`display.on` / `window.on` / mediaquery 等）
- 回调中的 `this` 一律用箭头函数
- **宿主契约（结构类型）仅适用于 public 成员**：把 `this` 直接传给接口的场景（如 `FrontendCardHost`）要求相关成员全为 public；成员的 `private` 会使结构赋值失败——此类抽取改用「构造注入依赖 + 调用期快照字段」

## 5. 快速命令速查

**编译验证（唯一标准）** —— 必须用 IDE 内置 SDK 6.1.1：

```powershell
$env:DEVECO_SDK_HOME = "D:\DevEco_studio\DevEco Studio\sdk"
& "D:\DevEco_studio\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

- 通过标准：输出 `hvigor BUILD SUCCESSFUL`（约 35~45 秒）；产物：`entry\build\default\outputs\default\entry-default-signed.hap`
- **同一编译命令最多运行 3 次**；不要 clean build（仅缓存异常时允许）
- `D:\DevEco_studio\Sdk`（旧版 6.0.2）会报 00303312，勿用
- 既有告警（非阻塞，勿当新问题）：`showToast`/`back` deprecated、若干 "Function may throw exceptions"、ChatPage 一处 `@ObjectLink` 赋值警告

**本地单元测试（host 侧回归，可选但建议在搬运类改动后跑一次）**：

```powershell
& "D:\DevEco_studio\DevEco Studio\tools\hvigor\bin\hvigorw.bat" test --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
```

- 逐用例结果落盘：`entry/.test/default/intermediates/test/coverage_data/test_result.txt`（`result=Success/Failure`）；覆盖率 HTML 在同目录 `outputs/test/reports/`
- 覆盖纯函数层（ChatTextContract / PromptSegment 段序 / 世界书激活与粘滞 / 记忆索引 / 状态 schema / 前端契约）；**会话 / Swipe / 分支 / 流式簇不在覆盖内**，只能真机冒烟

**git 纪律**：
- 一次一个操作 → 编译验证 → 提交；失败立即 `git checkout -- <file>` 回滚，不带病继续
- 提交信息风格：`feat/fix/refactor/chore/docs(scope): 中文描述`
- **未经用户确认不要 push**；重构安全基线：tag `refactor-baseline`

## 6. 数据库纪律

- 当前版本 **47**（`database/DatabaseConstants.ets` 的 `DATABASE_VERSION`）
- 迁移**只增不改**：禁止 DROP TABLE / DROP COLUMN；新增列必须新增迁移版本，**逐版连续**，禁止跳版本
- 行映射用 `getColumnIndex >= 0` 安全回退，保证旧 schema 兼容
- `senderType='character'` 的消息必须填 `senderCharacterId`，否则 MessageRepository 抛 `invalid data`
- 已废弃功能的表（如 worlds）仍留在库中，属预期（迁移只增不改），勿依赖

## 7. 关键领域概念速查

**消息三层体系**（改聊天相关代码前必须理解）：

| 层 | 类型 | 值 |
|---|---|---|
| Wire（网络） | `ChatRole` | `system` / `user` / `assistant` |
| DB（数据库） | `MessageSenderType` | `'user'` / `'character'` / `'narrator'` |
| UI（渲染） | `ChatSenderType`（ChatRichText.ets） | 对应渲染类型 |

- Impersonate（代写）= User role + `'character'` senderType；Narrator（旁白）= System role + `'narrator'`；AutoContinue 续写复用最后一条消息
- `ChatGenerationKind` enum 定义在 `models/ChatGenerationContext.ets`（P2-4 起；此前在 ChatService）
- `ChatService.currentChat` 是 private，外部走 `getCurrentChat()`
- `ChatRequest.temperature/topP` 是 number（非 optional）；`ProviderConfig.maxTokens` 与 `EffectiveGenerationSettings.maxOutputTokens` 字段名不同
- 存储键统一 `arktavern_solo` 前缀；不缓存 `$r()` 颜色结果

## 8. UI 一致性规范（新增 / 修改 UI 时必须遵守）

> 来源：《鸿蒙 App 开发指南》（真机验证沉淀），已按本项目现状适配。

- **返回按钮**：统一系统图标（`SymbolGlyph($r('sys.symbol.chevron_left'))` 或 `sys.media`），禁止文字按钮与自绘箭头混用；返回行为走统一分层（浮层 → 历史 → 退出确认）
- **安全区**：全应用统一策略——背景可沉浸（`expandSafeArea`），可交互控件留在安全区内；新页面禁止自行发挥
- **深浅色**：颜色一律 `$r('app.color.*')` + `dark/` 资源覆盖，**零硬编码色值**；不把颜色缓存进变量；弹窗配色跟随主题（禁白底黑字写死）
- **键盘避让**：压缩式（顶栏不动、内容区压缩、输入框贴键盘），严禁系统级 + 组件级双重避让；`keyboardHeightChange` 监听必须在 `aboutToDisappear` 解绑
- **列表**：> 20 条用 `LazyForEach`；keyGenerator 必须用业务唯一 id（**严禁 index**）；复用组件在 `aboutToReuse` 重置视觉状态
- **图片**：同路径覆盖后不刷新时加 `?t=timestamp` 破缓存；网络图配 `alt` 占位 + `onError`
- **横竖屏**：尊重系统旋转锁（`module.json5` 保持 `auto_rotation_restricted`）；旋转/尺寸变化后重算悬浮控件钳制位置（600ms 防抖）
- **交互一致性**：Toast / Loading / 空态 / 确认弹窗使用统一封装，禁止各页面自造

## 9. 功能 → 文件定位

> **权威定位表在 [FEATURE_MAP.md](./docs/handover/FEATURE_MAP.md)** —— 功能 → 文件 → 约束，含分层下钻路径、数据模型位置、以及"新增 X 该仿谁"。
> **改单个功能时先查它，不要检索全仓。** 本文件不再重复维护定位表（同一事实只允许出现一次，见 §10）。
> 历史版本（已过期，勿作依据）：`docs/handover/archive/agent/04_FEATURE_LOCATOR.md`。

## 10. 文档体系与维护纪律

```
AGENTS.md                            ← 本文件（总指挥 + 给 AI 的约束，唯一入口）
docs/handover/
├── README.md                        # 交接文档导航（含各文档职责与更新时机）
├── CURRENT.md                       # ① 当前状态与下一步 + 里程碑日志(§5) + 冒烟清单(§4b)
├── FEATURE_MAP.md                   # ② 功能 → 文件 → 约束（权威定位表）
├── INVENTORY.md                     # ③ 可复用资产清单（写新代码前必查）
├── PITFALLS.md                      # ④ 踩坑与硬约束累积（编号一条一行）
├── 2026-09-27-audit-and-roadmap.md  # 全项目审计报告 + 重构路线图（P1~P4）
└── archive/                         # 过期文档归档（勿作现状依据）
```

**每份文档只有一个职责**（见上注释）；**同一事实只允许出现一次**——定位→FEATURE_MAP；资产→INVENTORY；坑→PITFALLS；状态→CURRENT。

**纪律（必须遵守）**：

1. 每解决一个问题 / 踩一个坑 / 做一次决策，**当场**写进文档（不许"以后补"）；新坑入 `PITFALLS.md`，编号只增不复用
2. git 提交跟随里程碑：每完成一个可验证的操作就提交（一次一操作一提交）
3. 新增功能方法论：定契约（数据结构 / spec）→ 实现 → 编译 + 真机验证 → 收尾三步
4. 收尾三步：更新 `CURRENT.md` → 清理临时产物 → git 提交
5. 接手先读文档，禁止凭直觉直接改代码
6. 发现文档过时：**以代码为准**，当场改文档
7. **不建 changelog**：变更历史以 git 为准（`git log --grep="P3-2"`）；里程碑记 `CURRENT.md §5`
8. 代码改动若影响 定位表 / 资产清单 / 踩坑，**同一次提交**内更新对应文档

## 11. 当前状态与下一步

> **权威状态以 [CURRENT.md](./docs/handover/CURRENT.md) 为准**（当前进度、待办、里程碑日志 §5、统一冒烟清单 §4b）。此处只保留"接手即需知道"的骨架。

- **基线**：tag `refactor-baseline`（`8dbd9df`，2026-09-27）；此后 P1 / P2 / P3 全部完成并逐接缝提交（**未 push**）
- **已完成批次**（逐接缝清单、commit 锚点、冒烟项见 CURRENT.md §2 / §2b / §2c / §5）：
  1. **P1**：死代码清理 · ChatService 重复逻辑消除 · ChatPage 组件抽取 5 个 · 会话列表去重（删不可达死 UI ≈ -1069 行）· 组件越层修复 · 不可变性
  2. **P2**：ChatService 瘦身 **6,735 → 2,413 行（-64%）**（14 个接缝，搬运块全部 byte 级一致，公开 API 面 89 项零差异）
  3. **P3**：ChatViewModel **1,698 → 1,479** / MemoryService **1,953 → 1,451** / DatabaseSchema **2,879 → 1,443**（DatabaseSchema 逐版 DDL 逐字节一致）；**P3-4 治理口径已固化进 §3**（口径 C：pages 分级 T1/T2/T3 + `DbHelper` 白名单；A 留 P4）
- **P2 装配范式**（抽离逻辑的默认做法，后续接缝直接复用）：服务依赖**构造期注入**（字段同名）；跨类可变状态与宿主私有能力经 **`XxxHost` 函数属性**回调（读 getter / 写 setter，含 `doStream` 委托）；类内**同名 getter/setter/方法转发** ⇒ 搬运代码**零改写**。参考实现：`services/ChatRequestBuilder.ets` / `ChatOneShotGenerator.ets` / `ChatStatusService.ets` / `ChatSwipeController.ets` / `ConversationBranchService.ets` / `viewmodels/LorebookPanelVM.ets`
- **剩余高风险区**（改前必读）：① `ChatService` 流式核心簇（≈900 行：`doStream` / `finalizeAssistantTurn` / 句柄与定时器 / delta 持久化）——**不授权勿动**；② `ChatPage`（4,884 行、80+ @State）；③ `ChatSessionRootView`（2,786 行，拖拽重排 / 归档导入导出，无测试覆盖）；④ `ChatService` 构造装配（≈450 行宿主装配）；⑤ 数据库迁移链（只增不改，任何 DDL 差异按 bug 处理）
- **下一步候选**：① **口径 C 已固化进 §3**（无需再做）；剩余治理 = **A** 抽 `TransactionCoordinator` 收口 5 处 `DbHelper` 业务服务偏差（P4 候选）；② T2 页面逐个补 / 并 VM（**改到哪页就顺带做**，清单见 `CURRENT.md` P3-4）；③ P4 观察项（`State V1→V2` / `router→Navigation` / `@ObjectLink` 告警 / `EdgeTtsTestPage` 路由 / 自动化测试基建）
- **验证状态**：本轮编译 BUILD SUCCESSFUL + 本地单测 `hvigorw test` **96/96**（16 类）；机械校验手法与结论见 CURRENT.md §4 与 [PITFALLS.md](./docs/handover/PITFALLS.md) §4；**真机冒烟统一在 P3 末期一次性进行**（清单 CURRENT.md §4b）
