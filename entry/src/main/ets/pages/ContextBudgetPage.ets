/**
 * ContextBudgetPage 上下文管理页(v8.1)
 *
 * 功能:
 * - 显示当前模型名称 / 上下文上限 / 默认输出 Token
 * - 显示当前对话上下文上限 / 最大输出 Token / 输入可用预算
 * - 显示当前占用 / 剩余 Token / 占用百分比
 * - 切换"跟随模型配置"开关
 * - 自定义当前对话上下文长度(Slider,不超过模型上限)
 * - 自定义最大输出 Token(Slider)
 * - 自动管理最近消息开关(超限时自动裁剪)
 * - 分段占用详情(System Prompt / 角色卡 / 世界书 / 记忆摘要 / 历史 / 等)
 * - 恢复默认值
 *
 * 路由参数:{ chatId: string }
 *
 * 数据来源:
 * - 配置:ContextBudgetViewModel(底层 ContextBudgetService)
 * - 快照:ContextBudgetSnapshotStore(ChatPage 写入的最近一次构建结果)
 */

import { router } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { ContextBudgetSnapshotStore } from '../services/ContextBudgetSnapshotStore';
import { ContextBudgetViewModel } from '../viewmodels/ContextBudgetViewModel';
import {
  ContextBudgetStats,
  SegmentTokenStat,
  BudgetLevel
} from '../services/ContextBudgetEstimator';
import {
  CONTEXT_WINDOW_PRESETS,
  MIN_CUSTOM_CONTEXT_WINDOW,
  MIN_CUSTOM_RESERVED_OUTPUT_TOKENS
} from '../models/ContextBudgetConfig';
import { Logger } from '../utils/Logger';
import { ThemePalette } from '../theme/ThemePalette';

const LOG_TAG: string = 'ContextBudgetPage';

