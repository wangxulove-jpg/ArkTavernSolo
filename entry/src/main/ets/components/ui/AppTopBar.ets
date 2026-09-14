/**
 * AppTopBar 统一顶部标题栏原语(UI-Kit-4,薄组件)
 *
 * 纯 UI,统一四 Tab 顶栏 + 二级页顶栏:
 * - 统一 top=statusBar+8 / bottom8 / 左右 spacing_20(消除各 Tab 4/8/8/12 差异)
 * - title: app_font_title(26) Bold textPrimary
 * - subtitle(可选): app_font_subtitle(16) accent(distinct 副标题观感)
 * - showBack:二级页返回(chevron.left + onBack)
 * - transparent=true:不设背景,透出 Index 根背景(tab 顶栏);否则 pageBg 填充(二级页)
 * - trailing:右侧操作位(导入/来源标识/齿轮等 @BuilderParam)
 *
 * 消费:ThemePalette 取色 + $r('app.float.*')。禁止硬编码颜色/内边距。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct AppTopBar {
  /** 主标题 */
  title: ResourceStr = '';
  /** 副标题(空不显示) */
  subtitle: string = '';
  /** 二级页返回? */
  showBack: boolean = false;
  /** 是否透出底色(默认 true,二级页设 false 用 pageBg 填充) */
  transparent: boolean = true;
  /** 返回回调(showBack 时) */
  onBack: () => void = () => {
  };
  /** 右侧操作区(调用方必须提供,无操作传空 @Builder) */
  @BuilderParam trailing: () => void;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build() {
    Column() {
      Row() {
        if (this.showBack) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
            .padding(8)
            .margin({ right: 4 })
            .onClick(() => {
              this.onBack();
            })
        }

        Column() {
          Text(this.title)
            .fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize($r('app.float.app_font_subtitle'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: 2 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.trailing()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      top: this.statusBarHeight + 8,
      bottom: $r('app.float.app_spacing_8')
    })
    .backgroundColor(this.transparent ? Color.Transparent : ThemePalette.pageBgColor(this.effectiveTheme))
  }
}