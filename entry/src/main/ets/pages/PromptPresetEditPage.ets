/**
 * PromptPresetEditPage 预设编辑页面
 *
 * 支持新建和编辑预设。
 * 路由参数通过 aboutToAppear 中的 router.getParams() 稳定获取。
 * 表单状态通过 @State formState 快照实现响应式,不依赖 ViewModel 的 @Observed 字段。
 * 每个页面实例持有独立 ViewModel,支持新建和编辑模式切换。
 *
 * 主题适配:
 * - 页面背景使用 ThemePalette.pageBackgroundColor(this.effectiveTheme)(浅色 #F5F5F5 / 深色 #121212)
 * - 标题栏使用 ThemePalette.surface1Color(this.effectiveTheme)
 * - 文字使用 ThemePalette.textPrimaryColor(this.effectiveTheme) / ThemePalette.textSecondaryColor(this.effectiveTheme)
 * - 主操作按钮使用 ThemePalette.accentColor(this.effectiveTheme) + $r('app.color.app_on_accent')
 * - 错误文字使用 $r('app.color.app_danger')
 * - 分隔线使用 ThemePalette.dividerColor(this.effectiveTheme)
 * - 不在组件中散落十六进制颜色,浅色/深色模式自动切换
 *
 * 系统状态栏:
 * - 由 EntryAbility 全局处理(状态栏背景透明,图标颜色随 colorMode 切换)
 * - 页面只需保证根容器背景色与主题一致,深色模式下状态栏区域透出深色背景
 */

import { PromptPresetEditViewModel, PromptPresetEditFormState, emptyFormState, copyFormState, parsePresetEditRouteParam } from '../viewmodels/PromptPresetEditViewModel';
import { AppServices } from '../services/AppServices';
import { router } from '@kit.ArkUI';
import { Logger } from '../utils/Logger';
import { ThemePalette } from '../theme/ThemePalette';

const LOG_TAG: string = 'PromptPresetEditPage';

@Entry
@Component
struct PromptPresetEditPage {
  @State formState: PromptPresetEditFormState = emptyFormState();
  @State isLoading: boolean = true;
  @State isEditing: boolean = false;
  @State errorMessage: string = '';
  @State fieldErrors: Record<string, string> = {};
  @State isSaving: boolean = false;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private viewModel: PromptPresetEditViewModel = new PromptPresetEditViewModel(
    AppServices.getPromptPresetService()
  );
  private presetId: string | undefined = undefined;
  private readyHandled: boolean = false;

  aboutToAppear(): void {
    this.handleReady(router.getParams());
  }

