import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode, display } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { AppServices } from '../services/AppServices';
import { WebDavSyncService } from '../services/sync/WebDavSyncService';
import { LogBuffer } from '../utils/LogBuffer';

const DOMAIN = 0x0000;

const SYSTEM_DARK_KEY: string = 'systemDark';

/** 系统分享数据 Action(与 module.json5 skills 声明一致) */
const SHARE_CARD_ACTION: string = 'ohos.want.action.sendData';
/** 待导入的分享文件 URI(AppStorage,由 Index 消费) */
const PENDING_SHARE_URI_KEY: string = 'pendingShareCardUri';
/** 分享到达序号(AppStorage,每次到达 +1,驱动 Index 的 @Watch) */
const PENDING_SHARE_SEQ_KEY: string = 'pendingShareCardSeq';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 诊断日志缓冲尽早初始化(加载上次落盘的历史日志,本次启动日志从头收集)
    LogBuffer.init(this.context);
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
    // 冷启动可能由"分享 PNG 角色卡"发起
    this.handleShareWant(want);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 应用已在运行时再次收到分享(热启动)
    hilog.info(DOMAIN, 'testTag', 'Ability onNewWant action=%{public}s', want.action ?? '');
    this.handleShareWant(want);
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

  /**
   * 处理系统分享带来的 PNG 角色卡:
   * 仅当 action 匹配时解析分享数据,把文件 URI 写入 AppStorage 交给 Index 消费;
   * 普通启动(action 不匹配)不做任何事。
   */
  private handleShareWant(want: Want): void {
    if (want.action !== SHARE_CARD_ACTION) {
      return;
    }
    systemShare.getSharedData(want).then((data: systemShare.SharedData): void => {
      const records: systemShare.SharedRecord[] = data.getRecords();
      if (records.length === 0) {
        hilog.warn(DOMAIN, 'testTag', 'Shared data has no record');
        return;
      }
      const uri: string = records[0].uri ?? '';
      if (uri.length === 0) {
        hilog.warn(DOMAIN, 'testTag', 'Shared record has no uri, utd=%{public}s', records[0].utd);
        return;
      }
      AppStorage.setOrCreate<string>(PENDING_SHARE_URI_KEY, uri);
      const seq: number = AppStorage.get<number>(PENDING_SHARE_SEQ_KEY) ?? 0;
      AppStorage.setOrCreate<number>(PENDING_SHARE_SEQ_KEY, seq + 1);
      hilog.info(DOMAIN, 'testTag', 'Pending share card uri=%{public}s', uri);
    }).catch((e: Object): void => {
      hilog.error(DOMAIN, 'testTag', 'getSharedData failed: %{public}s', String(e));
    });
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
