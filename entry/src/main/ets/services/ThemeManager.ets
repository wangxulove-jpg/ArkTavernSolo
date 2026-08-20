/**
 * ThemeManager 全局主题权威(ARK-UI-THEME-1)
 *
 * 唯一 Theme Preference authority:
 * - 持久化 selectedThemeMode 到 AppPreferences(app_theme_mode key,非 RDB)
 * - 解析 effectiveTheme(FollowSystem 根据系统 colorMode 解析)
 * - 应用应用级 setColorMode(Light/Dark/FollowSystem 走资源限定符轨道)
 * - 发布 effectiveTheme 到 AppStorage,驱动全 App 响应式重绘
 *
 * 页面不保存独立 theme state,统一通过 @StorageProp('effectiveTheme') 读取。
 *
 * 依赖:
 * - AppPreferences(非 RDB 持久化,复用现有 authority)
 * - common.Context(仅用于 setColorMode)
 */

import { common } from '@kit.AbilityKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import {
  ThemeMode,
  EffectiveTheme,
  ThemeStorageKeys,
  THEME_MODE_PREFERENCE_KEY,
  resolveEffectiveTheme,
  parseThemeMode
} from '../models/ThemeMode';

/** 日志标签 */
const LOG_TAG: string = 'ThemeManager';

/** 默认主题模式:跟随设备 */
const DEFAULT_THEME_MODE: ThemeMode = ThemeMode.FOLLOW_SYSTEM;

/**
 * 全局主题权威单例。
 * 通过 ThemeManager.getInstance() 访问。
 */
export class ThemeManager {
  private static instance: ThemeManager | null = null;
  private readonly preferences: AppPreferences;
  /** 当前用户选择的主题模式(内存镜像,初始化后非空) */
  private selectedMode: ThemeMode = DEFAULT_THEME_MODE;
  /** 当前有效主题(内存镜像) */
  private effectiveTheme: EffectiveTheme = EffectiveTheme.DARK;
  /** 系统当前是否深色(默认深色,启动时按 config 刷新) */
  private systemDark: boolean = true;
  /** 应用 Context(initialize 时保存,用于 setColorMode) */
  private appContext: common.Context | null = null;

  private constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 获取单例。
   * @param preferences AppPreferences 实例
   * @returns ThemeManager
   */
  static getInstance(preferences?: AppPreferences): ThemeManager {
    if (ThemeManager.instance === null) {
      if (preferences === undefined) {
        throw new Error('ThemeManager requires AppPreferences for first init');
      }
      ThemeManager.instance = new ThemeManager(preferences);
    }
    return ThemeManager.instance;
  }

  /**
   * 初始化:从 AppPreferences 恢复用户选择,读取系统 colorMode,并发布 AppStorage 状态。
   * 在 AppServices.initialize 中 appPreferences 就绪后调用。
   *
   * @param context 应用 Context(保存用于 setColorMode)
   */
  async initialize(context: common.Context): Promise<void> {
    this.appContext = context;
    // 读取系统深浅色状态(由 EntryAbility.onCreate 写入 AppStorage)
    const systemDark: boolean | undefined = AppStorage.get<boolean>('systemDark');
    if (systemDark !== undefined) {
      this.systemDark = systemDark;
    }
    try {
      const stored: string = await this.preferences.getString(THEME_MODE_PREFERENCE_KEY, DEFAULT_THEME_MODE);
      this.selectedMode = parseThemeMode(stored);
    } catch (e) {
      Logger.warn(LOG_TAG, 'load theme mode failed, use default: ' + (e as Error).message);
      this.selectedMode = DEFAULT_THEME_MODE;
    }
    this.recomputeEffective();
    this.publishToAppStorage();
    this.applyColorMode();
    Logger.info(LOG_TAG,
      `initialize selected=${this.selectedMode} effective=${this.effectiveTheme} systemDark=${this.systemDark}`);
  }

  /**
   * 设置系统深色状态(由 EntryAbility 在 onConfigurationUpdate 中调用)。
   * 系统主题变化时:
   * - selected = FollowSystem → 有效主题跟随变化
   * - selected = Light/Dark/Tavern → 有效主题保持不变
   *
   * @param systemDark 系统当前是否深色
   */
  setSystemDark(systemDark: boolean): void {
    if (this.systemDark === systemDark) {
      return;
    }
    this.systemDark = systemDark;
    if (this.selectedMode === ThemeMode.FOLLOW_SYSTEM) {
      this.recomputeEffective();
      this.publishToAppStorage();
      this.applyColorMode();
      Logger.info(LOG_TAG,
        `system color mode changed -> effective=${this.effectiveTheme} systemDark=${systemDark}`);
    }
  }

  /**
   * 获取当前用户选择的主题模式。
   * @returns ThemeMode
   */
  getSelectedMode(): ThemeMode {
    return this.selectedMode;
  }

  /**
   * 获取当前有效主题。
   * @returns EffectiveTheme
   */
  getEffectiveTheme(): EffectiveTheme {
    return this.effectiveTheme;
  }

  /**
   * 获取系统当前是否深色。
   * @returns 系统深色状态
   */
  isSystemDark(): boolean {
    return this.systemDark;
  }

  /**
   * 设置主题模式并持久化。
   * 立即:
   * - 更新内存状态
   * - 持久化到 AppPreferences
   * - 重新解析 effectiveTheme
   * - 发布 AppStorage(全 App 响应式重绘)
   * - 应用 setColorMode
   *
   * @param mode 用户选择的主题模式
   */
  async setThemeMode(mode: ThemeMode): Promise<void> {
    if (this.selectedMode === mode) {
      return;
    }
    this.selectedMode = mode;
    try {
      await this.preferences.putString(THEME_MODE_PREFERENCE_KEY, mode);
    } catch (e) {
      Logger.error(LOG_TAG, 'persist theme mode failed: ' + (e as Error).message);
    }
    this.recomputeEffective();
    this.publishToAppStorage();
    this.applyColorMode();
    Logger.info(LOG_TAG, `setThemeMode mode=${mode} effective=${this.effectiveTheme}`);
  }

  /**
   * 重新计算 effectiveTheme。
   */
  private recomputeEffective(): void {
    this.effectiveTheme = resolveEffectiveTheme(this.selectedMode, this.systemDark);
  }

  /**
   * 发布 AppStorage 状态,触发全 App 响应式重绘。
   */
  private publishToAppStorage(): void {
    AppStorage.setOrCreate<ThemeMode>(ThemeStorageKeys.SELECTED_THEME_MODE, this.selectedMode);
    AppStorage.setOrCreate<EffectiveTheme>(ThemeStorageKeys.EFFECTIVE_THEME, this.effectiveTheme);
  }

  /**
   * 应用应用级 color mode。
   * - FollowSystem → COLOR_MODE_NOT_SET(跟随系统)
   * - Light → COLOR_MODE_LIGHT
   * - Dark → COLOR_MODE_DARK
   * - Tavern → COLOR_MODE_DARK(酒馆棕为深色基底,颜色由 ThemePalette 覆盖)
   */
  private applyColorMode(): void {
    if (this.appContext === null) {
      return;
    }
    try {
      let mode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (this.effectiveTheme === EffectiveTheme.LIGHT) {
        mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      } else if (this.effectiveTheme === EffectiveTheme.DARK || this.effectiveTheme === EffectiveTheme.TAVERN) {
        mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
      this.appContext.getApplicationContext().setColorMode(mode);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setColorMode failed: ' + (e as Error).message);
    }
  }
}
