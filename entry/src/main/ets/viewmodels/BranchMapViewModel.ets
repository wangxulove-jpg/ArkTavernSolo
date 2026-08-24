/**
 * BranchMapViewModel 分支树页面状态管理(T-6.4B-1.1 / T-6.4B-1.2)
 *
 * 职责:
 * - 加载指定 Chat 的 BranchMapDisplayInfo 列表(含 fork User 预览 + 分歧 Assistant 预览)
 * - 加载 Active Branch、RecordCounts
 * - 计算 Branch 树布局(BranchTreeLayout)
 * - 处理节点选中
 * - 调用 ConversationBranchPersistenceService.switchActiveBranch 切换 Branch
 * - 切换成功后刷新布局和 Active 状态
 *
 * 不依赖:
 * - ArkUI / 页面
 * - Repository(DbHelper 由 PersistenceService 封装)
 * - ChatService(避免初始化完整会话)
 *
 * 设计原则:
 * - @Observed 装饰,ArkUI 可直接绑定
 * - 通过 AppServices.getBranchPersistenceService() 获取服务
 * - 失败时保留当前状态,显示错误提示,不静默失败
 * - 不记录完整 Branch ID / Message ID / chatId / SQL
 */

import { ConversationBranchPersistenceService } from '../services/ConversationBranchPersistenceService';
import {
  ConversationBranchSummary,
  ConversationRecordCounts
} from '../models/ConversationBranch';
import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';
import { BranchMapNodeLayout, BranchTreeLayoutResult, BranchTreeEdge } from '../models/BranchMapNodeLayout';
import { computeBranchTreeLayout, getNodeWidth, getNodeHeight, getTerminalNodeHeight, getVerticalGap, getCanvasPadding } from '../utils/BranchTreeLayout';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'BranchMapViewModel';

@Observed
export class BranchMapViewModel {
  /** Branch 摘要列表(向后兼容,从 displayInfos 派生) */
  branches: ConversationBranchSummary[] = [];
  /** T-6.4B-1.2: BranchMap 展示信息列表(含预览) */
  displayInfos: BranchMapDisplayInfo[] = [];
  /** 当前活动 Branch ID */
  activeBranchId: string = '';
  /** Branch 记录数量统计 */
  recordCounts: ConversationRecordCounts | undefined = undefined;
  /** 用户选中的 Branch ID(不等于 Active Branch) */
  selectedBranchId: string = '';
  /** 树布局结果 */
  layout: BranchTreeLayoutResult | undefined = undefined;
  /** Branch 切换操作进行中 */
  isBranchOperating: boolean = false;
  /** 加载中 */
  isLoading: boolean = true;
  /** 错误信息(空表示无错误) */
  errorMessage: string = '';
  /** 当前活跃路径上的所有 Branch ID(Root → Active Branch) */
  activePathBranchIds: Set<string> = new Set<string>();

  private branchPersistenceService: ConversationBranchPersistenceService;
  private chatId: string = '';
  private disposed: boolean = false;

  constructor(branchPersistenceService: ConversationBranchPersistenceService) {
    this.branchPersistenceService = branchPersistenceService;
  }

