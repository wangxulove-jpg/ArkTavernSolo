# CURRENT — 当前状态与下一步

> 最后更新：2026-09-27 · **每次会话结束前必须更新本文件**（纪律见 `AGENTS.md` §10）

## 1. 现在在哪

- **基线**：tag `refactor-baseline` @ `8dbd9df`（2026-09-27 建立，工作区干净）
- **本日完成**：
  1. 全项目只读审计（286 文件 / 112,801 行；结论：分层主干成立，痛点集中于巨型文件与重复实现）→ [审计报告](./2026-09-27-audit-and-roadmap.md)
  2. 交接文档体系重建（根 `AGENTS.md` + `docs/handover/`）
  3. 清理：删除 `tools/`（card-studio）、`启动制卡软件.bat`、根 `screenshots/`、`.tools/uitree`；旧文档归档至 `docs/handover/archive/`
- **本次未修改任何 .ets 代码**（审计为只读）

## 2. 下一步（重构 P1 批次）

> 完整路线图见 [审计报告 §6](./2026-09-27-audit-and-roadmap.md)
> 纪律：一次一操作 → 编译验证（最多 3 次）→ 提交；任一步失败立即回滚

- [x] **P1-1 死代码清理**（2026-09-27 完成）：删除 `findLastAssistantIndex`（ChatService）；删除 `getEffectiveMemory` / `getInjectionContext` 及 `MemoryInjectionContext` 类型（MemoryService）；`trySummarize` 复核为 rolling 回退路径（被 `tryGenerateMultiLayerMemory` 调用）保留；关联注释 2 处同步修正；编译 BUILD SUCCESSFUL
- [x] **P1-2 ChatService 重复逻辑消除**（2026-09-27 完成）：Swipe 三方法 → `doActivateCandidate`；失败收尾 4 处 → `persistFinalAndCleanup`；锚点插入两处 → `applyAnchoredInserts`；状态一次性请求两处 → `runStatusOneShotStream`；每步编译通过
- [x] **P1-3 ChatPage 组件抽取**（2026-09-27 完成，逐个纯搬运不改行为）：`ChatForkPicker` / `ChatMessageList` / `ChatInputArea` / `ChatAppearancePanel`（appearanceSheetContent + colorSwatchRow + fontColorPreviewArea + 7 个私有辅助方法，683 行搬出；8 个语义色经 @Prop、色盘请求经 `ColorPickerRequest` 上抛，全屏色盘覆盖层留在页面）/ `ChatStatusWorldPanel`（statusWorldSheetContent + 世界书/AI 预览族 10 个 @Builder，465 行搬出；AI 区/输入/面板可见性经 @Link，AI 模式切换与条目启停回调上抛，展开态降为组件内 @State）。**ChatPage 5949 → 4898 行（-1051）**；组件均不持有 VM/服务（`ChatStatusWorldPanel` 仅类型引用 `LorebookPanelBook/Data` 自 ChatViewModel）
- [x] **P1-5 组件越层修复**（2026-09-27 完成，两个组件，各一次编译 + 提交）：
  1. `CardFrontendWeb` + `CardFrontendBridge` → bridge 层新增 **`FrontendCardHost` 契约**（`CardFrontendBridge.ets` 内导出）；组件/Bridge 不再 import viewmodels，ChatViewModel 结构上满足契约（无需适配器），页面直接传 `host: this.viewModel`（commit `d44797b`）
  2. `ChatSessionListPanel` 去掉 `ChatViewModel` / `AppServices` 依赖 → 7 个 @Prop 数据 + 5 个查询回调（isCurrentSession / getSessionTitle / getSessionSubtitle / getChapterLabel / getWorldName）+ 11 个动作/持久化回调；折叠状态持久化上提到 ChatPage（key 与读写逻辑不变，分组操作 Toast 时长/错误消息来源保持旧行为）（commit `726efec`）
  - 组件层现状：仅剩 `ChatStatusWorldPanel` 对 `LorebookPanelBook/Data` 的**类型引用**（不持有 VM 实例，暂留）；旧 `@ObjectLink` 赋值告警随 P1-5 消失
