/**
 * AddCharacterPage 添加角色入口页
 *
 * 重新设计角色卡 Tab 右上角"导入"进入的页面:
 * - 顶部:返回 + 标题"添加角色" + 分段(新建角色 / 文件导入)
 * - 默认打开"新建角色"分段
 *
 * 新建角色分段:
 * - 居中显示一个主要入口"开始新建"
 * - 点击进入全屏 CharacterEditPage(不传 characterId,新建模式)
 * - 不再使用旧的底部新建角色弹窗 / CharacterListPage 紧凑表单
 *
 * 文件导入分段:
 * - 点击区域调系统 DocumentViewPicker
 * - 复用 CharacterListViewModel.startImportFile + confirmImport 流程
 * - 支持 PNG / JSON / 现有 SillyTavern 角色卡格式
 * - 导入成功后返回角色卡首页,新角色立即显示(通过 characterListVersion 信号)
 * - 取消文件选择不修改任何内容
 *
 * 不修改:
 * - PNG / JSON 解析
 * - Tavern Card 格式
 * - 数据库结构
 * - 图片保存逻辑
 *
 * 旧入口处理:
 * - CharacterListPage 文件保留(其他流程仍可能使用)
 * - 但本页不再打开 CharacterListPage,新建/导入直接在本页完成
 */

import { CharacterListViewModel } from '../viewmodels/CharacterListViewModel';
import { AppServices } from '../services/AppServices';
import { picker } from '@kit.CoreFileKit';
import { promptAction, router } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';

const TAB_NEW: number = 0;
const TAB_IMPORT: number = 1;
const TAB_AI: number = 2;

