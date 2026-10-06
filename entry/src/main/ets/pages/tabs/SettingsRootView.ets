/**
 * SettingsRootView 设置 Tab 根视图(UI-1)
 *
 * 作为 HdsTabs 的第四个 Tab 内容,聚合现有设置功能入口。
 *
 * 分组:
 * - AI 与对话:模型设置 / 世界书 / 提示词预设
 * - 应用:应用设置 / 云同步 / 语音朗读
 *
 * 版式(v2,2026-09-28 收紧):
 * - 与"对话设置""应用设置"同一范式:分区小标题 + 一张卡(surface_1) + 卡内行高 56 + 1px 分隔线;
 * - 每行 = 标题 + 小字说明(左) + 入口图标(右,中性灰,兼作视觉锚点);
 * - 原先"每项一张整宽卡 + 卡片内边距 16 + 卡间距 8"改为同组共用一张卡,去掉顶栏下的引导句。
 *
 * 点击入口通过 router.pushUrl 跳转到现有二级页面,不复制业务逻辑。
 * 顶栏/分组标题复用 ui 原语(AppTopBar/AppSectionHeader)。
 */

import { AppTopBar } from '../../components/ui/AppTopBar';
import { AppSectionHeader } from '../../components/ui/AppSectionHeader';
import { router } from '@kit.ArkUI';
import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct SettingsRootView {
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题区(统一 AppTopBar,不设背景让壁纸透出) =====
        AppTopBar({ title: $r('app.string.tab_settings') }) {
        }

        // ===== 可滚动内容区 =====
        Scroll() {
          Column() {
            // ===== AI 与对话 =====
            AppSectionHeader({ title: $r('app.string.tab_settings_section_ai') })
            Column() {
              Column() {
                this.entryRow($r('sys.symbol.key'), $r('app.string.tab_settings_model'),
                  $r('app.string.tab_settings_model_desc'), false, (): void => {
                    router.pushUrl({ url: 'pages/ModelSettingsPage' });
                  })
                this.entryRow($r('sys.symbol.book'), $r('app.string.tab_settings_lorebook'),
                  $r('app.string.tab_settings_lorebook_desc'), true, (): void => {
                    router.pushUrl({ url: 'pages/LorebookPage' });
                  })
                this.entryRow($r('sys.symbol.textformat'), $r('app.string.tab_settings_preset'),
                  $r('app.string.tab_settings_preset_desc'), true, (): void => {
                    router.pushUrl({ url: 'pages/PromptPresetListPage' });
                  })
                this.entryRow($r('sys.symbol.square_grid_2x2'), $r('app.string.tab_settings_image_library'),
                  $r('app.string.tab_settings_image_library_desc'), true, (): void => {
                    router.pushUrl({ url: 'pages/LocalImageLibraryPage' });
                  })
              }
              .width('100%')
              .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_md'))
            }
            .width('100%')
            .padding({ left: $r('app.float.app_spacing_16'), right: $r('app.float.app_spacing_16') })

            // ===== 应用 =====
            AppSectionHeader({ title: $r('app.string.tab_settings_section_app') })
            Column() {
              Column() {
                this.entryRow($r('sys.symbol.exposure'), $r('app.string.tab_settings_app_settings'),
                  $r('app.string.tab_settings_app_settings_desc'), false, (): void => {
                    router.pushUrl({ url: 'pages/AppSettingsPage' });
                  })
                this.entryRow($r('sys.symbol.arrow_clockwise'), $r('app.string.sync_nav_title'),
                  $r('app.string.sync_nav_desc'), true, (): void => {
                    router.pushUrl({ url: 'pages/SyncSettingsPage' });
                  })
                this.entryRow($r('sys.symbol.speaker_wave_2'), '语音朗读',
                  '使用系统语音引擎朗读角色回复', true, (): void => {
                    router.pushUrl({ url: 'pages/TtsSettingsPage' });
                  })
              }
              .width('100%')
              .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_md'))
            }
            .width('100%')
            .padding({ left: $r('app.float.app_spacing_16'), right: $r('app.float.app_spacing_16') })
          }
          .width('100%')
          .padding({
            // 滚动到底部时,最后一项下方留足够空白可滚动到 tab bar 上方
            bottom: 160
          })
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')
      // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .width('100%')
    .height('100%')
    // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  /**
   * 设置项行:标题 + 小字说明(左) + 入口图标(右,中性灰)。
   * @param showDivider 是否在行顶画分隔线(卡片内非首行传 true)
   */
  @Builder
  entryRow(icon: Resource, title: ResourceStr, desc: ResourceStr, showDivider: boolean, onPress: () => void) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12 })
      }
      Row() {
        Column() {
          Text(title)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          if (desc !== '') {
            Text(desc)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 1 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        SymbolGlyph(icon)
          .fontSize(18)
          .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
          .margin({ left: 12 })
      }
      .width('100%')
      .height(56)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      onPress();
    })
  }
}
