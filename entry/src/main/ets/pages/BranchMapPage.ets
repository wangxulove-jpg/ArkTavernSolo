/**
 * BranchMapPage 分支缩进树页面(2026-09-27 改版)
 *
 * 改版动机:
 * - 原实现是「二维画布 + 176×118 方框节点 + 虚线贝塞尔连线 + 缩放平移」,
 *   分支一多整张图难分辨(同名节点、节点像一个个孤立盒子、非当前分支整体变淡)。
 * - 现改为**缩进树(graph 风格)**:拐角线 + 缩进表达层级,主路径用强调色画成一条
 *   可见的脊线,节点无边框,标题直接写"序号 + 分歧首句"。
 *
 * 功能:
 * - 一行 = 一个分支;Root 在最上,子分支缩进排在父分支下方
 * - 点行选中(不立即切换),底部按钮执行切换
 * - 当前分支整行高亮 + "当前"徽标;已选中未切换显示"已选择"
 * - 空分支(分叉点之后无新内容)标题显示"尚无新内容"
 *
 * 数据流:
 * - ChatPage 导航时传入 chatId
 * - BranchMapViewModel 通过 ConversationBranchPersistenceService 加载并拍平为行序列
 * - 切换成功后刷新行序列;返回 ChatPage 时由 ChatPage 重新加载消息和 Branch 状态
 *
 * 不依赖:Repository / ChatService / 页面实例
 */

import { BranchMapViewModel } from '../viewmodels/BranchMapViewModel';
import { AppServices } from '../services/AppServices';
import { BranchMapNode } from '../components/BranchMapNode';
import { BranchFlatRow } from '../models/BranchFlatRow';
import { Logger } from '../utils/Logger';
import { router } from '@kit.ArkUI';
import { ThemePalette } from '../theme/ThemePalette';

const LOG_TAG: string = 'BranchMapPage';

const RES_BRANCH_MAP_TITLE: string = 'branch_map_title';
const RES_BRANCH_SWITCH: string = 'branch_map_switch_button';
const RES_BRANCH_BACK: string = 'branch_map_back';
const RES_BRANCH_EMPTY: string = 'branch_map_empty';

interface BranchMapRouteParam {
  chatId: string;
}

