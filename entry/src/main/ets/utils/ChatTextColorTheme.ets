/**
 * ChatTextColorTheme 单人聊天字体配色主题
 *
 * 职责:
 * - 定义字体配色模式(AUTO / LIGHT / DARK / CUSTOM)
 * - 定义 Markdown 渲染器颜色主题接口(语义化字段)
 * - 提供预设主题(LIGHT / DARK)与默认颜色值
 *
 * 设计约束:
 * - 颜色值只允许 #RRGGBB 格式,禁止 Alpha 通道
 * - AUTO 模式返回 null,表示使用 ChatRichText 默认资源颜色($r('app.color.*'))
 * - LIGHT / DARK / CUSTOM 返回具体主题,覆盖默认资源颜色
 * - 不修改 Markdown 解析行为、节点结构、字体粗细、链接行为或换行逻辑
 * - 与气泡不透明度(chatBubbleOpacity)完全独立
 *
 * 语义化字段(与 ChatTextParser 的 colorRole 对应):
 * - bodyColor:     普通正文(default)
 * - emphasisColor: 加粗/斜体/删除线(emphasis + secondary)
 * - dialogueColor: 对白“”(dialogue + character)
 * - actionColor:   动作/旁白()(action + narrator)
 * - codeColor:     行内代码(code)
 * - linkColor:     链接(link)
 * - quoteColor:    引用块(quote)
 * - userColor:     用户消息(default + user)
 *
 * 不负责:
 * - 颜色选择 UI(由 ChatPage 显示设置面板提供)
 * - 持久化(由 ChatPage 负责)
 * - 气泡背景透明度(由 ChatMessageBubble 通过 bubbleOpacity 控制)
 */

/**
 * 字体配色模式。
 * - AUTO:使用 ChatRichText 默认资源颜色(不覆盖)
 * - LIGHT:适合深色或高度透明背景,文字偏浅
 * - DARK:适合浅色气泡背景,文字偏深
 * - CUSTOM:使用用户选择的颜色值
 */
export class ChatTextColorMode {
  static readonly AUTO: string = 'AUTO';
  static readonly LIGHT: string = 'LIGHT';
  static readonly DARK: string = 'DARK';
  static readonly CUSTOM: string = 'CUSTOM';
}

/**
 * Markdown 渲染器颜色主题。
 *
 * 传入 ChatRichText 后,仅覆盖片段颜色查询逻辑(getSegmentColor),
 * 不改变解析、节点结构、字体粗细、链接行为或换行逻辑。
 *
 * 颜色值格式:#RRGGBB(禁止 #AARRGGBB / rgba alpha < 1)。
 */
export interface ChatMarkdownColorTheme {
  /** 普通正文颜色 */
  readonly bodyColor: string;
  /** 加粗/斜体/删除线颜色 */
  readonly emphasisColor: string;
  /** 对白颜色(“”) */
  readonly dialogueColor: string;
  /** 动作/旁白颜色(()) */
  readonly actionColor: string;
  /** 行内代码颜色 */
  readonly codeColor: string;
  /** 链接颜色 */
  readonly linkColor: string;
  /** 引用块颜色 */
  readonly quoteColor: string;
  /** 用户消息文字颜色 */
  readonly userColor: string;
}

/** 默认正文颜色(DARK 模式色值) */
export const DEFAULT_BODY_TEXT_COLOR: string = '#171717';
/** 默认加粗/斜体颜色 */
export const DEFAULT_EMPHASIS_TEXT_COLOR: string = '#0D0D0D';
/** 默认对白颜色(蓝) */
export const DEFAULT_DIALOGUE_TEXT_COLOR: string = '#1565C0';
/** 默认动作/旁白颜色(灰蓝) */
export const DEFAULT_ACTION_TEXT_COLOR: string = '#607D8B';
/** 默认行内代码颜色(粉) */
export const DEFAULT_CODE_TEXT_COLOR: string = '#C2185B';
/** 默认链接颜色(蓝) */
export const DEFAULT_LINK_TEXT_COLOR: string = '#1976D2';
/** 默认引用块颜色(灰) */
export const DEFAULT_QUOTE_TEXT_COLOR: string = '#555555';
/** 默认用户消息文字颜色 */
export const DEFAULT_USER_TEXT_COLOR: string = '#FFFFFF';

