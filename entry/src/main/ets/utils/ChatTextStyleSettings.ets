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
 * - fontFamily: 正文字体族(见 ChatFontRegistry)
 * - quoteStyle: 引用样式
 * - codeStyle: 代码样式
 * - imageWidthRatio: 消息内图片宽度占气泡的比例(v52,Aa 面板可调)
 * - mediaAutoPlay: 消息内视频是否自动播放(v51;默认关闭 = 视频默认暂停,放大后才播放)
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from './Logger';
import { CHAT_FONT_SYSTEM } from './ChatFontRegistry';

const LOG_TAG: string = 'ChatTextStyleSettings';

/** 引用样式选项 */
export type QuoteStyle = 'line' | 'indent';
/** 代码样式选项 */
export type CodeStyle = 'bg' | 'plain';

/** 消息内图片宽度比例下限(相对气泡宽度) */
export const IMAGE_WIDTH_RATIO_MIN: number = 0.3;
/** 消息内图片宽度比例上限(1.0 = 铺满气泡宽度) */
export const IMAGE_WIDTH_RATIO_MAX: number = 1.0;

/**
 * 归一化图片宽度比例(纯函数):
 * 非法值 / NaN / 越界 → 夹到 [MIN, MAX];默认取 DEFAULT。
 */
export function normalizeImageWidthRatio(value: number): number {
  if (!Number.isFinite(value)) {
    return DEFAULT_CHAT_TEXT_STYLE.imageWidthRatio;
  }
  if (value < IMAGE_WIDTH_RATIO_MIN) {
    return IMAGE_WIDTH_RATIO_MIN;
  }
  if (value > IMAGE_WIDTH_RATIO_MAX) {
    return IMAGE_WIDTH_RATIO_MAX;
  }
  return value;
}

/** 聊天文本样式设置 */
export interface ChatTextStyle {
  readonly enableMarkdown: boolean;
  readonly enableDialogue: boolean;
  readonly enableCharacterColor: boolean;
  readonly fontSize: number;
  readonly lineHeight: number;
  readonly fontFamily: string;
  readonly quoteStyle: QuoteStyle;
  readonly codeStyle: CodeStyle;
  /** v52: 消息内图片宽度占气泡的比例(0.3~1.0;1.0 = 铺满气泡宽度) */
  readonly imageWidthRatio: number;
  /** v51: 消息内视频是否自动播放(默认 false = 默认暂停,点击放大后才播放) */
  readonly mediaAutoPlay: boolean;
}

/** 默认设置 */
export const DEFAULT_CHAT_TEXT_STYLE: ChatTextStyle = {
  enableMarkdown: true,
  enableDialogue: true,
  enableCharacterColor: true,
  fontSize: 16,
  lineHeight: 1.5,
  fontFamily: CHAT_FONT_SYSTEM,
  quoteStyle: 'line',
  codeStyle: 'bg',
  imageWidthRatio: 1.0,
  mediaAutoPlay: false
};

// Preferences keys
const KEY_ENABLE_MARKDOWN: string = 'chat_text_enable_markdown';
const KEY_ENABLE_DIALOGUE: string = 'chat_text_enable_dialogue';
const KEY_ENABLE_CHARACTER_COLOR: string = 'chat_text_enable_character_color';
const KEY_FONT_SIZE: string = 'chat_text_font_size';
const KEY_LINE_HEIGHT: string = 'chat_text_line_height';
const KEY_FONT_FAMILY: string = 'chat_text_font_family';
const KEY_QUOTE_STYLE: string = 'chat_text_quote_style';
const KEY_CODE_STYLE: string = 'chat_text_code_style';
/** v52: 消息内图片宽度比例 */
const KEY_IMAGE_WIDTH_RATIO: string = 'chat_text_image_width_ratio';
/** v51: 消息内视频是否自动播放 */
const KEY_MEDIA_AUTO_PLAY: string = 'chat_text_media_auto_play';

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
      const fontFamilyStr: string = await this.prefs.getString(KEY_FONT_FAMILY, DEFAULT_CHAT_TEXT_STYLE.fontFamily);
      const quoteStyleStr: string = await this.prefs.getString(KEY_QUOTE_STYLE, DEFAULT_CHAT_TEXT_STYLE.quoteStyle);
      const codeStyleStr: string = await this.prefs.getString(KEY_CODE_STYLE, DEFAULT_CHAT_TEXT_STYLE.codeStyle);
      const imageWidthStr: string = await this.prefs.getString(KEY_IMAGE_WIDTH_RATIO, DEFAULT_CHAT_TEXT_STYLE.imageWidthRatio.toString());
      const mediaAutoPlay: boolean = await this.prefs.getBoolean(KEY_MEDIA_AUTO_PLAY, DEFAULT_CHAT_TEXT_STYLE.mediaAutoPlay);

      const fontSize: number = parseInt(fontSizeStr, 10);
      const lineHeight: number = parseFloat(lineHeightStr);
      const imageWidthRatio: number = parseFloat(imageWidthStr);

      this.current = {
        enableMarkdown,
        enableDialogue,
        enableCharacterColor,
        fontSize: isNaN(fontSize) ? DEFAULT_CHAT_TEXT_STYLE.fontSize : fontSize,
        lineHeight: isNaN(lineHeight) ? DEFAULT_CHAT_TEXT_STYLE.lineHeight : lineHeight,
        fontFamily: fontFamilyStr.length > 0 ? fontFamilyStr : DEFAULT_CHAT_TEXT_STYLE.fontFamily,
        quoteStyle: quoteStyleStr === 'indent' ? 'indent' : 'line',
        codeStyle: codeStyleStr === 'plain' ? 'plain' : 'bg',
        imageWidthRatio: normalizeImageWidthRatio(imageWidthRatio),
        mediaAutoPlay: mediaAutoPlay
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
      fontFamily: partial.fontFamily !== undefined ? partial.fontFamily : this.current.fontFamily,
      quoteStyle: partial.quoteStyle !== undefined ? partial.quoteStyle : this.current.quoteStyle,
      codeStyle: partial.codeStyle !== undefined ? partial.codeStyle : this.current.codeStyle,
      imageWidthRatio: partial.imageWidthRatio !== undefined
        ? normalizeImageWidthRatio(partial.imageWidthRatio)
        : this.current.imageWidthRatio,
      mediaAutoPlay: partial.mediaAutoPlay !== undefined
        ? partial.mediaAutoPlay
        : this.current.mediaAutoPlay
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
      await this.prefs.putString(KEY_FONT_FAMILY, style.fontFamily);
      await this.prefs.putString(KEY_QUOTE_STYLE, style.quoteStyle);
      await this.prefs.putString(KEY_CODE_STYLE, style.codeStyle);
      await this.prefs.putString(KEY_IMAGE_WIDTH_RATIO, style.imageWidthRatio.toString());
      await this.prefs.putBoolean(KEY_MEDIA_AUTO_PLAY, style.mediaAutoPlay);
    } catch (e) {
      Logger.warn(LOG_TAG, 'persist failed: ' + (e as Error).message);
    }
  }
}
