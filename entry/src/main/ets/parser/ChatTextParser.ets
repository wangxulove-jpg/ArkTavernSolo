/**
 * ChatTextParser 聊天富文本解析器
 *
 * 职责:
 * - 把聊天消息正文解析为带样式的 ChatTextSegment 片段列表
 * - 支持 Markdown 子集(加粗/斜体/删除线/行内代码/链接/引用/列表)
 * - 支持角色对白识别(中英文引号、日式引号、角色名前缀)
 * - 支持动作和旁白识别(括号包裹、——开头)
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
 * 8. 在剩余普通文本中识别对白(引号包裹)
 * 9. 合并连续且样式相同的片段
 *
 * 安全降级:
 * - 解析失败时返回 [ { text: 原始文本, styleType: 'normal' } ]
 * - 未闭合语法保留为普通文本,不丢字
 */

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
  | 'system'
  | 'character';

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
  const bold: boolean = styleType === 'bold' || styleType === 'bold_italic' || extras.bold === true;
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
}

/** 默认解析选项 */
export const DEFAULT_PARSER_OPTIONS: ChatTextParserOptions = {
  enableMarkdown: true,
  enableDialogue: true
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
 * 解析行内 Markdown。
 * 顺序:链接 → 加粗斜体 → 加粗 → 斜体 → 删除线 → 还原代码 → 对白
 */
function parseInlineMarkdown(
  text: string,
  options: ChatTextParserOptions,
  codePlaceholders: CodePlaceholder[]
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

  // 对白识别(在代码还原后做,避免代码内容被误判)
  if (options.enableDialogue) {
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
 * 识别角色对白。
 * 支持:"对白" “对白” 「对白」 『对白』
 * 不识别:代码片段内的引号、未闭合引号、英文缩写撇号
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
    if (seg.styleType !== 'normal') {
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
    && a.listLevel === b.listLevel
    && !b.lineStart; // 行首标记不合并
}
