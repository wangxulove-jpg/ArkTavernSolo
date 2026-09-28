# CURRENT — 当前状态与下一步

> 最后更新：2026-09-28 · **每次会话结束前必须更新本文件**（纪律见 `AGENTS.md` §10）

## 1. 现在在哪

- **基线**：tag `refactor-baseline` @ `8dbd9df`（2026-09-27 建立，工作区干净）
- **里程碑 tag**（2026-09-28 补齐，全部为**注释 tag**，只增不改；锚点规则：指向该批次**最后一次代码提交**，故含批次末尾的校验修复）：
  | tag | 指向 | 含义 |
  |---|---|---|
  | `v1.0.0` | `af8b29b` | 旧版本线（轻量 tag，非本轮建立） |
  | `refactor-baseline` | `8dbd9df` | 重构安全基线（轻量 tag） |
  | `p1-complete` | `7983170` | P1 批次收官：组件抽取 + 死代码清理，ChatPage 4,898 行 |
  | `p2-complete` | `36d809c` | P2 收官：ChatService 6,735 → 2,413 行（含 API 面校验后的 `async` 修复） |
  | `p3-complete` | `92e13c4` | P3 收官：ChatViewModel 1,479 / MemoryService 1,451 / DatabaseSchema 1,443 行 |
  | `smoke-p2p3-passed` | `30bba43` | P2+P3 统一实机冒烟通过（真机 MIS-AL00 / API 24） |
  > tag 已于 2026-09-28 推送至 `origin`；**不要 rebase/squash 历史**——`docs/handover/` 里的短 hash 回滚锚点会全部失效
- **本日完成**：
  1. 全项目只读审计（286 文件 / 112,801 行；结论：分层主干成立，痛点集中于巨型文件与重复实现）→ [审计报告](./2026-09-27-audit-and-roadmap.md)
  2. 交接文档体系重建（根 `AGENTS.md` + `docs/handover/`）
  3. 清理：删除 `tools/`（card-studio）、`启动制卡软件.bat`、根 `screenshots/`、`.tools/uitree`；旧文档归档至 `docs/handover/archive/`
- **本次未修改任何 .ets 代码**（审计为只读）

## 2. 下一步（P2 批次：ChatService 瘦身）

> 目标：ChatService 从 6,735 行降到千行级门面（流式核心保持不动）；接缝见审计报告 §4.1
> 纪律：一次一操作 → 编译验证 → 提交；每步记录冒烟点

- [x] **P2-1a 契约常量与文本纯函数下沉**（commit `64b0c4e`）：新增 `services/ChatTextContract.ets`（Preferences key / 世界书默认值 / 前端交互与状态文本纯函数，300 行），ChatService **-285 行**；5 处外部导入（2 页面、LorebookViewModel、单测）改直接引用，不再经 ChatService 转出（同时解决审计 §3.2"常量经 ChatService 导入"问题）
- [x] **P2-1b 请求计划抽离**（commit `702d3db`）：新增 `services/ChatRequestPlan.ets`（`planRequest` + makeBudget/logNormalEstimate，依赖经参数传入），`updateRequestPlan` 改薄包装回写三个字段；五分支（无统计/统计失败/裁剪失败/裁剪成功/未裁剪）语义逐一对齐
- [x] **P2-1c `ChatRequestBuilder` 抽取**（commit `8e0ad06`）：`buildRequestMessages` + `autoLoadOnDemandMemories`/`injectOnDemandMemories`/`injectStickyLorebookEntries`/`applyAnchoredInserts`/`appendStickyReminder` 共 6 方法 **615 行逐字搬出**（已 byte 级比对一致），ChatService 留薄包装（3 个调用点不变）
  - 装配方式（已落地，供后续接缝复用）：服务依赖（10 个）构造期注入；可变会话状态与 5 个宿主私有能力经 `ChatRequestHost` **函数属性**回调读取（ArkTS 对象字面量要求属性而非方法签名），类内以**同名 getter/方法转发**→搬运代码零改写、读取即最新
  - 记录：仅日志 tag 由 `ChatService` 变为 `ChatRequestBuilder`；`OnDemandInsert` 接口随迁；`ChatService` **6,735 → 5,781 行**（P2-1 合计 -954）
- [x] **P2-2 `ChatOneShotGenerator`**（低，commit `bac896d` / `ad5d0aa`）：
  1. `bac896d` 前置：`ChatState` + `ChatServiceCallbacks` 迁入新增 `models/ChatServiceContract.ets`（逐字搬出；全仓仅 2 处引用改路径：ChatService / ChatViewModel L19）
  2. `ad5d0aa` 主步：新增 `services/ChatOneShotGenerator.ets`（724 行）——`extractUserFromCharacter` / `summarizeUserPersona` / `generateImpersonateCandidates` / `parseImpersonateCandidates` / `autoContinue` / `parseAutoContinueTurn` 共 **513 行逐字搬出**（byte 级比对一致），`AutoContinueTurn` 随迁；ChatService 留 4 个公开薄包装（两个 parser 私有，不保留包装）
  - 装配：3 服务构造注入；宿主 `ChatOneShotHost` 21 个回调（**读 getter + 写 setter**：`messages` / `lastCallbacks` / `generationOperationId` / `currentSequenceNumber` / `currentAssistantId` 的写侧经函数属性回写宿主），类内同名 getter/setter/方法转发 → 搬运代码零改写；**装配范式自此扩展出 setter 写入面**（后续接缝沿用）
  - 偏差记录：仅日志 tag 由 `ChatService` 变为 `ChatOneShotGenerator`；抛错文案 `'ChatService disposed'` 原样保留
  - **ChatService 5,781 → 5,273 行**（P2 累计 6,735 → 5,273，-1,462）
- [x] **P2-3 `ChatStatusService`**（中，commit `56e559f`）：新增 `services/ChatStatusService.ets`（768 行）——角色状态簇整块搬出：
  1. 5 个状态字段随迁（**自带状态**：currentStatusState / statusSchema / statusFieldGenerationRequested / statusGenerationInProgress / statusInstructionEnabled）
  2. 6 个模块级纯函数随迁（findStatusEntryByName / parseStatusJsonWhole / tryParseJson / collectScalarEntries / statusScalarToString / stripFencesForStatus）
  3. 三个方法区共 **597 行逐字搬出**（byte 级比对一致）：状态读写/归一/合并、Schema 同步、持久化与通知、一次性 AI 请求（生成字段 / 按指令修改）、提示词段文本
  - 装配：3 服务构造注入；宿主 `ChatStatusHost` 8 个回调（含 `setCurrentChat` 回写宿主缓存）；类内同名 getter/setter/方法转发 → 搬运代码零改写；ChatService 留 14 个薄包装（8 个公开 API + 6 个内部私有），调用点不变
  - 偏差记录：6 个原 private 方法因跨类调用改为 public（方法体未动）；`finalizeAssistantTurn` 中 flag 复位改走 `resetFieldGenerationRequest()`（1 行调用点）；日志 tag 改为 `ChatStatusService`
  - **ChatService 5,273 → 4,740 行**（P2 累计 6,735 → 4,740，-1,995）
- [x] **P2-4 `ChatSwipeController`**（中高，commit `4bd6998` / `9c21aa1` / `5ac6bb8`）：
  1. `9c21aa1` 前置：`ChatGenerationKind` + `ActiveGenerationContext` 迁入新增 `models/ChatGenerationContext.ets`（逐字搬出；`interface` 改为 `export interface`，全仓仅 ChatService 引用）
  2. `4bd6998`（P2-4a）：新增 `services/ChatSwipeController.ets` —— 浏览/切换族 **151 行逐字搬出**（getSwipeSummaries / getSwipeSummary / canOperateSwipe / doActivateCandidate / activatePrevious / activateNext / activateCandidateIndex / getSummaryForMessage）
  3. `5ac6bb8`（P2-4b-2）：生成族 **176 行逐字搬出**（generateAlternativeCandidate + replaceAssistantMessageInFullHistory）
  - 装配：Swipe 会话状态**仍由 ChatService 持有**（与流式核心强耦合，不随迁）；宿主 `ChatSwipeHost` 29 个回调（读 getter + 写 setter + `doStream` 委托，流式核心未动）；类内同名 getter/setter/方法转发 → 搬运代码零改写；ChatService 留 7 个薄包装（6 公开 + 1 私有），调用点不变
  - 偏差记录：`getSummaryForMessage` 因跨类调用改为 public（方法体未动）；日志 tag 改为 `ChatSwipeController`；`MAX_SWIPE_CANDIDATES` / `MessageSwipeState` 导入随迁
  - **ChatService 4,740 → 4,484 行**（P2 累计 6,735 → 4,484，-2,251）
- [x] **P2-5 `ConversationBranchService` 门面（查询与判定）**（中，commit `d798259`）：新增 `services/ConversationBranchService.ets`（388 行）——Branch 簇查询/判定 **252 行逐字搬出**（三区：Q1 106 行 getBranches/getActiveBranchId/getRecordCounts/isBranchOperating/canContinueFromAssistant/refreshBranchState；Q2 99 行 canGenerateFromUserMessage/canRegenerateAssistantMessage；Q3 47 行 canEditUserMessage）
  - **暂留 ChatService（P3 候选）**：fork+stream 族（continueFromAssistant / regenerateFromAssistant / continueFromUserMessage / editUserMessageAndGenerate / switchBranch / reloadAfterExternalBranchChange），与流式核心共享可变状态
  - 装配：Branch 状态仍由 ChatService 持有；宿主 `ConversationBranchHost` 13 个回调（含 `findMessageById` 辅助）；类内同名 getter/setter/方法转发 → 搬运代码零改写；9 个公开薄包装，调用点不变；**无需可见性调整**
  - 偏差记录：仅日志 tag 改为 `ConversationBranchService`
  - **ChatService 4,484 → 4,305 行**
- [x] **P2-6 `ChatMessageService`**（commit `01361d0`）：消息级操作（deleteMessage / editNarratorMessage / editAssistantMessage）**113 行逐字搬出**；宿主 `ChatMessageHost` 10 个回调；ChatService 留 3 个公开薄包装；**4,305 → 4,235 行**
- [x] **P2-7 `ChatContextMaintenanceService`**（commit `b4fc54f`）：上下文维护簇（手动/自动记忆总结、记忆软失效、世界书 Pin/Sticky 激活刷新、自动总结开关与 `memoryAutoSummaryEnabled` 状态随迁、`notifyMemoryChanged`）**四区 291 行逐字搬出**；6 服务注入 + 宿主 5 个读取回调；ChatService 留 4 公开 + 3 私有薄包装（3 处可见性调整）；**4,235 → 3,997 行**
- [x] **P2-8 `ConversationBranchService` 生成族补全**：
  1. `bbbfcda`（P2-8a）：switchBranch + reloadAfterExternalBranchChange **103 行逐字搬出**（宿主扩 8 项）
  2. `e272d9b`（P2-8b）：branch 生成族七碎片 **676 行逐字搬出**（regenerateLastResponse / regenerateAsBranch / forkAndStreamFromUser / continueFromAssistant / regenerateAssistantMessage / generateFromUserMessage / editUserMessageAndGenerate）；宿主扩 18 项（含 `doStream`、`canRegenerate`、`getSummaryForMessage` 经 Swipe 控制器桥接）；**3,997 → 3,315 行**
