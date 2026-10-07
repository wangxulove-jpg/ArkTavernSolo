/**
 * LocalImageLibraryPage 本地图片库页面
 *
 * 模型(v50,**图片池 + 标签即预设**):
 * - 所有图片一个池子,页面用**标签**分组与筛选(不再有全局/角色专属)
 * - 标签就是**普通提示词预设**:把图片名(和描述)写进预设正文即视为打上该标签
 * - 顶部筛选芯片:全部 / 未分类 / 各标签;图片行显示它属于哪些标签,并可一键勾选
 * - 图片可改名、编辑描述(描述会随名字写进标签预设,帮助模型选对图)、删除
 *
 * 通过 LocalImageLibraryViewModel 操作,不直接访问 Service / Repository。
 */

import {
  LocalImageLibraryViewModel,
  LocalImageEntry,
  LocalImageTagOption,
  IMAGE_FILTER_ALL,
  IMAGE_FILTER_NONE
} from '../viewmodels/LocalImageLibraryViewModel';
import { CAPTION_GUIDANCE_MAX_LENGTH } from '../models/LocalImageCaption';
import {
  describeImageNameProblem,
  describeImageDescriptionProblem,
  IMAGE_NAME_MAX_LENGTH,
  IMAGE_DESCRIPTION_MAX_LENGTH
} from '../models/LocalImage';
import { AppServices } from '../services/AppServices';
import { CharacterImageView } from '../components/CharacterImageView';
import { EmptyStateView } from '../components/EmptyStateView';
import { ThemePalette } from '../theme/ThemePalette';
import { Logger } from '../utils/Logger';
import { router, promptAction } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

const LOG_TAG: string = 'LocalImageLibraryPage';
/** 选择器最大多选张数 */
const MAX_PICK_COUNT: number = 20;
/** 标签名长度上限(与预设名一致,宽松) */
const TAG_NAME_MAX_LENGTH: number = 30;

@Entry
@Component
struct LocalImageLibraryPage {
  @State viewModel: LocalImageLibraryViewModel = AppServices.createLocalImageLibraryViewModel();
  @State isImporting: boolean = false;
  /** 顶部筛选下拉面板是否展开 */
  @State tagPanelOpen: boolean = false;

  /** 改名面板(两段式:挂载 → 上滑) */
  @State renameSheetMounted: boolean = false;
  @State renameSheetShow: boolean = false;
  @State renameImageId: string = '';
  @State renameText: string = '';
  @State renameProblem: string = '';

  /** 描述编辑面板 */
  @State descSheetMounted: boolean = false;
  @State descSheetShow: boolean = false;
  @State descImageId: string = '';
  @State descText: string = '';
  @State descProblem: string = '';

  /** 标签多选面板 */
  @State tagSheetMounted: boolean = false;
  @State tagSheetShow: boolean = false;
  @State tagImageId: string = '';
  @State tagImageName: string = '';
  @State tagSelection: string[] = [];

  /** 新建标签面板 */
  @State tagCreateMounted: boolean = false;
  @State tagCreateShow: boolean = false;
  @State tagNameText: string = '';
  @State tagNameProblem: string = '';

  /** 图片详情大卡片(长按图片打开;空串 = 关闭) */
  @State detailImageId: string = '';

  /** 多选模式与选中集合 */
  @State batchMode: boolean = false;
  @State selectedIds: string[] = [];

  /** 批量分类面板 */
  @State batchSheetMounted: boolean = false;
  @State batchSheetShow: boolean = false;
  @State batchTagSelection: string[] = [];
  /** false = 添加标签;true = 移除标签 */
  @State batchRemoveMode: boolean = false;

  /** AI 命名建议面板(详情卡上的「AI 自动命名」触发) */
  @State captionSheetMounted: boolean = false;
  @State captionSheetShow: boolean = false;

  /** 「描述方向」编辑面板(库级全局设置,页面顶部常驻入口) */
  @State guidanceSheetMounted: boolean = false;
  @State guidanceSheetShow: boolean = false;
  @State guidanceDraft: string = '';

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  private hasInitialized: boolean = false;

