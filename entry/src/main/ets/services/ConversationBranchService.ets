/**
 * ConversationBranchService Branch 门面(查询与判定)(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - 查询:Branch 列表 / 活动 Branch ID / 记录数量统计 / 操作互斥状态
 * - 刷新:refreshBranchState(从 DB 重载 branches / activeBranchId / recordCounts)
 * - 判定:canContinueFromAssistant / canGenerateFromUserMessage /
 *   canRegenerateAssistantMessage / canEditUserMessage(均为纯判定,不改状态)
 *
 * 暂留 ChatService(P3 候选):fork+stream 族(continueFromAssistant /
 * regenerateFromAssistant / continueFromUserMessage / editUserMessageAndGenerate /
 * switchBranch / reloadAfterExternalBranchChange),与流式核心共享可变状态。
 *
 * 依赖与宿主(ArkTS 说明):
 * - Branch 状态(branches / activeBranchId / recordCounts / branchOperationInProgress)
 *   仍由 ChatService 持有(暂留的 fork+stream 族共享写入),经 ConversationBranchHost
 *   函数属性回调读写——与搬运前 this.xxx 语义一致;类内同名 getter/setter/方法转发,
 *   使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ConversationBranchService(仅日志来源标注变化)。
 */

import { ConversationBranch, ConversationBranchSummary, ConversationRecordCounts } from '../models/ConversationBranch';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ConversationBranchPersistenceService } from './ConversationBranchPersistenceService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ConversationBranchService';

/** Branch 门面依赖(全部为只读引用,null 表示未装配) */
export interface ConversationBranchDeps {
  /** 对话分支持久化服务 */
  branchPersistenceService: ConversationBranchPersistenceService | null;
}

/**
 * 宿主回调:会话 / Branch 状态读写与宿主私有能力。
 * 读取即最新、写入即生效(与搬运前 this.xxx 语义一致)。
 */
export interface ConversationBranchHost {
  /** 宿主是否已释放 */
  isDisposed: () => boolean;
  /** 是否忙碌(生成 / Swipe / 会话 / Branch 操作中) */
  isBusy: () => boolean;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 当前正在生成的 Assistant 消息 id(无则 null) */
  getCurrentAssistantId: () => string | null;
  /** 当前消息列表(读取即最新;调用方不得直接修改返回值) */
  getMessages: () => ChatMessage[];
  /** 按 id 查找消息(宿主私有辅助) */
  findMessageById: (id: string) => ChatMessage | undefined;
  /** Branch 摘要列表读取 */
  getBranches: () => ConversationBranchSummary[];
  /** Branch 摘要列表整体替换 */
  setBranches: (branches: ConversationBranchSummary[]) => void;
  /** 活动 Branch ID 读取 */
  getActiveBranchId: () => string;
  /** 活动 Branch ID 更新 */
  setActiveBranchId: (branchId: string) => void;
  /** Branch 记录数量统计读取 */
  getRecordCounts: () => ConversationRecordCounts | undefined;
  /** Branch 记录数量统计更新 */
  setRecordCounts: (counts: ConversationRecordCounts | undefined) => void;
  /** Branch 操作互斥标志读取 */
  getBranchOperationInProgress: () => boolean;
}

export class ConversationBranchService {
  private readonly branchPersistenceService: ConversationBranchPersistenceService | null;
  private readonly host: ConversationBranchHost;

  constructor(deps: ConversationBranchDeps, host: ConversationBranchHost) {
    this.branchPersistenceService = deps.branchPersistenceService;
    this.host = host;
  }

  // ===== 宿主状态与能力(同名 getter/setter/方法转发,保持搬运代码零改写) =====

