# ArkTavern Card Studio

桌面制卡软件（Electron + Vue3）：把 SillyTavern 角色卡适配为 ArkTavern App 卡片，并提供完整卡片编辑器。

## 功能

- **卡片 IO**：导入/导出 SillyTavern PNG 卡（`chara`/`ccv3` tEXt chunk）与 JSON 卡（V1/V2/V3/ArkTavern 格式自动归一化）；导出 PNG 同时写 `ccv3` + 镜像 `chara`，保留原图底图。PC 端不做 sanitize，完整保留 TavernHelper_scripts / regex_scripts / 世界书等原始数据。
- **AI 适配管线**（5 步向导）：资产分析（扫描楼层 HTML 代码块/酒馆助手脚本/regex 脚本）→ AI 规划（status.fields 设计 + frontend 配置 + API 映射表，表单化可改）→ AI 生成（改造 HTML，尽量复原原版观感）→ 双预览对比（左 ST 原版模拟，右 App 模拟含状态块自测）→ 写入 `extensions.arktavern` 并导出。
- **完整编辑器**：全字段表单 + 世界书 + ArkTavern 扩展可视化编辑（状态字段表格 / frontend 表单 / CodeMirror HTML 编辑 / 实时 App 预览）+ 原始 JSON（带风险确认）。
- **AI 接入**：OpenAI 兼容协议（baseUrl + apiKey + model），主进程请求无 CORS，SSE 流式输出，覆盖 DeepSeek / Gemini 兼容端点等。

## 开发

```bash
npm install       # .npmrc 已配置国内镜像
npm run dev       # 开发模式(electron-vite)
npm run typecheck # TS 类型检查(node + web)
npm run build     # 构建产物到 out/
npm run dist      # electron-builder 打 Windows nsis 安装包(输出 release/)
```

## 与 App 的关系

- 卡片扩展契约以仓库 `docs/frontend-card-contract.md`、`docs/arktavern-card-extensions.md` 为单一事实来源，提示词常量内嵌于 `src/prompts/contract.ts`（docs 变更时需同步）。
- 适配后导出的卡：App 聊天页出现「界面」入口（panel 浮层/全屏），`status.fields` 声明后 App 自动注入状态输出指令，AI 回复末尾的 `<|status|>{...}</|status|>` 块驱动前端刷新。
- App 导入时会丢弃超 200KB 的非 arktavern 扩展，故适配导出默认移除 `regex_scripts` / `TavernHelper_scripts`。

## 目录结构

```
electron/            主进程:窗口 + IPC + 卡片 IO + AI 客户端
src/views/           Home(导入) / Editor(编辑器) / Adapt(AI 适配) / Settings(设置)
src/components/      editor/(编辑 Tab) preview/(双预览) CodeEditor(CodeMirror 6)
src/shared/          card.ts(数据模型归一化) assets.ts(前端资产扫描)
src/prompts/         AI 提示词(内嵌 App 契约文本)
```
