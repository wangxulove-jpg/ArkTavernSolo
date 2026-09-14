/**
 * MarketPage 市场 Tab 内容视图
 *
 * 替换原 MarketPlaceholderView,作为 HdsTabs 第三个 Tab 的内容。
 *
 * 结构(自上而下):
 * - 顶部标题栏:标题"角色市场" + 来源标识
 * - 搜索框(胶囊样式,防抖 350ms)
 * - 三联下拉栏(分类 / 排序 / 筛选 触发器一行,面板向下展开悬浮于内容上方,不挤压卡片)
 * - 内容区:
 *   - 加载中:LoadingProgress
 *   - 加载失败:EmptyStateView + 重试按钮
 *   - 空状态:EmptyStateView
 *   - 列表:Grid 双列 + 下拉刷新 + 滚动到底部加载更多
 * - NSFW 二次确认弹窗
 * - 翻译隐私提示弹窗(首次开启翻译时)
 *
 * 刷新机制:
 * - @State 装饰 `ViewModel | null` 联合类型时,对 @Observed 实例属性的观察不可靠,
 *   因此本页面将所有渲染相关状态镜像为本地 @State(items/uiSort/uiHideNsfw/...),
 *   并绑定 MarketViewModel.onStateChanged 回调,任何状态变化都同步一次本地状态。
 * - items 每次同步使用 slice() 生成新数组引用,确保 ForEach 重新渲染。
 *
 * 本地化:
 * - 所有 UI 文案通过 $r('app.string.market_*') 资源引用
 * - 不使用 String($r(...)) / 资源字符串拼接 / as string
 *
 * 不直接:
 * - 调用 network / Provider
 * - 操作 Preferences
 * - 持久化数据
 */

import { AppServices } from '../../services/AppServices';
import { MarketViewModel } from '../../viewmodels/MarketViewModel';
import { MarketSort } from '../../models/MarketQuery';
import { MarketCharacter, marketCharacterKey } from '../../models/MarketCharacter';
import { MarketCharacterCard, MarketCardClickParams } from '../../components/MarketCharacterCard';
import { EmptyStateView } from '../../components/EmptyStateView';
import { AppTopBar } from '../../components/ui/AppTopBar';
import { router } from '@kit.ArkUI';
import { ThemePalette } from '../../theme/ThemePalette';

interface MarketCategoryDef {
  readonly label: string;
  readonly searchtag: string;
}

const MARKET_CATEGORIES: MarketCategoryDef[] = [
  { label: '全部', searchtag: '' },
  { label: '中文', searchtag: 'Chinese' },
  { label: '角色扮演', searchtag: 'Roleplay' },
  { label: '奇幻', searchtag: 'Fantasy' },
  { label: '恋爱', searchtag: 'Romance' },
  { label: '动漫', searchtag: 'Anime' },
  { label: 'VTuber', searchtag: 'VTuber' },
  { label: '游戏', searchtag: 'Game' },
  { label: '科幻', searchtag: 'Sci-fi' },
  { label: '恐怖', searchtag: 'Horror' },
  { label: '动作', searchtag: 'Action' },
  { label: '喜剧', searchtag: 'Comedy' },
  { label: '剧情', searchtag: 'Drama' },
  { label: '悬疑', searchtag: 'Mystery' },
  { label: '助手', searchtag: 'Helper' },
  { label: '女性', searchtag: 'Female' },
  { label: '男性', searchtag: 'Male' },
];

@Component
export struct MarketPage {
  @State viewModel: MarketViewModel | null = null;
  @State isInitializing: boolean = true;

