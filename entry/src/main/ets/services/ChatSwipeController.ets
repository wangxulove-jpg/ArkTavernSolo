/**
 * ChatSwipeController Swipe 控制器(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - 查询:摘要列表 / 单条摘要 / 可操作性判定
 * - 切换:上一个 / 下一个 / 指定索引候选激活(公共执行块 doActivateCandidate)
 * - 生成:generateAlternativeCandidate(创建 Streaming 候选、建立 SwipeCandidate 活动上下文、
 *   启动流式请求;P2-4b 迁入)与 replaceAssistantMessageInFullHistory
 *
 * 依赖与宿主(ArkTS 说明):
 * - 会话状态(swipeSummaries / swipeOperationInProgress / lastAssistantMessageId /
 *   activeGeneration / messages 等)仍由 ChatService 持有(与流式核心强耦合,不随迁);
 *   经 ChatSwipeHost 函数属性回调读写——与搬运前 this.xxx 语义一致;
 *   类内同名 getter/setter/方法转发,使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ChatSwipeController(仅日志来源标注变化)。
 */

import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { MessageSwipeSummary, MessageSwipeState, MAX_SWIPE_CANDIDATES } from '../models/MessageSwipe';
import { ChatMessage, ChatMessageStatus, mergeChatMessage } from '../models/ChatMessage';
import { ChatGenerationKind, ActiveGenerationContext } from '../models/ChatGenerationContext';
import { ChatState, ChatServiceCallbacks } from '../models/ChatServiceContract';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatSwipeController';

/** Swipe 控制器依赖(全部为只读引用,null 表示未装配) */
export interface ChatSwipeDeps {
  /** 消息候选持久化服务 */
  swipePersistenceService: MessageSwipePersistenceService | null;
}

/**
 * 宿主回调:会话状态读写与宿主私有能力。
 * 读取即最新、写入即生效(与搬运前 this.xxx 语义一致)。
 */
export interface ChatSwipeHost {
  /** 是否忙碌(生成 / Swipe / 会话 / Branch 操作中) */
  isBusy: () => boolean;
  /** 是否正在生成(生成中不允许切换候选) */
  isGenerating: () => boolean;
  /** 最后一条非 firstMessage 的 Assistant 消息 id */
  getLastAssistantMessageId: () => string;
  /** Swipe 摘要列表读取 */
  getSwipeSummaries: () => MessageSwipeSummary[];
  /** Swipe 摘要列表整体替换 */
  setSwipeSummaries: (summaries: MessageSwipeSummary[]) => void;
  /** Swipe 操作互斥标志读取 */
  getSwipeOperationInProgress: () => boolean;
  /** Swipe 操作互斥标志写入 */
  setSwipeOperationInProgress: (inProgress: boolean) => void;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 最近一次回调(消息刷新通知用) */
  getLastCallbacks: () => ChatServiceCallbacks | null;
  /** 从数据库重新加载当前会话消息 */
  reloadCurrentSession: () => Promise<void>;
  /** 重算最后一条可 Swipe 的 Assistant 消息 id */
  updateLastAssistantMessageId: () => void;
  /** 仅更新会话 updatedAt(不修改 lastMessageAt) */
  persistChatTimestamp: () => void;
  /** 失效指定 Assistant 位置之后的记忆(内容已变化) */
  invalidateMemoryFromMessagePosition: (assistantMessageId: string) => void;
  /** 通知消息列表变更 */
  emitMessages: (callbacks: ChatServiceCallbacks | null) => void;
  /** 宿主是否已释放 */
  isDisposed: () => boolean;
  /** 生成操作号读取(迟到回调判定用) */
  getGenerationOperationId: () => number;
  /** 生成操作号更新 */
  setGenerationOperationId: (operationId: number) => void;
  /** 活动生成上下文读取 */
  getActiveGeneration: () => ActiveGenerationContext | null;
  /** 活动生成上下文更新 */
  setActiveGeneration: (context: ActiveGenerationContext | null) => void;
  /** 当前 Assistant 消息 id 读取 */
  getCurrentAssistantId: () => string | null;
  /** 当前 Assistant 消息 id 更新 */
  setCurrentAssistantId: (assistantId: string | null) => void;
  /** 当前消息列表读取(读取即最新;调用方不得直接修改返回值) */
  getMessages: () => ChatMessage[];
  /** 整体替换消息列表(不可变更新产生的新数组) */
  setMessages: (messages: ChatMessage[]) => void;
  /** delta 持久化已写字符数读取 */
  getLastPersistedContentLength: () => number;
  /** delta 持久化已写字符数更新 */
  setLastPersistedContentLength: (length: number) => void;
  /** 待持久化 Assistant id 读取 */
  getPendingPersistAssistantId: () => string | null;
  /** 待持久化 Assistant id 更新 */
  setPendingPersistAssistantId: (assistantId: string | null) => void;
  /** 设置聊天状态(宿主内做 disposed 判定与去重) */
  setState: (state: ChatState, callbacks: ChatServiceCallbacks | null) => void;
  /** 启动流式请求(流式核心不动,由宿主实现) */
  doStream: (assistantId: string, callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext) => Promise<void>;
}

