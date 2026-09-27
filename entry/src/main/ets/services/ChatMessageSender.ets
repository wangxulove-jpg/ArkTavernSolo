/**
 * ChatMessageSender 消息发起入口(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - sendMessage:发送用户消息并开始流式生成(User + Streaming Assistant 事务)
 * - narratorMessage:用户输入旁白文本,AI 以旁白身份回复
 * - narratorMessageOnly:仅插入旁白描述消息,不触发 AI 生成
 * - clearConversation:清空当前对话(生成中先停止)
 *
 * 依赖与宿主(ArkTS 说明):
 * - 会话与生成状态(messages / lastCallbacks / generationOperationId / currentChatId /
 *   currentSequenceNumber / lastPersistedContentLength / pendingPersistAssistantId /
 *   currentAssistantId / activeGeneration / state)仍由 ChatService 持有,
 *   经 ChatSendHost 函数属性回调读写——与搬运前 this.xxx 语义一致;
 *   类内同名 getter/setter/方法转发,使搬运代码零改写。
 * - 流式核心(doStream / stopGeneration)仍在 ChatService,经宿主委托调用。
 * - 日志 tag 由 ChatService 改为 ChatMessageSender(仅日志来源标注变化)。
 */

import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatState, ChatServiceCallbacks } from '../models/ChatServiceContract';
import { ChatGenerationKind, ActiveGenerationContext } from '../models/ChatGenerationContext';
import { ChatPersistenceService } from './ChatPersistenceService';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatMessageSender';

/** 消息发起服务依赖(全部为只读引用,null 表示未装配) */
export interface ChatSendDeps {
  /** 会话持久化服务 */
  persistenceService: ChatPersistenceService | null;
}

/**
 * 宿主回调:会话与生成状态读写、宿主私有能力委托。
 * 读取即最新、写入即生效(与搬运前 this.xxx 语义一致)。
 */
export interface ChatSendHost {
  /** 宿主是否已释放 */
  isDisposed: () => boolean;
  /** 是否处于忙碌状态(生成/Swipe/会话/Branch 操作中) */
  isBusy: () => boolean;
  /** 聊天状态机读取(用于忙碌日志) */
  getState: () => ChatState;
  /** 最近一次使用的回调读取 */
  getLastCallbacks: () => ChatServiceCallbacks | null;
  /** 最近一次使用的回调更新 */
  setLastCallbacks: (callbacks: ChatServiceCallbacks | null) => void;
  /** 生成操作标识读取 */
  getGenerationOperationId: () => number;
  /** 生成操作标识更新 */
  setGenerationOperationId: (operationId: number) => void;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 当前会话最大 sequenceNumber 更新 */
  setCurrentSequenceNumber: (sequenceNumber: number) => void;
  /** 上次持久化时的 Assistant content 长度更新 */
  setLastPersistedContentLength: (length: number) => void;
  /** 待持久化的 Assistant id 更新 */
  setPendingPersistAssistantId: (assistantId: string | null) => void;
  /** 设置聊天状态机并通知(宿主私有能力) */
  setState: (state: ChatState, callbacks: ChatServiceCallbacks | null) => void;
  /** 当前消息列表读取(读取即最新;调用方不得直接修改返回值) */
  getMessages: () => ChatMessage[];
  /** 整体替换消息列表(不可变更新产生的新数组) */
  setMessages: (messages: ChatMessage[]) => void;
  /** 当前 Assistant 消息 id 更新 */
  setCurrentAssistantId: (assistantId: string | null) => void;
  /** 当前活动生成上下文读取 */
  getActiveGeneration: () => ActiveGenerationContext | null;
  /** 当前活动生成上下文更新 */
  setActiveGeneration: (context: ActiveGenerationContext | null) => void;
  /** 通知消息更新(宿主私有能力) */
  emitMessages: (callbacks: ChatServiceCallbacks | null) => void;
  /** 启动流式请求(流式核心仍在 ChatService) */
  doStream: (assistantId: string, callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext) => Promise<void>;
  /** 是否正在生成 */
  isGenerating: () => boolean;
  /** 停止当前生成(流式核心取消路径仍在 ChatService) */
  stopGeneration: () => void;
}

export class ChatMessageSender {
  private readonly persistenceService: ChatPersistenceService | null;
  private readonly host: ChatSendHost;

  constructor(deps: ChatSendDeps, host: ChatSendHost) {
    this.persistenceService = deps.persistenceService;
    this.host = host;
  }

  // ===== 宿主状态与能力(同名 getter/setter/方法转发,保持搬运代码零改写) =====

  private get disposed(): boolean {
    return this.host.isDisposed();
  }

  private isBusy(): boolean {
    return this.host.isBusy();
  }

  private get state(): ChatState {
    return this.host.getState();
  }

  private get lastCallbacks(): ChatServiceCallbacks | null {
    return this.host.getLastCallbacks();
  }

  private set lastCallbacks(value: ChatServiceCallbacks | null) {
    this.host.setLastCallbacks(value);
  }

  private get generationOperationId(): number {
    return this.host.getGenerationOperationId();
  }

