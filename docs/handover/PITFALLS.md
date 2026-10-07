# PITFALLS — 踩坑与硬约束累积

> **唯一职责**：把"已经踩过的坑"沉淀成一行一条，避免下一个 agent / 下一次自己再踩。
> **规则**：① 踩坑**当场**加（不许"以后补"）；② 编号**只增不复用**；③ 尽量带证据（报错原文 / commit / 命令）；④ 若与代码冲突**以代码为准**并当场改本文件。
> 最后更新：2026-09-27（P3 收官）。

## 1. 工具链与环境

| # | 坑 | 正确做法 / 证据 |
|---|---|---|
| P-01 | 用旧 SDK 编译报 `00303312` | 必须 `DEVECO_SDK_HOME` → IDE 内置 **6.1.1**（`D:\DevEco_studio\DevEco Studio\sdk`）；`D:\DevEco_studio\Sdk` 是 6.0.2，**不可用** |
| P-02 | 盲目重试编译浪费大量时间 | **同一编译命令最多跑 3 次**；失败先读 `Error Message:` 再改，不盲试 |
| P-03 | 修改 `build-profile.json5` 或 clean build 破坏缓存 | 不 clean build（仅缓存异常时允许）；签名配置已指向本机有效路径 |
| P-04 | 单测结果"看不见" | 逐用例结果落盘 `entry/.test/default/intermediates/test/coverage_data/test_result.txt`（`result=Success/Failure`），用 `Get-Content … \| Select-String "result=Failure"` 计数 |
| P-05 | 大文件（>1500 行）用编辑工具多区间改，行号漂移 | 多区间操作**从后往前**改；大段搬运用 PowerShell 切片，保持 **LF 无 BOM**（`[System.IO.File]::WriteAllText(f, s, UTF8Encoding($false))`） |
| P-06 | PowerShell 双引号里 `$1`/`$anchor` 被当变量吞掉，替换静默失效（本轮踩过 2 次） | 写含 `$` 的脚本/替换串一律用**单引号**或单引号 here-string `@'…'@`；替换后**必须验证** `$c.Contains($old)` |
| P-07 | `Write`/`Edit` 工具只能改**工作区内**文件，写仓外失败（`Access denied … restricted to the working directory`） | 仓外临时夹具/脚本用 shell 生成；验证夹具放 `%TEMP%`，**不进仓** |
| P-08 | 用 PowerShell heredoc `<<'EOF'` 提交 git message 报解析错误 | PowerShell 用 `@'…'@` here-string 赋给变量后 `git commit -m $msg` |

## 2. ArkTS / ArkUI 语言坑

