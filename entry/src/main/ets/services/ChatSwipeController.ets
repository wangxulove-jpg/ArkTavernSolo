/**
 * ChatSwipeController Swipe 浏览/切换簇(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - 查询:摘要列表 / 单条摘要 / 可操作性判定
 * - 切换:上一个 / 下一个 / 指定索引候选激活(公共执行块 doActivateCandidate)
 *
 * 依赖与宿主(ArkTS 说明):
 * - 会话状态(swipeSummaries / swipeOperationInProgress / lastAssistantMessageId 等)
 *   仍由 ChatService 持有(与 messages / activeGeneration 强耦合,不随迁);
 *   经 ChatSwipeHost 函数属性回调读写——与搬运前 this.xxx 语义一致;
 *   类内同名 getter/setter/方法转发,使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ChatSwipeController(仅日志来源标注变化)。
 *
 * 后续(P2-4b):generateAlternativeCandidate(生成族)与 ChatGenerationKind /
 * ActiveGenerationContext 类型抽离后将一并迁入本类。
 */

import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { MessageSwipeSummary } from '../models/MessageSwipe';
import { ChatServiceCallbacks } from '../models/ChatServiceContract';
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

}