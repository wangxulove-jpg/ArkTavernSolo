/**
 * MarketDetailPage 市场角色详情页
 *
 * 从市场列表点击单张角色卡进入此页,展示完整远程角色信息并提供导入入口。
 *
 * 路由参数:{ baseJson: string } — MarketCharacter 的 JSON 字符串
 *
 * 页面结构:
 * - 顶部:返回 + 标题 + 中英文切换 + 导入按钮
 * - 内容:头像 / 名称 / 作者 / 标签 / 元信息 / 描述 / 创作者备注 / 开场白预览 / 备用开场白数量 / 对话示例 / 世界书条目 / 卡版本
 * - 底部:导入按钮(固定)
 *
 * 弹窗:
 * - NSFW 进入提示
 * - 重复确认(取消 / 仍导入为副本 / 查看本地角色)
 * - 导入成功(查看角色 / 新建对话 / 继续浏览)
 *
 * 本地化:
 * - 所有 UI 文案通过 $r('app.string.market_*') 资源引用
 * - 不使用 String($r(...)) / 资源字符串拼接 / as string
 * - 含动态名称的消息使用 Span 组合显示
 *
 * 翻译:
 * - 顶部"中文/原文"切换按钮,默认显示中文(若已翻译)
 * - 翻译开关未开启或翻译失败时,按钮隐藏
 * - 翻译内容仅用于展示,不影响导入后的角色卡数据
 *
 * 不直接:
 * - 调用 network / Provider
 * - 重新实现角色卡解析
 * - 操作文件系统
 */

import { AppServices } from '../services/AppServices';
import { MarketDetailViewModel } from '../viewmodels/MarketDetailViewModel';
import {
  MarketImportService,
  MarketImportStatus
} from '../services/market/MarketImportService';
import { MarketCharacter } from '../models/MarketCharacter';
import { MarketCharacterAvatar } from '../components/MarketCharacterAvatar';
import { EmptyStateView } from '../components/EmptyStateView';
import { router, promptAction } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';

@Entry
@Component
struct MarketDetailPage {
  @State viewModel: MarketDetailViewModel | null = null;
  @State isLoading: boolean = true;
  @State errorMessage: string = '';
  /** NSFW 进入提示弹窗(本地状态,基于 ViewModel.showNsfwEntryDialog 同步) */
  @State showNsfwEntryDialog: boolean = false;
  /** 重复确认弹窗 */
  @State showDuplicateDialog: boolean = false;
  /** 导入成功弹窗 */
  @State showImportSuccessDialog: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private readyHandled: boolean = false;

  async aboutToAppear(): Promise<void> {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;
    try {
      await AppServices.whenReady();
      const importService: MarketImportService | null = AppServices.getMarketImportService();
      if (importService === null) {
        this.errorMessage = '';
        this.isLoading = false;
        return;
      }
      const translationService = AppServices.getMarketTranslationService();
      const vm: MarketDetailViewModel = new MarketDetailViewModel(
        AppServices.getMarketService(),
        importService,
        translationService
      );
      this.viewModel = vm;

      // 解析路由参数
      const params: Record<string, Object> = router.getParams() as Record<string, Object>;
      const baseJsonObj: Object | undefined = params['baseJson'];
      if (baseJsonObj === undefined) {
        this.errorMessage = '';
        this.isLoading = false;
        return;
      }
      const baseJson: string = String(baseJsonObj);
      const parsed: Object = JSON.parse(baseJson);
      const base: MarketCharacter = parsed as MarketCharacter;
      await vm.load(base);
      this.syncDialogState();
      this.isLoading = false;
    } catch (e) {
      this.errorMessage = String(e);
      this.isLoading = false;
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose();
    }
  }

  onBackPress(): boolean {
    router.back();
    return true;
  }

  /**
   * 同步 ViewModel 弹窗状态到本地 @State。
   */
  private syncDialogState(): void {
    if (this.viewModel === null) {
      return;
    }
    this.showNsfwEntryDialog = this.viewModel.showNsfwEntryDialog;
    this.showDuplicateDialog = this.viewModel.showDuplicateDialog;
    this.showImportSuccessDialog = this.viewModel.showImportSuccessDialog;
  }

