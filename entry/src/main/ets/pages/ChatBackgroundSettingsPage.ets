/**
 * ChatBackgroundSettingsPage 聊天背景设置页
 *
 * 功能:
 * - 选择图片(通过 photoAccessHelper.PhotoViewPicker)
 * - 预览背景图 + 当前模糊度 + 当前暗化效果
 * - 调节模糊度 Slider(0~100)
 * - 调节暗化程度 Slider(0~100)
 * - 启用/禁用背景图开关
 * - 删除背景图
 *
 * 路由参数:{ chatId: string }
 */

import { router } from '@kit.ArkUI';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { AppServices } from '../services/AppServices';
import { ChatBackgroundConfig, ChatBackgroundService, ReasoningEffort } from '../services/ChatBackgroundService';
import { Logger } from '../utils/Logger';
import { promptAction } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';

const LOG_TAG: string = 'ChatBackgroundSettingsPage';

/** 思考强度档位描述(用于 UI 渲染) */
interface ReasoningEffortOption {
  readonly value: ReasoningEffort;
  readonly label: string;
  readonly desc: string;
}

const EFFORT_OPTIONS: ReasoningEffortOption[] = [
  { value: '', label: '跟随默认', desc: '不发送 reasoning_effort,使用 Provider 默认行为' },
  { value: 'none', label: '关闭思考', desc: '发送 reasoning_effort=none(若 Provider 支持)' },
  { value: 'low', label: '低 · 快速', desc: '快速响应,适合简短问答' },
  { value: 'medium', label: '中 · 标准', desc: '平衡速度与深度' },
  { value: 'high', label: '高 · 深度', desc: '深度思考,首字延迟较长' }
];

