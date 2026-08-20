import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode, display } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';

const DOMAIN = 0x0000;

/** AppStorage 中系统深浅色状态 key(由 EntryAbility 写入,boolean: true=深色) */
const SYSTEM_DARK_KEY: string = 'systemDark';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 读取系统当前深浅色状态,写入 AppStorage 供 ThemeManager 初始化时解析 FollowSystem。
    // 不再在此强制 setColorMode(NOT_SET):主题选择由 ThemeManager 统一 authority 管理。
    const systemColorMode: ConfigurationConstant.ColorMode =
      this.context.config?.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const systemDark: boolean = systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate<boolean>(SYSTEM_DARK_KEY, systemDark);
    hilog.info(DOMAIN, 'testTag', 'Ability onCreate systemDark=%{public}s', String(systemDark));
    // 启动应用服务初始化(异步,不阻塞 onCreate)
    AppServices.initialize(this.context).catch((e: Object): void => {
      hilog.error(DOMAIN, 'testTag', 'AppServices initialize failed: %{public}s', (e as Error).message);
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    // 系统深浅色变化时:更新 AppStorage 状态,并通知 ThemeManager。
    // FollowSystem 模式下有效主题跟随;显式主题(浅/深/酒馆棕)不受系统变化覆盖。
    const newColorMode: ConfigurationConstant.ColorMode =
      newConfig.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const newSystemDark: boolean = newColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate<boolean>(SYSTEM_DARK_KEY, newSystemDark);
    hilog.info(DOMAIN, 'testTag', 'onConfigurationUpdate systemDark=%{public}s', String(newSystemDark));
    try {
      if (AppServices.isStarted()) {
        AppServices.getThemeManager().setSystemDark(newSystemDark);
      }
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'ThemeManager setSystemDark failed: %{public}s', (e as Error).message);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 获取系统安全区(状态栏 + 导航栏)高度,存入 AppStorage 供所有页面避让使用。
    // 注意:AvoidArea 返回的是 px,而 ArkUI padding 用 vp,需通过屏幕密度换算。
    try {
      const mainWin: window.Window = windowStage.getMainWindowSync();
      const avoidArea: window.AvoidArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      // 屏幕密度(pixels per vp),通常 3.0 左右
      const densityPixels: number = display.getDefaultDisplaySync().densityPixels;
      const density: number = densityPixels > 0 ? densityPixels : 3.0;
      // 换算为 vp(向下取整避免 padding 不足)
      const statusBarHeightVp: number = Math.floor(avoidArea.topRect.height / density);
      const navigationBarHeightVp: number = Math.floor(avoidArea.bottomRect.height / density);
      AppStorage.setOrCreate<number>('statusBarHeight', statusBarHeightVp);
      AppStorage.setOrCreate<number>('navigationBarHeight', navigationBarHeightVp);
      hilog.info(DOMAIN, 'testTag',
        'SafeArea px statusBar=%{public}d navBar=%{public}d, density*1000=%{public}d, vp statusBar=%{public}d navBar=%{public}d',
        avoidArea.topRect.height, avoidArea.bottomRect.height,
        Math.round(density * 1000), statusBarHeightVp, navigationBarHeightVp);
      // 开启窗口沉浸式布局:让窗口内容延伸到状态栏/导航栏下方,
      // 使页面级 expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP/BOTTOM]) 生效。
      // 不开启时窗口内容区从状态栏下方开始,组件边界不与安全区重合,expandSafeArea 失效;
      // 同时页面 paddingTop 仍会再次避让 statusBarHeight,产生双计数大块顶部空白。
      // 异步触发,不阻塞 loadContent。窗口透明背景 + 状态栏透明在 loadContent 回调中设置
      // (loadContent 完成后窗口状态稳定,setWindowBackgroundColor 不会报 "window state abnormal")。
      mainWin.setWindowLayoutFullScreen(true).catch((e: Object): void => {
        hilog.error(DOMAIN, 'testTag', 'setWindowLayoutFullScreen failed: %{public}s', (e as Error).message);
      });
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'getWindowAvoidArea failed: %{public}s', (e as Error).message);
      // 兜底默认值(状态栏约 32vp,导航栏约 0vp,鸿蒙 NEXT 手势条不占空间)
      AppStorage.setOrCreate<number>('statusBarHeight', 32);
      AppStorage.setOrCreate<number>('navigationBarHeight', 0);
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');

      // 键盘避让模式设为 OFFSET:上抬模式,配合组件级 expandSafeArea([SafeAreaType.KEYBOARD])
      // 让背景/顶栏/Avatar 等固定层不上抬,只有未加 expandSafeArea 的输入栏被上抬到键盘上方。
      // (RESIZE 会压缩百分比组件导致画面缩小;OFFSET 下 expandSafeArea(KEYBOARD) 才生效)
      try {
        windowStage.getMainWindowSync().getUIContext()
          .setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'setKeyboardAvoidMode failed: %{public}s', (e as Error).message);
      }

      // 沉浸式:仅设置状态栏背景透明,让状态栏图标浮在应用背景之上。
      // 系统栏图标颜色跟随有效主题(浅色主题用深色图标,深色/酒馆棕用浅色图标)。
      const win: window.Window = windowStage.getMainWindowSync();
      const isDarkTheme: boolean = this.isDarkEffectiveTheme();
      const sysBarProps: window.SystemBarProperties = {
        statusBarColor: '#00000000',                            // 状态栏背景透明
        statusBarContentColor: isDarkTheme ? '#FFFFFF' : '#000000'   // 状态栏图标/文字颜色
      };
      win.setWindowSystemBarProperties(sysBarProps)
        .then((): void => {
          hilog.info(DOMAIN, 'testTag',
            'setWindowSystemBarProperties succeeded: isDark=%{public}s, contentColor=%{public}s',
            String(isDarkTheme), sysBarProps.statusBarContentColor!
          );
        })
        .catch((e: Object): void => {
          hilog.error(DOMAIN, 'testTag',
            'setWindowSystemBarProperties failed: %{public}s', (e as Error).message);
        });
    });
  }

  /**
   * 判断当前有效主题是否为深色系(决定系统栏图标明暗)。
   * 优先读 AppStorage 的 effectiveTheme;未初始化时回退系统深浅色状态。
   */
  private isDarkEffectiveTheme(): boolean {
    const effective: string | undefined = AppStorage.get<string>('effectiveTheme');
    if (effective === 'light') {
      return false;
    }
    if (effective === 'tavern' || effective === 'dark') {
      return true;
    }
    const systemDark: boolean | undefined = AppStorage.get<boolean>(SYSTEM_DARK_KEY);
    return systemDark ?? true;
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}