| # | 坑 | 正确做法 / 证据 |
|---|---|---|
| P-10 | **ArkTS 禁结构类型**：用"窄接口"接收更宽的接口编译失败 | 报错 `arkts-no-structural-typing`（P3-2① 实测）。接口参数必须**精确类型**；跨模块复用就把类型**下沉 `models/`**（例：`ChapterTriggerConfig` 迁 `models/ChatMemory.ets`） |
| P-11 | 从新模块 import 常量编译失败 | 报错 `Module './schema/SchemaWorld' declares 'X' locally, but it is not exported`。**跨模块引用的常量必须 `export`** |
| P-12 | 内存 Map 泛型写法在工具链里要显式 | 用 `new Map<number, string[]>()` + `.set()`（避免数组元组字面量的类型推断问题）；取值后**返回浅拷贝**保持调用方隔离 |
| P-13 | 禁 `any` / `unknown` / `as` 类型断言、禁动态属性访问、禁 `delete` | 用显式类型 + 中间变量；`Record<string, Object>` 可用字符串索引 |
| P-14 | 对象字面量缺类型上下文报错 | 逐层声明中间变量；深层嵌套对象拆开写 |
| P-15 | `@Builder` 内不能声明局部变量 | `@Builder` 内**禁 `const`/`let`** |
| P-16 | `String.replace` 不支持回调函数 | 用 `new RegExp()` + `RegExp.exec` 循环 |
| P-17 | 未捕获的 Promise 会 **Crash** | 异步必须配 `.catch()` |
| P-18 | 定时器 / 监听泄漏 | `aboutToDisappear` 中清理 `setTimeout` / `display.on` / `window.on` / `mediaquery` / `keyboardHeightChange` |
| P-19 | 回调里的 `this` 丢失 | 一律用**箭头函数** |
| P-20 | barrel export（汇总 `index.ets`）不允许 | 一律相对路径直接导入 |
| P-21 | 宿主契约（结构类型）里含 `private` 成员会导致结构赋值失败 | 宿主契约**仅适用于 public 成员**；需要私有能力的场景改用「构造注入 + 调用期快照字段」 |
| P-22 | 搬运代码后**签名悄悄变了**（丢失 `async`） | P2 实测：`refreshLorebookPinNow` 薄包装时丢了 `async`（commit `36d809c` 修复）。**必须做 API 面 diff**（见 §4） |
| P-23 | `@Builder` 参数导致状态不刷新 | VM 字段一律**新引用赋值**（`[...arr]`），确保 ArkUI 检测到变化 |
| P-24 | 给 `LazyForEach` 的项加 `.transition()` 后，**首次进页面整个列表集体入场** | 列表首帧是一次性批量插入的，过渡会全部触发。必须做**页面侧门控**：页面持 `entranceAnimationEnabled`，**首批（加载）不 animate，从第二批起才置 true**（首批必然是加载、第二批必然是用户动作触发，不依赖加载耗时）；关闭态用 `TransitionEffect.IDENTITY` |
| P-25 | `bindSheet(SheetSize.FIT_CONTENT)` 的内容加分区标题后超出可视高度 | Sheet 内容**可滚动**（拖动可到底），但**首屏看不到最后一组**（本轮给"对话设置"加分组标题后，"危险区/清空对话"落到屏外）。改完必须真机拖动确认最后一组可达，或显式压缩内容高度 |
| P-26 | **用"派生值"给兄弟节点命名 → 必然同名** | 分支地图原用「第 N 轮分支」(N = 分叉点前的用户消息数)作标题,**同一句话分叉的两条分支 N 相同 → 同名**,用户完全分不清(实测出现两对同名分支)。规则:同一父节点下的兄弟**必须**带**兄弟序号**(按 createdAt 排序的 ①②③);主标题用**与兄弟的差异**(分歧首句),派生值(轮次)降级为副标题;无差异内容的分支显式标"尚无新内容" |
| P-27 | **用整体降透明度表达"非当前项"** | 原分支地图给非活跃分支整节点 `opacity(0.7)`,文字一起变淡 → 用户反馈"看不清"。规则:**只降线/点/边框的颜色**(改中性色),文字保持 `--text-primary`;状态用**颜色与形状**区分,不用透明度 |
| P-28 | 同一行内既有"整行点击进 A"又有"行内按钮做 B"（模型列表行：点行进编辑页、点「切换」立即切换当前配置） | **不要用父子嵌套 `onClick`** —— 那样是否误触取决于事件冒泡语义，不可靠。做法：把两个点击区做成**兄弟节点**——左列（`layoutWeight(1)`）承载"整行"点击，右胶囊单独 `onClick`，两者互不包含；**行容器本身不带 `onClick`**（见 `ModelSettingsPage.configListItem`） |
| P-29 | 把居中模态弹框改成 `bindSheet` 上滑面板后**没有上滑动画**（仍旧直接出现） | `bindSheet` 的开关若在**节点首次挂载时就为 true**，面板会直接出现、没有进场过渡。必须**两段式**：外层 `if (showXxx)` 挂载一个 0 高节点 → 该节点 `onAppear` 里把 `sheetShow` 置真 → 由 `false→true` 触发上滑。**关闭时只置 `sheetShow = false`**，再由 `bindSheet.onDisappear` 去置 `showXxx = false` 卸载，这样才有下滑动画。范式见 `components/ChatMoreMenuSheet.ets`、`ChatPage` 的 `memoryModeSheetContent` / `userNameSheetContent` / `personaSheetContent` / `chapterSheetContent` |
| P-84 | 在解析管线里只"插入新 pass"就以为新增了一种片段类型（自定义符号片段）→ **后续 pass（对白/动作）仍把它当 `styleType='normal'` 拆开重建，打上的标记在重建时丢失，功能整体不生效**（2026-10-01 单测暴露：3 条用例 `symbolRuleId` 全为空，真机表现为"改了符号颜色没反应"） | 片段一旦"定型"就必须让**所有后续 pass 原样透传**：本仓用 `colorRole==='symbol'` 作标志（`isSymbolSegment`），在 `applyCustomSymbols`（防第二条规则覆盖第一条）、`applyDialogue`、`applyParenthetical` 三处提前 `continue`。新增任何"给片段打标"的 pass，都要沿管线排查后续重建点——`splitByPattern` 的**未命中分支也会 `createSegment(前缀)` 重建**，不只是命中分支 |
| P-85 | 把"动态颜色"固化进片段数据（`seg.symbolColor`），改色后**消息内不刷新** | `ForEach`/`Span` 按 key 复用，**key 不变则不重建 item，参数化数据不会自行更新**（`ChatRichText` 的 Span key 只含"文本长度"；`ChatAppearancePanel` 早有同类注释）。做法：① 颜色等动态值**在渲染时读 `@State`/`@Prop`**（`getSegmentColor` 按 `symbolRuleId` 查 `symbolRules`），不读片段内固化值；② 规则的**新增/删除**会改变片段的规则绑定，属结构性变化 → 把绑定 id **加进 Span key** 触发重建；③ 只改色**不进 key**（颜色走状态刷新），避免整条消息重排 |
| P-89 | `@Builder` **按值传参的状态**不驱动刷新：记忆模式面板把 `this.memoryModeIsAuto` 当 `selected` 参数传给通用 `sheetChoiceRow`，点"自动归档"后 `@State` 已变、保存也能存进去，但 ✓ 标记不动 → 用户以为"切换无效"（2026-10-05 v51 实测） | 状态**不要经 @Builder 参数传递**：让 Builder **体内直接读 `@State`/`@Prop`**，参数只留静态文案/语义标志。修复见 `ChatPage.memoryModeRow`（判断 `isManual === !this.memoryModeIsAuto` 在 Builder 体内求值） |