@Entry
@Component
struct ChatBackgroundSettingsPage {
  @State chatId: string = '';
  @State config: ChatBackgroundConfig = {
    enabled: false,
    imageUri: '',
    blur: 30,
    dim: 30
  };
  /** 思考强度(空字符串表示跟随默认) */
  @State reasoningEffort: ReasoningEffort = '';
  @State isImporting: boolean = false;
  @State isSaving: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    try {
      const param = router.getParams() as Record<string, Object>;
      if (param !== undefined && param !== null && param['chatId'] !== undefined) {
        this.chatId = String(param['chatId']);
        this.loadConfig();
      } else {
        Logger.warn(LOG_TAG, 'No chatId in route params');
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + String(e));
    }
  }

  private async loadConfig(): Promise<void> {
    const service = this.getBackgroundService();
    if (service === null) {
      return;
    }
    try {
      const cfg = await service.getConfig(this.chatId);
      this.config = cfg;
      const effort: ReasoningEffort = await service.getReasoningEffort(this.chatId);
      this.reasoningEffort = effort;
    } catch (e) {
      Logger.error(LOG_TAG, 'loadConfig failed: ' + (e as Error).message);
    }
  }

  private getBackgroundService(): ChatBackgroundService | null {
    return AppServices.getChatBackgroundService();
  }

  build() {
    Column() {
      this.titleBar()

      Scroll() {
        Column() {
          // 预览区域
          this.previewArea()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 16, bottom: 8 })

          // 启用开关
          this.enableRow()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

          // 模糊度 Slider
          this.blurRow()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

          // 暗化程度 Slider
          this.dimRow()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

          // 思考强度
          this.reasoningEffortRow()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

          // 操作按钮
          this.actionButtons()

          Blank().height(this.navigationBarHeight + 16)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  titleBar() {
    Row() {
      Button($r('app.string.branch_map_back'))
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .onClick(() => {
          router.back();
        })

      Blank()

      Text($r('app.string.chat_background_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))

      Blank()

      // 占位保持标题居中
      Text('')
        .fontSize(14)
        .width(44)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: this.statusBarHeight + 4, bottom: 8 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  previewArea() {
    Stack() {
      if (this.config.imageUri.length > 0) {
        // 预览背景图(应用当前模糊和暗化)
        Image(this.config.imageUri)
          .width('100%')
          .height(220)
          .borderRadius(12)
          .objectFit(ImageFit.Cover)
          .blur(this.config.blur)

        // 暗化遮罩
        Column()
          .width('100%')
          .height(220)
          .borderRadius(12)
          .backgroundColor('rgba(0,0,0,' + (this.config.dim / 100).toString() + ')')

        // 预览文字(模拟聊天气泡)
        Column() {
          Text('预览效果')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .margin({ bottom: 8 })

          Text('这是带背景的聊天界面示例文字')
            .fontSize(14)
            .fontColor(Color.White)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .backgroundColor('rgba(91, 124, 250, 0.8)')
            .borderRadius(12)
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .height(220)
      } else {
        // 未导入图片时的占位
        Column() {
          Text('🖼')
            .fontSize(48)
            .margin({ bottom: 8 })
          Text($r('app.string.chat_background_no_image'))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        }
        .width('100%')
        .height(220)
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height(220)
  }

  @Builder
  enableRow() {
    Row() {
      Column() {
        Text($r('app.string.chat_background_enable'))
          .fontSize(16)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Text($r('app.string.chat_background_enable_desc'))
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.config.enabled })
        .onChange((isOn: boolean) => {
          this.onEnableChange(isOn);
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  blurRow() {
    Column() {
      Row() {
        Text($r('app.string.chat_background_blur'))
          .fontSize(16)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text(this.config.blur.toString())
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ bottom: 4 })

      Slider({
        value: this.config.blur,
        min: 0,
        max: 100,
        step: 1,
        style: SliderStyle.OutSet
      })
        .blockColor(ThemePalette.accentColor(this.effectiveTheme))
        .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
        .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          this.onBlurChange(value);
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  dimRow() {
    Column() {
      Row() {
        Text($r('app.string.chat_background_dim'))
          .fontSize(16)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text(this.config.dim.toString())
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ bottom: 4 })

      Slider({
        value: this.config.dim,
        min: 0,
        max: 100,
        step: 1,
        style: SliderStyle.OutSet
      })
        .blockColor(ThemePalette.accentColor(this.effectiveTheme))
        .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
        .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
        .width('100%')
        .onChange((value: number, mode: SliderChangeMode) => {
          this.onDimChange(value);
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  reasoningEffortRow() {
    Column() {
      Row() {
        Text('思考强度')
          .fontSize(16)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text(this.getEffortLabel(this.reasoningEffort))
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      }
      .width('100%')
      .margin({ bottom: 4 })

      ForEach(EFFORT_OPTIONS, (opt: ReasoningEffortOption) => {
        Row() {
          Column() {
            Text(opt.label)
              .fontSize(14)
              .fontColor(this.reasoningEffort === opt.value
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.textPrimaryColor(this.effectiveTheme))
            Text(opt.desc)
              .fontSize(11)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Radio({ value: opt.value, group: 'reasoning_effort' })
            .checked(this.reasoningEffort === opt.value)
            .onChange((isChecked: boolean) => {
              if (isChecked) {
                this.onReasoningEffortChange(opt.value);
              }
            })
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      }, (opt: ReasoningEffortOption) => opt.value)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  actionButtons() {
    Column() {
      // 导入图片按钮
      Button($r('app.string.chat_background_import'))
        .fontSize(16)
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius(24)
        .width('100%')
        .height(48)
        .margin({ top: 16 })
        .enabled(!this.isImporting)
        .onClick(() => {
          this.pickAndImportImage();
        })

      // 删除背景图按钮
      if (this.config.imageUri.length > 0) {
        Button($r('app.string.chat_background_delete'))
          .fontSize(16)
          .fontColor($r('app.color.app_danger'))
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: $r('app.color.app_danger') })
          .borderRadius(24)
          .width('100%')
          .height(48)
          .margin({ top: 8 })
          .onClick(() => {
            this.deleteBackground();
          })
      }
    }
    .width('100%')
  }

  // ===== 事件处理 =====

  private async onEnableChange(isOn: boolean): Promise<void> {
    const service = this.getBackgroundService();
    if (service === null) {
      return;
    }
    try {
      await service.setEnabled(this.chatId, isOn);
      this.config = {
        enabled: isOn,
        imageUri: this.config.imageUri,
        blur: this.config.blur,
        dim: this.config.dim
      };
      this.notifyConfigChanged();
    } catch (e) {
      Logger.error(LOG_TAG, 'onEnableChange failed: ' + (e as Error).message);
      promptAction.showToast({ message: '保存失败' });
    }
  }

  private async onBlurChange(value: number): Promise<void> {
    const clamped = Math.round(value);
    const service = this.getBackgroundService();
    if (service === null) {
      return;
    }
    try {
      await service.setBlur(this.chatId, clamped);
      this.config = {
        enabled: this.config.enabled,
        imageUri: this.config.imageUri,
        blur: clamped,
        dim: this.config.dim
      };
      this.notifyConfigChanged();
    } catch (e) {
      Logger.error(LOG_TAG, 'onBlurChange failed: ' + (e as Error).message);
    }
  }

  private async onDimChange(value: number): Promise<void> {
    const clamped = Math.round(value);
    const service = this.getBackgroundService();
    if (service === null) {
      return;
    }
    try {
      await service.setDim(this.chatId, clamped);
      this.config = {
        enabled: this.config.enabled,
        imageUri: this.config.imageUri,
        blur: this.config.blur,
        dim: clamped
      };
      this.notifyConfigChanged();
    } catch (e) {
      Logger.error(LOG_TAG, 'onDimChange failed: ' + (e as Error).message);
    }
  }

  private async onReasoningEffortChange(effort: ReasoningEffort): Promise<void> {
    const service = this.getBackgroundService();
    if (service === null) {
      return;
    }
    try {
      await service.setReasoningEffort(this.chatId, effort);
      this.reasoningEffort = effort;
      this.notifyConfigChanged();
    } catch (e) {
      Logger.error(LOG_TAG, 'onReasoningEffortChange failed: ' + (e as Error).message);
      promptAction.showToast({ message: '保存失败' });
    }
  }

  /** 根据 ReasoningEffort 值获取 UI 显示标签 */
  private getEffortLabel(effort: ReasoningEffort): string {
    for (let i = 0; i < EFFORT_OPTIONS.length; i++) {
      if (EFFORT_OPTIONS[i].value === effort) {
        return EFFORT_OPTIONS[i].label;
      }
    }
    return '跟随默认';
  }

  private async pickAndImportImage(): Promise<void> {
    const service = this.getBackgroundService();
    if (service === null) {
      promptAction.showToast({ message: '服务未初始化' });
      return;
    }
    this.isImporting = true;
    try {
      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const selectOption = new photoAccessHelper.PhotoSelectOptions();
      selectOption.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      selectOption.maxSelectNumber = 1;
      const result = await photoPicker.select(selectOption);
      if (!result || !result.photoUris || result.photoUris.length === 0) {
        this.isImporting = false;
        return;
      }
      const sourceUri = result.photoUris[0];
      const targetUri = await service.importImage(this.chatId, sourceUri);
      // 导入后自动启用
      await service.setEnabled(this.chatId, true);
      const cfg = await service.getConfig(this.chatId);
      this.config = cfg;
      this.notifyConfigChanged();
      promptAction.showToast({ message: '导入成功' });
    } catch (e) {
      Logger.error(LOG_TAG, 'pickAndImportImage failed: ' + (e as Error).message);
      promptAction.showToast({ message: '导入失败: ' + (e as Error).message });
    } finally {
      this.isImporting = false;
    }
  }

  private async deleteBackground(): Promise<void> {
    const service = this.getBackgroundService();
    if (service === null) {
      return;
    }
    try {
      await service.deleteBackground(this.chatId);
      this.config = {
        enabled: false,
        imageUri: '',
        blur: 30,
        dim: 30
      };
      this.notifyConfigChanged();
      promptAction.showToast({ message: '已删除' });
    } catch (e) {
      Logger.error(LOG_TAG, 'deleteBackground failed: ' + (e as Error).message);
      promptAction.showToast({ message: '删除失败' });
    }
  }

  /**
   * 通知 ChatPage 重新加载背景配置。
   * 通过 AppStorage 的 chatBgConfigVersion 计数器触发 @Watch。
   */
  private notifyConfigChanged(): void {
    const v: number = AppStorage.get<number>('chatBgConfigVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatBgConfigVersion', v + 1);
  }
}
