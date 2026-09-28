# INVENTORY — 可复用资产清单（写新代码前必查）

> **本文件的唯一职责**：让 agent 和本人在动手前知道「**已经有了什么**」，避免重复造轮子、避免造出风格不一致的轮子。
> **硬规则（见 `AGENTS.md` §"给 AI 的工作约束"）**：
> 1. 写任何新组件 / 工具 / 服务 / 模式前，**先查本文件**；
> 2. 若决定新建，提交说明里写一句「**为何不能复用现有 X**」；
> 3. 新增了可复用资产，**同一次提交**内把它登记到本文件。
> 最后核对：2026-09-28（条目均来自实际目录扫描）。

## 1. 组件层 —— `entry/src/main/ets/components/`

> 全部为纯 UI：**禁网络 / DB / 安全存储 / services / viewmodels**。数据经 `@Prop` / `@Link` / 回调上抛。

### 1.1 通用外壳与容器（新页面优先用，别自绘）

| 组件 | 用途 | 何时用 / 注意 |
|---|---|---|
| `AppPageHeader` | 应用页面顶部标题区 | 所有二级页面顶栏；返回按钮统一系统图标（见 AGENTS §8） |
| `PressableCard` | 可按压卡片容器 | 需要"整卡可点 + 按压反馈"时 |
| `SectionHeader` | 区块小标题 | 设置类页面的分组标题 |
| `EmptyStateView` | 空状态视图 | 列表/页面无数据；**禁止各页面自造空态** |
| `ColorWheelPicker` | HSV 色盘选择器 | 需要取色时（全屏覆盖层由页面提供） |

### 1.2 弹窗 / 菜单（统一交互，别自造 sheet）

| 组件 | 用途 |
|---|---|
| `SessionGroupDialogs` | 会话分组（文件夹）管理弹窗族：新建 / 重命名 / 删除 / 移动 / 新建并移入 |
| `ChatMessageActionSheet` | 消息操作菜单（底部）：继续 / 重新生成 / 生成新回复 / 编辑 / 删除 |
| `ChatMoreMenuSheet` | 聊天页顶部"更多"菜单（底部） |
| `ChatForkPicker` | "从此处创建独立对话"模式选择弹窗 |
| `HistoricalMessageEditDialog` | 历史 User 消息编辑弹窗 |
| `ImpersonateCandidatesPanel` | 代写候选展示与选择（带序号、可滚动） | 自身不画底/描边，渲染在 `ChatInputArea` 胶囊内部顶部（2026-09-27 由独立浮层改入胶囊，避免材质割裂） |

### 1.3 聊天专用

| 组件 | 用途 | 注意 |
|---|---|---|
| `ChatMessageList` | 聊天消息列表 | 用 `ChatMessageDataSource`（懒加载）；keyGenerator 必须用消息 id |
| `ChatMessageDataSource` | 消息列表懒加载数据源 | **>20 条列表的标准做法** |
| `ChatMessageBubble` | 单条消息气泡 | — |
| `ChatRichText` | 富文本渲染（含 `ChatSenderType` 渲染类型） | 改渲染类型前先读 AGENTS §7 消息三层体系 |
| `ChatInputArea` | 聊天输入区（含发送/停止按钮、代写候选区） | 键盘避让由页面负责；停止键为低对比描边圆钮（刻意不用高饱和红）；发送/停止切换带形变过渡 |
| `MessageSwipeControls` | Swipe 候选切换控件 | — |
| `ChatAppearancePanel` | 聊天显示设置面板（滑块/配色/色盘/恢复默认） | 语义色经 `@Prop`，色盘请求经 `ColorPickerRequest` 上抛 |
| `ChatStatusWorldPanel` | 状态 / 世界书面板 | AI 区与条目启停经 `@Link` + 回调上抛 |
| `ChatCollapsibleBlock` / `ChatBranchBlock` | 可点击折叠块 / 分支选项 | — |
| `CardFrontendWeb` | 角色卡前端 ArkWeb 渲染 | 宿主契约在 `bridge/CardFrontendBridge.ets` |

