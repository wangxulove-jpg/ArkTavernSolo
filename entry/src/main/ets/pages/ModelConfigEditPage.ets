/**
 * ModelConfigEditPage 模型配置编辑页
 *
 * UI-2 新增页面,负责新建/编辑模型配置的完整表单。
 * 页面只通过 ModelSettingsViewModel 访问业务,不直接调用 Store/网络。
 *
 * 结构:
 * - 顶部导航栏:返回、标题(新建/编辑)、保存按钮
 * - 一级 Tab 切换:连接 / 参数
 * - 连接区域:名称、服务商(Sheet)、API Key、模型(Sheet/输入)、Base URL、测试连接
 * - 参数区域:Temperature、Top P、Max Tokens、流式请求、启用
 * - 底部危险操作区:删除(仅编辑)
 *
 * 安全:
 * - API Key 不回显,编辑时只显示"已配置"
 * - 不在页面状态中长期保留历史 Key
 * - 不显示完整 Base URL
 */

import { ModelSettingsViewModel } from '../viewmodels/ModelSettingsViewModel';
import { ProviderType } from '../models/ProviderType';
import { ModelOption } from '../models/ProviderPreset';
import { getModelCapability, ModelCapability } from '../models/ModelCapabilities';
import { router } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';

interface ProviderOption {
  readonly type: ProviderType;
  readonly displayName: string;
  readonly description: string;
}

const PROVIDER_OPTIONS: ProviderOption[] = [
  { type: ProviderType.DeepSeek, displayName: 'DeepSeek', description: 'DeepSeek V4 系列,官方 API' },
  { type: ProviderType.MiMo, displayName: 'MiMo', description: '小米 MiMo V2.5 系列,官方 API' },
  { type: ProviderType.SiliconFlow, displayName: '硅基流动', description: 'SiliconFlow 推理云,多种开源模型,OpenAI 兼容' },
  { type: ProviderType.OpenCodeGo, displayName: 'OpenCode Go', description: 'OpenCode Zen Go 订阅网关,OpenAI 兼容' },
  { type: ProviderType.OpenAICompatible, displayName: 'OpenAI Compatible', description: '通用 OpenAI 兼容接口,自定义 Base URL 与模型' }
];

const MAX_NAME_LENGTH: number = 32;

