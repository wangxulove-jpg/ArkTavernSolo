/**
 * ChatTextParser 聊天富文本解析器
 *
 * 职责:
 * - 把聊天消息正文解析为带样式的 ChatTextSegment 片段列表
 * - 支持 Markdown 子集(加粗/斜体/删除线/行内代码/链接/引用/列表)
 * - 支持角色对白识别(中英文引号、日式引号、角色名前缀)
 * - 支持动作和旁白识别(括号包裹、——开头)
 * - 支持自定义符号配色规则(用户定义符号对,命中片段携带 symbolRuleId)
 * - 流式未闭合语法安全降级为普通文本
 *
 * 不负责:
 * - 实际渲染(由 ChatRichText 负责)
 * - 颜色取值(由 ChatPalette + 资源 token 负责)
 * - 字体大小/行间距(由调用方决定)
 *
 * 解析顺序(规范要求):
 * 1. 保护代码块和行内代码(占位符替换,最后还原)
 * 2. 识别 Markdown 链接
 * 3. 识别加粗斜体 ***
 * 4. 识别加粗 ** 或 __
 * 5. 识别斜体 * 或 _
 * 6. 识别删除线 ~~
 * 7. 识别引用和列表(行级)
 * 8. 在剩余普通文本中识别自定义符号(用户规则,优先于对白/动作)
 * 9. 在剩余普通文本中识别对白(引号包裹)
 * 10. 合并连续且样式相同的片段
 *
 * 安全降级:
 * - 解析失败时返回 [ { text: 原始文本, styleType: 'normal' } ]
 * - 未闭合语法保留为普通文本,不丢字
 */
import { ChatSymbolColorRule } from '../utils/ChatTextColorTheme';

/**
 * 文本片段的样式类型。
 * - normal: 普通叙述
 * - bold: 加粗
 * - italic: 斜体
 * - bold_italic: 加粗斜体
 * - strikethrough: 删除线
 * - code: 行内代码
 * - link: 链接
 * - quote: 引用
 * - list_item: 列表项
 * - dialogue: 角色对白
 * - action: 动作/旁白(括号内)
 * - narrator: 旁白(——开头)
 */
export type ChatTextStyleType =
  | 'normal'
  | 'bold'
  | 'italic'
  | 'bold_italic'
  | 'strikethrough'
  | 'code'
  | 'link'
  | 'quote'
  | 'list_item'
  | 'header'
  | 'hr'
  | 'dialogue'
  | 'action'
  | 'narrator';

/**
 * 颜色角色(用于调用方查询资源颜色)。
 * - default: 默认正文
 * - emphasis: 加粗强调
 * - secondary: 次要文字(斜体/删除线)
 * - dialogue: 对白
 * - narrator: 旁白
 * - action: 动作
 * - code: 代码
 * - link: 链接
 * - quote: 引用
 * - system: 系统提示
 * - character: 角色专用色(由调用方按 senderCharacterId 解析)
 * - symbol: 自定义符号(片段携带 symbolRuleId,颜色由渲染层从规则列表实时解析)
 */
export type ChatColorRole =
  | 'default'
  | 'emphasis'
  | 'secondary'
  | 'dialogue'
  | 'narrator'
  | 'action'
  | 'code'
  | 'link'
  | 'quote'
  | 'header'
  | 'system'
  | 'character'
  | 'symbol';

/**
 * 解析后的文本片段。
 * 每个片段携带渲染所需的全部信息。
 */
export interface ChatTextSegment {
  /** 文本内容(已剥离 Markdown 标记) */
  readonly text: string;
  /** 样式类型 */
  readonly styleType: ChatTextStyleType;
  /** 颜色角色 */
  readonly colorRole: ChatColorRole;
  /** 是否加粗 */
  readonly bold: boolean;
  /** 是否斜体 */
  readonly italic: boolean;
  /** 是否删除线 */
  readonly strike: boolean;
  /** 是否行内代码 */
  readonly code: boolean;
  /** 是否对白 */
  readonly dialogue: boolean;
  /** 是否旁白/动作 */
  readonly narrator: boolean;
  /** 链接目标(link 类型有效) */
  readonly linkTarget: string;
  /**
   * 命中的自定义符号规则 id(= 起始符 + 结束符)。
   * 只存 id 不存颜色:渲染层据此从当前规则列表实时取色,
   * 保证规则改色/删除后已渲染的片段即时更新;
   * 空字符串表示未命中,走常规语义色查询。
   */
  readonly symbolRuleId: string;
  /** 是否为新行起始(用于引用线、列表缩进等布局) */
  readonly lineStart: boolean;
  /** 列表缩进层级(0=非列表) */
  readonly listLevel: number;
}

/**
 * 创建普通文本片段。
 */
export function createSegment(
  text: string,
  styleType: ChatTextStyleType = 'normal',
  colorRole: ChatColorRole = 'default',
  extras: Partial<ChatTextSegment> = {}
): ChatTextSegment {
  const bold: boolean = styleType === 'bold' || styleType === 'bold_italic' || styleType === 'header' || extras.bold === true;
  const italic: boolean = styleType === 'italic' || styleType === 'bold_italic' || extras.italic === true;
  const strike: boolean = styleType === 'strikethrough' || extras.strike === true;
  const code: boolean = styleType === 'code' || extras.code === true;
  const dialogue: boolean = styleType === 'dialogue' || extras.dialogue === true;
  const narrator: boolean = styleType === 'narrator' || styleType === 'action' || extras.narrator === true;
  return {
    text,
    styleType,
    colorRole,
    bold,
    italic,
    strike,
    code,
    dialogue,
    narrator,
    linkTarget: extras.linkTarget !== undefined ? extras.linkTarget : '',
    symbolRuleId: extras.symbolRuleId !== undefined ? extras.symbolRuleId : '',
    lineStart: extras.lineStart !== undefined ? extras.lineStart : false,
    listLevel: extras.listLevel !== undefined ? extras.listLevel : 0
  };
}

/**
 * 解析选项。
 */
export interface ChatTextParserOptions {
  /** 是否启用 Markdown 解析(默认 true) */
  readonly enableMarkdown: boolean;
  /** 是否启用对白配色(默认 true) */
  readonly enableDialogue: boolean;
  /**
   * 是否把「前端界面 HTML 大块」抽成折叠块(默认 true)。
   * 折叠块内部嵌套渲染时必须传 false,否则源码会被再次折叠(套娃)。
   */
  readonly extractFrontendHtml?: boolean;
  /**
   * 自定义符号配色规则(可选)。
   * 非空时在 Markdown/代码还原之后、对白/动作识别之前扫描:
   * 命中片段携带 symbolRuleId 且优先级最高(覆盖对白/动作等语义色)。
   * 为空或未传时不改变任何解析行为。
   */
  readonly symbolRules?: ChatSymbolColorRule[];
}

/** 默认解析选项 */
export const DEFAULT_PARSER_OPTIONS: ChatTextParserOptions = {
  enableMarkdown: true,
  enableDialogue: true,
  extractFrontendHtml: true
};

// ===== 占位符工具 =====

/** 代码占位符前缀,使用 PUA 区域避免与正文冲突 */
const CODE_PLACEHOLDER_PREFIX: string = '\uE000C';
const CODE_PLACEHOLDER_SUFFIX: string = '\uE001C';

interface CodePlaceholder {
  readonly text: string;
  readonly isBlock: boolean;
}

/**
 * 解析入口。
 * 解析失败时安全降级为单个普通文本片段。
 */
export function parseChatText(
  content: string,
  options: ChatTextParserOptions = DEFAULT_PARSER_OPTIONS
): ChatTextSegment[] {
  if (content.length === 0) {
    return [];
  }
  try {
    return doParse(content, options);
  } catch (e) {
    // 安全降级
    return [createSegment(content)];
  }
}

/**
 * 实际解析逻辑。
 */
