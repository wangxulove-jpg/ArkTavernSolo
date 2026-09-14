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
 * 顶栏/分组标题/入口卡统一复用 ui 原语(AppTopBar/AppSectionHeader/AppEntryCard)。
 */

import { AppTopBar } from '../../components/ui/AppTopBar';
import { AppSectionHeader } from '../../components/ui/AppSectionHeader';
import { AppEntryCard } from '../../components/ui/AppEntryCard';
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
            Text($r('app.string.tab_settings_desc'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({
                left: $r('app.float.app_spacing_16'),
                right: $r('app.float.app_spacing_16'),
                bottom: $r('app.float.app_spacing_12')
              })

            // ===== AI 与对话 =====
            AppSectionHeader({ title: $r('app.string.tab_settings_section_ai') })

            AppEntryCard({
              title: $r('app.string.tab_settings_model'),
              desc: $r('app.string.tab_settings_model_desc'),
              onPress: () => {
                router.pushUrl({ url: 'pages/ModelSettingsPage' });
              }
            })

            AppEntryCard({
              title: $r('app.string.tab_settings_lorebook'),
              desc: $r('app.string.tab_settings_lorebook_desc'),
              onPress: () => {
                router.pushUrl({ url: 'pages/LorebookPage' });
              }
            })

            AppEntryCard({
              title: $r('app.string.tab_settings_preset'),
              desc: $r('app.string.tab_settings_preset_desc'),
              onPress: () => {
                router.pushUrl({ url: 'pages/PromptPresetListPage' });
              }
            })

            // ===== 应用 =====
            AppSectionHeader({ title: $r('app.string.tab_settings_section_app') })

            AppEntryCard({
              title: $r('app.string.tab_settings_app_settings'),
              desc: $r('app.string.tab_settings_app_settings_desc'),
              onPress: () => {
                router.pushUrl({ url: 'pages/AppSettingsPage' });
              }
            })

            AppEntryCard({
              title: $r('app.string.sync_nav_title'),
              desc: $r('app.string.sync_nav_desc'),
              onPress: () => {
                router.pushUrl({ url: 'pages/SyncSettingsPage' });
              }
            })

            AppEntryCard({
              title: '语音朗读',
              desc: '使用系统语音引擎朗读角色回复',
              onPress: () => {
                router.pushUrl({ url: 'pages/TtsSettingsPage' });
              }
            })
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
}