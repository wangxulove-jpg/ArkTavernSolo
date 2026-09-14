/**
 * AppInputField 通用输入框原语(UI-Kit-2,薄组件)
 *
 * 纯 UI,TextInput/TextArea 合一,统一输入区视觉:
 * - label:顶部小标题(caption textSecondary)
 * - 容器底 surface2,圆角 rounded(radius_lg)/capsule(999)
 * - 聚焦态:accent 描边 1vp;错误态:error 描边 + errorMsg 文案
 * - 单行高 48,多行最小高 96
 *
 * 消费:ThemePalette 静态取色器 + $r('app.float.*')。禁止硬编码颜色/圆角/高度。
 */

import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct AppInputField {
  /** 输入值(父持 @State,onChange 回写) */
  text: string = '';
  /** 占位符 */
  placeholder: string = '';
  /** 顶部小标题(空则不显示) */
  label: string = '';
  /** 帮助文案(正常态,空不显示) */
  helperText: string = '';
  /** 错误文案(非空即错误态) */
  errorMsg: string = '';
  /** 多行(TextArea) */
  multiline: boolean = false;
  /** 输入类型(单行) */
  type: InputType = InputType.Normal;
  /** 形状:'rounded' | 'capsule' */
  shape: string = 'rounded';
  /** 是否可编辑 */
  enabled: boolean = true;
  /** 输入回调 */
  onChange: (value: string) => void = (value: string) => {
  };
  /** 是否聚焦(驱动边框色) */
  @State focused: boolean = false;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 容器描边色:聚焦=accent / 有错=error / 否则透明 */
  private borderColorValue(): ResourceColor {
    if (this.errorMsg.length > 0) {
      return ThemePalette.dangerColor(this.effectiveTheme);
    }
    if (this.focused) {
      return ThemePalette.accentColor(this.effectiveTheme);
    }
    return Color.Transparent;
  }

  /** 圆角:胶囊使用大圆角,圆角走 radius_lg */
  private fieldRadius(): number {
    return this.shape === 'capsule' ? 999 : 16;
  }

  /** 单行态容器高度 */
  private singleHeight(): number {
    return 48;
  }

  @Builder
  inputArea() {
    if (this.multiline) {
      TextArea({
        text: this.text,
        placeholder: this.placeholder
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .constraintSize({ minHeight: 96 })
        .onChange((value: string) => {
          this.onChange(value);
        })
        .onFocus(() => {
          this.focused = true;
        })
        .onBlur(() => {
          this.focused = false;
        })
    } else {
      TextInput({
        placeholder: this.placeholder,
        text: this.text,
        type: this.type
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .padding({ left: 16, right: 16 })
        .height(this.singleHeight())
        .onChange((value: string) => {
          this.onChange(value);
        })
        .onFocus(() => {
          this.focused = true;
        })
        .onBlur(() => {
          this.focused = false;
        })
    }
  }

  build() {
    Column() {
      // 顶部小标题
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ bottom: 8 })
      }

      // 输入容器(带聚焦/错误边框)
      Column() {
        this.inputArea()
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius(this.fieldRadius())
      .border({ width: 1, color: this.borderColorValue() })

      // 帮助/错误文案
      if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.dangerColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 6 })
      } else if (this.helperText.length > 0) {
        Text(this.helperText)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .enabled(this.enabled)
    .alignItems(HorizontalAlign.Start)
  }
}