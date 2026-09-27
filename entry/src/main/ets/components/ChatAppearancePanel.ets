/**
 * 聊天显示设置面板(自 ChatPage.appearanceSheetContent + colorSwatchRow + fontColorPreviewArea 抽取,纯搬运,行为不变)。
 *
 * 设计:组件不持有 VM/服务,依赖全部经 @Prop 值 + @Link + 回调上抛:
 * - 渲染态:effectiveTheme / chatTextStyle / chatTextColorMode / isDarkMode / 8 个自定义语义色
 * - 双向:chatAppearancePanelVisible(关闭按钮) / chatBubbleOpacity 与 chatContentHeightRatio(滑块)
 *         / colorPickerRequest(色盘请求,携带 target + 打开时当前色,由页面渲染全屏色盘覆盖层)
 * - 业务动作:全部回调上抛,由页面执行(Preferences 持久化、字体设置、恢复默认)
 */
import { ThemePalette } from '../theme/ThemePalette';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import {
  ChatTextColorMode,
  ChatMarkdownColorTheme,
  DEFAULT_BODY_TEXT_COLOR,
  DEFAULT_EMPHASIS_TEXT_COLOR,
  DEFAULT_DIALOGUE_TEXT_COLOR,
  DEFAULT_ACTION_TEXT_COLOR,
  DEFAULT_CODE_TEXT_COLOR,
  DEFAULT_LINK_TEXT_COLOR,
  DEFAULT_QUOTE_TEXT_COLOR,
  DEFAULT_USER_TEXT_COLOR,
  getLightColorTheme,
  getDarkColorTheme
} from '../utils/ChatTextColorTheme';

/** 自定义配色目标字段(语义化:正文/加粗斜体/对白/动作/代码/链接/引用/用户) */
export type CustomColorTarget =
  | 'body' | 'emphasis' | 'dialogue' | 'action'
  | 'code' | 'link' | 'quote' | 'user';

/**
 * 色盘打开请求:target + 打开时的当前色。
 * 页面的全屏色盘覆盖层据此渲染(初始色 + 实时写回的目标字段)。
 */
export interface ColorPickerRequest {
  target: CustomColorTarget;
  color: string;
}

@Component
export struct ChatAppearancePanel {
  /** 当前主题 */
  @Prop effectiveTheme: string = 'dark';
  /** 面板可见性(bindSheet 双向绑定;关闭按钮置 false) */
  @Link chatAppearancePanelVisible: boolean;
  /** 气泡不透明度(滑块双向,0.0~1.0) */
  @Link chatBubbleOpacity: number;
  /** 聊天显示范围比例(滑块双向,0.5~1.0) */
  @Link chatContentHeightRatio: number;
  /** 色盘请求(非空时页面渲染全屏色盘覆盖层) */
  @Link colorPickerRequest: ColorPickerRequest | null;
  /** 聊天文字样式(只读展示当前字号) */
  @Prop chatTextStyle: ChatTextStyle | null = null;
  /** 文字配色模式(只读;切换经回调) */
  @Prop chatTextColorMode: string = ChatTextColorMode.AUTO;
  /** 深色模式(预览气泡背景计算) */
  @Prop isDarkMode: boolean = false;
  /** 自定义语义色(只读;写入经回调) */
  @Prop bodyTextColor: string = DEFAULT_BODY_TEXT_COLOR;
  @Prop emphasisTextColor: string = DEFAULT_EMPHASIS_TEXT_COLOR;
  @Prop dialogueTextColor: string = DEFAULT_DIALOGUE_TEXT_COLOR;
  @Prop actionTextColor: string = DEFAULT_ACTION_TEXT_COLOR;
  @Prop codeTextColor: string = DEFAULT_CODE_TEXT_COLOR;
  @Prop linkTextColor: string = DEFAULT_LINK_TEXT_COLOR;
  @Prop quoteTextColor: string = DEFAULT_QUOTE_TEXT_COLOR;
  @Prop userTextColor: string = DEFAULT_USER_TEXT_COLOR;

