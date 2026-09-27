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
import { ChatMessage, ChatMessageStatus, mergeChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatState, ChatServiceCallbacks } from '../models/ChatServiceContract';
import { ChatGenerationKind, ActiveGenerationContext } from '../models/ChatGenerationContext';
import { MessageSwipeSummary } from '../models/MessageSwipe';
import { ConversationBranchPersistenceService, EditedBranchGenerationTarget } from './ConversationBranchPersistenceService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { ChatPersistenceService } from './ChatPersistenceService';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ConversationBranchService';

/** Branch 门面依赖(全部为只读引用,null 表示未装配) */
export interface ConversationBranchDeps {
  /** 对话分支持久化服务 */
  branchPersistenceService: ConversationBranchPersistenceService | null;
  /** 消息候选持久化服务(会话重载后同步 Swipe 摘要) */
  swipePersistenceService: MessageSwipePersistenceService | null;
  /** 会话持久化服务(fork 前置校验与事务) */
  persistenceService: ChatPersistenceService | null;
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
  /** Branch 操作互斥标志写入 */
  setBranchOperationInProgress: (inProgress: boolean) => void;
  /** Swipe 摘要列表读取(会话重载后同步) */
  getSwipeSummaries: () => MessageSwipeSummary[];
  /** Swipe 摘要列表整体替换 */
  setSwipeSummaries: (summaries: MessageSwipeSummary[]) => void;
  /** 从数据库重新加载当前会话消息 */
  reloadCurrentSession: () => Promise<void>;
  /** 重算最后一条可 Swipe 的 Assistant 消息 id */
  updateLastAssistantMessageId: () => void;
  /** 最近一次回调读取 */
  getLastCallbacks: () => ChatServiceCallbacks | null;
  /** 记录最近一次回调(宿主在停止/收尾时读取) */
  setLastCallbacks: (callbacks: ChatServiceCallbacks | null) => void;
  /** 设置聊天状态(宿主内做 disposed 判定与去重) */
  setState: (state: ChatState, callbacks: ChatServiceCallbacks | null) => void;
  /** 通知消息列表变更 */
  emitMessages: (callbacks: ChatServiceCallbacks | null) => void;
  /** 聊天状态机当前状态(仅读取,互斥判定日志用) */
  getState: () => ChatState;
  /** Swipe 浏览/切换操作互斥标志读取 */
  getSwipeOperationInProgress: () => boolean;
  /** 多会话操作互斥标志读取 */
  getSessionOperationInProgress: () => boolean;
  /** 是否可重新生成(宿主判定:非 Sending/Streaming 且存在可 Swipe 的 Assistant) */
  canRegenerate: () => boolean;
  /** 最后一条非 firstMessage 的 Assistant 消息 id */
  getLastAssistantMessageId: () => string;
  /** 活动生成上下文读取 */
  getActiveGeneration: () => ActiveGenerationContext | null;
  /** 活动生成上下文更新 */
  setActiveGeneration: (context: ActiveGenerationContext | null) => void;
  /** 当前 Assistant 消息 id 更新 */
  setCurrentAssistantId: (assistantId: string | null) => void;
  /** 整体替换消息列表(不可变更新产生的新数组) */
  setMessages: (messages: ChatMessage[]) => void;
  /** 按 id 取 Swipe 摘要(宿主经 Swipe 控制器实现) */
  getSummaryForMessage: (messageId: string) => MessageSwipeSummary | undefined;
  /** 生成操作号读取(迟到回调判定用) */
  getGenerationOperationId: () => number;
  /** 生成操作号更新 */
  setGenerationOperationId: (operationId: number) => void;
  /** delta 持久化已写字符数读取 */
  getLastPersistedContentLength: () => number;
  /** delta 持久化已写字符数更新 */
  setLastPersistedContentLength: (length: number) => void;
  /** 待持久化 Assistant id 读取 */
  getPendingPersistAssistantId: () => string | null;
  /** 待持久化 Assistant id 更新 */
  setPendingPersistAssistantId: (assistantId: string | null) => void;
  /** 启动流式请求(流式核心不动,由宿主实现) */
  doStream: (assistantId: string, callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext) => Promise<void>;
}

export class ConversationBranchService {
  private readonly branchPersistenceService: ConversationBranchPersistenceService | null;
  private readonly swipePersistenceService: MessageSwipePersistenceService | null;
  private readonly persistenceService: ChatPersistenceService | null;
  private readonly host: ConversationBranchHost;