/** LIGHT 模式正文颜色 */
export const LIGHT_BODY_TEXT_COLOR: string = '#FFFFFF';
/** LIGHT 模式加粗/斜体颜色 */
export const LIGHT_EMPHASIS_TEXT_COLOR: string = '#FFFFFF';
/** LIGHT 模式对白颜色(浅蓝) */
export const LIGHT_DIALOGUE_TEXT_COLOR: string = '#82B1FF';
/** LIGHT 模式动作/旁白颜色(浅灰蓝) */
export const LIGHT_ACTION_TEXT_COLOR: string = '#90A4AE';
/** LIGHT 模式行内代码颜色(浅粉) */
export const LIGHT_CODE_TEXT_COLOR: string = '#F48FB1';
/** LIGHT 模式链接颜色(浅蓝) */
export const LIGHT_LINK_TEXT_COLOR: string = '#90CAF9';
/** LIGHT 模式引用块颜色(浅灰) */
export const LIGHT_QUOTE_TEXT_COLOR: string = '#E5E7EB';
/** LIGHT 模式用户消息文字颜色 */
export const LIGHT_USER_TEXT_COLOR: string = '#FFFFFF';

/** Hex 颜色正则(#RRGGBB,禁止 Alpha) */
const HEX_REGEX: RegExp = /^#[0-9A-Fa-f]{6}$/;

/**
 * 校验颜色值是否为合法 #RRGGBB 格式。
 * 禁止 Alpha 通道(#AARRGGBB)与 CSS 函数(rgba/hsla)。
 */
export function isValidHexColor(color: string): boolean {
  return typeof color === 'string' && HEX_REGEX.test(color);
}

/**
 * 将合法 Hex 颜色标准化为大写。
 * 非法值返回 null,调用方不应提交。
 */
export function normalizeHexColor(color: string): string | null {
  if (!isValidHexColor(color)) {
    return null;
  }
  return color.toUpperCase();
}

/**
 * 构造 LIGHT 模式主题(适合深色或高度透明背景)。
 */
export function getLightColorTheme(): ChatMarkdownColorTheme {
  return {
    bodyColor: LIGHT_BODY_TEXT_COLOR,
    emphasisColor: LIGHT_EMPHASIS_TEXT_COLOR,
    dialogueColor: LIGHT_DIALOGUE_TEXT_COLOR,
    actionColor: LIGHT_ACTION_TEXT_COLOR,
    codeColor: LIGHT_CODE_TEXT_COLOR,
    linkColor: LIGHT_LINK_TEXT_COLOR,
    quoteColor: LIGHT_QUOTE_TEXT_COLOR,
    userColor: LIGHT_USER_TEXT_COLOR
  };
}

/**
 * 构造 DARK 模式主题(适合浅色气泡背景)。
 */
export function getDarkColorTheme(): ChatMarkdownColorTheme {
  return {
    bodyColor: DEFAULT_BODY_TEXT_COLOR,
    emphasisColor: DEFAULT_EMPHASIS_TEXT_COLOR,
    dialogueColor: DEFAULT_DIALOGUE_TEXT_COLOR,
    actionColor: DEFAULT_ACTION_TEXT_COLOR,
    codeColor: DEFAULT_CODE_TEXT_COLOR,
    linkColor: DEFAULT_LINK_TEXT_COLOR,
    quoteColor: DEFAULT_QUOTE_TEXT_COLOR,
    userColor: DEFAULT_USER_TEXT_COLOR
  };
}
