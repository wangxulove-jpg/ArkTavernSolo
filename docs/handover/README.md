# docs/handover — 交接文档体系

> 本目录是项目的**工作记录与交接中心**：Agent 接手、重大决策、审计报告、当前进度都在这里。
> 阅读入口：仓库根 `AGENTS.md` → 本文件 → [CURRENT.md](./CURRENT.md) → 按需深入。

## 文档地图

| 文档 | 作用 | 更新频率 |
|---|---|---|
| [CURRENT.md](./CURRENT.md) | **当前状态与下一步**（活的文档，接力先读它） | 每次会话结束前必更 |
| [2026-09-27-audit-and-roadmap.md](./2026-09-27-audit-and-roadmap.md) | 全项目审计报告 + 重构路线图（P1~P4） | 阶段性追加，不改历史 |
| [archive/](./archive/) | `[ARCHIVED]` 过期文档归档（旧 Agent 导航套件、旧 HANDOVER、历史 spec 等） | 只进不出 |

## 使用规则

1. **新会话接手**：`AGENTS.md` → `CURRENT.md` → `git log --oneline -8`
2. **做重构 / 大改动前**：读审计报告对应章节，按路线图的"一次一操作 → 编译 → 提交"执行
3. **踩坑 / 决策当场记**：写入 `CURRENT.md` 对应区域或本文档体系中的合适位置
4. **归档区（archive/）中的文档已过期**：其行数、数据库版本、进度全部不可信；需要历史细节时参考，当前事实**以代码为准**

## 相关位置

- 业务设计文档（历史方案，仍可参考，本地不进 git）：`.trae/documents/`（19 份功能方案文档）
- 用户向说明：根 `README.md`；前端卡契约：`docs/frontend-card-contract.md`、`docs/arktavern-card-extensions.md`（进 git 的契约文档，App 与制卡工具的单一事实来源）
- 架构可视化（历史，git 跟踪）：`docs/archify/`