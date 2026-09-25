# 前端页面角色卡 · Bridge 契约（frontend-card-contract）

> 本文档是 **ArkTavern App** 与 **PC 转换工具**（大模型 + skill 将其他平台角色卡改造成符合本结构）之间的接口契约。
> Bridge 当前版本：`v2`（App 侧 `CardFrontendBridge.getVersion()` 返回 `"2"`）。
> 版本历史：`v1` = getVersion/getState/getStatusSchema/setState/getCharacter/send/close；
> `v2` = 新增 `getMessages(limit)`、`message_update.messageCount`，`frontend.chrome` 支持 `"none"`（沉浸全屏）。
> 变更本契约时必须同步更新：`CardFrontendBridge.ets`、`CardFrontendWeb.ets`、`FrontendCardPage.ets`、本文档，且不破坏已导入卡（向前兼容）。

---

## 1. 存储结构

角色卡 JSON 的自定义字段（随 `extensions` 原样保存/导出，不丢失）：

```json
{
  "extensions": {
    "arktavern": {
      "user_name_override": "可选，角色对用户的称呼",
      "frontend": {
        "html": "<完整 HTML 字符串，含 <style>/<script>，作为一个整体>",
        "mode": "panel",
        "title": "界面标题",
        "size": { "width": 360, "height": "65%" },
        "chrome": "auto"
      }
    }
  }
}
```

- `frontend` 可以是**字符串**（旧写法，等价 `mode:"fullscreen"`、`chrome:"auto"`）或**对象** `{ html, mode?, title?, size?, chrome? }`。
- `html` 是完整 HTML 页面（CSS 与脚本全部内联）。**大小上限 512KB**（UTF-8 序列化）。超过上限导入时**保留**，但 App 界面提示"界面过大未启用"。
- `mode`：`"panel"`（聊天页内浮层面板，推荐展示型/轻交互卡）| `"fullscreen"`（独立全屏页，默认值）。
- `chrome`：仅 `mode:"fullscreen"` 有意义。`"auto"`（默认，App 顶栏 + 返回按钮）| `"none"`（沉浸，不渲染 App 顶栏，内容自状态栏下方铺满；退出靠系统返回手势/返回键或页面 `close()`）。
- 其他 `extensions.arktavern.*` 子字段不受影响；未知子字段原样保留。

## 2. 运行方式

App 在聊天页右下发出现"界面"折叠标签（仅当该角色卡含有效 frontend）：
- `mode:"panel"` → 在聊天页展开**浮层面板**（ArkWeb 首次打开后保活：收起只隐藏不销毁，再展开即时显示且内容始终最新；面板尺寸拖动调整后按角色卡记忆）。
- `mode:"fullscreen"` → 进入独立全屏页渲染该 HTML。

两种模式都注入两个全局对象：

| 全局对象 | 方向 | 说明 |
|---|---|---|
| `window.arktavern` | JS → App | 页面调用 App 能力（读状态、读历史消息、发消息、关闭页等） |
| `window.arktavernPush.dispatch(jsonString)` | App → JS | App 把事件推给页面（页面**必须先定义**该函数，再执行自己的逻辑） |

> 页面脚本被加载时 `window.arktavern` 可能尚未注入完成。**安全写法**：页面脚本先注册 `window.arktavernPush = { dispatch: ... }`，到 `window.arktavernReady && window.arktavernReady()` 被调用（页面 onPageEnd 后触发）或收到首个事件后再调 `window.arktavern.*` 方法。

## 3. `window.arktavern` 方法（JS → App）

| 方法 | 参数 | 返回 | 说明 |
|---|---|---|---|
| `getVersion()` | 无 | `string` | 契约版本号，当前 `"2"`。页面/工具可自查兼容性 |
| `getState()` | 无 | `string` | 角色状态 JSON 数组字符串：`[{"name":"金币","value":"120","fromUser":true,"locked":false}, ...]`，无字段时返回 `"[]"` |
| `getStatusSchema()` | 无 | `string` | 角色卡声明的状态字段定义 JSON：`[{"name":"金币","desc":"…","type":"number","locked":false}, ...]`，无声明返回 `"[]"` |
| `setState(name, value)` | `name: string`, `value: string` | `string` | 写角色状态：字段存在则更新；`value` 为空表示删除；字段不存在且非空则新增。返回 `"ok"` / `"invalid"` / `"disposed"` |
| `getCharacter()` | 无 | `string` | 角色卡信息 JSON：`{"name":"…","description":"…","personality":"…","scenario":"…","systemPrompt":"…"}` |
| `getMessages(limit)` | `limit?: number` | `string` | **v2 新增**。会话历史消息 JSON 数组（按时间正序，只含 user/assistant、正文已剥离状态块）：`[{"role":"user","content":"…"},{"role":"assistant","content":"…"}]`。`limit` 默认 50、上限 200（非法值按默认）。供全屏前端页在页面内自绘对话时拉历史 |
| `send(text)` | `text: string` | `string` | 发送一条消息到当前会话（同正常聊天链路，消息进入聊天气泡与历史）。返回 `"ok"` / `"busy"` / `"empty"` / `"disposed"`；发送结果经 `message_update` 事件反馈 |
| `close()` | 无 | `string` | 关闭前端页面返回聊天页（面板模式=收起面板；全屏页=返回聊天页），返回 `"ok"` |

## 4. App → 页面事件（`window.arktavernPush.dispatch`）

页面收到的参数是一个 JSON **字符串**（不是对象），形如：

```js
window.arktavernPush = {
  dispatch: function (jsonString) {
    const ev = JSON.parse(jsonString);   // { kind: string, data: object }
    if (ev.kind === 'message_update') { /* … */ }
    if (ev.kind === 'status_update')  { /* … */ }
  }
};
```