- [x] **P2-9 `ChatSessionService` 会话生命周期**（审计 SessionStore 接缝，3 个提交）：
  1. `cc32bfc`（P2-9a）：工具/查询/偏好族 **6 碎片 144 行逐字搬出**（buildGreetingPool / initializeGreetingSwipeCandidates / buildChapterTitlePreview / listSessions / loadLorebookPrefs / reloadSwipeStateAfterNewSession）
  2. `1f09346`（P2-9b）：会话初始化族 **四块 214 行逐字搬出**（initContext / initializeSession / doInitializeSession / createNewSession）
  3. `891de45`（P2-9c）：会话操作族 **五块 248 行逐字搬出**（startNewSession / switchSession / deleteSession / switchToSessionInternal / createChapter），并清理 4 个死包装（createNewSession / initializeGreetingSwipeCandidates / buildChapterTitlePreview / reloadSwipeStateAfterNewSession）
  - 装配：3 服务构造注入（persistenceService / swipePersistenceService / appPreferences，与 ChatService 字段同名）；宿主 `ChatSessionHost` 共 38 项回调（读 getter + 写 setter + 委托：初始化四态、状态同步、偏好加载、flush/emit/setState、互斥标志；worldGroup 走 AppServices 静态调用保持原样）；类内同名 getter/setter/方法转发 → 搬运代码零改写
  - 偏差记录：5 处 private → 默认可见（跨类调用，方法体未动）；`dispose` **有意留在 ChatService**（触及流式核心 currentHandle/定时器/回调面，性价比低）；日志 tag 改为 `ChatSessionService`
  - **ChatService 3,315 → 2,780 行**
- [x] **P2-10 `ChatMessageSender`**（commit `fa44f58`）：消息发起入口 **四块 231 行逐字搬出**（sendMessage / narratorMessage / narratorMessageOnly / clearConversation）；宿主 `ChatSendHost` 22 项（含 `doStream` 委托，流式核心未动）；`stopGeneration` 属流式核心取消路径（currentHandle/定时器）**有意留 ChatService**；**2,780 → 2,618 行**
- [x] **P2-11 `ChatUserIdentityService`**（commit `f0ee661`）：用户称呼与 Persona **124 行逐字搬出**（resolveUserName / updateCurrentChatUserNameOverride / updateCurrentChatPersonaId / updateCurrentChatUserPersonaSummary / getCharacterDefaultPersonaId / resolveEffectivePersona）；`DEFAULT_USER_NAME` 常量随迁；未用导入清理（`GLOBAL_USER_NAME_KEY` / `AppServices` / `WorldGroupService` / `WorldGroup`）；**2,618 → 2,532 行**
- [x] **P2-12 Preset 请求快照迁入 `ChatRequestBuilder`**（commit `1ab7a8c`）：`createPresetRequestSnapshot` **77 行逐字搬出**；`ChatRequestBuilderDeps` 扩 2 项（`modelService` 保持非空类型、`promptPresetService`）；ChatService 留私有薄包装（oneShot 宿主与 doStream 调用点不变）；偏差记录：编译修正 1 处（初版误标 `modelService` 可空，已对齐宿主非空语义）；**2,532 → 2,457 行**
- [x] **P2-13 消息记忆标记迁入 `ChatMessageService`**（commit `9f13ce4`）：`markMessageIncludeInMemory` + `findMessageIndexById` **31 行逐字搬出**；`findMessageIndexById` 由宿主转发改为类内实现（删除宿主项与转发器，3 个既有调用点不受影响）；**2,457 → 2,426 行**
- [x] **P2-14 `reloadCurrentSession` 迁入 `ChatSessionService`**（commit `29f8f45`）：**15 行逐字搬出**；Swipe/Branch 两处宿主箭头改指 `sessionService`；**2,426 → 2,413 行**
- **P2 扩展进展（P2-6..P2-14，服务于审计"千行级门面"总目标）**：ChatService **4,305 → 2,413 行**；**累计 6,735 → 2,413 行（-4,322，-64%）**；`services/` 模块 12 个（`ChatRequestBuilder` / `ChatOneShotGenerator` / `ChatStatusService` / `ChatSwipeController` / `ConversationBranchService` / `ChatMessageService` / `ChatContextMaintenanceService` / `ChatSessionService` / `ChatMessageSender` / `ChatUserIdentityService` + `ChatTextContract` / `ChatRequestPlan`）+ `models/` 2 个（`ChatServiceContract` / `ChatGenerationContext`）
  - **停止点（本次决策，主动放弃剩余 ≈77 行）**：剩余内容中 `constructor`（≈450 行宿主装配，组合根本体）、公开薄包装（≈200 行，对外 API 面）、流式核心簇（≈900 行：`doStream` 214 / `finalizeAssistantTurn` 100 / delta 持久化族 / 句柄与定时器 / `isCurrentGeneration` / `updateRequestPlan` + 预算缓存）、核心内联辅助（`findMessageById` / `updateLastAssistantMessageId` / `updateSwipeSummaryGeneratingFlag`——均被 doStream/finalize 直接调用，不可搬）→ **现实下限 ≈2,350~2,400 行**；仅剩可搬的 `updateRequestPlan` + 估算查询（≈77 行）因缓存字段被核心读写、搬出需回环回调，ROI 为负，**主动放弃**
  - **千行级须突破审计 §8"流式核心不动"约束（需用户显式授权）**；若授权，建议方向：delta 持久化/收尾族（appendDelta / finalizeAssistant / markAssistant / schedulePersistenceFlush / flushPersistence* / persistFinalAssistant / persistWithRetry ≈300 行）→ `GenerationPersistence`；句柄与定时器（currentHandle / startStartTimer / clearStartTimer ≈80 行）→ `GenerationRuntime`；`updateRequestPlan` + 估算缓存（≈77 行）→ `BudgetPlanner`
- [ ] 「聊天主路径冒烟清单」：发送/流式/停止 → 重生成 → 分支切换 → Swipe → 旁白 → 代写 → 记忆生成/查看 → 世界书注入 → 会话增删切换 → 归档导出导入 → 深浅色

## 2b. 已完成（P1 批次，全部收官）

> 完整路线图见 [审计报告 §6](./2026-09-27-audit-and-roadmap.md)
> 纪律：一次一操作 → 编译验证（最多 3 次）→ 提交；任一步失败立即回滚

- [x] **P1-1 死代码清理**（2026-09-27 完成）：删除 `findLastAssistantIndex`（ChatService）；删除 `getEffectiveMemory` / `getInjectionContext` 及 `MemoryInjectionContext` 类型（MemoryService）；`trySummarize` 复核为 rolling 回退路径（被 `tryGenerateMultiLayerMemory` 调用）保留；关联注释 2 处同步修正；编译 BUILD SUCCESSFUL
- [x] **P1-2 ChatService 重复逻辑消除**（2026-09-27 完成）：Swipe 三方法 → `doActivateCandidate`；失败收尾 4 处 → `persistFinalAndCleanup`；锚点插入两处 → `applyAnchoredInserts`；状态一次性请求两处 → `runStatusOneShotStream`；每步编译通过
- [x] **P1-3 ChatPage 组件抽取**（2026-09-27 完成，逐个纯搬运不改行为）：`ChatForkPicker` / `ChatMessageList` / `ChatInputArea` / `ChatAppearancePanel`（appearanceSheetContent + colorSwatchRow + fontColorPreviewArea + 7 个私有辅助方法，683 行搬出；8 个语义色经 @Prop、色盘请求经 `ColorPickerRequest` 上抛，全屏色盘覆盖层留在页面）/ `ChatStatusWorldPanel`（statusWorldSheetContent + 世界书/AI 预览族 10 个 @Builder，465 行搬出；AI 区/输入/面板可见性经 @Link，AI 模式切换与条目启停回调上抛，展开态降为组件内 @State）。**ChatPage 5949 → 4898 行（-1051）**；组件均不持有 VM/服务（`ChatStatusWorldPanel` 仅类型引用 `LorebookPanelBook/Data` 自 ChatViewModel）
- [x] **P1-5 组件越层修复**（2026-09-27 完成，两个组件，各一次编译 + 提交）：
  1. `CardFrontendWeb` + `CardFrontendBridge` → bridge 层新增 **`FrontendCardHost` 契约**（`CardFrontendBridge.ets` 内导出）；组件/Bridge 不再 import viewmodels，ChatViewModel 结构上满足契约（无需适配器），页面直接传 `host: this.viewModel`（commit `d44797b`）
  2. `ChatSessionListPanel` 去掉 `ChatViewModel` / `AppServices` 依赖 → 7 个 @Prop 数据 + 5 个查询回调 + 11 个动作/持久化回调（commit `726efec`）；**该组件随后核实为不可达死 UI 并被整体删除，本条改造随之作废**（见 P1-4 ③）
  - 组件层现状：仅剩 `ChatStatusWorldPanel` 对 `LorebookPanelBook/Data` 的**类型引用**（不持有 VM 实例，暂留）；旧 `@ObjectLink` 赋值告警随 P1-5 消失
- [x] **P1-4 会话列表去重**（2026-09-27 完成，以"删除死 UI"收官）：
  - [x] **① 共享纯函数与常量**（commit `8ff588e`）：新增 `utils/SessionListCollapseState`（key + parse/serialize + 折叠判定/切换纯函数），原先三处重复实现收口
  - [x] **② 共享分组弹窗**（commit `958b43b` / `a1d2a5d`）：新增 `components/SessionGroupDialogs`（四个分组弹窗），RootView 迁移后 **-380 行**（2815→2435）
  - [x] **③ 覆盖层面板删除**（commit `020dd05` / `b8500bb` / `7983170`）：核实 `ChatSessionListPanel` 为**不可达死 UI**（`showSessionList` 仅由无调用者的 `openSessionList()` 置真；顶栏无汉堡、更多菜单无入口，旧注释与实现脱节）→ 删除面板整文件 + ChatPage 引用/折叠持久化 + ChatViewModel 的 T-4.5 会话列表与分组 API（含 `refreshSessions`/`createNewSession`/删除确认三方法/`canOperateSessions` 等），**合计 ≈ -1069 行**；会话切换统一走首页"对话记录"Tab
  - 说明：原计划的"数据换源 + overlay 精简 + 单组件（mode 参数）"因面板不可达而**不再执行**；`SessionGroupDialogs` / `SessionListCollapseState` 保留（Tab 使用），将来若恢复"聊天页内切会话"即以此二者为基座
- [x] **P1-6 不可变性修复**（2026-09-27 完成）：`deleteMessage` / `editNarratorMessage` / `editAssistantMessage` 改为新数组整体替换；复核后**未补 `emitMessages`**——刷新契约由 ChatViewModel 承担（`[...getMessages()]` + `onMessagesUpdate`），补发会改变通知行为、超范围

## 2c. P3 批次（进行中）

> 目标：ChatViewModel / MemoryService / DatabaseSchema 三处中风险拆分 + 两项治理口径（P3-4 只出方案）
> 纪律：只读测绘 → 方案入档 → 逐接缝「搬运 + 编译 + 提交」；真机冒烟统一末期一次性进行
> 约束：**ChatService 不再动**（P2 已收官，2,413 行）；`ChatPage`（4,884 行）为约束方，行为不动
> 开工基线（2026-09-27）：`git status` 干净；编译 BUILD SUCCESSFUL；单测 **96/96**（0 失败）

### P3-1 ChatViewModel 拆分（起点 1,698 行）

**只读测绘**：L1-56 import；L61-73 世界书面板类型（导出）；L75-140 状态字段；L180-190 构造（4 依赖：chatService / modelService / characterService / promptPresetService）；方法约 110 个

- [x] **① `ChatErrorMapper`（纯函数收口）** ✅：`toUserError`（40 行）+ `toSessionOpError`（16 行）均为纯函数，调用点仅本文件（`toUserError` × 17、`toSessionOpError` × 2），**0 外部引用** → 新增 `viewmodels/ChatErrorMapper.ets`（两函数逐字搬出，函数名不变）；ChatViewModel 删除两私有方法、19 处调用点改直连（`this.x(` → `x(`）；映射分支零改动
  - 校验：搬运体**逐行等价（归一空白后 DIFF=0）**；公开 API 面 **131 → 131，零差异**；编译 BUILD SUCCESSFUL；**ChatViewModel 1,698 → 1,660 行**（-38）
