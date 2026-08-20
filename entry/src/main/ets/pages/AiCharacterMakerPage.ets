/**
 * AiCharacterMakerPage AI 制作角色卡创意输入页
 *
 * 全屏原生 ArkUI 页面,用户输入角色创意,调用 AI 模型生成标准 Tavern Card V2 JSON。
 *
 * 流程:
 * 输入创意 → 首次生成前显示隐私提示 → AI 流式生成 → 校验+自动修复 → 跳转到预览页
 *
 * 职责:
 * 1. 收集创意输入(创意描述、名称、世界观、性格、关系、对话风格、内容语言、详细程度、3 个开关)
 * 2. 始终使用当前聊天配置的模型(ModelService.getCurrentConfig),不在页面暴露模型/Provider/API Key 等配置信息
 * 3. 首次生成前显示隐私提示
 * 4. 调用 ViewModel.startGeneration,显示生成状态,提供停止按钮
 * 5. 生成成功后跳转到 AiCharacterPreviewPage
 *
 * 不直接:
 * - 调用 network/ 模块
 * - 调用 ModelService(通过 ViewModel)
 * - 调用 CharacterService(由 Preview ViewModel 调用)
 *
 * 隐私约束:
 * - 不向日志输出完整创意内容
 * - 不缓存 API Key
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { ModelService } from '../services/ModelService';
import {
  AiCharacterGenerationService
} from '../services/ai/AiCharacterGenerationService';
import {
  AiCharacterMakerViewModel,
  AiMakerState
} from '../viewmodels/AiCharacterMakerViewModel';
import { AiGenerationResult } from '../models/AiGenerationResult';
import { ThemePalette } from '../theme/ThemePalette';

@Entry
@Component
struct AiCharacterMakerPage {
  @State viewModel: AiCharacterMakerViewModel | null = null;
  @State isInitializing: boolean = true;
  @State showPrivacyDialog: boolean = false;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 草稿保存防抖定时器 ID */
  private draftTimerId: number = -1;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const appServices: AppServices = AppServices.getInstance();
      const modelService: ModelService = appServices.modelService;
      // 创建独立 AppPreferences 实例并使用页面 Context 初始化。
      // 由于平台按 store name 缓存 Preferences 实例,此处与 AppServices 中的实例指向同一文件。
      const ctx: common.Context = getContext(this) as common.Context;
      const prefs: AppPreferences = new AppPreferences();
      await prefs.initialize(ctx);
      const generationService: AiCharacterGenerationService = new AiCharacterGenerationService(modelService);
      const vm: AiCharacterMakerViewModel = new AiCharacterMakerViewModel(generationService, prefs);
      vm.setOnCompleteCallback((result: AiGenerationResult) => this.onGenerationComplete(result));
      this.viewModel = vm;
      await vm.loadDraft();
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      const msg: string = e instanceof Error ? e.message : '初始化失败';
      promptAction.showToast({ message: msg, duration: 2000 });
    }
  }

  aboutToDisappear(): void {
    this.cancelDraftTimer();
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
    }
  }

  /** 返回上一页 */
  private handleBack(): void {
    router.back();
  }

  /** 生成完成回调 */
  private onGenerationComplete(result: AiGenerationResult): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.state === AiMakerState.Idle) {
      // 跳转到预览页
      router.pushUrl({ url: 'pages/AiCharacterPreviewPage' });
    }
  }

  /** 点击生成按钮(校验隐私提示 + 输入) */
  private async onGenerateClick(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.conceptDescription.trim().length === 0) {
      promptAction.showToast({ message: '请输入角色创意描述', duration: 2000 });
      return;
    }
    if (!this.viewModel!.privacyConfirmed) {
      this.showPrivacyDialog = true;
      return;
    }
    this.startGeneration();
  }

  /** 真正开始生成 */
  private startGeneration(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.startGeneration();
  }

  /** 确认隐私提示 */
  private confirmPrivacy(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.privacyConfirmed = true;
    this.showPrivacyDialog = false;
    this.startGeneration();
  }

  /** 取消隐私提示 */
  private cancelPrivacy(): void {
    this.showPrivacyDialog = false;
  }

  /** 停止生成 */
  private onStopClick(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.cancelGeneration();
    promptAction.showToast({ message: '已停止生成,输入已保留', duration: 1500 });
  }

  /** 放弃 */
  private async onDiscardClick(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.resetAll();
    this.handleBack();
  }

  /** 创意描述输入变化 */
  private onConceptChange(value: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.conceptDescription = value;
    this.scheduleDraftSave();
  }

  /** 通用文本字段变化(防抖保存草稿) */
  private onTextFieldChange(): void {
    this.scheduleDraftSave();
  }

  /** 安排草稿保存(防抖 500ms) */
  private scheduleDraftSave(): void {
    this.cancelDraftTimer();
    this.draftTimerId = setTimeout((): void => {
      if (this.viewModel !== null) {
        void this.viewModel!.saveDraft();
      }
    }, 500);
  }

  /** 取消草稿保存定时器 */
  private cancelDraftTimer(): void {
    if (this.draftTimerId !== -1) {
      clearTimeout(this.draftTimerId);
      this.draftTimerId = -1;
    }
  }

  /** 切换"生成世界书" */
  private toggleGenerateBook(value: boolean): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.generateCharacterBook = value;
    this.scheduleDraftSave();
  }

  /** 切换"生成多个开场白" */
  private toggleGenerateGreetings(value: boolean): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.generateMultipleGreetings = value;
    this.scheduleDraftSave();
  }

  /** 切换"生成对话示例" */
  private toggleGenerateMesExample(value: boolean): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.generateMesExample = value;
    this.scheduleDraftSave();
  }

  build() {
    Stack() {
      Column() {
        this.topBar()
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.viewModel !== null && this.viewModel!.state === AiMakerState.Generating) {
          this.generatingView()
        } else {
          // 主体表单(可滚动)
          this.formView()
          // 底部固定操作栏(不随 Scroll 滚动)
          this.bottomActionBar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 隐私提示对话框(覆盖整个页面)
      if (this.showPrivacyDialog) {
        this.privacyDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ===== 顶部栏 =====

  @Builder
  topBar() {
    Row() {
      Button($r('app.string.character_edit_back'))
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .height(40)
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          this.handleBack();
        })

      Text('AI 制作角色卡')
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 占位平衡返回按钮宽度
      Button('')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(Color.Transparent)
        .fontColor(Color.Transparent)
        .height(40)
        .width(56)
        .enabled(false)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: this.statusBarHeight + 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }

  // ===== 表单视图(卡片化分组) =====

  @Builder
  formView() {
    Scroll() {
      Column() {
        // ===== 顶部说明条 =====
        Text('输入角色创意,由你已配置的 AI 模型生成标准 Tavern Card V2。仅需创意描述,其余选项均为可选辅助。')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor($r('app.color.app_accent_surface'))
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_12'),
            bottom: $r('app.float.app_spacing_12')
          })

        // ===== 卡片 1:创意描述(必填) =====
        Column() {
          this.cardHeader('创意描述', true, '用一两句话描述你想要的角色')
          TextArea({
            placeholder: '例如:一个在末世废土中独自旅行的女猎人,擅长改造废旧机械...',
            text: this.viewModel !== null ? this.viewModel!.conceptDescription : ''
          })
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(120)
            .width('100%')
            .padding(12)
            .textAlign(TextAlign.Start)
            .constraintSize({ maxHeight: 200 })
            .onChange((value: string) => this.onConceptChange(value))
        }
        .width('100%')
        .padding($r('app.float.app_spacing_16'))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
        .margin({
          left: $r('app.float.app_spacing_12'),
          right: $r('app.float.app_spacing_12'),
          top: $r('app.float.app_spacing_12')
        })

        // ===== 卡片 2:角色基础(可选) =====
        Column() {
          this.cardHeader('角色基础', false, '帮助 AI 更精确地塑造角色')

          // 角色名称
          this.fieldLabel('角色名称', '留空让 AI 生成')
          TextInput({
            placeholder: '例:林雾、Kira、Alice...',
            text: this.viewModel !== null ? this.viewModel!.name : ''
          })
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(48)
            .width('100%')
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              if (this.viewModel !== null) {
                this.viewModel!.name = value;
              }
              this.onTextFieldChange();
            })

          // 世界观或故事背景
          this.fieldLabel('世界观或故事背景', '')
          TextArea({
            placeholder: '例:末世后的废土城市,人类聚集在地下避难所...',
            text: this.viewModel !== null ? this.viewModel!.backstory : ''
          })
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(80)
            .width('100%')
            .padding(12)
            .onChange((value: string) => {
              if (this.viewModel !== null) {
                this.viewModel!.backstory = value;
              }
              this.onTextFieldChange();
            })

          // 性格关键词
          this.fieldLabel('性格关键词', '')
          TextInput({
            placeholder: '例:冷静、机智、有点固执',
            text: this.viewModel !== null ? this.viewModel!.personalityKeywords : ''
          })
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(48)
            .width('100%')
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              if (this.viewModel !== null) {
                this.viewModel!.personalityKeywords = value;
              }
              this.onTextFieldChange();
            })

          // 角色与用户的关系
          this.fieldLabel('角色与用户的关系', '')
          TextInput({
            placeholder: '例:旅伴、师徒、初识陌生人...',
            text: this.viewModel !== null ? this.viewModel!.relationshipWithUser : ''
          })
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(48)
            .width('100%')
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              if (this.viewModel !== null) {
                this.viewModel!.relationshipWithUser = value;
              }
              this.onTextFieldChange();
            })

          // 对话风格
          this.fieldLabel('对话风格', '')
          TextInput({
            placeholder: '例:简短冷峻,偶尔幽默',
            text: this.viewModel !== null ? this.viewModel!.speechStyle : ''
          })
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(48)
            .width('100%')
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              if (this.viewModel !== null) {
                this.viewModel!.speechStyle = value;
              }
              this.onTextFieldChange();
            })
        }
        .width('100%')
        .padding($r('app.float.app_spacing_16'))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
        .margin({
          left: $r('app.float.app_spacing_12'),
          right: $r('app.float.app_spacing_12'),
          top: $r('app.float.app_spacing_12')
        })

        // ===== 卡片 3:生成偏好 =====
        Column() {
          this.cardHeader('生成偏好', false, '控制生成内容的范围')

          this.toggleRow('生成世界书', '生成 character_book 角色世界书',
            this.viewModel !== null ? this.viewModel!.generateCharacterBook : false,
            (v: boolean) => this.toggleGenerateBook(v))

          this.toggleRow('生成多个开场白', '生成多个差异化的 alternate_greetings',
            this.viewModel !== null ? this.viewModel!.generateMultipleGreetings : false,
            (v: boolean) => this.toggleGenerateGreetings(v))

          this.toggleRow('生成对话示例', '生成 mes_example 体现角色语气',
            this.viewModel !== null ? this.viewModel!.generateMesExample : true,
            (v: boolean) => this.toggleGenerateMesExample(v))
        }
        .width('100%')
        .padding($r('app.float.app_spacing_16'))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
        .margin({
          left: $r('app.float.app_spacing_12'),
          right: $r('app.float.app_spacing_12'),
          top: $r('app.float.app_spacing_12')
        })

        // ===== 错误提示 =====
        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_16'),
              right: $r('app.float.app_spacing_16'),
              top: $r('app.float.app_spacing_12'),
              bottom: $r('app.float.app_spacing_12')
            })
            .borderRadius($r('app.float.app_radius_lg'))
            .margin({
              left: $r('app.float.app_spacing_12'),
              right: $r('app.float.app_spacing_12'),
              top: $r('app.float.app_spacing_12')
            })
        }

        // 底部留白(为固定操作栏腾出空间)
        Row()
          .height($r('app.float.app_spacing_24'))
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }

  // ===== 底部固定操作栏 =====

  @Builder
  bottomActionBar() {
    Row() {
      Button('放弃')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .layoutWeight(1)
        .onClick(() => {
          this.onDiscardClick();
        })

      Button('生成角色卡')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .layoutWeight(2)
        .margin({ left: $r('app.float.app_spacing_12') })
        .onClick(() => {
          this.onGenerateClick();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: this.navigationBarHeight + 12
    })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }

  // ===== 生成中视图 =====

  @Builder
  generatingView() {
    Column() {
      LoadingProgress()
        .width(48)
        .height(48)
        .color(ThemePalette.accentColor(this.effectiveTheme))
        .margin({ top: 80 })

      Text('正在生成角色卡...')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .margin({ top: 16 })

      Text('AI 正在根据你的创意生成标准 Tavern Card V2 JSON,生成期间不会写入数据库')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .width('80%')
        .margin({ top: 8 })

      // 流式累积预览(只显示已接收的字符数,不显示完整 JSON 内容)
      if (this.viewModel !== null && this.viewModel!.accumulatedText.length > 0) {
        Text('已接收 ' + this.viewModel!.accumulatedText.length.toString() + ' 字符')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ top: 8 })
      }

      // 停止按钮
      Button('停止生成')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .fontColor($r('app.color.app_danger'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('60%')
        .margin({ top: 32 })
        .onClick(() => {
          this.onStopClick();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 32, bottom: 32 })
  }

  // ===== 隐私提示对话框 =====

  @Builder
  privacyDialog() {
    Stack() {
      Column() {
        Column() {
          Text('隐私提示')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 12 })

          Text('你的角色创意将发送到当前聊天配置的 AI 模型,由该模型生成角色卡草案。\n\n请确保你已在模型设置中配置好 Provider 与 API Key。ArkTavern 不会记录你的 API Key、完整创意内容或完整模型响应。')
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 20 })

          Row() {
            Button('取消')
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.cancelPrivacy();
              })

            Button('我已了解,开始生成')
              .fontSize(14)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmPrivacy();
              })
          }
          .width('100%')
        }
        .width('85%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }

  // ===== 通用 Builder =====

  /** 卡片标题:主标题 + 副标题 + 必填标记 */
  @Builder
  cardHeader(title: string, required: boolean, subtitle: string) {
    Column() {
      Row() {
        Text(title)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        if (required) {
          Text(' *')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontColor($r('app.color.app_danger'))
        }
      }
      .width('100%')

      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: $r('app.float.app_spacing_4') })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: $r('app.float.app_spacing_12') })
  }

  /** 字段标签:label + 可选辅助 hint,紧贴输入框上方 */
  @Builder
  fieldLabel(label: string, hint: string) {
    Column() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')

      if (hint.length > 0) {
        Text(hint)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: $r('app.float.app_spacing_4') })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: $r('app.float.app_spacing_12'), bottom: $r('app.float.app_spacing_4') })
  }

  /** 开关行(不带左右 padding,适合卡片内部使用) */
  @Builder
  toggleRow(title: string, subtitle: string, value: boolean, onChange: (v: boolean) => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
        .onChange((v: boolean) => onChange(v))
    }
    .width('100%')
    .padding({
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 加载视图 =====

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(ThemePalette.accentColor(this.effectiveTheme))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