  private get disposed(): boolean {
    return this.host.isDisposed();
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private get currentAssistantId(): string | null {
    return this.host.getCurrentAssistantId();
  }

  private get messages(): ChatMessage[] {
    return this.host.getMessages();
  }

  private get branches(): ConversationBranchSummary[] {
    return this.host.getBranches();
  }

  private set branches(value: ConversationBranchSummary[]) {
    this.host.setBranches(value);
  }

  private get activeBranchId(): string {
    return this.host.getActiveBranchId();
  }

  private set activeBranchId(value: string) {
    this.host.setActiveBranchId(value);
  }

  private get recordCounts(): ConversationRecordCounts | undefined {
    return this.host.getRecordCounts();
  }

  private set recordCounts(value: ConversationRecordCounts | undefined) {
    this.host.setRecordCounts(value);
  }

  private get branchOperationInProgress(): boolean {
    return this.host.getBranchOperationInProgress();
  }

  private isBusy(): boolean {
    return this.host.isBusy();
  }

  private findMessageById(id: string): ChatMessage | undefined {
    return this.host.findMessageById(id);
  }

  // ===== 搬运方法(原 ChatService 成员,逐字搬出) =====

  // ===== T-6.4B-1 Branch 公开方法 =====

  /**
   * 获取 Branch 列表(副本)。
   */
  getBranches(): ConversationBranchSummary[] {
    return this.branches.slice();
  }

  /**
   * 获取当前活动 Branch ID。
   */
  getActiveBranchId(): string {
    return this.activeBranchId;
  }

  /**
   * 获取 Branch 记录数量统计。
   */
  getRecordCounts(): ConversationRecordCounts | undefined {
    return this.recordCounts;
  }

  /**
   * 是否正在执行 Branch 操作(创建 Child / 切换)。
   */
  isBranchOperating(): boolean {
    return this.branchOperationInProgress;
  }

  /**
   * 判断指定 Assistant 消息是否可"从此处继续"创建 Child Branch。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = Assistant
   * - source = Conversation 或 undefined(兼容)
   * - 不是 CharacterFirstMessage
   * - status = Completed
   * - 不是当前正在生成的消息
   * - 位于当前 messages 列表中
   */
  canContinueFromAssistant(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    if (this.currentAssistantId !== null && this.currentAssistantId === messageId) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.Assistant) {
      return false;
    }
    if (msg.source === ChatMessageSource.CharacterFirstMessage) {
      return false;
    }
    if (msg.source !== undefined && msg.source !== ChatMessageSource.Conversation) {
      return false;
    }
    if (msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    return true;
  }

  /**
   * 刷新 Branch 状态(branches / activeBranchId / recordCounts)。
   * 在 initializeSession 完成后以及 Branch 操作后调用。
   * 失败不抛异常,仅记录 warning。
   */
  async refreshBranchState(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.branchPersistenceService === null) {
      return;
    }
    if (this.currentChatId === undefined) {
      return;
    }
    try {
      const chatId: string = this.currentChatId;
      const branches: ConversationBranchSummary[] =
        await this.branchPersistenceService.listBranches(chatId);
      const activeBranch: ConversationBranch | null =
        await this.branchPersistenceService.getActiveBranch(chatId);
      const counts: ConversationRecordCounts =
        await this.branchPersistenceService.getRecordCounts(chatId);
      this.branches = branches;
      this.activeBranchId = activeBranch !== null ? activeBranch.id : '';
      this.recordCounts = counts;
    } catch (e) {
      Logger.warn(LOG_TAG, 'refreshBranchState failed: '
        + (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * T-6.4B-2: 判断指定 User 消息是否可"从此处生成新回复"创建 Branch。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = User
   * - status = Completed(或 undefined,兼容旧数据)
   * - 不是当前正在生成的消息(currentAssistantId 只可能是 Assistant,User 永远不匹配)
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 该 User 消息之后存在 Assistant 回复或后续消息(即不是最新一条尚未生成回复的 User)
   *   通过 indexOf(msg) < messages.length - 1 判断
   */
  canGenerateFromUserMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.User) {
      return false;
    }
    if (msg.status !== undefined && msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    // 必须有后续消息(后面存在 Assistant 回复或后续历史)
    // 最新一条尚未生成 Assistant 的 User 消息不显示该操作
    const idx: number = this.messages.indexOf(msg);
    if (idx < 0 || idx >= this.messages.length - 1) {
      return false;
    }
    return true;
  }

  /**
   * T-6.4B-3: 判断指定历史 Assistant 消息是否可"重新生成此回复"。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = Assistant
   * - source = Conversation 或 undefined(兼容旧数据)
   * - status = Completed
   * - 不是 CharacterFirstMessage
   * - 不是当前正在生成的消息(currentAssistantId)
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 前面存在对应的 User 消息(基于当前 Branch 有序路径向前查找)
   */
  canRegenerateAssistantMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    if (this.currentAssistantId !== null && this.currentAssistantId === messageId) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.Assistant) {
      return false;
    }
    if (msg.source === ChatMessageSource.CharacterFirstMessage) {
      return false;
    }
    if (msg.source !== undefined && msg.source !== ChatMessageSource.Conversation) {
      return false;
    }
    if (msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    // 基于当前 Active Branch 有序路径向前查找最近的 User
    const idx: number = this.messages.indexOf(msg);
    if (idx <= 0) {
      return false;
    }
    let hasPrevUser: boolean = false;
    for (let i = idx - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        hasPrevUser = true;
        break;
      }
    }
    return hasPrevUser;
  }

  /**
   * T-6.4B-3.1: 判断指定历史 User 消息是否可"编辑"。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = User
   * - status = Completed 或 undefined(兼容旧数据)
   * - content 非空
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 后面存在消息(目标 User 不是最新一条)
   * - 前面存在消息(目标 User 不是第一条,有 anchor)
   */
  canEditUserMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.User) {
      return false;
    }
    if (msg.status !== undefined && msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    if (msg.content.length === 0) {
      return false;
    }
    const idx: number = this.messages.indexOf(msg);
    if (idx <= 0) {
      // idx <= 0:第一条消息无 anchor,或不在列表
      return false;
    }
    if (idx >= this.messages.length - 1) {
      // 最新一条 User(后面无消息),不可编辑
      return false;
    }
    return true;
  }
}