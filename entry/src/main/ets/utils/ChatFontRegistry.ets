/**
 * ChatFontRegistry 聊天正文字体注册表
 *
 * 职责:
 * - 声明可选字体(显示名 + 注册用 familyName + 字库文件)
 * - 应用启动时把内置字库注册进系统(font.registerFont),之后 Text/Span 可用 familyName 引用
 *
 * 说明:
 * - familyName 为空表示"系统默认"(不需要注册)
 * - 中文字库体积大,故只内置一款开源字库(霞鹭文楷,OFL 协议,见 resources/rawfile/fonts/)
 * - 后续"用户自行导入字体"只需在此追加一项:把文件落到应用沙箱后注册,familyName 记入设置即可
 */

import { font } from '@kit.ArkUI';
import { Logger } from './Logger';

const LOG_TAG: string = 'ChatFontRegistry';

/** 系统默认字体族(HarmonyOS 默认字体) */
export const CHAT_FONT_SYSTEM: string = 'HarmonyOS Sans';
/** 内置:霞鹭文楷(楷体风,开源 OFL) */
export const CHAT_FONT_WENKAI: string = 'LXGWWenKai';

/** 一个可选字体项 */
export interface ChatFontOption {
  /** 稳定 id(仅用于 UI key / 持久化识别) */
  readonly id: string;
  /** 列表展示名 */
  readonly label: string;
  /** 应用到 Text.fontFamily 的字体族名;空串 = 系统默认 */
  readonly familyName: string;
  /** rawfile 内的相对路径;空串 = 无需注册(系统字体) */
  readonly rawfile: string;
}

const FONT_OPTION_SYSTEM: ChatFontOption = {
  id: 'system',
  label: '系统默认',
  familyName: CHAT_FONT_SYSTEM,
  rawfile: ''
};

const FONT_OPTION_WENKAI: ChatFontOption = {
  id: 'wenkai',
  label: '霞鹭文楷',
  familyName: CHAT_FONT_WENKAI,
  rawfile: 'fonts/LXGWWenKai-Regular.ttf'
};

/** 可选字体列表(顺序即 UI 展示顺序) */
export const CHAT_FONT_OPTIONS: ChatFontOption[] = [FONT_OPTION_SYSTEM, FONT_OPTION_WENKAI];

/** 取某字体族对应的展示名;未登记时回退展示名 = familyName */
export function chatFontLabel(familyName: string): string {
  for (let i = 0; i < CHAT_FONT_OPTIONS.length; i++) {
    if (CHAT_FONT_OPTIONS[i].familyName === familyName) {
      return CHAT_FONT_OPTIONS[i].label;
    }
  }
  return familyName;
}

/**
 * 注册内置字库(应用启动时调用一次)。
 * 需要有 UI 上下文($rawfile 解析),故放在入口页 aboutToAppear。
 */
export function registerBuiltinChatFonts(): void {
  for (let i = 0; i < CHAT_FONT_OPTIONS.length; i++) {
    const option: ChatFontOption = CHAT_FONT_OPTIONS[i];
    if (option.rawfile.length === 0) {
      continue;
    }
    try {
      font.registerFont({ familyName: option.familyName, familySrc: $rawfile(option.rawfile) });
    } catch (e) {
      Logger.warn(LOG_TAG, 'registerFont failed: ' + option.familyName + ' ' + (e as Error).message);
    }
  }
}