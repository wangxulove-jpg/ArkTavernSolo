/**
 * StFrontendFallback ST 卡散落前端运行时回退检测(纯函数)
 *
 * 背景:原版 SillyTavern 卡没有 extensions.arktavern.frontend,其前端界面散落在
 * 开场白(first_mes)/备用开场白(alternate_greetings)/美化正则(extensions.regex_scripts
 * 的 replaceString)里,导入后 App 识别不出、无法加载。
 *
 * 本模块在 extractFrontendSpec 无结果时做**运行时回退检测**(不写库、不改动卡数据):
 * 扫描上述三处,提取"界面级 HTML 块"(```html 围栏内容,或含 <body/<div 的长文本),
 * 多候选取最大。由 ChatPage/FrontendCardPage 作为 frontend.html 的兜底来源。
 *
 * 已知边界:
 * - 导入时 sanitizeExtensions 会丢弃整体序列化超 200KB 的 regex_scripts(CharacterService),
 *   重前端卡的正则在入库前已丢,本检测救不回——此类卡需在导入前用制卡工具/skill 适配;
 * - 检测出的前端默认以 panel 模式展示(聊天在原生聊天框,界面辅助展示),
 *   用户可在悬浮导航「全屏」入口切换显示方式;
 * - 世界书条目内的 HTML 不扫(数据在 lorebook 表,非 Character 字段)。
 */

import { Character } from '../models/Character';

/** 回退检测结果 */
export interface StFrontendFallback {
  /** 提取出的完整 HTML(已剥 markdown 围栏,trim 首尾) */
  html: string;
  /** 来源描述: '开场白' | '备用开场白 N' | '正则:名称' */
  source: string;
}

/** 视为界面级 HTML 的最小字符数(零散小段 HTML 美化不作为前端页面) */
const MIN_HTML_CHARS: number = 512;

/** 单段文本提取围栏 HTML 的最大扫描长度(超长文本截断扫描,防正则回溯) */
const MAX_FENCE_SCAN_CHARS: number = 512 * 1024;

/** HTML 特征标签(命中其一即视为 HTML 文本) */
const HTML_TAG_RE: RegExp = new RegExp('<(body|div|style|section)\\b', 'i');

/** ```html / ``` 围栏(容许语言标注省略) */
const FENCED_HTML_RE: RegExp = new RegExp('```(?:html)?\\s*\\n?([\\s\\S]*?)```', 'gi');

/**
 * 判断文本是否像 HTML 页面(含 body/div/style/section 开标签)。
 */
function looksLikeHtml(text: string): boolean {
  return HTML_TAG_RE.test(text);
}

/**
 * 从文本中提取所有 ```html 围栏内容,返回最长一块(剥围栏);无围栏返回空串。
 * 超长文本截断到 MAX_FENCE_SCAN_CHARS 再扫描(界面 HTML 围栏几乎都在前 512KB 内)。
 */
function extractLongestFencedHtml(text: string): string {
  if (text.indexOf('```') < 0) {
    return '';
  }
  const scanText: string = text.length > MAX_FENCE_SCAN_CHARS
    ? text.substring(0, MAX_FENCE_SCAN_CHARS) : text;
  FENCED_HTML_RE.lastIndex = 0; // 重置 lastIndex(全局正则复用)
  let longest: string = '';
  let match: RegExpExecArray | null = FENCED_HTML_RE.exec(scanText);
  while (match !== null) {
    const body: string = match[1].trim();
    if (body.length > longest.length) {
      longest = body;
    }
    match = FENCED_HTML_RE.exec(scanText);
  }
  return longest;
}

/**
 * 从一段文本中提取界面级 HTML 块:
 * - 优先取 ```html 围栏内容(多个围栏取最长);
 * - 无围栏时,整段含 HTML 特征标签且长度 ≥ MIN_HTML_CHARS 则视为整段 HTML;
 * - 不满足返回空串。
 */
export function extractHtmlBlockFromText(text: string): string {
  const source: string = typeof text === 'string' ? text : '';
  if (source.trim().length === 0) {
    return '';
  }
  const fenced: string = extractLongestFencedHtml(source);
  if (fenced.length > 0) {
    return fenced;
  }
  const trimmed: string = source.trim();
  if (trimmed.length >= MIN_HTML_CHARS && looksLikeHtml(trimmed)) {
    return trimmed;
  }
  return '';
}

/**
 * 检测 Character 内散落的 ST 前端结构(开场白/备用开场白/美化正则),取最大 HTML 块。
 * @returns 无界面级 HTML 时返回 null
 */
export function detectStFrontendHtml(character: Character): StFrontendFallback | null {
  let best: StFrontendFallback | null = null;

  const consider = (html: string, source: string): void => {
    if (html.length > 0 && (best === null || html.length > best!.html.length)) {
      const candidate: StFrontendFallback = { html: html, source: source };
      best = candidate;
    }
  };

  // 1. 开场白(整卡即前端:整个开场白就是一个 HTML 页面)
  consider(extractHtmlBlockFromText(character.firstMessage), '开场白');

  // 2. 备用开场白
  const greetings: string[] = character.alternateGreetings;
  for (let i = 0; i < greetings.length; i++) {
    consider(extractHtmlBlockFromText(greetings[i]), '备用开场白 ' + String(i + 1));
  }

  // 3. 美化正则 regex_scripts[].replaceString(正则替换模板里的界面 HTML)
  const raw: Object | undefined = character.extensions['regex_scripts'];
  if (raw !== undefined && Array.isArray(raw)) {
    const scripts: Object[] = raw as Object[];
    for (let i = 0; i < scripts.length; i++) {
      const item: Object = scripts[i];
      if (typeof item !== 'object' || item === null || Array.isArray(item)) {
        continue;
      }
      const rec: Record<string, Object> = item as Record<string, Object>;
      const replaceString: Object | undefined = rec['replaceString'];
      if (typeof replaceString !== 'string') {
        continue;
      }
      const name: Object | undefined = rec['scriptName'];
      const sourceName: string = typeof name === 'string' && name.length > 0
        ? name : ('#' + String(i + 1));
      consider(extractHtmlBlockFromText(replaceString as string), '正则:' + sourceName);
    }
  }

  return best;
}
