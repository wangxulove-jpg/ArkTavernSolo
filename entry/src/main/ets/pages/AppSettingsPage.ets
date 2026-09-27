/**
 * AppSettingsPage 应用设置页面
 *
 * v9: 全局用户称呼设置入口。
 * v10 (ARK-UI-THEME-1): 新增"外观"区块,提供四种主题选择(跟随设备 / 浅色 / 深色 / 酒馆棕)。
 * v11 (2026-09-27 设置页排版): 改为"分区小标题 + 紧凑卡片行"版式(与对话设置面板同一范式):
 * - 每个分区 = caption 小标题 + 一张 surface_1 卡片,卡内行高 44、1px 分隔线;
 * - 主题选择由竖向 4 张大卡改为一行 4 张竖条色块卡(仅保留三色预览 + 名称);
 * - 用户称呼改为行内输入 + 失焦/回车自动保存,不再有独立说明段与保存按钮;
 * - 用户身份 / 市场缓存 / 诊断日志 / 清空日志各压成单行,值右对齐、动作以胶囊呈现。
 * 通过 AppPreferences 读写 GLOBAL_USER_NAME_KEY;主题经 ThemeManager(唯一 authority)立即应用。
 * 不存储 API Key / Authorization / 敏感数据。
 */

import { router, promptAction } from '@kit.ArkUI';
import { picker, fileIo } from '@kit.CoreFileKit';
import { AppServices } from '../services/AppServices';
import { LogBuffer } from '../utils/LogBuffer';
import { AppPreferences } from '../storage/AppPreferences';
import { ThemeManager } from '../services/ThemeManager';
import { ThemeMode } from '../models/ThemeMode';
import { ThemePalette, ThemeColors } from '../theme/ThemePalette';
import { GLOBAL_USER_NAME_KEY } from '../services/ChatTextContract';
import { motion } from '@kit.MultimodalAwarenessKit';

