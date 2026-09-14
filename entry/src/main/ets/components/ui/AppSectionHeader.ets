/**
 * AppSectionHeader 统一分组小标题(UI-Kit-6,薄组件)
 *
 * 纯 UI,替代各页面内联的 sectionHeader 复本:caption(12) textTertiary Medium,
 * 顶 pad16 / 底 pad8,左对齐。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct AppSectionHeader {
  /** 标题 */
  title: ResourceStr = '';
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build() {
    Text(this.title)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_24'),
        bottom: $r('app.float.app_spacing_8')
      })
  }
}