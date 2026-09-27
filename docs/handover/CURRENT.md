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
- [ ] **P1-3 ChatPage 组件抽取**（逐个，纯搬运不改行为）：✅ `ChatForkPicker` 已抽取（components/ChatForkPicker.ets，2026-09-27，ChatPage 减 82 行）；⬜ `ChatMessageList`（messageList, ≈160 行）/ `ChatInputArea`（inputArea, ≈160 行）/ `ChatAppearancePanel`（appearanceSheetContent, ≈360 行）/ `ChatStatusWorldPanel`（≈350 行）
- [ ] **P1-4 会话列表去重**：`ChatSessionRootView` ↔ `ChatSessionListPanel` 近乎全量重复，合并为单组件 + 布局参数
- [ ] **P1-5 组件越层修复**：`CardFrontendWeb`（L23）、`ChatSessionListPanel`（L25/L30）对 ChatViewModel / AppServices 的直接依赖
- [x] **P1-6 不可变性修复**（2026-09-27 完成）：`deleteMessage` / `editNarratorMessage` / `editAssistantMessage` 改为新数组整体替换；复核后**未补 `emitMessages`**——刷新契约由 ChatViewModel 承担（`[...getMessages()]` + `onMessagesUpdate`），补发会改变通知行为、超范围

## 3. 环境事实（防重复踩坑）

- SDK：`D:\DevEco_studio\DevEco Studio\sdk`（6.1.1；`D:\DevEco_studio\Sdk` 是旧版 6.0.2，会报 00303312）
- 编译命令见 `AGENTS.md` §5；同一命令最多 3 次；单次约 35~45s
- 签名配置在 `build-profile.json5`（绝对路径指向 `C:\Users\35595\.ohos\config\...`，本机有效）
- 无 hvigorw 包装脚本，统一用全局 CLI；系统 node v24 可用
- 测试：`entry/src/test/` 有 11 个单测文件（如 frontend_interaction、prompt_segment_order、lorebook_sticky_service）；未纳入日常验证流程，主要验证手段仍是编译 + 真机冒烟

## 4. 待用户确认 / 关注

- `APK-reference/`（约 100MB 反编译参考资料）暂保留，未清理
- pages 直连具体服务（17 个文件，最重 ChatPage）属"务实偏差"，治理口径待定（见审计报告 §3）
- P2/P3/P4 的启动时机以用户节奏为准

## 5. 会话日志（追加式）

| 日期 | 会话主题 | 产出 / 决策 |
|---|---|---|
| 2026-09-27 | 审计 + 文档体系重建 | 审计报告与路线图；`AGENTS.md` + `docs/handover/` 建立；`tools/`、开发截图、旧文档归档清理；决策：交接文档进版本库 |
| 2026-09-27 | P1 批次执行 | P1-1 死代码清理 ✅；P1-2 重复逻辑消除完成（Swipe / 失败收尾 / 锚点插入 / 状态请求）✅；P1-6 不可变性修复 ✅；每步编译通过 |