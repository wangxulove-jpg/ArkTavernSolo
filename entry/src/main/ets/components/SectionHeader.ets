/**
 * SectionHeader 区块小标题
 *
 * UI-0 通用组件,纯 UI,不依赖任何业务实现。
 *
 * 用途:
 * - 在页面中作为分组小标题,出现在内容卡片上方
 * - 左对齐,字号偏小,辅助文字色
 *
 * 不处理:
 * - 右侧操作按钮(如有需要由调用方在外层 Row 自行组合)
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct SectionHeader {
  /** 区块标题(必填) */
  title: ResourceStr = '';
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build(): void {
    Text(this.title)
      .fontSize($r('app.float.app_font_caption'))
      .fontWeight(FontWeight.Medium)
      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20'),
        top: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_8')
      })
  }
}
