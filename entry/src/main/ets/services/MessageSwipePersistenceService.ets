/**
 * MessageSwipePersistenceService
 *
 * 职责:
 * - 协调 messages / message_swipe_groups / message_swipe_candidates 的联合操作
 * - ensureSwipeState: 懒创建 Group + Candidate 0
 * - appendCandidate: 追加新候选,索引连续,不超过 MAX_SWIPE_CANDIDATES
 * - updateCandidate: 更新候选,当前候选同步 messages
 * - activateCandidate: 切换候选,物化到 messages
 * - removeSwipeState: 删除指定 Assistant 消息的 Swipe 数据
 *
 * 不依赖:
 * - ArkUI / ChatPage
 * - Provider / PromptBuilder / TokenCounter / HistoryTrimmer
 *
 * 日志规则:
 * - 只记录操作类型和索引
 * - 严禁记录候选内容、errorMessage、完整 ID、SQL、ValuesBucket
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { MessageRepository } from '../repositories/MessageRepository';
import { MessageSwipeRepository } from '../repositories/MessageSwipeRepository';
import { ConversationBranchPersistenceService } from './ConversationBranchPersistenceService';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  MessageSwipeState,
  MessageSwipeSummary,
  CreateSwipeCandidateOptions,
  MessageSwipeCandidateUpdates,
  MAX_SWIPE_CANDIDATES,
  createSwipeCandidate,
  updateSwipeCandidate,
  isValidCandidateIndex
} from '../models/MessageSwipe';
import { ChatMessage } from '../models/ChatMessage';
import { ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import { generateUuid } from '../utils/Uuid';
import {
  TABLE_MESSAGES,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_ERROR_MESSAGE,
  COLUMN_IS_STREAMING,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';
import { extractCauseMessage } from '../repositories/RepositoryMappers';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MessageSwipe';

/**
 * 判断消息是否可建立 Swipe。
 * 允许 role=Assistant 且 source ∈ {Conversation, CharacterFirstMessage}。
 *
 * CharacterFirstMessage 可 Swipe 的用途:
 * - 当角色有 alternate_greetings 时,first_mes 作为 Candidate 0,
 *   alternate_greetings[i] 作为 Candidate 1..N
 * - 用户可以在开场白之间切换(Swipe)
 * - 用户也可以基于当前开场白生成新的 Swipe 候选(T-6.4B-1.2 Branch 模式,
 *   由 ChatService.regenerateLastResponse / generateAlternativeCandidate 处理)
 */
function isSwipeableMessage(message: ChatMessage): boolean {
  if (message.role !== ChatRole.Assistant) {
    return false;
  }
  const source: ChatMessageSource | undefined = message.source;
  if (source === undefined) {
    return true; // 旧数据 undefined 视为 Conversation
  }
  return source === ChatMessageSource.Conversation
    || source === ChatMessageSource.CharacterFirstMessage;
}

export class MessageSwipePersistenceService {
  private readonly dbHelper: DbHelper;
  private readonly messageRepository: MessageRepository;
  private readonly swipeRepository: MessageSwipeRepository;
  private readonly branchPersistenceService: ConversationBranchPersistenceService | null;

  constructor(
    dbHelper: DbHelper,
    messageRepository: MessageRepository,
    swipeRepository: MessageSwipeRepository,
    branchPersistenceService: ConversationBranchPersistenceService | null = null
  ) {
    this.dbHelper = dbHelper;
    this.messageRepository = messageRepository;
    this.swipeRepository = swipeRepository;
    this.branchPersistenceService = branchPersistenceService;
  }

  /**
   * 查询指定 Assistant 消息的完整 Swipe 状态。
   * 不存在返回 null。
   */
  async getSwipeState(
    assistantMessageId: string
  ): Promise<MessageSwipeState | null> {
    const group: MessageSwipeGroup | null =
      await this.swipeRepository.getGroup(assistantMessageId);
    if (group === null) {
      return null;
    }
    const candidates: MessageSwipeCandidate[] =
      await this.swipeRepository.listCandidates(assistantMessageId);
    return { group: group, candidates: candidates };
  }