- [x] **② `LorebookPanelVM`（世界书面板逻辑抽离）** ✅：新增 `viewmodels/LorebookPanelVM.ets`，6 方法搬出（`loadLorebookPanelData` 21 行 / `buildPanelBook` 15 / `aiProposeWorldbookChanges` 27 / `applyLorebookChangeSet` 72 / `toggleLorebookEntryEnabled` 17 / `getAiLorebookService` 9）+ `aiLorebookService` 字段随迁
  - 类型 `LorebookPanelBook` / `LorebookPanelData` 迁入 **新增 `models/LorebookPanel.ets`**（ChatViewModel / ChatPage / ChatStatusWorldPanel 三处引用改路径；**消除 `ChatStatusWorldPanel` 对 viewmodels 的类型引用偏差**——组件层现无任何 viewmodels 引用）
  - 装配：宿主契约 `LorebookPanelHost`（函数属性 `isDisposed` / `getCharacter` / `getRecentMessages` / `setPanelData`）构造期箭头填充；服务取用沿用 `AppServices.getXxx()` 静态（零改写）
  - **保留 `lorebookPanelData` 字段**（ArkUI 绑定，写入经 `setPanelData` 回调）+ 4 个公开薄包装 → 公开 API 面零差异；`refreshLorebookPinNow` / `aiModifyStatus` 非面板逻辑，留原处
  - 校验：搬运体逐行等价（**唯一差异 = 9 处宿主间接行**：disposed ×4、getCharacter ×2、getRecentMessages ×1、setPanelData ×2）；公开 API 面 **131 → 131 零差异**；编译 BUILD SUCCESSFUL；**ChatViewModel 1,660 → 1,479 行**（P3-1 累计 1,698 → 1,479，-219）
- [x] **③ 会话分组桥：已核实无重复，无需动作** ✅ —— P1-4 ③ 已随死 UI 删除 ChatViewModel 的世界分组 API；全仓 `getWorldName/getChapterLabel/createWorldGroup/renameWorldGroup/deleteWorldGroup/moveChatToWorld` 现仅存于 `ChatSessionListViewModel`（+ `ChatSessionRootView` 调用），ChatViewModel **0 命中**（0 调用证据充分，唯一实现保留）
- **P3-1 收官**：ChatViewModel **1,698 → 1,479 行（-219，-12.9%）**；新增 `viewmodels/ChatErrorMapper.ets` + `viewmodels/LorebookPanelVM.ets` + `models/LorebookPanel.ets`；两接缝公开 API 面均 131 → 131 零差异；附加收益：组件层 `ChatStatusWorldPanel` 的 viewmodels 类型引用偏差已消除
- **机械校验**：公开 API 面 diff（抽取全部非 private 类成员声明行，`Compare-Object` HEAD 前后）→ 两接缝均 **零差异**（含 `async` 修饰符）

### P3-2 MemoryService 拆分（起点 1,953 行）

**只读测绘**：L67-148 类型/常量（导出）；L150-185 字段 + 构造函数（8 依赖，后 3 个可空）；职责簇 = 加载 / 触发检查 / rolling 旧 API / v12 多层生成 / v46 会话记忆 / v44 世界级 CRUD + 关键词召回 / 过期标记 / 手动操作；`formatMessages` 被构建器与 `generateSessionMemory` 双处使用

- [x] **① `MemoryPromptBuilder`（纯 prompt 文本构建）** ✅：新增 `services/MemoryPromptBuilder.ets`，6 方法**逐字搬出**（`buildSummaryPrompt` 41 行 / `buildSessionPrompt` 53 / `buildChapterPrompt` 52 / `buildCorePrompt` 51 / `buildJailbreakInstruction` 10 / `formatMessages` 21）；构造期注入 `summaryPoints` + `chapterConfig`（字段与 MemoryService 同名 → 搬运体**逐行等价 DIFF=0**）
  - 5 处调用点改走 `this.promptBuilder.xxx(`；6 个原 private 因跨类调用改 public；`formatMessages` 被 `generateSessionMemory` 直用（L1279）保持可达
  - **教训（ArkTS 红线）**：ArkTS **禁止结构类型**（`arkts-no-structural-typing`）—— 首次尝试用「局部窄接口 `ChapterPromptConfig` 接收 `ChapterTriggerConfig`」编译失败 → 改为把 `ChapterTriggerConfig` + `DEFAULT_CHAPTER_TRIGGER` 下沉 `models/ChatMemory.ets`（与既有 `MemoryTriggerConfig` 同域），`AppServices` 改从 models 导入；**接口参数必须精确类型匹配，不可依赖结构兼容**
  - 校验：搬运体逐行等价（**6/6 DIFF=0**）；MemoryService 公开 API 面 **63 → 63 零差异**；编译 BUILD SUCCESSFUL；单测 **96/96**；**MemoryService 1,953 → 1,664 行**（-289）；`ChatMemory` 类型下沉零行为影响
- [x] **② `WorldMemoryStore`（v44 世界级手工记忆与关键词召回）** ✅：新增 `services/WorldMemoryStore.ets`，8 方法**逐字搬出**（`addWorldMemory` 23 行 / `updateWorldMemory` 3 / `removeWorldMemory` 3 / `listWorldMemories` 3 / `retrieveKeywordMemories` 33 / `parseMemoryKeywords` 21 / `matchMemoryKeywords` 18 / `isAsciiOnly` 8）
  - 依赖 `MemoryPersistenceService` 构造期注入（字段同名 → **8/8 DIFF=0**）；无可变状态，无需宿主回调；5 个公开方法保留薄包装 → 公开 API 面零差异
  - **边界决策**：`listWorldSessions`（会话记忆去重列表）依赖加载簇的 `dedupeWorldSessionMemories`（该私有方法被 `resolveWorldSessionMemories` 共用），**保留在 MemoryService**，避免跨簇依赖
  - 校验：搬运体逐行等价（**8/8 DIFF=0**）；MemoryService 真实类成员 API 面 **49 → 49 零差异**（注：此前口径 63 含 14 行顶层接口/常量的缩进行，属误计，已澄清）；编译 BUILD SUCCESSFUL；**MemoryService 1,664 → 1,580 行**（P3-2 累计 1,953 → 1,580，-373）
- [x] **③ `MemoryTriggerPolicy`（触发检查 + 归档边界）** ✅：新增 `services/MemoryTriggerPolicy.ets`，3 方法**逐字搬出**（`shouldTriggerSummary` 31 行 / `shouldGenerateChapter` 33 / `resolveArchivedPosition` 41）+ `ArchivedPosition` 类型随迁
  - 依赖 `memoryPersistence` + `triggerConfig` + `chapterConfig` 构造期注入（字段同名）；`resolveWorldIdByChat` 属宿主私有能力，经 `MemoryTriggerHost` **函数属性回调**（P2 范式）
  - **边界决策**：`resolveArchivedPosition` 同时被**保留**的 `doGenerateChapter` 使用 → 由策略类持有并公开，MemoryService 调用点改 `this.triggerPolicy.resolveArchivedPosition(...)`
  - 校验：搬运体逐行等价（`shouldTriggerSummary`/`shouldGenerateChapter` **DIFF=0**；`resolveArchivedPosition` 唯一差异 = 1 处宿主间接行 + 日志 tag）；类成员 API 面 **49 → 49 零差异**；编译 BUILD SUCCESSFUL；**MemoryService 1,580 → 1,481 行**
- [x] **旧兼容 API 死代码核实** ✅（全仓 0 调用证据充分，**删除 3 个**）：`getPersistence`（注释称"供 ChatService 事务内调用"，实际 0 引用）/ `invalidateFromPosition`（"硬删除,旧 API"）/ `softInvalidateFromPosition`（"v12"）→ 类成员 API 面 **49 → 46（有意删除，非回归）**；其余公开方法均确认有调用（`shouldTriggerSummary`←`trySummarize`、`shouldGenerateChapter`←多层/自动章节、`trySummarize`←`tryGenerateMultiLayerMemory`、`updateCoreMemory`←`forceGenerateChapterMemory`/`triggerCoreMemoryUpdateAsync`）
  - 附带死链**已按用户指示清除**（用户确认本项目单人使用、不保留历史库）：全仓 0 调用链 4 个方法一并删除 —— `MemoryPersistenceService.invalidateFromPosition` / `softInvalidateFromPosition` + `ChatMemoryRepository.invalidateFromPositionWithStore` / `softInvalidateFromPositionWithStore`（后两者仅被前两者调用）；同步修正 `softInvalidateCoveringPositionWithStore` 文档中指向已删方法的过时引用；无未用导入残留；编译 BUILD SUCCESSFUL
- **P3-2 收官**：MemoryService **1,953 → 1,451 行（-502，-25.7%）**；新增 `MemoryPromptBuilder` / `WorldMemoryStore` / `MemoryTriggerPolicy`；`ChapterTriggerConfig` + `DEFAULT_CHAPTER_TRIGGER` 下沉 `models/ChatMemory.ets`；编译 BUILD SUCCESSFUL + 单测 **96/96**

### P3-3 DatabaseSchema（起点 2,879 行）

**只读测绘**：L1-502 import（仅 1 个来源 `./DatabaseConstants`，490 行常量）；L504-2577 DDL 常量 + `Vxx_SCHEMA_STATEMENTS`/`Vxx_TO_Vyy` 数组；L2579-2713 `getSchemaStatements`（44 段 if）；L2715+ `getCreateTableStatements`/`getCreateIndexStatements`；**纯数据 + 纯函数，无 ArkData 依赖**（可 host 侧验证）

- [x] **① V38→39 / V39→40 版本映射疑点 — 只读核查 + 最小修正** ✅（核查只读；修正经用户拍板后落地，见末条）：
  - **迁移并不缺失**：38→39 / 39→40 的迁移**存在且完整**于 `database/DatabaseMigration.ets`——`V38ToV39Migration`（cleans 存量超大 `extensions_json`，数据迁移）、`V39ToV40Migration`（`ALTER characters` 补 Tavern V3 独有列，`V39_TO_V40_DDL_STATEMENTS` L1311）、`V40ToV41Migration`（`ALTER lorebooks` 补 activation_mode/injection_budget）。**版本连续、无 DROP、只增不改** ✅
  - **疑点确认为「schema 快照映射不准」而非「迁移缺失」**：[DatabaseSchema.ets L2694](`getSchemaStatements`) 将 `39 / 40 / 41 / 42` 四个版本**合并返回 `V42_SCHEMA_STATEMENTS`**；而语义上 `getSchemaStatements(v)` 应返回「到 v 为止的完整建库语句」（见 v1/v2 分支：v2 = v1 + v1→v2）。对 v39/v40/v41 返回 v42 快照，会**多出 v42 才引入的 `chats.world_id` / `chat_memories.world_id` 两列与两个 world 索引**；且 `V39_SCHEMA_STATEMENTS` / `V40_SCHEMA_STATEMENTS` **从未定义**（仅定义了 `V41_SCHEMA_STATEMENTS = [...V38_SCHEMA_STATEMENTS]`），疑为 39–42 分支被"就便"归并
  - **实际影响 = 0（潜伏不一致，非活跃缺陷）**：全仓 `getSchemaStatements` **仅 1 处调用**（`DbHelper.createFreshSchema` → `getSchemaStatements(DATABASE_VERSION)`，即 **47**）；无任何调用方/测试传 39/40/41；故该分支**生产不可达**
  - **修正已落地（用户拍板"最小修正"）**：注册表改为 `39/40/41 → V41_SCHEMA_STATEMENTS`、`42 → V42_SCHEMA_STATEMENTS`（后者未动）。依据：v39 为纯数据清洗（无 DDL），v40/v41 补的列**已并入 `CREATE_CHARACTERS_TABLE` / `CREATE_LOREBOOKS_TABLE` 常量**，故三者的完整建库语句本就等于 v38 链（= `V41_SCHEMA_STATEMENTS`）
  - 校验（逐版 DDL 对比）：**仅 v39/40/41 变化**（171 → 168 条，即由 v42 快照变回 v38 链）；**v1..v38 与 v42..v47 逐字节不变**；建表 37 / 索引 119 不变；修正后 `v38 == v39 == v40 == v41`、`v41 != v42`；v47 仍 176 条。**这三版不再纳入"逐版不变"验收口径（属预期变更）**，其余 44 版仍逐字节一致
  - 纪律：本次**未改任何迁移内容**（`DatabaseMigration.ets` 零改动），仅修正"新装快照"的版本归属；`DATABASE_VERSION` 仍 47