  // ===== 本地 UI 状态镜像(绕开 @Observed 联合类型观察不可靠的问题) =====
  @State items: MarketCharacter[] = [];
  @State searchInput: string = '';
  @State uiSort: MarketSort = MarketSort.Recommended;
  @State uiHideNsfw: boolean = true;
  @State uiHideImported: boolean = false;
  @State uiTranslateEnabled: boolean = false;
  @State uiError: string = '';
  @State refreshing: boolean = false;
  @State loadingMore: boolean = false;
  @State showNsfwConfirm: boolean = false;
  @State selectedCategoryIndex: number = 0;
  /** 当前展开的下拉面板: '' / 'category' / 'sort' / 'filter',同一时间最多展开一个 */
  @State activeDropdown: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 跨页面刷新信号:导入成功后递增,触发列表刷新 */
  @StorageProp('marketListVersion') @Watch('onMarketListVersionChange') marketListVersion: number = 0;

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const translationService = AppServices.getMarketTranslationService();
      const vm: MarketViewModel = new MarketViewModel(
        AppServices.getMarketService(),
        translationService
      );
      vm.onStateChanged = (): void => {
        this.syncUiState();
      };
      this.viewModel = vm;
      await vm.load();
      this.isInitializing = false;
      this.syncUiState();
    } catch (e) {
      this.isInitializing = false;
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel!.onStateChanged = null;
      this.viewModel!.dispose();
    }
  }

  /**
   * marketListVersion 变化时刷新列表(从详情页导入成功后自动刷新)。
   */
  private onMarketListVersionChange(): void {
    if (this.isInitializing || this.viewModel === null) {
      return;
    }
    void this.viewModel!.refresh();
  }

  /**
   * 将 ViewModel 状态同步到本地 @State(由 onStateChanged 回调触发)。
   */
  private syncUiState(): void {
    const vm: MarketViewModel | null = this.viewModel;
    if (vm === null) {
      return;
    }
    this.items = vm.items.slice();
    this.searchInput = vm.searchInput;
    this.uiSort = vm.sort;
    this.uiHideNsfw = vm.hideNsfw;
    this.uiHideImported = vm.hideImported;
    this.uiTranslateEnabled = vm.translateEnabled;
    this.uiError = vm.errorMessage;
    this.loadingMore = vm.loadingMore;
    this.refreshing = vm.refreshing;
    this.showNsfwConfirm = vm.showNsfwConfirm;
    if (vm.tag.length === 0) {
      this.selectedCategoryIndex = 0;
    } else {
      let found: boolean = false;
      for (let i = 0; i < MARKET_CATEGORIES.length; i++) {
        if (MARKET_CATEGORIES[i].searchtag === vm.tag) {
          this.selectedCategoryIndex = i;
          found = true;
          break;
        }
      }
      if (!found) {
        this.selectedCategoryIndex = 0;
      }
    }
  }

  build() {
    Stack() {
      Column() {
        // ===== 顶部标题栏(统一 AppTopBar,右侧来源标识) =====
        AppTopBar({ title: $r('app.string.market_title') }) {
          // 来源标识(第一版固定 chub)
          Text('Chub')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        }

        // ===== 搜索框(胶囊) =====
        this.searchBar()

        // ===== 三联下拉栏(分类 / 排序 / 筛选) =====
        this.dropdownBar()

        // ===== 错误提示 =====
        if (this.uiError.length > 0) {
          this.errorBanner()
        }

        // ===== 主内容区(下拉面板悬浮其上,不挤压卡片) =====
        Stack({ alignContent: Alignment.TopStart }) {
          Column() {
            if (this.isInitializing) {
              this.loadingView()
            } else if (this.viewModel === null) {
              this.errorView($r('app.string.market_init_failed'), $r('app.string.market_not_initialized'))
            } else {
              this.marketContent()
            }
          }
          .width('100%')
          .height('100%')

          if (this.activeDropdown !== '') {
            // 透明遮罩:点击面板外区域收起
            Column()
              .width('100%')
              .height('100%')
              .onClick(() => {
                this.activeDropdown = '';
              })

            this.dropdownPanel()
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // ===== NSFW 确认弹窗 =====
      if (this.showNsfwConfirm) {
        this.nsfwConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  // ===== 搜索框 =====

  @Builder
  searchBar(): void {
    Row() {
      // 搜索图标
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
        .margin({ right: 8 })

      TextInput({
        placeholder: $r('app.string.market_search_placeholder'),
        text: this.searchInput
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .layoutWeight(1)
        .padding(0)
        .onChange((value: string) => {
          if (this.viewModel !== null) {
            this.viewModel!.onSearchInput(value);
          }
        })
        .onSubmit(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.submitSearch();
          }
        })

      // 清空按钮
      if (this.searchInput.length > 0) {
        Button() {
          SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
            .fontSize(16)
            .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
        }
        .type(ButtonType.Normal)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .margin({ left: 4 })
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.clearSearch();
          }
        })
      }
    }
    .width('100%')
    .height(40)
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_lg'))
    .padding({ left: 14, right: 12 })
    .margin({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_4'),
      bottom: $r('app.float.app_spacing_8')
    })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 三联下拉栏(分类 / 排序 / 筛选,面板向下展开悬浮于内容上方) =====

  @Builder
  dropdownBar(): void {
    Row({ space: 8 }) {
      this.dropdownTrigger($r('app.string.market_filter_category'), this.currentCategoryLabel(), 'category')
      this.dropdownTrigger($r('app.string.market_filter_sort'), this.currentSortLabel(), 'sort')
      this.dropdownTrigger($r('app.string.market_filter_toggle'), this.currentFilterBadge(), 'filter')
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_4'),
      bottom: $r('app.float.app_spacing_4')
    })
  }

  /**
   * 下拉触发器:标签 + 当前值 + 旋转箭头,三列等宽。
   */
  @Builder
  private dropdownTrigger(label: ResourceStr, value: ResourceStr, key: string): void {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontWeight(this.activeDropdown === key ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeDropdown === key
          ? ThemePalette.accentColor(this.effectiveTheme)
          : ThemePalette.textSecondaryColor(this.effectiveTheme))

      Text(value)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: 64 })
        .margin({ left: 4 })

      SymbolGlyph($r('sys.symbol.arrow_down'))
        .fontSize(12)
        .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
        .margin({ left: 3 })
        .rotate({ angle: this.activeDropdown === key ? 180 : 0 })
        .animation({ duration: 200, curve: Curve.EaseOut })
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.activeDropdown === key
      ? this.selectedChipBg()
      : ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .onClick(() => {
      if (this.activeDropdown === key) {
        this.activeDropdown = '';
      } else {
        this.activeDropdown = key;
      }
    })
  }

  /**
   * 下拉面板:悬浮在内容区上方(Stack 覆盖层),不改变列表布局。
   * 外层用 padding 包裹,避免 width('100%')+margin 溢出父容器边界导致超出屏幕。
   */
  @Builder
  private dropdownPanel(): void {
    Column() {
      Column() {
        if (this.activeDropdown === 'category') {
          this.categoryPanel()
        } else if (this.activeDropdown === 'sort') {
          this.sortPanel()
        } else {
          this.filterPanel()
        }
      }
      .width('100%')
      .padding($r('app.float.app_spacing_12'))
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_lg'))
      .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16')
    })
    .margin({ top: $r('app.float.app_spacing_4') })
  }

  /**
   * 分类面板:全部分类 chips 换行平铺,选中即应用并收起。
   */
  @Builder
  private categoryPanel(): void {
    Scroll() {
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
        ForEach(MARKET_CATEGORIES, (cat: MarketCategoryDef, index: number) => {
          Text(cat.label)
            .fontSize($r('app.float.app_font_caption'))
            .fontWeight(this.selectedCategoryIndex === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.selectedCategoryIndex === index
              ? $r('app.color.app_on_accent')
              : ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(this.selectedCategoryIndex === index
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_lg'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.onCategoryClick(index, cat.searchtag);
              this.activeDropdown = '';
            })
        }, (cat: MarketCategoryDef, index: number) => cat.searchtag + '|' + index.toString())
      }
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .constraintSize({ maxHeight: 240 })
  }

  /**
   * 排序面板:三选一,选中即应用并收起。
   */
  @Builder
  private sortPanel(): void {
    Scroll() {
      Row({ space: 8 }) {
        this.sortChip($r('app.string.market_sort_recommended'), MarketSort.Recommended)
        this.sortChip($r('app.string.market_sort_latest'), MarketSort.Latest)
        this.sortChip($r('app.string.market_sort_top'), MarketSort.Top)
      }
      .width('100%')
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .constraintSize({ maxHeight: 160 })
  }

  /**
   * 筛选面板:多选 chips 换行平铺,切换后保持展开,点遮罩收起。
   */
  @Builder
  private filterPanel(): void {
    Scroll() {
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        this.nsfwChip()
        this.hideImportedChip()
        this.translateChip()
      }
      .width('100%')
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .constraintSize({ maxHeight: 160 })
  }

  /**
   * 统计当前生效的筛选项数量(用于筛选触发器角标)。
   * 默认状态(hideNsfw=true)不计为生效筛选。
   */
  private activeFilterCount(): number {
    let count: number = 0;
    if (!this.uiHideNsfw) {
      count++;
    }
    if (this.uiHideImported) {
      count++;
    }
    if (this.uiTranslateEnabled) {
      count++;
    }
    return count;
  }

  /** 触发器右侧显示的当前分类名 */
  private currentCategoryLabel(): string {
    if (this.selectedCategoryIndex >= 0 && this.selectedCategoryIndex < MARKET_CATEGORIES.length) {
      return MARKET_CATEGORIES[this.selectedCategoryIndex].label;
    }
    return MARKET_CATEGORIES[0].label;
  }

  /** 触发器右侧显示的当前排序文案 */
  private currentSortLabel(): ResourceStr {
    if (this.uiSort === MarketSort.Latest) {
      return $r('app.string.market_sort_latest');
    }
    if (this.uiSort === MarketSort.Top) {
      return $r('app.string.market_sort_top');
    }
    return $r('app.string.market_sort_recommended');
  }

  /** 筛选触发器角标:生效筛选项数量,无则空 */
  private currentFilterBadge(): string {
    const count: number = this.activeFilterCount();
    if (count > 0) {
      return count.toString();
    }
    return '';
  }

  /** 次级选中底色(selectedSurface,与分类面板的 accent 填充区分层级) */
  private selectedChipBg(): ResourceColor {
    return ThemePalette.forTheme(this.effectiveTheme).selectedSurface;
  }

  @Builder
  sortChip(label: ResourceStr, sort: MarketSort): void {
    Text(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontWeight(this.uiSort === sort ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.uiSort === sort
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(this.uiSort === sort
        ? this.selectedChipBg()
        : ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .onClick(() => {
        this.onSortClick(sort);
        this.activeDropdown = '';
      })
  }

  @Builder
  nsfwChip(): void {
    // 显示 NSFW 时用危险色描边警示,与普通筛选 chip 区分(主题化,不硬编码)
    Text(this.uiHideNsfw ? $r('app.string.market_hide_nsfw') : $r('app.string.market_show_nsfw'))
      .fontSize($r('app.float.app_font_caption'))
      .fontWeight(FontWeight.Medium)
      .fontColor(this.uiHideNsfw
        ? ThemePalette.textSecondaryColor(this.effectiveTheme)
        : $r('app.color.app_danger'))
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .border({
        width: this.uiHideNsfw ? 0 : 1,
        color: $r('app.color.app_danger')
      })
      .borderRadius($r('app.float.app_radius_md'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onNsfwClick();
      })
  }

  @Builder
  hideImportedChip(): void {
    Text(this.uiHideImported ? $r('app.string.market_hide_imported') : $r('app.string.market_show_imported'))
      .fontSize($r('app.float.app_font_caption'))
      .fontWeight(this.uiHideImported ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.uiHideImported
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(this.uiHideImported
        ? this.selectedChipBg()
        : ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onHideImportedClick();
      })
  }

  @Builder
  translateChip(): void {
    Text($r('app.string.market_translate_toggle'))
      .fontSize($r('app.float.app_font_caption'))
      .fontWeight(this.uiTranslateEnabled ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.uiTranslateEnabled
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(this.uiTranslateEnabled
        ? this.selectedChipBg()
        : ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onTranslateClick();
      })
  }

  // ===== 交互处理 =====

  private onSortClick(sort: MarketSort): void {
    if (this.viewModel === null || this.uiSort === sort) {
      return;
    }
    this.uiSort = sort;
    void this.viewModel!.setSort(sort);
  }

  private onNsfwClick(): void {
    if (this.viewModel === null) {
      return;
    }
    const target: boolean = !this.viewModel!.hideNsfw;
    this.viewModel!.setHideNsfw(target);
  }

  private onHideImportedClick(): void {
    if (this.viewModel === null) {
      return;
    }
    const target: boolean = !this.viewModel!.hideImported;
    this.uiHideImported = target;
    void this.viewModel!.setHideImported(target);
  }

  private onTranslateClick(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.toggleTranslate();
  }

  private onCategoryClick(index: number, searchtag: string): void {
    if (this.selectedCategoryIndex === index) {
      return;
    }
    this.selectedCategoryIndex = index;
    if (this.viewModel !== null) {
      void this.viewModel!.setTag(searchtag);
    }
  }

  // ===== 错误提示条 =====

  @Builder
  errorBanner(): void {
    Row() {
      Text(this.uiError)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Button($r('app.string.market_retry'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .padding({ left: 8, right: 8 })
        .height(28)
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.refresh();
          }
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: $r('app.float.app_spacing_4'),
      bottom: $r('app.float.app_spacing_4')
    })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 主内容区 =====

  @Builder
  marketContent(): void {
    if (this.refreshing && this.items.length === 0) {
      this.loadingView()
    } else if (this.uiError.length > 0 && this.items.length === 0) {
      this.errorView($r('app.string.market_load_failed'), this.uiError)
    } else if (this.items.length === 0) {
      this.emptyView()
    } else {
      this.characterGrid()
    }
  }

  @Builder
  characterGrid(): void {
    Refresh({ refreshing: $$this.refreshing }) {
      Grid() {
        ForEach(this.items, (item: MarketCharacter, index: number) => {
          GridItem() {
            MarketCharacterCard({
              item: item,
              imported: this.viewModel !== null && this.viewModel!.isImported(item),
              translation: this.viewModel !== null ? this.viewModel!.getTranslation(item) : null,
              allowImageLoad: this.resolveAllowImageLoad(item),
              onPress: (params: MarketCardClickParams): void => {
                this.openDetail(params.item);
              }
            })
          }
        }, (item: MarketCharacter, index: number) => marketCharacterKey(item))

        if (this.loadingMore) {
          GridItem() {
            Row() {
              LoadingProgress()
                .width(24)
                .height(24)
                .color(ThemePalette.accentColor(this.effectiveTheme))
              Text($r('app.string.market_loading'))
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .margin({ left: 8 })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: 16, bottom: 16 })
          }
        }
      }
      .columnsTemplate('1fr 1fr')
      .columnsGap($r('app.float.app_spacing_12'))
      .rowsGap($r('app.float.app_spacing_12'))
      .width('100%')
      .height('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_8'),
        bottom: 200
      })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .onReachEnd(() => {
        if (this.viewModel !== null) {
          void this.viewModel!.loadMore();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .onRefreshing(() => {
      if (this.viewModel !== null) {
        void this.viewModel!.refresh().catch((): void => {});
      } else {
        this.refreshing = false;
      }
    })
  }

  /**
   * 计算卡片是否允许加载图片。
   * NSFW 卡片仅在用户已确认显示 NSFW(hideNsfw=false)时加载大图,
   * 非 NSFW 卡片始终允许加载。
   */
  private resolveAllowImageLoad(item: MarketCharacter): boolean {
    if (!item.nsfw) {
      return true;
    }
    return !this.uiHideNsfw;
  }

  // ===== 加载 / 错误 / 空状态 =====

  @Builder
  loadingView(): void {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(ThemePalette.accentColor(this.effectiveTheme))

      Text($r('app.string.market_loading'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: $r('app.float.app_spacing_8') })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView(title: ResourceStr, description: ResourceStr): void {
    Column() {
      EmptyStateView({
        title: title,
        description: description
      })

      Button($r('app.string.market_retry'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('50%')
        .margin({ top: $r('app.float.app_spacing_16') })
        .onClick(() => {
          if (this.viewModel !== null) {
            void this.viewModel!.refresh();
          }
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: $r('app.float.app_spacing_32'), right: $r('app.float.app_spacing_32') })
  }

  @Builder
  emptyView(): void {
    Column() {
      EmptyStateView({
        title: $r('app.string.market_empty'),
        description: this.resolveEmptyDescription()
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 根据当前搜索/筛选状态给出更友好的空状态描述。
   */
  private resolveEmptyDescription(): ResourceStr {
    if (this.viewModel === null) {
      return $r('app.string.market_no_results_default_desc');
    }
    if (this.viewModel!.appliedSearch.length > 0) {
      return $r('app.string.market_no_results_search_desc');
    }
    if (this.uiHideImported) {
      return $r('app.string.market_no_results_hide_imported_desc');
    }
    return $r('app.string.market_no_results_default_desc');
  }

  // ===== 详情页跳转 =====

  /**
   * 跳转到市场角色详情页。
   * 将 MarketCharacter 序列化为 JSON 传入。
   */
  private openDetail(item: MarketCharacter): void {
    // 记录"已浏览"角色卡到永久缓存(失败不影响跳转)
    if (this.viewModel !== null) {
      void this.viewModel!.markBrowsed(item);
    }
    try {
      const baseJson: string = JSON.stringify(item);
      router.pushUrl({
        url: 'pages/MarketDetailPage',
        params: { baseJson: baseJson }
      });
    } catch (e) {
      // 静默失败,不影响其他交互
    }
  }

  // ===== NSFW 二次确认弹窗 =====

  @Builder
  nsfwConfirmDialog(): void {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.market_content_warning'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          Text($r('app.string.market_nsfw_confirm_message'))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ bottom: 20 })
            .textAlign(TextAlign.Center)
            .width('100%')

          Row() {
            Button($r('app.string.market_cancel'))
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel!.cancelShowNsfw();
                }
                this.showNsfwConfirm = false;
              })

            Button($r('app.string.market_confirm_show'))
              .fontSize(14)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White)
              .borderRadius(20)
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  void this.viewModel!.confirmShowNsfw();
                }
                this.showNsfwConfirm = false;
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius(16)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }

}
