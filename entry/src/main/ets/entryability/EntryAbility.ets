import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode, display } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { WebDavSyncService } from '../services/sync/WebDavSyncService';

const DOMAIN = 0x0000;

const SYSTEM_DARK_KEY: string = 'systemDark';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const systemColorMode: ConfigurationConstant.ColorMode =
      this.context.config?.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const systemDark: boolean = systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate<boolean>(SYSTEM_DARK_KEY, systemDark);
    hilog.info(DOMAIN, 'testTag', 'Ability onCreate systemDark=%{public}s', String(systemDark));
    AppServices.initialize(this.context).then(() => {
      this.triggerAutoSync();
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, 'testTag', 'AppServices initialize failed: %{public}s', (e as Error).message);
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
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
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    try {
      const mainWin: window.Window = windowStage.getMainWindowSync();
      const avoidArea: window.AvoidArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const densityPixels: number = display.getDefaultDisplaySync().densityPixels;
      const density: number = densityPixels > 0 ? densityPixels : 3.0;
      const statusBarHeightVp: number = Math.floor(avoidArea.topRect.height / density);
      const navigationBarHeightVp: number = Math.floor(avoidArea.bottomRect.height / density);
      AppStorage.setOrCreate<number>('statusBarHeight', statusBarHeightVp);
      AppStorage.setOrCreate<number>('navigationBarHeight', navigationBarHeightVp);
      hilog.info(DOMAIN, 'testTag',
        'SafeArea px statusBar=%{public}d navBar=%{public}d, density*1000=%{public}d, vp statusBar=%{public}d navBar=%{public}d',
        avoidArea.topRect.height, avoidArea.bottomRect.height,
        Math.round(density * 1000), statusBarHeightVp, navigationBarHeightVp);
      mainWin.setWindowLayoutFullScreen(true).catch((e: Object): void => {
        hilog.error(DOMAIN, 'testTag', 'setWindowLayoutFullScreen failed: %{public}s', (e as Error).message);
      });
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'getWindowAvoidArea failed: %{public}s', (e as Error).message);
      AppStorage.setOrCreate<number>('statusBarHeight', 32);
      AppStorage.setOrCreate<number>('navigationBarHeight', 0);
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');

      try {
        windowStage.getMainWindowSync().getUIContext()
          .setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'setKeyboardAvoidMode failed: %{public}s', (e as Error).message);
      }

      const win: window.Window = windowStage.getMainWindowSync();
      const isDarkTheme: boolean = this.isDarkEffectiveTheme();
      const sysBarProps: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        statusBarContentColor: isDarkTheme ? '#FFFFFF' : '#000000'
      };
      win.setWindowSystemBarProperties(sysBarProps)
        .then((): void => {
          hilog.info(DOMAIN, 'testTag',
            'setWindowSystemBarProperties succeeded: isDark=%{public}s, contentColor=%{public}s',
            String(isDarkTheme), sysBarProps.statusBarContentColor!);
        })
        .catch((e: Object): void => {
          hilog.error(DOMAIN, 'testTag',
            'setWindowSystemBarProperties failed: %{public}s', (e as Error).message);
        });
    });
  }

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

  private triggerAutoSync(): void {
    try {
      const syncService: WebDavSyncService = AppServices.getWebDavSyncService();
      syncService.autoSync().then((result): void => {
        if (result !== null) {
          hilog.info(DOMAIN, 'testTag', 'Auto-sync result: %{public}s', result.message);
        }
      }).catch((e: Object): void => {
        hilog.warn(DOMAIN, 'testTag', 'Auto-sync failed: %{public}s', (e as Error).message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, 'testTag', 'Auto-sync not available: %{public}s', (e as Error).message);
    }
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
