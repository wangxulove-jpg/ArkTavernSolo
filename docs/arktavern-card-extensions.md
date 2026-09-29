# 角色卡扩展规范（arktavern-card-extensions）

> 本文档定义 **ArkTavern App 角色卡自定义扩展**`extensions.arktavern` 的完整数据契约与交互标准，
> 供三个角色使用，避免各自拆一套导致冲突：
> 1. **角色卡作者 / 转换工具**：按本规范改造角色卡，保证开箱即用；
> 2. **App 端实现**：按本规范读取 `status`（角色状态）与 `frontend`（HTML 界面）并渲染；
> 3. **Bridge**：`window.arktavern.*` 方法与 App → 页面事件统一遵循本规范。
>
> 当前规范版本：`v1`（与 `CardFrontendBridge.getVersion()` 保持一致）。
> 变更时必须：同步更新 `CardFrontendBridge.ets`、`FrontendCardPage.ets`、本规范，
> 且**不破坏已导入的角色卡（向前兼容）**。

---

## 1. 设计原则

- **状态由角色卡声明，不由模型运行时自由发挥**：字段集合（骨架）由角色卡静态定义；
  模型每轮只负责在回复里带当前值，不增删改字段名。
- **`frontend` 向后兼容**：旧的「字符串 = 完整 HTML、全屏页」写法继续有效；
  新的「对象」写法额外支持面板、布局、版本等扩展。
- **无声明即关闭**：角色卡未声明某项能力时，该能力整体隐藏，不注入多余指令、不显示入口。
- **对话始终在 ChatPage**：HTML 界面（含面板模式）只是展示与交互容器，消息收发仍走正常聊天链路。

---

## 2. `extensions.arktavern` 统一结构

```json
{
  "extensions": {
    "arktavern": {
      "bridge_version": 1,
      "status": {
        "fields": [
          { "name": "金币", "desc": "回合制数值,初始 0", "type": "number", "locked": false },
          { "name": "地点", "desc": "当前位置/场景", "type": "string", "locked": false }
        ],
        "min": 1,
        "max": 8
      },
      "frontend": {
        "html": "<完整 HTML 字符串,含 <style>/<script>>",
        "mode": "panel",
        "title": "世界地图",
        "size": { "width": 360, "height": "65%" }
      }
    }
  }
}
```

- `extensions.arktavern.*` 未知子字段**原样保留**，App 不丢弃。
- `bridge_version` 可选；缺省视为 `1`。仅供前端/工具自查，不做强制校验。
  用了 v2 能力（`getMessages` / `messageCount` / `chrome`）的卡建议写 `2`，便于老 App 侧识别（老 App 上页面仍可运行，只是能力降级）。

---

## 3. `status`：声明式角色状态

### 3.1 结构

`status` 是对象，包含字段列表 `fields`（`status.fields` 缺省等同 `[]`）。

每个字段 `{ name, desc?, type?, locked? }`：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | 是 | 字段名，唯一 |
| `desc` | string | 否 | 字段含义/取值建议，喂给模型帮助其准确更新值 |
| `type` | string | 否 | `string` / `number`（提示与 UI 渲染用；值一律以字符串存储） |
| `locked` | boolean | 否 | 默认 `false`。`true` 表示该字段值**禁止 AI 更新**（仅展示/人工维护） |

`min` / `max` 为可选提示（建议字段数），仅供转换工具与 UI 参考，不强制。

### 3.2 行为契约（核心改变）

- **字段集合由角色卡锁定**：存在性与字段名不随对话轮次增删改。模型无权新增/删除/改名。
- **模型每轮只更新已声明字段的 `value`**：且 `locked=true` 的字段不更新。
- **解析机制**（沿用现有流）：模型在回复正文后输出 `<|status|>{json}<|/status|>` 块 →
  （结束标记以解析器为准 = `<|/status|>`，见 `ChatStatusBlockParser.STATUS_BLOCK_CLOSE`）
  解析 → 仅取与 `status.fields` 同名的字段值合并更新；不同名或无关字段丢弃。
- **无状态块 = 本论无变更**：不改变任何字段。
- **无 `status` 声明**：状态功能**整体禁用**——不注入状态指令、ChatPage 不显示「状态」入口、
  `getState()` 返回 `[]`、Bridge 不推送 `status_update`。
- 持久化与排序：内存模型沿用 `ChatStatusState`（用户在前、AI 在后），
  `fromUser` 语义保留用于「人工添加的、可在已声明框架外临时出现的字段」，但默认由声明覆盖。

---

## 4. `frontend`：HTML 界面

### 4.1 两种写法（向后兼容）

| 写法 | 形态 | 含义 |
|---|---|---|
| 字符串 | `"<html>…</html>"` | 兼容旧卡，等价 `mode:"fullscreen"`，全屏页 |
| 对象 | `{ html, mode?, title?, size?, chrome?, autoOpen? }` | 新卡，支持面板模式、沉浸全屏与自动打开 |

