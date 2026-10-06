/**
 * LocalImageLibraryPage 本地图片库页面
 *
 * 功能:
 * - 展示本地图片库(缩略图 + 名字 + 作用域标签),按 全局 / 各角色 / 孤儿 分组
 * - 导入图片(先选作用域 → photoAccessHelper 图片选择器,支持多选)
 * - 改名 / 改作用域 / 删除
 *
 * 通过 LocalImageLibraryViewModel 操作,不直接访问 Service / Repository。
 * 顶栏复用 AppPageHeader(标题区)+ 统一系统返回图标。
 */

import {
  LocalImageLibraryViewModel,
  LocalImageGroup,
  LocalImageEntry,
  ScopeOption
} from '../viewmodels/LocalImageLibraryViewModel';
import { describeImageNameProblem, IMAGE_NAME_MAX_LENGTH } from '../models/LocalImage';
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

@Entry
@Component
struct LocalImageLibraryPage {
  @State viewModel: LocalImageLibraryViewModel = AppServices.createLocalImageLibraryViewModel();
  @State isImporting: boolean = false;

  /** 作用域选择面板(两段式:挂载 → 上滑) */
  @State scopeSheetMounted: boolean = false;
  @State scopeSheetShow: boolean = false;
  /** 'import' = 导入前选作用域;'scope' = 修改某张图的作用域 */
  @State scopeAction: string = '';
  @State scopeImageId: string = '';
  @State scopeCurrentCharacterId: string = '';

  /** 改名面板(两段式:挂载 → 上滑) */
  @State renameSheetMounted: boolean = false;
  @State renameSheetShow: boolean = false;
  @State renameImageId: string = '';
  @State renameText: string = '';
  @State renameProblem: string = '';

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

      if (this.scopeSheetMounted) {
        this.scopeSheetHost()
      }
      if (this.renameSheetMounted) {
        this.renameSheetHost()
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
          this.openImportFlow();
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
            this.openImportFlow();
          })
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column() {
          // TODO: 条目数超过 20 时改用 LazyForEach(需实现 IDataSource;keyGenerator 仍用图片 id)。
          // 当前用 ForEach(分组渲染 + 缩略图,实现 LazyForEach 成本较高,暂缓)。
          ForEach(this.viewModel.groups, (group: LocalImageGroup): void => {
            this.groupSection(group);
          }, (group: LocalImageGroup): string => group.key + '_' + this.viewModel.version.toString())
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
  }

  @Builder
  groupSection(group: LocalImageGroup) {
    Column() {
      Text(group.label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(group.orphan
          ? $r('app.color.app_danger')
          : ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 14, bottom: 6 })

      Column() {
        ForEach(group.entries, (entry: LocalImageEntry, index: number): void => {
          this.imageRow(entry, index > 0);
        }, (entry: LocalImageEntry): string => entry.image.id + '_' + this.viewModel.version.toString())
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
    }
    .width('100%')
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
          Text(entry.scopeLabel)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(entry.orphan
              ? $r('app.color.app_danger')
              : ThemePalette.textSecondaryColor(this.effectiveTheme))
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

        Button($r('app.string.local_image_action_scope'))
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .padding({ left: 6, right: 6 })
          .enabled(!this.viewModel.isOperating)
          .onClick(() => {
            this.openScopeFlow(entry);
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

  // ===== 作用域选择面板 ====

  @Builder
  scopeSheetHost() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.scopeSheetShow, this.scopeSheetContent(), {
        height: SheetSize.MEDIUM,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.scopeSheetMounted = false;
        }
      })
      .onAppear(() => {
        this.scopeSheetShow = true;
      })
  }

  @Builder
  scopeSheetContent() {
    Column() {
      Row() {
        Text($r('app.string.local_image_scope_sheet_title'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Blank()
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(22)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          .onClick(() => {
            this.scopeSheetShow = false;
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      List({ space: 4 }) {
        ForEach(this.viewModel.scopeOptions, (option: ScopeOption): void => {
          ListItem() {
            this.scopeRow(option);
          }
        }, (option: ScopeOption): string => option.characterId)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .padding({ bottom: 8 })
  }

  @Builder
  scopeRow(option: ScopeOption) {
    Row() {
      Text(option.label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(option.characterId === this.scopeCurrentCharacterId
          ? ThemePalette.accentColor(this.effectiveTheme)
          : ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (option.characterId === this.scopeCurrentCharacterId) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(20)
          .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
      }
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .backgroundColor(option.characterId === this.scopeCurrentCharacterId
      ? $r('app.color.app_accent_surface')
      : Color.Transparent)
    .borderRadius($r('app.float.app_radius_sm'))
    .onClick(() => {
      this.onScopeChosen(option.characterId);
    })
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

  // ===== 交互 ====

  private openImportFlow(): void {
    if (this.isImporting || this.viewModel.isOperating) {
      return;
    }
    this.scopeAction = 'import';
    this.scopeImageId = '';
    this.scopeCurrentCharacterId = '';
    this.scopeSheetMounted = true;
  }

  private openScopeFlow(entry: LocalImageEntry): void {
    this.scopeAction = 'scope';
    this.scopeImageId = entry.image.id;
    this.scopeCurrentCharacterId = entry.image.characterId;
    this.scopeSheetMounted = true;
  }

  private openRenameFlow(entry: LocalImageEntry): void {
    this.renameImageId = entry.image.id;
    this.renameText = entry.image.name;
    this.renameProblem = '';
    this.renameSheetMounted = true;
  }

  private onScopeChosen(characterId: string): void {
    const action: string = this.scopeAction;
    const imageId: string = this.scopeImageId;
    this.scopeSheetShow = false;
    if (action === 'import') {
      void this.pickPhotos(characterId);
    } else if (action === 'scope') {
      void this.applyScopeChange(imageId, characterId);
    }
  }

  /** 打开系统图片选择器并逐张导入。 */
  private async pickPhotos(characterId: string): Promise<void> {
    if (this.isImporting) {
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
      await this.viewModel.importImages(uris, characterId);
      if (this.viewModel.successMessage.length > 0) {
        promptAction.showToast({ message: this.viewModel.successMessage });
      }
    } finally {
      this.isImporting = false;
    }
  }

  private async applyScopeChange(imageId: string, characterId: string): Promise<void> {
    await this.viewModel.changeScope(imageId, characterId);
    if (this.viewModel.successMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel.successMessage });
    }
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