@Entry
@Component
struct ModelConfigEditPage {
  @State viewModel: ModelSettingsViewModel | null = null;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    this.viewModel = AppStorage.get<ModelSettingsViewModel>('ModelSettingsViewModel') ?? null;
  }

  /** 递增 modelConfigListVersion,通知 ModelSettingsPage 重新刷新列表 */
  private bumpListVersion(): void {
    const v: number = AppStorage.get<number>('modelConfigListVersion') ?? 0;
    AppStorage.setOrCreate<number>('modelConfigListVersion', v + 1);
  }

  build() {
    Stack() {
      if (this.viewModel === null) {
        this.loadingView()
      } else {
        this.mainView()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
  }

  @Builder
  mainView() {
    // 用 Stack 包裹 Column,把 Provider Sheet 与 Model Sheet 拆到不同容器上,
    // 避免同一组件挂多个 bindSheet 时后定义者覆盖前者的状态绑定。
    Stack() {
      Column() {
        // 顶部标题栏:返回 + 标题 + 保存
        Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        Text(this.pageTitle())
          .fontSize($r('app.float.nav_title_font_size'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 8, right: 8 })

        Button({ type: ButtonType.Capsule }) {
          Text(this.viewModel!.isSaving ? $r('app.string.model_settings_saving') : $r('app.string.model_settings_save'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
        }
        .height(32)
        .padding({ left: 12, right: 12 })
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .enabled(this.isFormReady() && !this.viewModel!.isSaving && !this.viewModel!.isTesting)
        .onClick(async () => {
          if (!this.viewModel!.checkFormValid()) {
            return;
          }
          await this.viewModel!.save();
          if (this.viewModel!.errorMessage.length === 0) {
            this.bumpListVersion();
            router.back();
          }
        })
      }
      .width('100%')
      .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      Tabs({ barPosition: BarPosition.Start, index: this.viewModel!.activeEditTab }) {
        TabContent() {
          this.connectionTabContent()
        }
        .tabBar($r('app.string.model_settings_connection'))

        TabContent() {
          this.parametersTabContent()
        }
        .tabBar($r('app.string.model_settings_parameters'))
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barHeight(48)
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
      .onChange((index: number) => {
        this.viewModel!.setActiveEditTab(index);
      })

      this.dangerActionArea()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .bindSheet(this.viewModel!.modelSheetOpen, this.modelSheetBuilder, {
      height: SheetSize.MEDIUM,
      mode: SheetMode.EMBEDDED,
      dragBar: false,
      showClose: false,
      backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
      onDisappear: () => {
        this.viewModel!.closeModelSheet();
      }
    })
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.viewModel!.providerSheetOpen, this.providerSheetBuilder, {
      height: SheetSize.MEDIUM,
      mode: SheetMode.EMBEDDED,
      dragBar: false,
      showClose: false,
      backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
      onDisappear: () => {
        this.viewModel!.closeProviderSheet();
      }
    })
  }

  @Builder
  connectionTabContent() {
    Scroll() {
      Column({ space: 16 }) {
        this.statusBanner()

        // 配置名称
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_name'))
          TextInput({
            text: this.viewModel!.name,
            placeholder: $r('app.string.model_settings_name_placeholder')
          })
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 12, right: 12 })
            .maxLength(MAX_NAME_LENGTH)
            .showError(this.viewModel!.nameError.length > 0 ? this.viewModel!.nameError : undefined)
            .onChange((v: string) => {
              this.viewModel!.name = v;
              if (this.viewModel!.nameError.length > 0) {
                this.viewModel!.nameError = '';
              }
            })
        }

        // API 服务商
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_provider'))
          this.selectableRow(
            () => this.providerDisplayName(),
            () => {
              this.viewModel!.openProviderSheet();
            }
          )
        }

        // API Key
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_api_key'))
          if (this.viewModel!.selectedConfigId !== null && this.viewModel!.apiKeyConfigured) {
            Text($r('app.string.model_settings_api_key_status_configured'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ bottom: 4 })
          }
          Row() {
            TextInput({
              text: this.viewModel!.apiKey,
              placeholder: $r('app.string.model_settings_api_key_placeholder')
            })
              .type(this.viewModel!.showApiKey ? InputType.Normal : InputType.Password)
              .width('100%')
              .height(48)
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 12, right: 12 })
              .copyOption(this.viewModel!.showApiKey ? CopyOptions.LocalDevice : CopyOptions.None)
              .layoutWeight(1)
              .showError(this.viewModel!.apiKeyError.length > 0 ? this.viewModel!.apiKeyError : undefined)
              .onChange((v: string) => {
                this.viewModel!.apiKey = v;
                if (this.viewModel!.apiKeyError.length > 0) {
                  this.viewModel!.apiKeyError = '';
                }
              })

            Button(this.viewModel!.showApiKey ? $r('app.string.model_settings_hide_key') : $r('app.string.model_settings_show_key'))
              .width(72)
              .height(48)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .margin({ left: 8 })
              .onClick(() => {
                this.viewModel!.showApiKey = !this.viewModel!.showApiKey;
              })
          }
          .width('100%')
        }

        // 模型
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_model'))
          Row() {
            if (this.viewModel!.isPresetMode || this.viewModel!.hasModelList) {
              Column() {
                Text(this.modelDisplayName())
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              }
              .layoutWeight(1)
              .onClick(() => {
                this.viewModel!.openModelSheet();
              })
            } else {
              TextInput({
                text: this.viewModel!.modelName,
                placeholder: 'gpt-4o'
              })
                .width('100%')
                .height(48)
                .fontSize($r('app.float.app_font_body'))
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                .borderRadius($r('app.float.app_radius_sm'))
                .padding({ left: 12, right: 12 })
                .onChange((v: string) => {
                  this.viewModel!.modelName = v;
                })
            }
            if (this.viewModel!.isFetchingModels) {
              LoadingProgress()
                .width(24)
                .height(24)
                .color(ThemePalette.accentColor(this.effectiveTheme))
                .margin({ left: 8 })
            } else {
              SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                .fontSize(20)
                .fontColor([this.viewModel!.canFetchModels()
                  ? ThemePalette.accentColor(this.effectiveTheme)
                  : ThemePalette.textTertiaryColor(this.effectiveTheme)])
                .margin({ left: 8 })
                .enabled(this.viewModel!.canFetchModels())
                .onClick(() => {
                  this.viewModel!.fetchModels();
                })
            }
          }
          .width('100%')
          .height(48)
          .padding({ left: 16, right: 16 })
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          if (this.viewModel!.fetchModelsMessage.length > 0) {
            Text(this.viewModel!.fetchModelsMessage)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .margin({ top: 4 })
          }
        }

        // Base URL
        FormSection() {
          this.fieldLabel($r('app.string.model_settings_base_url_summary'))
          if (this.viewModel!.isPresetMode) {
            Row() {
              Text($r('app.string.model_settings_base_url_auto'))
                .fontSize($r('app.float.app_font_body'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              Blank()
              SymbolGlyph($r('sys.symbol.checkmark_circle'))
                .fontSize(18)
                .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
          } else {
            TextInput({
              text: this.viewModel!.baseUrl,
              placeholder: 'https://api.example.com'
            })
              .width('100%')
              .height(48)
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 12, right: 12 })
              .onChange((v: string) => {
                this.viewModel!.baseUrl = v;
              })
          }
        }

        // 测试连接
        Button(this.viewModel!.isTesting ? $r('app.string.model_settings_testing') : $r('app.string.model_settings_test'))
          .width('100%')
          .height(48)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .enabled(this.isFormReady() && !this.viewModel!.isSaving && !this.viewModel!.isTesting)
          .margin({ top: 8 })
          .onClick(() => {
            if (this.viewModel!.checkFormValid()) {
              this.viewModel!.testConnection();
            }
          })

        // 设为当前(仅编辑非当前配置)
        if (this.viewModel!.selectedConfigId !== null
          && this.viewModel!.selectedConfigId !== this.viewModel!.currentConfigId) {
          Button($r('app.string.model_settings_set_current'))
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor($r('app.color.app_accent_surface'))
            .borderRadius($r('app.float.app_radius_sm'))
            .enabled(!this.viewModel!.isSaving && !this.viewModel!.isTesting)
            .margin({ top: 8 })
            .onClick(async () => {
              await this.viewModel!.setCurrent();
            })
        }

        Blank().height(24)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  parametersTabContent() {
    Scroll() {
      Column({ space: 16 }) {
        this.statusBanner()

        Text($r('app.string.model_settings_param_hint'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ top: 4, bottom: 4 })

        // Temperature(需要小数,使用 Normal 输入类型并在 onChange 校验)
        FormSection() {
          this.fieldLabelWithHint($r('app.string.model_settings_temperature'), $r('app.string.model_settings_temperature_range'))
          this.fieldDesc($r('app.string.model_settings_temperature_desc'))
          TextInput({ text: this.viewModel!.temperature.toString() })
            .type(InputType.Normal)
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => {
              const n: number = parseFloat(v);
              if (!isNaN(n)) {
                this.viewModel!.temperature = n;
              }
            })
        }

        // Top P(需要小数,使用 Normal 输入类型)
        FormSection() {
          this.fieldLabelWithHint($r('app.string.model_settings_top_p'), $r('app.string.model_settings_top_p_range'))
          this.fieldDesc($r('app.string.model_settings_top_p_desc'))
          TextInput({ text: this.viewModel!.topP.toString() })
            .type(InputType.Normal)
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => {
              const n: number = parseFloat(v);
              if (!isNaN(n)) {
                this.viewModel!.topP = n;
              }
            })
        }

        // Max Tokens
        FormSection() {
          this.fieldLabelWithHint($r('app.string.model_settings_max_tokens'), $r('app.string.model_settings_max_tokens_desc'))
          TextInput({ text: this.viewModel!.maxTokens.toString() })
            .type(InputType.Number)
            .width('100%')
            .height(48)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 12, right: 12 })
            .onChange((v: string) => {
              const n: number = parseInt(v, 10);
              if (!isNaN(n)) {
                this.viewModel!.maxTokens = n;
              }
            })
        }

        // 流式请求
        this.toggleRow(
          $r('app.string.model_settings_stream'),
          $r('app.string.model_settings_stream_desc'),
          this.viewModel!.stream,
          (on: boolean) => {
            this.viewModel!.stream = on;
          }
        )

        // 启用
        this.toggleRow(
          $r('app.string.model_settings_enabled'),
          $r('app.string.model_settings_enabled_desc'),
          this.viewModel!.enabled,
          (on: boolean) => {
            this.viewModel!.enabled = on;
          }
        )

        Blank().height(24)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  dangerActionArea() {
    if (this.viewModel!.selectedConfigId !== null) {
      Column() {
        Button($r('app.string.model_settings_delete'))
          .width('100%')
          .height(48)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_danger'))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .enabled(!this.viewModel!.isSaving && !this.viewModel!.isTesting)
          .onClick(() => {
            AlertDialog.show({
              title: $r('app.string.model_settings_delete'),
              message: $r('app.string.model_settings_delete_confirm'),
              primaryButton: {
                value: $r('app.string.model_settings_delete'),
                fontColor: $r('app.color.app_danger'),
                action: async () => {
                  await this.viewModel!.deleteSelected();
                  if (this.viewModel!.errorMessage.length === 0) {
                    this.bumpListVersion();
                    router.back();
                  }
                }
              },
              secondaryButton: {
                value: $r('app.string.character_form_cancel'),
                action: () => {}
              }
            });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: this.navigationBarHeight + 24 })
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    }
  }

  @Builder
  providerSheetBuilder() {
    Column() {
      Row() {
        Text($r('app.string.model_settings_provider_sheet_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .onClick(() => {
            this.viewModel!.closeProviderSheet();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      List({ space: 4 }) {
        ForEach(PROVIDER_OPTIONS, (option: ProviderOption) => {
          ListItem() {
            Row() {
              Column({ space: 2 }) {
                Text(option.displayName)
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor(this.viewModel!.providerType === option.type
                    ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .fontWeight(this.viewModel!.providerType === option.type
                    ? FontWeight.Medium : FontWeight.Normal)
                Text(option.description)
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (this.viewModel!.providerType === option.type) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(20)
                  .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .backgroundColor(this.viewModel!.providerType === option.type
              ? $r('app.color.app_accent_surface') : ThemePalette.surface1Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .onClick(() => {
              this.viewModel!.selectProviderFromSheet(option.type);
            })
          }
        })
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .padding({ bottom: 24 })
  }

  @Builder
  modelSheetBuilder() {
    Column() {
      Row() {
        Text($r('app.string.model_settings_model_sheet_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Blank()
        if (this.viewModel!.isFetchingModels) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color(ThemePalette.accentColor(this.effectiveTheme))
        } else {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(20)
            .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
            .margin({ right: 12 })
            .onClick(() => {
              this.viewModel!.fetchModels();
            })
        }
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .onClick(() => {
            this.viewModel!.closeModelSheet();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel!.fetchModelsMessage.length > 0) {
        Text(this.viewModel!.fetchModelsMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .padding({ left: 16, right: 16 })
      }

      if (this.viewModel!.displayedModels.length > 0) {
        List({ space: 4 }) {
          ForEach(this.viewModel!.displayedModels, (model: ModelOption, index: number) => {
            ListItem() {
              Row() {
                Column({ space: 2 }) {
                  Text(model.displayName)
                    .fontSize($r('app.float.app_font_body'))
                    .fontColor(index === this.viewModel!.selectedModelIndex
                      ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.textPrimaryColor(this.effectiveTheme))
                    .fontWeight(index === this.viewModel!.selectedModelIndex
                      ? FontWeight.Medium : FontWeight.Normal)
                  if (model.description !== undefined) {
                    Text(model.description)
                      .fontSize($r('app.float.app_font_caption'))
                      .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                      .margin({ top: 2 })
                  }
                  if (this.modelCapabilityLabel(model.id).length > 0) {
                    Text(this.modelCapabilityLabel(model.id))
                      .fontSize($r('app.float.app_font_caption'))
                      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                      .margin({ top: 2 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (index === this.viewModel!.selectedModelIndex) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(20)
                    .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
                }
              }
              .width('100%')
              .padding(16)
              .backgroundColor(index === this.viewModel!.selectedModelIndex
                ? $r('app.color.app_accent_surface') : ThemePalette.surface1Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .onClick(() => {
                this.viewModel!.selectModelFromSheet(index);
              })
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .padding({ left: 16, right: 16, bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .padding({ bottom: 24 })
  }

  @Builder
  fieldLabel(label: Resource) {
    Text(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      .margin({ bottom: 6 })
  }

  @Builder
  fieldLabelWithHint(label: Resource, hint: Resource) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      Text(' · ')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      Text(hint)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
    .margin({ bottom: 6 })
  }

  @Builder
  fieldDesc(desc: Resource) {
    Text(desc)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      .margin({ bottom: 8 })
  }

  @Builder
  selectableRow(valueProvider: () => string, onClick: () => void) {
    Row() {
      if (valueProvider().length > 0) {
        Text(valueProvider())
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
      } else {
        Text($r('app.string.model_settings_select_provider_hint'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .layoutWeight(1)
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(18)
        .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(onClick)
  }

  @Builder
  toggleRow(title: Resource, desc: Resource, isOn: boolean, onChange: (on: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Text(desc)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange(onChange)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .onClick(() => {
      onChange(!isOn);
    })
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

  private pageTitle(): Resource {
    return this.viewModel!.selectedConfigId === null
      ? $r('app.string.model_settings_new_title')
      : $r('app.string.model_settings_edit_title');
  }

  private providerDisplayName(): string {
    for (let i = 0; i < PROVIDER_OPTIONS.length; i++) {
      if (PROVIDER_OPTIONS[i].type === this.viewModel!.providerType) {
        return PROVIDER_OPTIONS[i].displayName;
      }
    }
    return '';
  }

  private modelDisplayName(): string {
    const models: ModelOption[] = this.viewModel!.displayedModels;
    if (this.viewModel!.selectedModelIndex >= 0 && this.viewModel!.selectedModelIndex < models.length) {
      return models[this.viewModel!.selectedModelIndex].displayName;
    }
    return this.viewModel!.modelName;
  }

  private modelCapabilityLabel(modelId: string): string {
    const capability: ModelCapability | null = getModelCapability(modelId);
    if (capability === null) {
      return '';
    }
    return '上下文 ' + this.formatTokenCount(capability.contextWindow)
      + ' · 输出上限 ' + this.formatTokenCount(capability.maxOutputTokensLimit);
  }

  private formatTokenCount(tokens: number): string {
    if (tokens >= 1000000) {
      const m: number = tokens / 1000000;
      return this.trimNumber(m) + 'M';
    }
    if (tokens >= 1000) {
      const k: number = tokens / 1000;
      return this.trimNumber(k) + 'K';
    }
    return tokens.toString();
  }

  private trimNumber(n: number): string {
    if (Number.isInteger(n)) {
      return n.toString();
    }
    return n.toFixed(1);
  }

  private isFormReady(): boolean {
    if (this.viewModel === null) {
      return false;
    }
    if (this.viewModel!.isSaving || this.viewModel!.isTesting) {
      return false;
    }
    if (this.viewModel!.name.trim().length === 0) {
      return false;
    }
    if (!this.viewModel!.isSupportedType(this.viewModel!.providerType)) {
      return false;
    }
    if (this.viewModel!.selectedConfigId === null && this.viewModel!.apiKey.trim().length === 0) {
      return false;
    }
    return true;
  }
}

/**
 * 表单分组容器组件。
 * 通过 @BuilderParam 接收子组件,避免 @Builder 方法传递 Builder 的语法限制。
 */
@Component
struct FormSection {
  @BuilderParam content: () => void;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .alignItems(HorizontalAlign.Start)
  }
}
