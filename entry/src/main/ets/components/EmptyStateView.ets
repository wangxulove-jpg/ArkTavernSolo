/**
 * EmptyStateView 空状态视图
 *
 * UI-0 通用组件,纯 UI,不依赖任何业务实现。
 *
 * 用途:
 * - 在列表 / 卡片为空时展示标题与描述
 * - 居中对齐,次文字色,字号偏小
 * - 也可用于加载失败、未配置等场景
 *
 * 不处理:
 * - 操作按钮(由调用方在下方自行追加)
 * - 图标(本轮不引入 SymbolGlyph / Image,保持纯文字)
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct EmptyStateView {
  /** 状态标题(必填) */
  title: ResourceStr = '';
  /** 状态描述(必填,可为空字符串) */
  description: ResourceStr = '';
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build(): void {
    Column() {
      Text(this.title)
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .width('100%')

      Text(this.description)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 6 })
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .padding({
      top: $r('app.float.app_spacing_24'),
      bottom: $r('app.float.app_spacing_24'),
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20')
    })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