- `html`：完整 HTML 字符串，CSS/JS 全部内联。**大小上限 512KB**（UTF-8 序列化）。
  超限：保留但不启用，App 提示「界面过大未启用」。
- `mode`：`fullscreen`（默认） | `panel`。
- `title`：面板/页标题，可选（缺省用角色名）。
- `size`：面板模式下的建议尺寸 `{ width?: number, height?: "45%"/"65%" 等 vp 或百分比 }`，可选，缺省由 App 决定。
  App 端行为：用户在面板四角拖动调整过的尺寸会**按角色卡记忆**（持久化到 App 偏好），下次展开与重启 App 后沿用；记忆值优先于卡声明的 `size`。
- `chrome`：仅 `fullscreen` 有意义。`auto`（默认）= App 顶栏（返回按钮 + 「角色名 · 界面」）；`none` = **沉浸**：不渲染 App 顶栏，页面自状态栏下方铺满（底部保持原样）。沉浸卡应自带关闭入口（Bridge `close()`），系统返回手势/返回键始终可用。
- `autoOpen`：仅 `fullscreen` 有意义，默认 `false`。`true` = 进入会话时**自动打开界面页**（纯前端卡"整卡即应用"）；每次会话进入只触发一次，从界面页返回后停在聊天页。

### 4.2 交互标准（panel 在聊天页对话；fullscreen 可在页面内对话）

- ChatPage 右侧出现浮动的「界面」折叠标签（仅当卡含有效 `frontend`）：
  - 有角色状态时，排在其下方；无状态时，排右上角（与状态标签同一贴右侧）。
- `mode: "fullscreen"` → 点击进入独立全屏页：
  - 展示型卡：只渲染界面，对话仍在 ChatPage；
  - **纯前端卡**（游戏式/界面自带气泡与输入框）：可在页面内自绘对话——打开时 `getMessages()` 拉历史、输入走 `send(text)`、回复经 `message_update` 流式渲染（见 `frontend-card-contract.md` §5）。
- `mode: "panel"` → 点击在 ChatPage 上展开一个**浮层面板**（类似角色状态面板的展开/收起动画）：
  - 面板内用 ArkWeb 渲染 `html`，面板同级承载标题栏（标题 + 固定/收起按钮）；
  - **ArkWeb 保活**：首次打开后收起只做隐藏，不销毁页面——再次展开即时显示（无白屏重载），且收起期间页面持续接收 Bridge 事件、内容始终最新；
  - 收起/`close()` 时仅隐藏面板（含失焦，键盘跟随关闭），回到 ChatPage 聊天视图；**对话内容不被遮挡、可继续刷新**；
  - 面板保活范围限于当前聊天页实例：离开聊天页或切换到其他角色卡即回收。
- 无论哪种模式，Bridge 事件都保持活跃：`status_update` / `schema_update` / `message_update` 持续推送，前端实时刷新。

---

## 5. Bridge 契约（与 `frontend-card-contract.md` 对齐，并补充）

### 5.1 `window.arktavern` 方法（JS → App）

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `getVersion()` | 无 | `string` | 契约版本 `"2"`（v1 纯新增相容） |
| `getStatusSchema()` | 无 | `string` | 角色卡声明的状态字段定义 JSON：`[{"name":"金币","desc":"…","type":"number","locked":false}, …]`；无声明返回 `"[]"` |
| `getState()` | 无 | `string` | 当前状态值数组 JSON（结构同 `ChatStatusState`）；无字段返回 `"[]"` |
| `setState(name, value)` | `string`, `string` | `string` | 写状态值：字段存在则更新（`locked=true` 拒绝改）；`value` 空表示删除（仅允许非声明字段）；返回 `"ok"` / `"invalid"` / `"locked"` / `"disposed"` |
| `getCharacter()` | 无 | `string` | 角色卡信息 JSON（`name/description/personality/scenario/systemPrompt`） |
| `getMessages(limit?)` | `number?` | `string` | 会话历史消息 JSON（v2 新增）：`[{"role":"user"|"assistant","content":"…"}]`，时间正序、正文已剥离状态块；`limit` 默认 50、上限 200。供全屏纯前端卡在页面内自绘对话时拉历史 |
| `send(text)` | `string` | `string` | 发送消息到当前会话（同聊天链路）。返回 `"ok"`/`"busy"`/`"empty"`/`"disposed"` |
| `close()` | 无 | `string` | 关闭：全屏页 `router.back`；面板模式收起面板。返回 `"ok"` |

### 5.2 App → 页面事件（`window.arktavernPush.dispatch(jsonString)`）

入参为 JSON **字符串**，解析得 `{ kind, data }`：

