/**
 * GROUP-CHAT-TARGET-1: @角色回复模式与旁白开关按群聊持久化。
 *
 * 存储位置:Preferences 'ArkTavernSettings'
 * Key pattern: group_reply_mode_{chatId} / group_narration_{chatId}
 */

import { preferences } from '@kit.ArkData';

const STORE_NAME: string = 'ArkTavernSoloSettings';
const MODE_KEY_PREFIX: string = 'group_reply_mode_';
const NARRATION_KEY_PREFIX: string = 'group_narration_';
const NARRATION_TOKENS_KEY_PREFIX: string = 'group_narration_tokens_';
const NARRATION_TOKENS_DEFAULT: number = 256;

export type GroupReplyTargetModeSetting = 'one_shot' | 'persistent';

/** 加载指定群聊的 @角色回复模式,异常时返回默认 'one_shot' */
export async function loadGroupReplyTargetMode(chatId: string): Promise<GroupReplyTargetModeSetting> {
  try {
    const ctx: Context = getContext();
    const prefs: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    const raw: string = (prefs.getSync(MODE_KEY_PREFIX + chatId, 'one_shot')) as string;
    if (raw === 'persistent') {
      return 'persistent';
    }
    return 'one_shot';
  } catch (_e) {
    return 'one_shot';
  }
}

/** 持久化指定群聊的 @角色回复模式 */
export function persistGroupReplyTargetMode(chatId: string, mode: GroupReplyTargetModeSetting): void {
  try {
    const ctx: Context = getContext();
    preferences.getPreferences(ctx, STORE_NAME).then((prefs: preferences.Preferences): void => {
      prefs.put(MODE_KEY_PREFIX + chatId, mode);
      prefs.flush();
    }).catch((): void => {
      // silently ignore
    });
  } catch (_e) {
    // silently ignore
  }
}

// ===== GROUP-NARRATION-1A: 旁白开关按群聊持久化 =====

const NARRATION_DEFAULT: boolean = false;

/** 加载指定群聊的旁白开关,异常时返回默认关闭 */
export async function loadGroupNarrationEnabled(chatId: string): Promise<boolean> {
  try {
    const ctx: Context = getContext();
    const prefs: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    const raw: number = (prefs.getSync(NARRATION_KEY_PREFIX + chatId, 0)) as number;
    return raw !== 0;
  } catch (_e) {
    return NARRATION_DEFAULT;
  }
}

/** 持久化指定群聊的旁白开关 */
export function persistGroupNarrationEnabled(chatId: string, enabled: boolean): void {
  try {
    const ctx: Context = getContext();
    preferences.getPreferences(ctx, STORE_NAME).then((prefs: preferences.Preferences): void => {
      prefs.put(NARRATION_KEY_PREFIX + chatId, enabled ? 1 : 0);
      prefs.flush();
    }).catch((): void => {
      // silently ignore
    });
  } catch (_e) {
    // silently ignore
  }
}

/** 加载指定群聊的旁白 token 数,异常时返回默认 256 */
export async function loadGroupNarrationMaxTokens(chatId: string): Promise<number> {
  try {
    const ctx: Context = getContext();
    const prefs: preferences.Preferences = await preferences.getPreferences(ctx, STORE_NAME);
    const raw: number = (prefs.getSync(NARRATION_TOKENS_KEY_PREFIX + chatId, NARRATION_TOKENS_DEFAULT)) as number;
    if (typeof raw === 'number' && raw >= 16) {
      return raw;
    }
    return NARRATION_TOKENS_DEFAULT;
  } catch (_e) {
    return NARRATION_TOKENS_DEFAULT;
  }
}

/** 持久化指定群聊的旁白 token 数 */
export function persistGroupNarrationMaxTokens(chatId: string, tokens: number): void {
  try {
    const ctx: Context = getContext();
    preferences.getPreferences(ctx, STORE_NAME).then((prefs: preferences.Preferences): void => {
      prefs.put(NARRATION_TOKENS_KEY_PREFIX + chatId, tokens);
      prefs.flush();
    }).catch((): void => {
      // silently ignore
    });
  } catch (_e) {
    // silently ignore
  }
}
