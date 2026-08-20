/**
 * ForkChatService 从分支创建独立对话服务
 *
 * 实现两种模式:
 * - FullHistory:复制当前分支从根到目标消息的有效路径(消息/Swipe/Memory 全部新建)
 * - MemoryOnly:不复制旧消息,只把当前路径摘要作为新会话初始记忆(可选保留最后 2~4 条)
 *
 * 设计原则:
 * - 必须创建新实体(新 chatId、新 branchId、新 messageId、新 candidateId、新 memoryId)
 * - 新旧会话完全独立:删除任一不影响另一个
 * - 共享祖先 Memory 不得误删:ForkChatService 总是创建新 Memory 实体(标记 inheritedFromMemoryId)
 * - 事务内执行:全部写入在单个事务中完成,失败整体回滚
 * - 不修改源数据:只读取,不更新源 Chat/Branch/Message/Swipe/Memory
 *
 * 分层约束:
 * - 可被 ChatViewModel / MemoryManagementViewModel 调用
 * - 不直接被 pages/ 调用
 * - 不直接依赖 @ohos.net.http / @ohos.security.asset
 *
 * RDB 限制:
 * - HarmonyOS RDB 不支持嵌套事务,所有 *WithStore 方法不能自己开启事务
 * - 事务内对刚写入的数据查询不可见(快照隔离),next sequence/position 必须事务外预计算
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatRepository } from '../repositories/ChatRepository';
import { MessageRepository } from '../repositories/MessageRepository';
import { MessageSwipeRepository } from '../repositories/MessageSwipeRepository';
import { ConversationBranchRepository } from '../repositories/ConversationBranchRepository';
import { ChatMemoryRepository } from '../repositories/ChatMemoryRepository';
import { MemoryPersistenceService } from './MemoryPersistenceService';
import { Chat, createChat, updateChat } from '../models/Chat';
import { ChatMessage, createChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import {
  ConversationBranch,
  BranchMessageLink,
  BranchSwipeSelection,
  createBranchMessageLink
} from '../models/ConversationBranch';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  createSwipeCandidate
} from '../models/MessageSwipe';
import { ChatMemory, createChatMemory } from '../models/ChatMemory';
import {
  ForkChatMode,
  FullHistoryForkOptions,
  MemoryOnlyForkOptions,
  ForkChatResult
} from '../models/ForkChatOptions';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ForkChatService';

/**
 * Fork 执行过程中预读取的源数据快照。
 * 所有数据在事务开启前读取,事务内只写入新实体。
 */
interface FullHistorySourceSnapshot {
  sourceChat: Chat;
  sourceBranch: ConversationBranch;
  /** 按位置排序的 BranchMessageLink(已过滤 position <= forkPosition) */
  links: BranchMessageLink[];
  /** oldMessageId → Message 实体 */
  messageById: Map<string, ChatMessage>;
  /** oldAssistantMessageId → Group */
  groupByAssistantId: Map<string, MessageSwipeGroup>;
  /** oldAssistantMessageId → Candidates[] */
  candidatesByAssistantId: Map<string, MessageSwipeCandidate[]>;
  /** 源 Branch 的 SwipeSelection(对应范围内的 messageIds) */
  swipeSelections: BranchSwipeSelection[];
  /** 源 Branch 的 Memory(endPosition <= forkPosition) */
  memories: ChatMemory[];
  /** forkPosition(目标消息的 position) */
  forkPosition: number;
}

/**
 * MemoryOnly 模式预读取的源数据快照。
 */
interface MemoryOnlySourceSnapshot {
  sourceChat: Chat;
  sourceBranch: ConversationBranch;
  /** 源 Branch 全部 MessageLink(用于截取最近 N 条) */
  links: BranchMessageLink[];
  /** oldMessageId → Message 实体 */
  messageById: Map<string, ChatMessage>;
  /** 源 Branch 的最新 enabled Memory(可为 null) */
  latestMemory: ChatMemory | null;
}