### `message_update`

| 字段 | 类型 | 含义 |
|---|---|---|
| `generating` | boolean | 是否正在生成回复 |
| `lastAssistant` | string | 本会话最后一条助手消息全文（流式中为当前内容；无则空串） |
| `messageCount` | number | **v2 新增**。当前会话消息总数（含 system 等未在 getMessages 中返回的条目）。页面可用它与本地条数比对，不一致时重新 `getMessages()` 对齐（例如聊天页侧发生增删改） |

触发时机：任何消息增删改（用户消息、助手流式增量、完成、编辑、Swipe、删消息等）。

### `status_update`

`data` 为角色状态数组，与 `getState()` 返回结构一致。触发时机：状态字段增删改/锁定切换/AI 更新。

### `schema_update`

`data` 为角色卡声明的状态字段定义数组，与 `getStatusSchema()` 返回结构一致。触发时机：页面加载完成、会话/角色卡切换时（页面可据此重绘状态表单；无声明时为空数组）。

> 页面首次打开时，App 会在页面加载完成后立即推送一次 `status_update` 与 `message_update` 快照，打开即可用。

## 5. 全屏聊天卡（在页面内自绘对话，v2）

`mode:"fullscreen"` 的纯前端卡可以让**对话本身**发生在页面里（页面自带气泡列表与输入框），推荐流程：

```js
// 1) 先注册事件入口
window.arktavernPush = {
  dispatch: function (jsonString) {
    var ev = JSON.parse(jsonString);
    if (ev.kind === 'message_update') {
      renderReply(ev.data.lastAssistant, ev.data.generating);
      if (ev.data.messageCount !== localCount) { pullHistory(); }   // 计数不一致才重拉
    }
    if (ev.kind === 'status_update')  { renderStatus(ev.data); }
    if (ev.kind === 'schema_update')  { renderStatusForm(ev.data); }
  }
};

// 2) 拉历史（页面就绪后先拉一次；老 App 上该方法不存在，需降级）
function pullHistory() {
  if (window.arktavern && typeof window.arktavern.getMessages === 'function') {
    var list = JSON.parse(window.arktavern.getMessages(50));   // [{role, content}]
    renderHistory(list);
    localCount = list.length;
  }
}

// 3) 发送（用户气泡本地先渲染，回复经 message_update 流式回来）
function doSend(text) {
  if (window.arktavern && window.arktavern.send(text) === 'ok') { appendBubble('user', text); }
}
```

要点：
- **打开即拉历史**（`getMessages`），否则从聊天页进来会看不到已有对话；流式增量**不要**用 `getMessages` 轮询，交给 `message_update`。
- `lastAssistant` 是"最后一条助手消息的全文"，页面把它渲染到自己的最后一条助手气泡（替换式）即可得到流式效果；`generating=false` 表示本轮结束。
- 页面内发送与聊天页共享同一会话：回到聊天页能看到同样的消息，反之亦然。
- `chrome:"none"` 时不渲染 App 顶栏，页面应自带返回/关闭入口（调 `window.arktavern.close()`）；系统返回手势/返回键始终可用。

**兼容降级**：老版本 App（`getVersion()` 返回 `"1"`）没有 `getMessages`，页面用 `typeof window.arktavern.getMessages !== 'function'` 判定，此时退化为"只渲染 `message_update.lastAssistant`"（仍可对话，但看不到历史）。v1 页面在 v2 App 上行为完全不变（纯新增能力）。

## 6. 安全约束（页面与转换工具必须遵守）

- 页面**不允许**发起导航（`window.location` 跳转、`<a>` 点击）——App 会拦截并记录日志
- 页面**不应**请求外部网络资源（图片/CDN/接口）。如需图标字体等，全部内联或使用纯 CSS/emoji
- 不要依赖 `window.open`、弹窗、文件系统 API
- 页面体积尽量小（语义上限 512KB），转换工具建议输出 ≤256KB
- 页面不写用户数据，所有数据经上述 Bridge 读写

## 7. 最小可运行示例

```html
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<style>
  body { margin: 16px; font-family: sans-serif; }
  .row { display: flex; justify-content: space-between; padding: 6px 0; }
</style>
</head>
<body>
  <h3>状态面板</h3>
  <div id="status"></div>
  <input id="input" placeholder="说点什么…">
  <button onclick="doSend()">发送</button>
  <div id="reply"></div>
  <script>
    // 必须先注册事件入口
    window.arktavernPush = {
      dispatch: function (jsonString) {
        const ev = JSON.parse(jsonString);
        if (ev.kind === 'status_update') {
          document.getElementById('status').innerText =
            ev.data.map(function (e) { return e.name + ': ' + e.value; }).join('\n');
        }
        if (ev.kind === 'message_update') {
          document.getElementById('reply').innerText =
            ev.generating ? '生成中…\n' + ev.lastAssistant : ev.lastAssistant;
        }
      }
    };
    function doSend() {
      const t = document.getElementById('input').value;
      if (t && window.arktavern) { window.arktavern.send(t); }
    }
    function refresh() {
      if (window.arktavern) {
        window.arktavern.setState('金币', String((Math.random() * 1000) | 0));
      }
    }
  </script>
</body>
</html>
```

## 8. 版本兼容建议

- 契约版本当前为 `v2`（纯新增，v1 页面无需改动）
- App 升级且**破坏性**变更契约时，将 `getVersion()` 提升到 `v3`，页面通过 `getVersion()` 判级做降级展示
- 新增能力（如 `getMessages`）优先用 `typeof window.arktavern.xxx === 'function'` 探测，不要硬判版本号
- 转换工具输出页面时建议写入版本注释尾巴：`<!-- arktavern-bridge:2 -->`