- [ ] **P1-4 会话列表去重**（下一步）：`ChatSessionRootView` ↔ `ChatSessionListPanel` 近乎全量重复。**建议分相执行**：① 抽共享纯函数/常量（折叠 key、parse/join、toggle——两侧现各自实现）与 4 个分组弹窗（≈380 行重复）；② 再定「单组件 + 布局模式参数」的合并方向——两侧数据源不同（`Chat[]` vs `ChatSessionListItem[]`），需先定数据源归属与拖拽/归档等能力的归属，属设计决策，动工前与用户对齐
- [x] **P1-6 不可变性修复**（2026-09-27 完成）：`deleteMessage` / `editNarratorMessage` / `editAssistantMessage` 改为新数组整体替换；复核后**未补 `emitMessages`**——刷新契约由 ChatViewModel 承担（`[...getMessages()]` + `onMessagesUpdate`），补发会改变通知行为、超范围

## 3. 环境事实（防重复踩坑）

- SDK：`D:\DevEco_studio\DevEco Studio\sdk`（6.1.1；`D:\DevEco_studio\Sdk` 是旧版 6.0.2，会报 00303312）
- 编译命令见 `AGENTS.md` §5；同一命令最多 3 次；单次约 35~45s
- 签名配置在 `build-profile.json5`（绝对路径指向 `C:\Users\35595\.ohos\config\...`，本机有效）
- 无 hvigorw 包装脚本，统一用全局 CLI；系统 node v24 可用
- 测试：`entry/src/test/` 有 11 个单测文件（如 frontend_interaction、prompt_segment_order、lorebook_sticky_service）；未纳入日常验证流程，主要验证手段仍是编译 + 真机冒烟

## 4. 待用户确认 / 关注

- **真机冒烟验证**：P1-2 主链路改动 + P1-3 前三个组件已通过真机冒烟（用户确认无问题）；`ChatAppearancePanel`（显示设置：滑块/配色模式/自定义色/色盘/恢复默认）与 `ChatStatusWorldPanel`（世界书条目启停/展开、AI 入口与两种模式、变更预览应用与取消、刷新激活）待真机冒烟。若发现问题：告知功能名即可，按 commit 精确回滚（P1-2：a0c3a11 / 9456dc2 / a4511ac / c78caf5 / 0cd508f）
- **P1-5 两项待真机冒烟**（编译已过，行为按"不改行为"标准改造）：
  1. 角色卡前端界面（commit `d44797b`）：全屏页（FrontendCardPage）与聊天页面板两种入口打开；页面内 getState/setState/getCharacter/getMessages/send/appendInteraction/close 均可用；面板收起/展开无白屏
  2. 会话列表面板（commit `726efec`）：打开/关闭（含遮罩点击）、加载态、切换会话、新建对话、删除确认（含生成中置灰）、分组新建/重命名/删除、移动会话到分组/不分组、分组折叠状态重启后保持、错误提示（sessionError 横幅）
  - 回滚锚点：`d44797b`（CardFrontendWeb）/ `726efec`（ChatSessionListPanel）；两项均隔离在各自 commit，可单独回滚
- `APK-reference/`（约 100MB 反编译参考资料）暂保留，未清理
- pages 直连具体服务（17 个文件，最重 ChatPage）属"务实偏差"，治理口径待定（见审计报告 §3）
- P2/P3/P4 的启动时机以用户节奏为准

## 5. 会话日志（追加式）

| 日期 | 会话主题 | 产出 / 决策 |
|---|---|---|
| 2026-09-27 | 审计 + 文档体系重建 | 审计报告与路线图；`AGENTS.md` + `docs/handover/` 建立；`tools/`、开发截图、旧文档归档清理；决策：交接文档进版本库 |
| 2026-09-27 | P1 批次执行 | P1-1 ✅；P1-2 重复逻辑消除 ✅；P1-6 不可变性 ✅；**真机冒烟通过（用户确认无问题）**；P1-3：ChatForkPicker ✅ / ChatMessageList ✅ / ChatInputArea ✅ / ChatAppearancePanel ✅ / ChatStatusWorldPanel ✅（**P1-3 收官，ChatPage 5949→4898 行**）；每步编译通过 |
| 2026-09-27 | P1-5 组件越层修复 | `CardFrontendWeb`/`CardFrontendBridge` 改宿主契约 `FrontendCardHost` ✅（d44797b）；`ChatSessionListPanel` 去 `ChatViewModel`/`AppServices`，改 @Prop + 回调、折叠持久化上提 ChatPage ✅（726efec）；组件层仅剩 `ChatStatusWorldPanel` 一处类型引用；每步编译通过；P1-4 已写分相建议（待对齐合并方向） |