@Entry
@Component
struct BranchMapPage {
  @State viewModel: BranchMapViewModel = new BranchMapViewModel(
    AppServices.getBranchPersistenceService()
  );
  @State readyHandled: boolean = false;
  @State errorText: string = '';
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    this.handleReady();
  }

  build() {
    Column() {
      this.titleBar();

      if (this.viewModel.errorMessage.length > 0) {
        Text(this.viewModel.errorMessage)
          .fontSize(13)
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 4 })
      }

      if (this.viewModel.getStatusText().length > 0) {
        Text(this.viewModel.getStatusText())
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 2 })
      }

      if (!this.viewModel.isLoading && this.viewModel.rows.length > 0) {
        this.legend()
      }

      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).height(1).width('100%')

      if (this.viewModel.isLoading) {
        this.loadingState();
      } else if (this.viewModel.rows.length === 0) {
        this.emptyState();
      } else {
        this.treeList();
        this.bottomBar();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  titleBar() {
    Row() {
      Button($r('app.string.' + RES_BRANCH_BACK))
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .onClick(() => {
          this.popBack();
        })

      Blank()

      Text($r('app.string.' + RES_BRANCH_MAP_TITLE))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))

      Blank()

      Text('')
        .fontSize(14)
        .width(44)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: this.statusBarHeight + 4, bottom: 0 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 图例:说明"实心点 = 当前路径、空心点 = 其他分支"。
   * 原来的画法没有任何图例,是"看不懂这张图"的一部分。
   */
  @Builder
  legend() {
    Row() {
      Column()
        .width(9)
        .height(9)
        .borderRadius(9)
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .margin({ right: 4 })

      Text('当前路径')
        .fontSize(11)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))

      Column()
        .width(9)
        .height(9)
        .borderRadius(9)
        .border({ width: 2, color: ThemePalette.dividerColor(this.effectiveTheme) })
        .margin({ left: 14, right: 4 })

      Text('其他分支')
        .fontSize(11)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
    }
    .width('100%')
    .padding({ left: 24, right: 16, top: 2, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  loadingState() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyState() {
    Column() {
      Text($r('app.string.' + RES_BRANCH_EMPTY))
        .fontSize(14)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 缩进树行列表。
   * 缩进、拐角线、圆点全部由 BranchMapNode 按行数据绘制,页面不做布局计算。
   */
  @Builder
  treeList() {
    List() {
      ForEach(this.viewModel.rows, (row: BranchFlatRow) => {
        ListItem() {
          BranchMapNode({
            row: row,
            isSelected: this.viewModel.isSelected(row.branchId),
            onTap: (branchId: string): void => {
              this.viewModel.selectBranch(branchId);
            }
          })
        }
      }, (row: BranchFlatRow) => row.branchId)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 8, right: 8, top: 4, bottom: 4 })
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  /**
   * 底部栏:选中分支摘要 + 切换按钮。
   * 原实现里写死的 "艾伦:" 预览前缀已移除——改用行自身的"分叉轮次 · 消息数"。
   */
  @Builder
  bottomBar() {
    Column() {
      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).height(1).width('100%')

      Row() {
        Column() {
          Text(this.viewModel.getSelectedTitle().length > 0
            ? this.viewModel.getSelectedTitle()
            : '点选一条分支')
            .fontSize(14)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.viewModel.getSelectedHint().length > 0) {
            Text(this.viewModel.getSelectedHint())
              .fontSize(12)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button($r('app.string.' + RES_BRANCH_SWITCH))
          .fontSize(14)
          .backgroundColor(this.canSwitch()
            ? ThemePalette.accentColor(this.effectiveTheme)
            : ThemePalette.surface2Color(this.effectiveTheme))
          .fontColor(Color.White)
          .borderRadius(8)
          .height(40)
          .padding({ left: 20, right: 20 })
          .enabled(this.canSwitch())
          .onClick(async () => {
            await this.handleSwitch();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: this.navigationBarHeight + 12 })
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .alignItems(VerticalAlign.Center)
    }
  }

  private canSwitch(): boolean {
    if (this.viewModel.isBranchOperating) {
      return false;
    }
    if (this.viewModel.selectedBranchId.length === 0) {
      return false;
    }
    return this.viewModel.selectedBranchId !== this.viewModel.activeBranchId;
  }

  private async handleSwitch(): Promise<void> {
    const previousActive: string = this.viewModel.activeBranchId;
    await this.viewModel.switchToSelected();
    if (this.viewModel.activeBranchId !== previousActive
      && this.viewModel.activeBranchId.length > 0) {
      AppStorage.set('branchChangeSeq', Date.now());
    }
  }

  private handleReady(): void {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;

    try {
      const param = router.getParams() as Record<string, Object>;
      this.handleParam(param);
    } catch (e) {
      Logger.error(LOG_TAG, 'handleReady failed: ' + String(e));
      this.errorText = '页面参数错误';
    }
  }

  private async handleParam(param: Object | undefined): Promise<void> {
    let chatId: string = '';
    try {
      if (param !== undefined && param !== null) {
        const obj = param as Record<string, Object>;
        if (obj['chatId'] !== undefined) {
          chatId = String(obj['chatId']);
        }
      }
    } catch (_e) {
      chatId = '';
    }

    if (chatId.length === 0) {
      this.errorText = '缺少会话参数';
      Logger.error(LOG_TAG, 'missing chatId param');
      return;
    }

    await this.viewModel.initialize(chatId);
  }

  private popBack(): void {
    router.back();
  }

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }
}