- [x] **② DDL 常量按域拆文件** ✅：新增 `entry/src/main/ets/database/schema/` 7 个域文件（共 **1,744 行**）：`SchemaCore`（227）/ `SchemaLorebook`（114）/ `SchemaPresets`（66）/ `SchemaSwipe`（58）/ `SchemaBranch`（85）/ `SchemaMemory`（106）/ `SchemaWorld`（1,088，废弃沙盒表集中于此）
  - **搬出内容**：全部 **188 个非导出 DDL 常量**（CREATE_*/ALTER_*），逐字搬出后统一补 `export`（跨模块引用所需，等价于 P2 的 private→public 可见性调整，**DDL 文本零改动**）
  - **保留在 DatabaseSchema**：全部 `export` 常量（V1..V47 版本数组、别名导出）+ 3 个函数 → **2,879 → 1,516 行（-1,363，-47.3%）**；import 块由 490 行（≈489 名）缩至 **57 名**
  - 分类规则：`CREATE_CHAT_MEMORIES_*`/`INDEX_CHATS_WORLD_ID`→Memory；characters/chats/messages 及 ALTER→Core；lorebook/pins/sticky→Lorebook；prompts/personas→Presets；swipe→Swipe；branch→Branch；`CREATE_/INDEX_WORLD*`+`GROUP*`+`ALTER_WORLD*`→World；**分类后无 UNCLASSIFIED**；域间**零交叉依赖**（无循环 import 风险）
  - 校验：Node 验证夹具（临时，仓外）解析 `getSchemaStatements(1..47)` + `getCreateTableStatements()` + `getCreateIndexStatements()` 全量字符串，**改造前后逐字节 DIFF = 0**（v1=7 / v38=168 / v42=171 / v47=176 / 表 37 / 索引 119）；`DatabaseMigration.ets` 仅从 DatabaseSchema 取 V* 数组（导出未动）→ 无破坏
  - 编译 BUILD SUCCESSFUL；单测 **96/96**
- [x] **③ `getSchemaStatements` 逐版 if 链 → Registry** ✅：44 段 if 链改写为 `SCHEMA_BY_VERSION: Map<number, string[]>`（47 条 `set`，1..47 全覆盖；39/40/41 的归并语义在 ③ 时原样保留，**随后按 ① 的"最小修正"拆开**），`getSchemaStatements` 变 4 行查表 + 浅拷贝（未知版本仍返回 `[]`）
  - 校验：`getSchemaStatements(1..47)` + 建表/索引全量字符串 **逐字节 DIFF = 0**；**导出声明面 99 → 99 零差异**；编译 BUILD SUCCESSFUL；单测 **96/96**；**DatabaseSchema 1,516 → 1,443 行**
- **P3-3 收官**：DatabaseSchema **2,879 → 1,443 行（-1,436，-49.9%）**；新增 `database/schema/` 7 个域文件（1,744 行）；①②③ 各自独立 commit；三个接缝均以「逐版 DDL 逐字节一致」为准入
  - **① 的 39/40/41 版本映射潜伏不一致已按"最小修正"落地**（用户拍板；仅 v39/40/41 输出变化，属预期）；迁移与 `DATABASE_VERSION` 未动

### P3-4 治理口径（**已固化进 `AGENTS.md` §3**，2026-09-27 用户拍板）

> 依据：只读统计（`pages/` × `services/` 导入扫描、`DbHelper` 导入扫描）——**已按代码复核并修正计数**。
> 结论：**主干分层成立**，偏差集中在两类边界。规则本身写在 **AGENTS.md §3**（权威）；本处只保留**清单与统计**，不重复规则。

#### (a) pages → services 分级（清单）

页面共 **34 个**；其中 **27 个**存在 `services/repositories/network/database` 导入，另 7 个（4 个 Tab RootView + `EdgeTtsTestPage` / `FrontendCardPage` / `ModelConfigEditPage`）无此类导入。

| 级别 | 页面（按代码扫描，2026-09-27 复核） |
|---|---|
| **T1 允许（14）** | AddCharacter / BranchMap / CharacterList / Index / LorebookSourceEditor / ModelSettings / PersonaList / PromptPresetEdit / PromptPresetList / WorldMemory（以上仅 `AppServices`）；**AppSettings**（`ThemeManager` + 常量，属 T1 白名单）；**ContinueGuideSettings**（仅常量）；**MemoryManagement**（仅 `ChapterMemoryIndexer` 纯函数 + 3 个常量） |
| **T2 待治理（11）** | AiCardRevise / AiCharacterMaker / AiCharacterPreview（`ModelService` / `AiCharacterGenerationService` / `CharacterService`）；CharacterEdit / PersonaEdit（`PersonaService`）；TtsSettings（`TtsService` / `EdgeTtsService`）；SyncSettings（`WebDavSyncService`）；ChatBackgroundSettings（`ChatBackgroundService`）；ContextBudget（`ContextBudgetSnapshotStore`）；WorldChapterList / WorldMemoryDetail（`MemoryService`） |
| **T3 冻结（2）** | `ChatPage`（约 8 个服务：`ContextBudgetSnapshotStore` / `MacroReplacer` / `TtsService` / `EdgeTtsService` 等）；`LorebookPage`（`LorebookService` / `CharacterService` / `CharacterRepository`） |

**处置**：T2 **不专门开批次**——改到哪个页面就在该次提交里顺带补/并 VM（一次一页、行为等价、独立冒烟）；优先级建议：MemoryManagement / ContextBudget / WorldMemory* / Persona·CharacterEdit。
> 修正记录：上版清单有三处不准（`MarketDetailPage` 实为仅 `AppServices`；`MemoryManagementPage` 实为仅常量/纯函数；"仅 11 个只依赖 AppServices" 应为 14 个 T1），**已按代码更正**。

#### (b) services → DbHelper 口径（清单）

`DbHelper` 对外面 = `initialize` / `getStore` / `getVersion` / `runInTransaction` / `getTransactionDepth` / `isInTransaction` / `isInitialized` / `close`。
事实上的两层持久化：**Repository 层**（14 个文件直接持有 `DbHelper`，单表 CRUD + 行映射，方法可接 `store`）+ **PersistenceService 层**（跨表事务编排，`dbHelper.runInTransaction`）。

**直接 import `DbHelper` 的服务共 10 个**（2026-09-27 复核，修正上版"6 个"）：

| 分类 | 服务 |
|---|---|
| 组合根（允许） | `AppServices` |
| 事务编排层（允许，本职） | `ChatPersistenceService` / `ConversationBranchPersistenceService` / `MemoryPersistenceService` / `MessageSwipePersistenceService` |
| **业务服务偏差（冻结，可择机回收）** | `ChatArchiveImportService` / `ForkChatService` / `sync/SyncDataExporter` / `sync/SyncDataImporter` / `sync/WebDavSyncService` |

**已采纳方案（口径 C 止血 + A 入 P4）**：
- **C（已固化进 AGENTS §3）**：`DbHelper` 引用白名单 = `repositories/*` + `AppServices` + `*PersistenceService`；其余服务**不得新增**；新跨表事务放入对应 `*PersistenceService`
- **A（P4 候选）**：抽 `TransactionCoordinator`（只暴露 `runInTransaction` / `runWithStore`，不泄露 `RdbStore`），把上述 5 处业务服务偏差一次性收口——**未落地**
- **B（补 Repository 下沉事务）：不做**（与业务强耦合，易过度设计）

## 3. 环境事实（防重复踩坑）

