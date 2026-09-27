# 10 — 架构分析 & ChatService 重构交接

> 本文档记录一次「架构调查 + ChatService 拆分方案」会话的产出与结论，供新窗口/新 Agent 接续。
> 交接目的：让接手者快速知道**已产出哪些交付物、核心结论是什么、下一步该做什么**，无需重新调查一遍。

---

## 0. 一句话

本项目不需要整体重构；当前**高杠杆动作只有一件**：把巨石 `ChatService.ets`（**5462 行**）按职责拆成「瘦门面 + 5 个控制器」，边拆边补回归验证。

---

## 1. 本次已交付的图（可交互 HTML，含 `_archify` JSON 源规格）

| 产物 | 内容 | 校验 |
|------|------|------|
| `docs/AGENT/_archify/arktavern-solo-architecture.html` | 项目整体分层架构总览（UI/Biz/Infra/外部系统 4 层） | 9/9 showcase 通过，桌面视觉检查通过 |
| `docs/AGENT/_archify/chatservice-split.html` | ChatService 拆分蓝图（瘦门面 + 5 控制器 + 复用既有服务层） | 9/9 showcase 通过，桌面视觉检查通过 |
| `./_archify/arktavern-solo.architecture.json` | 上图①的源规格 | 已冻结 |
| `./_archify/chatservice-split.architecture.json` | 上图②的源规格 | 已冻结 |

> 用浏览器打开 `.html` 可直接交互（浅/深色、缩放、路径追踪、导出 PNG/SVG）。改图改 JSON 后用 archify 的 `validate`/`deliver` 重新生成。

---

## 2. 架构评判结论（调查所得，公允版）

**做得好的**
- 分层 + 单向依赖纪律成立：`pages → viewmodels → services → (repos|storage) → (db|network|parser)`，`viewmodels` 不碰网络/密钥层。
- 装配纪律优秀：`AppServices` 唯一组合根（静态、幂等）；`ModelService` 为 AI 请求唯一出口；`ChatService` 刻意做成 page 级非单例。
- 数据层治理认真：RDB 版本化迁移 `v1→v38`、只增不改；密钥走 Asset Store、先配后钥失败回滚。

**风险点**
- 🚨 巨石类：`ChatService` 5462 行、`ChatPage` 约 4400 行、`ChatViewModel` 状态繁多。——这是**唯一建议立即处理**的点。
- 近零三方依赖 + 网络/SSE/加密全自研：控制力强，但底层模块的边界 bug 无社区兜底。
- State V1（`@State/@Observed/@StorageProp`），长期迁移 V2 是显性成本（放最后评估）。
- 单点集中：`AppServices`/`ModelService` 改动影响面大、缺测试覆盖。

---

## 3. ChatService 拆分方案（目标蓝图 `chatservice-split.html`）

| 拆分出的模块 | 吸收的职责 |
|------|-----------|
| `ChatService`（瘦门面） | 仅保留会话生命周期、对外编排入口、dispose |
| `GenerationController` | sendMessage / autoContinue / regenerate* / doStream |
| `SessionStore` | 会话生命周期 + 上下文解析（Persona/用户名/PersonaSummary） |
| `ModifierAgent` | 代写候选 / 旁白 / 续写 / 用户性格总结 |
| `SwipeController` | Swipe 候选切换 / 生成 |
| `BranchController` | 分支 / 分叉（可吸收 `ForkChatService`） |

**底层复用既有服务**：`ModelService`（仍为 AI 唯一出口）、`PromptBuilder`、内容服务组（Character/Lorebook/Preset/Persona）、持久化组（Chat/Swipe/Branch Persistence）——**不重复造底层**。

---

## 4. 关于"是否整体重构"的明确结论

**不推荐整体重构。** 原因：
1. 已有 38 个 DB 版本 + 长期验证的隐性业务逻辑，重写把全部正确性推倒，而项目缺测试网兜底。
2. 分层边界干净，痛点只在 `ChatService` 一个局部，不需要重建全局骨架。

**若要做，按此顺序（对应既有演进原则：先稳定→再观测→再沉淀数据→最后智能）**
1. 冻结设计，为 `ChatService`/`ChatPage` 补可重复验证的聊天主路径数据集（回归基线）。
2. 按 §3 蓝图**逐个**抽控制器，每抽一个跑一次回归、可回滚 —— 目标是 `ChatService` 从 5462 行降到千行级门面，而非换框架。
3. 最后才评估 State V1→V2 等迁移（收益明确、迁移面大，需明确 ROI）。

> 具体可执行拆解未做。若续接，建议在 `spec/` 下起 `tasks.md`（先拆哪个 controller、每步回归验证点、回滚边界）。

---

## 5. 接续建议 / 待办

- [ ] （可选）把 `ChatService` 拆分方案落到 `spec/*/tasks.md` 的可执行步骤
- [ ] （可选）新增「当前巨石 → 拆分蓝图」迁移前后对照图
- [ ] 补一条最小回归基线（聊天主路径），作为后续任何重构的安全网

---

## 6. 关联既有文档

- `docs/HANDOVER.md` — 通用完整交接（本文件仅覆盖架构分析/重构主题）
- `docs/AGENT/01_ARCHITECTURE_MAP.md` — 分层架构
- `docs/AGENT/03_MODULE_INDEX.md` — 文件职责/依赖/风险
- `docs/AGENT/05_DATA_FLOW.md` — 数据流
- `docs/AGENT/AGENT_ENTRY.md` — Agent 快速入口