  /** 气泡不透明度 clamp 到 [0,1](页面提供,与加载路径共用同一实现) */
  clampBubbleOpacity: (value: number) => number = (value: number): number => value;
  /** 持久化气泡不透明度(滑块松手/点击时) */
  onPersistBubbleOpacity: (value: number) => void = (_: number) => {};
  /** 持久化聊天显示范围比例(滑块松手/点击时) */
  onPersistContentHeightRatio: (ratio: number) => void = (_: number) => {};
  /** 应用字体大小(实时更新 ChatTextStyle) */
  onApplyFontSize: (fontSize: number) => void = (_: number) => {};
  /** 切换文字配色模式(含持久化) */
  onSelectTextColorMode: (mode: string) => void = (_: string) => {};
  /** 设置自定义颜色(点击预设色块;含持久化) */
  onSetCustomColor: (target: CustomColorTarget, color: string) => void =
    (_target: CustomColorTarget, _color: string) => {};
  /** 设置自定义颜色(色盘拖动实时预览,不持久化) */
  onSetCustomColorLive: (target: CustomColorTarget, color: string) => void =
    (_target: CustomColorTarget, _color: string) => {};
  /** 恢复默认文字配色(不修改气泡不透明度) */
  onResetTextColor: () => void = () => {};
  /** 全部恢复默认(气泡不透明度 + 文字配色) */
  onResetAllAppearance: () => void = () => {};