export class ChatSwipeController {
  private readonly swipePersistenceService: MessageSwipePersistenceService | null;
  private readonly host: ChatSwipeHost;

  constructor(deps: ChatSwipeDeps, host: ChatSwipeHost) {
    this.swipePersistenceService = deps.swipePersistenceService;
    this.host = host;
  }

  // ===== 宿主状态与能力(同名 getter/setter/方法转发,保持搬运代码零改写) =====

  private get swipeSummaries(): MessageSwipeSummary[] {
    return this.host.getSwipeSummaries();
  }

  private set swipeSummaries(value: MessageSwipeSummary[]) {
    this.host.setSwipeSummaries(value);
  }

  private get swipeOperationInProgress(): boolean {
    return this.host.getSwipeOperationInProgress();
  }

  private set swipeOperationInProgress(value: boolean) {
    this.host.setSwipeOperationInProgress(value);
  }

  private get lastAssistantMessageId(): string {
    return this.host.getLastAssistantMessageId();
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private get lastCallbacks(): ChatServiceCallbacks | null {
    return this.host.getLastCallbacks();
  }

  private isBusy(): boolean {
    return this.host.isBusy();
  }

  private isGenerating(): boolean {
    return this.host.isGenerating();
  }

  private reloadCurrentSession(): Promise<void> {
    return this.host.reloadCurrentSession();
  }

  private updateLastAssistantMessageId(): void {
    this.host.updateLastAssistantMessageId();
  }

  private persistChatTimestamp(): void {
    this.host.persistChatTimestamp();
  }

  private invalidateMemoryFromMessagePosition(assistantMessageId: string): void {
    this.host.invalidateMemoryFromMessagePosition(assistantMessageId);
  }

  private emitMessages(callbacks: ChatServiceCallbacks | null): void {
    this.host.emitMessages(callbacks);
  }

  private get disposed(): boolean {
    return this.host.isDisposed();
  }

  private get generationOperationId(): number {
    return this.host.getGenerationOperationId();
  }

  private set generationOperationId(value: number) {
    this.host.setGenerationOperationId(value);
  }

  private get activeGeneration(): ActiveGenerationContext | null {
    return this.host.getActiveGeneration();
  }

  private set activeGeneration(value: ActiveGenerationContext | null) {
    this.host.setActiveGeneration(value);
  }

  private get currentAssistantId(): string | null {
    return this.host.getCurrentAssistantId();
  }

  private set currentAssistantId(value: string | null) {
    this.host.setCurrentAssistantId(value);
  }

  private get messages(): ChatMessage[] {
    return this.host.getMessages();
  }

  private set messages(value: ChatMessage[]) {
    this.host.setMessages(value);
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

  private setState(state: ChatState, callbacks: ChatServiceCallbacks | null): void {
    this.host.setState(state, callbacks);
  }

  private doStream(assistantId: string, callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext): Promise<void> {
    return this.host.doStream(assistantId, callbacks, context);
  }

  // ===== 搬运方法(原 ChatService 成员,逐字搬出) =====

  // ===== Swipe 公开方法 =====

  /**
   * 获取当前会话的 Swipe 摘要列表(副本)。
   */
  getSwipeSummaries(): MessageSwipeSummary[] {
    return this.swipeSummaries.slice();
  }

  /**
   * 获取指定 Assistant 消息的 Swipe 摘要。
   */
  getSwipeSummary(assistantMessageId: string): MessageSwipeSummary | undefined {
    return this.getSummaryForMessage(assistantMessageId);
  }

  /**
   * 判断指定 Assistant 消息是否可操作 Swipe。
   * 只允许非生成状态下操作最后一条 Assistant 消息。
   */
  canOperateSwipe(assistantMessageId: string): boolean {
    if (this.isGenerating()) {
      return false;
    }
    if (assistantMessageId !== this.lastAssistantMessageId) {
      return false;
    }
    return true;
  }

  /**
   * 候选激活公共执行块:互斥锁 + 持久化切换 + reload + 时间戳 + 记忆失效 + 通知。
   * activatePreviousCandidate / activateNextCandidate / activateCandidateIndex 共用;
   * 调用方已完成 canOperateSwipe / isBusy / 索引合法性校验。
   */
  private async doActivateCandidate(assistantMessageId: string, targetIndex: number): Promise<void> {
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    this.swipeOperationInProgress = true;
    try {
      await this.swipePersistenceService.activateCandidate(assistantMessageId, targetIndex);
      // 重新加载 messages
      await this.reloadCurrentSession();
      // 重新加载 summaries
      this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      this.updateLastAssistantMessageId();
      // 仅更新 updatedAt,不修改 lastMessageAt
      this.persistChatTimestamp();
      // v12: 切换候选后,失效该 Assistant position 之后的记忆(内容已变化,旧摘要可能不准确)
      // 失败不阻塞,只记录 warn
      this.invalidateMemoryFromMessagePosition(assistantMessageId);
      this.emitMessages(this.lastCallbacks);
    } finally {
      this.swipeOperationInProgress = false;
    }
  }

  /**
   * 激活前一个候选。
   * T-6.3: 与生成 / session op / 其他 swipe 操作互斥(swipeOperationInProgress)。
   * 仅更新 updatedAt(不修改 lastMessageAt),避免会话反复置顶。
   */
  async activatePreviousCandidate(assistantMessageId: string): Promise<void> {
    if (!this.canOperateSwipe(assistantMessageId)) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'activatePreviousCandidate rejected: busy');
      return;
    }
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    if (summary === undefined) {
      return;
    }
    const newIndex: number = summary.activeCandidateIndex - 1;
    if (newIndex < 0) {
      return;
    }
    await this.doActivateCandidate(assistantMessageId, newIndex);
  }

