# ArkTavernSolo 重构 · 工作交接文档

> 创建时间：2026-09-27
> 来源：旧工作区会话（d:\WorkSpace\6ab8873b511302291a4f713e，项目已移至当前位置）
> 用途：**新工作区（D:\ArkProject）的 AI 会话请先读本文档**，即可无缝接上重构工作
> 启动语：对 AI 说「读 .trae/documents/重构工作交接.md，继续重构，先做审计」

---

## 一、项目现状

- **项目**：ArkTavernSolo —— 原生 HarmonyOS NEXT AI 角色扮演聊天客户端（SillyTavern 思路），ArkTS / ArkUI，API 24 / SDK 6.1.1
- **当前位置**：`D:\ArkProject\ArkTavernSolo`（工作副本，**后续一切修改都在这里**）
- **原始项目**：`D:\DevEco_studio\ArkTavernSolo`（**只读参考，不要修改**）
- **复制方式**：从原项目复制，剔除了可重建产物：`build`、`node_modules`、`oh_modules`、`.deveco` / `.cache` / `.appanalyzer`、`entry/.test`、`tools/card-studio/{node_modules,release,out}`。如需恢复，从原项目拷回或重新安装（`npm install` / hvigor 自动解析）
- **禁改范围**：`tools/` 目录（Electron 制卡软件 card-studio）——用户明确要求保留、不修改
- 本次交接文档位于 `.trae/`（被 .gitignore），不进版本库，属本地工作文档

## 二、Git 基线（重构安全网）

- 副本含完整历史（130+ 提交，从原仓库继承）
- 基线 tag：`refactor-baseline`，HEAD：`8dbd9df`，当前工作区干净
- 重构纪律：**一次一个操作 → 编译验证 → 提交**；失败立即 `git checkout -- <file>` 回滚，不带病继续
- 提交信息风格沿用仓库习惯：`feat/fix/refactor/chore(scope): 中文描述`
- 远端 `origin` 是用户自己的 GitHub 仓库 —— **未经用户确认不要 push**

## 三、编译验证命令（已实测通过，2026-09-27）

```powershell
$env:DEVECO_SDK_HOME = "D:\DevEco_studio\DevEco Studio\sdk"   # 必须用 IDE 内置 SDK（6.1.1）；D:\DevEco_studio\Sdk 是旧版 6.0.2，会报 00303312 错误
& "D:\DevEco_studio\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

- 通过标准：输出 `hvigor BUILD SUCCESSFUL`（约 35~45 秒），产物在 `entry\build\default\outputs\default\entry-default-signed.hap`
- 既有警告（非阻塞、非本次引入）：`showToast/back` deprecated、若干 "Function may throw exceptions"、`ChatPage.ets:1193` 一处 `@ObjectLink` 赋值警告（重构时可顺手处理）
- 编译命令最多运行 3 次（用户约定）

## 四、重构目标与现状盘点

**目标态**（README 声明的分层，以它为准）：

```
pages → viewmodels → services → repositories → database
components / models 不访问网络、数据库，无业务副作用
```

**重灾区（当前行数）**：

| 文件 | 行数 |
|---|---|
| entry/src/main/ets/services/ChatService.ets | 6370 |
| entry/src/main/ets/pages/ChatPage.ets | 5848 |
| entry/src/main/ets/database/DatabaseSchema.ets | 2673 |
| entry/src/main/ets/pages/tabs/ChatSessionRootView.ets | 2615 |
| entry/src/main/ets/services/MemoryService.ets | 1874 |
| entry/src/main/ets/viewmodels/ChatViewModel.ets | 1793 |

（全项目 286 个 .ets 源文件，待全量扫描）

## 五、下一步流程（用户已确认）

1. **审计（只读，不动代码）**：全项目结构扫描（分层依赖方向、文件规模分布、重复代码、坏味道清单），再深挖 ChatService / ChatPage 两个巨无霸
2. **产出审计报告 + 重构路线图** → 交用户确认
3. **分步执行**：每步独立提交、编译验证、可回滚
4. 用户偏好约束：增量验证、一次一操作、不造轮子、不过度设计、先方案后动手

## 六、可用 Skill（用户级安装，新工作区同样生效）

- **`refactor`**（本次已安装：`c:\Users\35595\.trae-cn\skills\refactor\`）—— Fowler 重构目录 + 6 大坏味道家族检测 + 一次一操作纪律；触发词：重构/clean up/extract/MVVM 等
- `ponytail-audit` / `ponytail-review`：过度设计审计（找出该删该简化的东西）
- `karpathy-guidelines`：编码行为准则（写/改/重构时适用）
- `arkts-grammar-standards`（写 .ets 前必读）/ `arkts-syntax-assistant` / `arkts-error-fixes`：ArkTS 语法与修错
- `grill-me`：方案拷问；`archify`：架构图可视化

## 七、重要上下文素材

- `.trae/documents/`：20 份历史方案文档（分级记忆、缓存命中优化、UI 改版、前端卡等）——理解业务背景的快捷入口（注意：都是现状描述，改动前先确认与代码一致）
- `.trae/specs/optimize-session-memory-summary/`：历史 spec + checklist
- `README.md` / `AGENT.md`：项目说明 / 模板指南
- 关键领域概念：角色卡 V2/V3、对话分支、世界书（Lorebook）、长期记忆、Prompt 预设与宏、TTS、WebDAV 同步

## 八、已知环境事实（避免重复踩坑）

- DevEco Studio 安装在 `D:\DevEco_studio\DevEco Studio`（内置 hvigor + node + SDK 6.1.1）
- 系统 node v24.18.0 可用；git 2.45.1，已配置用户身份（wangxu）
- 项目无 hvigorw 包装脚本，统一用上面第三节的全局 CLI 命令
- 签名配置在 `build-profile.json5`，指向 `C:\Users\35595\.ohos\config\...`（绝对路径，搬移后依然有效）