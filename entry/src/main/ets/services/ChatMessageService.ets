/**
 * ChatMessageService 消息级操作(删除 / 编辑)(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - deleteMessage:删除单条消息(首条不可删;Assistant 同步清理 Swipe 候选)
 * - editNarratorMessage:编辑旁白消息(仅 senderType=narrator 生效)
 * - editAssistantMessage:编辑角色回复(仅 Assistant 生效;编辑后失效该位置记忆)
 *
 * 依赖与宿主(ArkTS 说明):
 * - 会话状态(messages / currentAssistantId / currentChatId / swipeOperationInProgress 等)
 *   仍由 ChatService 持有(与流式核心共享),经 ChatMessageHost 函数属性回调读写——
 *   与搬运前 this.xxx 语义一致;类内同名 getter/setter/方法转发,使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ChatMessageService(仅日志来源标注变化)。
 */

import { ChatMessage, mergeChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatPersistenceService } from './ChatPersistenceService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatMessageService';

/** 消息服务依赖(全部为只读引用,null 表示未装配) */
export interface ChatMessageDeps {
  /** 会话持久化服务(物理删除 / 更新消息) */
  persistenceService: ChatPersistenceService | null;
  /** 消息候选持久化服务(删除 Assistant 时清理 Swipe 候选) */
  swipePersistenceService: MessageSwipePersistenceService | null;
}

/**
 * 宿主回调:会话状态读写与宿主私有能力。
 * 读取即最新、写入即生效(与搬运前 this.xxx 语义一致)。
 */
export interface ChatMessageHost {
  /** 宿主是否已释放 */
  isDisposed: () => boolean;
  /** 是否正在生成(生成中不可删除) */
  isGenerating: () => boolean;
  /** Swipe 浏览/切换操作互斥标志读取 */
  getSwipeOperationInProgress: () => boolean;
  /** 当前消息列表读取(读取即最新;调用方不得直接修改返回值) */
  getMessages: () => ChatMessage[];
  /** 整体替换消息列表(不可变更新产生的新数组) */
  setMessages: (messages: ChatMessage[]) => void;
  /** 当前 Assistant 消息 id 读取 */
  getCurrentAssistantId: () => string | null;
  /** 当前 Assistant 消息 id 更新 */
  setCurrentAssistantId: (assistantId: string | null) => void;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 失效覆盖指定消息位置的记忆(章节/核心等) */
  invalidateMemoryFromMessagePosition: (messageId: string) => void;
}

export class ChatMessageService {
  private readonly persistenceService: ChatPersistenceService | null;
  private readonly swipePersistenceService: MessageSwipePersistenceService | null;
  private readonly host: ChatMessageHost;

  constructor(deps: ChatMessageDeps, host: ChatMessageHost) {
    this.persistenceService = deps.persistenceService;
    this.swipePersistenceService = deps.swipePersistenceService;
    this.host = host;
  }

  // ===== 宿主状态与能力(同名 getter/setter/方法转发,保持搬运代码零改写) =====

  private get disposed(): boolean {
    return this.host.isDisposed();
  }

  private get swipeOperationInProgress(): boolean {
    return this.host.getSwipeOperationInProgress();
  }

  private get messages(): ChatMessage[] {
    return this.host.getMessages();
  }

  private set messages(value: ChatMessage[]) {
    this.host.setMessages(value);
  }

  private get currentAssistantId(): string | null {
    return this.host.getCurrentAssistantId();
  }