function doParse(content: string, options: ChatTextParserOptions): ChatTextSegment[] {
  // 1. 保护代码块和行内代码
  const codePlaceholders: CodePlaceholder[] = [];
  const afterCode: string = protectCode(content, codePlaceholders);

  // 2. 按行拆分,处理行级语法(引用、列表)
  const lines: string[] = afterCode.split('\n');
  const lineSegments: ChatTextSegment[][] = [];

  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    const isFirstLine: boolean = i === 0;
    const segments: ChatTextSegment[] = parseLine(line, isFirstLine, options, codePlaceholders);
    lineSegments.push(segments);
  }

  // 3. 合并所有行,行间插入换行片段
  const merged: ChatTextSegment[] = [];
  for (let i = 0; i < lineSegments.length; i++) {
    if (i > 0) {
      merged.push(createSegment('\n', 'normal', 'default'));
    }
    const segs: ChatTextSegment[] = lineSegments[i];
    for (let j = 0; j < segs.length; j++) {
      merged.push(segs[j]);
    }
  }

  // 4. 合并连续相同样式的片段
  return mergeConsecutive(merged);
}

/**
 * 保护代码块(```...```)和行内代码(`...`)。
 * 用占位符替换,解析完成后再还原。
 */
function protectCode(content: string, placeholders: CodePlaceholder[]): string {
  let result: string = content;

  // 代码块 ```lang\n...\n```
  const codeBlockPattern: RegExp = /```[^\n]*\n?([\s\S]*?)```/g;
  result = result.replace(codeBlockPattern, (_match: string, code: string): string => {
    const index: number = placeholders.length;
    placeholders.push({ text: code, isBlock: true });
    return CODE_PLACEHOLDER_PREFIX + index.toString() + CODE_PLACEHOLDER_SUFFIX;
  });

  // 行内代码 `code`
  const inlineCodePattern: RegExp = /`([^`\n]+)`/g;
  result = result.replace(inlineCodePattern, (_match: string, code: string): string => {
    const index: number = placeholders.length;
    placeholders.push({ text: code, isBlock: false });
    return CODE_PLACEHOLDER_PREFIX + index.toString() + CODE_PLACEHOLDER_SUFFIX;
  });

  return result;
}

/**
 * 解析单行。
 */
function parseLine(
  line: string,
  isFirstLine: boolean,
  options: ChatTextParserOptions,
  codePlaceholders: CodePlaceholder[]
): ChatTextSegment[] {
  if (line.length === 0) {
    return [];
  }

  // 检测 Markdown 标题 # ## ###(1-6 级)
  const headerMatch: RegExpMatchArray | null = line.match(/^\s*(#{1,6})\s+(.*)$/);
  if (headerMatch !== null) {
    const level: number = headerMatch[1].length;
    const headingContent: string = headerMatch[2].trim();
    // 标题以加粗 + 标题色呈现,内容内部仍可解析行内 Markdown(如 **加粗**)
    const inner: ChatTextSegment[] = parseInlineMarkdown(headingContent, options, codePlaceholders, true);
    const wrapped: ChatTextSegment[] = [];
    for (let i = 0; i < inner.length; i++) {
      const s: ChatTextSegment = inner[i];
      wrapped.push({
        text: s.text,
        styleType: 'header',
        colorRole: 'header',
        bold: true,
        italic: s.italic,
        strike: s.strike,
        code: s.code,
        dialogue: false,
        narrator: false,
        linkTarget: s.linkTarget,
        symbolRuleId: s.symbolRuleId,
        lineStart: i === 0,
        listLevel: level
      });
    }
    return wrapped;
  }

  // 检测分隔线 --- / *** / ___
  const hrMatch: RegExpMatchArray | null = line.match(/^\s*(-{3,}|\*{3,}|_{3,})\s*$/);
  if (hrMatch !== null) {
    return [createSegment('――――――――', 'hr', 'secondary', { lineStart: isFirstLine })];
  }

  // 检测引用 >
  const quoteMatch: RegExpMatchArray | null = line.match(/^>\s?(.*)$/);
  if (quoteMatch !== null) {
    const quoteContent: string = quoteMatch[1];
    const inner: ChatTextSegment[] = parseInlineMarkdown(quoteContent, options, codePlaceholders);
    // 标记为引用样式
    const quoted: ChatTextSegment[] = [];
    for (let i = 0; i < inner.length; i++) {
      const s: ChatTextSegment = inner[i];
      quoted.push({
        text: s.text,
        styleType: 'quote',
        colorRole: 'quote',
        bold: s.bold,
        italic: s.italic,
        strike: s.strike,
        code: s.code,
        dialogue: s.dialogue,
        narrator: s.narrator,
        linkTarget: s.linkTarget,
        symbolRuleId: s.symbolRuleId,
        lineStart: i === 0,
        listLevel: 0
      });
    }
    return quoted;
  }

  // 检测无序列表 - * +
  const unorderedMatch: RegExpMatchArray | null = line.match(/^(\s*)([-*+])\s+(.*)$/);
  if (unorderedMatch !== null) {
    const indent: string = unorderedMatch[1];
    const listContent: string = unorderedMatch[3];
    const level: number = Math.floor(indent.length / 2);
    const inner: ChatTextSegment[] = parseInlineMarkdown(listContent, options, codePlaceholders);
    const listed: ChatTextSegment[] = [];
    // 前缀"• "
    listed.push(createSegment('• ', 'list_item', 'default', { lineStart: true, listLevel: level }));
    for (let i = 0; i < inner.length; i++) {
      const s: ChatTextSegment = inner[i];
      listed.push({
        text: s.text,
        styleType: s.styleType,
        colorRole: s.colorRole,
        bold: s.bold,
        italic: s.italic,
        strike: s.strike,
        code: s.code,
        dialogue: s.dialogue,
        narrator: s.narrator,
        linkTarget: s.linkTarget,
        symbolRuleId: s.symbolRuleId,
        lineStart: false,
        listLevel: level
      });
    }
    return listed;
  }

  // 检测有序列表 1.
  const orderedMatch: RegExpMatchArray | null = line.match(/^(\s*)(\d+)\.\s+(.*)$/);
  if (orderedMatch !== null) {
    const indent: string = orderedMatch[1];
    const num: string = orderedMatch[2];
    const listContent: string = orderedMatch[3];
    const level: number = Math.floor(indent.length / 2);
    const inner: ChatTextSegment[] = parseInlineMarkdown(listContent, options, codePlaceholders);
    const listed: ChatTextSegment[] = [];
    listed.push(createSegment(num + '. ', 'list_item', 'default', { lineStart: true, listLevel: level }));
    for (let i = 0; i < inner.length; i++) {
      const s: ChatTextSegment = inner[i];
      listed.push({
        text: s.text,
        styleType: s.styleType,
        colorRole: s.colorRole,
        bold: s.bold,
        italic: s.italic,
        strike: s.strike,
        code: s.code,
        dialogue: s.dialogue,
        narrator: s.narrator,
        linkTarget: s.linkTarget,
        symbolRuleId: s.symbolRuleId,
        lineStart: false,
        listLevel: level
      });
    }
    return listed;
  }

  // 检测旁白 —— --
  const narratorMatch: RegExpMatchArray | null = line.match(/^(——|--)\s*(.*)$/);
  if (narratorMatch !== null) {
    const narratorContent: string = narratorMatch[2];
    return [createSegment(narratorContent, 'narrator', 'narrator', { narrator: true, lineStart: isFirstLine })];
  }

  // 普通行:解析行内 Markdown
  return parseInlineMarkdown(line, options, codePlaceholders);
}

/**
 * 是否为 Markdown 表格行:以 | 开头,且包含至少 2 个 |。
 */
function isTableRow(line: string): boolean {
  if (!line.trimStart().startsWith('|')) {
    return false;
  }
  let count: number = 0;
  for (let i = 0; i < line.length; i++) {
    if (line.charAt(i) === '|') {
      count++;
    }
  }
  return count >= 2;
}

/**
 * 解析行内 Markdown。
 * 顺序:链接 → 加粗斜体 → 加粗 → 斜体 → 删除线 → 还原代码 → 对白
 * @param skipDecorations true 时跳过对白/动作装饰识别(用于表格单元格)
 */
function parseInlineMarkdown(
  text: string,
  options: ChatTextParserOptions,
  codePlaceholders: CodePlaceholder[],
  skipDecorations: boolean = false
): ChatTextSegment[] {
  if (text.length === 0) {
    return [];
  }

  let segments: ChatTextSegment[] = [createSegment(text)];

  if (options.enableMarkdown) {
    // 链接 [text](url)
    segments = applyLinks(segments);
    // 加粗斜体 ***text*** 或 ___text___
    segments = applyBoldItalic(segments);
    // 加粗 **text** 或 __text__
    segments = applyBold(segments);
    // 斜体 *text* 或 _text_
    segments = applyItalic(segments);
    // 删除线 ~~text~~
    segments = applyStrikethrough(segments);
  }

  // 还原代码占位符
  segments = restoreCode(segments, codePlaceholders);

  // 自定义符号识别(用户规则优先于对白/动作;代码还原后做,避免代码内容被误判)
  if (!skipDecorations && options.symbolRules !== undefined && options.symbolRules.length > 0) {
    segments = applyCustomSymbols(segments, options.symbolRules);
  }

  // 对白识别(在代码还原后做,避免代码内容被误判)
  if (options.enableDialogue && !skipDecorations) {
    segments = applyDialogue(segments);
    // 括号动作/旁白识别 (…)、（…）
    segments = applyParenthetical(segments);
  }

  // 合并连续相同样式
  return mergeConsecutive(segments);
}

/**
 * 识别 Markdown 链接 [text](url)。
 * 只处理 normal 类型片段,已格式化的片段跳过。
 */
function applyLinks(segments: ChatTextSegment[]): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  const linkPattern: RegExp = /\[([^\]]+)\]\(([^)\s]+)\)/g;

  for (let i = 0; i < segments.length; i++) {
    const seg: ChatTextSegment = segments[i];
    if (seg.styleType !== 'normal') {
      result.push(seg);
      continue;
    }
    const parts: ChatTextSegment[] = splitByPattern(seg.text, linkPattern, (match: RegExpExecArray): ChatTextSegment => {
      const linkText: string = match[1];
      const url: string = match[2];
      return createSegment(linkText, 'link', 'link', { linkTarget: url });
    });
    for (let j = 0; j < parts.length; j++) {
      result.push(parts[j]);
    }
  }
  return result;
}

/**
 * 识别加粗斜体 ***text*** 或 ___text___。
 */
function applyBoldItalic(segments: ChatTextSegment[]): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  const pattern: RegExp = /\*\*\*([^*\n]+)\*\*\*|___([^_\n]+)___/g;

  for (let i = 0; i < segments.length; i++) {
    const seg: ChatTextSegment = segments[i];
    if (seg.styleType !== 'normal') {
      result.push(seg);
      continue;
    }
    const parts: ChatTextSegment[] = splitByPattern(seg.text, pattern, (match: RegExpExecArray): ChatTextSegment => {
      const text: string = match[1] !== undefined ? match[1] : match[2];
      return createSegment(text, 'bold_italic', 'emphasis', { bold: true, italic: true });
    });
    for (let j = 0; j < parts.length; j++) {
      result.push(parts[j]);
    }
  }
  return result;
}

/**
 * 识别加粗 **text** 或 __text__。
 */
function applyBold(segments: ChatTextSegment[]): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  const pattern: RegExp = /\*\*([^*\n]+)\*\*|__([^_\n]+)__/g;

  for (let i = 0; i < segments.length; i++) {
    const seg: ChatTextSegment = segments[i];
    if (seg.styleType !== 'normal') {
      result.push(seg);
      continue;
    }
    const parts: ChatTextSegment[] = splitByPattern(seg.text, pattern, (match: RegExpExecArray): ChatTextSegment => {
      const text: string = match[1] !== undefined ? match[1] : match[2];
      return createSegment(text, 'bold', 'emphasis', { bold: true });
    });
    for (let j = 0; j < parts.length; j++) {
      result.push(parts[j]);
    }
  }
  return result;
}

/**
 * 识别斜体 *text* 或 _text_。
 * 注意:单个 * 必须成对出现才识别,避免与加粗冲突。
 */
function applyItalic(segments: ChatTextSegment[]): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  const pattern: RegExp = /(^|[^*])\*([^*\n]+)\*(?!\*)|(^|[^_])_([^_\n]+)_(?!_)/g;

  for (let i = 0; i < segments.length; i++) {
    const seg: ChatTextSegment = segments[i];
    if (seg.styleType !== 'normal') {
      result.push(seg);
      continue;
    }
    const parts: ChatTextSegment[] = splitByPatternWithPrefix(seg.text, pattern, (match: RegExpExecArray, content: string): ChatTextSegment => {
      // match[2] 是 *text* 的内容,match[4] 是 _text_ 的内容
      const text: string = match[2] !== undefined ? match[2] : match[4];
      return createSegment(text, 'italic', 'secondary', { italic: true });
    });
    for (let j = 0; j < parts.length; j++) {
      result.push(parts[j]);
    }
  }
  return result;
}

/**
 * 识别删除线 ~~text~~。
 */
function applyStrikethrough(segments: ChatTextSegment[]): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  const pattern: RegExp = /~~([^~\n]+)~~/g;

  for (let i = 0; i < segments.length; i++) {
    const seg: ChatTextSegment = segments[i];
    if (seg.styleType !== 'normal') {
      result.push(seg);
      continue;
    }
    const parts: ChatTextSegment[] = splitByPattern(seg.text, pattern, (match: RegExpExecArray): ChatTextSegment => {
      const text: string = match[1];
      return createSegment(text, 'strikethrough', 'secondary', { strike: true });
    });
    for (let j = 0; j < parts.length; j++) {
      result.push(parts[j]);
    }
  }
  return result;
}

/**
 * 是否已命中自定义符号规则。
 * 命中片段必须原样透传给后续 pass:它们仍是 styleType='normal',
 * 若被后续 pass 再次拆分重建,规则绑定(symbolRuleId)会在重建时丢失。
 */
function isSymbolSegment(seg: ChatTextSegment): boolean {
  return seg.colorRole === 'symbol';
}

/**
 * 识别角色对白。
 * 支持:"对白" “对白” 「对白」 『对白』
 * 不识别:代码片段内的引号、未闭合引号、英文缩写撇号、已命中自定义符号的片段
 */
function applyDialogue(segments: ChatTextSegment[]): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  // 匹配成对引号:"..." “...” 「...」 『...』
  // 不匹配跨行的(已按行处理)
  const dialoguePattern: RegExp = /["“「『]([^"”」』\n]+)["”」』]/g;

  for (let i = 0; i < segments.length; i++) {
    const seg: ChatTextSegment = segments[i];
    // 代码、链接、引用不识别对白
    if (seg.styleType === 'code' || seg.styleType === 'link' || seg.styleType === 'quote') {
      result.push(seg);
      continue;
    }
    // 已命中自定义符号规则:保持原样(自定义符号优先于对白)
    if (isSymbolSegment(seg)) {
      result.push(seg);
      continue;
    }
    if (seg.styleType !== 'normal') {
      result.push(seg);
      continue;
    }
    const parts: ChatTextSegment[] = splitByPattern(seg.text, dialoguePattern, (match: RegExpExecArray): ChatTextSegment => {
      const dialogueText: string = match[0]; // 包含引号
      return createSegment(dialogueText, 'dialogue', 'dialogue', { dialogue: true });
    });
    for (let j = 0; j < parts.length; j++) {
      result.push(parts[j]);
    }
  }
  return result;
}

/**
 * 正则元字符转义(用于把用户输入的符号安全拼进正则)。
 */
function escapeRegExp(text: string): string {
  let out: string = '';
  for (let i = 0; i < text.length; i++) {
    const c: string = text.charAt(i);
    if ('\\^$.*+?()[]{}|/-'.indexOf(c) >= 0) {
      out += '\\';
    }
    out += c;
  }
  return out;
}

/**
 * 转义为字符类内部安全的字面量([ ] \ ^ - 需转义,其余按字面)。
 */
function escapeInCharClass(c: string): string {
  if (c === '\\' || c === ']' || c === '^' || c === '-') {
    return '\\' + c;
  }
  return c;
}

/**
 * 构造单个符号规则的匹配正则:起始符号 + 内容 + 结束符号(不跨行、不嵌套)。
 */
function buildSymbolPattern(rule: ChatSymbolColorRule): RegExp {
  const contentClass: string = escapeInCharClass(rule.open) + escapeInCharClass(rule.close);
  return new RegExp(escapeRegExp(rule.open) + '([^' + contentClass + '\\n]+)' + escapeRegExp(rule.close), 'g');
}

/**
 * 识别用户自定义符号对(如 【】)。
 *
 * - 只处理 normal 片段(代码/链接/引用等已格式化片段跳过)
 * - 按规则顺序依次扫描,先命中的规则生效(不支持嵌套)
 * - 命中片段携带 symbolRuleId,渲染时优先级最高
 * - 未闭合符号保留为普通文本
 */
function applyCustomSymbols(segments: ChatTextSegment[], rules: ChatSymbolColorRule[]): ChatTextSegment[] {
  let current: ChatTextSegment[] = segments;
  for (let r = 0; r < rules.length; r++) {
    const rule: ChatSymbolColorRule = rules[r];
    if (rule.open.length === 0 || rule.close.length === 0) {
      continue;
    }
    const pattern: RegExp = buildSymbolPattern(rule);
    const next: ChatTextSegment[] = [];
    for (let i = 0; i < current.length; i++) {
      const seg: ChatTextSegment = current[i];
      // 跳过非普通片段与已被前序规则命中的片段(同一样子不被第二条规则重建覆盖)
      if (seg.styleType !== 'normal' || isSymbolSegment(seg)) {
        next.push(seg);
        continue;
      }
      const parts: ChatTextSegment[] = splitByPattern(seg.text, pattern, (match: RegExpExecArray): ChatTextSegment => {
        return createSegment(match[0], 'normal', 'symbol', { symbolRuleId: rule.id });
      });
      for (let j = 0; j < parts.length; j++) {
        next.push(parts[j]);
      }
    }
    current = next;
  }
  return current;
}

/**
 * 识别括号包裹的动作/旁白 (…)、（…）。
 * 括号整体作为动作片段(保留括号),赋予 action 颜色。
 * 只处理 normal 片段,跳过代码/链接/引用/对白等已格式化片段。
 */
function applyParenthetical(segments: ChatTextSegment[]): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  // 匹配成对括号(半角/全角),不匹配跨行、不匹配嵌套
  const parentheticalPattern: RegExp = /[\(（][^\(\)（）\n]+[\)）]/g;

  for (let i = 0; i < segments.length; i++) {
    const seg: ChatTextSegment = segments[i];
    // 已命中自定义符号规则:保持原样(自定义符号优先于动作/旁白)
    if (seg.styleType !== 'normal' || isSymbolSegment(seg)) {
      result.push(seg);
      continue;
    }
    const parts: ChatTextSegment[] = splitByPattern(seg.text, parentheticalPattern, (match: RegExpExecArray): ChatTextSegment => {
      return createSegment(match[0], 'action', 'action', { narrator: true });
    });
    for (let j = 0; j < parts.length; j++) {
      result.push(parts[j]);
    }
  }
  return result;
}

/**
 * 还原代码占位符。
 */
function restoreCode(segments: ChatTextSegment[], placeholders: CodePlaceholder[]): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  const placeholderPattern: RegExp = new RegExp(
    CODE_PLACEHOLDER_PREFIX + '(\\d+)' + CODE_PLACEHOLDER_SUFFIX,
    'g'
  );

  for (let i = 0; i < segments.length; i++) {
    const seg: ChatTextSegment = segments[i];
    if (seg.styleType !== 'normal') {
      result.push(seg);
      continue;
    }
    // 检查是否就是单个占位符
    const singleMatch: RegExpMatchArray | null = seg.text.match(
      new RegExp('^' + CODE_PLACEHOLDER_PREFIX + '(\\d+)' + CODE_PLACEHOLDER_SUFFIX + '$')
    );
    if (singleMatch !== null) {
      const idx: number = parseInt(singleMatch[1], 10);
      if (idx >= 0 && idx < placeholders.length) {
        const ph: CodePlaceholder = placeholders[idx];
        result.push(createSegment(ph.text, 'code', 'code', { code: true }));
        continue;
      }
    }
    // 文本中混合占位符的情况:按占位符拆分
    if (seg.text.indexOf(CODE_PLACEHOLDER_PREFIX) >= 0) {
      const parts: ChatTextSegment[] = splitByPattern(seg.text, placeholderPattern, (match: RegExpExecArray): ChatTextSegment => {
        const idx: number = parseInt(match[1], 10);
        if (idx >= 0 && idx < placeholders.length) {
          const ph: CodePlaceholder = placeholders[idx];
          return createSegment(ph.text, 'code', 'code', { code: true });
        }
        return createSegment(match[0]);
      });
      for (let j = 0; j < parts.length; j++) {
        result.push(parts[j]);
      }
    } else {
      result.push(seg);
    }
  }
  return result;
}

// ===== 工具函数 =====

/**
 * 按正则模式拆分文本。
 * 匹配的部分用 matcher 生成片段,未匹配部分保留为普通文本。
 */
function splitByPattern(
  text: string,
  pattern: RegExp,
  matcher: (match: RegExpExecArray) => ChatTextSegment
): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  let lastIndex: number = 0;
  let execResult: RegExpExecArray | null;
  // 重置 lastIndex(全局正则复用)
  pattern.lastIndex = 0;

  while ((execResult = pattern.exec(text)) !== null) {
    const matchStart: number = execResult.index;
    // 未匹配前缀
    if (matchStart > lastIndex) {
      const prefix: string = text.substring(lastIndex, matchStart);
      if (prefix.length > 0) {
        result.push(createSegment(prefix));
      }
    }
    // 匹配片段
    result.push(matcher(execResult));
    lastIndex = matchStart + execResult[0].length;
    // 防止零宽匹配死循环
    if (execResult[0].length === 0) {
      pattern.lastIndex++;
    }
  }
  // 尾部未匹配
  if (lastIndex < text.length) {
    const suffix: string = text.substring(lastIndex);
    if (suffix.length > 0) {
      result.push(createSegment(suffix));
    }
  }
  return result;
}

/**
 * 按正则模式拆分文本(带前缀保留)。
 * 用于斜体等需要保留前导字符的场景。
 */
function splitByPatternWithPrefix(
  text: string,
  pattern: RegExp,
  matcher: (match: RegExpExecArray, content: string) => ChatTextSegment
): ChatTextSegment[] {
  const result: ChatTextSegment[] = [];
  let lastIndex: number = 0;
  let execResult: RegExpExecArray | null;
  pattern.lastIndex = 0;

  while ((execResult = pattern.exec(text)) !== null) {
    const matchStart: number = execResult.index;
    // 前缀(包含 match[1] 或 match[3] 的前导字符)
    const prefixEnd: number = matchStart + execResult[0].length;
    const fullMatch: string = execResult[0];
    // 提取前导字符
    const leadingChar: string = execResult[1] !== undefined ? execResult[1] : (execResult[3] !== undefined ? execResult[3] : '');
    const leadingLen: number = leadingChar.length;

    // 未匹配前缀
    if (matchStart > lastIndex) {
      const prefix: string = text.substring(lastIndex, matchStart);
      if (prefix.length > 0) {
        result.push(createSegment(prefix));
      }
    }
    // 前导字符作为普通文本
    if (leadingLen > 0) {
      result.push(createSegment(leadingChar));
    }
    // 匹配内容
    const content: string = execResult[2] !== undefined ? execResult[2] : (execResult[4] !== undefined ? execResult[4] : '');
    result.push(matcher(execResult, content));
    lastIndex = prefixEnd;
    if (fullMatch.length === 0) {
      pattern.lastIndex++;
    }
  }
  // 尾部
  if (lastIndex < text.length) {
    const suffix: string = text.substring(lastIndex);
    if (suffix.length > 0) {
      result.push(createSegment(suffix));
    }
  }
  return result;
}

/**
 * 合并连续相同样式的片段。
 * 减少渲染节点数量。
 */
function mergeConsecutive(segments: ChatTextSegment[]): ChatTextSegment[] {
  if (segments.length === 0) {
    return [];
  }
  const result: ChatTextSegment[] = [segments[0]];
  for (let i = 1; i < segments.length; i++) {
    const cur: ChatTextSegment = segments[i];
    const last: ChatTextSegment = result[result.length - 1];
    if (canMerge(last, cur)) {
      // 合并:替换最后一个
      const merged: ChatTextSegment = {
        text: last.text + cur.text,
        styleType: last.styleType,
        colorRole: last.colorRole,
        bold: last.bold,
        italic: last.italic,
        strike: last.strike,
        code: last.code,
        dialogue: last.dialogue,
        narrator: last.narrator,
        linkTarget: last.linkTarget,
        symbolRuleId: last.symbolRuleId,
        lineStart: last.lineStart,
        listLevel: last.listLevel
      };
      result[result.length - 1] = merged;
    } else {
      result.push(cur);
    }
  }
  return result;
}

/**
 * 判断两个片段是否可以合并。
 */
function canMerge(a: ChatTextSegment, b: ChatTextSegment): boolean {
  return a.styleType === b.styleType
    && a.colorRole === b.colorRole
    && a.bold === b.bold
    && a.italic === b.italic
    && a.strike === b.strike
    && a.code === b.code
    && a.dialogue === b.dialogue
    && a.narrator === b.narrator
    && a.linkTarget === b.linkTarget
    && a.symbolRuleId === b.symbolRuleId
    && a.listLevel === b.listLevel
    && !b.lineStart; // 行首标记不合并
}

// ===== 交互分块渲染(ChatRenderChunk)=====
//
// 支持 SillyTavern 风格的富文本：
// - <details><summary>标题</summary>内容</details> → 可点击折叠块
// - <branches>[选项1]\n[选项2]</branches> → 可点击选项
// - <思考>/<变量思考>/<upstore> 指令块 → 隐藏
// - {{roll 1d20}} / {{roll::2d6+3}} 骰子宏 → 随机结果
// - <div>/<p>/<span>/<br>/<hr> 等 HTML 标签 → 消毒为换行/分隔线

/**
 * 渲染分块。
 * ChatRichText 据此在"纯文本"与"文本 + 交互块"两种布局间切换。
 */
/** 文本分块 */
export interface TextChatRenderChunk {
  readonly type: 'text';
  readonly segments: ChatTextSegment[];
}
/** 折叠分块(<details>) */
export interface CollapsibleChatRenderChunk {
  readonly type: 'collapsible';
  readonly id: string;
  readonly title: string;
  /** 折叠内容(原文,由嵌套渲染再次解析) */
  readonly content: string;
}
/** 分支选项分块(<branches>) */
export interface BranchesChatRenderChunk {
  readonly type: 'branches';
  readonly id: string;
  readonly options: string[];
}

/** 表格分块中的一行 */
export interface TableChunkRow {
  /** 是否为表头行(紧跟分隔行) */
  readonly isHeader: boolean;
  /** 每格已解析的行内片段(列数已补齐到全表最大列数) */
  readonly cells: ChatTextSegment[][];
}

/** 表格分块 */
export interface TableChatRenderChunk {
  readonly type: 'table';
  readonly id: string;
  readonly rows: TableChunkRow[];
}

/** 图片分块(markdown ![](url) 或 <img src>;仅 https) */
export interface ImageChatRenderChunk {
  readonly type: 'image';
  readonly id: string;
  readonly url: string;
  readonly alt: string;
}

/** 渲染分块联合 */
export type ChatRenderChunk =
  | TextChatRenderChunk
  | CollapsibleChatRenderChunk
  | BranchesChatRenderChunk
  | TableChatRenderChunk
  | ImageChatRenderChunk;

/** 交互块占位符前缀/后缀(仅用于解析中间态) */
const BLOCK_PLACEHOLDER: string = '\uE200';
const BLOCK_PLACEHOLDER_END: string = '\uE201';
/** 匹配单个占位符 "索引" */
const BLOCK_PLACEHOLDER_PATTERN: RegExp = new RegExp('^' + BLOCK_PLACEHOLDER + '(\\d+)' + BLOCK_PLACEHOLDER_END + '$');

/** 命中的交互块(原始内容) */
interface SourceBlock {
  readonly tag: string;
  readonly content: string;
}

interface BlockMarker {
  readonly open: boolean;
  readonly tag: string;
  readonly start: number;
  readonly end: number;
}

/** 交互块抽取结果 */
interface InteractiveExtraction {
  readonly residual: string;
  readonly blocks: SourceBlock[];
}

/** 匹配到的成对括号下标 */
interface BlockPair {
  readonly open: number;
  readonly close: number;
}

/** <details> 解析结果 */
interface CollapsibleParsed {
  readonly title: string;
  readonly body: string;
}

/** _.set(...) 变量操作行提取结果 */
interface SetOperationExtraction {
  /** 移除变量操作行后的剩余文本 */
  readonly residual: string;
  /** 提取到的变量操作行(含可能的前后 ``` 围栏之间的内容) */
  readonly lines: string[];
}