  build() {
    Scroll() {
      Column() {
        // 标题行
        Row() {
          Text('显示设置')
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          Blank()
          // 关闭按钮
          Stack() {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(14)
              .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .onClick(() => {
            this.chatAppearancePanelVisible = false;
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 12 })

        // ===== 气泡不透明度 =====
        Row() {
          Text('气泡不透明度')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Blank()
          Text(`${Math.round(this.chatBubbleOpacity * 100)}%`)
            .fontSize($r('app.float.app_font_caption'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        Slider({
          value: Math.round(this.chatBubbleOpacity * 100),
          min: 0,
          max: 100,
          step: 10,
          style: SliderStyle.OutSet
        })
          .blockColor(ThemePalette.accentColor(this.effectiveTheme))
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
          .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            const opacity: number = this.clampBubbleOpacity(value / 100);
            this.chatBubbleOpacity = opacity;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onPersistBubbleOpacity(opacity);
            }
          })

        Row() {
          Text('0%')
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Blank()
          Text('100%')
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        }
        .width('100%')
        .margin({ top: 4 })

        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ top: 16, bottom: 12 })

        // ===== 聊天显示范围 (顶部压缩, 消息渐变淡出) =====
        Row() {
          Text('聊天显示范围')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Blank()
          Text(`${Math.round(this.chatContentHeightRatio * 100)}%`)
            .fontSize($r('app.float.app_font_caption'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        Slider({
          value: Math.round(this.chatContentHeightRatio * 100),
          min: 0,
          max: 100,
          step: 5,
          style: SliderStyle.OutSet
        })
          .blockColor(ThemePalette.accentColor(this.effectiveTheme))
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
          .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            const ratio: number = value / 100;
            this.chatContentHeightRatio = ratio;
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onPersistContentHeightRatio(ratio);
            }
          })

        Row() {
          Text('50%')
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Blank()
          Text('100%')
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        }
        .width('100%')
        .margin({ top: 4 })

        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ top: 16, bottom: 12 })

        // ===== 字体大小 =====
        Row() {
          Text('字体大小')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Blank()
          Text(this.chatTextStyle !== null ? this.chatTextStyle!.fontSize.toString() + 'fp' : '16fp')
            .fontSize($r('app.float.app_font_caption'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        Slider({
          value: this.chatTextStyle !== null ? this.chatTextStyle!.fontSize : 16,
          min: 12,
          max: 24,
          step: 1,
          style: SliderStyle.OutSet
        })
          .blockColor(ThemePalette.accentColor(this.effectiveTheme))
          .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
          .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
          .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
          .width('100%')
          .onChange((value: number, mode: SliderChangeMode) => {
            const fontSize: number = Math.round(value);
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onApplyFontSize(fontSize);
            }
          })

        Row() {
          Text('12fp')
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Blank()
          Text('24fp')
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        }
        .width('100%')
        .margin({ top: 4 })

        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ top: 16, bottom: 12 })

        // ===== 文字配色模式 =====
        Row() {
          Text('文字配色')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        // 模式按钮:自动 / 浅色 / 深色 / 自定义
        Row({ space: 6 }) {
          ForEach([
            ChatTextColorMode.AUTO,
            ChatTextColorMode.LIGHT,
            ChatTextColorMode.DARK,
            ChatTextColorMode.CUSTOM
          ], (mode: string) => {
            Button(this.getModeLabel(mode))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(this.chatTextColorMode === mode
                ? $r('app.color.app_on_accent')
                : ThemePalette.textPrimaryColor(this.effectiveTheme))
              .backgroundColor(this.chatTextColorMode === mode
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius(14)
              .height(28)
              .padding({ left: 10, right: 10 })
              .onClick(() => {
                this.onSelectTextColorMode(mode);
              })
          }, (mode: string) => mode)
        }
        .width('100%')

        // 对比度辅助提示
        Text('气泡较透明时建议使用浅色文字,气泡较不透明时可使用深色文字')
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 8 })

        // 快捷按钮:适合深色背景 / 适合浅色背景
        Row({ space: 8 }) {
          Button('适合深色背景')
            .fontSize(11)
            .fontColor(this.chatTextColorMode === ChatTextColorMode.LIGHT
              ? $r('app.color.app_on_accent')
              : ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(this.chatTextColorMode === ChatTextColorMode.LIGHT
              ? ThemePalette.accentColor(this.effectiveTheme)
              : Color.Transparent)
            .border({
              width: 1,
              color: ThemePalette.accentColor(this.effectiveTheme)
            })
            .borderRadius(12)
            .height(24)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.onSelectTextColorMode(ChatTextColorMode.LIGHT);
            })
          Button('适合浅色背景')
            .fontSize(11)
            .fontColor(this.chatTextColorMode === ChatTextColorMode.DARK
              ? $r('app.color.app_on_accent')
              : ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(this.chatTextColorMode === ChatTextColorMode.DARK
              ? ThemePalette.accentColor(this.effectiveTheme)
              : Color.Transparent)
            .border({
              width: 1,
              color: ThemePalette.accentColor(this.effectiveTheme)
            })
            .borderRadius(12)
            .height(24)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.onSelectTextColorMode(ChatTextColorMode.DARK);
            })
        }
        .width('100%')
        .margin({ top: 8 })

        // ===== 自定义配色(仅在 CUSTOM 模式下显示)=====
        if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
          Divider()
            .color(ThemePalette.dividerColor(this.effectiveTheme))
            .margin({ top: 12, bottom: 12 })

          Text('自定义配色')
            .fontSize($r('app.float.app_font_caption'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 8 })

          // 普通正文
          this.colorSwatchRow('普通正文', 'body')

          // 加粗/斜体
          this.colorSwatchRow('**加粗** / *斜体*', 'emphasis')

          // 对白 “”
          this.colorSwatchRow('“对白”', 'dialogue')

          // 动作/旁白 ()
          this.colorSwatchRow('(动作)', 'action')

          // 行内代码
          this.colorSwatchRow('`代码`', 'code')

          // 链接
          this.colorSwatchRow('[链接](url)', 'link')

          // 引用
          this.colorSwatchRow('> 引用', 'quote')

          // 用户消息文字
          this.colorSwatchRow('用户消息', 'user')
        }

        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ top: 12, bottom: 12 })

        // ===== 预览区域 =====
        Text('预览')
          .fontSize($r('app.float.app_font_caption'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 6 })

        this.fontColorPreviewArea()

        // ===== 恢复默认按钮 =====
        Row({ space: 8 }) {
          Button('恢复默认')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent)
            .borderRadius(8)
            .height(32)
            .padding({ left: 12, right: 12 })
            .enabled(!this.isChatTextColorDefault())
            .onClick(() => {
              this.onResetTextColor();
            })
          Button('全部恢复默认')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent)
            .borderRadius(8)
            .height(32)
            .padding({ left: 12, right: 12 })
            .enabled(this.chatBubbleOpacity !== 0.65 || !this.isChatTextColorDefault())
            .onClick(() => {
              this.onResetAllAppearance();
            })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding(16)
    }
    .scrollBar(BarState.Auto)
    .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .width('100%')
  }

  /**
   * 颜色色块行:标签 + 预设色块 + 色盘入口。
   * 仅在 CUSTOM 模式下渲染。
   * 色块点击即应用(经页面回调持久化),色盘入口上抛 colorPickerRequest。
   *
   * 注意:当前颜色通过 this.getCustomColorByTarget(target) 在 Builder 体内响应式获取,
   * 不通过参数传入,确保 @Prop 变化时选中标记和预览圆点立即更新。
   */
  @Builder
  colorSwatchRow(label: string, target: CustomColorTarget) {
    Column() {
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Blank()
        // 当前颜色预览圆点(响应式:访问组件内颜色属性)
        Stack()
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(this.getCustomColorByTarget(target))
          .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 6 })

      // 预设色块
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.presetSwatches, (swatch: string) => {
          Stack() {
            if (this.getCustomColorByTarget(target).toUpperCase() === swatch.toUpperCase()) {
              // 选中标记:勾选(按亮度自动选择深/浅勾色)
              Text('✓')
                .fontSize(12)
                .fontColor(this.isLightColor(swatch) ? '#171717' : '#FFFFFF')
                .fontWeight(FontWeight.Bold)
            }
          }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor(swatch)
          .border({
            width: this.getCustomColorByTarget(target).toUpperCase() === swatch.toUpperCase() ? 2 : 1,
            color: this.getCustomColorByTarget(target).toUpperCase() === swatch.toUpperCase()
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.dividerColor(this.effectiveTheme)
          })
          .margin({ right: 8, bottom: 6 })
          .onClick(() => {
            this.onSetCustomColor(target, swatch);
          })
        }, (swatch: string, index: number) => swatch + index.toString())
      }
      .width('100%')

      // 色盘选择(打开 HSV 色盘,无需手动输入 RGB / Hex 数字)
      Button('色盘选择')
        .type(ButtonType.Normal)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
        .borderRadius(8)
        .height(30)
        .width('100%')
        .onClick(() => {
          const request: ColorPickerRequest = {
            target: target,
            color: this.getCustomColorByTarget(target)
          };
          this.colorPickerRequest = request;
        })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  /**
   * 字体配色预览区域(固定演示文本,不发送消息,不调用网络)。
   * 颜色根据当前模式实时计算,立即更新。
   */
  @Builder
  fontColorPreviewArea() {
    Column({ space: 6 }) {
      // 普通正文
      Row() {
        Text('普通正文示例文字')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('body'))
      }
      .width('100%')

      // 加粗/斜体
      Row() {
        Text('**加粗** *斜体*')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('emphasis'))
      }
      .width('100%')

      // 对白
      Row() {
        Text('“这是对白内容”')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('dialogue'))
      }
      .width('100%')

      // 动作/旁白
      Row() {
        Text('(这是动作/旁白)')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('action'))
      }
      .width('100%')

      // 行内代码
      Row() {
        Text('`代码内容`')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('code'))
      }
      .width('100%')

      // 链接
      Row() {
        Text('链接文字')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('link'))
      }
      .width('100%')

      // 引用
      Row() {
        Text('> 引用内容')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('quote'))
      }
      .width('100%')

      // 用户消息预览(右对齐,带气泡背景)
      Row() {
        Text('用户消息')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('user'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(this.computeUserBubbleColor())
          .borderRadius(10)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(this.computeAssistantBubbleColor())
    .borderRadius(10)
  }

  /**
   * 根据 target 获取当前自定义颜色。
   *
   * 此方法在 @Builder colorSwatchRow / fontColorPreviewArea 内部调用,
   * 方法体内访问的 @Prop 颜色会被 ArkUI 依赖收集,
   * 任一变化时触发 Builder 重新执行,确保色块选中标记和预览圆点立即更新。
   *
   * 不能通过 @Builder 参数传递 currentColor:参数在调用时求值后被固定,
   * 不响应式追踪颜色属性变化,会导致点击预设色块后选中标记不刷新。
   */
  private getCustomColorByTarget(target: CustomColorTarget): string {
    if (target === 'body') {
      return this.bodyTextColor;
    }
    if (target === 'emphasis') {
      return this.emphasisTextColor;
    }
    if (target === 'dialogue') {
      return this.dialogueTextColor;
    }
    if (target === 'action') {
      return this.actionTextColor;
    }
    if (target === 'code') {
      return this.codeTextColor;
    }
    if (target === 'link') {
      return this.linkTextColor;
    }
    if (target === 'quote') {
      return this.quoteTextColor;
    }
    return this.userTextColor;
  }

  /**
   * 计算预览区域助手气泡背景色(基于当前气泡不透明度)。
   * 字体配色与气泡不透明度相互独立:此处仅用于预览背景渲染,
   * 不影响字体颜色,也不受字体模式影响。
   * 浅色模式下基底为白色,深色模式下基底为深灰,叠加 chatBubbleOpacity。
   */
  private computeAssistantBubbleColor(): string {
    const alpha: number = this.chatBubbleOpacity;
    if (this.isDarkMode) {
      // 深色模式:深灰底 0x2A2A2A,叠加 Alpha
      const r: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      const g: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      const b: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
    }
    // 浅色模式:白底 0xFFFFFF,叠加 Alpha 向透明过渡(与 0x000000 混合)
    const r: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    const g: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    const b: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
  }

  /**
   * 计算预览区域用户气泡背景色(品牌蓝 + 当前不透明度)。
   * 用户气泡背景与字体颜色独立,保持品牌色基调。
   */
  private computeUserBubbleColor(): string {
    const alpha: number = this.chatBubbleOpacity;
    // 品牌蓝 0x5B7CFA,叠加 Alpha
    const r: number = Math.round(0x5B * alpha + 0x00 * (1 - alpha));
    const g: number = Math.round(0x7C * alpha + 0x00 * (1 - alpha));
    const b: number = Math.round(0xFA * alpha + 0x00 * (1 - alpha));
    return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
  }

  /** 将 0~255 整数转为 2 位大写 Hex */
  private toHex2(value: number): string {
    const clamped: number = Math.max(0, Math.min(255, Math.round(value)));
    const hex: string = clamped.toString(16).toUpperCase();
    return hex.length === 1 ? '0' + hex : hex;
  }

  /**
   * 获取预览区域指定语义类型的颜色。
   * - CUSTOM:直接使用组件内当前自定义颜色
   * - LIGHT / DARK:使用对应预设主题字段
   * - AUTO:使用默认深色主题作为预览基准
   */
  private getPreviewColor(target: CustomColorTarget): string {
    if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
      return this.getCustomColorByTarget(target);
    }
    if (this.chatTextColorMode === ChatTextColorMode.LIGHT) {
      return this.themeField(getLightColorTheme(), target);
    }
    return this.themeField(getDarkColorTheme(), target);
  }

  /** 按 target 读取主题对象中对应的语义颜色字段。 */
  private themeField(theme: ChatMarkdownColorTheme, target: CustomColorTarget): string {
    switch (target) {
      case 'body':
        return theme.bodyColor;
      case 'emphasis':
        return theme.emphasisColor;
      case 'dialogue':
        return theme.dialogueColor;
      case 'action':
        return theme.actionColor;
      case 'code':
        return theme.codeColor;
      case 'link':
        return theme.linkColor;
      case 'quote':
        return theme.quoteColor;
      default:
        return theme.userColor;
    }
  }

  /** 判断字体配色是否处于默认状态(用于"恢复默认"按钮 enabled 状态) */
  private isChatTextColorDefault(): boolean {
    return this.chatTextColorMode === ChatTextColorMode.AUTO
      && this.bodyTextColor === DEFAULT_BODY_TEXT_COLOR
      && this.emphasisTextColor === DEFAULT_EMPHASIS_TEXT_COLOR
      && this.dialogueTextColor === DEFAULT_DIALOGUE_TEXT_COLOR
      && this.actionTextColor === DEFAULT_ACTION_TEXT_COLOR
      && this.codeTextColor === DEFAULT_CODE_TEXT_COLOR
      && this.linkTextColor === DEFAULT_LINK_TEXT_COLOR
      && this.quoteTextColor === DEFAULT_QUOTE_TEXT_COLOR
      && this.userTextColor === DEFAULT_USER_TEXT_COLOR;
  }

  /** 获取模式按钮显示文本 */
  private getModeLabel(mode: string): string {
    if (mode === ChatTextColorMode.AUTO) {
      return '自动';
    }
    if (mode === ChatTextColorMode.LIGHT) {
      return '浅色';
    }
    if (mode === ChatTextColorMode.DARK) {
      return '深色';
    }
    return '自定义';
  }

  /**
   * 预设色块列表(中性色 + 常用和谐色,取自 Tailwind 色板)。
   * 覆盖黑白灰 + 蓝/青/青绿/绿/黄绿/琥珀/橙/红/粉/紫,便于对白/动作/代码等语义类型快速取色。
   */
  private readonly presetSwatches: string[] = [
    '#FFFFFF', '#E5E7EB', '#9CA3AF', '#4B5563', '#1F2937', '#111827',
    '#3B82F6', '#60A5FA', '#06B6D4', '#14B8A6', '#10B981', '#34D399',
    '#84CC16', '#F59E0B', '#F97316', '#EF4444', '#EC4899', '#8B5CF6', '#A78BFA'
  ];

  /**
   * 判断色块是否为浅色(用于自动选择勾选标记的深/浅颜色)。
   * 基于相对亮度(0.299R + 0.587G + 0.114B),阈值 150。
   */
  private isLightColor(hex: string): boolean {
    let h: string = hex;
    if (h.length > 0 && h.charAt(0) === '#') {
      h = h.substring(1);
    }
    if (h.length !== 6) {
      return false;
    }
    const r: number = parseInt(h.substring(0, 2), 16);
    const g: number = parseInt(h.substring(2, 4), 16);
    const b: number = parseInt(h.substring(4, 6), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return false;
    }
    const luminance: number = 0.299 * r + 0.587 * g + 0.114 * b;
    return luminance > 150;
  }
}