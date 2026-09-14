/**
 * AppButton 通用按钮原语(UI-Kit-1,薄组件)
 *
 * 纯 UI,不依赖任何 ViewModel / Service / 数据库。
 * 统一四 Tab / 二级页 / 弹窗 / 空态的按钮视觉:
 * - variant: primary(accent 实底) / secondary(surface2+描边) / danger(危险实底) / text(透明+accent 字)
 * - shape: rounded(radius_lg) / capsule(高度一半)
 * - size: default(48) / small(40)
 * - loading 态显示 LoadingProgress 替代文案
 * - 按压 scale 0.97 + opacity 0.9(@140ms EaseOut)
 *
 * 消费:ThemePalette 静态取色器 + $r('app.float.*')。禁止硬编码颜色/圆角/高度。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct AppButton {
  /** 视觉变体:'primary' | 'secondary' | 'danger' | 'text' */
  variant: string = 'secondary';
  /** 形状:'rounded' | 'capsule' */
  shape: string = 'rounded';
  /** 尺寸:'default'(48) | 'small'(40) */
  size: string = 'default';
  /** 按钮文案(ResourceStr) */
  label: ResourceStr = '';
  /** 可选前置图标(sys.symbol Resource) */
  icon: Resource | null = null;
  /** 是否可点 */
  enabled: boolean = true;
  /** 加载中(显示 LoadingProgress 替代文案) */
  loading: boolean = false;
  /** 点击回调 */
  onPress: () => void = () => {
  };
  /** 按压中(驱动缩放/透明度) */
  @State pressed: boolean = false;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 背景色:primary=accent / danger=danger / text=透明 / secondary=surface2 */
  private bgColorValue(): ResourceColor {
    const t: string = this.effectiveTheme;
    if (this.variant === 'primary') {
      return ThemePalette.accentColor(t);
    }
    if (this.variant === 'danger') {
      return ThemePalette.dangerColor(t);
    }
    if (this.variant === 'text') {
      return Color.Transparent;
    }
    return ThemePalette.surface2Color(t);
  }

  /** 文案/图标色:实底用 onAccent,text/secondary 用主题色 */
  private fgColorValue(): ResourceColor {
    const t: string = this.effectiveTheme;
    if (this.variant === 'primary' || this.variant === 'danger') {
      return $r('app.color.app_on_accent');
    }
    if (this.variant === 'text') {
      return ThemePalette.accentColor(t);
    }
    return ThemePalette.textPrimaryColor(t);
  }

  /** 边框色:secondary 用 divider;其余透明 */
  private borderColorValue(): ResourceColor {
    if (this.variant === 'secondary' && !this.pressed) {
      return ThemePalette.dividerColor(this.effectiveTheme);
    }
    return Color.Transparent;
  }

  /** 高度:default=48 / small=40 */
  private btnHeight(): number {
    return this.size === 'small' ? 40 : 48;
  }

  /** 圆角:capsule=高/2 / rounded=radius_lg(16) */
  private btnRadius(): number {
    if (this.shape === 'capsule') {
      return this.btnHeight() / 2;
    }
    return 16;
  }

  build() {
    Button() {
      Stack() {
        if (this.loading) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(this.fgColorValue())
        } else {
          Row() {
            if (this.icon !== null) {
              SymbolGlyph(this.icon)
                .fontSize(18)
                .fontColor([this.fgColorValue()])
                .margin({ right: 6 })
            }
            Text(this.label)
              .fontSize($r('app.float.app_font_body'))
              .fontColor(this.fgColorValue())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
        }
      }
      .width('100%')
      .height('100%')
    }
    .type(ButtonType.Normal)
    .width('100%')
    .height(this.btnHeight())
    .backgroundColor(this.bgColorValue())
    .borderRadius(this.btnRadius())
    .border({ width: 1, color: this.borderColorValue() })
    .padding({ left: 16, right: 16 })
    .enabled(this.enabled && !this.loading)
    .opacity((this.enabled && !this.loading) ? 1 : 0.4)
    .scale({ x: this.pressed ? 0.97 : 1, y: this.pressed ? 0.97 : 1 })
    .animation({ duration: 140, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
    .onClick(() => {
      this.onPress();
    })
  }
}