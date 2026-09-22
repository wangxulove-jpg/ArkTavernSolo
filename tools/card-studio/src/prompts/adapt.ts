/**
 * AI 适配管线提示词:规划(adaptPlan)与生成(adaptGenerate)。
 */
import { ARK_CONTRACT_TEXT, ST_ECOSYSTEM_TEXT, API_MAPPING_TEXT } from './contract'

export interface AdaptPlan {
  frontend: {
    enabled: boolean
    mode: 'panel' | 'fullscreen'
    title: string
    sizeWidth?: number
    sizeHeight?: string
  }
  statusFields: { name: string; desc: string; type: string; locked: boolean }[]
  featureChecklist: string[]
  apiMappings: { original: string; replacement: string; note?: string }[]
  updateMechanism: string
  risks: string[]
}

export interface PlanInput {
  cardSummary: string
  mainHtml: string
  scriptSummaries: string
  regexSummaries: string
  userRequirement: string
}

export interface GenerateInput {
  originalHtml: string
  plan: AdaptPlan
  feedback?: string
}

export function buildPlanSystemPrompt(): string {
  return [
    '你是 SillyTavern → ArkTavern 角色卡前端适配规划师。',
    '用户会给你一张 SillyTavern 重前端角色卡的摘要、其中的前端 HTML 资产与相关脚本,',
    '你要产出一份"适配规划 JSON",指导后续把该前端改造成 ArkTavern App 的前端界面。',
    '',
    '## 目标 App 生态',
    ARK_CONTRACT_TEXT,
    '',
    '## 原卡生态',
    ST_ECOSYSTEM_TEXT,
    '',
    '## API 映射参考',
    API_MAPPING_TEXT,
    '',
    '## 规划要求',
    '1. 尽量复原原版前端的视觉与功能(布局/配色/组件/交互),这是最高目标;',
    '2. 把原前端的"数据源"从 TavernHelper 变量/楼层消息迁移到 ArkTavern 角色状态字段:',
    '   原界面展示和更新的每个动态数据(数值/位置/物品/好感等)都应对应一个 status 字段;',
    '3. 字段建议 3-12 个:name 简短唯一,desc 说明取值含义,type 用 number/string,固定不变的设 locked:true;',
    '4. mode 建议 panel(聊天页浮层,尺寸建议 width 360 左右,height 45%~70%);界面是展示与交互入口,不是聊天器;',
    '5. 无法迁移的能力(如头像、读历史楼层)要列入 risks,并给出降级建议;',
    '6. updateMechanism 用一段话说明:模型每轮回复带状态块 → App 推送 status_update → 界面如何刷新。',
    '',
    '## 输出格式(最高优先级)',
    '只输出一个 JSON 对象,不要 markdown 代码块、不要解释文字,结构如下:',
    `{
  "frontend": { "enabled": true, "mode": "panel", "title": "界面标题", "sizeWidth": 360, "sizeHeight": "65%" },
  "statusFields": [ { "name": "金币", "desc": "当前持有金币数", "type": "number", "locked": false } ],
  "featureChecklist": ["原界面功能点1", "功能点2"],
  "apiMappings": [ { "original": "getVariables()", "replacement": "getState()", "note": "说明" } ],
  "updateMechanism": "……",
  "risks": ["无法迁移的项与降级方案"]
}`
  ].join('\n')
}

export function buildPlanUserPrompt(input: PlanInput): string {
  return [
    '## 角色卡摘要',
    input.cardSummary,
    '',
    '## 选定的主界面 HTML(原版前端,完整内容)',
    input.mainHtml,
    '',
    input.scriptSummaries ? `## 酒馆助手角色脚本(参考其交互意图)\n${input.scriptSummaries}\n` : '',
    input.regexSummaries ? `## regex 美化脚本摘要(参考其展示意图)\n${input.regexSummaries}\n` : '',
    '## 用户适配要求',
    input.userRequirement.trim() || '(无特殊要求,以复原原版前端为目标)',
    '',
    '请输出适配规划 JSON。'
  ]
    .filter(Boolean)
    .join('\n')
}

export function buildGenerateSystemPrompt(): string {
  return [
    '你是前端界面改造工程师:把 SillyTavern 前端 HTML 改造成 ArkTavern App 的前端界面,',
    '以"最大程度复原原版视觉与功能"为最高目标。',
    '',
    '## ArkTavern App 契约',
    ARK_CONTRACT_TEXT,
    '',
    '## API 映射参考',
    API_MAPPING_TEXT,
    '',
    '## 改造要求',
    '1. 保留原版布局、配色、字体层级、组件样式与交互动效,CSS 原样迁移优先于重写;',
    '2. 移动端适配:自适应手机宽(360-420px),触控目标≥44px,可滚动;',
    '3. 把原 HTML 中的 TavernHelper API 调用替换为 window.arktavern Bridge 调用(见映射表);',
    '4. 数据刷新:注册 window.arktavernPush.dispatch,监听 status_update / message_update 事件刷新界面;',
    '   页面加载后先渲染静态结构,收到首个事件再填数据(注意 arktavern 可能未就绪,先注册 dispatch 再等待事件);',
    '5. 交互动作(按钮点击等)通过 window.arktavern.send(text) 发送消息,或 setState 更新状态;',
    '6. 严禁引用外部资源(图片/字体/CDN),图标用 emoji 或纯 CSS;删除对头像 CSS 类的依赖;',
    '7. 单文件自包含,目标 ≤128KB,硬上限 256KB;删除原 HTML 中与展示无关的注释和冗余代码;',
    '8. getChatMessages 类"读取历史楼层"的能力不可用:相关展示改为状态字段或 lastAssistant。',
    '',
    '## 输出格式(最高优先级)',
    '只输出改造后的完整 HTML(从 <!doctype html> 或 <html> 开始到 </html> 结束),',
    '不要 markdown 代码块包裹,不要任何解释文字。'
  ].join('\n')
}

export function buildGenerateUserPrompt(input: GenerateInput): string {
  const parts = [
    '## 原版前端 HTML',
    input.originalHtml,
    '',
    '## 适配规划(JSON)',
    JSON.stringify(input.plan, null, 2)
  ]
  if (input.feedback && input.feedback.trim()) {
    parts.push('', '## 用户修改意见(优先级最高)', input.feedback.trim())
  }
  parts.push('', '请输出改造后的完整 HTML。')
  return parts.join('\n')
}

/** 从模型输出中提取 JSON(容忍 ```json 围栏与前后杂文) */
export function extractJson<T>(text: string): T | null {
  const fenced = /```(?:json)?\s*([\s\S]*?)```/.exec(text)
  const candidates = fenced ? [fenced[1], text] : [text]
  for (const candidate of candidates) {
    const start = candidate.indexOf('{')
    const end = candidate.lastIndexOf('}')
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(candidate.slice(start, end + 1)) as T
      } catch {
        // 继续尝试
      }
    }
  }
  return null
}

/** 从模型输出中提取完整 HTML(容忍 ```html 围栏与前后杂文) */
export function extractHtml(text: string): string {
  const fenced = /```(?:html)?\s*([\s\S]*?)```/.exec(text)
  let candidate = fenced ? fenced[1] : text
  const docStart = candidate.search(/<!doctype html|<html[\s>]/i)
  if (docStart > 0) {
    candidate = candidate.slice(docStart)
  }
  const endIdx = candidate.toLowerCase().lastIndexOf('</html>')
  if (endIdx >= 0) {
    candidate = candidate.slice(0, endIdx + 7)
  }
  return candidate.trim()
}
