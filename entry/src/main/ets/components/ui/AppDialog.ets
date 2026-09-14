/**
 * AppDialog 统一半屏/居中覆盖层原语(UI-Kit-3,薄组件)
 *
 * 纯 UI,不依赖任何 ViewModel / Service。
 * 吸收各页面内联的 Stack+scrim+Blank 推底面板副本:
 * - scrim = ThemeColors.scrim,点遮罩 onClose
 * - layout: 'bottom'(面板贴底,顶角 radius_xl,带手势区留白) / 'center'(居中卡片,radius_lg)
 * - 面板底 = ThemeColors.dialogBg
 * - actions: 底部按钮行(复用 AppButton),空则不渲染
 * - 动效:OPACITY + move(BOTTOM)(只组合单一 move)
 *
 * 消费:ThemePalette.forTheme().dialogBg/scrim + AppButton。禁止硬编码颜色/圆角。
 */

import { ThemePalette } from '../../theme/ThemePalette';
import { AppButton } from './AppButton';

/** 弹窗底部按钮项 */
export interface AppDialogAction {
  label: string;
  style: string;
  enabled: boolean;
  onTap: () => void;
}

@Component
export struct AppDialog {
  /** 是否显示 */
  visible: boolean = true;
  /** 标题(空则不显示) */
  title: string = '';
  /** 布局:'bottom' 贴底 / 'center' 居中卡片 */
  layout: string = 'bottom';
  /** 底部按钮行(空不渲染) */
  actions: AppDialogAction[] = [];
  /** 关闭回调(点遮罩触发) */
  onClose: () => void = () => {
  };
  /** 面板自定义内容 */
  @BuilderParam content: () => void;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  /** 面板背景色(dialogBg) */
  private panelBg(): ResourceColor {
    return ThemePalette.forTheme(this.effectiveTheme).dialogBg;
  }

  /** scrim 遮罩色 */
  private scrimColor(): ResourceColor {
    return ThemePalette.forTheme(this.effectiveTheme).scrim;
  }

  @Builder
  titleText() {
    if (this.title.length > 0) {
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ bottom: 16 })
    }
  }

  @Builder
  actionRow() {
    if (this.actions.length > 0) {
      Row() {
        ForEach(this.actions, (action: AppDialogAction, index: number) => {
          Column() {
            AppButton({
              variant: action.style,
              label: action.label,
              enabled: action.enabled,
              onPress: action.onTap
            })
          }.layoutWeight(1).margin({ left: index > 0 ? 12 : 0 })
        }, (action: AppDialogAction, index: number) => index.toString())
      }
      .width('100%')
      .margin({ top: 20 })
    }
  }

  @Builder
  panelBottom() {
    Column() {
      this.titleText()
      this.content()
      this.actionRow()
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 20, bottom: 28 })
    .backgroundColor(this.panelBg())
    .borderRadius({ topLeft: 22, topRight: 22 })
    .transition(TransitionEffect.OPACITY.combine(TransitionEffect.move(TransitionEdge.BOTTOM)))
    .onClick((event: ClickEvent) => {
      event.stopPropagation();
    })
  }

  @Builder
  panelCenter() {
    Column() {
      this.titleText()
      this.content()
      this.actionRow()
    }
    .width('86%')
    .padding(20)
    .backgroundColor(this.panelBg())
    .borderRadius(16)
    .transition(TransitionEffect.OPACITY)
    .onClick((event: ClickEvent) => {
      event.stopPropagation();
    })
  }

  build() {
    if (this.visible) {
      Stack() {
        if (this.layout === 'bottom') {
          this.panelBottom()
        } else {
          this.panelCenter()
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(this.layout === 'bottom' ? FlexAlign.End : FlexAlign.Center)
      .backgroundColor(this.scrimColor())
      .onClick(() => {
        this.onClose();
      })
    }
  }
}