  private set generationOperationId(value: number) {
    this.host.setGenerationOperationId(value);
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private set currentSequenceNumber(value: number) {
    this.host.setCurrentSequenceNumber(value);
  }

  private set lastPersistedContentLength(value: number) {
    this.host.setLastPersistedContentLength(value);
  }

  private set pendingPersistAssistantId(value: string | null) {
    this.host.setPendingPersistAssistantId(value);
  }

  private setState(state: ChatState, callbacks: ChatServiceCallbacks | null): void {
    this.host.setState(state, callbacks);
  }

  private get messages(): ChatMessage[] {
    return this.host.getMessages();
  }

  private set messages(value: ChatMessage[]) {
    this.host.setMessages(value);
  }

  private set currentAssistantId(value: string | null) {
    this.host.setCurrentAssistantId(value);
  }

  private get activeGeneration(): ActiveGenerationContext | null {
    return this.host.getActiveGeneration();
  }

  private set activeGeneration(value: ActiveGenerationContext | null) {
    this.host.setActiveGeneration(value);
  }

  private emitMessages(callbacks: ChatServiceCallbacks | null): void {
    this.host.emitMessages(callbacks);
  }

  private doStream(assistantId: string, callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext): Promise<void> {
    return this.host.doStream(assistantId, callbacks, context);
  }

  private isGenerating(): boolean {
    return this.host.isGenerating();
  }

  private stopGeneration(): void {
    this.host.stopGeneration();
  }

  // ===== 搬运方法(原 ChatService 成员,逐字搬出) =====

  /**
   * 发送用户消息并开始流式生成。
   * 顺序:校验 → 创建 User 消息 → 持久化 → 创建 Assistant 占位 → 持久化 → 启动网络。
   *
   * 持久化策略:
   * - 有 persistenceService 时:先持久化 User + Streaming Assistant(事务),
   *   失败则不启动网络请求,页面显示错误
   * - 无 persistenceService 时:仅更新内存(兼容旧测试)
   */
  async sendMessage(userContent: string, callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot send message');
    }
    if (userContent.trim().length === 0) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'sendMessage rejected: busy state=' + this.state);
      return;
    }

    this.lastCallbacks = callbacks;
    this.generationOperationId++;

    // 1. 创建用户消息
    const userMsg: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.User,
      content: userContent,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation
    };

    // 2. 创建空 Assistant 占位消息
    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 3. 持久化(如果有 persistenceService)
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        const result =
          await this.persistenceService.appendUserAndStreamingAssistant(
            this.currentChatId, userMsg, assistantMsg
          );
        this.currentSequenceNumber = result.assistantSequenceNumber;
        this.lastPersistedContentLength = 0;
        this.pendingPersistAssistantId = assistantId;
      } catch (e) {
        // 持久化失败:不启动请求,显示错误
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.error(LOG_TAG, 'sendMessage persist failed: ' + msg);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('消息保存失败,请重试');
        return;
      }
    }

    // 4. 更新内存(持久化成功后)
    this.messages = [...this.messages, userMsg, assistantMsg];
    this.currentAssistantId = assistantId;
    // 建立 NormalResponse 活动上下文
    this.activeGeneration = {
      operationId: this.generationOperationId,
      kind: ChatGenerationKind.NormalResponse,
      chatId: this.currentChatId !== undefined ? this.currentChatId : '',
      assistantMessageId: assistantId
    };
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 5. 启动网络请求(失败也保留消息)
    this.doStream(assistantId, callbacks, this.activeGeneration);
  }


  /**
   * Narrator: 用户输入旁白文本,AI 以旁白身份回复。
   *
   * 流程:
   * 1. 创建 role=System, senderType='narrator' 的旁白消息
   * 2. 创建 role=Assistant, senderType='narrator' 的 Streaming 占位
   * 3. 注入旁白指令,AI 以叙述者视角回复
   */
  async narratorMessage(content: string, callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (content.trim().length === 0) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'narratorMessage rejected: busy');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }

    this.lastCallbacks = callbacks;
    this.generationOperationId++;

    const narratorMsg: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.System,
      content: content,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation,
      senderType: 'narrator',
      includeInMemory: false
    };

    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation,
      senderType: 'narrator',
      senderCharacterId: '',
      includeInMemory: false
    };

    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        const result =
          await this.persistenceService.appendUserAndStreamingAssistant(
            this.currentChatId, narratorMsg, assistantMsg
          );
        this.currentSequenceNumber = result.assistantSequenceNumber;
        this.lastPersistedContentLength = 0;
        this.pendingPersistAssistantId = assistantId;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.error(LOG_TAG, 'narratorMessage persist failed: ' + msg);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('消息保存失败,请重试');
        return;
      }
    }

    this.messages = [...this.messages, narratorMsg, assistantMsg];
    this.currentAssistantId = assistantId;
    this.activeGeneration = {
      operationId: this.generationOperationId,
      kind: ChatGenerationKind.Narrator,
      chatId: this.currentChatId,
      assistantMessageId: assistantId
    };
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);
    this.doStream(assistantId, callbacks, this.activeGeneration);
  }


  /**
   * Narrator-Only: 仅插入旁白描述消息,不触发 AI 生成。
   */
  async narratorMessageOnly(content: string, callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (content.trim().length === 0) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'narratorMessageOnly rejected: busy');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }

    this.lastCallbacks = callbacks;
    this.generationOperationId++;

    const narratorMsg: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.System,
      content: content,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation,
      senderType: 'narrator',
      includeInMemory: false
    };

    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        const seq: number =
          await this.persistenceService.appendMessage(
            this.currentChatId, narratorMsg
          );
        this.currentSequenceNumber = seq;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.error(LOG_TAG, 'narratorMessageOnly persist failed: ' + msg);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('消息保存失败,请重试');
        return;
      }
    }

    this.messages = [...this.messages, narratorMsg];
    this.emitMessages(callbacks);
  }


  /**
   * 清空当前对话。如正在生成先停止。
   */
  clearConversation(): void {
    if (this.isGenerating()) {
      this.stopGeneration();
    }
    this.messages = [];
    this.currentAssistantId = null;
    this.setState(ChatState.Idle, this.lastCallbacks);
    this.emitMessages(this.lastCallbacks);
  }

}