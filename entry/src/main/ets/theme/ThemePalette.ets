/**
 * ThemePalette 全局主题设计令牌(ARK-UI-THEME-1)
 *
 * 统一管理全 App 颜色语义,四种有效主题(Light / Dark / Tavern / FollowSystem 解析后落到 Light 或 Dark)。
 * 与 resources/base/element/color.json 和 resources/dark/element/color.json 中的 app_* / page_* 语义色保持一致;
 * Tavern 为酒馆棕新色板。
 *
 * 用途:
 * - 页面 / 组件通过 ThemeManager 获取当前 EffectiveTheme 后,调用 ThemePalette.forTheme() 取色。
 * - 与资源限定符轨道互补:Light/Dark 下资源目录自动生效(3464 处 $r() 引用),Tavern 下
 *   setColorMode(DARK) 提供深色基底,再由本 Palette 覆盖关键语义色。
 * - 世界模式专属的 Canvas / 地图颜色保留在 WorldDesignTokens(World UI 层)。
 *
 * 不依赖 Repository / Service / 数据库。纯静态常量。
 */

/** 主题色板(与 UI token 一一对应) */
export interface ThemeColors {
  /** 页面背景 */
  readonly pageBg: string;
  /** 一级 Surface(卡片) */
  readonly surface1: string;
  /** 二级 / Elevated Surface */
  readonly surface2: string;
  /** Pressed / Selected Surface */
  readonly selectedSurface: string;
  /** 分隔线 */
  readonly divider: string;
  /** 普通 Border */
  readonly border: string;
  /** 主文字 */
  readonly textPrimary: string;
  /** 次文字 */
  readonly textSecondary: string;
  /** 弱文字 */
  readonly textTertiary: string;
  /** 主 Accent */
  readonly accent: string;
  /** Accent 上文字 */
  readonly onAccent: string;
  /** 图标主色 */
  readonly iconPrimary: string;
  /** 图标弱色 */
  readonly iconSecondary: string;
  /** 输入框背景 */
  readonly inputBg: string;
  /** Placeholder */
  readonly placeholder: string;
  /** Bottom Navigation 背景 */
  readonly navBg: string;
  /** Dialog / Sheet 背景 */
  readonly dialogBg: string;
  /** Scrim / Overlay */
  readonly scrim: string;
  /** 语义色 */
  readonly success: string;
  readonly warning: string;
  readonly error: string;
  readonly info: string;
}

/** 浅色(与 base/element/color.json 对齐) */
const LIGHT_COLORS: ThemeColors = {
  pageBg: '#F5F6F8',
  surface1: '#FFFFFF',
  surface2: '#F0F1F4',
  selectedSurface: '#E8EEFF',
  divider: '#E5E5E5',
  border: '#E5E5E5',
  textPrimary: '#1A1A1A',
  textSecondary: '#595959',
  textTertiary: '#8C8C8C',
  accent: '#5B7CFA',
  onAccent: '#FFFFFF',
  iconPrimary: '#1A1A1A',
  iconSecondary: '#8C8C8C',
  inputBg: '#F0F1F4',
  placeholder: '#8C8C8C',
  navBg: '#FFFFFF',
  dialogBg: '#FFFFFF',
  scrim: '#80000000',
  success: '#2E7D32',
  warning: '#E67E22',
  error: '#D32F2F',
  info: '#1976D2'
};

/** 深色(与 dark/element/color.json 对齐) */
const DARK_COLORS: ThemeColors = {
  pageBg: '#121212',
  surface1: '#1E1E1E',
  surface2: '#2A2A2A',
  selectedSurface: '#2A3552',
  divider: '#333333',
  border: '#333333',
  textPrimary: '#F0F0F0',
  textSecondary: '#B0B0B0',
  textTertiary: '#808080',
  accent: '#7B9BFF',
  onAccent: '#FFFFFF',
  iconPrimary: '#F0F0F0',
  iconSecondary: '#808080',
  inputBg: '#2A2A2A',
  placeholder: '#808080',
  navBg: '#1E1E1E',
  dialogBg: '#2A2A2A',
  scrim: '#B3000000',
  success: '#81C784',
  warning: '#FFB74D',
  error: '#EF5350',
  info: '#82B1FF'
};

