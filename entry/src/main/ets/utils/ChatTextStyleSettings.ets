/**
 * ChatTextStyleSettings 聊天文本样式设置
 *
 * 职责:
 * - 管理聊天富文本渲染相关的用户偏好
 * - 基于 AppPreferences 持久化
 * - 提供默认值与恢复默认
 * - 提供 version 号用于缓存失效
 *
 * 设置项:
 * - enableMarkdown: 启用 Markdown 解析
 * - enableDialogue: 启用对白配色
 * - enableCharacterColor: 角色独立颜色
 * - fontSize: 字体大小(fp)
 * - lineHeight: 行间距倍数
 * - quoteStyle: 引用样式
 * - codeStyle: 代码样式
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from './Logger';

const LOG_TAG: string = 'ChatTextStyleSettings';

/** 引用样式选项 */
export type QuoteStyle = 'line' | 'indent';
/** 代码样式选项 */
export type CodeStyle = 'bg' | 'plain';

/** 聊天文本样式设置 */
export interface ChatTextStyle {
  readonly enableMarkdown: boolean;
  readonly enableDialogue: boolean;
  readonly enableCharacterColor: boolean;
  readonly fontSize: number;
  readonly lineHeight: number;
  readonly quoteStyle: QuoteStyle;
  readonly codeStyle: CodeStyle;
}

/** 默认设置 */
export const DEFAULT_CHAT_TEXT_STYLE: ChatTextStyle = {
  enableMarkdown: true,
  enableDialogue: true,
  enableCharacterColor: true,
  fontSize: 16,
  lineHeight: 1.5,
  quoteStyle: 'line',
  codeStyle: 'bg'
};

// Preferences keys
const KEY_ENABLE_MARKDOWN: string = 'chat_text_enable_markdown';
const KEY_ENABLE_DIALOGUE: string = 'chat_text_enable_dialogue';
const KEY_ENABLE_CHARACTER_COLOR: string = 'chat_text_enable_character_color';
const KEY_FONT_SIZE: string = 'chat_text_font_size';
const KEY_LINE_HEIGHT: string = 'chat_text_line_height';
const KEY_QUOTE_STYLE: string = 'chat_text_quote_style';
const KEY_CODE_STYLE: string = 'chat_text_code_style';

/**
 * 聊天文本样式设置管理器。
 * 单例,由 AppServices 持有。
 */
export class ChatTextStyleSettings {
  private readonly prefs: AppPreferences;
  private current: ChatTextStyle;
  /** 设置版本号,每次修改自增,用于缓存失效 */
  private version: number;

  constructor(prefs: AppPreferences) {
    this.prefs = prefs;
    this.current = DEFAULT_CHAT_TEXT_STYLE;
    this.version = 1;
  }

  /**
   * 从 Preferences 加载设置。
   * 应在 AppServices 初始化时调用。
   */
  async load(): Promise<void> {
    try {
      const enableMarkdown: boolean = await this.prefs.getBoolean(KEY_ENABLE_MARKDOWN, DEFAULT_CHAT_TEXT_STYLE.enableMarkdown);
      const enableDialogue: boolean = await this.prefs.getBoolean(KEY_ENABLE_DIALOGUE, DEFAULT_CHAT_TEXT_STYLE.enableDialogue);
      const enableCharacterColor: boolean = await this.prefs.getBoolean(KEY_ENABLE_CHARACTER_COLOR, DEFAULT_CHAT_TEXT_STYLE.enableCharacterColor);
      const fontSizeStr: string = await this.prefs.getString(KEY_FONT_SIZE, DEFAULT_CHAT_TEXT_STYLE.fontSize.toString());
      const lineHeightStr: string = await this.prefs.getString(KEY_LINE_HEIGHT, DEFAULT_CHAT_TEXT_STYLE.lineHeight.toString());
      const quoteStyleStr: string = await this.prefs.getString(KEY_QUOTE_STYLE, DEFAULT_CHAT_TEXT_STYLE.quoteStyle);
      const codeStyleStr: string = await this.prefs.getString(KEY_CODE_STYLE, DEFAULT_CHAT_TEXT_STYLE.codeStyle);

      const fontSize: number = parseInt(fontSizeStr, 10);
      const lineHeight: number = parseFloat(lineHeightStr);

      this.current = {
        enableMarkdown,
        enableDialogue,
        enableCharacterColor,
        fontSize: isNaN(fontSize) ? DEFAULT_CHAT_TEXT_STYLE.fontSize : fontSize,
        lineHeight: isNaN(lineHeight) ? DEFAULT_CHAT_TEXT_STYLE.lineHeight : lineHeight,
        quoteStyle: quoteStyleStr === 'indent' ? 'indent' : 'line',
        codeStyle: codeStyleStr === 'plain' ? 'plain' : 'bg'
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'load failed, use default: ' + (e as Error).message);
      this.current = DEFAULT_CHAT_TEXT_STYLE;
    }
  }

  /**
   * 获取当前设置。
   */
  get(): ChatTextStyle {
    return this.current;
  }

  /**
   * 获取当前版本号(用于缓存失效)。
   */
  getVersion(): number {
    return this.version;
  }

  /**
   * 更新设置(部分字段)。
   * 自动持久化并自增版本号。
   */
  async update(partial: Partial<ChatTextStyle>): Promise<void> {
    const next: ChatTextStyle = {
      enableMarkdown: partial.enableMarkdown !== undefined ? partial.enableMarkdown : this.current.enableMarkdown,
      enableDialogue: partial.enableDialogue !== undefined ? partial.enableDialogue : this.current.enableDialogue,
      enableCharacterColor: partial.enableCharacterColor !== undefined ? partial.enableCharacterColor : this.current.enableCharacterColor,
      fontSize: partial.fontSize !== undefined ? partial.fontSize : this.current.fontSize,
      lineHeight: partial.lineHeight !== undefined ? partial.lineHeight : this.current.lineHeight,
      quoteStyle: partial.quoteStyle !== undefined ? partial.quoteStyle : this.current.quoteStyle,
      codeStyle: partial.codeStyle !== undefined ? partial.codeStyle : this.current.codeStyle
    };
    await this.persist(next);
    this.current = next;
    this.version++;
  }

  /**
   * 恢复默认设置。
   */
  async resetToDefault(): Promise<void> {
    await this.persist(DEFAULT_CHAT_TEXT_STYLE);
    this.current = DEFAULT_CHAT_TEXT_STYLE;
    this.version++;
  }

  /**
   * 持久化设置到 Preferences。
   */
  private async persist(style: ChatTextStyle): Promise<void> {
    try {
      await this.prefs.putBoolean(KEY_ENABLE_MARKDOWN, style.enableMarkdown);
      await this.prefs.putBoolean(KEY_ENABLE_DIALOGUE, style.enableDialogue);
      await this.prefs.putBoolean(KEY_ENABLE_CHARACTER_COLOR, style.enableCharacterColor);
      await this.prefs.putString(KEY_FONT_SIZE, style.fontSize.toString());
      await this.prefs.putString(KEY_LINE_HEIGHT, style.lineHeight.toString());
      await this.prefs.putString(KEY_QUOTE_STYLE, style.quoteStyle);
      await this.prefs.putString(KEY_CODE_STYLE, style.codeStyle);
    } catch (e) {
      Logger.warn(LOG_TAG, 'persist failed: ' + (e as Error).message);
    }
  }
}
