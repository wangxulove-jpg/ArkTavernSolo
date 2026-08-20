/**
 * MemoryManagementViewModel 对话记忆管理页面状态(v12)
 *
 * v12 升级:
 * - 支持多层记忆分类查看(Core/Chapter/Rolling/Legacy)
 * - 支持查看/编辑/启用/禁用/删除单条 Memory
 * - 显示失效状态和来源分支(继承标记)
 * - 显示覆盖消息范围和创建时间
 *
 * 职责:
 * - 加载当前 Active Branch 的全部 Memory(按类型分组)
 * - 启用/禁用 Memory
 * - 手动编辑摘要文本
 * - 手动删除单条 Memory
 * - 手动触发重新生成摘要
 * - 清除当前 Branch 自产记忆(继承祖先的不删)
 *
 * 数据流:
 * - MemoryManagementPage 传入 chatId
 * - ViewModel 通过 ConversationBranchPersistenceService 加载 Active BranchId + 消息
 * - ViewModel 通过 MemoryService 操作 Memory
 *
 * 不依赖:
 * - ArkUI / 页面
 * - 网络/Provider(通过 MemoryService 间接调用 ModelService)
 */

import { MemoryService } from '../services/MemoryService';
import { ConversationBranchPersistenceService } from '../services/ConversationBranchPersistenceService';
import { ChatMemory, MemoryType } from '../models/ChatMemory';
import { ChatMessage } from '../models/ChatMessage';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MemoryMgmtVM';

/** 记忆类型显示名称 */
const MEMORY_TYPE_LABELS: Record<MemoryType, string> = {
  'core': '核心记忆',
  'chapter': '章节记忆',
  'rolling': '滚动记忆',
  'legacy': '早期记忆'
};

/** 记忆类型排序优先级(数字越小越靠前) */
const MEMORY_TYPE_ORDER: Record<MemoryType, number> = {
  'core': 0,
  'chapter': 1,
  'rolling': 2,
  'legacy': 3
};

/**
 * 单条 Memory 的 UI 展示项。
 */
export interface MemoryDisplayItem {
  /** 原始 Memory */
  memory: ChatMemory;
  /** 类型显示名称 */
  typeLabel: string;
  /** 标题(空则用类型标签) */
  displayTitle: string;
  /** 摘要预览(前 80 字符) */
  summaryPreview: string;
  /** 覆盖范围文本 */
  coverageText: string;
  /** 创建时间文本 */
  createdTimeText: string;
  /** 是否继承自祖先 */
  isInherited: boolean;
  /** 是否已失效 */
  isInvalidated: boolean;
  /** 是否启用 */
  isEnabled: boolean;
}

/**
 * 按类型分组的 Memory 列表。
 */
export interface MemoryTypeGroup {
  /** 记忆类型 */
  memoryType: MemoryType;
  /** 类型显示名称 */
  typeLabel: string;
  /** 该类型的 Memory 列表 */
  items: MemoryDisplayItem[];
}

@Observed
export class MemoryManagementViewModel {
  /** 当前 Branch 最新 Memory(兼容旧字段,用于统计) */
  memory: ChatMemory | null = null;
  /** Active Branch ID */
  activeBranchId: string = '';
  /** 加载中 */
  isLoading: boolean = true;
  /** 操作进行中(启用/禁用/编辑/重新生成/清除/删除) */
  isOperating: boolean = false;
  /** 错误信息(空表示无错误) */
  errorMessage: string = '';
  /** 状态消息(成功提示,自动消失) */
  statusMessage: string = '';
  /** 编辑模式 */
  isEditing: boolean = false;
  /** 编辑中的摘要文本 */
  editingSummary: string = '';
  /** 当前编辑的 Memory ID */
  editingMemoryId: string = '';
  /** Branch 消息总数 */
  totalMessageCount: number = 0;
  /** 摘要覆盖的消息数 */
  summarizedMessageCount: number = 0;
  /** 未总结消息数 */
  unsummarizedMessageCount: number = 0;
  /** 未总结字符数 */
  unsummarizedChars: number = 0;
  /** 摘要字符数(所有有效记忆的总和) */
  summaryChars: number = 0;