/** 折叠块 id 序号(保证 id 唯一) */
let setSeqCounter: number = 0;

/** 需要整体隐藏的指令块标签(含内容删除) */
const INSTRUCTION_TAGS: string[] = ['思考', '变量思考', 'upstore', 'thought', 'reasoning'];

/** 块级 HTML 标签:其开始/结束标签都当作换行边界 */
const BLOCK_HTML_TAGS: string =
  'div|p|section|article|ul|ol|li|tr|td|table|thead|tbody|h1|h2|h3|h4|h5|h6|blockquote|center|form|nav|header|footer';

/**
 * 解析聊天内容为渲染分块列表。
 * 失败时降级为单个文本块(原始内容)。
 */
export function parseChatChunks(
  content: string,
  options: ChatTextParserOptions = DEFAULT_PARSER_OPTIONS
): ChatRenderChunk[] {
  if (content.length === 0) {
    return [];
  }
  try {
    const extracted: InteractiveExtraction = extractInteractiveBlocks(content);
    if (extracted.blocks.length === 0) {
      return buildLightChunks(extracted.residual, options);
    }

    const chunks: ChatRenderChunk[] = [];
    // 按占位符切成段,占位符处还原交互块,其余走文本管线(含表格分组)
    const parts: string[] = extracted.residual.split(/(\uE200\d+\uE201)/g);
    for (let i = 0; i < parts.length; i++) {
      const part: string = parts[i];
      if (part.length === 0) {
        continue;
      }
      const ph: RegExpMatchArray | null = part.match(BLOCK_PLACEHOLDER_PATTERN);
      if (ph !== null) {
        const idx: number = parseInt(ph[1], 10);
        if (idx >= 0 && idx < extracted.blocks.length) {
          const block: SourceBlock = extracted.blocks[idx];
          if (block.tag === 'details') {
            const col: CollapsibleParsed = parseCollapsibleBody(block.content);
            const c: CollapsibleChatRenderChunk = {
              type: 'collapsible',
              id: 'cb' + idx,
              title: col.title,
              content: col.body
            };
            chunks.push(c);
          } else if (block.tag === 'branches') {
            const b: BranchesChatRenderChunk = {
              type: 'branches',
              id: 'br' + idx,
              options: parseBranchOptions(block.content)
            };
            chunks.push(b);
          }
        }
      } else {
        const built: ChatRenderChunk[] = buildLightChunks(part, options);
        for (let j = 0; j < built.length; j++) {
          chunks.push(built[j]);
        }
      }
    }
    return chunks;
  } catch (_e) {
    // 安全降级:整条按普通文本显示,不丢字
    const fallback: TextChatRenderChunk = { type: 'text', segments: [createSegment(content)] };
    return [fallback];
  }
}

