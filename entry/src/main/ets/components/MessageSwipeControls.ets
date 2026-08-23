import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct MessageSwipeControls {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @Prop activeCandidateIndex: number = 0;
  @Prop candidateCount: number = 1;
  @Prop isGenerating: boolean = false;
  @Prop isOperable: boolean = false;
  onPrevious?: () => void;
  onNext?: () => void;
  onStop?: () => void;

  get isLeftDisabled(): boolean {
    if (this.isGenerating) {
      return true;
    }
    return this.activeCandidateIndex <= 0;
  }

  get isRightDisabled(): boolean {
    if (this.isGenerating) {
      return true;
    }
    return this.activeCandidateIndex >= this.candidateCount - 1;
  }

  get displayText(): string {
    const displayIndex: number = this.candidateCount > 0 ? this.activeCandidateIndex + 1 : 0;
    return `${displayIndex} / ${this.candidateCount}`;
  }

  get hasSwipeGroup(): boolean {
    return this.candidateCount > 1;
  }

  build() {
    Row() {
      if (this.isOperable) {
        if (this.hasSwipeGroup) {
          this.arrowButton('\u2039', this.isLeftDisabled, () => {
            this.onPrevious?.();
          })

          Text(this.displayText)
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)
            .width(56)

          this.arrowButton('\u203A', this.isRightDisabled, () => {
            this.onNext?.();
          })
        }

        if (this.isGenerating) {
          this.stopButton();
        }
      } else if (this.hasSwipeGroup) {
        Text(this.displayText)
          .fontSize(13)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .textAlign(TextAlign.Center)
      }
    }
    .width('100%')
    .height(this.shouldRenderEmpty ? 0 : 40)
    .padding({ left: 8, right: 8 })
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Start)
  }

  get shouldRenderEmpty(): boolean {
    return !this.hasSwipeGroup && !this.isOperable;
  }

  @Builder
  arrowButton(label: string, disabled: boolean, onClick: () => void) {
    Button(label)
      .fontSize(20)
      .fontWeight(FontWeight.Bold)
      .fontColor(disabled
        ? ThemePalette.textTertiaryColor(this.effectiveTheme)
        : ThemePalette.textPrimaryColor(this.effectiveTheme))
      .backgroundColor(Color.Transparent)
      .width(36)
      .height(36)
      .borderRadius(18)
      .enabled(!disabled)
      .onClick(() => {
        onClick();
      })
  }

  @Builder
  stopButton() {
    Button($r('app.string.chat_stop'))
      .fontSize(13)
      .fontColor($r('app.color.app_danger'))
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius(14)
      .height(28)
      .padding({ left: 12, right: 12 })
      .margin({ left: 8 })
      .onClick(() => {
        this.onStop?.();
      })
  }
}
