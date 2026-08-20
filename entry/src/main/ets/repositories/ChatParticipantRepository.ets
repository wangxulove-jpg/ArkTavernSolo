/**
 * ChatParticipantRepository
 *
 * 职责(G-DATA-1A):
 * - chat_participants 表的 CRUD 操作
 * - 提供事务内写入方法(insertManyWithStore / replaceAllWithStore / deleteByChatIdWithStore)
 * - 提供独立查询方法(listByChatId / listEnabledByChatId / countByChatId)
 * - 提供单行更新方法(updateEnabled)
 *
 * 不负责:
 * - 多人聊天业务规则(见 GroupConversationRules)
 * - 多人聊天事务编排(见 GroupConversationPersistenceService)
 * - Chat 主表操作(见 ChatRepository)
 *
 * 规则:
 * - 查询排序:speaker_order ASC
 * - 写入校验:chatId 非空、characterId 非空、speakerOrder >= 0
 * - 日志不打印完整 Chat ID / Character ID / SQL
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatParticipant } from '../models/ChatParticipant';
import { DatabaseError } from '../models/DatabaseError';
import {
  TABLE_CHAT_PARTICIPANTS,
  COLUMN_CHAT_ID,
  COLUMN_CHARACTER_ID,
  COLUMN_SPEAKER_ORDER,
  COLUMN_IS_ENABLED,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';
import { extractCauseMessage, isConstraintViolation } from './RepositoryMappers';
import { nowMillis } from '../utils/Time';

const LOG_TAG: string = 'ChatParticipantRepository';

export class ChatParticipantRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  /**
   * 在事务内批量插入参与者(不开启新事务,由调用方持有 store)。
   * - 校验每个 participant 的字段
   * - 任一插入失败抛错,由外层事务回滚
   */
  async insertManyWithStore(
    store: relationalStore.RdbStore,
    participants: ChatParticipant[]
  ): Promise<void> {
    for (let i = 0; i < participants.length; i++) {
      this.validateParticipant(participants[i]);
      try {
        await store.insert(TABLE_CHAT_PARTICIPANTS, this.participantToBucket(participants[i]));
      } catch (err) {
        if (isConstraintViolation(err)) {
          throw DatabaseError.constraintFailed('participant.insert');
        }
        throw DatabaseError.queryFailed(`participant.insert: ${extractCauseMessage(err)}`);
      }
    }
  }

  /**
   * 查询指定 Chat 的全部参与者(按 speaker_order ASC)。
   */
  async listByChatId(chatId: string): Promise<ChatParticipant[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_PARTICIPANTS);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.orderByAsc(COLUMN_SPEAKER_ORDER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: ChatParticipant[] = [];
      while (rs.goToNextRow()) {
        list.push(this.participantFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 查询指定 Chat 的启用参与者(按 speaker_order ASC)。
   */
  async listEnabledByChatId(chatId: string): Promise<ChatParticipant[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_PARTICIPANTS);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_IS_ENABLED, 1);
    predicates.orderByAsc(COLUMN_SPEAKER_ORDER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: ChatParticipant[] = [];
      while (rs.goToNextRow()) {
        list.push(this.participantFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 在事务内查询指定 Chat 的全部参与者(按 speaker_order ASC)。
   * G-MEMORY-1A: 供 GroupCharacterMemoryService 在事务内校验参与者存在。
   * 由调用方持有 store 和事务。
   */
  async listByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ChatParticipant[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_PARTICIPANTS);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.orderByAsc(COLUMN_SPEAKER_ORDER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const list: ChatParticipant[] = [];
      while (rs.goToNextRow()) {
        list.push(this.participantFromRow(rs));
      }
      return list;
    } finally {
      rs.close();
    }
  }

  /**
   * 在事务内替换指定 Chat 的全部参与者(删除旧行后重新写入)。
   * - 用于 replaceParticipantOrder(角色集合不变,仅调整顺序)
   * - 由调用方持有 store 和事务
   * - 任一步失败抛错,由外层事务回滚
   */
  async replaceAllWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    participants: ChatParticipant[]
  ): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    // 1. 删除该 Chat 的全部 participant 行
    const delPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_PARTICIPANTS);
    delPredicates.equalTo(COLUMN_CHAT_ID, chatId);
    try {
      await store.delete(delPredicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`participant.replaceAll.delete: ${extractCauseMessage(err)}`);
    }
    // 2. 按新顺序写入
    await this.insertManyWithStore(store, participants);
  }

  /**
   * 更新单个参与者的启用状态。
   * - 不在事务中执行(单行更新)
   * - 不存在抛 NotFound
   */
  async updateEnabled(
    chatId: string,
    characterId: string,
    enabled: boolean
  ): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    if (characterId === '') {
      throw DatabaseError.invalidData('characterId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_IS_ENABLED] = enabled ? 1 : 0;
    bucket[COLUMN_UPDATED_AT] = nowMillis();

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_PARTICIPANTS);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_CHARACTER_ID, characterId);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`participant.updateEnabled: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('participant.updateEnabled');
    }
  }

  /**
   * 在事务内删除指定 Chat 的全部参与者行。
   * - 由调用方持有 store 和事务
   * - 幂等:不存在返回 0,不抛错
   */
  async deleteByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_PARTICIPANTS);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`participant.deleteByChat: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 统计指定 Chat 的参与者数量。
   */
  async countByChatId(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_PARTICIPANTS);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      let count: number = 0;
      while (rs.goToNextRow()) {
        count++;
      }
      return count;
    } finally {
      rs.close();
    }
  }

  private participantToBucket(p: ChatParticipant): relationalStore.ValuesBucket {
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_CHAT_ID] = p.chatId;
    bucket[COLUMN_CHARACTER_ID] = p.characterId;
    bucket[COLUMN_SPEAKER_ORDER] = p.speakerOrder;
    bucket[COLUMN_IS_ENABLED] = p.isEnabled ? 1 : 0;
    bucket[COLUMN_CREATED_AT] = p.createdAt;
    bucket[COLUMN_UPDATED_AT] = p.updatedAt;
    return bucket;
  }

  private participantFromRow(rs: relationalStore.ResultSet): ChatParticipant {
    return {
      chatId: rs.getString(rs.getColumnIndex(COLUMN_CHAT_ID)),
      characterId: rs.getString(rs.getColumnIndex(COLUMN_CHARACTER_ID)),
      speakerOrder: rs.getLong(rs.getColumnIndex(COLUMN_SPEAKER_ORDER)),
      isEnabled: rs.getLong(rs.getColumnIndex(COLUMN_IS_ENABLED)) === 1,
      createdAt: rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT)),
      updatedAt: rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT))
    };
  }

  private validateParticipant(p: ChatParticipant): void {
    if (p.chatId === '') {
      throw DatabaseError.invalidData('participant.chatId empty');
    }
    if (p.characterId === '') {
      throw DatabaseError.invalidData('participant.characterId empty');
    }
    if (!Number.isFinite(p.speakerOrder) || p.speakerOrder < 0) {
      throw DatabaseError.invalidData('participant.speakerOrder invalid');
    }
  }
}