### 1.4 分支 / 市场

| 组件 | 用途 |
|---|---|
| `BranchMapNode` | 分支缩进树的一行（缩进 + 拐角线 + 圆点，无方框） |
| `MarketCharacterCard` / `MarketCharacterAvatar` | 市场角色卡列表项 / 头像 |

## 2. 工具层 —— `entry/src/main/ets/utils/`（纯函数，无副作用）

| 工具 | 用途 | 何时用 |
|---|---|---|
| `Logger` | 日志（含敏感信息脱敏 `redact*`） | 一律用它，**不要 `console.log`** |
| `LogBuffer` | 诊断日志缓冲 | 需要现场诊断导出时 |
| `Time` | `nowMillis` / `nowIso` / `millisToIso` | **不要手写 `Date.now()` 之外的格式化** |
| `Uuid` | `generateUuid`（v4） | 生成 id；**不要自己拼随机串** |
| `SessionListCollapseState` | 会话列表折叠状态 key + parse/serialize + 判定纯函数 | 折叠态持久化（P1-4 收口了三处重复） |
| `BranchTreeFlatten` | 分支树拍平成缩进树行序列（含 `formatRowTitle/formatRowHint` 文案口径） | 画分支地图时；**行文案只在这一处格式化** |
| `ChatTextColorTheme` | 字体配色主题（浅/深、校验/归一 hex） | 聊天气泡文字配色 |
| `ChatTextStyleSettings` | 聊天文本样式设置（含 `DEFAULT_CHAT_TEXT_STYLE`） | 字号/行距类设置 |
| `ChatBubbleAppearance` | 气泡外观（透明度归一 + 气泡底色计算） | 气泡配色；**不要在页面里重算** |
| `ChatPalette` | 角色对白颜色生成（按 characterId 稳定取色） | 多角色配色 |
| `ImageConverter` | 图片格式转换（`isPngBytes` 等） | 图片处理 |
| `CryptoHelper` | 加密（基于 `@kit.CryptoArchitectureKit`） | 需要加解密时 |
| `GroupReplyModeSetting` | 群聊回复模式/旁白开关持久化 | 群聊相关设置（Solo 版基本不用） |

## 3. 模式层（可复制的做法 —— 这才是"不造重复轮子"的关键）

