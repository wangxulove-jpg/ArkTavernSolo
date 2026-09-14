/**
 * AppEntryCard 统一设置/列表入口卡片(UI-Kit-5,薄组件)
 *
 * 纯 UI,替代各页面内联的 entryCard 复本:
 * - 底座复用 PressableCard(不重造按压逻辑)
 * - Row = [title + desc 列 | trailing]
 * - trailing:'chevron'(›) / 'switch'(Toggle)
 *
 * 消费:PressableCard + ThemePalette。禁止硬编码颜色/圆角/内边距。
 */

import { ThemePalette } from '../../theme/ThemePalette';
import { PressableCard } from '../PressableCard';

@Component
export struct AppEntryCard {
  /** 标题 */
  title: ResourceStr = '';
  /** 描述(空不显示) */
  desc: string = '';
  /** 右侧图形:'chevron' | 'switch' */
  trail: string = 'chevron';
  /** switch 态的当前值 */
  switchValue: boolean = false;
  /** switch 值变化回调 */
  onSwitchChange: (value: boolean) => void = (value: boolean) => {
  };
  /** 点击回调 */
  onPress: () => void = () => {
  };
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  @Builder
  trailingView() {
    if (this.trail === 'switch') {
      Toggle({ type: ToggleType.Switch, isOn: this.switchValue })
        .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
        .onChange((isOn: boolean) => {
          this.onSwitchChange(isOn);
        })
    } else {
      Text('›')
        .fontSize(20)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
  }

  build() {
    PressableCard({ onPress: () => {
      this.onPress();
    } }) {
      Row() {
        Column() {
          Text(this.title)
            .fontSize($r('app.float.app_font_body'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          if (this.desc.length > 0) {
            Text(this.desc)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        this.trailingView()
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_16'),
        bottom: $r('app.float.app_spacing_16')
      })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }
}