  /**
   * 初始化:加载指定 Chat 的 Branch 数据并计算布局。
   * 默认选中当前 Active Branch。
   */
  async initialize(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.chatId = chatId;
    this.isLoading = true;
    this.errorMessage = '';
    try {
      await this.reload();
      // 默认选中 Active Branch
      this.selectedBranchId = this.activeBranchId;
    } catch (e) {
      this.errorMessage = '加载分支失败';
      Logger.error(LOG_TAG, 'initialize failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 重新加载 Branch 数据并重算布局。
   * T-6.4B-1.2: 使用 loadBranchMapDisplayInfos 获取含预览的展示信息。
   */
  private async reload(): Promise<void> {
    if (this.chatId.length === 0) {
      return;
    }
    const displayInfos: BranchMapDisplayInfo[] =
      await this.branchPersistenceService.loadBranchMapDisplayInfos(this.chatId);
    const branches: ConversationBranchSummary[] = displayInfos.map(
      (info: BranchMapDisplayInfo): ConversationBranchSummary => info.summary
    );
    const activeBranch: ConversationBranchSummary | undefined =
      branches.find((b: ConversationBranchSummary): boolean => b.isActive);
    const counts: ConversationRecordCounts =
      await this.branchPersistenceService.getRecordCounts(this.chatId);

    this.displayInfos = displayInfos;
    this.branches = branches;
    this.activeBranchId = activeBranch !== undefined ? activeBranch.id : '';
    this.recordCounts = counts;
    let layout: BranchTreeLayoutResult = computeBranchTreeLayout(branches, displayInfos);
    layout = this.appendCurrentHeadNode(displayInfos, layout);
    this.layout = layout;
    this.computeActivePath();
  }

  /**
   * 选中指定 Branch(不切换 Active)。
   */
  selectBranch(branchId: string): void {
    if (this.disposed || this.isBranchOperating) {
      return;
    }
    this.selectedBranchId = branchId;
  }

  /**
   * 切换 Active Branch 到当前选中的 Branch。
   * 成功后刷新布局和 Active 状态。
   */
  async switchToSelected(): Promise<void> {
    if (this.disposed || this.isBranchOperating) {
      return;
    }
    if (this.selectedBranchId.length === 0) {
      this.errorMessage = '请先选择一个分支';
      return;
    }
    if (this.selectedBranchId === this.activeBranchId) {
      // 已是当前分支,无操作
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    try {
      await this.branchPersistenceService.switchActiveBranch(
        this.chatId, this.selectedBranchId
      );
      await this.reload();
      // 选中跟随 Active
      this.selectedBranchId = this.activeBranchId;
    } catch (e) {
      this.errorMessage = '切换分支失败,请重试';
      Logger.error(LOG_TAG, 'switchToSelected failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  /**
   * 获取顶部统计文本。
   */
  getStatusText(): string {
    if (this.recordCounts === undefined) {
      return '';
    }
    const current: number = this.recordCounts.currentBranchMessageCount;
    const total: number = this.recordCounts.totalUniqueMessageCount;
    const branches: number = this.recordCounts.totalBranchCount;
    return '当前分支 ' + current.toString() + ' 条 · 全部消息 ' + total.toString()
      + ' 条 · ' + branches.toString() + ' 个分支';
  }

  /**
   * 判断指定 Branch 是否为当前选中。
   */
  isSelected(branchId: string): boolean {
    return this.selectedBranchId === branchId;
  }

  /**
   * 判断指定 Branch 是否为当前 Active。
   */
  isActiveBranch(branchId: string): boolean {
    return this.activeBranchId === branchId;
  }

  /**
   * T-6.4B-1.2: 获取指定 Branch 的展示信息。
   */
  getDisplayInfo(branchId: string): BranchMapDisplayInfo | undefined {
    for (let i = 0; i < this.displayInfos.length; i++) {
      if (this.displayInfos[i].branchId === branchId) {
        return this.displayInfos[i];
      }
    }
    return undefined;
  }

  /**
   * T-6.4B-1.2: 获取选中 Branch 的显示名称。
   * Root: "主分支"
   * 非 Root: "第 N 轮分支"(N = forkTurnNumber)
   */
  getSelectedDisplayName(): string {
    if (this.selectedBranchId.length === 0) {
      return '';
    }
    const info: BranchMapDisplayInfo | undefined =
      this.getDisplayInfo(this.selectedBranchId);
    if (info === undefined) {
      return '';
    }
    if (info.isRoot) {
      return '主分支';
    }
    if (info.forkTurnNumber > 0) {
      return '第 ' + info.forkTurnNumber.toString() + ' 轮分支';
    }
    return '分支';
  }

  /**
   * T-6.4B-1.2: 获取选中 Branch 的 fork User 预览。
   */
  getSelectedForkUserPreview(): string {
    if (this.selectedBranchId.length === 0) {
      return '';
    }
    const info: BranchMapDisplayInfo | undefined =
      this.getDisplayInfo(this.selectedBranchId);
    return info !== undefined ? info.forkUserPreview : '';
  }

  /**
   * T-6.4B-1.2: 获取选中 Branch 的分歧 Assistant 预览。
   */
  getSelectedAssistantPreview(): string {
    if (this.selectedBranchId.length === 0) {
      return '';
    }
    const info: BranchMapDisplayInfo | undefined =
      this.getDisplayInfo(this.selectedBranchId);
    return info !== undefined ? info.firstDivergentAssistantPreview : '';
  }

  /**
   * 获取选中 Branch 的消息数。
   */
  getSelectedMessageCount(): number {
    if (this.selectedBranchId.length === 0) {
      return 0;
    }
    const info: BranchMapDisplayInfo | undefined =
      this.getDisplayInfo(this.selectedBranchId);
    return info !== undefined ? info.messageCount : 0;
  }

  /**
   * 为当前对话的 Active Branch 追加末端显示节点。
   * 解决"不创建分支就不显示当前对话位置"的问题。
   *
   * 逻辑:
   * - 查找 Active Branch 在布局中的最后一个真实节点
   * - 在其下方追加一个 isTerminal=true, isCurrent=true 的末端节点
   * - 添加连接线从最后一个真实节点到末端节点
   * - 更新画布高度
   */
  private appendCurrentHeadNode(
    displayInfos: BranchMapDisplayInfo[],
    layout: BranchTreeLayoutResult
  ): BranchTreeLayoutResult {
    if (this.activeBranchId.length === 0) {
      return layout;
    }

    // 查找 Active Branch 的展示信息
    const activeInfo: BranchMapDisplayInfo | undefined = displayInfos.find(
      (info: BranchMapDisplayInfo): boolean => info.branchId === this.activeBranchId
    );
    if (activeInfo === undefined) {
      return layout;
    }

    // Active Branch 还有下级子分支时,用子分支链路展示"当前位置",
    // 不再追加末端节点:否则末端节点会占据与下层子节点相同的槽位导致重叠。
    const hasDescendant: boolean = layout.nodes.some(
      (n: BranchMapNodeLayout): boolean =>
        !n.isTerminal && n.parentBranchId === this.activeBranchId
    );
    if (hasDescendant) {
      return layout;
    }

    // 查找 Active Branch 在布局中的最后一个真实节点
    const branchNodes: BranchMapNodeLayout[] = layout.nodes.filter(
      (n: BranchMapNodeLayout): boolean => n.branchId === this.activeBranchId && !n.isTerminal
    );
    if (branchNodes.length === 0) {
      return layout;
    }
    // 按 Y 坐标排序找到最后的节点
    branchNodes.sort((a: BranchMapNodeLayout, b: BranchMapNodeLayout): number => a.y - b.y);
    const lastNode: BranchMapNodeLayout = branchNodes[branchNodes.length - 1];

    // 计算末端节点 nodeId
    const terminalNodeId: string = 'head:' + this.activeBranchId + ':' + activeInfo.currentMaxTurn;

    // 计算末端节点的 Y 坐标(在最后一个节点下方一层)
    const NODE_HEIGHT_VALUE: number = getNodeHeight();
    const TERMINAL_HEIGHT: number = getTerminalNodeHeight();
    const VERTICAL_GAP: number = getVerticalGap();
    const NODE_WIDTH: number = getNodeWidth();
    const CANVAS_PADDING: number = getCanvasPadding();

    const terminalY: number = lastNode.y + lastNode.height + VERTICAL_GAP;

    // 创建末端节点布局
    const terminalNode: BranchMapNodeLayout = {
      nodeId: terminalNodeId,
      branchId: this.activeBranchId,
      parentBranchId: lastNode.parentBranchId,
      depth: lastNode.depth + 1,
      forkTurnNumber: activeInfo.currentMaxTurn,
      currentMaxTurn: activeInfo.currentMaxTurn,
      x: lastNode.x,
      y: terminalY,
      width: NODE_WIDTH,
      height: TERMINAL_HEIGHT,
      siblingIndex: 0,
      siblingCount: 0,
      isTerminal: true,
      isCurrent: true
    };

    // 创建连接线(最后一个真实节点 → 末端节点)
    const terminalEdge: BranchTreeEdge = {
      parentBranchId: lastNode.branchId,
      childBranchId: terminalNode.branchId,
      childNodeId: terminalNode.nodeId,
      startX: lastNode.x + lastNode.width / 2,
      startY: lastNode.y + lastNode.height,
      endX: terminalNode.x + terminalNode.width / 2,
      endY: terminalNode.y
    };

    // 更新画布高度
    const newCanvasHeight: number = Math.max(
      layout.canvasHeight,
      terminalY + TERMINAL_HEIGHT + CANVAS_PADDING
    );

    return {
      nodes: [...layout.nodes, terminalNode],
      canvasWidth: layout.canvasWidth,
      canvasHeight: newCanvasHeight,
      edges: [...layout.edges, terminalEdge]
    };
  }

  /**
   * 计算当前活跃路径(Root → Active Branch)上的所有 Branch ID。
   * 沿 parentBranchId 向上遍历到 Root,收集路径上所有 ID。
   */
  private computeActivePath(): void {
    const pathIds: Set<string> = new Set<string>();
    if (this.activeBranchId.length === 0) {
      this.activePathBranchIds = pathIds;
      return;
    }
    let currentId: string = this.activeBranchId;
    let safety: number = 0;
    while (currentId.length > 0 && safety < 100) {
      safety++;
      pathIds.add(currentId);
      const info: BranchMapDisplayInfo | undefined = this.displayInfos.find(
        (d: BranchMapDisplayInfo): boolean => d.branchId === currentId
      );
      if (info === undefined || info.parentBranchId === undefined || info.parentBranchId.length === 0) {
        break;
      }
      currentId = info.parentBranchId;
    }
    this.activePathBranchIds = pathIds;
  }

  /**
   * 判断指定 Branch 是否在当前活跃路径上。
   */
  isOnActivePath(branchId: string): boolean {
    return this.activePathBranchIds.has(branchId);
  }

  dispose(): void {
    this.disposed = true;
  }
}