  /** v12: 按类型分组的 Memory 列表 */
  memoryGroups: MemoryTypeGroup[] = [];
  /** v12: 当前展开查看详情的 Memory ID */
  expandedMemoryId: string = '';
  /** v12: 当前选中的 Memory ID(用于编辑) */
  selectedMemoryId: string = '';
  /** v12: 是否显示删除确认 */
  showDeleteConfirm: boolean = false;
  /** v12: 待删除的 Memory ID */
  pendingDeleteMemoryId: string = '';

  private memoryService: MemoryService;
  private branchPersistenceService: ConversationBranchPersistenceService;
  private chatId: string = '';
  private disposed: boolean = false;

  constructor(
    memoryService: MemoryService,
    branchPersistenceService: ConversationBranchPersistenceService
  ) {
    this.memoryService = memoryService;
    this.branchPersistenceService = branchPersistenceService;
  }

  /**
   * 初始化:加载 Active Branch 的 Memory 与统计。
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
    } catch (e) {
      this.errorMessage = '加载记忆失败';
      Logger.error(LOG_TAG, 'initialize failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 重新加载 Memory 与 Branch 消息统计。
   */
  async reload(): Promise<void> {
    if (this.chatId.length === 0) {
      return;
    }
    try {
      // 加载 Active Branch 消息
      const messages: ChatMessage[] =
        await this.branchPersistenceService.loadActiveBranchMessages(this.chatId);
      this.totalMessageCount = messages.length;

      // 获取 Active Branch ID
      const activeBranch = await this.branchPersistenceService.getActiveBranch(this.chatId);
      const branchId: string = activeBranch !== null ? activeBranch.id : '';
      this.activeBranchId = branchId;
      if (branchId.length === 0) {
        this.memory = null;
        this.memoryGroups = [];
        this.summarizedMessageCount = 0;
        this.unsummarizedMessageCount = this.totalMessageCount;
        this.unsummarizedChars = 0;
        this.summaryChars = 0;
        return;
      }

      // 加载全部 Memory(按类型分组)
      const allMemories: ChatMemory[] = await this.memoryService.listByBranch(branchId);
      this.memoryGroups = this.groupMemoriesByType(allMemories);

      // 兼容旧字段:取最新有效 Memory
      let latestValid: ChatMemory | null = null;
      let maxEndPos: number = -1;
      let totalChars: number = 0;
      for (let i = 0; i < allMemories.length; i++) {
        const m: ChatMemory = allMemories[i];
        if (!m.invalidated && m.enabled) {
          totalChars += m.summary.length;
          if (m.endPosition > maxEndPos) {
            maxEndPos = m.endPosition;
            latestValid = m;
          }
        }
      }
      this.memory = latestValid;
      this.summaryChars = totalChars;

      // 统计
      this.summarizedMessageCount = latestValid !== null && latestValid.endPosition >= 0
        ? latestValid.endPosition + 1 : 0;
      this.unsummarizedMessageCount = Math.max(0, this.totalMessageCount - this.summarizedMessageCount);
      let chars: number = 0;
      for (let i = this.summarizedMessageCount; i < messages.length; i++) {
        chars += messages[i].content.length;
      }
      this.unsummarizedChars = chars;
    } catch (e) {
      this.errorMessage = '加载记忆失败';
      Logger.error(LOG_TAG, 'reload failed: ' + String(e));
    }
  }