## 2b. 聊天消息列表滚动

| # | 坑 | 正确做法 / 证据 |
|---|---|---|
| P-80 | 懒加载消息列表直接 `scrollEdge(Edge.Bottom)` → **进入会话先看到最早的消息，随后"唰"地跳到最新** | 原因：`Scroll` + `LazyForEach` 的内容高度是**逐帧**长出来的，首帧滚底只能落在"当时已量出的底部"≈顶部。修正范式（见 `ChatPage` 的 `chatListPositioned` / `bottomLockActive`）：① 定位完成前消息列表 `.opacity(0)`——**必须仍然挂载**，否则不参与布局、永远算不出真实高度，会死锁成永远不显示；② 定位期间用 `loadingView()`（"加载会话中…"）占位，并加 `hitTestBehavior(HitTestMode.Block)` 阻断触摸，避免误触到不可见列表；③ **追底锁**：每次 `onAreaChange` 都 `scrollEdge(Edge.Bottom)`，直到 `scroller.isAtEnd()` 才结束（另设 **40 次重试上限** + **800ms 兜底定时器**，定时器须在 `aboutToDisappear` 清理）；④ 只在"**整列表被替换**"时定位（首条消息 id 变化，或页面首次加载且尚未显示过），空会话发第一条消息不触发（否则会闪一下加载动画）。**设备侧观感未验证** |

## 2c. 系统分享接收（Share Kit）

| # | 坑 | 正确做法 / 证据 |
|---|---|---|
| P-86 | 以为在 `skills.uris` 里写了 `utd` 应用就会出现在分享面板 | `uris` 的 **`maxFileSupported` 默认为 0（= 不支持该类文件）**——不写就**静默不出现**，必须显式 ≥1。本仓 PNG 卡：`scheme:"file"` + `utd:"general.png"` + `maxFileSupported:1`（`module.json5`，commit `c014825`）；UTD 需穷举声明（如 `general.image` 覆盖全部图片） |
| P-87 | 接收系统分享只处理 `onCreate` → **应用已在前台时分享进来无反应** | 必须 **`onCreate`（冷启动）+ `onNewWant`（热启动）都处理**；`systemShare.getSharedData(want)` **只在 `want.action === 'ohos.want.action.sendData'` 时调用**（普通启动调用会失败，官方示例 catch 里 `terminateSelf()` 不能照抄）。另：分享数据**异步**解析，冷启动时可能晚于根页面创建——只靠 `@StorageProp @Watch` 会漏（值在组件创建前已就位 → 无变化事件），需 `onPageShow` 兜底消费 + 消费后清空标志（范式：`Index.openSharedCardImport`） |
| P-88 | **测试里用非空对象字面量构造 Record**：`const s: Record<string, Object> = { a: 1 }` 报 `arkts-no-untyped-obj-literals`（空 `{}` 带类型注解合法，非空不行；主代码走 `as Record` 不受影响） | 测试 fixture 统一**空 Record + 逐键赋值**（`const s: Record<string, Object> = {}; s['a'] = 1;`），见 `st_frontend_fallback.test.ets` 的 `makeRegexScript` |

## 3. 分层与架构

| # | 坑 | 正确做法 / 证据 |
|---|---|---|
| P-30 | 组件层 import `viewmodels`/`services`/`database` 造成越层 | components 禁这三者（P1-5/P3-1② 已**清零**，勿回退）；数据经 `@Prop`/`@Link`/回调 |
| P-31 | 页面直连具体服务（T2/T3 偏差） | 新增页面**一律走 VM**；`ChatPage`/`LorebookPage` 属**冻结偏差**（`CURRENT.md` P3-4） |
| P-32 | 新服务直连 `DbHelper` | P3-4 口径 C：**services 不得新增 `DbHelper` 引用**；跨表事务走现有 `*PersistenceService` 或仿 `ChatPersistenceService` |
| P-33 | 巨型类里抽逻辑时"顺手改写" | 抽离**只搬运不改写**；必须改写时先证明行为等价；能逐字搬的一律逐字搬（字段同名 + 同名转发） |
| P-34 | 为"以后可能"加抽象层 | **抽象必须有 ≥2 个真实调用点**；不为假想需求加参数/接口层（AGENTS 约束） |
| P-35 | 同一份状态被多处持有 → 不一致 | 状态**只有一个 owner**；跨层用显式参数/回调 |
| P-36 | 删功能/删类前只看"我以为没人用" | 必须给出**全仓 0 调用证据**（`Grep` 全量 + 无动态调用），才可删（P3-2 死代码删除即按此执行） |
| P-91 | 给一条**透传链**加参数时只改了"上游接口 + 下游实现"，漏了**中间私有包装层** → 编译期才发现（2026-10-05 预设末尾段：`ChatOneShotGenerator.buildRequestMessages` 私有包装仍 1 参，报 `Expected 0-1 arguments, but got 2`） | 扩参必须沿链**全量排查**：`Grep "方法名("` 覆盖 ①接口/契约声明 ②宿主装配处的箭头函数 ③**私有/公开薄包装层** ④所有调用点。改完先 Grep 一遍再编译，别靠编译器逐个报 |

