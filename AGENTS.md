# AGENTS.md — ArkTavernSolo Agent 总指挥

> 任何 Agent / 开发者接手本项目前**必读的唯一入口**。最后更新：2026-09-27。
> 配套：`docs/handover/`（交接文档体系）· `README.md`（面向用户的项目说明）

## 1. 这是什么项目

原生 **HarmonyOS NEXT（ArkTS / ArkUI）** 的 **单人 AI 角色扮演聊天客户端**，复刻 SillyTavern 单人聊天核心（角色卡 V2/V3、AI 对话、世界书、多层记忆、Persona、对话分支、TTS、WebDAV 同步）。

| 项 | 值 |
|---|---|
| 平台 | HarmonyOS NEXT（API 24 / SDK 6.1.1） |
| 语言 / 框架 | ArkTS / ArkUI（State Management **V1**） |
| 存储 | 关系型数据库（RDB，当前 schema 版本 **47**）+ Preferences + Asset KeyStore |
| 与 ArkTavern 关系 | 完整版含群聊/世界/VRM；Solo 是单聊精简版，同设备共存，数据隔离（所有存储键前缀 `arktavern_solo`） |

## 2. 接手流程（新会话按顺序执行）

1. 读本文件（你在这一步）
2. 读 `docs/handover/CURRENT.md` —— 当前进度与下一步
3. `git log --oneline -8` 对照进度；`git status` 确认工作区状态
4. 跑一次编译（§5）确认环境可用，再动代码

## 3. 架构与分层（硬约束）

```
pages/ → viewmodels/ → services/ → repositories/ → database/
                          ↓                ↓
                     storage/          network/
components/ 与 models/：无网络、无数据库、无业务副作用
```

- `services/AppServices.ets` 是**唯一组合根**（静态、幂等）；页面**可以**通过 `AppServices.getXxx()` 静态方法取服务（架构允许）
- `ChatService` **不是单例**：每次进入 ChatPage 由 `AppServices.createChatService()` 新建，只被 `ChatViewModel` 独占使用
- `ModelService` 是**所有 AI 请求的唯一出口**（页面/服务不得直接碰 Provider/KeyStore）
- **红线**：pages 不得直接 import 具体 services / repositories / network / database；components 不得 import viewmodels / services / database
- 已知偏差（**勿扩散**，治理清单见审计报告 §3）：`ChatPage.ets` 直连约 8 个具体服务（TTS / MacroReplacer / 预算等）；`LorebookPage.ets` 直连 CharacterRepository；`ChatStatusWorldPanel.ets` 仅**类型引用** `ChatViewModel` 的 `LorebookPanelBook/Data`（不持有 VM 实例）
- 组件越层已修复（2026-09-27，P1-5）：`CardFrontendWeb`/`CardFrontendBridge` 依赖 `bridge/CardFrontendBridge.ets` 导出的 `FrontendCardHost` 契约（页面直接传 `host: this.viewModel`）
- 会话列表面板已删除（2026-09-27，P1-4）：原 `components/ChatSessionListPanel.ets` 为不可达死 UI（`ChatViewModel.openSessionList()` 无调用者），连同 ChatViewModel 的会话列表/分组 API 一并移除；**会话切换统一走首页"对话记录"Tab**（`pages/tabs/ChatSessionRootView.ets` + `components/SessionGroupDialogs`）

## 4. 编码规则（ArkTS 红线）

- 禁 `any` / `unknown` / `as` 类型断言；禁动态属性访问；禁 `delete`
- 对象字面量需显式类型上下文；深层嵌套对象字面量逐层声明中间变量
- **`@Builder` 方法内禁止 `const` / `let`**
- 不使用 barrel export（无汇总 index.ets），一律相对路径直接导入
- `String.replace` 不支持回调函数（用 `RegExp.exec` 循环）；正则用 `new RegExp()`
- 异步必须配 `.catch()`（未捕获的 Promise 会 Crash）；`aboutToDisappear` 中清理定时器与监听（`display.on` / `window.on` / mediaquery 等）
- 回调中的 `this` 一律用箭头函数
- **宿主契约（结构类型）仅适用于 public 成员**：把 `this` 直接传给接口的场景（如 `FrontendCardHost`）要求相关成员全为 public；成员的 `private` 会使结构赋值失败——此类抽取改用「构造注入依赖 + 调用期快照字段」

