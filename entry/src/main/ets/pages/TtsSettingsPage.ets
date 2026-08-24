import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { TtsReadMode } from '../models/TtsReadMode';
import { TtsEngine } from '../models/TtsEngine';
import { TtsService } from '../services/TtsService';
import { EdgeTtsService } from '../services/EdgeTtsService';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';

// 精选普通话/国语女声（以下都已验证在当前 Edge TTS 音色列表中真实存在；
// 曾被移除的 晓墨/晓睿/晓涵 等已全部去掉，避免选中后被服务端以
// “1007 Unsupported voice” 拒绝而无声）。
const PRESET_FEMALE_CN_VOICES: string[] = [
  'zh-CN-XiaoxiaoNeural',
  'zh-CN-XiaoyiNeural',
  'zh-CN-liaoning-XiaobeiNeural',
  'zh-CN-shaanxi-XiaoniNeural',
  'zh-TW-HsiaoYuNeural',
  'zh-TW-HsiaoChenNeural'
];

const PRESET_VOICE_LABELS: Record<string, string> = {
  'zh-CN-XiaoxiaoNeural': '晓晓·普通话',
  'zh-CN-XiaoyiNeural': '晓伊·普通话',
  'zh-CN-liaoning-XiaobeiNeural': '晓北·东北',
  'zh-CN-shaanxi-XiaoniNeural': '晓妮·西北',
  'zh-TW-HsiaoYuNeural': '小雨·台湾国语',
  'zh-TW-HsiaoChenNeural': '晓臻·台湾国语'
};