## 4. 验证手法（怎么证明"没改坏"）

> 这三招在本项目反复救场，优先用它们代替"人工看代码"。

| # | 手法 | 做法 |
|---|---|---|
| P-40 | **搬运等价性：byte 级 diff** | 从 `git show HEAD:<file>` 取原文，与搬出后的方法体**归一空白后逐行 `Compare-Object`**，要求 DIFF=0；唯一允许差异是宿主间接行 / 可见性 / 日志 tag，且需**逐条列出** |
| P-41 | **对外 API 面 diff** | 抽取全部**非 private 类成员声明行**（排除 `if/for/while/switch/catch` 等关键字行），HEAD 前后 `Compare-Object`，要求零差异（能抓出 P-22 那种残留） |
| P-42 | API 面 diff 的**口径陷阱** | 正则会把**顶层接口/常量的缩进行**误计入（曾出现 63 vs 49 的假差异）。跨模块搬类型时，按「类成员」口径统计并在文档中说明 |
| P-43 | **数据产物等价：逐版全量字符串 diff** | DatabaseSchema：对 v1..v47 逐版拼出 `getSchemaStatements` 返回字符串 + 建表/索引全量，前后逐字节比。**已留可复用 Node 夹具手法**（strip TS 注解 → 拼接 → `vm` 求值 → 落 JSON → 逐版比较） |
| P-44 | 提取方法体时用简单 end-marker 会**提前截断** | 按**花括号深度**计数提取（`{}` 累加/累减），不要用 `'  }'` 之类的字符串匹配 |
| P-45 | 只跑编译就宣称"没改坏" | 编译只保证语法；行为等价需 P-40/41/43 + 本地单测；**真机相关只能真机验**（会话/Swipe/分支/流式/DB 迁移） |
| P-46 | 在文档/TODO 写"真机通过"但没跑过 | **严禁**（AGENTS 约束）；没跑就写"未验证" |
| P-47 | **以为能靠日志 tag 判定"走到新代码"** | 实测 hilog 缓冲区里应用自身日志**极少**（MIS-AL00/API 24 上本轮只有 `ChatRequestBuilder` 打出 5 行，`ChatService`/`ChatOneShotGenerator`/`ChatSwipeController` 等在常规操作下**无输出**）。日志只能当**辅助**，真机主证据是 `uitest screenCap` 截图 + `uitest dumpLayout` 控件树 |
| P-48 | **拿截图预览坐标去 `uitest uiInput click`** | 设备是 **1224×2776** 真机像素，截图预览常被缩到 450×1000，直接换算点会偏（本轮在"生成章节"按钮 [54,1954][1170,2103] 上点 2125 落空）。**一律以 `dumpLayout` 的 `bounds` 取中心点**；长按菜单/Sheet 等弹层的项位置**每次重新 dump**，不复用上一屏坐标 |
| P-49 | `uitest uiInput inputText` 当纯文本注入用 | 它走**输入法**：英文空格会被自动更正成撇号、长句被折成多行（本轮 "smoke test 001" 变 `narration'test` + `001`）。需要确定内容时用**无空格短串**或分段核对 |

## 5. 数据库