## 5. 快速命令速查

**编译验证（唯一标准）** —— 必须用 IDE 内置 SDK 6.1.1：

```powershell
$env:DEVECO_SDK_HOME = "D:\DevEco_studio\DevEco Studio\sdk"
& "D:\DevEco_studio\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

- 通过标准：输出 `hvigor BUILD SUCCESSFUL`（约 35~45 秒）；产物：`entry\build\default\outputs\default\entry-default-signed.hap`
- **同一编译命令最多运行 3 次**；不要 clean build（仅缓存异常时允许）
- `D:\DevEco_studio\Sdk`（旧版 6.0.2）会报 00303312，勿用
- 既有告警（非阻塞，勿当新问题）：`showToast`/`back` deprecated、若干 "Function may throw exceptions"、ChatPage 一处 `@ObjectLink` 赋值警告

**本地单元测试（host 侧回归，可选但建议在搬运类改动后跑一次）**：

```powershell
& "D:\DevEco_studio\DevEco Studio\tools\hvigor\bin\hvigorw.bat" test --mode module -p module=entry@default -p product=default -p buildMode=debug --no-daemon
```

- 逐用例结果落盘：`entry/.test/default/intermediates/test/coverage_data/test_result.txt`（`result=Success/Failure`）；覆盖率 HTML 在同目录 `outputs/test/reports/`
- 覆盖纯函数层（ChatTextContract / PromptSegment 段序 / 世界书激活与粘滞 / 记忆索引 / 状态 schema / 前端契约）；**会话 / Swipe / 分支 / 流式簇不在覆盖内**，只能真机冒烟

**git 纪律**：
- 一次一个操作 → 编译验证 → 提交；失败立即 `git checkout -- <file>` 回滚，不带病继续
- 提交信息风格：`feat/fix/refactor/chore/docs(scope): 中文描述`
- **未经用户确认不要 push**；重构安全基线：tag `refactor-baseline`

## 6. 数据库纪律

- 当前版本 **47**（`database/DatabaseConstants.ets` 的 `DATABASE_VERSION`）
- 迁移**只增不改**：禁止 DROP TABLE / DROP COLUMN；新增列必须新增迁移版本，**逐版连续**，禁止跳版本
- 行映射用 `getColumnIndex >= 0` 安全回退，保证旧 schema 兼容
- `senderType='character'` 的消息必须填 `senderCharacterId`，否则 MessageRepository 抛 `invalid data`
- 已废弃功能的表（如 worlds）仍留在库中，属预期（迁移只增不改），勿依赖

## 7. 关键领域概念速查

**消息三层体系**（改聊天相关代码前必须理解）：

| 层 | 类型 | 值 |
|---|---|---|
| Wire（网络） | `ChatRole` | `system` / `user` / `assistant` |
| DB（数据库） | `MessageSenderType` | `'user'` / `'character'` / `'narrator'` |
| UI（渲染） | `ChatSenderType`（ChatRichText.ets） | 对应渲染类型 |

- Impersonate（代写）= User role + `'character'` senderType；Narrator（旁白）= System role + `'narrator'`；AutoContinue 续写复用最后一条消息
- `ChatGenerationKind` enum 定义在 `models/ChatGenerationContext.ets`（P2-4 起；此前在 ChatService）
- `ChatService.currentChat` 是 private，外部走 `getCurrentChat()`
- `ChatRequest.temperature/topP` 是 number（非 optional）；`ProviderConfig.maxTokens` 与 `EffectiveGenerationSettings.maxOutputTokens` 字段名不同
- 存储键统一 `arktavern_solo` 前缀；不缓存 `$r()` 颜色结果

## 8. UI 一致性规范（新增 / 修改 UI 时必须遵守）

> 来源：《鸿蒙 App 开发指南》（真机验证沉淀），已按本项目现状适配。

- **返回按钮**：统一系统图标（`SymbolGlyph($r('sys.symbol.chevron_left'))` 或 `sys.media`），禁止文字按钮与自绘箭头混用；返回行为走统一分层（浮层 → 历史 → 退出确认）
- **安全区**：全应用统一策略——背景可沉浸（`expandSafeArea`），可交互控件留在安全区内；新页面禁止自行发挥
- **深浅色**：颜色一律 `$r('app.color.*')` + `dark/` 资源覆盖，**零硬编码色值**；不把颜色缓存进变量；弹窗配色跟随主题（禁白底黑字写死）
- **键盘避让**：压缩式（顶栏不动、内容区压缩、输入框贴键盘），严禁系统级 + 组件级双重避让；`keyboardHeightChange` 监听必须在 `aboutToDisappear` 解绑
- **列表**：> 20 条用 `LazyForEach`；keyGenerator 必须用业务唯一 id（**严禁 index**）；复用组件在 `aboutToReuse` 重置视觉状态
- **图片**：同路径覆盖后不刷新时加 `?t=timestamp` 破缓存；网络图配 `alt` 占位 + `onError`
- **横竖屏**：尊重系统旋转锁（`module.json5` 保持 `auto_rotation_restricted`）；旋转/尺寸变化后重算悬浮控件钳制位置（600ms 防抖）
- **交互一致性**：Toast / Loading / 空态 / 确认弹窗使用统一封装，禁止各页面自造

## 9. 功能 → 文件定位（高频速查）

> 完整定位表（历史，可能过期，仅作起点）：`docs/handover/archive/agent/04_FEATURE_LOCATOR.md`

| 想改… | 第一定位 |
|---|---|
| 首页 4 Tab | `pages/Index.ets` → `pages/tabs/*RootView.ets` |
| 会话列表（切换/重命名/分组/拖拽/归档） | `pages/tabs/ChatSessionRootView.ets` + `components/SessionGroupDialogs.ets` |
| 聊天主界面 | `pages/ChatPage.ets` → `viewmodels/ChatViewModel.ets` |
| AI 对话 / 流式 / 分支 / Swipe | `services/ChatService.ets` → `services/ModelService.ets` → `network/providers/` |
| Prompt 组装 / 宏替换 | `services/PromptBuilder.ets`、`services/MacroReplacer.ets` |
| 世界书 | `services/LorebookService.ets` → `repositories/LorebookRepository.ets` |
| 多层记忆 | `services/MemoryService.ets` |
| 角色卡解析 | `parser/CharacterCardJsonParser.ets` / `PngCharacterCardParser.ets` |
| 数据库表 / 迁移 | `database/Database{Constants,Schema,Migration}.ets` |
| 云同步 | `services/sync/` → `network/webdav/` |
| TTS | `services/TtsService.ets`（离线）/ `EdgeTtsService.ets`（在线） |
| 主题 | `services/ThemeManager.ets` → `theme/ThemePalette.ets` |
| 日志 | `utils/Logger.ets` |

## 10. 文档体系与维护纪律

```
AGENTS.md                            ← 本文件（总指挥，唯一入口）
docs/handover/
├── README.md                        # 交接文档导航
├── CURRENT.md                       # 当前状态与下一步（**每次会话更新**）
├── 2026-09-27-audit-and-roadmap.md  # 全项目审计报告 + 重构路线图
└── archive/                         # 过期文档归档（勿作现状依据）
```

**纪律（必须遵守）**：

1. 每解决一个问题 / 踩一个坑 / 做一次决策，**当场**写进文档（不许"以后补"）
2. git 提交跟随里程碑：每完成一个可验证的操作就提交（一次一操作一提交）
3. 新增功能方法论：定契约（数据结构 / spec）→ 实现 → 编译 + 真机验证 → 收尾三步
4. 收尾三步：更新 `CURRENT.md` → 清理临时产物 → git 提交
5. 接手先读文档，禁止凭直觉直接改代码
6. 发现文档过时：**以代码为准**，当场改文档

## 11. 当前状态与下一步

- 基线：`refactor-baseline` tag（2026-09-27 建立）
- 已完成：全项目只读审计（286 文件 / 112,801 行）、交接文档体系重建、`tools/` 与开发截图清理
- **P1 批次全部完成**：P1-1 死代码清理 ✅ · P1-2 ChatService 重复逻辑消除 ✅ · P1-3 ChatPage 组件抽取（5 个）✅ · P1-4 会话列表去重 ✅（共享折叠纯函数 + 共享分组弹窗 + **删除不可达的会话列表面板**，≈-1069 行）· P1-5 组件越层修复 ✅ · P1-6 不可变性 ✅
- **P2 路线 + 扩展完成（ChatService 瘦身，6,735 → 2,413 行，-4,322，-64%）**：P2-1 ✅（`ChatTextContract` / `ChatRequestPlan` / `ChatRequestBuilder` 615 行）；P2-2 ✅（`models/ChatServiceContract` + `ChatOneShotGenerator` 513 行）；P2-3 ✅（`ChatStatusService` 597 行 + 5 状态字段）；P2-4 ✅（`models/ChatGenerationContext` + `ChatSwipeController` 327 行）；P2-5 ✅（`ConversationBranchService` 查询/判定 252 行）；**P2-6 ✅**（`ChatMessageService` 113 行）；**P2-7 ✅**（`ChatContextMaintenanceService` 291 行）；**P2-8 ✅**（branch 切换/重载 103 行 + 生成族 676 行）；**P2-9 ✅**（`ChatSessionService` 会话生命周期 606 行，dispose 有意留）；**P2-10 ✅**（`ChatMessageSender` 消息发起 231 行，stopGeneration 有意留）；**P2-11 ✅**（`ChatUserIdentityService` 用户称呼与 Persona 124 行）；**P2-12 ✅**（Preset 快照迁入 `ChatRequestBuilder` 77 行）；**P2-13 ✅**（消息记忆标记迁入 `ChatMessageService` 31 行）；**P2-14 ✅**（`reloadCurrentSession` 迁入 `ChatSessionService` 15 行）
- ChatService 现状：**现实下限 ≈2,350~2,400 行**（构成：构造装配 ≈450 + 公开薄包装 ≈200 + 流式核心簇 ≈900 + 核心内联辅助）；剩余仅 `updateRequestPlan` + 估算查询 ≈77 行，因预算缓存被核心读写、搬出需回环回调，ROI 为负已主动放弃；**千行级须突破"流式核心不动"（需用户显式授权）**；**下一步候选（P3，审计 §6）**：ChatViewModel 拆分 → MemoryService 拆分 → DatabaseSchema 分域
- P2 装配范式（后续接缝直接复用）：服务依赖构造期注入；跨类状态与宿主私有能力经**函数属性**回调（`ChatRequestHost` 式）读写——读走 getter、写走 setter（`ChatOneShotHost` / `ChatStatusHost` / `ChatSwipeHost` 含 `doStream` 委托），类内同名 getter/setter/方法转发 → 搬运代码零改写、读写语义不变；自带状态的簇可将状态随类迁出（见 `ChatStatusService`）。参考实现：`entry/src/main/ets/services/` 下 `ChatRequestBuilder.ets` / `ChatOneShotGenerator.ets` / `ChatStatusService.ets` / `ChatSwipeController.ets` / `ConversationBranchService.ets`
- 后续接缝：P2 批次（P2-1..P2-14）全部收官；P3 批次以用户拍板为准（流式核心不动）
- 验证状态：代码改动均编译通过（P2 全部搬运块 byte 级与原文一致）；**本地单测套件可用 `hvigorw test` 本机执行**（`entry/src/test`，16 类 / 96 用例；2026-09-27 首跑全通过，结果落盘 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`）；真机冒烟按批次进行（会话/Swipe/分支/流式簇只能真机验证），清单与回滚锚点见 `docs/handover/CURRENT.md` §4；路线图见 `docs/handover/2026-09-27-audit-and-roadmap.md` §6