/**
 * Fork 结果持有者(用于在事务闭包中传出结果,避免 TS 闭包 narrowing 问题)。
 */
interface ForkChatResultHolder {
  result: ForkChatResult | null;
}

export class ForkChatService {
  private readonly dbHelper: DbHelper;
  private readonly chatRepository: ChatRepository;
  private readonly messageRepository: MessageRepository;
  private readonly swipeRepository: MessageSwipeRepository;
  private readonly branchRepository: ConversationBranchRepository;
  private readonly memoryRepository: ChatMemoryRepository;
  private readonly memoryPersistence: MemoryPersistenceService;

  constructor(
    dbHelper: DbHelper,
    chatRepository: ChatRepository,
    messageRepository: MessageRepository,
    swipeRepository: MessageSwipeRepository,
    branchRepository: ConversationBranchRepository,
    memoryRepository: ChatMemoryRepository,
    memoryPersistence: MemoryPersistenceService
  ) {
    this.dbHelper = dbHelper;
    this.chatRepository = chatRepository;
    this.messageRepository = messageRepository;
    this.swipeRepository = swipeRepository;
    this.branchRepository = branchRepository;
    this.memoryRepository = memoryRepository;
    this.memoryPersistence = memoryPersistence;
  }

  // ===== 公开入口 =====

  /**
   * Fork 入口(根据 options.mode 分派)。
   */
  async forkChat(options: FullHistoryForkOptions | MemoryOnlyForkOptions): Promise<ForkChatResult> {
    if (options.mode === ForkChatMode.FullHistory) {
      return await this.forkChatWithFullHistory(options);
    }
    return await this.forkChatWithMemoryOnly(options);
  }