  build() {
    Column() {
      this.topBar()

      if (this.isLoading) {
        this.loadingView()
      } else if (this.errorMessage.length > 0) {
        this.errorView($r('app.string.market_detail_init_failed_prefix'), this.errorMessage)
      } else if (this.viewModel === null || this.viewModel!.detail === null) {
        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          this.errorView($r('app.string.market_detail_load_failed_prefix'), this.viewModel!.errorMessage)
        } else {
          this.loadingView()
        }
      } else {
        this.contentArea()
      }

      // 弹窗(覆盖整页)
      if (this.showNsfwEntryDialog) {
        this.nsfwEntryDialog()
      }
      if (this.showDuplicateDialog) {
        this.duplicateDialog()
      }
      if (this.showImportSuccessDialog) {
        this.importSuccessDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== 顶部栏 =====

  @Builder
  topBar(): void {
    Row() {
      Button($r('app.string.market_detail_back'))
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .height(40)
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          router.back();
        })

      Blank()

      Text(this.resolveTitle())
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      Blank()

      // 中英文切换按钮(仅在已翻译时显示)
      if (this.shouldShowLanguageToggle()) {
        Button(this.resolveLanguageToggleLabel())
          .fontSize($r('app.float.app_font_caption'))
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(40)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel!.toggleLanguage();
            }
          })
      } else {
        // 占位,保持标题居中
        Column().width(40)
      }
    }
    .width('100%')
    .padding({ left: 8, right: 12, top: this.statusBarHeight + 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }

  /**
   * 解析顶部标题(优先用角色名)。
   */
  private resolveTitle(): string {
    if (this.viewModel !== null && this.viewModel!.base !== null) {
      return this.viewModel!.base!.name;
    }
    return '';
  }

  /**
   * 是否显示中英文切换按钮(仅在翻译开关已开启且有翻译结果时显示)。
   */
  private shouldShowLanguageToggle(): boolean {
    return this.viewModel !== null
      && this.viewModel!.translateEnabled
      && this.viewModel!.detailTranslation !== null;
  }

  /**
   * 中英文切换按钮文字。
   * 当前显示中文时,按钮显示"查看原文";
   * 当前显示原文时,按钮显示"中文"。
   */
  private resolveLanguageToggleLabel(): ResourceStr {
    if (this.viewModel === null) {
      return $r('app.string.market_view_chinese');
    }
    if (this.viewModel!.shouldShowChinese()) {
      return $r('app.string.market_view_original');
    }
    return $r('app.string.market_view_chinese');
  }

  // ===== 内容区 =====

  @Builder
  contentArea(): void {
    Scroll() {
      Column() {
        // 头像(大图)
        this.avatarSection()

        // 名称 + 作者
        this.titleSection()

        // 元信息(评分 / 下载量 / 更新时间)
        this.metaSection()

        // 标签
        this.tagsSection()

        // 描述
        this.descriptionSection()

        // 创作者备注
        this.creatorNotesSection()

        // 开场白预览
        this.firstMessageSection()

        // 其他信息(备用开场白数量 / 对话示例 / 世界书条目 / 卡版本)
        this.statsSection()

        // 底部留白(避开固定按钮)
        Column().width('100%').height(120)
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16')
      })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)

    // 固定底部按钮
    this.bottomActionBar()
  }

  @Builder
  avatarSection(): void {
    Column() {
      MarketCharacterAvatar({
        item: this.viewModel!.detail!.base,
        imgWidth: 160,
        imgHeight: 200,
        imgBorderRadius: 16,
        fallbackFontSize: 48,
        allowLoad: this.resolveAllowImageLoad()
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: $r('app.float.app_spacing_16'), bottom: $r('app.float.app_spacing_12') })
  }

  /**
   * 计算头像是否允许加载。
   * NSFW 角色在 NSFW 警告弹窗未关闭前不加载大图。
   */
  private resolveAllowImageLoad(): boolean {
    if (this.viewModel === null || this.viewModel!.detail === null) {
      return true;
    }
    const isNsfw: boolean = this.viewModel!.detail!.base.nsfw;
    const dialogShowing: boolean = this.viewModel!.showNsfwEntryDialog;
    return !isNsfw || !dialogShowing;
  }

  @Builder
  titleSection(): void {
    Column() {
      Text(this.resolveDisplayName())
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .width('100%')

      if (this.viewModel!.detail!.base.creator.length > 0) {
        Row() {
          Text($r('app.string.market_creator_prefix'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Text(this.viewModel!.detail!.base.creator)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        }
        .margin({ top: 4 })
        .justifyContent(FlexAlign.Center)
      }

      // 来源标识
      Row() {
        Text(this.viewModel!.detail!.base.providerId)
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })

        if (this.viewModel!.detail!.base.nsfw) {
          Text('NSFW')
            .fontSize(10)
            .fontColor($r('app.color.app_danger'))
            .backgroundColor('#FFE5E5')
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 6 })
        }

        if (this.viewModel!.detail!.base.hasCharacterBook) {
          Text($r('app.string.market_contains_lorebook'))
            .fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 6 })
        }
      }
      .margin({ top: 8 })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 解析显示名称(翻译优先,无翻译显示原文)。
   */
  private resolveDisplayName(): string {
    if (this.viewModel === null || this.viewModel!.detail === null) {
      return '';
    }
    if (this.viewModel!.shouldShowChinese() && this.viewModel!.detailTranslation !== null) {
      const t: string = this.viewModel!.detailTranslation!.name;
      if (t.length > 0) {
        return t;
      }
    }
    return this.viewModel!.detail!.base.name;
  }

  @Builder
  metaSection(): void {
    Row() {
      // 评分
      if (this.viewModel!.detail!.base.rating >= 0) {
        Column() {
          Text($r('app.string.market_detail_rating'))
            .fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          Text(this.viewModel!.detail!.base.rating.toFixed(1))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
      }

      // 下载量
      if (this.viewModel!.detail!.base.downloadCount >= 0) {
        Column() {
          Text($r('app.string.market_detail_download'))
            .fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          Text(this.formatCount(this.viewModel!.detail!.base.downloadCount))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
      }

      // 更新时间
      if (this.viewModel!.detail!.base.updatedAt > 0) {
        Column() {
          Text($r('app.string.market_detail_updated'))
            .fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          Text(this.formatDate(this.viewModel!.detail!.base.updatedAt))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Center)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_16') })
    .padding({
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  tagsSection(): void {
    if (this.resolveDisplayTags().length > 0) {
      Column() {
        Text($r('app.string.market_detail_tags_label'))
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.resolveDisplayTags(), (tag: string, index: number) => {
            Text(tag)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .margin({ right: 6, top: 6 })
          }, (tag: string, index: number) => tag + '|' + index.toString())
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .width('100%')
      .margin({ top: $r('app.float.app_spacing_16') })
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 解析显示标签(翻译优先,无翻译显示原文)。
   */
  private resolveDisplayTags(): string[] {
    if (this.viewModel === null || this.viewModel!.detail === null) {
      return [];
    }
    if (this.viewModel!.shouldShowChinese() && this.viewModel!.detailTranslation !== null) {
      const t: string[] = this.viewModel!.detailTranslation!.tags;
      if (t.length > 0) {
        return t;
      }
    }
    return this.viewModel!.detail!.base.tags;
  }

  @Builder
  descriptionSection(): void {
    if (this.resolveDisplayDescription().length > 0) {
      Column() {
        Text($r('app.string.market_detail_description_label'))
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')

        Text(this.resolveDisplayDescription())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 6 })
          .width('100%')
      }
      .width('100%')
      .margin({ top: $r('app.float.app_spacing_16') })
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 解析显示描述(翻译优先,无翻译显示原文)。
   */
  private resolveDisplayDescription(): string {
    if (this.viewModel === null || this.viewModel!.detail === null) {
      return '';
    }
    if (this.viewModel!.shouldShowChinese() && this.viewModel!.detailTranslation !== null) {
      const t: string = this.viewModel!.detailTranslation!.description;
      if (t.length > 0) {
        return t;
      }
    }
    return this.viewModel!.detail!.description;
  }

  @Builder
  creatorNotesSection(): void {
    if (this.resolveDisplayCreatorNotes().length > 0) {
      Column() {
        Text($r('app.string.market_detail_creator_notes_label'))
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')

        Text(this.resolveDisplayCreatorNotes())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 6 })
          .width('100%')
      }
      .width('100%')
      .margin({ top: $r('app.float.app_spacing_16') })
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 解析显示创作者备注(翻译优先,无翻译显示原文)。
   */
  private resolveDisplayCreatorNotes(): string {
    if (this.viewModel === null || this.viewModel!.detail === null) {
      return '';
    }
    if (this.viewModel!.shouldShowChinese() && this.viewModel!.detailTranslation !== null) {
      const t: string = this.viewModel!.detailTranslation!.creatorNotes;
      if (t.length > 0) {
        return t;
      }
    }
    return this.viewModel!.detail!.creatorNotes;
  }

  @Builder
  firstMessageSection(): void {
    if (this.resolveDisplayFirstMessage().length > 0) {
      Column() {
        Text($r('app.string.market_detail_first_message_label'))
          .fontSize($r('app.float.app_font_body'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')

        Text(this.resolveDisplayFirstMessage())
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 6 })
          .width('100%')
      }
      .width('100%')
      .margin({ top: $r('app.float.app_spacing_16') })
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 解析显示开场白预览(翻译优先,无翻译显示原文)。
   */
  private resolveDisplayFirstMessage(): string {
    if (this.viewModel === null || this.viewModel!.detail === null) {
      return '';
    }
    if (this.viewModel!.shouldShowChinese() && this.viewModel!.detailTranslation !== null) {
      const t: string = this.viewModel!.detailTranslation!.firstMessagePreview;
      if (t.length > 0) {
        return t;
      }
    }
    return this.viewModel!.detail!.firstMessagePreview;
  }

  @Builder
  statsSection(): void {
    Column() {
      // 备用开场白数量
      this.statRowWithCount(
        $r('app.string.market_detail_alt_greetings_label'),
        this.viewModel!.detail!.alternateGreetingsCount,
        $r('app.string.market_detail_stat_unit_entries')
      )

      // 对话示例
      this.statRow(
        $r('app.string.market_detail_message_example_label'),
        this.viewModel!.detail!.hasMessageExample
          ? $r('app.string.market_detail_stat_included')
          : $r('app.string.market_detail_stat_none')
      )

      // 角色世界书
      this.statRowWithCount(
        $r('app.string.market_detail_character_book_label'),
        this.viewModel!.detail!.characterBookEntryCount,
        $r('app.string.market_detail_stat_unit_entries')
      )

      // 卡版本
      if (this.viewModel!.detail!.characterVersion.length > 0) {
        this.statRow(
          $r('app.string.market_detail_card_version_label'),
          this.viewModel!.detail!.characterVersion
        )
      }

      // 来源
      if (this.viewModel!.detail!.base.sourceUrl.length > 0) {
        this.statRow(
          $r('app.string.market_detail_source_label'),
          this.viewModel!.detail!.base.providerId
        )
      }
    }
    .width('100%')
    .margin({ top: $r('app.float.app_spacing_16') })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_12'),
      bottom: $r('app.float.app_spacing_12')
    })
  }

  @Builder
  statRow(label: ResourceStr, value: ResourceStr): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      Blank()
      Text(value)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  statRowWithCount(label: ResourceStr, count: number, unit: ResourceStr): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      Blank()
      Text() {
        Span(count.toString())
        Span(unit)
      }
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  // ===== 底部固定按钮 =====

  @Builder
  bottomActionBar(): void {
    Row() {
      Button(this.importButtonLabel())
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(this.canImport() ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .width('100%')
        .enabled(this.canImport())
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.startImport().then((): void => {
              this.syncDialogState();
              this.maybeShowImportErrorToast();
              // 首次导入成功(非重复)时通知角色列表刷新
              if (this.viewModel !== null && this.viewModel!.importStatus === MarketImportStatus.Imported
                && this.viewModel!.importedCharacter !== null) {
                this.notifyListChanged();
              }
            });
          }
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_8'),
      bottom: this.navigationBarHeight + 8
    })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }

  /**
   * 导入失败时显示 toast(使用资源前缀 + 运行时错误详情)。
   */
  private maybeShowImportErrorToast(): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.importError.length === 0) {
      return;
    }
    // 根据导入状态选择前缀资源,然后拼接运行时错误详情
    const prefixRes: ResourceStr = this.resolveImportErrorPrefix();
    const detail: string = this.viewModel!.importError;
    // 使用 promptAction 显示 toast
    // 由于 toast.message 接受 ResourceStr,且无法拼接 Resource + string,
    // 这里直接显示运行时错误详情(不带前缀),保证错误可见
    promptAction.showToast({
      message: detail.length > 0 ? detail : prefixRes,
      duration: 2000
    });
  }

  /**
   * 根据导入状态解析错误前缀资源。
   */
  private resolveImportErrorPrefix(): ResourceStr {
    if (this.viewModel === null || this.viewModel!.importStatus === null) {
      return $r('app.string.market_detail_import_failed_prefix');
    }
    const status: MarketImportStatus = this.viewModel!.importStatus as MarketImportStatus;
    if (status === MarketImportStatus.NetworkError) {
      return $r('app.string.market_detail_network_error_prefix');
    }
    if (status === MarketImportStatus.ParseError) {
      return $r('app.string.market_detail_parse_error_prefix');
    }
    return $r('app.string.market_detail_unknown_error_prefix');
  }

  /**
   * 是否允许触发导入(未在导入中且 detail 已加载)。
   */
  private canImport(): boolean {
    if (this.viewModel === null || this.viewModel!.detail === null) {
      return false;
    }
    return !this.viewModel!.importing;
  }

  /**
   * 导入按钮文字。
   */
  private importButtonLabel(): ResourceStr {
    if (this.viewModel === null) {
      return $r('app.string.market_detail_import_short');
    }
    if (this.viewModel!.importing) {
      return $r('app.string.market_detail_importing');
    }
    if (this.viewModel!.importStatus === MarketImportStatus.Imported && this.viewModel!.importedCharacter !== null) {
      return $r('app.string.market_detail_imported');
    }
    return $r('app.string.market_detail_import_button');
  }

  // ===== 加载 / 错误视图 =====

  @Builder
  loadingView(): void {
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

  @Builder
  errorView(title: ResourceStr, description: ResourceStr): void {
    Column() {
      EmptyStateView({
        title: title,
        description: description
      })

      Button($r('app.string.market_retry'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('50%')
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.retry().then((): void => {
              this.syncDialogState();
            });
          }
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: $r('app.float.app_spacing_32'), right: $r('app.float.app_spacing_32') })
  }

  // ===== NSFW 进入提示弹窗 =====

  @Builder
  nsfwEntryDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.market_content_warning'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          Text($r('app.string.market_detail_nsfw_warning'))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ bottom: 20 })
            .textAlign(TextAlign.Center)
            .width('100%')

          Button($r('app.string.market_detail_i_understand'))
            .fontSize(14)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel!.dismissNsfwEntryDialog();
              }
              this.showNsfwEntryDialog = false;
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius(16)
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

  // ===== 重复确认弹窗 =====

  @Builder
  duplicateDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.market_detail_duplicate_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          // 使用 Span 组合显示动态名称消息
          Text() {
            Span(this.formatDuplicateMessagePrefix())
            Span(this.resolveDuplicateName())
            Span($r('app.string.market_detail_duplicate_message_suffix'))
          }
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ bottom: 20 })
          .textAlign(TextAlign.Center)
          .width('100%')

          // 查看本地角色
          Button($r('app.string.market_detail_view_local'))
            .fontSize(14)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor($r('app.color.app_accent_surface'))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .margin({ bottom: 8 })
            .onClick(() => {
              this.openLocalCharacter();
            })

          // 仍导入为副本
          Button($r('app.string.market_detail_import_as_duplicate'))
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .margin({ bottom: 8 })
            .onClick(() => {
              if (this.viewModel !== null) {
                void this.viewModel!.confirmDuplicateImport().then((): void => {
                  this.syncDialogState();
                  if (this.viewModel !== null && this.viewModel!.importStatus === MarketImportStatus.Imported) {
                    this.notifyListChanged();
                    this.maybeShowImportErrorToast();
                  }
                });
              }
            })

          // 取消
          Button($r('app.string.market_cancel'))
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel!.cancelDuplicateImport();
              }
              this.showDuplicateDialog = false;
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius(16)
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

  /**
   * 解析重复角色名称(无名称时显示默认资源)。
   */
  private resolveDuplicateName(): string {
    if (this.viewModel === null) {
      return '';
    }
    const name: string = this.viewModel!.duplicateExistingName;
    if (name.length > 0) {
      return name;
    }
    return '';
  }

  /**
   * 格式化重复消息前缀。
   * 若无名称,使用 default 资源(包含完整说明);
   * 若有名称,使用 prefix 资源(后接名称与 suffix)。
   */
  private formatDuplicateMessagePrefix(): ResourceStr {
    if (this.viewModel === null || this.viewModel!.duplicateExistingName.length === 0) {
      return $r('app.string.market_detail_duplicate_local_only');
    }
    return $r('app.string.market_detail_duplicate_message_prefix');
  }

  /**
   * 跳转到本地角色编辑页。
   */
  private openLocalCharacter(): void {
    if (this.viewModel === null) {
      return;
    }
    const localId: string = this.viewModel!.duplicateExistingLocalId;
    this.viewModel!.cancelDuplicateImport();
    this.showDuplicateDialog = false;
    if (localId.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/CharacterEditPage',
      params: { param: { characterId: localId } }
    });
  }

  // ===== 导入成功弹窗 =====

  @Builder
  importSuccessDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.market_detail_import_success_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          // 使用 Span 组合显示动态名称消息
          if (this.viewModel !== null && this.viewModel!.importedCharacter !== null
            && this.viewModel!.importedCharacter!.name.length > 0) {
            Text() {
              Span($r('app.string.market_detail_import_success_prefix'))
              Span(this.viewModel!.importedCharacter!.name)
              Span($r('app.string.market_detail_import_success_suffix'))
            }
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ bottom: 20 })
            .textAlign(TextAlign.Center)
            .width('100%')
          } else {
            Text($r('app.string.market_detail_import_success_default'))
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ bottom: 20 })
              .textAlign(TextAlign.Center)
              .width('100%')
          }

          // 查看角色
          Button($r('app.string.market_detail_view_character'))
            .fontSize(14)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .margin({ bottom: 8 })
            .onClick(() => {
              this.openImportedCharacter();
            })

          // 新建对话
          Button($r('app.string.market_detail_start_new_chat'))
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .margin({ bottom: 8 })
            .onClick(() => {
              this.startNewChatWithImported();
            })

          // 继续浏览
          Button($r('app.string.market_detail_continue_browsing'))
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .borderRadius(20)
            .width('100%')
            .height(40)
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel!.dismissImportSuccess();
              }
              this.showImportSuccessDialog = false;
            })
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius(16)
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

  /**
   * 跳转到已导入角色的编辑页。
   */
  private openImportedCharacter(): void {
    if (this.viewModel === null || this.viewModel!.importedCharacter === null) {
      return;
    }
    const localId: string = this.viewModel!.importedCharacter!.id;
    this.viewModel!.dismissImportSuccess();
    this.showImportSuccessDialog = false;
    router.pushUrl({
      url: 'pages/CharacterEditPage',
      params: { param: { characterId: localId } }
    });
  }

  /**
   * 用已导入角色创建新对话并跳转 ChatPage。
   */
  private startNewChatWithImported(): void {
    if (this.viewModel === null || this.viewModel!.importedCharacter === null) {
      return;
    }
    const localId: string = this.viewModel!.importedCharacter!.id;
    this.viewModel!.dismissImportSuccess();
    this.showImportSuccessDialog = false;
    AppStorage.setOrCreate<string>('pendingCharacterId', localId);
    AppStorage.setOrCreate<string>('pendingChatId', '');
    router.pushUrl({ url: 'pages/ChatPage' });
  }

  /**
   * 通知列表刷新(导入成功后递增版本号)。
   * 同时通知市场列表和角色列表刷新。
   */
  private notifyListChanged(): void {
    const current: number = AppStorage.get<number>('marketListVersion') as number;
    const next: number = (current === undefined ? 0 : current) + 1;
    AppStorage.setOrCreate<number>('marketListVersion', next);
    // 通知角色列表刷新(CharacterRootView 通过 @StorageProp('characterListVersion') 监听)
    const charVersion: number = AppStorage.get<number>('characterListVersion') as number;
    const nextCharVersion: number = (charVersion === undefined ? 0 : charVersion) + 1;
    AppStorage.setOrCreate<number>('characterListVersion', nextCharVersion);
  }

  // ===== 格式化辅助 =====

  /**
   * 格式化数量(>1000 显示为 1k+)。
   */
  private formatCount(count: number): string {
    if (count < 1000) {
      return count.toString();
    }
    if (count < 10000) {
      return (count / 1000).toFixed(1) + 'k';
    }
    if (count < 1000000) {
      return (count / 1000).toFixed(0) + 'k';
    }
    return (count / 1000000).toFixed(1) + 'M';
  }

  /**
   * 格式化日期为 YYYY-MM-DD。
   */
  private formatDate(timestamp: number): string {
    const date: Date = new Date(timestamp);
    const year: number = date.getFullYear();
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const monthStr: string = month < 10 ? '0' + month.toString() : month.toString();
    const dayStr: string = day < 10 ? '0' + day.toString() : day.toString();
    return year.toString() + '-' + monthStr + '-' + dayStr;
  }
}