  /**
   * 将 Memory 列表按类型分组并构造 UI 展示项。
   */
  private groupMemoriesByType(memories: ChatMemory[]): MemoryTypeGroup[] {
    const groupMap: Map<MemoryType, ChatMemory[]> = new Map<MemoryType, ChatMemory[]>();
    groupMap.set('core', []);
    groupMap.set('chapter', []);
    groupMap.set('rolling', []);
    groupMap.set('legacy', []);

    for (let i = 0; i < memories.length; i++) {
      const m: ChatMemory = memories[i];
      const list: ChatMemory[] | undefined = groupMap.get(m.memoryType);
      if (list !== undefined) {
        list.push(m);
      } else {
        // 未知类型归入 rolling
        groupMap.get('rolling')!.push(m);
      }
    }

    const groups: MemoryTypeGroup[] = [];
    const types: MemoryType[] = ['core', 'chapter', 'rolling', 'legacy'];
    for (let t = 0; t < types.length; t++) {
      const type: MemoryType = types[t];
      const list: ChatMemory[] = groupMap.get(type)!;
      if (list.length === 0) {
        continue;
      }
      // 按 endPosition ASC 排序(chapter/rolling/legacy 按时间正序)
      list.sort((a: ChatMemory, b: ChatMemory): number => a.endPosition - b.endPosition);

      const items: MemoryDisplayItem[] = [];
      for (let i = 0; i < list.length; i++) {
        items.push(this.buildDisplayItem(list[i]));
      }
      groups.push({
        memoryType: type,
        typeLabel: MEMORY_TYPE_LABELS[type],
        items: items
      });
    }

    // 按类型优先级排序
    groups.sort((a: MemoryTypeGroup, b: MemoryTypeGroup): number =>
      MEMORY_TYPE_ORDER[a.memoryType] - MEMORY_TYPE_ORDER[b.memoryType]
    );

    return groups;
  }

  /**
   * 构造单条 Memory 的 UI 展示项。
   */
  private buildDisplayItem(memory: ChatMemory): MemoryDisplayItem {
    const typeLabel: string = MEMORY_TYPE_LABELS[memory.memoryType];
    const title: string = memory.title.length > 0 ? memory.title : typeLabel;
    const summaryPreview: string = memory.summary.length > 80
      ? memory.summary.substring(0, 80) + '...'
      : memory.summary;
    const coverageText: string = memory.endPosition >= 0
      ? (memory.startPosition + 1).toString() + ' - ' + (memory.endPosition + 1).toString()
      : '无范围';
    return {
      memory: memory,
      typeLabel: typeLabel,
      displayTitle: title,
      summaryPreview: summaryPreview,
      coverageText: coverageText,
      createdTimeText: this.formatTime(memory.createdAt),
      isInherited: memory.inheritedFromMemoryId !== undefined && memory.inheritedFromMemoryId.length > 0,
      isInvalidated: memory.invalidated,
      isEnabled: memory.enabled
    };
  }

  /**
   * 展开/折叠 Memory 详情。
   */
  toggleExpand(memoryId: string): void {
    this.expandedMemoryId = this.expandedMemoryId === memoryId ? '' : memoryId;
  }

  /**
   * 进入编辑模式。
   */
  enterEditMode(memoryId: string): void {
    const memory: ChatMemory | null = this.findMemoryById(memoryId);
    if (memory === null) {
      return;
    }
    this.editingMemoryId = memoryId;
    this.editingSummary = memory.summary;
    this.isEditing = true;
  }

  /**
   * 取消编辑。
   */
  cancelEdit(): void {
    this.isEditing = false;
    this.editingSummary = '';
    this.editingMemoryId = '';
  }

