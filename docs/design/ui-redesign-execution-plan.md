# ArkTavernSolo · UI 重设计执行计划（Token → Pilot 屏）

> 依据：`docs/design/ui-redesign-summary.md`（设计规范）+ `docs/design/ui-redesign-design-draft.html`（视觉稿）。
> 本文档是其**可执行落地版**，基于 2026-09-14 代码现状盘点，供 goal 模式逐项执行。
> 范围纪律：**只动视图/资源层，不动任何业务逻辑、ViewModel、Service、DB**。

---

## 0. 范围与阶段划分

| Phase | 内容 | 本次 goal | 回滚粒度 |
|---|---|---|---|
| P1 | Token 层增量（双轨同步） | ✅ | 单独 git commit |
| P2 | Pilot 屏 `CharacterListPage` 改造 | ✅ | 单独 git commit |
| P3 | 三主题视觉验证 + 编译 | ✅ | — |
| P4 | 聊天页（`ChatPage` 视觉层） | ❌ 后续 goal | — |
| P5 | 市场卡（`MarketCharacterCard`） | ❌ 后续 goal | — |

**本次 goal 的 DoD（完成定义）**：P1/P2/P3 全部勾选、`hvigorw` 编译通过、三主题下角色列表页无回归、设计稿核心要素（阴影/渐变/标签/chip/动效）落地。

---

## 1. 现状盘点（2026-09-14 核实）

### 1.1 Token 双轨架构
- **代码轨**：`entry/src/main/ets/theme/ThemePalette.ets` —— `ThemeColors` 接口 + LIGHT/DARK/TAVERN 三套色板 + `forTheme()` 静态取色。
- **资源轨**：`entry/src/main/resources/base/element/color.json`（浅色）+ `resources/dark/element/color.json`（深色）—— 已有 `app_bg / app_surface_1 / app_surface_2 / app_accent / app_on_accent / app_danger / app_text_*` 等 12 个 `app_*` 语义色。
- **纪律**：两轨必须保持同名对齐（ThemePalette 头注释明确要求）。Light/Dark 走资源轨自动生效，Tavern 走 `setColorMode(DARK)` + Palette 覆盖。

### 1.2 缺口清单
| 项 | 现状 | 目标 | 动作 |
|---|---|---|---|
| `ThemeColors.surface3` | 无（有近似 `selectedSurface: '#3D3220'`） | Tavern `#3D2E1A` | **新增字段**，`selectedSurface` 保留不动 |
| `ThemeColors.goldenStrong` | 无 | Tavern `#F2DCA6` | **新增字段** |
| TAVERN `accent` | `#D4A23B` | `#E3C27A`（提亮） | **改值**（设计意图本身） |
| TAVERN `error` | `#C45A4A` | `#E07A5A` | **改值**（对齐设计稿 danger） |
| `app_radius_xl` | 无（max=lg 16vp） | `22vp` | 新增 float.json |
| `app_font_display` | 无 | `30fp` | 新增 float.json |
| `app_font_micro` | 无 | `10fp` | 新增 float.json |
| `app_font_title` | **26fp** | 设计稿写 22fp | **不改，保留 26fp**（见决策 D1） |
| 资源轨 `app_surface_3` / `app_golden_strong` | 无 | 与代码轨对齐 | 新增 base+dark 两个 color.json |

### 1.3 硬编码扫描结果
- `#E74C3C`：**7 处，全部在 `CharacterListPage.ets`**（行 94/103/272/425/514/601/658）→ 全部替换。
- `Color.White`：21 处 / 11 文件 → **本次只清 `CharacterListPage.ets` 的 6 处**，其余文件留给各自屏幕的改造 Phase（P4/P5 或后续）。

---

## 2. 决策记录（执行时不再讨论）

- **D1 字阶冲突**：设计稿 `app_font_title: 22fp` 与现状 26fp 冲突。**保留 26fp 不改**——改现有值会让全 App 3464 处 `$r()` 引用的排版全变，超出"体验层小步改动"边界。如需字阶整体收紧，单独立项。
- **D2 surface3 vs selectedSurface**：语义重叠但**并存**——`selectedSurface` 已被引用，动它是回归风险；`surface3` 作为新视觉阶梯（P2 卡片选中态用）纯增量引入。
- **D3 danger 替换路径**：`#E74C3C` → `$r('app.color.app_danger')`（资源轨，自动跟随浅/深主题），**不走** ThemePalette（避免引入 ThemeColors 实例传递）。
- **D4 搜索框实现**：页面内 `@State searchQuery` + 本地 `filter()`，**不动 `CharacterListViewModel`**。
- **D5 组件化边界**：空状态/错误提示**不强制抽组件**（避免过度工程），仅当同一判断在文件内重复 ≥3 处才抽 `@Builder`。

---

## 3. Phase 1 — Token 层增量（双轨同步）

### 3.1 `entry/src/main/ets/theme/ThemePalette.ets`

1. `ThemeColors` 接口新增两个字段（带注释）：
   ```ts
   /** 三级 Surface(选中态/新视觉阶梯) */
   readonly surface3: string;
   /** 金色渐变高光(Tavern) */
   readonly goldenStrong: string;
   ```