  /**
   * FullHistory 模式:携带完整历史创建独立对话。
   *
   * 步骤:
   * 1. 事务外预读取源数据(Message/SwipeGroup/Candidates/SwipeSelection/Memory)
   * 2. 事务内:创建新 Chat + Root Branch + 复制 Message + 复制 Swipe + 复制 Memory
   * 3. 失败整体回滚,源数据保持不变
   */
  async forkChatWithFullHistory(options: FullHistoryForkOptions): Promise<ForkChatResult> {
    if (options.sourceChatId.length === 0) {
      throw new Error('ForkChat: sourceChatId empty');
    }
    if (options.sourceBranchId.length === 0) {
      throw new Error('ForkChat: sourceBranchId empty');
    }
    if (options.forkMessageId.length === 0) {
      throw new Error('ForkChat: forkMessageId empty');
    }

    // 1. 预读取源数据(事务外)
    const snapshot: FullHistorySourceSnapshot =
      await this.loadFullHistorySnapshot(
        options.sourceChatId,
        options.sourceBranchId,
        options.forkMessageId
      );

    // 2. 事务内执行复制(用对象包装避免 TS 闭包 narrowing 问题)
    const holder: ForkChatResultHolder = { result: null };
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          const r: ForkChatResult = await this.forkChatWithFullHistoryWithStore(store, options, snapshot);
          holder.result = r;
        },
        'chat_fork'
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'forkChatWithFullHistory failed: '
        + (e instanceof Error ? e.message : String(e)));
      throw new Error(e instanceof Error ? e.message : String(e));
    }
    if (holder.result === null) {
      throw new Error('ForkChat: full history result null');
    }
    const finalResult: ForkChatResult = holder.result;
    return finalResult;
  }

  /**
   * MemoryOnly 模式:只携带记忆创建独立对话。
   *
   * 步骤:
   * 1. 事务外预读取源数据(最新 Memory + 可选最近 N 条消息)
   * 2. 事务内:创建新 Chat + Root Branch + 复制最近 N 条消息(可选) + 创建初始 Memory
   * 3. 失败整体回滚
   */
  async forkChatWithMemoryOnly(options: MemoryOnlyForkOptions): Promise<ForkChatResult> {
    if (options.sourceChatId.length === 0) {
      throw new Error('ForkChat: sourceChatId empty');
    }
    if (options.sourceBranchId.length === 0) {
      throw new Error('ForkChat: sourceBranchId empty');
    }

    const keepRecent: number = options.keepRecentMessages !== undefined
      ? Math.max(0, Math.min(4, options.keepRecentMessages))
      : 0;

    // 1. 预读取源数据(事务外)
    const snapshot: MemoryOnlySourceSnapshot =
      await this.loadMemoryOnlySnapshot(
        options.sourceChatId,
        options.sourceBranchId,
        keepRecent
      );

    // 2. 事务内执行(用对象包装避免 TS 闭包 narrowing 问题)
    const holder: ForkChatResultHolder = { result: null };
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          const r: ForkChatResult = await this.forkChatWithMemoryOnlyWithStore(store, options, snapshot);
          holder.result = r;
        },
        'chat_fork'
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'forkChatWithMemoryOnly failed: '
        + (e instanceof Error ? e.message : String(e)));
      throw new Error(e instanceof Error ? e.message : String(e));
    }
    if (holder.result === null) {
      throw new Error('ForkChat: memory only result null');
    }
    const finalResult: ForkChatResult = holder.result;
    return finalResult;
  }

  // ===== FullHistory 模式实现 =====

  /**
   * 事务外预读取 FullHistory 模式所需的源数据。
   */
  private async loadFullHistorySnapshot(
    sourceChatId: string,
    sourceBranchId: string,
    forkMessageId: string
  ): Promise<FullHistorySourceSnapshot> {
    // 读取源 Chat
    const sourceChat: Chat | null = await this.chatRepository.getById(sourceChatId);
    if (sourceChat === null) {
      throw new Error('ForkChat: sourceChat not found');
    }

    // 读取源 Branch
    const sourceBranch: ConversationBranch | null =
      await this.branchRepository.getBranch(sourceBranchId);
    if (sourceBranch === null) {
      throw new Error('ForkChat: sourceBranch not found');
    }
    if (sourceBranch.chatId !== sourceChatId) {
      throw new Error('ForkChat: sourceBranch chatId mismatch');
    }

    // 读取所有 MessageLink
    const allLinks: BranchMessageLink[] =
      await this.branchRepository.listMessageLinks(sourceBranchId);

    // 获取 forkPosition
    const forkPosition: number =
      await this.branchRepository.getMessagePosition(sourceBranchId, forkMessageId);
    if (forkPosition < 0) {
      throw new Error('ForkChat: forkMessageId not in sourceBranch');
    }

    // 过滤 position <= forkPosition
    const links: BranchMessageLink[] = [];
    for (let i = 0; i < allLinks.length; i++) {
      if (allLinks[i].position <= forkPosition) {
        links.push(allLinks[i]);
      }
    }

    // 读取所有 Message 实体(避免在事务内多次查询)
    const messageById: Map<string, ChatMessage> = new Map();
    for (let i = 0; i < links.length; i++) {
      const msgId: string = links[i].messageId;
      if (!messageById.has(msgId)) {
        const msg: ChatMessage | null = await this.messageRepository.getById(msgId);
        if (msg !== null) {
          messageById.set(msgId, msg);
        }
      }
    }

    // 读取所有 Assistant Message 的 SwipeGroup + Candidates
    const groupByAssistantId: Map<string, MessageSwipeGroup> = new Map();
    const candidatesByAssistantId: Map<string, MessageSwipeCandidate[]> = new Map();
    messageById.forEach((msg: ChatMessage, msgId: string): void => {
      if (msg.role === ChatRole.Assistant) {
        // 异步读取但这里不能 await(在 forEach 回调中),改用顺序循环
        // 这里先占位,后续循环读取
      }
      void msg;
      void msgId;
    });
    // 顺序读取(避免 forEach 中无法 await)
    const messageEntries: Array<[string, ChatMessage]> = Array.from(messageById.entries());
    for (let i = 0; i < messageEntries.length; i++) {
      const msgId: string = messageEntries[i][0];
      const msg: ChatMessage = messageEntries[i][1];
      if (msg.role !== ChatRole.Assistant) {
        continue;
      }
      const group: MessageSwipeGroup | null = await this.swipeRepository.getGroup(msgId);
      if (group !== null) {
        groupByAssistantId.set(msgId, group);
        const candidates: MessageSwipeCandidate[] =
          await this.swipeRepository.listCandidates(msgId);
        candidatesByAssistantId.set(msgId, candidates);
      }
    }

    // 读取源 Branch 的 SwipeSelection(对应范围内的 messageIds)
    const allSwipeSelections: BranchSwipeSelection[] =
      await this.branchRepository.listSwipeSelections(sourceBranchId);
    const messageIdSet: Set<string> = new Set();
    for (let i = 0; i < links.length; i++) {
      messageIdSet.add(links[i].messageId);
    }
    const swipeSelections: BranchSwipeSelection[] = [];
    for (let i = 0; i < allSwipeSelections.length; i++) {
      if (messageIdSet.has(allSwipeSelections[i].assistantMessageId)) {
        swipeSelections.push(allSwipeSelections[i]);
      }
    }

    // 读取源 Branch 的 Memory(endPosition <= forkPosition)
    const allMemories: ChatMemory[] =
      await this.memoryRepository.listByBranch(sourceBranchId);
    const memories: ChatMemory[] = [];
    for (let i = 0; i < allMemories.length; i++) {
      if (allMemories[i].endPosition <= forkPosition) {
        memories.push(allMemories[i]);
      }
    }

    return {
      sourceChat: sourceChat,
      sourceBranch: sourceBranch,
      links: links,
      messageById: messageById,
      groupByAssistantId: groupByAssistantId,
      candidatesByAssistantId: candidatesByAssistantId,
      swipeSelections: swipeSelections,
      memories: memories,
      forkPosition: forkPosition
    };
  }

  /**
   * 事务内执行 FullHistory 模式复制。
   */
  private async forkChatWithFullHistoryWithStore(
    store: relationalStore.RdbStore,
    options: FullHistoryForkOptions,
    snapshot: FullHistorySourceSnapshot
  ): Promise<ForkChatResult> {
    const now: number = nowMillis();

    // 1. 创建新 Chat
    const newChatId: string = generateUuid();
    const resolvedTitle: string = options.title !== undefined && options.title.length > 0
      ? options.title : '独立对话';
    const newChat: Chat = createChat({
      id: newChatId,
      characterId: snapshot.sourceChat.characterId,
      title: resolvedTitle,
      createdAt: now
    });
    await this.chatRepository.insertWithStore(store, newChat);

    // 2. 创建 Root Branch + 设置 Active
    const rootBranch: ConversationBranch =
      await this.branchRepository.createRootBranchWithStore(store, newChatId);
    await this.branchRepository.setActiveBranchWithStore(store, newChatId, rootBranch.id);

    // 3. 复制 Message 实体 + 建立 oldMessageId → newMessageId 映射
    const oldToNewMessageId: Map<string, string> = new Map();
    let copiedMessageCount: number = 0;
    for (let i = 0; i < snapshot.links.length; i++) {
      const oldLink: BranchMessageLink = snapshot.links[i];
      const oldMessage: ChatMessage | undefined = snapshot.messageById.get(oldLink.messageId);
      if (oldMessage === undefined) {
        // 源 Message 缺失,跳过该 Link(不阻塞 fork)
        continue;
      }
      const newMessageId: string = generateUuid();
      const newMessage: ChatMessage = createChatMessage(
        newMessageId,
        oldMessage.role,
        oldMessage.content,
        now
      );
      // 透传 status / errorMessage(便于状态恢复)
      // createChatMessage 不接受 status/errorMessage,需要构造完整对象
      const fullMessage: ChatMessage = {
        id: newMessage.id,
        role: newMessage.role,
        content: newMessage.content,
        createdAt: newMessage.createdAt,
        updatedAt: now,
        status: oldMessage.status !== undefined ? oldMessage.status : ChatMessageStatus.Completed,
        errorMessage: oldMessage.errorMessage
      };
      // sequenceNumber = i + 1(从 1 开始,与 ChatPersistenceService.createSessionWithFirstMessage 一致)
      await this.messageRepository.insertWithStore(
        store, fullMessage, newChatId, i + 1
      );
      oldToNewMessageId.set(oldLink.messageId, newMessageId);
      copiedMessageCount++;
    }

    // 4. 插入 BranchMessageLink(新 branchId + 新 messageId,position 保持不变)
    for (let i = 0; i < snapshot.links.length; i++) {
      const oldLink: BranchMessageLink = snapshot.links[i];
      const newMessageId: string | undefined = oldToNewMessageId.get(oldLink.messageId);
      if (newMessageId === undefined) {
        continue;
      }
      await this.branchRepository.insertMessageLinkWithStore(
        store, rootBranch.id, newMessageId, oldLink.position
      );
    }

    // 5. 复制 SwipeGroup + Candidates(对每个 Assistant Message)
    const oldToNewAssistantId: Map<string, string> = new Map();
    snapshot.groupByAssistantId.forEach((group: MessageSwipeGroup, oldAssistantId: string): void => {
      // 在 Map.forEach 中无法 await,改用顺序循环
      void group;
      void oldAssistantId;
    });
    // 顺序循环
    const groupEntries: Array<[string, MessageSwipeGroup]> =
      Array.from(snapshot.groupByAssistantId.entries());
    for (let i = 0; i < groupEntries.length; i++) {
      const oldAssistantId: string = groupEntries[i][0];
      const oldGroup: MessageSwipeGroup = groupEntries[i][1];
      const newAssistantId: string | undefined = oldToNewMessageId.get(oldAssistantId);
      if (newAssistantId === undefined) {
        continue;
      }
      oldToNewAssistantId.set(oldAssistantId, newAssistantId);

      // 创建新 Group(新 assistantMessageId + 新 chatId)
      const newGroup: MessageSwipeGroup = {
        assistantMessageId: newAssistantId,
        chatId: newChatId,
        activeCandidateIndex: oldGroup.activeCandidateIndex,
        createdAt: now,
        updatedAt: now
      };
      await this.swipeRepository.insertGroupWithStore(store, newGroup);

      // 复制 Candidates
      const oldCandidates: MessageSwipeCandidate[] | undefined =
        snapshot.candidatesByAssistantId.get(oldAssistantId);
      if (oldCandidates !== undefined) {
        for (let j = 0; j < oldCandidates.length; j++) {
          const oldCandidate: MessageSwipeCandidate = oldCandidates[j];
          // 创建新 Candidate(新 id + 新 assistantMessageId)
          const newCandidate: MessageSwipeCandidate = createSwipeCandidate(
            newAssistantId,
            oldCandidate.candidateIndex,
            {
              id: generateUuid(),
              content: oldCandidate.content,
              status: oldCandidate.status,
              errorMessage: oldCandidate.errorMessage,
              isStreaming: false, // Fork 出来的候选不可能是流式中
              createdAt: now
            }
          );
          await this.swipeRepository.insertCandidateWithStore(store, newCandidate);
        }
      }
    }

    // 6. 复制 SwipeSelection(基于 oldMessageId → newMessageId 映射)
    for (let i = 0; i < snapshot.swipeSelections.length; i++) {
      const oldSel: BranchSwipeSelection = snapshot.swipeSelections[i];
      const newAssistantId: string | undefined = oldToNewMessageId.get(oldSel.assistantMessageId);
      if (newAssistantId === undefined) {
        continue;
      }
      await this.branchRepository.upsertSwipeSelectionWithStore(
        store, rootBranch.id, newAssistantId, oldSel.candidateIndex
      );
    }

    // 7. 复制 Memory(基于映射,使用新 chatId + 新 branchId + 新 messageId)
    let copiedMemoryCount: number = 0;
    for (let i = 0; i < snapshot.memories.length; i++) {
      const oldMemory: ChatMemory = snapshot.memories[i];
      const newStartMessageId: string | undefined =
        oldMemory.startMessageId.length > 0
          ? oldToNewMessageId.get(oldMemory.startMessageId)
          : '';
      const newEndMessageId: string | undefined =
        oldMemory.endMessageId.length > 0
          ? oldToNewMessageId.get(oldMemory.endMessageId)
          : '';

      // 若 start/end Message 缺失(理论上不应该发生),用空字符串
      const startMsgId: string = newStartMessageId !== undefined ? newStartMessageId : '';
      const endMsgId: string = newEndMessageId !== undefined ? newEndMessageId : '';

      const newMemory: ChatMemory = createChatMemory(
        generateUuid(),
        newChatId,
        rootBranch.id,
        startMsgId,
        endMsgId,
        oldMemory.startPosition,
        oldMemory.endPosition,
        oldMemory.summary,
        now,
        oldMemory.id // 标记继承自源 Memory
      );
      await this.memoryRepository.insertWithStore(store, newMemory);
      copiedMemoryCount++;
    }

    // 8. 更新 Branch 时间戳 + Chat lastMessageAt
    await this.branchRepository.touchBranchWithStore(store, rootBranch.id, now);
    const updatedChat: Chat = updateChat(newChat, {
      lastMessageAt: now,
      updatedAt: now
    });
    await this.chatRepository.updateLastMessageAtWithStore(
      store, newChatId, now, now
    );
    void updatedChat;

    return {
      chatId: newChatId,
      branchId: rootBranch.id,
      copiedMessageCount: copiedMessageCount,
      copiedMemoryCount: copiedMemoryCount
    };
  }

  // ===== MemoryOnly 模式实现 =====

  /**
   * 事务外预读取 MemoryOnly 模式所需的源数据。
   */
  private async loadMemoryOnlySnapshot(
    sourceChatId: string,
    sourceBranchId: string,
    keepRecent: number
  ): Promise<MemoryOnlySourceSnapshot> {
    const sourceChat: Chat | null = await this.chatRepository.getById(sourceChatId);
    if (sourceChat === null) {
      throw new Error('ForkChat: sourceChat not found');
    }

    const sourceBranch: ConversationBranch | null =
      await this.branchRepository.getBranch(sourceBranchId);
    if (sourceBranch === null) {
      throw new Error('ForkChat: sourceBranch not found');
    }
    if (sourceBranch.chatId !== sourceChatId) {
      throw new Error('ForkChat: sourceBranch chatId mismatch');
    }

    const links: BranchMessageLink[] =
      await this.branchRepository.listMessageLinks(sourceBranchId);

    // 读取最近 N 条消息(用于保留上下文)
    const messageById: Map<string, ChatMessage> = new Map();
    if (keepRecent > 0 && links.length > 0) {
      const startIndex: number = Math.max(0, links.length - keepRecent);
      for (let i = startIndex; i < links.length; i++) {
        const msgId: string = links[i].messageId;
        if (!messageById.has(msgId)) {
          const msg: ChatMessage | null = await this.messageRepository.getById(msgId);
          if (msg !== null) {
            messageById.set(msgId, msg);
          }
        }
      }
    }

    // 读取最新 enabled Memory
    const latestMemory: ChatMemory | null =
      await this.memoryPersistence.getLatestByBranch(sourceBranchId);

    return {
      sourceChat: sourceChat,
      sourceBranch: sourceBranch,
      links: links,
      messageById: messageById,
      latestMemory: latestMemory
    };
  }

  /**
   * 事务内执行 MemoryOnly 模式复制。
   */
  private async forkChatWithMemoryOnlyWithStore(
    store: relationalStore.RdbStore,
    options: MemoryOnlyForkOptions,
    snapshot: MemoryOnlySourceSnapshot
  ): Promise<ForkChatResult> {
    const now: number = nowMillis();
    const keepRecent: number = options.keepRecentMessages !== undefined
      ? Math.max(0, Math.min(4, options.keepRecentMessages))
      : 0;

    // 1. 创建新 Chat
    const newChatId: string = generateUuid();
    const resolvedTitle: string = options.title !== undefined && options.title.length > 0
      ? options.title : '独立对话';
    const newChat: Chat = createChat({
      id: newChatId,
      characterId: snapshot.sourceChat.characterId,
      title: resolvedTitle,
      createdAt: now
    });
    await this.chatRepository.insertWithStore(store, newChat);

    // 2. 创建 Root Branch + 设置 Active
    const rootBranch: ConversationBranch =
      await this.branchRepository.createRootBranchWithStore(store, newChatId);
    await this.branchRepository.setActiveBranchWithStore(store, newChatId, rootBranch.id);

    // 3. 可选:复制最近 N 条消息作为上下文
    let copiedMessageCount: number = 0;
    const recentLinks: BranchMessageLink[] = [];
    if (keepRecent > 0 && snapshot.links.length > 0) {
      const startIndex: number = Math.max(0, snapshot.links.length - keepRecent);
      for (let i = startIndex; i < snapshot.links.length; i++) {
        recentLinks.push(snapshot.links[i]);
      }
    }

    // 复制最近消息(新 messageId,position 从 0 开始)
    for (let i = 0; i < recentLinks.length; i++) {
      const oldLink: BranchMessageLink = recentLinks[i];
      const oldMessage: ChatMessage | undefined = snapshot.messageById.get(oldLink.messageId);
      if (oldMessage === undefined) {
        continue;
      }
      const newMessageId: string = generateUuid();
      const fullMessage: ChatMessage = {
        id: newMessageId,
        role: oldMessage.role,
        content: oldMessage.content,
        createdAt: now,
        updatedAt: now,
        status: oldMessage.status !== undefined ? oldMessage.status : ChatMessageStatus.Completed,
        errorMessage: oldMessage.errorMessage
      };
      await this.messageRepository.insertWithStore(
        store, fullMessage, newChatId, i + 1
      );
      await this.branchRepository.insertMessageLinkWithStore(
        store, rootBranch.id, newMessageId, i
      );
      copiedMessageCount++;
    }

    // 4. 创建初始 Memory(继承自源最新 Memory)
    let copiedMemoryCount: number = 0;
    if (snapshot.latestMemory !== null && snapshot.latestMemory.summary.trim().length > 0) {
      // 新 Memory 覆盖"空范围":
      // - startPosition = 0, endPosition = -1 表示"覆盖 0 条消息"
      // - startMessageId / endMessageId 为空字符串(无关联消息)
      // - 后续 shouldTriggerSummary 检测到 endPosition=-1,所有新消息都是未总结
      const newMemory: ChatMemory = createChatMemory(
        generateUuid(),
        newChatId,
        rootBranch.id,
        '',
        '',
        0,
        -1,
        snapshot.latestMemory.summary,
        now,
        snapshot.latestMemory.id // 标记继承自源 Memory
      );
      await this.memoryRepository.insertWithStore(store, newMemory);
      copiedMemoryCount = 1;
    }

    // 5. 更新 Branch 时间戳 + Chat lastMessageAt
    await this.branchRepository.touchBranchWithStore(store, rootBranch.id, now);
    await this.chatRepository.updateLastMessageAtWithStore(
      store, newChatId, now, now
    );

    return {
      chatId: newChatId,
      branchId: rootBranch.id,
      copiedMessageCount: copiedMessageCount,
      copiedMemoryCount: copiedMemoryCount
    };
  }
}
