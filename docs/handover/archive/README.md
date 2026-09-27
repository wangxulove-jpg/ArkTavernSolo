# [ARCHIVED] 过期文档归档区

> 归档时间：2026-09-27。本目录所有内容均**已被 `docs/handover/` 新体系取代**，属历史记录。

**重要：本目录内容不作为现状依据。**
其中的文件行数、数据库版本、开发进度、架构结论均为记录时点的旧数据（例：旧文档记录 ChatService 5462 行 / DB v38，实际已到 6770 行 / v47）。需要引用时，请先与代码交叉验证。

| 归档内容 | 原位置 | 说明 |
|---|---|---|
| `agent/` | `docs/AGENT/` | 旧 Agent 导航套件（00~10 系列 + AGENT_ENTRY + archify 交互图） |
| `HANDOVER.md` | `docs/` | 旧版通用交接文档（v36 时代） |
| `AGENT.template.md` | 根 `AGENT.md` | DevEco 模板样板指南（非项目内容，原样保留供查） |
| `docs-misc/` | `docs/*.md` | 历史计划 / 分析单篇：旁白实现计划、GOAL_PHASE2A、sync-persona 交接、世界观 Roadmap、角色卡格式对比 |
| `spec/` | `spec/` | persona-system 历史 spec |
| `trae-specs/` | `.trae/specs/` | optimize-session-memory-summary 历史 spec |
| `trae-refactor-handover.md` | `.trae/documents/重构工作交接.md` | 本体系建设前的重构交接文档（入口与新体系一致） |

**可能仍有价值的历史素材**（但需以代码为准）：

- `agent/10_REFACTOR_HANDOVER.md` + `agent/_archify/chatservice-split.html`：ChatService 拆分蓝图（瘦门面 + 5 控制器），与 2026-09-27 审计结论吻合，是 P2 的参考素材
- `agent/04_FEATURE_LOCATOR.md`：全功能 → 文件定位表（写于旧版本，作起点用）
- `agent/09_KNOWN_ISSUES.md`：已知问题 / 技术债清单（部分仍有效，注意版本过期）