- SDK：`D:\DevEco_studio\DevEco Studio\sdk`（6.1.1；`D:\DevEco_studio\Sdk` 是旧版 6.0.2，会报 00303312）
- 编译命令见 `AGENTS.md` §5；同一命令最多 3 次；单次约 35~45s
- 签名配置在 `build-profile.json5`（绝对路径指向 `C:\Users\35595\.ohos\config\...`，本机有效）
- 无 hvigorw 包装脚本，统一用全局 CLI；系统 node v24 可用
- 测试：`entry/src/test/` 有 11 个单测文件 / 16 个测试类 / 96 用例（如 frontend_interaction、prompt_segment_order、lorebook_sticky_service）；**已可用 `hvigorw test` 本机执行**（2026-09-27 首跑全通过；结果落盘 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`）；日常验证仍以编译 + 真机冒烟为主

## 4. 待用户确认 / 关注

- **`userScrolledUp` 疑似死标记（2026-09-28 发现，未修）**：全仓 `Grep "userScrolledUp"` 只找到 `= false` 赋值，**没有任何地方置 true** → 后果：① `ChatPage` 的"回到底部"浮动按钮（条件含 `userScrolledUp`）永不显示；② 用户上滑看历史时，新消息/流式仍会强制滚回底部（`autoScrollToBottom` 的上滑保护失效）。修法：在消息列表 `onScroll`/`onScrollStart` 里按 `isAtEnd()` 反推置位。**属未验证推断（仅静态 Grep 取证）**，待用户决定是否开一轮修复
- **冒烟节奏（2026-09-27 用户决定）**：真机冒烟**统一在 P3 批次末期一次性进行**（当前不便实机操作）；下方 P2-9 与 P2-10..P2-14 各冒烟清单保持待办，回滚锚点继续有效。host 侧验证已在当前 HEAD（`f1c54ed`）复跑：编译 BUILD SUCCESSFUL + 单测 **96/96 全通过**；P2 批次按"约束内收官"处理，千行级与实机验收待用户后续拍板
- **真机冒烟验证**：P1-2 主链路改动 + P1-3 前三个组件已通过真机冒烟（用户确认无问题）；`ChatAppearancePanel`（显示设置：滑块/配色模式/自定义色/色盘/恢复默认）与 `ChatStatusWorldPanel`（世界书条目启停/展开、AI 入口与两种模式、变更预览应用与取消、刷新激活）待真机冒烟。若发现问题：告知功能名即可，按 commit 精确回滚（P1-2：a0c3a11 / 9456dc2 / a4511ac / c78caf5 / 0cd508f）
- **待真机冒烟（当前有效两项）**：
  1. 角色卡前端界面（commit `d44797b`，P1-5）：全屏页（FrontendCardPage）与聊天页面板两种入口打开；页面内 getState/setState/getCharacter/getMessages/send/appendInteraction/close 均可用；面板收起/展开无白屏
  2. 对话记录 Tab 分组弹窗（commit `8ff588e` + `a1d2a5d`，P1-4 ①②）：分组新建（空名拒绝）/重命名/删除（仅解除关联）/移动会话（含"不分组"）/"新建文件夹并移入"（空名拒绝、操作中置灰）/左滑"分组"入口/折叠状态重启后保持
  - 回滚锚点：`d44797b`（CardFrontendWeb）/ `a1d2a5d`（Tab 弹窗迁移，依赖 `8ff588e` 与 SessionGroupDialogs，回滚需成组）
- **P2-1 待冒烟（"搬运不改行为"，以后两项为主）**：
  1. 请求计划（`702d3db`）：顶栏预算指示器数值正常；长会话发送时触发历史裁剪后回复仍完整；上下文占用统计正常
  2. 请求构建与注入（`8e0ad06`，**主链路，重点**）：发送/流式/停止正常；角色绑定世界书注入（日志 tag 现为 `ChatRequestBuilder`）；按需记忆（OnDemandPinned）与粘滞世界书（StickyOnDemand）注入与尾部"当前仍生效的设定"提醒正常；重生成/代写（候选生成走 excludeMessageId 路径）正常
  - 回滚锚点：`64b0c4e` / `702d3db` / `8e0ad06`（三者为独立 commit，但 1c 依赖 1a 的 ChatTextContract，回滚需成组）
- **P2-2 待冒烟（代写/性格/续写，"搬运不改行为"）**：
  1. 代写（impersonate）：输入区/更多菜单代写入口 → 生成 3 条候选、点击填入输入框；用户自定义代写引导（设置内）生效；有 persona 摘要的会话候选风格贴近摘要
  2. 性格提取（用户身份）与性格总结：两处入口执行成功并写回角色卡；无角色/未配置模型时提示不变
  3. 续写 ⚡：生成一对"用户发言 + 角色回应"并落库（切走再回来仍在）；续写引导生效；生成中不予重复触发、失败提示不变
  4. 旁白 / 分支 / Swipe / 主发送链路不受影响（未搬动）
  - 回滚锚点：`ad5d0aa`（P2-2b）/ `bac896d`（P2-2a 类型迁出，回滚需成组）
- **P2-3 待冒烟（角色状态簇，"搬运不改行为"）**：
  1. 状态面板：声明字段与当前值正常显示；编辑/锁定/清空字段后持久化并即时刷新
  2. "AI 生成"字段：一次性请求成功并更新状态；失败分支提示不变；状态指令开关（记忆管理页）切换生效、重启后保持
  3. 主线发送后：AI 回复中的状态块被解析合并（锁字段不动、未声明字段丢弃）；schema 为空时状态入口不出现
  4. 会话切换/新建后状态随会话切换（statusConfigJson 同步）
  - 回滚锚点：`56e559f`
- **P2-4 待冒烟（Swipe 全族，"搬运不改行为"）**：
  1. 候选切换：上一条/下一条/指定索引（开场白选择）切换后内容与摘要同步刷新、会话列表不置顶（仅 updatedAt）
  2. 重新生成：达到候选上限时的提示（"该回复已达到候选数量上限"）；创建候选失败的提示；生成期间与 Swipe 操作互斥
  3. 多开场白（alternate_greetings）：新建章节后首条消息可切换候选
  4. 生成完成后摘要箭头状态复位（isGeneratingCandidate）；候选切换后记忆失效逻辑不报错
  - 回滚锚点：`5ac6bb8`（P2-4b-2）/ `9c21aa1`（类型迁出）/ `4bd6998`（P2-4a）
- **P2-5 待冒烟（Branch 查询/判定，"搬运不改行为"）**：
  1. 消息操作菜单可用性判定不变：历史 Assistant"从此处继续"/"重新生成此回复"、历史 User"生成新回复"/"编辑"（不可用时入口隐藏/禁用）
  2. 分支面板/分支映射页：分支列表、活动分支、记录数量统计显示正确
  3. 外部（BranchMapPage）切换分支后回聊天页，消息与分支状态刷新正常（`reloadAfterExternalBranchChange` 未搬，走原路径）
  - 回滚锚点：`d798259`
- **P2-6/P2-7/P2-8 待冒烟（"搬运不改行为"）**：
  1. 消息操作（`01361d0`）：删除单条消息（首条不可删提示、Assistant 同步清理 Swipe 候选、记忆失效）；编辑旁白；编辑角色回复（编辑后记忆失效）
  2. 上下文维护（`b4fc54f`）：手动记忆总结成功后世界书激活刷新；自动总结开关切换并重启保持；Swipe 切换/删除消息后软失效不报错
  3. 分支生成（`bbbfcda` / `e272d9b`）：重新生成（创建分支）正常；四个历史消息入口（从此处继续 / 重新生成此回复 / 生成新回复 / 编辑并生成）正常；分支映射页切换后回聊天页刷新；候选上限与失败提示不变
  - 回滚锚点：`e272d9b` / `bbbfcda` / `b4fc54f` / `01361d0`（各自独立）
- **P2-9 待冒烟（会话生命周期，"搬运不改行为"）**：
  1. 应用启动进入聊天页：会话恢复（继续上次会话）；首次无会话时自动新建并注入开场白（多开场白时首条消息可 Swipe 切换）；角色卡"新建对话"入口立即创建新会话
  2. 会话切换：从"对话记录"Tab 点会话进入聊天页后切换到指定会话；相同会话重复切换无副作用；生成中/会话操作中互斥提示不变
  3. 删除会话：删除当前会话后回退到最近会话；全部删完自动新建（含开场白候选）；删除非当前会话时页面消息不变
  4. 新建章节（开场白选择器）：世界分组自动创建/移入、标题"第N章·…"、状态配置继承、创建后自动切到新会话
  5. 初始化失败路径提示不变（数据库异常等文案由 ViewModel 呈现一次）
  - 回滚锚点：`891de45` / `1f09346` / `cc32bfc`（9b/9c 依赖 9a 的 ChatSessionService 基座，回滚需成组）
- **P2-10..P2-14 待冒烟（"搬运不改行为"，**主链路重点**）**：
  1. 发送消息（`fa44f58`）：输入发送 → 用户消息 + 流式回复（打字机、停止按钮、完成/取消/失败状态）；持久化失败提示"消息保存失败,请重试"不变；生成中重复发送被拒（日志 `ChatMessageSender`）
  2. 旁白两种模式：旁白（AI 以叙述者身份回复）与"仅插入旁白"（不触发请求）；会话未初始化时提示"会话未初始化"
  3. 清空对话：菜单"清空对话"后列表为空、状态复位（生成中先停止）
  4. 用户称呼（`f0ee661`）：聊天页"用户称呼"弹窗读写（对话级覆盖/清空）；角色卡默认 Persona 与锁定 Persona 生效；代写/请求构建中的用户称呼与 Persona 注入不变（日志 tag `ChatUserIdentityService`）
  5. 请求预设快照（`1ab7a8c`）：发送/重生成/代写均按当前选中预设出请求（日志 `createPresetRequestSnapshot: selected preset count=N`）；预设读取异常提示"无法读取当前提示词预设，请重试"不变
  6. 消息"计入记忆"开关（`9f13ce4`）：长按/菜单切换该条消息的 includeInMemory 并持久化（重进会话仍生效）
  7. Swipe 生成标志与分支刷新（`29f8f45`）：重新生成候选时摘要箭头的生成中状态正常；分支面板数据刷新正常
  - 回滚锚点：`29f8f45` / `9f13ce4` / `1ab7a8c` / `f0ee661` / `fa44f58`（各自独立）
- **P3-1 待冒烟（"搬运不改行为"）**：
  1. 错误映射（`a1c0478`）：未配置模型 / 禁用模型 / API Key 缺失 / 401 / 429 / 超时 / 网络失败 / 5xx / 解析失败 的提示文案不变；会话切换/新建/删除失败提示文案不变（"会话不存在或已删除"等）
  2. 世界书面板（`38dc6a3`）：聊天页状态/世界书面板打开后角色专属世界书条目列出（按 priority 降序、同级按名）；条目启停开关切换后列表刷新；AI 世界书"修改/提取"生成变更预览、套用（新增/更新/删除）后列表刷新；以上失败路径仅日志告警、面板数据回退 null
  - 回滚锚点：`38dc6a3`（P3-1②）/ `a1c0478`（P3-1①，各自独立）
- **P3-2 待冒烟（"搬运不改行为" + 死代码删除）**：
  1. 记忆生成（`7ebc2e1` / `bfb1114` / ③）：多层记忆手动/自动总结产出章节/核心/会话记忆；聊天页状态·记忆面板"生成摘要"成功；会话记忆生成（记忆管理页）正文与结构不变
  2. 词条召回与手工记忆（`bfb1114`）：文件夹记忆根页/详情页新增·编辑·删除手工记忆；聊天注入的世界池记忆与关键词召回命中行为不变
  3. 触发阈值（③）：长会话达到阈值自动触发章节/rolling 总结的时机不变（日志 tag 现为 `MemoryTriggerPolicy`）
  4. 死代码删除回归：无 UI 入口（`getPersistence`/`invalidateFromPosition`/`softInvalidateFromPosition` 均无调用方）；确认"重新生成/Swipe 切换后记忆软失效"仍走 `softInvalidateCoveringPosition`（未动）
  - 回滚锚点：`7ebc2e1`（P3-2①）/ `bfb1114`（P3-2②）/ ③+死代码（各自独立）
- **P3-3 待冒烟（数据库层，**重点**）**：
  1. 全新安装（清数据后首启）：建库成功、`user_version=47`、聊天/角色/世界书/记忆/Swipe/分支各表可用（对应 `createFreshSchema` → `getSchemaStatements(47)`）
  2. 既有库启动（低版本升级）：逐版迁移链跑通（含 38→39 数据清洗、39→40 characters 补列、40→41 lorebooks 补列、41→42 world_id 补列、43→44 正则/扫描深度、44→45 pins、45→46 sticky、46→47 anchors）；升级后旧数据可读、无 `schema failed`
  3. 启动幂等：非首次启动走 `ensureSchemaExists`（仅 CREATE IF NOT EXISTS，不执行 ALTER）无报错
  4. 回归：聊天主链路（发送/流式/重生成/Swipe/分支）与记忆、世界书读写正常
  - 回滚锚点：`2ad376d`（P3-3② 域拆分）/ `71dd42a`（P3-3③ Registry，各自独立）
- **本轮附加验证（2026-09-27，host 侧）**：本地单元测试套件已在本机执行通过 —— `hvigorw test`（`entry/src/test`，16 个测试类 / **96 用例全部 Success，0 失败 0 忽略**；结果落盘 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`）。覆盖：ChatTextContract 纯函数（前端交互缓冲 / 粘滞提醒文本 / 状态段拆分 —— P2-1、P2-3 搬运过的纯函数）、PromptSegment 段序、状态 schema 解析、世界书激活与粘滞服务、ChapterMemoryIndexer、MemoryLoadRefService、ContextBudgetEstimator、Lorebook 模式、Gemini 模型过滤、前端契约 v2；**不含**会话 / Swipe / 分支 / 流式簇（依赖 DB/网络，只能真机冒烟）。命令：`hvigorw test --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon`
- **API 面等价校验（2026-09-27，机械对比）**：以 tag `refactor-baseline` 为基准，抽取 ChatService 全部非 private 声明（方法 / 访问器）逐行对比 → 修复后 **89 项签名与基线完全一致**（含 `async` 修饰符）。过程中发现并修复 1 处搬运残留：`refreshLorebookPinNow` 的 `async` 修饰符在 P2-7 薄包装时丢失（调用侧行为等价，但签名不同）→ 已恢复（commit `36d809c`，编译通过）。新模块分层抽查：`ChatSessionService` / `ChatMessageSender` / `ChatUserIdentityService` 无 viewmodels / pages / components 越层导入
- **已作废冒烟项**（相关代码已删除）：会话列表面板（`726efec` / `958b43b` 的面板侧）——面板与 ChatViewModel 会话列表 API 已随 P1-4 ③ 删除，不必再测
- **需回归确认**（删除相影响面）：聊天页正常打开/发送/停止/重生成；更多菜单"新建章节(切换开场白)"创建后提示与当前会话不变；从"对话记录"Tab 点会话进入聊天页仍能切到指定会话（`pendingChatId` → `selectSession` 路径未动，但 `refreshSessions` 已移除，建议确认切换后列表/消息正常）
- `APK-reference/`（约 100MB 反编译参考资料）暂保留，未清理
- pages 直连具体服务（17 个文件，最重 ChatPage）属"务实偏差"，治理口径待定（见审计报告 §3）
- P2/P3/P4 的启动时机以用户节奏为准

