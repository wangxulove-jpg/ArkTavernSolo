/**
 * ThemeMode 主题模式模型(ARK-UI-THEME-1)
 *
 * 应用级主题 authority 的数据模型:
 * - selectedThemeMode:用户显式选择的主题模式(持久化到 AppPreferences,不写 RDB)
 * - EffectiveTheme:解析后的有效主题(FollowSystem 根据系统 colorMode 解析)
 *
 * 命名约定:字符串值为 AppStorage / AppPreferences 中使用的稳定标识。
 */

/** 用户可选择的主题模式(持久化值) */
export enum ThemeMode {
  /** 跟随系统浅色 / 深色外观 */
  FOLLOW_SYSTEM = 'follow_system',
  /** 固定浅色 */
  LIGHT = 'light',
  /** 固定深色 */
  DARK = 'dark',
  /** 酒馆棕(暖金与深木色的 ArkTavern 酒馆风格) */
  TAVERN = 'tavern'
}

/** 解析后的有效主题(驱动渲染) */
export enum EffectiveTheme {
  /** 浅色 */
  LIGHT = 'light',
  /** 深色 */
  DARK = 'dark',
  /** 酒馆棕 */
  TAVERN = 'tavern'
}

/** AppStorage 中主题相关 key(唯一权威状态) */
export class ThemeStorageKeys {
  /** 用户选择的主题模式(ThemeMode 字符串值) */
  static readonly SELECTED_THEME_MODE: string = 'selectedThemeMode';
  /** 解析后的有效主题(EffectiveTheme 字符串值) */
  static readonly EFFECTIVE_THEME: string = 'effectiveTheme';
}

/** AppPreferences 中主题持久化 key(非 RDB) */
export const THEME_MODE_PREFERENCE_KEY: string = 'app_theme_mode';

/**
 * 将 ThemeMode 解析为 EffectiveTheme。
 *
 * @param mode 用户选择的模式
 * @param systemDark 系统当前是否为深色
 * @returns 有效主题
 */
export function resolveEffectiveTheme(mode: ThemeMode, systemDark: boolean): EffectiveTheme {
  switch (mode) {
    case ThemeMode.LIGHT:
      return EffectiveTheme.LIGHT;
    case ThemeMode.DARK:
      return EffectiveTheme.DARK;
    case ThemeMode.TAVERN:
      return EffectiveTheme.TAVERN;
    case ThemeMode.FOLLOW_SYSTEM:
    default:
      return systemDark ? EffectiveTheme.DARK : EffectiveTheme.LIGHT;
  }
}

/**
 * 将字符串转换为 ThemeMode(容错,未知值回退 FollowSystem)。
 * @param value 字符串值
 * @returns ThemeMode
 */
export function parseThemeMode(value: string): ThemeMode {
  if (value === ThemeMode.LIGHT) {
    return ThemeMode.LIGHT;
  }
  if (value === ThemeMode.DARK) {
    return ThemeMode.DARK;
  }
  if (value === ThemeMode.TAVERN) {
    return ThemeMode.TAVERN;
  }
  return ThemeMode.FOLLOW_SYSTEM;
}
