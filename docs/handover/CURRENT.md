# CURRENT — 当前状态与下一步

> 最后更新：2026-09-27 · **每次会话结束前必须更新本文件**（纪律见 `AGENTS.md` §10）

## 1. 现在在哪

- **基线**：tag `refactor-baseline` @ `8dbd9df`（2026-09-27 建立，工作区干净）
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
  - 附带发现（**未处理，留待拍板**）：`MemoryPersistenceService.invalidateFromPosition` / `softInvalidateFromPosition` 仅被上述已删包装引用，现亦无调用者；属 persistence 层 API，删除超出本批范围，登记待议
- **P3-2 收官**：MemoryService **1,953 → 1,451 行（-502，-25.7%）**；新增 `MemoryPromptBuilder` / `WorldMemoryStore` / `MemoryTriggerPolicy`；`ChapterTriggerConfig` + `DEFAULT_CHAPTER_TRIGGER` 下沉 `models/ChatMemory.ets`；编译 BUILD SUCCESSFUL + 单测 **96/96**

### P3-3 DatabaseSchema（起点 2,879 行）

**只读测绘**：L1-502 import（仅 1 个来源 `./DatabaseConstants`，490 行常量）；L504-2577 DDL 常量 + `Vxx_SCHEMA_STATEMENTS`/`Vxx_TO_Vyy` 数组；L2579-2713 `getSchemaStatements`（44 段 if）；L2715+ `getCreateTableStatements`/`getCreateIndexStatements`；**纯数据 + 纯函数，无 ArkData 依赖**（可 host 侧验证）

- [x] **① V38→39 / V39→40 版本映射疑点 — 只读核查结论** ✅（**未改任何代码**）：
  - **迁移并不缺失**：38→39 / 39→40 的迁移**存在且完整**于 `database/DatabaseMigration.ets`——`V38ToV39Migration`（cleans 存量超大 `extensions_json`，数据迁移）、`V39ToV40Migration`（`ALTER characters` 补 Tavern V3 独有列，`V39_TO_V40_DDL_STATEMENTS` L1311）、`V40ToV41Migration`（`ALTER lorebooks` 补 activation_mode/injection_budget）。**版本连续、无 DROP、只增不改** ✅
  - **疑点确认为「schema 快照映射不准」而非「迁移缺失」**：[DatabaseSchema.ets L2694](`getSchemaStatements`) 将 `39 / 40 / 41 / 42` 四个版本**合并返回 `V42_SCHEMA_STATEMENTS`**；而语义上 `getSchemaStatements(v)` 应返回「到 v 为止的完整建库语句」（见 v1/v2 分支：v2 = v1 + v1→v2）。对 v39/v40/v41 返回 v42 快照，会**多出 v42 才引入的 `chats.world_id` / `chat_memories.world_id` 两列与两个 world 索引**；且 `V39_SCHEMA_STATEMENTS` / `V40_SCHEMA_STATEMENTS` **从未定义**（仅定义了 `V41_SCHEMA_STATEMENTS = [...V38_SCHEMA_STATEMENTS]`），疑为 39–42 分支被"就便"归并
  - **实际影响 = 0（潜伏不一致，非活跃缺陷）**：全仓 `getSchemaStatements` **仅 1 处调用**（`DbHelper.createFreshSchema` → `getSchemaStatements(DATABASE_VERSION)`，即 **47**）；无任何调用方/测试传 39/40/41；故该分支**生产不可达**
  - **建议（等拍板，不擅自改）**：改为 `39/40/41 → V41_SCHEMA_STATEMENTS`、`42 → V42_SCHEMA_STATEMENTS`（或补 `V39/V40_SCHEMA_STATEMENTS`）。因当前不可达，**本批次不改**；如需修，另开单独 commit 并做逐版 DDL 对比
- [x] **② DDL 常量按域拆文件** ✅：新增 `entry/src/main/ets/database/schema/` 7 个域文件（共 **1,744 行**）：`SchemaCore`（227）/ `SchemaLorebook`（114）/ `SchemaPresets`（66）/ `SchemaSwipe`（58）/ `SchemaBranch`（85）/ `SchemaMemory`（106）/ `SchemaWorld`（1,088，废弃沙盒表集中于此）
  - **搬出内容**：全部 **188 个非导出 DDL 常量**（CREATE_*/ALTER_*），逐字搬出后统一补 `export`（跨模块引用所需，等价于 P2 的 private→public 可见性调整，**DDL 文本零改动**）
  - **保留在 DatabaseSchema**：全部 `export` 常量（V1..V47 版本数组、别名导出）+ 3 个函数 → **2,879 → 1,516 行（-1,363，-47.3%）**；import 块由 490 行（≈489 名）缩至 **57 名**
  - 分类规则：`CREATE_CHAT_MEMORIES_*`/`INDEX_CHATS_WORLD_ID`→Memory；characters/chats/messages 及 ALTER→Core；lorebook/pins/sticky→Lorebook；prompts/personas→Presets；swipe→Swipe；branch→Branch；`CREATE_/INDEX_WORLD*`+`GROUP*`+`ALTER_WORLD*`→World；**分类后无 UNCLASSIFIED**；域间**零交叉依赖**（无循环 import 风险）
  - 校验：Node 验证夹具（临时，仓外）解析 `getSchemaStatements(1..47)` + `getCreateTableStatements()` + `getCreateIndexStatements()` 全量字符串，**改造前后逐字节 DIFF = 0**（v1=7 / v38=168 / v42=171 / v47=176 / 表 37 / 索引 119）；`DatabaseMigration.ets` 仅从 DatabaseSchema 取 V* 数组（导出未动）→ 无破坏
  - 编译 BUILD SUCCESSFUL；单测 **96/96**