- `message_update`：`{ generating: boolean, lastAssistant: string, messageCount: number }`，任何消息增删改时推送。
  `messageCount`（v2 新增）为当前会话消息总数，页面可与本地条数比对，不一致时重新 `getMessages()` 对齐。
- `status_update`：`data` 为当前状态值数组（同 `getState()`），状态变更时推送。
- `schema_update`：`data` 为 `getStatusSchema()` 结构，会话/卡片切换时推送（页面可据此重绘表单）。

> 页面加载完成即推送一次 `status_update` + `message_update` 快照；面板模式保活后不再重新加载，但事件订阅持续生效，收起期间仍实时接收更新，展开即为最新。

---

## 6. `character_book.extensions.arktavern`：世界书注入建议（v50）

> 与 `data.extensions.arktavern`（状态/前端）平行的另一扩展点：**挂在 `character_book.extensions` 上**，
> 由制卡工具（Card Studio）写入，App 导入角色卡创建专属世界书时读取。

### 6.1 结构

```json
{
  "character_book": {
    "extensions": {
      "arktavern": {
        "activationMode": "StickyOnDemand",
        "scanDepth": 10,
        "injectionBudgetChars": 12000
      }
    }
  }
}
```

### 6.2 字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `activationMode` | string | 激活方式：`StickyOnDemand`（粘滞按需，推荐，缓存命中最优）/ `FullInject`（全量）/ `OnDemand`（按需）/ `OnDemandPinned`（按需锁定）/ `FollowGlobal`（跟随 App 全局默认，缺省值）。非法值按 `FollowGlobal` 处理 |
| `scanDepth` | number | 关键词扫描深度（最近 N 条消息，0=默认 10，上限 50） |
| `injectionBudgetChars` | number | 注入预算（字符，0=默认 12000，上限 200000） |

### 6.3 App 导入读取规则

- 优先读取 `character_book.extensions.arktavern` 的三个字段，应用到创建的 Lorebook；
- 无建议时的回退：`scanDepth` 取 V2 标准 `scan_depth`；`injectionBudgetChars` 由 `token_budget`（按 1 token ≈ 4 字符）折算；
- 条目级 `constant: true` 条目常驻注入头部（与激活方式无关）；其余条目按激活方式的关键词匹配注入。

### 6.4 制卡工具约定（缓存命中率导向）

- **constant 从严**：仅世界观根基/贯穿全程的机制规则/高频核心场景设为 constant（建议 ≤ 总条目数 1/3）；
  特定人物支线/一次性事件/稀有地点用关键词触发。
- **keys 精准**：只用专名与别名（角色名/地名/物品名/组织名/招式名），禁用代词与高频泛词，避免误触发污染上下文。
- **默认建议**：AI 创建/适配导出时未手动设置，自动补
  `{ activationMode: "StickyOnDemand", scanDepth: 10, injectionBudgetChars: 12000 }`。

---

## 7. 可扩展性指导

- **新增能力走模式/配置字段**：`frontend` 对象保留任意自定义 `meta.*`，App 未知字段透传，不阻塞。
- **新增 UI 控件类型由 HTML 自身承担**：地图、面板、倒计时、交互组件都在 `html` 内用 HTML/CSS/JS 实现，
  通过 Bridge 与 App 对话——App 不感知具体组件，只提供统一的能力通道。
- **版本演化**：破坏性变更提升 `bridge_version`（`v3`…），页面试图解析「新版能力但运行在旧 App」时做降级提示；新增能力（v2 的 `getMessages` 等）用 `typeof window.arktavern.xxx === 'function'` 探测即可。
- **转换工具输出建议**：HTML ≤ 256KB；结尾写 `<!-- arktavern-bridge:2 -->` 便于识别。

---

## 8. 与本仓库其他文档的关系

| 文档 | 关系 |
|---|---|
| `docs/frontend-card-contract.md` | Bridge 方法/事件的细部契约，本规范为 `extensions.arktavern` 的上层标准；两者应同步更新 |
| `docs/sample-frontend-demo-card.json` | 演示卡，应逐步改为含 `status` + `frontend` 的完整示例 |

---

## 9. 待办（实现阶段，本规范确认后执行）

- [ ] `ChatStatusState` / `ChatService`：状态骨架改为从 `status.fields` 读取；仅更新已声明字段；无声明禁用状态功能
- [ ] `buildStatusInstruction`：改为「只输出已声明字段的当前值」，去掉“推断/增删字段”指令
- [ ] `extractFrontendHtml` → 升级为解析 `frontend` 对象（`html` + `mode` + `title` + `size`）
- [ ] ChatPage「界面」标签 → 支持 `panel` 模式内嵌浮层面板（动画与 `status` 面板一致）
- [ ] Bridge 新增 `getStatusSchema()`、`schema_update` 事件；`setState` 遵守 `locked` 与声明边界
- [ ] 更新 `sample-frontend-demo-card.json` 为符合本规范的完整示例