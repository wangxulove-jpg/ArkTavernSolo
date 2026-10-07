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
import {
  describeImageNameProblem,
  describeImageDescriptionProblem,
  IMAGE_NAME_MAX_LENGTH,
  IMAGE_DESCRIPTION_MAX_LENGTH
} from '../models/LocalImage';
import { AppServices } from '../services/AppServices';
import { AppPageHeader } from '../components/AppPageHeader';
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

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
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
        this.content()
      }
      .width('100%')
      .height('100%')

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
        .fontSize(24)
        .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
        .padding(8)
        .margin({ top: this.statusBarHeight + 10 })
        .onClick(() => {
          router.back();
        })

      Column() {
        AppPageHeader({
          title: $r('app.string.local_image_library_title'),
          subtitle: $r('app.string.local_image_library_subtitle')
        })
      }
      .layoutWeight(1)

      Button($r('app.string.local_image_import'))
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .height(32)
        .padding({ left: 10, right: 10 })
        .margin({ top: this.statusBarHeight + 14 })
        .enabled(!this.isImporting && !this.viewModel.isOperating)
        .onClick(() => {
          void this.pickPhotos();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 12, right: 12, bottom: 8 })
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
        this.filterChips()
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
            Blank().height(80)
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

  /** 顶部筛选芯片:全部 / 未分类 / 各标签 / 新建标签(横向滚动,标签多也不挤) */
  @Builder
  filterChips() {
    Scroll() {
      Row({ space: 8 }) {
        this.filterChip($r('app.string.local_image_filter_all'),
          this.viewModel.entries.length, IMAGE_FILTER_ALL)
        this.filterChip($r('app.string.local_image_filter_uncategorized'),
          this.viewModel.uncategorizedCount(), IMAGE_FILTER_NONE)
        ForEach(this.viewModel.usedTagOptions, (option: LocalImageTagOption): void => {
          this.filterChip(option.name, option.imageCount, option.id);
        }, (option: LocalImageTagOption): string =>
        option.id + '_' + option.imageCount.toString() + '_' + this.viewModel.version.toString())

        Button($r('app.string.local_image_tag_create'))
          .fontSize(13)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(17)
          .height(34)
          .padding({ left: 14, right: 14 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            this.openCreateTag();
          })
      }
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .padding({ bottom: 6 })
  }

  @Builder
  filterChip(label: ResourceStr, count: number, filterKey: string) {
    Row({ space: 5 }) {
      Text(label)
        .fontSize(13)
        .fontWeight(this.viewModel.activeFilter === filterKey ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.viewModel.activeFilter === filterKey
          ? $r('app.color.app_on_accent')
          : ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
      Text(count.toString())
        .fontSize(12)
        .fontColor(this.viewModel.activeFilter === filterKey
          ? $r('app.color.app_on_accent')
          : ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
    .height(34)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.viewModel.activeFilter === filterKey
      ? ThemePalette.accentColor(this.effectiveTheme)
      : ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius(17)
    .onClick(() => {
      this.viewModel.setFilter(filterKey);
    })
  }

  @Builder
  imageRow(entry: LocalImageEntry, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12 })
      }
      Row() {
        CharacterImageView({
          imageUri: entry.image.fileUri,
          fallbackName: entry.image.name,
          imgWidth: 48,
          imgHeight: 48,
          imgBorderRadius: $r('app.float.app_radius_sm'),
          displayMode: 'thumbnail'
        })

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
          Text(entry.tagNames.length > 0
            ? $r('app.string.local_image_tag_prefix') + entry.tagNames.join('、')
            : $r('app.string.local_image_tag_none'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })

        Button($r('app.string.local_image_action_rename'))
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            this.openRenameFlow(entry);
          })

        Button($r('app.string.local_image_action_description'))
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            this.openDescFlow(entry);
          })

        Button($r('app.string.local_image_action_tag'))
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            this.openTagFlow(entry);
          })

        Button($r('app.string.local_image_action_delete'))
          .fontSize(12)
          .fontColor($r('app.color.app_danger'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 0 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            this.openDeleteConfirm(entry);
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
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
              this.tagCheckRow(option);
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

  /** 标签多选行(勾选态直接读 @State,并参与 ForEach key,保证勾选即时刷新) */
  @Builder
  tagCheckRow(option: LocalImageTagOption) {
    Row() {
      Text(option.name)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.tagSelection.indexOf(option.id) >= 0) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(20)
          .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.tagSelection.indexOf(option.id) >= 0
      ? $r('app.color.app_accent_surface')
      : Color.Transparent)
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(() => {
      this.toggleTagSelection(option.id);
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
    const next: string[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.tagSelection.length; i++) {
      if (this.tagSelection[i] === id) {
        removed = true;
      } else {
        next.push(this.tagSelection[i]);
      }
    }
    if (!removed) {
      next.push(id);
    }
    this.tagSelection = next;
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
    if (this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
    }
  }
}