- [ ] **③ `getSchemaStatements` 逐版 if 链 → Registry（逐版输出 100% 一致）**

## 3. 环境事实（防重复踩坑）

- SDK：`D:\DevEco_studio\DevEco Studio\sdk`（6.1.1；`D:\DevEco_studio\Sdk` 是旧版 6.0.2，会报 00303312）
- 编译命令见 `AGENTS.md` §5；同一命令最多 3 次；单次约 35~45s
- 签名配置在 `build-profile.json5`（绝对路径指向 `C:\Users\35595\.ohos\config\...`，本机有效）
- 无 hvigorw 包装脚本，统一用全局 CLI；系统 node v24 可用
- 测试：`entry/src/test/` 有 11 个单测文件 / 16 个测试类 / 96 用例（如 frontend_interaction、prompt_segment_order、lorebook_sticky_service）；**已可用 `hvigorw test` 本机执行**（2026-09-27 首跑全通过；结果落盘 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`）；日常验证仍以编译 + 真机冒烟为主

## 4. 待用户确认 / 关注

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
- **本轮附加验证（2026-09-27，host 侧）**：本地单元测试套件已在本机执行通过 —— `hvigorw test`（`entry/src/test`，16 个测试类 / **96 用例全部 Success，0 失败 0 忽略**；结果落盘 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`）。覆盖：ChatTextContract 纯函数（前端交互缓冲 / 粘滞提醒文本 / 状态段拆分 —— P2-1、P2-3 搬运过的纯函数）、PromptSegment 段序、状态 schema 解析、世界书激活与粘滞服务、ChapterMemoryIndexer、MemoryLoadRefService、ContextBudgetEstimator、Lorebook 模式、Gemini 模型过滤、前端契约 v2；**不含**会话 / Swipe / 分支 / 流式簇（依赖 DB/网络，只能真机冒烟）。命令：`hvigorw test --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon`
- **API 面等价校验（2026-09-27，机械对比）**：以 tag `refactor-baseline` 为基准，抽取 ChatService 全部非 private 声明（方法 / 访问器）逐行对比 → 修复后 **89 项签名与基线完全一致**（含 `async` 修饰符）。过程中发现并修复 1 处搬运残留：`refreshLorebookPinNow` 的 `async` 修饰符在 P2-7 薄包装时丢失（调用侧行为等价，但签名不同）→ 已恢复（commit `36d809c`，编译通过）。新模块分层抽查：`ChatSessionService` / `ChatMessageSender` / `ChatUserIdentityService` 无 viewmodels / pages / components 越层导入
- **已作废冒烟项**（相关代码已删除）：会话列表面板（`726efec` / `958b43b` 的面板侧）——面板与 ChatViewModel 会话列表 API 已随 P1-4 ③ 删除，不必再测
- **需回归确认**（删除相影响面）：聊天页正常打开/发送/停止/重生成；更多菜单"新建章节(切换开场白)"创建后提示与当前会话不变；从"对话记录"Tab 点会话进入聊天页仍能切到指定会话（`pendingChatId` → `selectSession` 路径未动，但 `refreshSessions` 已移除，建议确认切换后列表/消息正常）
- `APK-reference/`（约 100MB 反编译参考资料）暂保留，未清理
- pages 直连具体服务（17 个文件，最重 ChatPage）属"务实偏差"，治理口径待定（见审计报告 §3）
- P2/P3/P4 的启动时机以用户节奏为准

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
| 2026-09-27 | P2 验证（API 面等价） | ChatService 公开 API 面与基线 `refactor-baseline` 机械对比：**89 项签名完全一致**；发现并修复 1 处搬运残留——`refreshLorebookPinNow` 丢 `async` 修饰符（`36d809c`，编译通过）；新模块（`ChatSessionService`/`ChatMessageSender`/`ChatUserIdentityService`）无越层导入 |