@Entry
@Component
struct AddCharacterPage {
  @State activeTab: number = TAB_NEW;
  @State viewModel: CharacterListViewModel | null = null;
  @State isInitializing: boolean = true;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const charService = AppServices.getCharacterService();
      const vm: CharacterListViewModel = new CharacterListViewModel(charService);
      this.viewModel = vm;
      // 不调 vm.load():本页不需要角色列表,只用 ViewModel 的导入能力
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      const msg: string = e instanceof Error ? e.message : '初始化失败';
      promptAction.showToast({
        message: msg,
        duration: 2000
      });
    }
  }

  /** 返回上一页 */
  private handleBack(): void {
    router.back();
  }

  /** 跳转到全屏 CharacterEditPage 新建角色(不传 characterId) */
  private startNewCharacter(): void {
    router.pushUrl({ url: 'pages/CharacterEditPage' });
  }

  /** 跳转到 AI 制作角色卡页面 */
  private startAiMaker(): void {
    router.pushUrl({ url: 'pages/AiCharacterMakerPage' });
  }

  /** 跳转到“导入已有卡·AI 改造”页面 */
  private startCardRevise(): void {
    router.pushUrl({ url: 'pages/AiCardRevisePage' });
  }

  /** 打开系统文件选择器(PNG / JSON) */
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
      // 用户取消或系统错误,静默处理(不修改任何内容)
      return;
    }
    // 用户取消选择
    if (uris.length === 0) {
      return;
    }
    try {
      await this.viewModel.startImportFile(uris[0]);
      if (this.viewModel.importError.length > 0) {
        promptAction.showToast({
          message: this.viewModel.importError,
          duration: 2000
        });
      }
    } catch (e) {
      promptAction.showToast({
        message: '导入失败',
        duration: 2000
      });
    }
  }

  /** 确认导入:复用 CharacterListViewModel.confirmImport */
  private async confirmImport(): Promise<void> {    if (this.viewModel === null) {
      return;
    }
    try {
      await this.viewModel.confirmImport();
      if (this.viewModel.importError.length > 0) {
        promptAction.showToast({
          message: this.viewModel.importError,
          duration: 2000
        });
        return;
      }
      // 导入成功:通知角色卡首页刷新 + 返回
      this.bumpListVersion();
      this.handleBack();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : '保存失败';
      promptAction.showToast({
        message: msg,
        duration: 2000
      });
    }
  }

  /** 取消导入预览 */
  private cancelImport(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel.cancelImport();
  }

  /** 返回键处理:导入预览弹窗显示时,优先取消预览;否则正常返回 */
  onBackPressed(): boolean {
    if (this.viewModel !== null && this.viewModel!.showImportPreview) {
      this.cancelImport();
      return true;
    }
    return false;
  }

  /** 递增 characterListVersion,触发 CharacterRootView 刷新 */
  private bumpListVersion(): void {
    const v: number = AppStorage.get<number>('characterListVersion') ?? 0;
    AppStorage.setOrCreate<number>('characterListVersion', v + 1);
  }

  /** 格式化来源格式标签 */
  private formatSourceLabel(sourceFormat: string): string {
    if (sourceFormat === 'arktavern_v1') {
      return 'ArkTavern v1';
    }
    if (sourceFormat === 'chara_card_v2') {
      return 'Character Card V2';
    }
    if (sourceFormat === 'chara_card_v3') {
      return 'Character Card V3';
    }
    return sourceFormat;
  }

  build() {
    Stack() {
      Column() {
        this.topBar()

        // 错误提示
        if (this.viewModel !== null && this.viewModel!.importError.length > 0) {
          Text(this.viewModel!.importError)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_20'),
              right: $r('app.float.app_spacing_20'),
              top: $r('app.float.app_spacing_4'),
              bottom: $r('app.float.app_spacing_4')
            })
        }

        if (this.isInitializing) {
          this.loadingView()
        } else {
          this.contentArea()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 导入预览弹窗:浮层,覆盖整个页面(包括顶栏),居中显示
      if (this.viewModel !== null
        && this.viewModel!.showImportPreview
        && this.viewModel!.previewCard !== null) {
        this.importPreviewDialog()
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

      Text($r('app.string.add_character_title'))
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

    // 分段切换
    Row() {
      Text($r('app.string.add_character_tab_new'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(this.activeTab === TAB_NEW ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === TAB_NEW
          ? $r('app.color.app_on_accent')
          : ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(this.activeTab === TAB_NEW
          ? ThemePalette.accentColor(this.effectiveTheme)
          : Color.Transparent)
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .onClick(() => { this.activeTab = TAB_NEW; })

      Text($r('app.string.add_character_tab_ai'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(this.activeTab === TAB_AI ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === TAB_AI
          ? $r('app.color.app_on_accent')
          : ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(this.activeTab === TAB_AI
          ? ThemePalette.accentColor(this.effectiveTheme)
          : Color.Transparent)
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .margin({ left: 4 })
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .onClick(() => { this.activeTab = TAB_AI; })

      Text($r('app.string.add_character_tab_import'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(this.activeTab === TAB_IMPORT ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === TAB_IMPORT
          ? $r('app.color.app_on_accent')
          : ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(this.activeTab === TAB_IMPORT
          ? ThemePalette.accentColor(this.effectiveTheme)
          : Color.Transparent)
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32)
        .padding({ left: 12, right: 12 })
        .margin({ left: 4 })
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .onClick(() => { this.activeTab = TAB_IMPORT; })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }

  // ===== 主内容区 =====

  @Builder
  contentArea() {
    if (this.activeTab === TAB_NEW) {
      this.newCharacterTab()
    } else if (this.activeTab === TAB_AI) {
      this.aiCharacterTab()
    } else {
      this.importTab()
    }
  }

  // ===== AI 制作分段 =====

  @Builder
  aiCharacterTab() {
    Column() {
      Column() {
        Text($r('app.string.add_character_ai_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .textAlign(TextAlign.Center)

        Text($r('app.string.add_character_ai_desc'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 8 })
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      Button($r('app.string.add_character_start_ai'))
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .width('80%')
        .margin({ top: 32 })
        .onClick(() => {
          this.startAiMaker();
        })

      Button('导入已有卡 · AI 改造')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .width('80%')
        .margin({ top: 12 })
        .onClick(() => {
          this.startCardRevise();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({
      left: $r('app.float.app_spacing_24'),
      right: $r('app.float.app_spacing_24'),
      top: $r('app.float.app_spacing_48'),
      bottom: 100
    })
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 新建角色分段 =====

  @Builder
  newCharacterTab() {
    Column() {
      Column() {
        Text($r('app.string.add_character_new_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .textAlign(TextAlign.Center)

        Text($r('app.string.add_character_new_desc'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 8 })
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      Button($r('app.string.add_character_start_new'))
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .width('80%')
        .margin({ top: 32 })
        .onClick(() => {
          this.startNewCharacter();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({
      left: $r('app.float.app_spacing_24'),
      right: $r('app.float.app_spacing_24'),
      top: $r('app.float.app_spacing_48'),
      bottom: 100
    })
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 文件导入分段 =====

  @Builder
  importTab() {
    Column() {
      // 文件选择区域(可点击)
      Button() {
        Column() {
          Text($r('app.string.add_character_import_icon'))
            .fontSize(48)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          Text($r('app.string.add_character_import_title'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)

          Text($r('app.string.add_character_import_desc'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ top: 6 })
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({
          top: $r('app.float.app_spacing_48'),
          bottom: $r('app.float.app_spacing_48'),
          left: $r('app.float.app_spacing_24'),
          right: $r('app.float.app_spacing_24')
        })
        .alignItems(HorizontalAlign.Center)
      }
      .type(ButtonType.Capsule)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_lg'))
      .width('100%')
      .onClick(() => {
        this.openImportPicker();
      })

      Text($r('app.string.add_character_import_formats'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 16 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      top: $r('app.float.app_spacing_32'),
      bottom: 100
    })
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 导入预览弹窗 =====

  @Builder
  importPreviewDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.character_import_preview'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 12 })

          // PNG 头像预览
          if (this.viewModel!.isPngImport && this.viewModel!.previewPngUri.length > 0) {
            Image(this.viewModel!.previewPngUri)
              .width(80)
              .height(80)
              .borderRadius(12)
              .objectFit(ImageFit.Cover)
              .margin({ bottom: 12 })
          }

          this.importPreviewField('名称', this.viewModel!.previewCard!.name, true)
          this.importPreviewField('描述', this.viewModel!.previewCard!.description, false)
          this.importPreviewField('性格', this.viewModel!.previewCard!.personality, false)
          this.importPreviewField('场景', this.viewModel!.previewCard!.scenario, false)
          this.importPreviewField('开场白', this.viewModel!.previewCard!.firstMessage, false)
          this.importPreviewField('System Prompt', this.viewModel!.previewCard!.systemPrompt, false)

          // 来源格式
          Text('来源格式: ' + this.formatSourceLabel(this.viewModel!.previewCard!.sourceFormat))
            .fontSize(12)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 8, bottom: 16 })

          if (this.viewModel!.importError.length > 0) {
            Text(this.viewModel!.importError)
              .fontSize(13)
              .fontColor($r('app.color.app_danger'))
              .width('100%')
              .margin({ bottom: 12 })
          }

          Row() {
            Button($r('app.string.character_import_cancel'))
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.cancelImport();
              })

            Button($r('app.string.character_import_confirm'))
              .fontSize(14)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .margin({ left: 12 })
              .enabled(!this.viewModel!.importing)
              .onClick(() => {
                this.confirmImport();
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
    // 不设 onClick:点击外部遮罩不取消,只能通过"取消"按钮或返回键取消
  }

  @Builder
  importPreviewField(label: string, value: string, isRequired: boolean) {    if (value.length > 0 || isRequired) {
      Column() {
        Row() {
          Text(label)
            .fontSize(12)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
          if (isRequired) {
            Text(' *')
              .fontSize(12)
              .fontColor($r('app.color.app_danger'))
          }
        }
        .width('100%')

        Text(value.length > 0 ? value : '(空)')
          .fontSize(13)
          .fontColor(value.length > 0
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2, bottom: 8 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
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
