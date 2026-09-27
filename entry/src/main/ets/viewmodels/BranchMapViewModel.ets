/**
 * BranchMapViewModel 分支树页面状态管理(2026-09-27 改版:缩进树)
 *
 * 职责:
 * - 加载指定 Chat 的 BranchMapDisplayInfo 列表(含 fork User 预览 + 分歧 Assistant 预览)
 * - 加载 Active Branch、RecordCounts
 * - 把分支树拍平成缩进树行序列(见 utils/BranchTreeFlatten)
 * - 处理节点选中
 * - 调用 ConversationBranchPersistenceService.switchActiveBranch 切换 Branch
 * - 切换成功后刷新行序列和 Active 状态
 *
 * 改版说明:
 * - 原「二维画布布局(computeBranchTreeLayout + 末端节点追加)」已移除,
 *   现由 BranchTreeFlatten 直接拍平成 List 行;缩放/平移随之删除。
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
import { ConversationRecordCounts } from '../models/ConversationBranch';
import { BranchMapDisplayInfo } from '../models/BranchMapDisplayInfo';
import { BranchFlatRow } from '../models/BranchFlatRow';
import { flattenBranchTree, formatRowTitle, formatRowHint } from '../utils/BranchTreeFlatten';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'BranchMapViewModel';

@Observed
export class BranchMapViewModel {
  /** BranchMap 展示信息列表(含预览,用于派生 rows) */
  displayInfos: BranchMapDisplayInfo[] = [];
  /** 缩进树行序列(DFS 顺序,页面直接渲染) */
  rows: BranchFlatRow[] = [];
  /** 当前活动 Branch ID */
  activeBranchId: string = '';
  /** Branch 记录数量统计 */
  recordCounts: ConversationRecordCounts | undefined = undefined;
  /** 用户选中的 Branch ID(不等于 Active Branch) */
  selectedBranchId: string = '';
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
   * 初始化:加载指定 Chat 的 Branch 数据并生成行序列。
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
   * 重新加载 Branch 数据并重建行序列。
   */
  private async reload(): Promise<void> {
    if (this.chatId.length === 0) {
      return;
    }
    const displayInfos: BranchMapDisplayInfo[] =
      await this.branchPersistenceService.loadBranchMapDisplayInfos(this.chatId);
    const counts: ConversationRecordCounts =
      await this.branchPersistenceService.getRecordCounts(this.chatId);

    this.displayInfos = displayInfos;
    let activeId: string = '';
    for (let i = 0; i < displayInfos.length; i++) {
      if (displayInfos[i].isActive) {
        activeId = displayInfos[i].branchId;
        break;
      }
    }
    this.activeBranchId = activeId;
    this.recordCounts = counts;
    // 先算活跃路径,再拍平(行需要 isOnPath)
    this.computeActivePath();
    this.rows = flattenBranchTree(this.displayInfos, this.activeBranchId, this.activePathBranchIds);
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
   * 成功后刷新行序列和 Active 状态。
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
   * 取选中分支对应的行(供底部栏展示;未选中/未找到返回 undefined)。
   */
  getSelectedRow(): BranchFlatRow | undefined {
    if (this.selectedBranchId.length === 0) {
      return undefined;
    }
    return this.rows.find((row: BranchFlatRow): boolean => row.branchId === this.selectedBranchId);
  }

  /**
   * 底部摘要标题(序号 + 分歧首句;未选中返回空字符串)。
   */
  getSelectedTitle(): string {
    const row: BranchFlatRow | undefined = this.getSelectedRow();
    return row !== undefined ? formatRowTitle(row) : '';
  }

  /**
   * 底部摘要副标题(分叉轮次 + 消息数;未选中返回空字符串)。
   */
  getSelectedHint(): string {
    const row: BranchFlatRow | undefined = this.getSelectedRow();
    return row !== undefined ? formatRowHint(row) : '';
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
