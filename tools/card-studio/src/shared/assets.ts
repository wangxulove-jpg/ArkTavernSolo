/**
 * 前端资产扫描:定位 SillyTavern 重前端卡的前端 HTML 代码块、
 * 酒馆助手(TavernHelper)角色脚本与 regex 美化脚本。
 */
import type { CharaCard, CardData } from './card'

export interface HtmlAsset {
  id: string
  /** 来源位置描述,如 "开场白 first_mes" / "备用开场白 #2" / "世界书条目: xxx" */
  source: string
  content: string
  chars: number
  /** 是否为完整页面(含 <body>,酒馆助手渲染器标准) */
  isFullPage: boolean
}

export interface ScriptAsset {
  id: string
  name: string
  content: string
}

export interface RegexAsset {
  id: string
  name: string
  findRegex: string
  replaceString: string
  disabled: boolean
}

export interface AssetScanResult {
  htmlAssets: HtmlAsset[]
  scripts: ScriptAsset[]
  regexes: RegexAsset[]
}

/** 从文本中提取围栏代码块里疑似前端的 HTML */
function extractHtmlBlocks(text: string, source: string, out: HtmlAsset[]): void {
  if (!text) return
  const fence = /```[^\n`]*\r?\n([\s\S]*?)```/g
  let match: RegExpExecArray | null
  let index = 0
  while ((match = fence.exec(text)) !== null) {
    index++
    const content = match[1]
    const hasBody = /<body[\s>]/i.test(content) && /<\/body>/i.test(content)
    const looksHtml =
      hasBody ||
      ((/<style[\s>]/i.test(content) || /<div[\s>]/i.test(content) || /<script[\s>]/i.test(content)) &&
        content.length > 500)
    if (!looksHtml) continue
    out.push({
      id: `${source}#${index}`,
      source,
      content,
      chars: content.length,
      isFullPage: hasBody
    })
  }
}

export function scanAssets(card: CharaCard): AssetScanResult {
  const data = card.data as CardData
  const htmlAssets: HtmlAsset[] = []

  extractHtmlBlocks(String(data.first_mes ?? ''), '开场白 first_mes', htmlAssets)
  const greetings = Array.isArray(data.alternate_greetings) ? data.alternate_greetings : []
  greetings.forEach((g: unknown, i: number): void => {
    extractHtmlBlocks(String(g ?? ''), `备用开场白 #${i + 1}`, htmlAssets)
  })
  const book = data.character_book as { entries?: Array<{ name?: string; comment?: string; content?: string }> } | undefined
  if (book && Array.isArray(book.entries)) {
    book.entries.forEach((entry): void => {
      const label = `世界书条目: ${entry.name || entry.comment || '(未命名)'}`
      extractHtmlBlocks(String(entry.content ?? ''), label, htmlAssets)
    })
  }

  // TavernHelper 角色脚本(随卡导出)
  const scripts: ScriptAsset[] = []
  const ext = data.extensions as Record<string, unknown> | undefined
  const th = ext?.TavernHelper_scripts
  if (Array.isArray(th)) {
    th.forEach((s: Record<string, unknown>, i: number): void => {
      const content = typeof s.content === 'string' ? s.content : ''
      if (!content) return
      scripts.push({
        id: `th-${i}`,
        name: String(s.name ?? s.comment ?? `脚本 ${i + 1}`),
        content
      })
    })
  }

  // regex 美化脚本
  const regexes: RegexAsset[] = []
  const rs = ext?.regex_scripts
  if (Array.isArray(rs)) {
    rs.forEach((r: Record<string, unknown>, i: number): void => {
      const findRegex = typeof r.findRegex === 'string' ? r.findRegex : ''
      if (!findRegex) return
      regexes.push({
        id: `rx-${i}`,
        name: String(r.scriptName ?? `正则 ${i + 1}`),
        findRegex,
        replaceString: typeof r.replaceString === 'string' ? r.replaceString : '',
        disabled: r.disabled === true
      })
    })
  }

  return { htmlAssets, scripts, regexes }
}