// ===== v50: 前端界面 HTML 大块折叠 =====

/** HTML 型围栏的语言标记(命中即视为前端页面,不看长度) */
const FRONTEND_HTML_LANGS: string[] = ['html', 'htm', 'xml'];
/** 无语言标记时,内容达到该长度且含 HTML 特征才视为前端页面 */
const FRONTEND_HTML_MIN_CHARS: number = 600;
/** 折叠块占位符(仅解析中间态,渲染后不出现) */
const FE_PLACEHOLDER: string = '\uE300';
const FE_PLACEHOLDER_END: string = '\uE301';
const FE_PLACEHOLDER_PATTERN: RegExp =
  new RegExp('^' + FE_PLACEHOLDER + '(\\d+)' + FE_PLACEHOLDER_END + '$');

/** 前端界面大块抽取结果 */
interface FrontendExtraction {
  /** 抽走大块后的剩余文本(原位置留一行占位符,渲染时按序还原为折叠块) */
  readonly residual: string;
  /** 折叠块(按出现顺序) */
  readonly blocks: CollapsibleChatRenderChunk[];
}

/** 消息内图片占位符(仅用于解析中间态;独立成行,渲染时按序还原为图片分块) */
const IMG_PLACEHOLDER: string = '\uE202';
const IMG_PLACEHOLDER_END: string = '\uE203';
/** 匹配单个图片占位符 "索引" */
const IMG_PLACEHOLDER_PATTERN: RegExp =
  new RegExp('^' + IMG_PLACEHOLDER + '(\\d+)' + IMG_PLACEHOLDER_END + '$');

