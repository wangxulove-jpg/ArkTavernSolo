/**
 * PromptPresetListPage 预设列表页面
 *
 * 显示所有预设,支持设为当前、新建、编辑、删除。
 * 通过 PromptPresetListViewModel 操作,不直接访问 Repository 或 Service。
 *
 * 视觉风格与 LorebookPage 保持一致:
 * - SymbolGlyph chevron_left 返回按钮
 * - ThemePalette 统一主题色
 * - 带边框的卡片式条目
 * - FAB 新建按钮
 */

import { PromptPresetListViewModel } from '../viewmodels/PromptPresetListViewModel';
import { AppServices } from '../services/AppServices';
import { PromptPreset } from '../models/PromptPreset';
import { router, promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { Logger } from '../utils/Logger';
import { ThemePalette } from '../theme/ThemePalette';

interface PresetEditRouteParam {
  presetId: string;
}

const LOG_TAG: string = 'PromptPresetListPage';

@Entry
@Component
struct PromptPresetListPage {
  @State viewModel: PromptPresetListViewModel = AppServices.createPromptPresetListViewModel();
  @State refreshKey: number = 0;
  @State importing: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  private hasInitialized: boolean = false;

  aboutToAppear(): void {
  }

  onPageShow(): void {
    if (this.hasInitialized) {
      this.viewModel.refresh();
    } else {
      this.hasInitialized = true;
      this.viewModel.initialize();
    }
  }

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }

  /** 选择并导入提示词预设 JSON 文件。成功后提示导入数量。 */
  private async pickPresetFile(): Promise<void> {
    if (this.importing) {
      return;
    }
    let uris: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json', '.txt'];
      uris = await documentPicker.select(options);
    } catch (e) {
      promptAction.showToast({ message: '打开文件选择器失败', duration: 2000 });
      return;
    }
    if (uris.length === 0) {
      return;
    }
    this.importing = true;
    try {
      const inserted: number = await this.viewModel.importPresetsFromFile(uris[0]);
      if (inserted > 0) {
        promptAction.showToast({ message: '成功导入 ' + inserted.toString() + ' 个预设', duration: 2000 });
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'pickPresetFile failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  build() {
    Stack() {
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
            .padding(8)
            .onClick(() => {
              router.back();
            })

          Text('提示词预设')
            .fontSize($r('app.float.nav_title_font_size'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8 })

          Button('导入')
            .fontSize(13)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(32)
            .padding({ left: 10, right: 10 })
            .enabled(!this.importing)
            .onClick(() => {
              void this.pickPresetFile();
            })
        }
        .width('100%')
        .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(13)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        }

        if (this.viewModel.isLoading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color(ThemePalette.accentColor(this.effectiveTheme))
            Text('加载中...')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.viewModel.presets.length === 0) {
          Column() {
            Text('暂无预设')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            Text('点击右下角按钮创建第一个预设')
              .fontSize(13)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ top: 8 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column() {
              ForEach(this.viewModel.presets, (preset: PromptPreset) => {
                this.presetCard(preset);
              }, (preset: PromptPreset) => preset.id + '_' + this.refreshKey.toString())
              Blank().height(80);
            }
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16, top: 8 })
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')

      if (!this.viewModel.isLoading && this.viewModel.presets.length >= 0) {
        Button('+ 新建预设')
          .fontSize(14)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius(24)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .position({ x: '70%', y: '90%' })
          .onClick(() => {
            router.pushUrl({
              url: 'pages/PromptPresetEditPage',
              params: { presetId: '' } as PresetEditRouteParam
            });
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  presetCard(preset: PromptPreset) {
    Column() {
      Row() {
        Text(preset.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (this.viewModel.isSelected(preset.id)) {
          Text('已选')
            .fontSize(11)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (preset.description.length > 0) {
        Text(preset.description)
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
      }

      Text(this.viewModel.getPresetSummary(preset))
        .fontSize(12)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 4 })
        .width('100%')

      Row() {
        Button(this.viewModel.isSelected(preset.id) ? '取消选择' : '选择')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .padding({ left: 0, right: 8 })
          .onClick(() => {
            this.viewModel.toggle(preset.id);
          })

        Button('编辑')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .padding({ left: 0, right: 8 })
          .onClick(() => {
            router.pushUrl({
              url: 'pages/PromptPresetEditPage',
              params: { presetId: preset.id } as PresetEditRouteParam
            });
          })

        Button('删除')
          .fontSize(12)
          .fontColor($r('app.color.app_danger'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 0, right: 0 })
          .onClick(() => {
            AlertDialog.show({
              title: '删除确认',
              message: '删除该提示词预设？\n此操作无法撤销。',
              autoCancel: true,
              alignment: DialogAlignment.Center,
              primaryButton: {
                value: '取消',
                action: () => {}
              },
              secondaryButton: {
                value: '删除',
                fontColor: $r('app.color.app_danger'),
                action: () => {
                  this.viewModel.confirmDelete(preset.id);
                }
              }
            });
          })
      }
      .width('100%')
      .margin({ top: 8 })
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
    .margin({ bottom: 8 })
  }
}
