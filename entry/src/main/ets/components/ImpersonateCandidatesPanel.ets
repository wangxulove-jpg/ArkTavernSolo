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
      Row() {
        Text('🎭')
          .fontSize(13)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))

        if (this.isGenerating && this.candidates.length === 0) {
          Text('生成中…')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .fontStyle(FontStyle.Italic)
            .margin({ left: 6 })
        }

        Blank()

        Text('✕')
          .fontSize(13)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            if (this.onDismiss !== undefined) {
              this.onDismiss!();
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 4, top: 8, bottom: 4 })

      Column({ space: 6 }) {
        ForEach(this.candidates, (candidate: ImpersonateCandidate) => {
          Text(candidate.content)
            .fontSize(13)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(12)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .onClick(() => {
              if (this.onSelect !== undefined) {
                this.onSelect!(candidate.index);
              }
            })
        }, (candidate: ImpersonateCandidate) => candidate.index.toString())
      }
      .width('100%')
      .padding({ left: 10, right: 10, bottom: 10 })
    }
    .width('100%')
    .clip(false)
    .hitTestBehavior(HitTestMode.BLOCK_HIERARCHY)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius({ topLeft: 12, topRight: 12, bottomLeft: 0, bottomRight: 0 })
    .border({
      width: { top: 1, left: 1, right: 1, bottom: 0 },
      color: ThemePalette.dividerColor(this.effectiveTheme)
    })
  }
}