const TAGS_PREF_KEY: string = 'tts_edge_voice_tags';

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
  @State allVoices: EdgeVoiceItem[] = [];
  @State edgePresets: EdgeVoiceItem[] = [];
  @State voiceTags: Record<string, string> = {};
  @State edgeVoicesLoading: boolean = false;
  @State isLoading: boolean = true;
  @State showVoicePicker: boolean = false;
  @State isPreviewPlaying: boolean = false;
  // 标签编辑弹窗状态
  @State showTagEditor: boolean = false;
  @State tagEditingName: string = '';
  @State tagInput: string = '';

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
      // 读取音色自定义标签
      const tagRaw: string = await this.preferences.getString(TAGS_PREF_KEY, '{}');
      try {
        const parsed: Record<string, string> = JSON.parse(tagRaw) as Record<string, string>;
        this.voiceTags = parsed;
      } catch (_e) {
        this.voiceTags = {};
      }
      this.edgePresets = this.buildPresets();
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
    this.edgeService.voiceName = name;
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
      const all: EdgeVoiceItem[] = [];
      const others: EdgeVoiceItem[] = [];
      for (let i = 0; i < voices.length; i++) {
        const v: Record<string, string> = voices[i] as Record<string, string>;
        const shortName: string = v['ShortName'] ?? '';
        const item: EdgeVoiceItem = {
          shortName: shortName,
          gender: v['Gender'] ?? '',
          locale: v['Locale'] ?? '',
          friendlyName: v['FriendlyName'] ?? '',
          tag: (this.voiceTags[shortName] ?? ''),
          isPreset: PRESET_FEMALE_CN_VOICES.indexOf(shortName) >= 0
        };
        all.push(item);
        // 精选女声单独放在“推荐女声”区，其余进“全部中文音色”，避免重复
        if (!item.isPreset) {
          others.push(item);
        }
      }
      this.allVoices = all;
      this.edgeVoiceList = others;
      this.edgePresets = this.buildPresets();
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
    // 当前音色可能是精选女声（不在全部列表里）
    for (let i = 0; i < this.edgePresets.length; i++) {
      if (this.edgePresets[i].shortName === this.edgeVoiceName) {
        const v: EdgeVoiceItem = this.edgePresets[i];
        const genderLabel: string = '（女）';
        return this.presetDisplayName(v) + ' ' + genderLabel;
      }
    }
    return this.edgeVoiceName;
  }

  // 构建精选普通话/国语女声列表（按固定顺序，附带标签）。
  // 若已成功拉取在线音色列表（allVoices 非空），则严格从列表里挑选，确保选中
  // 的音色都真实存在；否则回退到上面已验证存在的固定名单。
  private buildPresets(): EdgeVoiceItem[] {
    const result: EdgeVoiceItem[] = [];
    if (this.allVoices.length === 0) {
      for (let i = 0; i < PRESET_FEMALE_CN_VOICES.length; i++) {
        const shortName: string = PRESET_FEMALE_CN_VOICES[i];
        result.push({
          shortName: shortName,
          gender: 'Female',
          locale: shortName.indexOf('zh-TW') === 0 ? 'zh-TW' : 'zh-CN',
          friendlyName: PRESET_VOICE_LABELS[shortName] ?? shortName,
          tag: (this.voiceTags[shortName] ?? ''),
          isPreset: true
        });
      }
      return result;
    }
    // 已拉取列表：先按固定顺序加入精选，再从在线列表补充其他女声
    const added: Record<string, boolean> = {};
    for (let i = 0; i < PRESET_FEMALE_CN_VOICES.length; i++) {
      const shortName: string = PRESET_FEMALE_CN_VOICES[i];
      const item: EdgeVoiceItem | null = this.findVoice(shortName);
      if (item !== null) {
        result.push({
          shortName: item.shortName,
          gender: item.gender,
          locale: item.locale,
          friendlyName: this.shortDisplayName(item),
          tag: (this.voiceTags[item.shortName] ?? ''),
          isPreset: true
        });
        added[item.shortName] = true;
      }
    }
    for (let i = 0; i < this.allVoices.length; i++) {
      const it: EdgeVoiceItem = this.allVoices[i];
      if (it.gender === 'Female' && added[it.shortName] !== true) {
        result.push({
          shortName: it.shortName,
          gender: it.gender,
          locale: it.locale,
          friendlyName: this.shortDisplayName(it),
          tag: (this.voiceTags[it.shortName] ?? ''),
          isPreset: true
        });
        added[it.shortName] = true;
      }
      if (result.length >= 20) {
        break;
      }
    }
    return result;
  }

  private findVoice(shortName: string): EdgeVoiceItem | null {
    for (let i = 0; i < this.allVoices.length; i++) {
      if (this.allVoices[i].shortName === shortName) {
        return this.allVoices[i];
      }
    }
    return null;
  }

  // 用在线列表里的中文友好名做展示；取短名（如 “HiuGaai”）而非完整长名
  private shortDisplayName(item: EdgeVoiceItem): string {
    const label: string = PRESET_VOICE_LABELS[item.shortName] ?? '';
    if (label.length > 0) {
      return label;
    }
    let name: string = item.friendlyName;
    if (name.startsWith('Microsoft ')) {
      name = name.substring('Microsoft '.length);
    }
    const idxOnline: number = name.indexOf(' Online');
    if (idxOnline > 0) {
      name = name.substring(0, idxOnline);
    }
    if (name.length > 0) {
      return name;
    }
    return item.shortName;
  }

  private presetDisplayName(item: EdgeVoiceItem): string {
    if (item.friendlyName.length > 0 && item.friendlyName !== item.shortName) {
      return item.friendlyName;
    }
    return PRESET_VOICE_LABELS[item.shortName] ?? item.shortName;
  }

  // 打开标签编辑弹窗
  private openTagEditor(shortName: string): void {
    this.tagEditingName = shortName;
    this.tagInput = (this.voiceTags[shortName] ?? '');
    this.showTagEditor = true;
  }

  // 保存标签
  private async confirmTag(): Promise<void> {
    const tag: string = this.tagInput.trim();
    this.saveVoiceTag(this.tagEditingName, tag);
    this.showTagEditor = false;
    this.tagEditingName = '';
  }

  private cancelTag(): void {
    this.showTagEditor = false;
    this.tagEditingName = '';
    this.tagInput = '';
  }

  private async saveVoiceTag(shortName: string, tag: string): Promise<void> {
    const next: Record<string, string> = {};
    const keys: string[] = Object.keys(this.voiceTags);
    let wroteTag: boolean = false;
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (k === shortName) {
        if (tag.length > 0) {
          next[k] = tag;
          wroteTag = true;
        }
      } else {
        next[k] = this.voiceTags[k];
      }
    }
    if (!wroteTag && tag.length > 0) {
      next[shortName] = tag;
    }
    this.voiceTags = next;
    // 刷新精选列表与全部列表的标签显示
    this.edgePresets = this.buildPresets();
    const updated: EdgeVoiceItem[] = [];
    for (let i = 0; i < this.edgeVoiceList.length; i++) {
      const it: EdgeVoiceItem = this.edgeVoiceList[i];
      updated.push({
        shortName: it.shortName,
        gender: it.gender,
        locale: it.locale,
        friendlyName: it.friendlyName,
        tag: (this.voiceTags[it.shortName] ?? ''),
        isPreset: it.isPreset
      });
    }
    this.edgeVoiceList = updated;
    if (this.preferences !== null) {
      try {
        await this.preferences.putString(TAGS_PREF_KEY, JSON.stringify(this.voiceTags));
      } catch (_e) {}
    }
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
      }, (msg: string): void => {
        this.isPreviewPlaying = false;
        promptAction.showToast({ message: msg, duration: 2500 });
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
    Stack() {
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

                // 精选普通话女声（一键选择）
                Text('推荐女声（普通话）')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.page_primary_text'))
                  .width('100%')
                  .margin({ top: 12, bottom: 6 })

                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(this.edgePresets, (item: EdgeVoiceItem) => {
                    Text(this.presetDisplayName(item))
                      .fontSize(12)
                      .height(28)
                      .padding({ left: 12, right: 12 })
                      .borderRadius(14)
                      .backgroundColor(this.edgeVoiceName === item.shortName
                        ? $r('app.color.app_accent') : $r('app.color.app_surface_2'))
                      .fontColor(this.edgeVoiceName === item.shortName
                        ? $r('app.color.app_on_accent') : $r('app.color.page_primary_text'))
                      .border({ width: 1, color: item.tag.length > 0 ? $r('app.color.app_accent') : $r('app.color.app_divider') })
                      .margin({ top: 4, bottom: 4, left: 4, right: 4 })
                      .onClick(() => { this.saveEdgeVoice(item.shortName); })
                  }, (item: EdgeVoiceItem) => item.shortName)
                }
                .width('100%')
                .margin({ bottom: 8 })

                // 挑选中文音色并添加标签
                Row() {
                  Text('更多中文音色 · 自定义标签')
                    .fontSize(12)
                    .fontColor($r('app.color.app_accent'))
                    .layoutWeight(1)
                  Text('管理')
                    .fontSize(12)
                    .fontColor($r('app.color.app_accent'))
                    .onClick(() => { this.loadEdgeVoices(); })
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
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
              Text('标签 = 长按行内“标签”按钮编辑')
                .fontSize(12)
                .fontColor($r('app.color.page_secondary_text'))
                .margin({ right: 8 })
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
              ListItem() {
                Text('推荐女声（普通话）')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.app_accent'))
                  .width('100%')
                  .padding({ left: 16, top: 8, bottom: 4 })
              }
              ForEach(this.edgePresets, (item: EdgeVoiceItem) => {
                ListItem() {
                  this.voiceRow(item)
                }
              }, (item: EdgeVoiceItem) => 'p_' + item.shortName)

              ListItem() {
                Text('全部中文音色')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.app_accent'))
                  .width('100%')
                  .padding({ left: 16, top: 12, bottom: 4 })
              }
              ForEach(this.edgeVoiceList, (item: EdgeVoiceItem) => {
                ListItem() {
                  this.voiceRow(item)
                }
              }, (item: EdgeVoiceItem) => item.shortName)
            }
            .width('100%')
            .layoutWeight(1)
            .divider({ strokeWidth: 0.5, color: $r('app.color.app_divider') })
          }
          .width('100%')
          .height('70%')
          .backgroundColor($r('app.color.page_background'))
          .borderRadius({ topLeft: 16, topRight: 16 })
          .shadow({ radius: 16, color: '#66000000', offsetY: -4 })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 标签编辑弹窗
      if (this.showTagEditor) {
        Column() {
          Column() {
            Text('编辑标签')
              .fontSize($r('app.float.app_font_title'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .textAlign(TextAlign.Center)

            Text(this.tagEditingName)
              .fontSize(12)
              .fontColor($r('app.color.page_secondary_text'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 4 })

            TextInput({ placeholder: '给这个音色起个易记的标签，例如：温柔、御姐、播音…', text: this.tagInput })
              .width('100%')
              .height(44)
              .fontSize($r('app.float.app_font_body'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .margin({ top: 16 })
              .onChange((value: string) => { this.tagInput = value; })

            Row() {
              Button('取消')
                .fontSize($r('app.float.app_font_body'))
                .fontColor($r('app.color.page_secondary_text'))
                .backgroundColor(Color.Transparent)
                .borderRadius($r('app.float.app_radius_md'))
                .layoutWeight(1)
                .height(40)
                .onClick(() => { this.cancelTag(); })
              Button('保存')
                .fontSize($r('app.float.app_font_body'))
                .fontColor($r('app.color.app_on_accent'))
                .backgroundColor($r('app.color.app_accent'))
                .borderRadius($r('app.float.app_radius_md'))
                .layoutWeight(1)
                .height(40)
                .margin({ left: 12 })
                .onClick(() => { this.confirmTag(); })
            }
            .width('100%')
            .margin({ top: 16 })
          }
          .width('100%')
          .padding(20)
          .borderRadius($r('app.float.app_radius_md'))
          .backgroundColor($r('app.color.app_surface_1'))
          .border({ width: 1, color: $r('app.color.app_divider') })
          .shadow({ radius: 16, color: '#66000000', offsetY: -4 })
        }
        .width('88%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  private voiceRow(item: EdgeVoiceItem) {
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
        if (item.tag.length > 0) {
          Text('标签：' + item.tag)
            .fontSize(11)
            .fontColor($r('app.color.app_accent'))
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .margin({ left: 12 })
      .alignItems(HorizontalAlign.Start)

      Button(item.tag.length > 0 ? '改标签' : '加标签')
        .fontSize(11)
        .height(26)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_accent'))
        .border({ width: 1, color: $r('app.color.app_accent') })
        .borderRadius(13)
        .padding({ left: 10, right: 10 })
        .onClick(() => { this.openTagEditor(item.shortName); })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }
}

interface EdgeVoiceItem {
  shortName: string;
  gender: string;
  locale: string;
  friendlyName: string;
  tag: string;
  isPreset: boolean;
}
