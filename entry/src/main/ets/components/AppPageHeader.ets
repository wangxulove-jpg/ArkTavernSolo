/**
 * AppPageHeader 应用页面顶部标题区
 *
 * UI-0 通用组件,纯 UI,不依赖任何业务 Service / Repository / 数据库。
 *
 * 用途:
 * - 首页或二级页面顶部展示应用 / 模块名称与简短副标题
 * - 左对齐,不嵌入返回按钮(返回按钮由 Navigation 系统标题栏管理)
 *
 * 设计:
 * - 标题:大字号,主文字色
 * - 副标题:中字号,强调色
 *
 * 不处理:
 * - 状态栏安全区(由调用方在 Navigation / NavDestination 处理)
 * - 滚动吸顶
 */

/**
 * AppPageHeader 应用页面顶部标题区
 *
 * UI-0 通用组件,纯 UI,不依赖任何业务 Service / Repository / 数据库。
 *
 * 用途:
 * - 首页或二级页面顶部展示应用 / 模块名称与简短副标题
 * - 左对齐,不嵌入返回按钮(返回按钮由 Navigation 系统标题栏管理)
 *
 * 设计:
 * - 标题:大字号,主文字色
 * - 副标题:中字号,强调色
 *
 * 不处理:
 * - 状态栏安全区(由调用方在 Navigation / NavDestination 处理)
 * - 滚动吸顶
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct AppPageHeader {
  /** 主标题(必填,通常为应用名或模块名) */
  title: ResourceStr = '';
  /** 副标题(必填,通常为英文名或分类) */
  subtitle: ResourceStr = '';
  /** 顶部状态栏避让高度(由 AppStorage 注入,默认 0 表示不避让) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 当前有效主题(ARK-UI-THEME-1,响应式驱动背景) */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build(): void {
    Column() {
      Text(this.title)
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(this.subtitle)
        .fontSize($r('app.float.app_font_subtitle'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      // 顶部 padding = 状态栏高度 + 间距 12(避开状态栏,避免顶部大块空白)
      top: this.statusBarHeight + 12,
      bottom: $r('app.float.app_spacing_12')
    })
    // 关键:加 backgroundColor,确保 expandSafeArea 状态栏区域被填充,
    // 同时作为固定顶栏时不透出下方滚动内容
    .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
  }
}