| # | 坑 | 正确做法 / 证据 |
|---|---|---|
| P-50 | 改历史迁移 / DROP 表列 | **迁移只增不改、版本连续、禁 DROP**；新增列 = 新增迁移版本。`DATABASE_VERSION` 当前 **51** |
| P-51 | 用 schema 快照函数"顺手修历史语义" | `getSchemaStatements(v)` = 「从空库建到 v」；P3-3 实测 `39/40/41` 曾被并到 V42 快照（多出 world_id 列/索引）→ 已改为 → `V41_SCHEMA_STATEMENTS`。**任何 DDL 文本差异按 bug 处理**，改前先对照逐版 diff |
| P-52 | 行映射硬取列索引 | 用 `getColumnIndex >= 0` **安全回退**，保证旧 schema 兼容 |
| P-53 | `senderType='character'` 的消息没填 `senderCharacterId` | `MessageRepository` 会抛 `invalid data` |
| P-54 | 依赖已废弃功能的表（如 `worlds`） | 属**预期残留**（迁移只增不改），**勿依赖** |
| P-55 | 以为 `bm clean -n <bundle> -d` 只清聊天数据 | 它清**整个应用数据目录**（含 Preferences / Asset KeyStore）→ **模型 API Key 一并丢失**，清数据后所有 AI 相关验证都要先重新配置模型。清数据首启可用来验建库：hilog 里可见 `HandleSchemaDDL … schema<k-1->k>` 逐版跑完且无 error |
| P-81 | 列表查询默认 LIMIT 截断 + 新内容 sortOrder 追加末尾 → **会话满 50 条后新建会话"不显示"**（删几条才出现，2026-09-30 用户实测） | "全量列表"类查询必须**显式传足够大的 limit**（`ChatSessionListViewModel.reload()` → `listAllSessions(200)`，且不得越过 `MAX_LIMIT`，见 P-83）；新内容 sortOrder 分配在末尾，与 LIMIT 叠加即在 SQL 层截断、根本不进内存。排查"不显示"先查 SQL 截断，再查渲染 |
| P-82 | 看到 chats / characters 表里 **sortOrder 为负数**，以为是 bug 要"修平" | 2026-09-30 起新建会话/角色取 `min-1` 置顶（用户要求新内容排最前），持续新建会递减为负——**这是预期**。上移/下移是相邻交换、拖拽重排 `moveChatByDrag` 会整组重编号为 `(i+1)*10`，负值安全，**勿改** |
| P-83 | 给 Repository 查询方法传更大的 limit 前没查上限校验 → **运行时抛 `DatabaseError: invalid data('limit out of range')`，整列表加载失败**（2026-09-30 真机实测：`SESSION_LIST_LOAD_LIMIT` 设 500 越过 `ChatRepository.MAX_LIMIT=200`，编译期完全不可见） | 传 limit 前先 Grep 目标 Repository 的 `MAX_LIMIT` 常量；此类**参数校验错误编译不可见**，改查询参数必须沿调用链核对校验，不能只靠编译通过 |
| P-99 | 新增一版数据库迁移时**只写了 DDL 与迁移类**，漏掉注册点 → **静默失效**：漏 `DbHelper` 注册 → `buildMigrationPath` 找不到步骤，路径为空却**照样写 `user_version`**；漏 `SCHEMA_BY_VERSION` → 新装 `getSchemaStatements` 返回 `[]` 出空库；漏 `getCreateTableStatements/getCreateIndexStatements` → 同版缺表时 `ensureSchemaExists` **不自愈**（2026-10-07 v49 分类表落地时固化） | 新增一版要改 **4 处**（逐条对照）：① `database/DatabaseConstants.ets`（`DATABASE_VERSION` 自增 + 新表/列/索引常量，禁硬编码字符串）；② `database/schema/Schema<域>.ets`（DDL 常量 + `Vxx_NEW_DDL_STATEMENTS`）；③ `database/DatabaseSchema.ets`（`Vxx_TO_Vyy_DDL_STATEMENTS` / `Vxx_SCHEMA_STATEMENTS` / `SCHEMA_BY_VERSION.set` / **`getCreateTableStatements()` 与 `getCreateIndexStatements()` 两个数组**）；④ `database/DatabaseMigration.ets`（工厂 + 迁移类）+ `database/DbHelper.ets`（构造函数注册数组尾部）。验证用单测机械校验：`buildMigrationPath(旧,新).steps.length===1` 且 `getSchemaStatements(新)` 的**前 N 条与旧版逐字节相同**、尾部恰好是本版新增条数（见 `entry/src/test/local_image_category.test.ets` 的 `databaseV49Migration`） |

## 6. 领域概念坑

| # | 坑 | 正确做法 |
|---|---|---|
| P-60 | 混淆消息三层体系 | Wire=`ChatRole(system/user/assistant)`；DB=`MessageSenderType('user'/'character'/'narrator')`；UI=`ChatSenderType`。Impersonate = user role + `'character'`；Narrator = system role + `'narrator'` |
| P-61 | 直接访问 `ChatService.currentChat` | 它是 `private`，外部走 `getCurrentChat()` |
| P-62 | 以为字段名一致 | `ChatRequest.temperature/topP` 是 **number（非 optional）**；`ProviderConfig.maxTokens` ≠ `EffectiveGenerationSettings.maxOutputTokens` |
| P-63 | 自定义存储键 | 统一 `arktavern_solo` 前缀 |
| P-64 | 把 `$r()` 颜色缓存进变量 | **不缓存**；颜色一律 `$r('app.color.*')`（并做 dark 覆盖） |
| P-65 | `LazyForEach` 用 index 当 key | keyGenerator **必须用业务唯一 id**；复用组件在 `aboutToReuse` 重置视觉状态 |
| P-90 | 记忆总结请求**独立拼装 prompt** → 与聊天请求前缀不同 → LLM prompt cache **全量 miss**（60k 输入全额计费）；且每章落库后**立即**注入 head + 立即更新核心记忆（位于 head 最高位，其后全部作废）+ 立即前移窗口锚点 → 每个归档周期一次全量冷重建（自动归档下每 50 条/2 万字符一次） | ① 总结请求 = **聊天请求基座逐字节复用 + 末尾追加总结指令**（"后缀扩展"）：`ChatContextMaintenanceService` 经 `buildSummaryBaseMessages` 取 `ChatService` 重建后的 `lastBuiltRequestMessages`，`MemoryPromptBuilder.buildChapterSuffixInstruction` 生成尾部指令；无基座时回退独立 prompt。② **延迟激活**：会话级"激活边界"`activeBoundary`（`ChatMemoryModeService`，Preferences，key `chat_memory_<id>_aboundary`）——章节生成只写库，注入只取 `endPosition <= activeBoundary`、锚点也停在激活边界（实际边界更小时 clamp 自愈）；仅在手动"立即归档"或自动归档待激活达 4 章时推进边界（一次冷重建）。参考 commit `99f2469` / `d4f91a0` / `11eb2b0` |
| P-92 | 在聊天文本管线的 `sanitizeHtmlTags` **之后**才处理 `<img>` 标签 → 消毒正则 `/<[^>]+>/g` 已把标签连同 src 整段删除，URL 无从提取（2026-10-06 消息内图片渲染） | 任何依赖 HTML 标签**属性内容**的抽取（img src / a href 等）必须在 `buildLightChunks` 的 `sanitizeHtmlTags` **之前**做，先抽走再消毒；仅依赖标签存在性/换行语义的处理（如 BLOCK_HTML_TAGS 边界）不受此限 |
| P-93 | 角色卡 HTML（`<details>` 状态栏等）在纯文本回退里**标签之间出现大段空行**（2026-10-06 用户报"知名艺术画廊馆长"卡）。两个叠加原因：① 卡片内嵌数据是 **CRLF**，`\n\r\n` 使 `/^\n+\|…/` 的 `\n{3,}` 收敛失效、每行尾残留 `\r`；② 块级标签直接换成 `\n`，而 HTML 源码「每标签一行 + 前导缩进」→ 产生大量**仅含空白**的行，逐行渲染即成空行 | `sanitizeHtmlTags` 里：① 先 `/\r\n?/g → '\n'` 统一换行；② 块级标签先落中间态占位符 `BLOCK_BOUNDARY`（`\uE400`），再 `/[ \t]*占位符(?:[ \t\n]*占位符)*[ \t]*/ → '\n'` 把「占位符 + 周边缩进空白」整段收敛为单个换行（`<br>` 仍走 `\n`，故 `<br><br>` 的空行语义保留）。回归用例见 `frontend_interaction.test.ets` 的 `HtmlBlockWhitespace`（CRLF+缩进 HTML → 紧凑无空行、纯文本 `\r\n\r\n` → 保留单空行且无 `\r`） |

