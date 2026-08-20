/**
 * ModelSettingsPage 模型设置主页
 *
 * UI-2 重构后只负责配置管理:
 * - 当前配置摘要卡
 * - 配置列表
 * - 新建配置入口
 * - 空状态、加载状态、错误状态
 *
 * 编辑表单拆分到 ModelConfigEditPage。
 * 页面通过 AppStorage 与编辑页共享同一个 ModelSettingsViewModel 实例。
 */

import { ModelSettingsViewModel } from '../viewmodels/ModelSettingsViewModel';
import { AppServices } from '../services/AppServices';
import { ProviderConfig } from '../models/ProviderConfig';
import { ProviderType } from '../models/ProviderType';
import { router } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';
import { Logger } from '../utils/Logger';

const APP_STORAGE_VM_KEY: string = 'ModelSettingsViewModel';
const LOG_TAG: string = 'ModelSettingsPage';

@Entry
@Component
struct ModelSettingsPage {
  @State viewModel: ModelSettingsViewModel | null = null;
  @State initError: string = '';
  /** 本地配置列表(从 viewModel 同步,作为 ForEach 数据源以可靠触发重渲染) */
  @State configs: ProviderConfig[] = [];
  /** 强制 ForEach 重建所有项(配合 keyGenerator 使用) */
  @State refreshKey: number = 0;
  /** 配置列表版本号(由 ModelConfigEditPage 保存/删除后递增,触发 onListVersionChange 刷新) */
  @StorageProp('modelConfigListVersion') @Watch('onListVersionChange') modelConfigListVersion: number = 0;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const ms = AppServices.getInstance().modelService;
      this.viewModel = new ModelSettingsViewModel(ms);
      await this.viewModel.initialize();
      AppStorage.setOrCreate(APP_STORAGE_VM_KEY, this.viewModel);
      this.syncConfigs();
    } catch (e) {
      this.initError = '初始化失败,请重试';
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  /** modelConfigListVersion 变化时刷新列表(从编辑页保存/删除后返回自动刷新) */
  onListVersionChange(): void {
    if (this.viewModel === null) {
      return;
    }
    Logger.info(LOG_TAG, 'onListVersionChange fired, version=' + this.modelConfigListVersion.toString());
    this.viewModel!.refreshConfigList()
      .then(() => {
        this.syncConfigs();
        Logger.info(LOG_TAG, 'onListVersionChange reload done, count=' + this.configs.length.toString()
          + ' refreshKey=' + this.refreshKey.toString());
      })
      .catch((): void => {});
  }

  /** 同步 viewModel.configs 到本地 @State configs(触发 ForEach 重渲染) */
  private syncConfigs(): void {
    if (this.viewModel !== null) {
      this.configs = this.viewModel!.configs;
      this.refreshKey++;
    }
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏:返回 + 标题
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
            .padding(8)
            .onClick(() => {
              router.back();
            })

          Text($r('app.string.nav_model_settings_title'))
            .fontSize($r('app.float.nav_title_font_size'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8, right: 40 })
        }
        .width('100%')
        .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        if (this.viewModel === null) {
          this.loadingView()
        } else {
          this.mainView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }

  @Builder
  loadingView() {
    Column() {
      if (this.initError.length > 0) {
        Text(this.initError)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      } else {
        LoadingProgress()
          .width(36)
          .height(36)
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
  }

  @Builder
  mainView() {
    Scroll() {
      Column({ space: 16 }) {
        this.statusBanner()

        if (this.configs.length === 0) {
          this.emptyState()
        } else {
          this.currentConfigCard()
          this.configListSection()
        }

        // 新建配置按钮
        Button($r('app.string.model_settings_add_config'))
          .width('100%')
          .height(48)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .margin({ top: 8, bottom: 32 })
          .onClick(() => {
            this.viewModel!.startCreate();
            this.viewModel!.setActiveEditTab(0);
            router.pushUrl({ url: 'pages/ModelConfigEditPage' });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .scrollBar(BarState.Auto)
    .layoutWeight(1)
    .align(Alignment.Top)
  }

  @Builder
  currentConfigCard() {
    if (this.currentConfig !== undefined) {
      Column({ space: 8 }) {
        Row() {
          Text($r('app.string.model_settings_current_config_title'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Blank()
          if (this.currentConfig.enabled) {
            Text($r('app.string.model_settings_config_enabled'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.model_settings_success'))
          } else {
            Text($r('app.string.model_settings_config_disabled'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          }
        }
        .width('100%')

        Text(this.currentConfig.name)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          Text(this.providerDisplayName(this.currentConfig.type))
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Text(' · ')
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          Text(this.currentConfig.modelName)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')

        Row() {
          SymbolGlyph($r('sys.symbol.key'))
            .fontSize(16)
            .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
          Text(this.viewModel!.currentConfigApiKeyDisplay.length > 0
            ? this.viewModel!.currentConfigApiKeyDisplay
            : $r('app.string.model_settings_api_key_status_not_configured'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ left: 4 })
            .copyOption(CopyOptions.LocalDevice)
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  configListSection() {
    Column({ space: 12 }) {
      Text($r('app.string.model_settings_config_list'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')

      List({ space: 8 }) {
        ForEach(this.configs, (config: ProviderConfig) => {
          ListItem() {
            this.configListItem(config)
          }
        }, (config: ProviderConfig) => config.id + '_' + this.refreshKey.toString())
      }
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  configListItem(config: ProviderConfig) {
    Row() {
      Column({ space: 4 }) {
        Row() {
          Text(config.name)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.viewModel!.currentConfigId === config.id) {
            Text($r('app.string.model_settings_current_badge'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .margin({ left: 8 })
          }
        }
        .width('100%')

        Row() {
          Text(this.providerDisplayName(config.type))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Text(' · ')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          Text(config.modelName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
        .margin({ left: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .onClick(() => {
      this.viewModel!.selectConfig(config.id);
      this.viewModel!.setActiveEditTab(0);
      router.pushUrl({ url: 'pages/ModelConfigEditPage' });
    })
  }

  @Builder
  emptyState() {
    Column({ space: 8 }) {
      Text($r('app.string.model_settings_empty_title'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      Text($r('app.string.model_settings_empty_desc'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ top: 48, bottom: 48 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  statusBanner() {
    if (this.viewModel!.errorMessage.length > 0) {
      Text(this.viewModel!.errorMessage)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_danger'))
        .padding(12)
        .width('100%')
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
    }
    if (this.viewModel!.statusMessage.length > 0) {
      Text(this.viewModel!.statusMessage)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.model_settings_success'))
        .padding(12)
        .width('100%')
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
    }
  }

  private get currentConfig(): ProviderConfig | undefined {
    if (this.viewModel === null || this.viewModel!.currentConfigId === null) {
      return undefined;
    }
    return this.findConfig(this.viewModel!.currentConfigId);
  }

  private findConfig(id: string): ProviderConfig | undefined {
    const configs: ProviderConfig[] = this.configs;
    for (let i = 0; i < configs.length; i++) {
      if (configs[i].id === id) {
        return configs[i];
      }
    }
    return undefined;
  }

  private providerDisplayName(type: ProviderType): string {
    switch (type) {
      case ProviderType.DeepSeek:
        return 'DeepSeek';
      case ProviderType.MiMo:
        return 'MiMo';
      case ProviderType.OpenAICompatible:
        return 'OpenAI Compatible';
      case ProviderType.OpenAI:
        return 'OpenAI';
      case ProviderType.OpenRouter:
        return 'OpenRouter';
      case ProviderType.Claude:
        return 'Claude';
      case ProviderType.Gemini:
        return 'Gemini';
      case ProviderType.OpenCodeGo:
        return 'OpenCode Go';
      case ProviderType.SiliconFlow:
        return 'SiliconFlow';
      default:
        return 'Unknown';
    }
  }
}
