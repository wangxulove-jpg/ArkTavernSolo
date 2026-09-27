/**
 * 从此处创建独立对话的模式选择弹窗。
 * 自 ChatPage.forkModePickerDialog 抽取(纯搬运,行为不变):
 * - 携带完整历史 / 只携带记忆 / 取消 / 点击遮罩关闭
 */
import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct ChatForkPicker {
  /** 当前主题(对应页面 effectiveTheme,变化时同步) */
  @Prop effectiveTheme: string = 'dark';
  /** 选择结果:true=携带完整历史,false=只携带记忆 */
  onPick: (fullHistory: boolean) => void = (_: boolean) => {};
  /** 取消或点击遮罩关闭 */
  onCancel: () => void = () => {};

  build() {
    Stack() {
      Column() {
        Text('从此处创建独立对话')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ top: 20, bottom: 8 })

        Text('选择新会话的初始内容范围,新会话与原会话后续完全独立。')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .lineHeight(20)
          .margin({ left: 16, right: 16, bottom: 12 })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

        // 携带完整历史
        Column() {
          Text('携带完整历史')
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ top: 12, bottom: 4 })
          Text('复制从根到当前消息的全部历史与记忆')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 8, bottom: 12 })
        .onClick(() => {
          this.onPick(true);
        })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

        // 只携带记忆
        Column() {
          Text('只携带记忆')
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ top: 12, bottom: 4 })
          Text('不复制旧消息,仅继承记忆摘要 + 最近 2 条消息')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 8, bottom: 12 })
        .onClick(() => {
          this.onPick(false);
        })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

        // 取消
        Text('取消')
          .fontSize(15)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .onClick(() => {
            this.onCancel();
          })
      }
      .width('80%')
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.onCancel();
    })
  }
}