/** 酒馆棕(深色奇幻酒馆质感,参考用户世界模式 UI 概念视觉语言) */
const TAVERN_COLORS: ThemeColors = {
  pageBg: '#1B130E',
  surface1: '#241A13',
  surface2: '#302219',
  selectedSurface: '#3D3220',
  divider: '#4D3724',
  border: '#4D3724',
  textPrimary: '#F7EBDD',
  textSecondary: '#C0AF99',
  textTertiary: '#968574',
  accent: '#D4A23B',
  onAccent: '#1A1510',
  iconPrimary: '#F7EBDD',
  iconSecondary: '#968574',
  inputBg: '#302219',
  placeholder: '#827467',
  navBg: '#241A13',
  dialogBg: '#2E2216',
  scrim: '#B3000000',
  success: '#6B9E47',
  warning: '#D49B43',
  error: '#C45A4A',
  info: '#5B8AB5'
};

/**
 * 全局主题色板工具。
 * 提供当前有效主题对应的色板。
 */
export class ThemePalette {
  /** 浅色色板 */
  static readonly LIGHT: ThemeColors = LIGHT_COLORS;
  /** 深色色板 */
  static readonly DARK: ThemeColors = DARK_COLORS;
  /** 酒馆棕色板 */
  static readonly TAVERN: ThemeColors = TAVERN_COLORS;

  /**
   * 根据有效主题字符串取色板。
   * 未知值回退深色(当前应用默认深色视觉)。
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns 对应色板
   */
  static forTheme(effectiveTheme: string): ThemeColors {
    if (effectiveTheme === 'light') {
      return LIGHT_COLORS;
    }
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS;
    }
    return DARK_COLORS;
  }

  /**
   * 页面/组件背景色(ResourceColor)。
   * - Tavern → 酒馆棕页面背景
   * - 其余 → 资源限定符 app_bg(自动跟随浅/深)
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static pageBgColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.pageBg;
    }
    return $r('app.color.app_bg');
  }

  /**
   * 一级 Surface 颜色(ResourceColor)。
   * - Tavern → 酒馆棕一级表面
   * - 其余 → 资源限定符 app_surface_1
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static surface1Color(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.surface1;
    }
    return $r('app.color.app_surface_1');
  }

  /**
   * 二级 Surface 颜色(ResourceColor)。
   * - Tavern → 酒馆棕二级表面
   * - 其余 → 资源限定符 app_surface_2
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static surface2Color(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.surface2;
    }
    return $r('app.color.app_surface_2');
  }

  /**
   * 页面背景颜色(ResourceColor,与 page_background 语义一致)。
   * - Tavern → 酒馆棕页面背景
   * - 其余 → 资源限定符 page_background
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static pageBackgroundColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.pageBg;
    }
    return $r('app.color.page_background');
  }

  /**
   * 分隔线/边框颜色(ResourceColor)。
   * - Tavern → 酒馆棕分隔线
   * - 其余 → 资源限定符 app_divider
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static dividerColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.divider;
    }
    return $r('app.color.app_divider');
  }

  /**
   * 主文字颜色(ResourceColor)。
   * - Tavern → 酒馆棕主文字
   * - 其余 → 资源限定符 app_text_primary
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static textPrimaryColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.textPrimary;
    }
    return $r('app.color.app_text_primary');
  }

  /**
   * 次文字颜色(ResourceColor)。
   * - Tavern → 酒馆棕次文字
   * - 其余 → 资源限定符 app_text_secondary
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static textSecondaryColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.textSecondary;
    }
    return $r('app.color.app_text_secondary');
  }

  /**
   * 弱文字颜色(ResourceColor)。
   * - Tavern → 酒馆棕弱文字
   * - 其余 → 资源限定符 app_text_tertiary
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static textTertiaryColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.textTertiary;
    }
    return $r('app.color.app_text_tertiary');
  }

  /**
   * 主 Accent 颜色(ResourceColor)。
   * - Tavern → 暖金
   * - 其余 → 资源限定符 app_accent
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static accentColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.accent;
    }
    return $r('app.color.app_accent');
  }

  /**
   * World UI shell 卡片表面色(ResourceColor)。
   * - Tavern → 酒馆棕一级表面
   * - 其余 → 资源限定符 app_surface_1
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static worldSurfaceColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.surface1;
    }
    return $r('app.color.app_surface_1');
  }

  /**
   * World UI shell 描边/边框色(ResourceColor)。
   * - Tavern → 酒馆棕描边
   * - 其余 → 资源限定符 app_divider
   *
   * @param effectiveTheme EffectiveTheme 字符串值
   * @returns ResourceColor
   */
  static worldBorderColor(effectiveTheme: string): ResourceColor {
    if (effectiveTheme === 'tavern') {
      return TAVERN_COLORS.border;
    }
    return $r('app.color.app_divider');
  }
}
