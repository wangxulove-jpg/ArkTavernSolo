# 架构分析与解耦计划

> 本文档记录 ArkTavernSolo 项目一次系统性的架构体检结果与解耦行动方案。
> 配套可视化交互图:`docs/archify/arktavern_architecture.html`(浏览器打开,支持主题切换 / 焦点聚焦 / 搜索 / 导出图片)。

---

## 1. 目标

- 判断当前分层架构是否合理
- 找出“太大、塞了太多职责”的文件(上帝文件)
- 给出按优先级拆解(解耦)的落地计划
- 制定拆解过程的守则,避免拆坏功能

## 2. 现状体检(2026-09,共约 11.5 万行 ArkTS)

按层统计:

| 分层 | 文件数 | 总行数 | 平均行数 | 说明 |
|---|---|---|---|---|
| pages 页面层 | 33 | 28,912 | 876 | 页面过肥,重度页面偏高 |
| services 业务服务 | 48 | 27,671 | 576 | 大量代码集中在少数服务里 |
| viewmodels 状态编排 | 21 | 9,878 | 470 | 基本合理 |
| repositories 数据访问 | 20 | 7,617 | 381 | 合理 |
| models 共享模型 | 55 | 7,044 | 128 | 细粒度,合理 |
| parser 解析器 | 14 | 6,436 | 460 | 合理偏大 |
| database 持久化 | 4 | 5,213 | 1,303 | 文件过少、单个过大 |
| components 复用 UI | 26 | 4,775 | 184 | 合理 |
| network 模型网络 | 15 | 4,381 | 292 | 合理 |
| storage / utils / theme | 40 | 5,109 | 128 | 合理 |

### 上帝文件清单(解耦热点)

| 文件 | 行数 | 症状 |
|---|---|---|
| `services/ChatService.ets` | **5,790** | 聊天编排、角色状态、世界书、分支、上下文预算等混于一处 |
| `pages/ChatPage.ets` | **5,142** | 顶栏、消息列表、世界书面板、AI 操作、外观/背景设置等全部内聚 |
| `database/DatabaseSchema.ets` | 2,620 | 全量建表挤在一个文件 |
| `pages/tabs/ChatSessionRootView.ets` | 2,615 | Tab 根视图过肥 |
| `services/MemoryService.ets` | 1,840 | 记忆领域职责偏多 |
| `pages/tabs/CharacterRootView.ets` | 1,627 | Tab 根视图过肥 |
| `viewmodels/ChatViewModel.ets` | 1,671 | 状态编排集中度偏高 |

## 3. 架构判断:方向正确,粒度过粗

- 依赖主线 `pages → viewModels → services → repositories → database` 方向清晰,没有反向与环
- `models / parser / network / storage` 是无环的支撑层,职责单一
- 结论:**分层模式是合理的,不需要推翻重来**;问题出在少数文件的“单一职责”被突破(上帝文件),通过拆文件即可解决

## 4. 解耦计划(按优先级)

| 步骤 | 对象 | 拆法 | 预估目标 |
|---|---|---|---|
| ① | `ChatService.ets` | 按领域拆: Chat 编排 / 角色状态(Status) / 世界书(Lorebook) / 分支(Branch) / 上下文预算(Context) / 记忆(Memory) | 每文件 ≤ 800 行 |
| ② | `ChatPage.ets` | 各 `@Builder` 面板抽为 `components/` 独立组件文件;纯逻辑函数外移至 service/utility;页面只留壳 | 页面 ≤ ~1,200 行 |
| ③ | `DatabaseSchema.ets` | 按业务域分组建表(chat / character / lorebook / memory / persona) | 拆分为多文件或模块常量 |
| ④ | `ChatSessionRootView` / `CharacterRootView` | 面板下沉为子组件,根视图只留 Tab 骨架 | 每文件 ≤ 1,000 行 |
| ⑤ | `ChatViewModel.ets` / `MemoryService.ets` | 跟随 ①② 拆出的领域同步下沉状态与逻辑 | 靠拢 800 行以内 |

### 目标目录形态(示意)

```
services/
  ChatService.ets            ← 只负责会话编排 + 消息流
  ChatStatusService.ets      ← 状态字段生成/合并/锁定
  LorebookService.ets        ← 世界书激活
  ChatBranchService.ets      ← 分支/续写
  ChatContextService.ets     ← 上下文预算
components/chat/
  ChatWorldbookPanel.ets     ← 从 ChatPage 抽出
  ChatAIActionPanel.ets
  ChatAppearancePanel.ets
```

## 5. 实施守则(防拆坏)

1. **纯搬移 + 改名,不改行为**:拆解只改变文件归属,不顺手修 bug、不调整逻辑
2. **每拆一步立即构建**:ArkTS 对搬移后的 import/导出非常敏感,构建通过再进入下一步
3. **保持 import 无环**:领域服务只依赖比自己低层的模块(models/parser/network/storage/utils)
4. **独立提交分批做**:每次拆解一个文件、一次提交,便于回归与回滚
5. **目标阈值**:单文件 ≤ ~800 行为主,页面 ≤ ~1,200 行为辅

## 6. 相关产物

- 可视化架构图: `docs/archify/arktavern_architecture.html`
- 图数据源: `docs/archify/arktavern-current-architecture.json`
- 本轮提交: `0c06b51`(角色状态侧边栏功能 + 角色列表网格优化 + 本分析)