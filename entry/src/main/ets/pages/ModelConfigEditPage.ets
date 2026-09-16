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
import {
  TEMPERATURE_MIN,
  TEMPERATURE_MAX,
  TOP_P_MIN,
  TOP_P_MAX,
  MAX_TOKENS_MIN,
  MAX_TOKENS_MAX,
  MAX_TOKENS_DEFAULT
} from '../models/ProviderConfig';
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
  { type: ProviderType.Zhipu, displayName: '智谱 GLM', description: '智谱 BigModel 开放平台,GLM 系列,OpenAI 兼容' },
  { type: ProviderType.Qwen, displayName: '通义千问', description: '阿里云 DashScope 兼容模式,Qwen 系列,OpenAI 兼容' },
  { type: ProviderType.Kimi, displayName: '月之暗面', description: 'Moonshot Kimi 系列,OpenAI 兼容' },
  { type: ProviderType.Volcengine, displayName: '火山方舟', description: '字节跳动 Ark 托管控,豆包/DeepSeek,OpenAI 兼容' },
  { type: ProviderType.MiniMax, displayName: 'MiniMax', description: 'MiniMax 推理模型,OpenAI 兼容' },
  { type: ProviderType.Gemini, displayName: 'Gemini', description: 'Google 官方 OpenAI 兼容端点,可获取模型列表' },
  { type: ProviderType.OpenAICompatible, displayName: 'OpenAI Compatible', description: '通用 OpenAI 兼容接口,自定义 Base URL 与模型' }
];

const MAX_NAME_LENGTH: number = 32;

@Entry
@Component
struct ModelConfigEditPage {
  @State viewModel: ModelSettingsViewModel | null = null;
  /** 服务商选择 Sheet 开关(页面 @State,驱动 bindSheet 显示) */
  @State providerSheetOpen: boolean = false;
  /** 模型选择 Sheet 开关(页面 @State,驱动 bindSheet 显示) */
  @State modelSheetOpen: boolean = false;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** Max Tokens 输入框文本(与 viewModel.maxTokens 双向同步) */
  @State maxTokensInput: string = '';