| P-94 | 在 ArkTS 里 `catch (e) { throw e; }` 直接重抛原值 | 编译器报 **`arkts-limited-throw`**（throw 不接受任意类型）。重抛必须转成 `Error`：`throw new Error('…:' + (e as Error).message)`（仓内 service 层通用写法），或至少 `throw e as Error`。（2026-10-06 本地图片库 `LocalImageService.addImage` 入库失败回滚时踩到） |
| P-95 | `Image(url)` 在**加载完成前没有固有高度**（`width('100%')` 下高度为 0）→ 远端图片未就绪时气泡里完全看不到"这里有一张图"，用户不知道有图在加载（2026-10-06 用户反馈） | 图片节点**常驻挂载**负责触发加载，未加载时在其上层叠一个**有固定最小高度**的占位（`constraintSize({ minHeight: … })`），由 `onComplete` 撤占位、`onError` 转失败态；占位文案用解析层保留的**原始语法源码**（`ImageChatRenderChunk.source`）。注意 ArkUI `Stack` 对齐只能用构造参数 `Stack({ alignContent })`，**没有** `.justifyContent()/.alignItems()` |
| P-96 | 在 `bindContentCover` 里做图片"从缩略图位置展开、从哪来回哪去"的一镜到底：只开模态（`ModalTransition.DEFAULT`）得到的是系统默认整屏转场；或绑了 `geometryTransition` 却没在动画闭包内改状态 → **动画不生效、组件闪现**（2026-10-06 消息内图片放大） | 四件套缺一不可：① 缩略图与预览大图绑**同一个** `geometryTransition(id)`（同一 id 只能绑两个组件、一 in 一 out；id 必须全局唯一，不能复用只在单条消息内唯一的 `chunk.id` —— 用模块级计数器生成）；② `bindContentCover` 的 `modalTransition` 必须设 **`ModalTransition.NONE`**，否则系统转场与共享元素打架；③ 显隐开关必须写在 `this.getUIContext().animateTo({duration, curve}, () => { show = … })` **闭包内**（一镜到底时长/曲线跟随 animateTo），`onWillDismiss`（返回键/侧滑关闭）里同样要包 animateTo；④ 参与转场的节点要带 `transition(TransitionEffect.OPACITY)`（保证离场不被立即析构）。另：预览大图的 **frame 开场就必须是"按图片宽高比 fit 进屏幕"的矩形**（缩略图 `onAreaChange` 量出宽高比 + `display.getDefaultDisplaySync()` 换算屏幕 vp），否则几何转场的目标矩形是错的、动画会跳变。兜底：根节点带 opacity 过渡，即使共享元素未生效也只退化为淡入淡出，不会硬切 |
| P-97 | 图片预览的"双指缩放 + 放大后拖动"用 **图形变换属性**（`.scale()` + `.translate()`，或 `.scale` 的 `centerX/centerY` 锚点）表达：真机上**拖动与手指不成 1:1（明显偏慢）**、**缩放始终从组件中心放大**（2026-10-06 消息内图片预览，两次修复均未生效）。根因：**手势量是按"组件原始区域（未变换）"度量的，而变换属性作用在已变换的坐标系上**——两者的换算比例由框架内部决定、不对外承诺（PanGesture 文档原话："当组件应用了 scale 缩放变换时，distance 的实际识别距离会按照 scale 比例进行缩放"；`offsetX/offsetY`、`pinchCenterX/Y` 的官方口径都是"relative to the original area of the current component"） | **缩放/平移全部走布局量**，不用任何图形变换：放大 = 直接改 `Image` 的 `width/height`（`previewW × s`，`objectFit(Contain)` 保证等比），平移 = `.offset({ x, y })`（vp，布局偏移）。布局量没有"叠加顺序"语义，1:1 可预期。锚点与位移统一改用**窗口坐标**：`GestureEvent.fingerList[].globalX/globalY`（"相对应用窗口左上角，vp"，不受组件缩放影响）——拖动 = 当前帧窗口坐标 − 起手帧窗口坐标；焦点缩放 = 两指中点 + `a1 = (1 - s1/s)(F - 窗口中心) + (s1/s)·a`（逐帧用上一帧倍率 `s`）。窗口中心 = 全屏模态的中心（`display.getDefaultDisplaySync()` ÷ `densityPixels`）。教训（同类问题通用）：**只要发现"位移/缩放比例不对"，先怀疑手势量与变换量的坐标系口径不一致，而不是调系数**；能用布局量表达就不要用变换属性 |
| P-98 | 取手指位置时只判 `GestureEvent.fingerList.length` 就按下标取值（`fingerList[0].globalX`）→ **jscrash** `TypeError: Cannot read property globalX of undefined`（2026-10-06 图片预览捏合，`ChatMessageImage.ets:409`，真机日志 `[FRAMEWORK,PROCESS_KILL,JS_ERROR]`）。官方口径：**未参与本次手势触发的手指，其在 `fingerList` 中对应的位置为空**；而类型声明写的是 `FingerInfo[]`（非可选）——**类型骗人**，编译器完全看不出问题 | 逐槽判空后再用：`const f: FingerInfo \| undefined = list[i]; if (f === undefined) { continue; }`（把元素赋给 `FingerInfo \| undefined` 的局部变量就能合法比较），并把非 `[0, +∞)` 的坐标（undefined/NaN）一并当无效跳过；顺手用 `count` 做门控（**双指才做缩放锚点、单指才做拖动**，捏合进行中给拖动设让位标志，否则两指整体平移会被"锚点 + 拖动"各算一遍）。凡是"框架给数组/事件对象里可能缺项"的地方（`fingerList` / `touches` / 可选回调整体）都要按"类型不可信、逐项判空"处理 |
| P-100 | **把"分组"实体化**成一个新领域概念（v49：自定义"分类"表 + "分类↔图片"/"分类↔角色卡"多态关联表 + 按分类自动维护的受管清单预设 + 归属三态互斥）→ 用户实测后直接否掉："明明可以用很简单的方法"（2026-10-07）。根因：设计前没和用户对齐**心智模型**，凭自己的"规范化直觉"造实体，结果概念多、互斥规则绕、还要维护派生层 | 分组类需求**先对齐用户怎么想**，再优先"挂在用户已有的对象上"：v50 改为 **标签 = 普通提示词预设** —— 把 `- 名字：描述` 写进预设正文就算打上该标签（反推归属、不建关联表、不造受管层），多对多自然成立、用户还能直接编辑正文与启用/禁用。教训：**能复用用户已有概念（预设）时，不要新建实体**；"规范化"不是理由，**能少一层就少一层** |
| P-101 | 图片的**名字是它在提示词里的唯一标识**，但库内改名/改描述/删图后没有同步回"引用它的文本"（预设正文）→ 出现三类静默错位：改名后标签条目成了幽灵名（图片行显示"未分类"、模型按旧名引用却已解析不到）、描述改了正文里还是旧描述、删图后正文残留死条目 | 库内变更必须**回写引用处**：`LocalImageService.renameImage` / `updateImageDescription` / `removeImage` 统一走 `rewritePresetEntries`（只改"提到该名字"的预设，逐行 `upsert/remove`，正文未变则跳过写入）。判断"是否提到"用与写入同一套解析（`utils/LocalImageTagText.hasTagEntry`）——**格式与解析只写一处** |
| P-102 | 看到 `local_images.character_id` 列还在，以为"图片还有全局/角色归属"（v50 已停用该概念，代码不再读写；迁移只增不改故列保留） | **勿依赖该列**：图片池模型下所有图片等价，分组一律用标签（= 预设正文）。新写查询/迁移时不要引用它；`nameTaken(nameKey)` 已是全局唯一语义 |
| P-103 | 以为还有"受管图片清单预设"（列表页只读、导出排除、`arkimg-global` / `arkimg-char-*` 自动维护） | v50 起**没有受管预设**：标签就是普通预设，用户可编辑/删除/导出/启用；`isManagedImagePresetId()` 现在**恒返回 false**（只为不动预设列表/编辑页的 `isManagedPreset` 分支而保留，是死分支，引用清零后连同函数一起删）。v49 期间若产生过 `arkimg-*` 预设，现在会以普通预设出现，可直接删 |
| P-104 | 把资源当字符串拼接：`$r('app.string.x') + 字符串` → 界面显示 **`[object Object]…`**（2026-10-07 本地图片库标签行）。`$r()` 返回的是 **Resource 对象**，`Resource + string` 会走对象 `toString()` | 资源与动态文本**必须分开渲染**（两个 `Text` + `Row`/`Flex`，资源那个不参与拼接）。同类要警惕的还有模板串 `${$r(...)}`、`Resource` 与数组 `join`。**扫证过：全仓仅此一处**；新增拼接前先确认右侧是不是普通 string |
| P-105 | 给请求加多模态内容块时，用「接口联合类型」表达（`type Part = TextPart \| ImagePart`，再往里塞对象字面量）→ ArkTS 严格模式下**字面量无法推断目标类型**直接编译失败（2026-10-07 AI 图片命名，`OpenAIContentPart`） | 用**单接口 + 可选字段**、由 `type` 决定哪组字段有效（`{ type, text?, image_url? }`），构造时逐层写**显式类型注解的局部变量**、不新增 `as`。`JSON.stringify` 会丢弃 `undefined` 键，不会产出脏字段 |
| P-106 | 视觉输入（图片）挂错消息角色：放到 `system`/`assistant` 消息上 → 端点直接 **400**（DeepSeek 明确"仅 user / developer 消息可带图"；2026-10-07 AI 图片命名）。另一类同类坑：把 base64 图片按保存上限（50MB）校验 → 请求体膨胀到约 68MB 必被拒 | ① 图片**只挂最后一条 user 消息**，并在 `validateRequest` 加守卫（带图但无 user 消息 → InvalidRequest）；② 送 AI 的图片体积用**独立的小上限**（本项目 4MB），与"保存到沙箱"的上限分开；③ deepseek 侧用 `image_url.detail='low'`（服务端降到 512×512、单图 ≤384 tokens）即可，不必在端上做压缩 |
| P-107 | 把 `local_images.file_uri`（`file:///绝对路径` 形式）直接喂给 ArkUI **Video** 组件 → 视频不加载/黑屏：Video 的 `src` 明确**只认沙箱 URI `file://<bundleName>/<sandboxPath>`**（`Image` 组件接受 `file:///绝对路径`，两者口径不同；2026-10-07 本地视频） | **落库仍统一存 `file:///绝对路径`**（不改存储层——改了 `LocalImageAssetStore.deleteByUri` 剥前缀就删不掉文件）；**读取侧**用 `fileUri.getUriFromPath(path)`（`@kit.CoreFileKit`）转成 Video 形式，统一收口在 `utils/LocalImageResolution.toPlayableUri(uri, mediaType)`（聊天渲染与图片库详情播放共用） |
| P-108 | ArkUI **Image 组件没有"暂停动图"属性**（GIF/WEBP 可见即播放）；文档提到的 `AnimatedDrawableDescriptor` + `AnimationController` 需真机验证且 Previewer 不支持（2026-10-07 本地视频/动图需求评估） | 若确需"GIF 默认暂停"，只能走 `AnimatedDrawableDescriptor({ autoPlay:false })` + `getAnimationController()`（API 21+），或"气泡内先渲染首帧静态图、放大后才加载动图"；**本期未实现 GIF 暂停**（用户拍板暂缓），勿以为 `Image` 有开关 |

