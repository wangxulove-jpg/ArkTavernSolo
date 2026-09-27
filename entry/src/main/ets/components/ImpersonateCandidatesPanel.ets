/**
 * ImpersonateCandidatesPanel 代写候选区(渲染在输入胶囊内部顶部)
 *
 * 设计:
 * - 自身不画底/不画描边:宿主 `ChatInputArea` 的胶囊已经提供模糊底与圆角,
 *   这里只做内容排布,视觉上与输入栏连成一块(此前是独立描边卡片,材质割裂)。
 * - 候选加序号,超出可用高度时列表内滚动,不再用 maxLines(3) 硬裁文本。
 * - 不持有 VM/服务:数据经 @Prop 传入,动作经回调上抛。
 */
import { ImpersonateCandidate } from '../models/ImpersonateCandidate';
import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct ImpersonateCandidatesPanel {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @Prop candidates: ImpersonateCandidate[] = [];
  @Prop isGenerating: boolean = false;
  onSelect?: (index: number) => void;
  onDismiss?: () => void;

  build() {
    Column() {
      // 头部:状态/条数 + 操作提示 + 关闭
      Row() {
        Text(this.candidates.length > 0
          ? `${this.candidates.length} 条候选`
          : '生成中…')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .fontStyle(this.candidates.length > 0 ? FontStyle.Normal : FontStyle.Italic)

        Blank()

        if (this.candidates.length > 0) {
          Text('点击填入')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }

        Text('✕')
          .fontSize(13)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .padding({ left: 10, right: 6, top: 4, bottom: 4 })
          .onClick(() => {
            if (this.onDismiss !== undefined) {
              this.onDismiss!();
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 2, top: 6, bottom: 2 })

      // 候选列表:内容自然展开,超出 200 时列表内滚动
      List({ space: 6 }) {
        ForEach(this.candidates, (candidate: ImpersonateCandidate) => {
          ListItem() {
            Row() {
              Text(`${candidate.index + 1}`)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .textAlign(TextAlign.Center)
                .width(18)
                .height(18)
                .borderRadius(18)
                .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })

              Text(candidate.content)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .layoutWeight(1)
                .margin({ left: 8 })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .borderRadius($r('app.float.app_radius_md'))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .onClick(() => {
              if (this.onSelect !== undefined) {
                this.onSelect!(candidate.index);
              }
            })
          }
        }, (candidate: ImpersonateCandidate) => candidate.index.toString())
      }
      .width('100%')
      .constraintSize({ maxHeight: 200 })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
      .padding({ left: 8, right: 8, bottom: 8 })
    }
    .width('100%')
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
  }
}
