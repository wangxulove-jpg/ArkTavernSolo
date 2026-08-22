/**
 * AppSettingsPage 应用设置页面
 *
 * v9: 全局用户称呼设置入口。
 * v10 (ARK-UI-THEME-1): 新增"外观"区块,提供四种主题选择(跟随设备 / 浅色 / 深色 / 酒馆棕)。
 * - 通过 AppPreferences 读写 GLOBAL_USER_NAME_KEY
 * - 通过 ThemeManager(唯一主题 authority)读写主题模式,选择后立即应用
 * - 不存储 API Key / Authorization / 敏感数据
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { ThemeManager } from '../services/ThemeManager';
import { ThemeMode } from '../models/ThemeMode';
import { ThemePalette, ThemeColors } from '../theme/ThemePalette';
import { GLOBAL_USER_NAME_KEY } from '../services/ChatService';
import { motion } from '@kit.MultimodalAwarenessKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { TtsReadMode } from '../models/TtsReadMode';

/** 主题选项模型(供构建器使用) */
interface ThemeOption {
  mode: ThemeMode;
  title: Resource;
  desc: Resource;
}

@Entry
@Component
struct AppSettingsPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题(响应式,驱动预览色块) */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 当前输入的全局用户称呼(从 AppPreferences 加载) */
  @State globalUserName: string = '';
  /** 保存中 */
  @State isSaving: boolean = false;
  /** 加载中 */
  @State isLoading: boolean = true;
  /** 错误提示(空表示无错误) */
  @State errorMessage: string = '';
  /** 当前选中的主题模式(内存镜像) */
  @State selectedThemeMode: ThemeMode = ThemeMode.FOLLOW_SYSTEM;
  /** 发送按钮位置: true = 左侧, false = 右侧 */
  @State sendButtonLeft: boolean = false;
  /** 智感握姿开关 */
  @State smartGripEnabled: boolean = false;
  /** 设备是否支持智感握姿 */
  @State smartGripSupported: boolean = true;
  /** TTS 朗读模式 */
  @State ttsReadMode: number = 0;
  /** TTS 语速 */
  @State ttsSpeed: number = 1.0;
  /** TTS 音量 */
  @State ttsVolume: number = 1.0;
  /** TTS 音调 */
  @State ttsPitch: number = 1.0;
  /** TTS 音色 person */
  @State ttsVoicePerson: number = 13;

  private preferences: AppPreferences | null = null;
  private themeManager: ThemeManager | null = null;

  aboutToAppear(): void {
    AppServices.whenReady().then(() => {
      this.preferences = AppServices.getAppPreferences();
      this.themeManager = AppServices.getThemeManager();
      this.selectedThemeMode = this.themeManager.getSelectedMode();
      this.loadGlobalUserName();
      this.loadSendButtonSettings();
      this.checkGripSupport();
      this.loadTtsSettings();
    }).catch(() => {
      this.errorMessage = 'AppServices 初始化失败';
      this.isLoading = false;
    });
  }

  private async loadGlobalUserName(): Promise<void> {
    if (this.preferences === null) {
      this.errorMessage = 'AppPreferences 未初始化';
      this.isLoading = false;
      return;
    }
    try {
      const value: string = await this.preferences.getString(GLOBAL_USER_NAME_KEY, '');
      this.globalUserName = value;
    } catch (e) {
      this.errorMessage = '加载失败';
    } finally {
      this.isLoading = false;
    }
  }

  private async saveGlobalUserName(): Promise<void> {
    if (this.preferences === null) {
      this.errorMessage = 'AppPreferences 未初始化';
      return;
    }
    this.isSaving = true;
    try {
      await this.preferences.putString(GLOBAL_USER_NAME_KEY, this.globalUserName.trim());
      promptAction.showToast({ message: $r('app.string.settings_global_user_name_saved') });
    } catch (e) {
      this.errorMessage = '保存失败';
      promptAction.showToast({ message: $r('app.string.settings_global_user_name_save_failed') });
    } finally {
      this.isSaving = false;
    }
  }

  /** 选择主题并立即应用(无需保存按钮) */
  private async selectTheme(mode: ThemeMode): Promise<void> {
    if (this.themeManager === null || this.selectedThemeMode === mode) {
      return;
    }
    this.selectedThemeMode = mode;
    await this.themeManager.setThemeMode(mode);
  }

  private async loadSendButtonSettings(): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    try {
      const pos: string = await this.preferences.getString('chat_send_button_position', 'right');
      this.sendButtonLeft = pos === 'left';
      const grip: boolean = await this.preferences.getBoolean('chat_smart_grip_enabled', false);
      this.smartGripEnabled = grip;
    } catch (_e) {}
  }

  private async saveSendButtonPos(left: boolean): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.sendButtonLeft = left;
    try {
      await this.preferences.putString('chat_send_button_position', left ? 'left' : 'right');
    } catch (_e) {}
  }

  private async saveSmartGrip(enabled: boolean): Promise<void> {
    if (this.preferences === null) {
      return;
    }
    this.smartGripEnabled = enabled;
    try {
      await this.preferences.putBoolean('chat_smart_grip_enabled', enabled);
    } catch (_e) {}
  }

  private checkGripSupport(): void {
    try {
      const callback = (status: number): void => {};
      motion.on('holdingHandChanged', callback);
      motion.off('holdingHandChanged', callback);
      this.smartGripSupported = true;
    } catch (_e) {
      this.smartGripSupported = false;
    }
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

  /** 根据模式获取标题资源 */
  private themeTitle(mode: ThemeMode): Resource {
    if (mode === ThemeMode.LIGHT) {
      return $r('app.string.settings_theme_light');
    }
    if (mode === ThemeMode.DARK) {
      return $r('app.string.settings_theme_dark');
    }
    if (mode === ThemeMode.TAVERN) {
      return $r('app.string.settings_theme_tavern');
    }
    return $r('app.string.settings_theme_follow_system');
  }

  /** 根据模式获取说明资源 */
  private themeDesc(mode: ThemeMode): Resource {
    if (mode === ThemeMode.LIGHT) {
      return $r('app.string.settings_theme_light_desc');
    }
    if (mode === ThemeMode.DARK) {
      return $r('app.string.settings_theme_dark_desc');
    }
    if (mode === ThemeMode.TAVERN) {
      return $r('app.string.settings_theme_tavern_desc');
    }
    return $r('app.string.settings_theme_follow_system_desc');
  }

  /** 获取预览色块色板(跟随设备按有效主题取色) */
  private previewColors(mode: ThemeMode): ThemeColors {
    let effective: string = this.effectiveTheme;
    if (mode === ThemeMode.LIGHT) {
      effective = 'light';
    } else if (mode === ThemeMode.DARK) {
      effective = 'dark';
    } else if (mode === ThemeMode.TAVERN) {
      effective = 'tavern';
    }
    return ThemePalette.forTheme(effective);
  }

  build() {
    Column() {
      // 顶部标题栏
      Row() {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor([$r('app.color.page_primary_text')])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        Text($r('app.string.nav_app_settings_title'))
          .fontSize($r('app.float.nav_title_font_size'))
          .fontColor($r('app.color.page_primary_text'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ right: 40 })
      }
      .width('100%')
      .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)

      // 错误提示
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_4'),
            bottom: $r('app.float.app_spacing_4')
          })
      }

      if (this.isLoading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color($r('app.color.page_secondary_text'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            // ===== 外观:主题选择 =====
            Text($r('app.string.settings_theme_section'))
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ bottom: 12 })

            Text($r('app.string.settings_theme_title'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ bottom: 4 })

            Text($r('app.string.settings_theme_desc'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.page_secondary_text'))
              .width('100%')
              .margin({ bottom: 12 })

            this.themeOptionCard(ThemeMode.FOLLOW_SYSTEM)
            this.themeOptionCard(ThemeMode.LIGHT)
            this.themeOptionCard(ThemeMode.DARK)
            this.themeOptionCard(ThemeMode.TAVERN)

            // ===== 全局用户称呼分区 =====
            Text($r('app.string.settings_global_user_name_section'))
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ top: 24, bottom: 12 })

            Text($r('app.string.settings_global_user_name_label'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ bottom: 8 })

            TextInput({
              placeholder: $r('app.string.settings_global_user_name_placeholder'),
              text: this.globalUserName
            })
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .backgroundColor($r('app.color.app_surface_2'))
              .borderRadius($r('app.float.app_radius_md'))
              .height(48)
              .padding({ left: 16, right: 16 })
              .width('100%')
              .onChange((value: string) => {
                this.globalUserName = value;
              })

            Text($r('app.string.settings_global_user_name_hint'))
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.page_secondary_text'))
              .width('100%')
              .margin({ top: 8 })

            Button($r('app.string.character_edit_save'))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .backgroundColor($r('app.color.app_accent'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .width('100%')
              .margin({ top: 24 })
              .enabled(!this.isSaving)
              .onClick(() => {
                this.saveGlobalUserName();
              })

            // ===== 用户身份分区 =====
            Text('用户身份')
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ top: 24, bottom: 12 })

            Text('管理用户身份(Persona),用于在提示词中注入用户角色设定')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.page_secondary_text'))
              .width('100%')
              .margin({ bottom: 8 })

            Row() {
              Column() {
                Text('身份管理')
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.page_primary_text'))
                  .width('100%')
                Text('创建和管理用户身份')
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.page_secondary_text'))
                  .width('100%')
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(16)
                .fontColor([$r('app.color.page_secondary_text')])
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 12, bottom: 12 })
            .borderRadius($r('app.float.app_radius_md'))
            .backgroundColor($r('app.color.app_surface_1'))
            .border({ width: 1, color: $r('app.color.app_divider') })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              router.pushUrl({ url: 'pages/PersonaListPage' });
            })

            // ===== 云同步分区 =====
            Text('云同步')
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ top: 24, bottom: 12 })

            Text('通过坚果云 WebDAV 同步您的数据')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.page_secondary_text'))
              .width('100%')
              .margin({ bottom: 8 })

            Row() {
              Column() {
                Text($r('app.string.sync_nav_title'))
                  .fontSize($r('app.float.app_font_body'))
                  .fontColor($r('app.color.page_primary_text'))
                  .width('100%')
                Text($r('app.string.sync_nav_desc'))
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor($r('app.color.page_secondary_text'))
                  .width('100%')
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(16)
                .fontColor([$r('app.color.page_secondary_text')])
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 12, bottom: 12 })
            .borderRadius($r('app.float.app_radius_md'))
            .backgroundColor($r('app.color.app_surface_1'))
            .border({ width: 1, color: $r('app.color.app_divider') })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              router.pushUrl({ url: 'pages/SyncSettingsPage' });
            })

            // ===== 发送按钮分区 =====
            Text($r('app.string.settings_send_button_section'))
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ top: 24, bottom: 12 })

            // 按钮位置选择
            Text($r('app.string.settings_send_button_position'))
              .fontSize($r('app.float.app_font_body'))
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ bottom: 8 })

            Row() {
              this.positionOption(false)
              this.positionOption(true)
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)

            // 智感握姿开关
            if (this.smartGripSupported) {
              Row() {
                Column() {
                  Text($r('app.string.settings_smart_grip'))
                    .fontSize($r('app.float.app_font_body'))
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.page_primary_text'))
                    .width('100%')
                  Text($r('app.string.settings_smart_grip_desc'))
                    .fontSize($r('app.float.app_font_caption'))
                    .fontColor($r('app.color.page_secondary_text'))
                    .width('100%')
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Toggle({ type: ToggleType.Switch, isOn: this.smartGripEnabled })
                  .onChange((isOn: boolean) => {
                    this.saveSmartGrip(isOn);
                  })
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 12, bottom: 12 })
              .borderRadius($r('app.float.app_radius_md'))
              .backgroundColor($r('app.color.app_surface_1'))
              .border({ width: 1, color: $r('app.color.app_divider') })
              .margin({ top: 12 })
              .alignItems(VerticalAlign.Center)
            }

            // ===== 语音朗读 (TTS) 分区 =====
            Text('语音朗读')
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))
              .width('100%')
              .margin({ top: 24, bottom: 12 })

            Text('使用系统语音引擎朗读角色回复')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.page_secondary_text'))
              .width('100%')
              .margin({ bottom: 8 })

            // 朗读模式
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

            // 语速
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
            .padding({ left: 12, right: 12, top: 8, bottom: 0 })

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

            // 音色
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 主题选项卡片:名称 + 说明 + 小型颜色预览 + 当前选择标记 */
  @Builder
  themeOptionCard(mode: ThemeMode) {
    Column() {
      Row() {
        // 小型颜色预览(背景 / 表面 / 文字 / Accent 四色块)
        Column() {
          Column() {
            Row() {
              this.previewSwatch(this.previewColors(mode).pageBg, 1.0)
              this.previewSwatch(this.previewColors(mode).surface1, 1.0)
              this.previewSwatch(this.previewColors(mode).textPrimary, 0.6)
              this.previewSwatch(this.previewColors(mode).accent, 1.0)
            }
            .width('100%')
            .justifyContent(FlexAlign.Start)
          }
          .width(64)
          .height(40)
          .borderRadius(8)
          .backgroundColor(this.previewColors(mode).pageBg)
          .justifyContent(FlexAlign.Center)
          .padding({ left: 6, right: 6 })
          .border({ width: 1, color: this.previewColors(mode).border })
        }
        .margin({ right: 12 })

        Column() {
          Row() {
            Text(this.themeTitle(mode))
              .fontSize($r('app.float.app_font_body'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.page_primary_text'))

            if (this.selectedThemeMode === mode) {
              Text('✓')
                .fontSize(14)
                .fontColor($r('app.color.app_accent'))
                .margin({ left: 6 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(this.themeDesc(mode))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.page_secondary_text'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .borderRadius($r('app.float.app_radius_md'))
    .backgroundColor($r('app.color.app_surface_1'))
    .border({
      width: this.selectedThemeMode === mode ? 2 : 1,
      color: this.selectedThemeMode === mode ? $r('app.color.app_accent') : $r('app.color.app_divider')
    })
    .margin({ bottom: 8 })
    .onClick(() => {
      this.selectTheme(mode);
    })
  }

  /** 单个预览色块 */
  @Builder
  previewSwatch(color: string, opacity: number) {
    Text('')
      .width(10)
      .height(10)
      .borderRadius(2)
      .backgroundColor(color)
      .opacity(opacity)
      .margin({ right: 4 })
  }

  /** 发送按钮位置选项卡片 */
  @Builder
  positionOption(isLeft: boolean) {
    Column() {
      Row() {
        if (isLeft) {
          Stack() {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize(12)
              .fontColor([$r('app.color.app_on_accent')])
          }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor($r('app.color.app_accent'))
          .margin({ right: 6 })

          Text('')
            .width(60)
            .height(20)
            .borderRadius(4)
            .backgroundColor($r('app.color.app_surface_2'))
        } else {
          Text('')
            .width(60)
            .height(20)
            .borderRadius(4)
            .backgroundColor($r('app.color.app_surface_2'))
            .margin({ right: 6 })

          Stack() {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize(12)
              .fontColor([$r('app.color.app_on_accent')])
          }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor($r('app.color.app_accent'))
        }
      }
      .alignItems(VerticalAlign.Center)

      Text(isLeft
        ? $r('app.string.settings_send_button_position_left')
        : $r('app.string.settings_send_button_position_right'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.page_primary_text'))
        .margin({ top: 6 })
    }
    .layoutWeight(1)
    .padding({ top: 12, bottom: 12 })
    .borderRadius($r('app.float.app_radius_md'))
    .backgroundColor($r('app.color.app_surface_1'))
    .border({
      width: this.sendButtonLeft === isLeft ? 2 : 1,
      color: this.sendButtonLeft === isLeft ? $r('app.color.app_accent') : $r('app.color.app_divider')
    })
    .margin({ right: isLeft ? 8 : 0 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.saveSendButtonPos(isLeft);
    })
  }
}