  onPageShow(): void {
    if (this.hasInitialized) {
      void this.viewModel.refresh();
    } else {
      this.hasInitialized = true;
      void this.viewModel.initialize();
    }
  }

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }

  build() {
    Stack() {
      Column() {
        this.header()
        this.errorBanner()
        this.guidanceRow()
        this.content()
        if (this.batchMode) {
          this.batchBar()
        }
      }
      .width('100%')
      .height('100%')

      if (this.detailImageId.length > 0) {
        this.detailCard()
      }
      if (this.renameSheetMounted) {
        this.renameSheetHost()
      }
      if (this.descSheetMounted) {
        this.descSheetHost()
      }
      if (this.tagSheetMounted) {
        this.tagSheetHost()
      }
      if (this.tagCreateMounted) {
        this.tagCreateSheetHost()
      }
      if (this.batchSheetMounted) {
        this.batchSheetHost()
      }
      if (this.captionSheetMounted) {
        this.captionSheetHost()
      }
      if (this.guidanceSheetMounted) {
        this.guidanceSheetHost()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== 顶栏 ====

  @Builder
  header() {
    Row() {
      SymbolGlyph($r('sys.symbol.chevron_left'))
        .fontSize(22)
        .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
        .padding(6)
        .onClick(() => {
          router.back();
        })

      Column() {
        Text($r('app.string.local_image_library_title'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text($r('app.string.local_image_library_subtitle'))
          .fontSize(11)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 1 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 4 })

      Button($r('app.string.local_image_import'))
        .fontSize(12)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .height(28)
        .padding({ left: 8, right: 8 })
        .enabled(!this.isImporting && !this.viewModel.isOperating)
        .onClick(() => {
          void this.pickPhotos();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 12, top: this.statusBarHeight + 10, bottom: 8 })
  }

  @Builder
  errorBanner() {
    if (this.viewModel.errorMessage.length > 0) {
      Text(this.viewModel.errorMessage)
        .fontSize(13)
        .fontColor($r('app.color.app_danger'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
    }
  }

  // ===== 顶部:描述方向(库级全局设置,对所有图片生效) =====

  /** 常驻一行:显示当前描述方向,点击打开编辑面板 */
  @Builder
  guidanceRow() {
    Row({ space: 8 }) {
      Text($r('app.string.local_image_guidance_label'))
        .fontSize(12)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      if (this.viewModel.captionGuidance.length > 0) {
        Text(this.viewModel.captionGuidance)
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      } else {
        Text($r('app.string.local_image_guidance_empty'))
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .layoutWeight(1)
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
    }
    .width('100%')
    .height(34)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openGuidanceSheet();
    })
  }

  // ===== 描述方向编辑面板 =====

  @Builder
  guidanceSheetHost() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.guidanceSheetShow, this.guidanceSheetContent(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.guidanceSheetMounted = false;
        }
      })
      .onAppear(() => {
        this.guidanceSheetShow = true;
      })
  }

  @Builder
  guidanceSheetContent() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.local_image_guidance_label'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text($r('app.string.local_image_guidance_hint'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .onClick(() => {
            this.guidanceSheetShow = false;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      TextArea({
        text: this.guidanceDraft,
        placeholder: $r('app.string.local_image_caption_guidance_placeholder')
      })
        .width('100%')
        .height(120)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .maxLength(CAPTION_GUIDANCE_MAX_LENGTH)
        .onChange((value: string) => {
          this.guidanceDraft = value;
        })

      Row() {
        Button($r('app.string.local_image_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .height(44)
          .layoutWeight(1)
          .onClick(() => {
            this.guidanceSheetShow = false;
          })

        Button($r('app.string.local_image_guidance_save'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(44)
          .layoutWeight(1)
          .margin({ left: 12 })
          .onClick(() => {
            void this.saveGuidance();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  // ===== 内容区 ====

  @Builder
  content() {
    if (this.viewModel.isLoading) {
      Column() {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(ThemePalette.accentColor(this.effectiveTheme))
        Text($r('app.string.local_image_loading'))
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 12 })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else if (this.viewModel.entries.length === 0) {
      Column() {
        EmptyStateView({
          title: $r('app.string.local_image_empty_title'),
          description: $r('app.string.local_image_empty_desc')
        })
        Button($r('app.string.local_image_import'))
          .fontSize(14)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius(24)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .enabled(!this.isImporting && !this.viewModel.isOperating)
          .onClick(() => {
            void this.pickPhotos();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Column() {
        this.filterToolbar()
        if (this.tagPanelOpen) {
          this.tagFilterPanel()
        }
        Scroll() {
          Column() {
            // TODO: 条目数超过 20 时改用 LazyForEach(需实现 IDataSource;keyGenerator 仍用图片 id)。
            ForEach(this.viewModel.filteredEntries(), (entry: LocalImageEntry, index: number): void => {
              this.imageRow(entry, index > 0);
            }, (entry: LocalImageEntry): string => entry.image.id + '_' + this.viewModel.version.toString())
            if (this.viewModel.filteredEntries().length === 0) {
              Text($r('app.string.local_image_filter_empty'))
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .width('100%')
                .padding({ top: 24 })
                .textAlign(TextAlign.Center)
            }
            Blank().height(64)
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .layoutWeight(1)
    }
  }

  /** 顶部工具条:筛选下拉按钮(点击展开全部标签)+ 新建标签 */
  @Builder
  filterToolbar() {
    Row({ space: 10 }) {
      Row({ space: 6 }) {
        Text(this.activeFilterLabel())
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 200 })
        Text(this.activeFilterCount().toString())
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .rotate({ angle: this.tagPanelOpen ? 180 : 0 })
      }
      .height(32)
      .padding({ left: 12, right: 10 })
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius(16)
      .onClick(() => {
        this.tagPanelOpen = !this.tagPanelOpen;
      })

      Blank()

      if (!this.batchMode) {
        Button($r('app.string.local_image_tag_create'))
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(16)
          .height(32)
          .padding({ left: 12, right: 12 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            this.tagPanelOpen = false;
            this.openCreateTag();
          })
      }

      Button(this.batchMode
        ? $r('app.string.local_image_batch_exit')
        : $r('app.string.local_image_batch_select'))
        .fontSize(12)
        .fontColor(this.batchMode
          ? $r('app.color.app_on_accent')
          : ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(this.batchMode
          ? ThemePalette.accentColor(this.effectiveTheme)
          : ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(16)
        .height(32)
        .padding({ left: 12, right: 12 })
        .enabled(!this.viewModel.isOperating)
        .onClick(() => {
          this.toggleBatchMode();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 6 })
    .alignItems(VerticalAlign.Center)
  }

  /** 筛选下拉面板:全部 / 未分类 / 所有标签(超过一屏可滚动) */
  @Builder
  tagFilterPanel() {
    Column() {
      Scroll() {
        Column() {
          this.filterPanelRow($r('app.string.local_image_filter_all'),
            this.viewModel.entries.length, IMAGE_FILTER_ALL)
          this.filterPanelRow($r('app.string.local_image_filter_uncategorized'),
            this.viewModel.uncategorizedCount(), IMAGE_FILTER_NONE)
          ForEach(this.viewModel.tagOptions, (option: LocalImageTagOption): void => {
            this.filterPanelRow(option.name, option.imageCount, option.id);
          }, (option: LocalImageTagOption): string =>
          option.id + '_' + option.imageCount.toString() + '_' + this.viewModel.version.toString())
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 260 })
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .padding({ top: 2, bottom: 2 })
    .margin({ left: 16, right: 16, bottom: 6 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
  }

  /** 筛选面板行(选中态直接读 activeFilter,并参与 ForEach key,保证即时刷新) */
  @Builder
  filterPanelRow(label: ResourceStr, count: number, filterKey: string) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(this.viewModel.activeFilter === filterKey ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.viewModel.activeFilter === filterKey
          ? ThemePalette.accentColor(this.effectiveTheme)
          : ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
      Text(count.toString())
        .fontSize(11)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      if (this.viewModel.activeFilter === filterKey) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(15)
          .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.viewModel.setFilter(filterKey);
      this.tagPanelOpen = false;
    })
  }

  @Builder
  imageRow(entry: LocalImageEntry, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
      }

      Row() {
        // 多选模式下:前置勾选圈,点击整行即为勾选/取消
        if (this.batchMode) {
          Stack() {
            Column()
              .width(22)
              .height(22)
              .borderRadius(11)
              .backgroundColor(this.selectedIds.indexOf(entry.image.id) >= 0
                ? ThemePalette.accentColor(this.effectiveTheme)
                : Color.Transparent)
              .border({
                width: this.selectedIds.indexOf(entry.image.id) >= 0 ? 0 : 1.5,
                color: ThemePalette.textTertiaryColor(this.effectiveTheme)
              })
            if (this.selectedIds.indexOf(entry.image.id) >= 0) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(13)
                .fontColor([$r('app.color.app_on_accent')])
            }
          }
          .width(22)
          .height(22)
          .margin({ right: 10 })
        }

        CharacterImageView({
          imageUri: entry.image.fileUri,
          fallbackName: entry.image.name,
          imgWidth: 44,
          imgHeight: 44,
          imgBorderRadius: $r('app.float.app_radius_sm'),
          displayMode: 'thumbnail'
        })

        // 文字区:名称 / 描述 / 标签各占一行,紧凑排布
        Column() {
          Text(entry.image.name)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          if (entry.image.description.length > 0) {
            Text(entry.image.description)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          // 标签行:前缀是资源,必须与名字分开渲染($r 返回 Resource,直接 + 字符串会得到 [object Object])
          if (entry.tagNames.length > 0) {
            Row() {
              Text($r('app.string.local_image_tag_prefix'))
                .fontSize(11)
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              Text(entry.tagNames.join('、'))
                .fontSize(11)
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 2 })
          } else {
            Text($r('app.string.local_image_tag_none'))
              .fontSize(11)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })

        // 非多选:右侧箭头提示「点击查看详情」
        if (!this.batchMode) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
        }
      }
      .width('100%')
      .padding({ top: 7, bottom: 7 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        if (this.batchMode) {
          this.toggleSelect(entry.image.id);
        } else {
          this.openDetailCard(entry.image.id);
        }
      })
    }
    .width('100%')
  }

  // ===== 图片详情大卡片(点击图片打开) =====

  @Builder
  detailCard() {
    Stack() {
      // 遮罩:淡入淡出,点击空白处关闭
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.55)')
        .transition(TransitionEffect.OPACITY)
        .onClick(() => {
          this.closeDetailCard();
        })

      if (this.viewModel.findEntry(this.detailImageId) !== null) {
        this.detailCardBody(this.viewModel.findEntry(this.detailImageId)!)
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  /** 详情卡内容:大图 + 名称 + 描述 + 分类 + 四个功能按键 */
  @Builder
  detailCardBody(entry: LocalImageEntry) {
    Column() {
      Row() {
        Text($r('app.string.local_image_detail_title'))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .onClick(() => {
            this.closeDetailCard();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        CharacterImageView({
          imageUri: entry.image.fileUri,
          fallbackName: entry.image.name,
          imgWidth: 200,
          imgHeight: 200,
          imgBorderRadius: $r('app.float.app_radius_md'),
          displayMode: 'cover',
          objectFit: ImageFit.Contain
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 12 })

      Text(entry.image.name)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 12 })

      if (entry.image.description.length > 0) {
        Text(entry.image.description)
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 6 })
      } else {
        Text($r('app.string.local_image_detail_empty_description'))
          .fontSize(13)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 6 })
      }

      // 分类(标签)
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        if (entry.tagNames.length > 0) {
          ForEach(entry.tagNames, (tagName: string, index: number): void => {
            Text(tagName)
              .fontSize(11)
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius(10)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .margin({ right: 6, top: 6 })
              .maxLines(1)
          }, (tagName: string, index: number): string => tagName + '_' + index.toString())
        } else {
          Text($r('app.string.local_image_tag_none'))
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 6 })
        }
      }
      .width('100%')

      Divider()
        .color(ThemePalette.dividerColor(this.effectiveTheme))
        .margin({ top: 12, bottom: 4 })

      // AI 自动命名(视觉任务):结果先进建议面板,用户确认后才写入
      Button($r('app.string.local_image_action_ai_caption'))
        .fontSize(13)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor($r('app.color.app_accent_surface'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(38)
        .width('100%')
        .margin({ top: 8, bottom: 4 })
        .enabled(!this.captionLoadingOrApplying())
        .onClick(() => {
          this.openCaptionSheet(entry.image.id);
        })

      Row({ space: 4 }) {
        Button($r('app.string.local_image_action_rename'))
          .fontSize(13)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .height(40)
          .layoutWeight(1)
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            const target: LocalImageEntry | null = this.viewModel.findEntry(this.detailImageId);
            if (target !== null) {
              this.openRenameFlow(target);
            }
          })

        Button($r('app.string.local_image_action_description'))
          .fontSize(13)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .height(40)
          .layoutWeight(1)
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            const target: LocalImageEntry | null = this.viewModel.findEntry(this.detailImageId);
            if (target !== null) {
              this.openDescFlow(target);
            }
          })

        Button($r('app.string.local_image_action_tag'))
          .fontSize(13)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .height(40)
          .layoutWeight(1)
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            const target: LocalImageEntry | null = this.viewModel.findEntry(this.detailImageId);
            if (target !== null) {
              this.openTagFlow(target);
            }
          })

        Button($r('app.string.local_image_action_delete'))
          .fontSize(13)
          .fontColor($r('app.color.app_danger'))
          .backgroundColor(Color.Transparent)
          .height(40)
          .layoutWeight(1)
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            const target: LocalImageEntry | null = this.viewModel.findEntry(this.detailImageId);
            if (target !== null) {
              this.openDeleteConfirm(target);
            }
          })
      }
      .width('100%')
    }
    .width('86%')
    .padding(16)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_lg'))
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.scale({ x: 0.85, y: 0.85 })))
  }

  // ===== 多选底部操作栏 =====

  @Builder
  batchBar() {
    Column() {
      Divider()
        .color(ThemePalette.dividerColor(this.effectiveTheme))

      Row({ space: 12 }) {
        Text($r('app.string.local_image_batch_selected', this.selectedIds.length))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Blank()
        Button($r('app.string.local_image_batch_categorize'))
          .fontSize(13)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius(18)
          .height(36)
          .padding({ left: 16, right: 16 })
          .enabled(this.selectedIds.length > 0 && !this.viewModel.isOperating)
          .onClick(() => {
            this.openBatchCategorize();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: this.navigationBarHeight + 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }

  // ===== 批量分类面板 =====

  @Builder
  batchSheetHost() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.batchSheetShow, this.batchSheetContent(), {
        height: SheetSize.MEDIUM,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.batchSheetMounted = false;
        }
      })
      .onAppear(() => {
        this.batchSheetShow = true;
      })
  }

  @Builder
  batchSheetContent() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.local_image_batch_categorize'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text($r('app.string.local_image_batch_selected', this.selectedIds.length))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .onClick(() => {
            this.batchSheetShow = false;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      // 模式:添加 / 移除
      Row({ space: 8 }) {
        this.batchModeChip($r('app.string.local_image_batch_mode_add'), false)
        this.batchModeChip($r('app.string.local_image_batch_mode_remove'), true)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      Text($r('app.string.local_image_batch_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      if (this.viewModel.tagOptions.length === 0) {
        Column() {
          EmptyStateView({
            title: $r('app.string.local_image_tag_empty_title'),
            description: $r('app.string.local_image_tag_empty_desc')
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Row() {
          Button($r('app.string.local_image_tag_create'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(44)
            .layoutWeight(1)
            .onClick(() => {
              this.batchSheetShow = false;
              this.openCreateTag();
            })
        }
        .width('100%')
        .padding({ bottom: 16 })
      } else {
        List({ space: 4 }) {
          ForEach(this.viewModel.tagOptions, (option: LocalImageTagOption): void => {
            ListItem() {
              this.tagCheckRow(option, this.batchTagSelection.indexOf(option.id) >= 0, () => {
                this.toggleBatchTag(option.id);
              });
            }
          }, (option: LocalImageTagOption): string =>
          option.id + (this.batchTagSelection.indexOf(option.id) >= 0 ? '_1' : '_0'))
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)

        Button($r('app.string.local_image_confirm'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(44)
          .width('100%')
          .margin({ top: 12 })
          .enabled(this.batchTagSelection.length > 0 && !this.viewModel.isOperating)
          .onClick(() => {
            void this.confirmBatchTags();
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  /** 批量分类模式切换芯片(true = 移除标签,false = 添加标签) */
  @Builder
  batchModeChip(label: ResourceStr, removeMode: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(this.batchRemoveMode === removeMode
          ? $r('app.color.app_on_accent')
          : ThemePalette.textPrimaryColor(this.effectiveTheme))
    }
    .height(32)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.batchRemoveMode === removeMode
      ? ThemePalette.accentColor(this.effectiveTheme)
      : ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius(16)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.batchRemoveMode = removeMode;
    })
  }

  // ===== AI 命名建议面板(详情卡「AI 自动命名」触发;先进建议,确认后写入) =====

  @Builder
  captionSheetHost() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.captionSheetShow, this.captionSheetContent(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.captionSheetMounted = false;
          this.viewModel.resetCaption();
        }
      })
      .onAppear(() => {
        this.captionSheetShow = true;
      })
  }

  @Builder
  captionSheetContent() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.local_image_caption_sheet_title'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text(this.captionTargetName())
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .onClick(() => {
            this.captionSheetShow = false;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      if (this.viewModel.captionState === 'error') {
        // 请求失败:展示原因 + 重试
        Column() {
          Text(this.viewModel.captionError)
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .maxLines(8)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Row() {
            Button($r('app.string.local_image_caption_retry'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .height(44)
              .layoutWeight(1)
              .onClick(() => {
                void this.retryCaption();
              })

            Button($r('app.string.local_image_cancel'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .height(44)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                this.captionSheetShow = false;
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('100%')
        .padding({ bottom: 16 })
      } else if (this.viewModel.captionState === 'ready') {
        // 出建议:确认后写入
        Column() {
          Text($r('app.string.local_image_caption_suggested_name'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
          Text(this.viewModel.captionName)
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 4 })

          Text($r('app.string.local_image_caption_suggested_description'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 14 })
          if (this.viewModel.captionDescription.length > 0) {
            Text(this.viewModel.captionDescription)
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ top: 4 })
          } else {
            Text($r('app.string.local_image_caption_empty_description'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ top: 4 })
          }

          // 写入失败的原因(保留建议,改完可直接重试)
          if (this.viewModel.captionError.length > 0) {
            Text(this.viewModel.captionError)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .width('100%')
              .margin({ top: 10 })
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          Row() {
            Button($r('app.string.local_image_cancel'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .height(44)
              .layoutWeight(1)
              .onClick(() => {
                this.captionSheetShow = false;
              })

            Button($r('app.string.local_image_caption_retry'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .height(44)
              .layoutWeight(1)
              .margin({ left: 12 })
              .enabled(!this.viewModel.isOperating)
              .onClick(() => {
                void this.retryCaption();
              })

            Button($r('app.string.local_image_caption_apply'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_on_accent'))
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .height(44)
              .layoutWeight(1)
              .margin({ left: 12 })
              .enabled(!this.viewModel.isOperating)
              .onClick(() => {
                void this.confirmCaption();
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('100%')
        .padding({ bottom: 16 })
      } else {
        // idle / loading:进入即发起请求,统一显示加载态
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(ThemePalette.accentColor(this.effectiveTheme))
          Text($r('app.string.local_image_caption_loading'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ top: 12 })
        }
        .width('100%')
        .padding({ top: 28, bottom: 28 })
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  // ===== 改名面板 ====

  @Builder
  renameSheetHost() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.renameSheetShow, this.renameSheetContent(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.renameSheetMounted = false;
        }
      })
      .onAppear(() => {
        this.renameSheetShow = true;
      })
  }

  @Builder
  renameSheetContent() {
    Column() {
      Text($r('app.string.local_image_rename_sheet_title'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 16, bottom: 12 })

      TextInput({
        text: this.renameText,
        placeholder: $r('app.string.local_image_rename_placeholder')
      })
        .width('100%')
        .height(44)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .padding({ left: 12, right: 12 })
        .maxLength(IMAGE_NAME_MAX_LENGTH)
        .showError(this.renameProblem.length > 0 ? this.renameProblem : undefined)
        .onChange((value: string) => {
          this.renameText = value;
          this.renameProblem = describeImageNameProblem(value);
        })

      Row() {
        Button($r('app.string.local_image_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .height(44)
          .layoutWeight(1)
          .onClick(() => {
            this.renameSheetShow = false;
          })

        Button($r('app.string.local_image_confirm'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(44)
          .layoutWeight(1)
          .margin({ left: 12 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            void this.confirmRename();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  // ===== 描述编辑面板 ====

  @Builder
  descSheetHost() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.descSheetShow, this.descSheetContent(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.descSheetMounted = false;
        }
      })
      .onAppear(() => {
        this.descSheetShow = true;
      })
  }

  @Builder
  descSheetContent() {
    Column() {
      Text($r('app.string.local_image_description_sheet_title'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 16, bottom: 4 })

      Text($r('app.string.local_image_description_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, bottom: 12 })

      TextArea({
        text: this.descText,
        placeholder: $r('app.string.local_image_description_placeholder')
      })
        .width('100%')
        .height(88)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .maxLength(IMAGE_DESCRIPTION_MAX_LENGTH)
        .onChange((value: string) => {
          this.descText = value;
          this.descProblem = describeImageDescriptionProblem(value);
        })

      // TextArea 没有 showError,错误文案单独一行展示
      if (this.descProblem.length > 0) {
        Text(this.descProblem)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .padding({ left: 4, top: 6 })
      }

      Row() {
        Button($r('app.string.local_image_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .height(44)
          .layoutWeight(1)
          .onClick(() => {
            this.descSheetShow = false;
          })

        Button($r('app.string.local_image_confirm'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(44)
          .layoutWeight(1)
          .margin({ left: 12 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            void this.confirmDesc();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  // ===== 标签多选面板 ====

  @Builder
  tagSheetHost() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.tagSheetShow, this.tagSheetContent(), {
        height: SheetSize.MEDIUM,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.tagSheetMounted = false;
        }
      })
      .onAppear(() => {
        this.tagSheetShow = true;
      })
  }

  @Builder
  tagSheetContent() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.local_image_tag_sheet_title'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Text(this.tagImageName)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .onClick(() => {
            this.tagSheetShow = false;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.local_image_tag_sheet_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      if (this.viewModel.tagOptions.length === 0) {
        Column() {
          EmptyStateView({
            title: $r('app.string.local_image_tag_empty_title'),
            description: $r('app.string.local_image_tag_empty_desc')
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)

        Row() {
          Button($r('app.string.local_image_tag_create'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(44)
            .layoutWeight(1)
            .onClick(() => {
              this.tagSheetShow = false;
              this.openCreateTag();
            })
        }
        .width('100%')
        .padding({ bottom: 16 })
      } else {
        List({ space: 4 }) {
          ForEach(this.viewModel.tagOptions, (option: LocalImageTagOption): void => {
            ListItem() {
              this.tagCheckRow(option, this.tagSelection.indexOf(option.id) >= 0, () => {
                this.toggleTagSelection(option.id);
              });
            }
          }, (option: LocalImageTagOption): string =>
          option.id + (this.tagSelection.indexOf(option.id) >= 0 ? '_1' : '_0'))
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)

        Button($r('app.string.local_image_confirm'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(44)
          .width('100%')
          .margin({ top: 12 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            void this.confirmTags();
          })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  /** 标签勾选行(勾选态与回调由调用方传入,单图面板与批量面板共用) */
  @Builder
  tagCheckRow(option: LocalImageTagOption, selected: boolean, onToggle: () => void) {
    Row() {
      Text(option.name)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(20)
          .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .backgroundColor(selected
      ? $r('app.color.app_accent_surface')
      : Color.Transparent)
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(() => {
      onToggle();
    })
  }

  // ===== 新建标签面板 ====

  @Builder
  tagCreateSheetHost() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.tagCreateShow, this.tagCreateSheetContent(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.tagCreateMounted = false;
        }
      })
      .onAppear(() => {
        this.tagCreateShow = true;
      })
  }

  @Builder
  tagCreateSheetContent() {
    Column() {
      Text($r('app.string.local_image_tag_create_title'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 16, bottom: 4 })

      Text($r('app.string.local_image_tag_create_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, bottom: 12 })

      TextInput({
        text: this.tagNameText,
        placeholder: $r('app.string.local_image_tag_name_placeholder')
      })
        .width('100%')
        .height(44)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .padding({ left: 12, right: 12 })
        .maxLength(TAG_NAME_MAX_LENGTH)
        .showError(this.tagNameProblem.length > 0 ? this.tagNameProblem : undefined)
        .onChange((value: string) => {
          this.tagNameText = value;
          this.tagNameProblem = value.trim().length === 0 ? '标签名不能为空' : '';
        })

      Row() {
        Button($r('app.string.local_image_cancel'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .height(44)
          .layoutWeight(1)
          .onClick(() => {
            this.tagCreateShow = false;
          })

        Button($r('app.string.local_image_confirm'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(44)
          .layoutWeight(1)
          .margin({ left: 12 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            void this.confirmCreateTag();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  // ===== 交互 ====

  /** 下拉按钮当前显示的名称(全部 / 未分类 / 当前标签名) */
  private activeFilterLabel(): ResourceStr {
    if (this.viewModel.activeFilter === IMAGE_FILTER_ALL) {
      return $r('app.string.local_image_filter_all');
    }
    if (this.viewModel.activeFilter === IMAGE_FILTER_NONE) {
      return $r('app.string.local_image_filter_uncategorized');
    }
    const options: LocalImageTagOption[] = this.viewModel.tagOptions;
    for (let i = 0; i < options.length; i++) {
      if (options[i].id === this.viewModel.activeFilter) {
        return options[i].name;
      }
    }
    return '';
  }

  /** 下拉按钮当前显示的图片张数 */
  private activeFilterCount(): number {
    if (this.viewModel.activeFilter === IMAGE_FILTER_ALL) {
      return this.viewModel.entries.length;
    }
    if (this.viewModel.activeFilter === IMAGE_FILTER_NONE) {
      return this.viewModel.uncategorizedCount();
    }
    return this.viewModel.countForTag(this.viewModel.activeFilter);
  }

  /** 点击图片 → 放大打开详情大卡片(带弹出动画) */
  private openDetailCard(id: string): void {
    if (this.batchMode) {
      return;
    }
    this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.detailImageId = id;
    });
  }

  /** 关闭详情大卡片(带收起动画) */
  private closeDetailCard(): void {
    this.getUIContext().animateTo({ duration: 140, curve: Curve.EaseIn }, () => {
      this.detailImageId = '';
    });
  }

  /** AI 命名面板标题里的目标图片名 */
  private captionTargetName(): string {
    const entry: LocalImageEntry | null = this.viewModel.findEntry(this.viewModel.captionImageId);
    return entry !== null ? entry.image.name : '';
  }

  /** 命名请求进行中或正在写入(用于禁用详情卡上的 AI 按钮) */
  private captionLoadingOrApplying(): boolean {
    return this.viewModel.isOperating || this.viewModel.captionState === 'loading';
  }

  /** 打开「描述方向」编辑面板(草稿从当前值开始,取消不改动) */
  private openGuidanceSheet(): void {
    this.guidanceDraft = this.viewModel.captionGuidance;
    this.guidanceSheetMounted = true;
  }

  /** 保存「描述方向」并关闭面板 */
  private async saveGuidance(): Promise<void> {
    this.guidanceSheetShow = false;
    await this.viewModel.saveCaptionGuidance(this.guidanceDraft);
  }

  /** 打开 AI 命名面板并立即请求建议(结果只进面板,确认后才写入) */
  private openCaptionSheet(imageId: string): void {
    if (this.captionLoadingOrApplying()) {
      return;
    }
    this.captionSheetMounted = true;
    void this.viewModel.requestCaption(imageId);
  }

  /** 重新生成建议 */
  private async retryCaption(): Promise<void> {
    const imageId: string = this.viewModel.captionImageId;
    if (imageId.length === 0) {
      return;
    }
    await this.viewModel.requestCaption(imageId);
  }

  /** 采用建议:改名 + 改描述落库,成功后关闭面板 */
  private async confirmCaption(): Promise<void> {
    await this.viewModel.applyCaption();
    if (this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
      this.captionSheetShow = false;
    }
  }

  /** 进入/退出多选模式;退出时清空选中 */
  private toggleBatchMode(): void {
    this.batchMode = !this.batchMode;
    this.selectedIds = [];
    this.tagPanelOpen = false;
    this.closeDetailCard();
  }

  /** 勾选/取消一张图 */
  private toggleSelect(id: string): void {
    this.selectedIds = toggleInList(this.selectedIds, id);
  }

  /** 打开批量分类面板(需已选中至少一张) */
  private openBatchCategorize(): void {
    if (this.selectedIds.length === 0 || this.viewModel.isOperating) {
      return;
    }
    this.batchTagSelection = [];
    this.batchRemoveMode = false;
    this.batchSheetMounted = true;
  }

  /** 批量分类面板里勾选/取消一个标签 */
  private toggleBatchTag(id: string): void {
    this.batchTagSelection = toggleInList(this.batchTagSelection, id);
  }

  /** 把勾选的标签统一添加/移除到所选图片 */
  private async confirmBatchTags(): Promise<void> {
    const imageIds: string[] = this.selectedIds.slice();
    const tagIds: string[] = this.batchTagSelection.slice();
    if (imageIds.length === 0 || tagIds.length === 0) {
      this.batchSheetShow = false;
      return;
    }
    const remove: boolean = this.batchRemoveMode;
    this.batchSheetShow = false;
    if (remove) {
      await this.viewModel.removeTagsFromImages(imageIds, tagIds);
    } else {
      await this.viewModel.addTagsToImages(imageIds, tagIds);
    }
    if (this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
    }
    // 应用完成 → 退出多选并清空选中
    this.batchMode = false;
    this.selectedIds = [];
  }

  /** 打开系统图片选择器并逐张导入(池子;描述留空,导入后再编辑) */
  private async pickPhotos(): Promise<void> {
    if (this.isImporting || this.viewModel.isOperating) {
      return;
    }
    let uris: string[] = [];
    this.isImporting = true;
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const selectOption = new photoAccessHelper.PhotoSelectOptions();
      selectOption.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      selectOption.maxSelectNumber = MAX_PICK_COUNT;
      const result = await photoPicker.select(selectOption);
      if (!result || !result.photoUris || result.photoUris.length === 0) {
        this.isImporting = false;
        return;
      }
      uris = result.photoUris;
    } catch (e) {
      Logger.error(LOG_TAG, 'pickPhotos failed: ' + String(e));
      promptAction.showToast({ message: $r('app.string.local_image_picker_failed') });
      this.isImporting = false;
      return;
    }
    try {
      await this.viewModel.importImages(uris);
      if (this.viewModel.successMessage.length > 0) {
        promptAction.showToast({ message: this.viewModel.successMessage });
      }
    } finally {
      this.isImporting = false;
    }
  }

  private openRenameFlow(entry: LocalImageEntry): void {
    this.renameImageId = entry.image.id;
    this.renameText = entry.image.name;
    this.renameProblem = '';
    this.renameSheetMounted = true;
  }

  private async confirmRename(): Promise<void> {
    const problem: string = describeImageNameProblem(this.renameText);
    if (problem.length > 0) {
      this.renameProblem = problem;
      return;
    }
    this.renameSheetShow = false;
    await this.viewModel.renameImage(this.renameImageId, this.renameText);
    if (this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
    }
  }

  private openDescFlow(entry: LocalImageEntry): void {
    this.descImageId = entry.image.id;
    this.descText = entry.image.description;
    this.descProblem = '';
    this.descSheetMounted = true;
  }

  private async confirmDesc(): Promise<void> {
    const problem: string = describeImageDescriptionProblem(this.descText);
    if (problem.length > 0) {
      this.descProblem = problem;
      return;
    }
    this.descSheetShow = false;
    await this.viewModel.updateDescription(this.descImageId, this.descText);
    if (this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
    }
  }

  private openTagFlow(entry: LocalImageEntry): void {
    this.tagImageId = entry.image.id;
    this.tagImageName = entry.image.name;
    this.tagSelection = entry.tagIds.slice();
    this.tagSheetMounted = true;
  }

  private toggleTagSelection(id: string): void {
    this.tagSelection = toggleInList(this.tagSelection, id);
  }

  private async confirmTags(): Promise<void> {
    const imageId: string = this.tagImageId;
    const selection: string[] = this.tagSelection.slice();
    this.tagSheetShow = false;
    await this.viewModel.setImageTags(imageId, selection);
    if (this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
    }
  }

  private openCreateTag(): void {
    if (this.viewModel.isOperating) {
      return;
    }
    this.tagNameText = '';
    this.tagNameProblem = '';
    this.tagCreateMounted = true;
  }

  private async confirmCreateTag(): Promise<void> {
    if (this.tagNameText.trim().length === 0) {
      this.tagNameProblem = '标签名不能为空';
      return;
    }
    this.tagCreateShow = false;
    const ok: boolean = await this.viewModel.createTag(this.tagNameText);
    if (ok && this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
    }
  }

  private openDeleteConfirm(entry: LocalImageEntry): void {
    const id: string = entry.image.id;
    this.viewModel.requestDelete(id);
    AlertDialog.show({
      title: $r('app.string.local_image_delete_title'),
      message: $r('app.string.local_image_delete_message'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: $r('app.string.local_image_cancel'),
        action: () => {
          this.viewModel.cancelDelete();
        }
      },
      secondaryButton: {
        value: $r('app.string.local_image_confirm'),
        fontColor: $r('app.color.app_danger'),
        action: () => {
          void this.confirmDelete(id);
        }
      }
    });
  }

  private async confirmDelete(id: string): Promise<void> {
    await this.viewModel.confirmDelete(id);
    // 删除后清理指向该图的临时状态(详情卡 / 多选集合)
    if (this.detailImageId === id) {
      this.closeDetailCard();
    }
    if (this.selectedIds.indexOf(id) >= 0) {
      this.selectedIds = this.selectedIds.filter((value: string): boolean => value !== id);
    }
    if (this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
    }
  }
}

/** 切换数组中的某个元素:已存在则移除,不存在则追加(返回新数组,保证不可变替换) */
function toggleInList(list: string[], id: string): string[] {
  const next: string[] = [];
  let removed: boolean = false;
  for (let i = 0; i < list.length; i++) {
    if (list[i] === id) {
      removed = true;
    } else {
      next.push(list[i]);
    }
  }
  if (!removed) {
    next.push(id);
  }
  return next;
}