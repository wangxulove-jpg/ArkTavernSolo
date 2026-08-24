/**
 * ConversationBranchPersistenceService(T-6.4A)
 *
 * 职责:
 * - 协调 ConversationBranchRepository / MessageRepository / MessageSwipeRepository
 * - 提供 Branch 级业务接口:ensureRootBranch / forkAtMessage / loadActiveBranchMessages /
 *   appendMessageToActiveBranch / updateActiveBranchSwipeSelection / getRecordCounts / listBranches
 * - 通过 DbHelper 事务保证跨表写入的原子性
 *
 * 不依赖:
 * - ArkUI / 页面
 * - Provider / PromptBuilder / ChatService
 *
 * 设计原则:
 * - WithStore 方法组合,避免嵌套事务
 * - 不修改 Message 实体(只通过 BranchMessageLink 关联)
 * - 不复制 Candidate 正文(只保存 BranchSwipeSelection 选择)
 * - 不删除原 Branch 后续消息
 * - 活动 Branch 的 Candidate 投影只用于当前 Branch 加载,不影响其他 Branch
 * - 日志只记录操作类型和数量,不记录正文 / 完整 ID / SQL
 *
 * 物化兼容(T-6.4A 阶段):
 * - 当前活动 Branch 的 SwipeSelection 与 message_swipe_groups.active_candidate_index 同步
 * - 非活动 Branch 的选择只保存在 BranchSwipeSelection
 * - 切换 Branch 时由 T-6.4B 重新物化对应 Candidate
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import {
  ConversationBranchRepository,
  V5IntegrityReport
} from '../repositories/ConversationBranchRepository';
import { MessageRepository } from '../repositories/MessageRepository';
import { MessageSwipeRepository } from '../repositories/MessageSwipeRepository';
import { MemoryPersistenceService } from './MemoryPersistenceService';
import {
  ConversationBranch,
  BranchMessageLink,
  BranchSwipeSelection,
  ConversationBranchSummary,
  ConversationRecordCounts
} from '../models/ConversationBranch';
import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { MessageSwipeCandidate } from '../models/MessageSwipe';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import { Logger } from '../utils/Logger';
import {
  TABLE_MESSAGES,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_ERROR_MESSAGE,
  COLUMN_IS_STREAMING,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';
import { extractCauseMessage } from '../repositories/RepositoryMappers';
import { isConstraintViolation } from '../repositories/RepositoryMappers';
import {
  BranchMapDisplayInfo,
  buildUserPreview,
  buildAssistantPreview
} from '../models/BranchMapDisplayInfo';

const LOG_TAG: string = 'ConvBranchSvc';

/**
 * T-6.4B-3.1 编辑 User Message 创建新 Branch 的返回结果。
 */
export interface EditedBranchGenerationTarget {
  /** 新创建 Branch ID */
  newBranchId: string;
  /** 新创建 User Message ID(编辑后内容) */
  newUserMessageId: string;
  /** 新创建 Streaming Assistant Message ID */
  newAssistantMessageId: string;
  /** fork anchor Message ID(原 User 前一条消息) */
  anchorMessageId: string;
  /** 被编辑的原 User Message ID(未修改) */
  originalUserMessageId: string;
  /** 新 Branch 摘要 */
  newBranchSummary: ConversationBranchSummary;
}

/**
 * 判断消息是否为可建立 Swipe 的 Assistant 消息。
 * 与 MessageSwipePersistenceService 保持一致。
 */
function isSwipeableAssistant(message: ChatMessage): boolean {
  if (message.role !== ChatRole.Assistant) {
    return false;
  }
  const source: ChatMessageSource | undefined = message.source;
  if (source === undefined) {
    return true;
  }
  return source === ChatMessageSource.Conversation;
}

/**
 * 用 Candidate 的内容投影 ChatMessage(不可变更新)。
 * 只覆盖 content / status / errorMessage / isStreaming / updatedAt,
 * 保留 id / role / createdAt / source / sequenceNumber。
 */
function projectMessageWithCandidate(
  message: ChatMessage,
  candidate: MessageSwipeCandidate
): ChatMessage {
  return {
    id: message.id,
    role: message.role,
    content: candidate.content,
    createdAt: message.createdAt,
    updatedAt: candidate.updatedAt !== undefined ? candidate.updatedAt : candidate.createdAt,
    isStreaming: candidate.isStreaming,
    errorMessage: candidate.errorMessage,
    status: candidate.status,
    source: message.source
  };
}

export class ConversationBranchPersistenceService {
  private readonly dbHelper: DbHelper;
  private readonly branchRepository: ConversationBranchRepository;
  private readonly messageRepository: MessageRepository;
  private readonly swipeRepository: MessageSwipeRepository;
  /** Memory 持久化服务(可选,fork 时复制祖先记忆) */
  private readonly memoryPersistenceService: MemoryPersistenceService | null;

  constructor(
    dbHelper: DbHelper,
    branchRepository: ConversationBranchRepository,
    messageRepository: MessageRepository,
    swipeRepository: MessageSwipeRepository,
    memoryPersistenceService: MemoryPersistenceService | null = null
  ) {
    this.dbHelper = dbHelper;
    this.branchRepository = branchRepository;
    this.messageRepository = messageRepository;
    this.swipeRepository = swipeRepository;
    this.memoryPersistenceService = memoryPersistenceService;
  }

  // ===== Root Branch =====