## 7. 文档与协作

| # | 坑 | 正确做法 |
|---|---|---|
| P-70 | 新增一份"变更日志"文档 | **不建 changelog**：会与 git 重复并腐烂。变更历史以 git 为准（`git log --grep="P3-2"` 可按功能捞）；里程碑记 `CURRENT.md §5` |
| P-71 | 同一事实写在两份文档里 | **同一事实只允许出现一次**（重复即 bug）：定位表→`FEATURE_MAP.md`；资产→`INVENTORY.md`；坑→本文件；当前状态→`CURRENT.md` |
| P-72 | 改了代码不更新对应文档 | 代码改动若影响 定位表/资产清单/踩坑，**同一次提交**内更新 |
| P-73 | 文档与代码冲突时凭文档改代码 | **以代码为准**，并当场修文档 |
| P-74 | AGENTS.md 越写越长 | AGENTS.md 只放「**能改变 agent 行为**的规则 + 指针」；细节拆到 `docs/handover/`。不具体 = 无效（`写干净的代码` ✗ / `禁止 console.log，用 utils/Logger` ✓） |
| P-75 | **统计类清单凭印象/抄上一版文档**（本轮实测：P3-4 曾写"导入 DbHelper 的服务 6 个""27 个页面"，实际是 **10 个**、**34 个页面**） | 任何"清单/计数"**必须当场扫描代码得出**（`Grep`/目录遍历），并把命令与日期写进文档；发现旧数字不对就**当场更正并留下修正记录** |
| P-76 | 用 `Edit` 往 Markdown **表格插入新行**时，`old_string` 只取行首（如 `\| 2026-09-28 \| **某标题** \|`）→ 会把**原行从中间切断**，新行与原行剩余内容挤成一行（`CURRENT.md` §5 本轮踩了 **2 次**） | `old_string` 必须包含**整行内容**（含行尾文字），或改用脚本按行操作（PowerShell 读行数组 → 插入/交换 → 写回 LF 无 BOM，见 P-05/P-06）。改完**必须校验**：`Select-String -Pattern "^\| 2026-"` 看行数/顺序，再 `Select-String -Pattern "^ 起因："` 确认没有孤立残行 |