### 4b. 统一实机冒烟清单（P2 + P3 汇总 · 末期一次性执行）

> 上方 §4 为逐接缝明细；此处按**功能域**汇总，便于一次跑完。全部为「搬运不改行为」验证，**只看行为是否与重构前一致**。
> 若发现问题：告知功能名 → 按下方锚点精确回滚（同一域内锚点均独立，`ChatService` 系列除外）。

| # | 功能域 | 关键判定点 | 回滚锚点 |
|---|---|---|---|
| A | **聊天主链路** | 发送/流式打字机/停止 → 持久化失败提示"消息保存失败,请重试"；生成中重复发送被拒；旁白两种模式；清空对话；重生成（含创建分支）；代写 3 候选填入；性格提取/总结写回角色卡；续写 ⚡ 成对落库 | P2-10/11/12/13/14：`fa44f58` `f0ee661` `1ab7a8c` `9f13ce4` `29f8f45` |
| B | **请求计划与注入** | 顶栏预算指示器；长会话裁剪后回复完整；角色绑定世界书注入；按需记忆 + 粘滞世界书 + 尾部"当前仍生效的设定"提醒（日志 tag `ChatRequestBuilder`） | P2-1：`64b0c4e` `702d3db` `8e0ad06`（成组） |
| C | **代写/性格/续写引擎** | 候选生成走 `excludeMessageId`；用户自定义引导生效；无角色/未配模型提示不变 | P2-2：`ad5d0aa`（+`bac896d`） |
| D | **角色状态** | 状态面板读写/锁定/清空；AI 生成字段；回复中状态块合并（锁字段不动/未声明丢弃）；schema 空时无入口；状态指令开关重启保持 | P2-3：`56e559f` |
| E | **Swipe / 分支** | 候选上下切换与摘要刷新（会话不置顶）；候选上限提示；多开场白；生成中标志复位；消息菜单四项可用性判定；分支面板/映射页切换后刷新 | P2-4/5/8：`5ac6bb8` `9c21aa1` `4bd6998` `d798259` `e272d9b` `bbbfcda` |
| F | **消息操作与上下文维护** | 删除单条（首条不可删/同步清 Swipe/记忆失效）；编辑旁白/角色回复；手动总结后世界书激活刷新；自动总结开关重启保持；软失效不报错 | P2-6/7：`01361d0` `b4fc54f` |
| G | **会话生命周期** | 启动恢复会话/首启新建注入开场白；从"对话记录"Tab 切换；删除回退/全删新建；新建章节（世界分组自动入/标题/状态继承）；初始化失败文案 | P2-9：`891de45` `1f09346` `cc32bfc`（成组） |
| H | **记忆（P3-2）** | 多层手动/自动总结产出章节+核心+会话记忆；手工记忆增删改；关键词召回命中；阈值触发时机（日志 `MemoryTriggerPolicy`） | P3-2：`7ebc2e1` `bfb1114` `bf18dbe` |
| I | **世界书面板与错误文案（P3-1）** | 面板条目按 priority 降序；条目启停刷新；AI 世界书修改/提取 → 预览 → 套用；未配模型/禁用/401/429/超时/5xx 等文案不变 | P3-1：`a1c0478` `38dc6a3` |
| J | **数据库（P3-3，重点）** | ① 清数据首启建库成功 `user_version=47`；② 低版本库升级逐版迁移链跑通、旧数据可读、无 `schema failed`；③ 再次启动走幂等路径无报错；④ 聊天/记忆/世界书读写回归 | P3-3：`2ad376d` `71dd42a` |
| K | **UI 组件（P1 遗留）** | 显示设置面板（滑块/配色/色盘/恢复默认）；状态·世界书面板（条目启停/展开/AI 两种模式/预览套用/刷新激活）；角色卡前端全屏页与聊天面板；对话记录 Tab 分组弹窗；归属 P1 冒烟项继续有效 | P1：`d44797b` / `a1d2a5d`（+`8ff588e`） |
| L | **回归确认（P1-4 删除影响面）** | 聊天页正常打开/发送/停止/重生成；"新建章节(切换开场白)"提示与当前会话不变；Tab 点会话进入聊天页仍能切到指定会话 | 见 §4"需回归确认" |

**执行前置**：`git status` 干净 + 当前 HEAD 编译 BUILD SUCCESSFUL + 单测 96/96（本次已验证）。
**建议顺序**：J（数据库，最影响可用性）→ A → E → H → I → B/C/D/F/G → K/L。

### 4c. 统一实机冒烟执行结果（2026-09-27 · 真机 MIS-AL00 / API 24）

> 设备 `192.168.137.142:12345`；流程 = 覆盖安装（`install -r`，保留数据）→ 逐域执行 → 清数据首启。
> **本轮无基线构建作对照**，判定口径 = 「功能可用 + 无异常/无崩溃 + 数据读写正确 + 与文档描述的预期一致」。

| 域 | 结论 | 证据 |
|---|---|---|
| A 聊天主链路 | ✅ 通过 | 发送 → 流式逐字产出 → 红色停止键中断且保留已生成内容；顶栏预算指示器 `2.2K / 121.9K · 2%`、`Cache 72~87%` |
| B 请求计划与注入 | ✅ 通过 | `ChatRequestBuilder` 日志 5 行（`createPresetRequestSnapshot` / `buildRequestMessages` 世界书 `小雅 · 角色世界书 entries=2` / `lorebookSticky entries=2` / `sticky lorebook injected anchored=2 head=0`） |
| C 代写/性格/续写引擎 | ✅ 通过 | 续写 ⚡ 生成整回合（用户台词 + 助手回复）；代写 🎭 出 3 条候选面板；旁白 📖 是**模式开关**（`[旁白模式] Enter=仅旁白`），以 NARRATOR 样式落消息并触发生成 |
| C/E Swipe 候选 | ⚠️ 未覆盖 | `MessageSwipeControls` 仅 `candidateCount > 1` 时渲染 `‹ n/m ›`，本轮未构造多候选（`重新生成` 走分支生成族，已通过） |
| C 分支 | ✅ 通过 | 长按助手消息 →「从此处创建独立对话」→「携带完整历史」→ 会话列表新增 `独立对话`（preview 正确）→ 可正常删除 |
| D 角色状态 | ➖ 未覆盖 | `小雅` 卡无 status schema，聊天页无状态入口（与"schema 空时无入口"设计一致） |
| F 消息操作与上下文维护 | ⚠️ 部分 | 助手菜单（复制/编辑/从此处继续/重新生成/从此处创建独立对话/删除）与旁白菜单（复制/编辑/加入记忆/从此处创建独立对话/删除）均正常弹出；未逐项执行编辑/删除落地 |
| G 会话生命周期 | ✅ 通过 | 切换会话加载正确内容；左滑 → 上移/下移/重命名/导出/分组/删除；删除有二次确认且真删；分组管理弹窗（重命名/删除分组）正常 |
| H 记忆（P3-2） | ✅ 通过 | 对话记忆页统计正确（17 消息 / 未总结 2121 字符）→「生成章节」→ 已总结 17/17、记忆 2230 字符、时间线 + 按人物·事件 两种视图、章节条目 `章节 1-17`（雾都 · 世界共享） |
| I 世界书面板与错误文案（P3-1） | ✅ 通过 | 聊天页世界书面板渲染角色世界书条目（家庭背景 / 小雅的习惯 + 关键词 + 启用态），AI / 刷新激活 按钮在位；世界书页（清数据后）空态正常 |
| J 数据库（P3-3，重点） | ✅ 通过 | `bm clean -d` 后首启：hilog `HandleSchemaDDL … schema<0->1> … <49->50>` 逐版跑完，**无 error / 无 jscrash**；空态全部正确（角色卡「还没有角色」/ 对话记录「暂无会话」/ 世界书「暂无世界书」/ 模型设置「尚无模型配置」）；`DATABASE_VERSION=47`（`database/DatabaseConstants.ets`）与文档一致 |
| 持久化（跨重启） | ✅ 通过 | `aa force-stop` + 重启后会话与记忆保留，已删会话未复活 |
| K/L 组件与 P1-4 回归 | ⚠️ 部分 | 分组弹窗 ✅、世界书·状态面板 ✅；角色卡前端页 / 显示设置面板 / TTS / 归档导入导出 / 云同步 未覆盖 |

**未覆盖项**（需另择时或用户自验）：Swipe 多候选切换、角色状态面板（当前卡无 schema）、消息编辑/删除落地、新建章节、角色卡前端页、显示设置面板、TTS 朗读、归档导入导出、云同步。

**观察（未确认，非阻塞）**：聊天页历史助手消息气泡下方有时出现一个**小空心圆指示**，来源与语义未确认——非 `▍` 流式光标，`ChatMessageList` / `ChatMessageBubble` 内未找到对应渲染节点，`dumpLayout` 也未捕获到对应文本节点。不影响功能；**建议与基线构建对照确认是否既有**。

**测试后设备状态**：应用已**清数据**（无角色 / 无会话 / 无模型配置），需重新导入角色卡并配置模型后才能使用。

**新增踩坑**：`PITFALLS.md` P-47（日志非主证据）/ P-48（坐标必取 `bounds`）/ P-49（`inputText` 走输入法）/ P-55（`bm clean -d` 清掉 KeyStore）。

## 5. 会话日志（追加式）

