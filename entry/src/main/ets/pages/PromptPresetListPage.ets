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
  @State exporting: boolean = false;
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

  /** 选择保存位置并导出全部预设。成功后提示导出数量。 */
  private async pickPresetExportFile(): Promise<void> {
    if (this.exporting || this.viewModel.presets.length === 0) {
      return;
    }
    let uris: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [presetExportFileName()];
      uris = await documentPicker.save(options);
    } catch (e) {
      promptAction.showToast({ message: '打开保存位置选择器失败', duration: 2000 });
      return;
    }
    if (uris.length === 0) {
      return;
    }
    this.exporting = true;
    try {
      const exported: number = await this.viewModel.exportPresetsToFile(uris[0]);
      if (exported > 0) {
        promptAction.showToast({ message: '已导出 ' + exported.toString() + ' 个预设', duration: 2000 });
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'pickPresetExportFile failed: ' + String(e));
    } finally {
      this.exporting = false;
    }
  }

  build() {
    Stack() {
      Column() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
            .padding(6)
            .onClick(() => {
              router.back();
            })

          Text('提示词预设')
            .fontSize(18)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8 })

          Button('导入')
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(28)
            .padding({ left: 8, right: 8 })
            .enabled(!this.importing)
            .onClick(() => {
              void this.pickPresetFile();
            })

          Button('导出')
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(28)
            .padding({ left: 8, right: 8 })
            .enabled(!this.exporting && this.viewModel.presets.length > 0)
            .onClick(() => {
              void this.pickPresetExportFile();
            })
        }
        .width('100%')
        .padding({ top: this.statusBarHeight + 10, left: 12, right: 12, bottom: 8 })
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
              Blank().height(64);
            }
            .width('100%')
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 12, right: 12, top: 6 })
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')

      if (!this.viewModel.isLoading && this.viewModel.presets.length >= 0) {
        Button('+ 新建预设')
          .fontSize(13)
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius(22)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
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
      // 标题独占整行:避免与徽标争抢宽度而被挤压/遮挡
      Text(preset.name)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      // 徽标独立一行,自动换行(已选 / 末尾 / 作用域 / 自动维护)
      if (this.viewModel.isSelected(preset.id) || this.viewModel.isTail(preset.id)
        || this.viewModel.getScopeLabel(preset.id) !== '全局'
        || this.viewModel.isManagedPreset(preset.id)) {
        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.viewModel.isSelected(preset.id)) {
            this.presetBadge('已选', true)
          }
          if (this.viewModel.isTail(preset.id)) {
            this.presetBadge('末尾', false)
          }
          // v52: 作用域徽标(全局为默认值,不占位;绑定了角色才显示角色名)
          if (this.viewModel.getScopeLabel(preset.id) !== '全局') {
            this.presetBadge(this.viewModel.getScopeLabel(preset.id), false)
          }
          // v52: 受管图片清单预设由图片库自动维护
          if (this.viewModel.isManagedPreset(preset.id)) {
            this.presetBadge('自动维护', false)
          }
        }
        .width('100%')
      }

      if (preset.description.length > 0) {
        Text(preset.description)
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
      }

      Text(this.viewModel.getPresetSummary(preset))
        .fontSize(11)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 3 })
        .width('100%')

      Row() {
        Button(this.viewModel.isSelected(preset.id) ? '取消选择' : '选择')
          .fontSize(11)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .height(24)
          .padding({ left: 0, right: 6 })
          .onClick(() => {
            this.viewModel.toggle(preset.id);
          })

        if (this.viewModel.isManagedPreset(preset.id)) {
          // v52: 受管预设由「本地图片库」自动维护(位置固定在末尾),不允许编辑/删除
          Text('由本地图片库自动维护')
            .fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        } else {
          Button('编辑')
            .fontSize(11)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent)
            .height(24)
            .padding({ left: 0, right: 6 })
            .onClick(() => {
              router.pushUrl({
                url: 'pages/PromptPresetEditPage',
                params: { presetId: preset.id } as PresetEditRouteParam
              });
            })

          Button('删除')
            .fontSize(11)
            .fontColor($r('app.color.app_danger'))
            .backgroundColor(Color.Transparent)
            .height(24)
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
      }
      .width('100%')
      .margin({ top: 6 })
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
    .margin({ bottom: 6 })
  }

  /** 预设徽标(accent=true 为强调色底;用于已选/末尾/作用域/自动维护) */
  @Builder
  presetBadge(label: string, accent: boolean) {
    Text(label)
      .fontSize(10)
      .fontColor(accent ? $r('app.color.app_on_accent') : ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(accent ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius(4)
      .padding({ left: 5, right: 5, top: 1, bottom: 1 })
      .margin({ right: 5, top: 4 })
      .maxLines(1)
  }
}

/** 生成默认导出文件名:presets_YYYYMMDD_HHmm.json */
function presetExportFileName(): string {
  const d: Date = new Date();
  const p2 = (n: number): string => n.toString().padStart(2, '0');
  return 'presets_'
    + d.getFullYear().toString()
    + p2(d.getMonth() + 1)
    + p2(d.getDate())
    + '_'
    + p2(d.getHours())
    + p2(d.getMinutes())
    + '.json';
}