/** 消息内图片抽取结果 */
interface ImageExtraction {
  /** 抽走图片后的剩余文本(原位置留占位符行) */
  readonly residual: string;
  /** 图片分块(按出现顺序) */
  readonly blocks: ImageChatRenderChunk[];
}

/** 图片语法命中区间(原文下标 + 提取结果) */
interface ImageHit {
  readonly start: number;
  readonly end: number;
  readonly url: string;
  readonly alt: string;
}

/** markdown 图片语法:![alt](https://...) */
const MD_IMAGE_RE: RegExp = /!\[([^\]]*)\]\((https:\/\/[^)\s]+)\)/g;
/** HTML img 标签(属性顺序任意;src 是否 https 由抽取逻辑判断) */
const IMG_TAG_RE: RegExp = /<img\b[^>]*>/gi;
/** img 标签内 src 属性(双引号/单引号) */
const IMG_TAG_SRC_RE: RegExp = /src\s*=\s*(?:"([^"]*)"|'([^']*)')/i;
/** img 标签内 alt 属性(双引号/单引号,可选) */
const IMG_TAG_ALT_RE: RegExp = /alt\s*=\s*(?:"([^"]*)"|'([^']*)')/i;

/** 从 img 标签串里提取 src(无 src 返回空串) */
function extractImgTagSrc(tag: string): string {
  const m: RegExpExecArray | null = IMG_TAG_SRC_RE.exec(tag);
  if (m === null) {
    return '';
  }
  return m[1] !== undefined ? m[1] : (m[2] !== undefined ? m[2] : '');
}

