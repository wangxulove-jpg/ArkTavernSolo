/**
 * AiCardRevisePage 导入角色卡→看详情→提修改建议→AI 重新生成
 *
 * 流程:
 * 导入(JSON/PNG)→ 解析并展示详情 → 输入修改建议 → AI 基于原卡+建议重新生成
 * → 生成成功写入 AppStorage(pendingAiCard)并跳转 AiCharacterPreviewPage 预览/保存
 *
 * 复用:
 * - CharacterService:导入解析(quality 与 AddCharacterPage 一致)
 * - AiCharacterGenerationService.reviseCharacterCard:基于原卡+建议生成
 * - AiCharacterPreviewPage:承接生成结果的可编辑预览页(可保存/单字段重生成/导出)
 *
 * 不直接:
 * - 调用 network/、ModelService(经 ViewModel)
 * - 操作 RDB
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { ModelService } from '../services/ModelService';
import { AiCharacterGenerationService } from '../services/ai/AiCharacterGenerationService';
import { AiCardReviseViewModel } from '../viewmodels/AiCardReviseViewModel';
import { ParsedCharacterCard } from '../parser/CharacterCardJsonParser';
import { ThemePalette } from '../theme/ThemePalette';

/** 快捷修改建议预设 */
interface suggestionPreset {
  label: string;
  text: string;
}

@Entry
@Component
struct AiCardRevisePage {
  @State viewModel: AiCardReviseViewModel | null = null;
  @State isInitializing: boolean = true;