  private set currentAssistantId(value: string | null) {
    this.host.setCurrentAssistantId(value);
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private isGenerating(): boolean {
    return this.host.isGenerating();
  }

  private findMessageIndexById(messageId: string): number {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        return i;
      }
    }
    return -1;
  }

  private invalidateMemoryFromMessagePosition(messageId: string): void {
    this.host.invalidateMemoryFromMessagePosition(messageId);
  }

  // ===== 搬运方法(原 ChatService 成员,逐字搬出) =====

  /**
   * 删除单条消息(聊天泡"删除"功能)。
   *
   * 规则:
   * - 首条消息(本会话开场白)不可删除,避免破坏会话结构
   * - 删除前失效覆盖该消息位置的记忆(章节/核心等,避免记忆引用已删内容)
   * - 若为 Assistant 消息,同步清理其 Swipe 候选数据
   * - 物理删除数据库记录并从内存列表移除
   *
   * @param messageId 待删除的消息 ID
   */
  async deleteMessage(messageId: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isGenerating()) {
      throw new Error('请先停止当前回复');
    }
    if (this.swipeOperationInProgress) {
      throw new Error('请先完成当前 Swipe 操作');
    }
    const idx: number = this.findMessageIndexById(messageId);
    if (idx <= 0) {
      throw new Error('首条消息不可删除');
    }
    if (idx >= this.messages.length) {
      return;
    }
    // 删除前失效覆盖该位置的记忆(不阻塞删除)
    this.invalidateMemoryFromMessagePosition(messageId);
    // Assistant 消息:清理 Swipe 候选数据
    if (this.swipePersistenceService !== null) {
      try {
        await this.swipePersistenceService.removeSwipeState(messageId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'deleteMessage | clear swipe failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }
    // 物理删除数据库记录
    if (this.persistenceService !== null) {
      await this.persistenceService.removeMessage(messageId);
    }
    // 移除内存列表(不可变更新:构造新数组并整体替换)
    const next: ChatMessage[] = this.messages.slice();
    next.splice(idx, 1);
    this.messages = next;
    if (this.currentAssistantId === messageId) {
      this.currentAssistantId = null;
    }
  }

  async editNarratorMessage(messageId: string, editedContent: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    const idx: number = this.findMessageIndexById(messageId);
    if (idx < 0) {
      return;
    }
    const msg: ChatMessage = this.messages[idx];
    if (msg.senderType !== 'narrator') {
      return;
    }
    const updated: ChatMessage = mergeChatMessage(msg, {
      content: editedContent,
      updatedAt: Date.now()
    });
    // 不可变更新:构造新数组并整体替换
    const next: ChatMessage[] = this.messages.slice();
    next[idx] = updated;
    this.messages = next;
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      await this.persistenceService.updateMessage(messageId, updated);
    }
  }

  /**
   * 编辑角色回复内容(仅改当前激活的文本,不重新生成)。
   *
   * - 仅对 Assistant 消息生效
   * - 编辑会改变剧情内容,因此失效覆盖该消息位置的记忆(与 re-swipe/删除一致)
   * - Swipe 候选记录保留不动(只更新激活消息本身)
   *
   * @param messageId 目标 Assistant 消息 ID
   * @param editedContent 编辑后的内容
   */
  async editAssistantMessage(messageId: string, editedContent: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    const idx: number = this.findMessageIndexById(messageId);
    if (idx < 0) {
      return;
    }
    const msg: ChatMessage = this.messages[idx];
    if (msg.role !== ChatRole.Assistant) {
      return;
    }
    const updated: ChatMessage = mergeChatMessage(msg, {
      content: editedContent,
      updatedAt: Date.now()
    });
    // 不可变更新:构造新数组并整体替换
    const next: ChatMessage[] = this.messages.slice();
    next[idx] = updated;
    this.messages = next;
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      await this.persistenceService.updateMessage(messageId, updated);
    }
    // 编辑内容会改变剧情,失效覆盖该位置的记忆(章节/核心等)
    this.invalidateMemoryFromMessagePosition(messageId);
  }

  /**
   * 标记消息是否计入记忆摘要。
   */
  async markMessageIncludeInMemory(messageId: string, include: boolean): Promise<void> {
    if (this.disposed) {
      return;
    }
    const idx: number = this.findMessageIndexById(messageId);
    if (idx < 0) {
      return;
    }
    const msg: ChatMessage = this.messages[idx];
    const updated: ChatMessage = mergeChatMessage(msg, { includeInMemory: include });
    this.messages[idx] = updated;
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        await this.persistenceService.updateMessage(messageId, updated);
      } catch (e) {
        Logger.error(LOG_TAG, 'markMessageIncludeInMemory failed: ' + String(e));
      }
    }
  }

}