/** 从 img 标签串里提取 alt(无 alt 返回空串) */
function extractImgTagAlt(tag: string): string {
  const m: RegExpExecArray | null = IMG_TAG_ALT_RE.exec(tag);
  if (m === null) {
    return '';
  }
  return m[1] !== undefined ? m[1] : (m[2] !== undefined ? m[2] : '');
}

/**
 * 抽取消息文本内的网络图片(markdown ![](url) 与 <img src> 两种语法)为图片分块。
 * - 仅 https:// 生效;http:// 命中不抽取,留给原消毒管线(与 MarketCharacterAvatar 口径一致)
 * - 必须在 sanitizeHtmlTags 之前调用:消毒会删除 <img> 标签导致 URL 丢失
 * - 占位符两侧以换行隔离,保证行扫描时独立成行(不与表格行判断互相干扰)
 */
function extractImageLinks(text: string): ImageExtraction {
  const blocks: ImageChatRenderChunk[] = [];
  // 收集所有命中区间(含 url/alt),按原文位置排序后重建文本,避免下标位移
  const hits: ImageHit[] = [];
  MD_IMAGE_RE.lastIndex = 0;
  let m: RegExpExecArray | null = MD_IMAGE_RE.exec(text);
  while (m !== null) {
    hits.push({ start: m.index, end: m.index + m[0].length, url: m[2], alt: m[1] });
    m = MD_IMAGE_RE.exec(text);
  }
  IMG_TAG_RE.lastIndex = 0;
  m = IMG_TAG_RE.exec(text);
  while (m !== null) {
    const src: string = extractImgTagSrc(m[0]);
    if (src.startsWith('https://')) {
      hits.push({ start: m.index, end: m.index + m[0].length, url: src, alt: extractImgTagAlt(m[0]) });
    }
    m = IMG_TAG_RE.exec(text);
  }
  if (hits.length === 0) {
    return { residual: text, blocks: blocks };
  }
  hits.sort((a: ImageHit, b: ImageHit): number => a.start - b.start);
  const out: string[] = [];
  let cursor: number = 0;
  for (let i = 0; i < hits.length; i++) {
    const h: ImageHit = hits[i];
    if (h.start < cursor) {
      continue; // 重叠命中(不应出现)跳过
    }
    out.push(text.substring(cursor, h.start));
    out.push('\n' + IMG_PLACEHOLDER + blocks.length.toString() + IMG_PLACEHOLDER_END + '\n');
    blocks.push({ type: 'image', id: 'img' + blocks.length.toString(), url: h.url, alt: h.alt });
    cursor = h.end;
  }
  out.push(text.substring(cursor));
  return { residual: out.join(''), blocks: blocks };
}

/** 该围栏内容是否像「角色卡前端界面」(整页 HTML):先过长度门槛(短示例不折叠),再看语言/结构 */
function isFrontendHtmlFence(lang: string, body: string): boolean {
  // 短片段(对话里的 HTML 示例)保持原样,不当成前端页面
  if (body.length < FRONTEND_HTML_MIN_CHARS) {
    return false;
  }
  const l: string = lang.trim().toLowerCase();
  for (let i = 0; i < FRONTEND_HTML_LANGS.length; i++) {
    if (l === FRONTEND_HTML_LANGS[i]) {
      return true;
    }
  }
  const lower: string = body.toLowerCase();
  return lower.indexOf('<style') >= 0 || lower.indexOf('<div') >= 0
    || lower.indexOf('<script') >= 0 || lower.indexOf('<!doctype') >= 0
    || lower.indexOf('<body') >= 0;
}

/**
 * 抽取「前端界面 HTML 大块」(契约 v3 卡片:开场白常把整页前端 HTML 放在 ``` 围栏里)。
 * 不抽的话整页标签会铺满聊天气泡,而且 sanitizeHtmlTags 会先删掉标签导致源码都看不全;
 * 抽出后气泡只显示一行「🖼 前端界面」标题,点开才看源码(原文照旧保存在消息里)。
 * 必须在 sanitizeHtmlTags 之前调用(消毒会删标签)。
 */
