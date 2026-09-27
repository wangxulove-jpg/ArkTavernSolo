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

## 5. 数据库

| # | 坑 | 正确做法 / 证据 |
|---|---|---|
| P-50 | 改历史迁移 / DROP 表列 | **迁移只增不改、版本连续、禁 DROP**；新增列 = 新增迁移版本。`DATABASE_VERSION` 当前 **47** |
| P-51 | 用 schema 快照函数"顺手修历史语义" | `getSchemaStatements(v)` = 「从空库建到 v」；P3-3 实测 `39/40/41` 曾被并到 V42 快照（多出 world_id 列/索引）→ 已改为 → `V41_SCHEMA_STATEMENTS`。**任何 DDL 文本差异按 bug 处理**，改前先对照逐版 diff |
| P-52 | 行映射硬取列索引 | 用 `getColumnIndex >= 0` **安全回退**，保证旧 schema 兼容 |
| P-53 | `senderType='character'` 的消息没填 `senderCharacterId` | `MessageRepository` 会抛 `invalid data` |
| P-54 | 依赖已废弃功能的表（如 `worlds`） | 属**预期残留**（迁移只增不改），**勿依赖** |

## 6. 领域概念坑

| # | 坑 | 正确做法 |
|---|---|---|
| P-60 | 混淆消息三层体系 | Wire=`ChatRole(system/user/assistant)`；DB=`MessageSenderType('user'/'character'/'narrator')`；UI=`ChatSenderType`。Impersonate = user role + `'character'`；Narrator = system role + `'narrator'` |
| P-61 | 直接访问 `ChatService.currentChat` | 它是 `private`，外部走 `getCurrentChat()` |
| P-62 | 以为字段名一致 | `ChatRequest.temperature/topP` 是 **number（非 optional）**；`ProviderConfig.maxTokens` ≠ `EffectiveGenerationSettings.maxOutputTokens` |
| P-63 | 自定义存储键 | 统一 `arktavern_solo` 前缀 |
| P-64 | 把 `$r()` 颜色缓存进变量 | **不缓存**；颜色一律 `$r('app.color.*')`（并做 dark 覆盖） |
| P-65 | `LazyForEach` 用 index 当 key | keyGenerator **必须用业务唯一 id**；复用组件在 `aboutToReuse` 重置视觉状态 |

## 7. 文档与协作

| # | 坑 | 正确做法 |
|---|---|---|
| P-70 | 新增一份"变更日志"文档 | **不建 changelog**：会与 git 重复并腐烂。变更历史以 git 为准（`git log --grep="P3-2"` 可按功能捞）；里程碑记 `CURRENT.md §5` |
| P-71 | 同一事实写在两份文档里 | **同一事实只允许出现一次**（重复即 bug）：定位表→`FEATURE_MAP.md`；资产→`INVENTORY.md`；坑→本文件；当前状态→`CURRENT.md` |
| P-72 | 改了代码不更新对应文档 | 代码改动若影响 定位表/资产清单/踩坑，**同一次提交**内更新 |
| P-73 | 文档与代码冲突时凭文档改代码 | **以代码为准**，并当场修文档 |
| P-74 | AGENTS.md 越写越长 | AGENTS.md 只放「**能改变 agent 行为**的规则 + 指针」；细节拆到 `docs/handover/`。不具体 = 无效（`写干净的代码` ✗ / `禁止 console.log，用 utils/Logger` ✓） |
| P-75 | **统计类清单凭印象/抄上一版文档**（本轮实测：P3-4 曾写"导入 DbHelper 的服务 6 个""27 个页面"，实际是 **10 个**、**34 个页面**） | 任何"清单/计数"**必须当场扫描代码得出**（`Grep`/目录遍历），并把命令与日期写进文档；发现旧数字不对就**当场更正并留下修正记录** |
