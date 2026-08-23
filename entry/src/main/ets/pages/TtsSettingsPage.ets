import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { TtsReadMode } from '../models/TtsReadMode';
import { TtsEngine } from '../models/TtsEngine';
import { TtsService } from '../services/TtsService';
import { EdgeTtsService } from '../services/EdgeTtsService';
import { common } from '@kit.AbilityKit';

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
  @State ttsEngine: number = 0;
  @State edgeVoiceName: string = 'zh-CN-XiaoxiaoNeural';
  @State edgeVoiceList: EdgeVoiceItem[] = [];
  @State edgeVoicesLoading: boolean = false;
  @State isLoading: boolean = true;
  @State showVoicePicker: boolean = false;
  @State isPreviewPlaying: boolean = false;

  private preferences: AppPreferences | null = null;
  private edgeService: EdgeTtsService = new EdgeTtsService();
  private offlineService: TtsService = new TtsService();

  aboutToAppear(): void {
    AppServices.whenReady().then(() => {
      this.preferences = AppServices.getAppPreferences();
      const ctx: common.Context = getContext(this) as common.Context;
      this.edgeService.setContext(ctx);
      this.loadTtsSettings();
    }).catch(() => {
      this.isLoading = false;
    });
  }

  aboutToDisappear(): void {
    this.edgeService.shutdown();
    this.offlineService.shutdown();
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
      const engine: string = await this.preferences.getString('tts_engine', '0');
      this.ttsEngine = parseInt(engine, 10);
      if (isNaN(this.ttsEngine)) {
        this.ttsEngine = 0;
      }
      const edgeVoice: string = await this.preferences.getString('tts_edge_voice', 'zh-CN-XiaoxiaoNeural');
      if (edgeVoice.length > 0) {
        this.edgeVoiceName = edgeVoice;
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

  private async saveTtsEngine(engine: number): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.ttsEngine = engine;
    try {
      await this.preferences.putString('tts_engine', String(engine));
    } catch (_e) {}
  }

  private async saveEdgeVoice(name: string): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.edgeVoiceName = name;
    this.showVoicePicker = false;
    try {
      await this.preferences.putString('tts_edge_voice', name);
    } catch (_e) {}
  }

  private async loadEdgeVoices(): Promise<void> {
    if (this.edgeVoiceList.length > 0) {
      this.showVoicePicker = true;
      return;
    }
    this.edgeVoicesLoading = true;
    const success: boolean = await this.edgeService.fetchVoices();
    if (success) {
      const voices: Object[] = this.edgeService.getChineseVoices() as Object[];
      const items: EdgeVoiceItem[] = [];
      for (let i = 0; i < voices.length; i++) {
        const v: Record<string, string> = voices[i] as Record<string, string>;
        items.push({
          shortName: v['ShortName'] ?? '',
          gender: v['Gender'] ?? '',
          locale: v['Locale'] ?? '',
          friendlyName: v['FriendlyName'] ?? ''
        });
      }
      this.edgeVoiceList = items;
      this.showVoicePicker = true;
    }
    this.edgeVoicesLoading = false;
  }

  private getEdgeVoiceDisplay(): string {
    for (let i = 0; i < this.edgeVoiceList.length; i++) {
      if (this.edgeVoiceList[i].shortName === this.edgeVoiceName) {
        const v: EdgeVoiceItem = this.edgeVoiceList[i];
        const genderLabel: string = v.gender === 'Male' ? '(男)' : '(女)';
        return v.shortName + ' ' + genderLabel;
      }
    }
    return this.edgeVoiceName;
  }

  private previewVoice(): void {
    if (this.isPreviewPlaying) {
      this.stopPreview();
      return;
    }
    const sampleText: string = '你好，这是一段语音试听示例。今天天气真不错！';
    if (this.ttsEngine === TtsEngine.Edge) {
      this.edgeService.voiceName = this.edgeVoiceName;
      this.edgeService.speed = this.ttsSpeed;
      this.edgeService.volume = this.ttsVolume;
      this.edgeService.pitch = this.ttsPitch;
      this.edgeService.readMode = TtsReadMode.All;
      this.edgeService.speak(sampleText, (): void => {
        this.isPreviewPlaying = false;
      }, (): void => {
        this.isPreviewPlaying = true;
      });
      this.isPreviewPlaying = true;
    } else {
      this.offlineService.voicePerson = this.ttsVoicePerson;
      this.offlineService.speed = this.ttsSpeed;
      this.offlineService.volume = this.ttsVolume;
      this.offlineService.pitch = this.ttsPitch;
      this.offlineService.readMode = TtsReadMode.All;
      if (this.ttsVoicePerson === 8) {
        this.offlineService.language = 'en-US';
      } else {
        this.offlineService.language = 'zh-CN';
      }
      this.offlineService.speak(sampleText, (): void => {
        this.isPreviewPlaying = false;
      }, (): void => {
        this.isPreviewPlaying = true;
      });
    }
  }

  private stopPreview(): void {
    if (this.ttsEngine === TtsEngine.Edge) {
      this.edgeService.stop();
    } else {
      this.offlineService.stop();
    }
    this.isPreviewPlaying = false;
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
          Text('选择语音引擎和朗读参数')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.page_secondary_text'))
            .width('100%')
            .margin({ bottom: 12 })

          Row() {
            Text('语音引擎')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .layoutWeight(1)
            Row() {
              Button('离线')
                .fontSize(12)
                .height(28)
                .backgroundColor(this.ttsEngine === TtsEngine.Offline
                  ? $r('app.color.app_accent') : Color.Transparent)
                .fontColor(this.ttsEngine === TtsEngine.Offline
                  ? $r('app.color.app_on_accent') : $r('app.color.page_secondary_text'))
                .borderRadius(14)
                .padding({ left: 10, right: 10 })
                .onClick(() => { this.saveTtsEngine(TtsEngine.Offline); })
              Button('Edge在线')
                .fontSize(12)
                .height(28)
                .backgroundColor(this.ttsEngine === TtsEngine.Edge
                  ? $r('app.color.app_accent') : Color.Transparent)
                .fontColor(this.ttsEngine === TtsEngine.Edge
                  ? $r('app.color.app_on_accent') : $r('app.color.page_secondary_text'))
                .borderRadius(14)
                .padding({ left: 10, right: 10 })
                .onClick(() => { this.saveTtsEngine(TtsEngine.Edge); })
            }
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .borderRadius($r('app.float.app_radius_md'))
          .backgroundColor($r('app.color.app_surface_1'))
          .border({ width: 1, color: $r('app.color.app_divider') })
          .alignItems(VerticalAlign.Center)

          if (this.ttsEngine === TtsEngine.Edge) {
            Column() {
              Text('Edge TTS 使用微软在线神经语音，需联网，支持300+音色')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.page_secondary_text'))
                .width('100%')
                .margin({ bottom: 8 })

              Row() {
                Text('音色')
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.page_primary_text'))
                  .layoutWeight(1)
                Text(this.getEdgeVoiceDisplay())
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.app_accent'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 180 })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 12, bottom: 12 })
              .borderRadius($r('app.float.app_radius_md'))
              .backgroundColor($r('app.color.app_surface_2'))
              .border({ width: 1, color: $r('app.color.app_divider') })
              .alignItems(VerticalAlign.Center)
              .onClick(() => { this.loadEdgeVoices(); })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius($r('app.float.app_radius_md'))
            .backgroundColor($r('app.color.app_surface_1'))
            .border({ width: 1, color: $r('app.color.app_divider') })
            .margin({ top: 8 })
          }

          if (this.ttsEngine === TtsEngine.Offline) {
            Column() {
              Text('离线引擎使用系统内置语音，无需联网，音色较少')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor($r('app.color.page_secondary_text'))
                .width('100%')
                .margin({ bottom: 8 })

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
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius($r('app.float.app_radius_md'))
            .backgroundColor($r('app.color.app_surface_1'))
            .border({ width: 1, color: $r('app.color.app_divider') })
            .margin({ top: 8 })
          }

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
          .margin({ top: 8 })

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
            Button(this.isPreviewPlaying ? '停止试听' : '试听')
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.app_on_accent'))
              .backgroundColor(this.isPreviewPlaying
                ? $r('app.color.app_danger') : $r('app.color.app_accent'))
              .borderRadius($r('app.float.app_radius_md'))
              .width('100%')
              .height(40)
              .onClick(() => { this.previewVoice(); })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 16, bottom: 8 })
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

      if (this.showVoicePicker) {
        Column() {
          Row() {
            Text('选择音色')
              .fontSize($r('app.float.app_font_title'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .layoutWeight(1)
            Button('关闭')
              .fontSize(12)
              .height(28)
              .backgroundColor(Color.Transparent)
              .fontColor($r('app.color.page_secondary_text'))
              .onClick(() => { this.showVoicePicker = false; })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 8 })

          List() {
            ForEach(this.edgeVoiceList, (item: EdgeVoiceItem) => {
              ListItem() {
                Row() {
                  Radio({ value: item.shortName, group: 'edgeVoice' })
                    .checked(item.shortName === this.edgeVoiceName)
                    .onChange((isChecked: boolean) => {
                      if (isChecked) {
                        this.saveEdgeVoice(item.shortName);
                      }
                    })
                  Column() {
                    Text(item.shortName)
                      .fontSize(14)
                      .fontColor($r('app.color.page_primary_text'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(item.locale + ' · ' + (item.gender === 'Male' ? '男' : '女'))
                      .fontSize(12)
                      .fontColor($r('app.color.page_secondary_text'))
                      .margin({ top: 2 })
                  }
                  .layoutWeight(1)
                  .margin({ left: 12 })
                  .alignItems(HorizontalAlign.Start)
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              }
            }, (item: EdgeVoiceItem) => item.shortName)
          }
          .width('100%')
          .layoutWeight(1)
          .divider({ strokeWidth: 0.5, color: $r('app.color.app_divider') })
        }
        .width('100%')
        .height('60%')
        .backgroundColor($r('app.color.page_background'))
        .borderRadius({ topLeft: 16, topRight: 16 })
        .shadow({ radius: 16, color: '#66000000', offsetY: -4 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

interface EdgeVoiceItem {
  shortName: string;
  gender: string;
  locale: string;
  friendlyName: string;
}