  build() {
    Column() {
      // 标题栏(复用设置子页面规范:app_surface_1 背景 + app_text_primary 文字)
      Row() {
        Button('取消')
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .onClick(() => {
            router.back();
          })

        Blank()

        Text(this.isEditing ? '编辑预设' : '新建预设')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))

        Blank()

        Button('保存')
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius(6)
          .padding({ left: 12, right: 12 })
          .enabled(!this.isSaving && this.formState.nameInput.trim().length > 0)
          .onClick(async () => {
            await this.handleSave();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: this.statusBarHeight + 8, bottom: 8 })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))

      Divider()
        .height(1)
        .color(ThemePalette.dividerColor(this.effectiveTheme))

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(ThemePalette.accentColor(this.effectiveTheme))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMessage.length > 0 && !this.isEditing) {
        // 未找到记录或参数错误:显示错误而非空表单
        Column() {
          Text(this.errorMessage)
            .fontSize(14)
            .fontColor($r('app.color.app_danger'))
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding(16)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // ===== 卡片 1:基本信息 =====
            this.basicInfoCard()

            // ===== 卡片 2:参数覆盖 =====
            this.parameterOverrideCard()

            // 全局错误(保存失败时显示)
            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .fontSize(13)
                .fontColor($r('app.color.app_danger'))
                .width('100%')
                .margin({ top: 8, bottom: 8 })
                .padding(12)
                .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
                .borderRadius(8)
            }

            // 底部安全区避让
            Blank().height(this.navigationBarHeight + 16)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 基本信息卡片:名称、描述、System Prompt
   */
  @Builder
  basicInfoCard() {
    Column() {
      Text('基本信息')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 12 })

      // 1. 名称 *
      this.fieldLabel('名称 *')
      TextInput({ placeholder: '输入预设名称', text: this.formState.nameInput })
        .maxLength(100)
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(8)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onChange((value: string) => {
          const updated = copyFormState(this.formState);
          updated.nameInput = value;
          this.formState = updated;
        })
        .width('100%')
      this.fieldError('name')

      // 2. 描述
      this.fieldLabel('描述(可选)')
      TextInput({ placeholder: '输入描述', text: this.formState.descriptionInput })
        .maxLength(1000)
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(8)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onChange((value: string) => {
          const updated = copyFormState(this.formState);
          updated.descriptionInput = value;
          this.formState = updated;
        })
        .width('100%')

      // 3. System Prompt
      this.fieldLabel('System Prompt(可选)')
      TextArea({ placeholder: '输入附加 System Prompt', text: this.formState.systemPromptInput })
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(8)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onChange((value: string) => {
          const updated = copyFormState(this.formState);
          updated.systemPromptInput = value;
          this.formState = updated;
        })
        .width('100%')
        .height(120)
        .maxLength(10000)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
    .margin({ bottom: 12 })
  }

  /**
   * 参数覆盖卡片:Temperature / Top P / MaxOutputTokens / ContextWindow
   */
  @Builder
  parameterOverrideCard() {
    Column() {
      Text('参数覆盖(可选)')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 4 })

      Text('启用后可覆盖模型默认参数')
        .fontSize(12)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 12 })

      // 4. Temperature
      this.toggleField(
        '覆盖 Temperature',
        '0 ~ 2',
        '采样随机性:越高回复越多样、越有创意,越低越稳定、越确定。',
        this.formState.overrideTemperature,
        this.formState.temperatureInput,
        (isOn: boolean) => {
          const updated = copyFormState(this.formState);
          updated.overrideTemperature = isOn;
          updated.temperatureInput = isOn ? this.formState.temperatureInput : '';
          this.formState = updated;
        },
        (value: string) => {
          const updated = copyFormState(this.formState);
          updated.temperatureInput = value;
          this.formState = updated;
        }
      )
      this.fieldError('temperature')

      Divider()
        .height(1)
        .color(ThemePalette.dividerColor(this.effectiveTheme))
        .margin({ top: 8, bottom: 8 })

      // 5. Top P
      this.toggleField(
        '覆盖 Top P',
        '0 ~ 1',
        '核采样:只从概率累计到该值的候选词中采样,越低越保守集中,越高越多样。',
        this.formState.overrideTopP,
        this.formState.topPInput,
        (isOn: boolean) => {
          const updated = copyFormState(this.formState);
          updated.overrideTopP = isOn;
          updated.topPInput = isOn ? this.formState.topPInput : '';
          this.formState = updated;
        },
        (value: string) => {
          const updated = copyFormState(this.formState);
          updated.topPInput = value;
          this.formState = updated;
        }
      )
      this.fieldError('topP')

      Divider()
        .height(1)
        .color(ThemePalette.dividerColor(this.effectiveTheme))
        .margin({ top: 8, bottom: 8 })

      // 6. maxOutputTokens
      this.toggleField(
        '覆盖最大输出 Token',
        '正整数',
        '',
        this.formState.overrideMaxOutputTokens,
        this.formState.maxOutputTokensInput,
        (isOn: boolean) => {
          const updated = copyFormState(this.formState);
          updated.overrideMaxOutputTokens = isOn;
          updated.maxOutputTokensInput = isOn ? this.formState.maxOutputTokensInput : '';
          this.formState = updated;
        },
        (value: string) => {
          const updated = copyFormState(this.formState);
          updated.maxOutputTokensInput = value;
          this.formState = updated;
        }
      )
      this.fieldError('maxOutputTokens')

      Divider()
        .height(1)
        .color(ThemePalette.dividerColor(this.effectiveTheme))
        .margin({ top: 8, bottom: 8 })

      // 7. contextWindow
      this.toggleField(
        '覆盖上下文窗口',
        '512 ~ 1000000',
        '',
        this.formState.overrideContextWindow,
        this.formState.contextWindowInput,
        (isOn: boolean) => {
          const updated = copyFormState(this.formState);
          updated.overrideContextWindow = isOn;
          updated.contextWindowInput = isOn ? this.formState.contextWindowInput : '';
          this.formState = updated;
        },
        (value: string) => {
          const updated = copyFormState(this.formState);
          updated.contextWindowInput = value;
          this.formState = updated;
        }
      )
      this.fieldError('contextWindow')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
  }

  private handleReady(param: Object | undefined): void {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;

    try {
      this.handleDestinationReady(param);
    } catch (e) {
      this.errorMessage = '页面参数错误';
      this.isLoading = false;
    }
  }

  private async handleDestinationReady(param: Object | undefined): Promise<void> {
    const parsed = parsePresetEditRouteParam(param);

    if (parsed.error !== undefined) {
      this.errorMessage = parsed.error;
      this.isLoading = false;
      Logger.warn(LOG_TAG, 'route param error: ' + parsed.error);
      return;
    }

    this.presetId = parsed.presetId;
    Logger.info(LOG_TAG, 'handleDestinationReady presetId=' + (this.presetId ?? '(new)'));

    // 初始化 ViewModel
    await this.viewModel.initialize(this.presetId);

    // 编辑模式:要检查是否找到记录
    if (this.presetId !== undefined && this.presetId.length > 0) {
      // 加载表单状态
      const fs: PromptPresetEditFormState = await this.viewModel.getFormState(this.presetId);
      // 检查是否为空表单(表示未找到记录)
      const isNotFound: boolean = fs.nameInput.length === 0 && this.presetId.length > 0;
      if (isNotFound) {
        this.errorMessage = '该预设不存在或已被删除';
        this.isEditing = false;
        this.isLoading = false;
        Logger.warn(LOG_TAG, 'preset not found: ' + this.presetId);
        return;
      }
      this.formState = fs;
      this.isEditing = true;
      Logger.info(LOG_TAG, 'edit mode loaded, name=' + fs.nameInput);
    } else {
      this.formState = emptyFormState();
      this.isEditing = false;
      Logger.info(LOG_TAG, 'create mode');
    }

    this.isLoading = false;
  }

  private async handleSave(): Promise<void> {
    this.isSaving = true;
    this.errorMessage = '';
    this.fieldErrors = {};

    const success: boolean = await this.viewModel.save(this.formState);

    if (success) {
      router.back();
    } else {
      this.errorMessage = '保存失败,请检查输入';
    }

    this.isSaving = false;
  }

  @Builder
  fieldLabel(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      .fontWeight(FontWeight.Regular)
      .width('100%')
      .margin({ top: 12, bottom: 6 })
  }

  @Builder
  fieldError(key: string) {
    if (this.fieldErrors[key] !== undefined) {
      Text(this.fieldErrors[key])
        .fontSize(12)
        .fontColor($r('app.color.app_danger'))
        .width('100%')
        .margin({ top: 4, bottom: 4 })
    }
  }

  @Builder
  toggleField(
    label: string,
    hint: string,
    description: string,
    enabled: boolean,
    inputValue: string,
    onToggle: (isOn: boolean) => void,
    onInputChange: (value: string) => void
  ) {
    Column() {
      Row() {
        Column() {
          Text(label)
            .fontSize(14)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          if (hint.length > 0) {
            Text(hint)
              .fontSize(11)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ top: 2 })
          }
          if (description.length > 0) {
            Text(description)
              .fontSize(11)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: enabled })
          .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
          .onChange((isOn: boolean) => {
            onToggle(isOn);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (enabled) {
        TextInput({ placeholder: '请输入 ' + hint, text: inputValue })
          .type(InputType.Number)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .onChange((value: string) => {
            onInputChange(value);
          })
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }
}
