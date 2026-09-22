/**
 * ArkTavern App 前端卡契约文本(内嵌进 AI 提示词的单一事实来源)。
 * 摘自 docs/frontend-card-contract.md 与 docs/arktavern-card-extensions.md,
 * App 侧契约变更时需同步更新本文件。
 */
export const ARK_CONTRACT_TEXT = `
# ArkTavern App 角色卡扩展契约(arktavern)

## 存储结构(随角色卡 data.extensions 原样保存)
{
  "extensions": {
    "arktavern": {
      "bridge_version": 1,
      "status": { "fields": [ { "name": "金币", "desc": "当前持有金币数", "type": "number", "locked": false } ] },
      "frontend": { "html": "<完整HTML字符串,含<style>/<script>,全部内联>", "mode": "panel", "title": "界面标题", "size": { "width": 360, "height": "65%" } }
    }
  }
}

## 角色状态(status)
- 字段集合由角色卡静态声明:字段名唯一,desc 说明取值含义,type 为 "number"/"string",locked=true 禁止 AI 更新。
- 建议声明 3-8 个字段。声明后 App 在聊天时自动注入状态输出规则:模型每轮回复末尾输出
  <|status|>
  {"字段名":"值"}
  </|status|>
  只更新已声明字段,每轮输出全部字段最新值。卡片无需在 system_prompt 中另写状态规则。

## 前端界面(frontend)
- 两种写法:字符串(旧,= 完整HTML,全屏) 或 对象 { html, mode, title, size }(推荐)。
- mode: "panel"(聊天页浮层面板,推荐) | "fullscreen"(独立全屏页)。对话始终在聊天页进行,界面只是展示与交互入口。
- HTML 限制:CSS/JS 全部内联,不引用任何外部网络资源(图片/CDN/接口),图标用 emoji 或纯 CSS;
  移动端适配(viewport、触控目标≥44px);建议 ≤256KB,上限 512KB。
- 页面脚本加载时 window.arktavern 可能尚未就绪:页面先注册 window.arktavernPush.dispatch,收到首个事件后再调用 window.arktavern。

## Bridge 方法(JS → App):window.arktavern.*
- getVersion() → "1"
- getState() → 状态数组字符串 [{"name":"金币","value":"120","fromUser":true,"locked":false}]
- getStatusSchema() → 声明字段定义 [{"name":"金币","desc":"…","type":"number","locked":false}]
- setState(name, value) → 写状态:存在则更新(locked 拒绝),value 空表示删除;返回 "ok"/"invalid"/"locked"/"disposed"
- getCharacter() → {"name":"…","description":"…","personality":"…","scenario":"…","systemPrompt":"…"}
- send(text) → 以用户身份发送消息进当前会话;返回 "ok"/"busy"/"empty"
- close() → 关闭界面/收起面板

## App → 页面事件:window.arktavernPush.dispatch(jsonString)
入参为 JSON 字符串,解析得 { kind, data }:
- "message_update": { generating: boolean, lastAssistant: string } — 任何消息增删改时推送
- "status_update": data 为状态数组(同 getState) — 状态变更时推送
- "schema_update": data 为字段定义(同 getStatusSchema) — 页面加载完成时推送
页面首次打开即收到一次 schema_update + status_update + message_update 快照。

## 安全约束
- 禁止页面导航(window.location 跳转、<a> 点击)、外部网络资源、window.open、文件系统 API。
- 页面不写用户数据,所有数据经 Bridge 读写。
`.trim()

/**
 * SillyTavern 重前端卡生态说明(告知 AI 原卡的工作环境)。
 */
export const ST_ECOSYSTEM_TEXT = `
# SillyTavern 重前端角色卡的运行机制(原卡环境)

- 前端界面 HTML 以围栏代码块(\`\`\` 包裹,内含 <body>)放在楼层消息(first_mes/备用开场白/世界书条目)中,
  由第三方扩展"酒馆助手(TavernHelper / JS-Slash-Runner)"以 iframe 渲染在楼层里。
- 页面内可调用 TavernHelper 注入的 API:
  · getVariables(type?) / setVariables(newVars) / insertOrReplaceVariables(pattern, value) — 变量读写
  · getChatMessages(range) / setChatMessages(messages, range) — 楼层消息读写(常用于更新界面内容)
  · generate / generateRaw(prompt) — 触发生成
  · eventOn(event, cb) / eventEmit — 事件监听
  · triggerSlash(command) — 触发酒馆斜杠命令
  · getCharAvatarUrl() / getUserAvatarUrl() — 头像
  · substitudeMacros(text) — 宏替换
- 头像 CSS 类:容器加 class "char-avatar"/"user-avatar"(或下划线变体)自动填充角色/用户头像背景。
- regex_scripts(extensions.regex_scripts):把模型输出正则替换成美化 HTML 的脚本。
- TavernHelper_scripts(extensions.TavernHelper_scripts):随卡导出的角色脚本,运行在酒馆页面上下文。
`.trim()

/** TavernHelper API → ArkTavern Bridge 映射表(供规划与生成提示词共用) */
export const API_MAPPING_TEXT = `
# TavernHelper API → ArkTavern Bridge 映射表
| 原调用 | 替代方案 |
|---|---|
| getVariables() | window.arktavern.getState() 解析 JSON(status 字段即变量) |
| setVariables(v) / insertOrReplaceVariables(k, v) | window.arktavern.setState(name, value) |
| 变量变化驱动界面刷新 | 监听 status_update 事件(window.arktavernPush.dispatch) |
| getChatMessages() 读取楼层 | 监听 message_update 事件的 lastAssistant(仅最后一条助手消息);历史记录不可用,改为状态字段承载 |
| setChatMessages() 改写楼层内容 | 不可用;改为 setState 更新状态字段 + 页面自行重绘 |
| generate() / triggerSlash() | window.arktavern.send(text) 发送消息,由模型回复驱动状态变化 |
| getCharAvatarUrl()/getUserAvatarUrl() | 不可用(App 当前未提供头像);用 emoji/文字/纯 CSS 替代 |
| eventOn(事件) | 等价事件已由 status_update / message_update 覆盖 |
`.trim()