  aboutToAppear(): void {
    this.viewModel = AppStorage.get<ModelSettingsViewModel>('ModelSettingsViewModel') ?? null;
    if (this.viewModel !== null) {
      this.maxTokensInput = this.viewModel.maxTokens.toString();
    }
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
    .bindSheet(this.modelSheetOpen, this.modelSheetBuilder, {
      height: SheetSize.MEDIUM,
      mode: SheetMode.EMBEDDED,
      dragBar: false,
      showClose: false,
      backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
      onDisappear: () => {
        this.modelSheetOpen = false;
      }
    })
    }
    .width('100%')
    .height('100%')
    .bindSheet(this.providerSheetOpen, this.providerSheetBuilder, {
      height: SheetSize.MEDIUM,
      mode: SheetMode.EMBEDDED,
      dragBar: false,
      showClose: false,
      backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
      onDisappear: () => {
        this.providerSheetOpen = false;
      }
    })
  }

  @Builder
  connectionTabContent() {
    Scroll() {
      Column({ space: 16 }) {
        this.statusBanner()

        // ===== 基础信息 分组卡片 =====
        Column() {
          this.fieldRowLabel($r('app.string.model_settings_name'))
          TextInput({
            text: this.viewModel!.name,
            placeholder: $r('app.string.model_settings_name_placeholder')
          })
            .width('100%')
            .height(44)
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
        .width('100%')
        .padding(16)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))

        // ===== API 接入 分组卡片 =====
        Column() {
          // 服务商
          this.fieldRowLabel($r('app.string.model_settings_provider'))
          this.providerPickerRow()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ left: 16, right: 16, top: 12, bottom: 12 })

          // API Key
          this.fieldRowLabel($r('app.string.model_settings_api_key'))
          if (this.viewModel!.selectedConfigId !== null && this.viewModel!.apiKeyConfigured) {
            Text($r('app.string.model_settings_api_key_status_configured'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          }
          Row() {
            TextInput({
              text: this.viewModel!.apiKey,
              placeholder: $r('app.string.model_settings_api_key_placeholder')
            })
              .type(this.viewModel!.showApiKey ? InputType.Normal : InputType.Password)
              .width('100%')
              .height(44)
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
              .height(44)
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
        .width('100%')
        .padding(16)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))

        // ===== 模型 & 接口 分组卡片 =====
        Column() {
          // 模型(可点击选择)
          this.modelPickerRow()
          if (this.viewModel!.fetchModelsMessage.length > 0) {
            Text(this.viewModel!.fetchModelsMessage)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .margin({ top: 8 })
          }

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ left: 16, right: 16, top: 12, bottom: 12 })

          // Base URL
          this.fieldRowLabel($r('app.string.model_settings_base_url_summary'))
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
            .height(44)
            .padding({ left: 12, right: 12 })
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
          } else {
            TextInput({
              text: this.viewModel!.baseUrl,
              placeholder: 'https://api.example.com'
            })
              .width('100%')
              .height(44)
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
        .width('100%')
        .padding(16)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))

        // 测试连接
        Button(this.viewModel!.isTesting ? $r('app.string.model_settings_testing') : $r('app.string.model_settings_test'))
          .width('100%')
          .height(50)
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_md'))
          .enabled(this.isFormReady() && !this.viewModel!.isSaving && !this.viewModel!.isTesting)
          .margin({ top: 4 })
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
            .height(50)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor($r('app.color.app_accent_surface'))
            .borderRadius($r('app.float.app_radius_md'))
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
  fieldRowLabel(label: Resource) {
    Text(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontWeight(FontWeight.Medium)
      .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      .margin({ bottom: 8 })
  }

  @Builder
  providerPickerRow() {
    Row() {
      Text(this.providerDisplayName())
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(() => {
      this.providerSheetOpen = true;
    })
  }

  @Builder
  modelPickerRow() {
    Row() {
      // 内容区始终填充文字(为空时显示占位),保证可点击区域始终存在
      Column() {
        Text(this.modelDisplayName().length > 0
          ? this.modelDisplayName()
          : $r('app.string.model_settings_model_placeholder'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.modelDisplayName().length > 0
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textTertiaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.modelSheetOpen = true;
      })
      if (this.viewModel!.isFetchingModels) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(ThemePalette.accentColor(this.effectiveTheme))
          .margin({ left: 8 })
      } else {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(18)
          .fontColor([this.viewModel!.canFetchModels()
            ? ThemePalette.accentColor(this.effectiveTheme)
            : ThemePalette.textTertiaryColor(this.effectiveTheme)])
          .margin({ left: 8 })
          .enabled(this.viewModel!.canFetchModels())
          .onClick(() => {
            this.viewModel!.fetchModels();
          })
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
        .margin({ left: 8 })
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_sm'))
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

        // ===== 采样参数 分组卡片 =====
        Column() {
          // Temperature
          this.sliderRow(
            $r('app.string.model_settings_temperature'),
            $r('app.string.model_settings_temperature_desc'),
            this.viewModel!.temperature,
            TEMPERATURE_MIN,
            TEMPERATURE_MAX,
            0.1,
            (n: number) => {
              this.viewModel!.temperature = n;
            }
          )

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ left: 16, right: 16, top: 4, bottom: 4 })

          // Top P
          this.sliderRow(
            $r('app.string.model_settings_top_p'),
            $r('app.string.model_settings_top_p_desc'),
            this.viewModel!.topP,
            TOP_P_MIN,
            TOP_P_MAX,
            0.05,
            (n: number) => {
              this.viewModel!.topP = n;
            }
          )

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ left: 16, right: 16, top: 4, bottom: 4 })

          // Max Tokens
          Column({ space: 6 }) {
            Row() {
              Column({ space: 2 }) {
                Text($r('app.string.model_settings_max_tokens'))
                  .fontSize($r('app.float.app_font_body'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                Text($r('app.string.model_settings_max_tokens_desc'))
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              TextInput({
                text: this.maxTokensInput,
                placeholder: MAX_TOKENS_DEFAULT.toString()
              })
                .type(InputType.Number)
                .width(120)
                .height(40)
                .fontSize($r('app.float.app_font_body'))
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                .borderRadius($r('app.float.app_radius_sm'))
                .padding({ left: 10, right: 10 })
                .onChange((v: string) => {
                  this.maxTokensInput = v;
                  const parsed: number = Number.parseInt(v, 10);
                  if (!Number.isNaN(parsed)) {
                    this.viewModel!.maxTokens = parsed;
                  }
                })
            }
            .width('100%')

            Text('范围 ' + MAX_TOKENS_MIN + ' ~ ' + MAX_TOKENS_MAX + ',过小会导致长回复被截断')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))

        // ===== 行为 分组卡片 =====
        Column() {
          this.switchRow(
            $r('app.string.model_settings_stream'),
            $r('app.string.model_settings_stream_desc'),
            this.viewModel!.stream,
            (on: boolean) => {
              this.viewModel!.stream = on;
            }
          )

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ left: 16, right: 16 })

          this.switchRow(
            $r('app.string.model_settings_enabled'),
            $r('app.string.model_settings_enabled_desc'),
            this.viewModel!.enabled,
            (on: boolean) => {
              this.viewModel!.enabled = on;
            }
          )
        }
        .width('100%')
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))

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
  sliderRow(title: Resource, desc: Resource, value: number, min: number, max: number, step: number, onChange: (n: number) => void) {
    Column() {
      Row() {
        Column({ space: 2 }) {
          Text(title)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text(desc)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.formatSliderValue(value))
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
      }
      .width('100%')

      Slider({
        value: value,
        min: min,
        max: max,
        step: step,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
        .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
        .blockColor(ThemePalette.accentColor(this.effectiveTheme))
        .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
        .onChange((v: number, mode: SliderChangeMode) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  switchRow(title: Resource, desc: Resource, isOn: boolean, onChange: (on: boolean) => void) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Text(desc)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
        .onChange(onChange)
    }
    .width('100%')
    .padding(16)
    .onClick(() => {
      onChange(!isOn);
    })
  }

  private formatSliderValue(value: number): string {
    if (Number.isInteger(value)) {
      return value.toString();
    }
    return value.toFixed(2);
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
            this.providerSheetOpen = false;
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
              this.providerSheetOpen = false;
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
            this.modelSheetOpen = false;
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

      // 手动输入模型名(自定义 URL 无预设列表时可在此直接填)
      TextInput({
        text: this.viewModel!.modelName,
        placeholder: 'model-name(可手动输入)'
      })
        .width('100%')
        .height(48)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .padding({ left: 12, right: 12 })
        .margin({ left: 16, right: 16 })
        .onChange((v: string) => {
          this.viewModel!.modelName = v;
          this.viewModel!.syncModelIndexFromName(v);
        })

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
                this.modelSheetOpen = false;
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