| 场景 | 现成范式 | 参考实现 |
|---|---|---|
| **从巨型类里抽逻辑**（保持行为不变） | 构造期注入只读依赖（字段同名）+ `XxxHost` 函数属性回调读写可变状态 + 类内同名转发 ⇒ **搬运体可逐字不改** | `services/ChatRequestBuilder.ets`、`ChatSessionService.ets`、`ChatStatusService.ets`、`viewmodels/LorebookPanelVM.ets` |
| **组件越层解耦** | 导出宿主契约（结构类型），页面直接传 `host: this.viewModel` | `bridge/CardFrontendBridge.ets` 的 `FrontendCardHost`（P1-5） |
| **内存态经宿主回写**（不丢 ArkUI 观察） | 抽取类只读+回调写，`@Observed` 字段仍留在 VM | `LorebookPanelVM` 的 `setPanelData` |
| **错误文案映射** | 纯函数收口，调用点直连 | `viewmodels/ChatErrorMapper.ets` |
| **纯常量 / 契约文本** | 独立契约模块 | `services/ChatTextContract.ets` |
| **纯 prompt 文本构建** | 独立 builder（无网络/无 DB） | `services/MemoryPromptBuilder.ets` |
| **阈值/策略判定** | 独立策略类 + 宿主回调取宿主私有能力 | `services/MemoryTriggerPolicy.ets` |
| **DDL 常量组织** | 按域拆文件 + `DatabaseConstants` 取名字 | `database/schema/Schema*.ets` |
| **版本 → 语句映射** | `Map` 注册表，取值返回浅拷贝 | `database/DatabaseSchema.ets` 的 `SCHEMA_BY_VERSION` |
| **跨表事务** | `dbHelper.runInTransaction(fn)`，Repository 传 `store` | `services/ChatPersistenceService.ets` |
| **纯数据/共享类型** | 下沉 `models/`（跨模块复用必须 export） | `models/LorebookPanel.ets` |
| **设置类页面紧凑行版式**（提高信息密度用） | 分区 = `caption` 小标题（tertiary 色，`padding-left 4`）+ 一张 `surface_1` 卡片；卡内行高 **44**、行间 `Divider`（左右缩进 12）、行 = 标签(次要色) + 值(主色，右对齐 `layoutWeight(1)`) + `›`；动作以 `surface_2` 胶囊呈现在行尾；危险项独立成行用 `app_danger` | `components/ChatMoreMenuSheet.ets`（sheet 场景）、`pages/AppSettingsPage.ets`（整页场景） |
| **入口行版式（图标在行尾）** | 行 = 标题(主色 medium) + 小字说明(次要色 caption) 左对齐 + **行尾只放一个入口图标**（18，tertiary 色，兼作视觉锚点，**不放箭头**）；行高 **56**、卡内 1px 分隔线、卡片左右各缩进 16（`app_spacing_16`）；同组共用一张卡（不再每项一张整宽卡）。**替代已删除的 `components/ui/AppEntryCard.ets`**（该项每入口一张整宽卡，0 引用后删除，2026-09-28） | `pages/tabs/SettingsRootView.ets` 的 `entryRow`（6 个入口）；图标取仓内**已编译通过**的 `sys.symbol.*`（key / book / textformat / exposure / arrow_clockwise / speaker_wave_2） |
| **多选一控件（主题/位置等）压成一行** | 4 个以内用一行等宽小卡（色块预览 + 名称 + 选中描边）；2 个用段选胶囊（`surface_2` 轨道 + `surface_1` 滑块）；**不要**每项占一张整宽大卡 | `AppSettingsPage.themeRow` / `positionSegment` |
| **子入口统一走上滑面板**（替代居中弹框，避免"突兀"） | `bindSheet` + **两段式开关**（外层 `if` 挂载 → `onAppear` 置真；关闭只置 false，`onDisappear` 再卸载，详见 PITFALLS P-29）；面板内容复用「分区小标题 + 卡片 + 行高 44」范式 | `components/ChatMoreMenuSheet.ets`；`pages/ChatPage.ets` 的 `memoryModeSheetContent` / `userNameSheetContent` / `personaSheetContent`（分段）/ `chapterSheetContent` |
| **懒加载列表"先定位再显示"**（避免进入时从顶部翻到最新） | 门控 `.opacity(0)` 保持挂载 → 加载动画占位 → 追底锁持续 `scrollEdge(Bottom)` 直到 `isAtEnd()` → 再显示；只在整列表被替换时触发（详见 PITFALLS P-80） | `pages/ChatPage.ets` 的 `chatListPositioned` / `beginListPositioning` / `autoScrollToBottom` |
| **机械校验**（改动是否等价） | 搬运→byte diff；对外 API→声明面 diff；数据产物→全量字符串 diff | 手法记录见 [PITFALLS](./PITFALLS.md) 第 4 节 |

## 4. 明确"不要重复造"的反例清单

| ❌ 不要 | ✅ 用 |
|---|---|
| 自己写 Toast / Loading / 空态 / 确认弹窗 | 统一封装 + `EmptyStateView`（AGENTS §8） |
| 自己拼随机 id / 时间格式化 | `utils/Uuid` / `utils/Time` |
| `console.log` | `utils/Logger` |
| 在页面里重算气泡颜色 / 角色配色 | `utils/ChatBubbleAppearance` / `ChatPalette` |
| 新写一个"折叠状态"存取 | `utils/SessionListCollapseState` |
| 在 `components/` 里取服务或查库 | 经回调上抛给页面/VM |
| 为新页面凭空造 ViewModel 层（薄页面） | 先按 `CURRENT.md` P3-4 的 T1/T2/T3 口径判断 |
| 复制一份 LLM 请求发送逻辑 | 一律经 `services/ModelService` |
| 直接 `ALTER TABLE` 改历史迁移 | 新增版本（只增不改） |