2. 三套色板全部补齐（interface 是 readonly，缺字段编译不过）：

   | 色板 | surface3 | goldenStrong |
   |---|---|---|
   | LIGHT | `#E0E6F0`（选中偏蓝灰，视觉验证后可调） | `#8FA4F8`（accent 提亮版） |
   | DARK | `#2E3852`（与现有 selectedSurface 同值） | `#A3BCFF` |
   | TAVERN | `#3D2E1A` | `#F2DCA6` |

3. TAVERN 改值（设计意图）：`accent: '#D4A23B' → '#E3C27A'`；`error: '#C45A4A' → '#E07A5A'`。
4. （可选，若 P2 需要）新增静态取色 helper：`goldenStrongColor(effectiveTheme)` / `surface3Color(effectiveTheme)`，模式照抄现有 `surface2Color()`——Tavern 走 Palette、其余走 `$r('app.color.app_surface_3')`。

### 3.2 `entry/src/main/resources/base/element/color.json` + `resources/dark/element/color.json`

两个文件**同步**新增（值与 3.1 表格一致）：
- `app_surface_3`：base `#E0E6F0` / dark `#2E3852`
- `app_golden_strong`：base `#8FA4F8` / dark `#A3BCFF`

> 注意：dark 目录只覆盖与 base 不同的项，但按本项目现有习惯（app_* 双轨对齐），两个文件都显式写全，避免遗漏。

### 3.3 `entry/src/main/resources/base/element/float.json`

新增三项（**不动任何现有项**）：
```json
{ "name": "app_radius_xl",     "value": "22vp" },
{ "name": "app_font_display",  "value": "30fp" },
{ "name": "app_font_micro",    "value": "10fp" }
```

### 3.4 阴影 Token（轻量方案）

ArkUI 无资源型 shadow token，**不建全局常量文件**（避免过度工程）。P2 直接在使用处内联：
- 卡片阴影：`.shadow({ radius: 18, color: '#99000000', offsetX: 0, offsetY: 6 })`
- 金色辉光（仅 Tavern/选中态）：`.shadow({ radius: 18, color: '#47E3C27A', offsetY: 4 })`

### ✅ P1 验证
- `hvigorw assembleHap`（或 DevEco 编译）通过——interface 新字段三套色板必须补齐，否则此步暴露。
- grep 确认：`surface3` / `goldenStrong` 在 LIGHT/DARK/TAVERN 三处均有值。
- **git commit**（回滚点 1）：`feat(theme): add surface3/goldenStrong tokens, brighten tavern accent (#E3C27A)`。

---

## 4. Phase 2 — Pilot 屏改造（`entry/src/main/ets/pages/CharacterListPage.ets`）

按依赖顺序分 5 步，**每步完成后编译一次**，失败立即修复再进下一步。

### 步骤 2.1 清硬编码（机械替换，先做）
- 7 处 `'#E74C3C'` → `$r('app.color.app_danger')`（行 94/103/272/425/514/601/658，以实际 grep 为准）。
- 6 处 `Color.White` 逐处判断：
  - accent 按钮上的白字（如行 78 导入按钮）→ `$r('app.color.app_on_accent')`
  - 其余按上下文 → `textPrimary` 语义色
- 编译通过后可单独 commit：`refactor(ui): replace hardcoded colors in CharacterListPage with tokens`。

### 步骤 2.2 头部：副标题 + 搜索框
- 标题栏下方加副标题行：`{N} 位 · {M} 位在使用`，字号 `app_font_caption`、色 `textTertiary`。
- 搜索框：胶囊造型（`borderRadius(20)`、高 36、`inputBg` 背景、放大镜 SymbolGlyph），`@State searchQuery: string` + `onChange`；列表 ForEach 数据源改为 `this.filteredCharacters()`（本地 filter，name/description 包含匹配，忽略大小写）。
- 搜索无结果时显示轻量空提示 Text（不新建组件）。

### 步骤 2.3 角色卡视觉升级（`characterCard` builder）
对照设计稿 §4.1：
1. **阶梯表面**：卡片 `surface1` → 内部嵌块（描述区/元信息区）`surface2`；选中/使用中态 `surface3`。
2. **阴影**：卡片加 3.4 的 `shadowCard`；「使用中」卡片额外金色辉光（仅 Tavern 主题，判断 `this.effectiveTheme === 'tavern'`）。
3. **头像占位**：纯色首字母块 → 暖色渐变（`linearGradient` 从 `surface2` 到 `accent` 的 30% 透明度混色，或直接 `#332715 → #E3C27A` 渐变 + 首字母金字）。
4. **状态标签**：「使用中」金色实心（`accent` 底 + `onAccent` 字，小圆角 chip）；「已停用」金色描边（`accent` 描边 1vp + `accent` 字，透明底）。
5. **元信息 chip**：底部"上次对话时间 / 消息数"统一为小 chip（`app_font_micro`、`surface2` 底、`textTertiary` 字、`app_radius_sm` 圆角）。
6. **圆角**：卡片 `app_radius_lg(16)`，嵌块 `app_radius_md(12)`。