  /**
   * 确保 Chat 存在 Root Branch(幂等)。
   * - 已存在:直接返回
   * - 不存在:在事务中创建 Root Branch + chat_branch_state
   *
   * 不检查 Chat 是否存在,由调用方负责(避免与 Chat 创建事务嵌套)。
   * ChatPersistenceService.createSessionWithFirstMessage 等场景需要调用方在外部事务中
   * 使用 ensureRootBranchWithStore。
   *
   * @param chatId 所属 Chat ID
   * @returns Root Branch
   */
  async ensureRootBranch(chatId: string): Promise<ConversationBranch> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('ensureRootBranch: chatId empty');
    }
    const existing: ConversationBranch | null =
      await this.branchRepository.getRootBranch(chatId);
    if (existing !== null) {
      return existing;
    }
    let result: ConversationBranch | null = null;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          result = await this.ensureRootBranchWithStore(store, chatId);
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `ensureRootBranch: ${(err as Error).message}`
      );
    }
    return result!;
  }

  /**
   * 在给定 store 上确保 Root Branch 存在(事务内部方法)。
   * 幂等:已存在时直接返回。
   */
  async ensureRootBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ConversationBranch> {
    const existing: ConversationBranch | null =
      await this.branchRepository.getRootBranchWithStore(store, chatId);
    if (existing !== null) {
      return existing;
    }
    const branch: ConversationBranch =
      await this.branchRepository.createRootBranchWithStore(store, chatId);
    await this.branchRepository.setActiveBranchWithStore(store, chatId, branch.id);
    return branch;
  }

  // ===== Active Branch =====

  /**
   * 获取 Chat 的当前活动 Branch。
   * 不存在返回 null。
   */
  async getActiveBranch(chatId: string): Promise<ConversationBranch | null> {
    return await this.branchRepository.getActiveBranch(chatId);
  }

  // ===== Branch 列表 =====

  /**
   * 列出 Chat 的所有 Branch 摘要。
   */
  async listBranches(chatId: string): Promise<ConversationBranchSummary[]> {
    return await this.branchRepository.listBranches(chatId);
  }

  // ===== 记录数量 =====

  /**
   * 获取 Chat 的记录数量统计。
   */
  async getRecordCounts(chatId: string): Promise<ConversationRecordCounts> {
    return await this.branchRepository.getRecordCounts(chatId);
  }

  // ===== 加载活动 Branch 消息 =====

  /**
   * 加载当前活动 Branch 的消息路径(按 position ASC)。
   *
   * 流程:
   * 1. 读取 activeBranch
   * 2. 读取该 Branch 的 Message Links(position ASC)
   * 3. 按 messageId 读取 Message(保留 id / role / createdAt / source)
   * 4. 读取该 Branch 的 SwipeSelections
   * 5. 对有选择的 Assistant,读取对应 Candidate 并投影 content / status / errorMessage / isStreaming
   * 6. 返回新数组和新对象
   *
   * 不修改 MessageRepository 返回对象。
   * 不修改 Candidate。
   * 不记录正文。
   * Message ID / role / source / sequenceNumber 保持不变。
   *
   * @param chatId 所属 Chat ID
   * @returns 投影后的消息数组(可能为空)
   */
  async loadActiveBranchMessages(chatId: string): Promise<ChatMessage[]> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('loadActiveBranchMessages: chatId empty');
    }
    // 只读操作:不开启写事务,不创建 Root Branch
    // Active State 缺失属于数据完整性问题,返回明确错误而非空数组
    const activeBranch: ConversationBranch | null =
      await this.branchRepository.getActiveBranch(chatId);
    if (activeBranch === null) {
      throw DatabaseError.notFound('loadActiveBranchMessages: branch state missing');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const links: BranchMessageLink[] =
      await this.branchRepository.listMessageLinksWithStore(store, activeBranch.id);
    if (links.length === 0) {
      return [];
    }
    // 加载该 Branch 的 SwipeSelections
    const selections: BranchSwipeSelection[] =
      await this.branchRepository.listSwipeSelectionsWithStore(store, activeBranch.id);
    const selectionMap: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < selections.length; i++) {
      selectionMap.set(selections[i].assistantMessageId, selections[i].candidateIndex);
    }
    // 批量按 ID 查询所有消息(避免 N+1:100 条消息不再执行 100 次独立查询)
    const messageIds: string[] = links.map((l: BranchMessageLink): string => l.messageId);
    const messageMap: Map<string, ChatMessage> =
      await this.messageRepository.listByIdsWithStore(store, messageIds);

    // 按 link 顺序组装结果(保持 Branch position 顺序)
    const result: ChatMessage[] = [];
    for (let i = 0; i < links.length; i++) {
      const messageId: string = links[i].messageId;
      const message: ChatMessage | undefined = messageMap.get(messageId);
      if (message === undefined) {
        // Message 已被删除但 Link 仍存在,跳过(数据完整性问题)
        Logger.warn(LOG_TAG, 'message missing in branch path');
        continue;
      }
      // 如果是可 Swipe 的 Assistant 且有 Selection,投影 Candidate 内容
      if (isSwipeableAssistant(message) && selectionMap.has(messageId)) {
        const candidateIndex: number = selectionMap.get(messageId)!;
        const candidate: MessageSwipeCandidate | null =
          await this.swipeRepository.getCandidateWithStore(store, messageId, candidateIndex);
        if (candidate !== null) {
          const projected: ChatMessage = projectMessageWithCandidate(message, candidate);
          result.push(projected);
          continue;
        }
        // Candidate 不存在(可能被删除),回退使用 Message 本身
      }
      // 普通 Message 或无 Selection 的 Assistant:直接使用 Message
      result.push(message);
    }
    return result;
  }

  // ===== Fork Parent 解析 =====

  /**
   * 解析新 fork Branch 应挂载的 parent Branch ID。
   *
   * 背景:Branch 创建时会复制 parent 的 0..forkPosition 消息前缀,因此当前
   * Active Branch 中包含其所有祖先的前缀消息。当用户"回到以前的对话"从更早
   * 的消息 fork 时,新 Branch 语义上是从祖先分支的对话线分出,而非当前分支
   * 的子级。若仍挂到当前分支,BranchTreeLayout 的"子节点至少低一层"约束会
   * 把它压到当前分支下方,导致 Y 位置与 fork 轮次错位。
   *
   * 规则(沿祖先链自下而上):
   * - fork 消息 position > 当前分支自身 forkMessageId 的 position
   *   → fork 点在当前分支自有消息区间内 → parent = 当前分支(子级)
   * - 否则(fork 点在复制前缀内,含相同 fork 消息的再次再生)→ 上移到其 parent
   *   继续判断;Root 无复制前缀,为兜底 parent
   *
   * 该规则同时覆盖旧"同级再生"判断:fork 消息 === 当前分支 forkMessageId 时
   * 会上移一级,与旧逻辑(parent = 当前分支 parent)结果一致。
   *
   * @param chatId 所属 Chat ID
   * @param activeBranchId 当前 Active Branch ID(fork 消息所在链的起点)
   * @param forkMessageId Fork 点 Message ID(User 或 Assistant)
   * @returns 应作为新 Branch parent 的 Branch ID
   */
  async resolveForkParentBranchId(
    chatId: string,
    activeBranchId: string,
    forkMessageId: string
  ): Promise<string> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('resolveForkParentBranchId: chatId empty');
    }
    if (activeBranchId.length === 0) {
      throw DatabaseError.invalidData('resolveForkParentBranchId: activeBranchId empty');
    }
    if (forkMessageId.length === 0) {
      throw DatabaseError.invalidData('resolveForkParentBranchId: forkMessageId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return this.resolveForkParentBranchIdWithStore(store, chatId, activeBranchId, forkMessageId);
  }

  /**
   * 在给定 store 上解析 fork parent(只读,可在事务内/外调用)。
   * 数据异常(分支缺失/position 查不到)时返回当前候选,等同旧逻辑兜底。
   */
  private async resolveForkParentBranchIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    activeBranchId: string,
    forkMessageId: string
  ): Promise<string> {
    let currentId: string = activeBranchId;
    let safety: number = 0;
    while (safety < 100) {
      safety++;
      const branch: ConversationBranch | null =
        await this.branchRepository.getBranchWithStore(store, currentId);
      if (branch === null || branch.chatId !== chatId) {
        return currentId;
      }
      if (branch.isRoot) {
        return branch.id;
      }
      const currentForkMessageId: string | undefined = branch.forkMessageId;
      if (currentForkMessageId === undefined || currentForkMessageId.length === 0) {
        return branch.id;
      }
      const forkPos: number =
        await this.branchRepository.getMessagePositionWithStore(store, branch.id, forkMessageId);
      if (forkPos < 0) {
        return branch.id;
      }
      const ownerForkPos: number =
        await this.branchRepository.getMessagePositionWithStore(store, branch.id, currentForkMessageId);
      if (ownerForkPos < 0) {
        return branch.id;
      }
      if (forkPos > ownerForkPos) {
        // fork 点在当前分支自有消息区间内 → 当前分支即 parent
        return branch.id;
      }
      // fork 点在复制前缀内(或相同 fork 消息再生)→ 上移到 parent 继续判断
      const parentId: string | undefined = branch.parentBranchId;
      if (parentId === undefined || parentId.length === 0) {
        return branch.id;
      }
      currentId = parentId;
    }
    return currentId;
  }

  // ===== Fork Branch =====

  /**
   * 从指定 Branch 的某条 Message 创建 Child Branch(事务)。
   *
   * 流程:
   * 1. 验证 sourceBranch 属于 chatId
   * 2. 验证 messageId 在 sourceBranch 路径内(获取 position)
   * 3. 创建 Child Branch
   * 4. 复制 sourceBranch 中 position 0..forkPosition 的全部 Message Links
   * 5. 复制这些 messageId 对应的 SwipeSelections
   * 6. 若传入 selectedCandidateIndex:
   *    - 目标必须是 Assistant Conversation
   *    - Candidate 必须存在
   *    - 覆盖新 Branch 对该 Assistant 的选择
   * 7. 将新 Branch 设置为 Active
   * 8. 提交
   *
   * 创建后:
   * - 新 Branch 的消息路径截至目标 Message
   * - 原 Branch 后续 Message 仍完整存在
   * - 原 Branch active Candidate 选择不变
   * - 不复制 Message 实体
   * - 不复制 Candidate 实体
   * - 不删除任何数据
   *
   * @param chatId 所属 Chat ID
   * @param sourceBranchId 来源 Branch ID
   * @param messageId Fork 点 Message ID
   * @param selectedCandidateIndex 可选,覆盖新 Branch 对该 Assistant 的 Candidate 选择
   * @returns 新创建的 Child Branch
   */
  async forkAtMessage(
    chatId: string,
    sourceBranchId: string,
    messageId: string,
    selectedCandidateIndex?: number
  ): Promise<ConversationBranch> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('forkAtMessage: chatId empty');
    }
    if (sourceBranchId.length === 0) {
      throw DatabaseError.invalidData('forkAtMessage: sourceBranchId empty');
    }
    if (messageId.length === 0) {
      throw DatabaseError.invalidData('forkAtMessage: messageId empty');
    }
    if (selectedCandidateIndex !== undefined) {
      if (!Number.isInteger(selectedCandidateIndex) || selectedCandidateIndex < 0) {
        throw DatabaseError.invalidData('forkAtMessage: invalid selectedCandidateIndex');
      }
    }

    let result: ConversationBranch | null = null;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          result = await this.forkAtMessageWithStore(
            store, chatId, sourceBranchId, messageId, selectedCandidateIndex
          );
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `forkAtMessage: ${(err as Error).message}`
      );
    }
    return result!;
  }

  /**
   * 在给定 store 上执行 forkAtMessage(事务内部方法)。
   */
  async forkAtMessageWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    sourceBranchId: string,
    messageId: string,
    selectedCandidateIndex?: number
  ): Promise<ConversationBranch> {
    // 1. 验证 sourceBranch 属于 chatId
    const sourceBranch: ConversationBranch | null =
      await this.branchRepository.getBranchWithStore(store, sourceBranchId);
    if (sourceBranch === null) {
      throw DatabaseError.notFound('forkAtMessage: sourceBranch not found');
    }
    if (sourceBranch.chatId !== chatId) {
      throw DatabaseError.invalidData('forkAtMessage: sourceBranch chatId mismatch');
    }
    // 2. 验证 messageId 在 sourceBranch 路径内
    const forkPosition: number =
      await this.branchRepository.getMessagePositionWithStore(store, sourceBranchId, messageId);
    if (forkPosition < 0) {
      throw DatabaseError.notFound('forkAtMessage: messageId not in sourceBranch');
    }
    // 3. 解析 parent:回到历史消息 fork 时,fork 点可能在 source 的复制前缀内
    //    (属于祖先分支的对话线),此时新 Branch 应挂到对应祖先而非 source。
    //    links 复制来源仍为 source(消息就在 source 路径内)。
    const parentBranchId: string = await this.resolveForkParentBranchIdWithStore(
      store, chatId, sourceBranchId, messageId
    );
    // 3.1 创建 Child Branch(parent 可能为祖先分支)
    const childBranch: ConversationBranch =
      await this.branchRepository.createChildBranchWithStore(
        store, chatId, parentBranchId, messageId, ''
      );
    // 4. 复制 sourceBranch 中 position 0..forkPosition 的 Message Links
    await this.branchRepository.copyMessageLinksThroughPositionWithStore(
      store, sourceBranchId, childBranch.id, forkPosition
    );
    // 5. 读取复制的 messageIds,复制对应的 SwipeSelections
    const childLinks: BranchMessageLink[] =
      await this.branchRepository.listMessageLinksWithStore(store, childBranch.id);
    const copiedMessageIds: string[] = childLinks.map(
      (link: BranchMessageLink): string => link.messageId
    );
    await this.branchRepository.copySwipeSelectionsForMessageIdsWithStore(
      store, sourceBranchId, childBranch.id, copiedMessageIds
    );
    // 5.5 v8: 复制祖先 Branch 中 endPosition <= forkPosition 的 Memory(分叉点之前可用的)
    //        复制品标记 inheritedFromMemoryId,不删除原 Memory,继续归祖先 Branch 所有
    if (this.memoryPersistenceService !== null) {
      try {
        await this.memoryPersistenceService.copyAncestorMemoriesThroughPositionWithStore(
          store, sourceBranchId, childBranch.id, forkPosition
        );
      } catch (e) {
        // Memory 复制失败不阻塞 fork(避免影响现有 Branch 创建流程)
        Logger.warn(LOG_TAG, 'copyAncestorMemories failed: ' + String(e));
      }
    }
    // 6. 若传入 selectedCandidateIndex,覆盖新 Branch 对该 Assistant 的选择
    if (selectedCandidateIndex !== undefined) {
      // 验证目标 Message 是 Assistant Conversation
      const targetMessage: ChatMessage | null =
        await this.messageRepository.getById(messageId);
      if (targetMessage === null) {
        throw DatabaseError.notFound('forkAtMessage: target message not found');
      }
      if (!isSwipeableAssistant(targetMessage)) {
        throw DatabaseError.invalidData(
          'forkAtMessage: selectedCandidateIndex requires Assistant Conversation'
        );
      }
      // 验证 Candidate 存在
      const candidate: MessageSwipeCandidate | null =
        await this.swipeRepository.getCandidateWithStore(
          store, messageId, selectedCandidateIndex
        );
      if (candidate === null) {
        throw DatabaseError.invalidData('forkAtMessage: candidate not found');
      }
      // 覆盖新 Branch 对该 Assistant 的选择
      await this.branchRepository.upsertSwipeSelectionWithStore(
        store, childBranch.id, messageId, selectedCandidateIndex
      );
    }
    // 7. 将新 Branch 设置为 Active
    await this.branchRepository.setActiveBranchWithStore(store, chatId, childBranch.id);
    // 8. 触发 Branch 时间戳更新
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, childBranch.id, now);
    return childBranch;
  }

  // ===== Fork for Regeneration(T-6.4B-1.2) =====

  /**
   * 为"重新生成"创建新的 Conversation Branch(事务)。
   *
   * 与 forkAtMessage 的区别:
   * - forkAtMessage 用于"从此处继续",复制 0..forkPosition 的全部 links(包括 fork 位置的 Assistant)
   * - forkForRegeneration 用于"重新生成",只复制 0..forkUserPosition 的 links(不包括需要被替换的旧 Assistant)
   *   然后创建新的 Streaming Assistant Message 并 link 到新 Branch
   *
   * parentBranchId 由调用方通过 resolveForkParentBranchId 解析:
   * - fork 点在 Active Branch 自有消息区间 → parentBranchId = Active Branch(下一层 Child)
   * - fork 点在复制前缀(回到祖先对话线)→ parentBranchId = 对应祖先(与祖先的
   *   既有子分支按 fork 轮次排列,含相同 fork 消息再生的同级场景)
   *
   * 事务步骤:
   * 1. 验证 source Branch、parent Branch 和 fork Message 属于当前 Chat
   * 2. 验证 fork Message 位于 source Branch
   * 3. 验证 fork Message 为 User 角色
   * 4. 创建新的 Child Branch(parent=parentBranchId, forkMessageId=forkUserMessageId)
   * 5. 复制 source Branch 中 0..forkUserPosition 的 Message Links(不复制旧 Assistant)
   * 6. 复制这些 messageIds 的 SwipeSelections
   * 7. 插入新的 Streaming Assistant Message 到 messages 表
   * 8. 将新 Assistant Message Link 到新 Branch(position = forkUserPosition + 1)
   * 9. 更新 chat_branch_state.active_branch_id 为新 Branch
   * 10. 触发 Branch 时间戳更新
   * 11. 提交事务
   *
   * 事务失败时:
   * - 不创建半成品 Branch
   * - 不修改当前 Active Branch
   * - 不写入新 Assistant Message
   *
   * @param chatId 所属 Chat ID
   * @param sourceBranchId 来源 Branch ID(包含 fork User Message 的 Branch,通常是当前 Active Branch)
   * @param parentBranchId 新 Branch 的父 Branch ID(同级时为 sourceBranch.parentBranchId)
   * @param forkUserMessageId Fork 点 User Message ID
   * @param newAssistantMessage 新创建的 Streaming Assistant Message(由调用方构造,本方法负责持久化和 link)
   * @returns 新创建 Branch 的摘要(含 messageCount 和 isActive)
   */
  async forkForRegeneration(
    chatId: string,
    sourceBranchId: string,
    parentBranchId: string,
    forkUserMessageId: string,
    newAssistantMessage: ChatMessage
  ): Promise<ConversationBranchSummary> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('forkForRegeneration: chatId empty');
    }
    if (sourceBranchId.length === 0) {
      throw DatabaseError.invalidData('forkForRegeneration: sourceBranchId empty');
    }
    if (parentBranchId.length === 0) {
      throw DatabaseError.invalidData('forkForRegeneration: parentBranchId empty');
    }
    if (forkUserMessageId.length === 0) {
      throw DatabaseError.invalidData('forkForRegeneration: forkUserMessageId empty');
    }
    if (newAssistantMessage.id.length === 0) {
      throw DatabaseError.invalidData('forkForRegeneration: newAssistantMessage id empty');
    }

    // 事务外计算 maxSeq(避免快照隔离读到旧值)
    const maxSeq: number = await this.messageRepository.getMaxSequenceNumber(chatId);
    const assistantSeq: number = maxSeq + 1;

    let result: ConversationBranchSummary | null = null;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          result = await this.forkForRegenerationWithStore(
            store, chatId, sourceBranchId, parentBranchId,
            forkUserMessageId, newAssistantMessage, assistantSeq
          );
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `forkForRegeneration: ${(err as Error).message}`
      );
    }
    return result!;
  }

  /**
   * 在给定 store 上执行 forkForRegeneration(事务内部方法)。
   */
  async forkForRegenerationWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    sourceBranchId: string,
    parentBranchId: string,
    forkUserMessageId: string,
    newAssistantMessage: ChatMessage,
    assistantSequenceNumber: number
  ): Promise<ConversationBranchSummary> {
    // 1. 验证 source Branch 属于 chatId
    const sourceBranch: ConversationBranch | null =
      await this.branchRepository.getBranchWithStore(store, sourceBranchId);
    if (sourceBranch === null) {
      throw DatabaseError.notFound('forkForRegeneration: sourceBranch not found');
    }
    if (sourceBranch.chatId !== chatId) {
      throw DatabaseError.invalidData('forkForRegeneration: sourceBranch chatId mismatch');
    }
    // 2. 验证 parent Branch 属于 chatId
    const parentBranch: ConversationBranch | null =
      await this.branchRepository.getBranchWithStore(store, parentBranchId);
    if (parentBranch === null) {
      throw DatabaseError.notFound('forkForRegeneration: parentBranch not found');
    }
    if (parentBranch.chatId !== chatId) {
      throw DatabaseError.invalidData('forkForRegeneration: parentBranch chatId mismatch');
    }
    // 3. 验证 fork Message 位于 source Branch
    const forkUserPosition: number =
      await this.branchRepository.getMessagePositionWithStore(store, sourceBranchId, forkUserMessageId);
    if (forkUserPosition < 0) {
      throw DatabaseError.notFound('forkForRegeneration: forkUserMessage not in sourceBranch');
    }
    // 4. 验证 fork Message 为 User 角色
    const forkMessage: ChatMessage | null =
      await this.messageRepository.getById(forkUserMessageId);
    if (forkMessage === null) {
      throw DatabaseError.notFound('forkForRegeneration: forkUserMessage not found');
    }
    if (forkMessage.role !== ChatRole.User) {
      throw DatabaseError.invalidData('forkForRegeneration: forkMessage must be User role');
    }
    // 5. 创建新的 Child Branch(parent=parentBranchId, forkMessageId=forkUserMessageId)
    const newBranch: ConversationBranch =
      await this.branchRepository.createChildBranchWithStore(
        store, chatId, parentBranchId, forkUserMessageId, ''
      );
    // 6. 复制 source Branch 中 0..forkUserPosition 的 Message Links(不复制旧 Assistant)
    await this.branchRepository.copyMessageLinksThroughPositionWithStore(
      store, sourceBranchId, newBranch.id, forkUserPosition
    );
    // 7. 复制这些 messageIds 的 SwipeSelections(从 sourceBranch 到 newBranch)
    const newBranchLinks: BranchMessageLink[] =
      await this.branchRepository.listMessageLinksWithStore(store, newBranch.id);
    const copiedMessageIds: string[] = newBranchLinks.map(
      (link: BranchMessageLink): string => link.messageId
    );
    if (copiedMessageIds.length > 0) {
      await this.branchRepository.copySwipeSelectionsForMessageIdsWithStore(
        store, sourceBranchId, newBranch.id, copiedMessageIds
      );
    }
    // 7.5 复制祖先 Branch 中 endPosition <= forkUserPosition 的 Memory(分叉点之前可用的)
    //    复制品标记 inheritedFromMemoryId,不删除原 Memory,继续归祖先 Branch 所有
    //    否则重新生成创建的新 Branch 会丢失旧章节/核心/滚动记忆,导致"当前分支无记忆"
    if (this.memoryPersistenceService !== null) {
      try {
        await this.memoryPersistenceService.copyAncestorMemoriesThroughPositionWithStore(
          store, sourceBranchId, newBranch.id, forkUserPosition
        );
      } catch (e) {
        // Memory 复制失败不阻塞 fork(避免影响现有 Branch 创建流程)
        Logger.warn(LOG_TAG, 'forkForRegeneration copyAncestorMemories failed: ' + String(e));
      }
    }
    // 8. 插入新的 Streaming Assistant Message 到 messages 表
    await this.messageRepository.insertWithStore(
      store, newAssistantMessage, chatId, assistantSequenceNumber
    );
    // 9. 将新 Assistant Message Link 到新 Branch(position = forkUserPosition + 1)
    const newAssistantPosition: number = forkUserPosition + 1;
    await this.branchRepository.insertMessageLinkWithStore(
      store, newBranch.id, newAssistantMessage.id, newAssistantPosition
    );
    // 10. 更新 chat_branch_state.active_branch_id 为新 Branch
    await this.branchRepository.setActiveBranchWithStore(store, chatId, newBranch.id);
    // 11. 触发 Branch 时间戳更新
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, newBranch.id, now);
    // 返回新 Branch 摘要(包含 messageCount 和 isActive)
    const messageCount: number =
      await this.branchRepository.countMessagesWithStore(store, newBranch.id);
    return {
      id: newBranch.id,
      parentBranchId: newBranch.parentBranchId,
      forkMessageId: newBranch.forkMessageId,
      name: newBranch.name,
      isRoot: newBranch.isRoot,
      messageCount: messageCount,
      createdAt: newBranch.createdAt,
      updatedAt: now,
      lastMessageAt: now,
      isActive: true
    };
  }

  // ===== Edit User and Fork(T-6.4B-3.1) =====

  /**
   * 编辑历史 User Message 并创建新 Branch(事务)。
   *
   * 与 forkForRegeneration 的区别:
   * - forkForRegeneration: fork point = 原 User,继承原 User,只替换后面的 Assistant
   * - editUserAndForkWithAssistant: fork point = 原 User 前一条消息(anchor),
   *   不继承原 User,创建新的编辑后 User 和新 Streaming Assistant
   *
   * 单一事务步骤:
   * 1. 验证 source Branch / parent Branch 属于当前 Chat
   * 2. 验证 originalUserMessage 位于 source Branch 且 role = User
   * 3. 验证 anchorMessage 位于 source Branch 且 position = targetPosition - 1
   * 4. 创建新 Child Branch(parent=parentBranchId, forkMessageId=anchorMessageId)
   * 5. 复制 source Branch 中 0..(targetPosition-1) 的 Message Links(不含原 User 和后续)
   * 6. 复制继承范围内 messageIds 的 SwipeSelections
   * 7. 插入新的 Completed User Message 到 messages 表
   * 8. Link 新 User 到 targetPosition
   * 9. 插入新的 Streaming Assistant Message 到 messages 表
   * 10. Link 新 Assistant 到 targetPosition + 1
   * 11. 设置新 Branch 为 Active
   * 12. 触发 Branch 时间戳更新
   * 13. 提交事务
   *
   * 事务失败:不创建半成品 Branch,不修改原 User,不改变 Active Branch。
   *
   * @param chatId 所属 Chat ID
   * @param sourceBranchId 来源 Branch ID(包含原 User 的 Branch,通常是当前 Active Branch)
   * @param parentBranchId 新 Branch 的父 Branch ID(同级时为 activeBranch.parentBranchId)
   * @param originalUserMessageId 被编辑的原 User Message ID(不修改,只用于定位)
   * @param anchorMessageId fork anchor Message ID(原 User 前一条消息)
   * @param newUserMessage 编辑后的新 User Message(由调用方构造,本方法负责持久化和 link)
   * @param newAssistantMessage 新的 Streaming Assistant Message(由调用方构造)
   * @returns 新 Branch 摘要 + 新 User/Assistant Message ID + anchor 信息
   */
  async editUserAndForkWithAssistant(
    chatId: string,
    sourceBranchId: string,
    parentBranchId: string,
    originalUserMessageId: string,
    anchorMessageId: string,
    newUserMessage: ChatMessage,
    newAssistantMessage: ChatMessage
  ): Promise<EditedBranchGenerationTarget> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('editUserAndFork: chatId empty');
    }
    if (sourceBranchId.length === 0) {
      throw DatabaseError.invalidData('editUserAndFork: sourceBranchId empty');
    }
    if (parentBranchId.length === 0) {
      throw DatabaseError.invalidData('editUserAndFork: parentBranchId empty');
    }
    if (originalUserMessageId.length === 0) {
      throw DatabaseError.invalidData('editUserAndFork: originalUserMessageId empty');
    }
    if (anchorMessageId.length === 0) {
      throw DatabaseError.invalidData('editUserAndFork: anchorMessageId empty');
    }
    if (newUserMessage.id.length === 0) {
      throw DatabaseError.invalidData('editUserAndFork: newUserMessage id empty');
    }
    if (newAssistantMessage.id.length === 0) {
      throw DatabaseError.invalidData('editUserAndFork: newAssistantMessage id empty');
    }

    // 事务外计算 maxSeq(避免快照隔离读到旧值)
    const maxSeq: number = await this.messageRepository.getMaxSequenceNumber(chatId);
    const userSeq: number = maxSeq + 1;
    const assistantSeq: number = maxSeq + 2;

    let result: EditedBranchGenerationTarget | null = null;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          result = await this.editUserAndForkWithStore(
            store, chatId, sourceBranchId, parentBranchId,
            originalUserMessageId, anchorMessageId,
            newUserMessage, newAssistantMessage,
            userSeq, assistantSeq
          );
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `editUserAndFork: ${(err as Error).message}`
      );
    }
    return result!;
  }

  /**
   * 在给定 store 上执行 editUserAndForkWithAssistant(事务内部方法)。
   */
  async editUserAndForkWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    sourceBranchId: string,
    parentBranchId: string,
    originalUserMessageId: string,
    anchorMessageId: string,
    newUserMessage: ChatMessage,
    newAssistantMessage: ChatMessage,
    userSequenceNumber: number,
    assistantSequenceNumber: number
  ): Promise<EditedBranchGenerationTarget> {
    // 1. 验证 source Branch 属于 chatId
    const sourceBranch: ConversationBranch | null =
      await this.branchRepository.getBranchWithStore(store, sourceBranchId);
    if (sourceBranch === null) {
      throw DatabaseError.notFound('editUserAndFork: sourceBranch not found');
    }
    if (sourceBranch.chatId !== chatId) {
      throw DatabaseError.invalidData('editUserAndFork: sourceBranch chatId mismatch');
    }
    // 2. 验证 parent Branch 属于 chatId
    const parentBranch: ConversationBranch | null =
      await this.branchRepository.getBranchWithStore(store, parentBranchId);
    if (parentBranch === null) {
      throw DatabaseError.notFound('editUserAndFork: parentBranch not found');
    }
    if (parentBranch.chatId !== chatId) {
      throw DatabaseError.invalidData('editUserAndFork: parentBranch chatId mismatch');
    }
    // 3. 验证 originalUserMessage 位于 source Branch 且 role = User
    const targetPosition: number =
      await this.branchRepository.getMessagePositionWithStore(
        store, sourceBranchId, originalUserMessageId
      );
    if (targetPosition < 0) {
      throw DatabaseError.notFound('editUserAndFork: originalUserMessage not in sourceBranch');
    }
    const originalUserMessage: ChatMessage | null =
      await this.messageRepository.getById(originalUserMessageId);
    if (originalUserMessage === null) {
      throw DatabaseError.notFound('editUserAndFork: originalUserMessage not found');
    }
    if (originalUserMessage.role !== ChatRole.User) {
      throw DatabaseError.invalidData('editUserAndFork: originalUserMessage must be User role');
    }
    // 4. 验证 anchorMessage 位于 source Branch 且 position = targetPosition - 1
    if (targetPosition === 0) {
      throw DatabaseError.invalidData('editUserAndFork: target User has no preceding anchor');
    }
    const anchorPosition: number =
      await this.branchRepository.getMessagePositionWithStore(
        store, sourceBranchId, anchorMessageId
      );
    if (anchorPosition < 0) {
      throw DatabaseError.notFound('editUserAndFork: anchorMessage not in sourceBranch');
    }
    if (anchorPosition !== targetPosition - 1) {
      throw DatabaseError.invalidData('editUserAndFork: anchorMessage must be immediately before target User');
    }
    // 5. 创建新 Child Branch(parent=parentBranchId, forkMessageId=anchorMessageId)
    const newBranch: ConversationBranch =
      await this.branchRepository.createChildBranchWithStore(
        store, chatId, parentBranchId, anchorMessageId, ''
      );
    // 6. 复制 source Branch 中 0..(targetPosition-1) 的 Message Links
    //    即 0..anchorPosition(包含 anchor,不含原 User)
    await this.branchRepository.copyMessageLinksThroughPositionWithStore(
      store, sourceBranchId, newBranch.id, anchorPosition
    );
    // 7. 复制继承范围内 messageIds 的 SwipeSelections
    const newBranchLinks: BranchMessageLink[] =
      await this.branchRepository.listMessageLinksWithStore(store, newBranch.id);
    const copiedMessageIds: string[] = newBranchLinks.map(
      (link: BranchMessageLink): string => link.messageId
    );
    if (copiedMessageIds.length > 0) {
      await this.branchRepository.copySwipeSelectionsForMessageIdsWithStore(
        store, sourceBranchId, newBranch.id, copiedMessageIds
      );
    }
    // 8. 插入新的 Completed User Message 到 messages 表
    await this.messageRepository.insertWithStore(
      store, newUserMessage, chatId, userSequenceNumber
    );
    // 9. Link 新 User 到 targetPosition
    await this.branchRepository.insertMessageLinkWithStore(
      store, newBranch.id, newUserMessage.id, targetPosition
    );
    // 10. 插入新的 Streaming Assistant Message 到 messages 表
    await this.messageRepository.insertWithStore(
      store, newAssistantMessage, chatId, assistantSequenceNumber
    );
    // 11. Link 新 Assistant 到 targetPosition + 1
    await this.branchRepository.insertMessageLinkWithStore(
      store, newBranch.id, newAssistantMessage.id, targetPosition + 1
    );
    // 12. 设置新 Branch 为 Active
    await this.branchRepository.setActiveBranchWithStore(store, chatId, newBranch.id);
    // 13. 触发 Branch 时间戳更新
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, newBranch.id, now);
    return {
      newBranchId: newBranch.id,
      newUserMessageId: newUserMessage.id,
      newAssistantMessageId: newAssistantMessage.id,
      anchorMessageId: anchorMessageId,
      originalUserMessageId: originalUserMessageId,
      newBranchSummary: {
        id: newBranch.id,
        parentBranchId: newBranch.parentBranchId,
        forkMessageId: newBranch.forkMessageId,
        name: newBranch.name,
        isRoot: newBranch.isRoot,
        messageCount: targetPosition + 2,
        createdAt: newBranch.createdAt,
        updatedAt: now,
        lastMessageAt: now,
        isActive: true
      }
    };
  }

  // ===== BranchMap Display Info(T-6.4B-1.2) =====

  /**
   * 加载指定 Chat 的全部 BranchMapDisplayInfo。
   *
   * 为每个 Branch 派生:
   * - fork User Message 短预览(非 Root)
   * - 分歧 Assistant Message 短预览
   * - fork 轮次序号
   *
   * 派生策略:
   * - Root:forkUserPreview 为空;firstDivergentAssistantPreview 为 Branch 中第一条 Assistant 消息
   * - 非 Root:forkUserPreview 为 fork User 消息内容;firstDivergentAssistantPreview 为 fork 位置之后的第一条 Assistant 消息
   * - forkTurnNumber = fork 位置及之前的 User 消息数(从 1 开始)
   *
   * 不修改 Schema。
   * 不存储完整正文(预览已截断)。
   * 不记录正文 / ID 到日志。
   *
   * @param chatId 所属 Chat ID
   * @returns BranchMapDisplayInfo 列表(按 createdAt 升序)
   */
  async loadBranchMapDisplayInfos(chatId: string): Promise<BranchMapDisplayInfo[]> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('loadBranchMapDisplayInfos: chatId empty');
    }
    const summaries: ConversationBranchSummary[] =
      await this.branchRepository.listBranches(chatId);
    if (summaries.length === 0) {
      return [];
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const result: BranchMapDisplayInfo[] = [];
    for (let i = 0; i < summaries.length; i++) {
      const summary: ConversationBranchSummary = summaries[i];
      const links: BranchMessageLink[] =
        await this.branchRepository.listMessageLinksWithStore(store, summary.id);
      let forkUserPreview: string = '';
      let firstDivergentAssistantPreview: string = '';
      let latestMessagePreview: string = '';
      let forkTurnNumber: number = 0;
      if (summary.isRoot) {
        // Root: 找到 Branch 中第一条 Assistant 消息
        for (let j = 0; j < links.length; j++) {
          const msg: ChatMessage | null =
            await this.messageRepository.getById(links[j].messageId);
          if (msg !== null && msg.role === ChatRole.Assistant) {
            firstDivergentAssistantPreview = buildAssistantPreview(msg.content);
            break;
          }
        }
      } else {
        // 非 Root: 找到 fork User 消息和 fork 之后的第一条 Assistant
        const forkMessageId: string | undefined = summary.forkMessageId;
        if (forkMessageId !== undefined && forkMessageId.length > 0) {
          const forkMsg: ChatMessage | null =
            await this.messageRepository.getById(forkMessageId);
          if (forkMsg !== null) {
            forkUserPreview = buildUserPreview(forkMsg.content);
          }
          // 找到 fork 在当前 Branch 中的 position
          const forkPosition: number =
            await this.branchRepository.getMessagePositionWithStore(
              store, summary.id, forkMessageId
            );
          if (forkPosition >= 0) {
            // 找 fork 之后的第一条 Assistant
            for (let j = 0; j < links.length; j++) {
              if (links[j].position <= forkPosition) {
                continue;
              }
              const msg: ChatMessage | null =
                await this.messageRepository.getById(links[j].messageId);
              if (msg !== null && msg.role === ChatRole.Assistant) {
                firstDivergentAssistantPreview = buildAssistantPreview(msg.content);
                break;
              }
            }
            // 计算 forkTurnNumber = fork 位置及之前的 User 消息数
            let turnCount: number = 0;
            for (let j = 0; j < links.length; j++) {
              if (links[j].position > forkPosition) {
                break;
              }
              const msg: ChatMessage | null =
                await this.messageRepository.getById(links[j].messageId);
              if (msg !== null && msg.role === ChatRole.User) {
                turnCount++;
              }
            }
            forkTurnNumber = turnCount;
          }
        }
      }
      // 计算当前 Branch 中的 User 消息总数(用于 currentMaxTurn)
      let totalUserMessages: number = 0;
      for (let j = 0; j < links.length; j++) {
        const msg: ChatMessage | null =
          await this.messageRepository.getById(links[j].messageId);
        if (msg !== null && msg.role === ChatRole.User) {
          totalUserMessages++;
        }
      }

      // 计算最近一条消息预览(始终用于节点展示,保证分支消息随时可见)
      if (links.length > 0) {
        let lastPosition: number = -1;
        let latestMsg: ChatMessage | null = null;
        for (let j = 0; j < links.length; j++) {
          if (links[j].position > lastPosition) {
            lastPosition = links[j].position;
          }
        }
        let latestMsgId: string = '';
        for (let j = 0; j < links.length; j++) {
          if (links[j].position === lastPosition) {
            latestMsgId = links[j].messageId;
            break;
          }
        }
        if (latestMsgId.length > 0) {
          latestMsg = await this.messageRepository.getById(latestMsgId);
        }
        if (latestMsg !== null) {
          latestMessagePreview = buildAssistantPreview(latestMsg.content);
        }
      }

      result.push({
        summary: summary,
        branchId: summary.id,
        parentBranchId: summary.parentBranchId,
        forkMessageId: summary.forkMessageId,
        forkTurnNumber: forkTurnNumber,
        currentMaxTurn: totalUserMessages,
        forkUserPreview: forkUserPreview,
        firstDivergentAssistantPreview: firstDivergentAssistantPreview,
        latestMessagePreview: latestMessagePreview,
        messageCount: summary.messageCount,
        isRoot: summary.isRoot,
        isActive: summary.isActive,
        createdAt: summary.createdAt,
        nodeId: summary.id,
        isTerminal: false,
        isCurrent: summary.isActive
      });
    }
    return result;
  }

  // ===== 切换 Active Branch(T-6.4B-1) =====

  /**
   * 切换当前活动 Branch 到 targetBranchId(事务)。
   *
   * 流程:
   * 1. 验证 targetBranch 属于 chatId
   * 2. 将 chat_branch_state.active_branch_id 更新为 targetBranch
   * 3. 读取目标 Branch 的全部 SwipeSelections
   * 4. 对每条 Selection:
   *    - 读取对应 Candidate
   *    - 物化 Candidate 内容到 messages 表(覆盖 content/status/errorMessage/isStreaming/updatedAt)
   *    - 同步 message_swipe_groups.active_candidate_index
   * 5. 不修改其他 Branch 的 SwipeSelections
   * 6. 提交
   *
   * 物化失败(Candidate 缺失)时跳过该 Assistant,不中断整体切换。
   * 不复制 Message / Candidate 实体。
   * 不删除任何数据。
   *
   * @param chatId 所属 Chat ID
   * @param targetBranchId 目标 Branch ID
   */
  async switchActiveBranch(
    chatId: string,
    targetBranchId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('switchActiveBranch: chatId empty');
    }
    if (targetBranchId.length === 0) {
      throw DatabaseError.invalidData('switchActiveBranch: targetBranchId empty');
    }
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.switchActiveBranchWithStore(store, chatId, targetBranchId);
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `switchActiveBranch: ${(err as Error).message}`
      );
    }
  }

  /**
   * 在给定 store 上切换 Active Branch(事务内部方法)。
   */
  async switchActiveBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    targetBranchId: string
  ): Promise<void> {
    // 1. 验证 targetBranch 属于 chatId
    const targetBranch: ConversationBranch | null =
      await this.branchRepository.getBranchWithStore(store, targetBranchId);
    if (targetBranch === null) {
      throw DatabaseError.notFound('switchActiveBranch: target branch not found');
    }
    if (targetBranch.chatId !== chatId) {
      throw DatabaseError.invalidData('switchActiveBranch: branch chatId mismatch');
    }
    // 2. 更新 chat_branch_state
    await this.branchRepository.setActiveBranchWithStore(store, chatId, targetBranchId);
    // 3. 读取目标 Branch 的 SwipeSelections
    const selections: BranchSwipeSelection[] =
      await this.branchRepository.listSwipeSelectionsWithStore(store, targetBranchId);
    // 4. 对每条 Selection 物化 Candidate 到 messages 并同步 group active index
    const now: number = nowMillis();
    for (let i = 0; i < selections.length; i++) {
      const sel: BranchSwipeSelection = selections[i];
      const candidate: MessageSwipeCandidate | null =
        await this.swipeRepository.getCandidateWithStore(
          store, sel.assistantMessageId, sel.candidateIndex
        );
      if (candidate === null) {
        // Candidate 缺失(可能被删除),跳过该 Assistant
        Logger.warn(LOG_TAG, 'switchActiveBranch: candidate missing, skip');
        continue;
      }
      // 物化到 messages 表
      await this.materializeCandidateToMessageWithStore(
        store, sel.assistantMessageId, candidate, now
      );
      // 同步 message_swipe_groups.active_candidate_index
      try {
        await this.swipeRepository.updateGroupActiveIndexWithStore(
          store, sel.assistantMessageId, sel.candidateIndex, now
        );
      } catch (e) {
        // Group 可能不存在(消息已删除),跳过
        Logger.warn(LOG_TAG, 'switchActiveBranch: group missing, skip');
      }
    }
  }

  /**
   * 将 Candidate 内容物化到 messages 表的 Assistant 消息行(事务内部方法)。
   *
   * 与 MessageSwipePersistenceService.materializeCandidateToMessageWithStore 等价,
   * 但本服务独立实现,避免跨服务依赖。
   *
   * 只替换: content, status, errorMessage, isStreaming, updatedAt
   * 不修改: id, chatId, role, source, sequenceNumber, createdAt
   */
  private async materializeCandidateToMessageWithStore(
    store: relationalStore.RdbStore,
    assistantMessageId: string,
    candidate: MessageSwipeCandidate,
    now: number
  ): Promise<void> {
    const updateBucket: relationalStore.ValuesBucket = {};
    updateBucket[COLUMN_CONTENT] = candidate.content;
    updateBucket[COLUMN_STATUS] = candidate.status;
    updateBucket[COLUMN_ERROR_MESSAGE] = candidate.errorMessage !== undefined ? candidate.errorMessage : null;
    updateBucket[COLUMN_IS_STREAMING] = candidate.isStreaming ? 1 : 0;
    updateBucket[COLUMN_UPDATED_AT] = now;

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo('id', assistantMessageId);

    try {
      const affected: number = await store.update(updateBucket, predicates);
      if (affected === 0) {
        // Message 可能已被删除,跳过
        Logger.warn(LOG_TAG, 'materialize: message not found, skip');
      }
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('materialize');
      }
      throw DatabaseError.queryFailed(
        `materialize: ${extractCauseMessage(err)}`
      );
    }
  }

  // ===== 新消息加入 Active Branch =====

  /**
   * 将新消息追加到当前活动 Branch(事务)。
   *
   * 流程:
   * 1. 读取 activeBranch
   * 2. 获取该 Branch 最大 position + 1
   * 3. 插入 BranchMessage Link
   * 4. 更新 Branch.updatedAt / lastMessageAt
   *
   * 不检查 Message 是否已存在(由调用方负责在 ChatPersistenceService 事务中先插入 Message)。
   * 调用方应在同一事务中使用 appendMessageToActiveBranchWithStore。
   *
   * @param chatId 所属 Chat ID
   * @param messageId 待追加的 Message ID
   */
  async appendMessageToActiveBranch(
    chatId: string,
    messageId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('appendMessageToActiveBranch: chatId empty');
    }
    if (messageId.length === 0) {
      throw DatabaseError.invalidData('appendMessageToActiveBranch: messageId empty');
    }
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.appendMessageToActiveBranchWithStore(store, chatId, messageId);
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `appendMessageToActiveBranch: ${(err as Error).message}`
      );
    }
  }

  /**
   * 在给定 store 上追加 Message 到 Active Branch(事务内部方法)。
   *
   * 注意:HarmonyOS RDB 在事务内查询读不到本事务内的写入(快照隔离),
   * 因此不能在同一事务中多次调用本方法来追加多条消息 —
   * 第二次调用 getMaxPositionWithStore 仍返回事务前的 maxPosition,
   * 会触发 (branch_id, position) PRIMARY KEY 冲突。
   * 多条消息的原子追加请使用 appendMessagePairToActiveBranchWithStore。
   */
  async appendMessageToActiveBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    messageId: string
  ): Promise<void> {
    const activeBranch: ConversationBranch | null =
      await this.branchRepository.getActiveBranchWithStore(store, chatId);
    if (activeBranch === null) {
      throw DatabaseError.notFound('appendMessageToActiveBranch: active branch not found');
    }
    const maxPosition: number =
      await this.branchRepository.getMaxPositionWithStore(store, activeBranch.id);
    const nextPosition: number = maxPosition + 1;
    await this.branchRepository.insertMessageLinkWithStore(
      store, activeBranch.id, messageId, nextPosition
    );
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, activeBranch.id, now);
  }

  /**
   * 在给定 store 上原子追加 User + Assistant 两条 Message 到 Active Branch。
   *
   * 用于 appendUserAndStreamingAssistant 场景:
   * - 只读取一次 maxPosition(避免快照隔离导致 position 冲突)
   * - userMessage 使用 maxPosition + 1
   * - assistantMessage 使用 maxPosition + 2
   * - 只 touch 一次 Branch
   *
   * 必须在外层事务中调用,本方法不开启事务。
   */
  async appendMessagePairToActiveBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    userMessageId: string,
    assistantMessageId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('appendMessagePair: chatId empty');
    }
    if (userMessageId.length === 0) {
      throw DatabaseError.invalidData('appendMessagePair: userMessageId empty');
    }
    if (assistantMessageId.length === 0) {
      throw DatabaseError.invalidData('appendMessagePair: assistantMessageId empty');
    }
    const activeBranch: ConversationBranch | null =
      await this.branchRepository.getActiveBranchWithStore(store, chatId);
    if (activeBranch === null) {
      throw DatabaseError.notFound('appendMessagePair: active branch not found');
    }
    const maxPosition: number =
      await this.branchRepository.getMaxPositionWithStore(store, activeBranch.id);
    const userPosition: number = maxPosition + 1;
    const assistantPosition: number = maxPosition + 2;
    await this.branchRepository.insertMessageLinkWithStore(
      store, activeBranch.id, userMessageId, userPosition
    );
    await this.branchRepository.insertMessageLinkWithStore(
      store, activeBranch.id, assistantMessageId, assistantPosition
    );
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, activeBranch.id, now);
  }

  /**
   * 在给定 store 上原子地创建 Root Branch 并追加 firstMessage(position=0)。
   *
   * 用于 createSessionWithFirstMessage 场景:
   * - 避免在事务中先 ensureRootBranch 再 getActiveBranch(快照隔离可能读不到 state)
   * - 直接复用 ensureRootBranchWithStore 返回的 branch,用其 id 插入 link
   * - position 固定为 0(新 Root Branch 的第一条消息)
   *
   * 必须在外层事务中调用,本方法不开启事务。
   *
   * @returns 创建的 Root Branch
   */
  async ensureRootBranchAndAppendFirstMessageWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    firstMessageId: string
  ): Promise<ConversationBranch> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('ensureRootAndAppend: chatId empty');
    }
    if (firstMessageId.length === 0) {
      throw DatabaseError.invalidData('ensureRootAndAppend: firstMessageId empty');
    }
    const branch: ConversationBranch =
      await this.ensureRootBranchWithStore(store, chatId);
    // 直接使用刚创建/获取的 branch.id,不再查询 chat_branch_state
    await this.branchRepository.insertMessageLinkWithStore(
      store, branch.id, firstMessageId, 0
    );
    const now: number = nowMillis();
    await this.branchRepository.touchBranchWithStore(store, branch.id, now);
    return branch;
  }

  // ===== Swipe Selection 同步 =====

  /**
   * 更新当前活动 Branch 对指定 Assistant 的 Candidate 选择(事务)。
   *
   * 流程:
   * 1. 读取 activeBranch
   * 2. Upsert BranchSwipeSelection
   *
   * 不修改 message_swipe_groups.active_candidate_index(由 MessageSwipePersistenceService 物化时同步)。
   * 本方法只负责 Branch 维度的选择记录。
   *
   * @param chatId 所属 Chat ID
   * @param assistantMessageId Assistant Message ID
   * @param candidateIndex Candidate 索引(非负整数)
   */
  async updateActiveBranchSwipeSelection(
    chatId: string,
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('updateActiveBranchSwipeSelection: chatId empty');
    }
    if (assistantMessageId.length === 0) {
      throw DatabaseError.invalidData('updateActiveBranchSwipeSelection: assistantMessageId empty');
    }
    if (!Number.isInteger(candidateIndex) || candidateIndex < 0) {
      throw DatabaseError.invalidData('updateActiveBranchSwipeSelection: invalid candidateIndex');
    }
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.updateActiveBranchSwipeSelectionWithStore(
            store, chatId, assistantMessageId, candidateIndex
          );
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `updateActiveBranchSwipeSelection: ${(err as Error).message}`
      );
    }
  }

  /**
   * 在给定 store 上更新活动 Branch 的 Swipe Selection(事务内部方法)。
   */
  async updateActiveBranchSwipeSelectionWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<void> {
    const activeBranch: ConversationBranch | null =
      await this.branchRepository.getActiveBranchWithStore(store, chatId);
    if (activeBranch === null) {
      throw DatabaseError.notFound('updateActiveBranchSwipeSelection: active branch not found');
    }
    await this.branchRepository.upsertSwipeSelectionWithStore(
      store, activeBranch.id, assistantMessageId, candidateIndex
    );
  }

  // ===== 删除清理 =====

  /**
   * 删除指定 Chat 的全部 Branch 数据(事务内部方法)。
   * 删除顺序:SwipeSelections → MessageLinks → BranchState → Branches
   * 调用方应在删除 Chat 的事务中调用此方法。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    await this.branchRepository.removeByChatIdWithStore(store, chatId);
  }

  // ===== v5 完整性检查与修复 =====

  /**
   * 检查 v5 Branch 数据完整性(只读)。
   *
   * 用于诊断运行时 transaction failed 问题:
   * - 统计 Chat 总数、Root Branch 总数、Active State 总数
   * - 检测没有 Root 的 Chat
   * - 检测没有 Active State 的 Chat
   * - 检测 Root 重复的 Chat
   * - 检测 Active Branch 不属于 Chat 的情况
   *
   * 不修改任何数据。
   * 不记录 chatId / branchId 等敏感信息,只输出计数。
   */
  async checkV5Integrity(): Promise<V5IntegrityReport> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.branchRepository.checkV5IntegrityWithStore(store);
  }

  /**
   * 修复 v5 Branch 数据完整性(事务,幂等)。
   *
   * 仅在 checkV5Integrity 报告存在以下问题时调用:
   * - chatsWithoutRoot > 0
   * - chatsWithoutActiveState > 0
   *
   * 修复内容:
   * - 为没有 Root 的 Chat 创建 Root Branch + Active State
   * - 为没有 Active State 但有 Root 的 Chat 创建 Active State
   *
   * 不修复:
   * - 多个 Root 的 Chat(数据完整性错误,需人工处理)
   * - Active Branch 不属于 Chat 的情况(数据完整性错误)
   *
   * 不删除任何用户数据。
   * 不复制或修改 Message / Candidate。
   * 失败整体回滚。
   */
  async repairV5Integrity(): Promise<V5RepairResult> {
    let created: number = 0;
    let skipped: number = 0;
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          const report: V5IntegrityReport =
            await this.branchRepository.checkV5IntegrityWithStore(store);
          if (report.chatsWithMultipleRoots > 0
            || report.chatsWithInvalidActiveBranch > 0) {
            // 数据完整性错误,不修复
            skipped = report.chatsWithoutRoot + report.chatsWithoutActiveState;
            Logger.error(LOG_TAG, 'repair skipped: data integrity error');
            return;
          }
          // 为没有 Root 的 Chat 创建 Root + Active State
          for (let i = 0; i < report.chatIdsWithoutRoot.length; i++) {
            const chatId: string = report.chatIdsWithoutRoot[i];
            await this.ensureRootBranchWithStore(store, chatId);
            created++;
          }
          // 为没有 Active State 但有 Root 的 Chat 创建 Active State
          for (let i = 0; i < report.chatIdsWithoutActiveState.length; i++) {
            const chatId: string = report.chatIdsWithoutActiveState[i];
            const root: ConversationBranch | null =
              await this.branchRepository.getRootBranchWithStore(store, chatId);
            if (root !== null) {
              await this.branchRepository.setActiveBranchWithStore(store, chatId, root.id);
              created++;
            } else {
              skipped++;
            }
          }
        },
        'v5_integrity_repair'
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `repairV5Integrity: ${(err as Error).message}`
      );
    }
    return {
      createdCount: created,
      skippedCount: skipped
    };
  }
}

/**
 * v5 修复结果。
 */
export interface V5RepairResult {
  readonly createdCount: number;
  readonly skippedCount: number;
}