function extractFrontendHtmlBlocks(text: string): FrontendExtraction {
  const blocks: CollapsibleChatRenderChunk[] = [];
  const outLines: string[] = [];
  const lines: string[] = text.split('\n');
  let i: number = 0;
  while (i < lines.length) {
    const open: RegExpMatchArray | null = lines[i].match(/^ {0,3}```([^\n`]*)$/);
    if (open === null) {
      outLines.push(lines[i]);
      i++;
      continue;
    }
    let close: number = -1;
    for (let j = i + 1; j < lines.length; j++) {
      if (/^ {0,3}```\s*$/.test(lines[j])) {
        close = j;
        break;
      }
    }
    if (close < 0) {
      // 未闭合(可能还在流式输出):原样保留,闭合后再折叠
      outLines.push(lines[i]);
      i++;
      continue;
    }
    const lang: string = open[1];
    const body: string = lines.slice(i + 1, close).join('\n');
    if (isFrontendHtmlFence(lang, body)) {
      const kb: number = Math.max(1, Math.round(body.length / 1024));
      blocks.push({
        type: 'collapsible',
        id: 'fe' + blocks.length.toString(),
        title: '🖼 前端界面（' + kb.toString() + 'KB，点开查看源码）',
        // 内容仍按代码块交给嵌套渲染:等宽显示与长按复制不变
        content: '```\n' + body + '\n```'
      });
      outLines.push(FE_PLACEHOLDER + (blocks.length - 1).toString() + FE_PLACEHOLDER_END);
    } else {
      for (let k = i; k <= close; k++) {
        outLines.push(lines[k]);
      }
    }
    i = close + 1;
  }
  return { residual: outLines.join('\n'), blocks: blocks };
}

/**
 * 轻量管线(无交互块时的文本构建):
 * 隐藏指令块 → 掷骰宏 → HTML 消毒 → 按行扫描,把连续表格行聚合成 table 分块,
 * 其余行作为文本分块。文本分块内部复用 parseChatText(支持整段多行)。
 *
 * 相比旧的 parseLightTextPipeline(只产出 text 分块),表格不再内联渲染,
 * 而是作为一个结构化表格分块交给渲染层做列对齐。
 */
function buildLightChunks(text: string, options: ChatTextParserOptions): ChatRenderChunk[] {
  const result: ChatRenderChunk[] = [];
  let s: string = text;
  // 先提取 _.set(...) 变量操作行(含可能包裹的 ``` 围栏)→ 折叠块(默认收起,点击展开)
  const setExtracted: SetOperationExtraction = extractSetOperationLines(s);
  if (setExtracted.lines.length > 0) {
    const setChunk: CollapsibleChatRenderChunk = {
      type: 'collapsible',
      id: 'set_' + setSeqCounter.toString(),
      title: '变量初始化 (' + setExtracted.lines.length + ')',
      content: setExtracted.lines.join('\n')
    };
    setSeqCounter++;
    result.push(setChunk);
  }
  s = setExtracted.residual;
  s = stripInstructionBlocks(s);
  s = resolveDiceMacros(s);
  // v50: 先抽「前端界面 HTML 大块」→ 折叠块(必须在 sanitizeHtmlTags 之前:消毒会删标签,源码就没了)
  // 折叠块内部嵌套渲染时 options.extractFrontendHtml=false,避免把源码再折叠一层(套娃)
  let fe: FrontendExtraction = { residual: s, blocks: [] };
  if (options.extractFrontendHtml !== false) {
    fe = extractFrontendHtmlBlocks(s);
  }
  s = fe.residual;
  // 消息内网络图片抽取(必须在 sanitizeHtmlTags 之前:消毒会删 <img> 标签导致 URL 丢失)
  const imgs: ImageExtraction = extractImageLinks(s);
  s = imgs.residual;
  s = sanitizeHtmlTags(s);
  if (s.length === 0) {
    return [];
  }
  const lines: string[] = s.split('\n');
  // 累积的普通文本行(整段交给 parseChatText,保留内部换行语义)
  const textLines: string[] = [];
  // 累积的连续表格行(聚合成一个 table 分块)
  const tableLines: string[] = [];
  let tableSeq: number = 0;

  const flushText = (): void => {
    if (textLines.length === 0) {
      return;
    }
    const segs: ChatTextSegment[] = parseChatText(textLines.join('\n'), options);
    textLines.length = 0;
    if (segs.length > 0) {
      const t: TextChatRenderChunk = { type: 'text', segments: segs };
      result.push(t);
    }
  };
  const flushTable = (): void => {
    if (tableLines.length === 0) {
      return;
    }
    result.push({
      type: 'table',
      id: 'tbl' + tableSeq.toString(),
      rows: parseTableBlock(tableLines, options)
    });
    tableSeq++;
    tableLines.length = 0;
  };

  for (let i = 0; i < lines.length; i++) {
    // v50: 前端界面大块占位符 → 按序还原为折叠块(位置与原文一致)
    const feMatch: RegExpMatchArray | null = lines[i].match(FE_PLACEHOLDER_PATTERN);
    if (feMatch !== null) {
      flushText();
      flushTable();
      const feIdx: number = parseInt(feMatch[1], 10);
      if (feIdx >= 0 && feIdx < fe.blocks.length) {
        result.push(fe.blocks[feIdx]);
      }
      continue;
    }
    // 消息内图片占位符 → 按序还原为图片分块(位置与原文一致)
    const imgMatch: RegExpMatchArray | null = lines[i].match(IMG_PLACEHOLDER_PATTERN);
    if (imgMatch !== null) {
      flushText();
      flushTable();
      const imgIdx: number = parseInt(imgMatch[1], 10);
      if (imgIdx >= 0 && imgIdx < imgs.blocks.length) {
        result.push(imgs.blocks[imgIdx]);
      }
      continue;
    }
    if (isTableRow(lines[i])) {
      flushText();
      tableLines.push(lines[i]);
    } else {
      flushTable();
      textLines.push(lines[i]);
    }
  }
  flushText();
  flushTable();
  return result;
}

/**
 * 解析一个表格分块(连续表格行)。
 * - 单元格以 | 分隔,内容复用 parseInlineMarkdown(支持加粗/行内代码等)
 * - 分隔行(| --- | --- |)不显示,把上一行标记为表头
 * - 列数以全表最大列数为准,不足补空格占位列
 */
function parseTableBlock(lines: string[], options: ChatTextParserOptions): TableChunkRow[] {
  // 单元格内行内代码等仍需代码块保护,按表整体走一次 protectCode
  const placeholders: CodePlaceholder[] = [];
  const protectedText: string = protectCode(lines.join('\n'), placeholders);
  const rawLines: string[] = protectedText.split('\n');

  const rows: TableChunkRow[] = [];
  for (let i = 0; i < rawLines.length; i++) {
    const cells: string[] | null = splitTableCells(rawLines[i]);
    if (cells === null) {
      continue;
    }
    // 分隔行:仅标记上一行为表头,不单独渲染
    if (isSeparatorRow(cells)) {
      if (rows.length > 0 && !rows[rows.length - 1].isHeader) {
        const prev: TableChunkRow = rows[rows.length - 1];
        rows[rows.length - 1] = { isHeader: true, cells: prev.cells };
      }
      continue;
    }
    const cellSegs: ChatTextSegment[][] = [];
    for (let j = 0; j < cells.length; j++) {
      cellSegs.push(parseInlineMarkdown(cells[j], options, placeholders, true));
    }
    rows.push({ isHeader: false, cells: cellSegs });
  }

  // 补齐列数(不足的列补空格占位,保证渲染层列宽一致)
  let colCount: number = 0;
  for (let i = 0; i < rows.length; i++) {
    colCount = Math.max(colCount, rows[i].cells.length);
  }
  if (colCount === 0) {
    return rows;
  }
  for (let i = 0; i < rows.length; i++) {
    while (rows[i].cells.length < colCount) {
      rows[i] = {
        isHeader: rows[i].isHeader,
        cells: rows[i].cells.concat([[createSegment(' ')]])
      };
    }
  }
  return rows;
}

/**
 * 拆分表格行单元格:以 | 分割并 trim。非表格行返回 null。
 */
function splitTableCells(line: string): string[] | null {
  if (!isTableRow(line)) {
    return null;
  }
  const parts: string[] = line.split('|');
  const cells: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    const t: string = parts[i].trim();
    if (t.length > 0) {
      cells.push(t);
    }
  }
  return cells;
}

/**
 * 是否表格分隔行(每个单元都是 :?-+:? 形式的横线)。
 */
function isSeparatorRow(cells: string[]): boolean {
  let ok: boolean = cells.length > 0;
  for (let i = 0; i < cells.length; i++) {
    if (!/^:?-+:?$/.test(cells[i])) {
      ok = false;
      break;
    }
  }
  return ok;
}

/**
 * 抽取外层已闭合的 <details> 与 <branches> 块,用占位符替换。
 * 未闭合(流式中)的块不会被抽取,保留为普通文本。
 */
