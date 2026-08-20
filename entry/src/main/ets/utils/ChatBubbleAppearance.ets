/**
 * ChatBubbleAppearance 聊天气泡外观共享 helper(G-UI-ALIGN-2A)
 *
 * 职责:
 * - 提供气泡不透明度的规范化、持久化、加载
 * - 提供气泡背景色的动态计算(基于 isDarkMode + bubbleOpacity)
 * - 单聊与多人聊天共享同一份 Preferences key,实现应用级显示设置一致
 *
 * 设计约束:
 * - 不依赖 ArkUI 组件 / 页面 / ViewModel
 * - 不修改 ChatPage / ChatMessageBubble(单聊保持原实现,避免回归)
 * - 颜色计算与 ChatMessageBubble 内部实现保持一致(#AARRGGBB 格式)
 * - Preferences key 与 ChatPage.PREF_KEY_BUBBLE_OPACITY 完全相同('chat_bubble_opacity')
 *
 * 共享规则:
 * - 单聊 ChatPage 已使用 'chat_bubble_opacity' key 持久化
 * - 多人聊天读取/写入同一 key,用户在任一页面调节,两端均生效
 * - 默认值 0.65,范围 0.0~1.0(与单聊 normalizeChatBubbleOpacity 完全一致),步进 0.1
 */

import { AppServices } from '../services/AppServices';

/**
 * 气泡不透明度 Preferences key(与 ChatPage.PREF_KEY_BUBBLE_OPACITY 完全相同)。
 * 单聊与多人聊天共享此 key,实现应用级显示设置一致。
 */
export const PREF_KEY_BUBBLE_OPACITY: string = 'chat_bubble_opacity';

/** 气泡不透明度默认值(与单聊一致) */
export const DEFAULT_BUBBLE_OPACITY: number = 0.65;
/** 气泡不透明度最小值(与单聊一致,允许 0.0) */
export const MIN_BUBBLE_OPACITY: number = 0.0;
/** 气泡不透明度最大值(与单聊一致,允许 1.0) */
export const MAX_BUBBLE_OPACITY: number = 1.0;

/**
 * 将气泡不透明度规范化到 [0.0, 1.0](与单聊 normalizeChatBubbleOpacity 完全一致)。
 * 非有限值返回默认值 0.65,越界值截断到范围内。
 */
export function normalizeBubbleOpacity(value: number): number {
  if (!Number.isFinite(value)) {
    return DEFAULT_BUBBLE_OPACITY;
  }
  if (value < MIN_BUBBLE_OPACITY) {
    return MIN_BUBBLE_OPACITY;
  }
  if (value > MAX_BUBBLE_OPACITY) {
    return MAX_BUBBLE_OPACITY;
  }
  return value;
}

/**
 * 从 Preferences 加载气泡不透明度。
 * 读取失败或未初始化时返回 DEFAULT_BUBBLE_OPACITY。
 */
export function loadBubbleOpacity(): Promise<number> {
  return new Promise<number>((resolve: (value: number) => void): void => {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        resolve(DEFAULT_BUBBLE_OPACITY);
        return;
      }
      prefs.getString(PREF_KEY_BUBBLE_OPACITY, DEFAULT_BUBBLE_OPACITY.toString())
        .then((value: string): void => {
          const parsed: number = parseFloat(value);
          if (Number.isFinite(parsed)) {
            resolve(normalizeBubbleOpacity(parsed));
          } else {
            resolve(DEFAULT_BUBBLE_OPACITY);
          }
        })
        .catch((_e: Object): void => {
          resolve(DEFAULT_BUBBLE_OPACITY);
        });
    } catch (_e) {
      resolve(DEFAULT_BUBBLE_OPACITY);
    }
  });
}

/**
 * 将气泡不透明度持久化到 Preferences。
 * 写入失败静默忽略(不影响 UI 交互)。
 */
export function persistBubbleOpacity(value: number): void {
  try {
    const prefs = AppServices.getAppPreferences();
    if (!prefs.isInitialized()) {
      return;
    }
    const normalized: number = normalizeBubbleOpacity(value);
    prefs.putString(PREF_KEY_BUBBLE_OPACITY, normalized.toString())
      .catch((_e: Object): void => {
        // 写入失败静默忽略
      });
  } catch (_e) {
    // AppServices 未初始化时静默忽略
  }
}

/**
 * 将 Alpha(0~1) 转为两位 16 进制字符串(大写)。
 * clamp 到 [0, 255] 后取整。
 */
export function alphaToHex(alpha: number): string {
  const clamped: number = Math.max(0, Math.min(255, Math.round(alpha * 255)));
  const hex: string = clamped.toString(16).toUpperCase();
  return hex.length === 1 ? '0' + hex : hex;
}

/**
 * 计算助手气泡背景色:RGB 保持资源浅色/深色值,Alpha = bubbleOpacity。
 * 返回 #AARRGGBB 格式(与 ChatMessageBubble.computeAssistantBubbleColor 一致)。
 * - light: #FFFFFF, dark: #2A2A2A
 */
export function computeAssistantBubbleColor(opacity: number, isDarkMode: boolean): string {
  const rgb: string = isDarkMode ? '2A2A2A' : 'FFFFFF';
  return '#' + alphaToHex(opacity) + rgb;
}

/**
 * 计算用户气泡背景色:RGB 保持品牌蓝,Alpha = min(bubbleOpacity + 0.08, 0.95)。
 * 返回 #AARRGGBB 格式(与 ChatMessageBubble.computeUserBubbleColor 一致)。
 * - light: #5B7CFA, dark: #7B9BFF
 */
export function computeUserBubbleColor(opacity: number, isDarkMode: boolean): string {
  const rgb: string = isDarkMode ? '7B9BFF' : '5B7CFA';
  const alpha: number = Math.min(opacity + 0.08, 0.95);
  return '#' + alphaToHex(alpha) + rgb;
}
