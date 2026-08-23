import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { TtsReadMode } from '../models/TtsReadMode';

@Entry
@Component
struct TtsSettingsPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @State ttsReadMode: number = 0;
  @State ttsSpeed: number = 1.0;
  @State ttsVolume: number = 1.0;
  @State ttsPitch: number = 1.0;
  @State ttsVoicePerson: number = 13;
  @State isLoading: boolean = true;

  private preferences: AppPreferences | null = null;

  aboutToAppear(): void {
    AppServices.whenReady().then(() => {
      this.preferences = AppServices.getAppPreferences();
      this.loadTtsSettings();
    }).catch(() => {
      this.isLoading = false;
    });
  }

  private async loadTtsSettings(): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    try {
      const mode: string = await this.preferences.getString('tts_mode', '0');
      this.ttsReadMode = parseInt(mode, 10);
      if (isNaN(this.ttsReadMode)) {
        this.ttsReadMode = 0;
      }
      const speed: string = await this.preferences.getString('tts_speed', '1.0');
      this.ttsSpeed = parseFloat(speed);
      if (isNaN(this.ttsSpeed)) {
        this.ttsSpeed = 1.0;
      }
      const volume: string = await this.preferences.getString('tts_volume', '1.0');
      this.ttsVolume = parseFloat(volume);
      if (isNaN(this.ttsVolume)) {
        this.ttsVolume = 1.0;
      }
      const pitch: string = await this.preferences.getString('tts_pitch', '1.0');
      this.ttsPitch = parseFloat(pitch);
      if (isNaN(this.ttsPitch)) {
        this.ttsPitch = 1.0;
      }
      const person: string = await this.preferences.getString('tts_voice_person', '13');
      this.ttsVoicePerson = parseInt(person, 10);
      if (isNaN(this.ttsVoicePerson)) {
        this.ttsVoicePerson = 13;
      }
    } catch (_e) {}
    this.isLoading = false;
  }

  private async saveTtsMode(mode: number): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.ttsReadMode = mode;
    try {
      await this.preferences.putString('tts_mode', String(mode));
    } catch (_e) {}
  }

  private async saveTtsSpeed(speed: number): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.ttsSpeed = speed;
    try {
      await this.preferences.putString('tts_speed', String(speed));
    } catch (_e) {}
  }

  private async saveTtsVolume(volume: number): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.ttsVolume = volume;
    try {
      await this.preferences.putString('tts_volume', String(volume));
    } catch (_e) {}
  }

  private async saveTtsPitch(pitch: number): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.ttsPitch = pitch;
    try {
      await this.preferences.putString('tts_pitch', String(pitch));
    } catch (_e) {}
  }

  private async saveTtsVoicePerson(person: number): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.ttsVoicePerson = person;
    try {
      await this.preferences.putString('tts_voice_person', String(person));
    } catch (_e) {}
  }

  build() {
    Column() {
      Column() {
        Text('语音朗读')
          .fontSize($r('app.float.app_font_title'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.page_primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(44)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin({ top: this.statusBarHeight })

      Scroll() {
        Column() {
          Text('使用系统语音引擎朗读角色回复')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.page_secondary_text'))
            .width('100%')
            .margin({ bottom: 12 })

          Row() {
            Text('朗读模式')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .layoutWeight(1)
            Row() {
              Button('关闭')
                .fontSize(12)
                .height(28)
                .backgroundColor(this.ttsReadMode === TtsReadMode.Off
                  ? $r('app.color.app_accent') : Color.Transparent)
                .fontColor(this.ttsReadMode === TtsReadMode.Off
                  ? $r('app.color.app_on_accent') : $r('app.color.page_secondary_text'))
                .borderRadius(14)
                .padding({ left: 10, right: 10 })
                .onClick(() => { this.saveTtsMode(TtsReadMode.Off); })
              Button('全文')
                .fontSize(12)
                .height(28)
                .backgroundColor(this.ttsReadMode === TtsReadMode.All
                  ? $r('app.color.app_accent') : Color.Transparent)
                .fontColor(this.ttsReadMode === TtsReadMode.All
                  ? $r('app.color.app_on_accent') : $r('app.color.page_secondary_text'))
                .borderRadius(14)
                .padding({ left: 10, right: 10 })
                .onClick(() => { this.saveTtsMode(TtsReadMode.All); })
              Button('仅对白')
                .fontSize(12)
                .height(28)
                .backgroundColor(this.ttsReadMode === TtsReadMode.QuotesOnly
                  ? $r('app.color.app_accent') : Color.Transparent)
                .fontColor(this.ttsReadMode === TtsReadMode.QuotesOnly
                  ? $r('app.color.app_on_accent') : $r('app.color.page_secondary_text'))
                .borderRadius(14)
                .padding({ left: 10, right: 10 })
                .onClick(() => { this.saveTtsMode(TtsReadMode.QuotesOnly); })
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .borderRadius($r('app.float.app_radius_md'))
          .backgroundColor($r('app.color.app_surface_1'))
          .border({ width: 1, color: $r('app.color.app_divider') })
          .alignItems(VerticalAlign.Center)

          Row() {
            Text('语速')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .layoutWeight(1)
            Text(this.ttsSpeed.toFixed(1))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_secondary_text'))
              .width(30)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 16, bottom: 0 })

          Slider({
            value: this.ttsSpeed,
            min: 0.5,
            max: 2.0,
            step: 0.1,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .padding({ left: 12, right: 12 })
            .trackColor($r('app.color.app_divider'))
            .selectedColor($r('app.color.app_accent'))
            .onChange((value: number) => { this.saveTtsSpeed(value); })

          Row() {
            Text('音量')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .layoutWeight(1)
            Text(this.ttsVolume.toFixed(1))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_secondary_text'))
              .width(30)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 0 })

          Slider({
            value: this.ttsVolume,
            min: 0.0,
            max: 1.0,
            step: 0.1,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .padding({ left: 12, right: 12 })
            .trackColor($r('app.color.app_divider'))
            .selectedColor($r('app.color.app_accent'))
            .onChange((value: number) => { this.saveTtsVolume(value); })

          Row() {
            Text('音调')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .layoutWeight(1)
            Text(this.ttsPitch.toFixed(1))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_secondary_text'))
              .width(30)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 0 })

          Slider({
            value: this.ttsPitch,
            min: 0.5,
            max: 2.0,
            step: 0.1,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .padding({ left: 12, right: 12 })
            .trackColor($r('app.color.app_divider'))
            .selectedColor($r('app.color.app_accent'))
            .onChange((value: number) => { this.saveTtsPitch(value); })

          Row() {
            Text('音色')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .layoutWeight(1)
            Text(this.ttsVoicePerson === 21 ? '凌飞哲(男)' : this.ttsVoicePerson === 8 ? 'Laura(en)' : '聆小珊(女)')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_secondary_text'))
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 0 })

          Row() {
            Button('聆小珊(女)')
              .fontSize(12)
              .height(28)
              .backgroundColor(this.ttsVoicePerson === 13
                ? $r('app.color.app_accent') : Color.Transparent)
              .fontColor(this.ttsVoicePerson === 13
                ? $r('app.color.app_on_accent') : $r('app.color.page_secondary_text'))
              .borderRadius(14)
              .padding({ left: 10, right: 10 })
              .onClick(() => { this.saveTtsVoicePerson(13); })
            Button('凌飞哲(男)')
              .fontSize(12)
              .height(28)
              .backgroundColor(this.ttsVoicePerson === 21
                ? $r('app.color.app_accent') : Color.Transparent)
              .fontColor(this.ttsVoicePerson === 21
                ? $r('app.color.app_on_accent') : $r('app.color.page_secondary_text'))
              .borderRadius(14)
              .padding({ left: 10, right: 10 })
              .onClick(() => { this.saveTtsVoicePerson(21); })
            Button('Laura(en)')
              .fontSize(12)
              .height(28)
              .backgroundColor(this.ttsVoicePerson === 8
                ? $r('app.color.app_accent') : Color.Transparent)
              .fontColor(this.ttsVoicePerson === 8
                ? $r('app.color.app_on_accent') : $r('app.color.page_secondary_text'))
              .borderRadius(14)
              .padding({ left: 10, right: 10 })
              .onClick(() => { this.saveTtsVoicePerson(8); })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 4, bottom: 12 })
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_16'),
          right: $r('app.float.app_spacing_16'),
          top: $r('app.float.app_spacing_16'),
          bottom: 100
        })
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
