/**
 * MessageSwipeRepository
 *
 * 职责:
 * - MessageSwipeGroup 和 MessageSwipeCandidate 的 CRUD 操作
 * - 提供 WithStore 内部方法供事务组合使用
 * - 候选按 candidate_index ASC 排序
 *
 * 不负责:
 * - 业务逻辑(见 MessageSwipePersistenceService)
 * - 与 messages 表协同(见 PersistenceService)
 * - 级联删除(见 ChatPersistenceOperations)
 *
 * 规则:
 * - 不暴露任意 SQL 执行接口
 * - 写入使用 ValuesBucket
 * - ResultSet 所有路径关闭
 * - 不拼接用户输入 SQL
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { DatabaseError } from '../models/DatabaseError';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  isValidCandidateIndex
} from '../models/MessageSwipe';
import {
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES,
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX,
  COLUMN_SWIPE_CANDIDATE_INDEX,
  COLUMN_CHAT_ID,
  COLUMN_SWIPE_CANDIDATE_ID,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_ERROR_MESSAGE,
  COLUMN_IS_STREAMING,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';
import {
  swipeGroupFromRow,
  swipeGroupToBucket,
  swipeCandidateFromRow,
  swipeCandidateToBucket,
  swipeCandidateUpdateToBucket
} from './MessageSwipeRepositoryMapper';
import {
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

const LOG_TAG: string = 'SwipeRepo';

export class MessageSwipeRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  // ===== Group 操作 =====

  /**
   * 查询指定 Assistant 消息的 Swipe Group。
   * 不存在返回 null。
   */
  async getGroup(
    assistantMessageId: string
  ): Promise<MessageSwipeGroup | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getGroupWithStore(store, assistantMessageId);
  }

  /**
   * 在给定 store 上查询 Group。
   */
  async getGroupWithStore(
    store: relationalStore.RdbStore,
    assistantMessageId: string
  ): Promise<MessageSwipeGroup | null> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_GROUPS);
    predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return swipeGroupFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 插入 Group。
   */
  async insertGroup(
    group: MessageSwipeGroup
  ): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertGroupWithStore(store, group);
  }

  /**
   * 在给定 store 上插入 Group。
   */
  async insertGroupWithStore(
    store: relationalStore.RdbStore,
    group: MessageSwipeGroup
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = swipeGroupToBucket(group);
    try {
      await store.insert(TABLE_MESSAGE_SWIPE_GROUPS, bucket);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('swipeGroup.insert');
      }
      throw DatabaseError.queryFailed(
        `swipeGroup.insert: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 更新 Group 的 activeCandidateIndex 和 updatedAt。
   */
  async updateGroupActiveIndex(
    assistantMessageId: string,
    activeCandidateIndex: number,
    updatedAt: number
  ): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.updateGroupActiveIndexWithStore(
      store, assistantMessageId, activeCandidateIndex, updatedAt
    );
  }

  /**
   * 在给定 store 上更新 Group 的 activeCandidateIndex 和 updatedAt。
   */
  async updateGroupActiveIndexWithStore(
    store: relationalStore.RdbStore,
    assistantMessageId: string,
    activeCandidateIndex: number,
    updatedAt: number
  ): Promise<void> {
    if (!isValidCandidateIndex(activeCandidateIndex)) {
      throw DatabaseError.invalidData('updateGroup: activeCandidateIndex invalid');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX] = activeCandidateIndex;
    bucket[COLUMN_UPDATED_AT] = updatedAt;

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_GROUPS);
    predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);

    const affected: number = await store.update(bucket, predicates);
    if (affected === 0) {
      throw DatabaseError.notFound('swipeGroup.updateActiveIndex');
    }
  }

  // ===== Candidate 操作 =====

  /**
   * 查询指定 Assistant 消息的指定索引候选。
   * 不存在返回 null。
   */
  async getCandidate(
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<MessageSwipeCandidate | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getCandidateWithStore(store, assistantMessageId, candidateIndex);
  }

  /**
   * 在给定 store 上查询 Candidate。
   */
  async getCandidateWithStore(
    store: relationalStore.RdbStore,
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<MessageSwipeCandidate | null> {
    if (!isValidCandidateIndex(candidateIndex)) {
      throw DatabaseError.invalidData('getCandidate: candidateIndex invalid');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
    predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);
    predicates.equalTo(COLUMN_SWIPE_CANDIDATE_INDEX, candidateIndex);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return swipeCandidateFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 列出指定 Assistant 消息的全部候选,按 candidate_index ASC 排序。
   */
  async listCandidates(
    assistantMessageId: string
  ): Promise<MessageSwipeCandidate[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listCandidatesWithStore(store, assistantMessageId);
  }

  /**
   * 在给定 store 上列出候选。
   */
  async listCandidatesWithStore(
    store: relationalStore.RdbStore,
    assistantMessageId: string
  ): Promise<MessageSwipeCandidate[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
    predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);
    predicates.orderByAsc(COLUMN_SWIPE_CANDIDATE_INDEX);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const candidates: MessageSwipeCandidate[] = [];
      while (rs.goToNextRow()) {
        candidates.push(swipeCandidateFromRow(rs));
      }
      return candidates;
    } finally {
      rs.close();
    }
  }

  /**
   * 统计指定 Assistant 消息的候选数量。
   */
  async countCandidates(
    assistantMessageId: string
  ): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
    predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);
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

  /**
   * 获取当前最大 candidateIndex。
   * 不存在候选时返回 -1。
   */
  async getMaxCandidateIndex(
    assistantMessageId: string
  ): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const sql: string =
      `SELECT MAX(${COLUMN_SWIPE_CANDIDATE_INDEX}) AS max_idx ` +
      `FROM ${TABLE_MESSAGE_SWIPE_CANDIDATES} ` +
      `WHERE ${COLUMN_SWIPE_ASSISTANT_MESSAGE_ID} = ?`;
    const rs: relationalStore.ResultSet =
      await store.querySql(sql, [assistantMessageId]);
    try {
      if (rs.goToFirstRow()) {
        const ci: number = rs.getColumnIndex('max_idx');
        if (ci >= 0 && !rs.isColumnNull(ci)) {
          return rs.getLong(ci);
        }
      }
      return -1;
    } finally {
      rs.close();
    }
  }

  /**
   * 插入 Candidate。
   */
  async insertCandidate(
    candidate: MessageSwipeCandidate
  ): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertCandidateWithStore(store, candidate);
  }

  /**
   * 在给定 store 上插入 Candidate。
   */
  async insertCandidateWithStore(
    store: relationalStore.RdbStore,
    candidate: MessageSwipeCandidate
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = swipeCandidateToBucket(candidate);
    try {
      await store.insert(TABLE_MESSAGE_SWIPE_CANDIDATES, bucket);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('swipeCandidate.insert');
      }
      throw DatabaseError.queryFailed(
        `swipeCandidate.insert: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 更新 Candidate 的内容、状态、isStreaming、errorMessage 和 updatedAt。
   * 通过 assistantMessageId + candidateIndex 定位。
   */
  async updateCandidate(
    candidate: MessageSwipeCandidate
  ): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.updateCandidateWithStore(store, candidate);
  }

  /**
   * 在给定 store 上更新 Candidate。
   */
  async updateCandidateWithStore(
    store: relationalStore.RdbStore,
    candidate: MessageSwipeCandidate
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = swipeCandidateUpdateToBucket(
      candidate.content,
      candidate.status,
      candidate.errorMessage,
      candidate.isStreaming,
      candidate.updatedAt ?? 0
    );

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
    predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, candidate.assistantMessageId);
    predicates.equalTo(COLUMN_SWIPE_CANDIDATE_INDEX, candidate.candidateIndex);

    const affected: number = await store.update(bucket, predicates);
    if (affected === 0) {
      throw DatabaseError.notFound('swipeCandidate.update');
    }
  }

  // ===== 批量操作 =====

  /**
   * 按 chatId 列出所有 Group。
   * 排序字段使用 assistant_message_id(该表主键)。
   * 注意:message_swipe_groups 表无 candidate_index 列,该列仅存在于
   * message_swipe_candidates 表,不能用 candidate_index 排序。
   */
  async listGroupsByChatId(chatId: string): Promise<MessageSwipeGroup[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_GROUPS);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.orderByAsc(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const groups: MessageSwipeGroup[] = [];
      while (rs.goToNextRow()) {
        groups.push(swipeGroupFromRow(rs));
      }
      return groups;
    } finally {
      rs.close();
    }
  }

  /**
   * 批量统计多个 messageId 的候选数量。
   * 返回 Map<messageId, count>。
   */
  async countCandidatesForMessageIds(
    messageIds: string[]
  ): Promise<Map<string, number>> {
    if (messageIds.length === 0) {
      return new Map();
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
    predicates.in(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, messageIds);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const counts: Map<string, number> = new Map();
    // 初始化全部为 0
    for (let i = 0; i < messageIds.length; i++) {
      counts.set(messageIds[i], 0);
    }
    try {
      while (rs.goToNextRow()) {
        const mid: string = rs.getString(
          rs.getColumnIndex(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID)
        );
        const existing: number = counts.get(mid) ?? 0;
        counts.set(mid, existing + 1);
      }
      return counts;
    } finally {
      rs.close();
    }
  }

  // ===== 删除操作 =====

  /**
   * 删除指定 Assistant 消息的所有 Swipe 数据(Group + Candidates)。
   * 幂等:不存在时返回 0。
   */
  async removeByAssistantMessageId(
    assistantMessageId: string
  ): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.removeByAssistantMessageIdWithStore(store, assistantMessageId);
  }

  /**
   * 在给定 store 上删除指定 Assistant 消息的所有 Swipe 数据。
   */
  async removeByAssistantMessageIdWithStore(
    store: relationalStore.RdbStore,
    assistantMessageId: string
  ): Promise<void> {
    // 先删 Candidates
    const candPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
    candPredicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);
    try {
      await store.delete(candPredicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `swipe.removeByMessageId.candidates: ${extractCauseMessage(err)}`
      );
    }

    // 再删 Group
    const groupPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_GROUPS);
    groupPredicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);
    try {
      await store.delete(groupPredicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `swipe.removeByMessageId.group: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 删除指定 Chat 的所有 Swipe 数据。
   * 返回删除的 Group 数量(仅用于日志)。
   * 幂等:不存在时返回 0。
   */
  async removeByChatId(
    chatId: string
  ): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.removeByChatIdWithStore(store, chatId);
  }

  /**
   * 在给定 store 上删除指定 Chat 的所有 Swipe 数据。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<number> {
    // 查询该 Chat 的所有 Group,获取 assistantMessageId 列表
    const groupPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_GROUPS);
    groupPredicates.equalTo(COLUMN_CHAT_ID, chatId);
    const groupRs: relationalStore.ResultSet = await store.query(groupPredicates);
    const messageIds: string[] = [];
    try {
      while (groupRs.goToNextRow()) {
        const mid: string = groupRs.getString(
          groupRs.getColumnIndex(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID)
        );
        messageIds.push(mid);
      }
    } finally {
      groupRs.close();
    }

    if (messageIds.length === 0) {
      return 0;
    }

    // 删除该 Chat 所有消息的 Candidates
    const candPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
    // 通过 chatId 删除:需要先查 Group 再删 Candidate
    // 更高效的方式:通过 Group 的 assistant_message_id 列表
    // 使用 RdbPredicates.in 批量删除
    const candPredicates2: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_CANDIDATES);
    candPredicates2.in(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, messageIds);
    try {
      await store.delete(candPredicates2);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `swipe.removeByChatId.candidates: ${extractCauseMessage(err)}`
      );
    }

    // 删除 Groups
    const groupDelPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_GROUPS);
    groupDelPredicates.equalTo(COLUMN_CHAT_ID, chatId);
    try {
      await store.delete(groupDelPredicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `swipe.removeByChatId.groups: ${extractCauseMessage(err)}`
      );
    }

    return messageIds.length;
  }
}