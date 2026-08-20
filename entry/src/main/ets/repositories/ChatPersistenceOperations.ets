/**
 * ChatPersistenceOperations
 *
 * 职责:
 * - 提供 Chat 与 Message 的联合事务操作
 * - removeChatWithMessages: 在一个事务中同时删除 Chat 及其所有 Message
 * - 删除 Chat 时同步清理 Swipe 数据(Group + Candidates)
 * - 删除 Chat 时同步清理 Branch 数据(T-6.4A)
 * - 删除 Chat 时同步清理多人聊天角色记忆(G-MEMORY-1A)
 * - 删除 Chat 时同步清理多人角色关系记忆(G-MEMORY-AUTO-1B)
 *
 * 不负责:
 * - 单表 CRUD(见 ChatRepository / MessageRepository / MessageSwipeRepository / ConversationBranchRepository)
 * - 业务逻辑
 *
 * 规则:
 * - 使用 DbHelper.runInTransaction 保证原子性
 * - 任一步失败全部回滚
 * - 删除顺序(T-6.4A / G-MEMORY-1A / G-MEMORY-AUTO-1B):
 *   1. conversation_branch_swipe_selections(通过 BranchPersistenceService)
 *   2. conversation_branch_messages
 *   3. chat_branch_state
 *   4. conversation_branches
 *   5. message_swipe_candidates(通过 MessageSwipeRepository)
 *   6. message_swipe_groups
 *   7. messages
 *   8. group_character_memories(G-MEMORY-1A 多人聊天角色记忆级联清理,幂等)
 *   9. group_character_relationship_memories(G-MEMORY-AUTO-1B 多人角色关系记忆级联清理,幂等)
 *   10. chat_participants(G-DATA-1A 多人聊天参与者,幂等)
 *   11. chats
 * - 删除不存在 Chat 时保持幂等(不抛错)
 * - 通过 WithStore 内部方法操作,避免嵌套事务
 * - branchPersistenceService 为可选参数,为 null 时跳过 Branch 清理(向后兼容旧测试)
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatRepository } from './ChatRepository';
import { MessageRepository } from './MessageRepository';
import { MessageSwipeRepository } from './MessageSwipeRepository';
import { ChatParticipantRepository } from './ChatParticipantRepository';

import { ConversationBranchPersistenceService } from '../services/ConversationBranchPersistenceService';
import { MemoryPersistenceService } from '../services/MemoryPersistenceService';
import { DatabaseError } from '../models/DatabaseError';
import { extractCauseMessage } from './RepositoryMappers';

export class ChatPersistenceOperations {
  private readonly dbHelper: DbHelper;
  private readonly chatRepository: ChatRepository;
  private readonly messageRepository: MessageRepository;
  private readonly swipeRepository: MessageSwipeRepository;
  private readonly branchPersistenceService: ConversationBranchPersistenceService | null;
  private readonly memoryPersistenceService: MemoryPersistenceService | null;
  private readonly participantRepository: ChatParticipantRepository | null;

  constructor(
    dbHelper: DbHelper,
    chatRepository: ChatRepository,
    messageRepository: MessageRepository,
    swipeRepository: MessageSwipeRepository,
    branchPersistenceService: ConversationBranchPersistenceService | null = null,
    memoryPersistenceService: MemoryPersistenceService | null = null,
    participantRepository: ChatParticipantRepository | null = null
  ) {
    this.dbHelper = dbHelper;
    this.chatRepository = chatRepository;
    this.messageRepository = messageRepository;
    this.swipeRepository = swipeRepository;
    this.branchPersistenceService = branchPersistenceService;
    this.memoryPersistenceService = memoryPersistenceService;
    this.participantRepository = participantRepository;
  }

  /**
   * 在一个事务中按顺序删除:
   * 1. conversation_branch_swipe_selections
   * 2. conversation_branch_messages
   * 3. chat_branch_state
   * 4. conversation_branches
   * 5. chat_memories(v8 长期记忆级联清理)
   * 6. message_swipe_candidates
   * 7. message_swipe_groups
   * 8. messages
   * 9. group_character_memories(G-MEMORY-1A 多人聊天角色记忆级联清理,幂等)
   * 10. group_character_relationship_memories(G-MEMORY-AUTO-1B 多人角色关系记忆级联清理,幂等)
   * 11. chat_participants(G-DATA-1A 多人聊天参与者,幂等)
   * 12. chats
   *
   * 任一步失败全部回滚。
   * 删除不存在 Chat 时保持幂等(不抛错)。
   * branchPersistenceService 为 null 时跳过 Branch 清理(步骤 1-4)。
   * memoryPersistenceService 为 null 时跳过 Memory 清理(步骤 5)。
   * groupCharacterMemoryRepository 为 null 时跳过多人角色记忆清理(步骤 9)。
   * groupCharacterRelationshipMemoryRepository 为 null 时跳过多人关系记忆清理(步骤 10)。
   * participantRepository 为 null 时跳过参与者清理(步骤 11)。
   *
   * 注意:G-MEMORY-AUTO-1B 要求"删除整个群聊时必须在同一事务中删除该群聊的全部关系记忆",
   * 不影响其他群聊中的同角色关系(因为 group_character_relationship_memories 按 group_conversation_id 隔离)。
   */
  async removeChatWithMessages(chatId: string): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 1-4. 删除 Branch 相关数据(幂等)
          if (this.branchPersistenceService !== null) {
            await this.branchPersistenceService.removeByChatIdWithStore(store, chatId);
          }
          // 5. 删除 Memory 相关数据(v8,幂等)
          if (this.memoryPersistenceService !== null) {
            await this.memoryPersistenceService.removeByChatIdWithStore(store, chatId);
          }
          // 6-7. 删除 Swipe 数据(幂等,不存在返回 0)
          await this.swipeRepository.removeByChatIdWithStore(store, chatId);
          // 8. 删除消息(幂等,不存在返回 0)
          await this.messageRepository.removeByChatIdWithStore(store, chatId);

          // 11. 删除 chat_participants(G-DATA-1A,幂等,单聊无行也安全)
          if (this.participantRepository !== null) {
            await this.participantRepository.deleteByChatIdWithStore(store, chatId);
          }
          // 12. 删除 Chat(幂等,不存在不抛错)
          await this.chatRepository.removeWithStore(store, chatId);
        }
      );
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(
        `removeChatWithMessages: ${extractCauseMessage(err)}`
      );
    }
  }
}