  /**
   * 激活下一个候选。
   * T-6.3: 与生成 / session op / 其他 swipe 操作互斥(swipeOperationInProgress)。
   * 仅更新 updatedAt(不修改 lastMessageAt),避免会话反复置顶。
   */
  async activateNextCandidate(assistantMessageId: string): Promise<void> {
    if (!this.canOperateSwipe(assistantMessageId)) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'activateNextCandidate rejected: busy');
      return;
    }
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    if (summary === undefined) {
      return;
    }
    const newIndex: number = summary.activeCandidateIndex + 1;
    if (newIndex >= summary.candidateCount) {
      return;
    }
    await this.doActivateCandidate(assistantMessageId, newIndex);
  }

  /**
   * 激活指定索引的候选(开场白选择等场景的显式索引切换)。
   * 语义同 activateNextCandidate,但允许任意合法索引(含回绕到 Candidate 0)。
   * 索引越界时安全回退到 Candidate 0。
   */
  async activateCandidateIndex(assistantMessageId: string, index: number): Promise<void> {
    if (!this.canOperateSwipe(assistantMessageId)) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'activateCandidateIndex rejected: busy');
      return;
    }
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    if (summary === undefined) {
      return;
    }
    const target: number =
      index >= 0 && index < summary.candidateCount ? index : 0;
    if (target === summary.activeCandidateIndex) {
      return;
    }
    await this.doActivateCandidate(assistantMessageId, target);
  }

  /**
   * 获取指定消息的 Swipe 摘要。
   */
  getSummaryForMessage(messageId: string): MessageSwipeSummary | undefined {
    for (let i = 0; i < this.swipeSummaries.length; i++) {
      if (this.swipeSummaries[i].assistantMessageId === messageId) {
        return this.swipeSummaries[i];
      }
    }
    return undefined;
  }

  /**
   * 为最后一条 Assistant 消息生成新的候选回复。
   * 内部创建 Streaming 候选,启动流式请求。
   *
   * T-6.3:
   * - 创建 SwipeCandidate ActiveGenerationContext(包含 candidateIndex)
   * - 与 normal send / swipe browse / session op 互斥(swipeOperationInProgress)
   * - 启动失败时通过 doStream 的 handleStartFailure 统一处理
   * - 持久化走 MessageSwipePersistenceService(由 flushPersistence/persistWithRetry 路由)
   */
  async generateAlternativeCandidate(): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | busy');
      return;
    }
    if (this.lastAssistantMessageId.length === 0) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_assistant_message');
      return;
    }
    if (this.swipePersistenceService === null) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_swipe_state');
      return;
    }
    if (this.lastCallbacks === null) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_callbacks');
      return;
    }

    this.generationOperationId++;
    // 占用 swipe 操作互斥锁(保护 appendCandidate + reloadCurrentSession 期间不被并发)
    this.swipeOperationInProgress = true;

    const assistantMessageId: string = this.lastAssistantMessageId;
    const operationId: number = this.generationOperationId;
    const chatId: string = this.currentChatId !== undefined ? this.currentChatId : '';

    // 检查候选数量上限
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    let nextIndex: number = 0;
    if (summary !== undefined) {
      nextIndex = summary.candidateCount;
      if (nextIndex >= MAX_SWIPE_CANDIDATES) {
        Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | candidate_limit');
        this.swipeOperationInProgress = false;
        this.lastCallbacks.onError('该回复已达到候选数量上限');
        return;
      }
    }

    // 创建新候选(Streaming)并激活
    // T-6.4A-R6: 必须使用 appendCandidate 实际返回的 newIndex,
    // 不能使用 nextIndex(当 summary===undefined 时 nextIndex=0,
    // 但 ensureSwipeState 会先创建 Candidate 0,appendCandidate 实际创建 Candidate 1)
    let actualNewIndex: number = nextIndex;
    try {
      await this.swipePersistenceService.appendCandidate(
        assistantMessageId,
        {
          content: '',
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        },
        true // activate
      );
      // T-6.4A-R6: appendCandidate 返回的 candidates 可能是事务内旧快照,
      // 不包含刚插入的 Candidate。事务已提交,重新查询获取最新数据。
      const freshState: MessageSwipeState | null =
        await this.swipePersistenceService.getSwipeState(assistantMessageId);
      if (freshState !== null) {
        let maxIdx: number = 0;
        for (let i = 0; i < freshState.candidates.length; i++) {
          if (freshState.candidates[i].candidateIndex > maxIdx) {
            maxIdx = freshState.candidates[i].candidateIndex;
          }
        }
        actualNewIndex = maxIdx;
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'Regenerate | failed | appendCandidate: ' + msg);
      this.swipeOperationInProgress = false;
      this.lastCallbacks.onError('创建候选回复失败: ' + msg);
      return;
    }

    // 更新 swipeSummaries(使用 actualNewIndex)
    if (summary !== undefined) {
      this.swipeSummaries = this.swipeSummaries.map(
        (s: MessageSwipeSummary): MessageSwipeSummary => {
          if (s.assistantMessageId === assistantMessageId) {
            return {
              assistantMessageId: s.assistantMessageId,
              activeCandidateIndex: actualNewIndex,
              candidateCount: actualNewIndex + 1,
              isGeneratingCandidate: true
            };
          }
          return s;
        }
      );
    } else {
      this.swipeSummaries.push({
        assistantMessageId: assistantMessageId,
        activeCandidateIndex: actualNewIndex,
        candidateCount: actualNewIndex + 1,
        isGeneratingCandidate: true
      });
    }

    // 建立 SwipeCandidate 活动上下文(替代旧 ActiveSwipeGeneration)
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.SwipeCandidate,
      chatId: chatId,
      assistantMessageId: assistantMessageId,
      swipeCandidateIndex: actualNewIndex
    };

    // 候选创建 + summary 更新完成,释放 swipe 操作锁;
    // 后续生成期间通过 activeGeneration 与 isBusy()(state=Sending/Streaming)互斥
    this.swipeOperationInProgress = false;

    // T-6.4A: 不再调用 reloadCurrentSession()。
    // 原因:reloadCurrentSession → loadSessionInternal → normalizeInterruptedMessages
    // 会把刚物化的 Streaming 候选改为 Cancelled,导致 DB 与内存状态不一致,
    // 重新进入页面时目标 Assistant 显示为空内容(旧历史"消失"Bug 根因)。
    // 正确做法:直接在完整内存历史中替换目标 Assistant 为 Streaming + 空 content,
    // 保留所有其他消息不变。
    this.replaceAssistantMessageInFullHistory(assistantMessageId);

    // 更新状态
    this.currentAssistantId = assistantMessageId;
    this.setState(ChatState.Sending, this.lastCallbacks);
    this.emitMessages(this.lastCallbacks);

    // 启动流式请求(携带 SwipeCandidate 上下文)
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = assistantMessageId;
    this.doStream(assistantMessageId, this.lastCallbacks, this.activeGeneration);
  }

  /**
   * T-6.4A: 在完整页面历史中按 Message ID 查找目标 Assistant,
   * 只替换该消息为 Streaming + 空 content(用于重新生成候选),
   * 保留所有其他消息的 ID、内容、顺序、sequenceNumber 不变。
   *
   * 要求:
   * 1. 在完整页面历史中按 Message ID 查找;
   * 2. 只替换一项;
   * 3. 保留其他所有项;
   * 4. 返回新数组引用;
   * 5. 找不到时抛安全错误;
   * 6. 不使用请求裁剪后的数组更新 UI。
   */
  private replaceAssistantMessageInFullHistory(assistantMessageId: string): void {
    let found: boolean = false;
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === assistantMessageId) {
        found = true;
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          content: '',
          updatedAt: Date.now(),
          isStreaming: true,
          errorMessage: undefined,
          status: ChatMessageStatus.Streaming
        });
      }
      return msg;
    });
    if (!found) {
      throw new Error('replaceAssistantMessageInFullHistory: target assistant not found');
    }
  }
}