  constructor(deps: ConversationBranchDeps, host: ConversationBranchHost) {
    this.branchPersistenceService = deps.branchPersistenceService;
    this.swipePersistenceService = deps.swipePersistenceService;
    this.persistenceService = deps.persistenceService;
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

  private set messages(value: ChatMessage[]) {
    this.host.setMessages(value);
  }

  private getSummaryForMessage(messageId: string): MessageSwipeSummary | undefined {
    return this.host.getSummaryForMessage(messageId);
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

  private set branchOperationInProgress(value: boolean) {
    this.host.setBranchOperationInProgress(value);
  }

  private get swipeSummaries(): MessageSwipeSummary[] {
    return this.host.getSwipeSummaries();
  }

  private set swipeSummaries(value: MessageSwipeSummary[]) {
    this.host.setSwipeSummaries(value);
  }

  private reloadCurrentSession(): Promise<void> {
    return this.host.reloadCurrentSession();
  }

  private updateLastAssistantMessageId(): void {
    this.host.updateLastAssistantMessageId();
  }

  private setState(state: ChatState, callbacks: ChatServiceCallbacks | null): void {
    this.host.setState(state, callbacks);
  }

  private get lastCallbacks(): ChatServiceCallbacks | null {
    return this.host.getLastCallbacks();
  }

  private set lastCallbacks(value: ChatServiceCallbacks | null) {
    this.host.setLastCallbacks(value);
  }

  private get state(): ChatState {
    return this.host.getState();
  }

  private get swipeOperationInProgress(): boolean {
    return this.host.getSwipeOperationInProgress();
  }

  private get sessionOperationInProgress(): boolean {
    return this.host.getSessionOperationInProgress();
  }

  private canRegenerate(): boolean {
    return this.host.canRegenerate();
  }

  private get lastAssistantMessageId(): string {
    return this.host.getLastAssistantMessageId();
  }

  private get activeGeneration(): ActiveGenerationContext | null {
    return this.host.getActiveGeneration();
  }

  private set activeGeneration(value: ActiveGenerationContext | null) {
    this.host.setActiveGeneration(value);
  }

  private set currentAssistantId(value: string | null) {
    this.host.setCurrentAssistantId(value);
  }

  private get generationOperationId(): number {
    return this.host.getGenerationOperationId();
  }

  private set generationOperationId(value: number) {
    this.host.setGenerationOperationId(value);
  }

  private get lastPersistedContentLength(): number {
    return this.host.getLastPersistedContentLength();
  }

  private set lastPersistedContentLength(value: number) {
    this.host.setLastPersistedContentLength(value);
  }

  private get pendingPersistAssistantId(): string | null {
    return this.host.getPendingPersistAssistantId();
  }

  private set pendingPersistAssistantId(value: string | null) {
    this.host.setPendingPersistAssistantId(value);
  }

  private doStream(assistantId: string, callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext): Promise<void> {
    return this.host.doStream(assistantId, callbacks, context);
  }

  private emitMessages(callbacks: ChatServiceCallbacks | null): void {
    this.host.emitMessages(callbacks);
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
  /**
   * 切换 Active Branch 到 targetBranchId。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化
   * 2. 调用 switchActiveBranch(事务内物化 Candidate 到 messages 并同步 group active index)
   * 3. 重新加载 messages / swipeSummaries / branches / recordCounts
   * 4. 通知 UI
   *
   * @param targetBranchId 目标 Branch ID
   * @param callbacks 回调集合
   */
  async switchBranch(
    targetBranchId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'switchBranch rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (targetBranchId.length === 0) {
      callbacks.onError('目标分支无效');
      return;
    }
    if (targetBranchId === this.activeBranchId) {
      // 已是当前分支,无操作
      return;
    }

    this.branchOperationInProgress = true;
    this.lastCallbacks = callbacks;
    try {
      const chatId: string = this.currentChatId;
      await this.branchPersistenceService.switchActiveBranch(chatId, targetBranchId);
      // 重新加载
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'switchBranch failed: ' + msg);
      callbacks.onError('切换分支失败,请重试');
    } finally {
      this.branchOperationInProgress = false;
    }
  }

  /**
   * T-6.4B-1.1: 外部 Branch 切换后重新加载当前会话。
   *
   * 当 BranchMapPage 通过 branchPersistenceService.switchActiveBranch 切换 Active Branch 后,
   * ChatPage 的 ChatService 需要重新从数据库加载消息和 Branch 状态。
   * 此方法不执行 switchActiveBranch(已由外部完成),只做 reload + 通知 UI。
   *
   * 流程:
   * 1. 重新加载 messages(从 DB,含 Active Branch 的 Candidate 投影)
   * 2. 重新加载 swipeSummaries
   * 3. 更新 lastAssistantMessageId
   * 4. 刷新 Branch 状态(branches / activeBranchId / recordCounts)
   * 5. 通知 UI(新数组引用)
   *
   * @param callbacks 回调集合
   */
  async reloadAfterExternalBranchChange(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.currentChatId === undefined) {
      return;
    }
    try {
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'reloadAfterExternalBranchChange failed: ' + msg);
      callbacks.onError('重新加载会话失败');
    }
  }
  /**
   * 重新生成最后一条 Assistant 回复(T-6.4B-1.2: 创建 Conversation Branch)。
   *
   * 不再创建 MessageSwipeCandidate,改为:
   * 1. 找到目标 Assistant 前一条 User 消息作为 fork point
   * 2. 创建新的 Conversation Branch(同级或子级)
   * 3. 新 Branch 继承 fork point 之前及本身的路径,不继承旧 Assistant
   * 4. 在新 Branch 中创建新的 Streaming Assistant Message
   * 5. 启动 Provider,流式内容只写入新 Assistant Message
   * 6. 原 Branch、原 Assistant Message、原 Candidate 数据保持不变
   *
   * T-6.3: 与 send / swipe browse / session op 互斥(通过 isBusy)。
   */
  async regenerateLastResponse(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot regenerate');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'regenerateLastResponse rejected: busy state=' + this.state
        + ' swipeOp=' + this.swipeOperationInProgress.toString()
        + ' sessionOp=' + this.sessionOperationInProgress.toString());
      return;
    }
    if (!this.canRegenerate()) {
      return;
    }

    this.lastCallbacks = callbacks;
    await this.regenerateAsBranch(callbacks);
  }

  /**
   * T-6.4B-1.2: 重新生成为新 Conversation Branch。
   *
   * 流程:
   * 1. 找到目标 Assistant 前一条 User 消息作为 fork point
   * 2. 判断同级 Branch:
   *    - 当前 Active Branch 的 forkMessageId === forkUserMessageId → 同级
   *      (parent = activeBranch.parentBranchId)
   *    - 否则 → 子级 (parent = activeBranch.id)
   * 3. 创建新的 Streaming Assistant Message
   * 4. 调用 forkForRegeneration 在单一事务中创建新 Branch + 复制 Links + 插入 Assistant
   * 5. 重载 messages / swipeSummaries / branchState
   * 6. 建立 BranchRegeneration ActiveGenerationContext
   * 7. 调用 doStream 启动 Provider
   *
   * 失败处理:
   * - 事务失败:不创建半成品 Branch,不启动 Provider,不修改当前 Active Branch
   * - 显示错误提示
   *
   * 不修改:
   * - 原 Branch 的 Message Link
   * - 原 Assistant Message
   * - 旧 MessageSwipeCandidate 数据
   */
  private async regenerateAsBranch(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (this.lastAssistantMessageId.length === 0) {
      callbacks.onError('没有可重新生成的回复');
      return;
    }

    const chatId: string = this.currentChatId;
    const targetAssistantId: string = this.lastAssistantMessageId;

    // 1. 在 this.messages 中找到目标 Assistant,并向前查找最近的 User 消息
    let assistantIndex: number = -1;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].id === targetAssistantId) {
        assistantIndex = i;
        break;
      }
    }
    if (assistantIndex < 0) {
      callbacks.onError('找不到目标回复');
      return;
    }
    let forkUserMessageId: string = '';
    for (let i = assistantIndex - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        forkUserMessageId = this.messages[i].id;
        break;
      }
    }
    if (forkUserMessageId.length === 0) {
      callbacks.onError('找不到原始用户消息');
      return;
    }

    // 2. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 3. 解析新 Branch 的 parent:
    //    fork 点在 Active Branch 自有消息区间 → 子级(parent = Active Branch);
    //    fork 点在复制前缀(回到祖先对话线)→ 挂到对应祖先,避免布局层级错位
    const parentBranchId: string =
      await this.branchPersistenceService.resolveForkParentBranchId(
        chatId, activeBranch.id, forkUserMessageId
      );

    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, forkUserMessageId, callbacks
    );
  }

  /**
   * T-6.4B-1.2 / T-6.4B-2 公共:从指定 User Message fork 新 Branch 并启动流式生成。
   *
   * 调用方负责:
   * - 校验 disposed / isBusy / persistenceService / branchPersistenceService
   * - 解析 forkUserMessageId(从 lastAssistant 前找,或直接传入历史 User 消息 ID)
   * - 解析 parentBranchId(同级 vs 子级,基于 activeBranch.forkMessageId)
   *
   * 本方法负责:
   * 1. 创建新 Streaming Assistant Message
   * 2. 调用 forkForRegeneration 在单一事务中创建 Branch + 复制 Links + 插入 Assistant
   * 3. 重载 messages / swipeSummaries / branchState
   * 4. 建立 BranchRegeneration ActiveGenerationContext
   * 5. 调用 doStream 启动 Provider
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  private async forkAndStreamFromUser(
    chatId: string,
    sourceBranchId: string,
    parentBranchId: string,
    forkUserMessageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    // 1. 创建新的 Streaming Assistant Message
    this.generationOperationId++;
    const operationId: number = this.generationOperationId;
    const newAssistantId: string = 'msg-' + generateUuid();
    const newAssistantMessage: ChatMessage = {
      id: newAssistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 2. 占用 Branch 操作互斥锁(保护事务 + reload 期间不被并发)
    this.branchOperationInProgress = true;
    let newBranchSummary: ConversationBranchSummary;
    try {
      newBranchSummary = await this.branchPersistenceService!.forkForRegeneration(
        chatId,
        sourceBranchId,
        parentBranchId,
        forkUserMessageId,
        newAssistantMessage
      );
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'forkAndStreamFromUser forkForRegeneration failed: ' + msg);
      this.branchOperationInProgress = false;
      callbacks.onError('创建分支失败,请重试');
      return;
    }

    // 3. 事务成功,重载内存状态(新 Branch 已成为 Active)
    try {
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'forkAndStreamFromUser reload failed: ' + msg);
      // Branch 已创建,继续执行生成,UI 状态可能与 DB 不一致但可恢复
    }

    // 3.5 修正 reload 丢失的 isStreaming 状态
    // reloadCurrentSession 从数据库加载 messages,数据库不保存 isStreaming=true,
    // 导致 placeholder 的 isStreaming 被重置为 false。
    // 在 emitMessages 之前修正 placeholder 为 Streaming 状态,确保 UI 正确显示打字机效果。
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === newAssistantId) {
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          isStreaming: true,
          status: ChatMessageStatus.Streaming
        });
      }
      return msg;
    });

    // 4. 建立 BranchRegeneration 活动上下文
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.BranchRegeneration,
      chatId: chatId,
      assistantMessageId: newAssistantId,
      branchId: newBranchSummary.id,
      forkMessageId: forkUserMessageId
    };

    // 5. 设置当前 Assistant ID 和持久化追踪
    this.currentAssistantId = newAssistantId;
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = newAssistantId;

    // 6. 释放 Branch 操作锁(后续通过 isBusy / activeGeneration 互斥)
    this.branchOperationInProgress = false;

    // 7. 进入 Sending 状态,通知 UI
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 8. 启动 Provider
    this.doStream(newAssistantId, callbacks, this.activeGeneration);
  }

  /**
   * 从历史 Assistant 创建 Child Branch(从此处继续)。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化
   * 2. 校验消息可继续(canContinueFromAssistant)
   * 3. 获取当前 Active Branch
   * 4. 获取该 Assistant 在当前 Branch 中选中的 Candidate index(若有)
   * 5. 调用 forkAtMessage 创建 Child Branch(自动成为 Active)
   * 6. 重新加载 messages / swipeSummaries / branches / recordCounts
   * 7. 创建新的 messages 数组引用
   * 8. 通知 UI
   *
   * 不会:
   * - 删除原 Branch 后续消息
   * - 复制 Message / Candidate 实体
   * - 原地修改 messages 数组
   * - 自动开始 Provider 请求
   * - 自动插入空 User 消息
   *
   * @param messageId 目标历史 Assistant 消息 ID
   * @param callbacks 回调集合
   */
  async continueFromAssistant(
    messageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'continueFromAssistant rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canContinueFromAssistant(messageId)) {
      Logger.warn(LOG_TAG, 'continueFromAssistant rejected: invalid message');
      callbacks.onError('该消息无法继续');
      return;
    }

    this.branchOperationInProgress = true;
    this.lastCallbacks = callbacks;
    try {
      const chatId: string = this.currentChatId;
      // 1. 获取当前 Active Branch
      const activeBranch: ConversationBranch | null =
        await this.branchPersistenceService.getActiveBranch(chatId);
      if (activeBranch === null) {
        throw new Error('当前会话无活动分支');
      }
      // 2. 获取该 Assistant 在当前 Branch 中选中的 Candidate index
      //    (用于 forkAtMessage 覆盖新 Branch 的选择,保留来源 Branch 当前显示的 Candidate)
      const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(messageId);
      const selectedCandidateIndex: number | undefined =
        summary !== undefined ? summary.activeCandidateIndex : undefined;
      // 3. 调用 forkAtMessage 创建 Child Branch(自动成为 Active)
      await this.branchPersistenceService.forkAtMessage(
        chatId,
        activeBranch.id,
        messageId,
        selectedCandidateIndex
      );
      // 4. 重新加载 messages / swipeSummaries / branchState
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      // 5. 通知 UI(新数组引用)
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'continueFromAssistant failed: ' + msg);
      callbacks.onError('创建分支失败,请重试');
    } finally {
      this.branchOperationInProgress = false;
    }
  }

  /**
   * T-6.4B-3: 历史 Assistant "重新生成此回复"。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化、消息可重新生成
   * 2. 在当前 Active Branch 有序路径中定位目标 Assistant
   * 3. 向前查找最近的 User 消息作为 fork point
   * 4. 判断同级或子级 parentBranchId(复用 T-6.4B-1.2 规则)
   * 5. 调用 forkAndStreamFromUser 创建 Branch + Streaming Assistant + 启动 Provider
   *
   * 与"从此处继续"的区别:
   * - fork point 是目标 Assistant 前面的 User(不是 Assistant 本身)
   * - 新 Branch 不保留目标 Assistant 和后续历史
   * - 自动调用 Provider 生成新 Assistant
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async regenerateAssistantMessage(
    messageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'regenerateAssistantMessage rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canRegenerateAssistantMessage(messageId)) {
      Logger.warn(LOG_TAG, 'regenerateAssistantMessage rejected: invalid message');
      callbacks.onError('该消息无法重新生成');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 在当前 Active Branch 有序路径中定位目标 Assistant
    let assistantIndex: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        assistantIndex = i;
        break;
      }
    }
    if (assistantIndex < 0) {
      callbacks.onError('找不到目标回复');
      return;
    }

    // 2. 向前查找最近的 User 消息作为 fork point
    let forkUserMessageId: string = '';
    for (let i = assistantIndex - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        forkUserMessageId = this.messages[i].id;
        break;
      }
    }
    if (forkUserMessageId.length === 0) {
      callbacks.onError('找不到原始用户消息');
      return;
    }

    // 3. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 4. 解析新 Branch 的 parent:
    //    fork 点在 Active Branch 自有消息区间 → 子级;在复制前缀 → 挂到祖先
    const parentBranchId: string =
      await this.branchPersistenceService.resolveForkParentBranchId(
        chatId, activeBranch.id, forkUserMessageId
      );

    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, forkUserMessageId, callbacks
    );
  }

  /**
   * T-6.4B-2: 从历史 User 消息生成新回复(创建新 Branch 并自动启动 Provider)。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化、消息可生成
   * 2. 获取当前 Active Branch
   * 3. 判断同级或子级 parentBranchId(复用 T-6.4B-1.2 规则)
   * 4. 调用 forkAndStreamFromUser 创建 Branch + Streaming Assistant + 启动 Provider
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async generateFromUserMessage(
    userMessageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'generateFromUserMessage rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canGenerateFromUserMessage(userMessageId)) {
      Logger.warn(LOG_TAG, 'generateFromUserMessage rejected: invalid message');
      callbacks.onError('该消息无法生成新回复');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 2. 解析新 Branch 的 parent:
    //    fork 点在 Active Branch 自有消息区间 → 子级;在复制前缀 → 挂到祖先
    const parentBranchId: string =
      await this.branchPersistenceService.resolveForkParentBranchId(
        chatId, activeBranch.id, userMessageId
      );

    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, userMessageId, callbacks
    );
  }

  /**
   * T-6.4B-3.1: 编辑历史 User Message 并创建新 Branch + Streaming Assistant。
   *
   * 流程:
   * 1. 校验:未忙碌、服务可用、会话已初始化、消息可编辑、编辑内容非空且不同
   * 2. 在当前 Active Branch 有序路径中定位目标 User 和 anchor(前一条消息)
   * 3. 判断同级或子级 parentBranchId(基于 activeBranch.forkMessageId == anchorMessageId)
   * 4. 创建新的 Completed User Message(编辑后内容)和 Streaming Assistant Message
   * 5. 调用 editUserAndForkWithAssistant 原子事务
   * 6. 重载 messages / swipeSummaries / branchState
   * 7. 建立 BranchRegeneration ActiveGenerationContext
   * 8. 调用 doStream 启动 Provider
   *
   * 与"从此处生成新回复"的区别:
   * - 编辑:fork point = anchor(原 User 前一条),创建新 User,不继承原 User
   * - 从此处生成新回复:fork point = 原 User,继承原 User,只替换后面的 Assistant
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async editUserMessageAndGenerate(
    messageId: string,
    editedContent: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'editUserMessageAndGenerate rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canEditUserMessage(messageId)) {
      Logger.warn(LOG_TAG, 'editUserMessageAndGenerate rejected: invalid message');
      callbacks.onError('该消息无法编辑');
      return;
    }
    const trimmedContent: string = editedContent.trim();
    if (trimmedContent.length === 0) {
      callbacks.onError('编辑内容不能为空');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 在当前 Active Branch 有序路径中定位目标 User
    let userIndex: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        userIndex = i;
        break;
      }
    }
    if (userIndex <= 0) {
      callbacks.onError('找不到目标用户消息');
      return;
    }

    // 2. anchor = 目标 User 前一条消息(任何角色,通常是 Assistant 或 CharacterFirstMessage)
    const anchorMessageId: string = this.messages[userIndex - 1].id;

    // 3. 获取当前 Active Branch
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 4. 判断同级或子级
    //    同级条件:当前 Active Branch 非 Root 且 forkMessageId 等于本次 anchorMessageId
    //    (即当前 Branch 也是从同一个 anchor fork 出的编辑/再生分支)
    let parentBranchId: string;
    if (!activeBranch.isRoot
      && activeBranch.forkMessageId !== undefined
      && activeBranch.forkMessageId === anchorMessageId) {
      parentBranchId = activeBranch.parentBranchId !== undefined
        ? activeBranch.parentBranchId : activeBranch.id;
    } else {
      parentBranchId = activeBranch.id;
    }

    // 5. 创建新的 Completed User Message 和 Streaming Assistant Message
    this.generationOperationId++;
    const operationId: number = this.generationOperationId;
    const newUserMessage: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.User,
      content: trimmedContent,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation
    };
    const newAssistantMessage: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 6. 调用原子事务创建 Branch + 新 User + 新 Assistant
    this.branchOperationInProgress = true;
    let editResult: EditedBranchGenerationTarget;
    try {
      editResult = await this.branchPersistenceService!.editUserAndForkWithAssistant(
        chatId,
        activeBranch.id,
        parentBranchId,
        messageId,
        anchorMessageId,
        newUserMessage,
        newAssistantMessage
      );
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'editUserMessageAndGenerate failed: ' + msg);
      this.branchOperationInProgress = false;
      callbacks.onError('创建分支失败,请重试');
      return;
    }

    // 7. 事务成功,重载内存状态(新 Branch 已成为 Active)
    try {
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'editUserMessageAndGenerate reload failed: ' + msg);
      // Branch 已创建,继续执行生成,UI 状态可能与 DB 不一致但可恢复
    }

    // 8. 建立 BranchRegeneration 活动上下文
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.BranchRegeneration,
      chatId: chatId,
      assistantMessageId: editResult.newAssistantMessageId,
      branchId: editResult.newBranchId,
      forkMessageId: anchorMessageId
    };

    // 9. 设置当前 Assistant ID 和持久化追踪
    this.currentAssistantId = editResult.newAssistantMessageId;
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = editResult.newAssistantMessageId;

    // 10. 释放 Branch 操作锁
    this.branchOperationInProgress = false;

    // 11. 进入 Sending 状态,通知 UI
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 12. 启动 Provider
    this.doStream(editResult.newAssistantMessageId, callbacks, this.activeGeneration);
  }
}