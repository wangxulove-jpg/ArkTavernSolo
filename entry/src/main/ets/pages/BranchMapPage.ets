/**
 * BranchMapPage 分支树页面(T-6.4B-1.1 / T-6.4B-4)
 *
 * 独立页面,以可点击的分支树形式展示当前 Chat 的所有 Branch。
 * 替代原有平铺式 BranchListPanel 作为 Branch 状态入口的主入口。
 *
 * T-6.4B-4 改进:
 * - 移除嵌套 Scroll,改用 PanGesture + PinchGesture 实现流畅缩放平移
 * - 内容尺寸不再乘以 zoomScale,避免双重缩放
 * - 进入页面自动 adapt 到视口
 * - 末端节点显示当前对话位置
 *
 * 功能:
 * - 根据 parentBranchId 构造父子树,Root 位于顶部,Child 向下排列
 * - 父子节点之间使用虚线贝塞尔曲线连接
 * - 当前 Active Branch 使用强调色边框 + 右上角圆点
 * - 节点可点击选中(不立即切换)
 * - 底部"切换到此分支"按钮执行 switchActiveBranch
 * - 单指拖动平移,双指缩放
 *
 * 数据流:
 * - ChatPage 导航时传入 chatId
 * - BranchMapViewModel 通过 ConversationBranchPersistenceService 加载 Branch 数据
 * - 切换成功后刷新布局
 * - 返回 ChatPage 时由 ChatPage 重新加载消息和 Branch 状态
 *
 * 不依赖:
 * - Repository
 * - ChatService
 * - 页面实例
 */