@Entry
@Component
struct ContextBudgetPage {
  @State chatId: string = '';
  @State viewModel: ContextBudgetViewModel | null = null;
  /** 当前快照统计(由 ChatPage 写入) */
  @State stats: ContextBudgetStats | null = null;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 预算配置变更通知(由本页面写入触发) */
  @StorageProp('chatBudgetConfigVersion') @Watch('onBudgetConfigVersionChanged') chatBudgetConfigVersion: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    try {
      const param = router.getParams() as Record<string, Object>;
      if (param !== undefined && param !== null && param['chatId'] !== undefined) {
        this.chatId = String(param['chatId']);
      } else {
        Logger.warn(LOG_TAG, 'No chatId in route params');
        return;
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear parse params failed: ' + String(e));
      return;
    }

    const budgetService = AppServices.getContextBudgetService();
    const modelService = AppServices.getModelService();
    const tokenCounter = AppServices.getTokenCounter();
    const vm: ContextBudgetViewModel = new ContextBudgetViewModel(
      budgetService, modelService, tokenCounter
    );
    this.viewModel = vm;
    vm.initialize(this.chatId).then((): void => {
      this.loadSnapshot();
    }).catch((e: Error): void => {
      Logger.error(LOG_TAG, 'vm.initialize failed: ' + e.message);
    });
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
      this.viewModel = null;
    }
  }

  /**
   * 从 SnapshotStore 读取最近一次构建的快照,刷新 VM stats。
   */
  private loadSnapshot(): void {
    if (this.viewModel === null || this.chatId.length === 0) {
      return;
    }
    const store = ContextBudgetSnapshotStore.getInstance();
    const snapshot = store.getSnapshot(this.chatId);
    if (snapshot === null) {
      this.stats = null;
      return;
    }
    this.viewModel!.refreshFromSnapshot(snapshot.budget, snapshot.requestMessages).then((): void => {
      this.stats = this.viewModel!.stats;
    }).catch((e: Error): void => {
      Logger.warn(LOG_TAG, 'refreshFromSnapshot failed: ' + e.message);
      this.stats = null;
    });
  }

  /**
   * AppStorage 上的 chatBudgetConfigVersion 变化时,说明本页或其他页修改了预算配置。
   * 本页修改时 vm 状态已更新,这里仅触发一次 ChatPage 重算(由 ChatPage 的 @Watch 自己处理)。
   * 此处重新加载快照,以便用户改完上下文上限后立即看到刷新后的占用。
   */
  onBudgetConfigVersionChanged(): void {
    // 防止本页修改时触发自身的循环刷新:本页修改时 vm 状态已同步,
    // 这里只刷新 stats(基于已更新的 VM 状态)
    if (this.viewModel !== null) {
      this.stats = this.viewModel!.stats;
    }
  }

  build() {
    Column() {
      this.titleBar()

      Scroll() {
        Column() {
          // 模型信息
          this.modelInfoSection()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

          // 预算配置
          this.budgetConfigSection()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

          // 当前占用
          this.usageSection()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

          // 分段占用详情
          this.segmentBreakdownSection()

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

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

      Text('上下文管理')
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
  modelInfoSection() {
    Column() {
      Text('模型信息')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ bottom: 8 })

      this.readonlyRow('模型名称', this.getModelName())
      this.readonlyRow('模型上下文上限', this.formatTokenNumber(this.getModelContextWindow()))
      this.readonlyRow('默认输出 Token', this.formatTokenNumber(this.getModelReservedOutput()))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  budgetConfigSection() {
    Column() {
      Text('预算配置')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ bottom: 8 })

      // 跟随模型配置
      this.followModelRow()

      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

      // 自定义上下文窗口
      this.customContextWindowRow()

      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

      // 自定义预留输出
      this.customReservedRow()

      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

      // 自动管理
      this.autoManageRow()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  usageSection() {
    Column() {
      Text('当前占用(基于当前分支)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ bottom: 8 })

      if (this.stats === null) {
        Text('暂无统计数据,发送一次消息后再查看')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .padding({ top: 12, bottom: 12 })
      } else {
        // 占用百分比与进度条(基于 effectiveAvailable)
        this.usageProgressBar()

        // 预算数值表(effective 值反映当前配置,实际输入来自上次构建)
        this.usageNumberRow('当前对话上下文上限',
          this.formatTokenNumber(this.getEffectiveContextWindow()))
        this.usageNumberRow('最大输出 Token',
          this.formatTokenNumber(this.getEffectiveReserved()))
        this.usageNumberRow('输入可用预算',
          this.formatTokenNumber(this.getEffectiveAvailable()))
        this.usageNumberRow('实际输入 Token(估算)',
          this.formatTokenNumber(this.stats!.totalInputTokens))
        this.usageNumberRow('剩余 Token',
          this.formatTokenNumber(this.getEffectiveAvailable() - this.stats!.totalInputTokens),
          this.getEffectiveAvailable() - this.stats!.totalInputTokens < 0)

        if (this.getEffectiveAvailable() - this.stats!.totalInputTokens < 0) {
          Row() {
            Text('已超出输入预算,请减少历史、降低最大输出 Token 或提高上下文长度')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .layoutWeight(1)
          }
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  segmentBreakdownSection() {
    Column() {
      Text('分段占用(估算)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ bottom: 8 })

      if (this.stats === null || this.stats!.segments.length === 0) {
        Text('暂无分段统计')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .padding({ top: 12, bottom: 12 })
      } else {
        ForEach(this.stats!.segments, (seg: SegmentTokenStat) => {
          this.segmentRow(seg)
        }, (seg: SegmentTokenStat) => seg.source + '_' + seg.messageCount.toString())

        // 预留输出 Token
        this.segmentRow(this.stats!.reservedSegment)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  actionButtons() {
    Column() {
      Button('恢复默认值')
        .fontSize(16)
        .fontColor($r('app.color.app_danger'))
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: $r('app.color.app_danger') })
        .borderRadius(24)
        .width('100%')
        .height(48)
        .margin({ top: 16 })
        .enabled(this.viewModel !== null && !this.viewModel!.isOperating)
        .onClick(() => {
          this.onResetToDefault();
        })
    }
    .width('100%')
  }

  // ===== 子 Builder =====

  @Builder
  readonlyRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .layoutWeight(1)
      Text(value)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('40%')
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(48)
    .padding({ left: 0, right: 0 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  followModelRow() {
    Row() {
      Column() {
        Text('跟随模型配置')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Text('关闭后可自定义上下文长度与输出 Token')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.getFollowModel() })
        .onChange((isOn: boolean) => {
          this.onFollowModelChange(isOn);
        })
        .enabled(this.viewModel !== null && !this.viewModel!.isOperating)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  customContextWindowRow() {
    Column() {
      Row() {
        Text('自定义上下文长度')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.getFollowModel()
            ? ThemePalette.textTertiaryColor(this.effectiveTheme)
            : ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text(this.formatTokenNumber(this.getCustomContextWindow()))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width(80)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ bottom: 4 })

      Slider({
        value: this.getCustomContextWindow(),
        min: MIN_CUSTOM_CONTEXT_WINDOW,
        max: this.getCustomContextWindowMax(),
        step: 1024,
        style: SliderStyle.OutSet
      })
        .blockColor(ThemePalette.accentColor(this.effectiveTheme))
        .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
        .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
        .width('100%')
        .enabled(this.viewModel !== null
          && !this.viewModel!.isOperating
          && !this.getFollowModel())
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.onCustomContextWindowChange(Math.round(value));
          }
        })

      // v8.2: 预设档位按钮(16K/32K/64K/128K/256K/512K/1M)
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.getContextWindowPresetList(), (preset: number) => {
          Text(this.formatTokenNumber(preset))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(this.isContextWindowPresetActive(preset)
              ? $r('app.color.app_on_accent')
              : ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(this.isContextWindowPresetActive(preset)
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius(12)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .margin({ right: 6, bottom: 6 })
            .onClick(() => {
              if (!this.getFollowModel()) {
                this.onCustomContextWindowChange(preset);
              }
            })
        }, (preset: number) => preset.toString())
      }
      .width('100%')
      .margin({ top: 4 })

      Text('范围 ' + this.formatTokenNumber(MIN_CUSTOM_CONTEXT_WINDOW)
        + ' ~ ' + this.formatTokenNumber(this.getCustomContextWindowMax())
        + '(不可超过模型上限 1M)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  customReservedRow() {
    Column() {
      Row() {
        Text('最大输出 Token')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.getFollowModel()
            ? ThemePalette.textTertiaryColor(this.effectiveTheme)
            : ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text(this.formatTokenNumber(this.getCustomReserved()))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width(80)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ bottom: 4 })

      Slider({
        value: this.getCustomReserved(),
        min: MIN_CUSTOM_RESERVED_OUTPUT_TOKENS,
        max: this.getCustomReservedMax(),
        step: 256,
        style: SliderStyle.OutSet
      })
        .blockColor(ThemePalette.accentColor(this.effectiveTheme))
        .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
        .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
        .width('100%')
        .enabled(this.viewModel !== null
          && !this.viewModel!.isOperating
          && !this.getFollowModel())
        .onChange((value: number, mode: SliderChangeMode) => {
          if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
            this.onCustomReservedChange(Math.round(value));
          }
        })

      Text('范围 ' + this.formatTokenNumber(MIN_CUSTOM_RESERVED_OUTPUT_TOKENS)
        + ' ~ ' + this.formatTokenNumber(this.getCustomReservedMax())
        + '(不得超过当前上下文)')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  autoManageRow() {
    Row() {
      Column() {
        Text('自动管理最近消息')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Text('超预算时自动裁剪最旧的对话历史')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: this.getAutoManage() })
        .onChange((isOn: boolean) => {
          this.onAutoManageChange(isOn);
        })
        .enabled(this.viewModel !== null && !this.viewModel!.isOperating)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  usageProgressBar() {
    Column() {
      Row() {
        Text('占用')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text(this.formatUsagePercent())
          .fontSize($r('app.float.app_font_body'))
          .fontColor(this.getUsageColor())
          .width(80)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ bottom: 4 })

      Progress({ value: this.getUsageProgressValue(), total: 100, type: ProgressType.Linear })
        .width('100%')
        .color(this.getUsageColor())
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .margin({ bottom: 8 })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  usageNumberRow(label: string, value: string, isDanger: boolean = false) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .layoutWeight(1)
      Text(value)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(isDanger ? $r('app.color.app_danger') : ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('40%')
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(40)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  segmentRow(seg: SegmentTokenStat) {
    Column() {
      Row() {
        Text(seg.label)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text(this.formatTokenNumber(seg.tokenCount))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width(80)
          .textAlign(TextAlign.End)
        Text(this.formatRatioPercent(seg.ratio))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width(56)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      // 段内条形进度(占总输入的占比)
      Progress({ value: seg.ratio * 100, total: 100, type: ProgressType.Linear })
        .width('100%')
        .color(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .margin({ top: 4, bottom: 4 })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  // ===== 数据读取辅助 =====

  private getModelName(): string {
    if (this.viewModel === null || this.viewModel!.currentConfig === null) {
      return '未配置';
    }
    const name: string = this.viewModel!.currentConfig!.modelName;
    return name.length > 0 ? name : '未配置';
  }

  private getModelContextWindow(): number {
    if (this.viewModel === null) {
      return 0;
    }
    return this.viewModel!.modelContextWindow;
  }

  private getModelReservedOutput(): number {
    if (this.viewModel === null) {
      return 0;
    }
    return this.viewModel!.modelReservedOutput;
  }

  private getFollowModel(): boolean {
    if (this.viewModel === null) {
      return true;
    }
    return this.viewModel!.config.followModel;
  }

  private getCustomContextWindow(): number {
    if (this.viewModel === null) {
      return 32768;
    }
    return this.viewModel!.config.customContextWindow;
  }

  private getCustomContextWindowMax(): number {
    if (this.viewModel === null) {
      return 1000000;
    }
    // v8.2: 不超过模型上限(DeepSeek-V4-Flash = 1M)
    // 不再与硬上限 200000 取 min(已调整为 1M)
    return this.viewModel!.modelContextWindow;
  }

  /**
   * v8.2: 自定义预留输出的 Slider 上限。
   * = min(modelReservedOutputLimit, effectiveContextWindow - BUDGET_SAFETY_MARGIN)
   */
  private getCustomReservedMax(): number {
    if (this.viewModel === null) {
      return 8192;
    }
    return this.viewModel!.getCustomReservedSliderMax();
  }

  /**
   * v8.2: 获取当前可选的上下文窗口预设档位列表。
   * 过滤掉超过 modelContextWindow 的档位。
   */
  private getContextWindowPresetList(): number[] {
    if (this.viewModel === null) {
      return CONTEXT_WINDOW_PRESETS;
    }
    const max: number = this.viewModel!.modelContextWindow;
    const list: number[] = [];
    for (let i = 0; i < CONTEXT_WINDOW_PRESETS.length; i++) {
      if (CONTEXT_WINDOW_PRESETS[i] <= max) {
        list.push(CONTEXT_WINDOW_PRESETS[i]);
      }
    }
    return list;
  }

  /**
   * v8.2: 判断某个预设档位是否为当前选中值。
   */
  private isContextWindowPresetActive(preset: number): boolean {
    if (this.viewModel === null) {
      return false;
    }
    return this.viewModel!.config.customContextWindow === preset;
  }

  private getCustomReserved(): number {
    if (this.viewModel === null) {
      return 2048;
    }
    return this.viewModel!.config.customReservedOutputTokens;
  }

  private getAutoManage(): boolean {
    if (this.viewModel === null) {
      return true;
    }
    return this.viewModel!.config.autoManage;
  }

  private getEffectiveContextWindow(): number {
    if (this.viewModel === null) {
      return 0;
    }
    return this.viewModel!.effectiveContextWindow;
  }

  private getEffectiveReserved(): number {
    if (this.viewModel === null) {
      return 0;
    }
    return this.viewModel!.effectiveReserved;
  }

  private getEffectiveAvailable(): number {
    if (this.viewModel === null) {
      return 0;
    }
    return this.viewModel!.effectiveAvailable;
  }

  private getUsageProgressValue(): number {
    if (this.stats === null) {
      return 0;
    }
    const available: number = this.getEffectiveAvailable();
    if (available <= 0) {
      return 100;
    }
    const ratio: number = this.stats!.totalInputTokens / available;
    if (ratio < 0) {
      return 0;
    }
    if (ratio > 1) {
      return 100;
    }
    return ratio * 100;
  }

  private formatUsagePercent(): string {
    if (this.stats === null) {
      return '—';
    }
    const available: number = this.getEffectiveAvailable();
    if (available <= 0) {
      return '—';
    }
    const ratio: number = this.stats!.totalInputTokens / available;
    if (ratio < 0) {
      return '0%';
    }
    const percent: number = Math.round(ratio * 100);
    return percent.toString() + '%';
  }

  private getUsageColor(): ResourceColor {
    if (this.viewModel === null || this.stats === null) {
      return ThemePalette.textTertiaryColor(this.effectiveTheme);
    }
    const available: number = this.getEffectiveAvailable();
    if (available <= 0) {
      return $r('app.color.app_danger');
    }
    const ratio: number = this.stats!.totalInputTokens / available;
    const level: BudgetLevel = this.classifyLevel(ratio);
    switch (level) {
      case BudgetLevel.Exceeded:
        return $r('app.color.app_danger');
      case BudgetLevel.High:
        return $r('app.color.app_danger');
      case BudgetLevel.Warning:
        return ThemePalette.accentColor(this.effectiveTheme);
      default:
        return ThemePalette.textSecondaryColor(this.effectiveTheme);
    }
  }

  private classifyLevel(ratio: number): BudgetLevel {
    if (ratio >= 1.0) {
      return BudgetLevel.Exceeded;
    }
    if (ratio >= 0.9) {
      return BudgetLevel.High;
    }
    if (ratio >= 0.7) {
      return BudgetLevel.Warning;
    }
    return BudgetLevel.Normal;
  }

  // ===== 事件处理 =====

  private async onFollowModelChange(follow: boolean): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.setFollowModel(follow);
    // 配置变更后,尝试重新加载快照(基于已有 messages)
    this.loadSnapshot();
  }

  private async onCustomContextWindowChange(value: number): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.setCustomContextWindow(value);
    this.loadSnapshot();
  }

  private async onCustomReservedChange(value: number): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.setCustomReservedOutputTokens(value);
    this.loadSnapshot();
  }

  private async onAutoManageChange(auto: boolean): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.setAutoManage(auto);
  }

  private async onResetToDefault(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.resetToDefault();
    this.loadSnapshot();
  }

  // ===== 格式化 =====

  /**
   * 格式化 Token 数字:
   * - v8.2: >= 1000000 显示为 M(保留 1 位小数,如 1M / 1.5M)
   * - >= 1000 显示为 K(保留 1 位小数,如 12.4K / 128K)
   * - 否则原样显示
   */
  private formatTokenNumber(value: number): string {
    if (value < 0) {
      return '-' + this.formatTokenNumber(-value);
    }
    if (value >= 1000000) {
      const m: number = value / 1000000;
      const str: string = m.toFixed(1);
      if (str.endsWith('.0')) {
        return str.substring(0, str.length - 2) + 'M';
      }
      return str + 'M';
    }
    if (value >= 1000) {
      const k: number = value / 1000;
      // 保留 1 位小数,去除多余 .0
      const str: string = k.toFixed(1);
      if (str.endsWith('.0')) {
        return str.substring(0, str.length - 2) + 'K';
      }
      return str + 'K';
    }
    return value.toString();
  }

  /**
   * 格式化占比(0~1)为百分比字符串。
   */
  private formatRatioPercent(ratio: number): string {
    if (ratio < 0) {
      return '0%';
    }
    const percent: number = Math.round(ratio * 100);
    return percent.toString() + '%';
  }
}