  /** 快捷修改建议预设(点击即追加到建议框) */
  private presetSuggestions: suggestionPreset[] = [
    {
      label: '补全缺失字段',
      text: '请补全缺失或不完整的字段(personality 人格、scenario 场景、mes_example 对话示例、post_history_instructions 等),让角色卡结构完整。'
    },
    {
      label: '生成合适开场白',
      text: '请生成一个贴合角色设定的开场白(first_mes),替换当前不合适或占位性的开场白。'
    },
    {
      label: '清理代码/脚本输出',
      text: '请检查角色卡内容,避免把代码、正则脚本、指令等大量技术性文本直接输出到聊天界面;需要表达的规则用自然语言说明。'
    },
    {
      label: '丰富性格与语气',
      text: '请丰富 personality 与对话风格,使角色说话方式、语气、口癖更加鲜明有辨识度。'
    },
    {
      label: '开场白：状态折叠栏',
      text: '重写 first_mes,并在结尾加一个可折叠状态栏:用 <details><summary>当前状态</summary>属性/装备/位置等状态信息</details> 包裹(平时只显示标题行,点击才展开)。并把"每次回复都要持续输出并更新同一个格式的折叠状态栏,放在正文末尾,位置结构保持一致"写进 system_prompt 或 post_history_instructions,确保后续每次对话都保留状态栏,不只出现在开场白。'
    },
    {
      label: '开场白：分支选项',
      text: '重写 first_mes:开头一段贴合角色与场景的开局描写后,生成 3~5 个互补的剧情起始选项,用 <branches>\n[选项一]\n[选项二]\n[选项三]\n</branches> 包裹,每行一个选项,让用户点击选择如何开局;并在 system_prompt / post_history_instructions 要求角色在后续每次行动后继续用 <branches> 提供下一组选项,延续这种交互形式。'
    },
    {
      label: '开场白：隐藏引导',
      text: '重写 first_mes:把需要引导 AI 的幕后说明(如世界观、节奏、判定规则)用 <思考>…</思考> 或 <变量思考>…</变量思考> 包裹(不会显示给用户),正文只保留玩家能看到的内容,末尾用 <branches> 收 3~5 个开局选项,并让角色后续持续用 <branches> 延续选项交互。'
    },
    {
      label: '开场白：轻量面板',
      text: '重写 first_mes:把状态/信息做成轻量 HTML 结构(<div>/<p>/<span style="color:...">/<br>/<hr>),App 会渲染成可读排版(标签转成换行与分隔线);不要写依赖背景色的完整网页,避免正文杂乱。'
    }
  ];
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const appServices: AppServices = AppServices.getInstance();
      const modelService: ModelService = appServices.modelService;
      const ctx: common.Context = getContext(this) as common.Context;
      const prefs: AppPreferences = new AppPreferences();
      await prefs.initialize(ctx);
      const generationService: AiCharacterGenerationService =
        new AiCharacterGenerationService(modelService);
      const vm: AiCardReviseViewModel = new AiCardReviseViewModel(
        AppServices.getCharacterService(),
        generationService
      );
      vm.setOnReviseComplete((success: boolean, errorMessage: string) => {
        this.onReviseComplete(success, errorMessage);
      });
      this.viewModel = vm;
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      promptAction.showToast({ message: '初始化失败', duration: 2000 });
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
    }
  }

  private handleBack(): void {
    router.back();
  }

  /** 打开文件选择器(限制 .png / .json) */
  private async openImportPicker(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    let uris: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.png', '.json'];
      uris = await documentPicker.select(options);
    } catch (e) {
      return;
    }
    if (uris.length === 0) {
      return;
    }
    try {
      await this.viewModel!.startImportFile(uris[0]);
      if (this.viewModel!.importError.length > 0) {
        promptAction.showToast({ message: this.viewModel!.importError, duration: 2000 });
      }
    } catch (e) {
      promptAction.showToast({ message: '导入失败', duration: 2000 });
    }
  }

  /** 点击“让 AI 重新生成” */
  private onReviseClick(): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.parsedCard === null) {
      promptAction.showToast({ message: '请先导入一张角色卡', duration: 2000 });
      return;
    }
    if (this.viewModel!.suggestions.trim().length === 0) {
      promptAction.showToast({ message: '请输入修改建议', duration: 2000 });
      return;
    }
    this.viewModel!.startRevise();
  }

  /** 生成完成回调:成功跳预览页,失败 toast */
  private onReviseComplete(success: boolean, errorMessage: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (success) {
      router.pushUrl({ url: 'pages/AiCharacterPreviewPage' });
    } else if (this.viewModel!.aiError.length > 0) {
      promptAction.showToast({ message: this.viewModel!.aiError, duration: 2500 });
    }
  }

  private goBack(): void {
    this.handleBack();
  }

  /** 点击快捷建议:把预设文本追加到建议框 */
  private applyPreset(text: string): void {
    if (this.viewModel === null) {
      return;
    }
    const current: string = this.viewModel!.suggestions.trim();
    const sep: string = current.length > 0 ? '\n' : '';
    this.viewModel!.suggestions = current + sep + text;
  }

  build() {
    Stack() {
      Column() {
        this.topBar()
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.viewModel !== null && this.viewModel!.aiWorking) {
          this.generatingView()
        } else {
          this.bodyView()
          this.bottomActionBar()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
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
        .onClick(() => this.goBack())

      Text('导入角色卡 · AI 改造')
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

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

  // ===== 主体 =====

  @Builder
  bodyView() {
    Scroll() {
      Column() {
        // ===== 步骤 1:导入 =====
        Column() {
          this.cardHeader('1. 导入角色卡', false, '支持 Tavern Card PNG 或 JSON,导入后自动解析')
          Button('选择角色卡文件(.png / .json)')
            .fontSize($r('app.float.app_font_body'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius($r('app.float.app_radius_md'))
            .height(46)
            .width('100%')
            .onClick(() => this.openImportPicker())
        }
        .width('100%')
        .padding($r('app.float.app_spacing_16'))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
        .margin({
          top: $r('app.float.app_spacing_12')
        })

        // ===== 步骤 2:卡详情 =====
        if (this.viewModel !== null && this.viewModel!.parsedCard !== null) {
          Column() {
            this.cardHeader('2. 角色卡详情', false, 'AI 将以此为背景信息进行改造')
            this.detailField('名称', this.viewModel!.parsedCard!.name)
            this.detailField('描述', this.viewModel!.parsedCard!.description)
            this.detailField('性格', this.viewModel!.parsedCard!.personality)
            this.detailField('场景', this.viewModel!.parsedCard!.scenario)
            this.detailField('开场白', this.viewModel!.parsedCard!.firstMessage)
            this.detailField('System Prompt', this.viewModel!.parsedCard!.systemPrompt)
            this.detailField('对话示例', this.viewModel!.parsedCard!.mesExample)
            this.metaLine('备用开场白', this.viewModel!.parsedCard!.alternateGreetings.length)
            this.metaLine('标签', this.viewModel!.parsedCard!.tags.length)
            if (this.viewModel!.parsedCard!.characterBook !== null) {
              this.metaLine('世界书条目', this.viewModel!.parsedCard!.characterBook!.entries.length)
            }
          }
          .width('100%')
          .padding($r('app.float.app_spacing_16'))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_lg'))
          .margin({
            top: $r('app.float.app_spacing_12')
          })
        }

        // ===== 步骤 3:修改建议 =====
        if (this.viewModel !== null && this.viewModel!.parsedCard !== null) {
          Column() {
            this.cardHeader('3. 修改建议', false, '可点选快捷建议自动填入,也可自由输入;未提及部分将尽量保持原样,空缺字段可补全')
            Text('快捷建议')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.presetSuggestions, (item: suggestionPreset, index: number) => {
                Button(item.label)
                  .fontSize(13)
                  .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                  .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                  .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
                  .borderRadius(16)
                  .height(32)
                  .padding({ left: 12, right: 12 })
                  .margin({ right: 8, top: 8 })
                  .onClick(() => this.applyPreset(item.text))
              }, (item: suggestionPreset) => item.label)
            }
            .width('100%')
            .margin({ top: 4 })
            TextArea({
              placeholder: '例如:把性格改得更冷酷,开场白换成咖啡馆偶遇,并补充末世细节...',
              text: this.viewModel!.suggestions
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
              .onChange((value: string) => {
                if (this.viewModel !== null) {
                  this.viewModel!.suggestions = value;
                }
              })

            // ===== 世界书修改开关(仅当卡带世界书时显示) =====
            if (this.viewModel!.parsedCard!.characterBook !== null) {
              Divider()
                .height(1)
                .color(ThemePalette.dividerColor(this.effectiveTheme))
                .margin({ top: 12, bottom: 4 })
              Row() {
                Column() {
                  Text('同时让 AI 修改世界书')
                    .fontSize($r('app.float.app_font_body'))
                    .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  Text('开启后会把当前世界书发给 AI,按建议修改对应条目(未提及条目尽量保持)')
                    .fontSize(11)
                    .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.viewModel!.includeWorldbook })
                  .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
                  .onChange((isOn: boolean) => {
                    if (this.viewModel !== null) {
                      this.viewModel!.includeWorldbook = isOn;
                    }
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .margin({ top: 8 })
            }
          }
          .width('100%')
          .padding($r('app.float.app_spacing_16'))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_lg'))
          .margin({
            top: $r('app.float.app_spacing_12')
          })
        }

        // ===== 错误提示 =====
        if (this.viewModel !== null && this.viewModel!.importError.length > 0) {
          Text(this.viewModel!.importError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }
        if (this.viewModel !== null && this.viewModel!.aiError.length > 0) {
          Text(this.viewModel!.aiError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }

        Row().height($r('app.float.app_spacing_24')).width('100%')
      }
      .width('100%')
      .padding({ left: $r('app.float.app_spacing_12'), right: $r('app.float.app_spacing_12') })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }

  // ===== 底部操作栏 =====

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
        .onClick(() => this.goBack())

      Button('让 AI 重新生成')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .layoutWeight(2)
        .margin({ left: $r('app.float.app_spacing_12') })
        .onClick(() => this.onReviseClick())
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

      Text('正在根据你的建议重新生成角色卡...')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .margin({ top: 16 })

      Text('AI 以原卡为背景,只修改你建议的部分;期间不写入数据库')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .width('80%')
        .margin({ top: 8 })

      if (this.viewModel !== null && this.viewModel!.aiProgressChars > 0) {
        Text('已接收 ' + this.viewModel!.aiProgressChars.toString() + ' 字符')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ top: 8 })
      }

      Button('停止生成')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .fontColor($r('app.color.app_danger'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('60%')
        .margin({ top: 32 })
        .onClick(() => {
          if (this.viewModel !== null) {
            this.viewModel!.cancelRevise();
          }
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 32, bottom: 32 })
  }

  // ===== 通用 Builder =====

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

  /** 详情字段:标签 + 内容(最多 3 行) */
  @Builder
  detailField(label: string, value: string) {
    if (value.trim().length > 0) {
      Column() {
        Text(label)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
        Text(value)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
          .margin({ top: 2 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: $r('app.float.app_spacing_8') })
    }
  }

  /** 元数据行(数组计数) */
  @Builder
  metaLine(label: string, count: number) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      Text(count.toString())
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .margin({ left: 8 })
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_8') })
  }

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