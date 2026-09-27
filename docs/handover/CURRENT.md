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
- [ ] **P2-2 `ChatOneShotGenerator`**（低）：impersonate / persona 提取 / autoContinue 及其 parser（~L1456-1968）
- [ ] **P2-3 `ChatStatusService`**（中）：角色状态簇（~L2736-3538）
- [ ] **P2-4 `ChatSwipeController`**（中高）：~L5468-5858
- [ ] **P2-5 Branch 门面**（中）：先搬纯判定与查询（~L5865-6160）
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

## 3. 环境事实（防重复踩坑）

- SDK：`D:\DevEco_studio\DevEco Studio\sdk`（6.1.1；`D:\DevEco_studio\Sdk` 是旧版 6.0.2，会报 00303312）
- 编译命令见 `AGENTS.md` §5；同一命令最多 3 次；单次约 35~45s
- 签名配置在 `build-profile.json5`（绝对路径指向 `C:\Users\35595\.ohos\config\...`，本机有效）
- 无 hvigorw 包装脚本，统一用全局 CLI；系统 node v24 可用
- 测试：`entry/src/test/` 有 11 个单测文件（如 frontend_interaction、prompt_segment_order、lorebook_sticky_service）；未纳入日常验证流程，主要验证手段仍是编译 + 真机冒烟

## 4. 待用户确认 / 关注

- **真机冒烟验证**：P1-2 主链路改动 + P1-3 前三个组件已通过真机冒烟（用户确认无问题）；`ChatAppearancePanel`（显示设置：滑块/配色模式/自定义色/色盘/恢复默认）与 `ChatStatusWorldPanel`（世界书条目启停/展开、AI 入口与两种模式、变更预览应用与取消、刷新激活）待真机冒烟。若发现问题：告知功能名即可，按 commit 精确回滚（P1-2：a0c3a11 / 9456dc2 / a4511ac / c78caf5 / 0cd508f）
- **待真机冒烟（当前有效两项）**：
  1. 角色卡前端界面（commit `d44797b`，P1-5）：全屏页（FrontendCardPage）与聊天页面板两种入口打开；页面内 getState/setState/getCharacter/getMessages/send/appendInteraction/close 均可用；面板收起/展开无白屏
  2. 对话记录 Tab 分组弹窗（commit `8ff588e` + `a1d2a5d`，P1-4 ①②）：分组新建（空名拒绝）/重命名/删除（仅解除关联）/移动会话（含"不分组"）/"新建文件夹并移入"（空名拒绝、操作中置灰）/左滑"分组"入口/折叠状态重启后保持
  - 回滚锚点：`d44797b`（CardFrontendWeb）/ `a1d2a5d`（Tab 弹窗迁移，依赖 `8ff588e` 与 SessionGroupDialogs，回滚需成组）
- **P2-1 待冒烟（"搬运不改行为"，以后两项为主）**：
  1. 请求计划（`702d3db`）：顶栏预算指示器数值正常；长会话发送时触发历史裁剪后回复仍完整；上下文占用统计正常
  2. 请求构建与注入（`8e0ad06`，**主链路，重点**）：发送/流式/停止正常；角色绑定世界书注入（日志 tag 现为 `ChatRequestBuilder`）；按需记忆（OnDemandPinned）与粘滞世界书（StickyOnDemand）注入与尾部"当前仍生效的设定"提醒正常；重生成/代写（候选生成走 excludeMessageId 路径）正常
  - 回滚锚点：`64b0c4e` / `702d3db` / `8e0ad06`（三者为独立 commit，但 1c 依赖 1a 的 ChatTextContract，回滚需成组）
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