  /**
   * 确保指定 Assistant 消息存在 Swipe 状态。
   * 旧消息懒创建 Group + Candidate 0。
   * 重复调用幂等。
   * 使用事务和唯一约束保证数据一致性。
   */
  async ensureSwipeState(
    assistantMessageId: string
  ): Promise<MessageSwipeState> {
    const existing: MessageSwipeState | null =
      await this.getSwipeState(assistantMessageId);
    if (existing !== null) {
      return existing;
    }

    try {
      let result: MessageSwipeState | null = null;
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 事务内再次检查(防止并发创建)
          const existingGroup: MessageSwipeGroup | null =
            await this.swipeRepository.getGroupWithStore(store, assistantMessageId);
          if (existingGroup !== null) {
            const candidates: MessageSwipeCandidate[] =
              await this.swipeRepository.listCandidatesWithStore(store, assistantMessageId);
            result = { group: existingGroup, candidates: candidates };
            return;
          }

          // 查询正式 Message
          const message: ChatMessage | null =
            await this.messageRepository.getById(assistantMessageId);
          if (message === null) {
            throw DatabaseError.notFound('ensureSwipeState: message not found');
          }
          if (!isSwipeableMessage(message)) {
            throw DatabaseError.invalidData('ensureSwipeState: not swipeable');
          }

          const now: number = nowMillis();

          // 查询消息的 chatId
          const chatId: string | null =
            await this.messageRepository.getChatIdByMessageId(assistantMessageId);
          if (chatId === null) {
            throw DatabaseError.notFound('ensureSwipeState: message chatId not found');
          }

          const group: MessageSwipeGroup = {
            assistantMessageId: assistantMessageId,
            chatId: chatId,
            activeCandidateIndex: 0,
            createdAt: now,
            updatedAt: now
          };

          // 创建 Candidate 0
          const candidate0: MessageSwipeCandidate = createSwipeCandidate(
            assistantMessageId,
            0,
            {
              id: generateUuid(),
              content: message.content,
              status: message.status,
              errorMessage: message.errorMessage,
              isStreaming: message.isStreaming ?? false,
              createdAt: now
            }
          );

          await this.swipeRepository.insertGroupWithStore(store, group);
          await this.swipeRepository.insertCandidateWithStore(store, candidate0);

          // T-6.4A: 同步 BranchSwipeSelection(candidateIndex=0)到当前活动 Branch
          if (this.branchPersistenceService !== null) {
            await this.branchPersistenceService!.updateActiveBranchSwipeSelectionWithStore(
              store, chatId, assistantMessageId, 0
            );
          }

          result = { group: group, candidates: [candidate0] };
        }
      );
      return result!;
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `ensureSwipeState: ${(err as Error).message}`
      );
    }
  }

  /**
   * 追加新候选。
   * 索引自动使用 max(candidateIndex) + 1。
   * 不超过 MAX_SWIPE_CANDIDATES(含 Candidate 0)。
   * activate=true 时同时物化到 messages。
   */
  async appendCandidate(
    assistantMessageId: string,
    options: CreateSwipeCandidateOptions,
    activate: boolean
  ): Promise<MessageSwipeState> {
    // 先 ensure Group 存在
    await this.ensureSwipeState(assistantMessageId);

    try {
      let result: MessageSwipeState | null = null;
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 检查候选数量
          const currentCount: number =
            await this.swipeRepository.countCandidates(assistantMessageId);
          if (currentCount >= MAX_SWIPE_CANDIDATES) {
            throw DatabaseError.invalidData('该回复已达到候选数量上限');
          }

          // 获取当前最大 index
          const maxIndex: number =
            await this.swipeRepository.getMaxCandidateIndex(assistantMessageId);
          const newIndex: number = Math.max(0, maxIndex + 1);

          const now: number = nowMillis();
          const candidate: MessageSwipeCandidate = createSwipeCandidate(
            assistantMessageId,
            newIndex,
            {
              id: options.id,
              content: options.content,
              status: options.status,
              errorMessage: options.errorMessage,
              isStreaming: options.isStreaming,
              createdAt: options.createdAt ?? now
            }
          );

          await this.swipeRepository.insertCandidateWithStore(store, candidate);

          // 读取当前 Group(用于获取 chatId 以同步 BranchSwipeSelection)
          const currentGroup: MessageSwipeGroup | null =
            await this.swipeRepository.getGroupWithStore(store, assistantMessageId);

          if (activate) {
            // 更新 Group
            await this.swipeRepository.updateGroupActiveIndexWithStore(
              store, assistantMessageId, newIndex, now
            );

            // 物化到 messages
            await this.materializeCandidateToMessageWithStore(
              store, assistantMessageId, candidate, now
            );

            // T-6.4A: 同步 BranchSwipeSelection(newIndex)到当前活动 Branch
            if (this.branchPersistenceService !== null && currentGroup !== null) {
              await this.branchPersistenceService!.updateActiveBranchSwipeSelectionWithStore(
                store, currentGroup.chatId, assistantMessageId, newIndex
              );
            }
          }

          const group: MessageSwipeGroup =
            (await this.swipeRepository.getGroupWithStore(store, assistantMessageId))!;
          const candidates: MessageSwipeCandidate[] =
            await this.swipeRepository.listCandidatesWithStore(store, assistantMessageId);

          result = { group: group, candidates: candidates };
        }
      );
      return result!;
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `appendCandidate: ${(err as Error).message}`
      );
    }
  }

  /**
   * 更新候选。
   * 当前候选(active)同步更新 messages。
   * 非当前候选只更新 Candidate。
   */
  async updateCandidate(
    assistantMessageId: string,
    candidateIndex: number,
    updates: MessageSwipeCandidateUpdates
  ): Promise<MessageSwipeState> {
    if (!isValidCandidateIndex(candidateIndex)) {
      throw DatabaseError.invalidData('updateCandidate: candidateIndex invalid');
    }

    try {
      let result: MessageSwipeState | null = null;
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 读取当前 Candidate
          const existing: MessageSwipeCandidate | null =
            await this.swipeRepository.getCandidateWithStore(
              store, assistantMessageId, candidateIndex
            );
          if (existing === null) {
            throw DatabaseError.notFound('updateCandidate: candidate not found');
          }

          const updated: MessageSwipeCandidate = updateSwipeCandidate(existing, updates);
          await this.swipeRepository.updateCandidateWithStore(store, updated);

          // 检查是否为当前候选
          const group: MessageSwipeGroup | null =
            await this.swipeRepository.getGroupWithStore(store, assistantMessageId);
          if (group === null) {
            throw DatabaseError.notFound('updateCandidate: group not found');
          }

          if (group.activeCandidateIndex === candidateIndex) {
            const now: number = nowMillis();
            await this.materializeCandidateToMessageWithStore(
              store, assistantMessageId, updated, now
            );
          }

          const candidates: MessageSwipeCandidate[] =
            await this.swipeRepository.listCandidatesWithStore(store, assistantMessageId);

          result = { group: group, candidates: candidates };
        }
      );
      return result!;
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `updateCandidate: ${(err as Error).message}`
      );
    }
  }

  /**
   * 激活指定候选。
   * 更新 Group.activeCandidateIndex 并物化到 messages。
   */
  async activateCandidate(
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<MessageSwipeState> {
    if (!isValidCandidateIndex(candidateIndex)) {
      throw DatabaseError.invalidData('activateCandidate: candidateIndex invalid');
    }

    try {
      let result: MessageSwipeState | null = null;
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 检查 Group 存在
          const group: MessageSwipeGroup | null =
            await this.swipeRepository.getGroupWithStore(store, assistantMessageId);
          if (group === null) {
            throw DatabaseError.notFound('activateCandidate: group not found');
          }

          // 检查 Candidate 存在
          const candidate: MessageSwipeCandidate | null =
            await this.swipeRepository.getCandidateWithStore(
              store, assistantMessageId, candidateIndex
            );
          if (candidate === null) {
            throw DatabaseError.invalidData('activateCandidate: candidate not found');
          }

          const now: number = nowMillis();

          // 更新 Group
          await this.swipeRepository.updateGroupActiveIndexWithStore(
            store, assistantMessageId, candidateIndex, now
          );

          // 物化到 messages
          await this.materializeCandidateToMessageWithStore(
            store, assistantMessageId, candidate, now
          );

          // T-6.4A: 同步 BranchSwipeSelection(candidateIndex)到当前活动 Branch
          if (this.branchPersistenceService !== null) {
            await this.branchPersistenceService!.updateActiveBranchSwipeSelectionWithStore(
              store, group.chatId, assistantMessageId, candidateIndex
            );
          }

          const updatedGroup: MessageSwipeGroup =
            (await this.swipeRepository.getGroupWithStore(store, assistantMessageId))!;
          const candidates: MessageSwipeCandidate[] =
            await this.swipeRepository.listCandidatesWithStore(store, assistantMessageId);

          result = { group: updatedGroup, candidates: candidates };
        }
      );
      return result!;
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `activateCandidate: ${(err as Error).message}`
      );
    }
  }

  /**
   * 删除指定 Assistant 消息的所有 Swipe 数据。
   * 幂等。
   */
  async removeSwipeState(
    assistantMessageId: string
  ): Promise<void> {
    await this.swipeRepository.removeByAssistantMessageId(assistantMessageId);
  }

  /**
   * 获取指定 Chat 中所有消息的 Swipe 数据删除方法(供 ChatPersistenceOperations 使用)。
   */
  async removeByChatId(
    chatId: string
  ): Promise<number> {
    return await this.swipeRepository.removeByChatId(chatId);
  }

  /**
   * 在给定 store 上删除指定 Chat 的所有 Swipe 数据(供事务组合使用)。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<number> {
    return await this.swipeRepository.removeByChatIdWithStore(store, chatId);
  }

  /**
   * 批量加载指定 Chat 的 Swipe 摘要列表。
   * 只返回已有 Group 的摘要,无 Group 的旧消息由调用方合成为隐式 1/1。
   * 不返回 Candidate content 或 ID。
   */
  async listSwipeSummariesByChatId(
    chatId: string
  ): Promise<MessageSwipeSummary[]> {
    const groups: MessageSwipeGroup[] =
      await this.swipeRepository.listGroupsByChatId(chatId);
    if (groups.length === 0) {
      return [];
    }
    const messageIds: string[] = groups.map(
      (g: MessageSwipeGroup): string => g.assistantMessageId
    );
    const counts: Map<string, number> =
      await this.swipeRepository.countCandidatesForMessageIds(messageIds);

    const summaries: MessageSwipeSummary[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g: MessageSwipeGroup = groups[i];
      const count: number = counts.get(g.assistantMessageId) ?? 0;
      summaries.push({
        assistantMessageId: g.assistantMessageId,
        activeCandidateIndex: g.activeCandidateIndex,
        candidateCount: count,
        isGeneratingCandidate: false
      });
    }
    return summaries;
  }

  /**
   * 规范化中断的 Streaming Candidate。
   * 查找当前 Chat 中激活 Candidate 为 Streaming 的 Group,
   * 将其更新为 Cancelled,并同步 messages。
   *
   * 返回处理的 Candidate 数量。
   */
  async normalizeInterruptedCandidates(
    chatId: string
  ): Promise<number> {
    const groups: MessageSwipeGroup[] =
      await this.swipeRepository.listGroupsByChatId(chatId);
    if (groups.length === 0) {
      return 0;
    }

    let handledCount: number = 0;
    for (let i = 0; i < groups.length; i++) {
      const g: MessageSwipeGroup = groups[i];
      const activeCandidate: MessageSwipeCandidate | null =
        await this.swipeRepository.getCandidate(
          g.assistantMessageId, g.activeCandidateIndex
        );
      if (activeCandidate === null) {
        continue;
      }
      if (activeCandidate.status !== ChatMessageStatus.Streaming) {
        continue;
      }
      // 更新为 Cancelled
      try {
        const now: number = nowMillis();
        const updatedCandidate: MessageSwipeCandidate = updateSwipeCandidate(
          activeCandidate,
          {
            status: ChatMessageStatus.Cancelled,
            isStreaming: false
          }
        );
        // 事务中更新 Candidate 和 messages
        await this.dbHelper.runInTransaction(
          async (store: relationalStore.RdbStore): Promise<void> => {
            await this.swipeRepository.updateCandidateWithStore(store, updatedCandidate);
            await this.materializeCandidateToMessageWithStore(
              store, g.assistantMessageId, updatedCandidate, now
            );
          }
        );
        // 更新 Group 的 updatedAt
        await this.swipeRepository.updateGroupActiveIndex(
          g.assistantMessageId, g.activeCandidateIndex, now
        );
        handledCount++;
      } catch (err) {
        Logger.error(LOG_TAG, 'normalizeInterrupted failed');
      }
    }
    return handledCount;
  }

  // ===== 内部方法 =====

  /**
   * 将候选内容物化到 messages 表的 Assistant 消息行。
   * 只替换: content, status, errorMessage, isStreaming, updatedAt
   * 不修改: id, chatId, role, source, sequenceNumber, createdAt
   */
  private async materializeCandidateToMessageWithStore(
    store: relationalStore.RdbStore,
    assistantMessageId: string,
    candidate: MessageSwipeCandidate,
    now: number
  ): Promise<void> {
    // 直接构建更新 bucket,使用 DatabaseConstants 导出的列名常量
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
        throw DatabaseError.notFound('materialize: message not found');
      }
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.queryFailed(
        `materialize: ${extractCauseMessage(err)}`
      );
    }
  }
}