  /**
   * 保存编辑后的摘要。
   */
  async saveEditedSummary(): Promise<void> {
    if (this.editingMemoryId.length === 0) {
      return;
    }
    if (this.isOperating) {
      return;
    }
    const trimmed: string = this.editingSummary.trim();
    if (trimmed.length === 0) {
      this.errorMessage = '摘要不能为空';
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.memoryService.editSummary(this.editingMemoryId, trimmed);
      this.statusMessage = '已保存';
      this.isEditing = false;
      this.editingSummary = '';
      this.editingMemoryId = '';
      await this.reload();
    } catch (e) {
      this.errorMessage = '保存失败';
      Logger.error(LOG_TAG, 'saveEditedSummary failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 启用/禁用指定 Memory。
   */
  async toggleEnabled(memoryId: string): Promise<void> {
    if (this.isOperating) {
      return;
    }
    const memory: ChatMemory | null = this.findMemoryById(memoryId);
    if (memory === null) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.memoryService.setEnabled(memoryId, !memory.enabled);
      this.statusMessage = memory.enabled ? '已禁用' : '已启用';
      await this.reload();
    } catch (e) {
      this.errorMessage = '切换状态失败';
      Logger.error(LOG_TAG, 'toggleEnabled failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 请求删除单条 Memory(弹出确认)。
   */
  requestDelete(memoryId: string): void {
    this.pendingDeleteMemoryId = memoryId;
    this.showDeleteConfirm = true;
  }

  /**
   * 取消删除。
   */
  cancelDelete(): void {
    this.showDeleteConfirm = false;
    this.pendingDeleteMemoryId = '';
  }

  /**
   * 确认删除单条 Memory。
   */
  async confirmDelete(): Promise<void> {
    if (this.pendingDeleteMemoryId.length === 0) {
      this.showDeleteConfirm = false;
      return;
    }
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    const memoryId: string = this.pendingDeleteMemoryId;
    try {
      await this.memoryService.removeById(memoryId);
      this.statusMessage = '已删除';
      this.showDeleteConfirm = false;
      this.pendingDeleteMemoryId = '';
      if (this.expandedMemoryId === memoryId) {
        this.expandedMemoryId = '';
      }
      await this.reload();
    } catch (e) {
      this.errorMessage = '删除失败';
      Logger.error(LOG_TAG, 'confirmDelete failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 手动触发重新生成摘要(强制,不检查阈值)。
   */
  async regenerateSummary(): Promise<void> {
    if (this.activeBranchId.length === 0) {
      return;
    }
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    this.statusMessage = '正在生成章节...';
    try {
      const messages: ChatMessage[] =
        await this.branchPersistenceService.loadActiveBranchMessages(this.chatId);
      if (messages.length === 0) {
        this.errorMessage = '没有消息可总结';
        this.statusMessage = '';
        return;
      }
      // 手动触发:强制生成详细章节并同步更新核心记忆
      const result = await this.memoryService.forceGenerateChapterMemory(
        this.chatId, this.activeBranchId, messages
      );
      if (result.success) {
        this.statusMessage = result.memory !== null ? '已生成章节' : '无新消息需归档';
      } else {
        this.errorMessage = '生成失败: ' + (result.error !== undefined ? result.error : '未知错误');
        this.statusMessage = '';
      }
      await this.reload();
    } catch (e) {
      this.errorMessage = '生成失败';
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'regenerateSummary failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 清除当前 Branch 自产的记忆(继承祖先的不删)。
   */
  async clearOwnedMemory(): Promise<void> {
    if (this.activeBranchId.length === 0) {
      return;
    }
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.memoryService.clearOwnedByBranch(this.activeBranchId);
      this.statusMessage = '已清除当前分支记忆';
      await this.reload();
    } catch (e) {
      this.errorMessage = '清除失败';
      Logger.error(LOG_TAG, 'clearOwnedMemory failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 清除状态消息。
   */
  clearStatusMessage(): void {
    this.statusMessage = '';
  }

  /**
   * 清除错误消息。
   */
  clearErrorMessage(): void {
    this.errorMessage = '';
  }

  /**
   * 释放资源。
   */
  dispose(): void {
    this.disposed = true;
  }

  /**
   * 按 ID 查找 Memory。
   */
  private findMemoryById(memoryId: string): ChatMemory | null {
    for (let g = 0; g < this.memoryGroups.length; g++) {
      const group: MemoryTypeGroup = this.memoryGroups[g];
      for (let i = 0; i < group.items.length; i++) {
        if (group.items[i].memory.id === memoryId) {
          return group.items[i].memory;
        }
      }
    }
    return null;
  }

  /**
   * 格式化时间戳为可读文本。
   */
  private formatTime(ts: number): string {
    if (ts <= 0) {
      return '从未';
    }
    const date: Date = new Date(ts);
    const y: number = date.getFullYear();
    const m: number = date.getMonth() + 1;
    const d: number = date.getDate();
    const h: number = date.getHours();
    const min: number = date.getMinutes();
    const pad = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return y.toString() + '-' + pad(m) + '-' + pad(d)
      + ' ' + pad(h) + ':' + pad(min);
  }
}