| 日期 | 会话主题 | 产出 / 决策 |
|---|---|---|
| 2026-09-27 | 审计 + 文档体系重建 | 审计报告与路线图；`AGENTS.md` + `docs/handover/` 建立；`tools/`、开发截图、旧文档归档清理；决策：交接文档进版本库 |
| 2026-09-27 | P1 批次执行 | P1-1 ✅；P1-2 重复逻辑消除 ✅；P1-6 不可变性 ✅；**真机冒烟通过（用户确认无问题）**；P1-3：ChatForkPicker ✅ / ChatMessageList ✅ / ChatInputArea ✅ / ChatAppearancePanel ✅ / ChatStatusWorldPanel ✅（**P1-3 收官，ChatPage 5949→4898 行**）；每步编译通过 |
| 2026-09-27 | P1-5 组件越层修复 | `CardFrontendWeb`/`CardFrontendBridge` 改宿主契约 `FrontendCardHost` ✅（d44797b）；`ChatSessionListPanel` 去 `ChatViewModel`/`AppServices`，改 @Prop + 回调、折叠持久化上提 ChatPage ✅（726efec）；组件层仅剩 `ChatStatusWorldPanel` 一处类型引用；每步编译通过；P1-4 已写分相建议（待对齐合并方向） |
| 2026-09-27 | P1-4 低风险相 | ① `utils/SessionListCollapseState` 折叠纯函数收口三处重复 ✅（8ff588e）；② `components/SessionGroupDialogs` 四个分组弹窗共享，面板迁移 ✅（958b43b）；③ 对话记录 Tab 迁移 ✅（a1d2a5d，-380 行，2815→2435）；每步编译通过 |
| 2026-09-27 | P1-4 收官（删除死 UI） | 核实 `ChatSessionListPanel` 不可达（入口早已收敛到"对话记录"Tab）→ 经用户确认改为删除：ChatPage 引用摘除（020dd05）→ 面板整文件（b8500bb）→ ChatViewModel T-4.5 会话列表/分组 API（7983170），合计 **≈-1069 行**；原"数据换源 + overlay + 单组件(mode)"方案作废；`SessionGroupDialogs`/`SessionListCollapseState` 保留给 Tab；每步编译通过 |
| 2026-09-27 | P2-1 开工（ChatService 瘦身） | ① 契约常量 + 文本纯函数下沉 `ChatTextContract` ✅（64b0c4e，-285 行，5 处外部导入改路径）；② 请求计划抽离 `ChatRequestPlan` ✅（702d3db，五分支语义对齐）；③ `ChatRequestBuilder` 抽取 ✅（8e0ad06，6 方法 615 行逐字搬运 byte 级比对一致）；**ChatService 6,735 → 5,781 行（P2-1 合计 -954）**；装配范式确立：构造注入 + 函数属性宿主回调 + 同名转发（零改写） |
| 2026-09-27 | P2-2 开工（ChatService 瘦身） | ① `ChatState` / `ChatServiceCallbacks` 迁入 `models/ChatServiceContract` ✅（bac896d，2 处引用改路径）；② `ChatOneShotGenerator` 抽取 ✅（ad5d0aa，6 方法 513 行逐字搬运 byte 级一致 + `AutoContinueTurn` 随迁，宿主回调扩展 **setter 写入面**）；**ChatService 5,781 → 5,273 行**；每步编译通过；待用户真机冒烟 |
| 2026-09-27 | P2-3 开工（ChatService 瘦身） | `ChatStatusService` 抽取 ✅（56e559f，5 状态字段 + 6 纯函数 + 597 行逐字搬运 byte 级一致；6 处可见性调整、1 处调用点改写（flag 复位走 `resetFieldGenerationRequest`）已记录）；**ChatService 5,273 → 4,740 行**；编译通过；待用户真机冒烟 |
| 2026-09-27 | P2-4 开工（ChatService 瘦身） | ① `ChatGenerationKind`/`ActiveGenerationContext` 迁入 `models/ChatGenerationContext` ✅（9c21aa1）；② `ChatSwipeController` 浏览/切换族 ✅（4bd6998，151 行逐字一致）；③ 生成族迁入 ✅（5ac6bb8，176 行逐字一致，宿主含 `doStream` 委托；流式核心未动）；**ChatService 4,740 → 4,484 行**；每步编译通过；待用户真机冒烟 |
| 2026-09-27 | P2-5 开工 + P2 批次收官 | `ConversationBranchService` 查询/判定 ✅（d798259，三区 252 行逐字一致；fork+stream 族暂留 P3）；**ChatService 4,484 → 4,305 行，P2 合计 6,735 → 4,305（-2,430）**；P2 路线（P2-1..P2-5）全部完成；编译通过；待用户真机冒烟 + 决定 P3 走向 |
| 2026-09-27 | P2 扩展（P2-6..P2-8） | `ChatMessageService`（01361d0）/ `ChatContextMaintenanceService`（b4fc54f）/ branch 切换与重载（bbbfcda）/ branch 生成族七碎片（e272d9b）——合计 **1,183 行逐字搬出**（均 byte 级一致）；**ChatService 4,305 → 3,315 行（累计 6,735 → 3,315，-3,420）**；每步编译通过；待真机冒烟 |
| 2026-09-27 | P2-9（会话生命周期） | `ChatSessionService` 三段抽取：工具/查询族（cc32bfc，6 碎片 144 行）→ 初始化族（1f09346，四块 214 行）→ 操作族（891de45，五块 248 行）——合计 **606 行逐字搬出**（均 byte 级一致），清理 4 个死包装；宿主 38 项回调；`dispose` 有意留 ChatService 并已记录；**ChatService 3,315 → 2,780 行（累计 6,735 → 2,780，-3,955，-59%）**；每步编译通过；待真机冒烟 |
| 2026-09-27 | P2-10..P2-14（收官） | ① `ChatMessageSender` 消息发起入口（fa44f58，四块 231 行，`stopGeneration` 有意留 ChatService）；② `ChatUserIdentityService` 用户称呼与 Persona（f0ee661，124 行）；③ Preset 快照迁入 `ChatRequestBuilder`（1ab7a8c，77 行 + 2 依赖，编译修正 1 处）；④ 消息记忆标记迁入 `ChatMessageService`（9f13ce4，31 行 + 宿主项收口）；⑤ `reloadCurrentSession` 迁入 `ChatSessionService`（29f8f45，15 行）——合计 **478 行逐字搬出**（均 byte 级一致）；**ChatService 2,780 → 2,413 行（累计 6,735 → 2,413，-4,322，-64%）**；**主动停止**：现实下限 ≈2,350~2,400（剩余仅 `updateRequestPlan`+估算 ≈77 行，因核心共享缓存 ROI 为负）；千行级需突破"流式核心不动"约束（待用户授权）；每步编译通过；待真机冒烟 |
| 2026-09-27 | P2 验证（host 侧附加） | 本地单测套件执行通过：**16 类 / 96 用例全 Success，0 失败**（`hvigorw test` BUILD SUCCESSFUL；结果落盘 `entry/.test/.../coverage_data/test_result.txt`）——含 P2-1/P2-3 搬运过的 ChatTextContract 纯函数（前端交互缓冲 / 粘滞提醒 / 状态段拆分）；为 P2 搬运补一层 host 侧回归证据；会话 / Swipe / 分支 / 流式簇仍需真机冒烟（本机当前无设备连接，`hdc list targets` 为空） |
| 2026-09-27 | **文档治理与 AI 约束体系** | 新增 3 份单一职责文档：`FEATURE_MAP.md`（功能→文件→约束，权威定位表，替代过期 archive 表）· `INVENTORY.md`（可复用资产清单，解决"重复造轮子/轮子不统一"）· `PITFALLS.md`（踩坑与硬约束累积，编号一条一行）；`README.md` 文档地图与使用规则重写。`AGENTS.md`：新增 **§3B 给 AI 的工作约束**（设计/验证/诚实/文档四组，共 15 条）· §2 接手流程改为"按任务类型选读" · §9 定位表改为指针 · §10 补文档职责与"同一事实只出现一次/不建 changelog" · §11 瘦身为骨架 + 指针。决策：**不建 changelog**（变更历史以 git 为准，`git log --grep` 可按功能检索）。同日**固化 P3-4 治理口径进 AGENTS §3**（pages 三级 T1/T2/T3 + `DbHelper` 引用白名单；口径 C 生效、A 留 P4、B 不做），并按代码复核更正清单计数（`DbHelper` 服务 **10** 个非 6；页面 **34** 个、T1 14/T2 11/T3 2）；新增踩坑 P-75（统计类清单必须扫描代码得出） |
| 2026-09-27 | **P3 批次（ChatViewModel / MemoryService / DatabaseSchema + 治理口径）** | 开工基线编译通过 + 单测 96/96。**P3-1**：`ChatErrorMapper`（a1c0478，-38 行）+ `LorebookPanelVM`（38dc6a3，-181；类型迁 `models/LorebookPanel`，顺带消除组件层 viewmodels 类型引用偏差）+ ③ 会话分组桥核实无重复 → **ChatViewModel 1,698 → 1,479 行**。**P3-2**：`MemoryPromptBuilder`（7ebc2e1，-289；`ChapterTriggerConfig` 下沉 models/ChatMemory——ArkTS 禁结构类型的教训）+ `WorldMemoryStore`（bfb1114，-84）+ `MemoryTriggerPolicy` 与死代码删除（bf18dbe，-99；删 3 个 0 调用公开方法）→ **MemoryService 1,953 → 1,451 行**。**P3-3**：① V38→39/39→40 只读核查（迁移完整；39/40/41→V42 快照映射潜伏不一致、生产不可达，**未改**）+ ② DDL 分域 7 文件（2ad376d；DatabaseSchema 2,879 → 1,516）+ ③ Registry（71dd42a；→ 1,443）→ 逐版 DDL **逐字节 DIFF=0**。**P3-4**：治理口径方案（只出方案）。每接缝均编译通过 + 机械校验（byte / API 面 / 逐版 DDL）；真机冒烟统一末期（清单见 §4b） |
| 2026-09-27 | P2 验证（API 面等价） | ChatService 公开 API 面与基线 `refactor-baseline` 机械对比：**89 项签名完全一致**；发现并修复 1 处搬运残留——`refreshLorebookPinNow` 丢 `async` 修饰符（`36d809c`，编译通过）；新模块（`ChatSessionService`/`ChatMessageSender`/`ChatUserIdentityService`）无越层导入 |
| 2026-09-27 | **统一实机冒烟（P2+P3）** | 真机 MIS-AL00 / API 24（`192.168.137.142:12345`），覆盖安装（保留数据）→ 逐域执行 → 清数据首启。**通过**：A 主链路（发送/流式/停止）· B 请求注入（`ChatRequestBuilder` 日志 5 行）· C 代写/续写/旁白/重生成/分支（新建 `独立对话`）· G 会话切换/删除/分组 · H 记忆章节（17→17 已总结，2230 字符）· I 世界书面板 · J 清数据首启建库（DDL 逐版跑完无 error，四页空态正确，`DATABASE_VERSION=47` 一致）· 跨重启持久化。**未覆盖**：Swipe 多候选、角色状态面板（当前卡无 schema）、消息编辑/删除落地、新建章节、角色卡前端页、显示设置面板、TTS、归档导入导出、云同步。**未发现重构相关缺陷**（无 jscrash / 无 error / 无功能回归）。记录一处**未确认观察**：历史助手消息气泡下方的小空心圆指示（来源未确认，非阻塞）。结果详见 **§4c**；新增踩坑 P-47/P-48/P-49/P-55。测试后设备已清数据 |
| 2026-09-27 | **分支地图改版（缩进树）** | 起因：用户导出存档反馈"分支显示迷惑 + 整张图难分辨"。**先读存档还原真实结构**（21 条消息 / 6 个分支 / 4 个分叉点），定位三个缺陷：① 标题取「第 N 轮分支」（N = 分叉点前的用户消息数）→ **同一句话分叉的两条分支必然同名**（实测两对）；② 末端节点「第 N 轮」与其所属分支「第 N 轮分支」几乎同名；③ 已经算好的"分歧首句"（`firstDivergentAssistantPreview`）**根本没显示**。另发现底部栏**硬编码角色名「艾伦:」**（真实角色是 `小雅`）。方案经可视化对比由用户拍板：**保留树形、只换画法**（用户明确"不是文字难分辨，是整张图难分辨"）→ **缩进树（graph 风格）**。**实现**：新增 `models/BranchFlatRow` + `utils/BranchTreeFlatten`（DFS 拍平、兄弟序号 ①②③、`formatRowTitle/formatRowHint` 单一文案口径）；`BranchMapViewModel` 改为输出 `rows`，删掉画布布局与末端节点追加；`BranchMapNode` 重写为缩进行（缩进 + 拐角线 + 圆点，**无方框**；主路径用强调色画成脊线，非主路径**不再整体降透明度**）；`BranchMapPage` 删画布/缩放/平移/缩放控件改 `List`，新增图例，底部栏改用行文案（去掉硬编码角色名）。**删除死代码**：`utils/BranchTreeLayout.ets`、`models/BranchMapNodeLayout.ets`（全仓 0 引用，已 Grep 取证，含单测）。编译 **BUILD SUCCESSFUL** + 单测 **0 失败**；新增踩坑 P-26（派生值命名必同名）/ P-27（降透明度 = 看不清）。**设备侧未验证**（按新规则，用户未要求"自动测试"） |
| 2026-09-27 | **聊天页 UI 优化（4 项，方案经可视化对比拍板）** | ① **停止键**：高饱和红色实心圆 + ✕ → **低对比描边圆钮 + ■**（`textSecondary` 图标 + `divider` 描边，按用户要求不用红色）；发送↔停止切换加 180ms 形变过渡（`TransitionEffect.OPACITY + scale`）。② **新消息入场动画**：`ChatMessageList` 项加 `.transition`（淡入 + 上移 12vp / 220ms），页面侧 `messageEntranceEnabled` 门控（**首批加载不 animate、第二批起启用**）。③ **对话设置面板**改**分组卡片**：6 分区（模型与预设/分支/对话/身份/会话/危险区）+ 卡内 1px 分隔线；行高 52→44；**标签不再写死 56 宽**（修复"记忆模式""本对话称呼"折行），标签精简 ≤6 字 + `maxLines(1)`；`清空对话` 独立成危险区。④ **代写候选浮层**由独立描边卡片**移入输入胶囊内部**（同底同圆角无缝），加 1/2/3 序号与「点击填入」；`maxLines(3)` 硬裁 → **列表内滚动**（上限 200vp）；`ChatPage` 侧旧浮层与 import 一并摘除。改动文件：`ChatInputArea` / `ImpersonateCandidatesPanel` / `ChatMessageList` / `ChatMoreMenuSheet` / `ChatPage`。编译 **BUILD SUCCESSFUL** + 单测 **0 失败**。**设备验证范围说明（重要）**：停止键 / 设置面板 / 代写浮层三项已用真机截图确认；随后按用户指示**停止设备测试**（新规则：未明确要求"自动测试"时只做代码层验证，见 `AGENTS.md` §3B.2 第 10 条），故**入场动效未做设备取证**（设备无 `screenrecord`）。门控实现随后由"400ms 定时器"改为"**首批分批不animate、第二批起启用**"（去掉定时器，行为更确定；仅编译验证，**未上设备 → 标记未验证**）。新增踩坑 P-24（列表 transition 需页面侧门控）/ P-25（FIT_CONTENT Sheet 加分区后首屏看不到最后一组） |
| 2026-09-27 | **设置 Tab UI 优化（应用设置 + 模型设置，方案经可视化对比拍板）** | 起因：用户反馈设置页留白多、信息密度低，"切换模型太麻烦"。**方案先经 `dynamic-ui` 渲染对比图 → AskUserQuestion 拍板**（应用设置取"分组卡片紧凑行"；主题取"四个竖条色块卡排一行"；称呼改失焦自动保存并去掉说明文字；模型切换取"列表行内联切换"）。**实现**：① `AppSettingsPage` 整页改为 4 分区（外观 / 对话 / 身份 / 存储与诊断）= `caption` 小标题 + `surface_1` 卡片 + 行高 **44** + 卡内 1px 分隔线（与 `ChatMoreMenuSheet` 同一范式）；主题由 4 张整宽竖卡改**一行 4 张竖条色块卡**（三色预览 + 名称 + 选中描边）；用户称呼改**行内输入 + 失焦/回车自动保存**（删掉说明段、独立 label 与保存按钮；`lastSavedUserName` 去重避免重复写盘与重复 toast）；发送按钮位置改**段选胶囊**；用户身份 / 市场缓存 / 诊断日志 / 清空日志各压成**单行**（值右对齐 + `surface_2` 动作胶囊）；首屏可见分区约 **2 → 约 5**。② `ModelSettingsPage`：配置列表行右侧加**内联「切换」胶囊**（当前项显示「当前」徽标），新增 `ModelSettingsViewModel.setCurrentById(id)`（不依赖 `selectedConfigId`，供列表直接切换）；**切换模型由 3 步（点行→编辑页→设为当前→返回）压到 1 步**；顺带压缩当前配置卡（provider·model 与 API Key 同行、Key 文本限宽 110）与列表/新建按钮留白。新增字符串资源 `model_settings_switch`。**删除**：`isSaving` / `ThemeOption` 死接口 / 未用 import `BusinessError`。改动文件：`AppSettingsPage` / `ModelSettingsPage` / `ModelSettingsViewModel` / `string.json`。编译 **BUILD SUCCESSFUL**（仅既有 `deprecated` 与"Function may throw"告警）+ 单测 **96 通过 / 0 失败**；新增踩坑 P-28（行内双点击区做**兄弟节点**，不嵌套 `onClick`）。**设备侧未验证**（未要求"自动测试"）；**切换模型后 LLM 实际走新配置未在设备验证** |
| 2026-09-27 | **对话设置子面板改上滑 Sheet（4 个）+ 用户身份重排** | 起因：用户反馈对话设置里点「记忆模式 / 对话称呼 / 用户身份」**直接蹦出居中弹框**很突兀，要求改成与对话设置一致的向上弹出；并反馈「切换用户身份」卡片很丑。**方案经 `dynamic-ui` 渲染对比图 → AskUserQuestion 拍板**（身份面板取"上下分段切换"；「新建章节」一并改）。**实现**：① 四个居中模态框（`memoryModeDialog` 88% 宽 / `userNameOverrideDialog` 80% 宽 / `personaPickerSheet` 85% 宽 / `chapterGreetingPickerDialog` 88% 宽，均为 `rgba(0,0,0,0.5)` 遮罩居中）全部改为 `bindSheet(SheetSize.FIT_CONTENT)` 上滑面板，走 `ChatMoreMenuSheet` 同一**两段式开关**（外层 `if` 挂载 0 高节点 → `onAppear` 置 `sheetShow = true` 触发上滑；关闭只置 `sheetShow = false`，由 `onDisappear` 再卸载 → 有下滑动画）；面板内容改用「标题 + 分区小标题 + `surface_2` 卡片 + 卡内 1px 分隔线 + 行高 44」范式。② **用户身份面板重排**：新增 `@State personaSheetTab` 分段（用户身份 / 性格总结），身份分段 = 一张卡（`跟随默认` + 各 Persona 行，右侧对勾表选中，`persona.description` 限 2 行）、性格总结分段 = 摘要卡 + 操作卡（`从角色卡提取` / `从对话总结` 忙碌时行尾换 `LoadingProgress`、有摘要时多一行危险色 `清除性格总结`）；去掉原「取消」按钮（改用遮罩/下拉关闭）。③ 新增 3 个可复用 `@Builder`：`sheetSectionCaption` / `sheetChoiceRow` / `sheetActionRow`（+ `personaTabItem`）；开场白预览由 `maxLines(4)` 收到 **2 行**、去掉内层 `Scroll(300)`（改由 Sheet 自身滚动）。④ **删除死代码** `closeChapterGreetingPicker()`（0 调用）。⑤ 记忆模式「自动归档」说明文案由长句精简为「未归档满 50 条或 2 万字符时,回复完成后自动生成」（去掉了"只在归档时刻一次性重建缓存前缀"这一实现细节）。改动文件：`pages/ChatPage.ets`（4,884 → 4,890 行）。编译 **BUILD SUCCESSFUL** + 单测 **96 通过 / 0 失败**；新增踩坑 P-29（bindSheet 必须两段式开关才有上滑动画）。**设备侧未验证**（未要求"自动测试"）；**四个面板的实际上滑动画与「更多菜单 → 子面板」的衔接观感需真机确认** |
| 2026-09-28 | **进入会话直接停在最新消息（不再从最开始翻到最新）** | 起因：用户反馈每次进对话都"从最开始的对话突然跳到最后的对话内容"。**定位**：消息列表是 `Scroll` + `LazyForEach`，而 `autoScrollToBottom` 只在 `messages.length > lastMessageCount` 时滚底**一次**；懒加载的内容高度是逐帧长出来的，首帧 `scrollEdge(Bottom)` 只能落在"当时已量出的底部"（≈顶部），随后内容补齐才跳到最新 → 用户就看到"先顶部、后跳最新"。**修正**（用户拍板"加加载动画"；只改 `ChatPage` 单文件，未动 `ChatMessageList`）：① 新增 `@State chatListPositioned` 门控 + 追底锁 `bottomLockActive`，定位完成前消息列表 `.opacity(0)`（**仍保持挂载**，否则不参与布局、永远算不出真实高度 → 会死锁成永不显示），期间复用现有 `loadingView()`（"加载会话中…"）占位并加 `hitTestBehavior(HitTestMode.Block)` 阻断误触（`loadingView` 也用于初始加载分支，两处都该挡触摸）；② `autoScrollToBottom` 改为「锁生效时每次 `onAreaChange` 都 `scrollEdge(Bottom)`，直到 `scroller.isAtEnd()`」，另设 **40 次重试上限** + **800ms 兜底定时器**（`aboutToDisappear` 清理，符合定时器清理约束）；③ 只在**整列表被替换**时定位（首条消息 id 变化，或页面首次加载且尚未显示过），空会话发第一条消息不触发（否则会闪一下加载动画）。编译 **BUILD SUCCESSFUL** + 单测 **96 通过 / 0 失败**。踩坑单独成节：`PITFALLS.md` 新增 **§2b 聊天消息列表滚动** + **P-80**。**设备侧观感未验证**（未要求"自动测试"）——需真机确认：进长对话是否直接停在最新、无翻页残留、定位耗时（应 1~3 帧，兜底上限 800ms）是否可接受。**另发现（未修，见 §4）**：`userScrolledUp` 全仓无置 true 之处，"回到底部"按钮实际永不出现 |
| 2026-09-28 | **里程碑 tag 补齐（不改写历史）** | 起因：用户问"master 上大量细小提交是否正常"。**结论**：正常且是刻意的——`AGENTS.md` 的"一次一操作 → 编译验证 → 提交，失败即回滚"要求细粒度提交，`CURRENT.md` 直接用短 hash 当回滚锚点、且"不建 changelog"依赖 `git log --grep`；实测 212 提交 / 中位数 **206 行** / 58 条 >500 行，细碎集中在 09-27 的 84 条（47 条是 P2/P3 重构接缝）。**决定**：不 rebase/squash（会让文档里的短 hash 锚点全部失效），改用 tag 导航。新增 4 个**注释 tag**：`p1-complete`@`7983170` · `p2-complete`@`36d809c` · `p3-complete`@`92e13c4` · `smoke-p2p3-passed`@`30bba43`，锚点规则统一为"该批次**最后一次代码提交**"（故含批次末尾的校验修复：P2 的 `async` 回归、P3-3① 快照归属）；清单记入 **§1**（唯一出处）。**另指出一处待收紧**：23 条 `docs(handover)` 全在 09-27 且基本是"代码接缝提交之后紧跟一条补文档"，违反 `AGENTS.md` §10 第 8 条"同一次提交内更新"，是当天提交数翻倍主因。tag 与 master 已于 2026-09-28 推送至 `origin`（tag：`refactor-baseline` + 4 个新里程碑） |
| 2026-09-28 | **设置 Tab 版式收紧（方案经可视化对比拍板）** | 起因：用户反馈设置 Tab"太空旷"，要求调小间距、更和谐、可加简单图标。**方案先经 dynamic-ui 渲染前后对比图 → AskUserQuestion 拍板**（取"分组卡片 + 图标行"；图标中性灰、放**行尾**且**只留图标不放箭头**；去掉顶栏下引导句）。**实现**（pages/tabs/SettingsRootView.ets 重写）：① 由"6 张整宽卡（内边距 16 + 卡间距 8）"改为"**同组共用一张卡** + 卡内行高 **56** + 1px 分隔线（左右缩进 12）"，卡片左右各缩进 16；② 每行 = 标题(主色 medium) + 小字说明(次要色 caption) + **行尾入口图标**（18，tertiary 色，兼作视觉锚点）；新增页内 @Builder entryRow；③ 图标全部取自**仓内已编译通过**的 sys.symbol.*（key / book / textformat / exposure（与设置 Tab 图标一致）/ arrow_clockwise / speaker_wave_2）——**不猜未验证的符号名**，避免 $r('sys.symbol.*') 资源不存在导致编译失败；④ components/ui/AppSectionHeader.ets 顶距 **24 → 16**（与其自身注释"顶 pad16"原本口径一致）；⑤ **删除死代码**：components/ui/AppEntryCard.ets（全仓 0 引用，已 Grep 取证）与已无引用的字符串资源 tab_settings_desc。编译 **BUILD SUCCESSFUL**（仅既有 6 处 pushUrl deprecated 告警）+ 单测 **96 通过 / 0 失败**。**设备侧观感未验证**（未要求"自动测试"） |
