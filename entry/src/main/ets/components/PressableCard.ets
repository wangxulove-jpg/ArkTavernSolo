/**
 * PressableCard 可按压卡片容器
 *
 * UI-0 通用组件,纯 UI,不依赖任何业务实现。
 *
 * 用途:
 * - 作为可点击的卡片容器,内部内容由调用方通过 @BuilderParam 注入
 * - 提供轻微按压缩放反馈(0.98)
 * - 不提供阴影、不提供边框(由调用方按需在外层叠加)
 *
 * 动画:
 * - 按压缩放:140ms EaseOut
 * - 不引入循环动画
 *
 * 不处理:
 * - 内容布局(由调用方提供)
 * - 点击逻辑(由调用方通过 onPress 回调处理)
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct PressableCard {
  /** 是否处于按压状态(内部状态,不暴露) */
  @State isPressed: boolean = false;
  /** 点击回调 */
  onPress: () => void = () => {};
  /** 卡片背景色,默认一级表面色,可传入强调色表面营造主卡片 */
  surfaceColor: ResourceColor = $r('app.color.app_surface_1');
  /** 当前有效主题(ARK-UI-THEME-1) */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 内容构建器 */
  @BuilderParam content: () => void;

  /** 卡片背景:Tavern 使用酒馆棕一级表面,其余走资源限定符 */
  private cardBg(): ResourceColor {
    if (this.effectiveTheme === 'tavern') {
      return ThemePalette.forTheme('tavern').surface1;
    }
    return this.surfaceColor;
  }

  build(): void {
    Column() {
      this.content()
    }
    .width('100%')
    .backgroundColor(this.cardBg())
    .borderRadius($r('app.float.app_radius_md'))
    .scale({
      x: this.isPressed ? 0.98 : 1.0,
      y: this.isPressed ? 0.98 : 1.0
    })
    .animation({ duration: 140, curve: Curve.EaseOut })
    .onClick(() => {
      this.onPress();
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.isPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPressed = false;
      }
    })
  }
}