@Entry
@Component
struct AppSettingsPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题(响应式,驱动预览色块) */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 当前输入的全局用户称呼(从 AppPreferences 加载) */
  @State globalUserName: string = '';
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
  /** 市场缓存大小文本(如 "128 KB") */
  @State marketCacheSize: string = '';
  /** 诊断日志缓冲条数 */
  @State logEntryCount: number = 0;

  private preferences: AppPreferences | null = null;
  private themeManager: ThemeManager | null = null;
  /** 最近一次成功落盘的用户称呼(用于失焦自动保存时跳过无变化的写入) */
  private lastSavedUserName: string = '';

  aboutToAppear(): void {
    this.logEntryCount = LogBuffer.getEntryCount();
    AppServices.whenReady().then(() => {
      this.preferences = AppServices.getAppPreferences();
      this.themeManager = AppServices.getThemeManager();
      this.selectedThemeMode = this.themeManager.getSelectedMode();
      this.loadGlobalUserName();
      this.loadSendButtonSettings();
      this.checkGripSupport();
      this.loadMarketCacheSize();
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
      this.lastSavedUserName = value;
    } catch (e) {
      this.errorMessage = '加载失败';
    } finally {
      this.isLoading = false;
    }
  }

  /** 失焦/回车时自动保存;内容未变化则跳过,避免重复写盘与重复提示 */
  private async saveGlobalUserNameIfChanged(): Promise<void> {
    const trimmed: string = this.globalUserName.trim();
    if (trimmed === this.lastSavedUserName) {
      return;
    }
    if (this.preferences === null) {
      this.errorMessage = 'AppPreferences 未初始化';
      return;
    }
    try {
      await this.preferences.putString(GLOBAL_USER_NAME_KEY, trimmed);
      this.lastSavedUserName = trimmed;
      this.globalUserName = trimmed;
      promptAction.showToast({ message: $r('app.string.settings_global_user_name_saved') });
    } catch (e) {
      this.errorMessage = '保存失败';
      promptAction.showToast({ message: $r('app.string.settings_global_user_name_save_failed') });
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

  /** 弹出确认框,确认后清除市场缓存 */
  private confirmClearMarketCaches(): void {
    promptAction.showDialog({
      title: $r('app.string.settings_market_cache_clear_confirm_title'),
      message: $r('app.string.settings_market_cache_clear_confirm_message'),
      buttons: [
        {
          text: $r('app.string.settings_market_cache_clear_confirm_ok'),
          color: $r('app.color.app_danger')
        },
        {
          text: $r('app.string.market_cancel'),
          color: $r('app.color.page_secondary_text')
        }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 0) {
        void this.clearMarketCaches();
      }
    }).catch(() => {});
  }

  private async clearMarketCaches(): Promise<void> {
    try {
      await AppServices.getMarketService().clearMarketCaches();
      this.loadMarketCacheSize();
      promptAction.showToast({ message: $r('app.string.settings_market_cache_cleared') });
    } catch (e) {
      promptAction.showToast({ message: $r('app.string.settings_market_cache_clear_failed') });
    }
  }

  /** 加载并格式化市场缓存大小 */
  private async loadMarketCacheSize(): Promise<void> {
    try {
      const bytes: number = await AppServices.getMarketService().getCacheSizeBytes();
      this.marketCacheSize = this.formatBytes(bytes);
    } catch (e) {
      this.marketCacheSize = '';
    }
  }

  /** 导出诊断日志:拼接缓冲文本,通过系统保存选择器写入用户选择的位置 */
  private async exportLogs(): Promise<void> {
    try {
      const text: string = LogBuffer.getLogText();
      if (text.trim().length === 0) {
        promptAction.showToast({ message: '暂无日志可导出' });
        return;
      }
      // 同步落盘一份磁盘镜像(导出的文本本身来自内存缓冲,落盘只为崩溃后留底)
      LogBuffer.flushToDisk().catch(() => {});
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [this.buildLogFileName()];
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      const file: fileIo.File = fileIo.openSync(
        uris[0], fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(file.fd, text);
      } finally {
        fileIo.closeSync(file);
      }
      promptAction.showToast({ message: '日志已导出' });
    } catch (e) {
      promptAction.showToast({
        message: '导出失败: ' + (e instanceof Error ? e.message : String(e))
      });
    }
  }

  /** 生成导出文件名:arktavern_log_YYYYMMDD_HHmmss.txt */
  private buildLogFileName(): string {
    const d: Date = new Date();
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return 'arktavern_log_' + d.getFullYear().toString()
      + pad(d.getMonth() + 1) + pad(d.getDate())
      + '_' + pad(d.getHours()) + pad(d.getMinutes()) + pad(d.getSeconds())
      + '.txt';
  }

  /** 弹出确认框,确认后清空诊断日志 */
  private confirmClearLogs(): void {
    promptAction.showDialog({
      title: '清空日志',
      message: '将清空内存缓冲与已落盘的日志,该操作不可恢复。确定清空吗?',
      buttons: [
        { text: '清空', color: $r('app.color.app_danger') },
        { text: $r('app.string.market_cancel'), color: $r('app.color.page_secondary_text') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 0) {
        LogBuffer.clear();
        this.logEntryCount = 0;
        promptAction.showToast({ message: '日志已清空' });
      }
    }).catch(() => {});
  }

  /** 字节数格式化为可读文本 */
  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return bytes.toString() + ' B';
    }
    if (bytes < 1024 * 1024) {
      return (bytes / 1024).toFixed(1) + ' KB';
    }
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
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
      .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 8 })
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
            // ===== 外观 =====
            this.sectionCaption($r('app.string.settings_theme_section'))
            Column() {
              this.themeRow()
            }
            .width('100%')
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_md'))

            // ===== 对话 =====
            this.sectionCaption('对话')
            Column() {
              this.userNameRow()
              this.sendPositionRow()
              if (this.smartGripSupported) {
                this.smartGripRow()
              }
            }
            .width('100%')
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_md'))

            // ===== 身份 =====
            this.sectionCaption('身份')
            Column() {
              this.valueRow('用户身份', '管理', true, false, (): void => {
                router.pushUrl({ url: 'pages/PersonaListPage' });
              })
            }
            .width('100%')
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_md'))

            // ===== 存储与诊断 =====
            this.sectionCaption('存储与诊断')
            Column() {
              this.actionRow('市场缓存', this.marketCacheSize,
                $r('app.string.settings_market_cache_clear_confirm_ok'), false, (): void => {
                  this.confirmClearMarketCaches();
                })
              this.actionRow('诊断日志', this.logEntryCount.toString() + ' 条', '导出', true, (): void => {
                this.exportLogs();
              })
              this.menuRow('清空日志', true, true, (): void => {
                this.confirmClearLogs();
              })
            }
            .width('100%')
            .backgroundColor($r('app.color.app_surface_1'))
            .borderRadius($r('app.float.app_radius_md'))
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            top: $r('app.float.app_spacing_4'),
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

  /** 分区小标题(与行内文字左对齐:卡片内边距 12 + 标题内边距 4) */
  @Builder
  sectionCaption(text: ResourceStr) {
    Text(text)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.page_secondary_text'))
      .width('100%')
      .padding({ left: 4, top: 16, bottom: 6 })
  }

  /** 行顶分隔线(卡片内非首行使用) */
  @Builder
  rowDivider() {
    Divider()
      .color($r('app.color.app_divider'))
      .margin({ left: 12, right: 12 })
  }

  /** 主题选择:一行四张竖条色块卡(三色预览 + 名称,选中加描边) */
  @Builder
  themeRow() {
    Row() {
      this.themeMiniCard(ThemeMode.FOLLOW_SYSTEM)
      this.themeMiniCard(ThemeMode.LIGHT)
      this.themeMiniCard(ThemeMode.DARK)
      this.themeMiniCard(ThemeMode.TAVERN)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  themeMiniCard(mode: ThemeMode) {
    Column() {
      Column() {
        Text('')
          .width('100%')
          .height(11)
          .backgroundColor(this.previewColors(mode).pageBg)
        Text('')
          .width('100%')
          .height(11)
          .backgroundColor(this.previewColors(mode).surface1)
        Text('')
          .width('100%')
          .height(11)
          .backgroundColor(this.previewColors(mode).textPrimary)
      }
      .width('100%')
      .borderRadius($r('app.float.app_radius_sm'))
      .clip(true)
      .border({ width: 1, color: $r('app.color.app_divider') })

      Text(this.themeTitle(mode))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(this.selectedThemeMode === mode
          ? $r('app.color.app_accent')
          : $r('app.color.page_secondary_text'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .margin({ left: 4, right: 4 })
    .padding(4)
    .borderRadius($r('app.float.app_radius_sm'))
    .border({
      width: this.selectedThemeMode === mode ? 2 : 1,
      color: this.selectedThemeMode === mode ? $r('app.color.app_accent') : $r('app.color.app_divider')
    })
    .onClick(() => {
      this.selectTheme(mode);
    })
  }

  /** 用户称呼行:行内输入,失焦/回车自动保存 */
  @Builder
  userNameRow() {
    Row() {
      Text($r('app.string.settings_global_user_name_label'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.page_secondary_text'))
        .maxLines(1)

      TextInput({
        placeholder: $r('app.string.settings_global_user_name_placeholder'),
        text: this.globalUserName
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.page_primary_text'))
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(34)
        .padding({ left: 10, right: 10 })
        .layoutWeight(1)
        .margin({ left: 12 })
        .onChange((value: string) => {
          this.globalUserName = value;
        })
        .onSubmit(() => {
          this.saveGlobalUserNameIfChanged().catch(() => {});
        })
        .onBlur(() => {
          this.saveGlobalUserNameIfChanged().catch(() => {});
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
  }

  /** 发送按钮位置行:段选控件 */
  @Builder
  sendPositionRow() {
    Column() {
      this.rowDivider()
      Row() {
        Text($r('app.string.settings_send_button_position'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_secondary_text'))
          .maxLines(1)

        Row() {
          this.positionSegment(false)
          this.positionSegment(true)
        }
        .padding(2)
        .backgroundColor($r('app.color.app_surface_2'))
        .borderRadius($r('app.float.app_radius_sm'))
        .margin({ left: 12 })
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  /** 段选控件中的单个选项 */
  @Builder
  positionSegment(isLeft: boolean) {
    Text(isLeft
      ? $r('app.string.settings_send_button_position_left')
      : $r('app.string.settings_send_button_position_right'))
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(this.sendButtonLeft === isLeft
        ? $r('app.color.page_primary_text')
        : $r('app.color.page_secondary_text'))
      .backgroundColor(this.sendButtonLeft === isLeft
        ? $r('app.color.app_surface_1')
        : Color.Transparent)
      .borderRadius($r('app.float.app_radius_sm'))
      .padding({ left: 14, right: 14, top: 5, bottom: 5 })
      .onClick(() => {
        this.saveSendButtonPos(isLeft);
      })
  }

  /** 智感握姿行:开关 */
  @Builder
  smartGripRow() {
    Column() {
      this.rowDivider()
      Row() {
        Text($r('app.string.settings_smart_grip'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_secondary_text'))
          .maxLines(1)
          .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.smartGripEnabled })
          .selectedColor($r('app.color.app_accent'))
          .onChange((isOn: boolean) => {
            this.saveSmartGrip(isOn);
          })
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  /**
   * 值行:标签(次要色) + 右对齐值(主色) + 箭头。
   * @param showDivider 是否在行顶画分隔线(卡片内非首行传 true)
   */
  @Builder
  valueRow(label: string, value: string, enabled: boolean, showDivider: boolean, onClick: () => void) {
    Column() {
      if (showDivider) {
        this.rowDivider()
      }
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(value)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(enabled
            ? $r('app.color.page_primary_text')
            : $r('app.color.page_secondary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .layoutWeight(1)
          .margin({ left: 12 })
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.page_secondary_text'))
          .margin({ left: 4 })
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      if (!enabled) {
        return;
      }
      onClick();
    })
  }

  /**
   * 带动作胶囊的值行:标签 + 右对齐值 + 胶囊动作(点击整行触发)。
   * @param showDivider 是否在行顶画分隔线
   */
  @Builder
  actionRow(label: string, value: string, actionText: ResourceStr, showDivider: boolean,
    onClick: () => void) {
    Column() {
      if (showDivider) {
        this.rowDivider()
      }
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_secondary_text'))
          .maxLines(1)

        Text(value)
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.page_primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .layoutWeight(1)
          .margin({ left: 12 })

        Text(actionText)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.page_primary_text'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .margin({ left: 12 })
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      onClick();
    })
  }

  /**
   * 卡片内菜单行(无值列,可危险色)。
   * @param showDivider 是否在行顶画分隔线
   */
  @Builder
  menuRow(label: string, isDestructive: boolean, showDivider: boolean, onClick: () => void) {
    Column() {
      if (showDivider) {
        this.rowDivider()
      }
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(isDestructive
            ? $r('app.color.app_danger')
            : $r('app.color.page_primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.page_secondary_text'))
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      onClick();
    })
  }
}