function extractInteractiveBlocks(input: string): InteractiveExtraction {
  const tagRe: RegExp = /<\/(details|branches)\s*>|<(details|branches)\b[^>]*>/gi;
  const markers: BlockMarker[] = [];
  let m: RegExpExecArray | null;
  while ((m = tagRe.exec(input)) !== null) {
    // m[1] 是闭合标签的 tag 名, m[2] 是开始标签的 tag 名
    const closeTag: string = m[1] as string;
    const openTag: string = m[2] as string;
    const start: number = m.index as number;
    const end: number = start + m[0].length;
    if (openTag !== undefined) {
      const mk: BlockMarker = { open: true, tag: openTag.toLowerCase(), start: start, end: end };
      markers.push(mk);
    } else if (closeTag !== undefined) {
      const mk: BlockMarker = { open: false, tag: closeTag.toLowerCase(), start: start, end: end };
      markers.push(mk);
    }
  }

  // 用栈匹配同标签的外层对(忽略跨标签嵌套,按同标签匹配)
  const stack: number[] = [];
  const pairs: BlockPair[] = [];
  for (let i = 0; i < markers.length; i++) {
    const mk: BlockMarker = markers[i];
    if (mk.open) {
      stack.push(i);
      continue;
    }
    for (let j = stack.length - 1; j >= 0; j--) {
      if (markers[stack[j]].tag === mk.tag) {
        const pr: BlockPair = { open: stack[j], close: i };
        pairs.push(pr);
        stack.splice(j, 1);
        break;
      }
    }
  }

  // 只保留最外层对(剔除嵌套在其它对内部的)
  const outer: BlockPair[] = [];
  for (let i = 0; i < pairs.length; i++) {
    let nested: boolean = false;
    for (let j = 0; j < pairs.length; j++) {
      if (i !== j && pairs[j].open < pairs[i].open && pairs[j].close > pairs[i].close) {
        nested = true;
        break;
      }
    }
    if (!nested) {
      outer.push(pairs[i]);
    }
  }
  outer.sort((a: BlockPair, b: BlockPair): number => a.open - b.open);

  const blocks: SourceBlock[] = [];
  let residual: string = '';
  let cursor: number = 0;
  for (let i = 0; i < outer.length; i++) {
    const p: BlockPair = outer[i];
    const om: BlockMarker = markers[p.open];
    const cm: BlockMarker = markers[p.close];
    if (om.start < cursor) {
      continue;
    }
    residual += input.slice(cursor, om.start);
    const idx: number = blocks.length;
    residual += BLOCK_PLACEHOLDER + idx + BLOCK_PLACEHOLDER_END;
    const sb: SourceBlock = { tag: om.tag, content: input.slice(om.end, cm.start) };
    blocks.push(sb);
    cursor = cm.end;
  }
  residual += input.slice(cursor);
  const r: InteractiveExtraction = { residual: residual, blocks: blocks };
  return r;
}

/**
 * 解析 <details> 内容:剥离开头的 <summary>标题</summary>。
 */
function parseCollapsibleBody(contentRaw: string): CollapsibleParsed {
  const summaryRe: RegExp = /^\s*<summary\b[^>]*>([\s\S]*?)<\/summary\s*>/i;
  const m: RegExpExecArray | null = summaryRe.exec(contentRaw);
  if (m !== null) {
    const title: string = sanitizeHtmlTags(m[1] as string).trim();
    const body: string = contentRaw.slice((m.index as number) + m[0].length);
    const r: CollapsibleParsed = { title: title, body: body };
    return r;
  }
  const r2: CollapsibleParsed = { title: '', body: contentRaw };
  return r2;
}

/**
 * 解析 <branches> 内容:按行切分选项,空的去掉,去掉 [channel=?] 前缀。
 */
function parseBranchOptions(contentRaw: string): string[] {
  const out: string[] = [];
  const lines: string[] = contentRaw.split('\n');
  for (let i = 0; i < lines.length; i++) {
    let line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    line = line.replace(/^\[channel=[^\]]+\]\s*/i, '');
    if (line.length > 0) {
      out.push(line);
    }
  }
  return out;
}

/**
 * 隐藏指令块:<思考>…</思考>、<变量思考>…</变量思考>、<upstore>…</upstore> 等。
 * 整块删除(含内容与可能的前导换行)。未闭合时保守保留(降级为普通文本)。
 */
function stripInstructionBlocks(input: string): string {
  let s: string = input;
  for (let i = 0; i < INSTRUCTION_TAGS.length; i++) {
    const tag: string = INSTRUCTION_TAGS[i];
    const pat: RegExp = new RegExp('\\s*<' + tag + '\\b[^>]*>[\\s\\S]*?</' + tag + '>', 'gi');
    s = s.replace(pat, '');
  }
  s = s.replace(/[\n]+\s*$/, '\n');
  return s;
}

/**
 * 提取 _.set(...) 变量操作行。
 * AI 可能直接输出 `_.set('路径', 旧值, 新值); // 注释` 形式的变量操作(upstore 协议的另一种写法),
 * 这些是给前端解析执行的状态配置,不应作为叙事正文展示,提取为可折叠块(默认收起)。
 * 若变量操作行被 Markdown ``` 围栏包裹,围栏一并吸收,避免残留孤立的 ```。
 */
function extractSetOperationLines(input: string): SetOperationExtraction {
  const lines: string[] = input.split('\n');
  const removed: boolean[] = new Array(lines.length).fill(false);
  const out: string[] = [];
  const setRe: RegExp = /_\.set\(/;
  const fenceRe: RegExp = /^\s*```/;
  let i: number = 0;
  while (i < lines.length) {
    if (setRe.test(lines[i])) {
      let j: number = i;
      while (j < lines.length && setRe.test(lines[j])) {
        out.push(lines[j]);
        j++;
      }
      for (let k: number = i; k < j; k++) {
        removed[k] = true;
      }
      // 吸收紧邻的前后 ``` 围栏行(若有),避免残留孤立围栏
      const stripOpen: boolean = i > 0 && fenceRe.test(lines[i - 1]);
      const stripClose: boolean = j < lines.length && fenceRe.test(lines[j]);
      if (stripOpen) {
        removed[i - 1] = true;
      }
      if (stripClose) {
        removed[j] = true;
        i = j + 1;
      } else {
        i = j;
      }
    } else {
      i++;
    }
  }
  const residualLines: string[] = [];
  for (let k: number = 0; k < lines.length; k++) {
    if (!removed[k]) {
      residualLines.push(lines[k]);
    }
  }
  const result: SetOperationExtraction = {
    residual: residualLines.join('\n'),
    lines: out
  };
  return result;
}

/**
 * 解析骰子宏 {{roll 1d20}} / {{roll:1d6}} / {{roll::2d6+3}}。
 * 输出掷骰结果(整数,含修饰项)。非法公式保持原样。
 */
function resolveDiceMacros(input: string): string {
  const pat: RegExp = /\{\{\s*roll\s*[:\s]*([0-9]+d[0-9]+(?:[+-][0-9]+)?)\s*\}\}/gi;
  return input.replace(pat, (_match: string, formula: string): string => rollDice(formula));
}

function rollDice(formula: string): string {
  const clean: string = formula.replace(/\s/g, '');
  const diceRe: RegExp = /^(\d+)d(\d+)([+-]\d+)?$/;
  const m: RegExpExecArray | null = diceRe.exec(clean);
  if (m === null) {
    return formula;
  }
  let count: number = parseInt(m[1], 10);
  const sides: number = parseInt(m[2], 10);
  const mod: number = m[3] !== undefined ? parseInt(m[3], 10) : 0;
  if (sides < 1) {
    return formula;
  }
  if (count < 1) {
    count = 1;
  }
  if (count > 100) {
    count = 100;
  }
  let sum: number = 0;
  for (let i = 0; i < count; i++) {
    sum += 1 + Math.floor(Math.random() * sides);
  }
  return String(sum + mod);
}

/**
 * HTML 消毒:整体删除 style/script/head/title 块;
 * <br>→换行、<hr>→分隔线、块级标签→换行边界;
 * 剥除其余标签保留文字;解码常见 HTML 实体;收敛连续空行。
 */
function sanitizeHtmlTags(input: string): string {
  let s: string = input;
  s = s.replace(/<(style|script|head|title)[^>]*>[\s\S]*?<\/\1>/gi, '');
  s = s.replace(/<br\s*\/?>/gi, '\n');
  s = s.replace(/<hr\s*\/?>/gi, '\n---\n');
  s = s.replace(new RegExp('</?(' + BLOCK_HTML_TAGS + ')[^>]*>', 'gi'), '\n');
  s = s.replace(/<[^>]+>/g, '');
  s = decodeHtmlEntities(s);
  s = s.replace(/\n{3,}/g, '\n\n');
  s = s.replace(/^\n+|\n+$/g, '');
  return s;
}

/**
 * 解码常见 HTML 实体。
 */
function decodeHtmlEntities(input: string): string {
  return input
    .replace(/&nbsp;/gi, ' ')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/gi, "'")
    .replace(/&amp;/gi, '&');
}