import { BranchMapViewModel } from '../viewmodels/BranchMapViewModel';
import { AppServices } from '../services/AppServices';
import { BranchMapNode } from '../components/BranchMapNode';
import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';
import { BranchMapNodeLayout, BranchTreeEdge, BranchTreeLayoutResult } from '../models/BranchMapNodeLayout';
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

  // ===== 缩放与平移状态(T-6.4B-4) =====
  @State zoomScale: number = 1.0;
  @State mapOffsetX: number = 0;
  @State mapOffsetY: number = 0;

  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  private panStartX: number = 0;
  private panStartY: number = 0;
  private pinchStartScale: number = 1.0;
  private fitPerformed: boolean = false;

  private readonly MIN_SCALE: number = 0.45;
  private readonly MAX_SCALE: number = 2.5;

  aboutToAppear(): void {
    this.handleReady();
  }

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
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
            .padding({ left: 16, right: 16, top: 4, bottom: 8 })
        }

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).height(1).width('100%')

        if (this.viewModel.isLoading) {
          this.loadingState();
        } else if (this.viewModel.branches.length === 0) {
          this.emptyState();
        } else {
          this.treeContent();
          this.bottomBar();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 缩放控件浮层
      if (!this.viewModel.isLoading && this.viewModel.branches.length > 0) {
        this.zoomControls()
      }
    }
    .width('100%')
    .height('100%')
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

  @Builder
  treeContent() {
    if (this.viewModel.layout !== undefined) {
      // 视口裁剪容器:clip 确保内容不超出视口
      Stack({ alignContent: Alignment.TopStart }) {
        // 内容层:保持原始画布尺寸,通过 scale + translate 实现缩放平移
        Stack({ alignContent: Alignment.TopStart }) {
          // 连接线层:Path 命令单位为 px(官方文档),节点布局坐标为 vp。
          // 坐标换算在 buildEdgePathCmd 中通过 vp2px 显式完成,与节点层坐标系对齐。
          ForEach(this.viewModel.layout.edges,
            (edge: BranchTreeEdge) => {
              this.edgeConnection(edge)
            },
            (edge: BranchTreeEdge) => edge.parentBranchId + '->' + edge.childNodeId
          )

          // 节点层
          ForEach(this.viewModel.layout.nodes,
            (node: BranchMapNodeLayout) => {
              this.nodeWrapper(node)
            },
            (node: BranchMapNodeLayout) => node.nodeId
          )
        }
        // 内容尺寸始终是原始布局尺寸,不再乘以 zoomScale(避免双重缩放)
        .width(this.viewModel.layout.canvasWidth)
        .height(this.viewModel.layout.canvasHeight)
        .scale({
          x: this.zoomScale,
          y: this.zoomScale,
          centerX: 0,
          centerY: 0
        })
        .translate({
          x: this.mapOffsetX,
          y: this.mapOffsetY
        })
      }
      .width('100%')
      .height('100%')
      .clip(true)
      .layoutWeight(1)
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        const w: number = Number(newArea.width);
        const h: number = Number(newArea.height);
        if (w <= 0 || h <= 0) {
          return;
        }
        this.viewportWidth = w;
        this.viewportHeight = h;
        if (!this.fitPerformed) {
          this.fitMapToViewport();
          this.fitPerformed = true;
        } else {
          this.clampMapOffset();
        }
      })
      .gesture(
        GestureGroup(
          GestureMode.Parallel,

          PanGesture({
            fingers: 1,
            distance: 1
          })
            .onActionStart(() => {
              this.panStartX = this.mapOffsetX;
              this.panStartY = this.mapOffsetY;
            })
            .onActionUpdate((event: GestureEvent | undefined) => {
              if (event === undefined) {
                return;
              }
              this.mapOffsetX = this.panStartX + event.offsetX;
              this.mapOffsetY = this.panStartY + event.offsetY;
              this.clampMapOffset();
            }),

          PinchGesture({
            fingers: 2,
            distance: 3
          })
            .onActionStart(() => {
              this.pinchStartScale = this.zoomScale;
            })
            .onActionUpdate((event: GestureEvent | undefined) => {
              if (event === undefined) {
                return;
              }
              const nextScale: number = this.pinchStartScale * event.scale;
              this.applyZoomAtViewportCenter(nextScale);
            })
        )
      )
    }
  }

  /**
   * 单条连接线(流程图风格):
   * - Path 贝塞尔曲线:父底部中心 → 子顶部中心
   * - 活跃路径连线:强调色实线
   * - 非活跃路径连线:分割线色虚线
   */
  @Builder
  edgeConnection(edge: BranchTreeEdge) {
    // Path 命令单位为 px(官方文档),节点布局坐标为 vp。
    // Path 铺满画布,commands 由 buildEdgePathCmd 做 vp→px 显式换算,
    // 确保连线锚点落在节点层的 vp 坐标网格上。
    Path()
      .width(this.getEdgeLayerWidth())
      .height(this.getEdgeLayerHeight())
      .position({ x: 0, y: 0 })
      .commands(this.buildEdgePathCmd(edge))
      .fillOpacity(0)
      .stroke(this.isOnActiveEdgePath(edge)
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.dividerColor(this.effectiveTheme))
      .strokeWidth(this.isOnActiveEdgePath(edge) ? 2.5 : 1.5)
      .strokeLineCap(LineCapStyle.Round)
      .strokeDashArray(this.isOnActiveEdgePath(edge) ? [] : [4, 4])
  }

  private isOnActiveEdgePath(edge: BranchTreeEdge): boolean {
    return this.viewModel.isOnActivePath(edge.parentBranchId)
      && this.viewModel.isOnActivePath(edge.childBranchId);
  }

  /** 连线层画布宽度(Path 布局尺寸,单位 vp) */
  private getEdgeLayerWidth(): number {
    return this.viewModel.layout !== undefined ? this.viewModel.layout.canvasWidth : 0;
  }

  /** 连线层画布高度(Path 布局尺寸,单位 vp) */
  private getEdgeLayerHeight(): number {
    return this.viewModel.layout !== undefined ? this.viewModel.layout.canvasHeight : 0;
  }

  private buildEdgePathCmd(edge: BranchTreeEdge): string {
    // Path 命令单位为 px,布局坐标为 vp:按屏幕密度显式换算后再生成命令,
    // 避免 density>1 设备上连线整体缩小并偏移到左上。
    const scale: number = this.getUIContext().vp2px(1);
    const startX: number = edge.startX * scale;
    const startY: number = edge.startY * scale;
    const endX: number = edge.endX * scale;
    const endY: number = edge.endY * scale;
    const ctrlOffset: number = (edge.endY - edge.startY) * 0.4 * scale;
    this.logEdgeAlignDebugOnce(edge, scale);
    return 'M ' + startX.toString() + ' ' + startY.toString()
      + ' C ' + startX.toString() + ' ' + (startY + ctrlOffset).toString()
      + ' ' + endX.toString() + ' ' + (endY - ctrlOffset).toString()
      + ' ' + endX.toString() + ' ' + endY.toString();
  }

  /** 对齐观测日志是否已输出(每次进入页面仅输出一次) */
  private alignDebugLogged: boolean = false;

  /**
   * 一次性观测日志:输出首条连线锚点与父子节点锚点(vp)及 vp→px 换算比例。
   * 用于区分"数据错位"(edge 与 node 坐标不一致)与"渲染单位错位"(pxScale≠密度)。
   * 验证方式:hilog 过滤 BranchMapPage;正常时 edgeStart == parentBottomCenter,
   * edgeEnd == childTopCenter,pxScale 与设备屏幕密度一致。
   */
  private logEdgeAlignDebugOnce(edge: BranchTreeEdge, pxScale: number): void {
    if (this.alignDebugLogged) {
      return;
    }
    this.alignDebugLogged = true;
    const layout: BranchTreeLayoutResult | undefined = this.viewModel.layout;
    if (layout === undefined) {
      return;
    }
    const parentNode: BranchMapNodeLayout | undefined = layout.nodes.find(
      (n: BranchMapNodeLayout): boolean => n.branchId === edge.parentBranchId
    );
    const childNode: BranchMapNodeLayout | undefined = layout.nodes.find(
      (n: BranchMapNodeLayout): boolean => n.nodeId === edge.childNodeId
    );
    const parentAnchor: string = parentNode !== undefined
      ? (parentNode.x + parentNode.width / 2).toString() + ',' + (parentNode.y + parentNode.height).toString()
      : 'n/a';
    const childAnchor: string = childNode !== undefined
      ? (childNode.x + childNode.width / 2).toString() + ',' + childNode.y.toString()
      : 'n/a';
    Logger.debug(LOG_TAG,
      'edge align check: edgeStart=' + edge.startX.toString() + ',' + edge.startY.toString()
      + ' edgeEnd=' + edge.endX.toString() + ',' + edge.endY.toString()
      + ' parentBottomCenter=' + parentAnchor
      + ' childTopCenter=' + childAnchor
      + ' pxScale=' + pxScale.toString());
  }

  // ===== 缩放与平移方法(T-6.4B-4) =====

  /**
   * 将整个地图适应到视口内。
   */
  private fitMapToViewport(): void {
    if (this.viewModel.layout === undefined) {
      return;
    }
    if (this.viewportWidth <= 0 || this.viewportHeight <= 0) {
      return;
    }

    const canvasWidth: number = Math.max(1, this.viewModel.layout.canvasWidth);
    const canvasHeight: number = Math.max(1, this.viewModel.layout.canvasHeight);
    const availableWidth: number = Math.max(1, this.viewportWidth - 32);
    const availableHeight: number = Math.max(1, this.viewportHeight - 32);

    this.zoomScale = this.clampScale(
      Math.min(
        availableWidth / canvasWidth,
        availableHeight / canvasHeight,
        1.0
      )
    );

    this.mapOffsetX = (this.viewportWidth - canvasWidth * this.zoomScale) / 2;
    this.mapOffsetY = 16;
    this.clampMapOffset();
  }

  /**
   * 限制缩放范围。
   */
  private clampScale(value: number): number {
    return Math.max(this.MIN_SCALE, Math.min(this.MAX_SCALE, value));
  }

  /**
   * 限制平移偏移量,防止内容拖出视口。
   */
  private clampMapOffset(): void {
    if (this.viewModel.layout === undefined) {
      return;
    }
    const contentWidth: number = this.viewModel.layout.canvasWidth * this.zoomScale;
    const contentHeight: number = this.viewModel.layout.canvasHeight * this.zoomScale;

    if (contentWidth <= this.viewportWidth) {
      this.mapOffsetX = (this.viewportWidth - contentWidth) / 2;
    } else {
      const minX: number = this.viewportWidth - contentWidth;
      this.mapOffsetX = Math.max(minX, Math.min(0, this.mapOffsetX));
    }

    if (contentHeight <= this.viewportHeight) {
      this.mapOffsetY = 16;
    } else {
      const minY: number = this.viewportHeight - contentHeight - 16;
      this.mapOffsetY = Math.max(minY, Math.min(16, this.mapOffsetY));
    }
  }

  /**
   * 在视口中心缩放,保持视口中心点对应的地图坐标不变。
   */
  private applyZoomAtViewportCenter(nextScaleValue: number): void {
    const nextScale: number = this.clampScale(nextScaleValue);
    const oldScale: number = this.zoomScale;
    if (Math.abs(nextScale - oldScale) < 0.001) {
      return;
    }

    const centerX: number = this.viewportWidth / 2;
    const centerY: number = this.viewportHeight / 2;

    // 计算视口中心在地图坐标系中的位置
    const mapPointX: number = (centerX - this.mapOffsetX) / oldScale;
    const mapPointY: number = (centerY - this.mapOffsetY) / oldScale;

    this.zoomScale = nextScale;

    // 缩放后保持该点仍位于视口中心
    this.mapOffsetX = centerX - mapPointX * nextScale;
    this.mapOffsetY = centerY - mapPointY * nextScale;

    this.clampMapOffset();
  }

  // ===== 缩放控件 =====

  @Builder
  zoomControls() {
    Column() {
      // 适应屏幕按钮
      Stack() {
        Text('适应')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width(44)
      .height(36)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(8)
      .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
      .margin({ bottom: 8 })
      .onClick(() => {
        this.fitMapToViewport();
      })

      // 放大按钮
      Stack() {
        Text('+')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.zoomScale < this.MAX_SCALE - 0.001
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textSecondaryColor(this.effectiveTheme))
      }
      .width(44)
      .height(44)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(22)
      .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
      .margin({ bottom: 8 })
      .opacity(this.zoomScale < this.MAX_SCALE - 0.001 ? 1.0 : 0.4)
      .onClick(() => {
        const newScale: number = this.clampScale(this.zoomScale + 0.25);
        this.applyZoomAtViewportCenter(newScale);
      })

      // 缩放比例(点击重置为 1.0)
      Stack() {
        Text(Math.round(this.zoomScale * 100) + '%')
          .fontSize(12)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width(44)
      .height(36)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(8)
      .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
      .margin({ bottom: 8 })
      .onClick(() => {
        this.applyZoomAtViewportCenter(1.0);
      })

      // 缩小按钮
      Stack() {
        Text('−')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.zoomScale > this.MIN_SCALE + 0.001
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textSecondaryColor(this.effectiveTheme))
      }
      .width(44)
      .height(44)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(22)
      .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
      .opacity(this.zoomScale > this.MIN_SCALE + 0.001 ? 1.0 : 0.4)
      .onClick(() => {
        const newScale: number = this.clampScale(this.zoomScale - 0.25);
        this.applyZoomAtViewportCenter(newScale);
      })
    }
    .padding({
      top: this.statusBarHeight + 72,
      right: 16
    })
  }

  @Builder
  nodeWrapper(node: BranchMapNodeLayout) {
    Column() {
      BranchMapNode({
        displayInfo: this.findDisplayInfo(node.branchId),
        isActive: this.viewModel.isActiveBranch(node.branchId),
        isSelected: this.viewModel.isSelected(node.branchId),
        isTerminal: node.isTerminal,
        isCurrent: node.isCurrent,
        isOnPath: this.viewModel.isOnActivePath(node.branchId),
        onTap: (branchId: string) => {
          this.viewModel.selectBranch(branchId);
        }
      })
    }
    .width(node.width)
    .height(node.height)
    .position({ x: node.x, y: node.y })
    .opacity(this.viewModel.isOnActivePath(node.branchId) || this.viewModel.isSelected(node.branchId)
      ? 1.0 : 0.7)
  }

  @Builder
  bottomBar() {
    Column() {
      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).height(1).width('100%')

      Row() {
        Column() {
          Text(this.viewModel.getSelectedDisplayName())
            .fontSize(14)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.viewModel.getSelectedForkUserPreview().length > 0) {
            Text('你:' + this.viewModel.getSelectedForkUserPreview())
              .fontSize(12)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }

          if (this.viewModel.getSelectedAssistantPreview().length > 0) {
            Text('艾伦:' + this.viewModel.getSelectedAssistantPreview())
              .fontSize(12)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }

          Text(this.viewModel.getSelectedMessageCount().toString() + ' 条消息')
            .fontSize(12)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ top: 2 })
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

  private findDisplayInfo(branchId: string): BranchMapDisplayInfo {
    const info: BranchMapDisplayInfo | undefined =
      this.viewModel.getDisplayInfo(branchId);
    if (info !== undefined) {
      return info;
    }
    return {
      summary: {
        id: '',
        parentBranchId: undefined,
        forkMessageId: undefined,
        name: '',
        isRoot: true,
        messageCount: 0,
        createdAt: 0,
        updatedAt: 0,
        lastMessageAt: 0,
        isActive: false
      },
      branchId: '',
      parentBranchId: undefined,
      forkMessageId: undefined,
      forkTurnNumber: 0,
      currentMaxTurn: 0,
      forkUserPreview: '',
      firstDivergentAssistantPreview: '',
      latestMessagePreview: '',
      messageCount: 0,
      isRoot: true,
      isActive: false,
      createdAt: 0,
      nodeId: '',
      isTerminal: false,
      isCurrent: false
    };
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
    // fitMapToViewport 在 onAreaChange 中自动调用
  }

  private popBack(): void {
    router.back();
  }

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }
}