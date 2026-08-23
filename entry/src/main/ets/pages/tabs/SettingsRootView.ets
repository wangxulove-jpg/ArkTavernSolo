/**
 * SettingsRootView 设置 Tab 根视图(UI-1)
 *
 * 作为 HdsTabs 的第四个 Tab 内容,聚合现有设置功能入口。
 *
 * 分组:
 * - AI 与对话:模型设置 / 世界书 / 提示词预设
 * - 应用:应用设置
 *
 * 点击入口卡片通过 router.pushUrl 跳转到现有二级页面,不复制业务逻辑。
 */

import { PressableCard } from '../../components/PressableCard';
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
        // ===== 顶部标题区(与 Tab1/Tab2 一致,不设 backgroundColor 让壁纸透出) =====
        Row() {
          Text($r('app.string.tab_settings'))
            .fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_20'),
          right: $r('app.float.app_spacing_20'),
          top: this.statusBarHeight + 8,
          bottom: $r('app.float.app_spacing_8')
        })
        .alignItems(VerticalAlign.Center)

        // ===== 可滚动内容区 =====
        Scroll() {
          Column() {
            Text($r('app.string.tab_settings_desc'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({
                left: $r('app.float.app_spacing_20'),
                right: $r('app.float.app_spacing_20'),
                bottom: $r('app.float.app_spacing_12')
              })

            // ===== AI 与对话 =====
            this.sectionHeader($r('app.string.tab_settings_section_ai'))

            this.entryCard(
              $r('app.string.tab_settings_model'),
              $r('app.string.tab_settings_model_desc'),
              () => {
                router.pushUrl({ url: 'pages/ModelSettingsPage' });
              }
            )

            this.entryCard(
              $r('app.string.tab_settings_lorebook'),
              $r('app.string.tab_settings_lorebook_desc'),
              () => {
                router.pushUrl({ url: 'pages/LorebookPage' });
              }
            )

            this.entryCard(
              $r('app.string.tab_settings_preset'),
              $r('app.string.tab_settings_preset_desc'),
              () => {
                router.pushUrl({ url: 'pages/PromptPresetListPage' });
              }
            )

            // ===== 应用 =====
            this.sectionHeader($r('app.string.tab_settings_section_app'))

            this.entryCard(
              $r('app.string.tab_settings_app_settings'),
              $r('app.string.tab_settings_app_settings_desc'),
              () => {
                router.pushUrl({ url: 'pages/AppSettingsPage' });
              }
            )

            this.entryCard(
              $r('app.string.sync_nav_title'),
              $r('app.string.sync_nav_desc'),
              () => {
                router.pushUrl({ url: 'pages/SyncSettingsPage' });
              }
            )

            this.entryCard(
              '语音朗读',
              '使用系统语音引擎朗读角色回复',
              () => {
                router.pushUrl({ url: 'pages/TtsSettingsPage' });
              }
            )
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
        // 不设 margin-bottom,让 Scroll 视口铺满整个 HdsTabs 区域
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

  /** 分组标题 */
  @Builder
  sectionHeader(title: ResourceStr) {
    Text(title)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20'),
        top: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })
  }

  /** 入口卡片 */
  @Builder
  entryCard(title: ResourceStr, desc: ResourceStr, onPress: () => void) {
    Column() {
      PressableCard({ onPress: onPress }) {
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

            Text(desc)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›')
            .fontSize(20)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_16'),
          right: $r('app.float.app_spacing_16'),
          top: $r('app.float.app_spacing_16'),
          bottom: $r('app.float.app_spacing_16')
        })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_4'),
      bottom: $r('app.float.app_spacing_4')
    })
  }
}