### 步骤 2.4 动效
- 按压缩放：`.scale({ x: 0.97, y: 0.97 })` + `.animation({ duration: 140, curve: Curve.Spring })`（作用于卡片外层，配合 `@State pressedIndex` 或 `onClick` 态）。
- 列表入场 stagger：`aboutToAppear` 后首帧，ForEach 各项 `.translate`/`.opacity` + 按索引延迟 `index * 80ms` 的 `animateTo`。实现取最简：`onAppear` 里 `animateTo` 单卡片 opacity 0→1。
- **无障碍**：检测系统"减少动态效果"不可用时直接展示终态（简单做法：stagger 仅在首屏做一次，失败静默降级为无动画）。

### 步骤 2.5 自查清理
- 确认未触碰 `CharacterListViewModel` / `AppServices` / router 逻辑。
- 确认所有新增颜色引用均走 Token（grep 新写入的 `#` 字面量仅允许出现在 3.4 阴影 color 处）。

### ✅ P2 验证
- `hvigorw assembleHap` 通过。
- **git commit**（回滚点 2）：`feat(ui): character list visual upgrade (shadow/gradient/chips/stagger)`。

---

## 5. Phase 3 — 验证

1. **编译**：`hvigorw assembleHap` 通过（同一命令最多尝试 3 次，失败先定位再改，不盲重试）。
2. **三主题视觉检查**（模拟器即可，真机断开只重连一次）：
   - Light / Dark / Tavern 各进一次角色列表页。
   - 检查项：卡片阴影可见、渐变头像无色块断层、「使用中」金标签对比度足够、搜索框可用且过滤正确、错误提示色（可临时触发导入错误）在浅色下可读。
   - 对照 `ui-redesign-design-draft.html` 屏一截图比还原度，不求像素级一致，求要素齐全。
3. **回归自查**：新建/编辑/删除/设为当前/导入/导出各点一遍（这是 Pilot 屏自带的业务动作，必须全绿）。
4. 更新本文档勾选状态 + 在 commit message 里记录验证结论。

---

## 6. 风险与回滚

| 风险 | 概率 | 缓解 |
|---|---|---|
| TAVERN accent 提亮后某些页面对比度劣化 | 中 | P3 三主题过一遍；劣化处单独调，不回滚整个 P1 |
| interface 加字段漏补某套色板 | 低 | 编译期强约束（readonly 缺字段直接报错） |
| stagger 动效在低端机卡顿 | 低 | 动画仅 opacity/translate，且只首屏一次 |
| 搜索 filter 大小写/空串边界 | 低 | 空串返回全量；`toLowerCase()` 后匹配 |

**回滚**：P1、P2 各自独立 commit，任一 Phase 出问题 `git revert` 对应 commit 即可，互不牵连。

---

## 7. 执行检查表

- [x] P1.1 ThemeColors 接口 + 三套色板新增 surface3/goldenStrong
- [x] P1.2 TAVERN accent → #E3C27A、error → #E07A5A
- [x] P1.3 base/dark color.json 新增 app_surface_3 / app_golden_strong
- [x] P1.4 float.json 新增 app_radius_xl / app_font_display / app_font_micro
- [x] P1.5 编译通过 + commit（回滚点 1）— commit 13dea08，BUILD SUCCESSFUL
- [x] P2.1 清 7 处 #E74C3C + 5 处 Color.White → Token，+ 编译（回滚点 1 后；delete 对话框确认键保留 Color.White：红底白字无对应用户 token，各主题对比度均最优，刻意不回退）
- [x] P2.2 头部副标题 + 胶囊搜索框（本地过滤）— 副标题内外联文案（项目无 getStringSync 惯例）
- [x] P2.3 角色卡：阴影/渐变头像/使用中·已停用标签/元信息 chip — 注：消息数因不改 ViewModel 拿不到，chip 仅展示上次修改时间
- [x] P2.4 按压缩放（onTouch+scale 0.97）+ 入场 stagger（appearedCount+80ms 定时器，搜索 onChange 重置）
- [x] P2.5 自查未触碰业务层（git status 仅 CharacterListPage.ets + string.json）+ 编译通过 + commit（回滚点 2）
- [ ] P3.1 hvigorw 编译通过
- [ ] P3.2 三主题视觉检查（阴影/渐变/标签/对比度）
- [ ] P3.3 业务动作回归（增删改/设当前/导入导出）
- [ ] P3.4 更新本文档勾选状态

---

## 8. 后续（不在本次 goal）

- P4 聊天页：顶部暖金渐变背景、气泡主次对比、打字指示动画、输入栏胶囊化 + 发送键辉光。`ChatPage` 约 4400 行，**只改 build 层视觉**，严禁顺手重构。
- P5 市场卡：`MarketCharacterCard.ets` 封面上浮渐变遮罩 + 角标细分 + 信息节奏。
- 届时同步清理各自文件内残余 `Color.White`。
