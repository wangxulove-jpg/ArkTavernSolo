/**
 * ChatMemory Repository(分支感知长期记忆)
 *
 * 职责:
 * - chat_memories 表的 CRUD
 * - 按 chatId / branchId 查询
 * - 事务内清理(供 ChatPersistenceOperations 调用)
 *
 * 约定:
 * - 公开方法自行 getStore,委托 WithStore
 * - WithStore 方法不调用 getStore / runInTransaction
 * - ResultSet 所有路径 finally close
 * - 不暴露通用 SQL 执行方法
 * - 不记录正文
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatMemory, createChatMemory, MemoryType } from '../models/ChatMemory';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import { generateUuid } from '../utils/Uuid';
import {
  TABLE_CHAT_MEMORIES,
  COLUMN_MEMORY_ID,
  COLUMN_MEMORY_CHAT_ID,
  COLUMN_MEMORY_BRANCH_ID,
  COLUMN_MEMORY_START_POSITION,
  COLUMN_MEMORY_END_POSITION,
  COLUMN_MEMORY_SUMMARY,
  COLUMN_MEMORY_ENABLED,
  COLUMN_MEMORY_SUMMARY_VERSION,
  COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID,
  COLUMN_UPDATED_AT,
  COLUMN_CREATED_AT,
  COLUMN_MEMORY_TYPE,
  COLUMN_MEMORY_INVALIDATED,
  COLUMN_MEMORY_TITLE,
  COLUMN_MEMORY_DETAIL,
  COLUMN_MEMORY_IMPORTANCE,
  COLUMN_MEMORY_KEYWORDS_JSON,
  COLUMN_MEMORY_SOURCE_HASH
} from '../database/DatabaseConstants';
import { memoryFromRow, memoryToBucket } from './ChatMemoryRepositoryMapper';

export class ChatMemoryRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  // ===== 查询 =====

  /**
   * 获取指定 Branch 的最新一条 Memory(endPosition 最大)。
   * 无 Memory 返回 null。
   */
  async getLatestByBranch(branchId: string): Promise<ChatMemory | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getLatestByBranchWithStore(store, branchId);
  }

  async getLatestByBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<ChatMemory | null> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('getLatestByBranch: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.orderByDesc(COLUMN_MEMORY_END_POSITION);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return memoryFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 获取指定 Branch 的全部 Memory(按 endPosition ASC)。
   */
  async listByBranch(branchId: string): Promise<ChatMemory[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listByBranchWithStore(store, branchId);
  }

  async listByBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<ChatMemory[]> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('listByBranch: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.orderByAsc(COLUMN_MEMORY_END_POSITION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const result: ChatMemory[] = [];
    try {
      while (rs.goToNextRow()) {
        result.push(memoryFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return result;
  }

  // ===== v12: 多层记忆查询 =====

  /**
   * v12: 获取指定 Branch 的有效记忆(enabled=1 且 invalidated=0,按 endPosition ASC)。
   * 失效或禁用的记忆不返回,用于 PromptBuilder 注入。
   */
  async listValidByBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<ChatMemory[]> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('listValidByBranch: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.and();
    predicates.equalTo(COLUMN_MEMORY_ENABLED, 1);
    predicates.and();
    predicates.equalTo(COLUMN_MEMORY_INVALIDATED, 0);
    predicates.orderByAsc(COLUMN_MEMORY_END_POSITION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const result: ChatMemory[] = [];
    try {
      while (rs.goToNextRow()) {
        result.push(memoryFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return result;
  }

  async listValidByBranch(branchId: string): Promise<ChatMemory[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listValidByBranchWithStore(store, branchId);
  }

  /**
   * v12: 获取指定 Branch 某类型的有效记忆(enabled=1 且 invalidated=0)。
   * 按 importance DESC, endPosition ASC 排序(高优先级在前)。
   */
  async listValidByBranchAndTypeWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    memoryType: MemoryType
  ): Promise<ChatMemory[]> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('listValidByBranchAndType: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.and();
    predicates.equalTo(COLUMN_MEMORY_TYPE, memoryType);
    predicates.and();
    predicates.equalTo(COLUMN_MEMORY_ENABLED, 1);
    predicates.and();
    predicates.equalTo(COLUMN_MEMORY_INVALIDATED, 0);
    predicates.orderByDesc(COLUMN_MEMORY_IMPORTANCE);
    predicates.orderByAsc(COLUMN_MEMORY_END_POSITION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const result: ChatMemory[] = [];
    try {
      while (rs.goToNextRow()) {
        result.push(memoryFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return result;
  }

  async listValidByBranchAndType(branchId: string, memoryType: MemoryType): Promise<ChatMemory[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listValidByBranchAndTypeWithStore(store, branchId, memoryType);
  }

  /**
   * 按 chatId 列出所有 Memory(用于级联清理时统计)。
   */
  async listByChat(chatId: string): Promise<ChatMemory[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listByChatWithStore(store, chatId);
  }

  async listByChatWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ChatMemory[]> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('listByChat: chatId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_CHAT_ID, chatId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const result: ChatMemory[] = [];
    try {
      while (rs.goToNextRow()) {
        result.push(memoryFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return result;
  }

  /**
   * 按 ID 查询 Memory。
   */
  async getById(memoryId: string): Promise<ChatMemory | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, memoryId);
  }

  async getByIdWithStore(
    store: relationalStore.RdbStore,
    memoryId: string
  ): Promise<ChatMemory | null> {
    if (memoryId.length === 0) {
      throw DatabaseError.invalidData('getById: memoryId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memoryId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return memoryFromRow(rs);
    } finally {
      rs.close();
    }
  }

  // ===== 插入 / 更新 =====

  /**
   * 插入新的 Memory 记录。
   */
  async insert(memory: ChatMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertWithStore(store, memory);
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    memory: ChatMemory
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket = memoryToBucket(memory);
    await store.insert(TABLE_CHAT_MEMORIES, bucket);
  }

  /**
   * 更新 Memory(summary / endPosition / enabled / summaryVersion / updatedAt)。
   * 不可变字段(id/chatId/branchId/startMessageId/startPosition/createdAt/inheritedFromMemoryId)保持不变。
   */
  async update(memory: ChatMemory): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.updateWithStore(store, memory);
  }

  async updateWithStore(
    store: relationalStore.RdbStore,
    memory: ChatMemory
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memory.id);
    const bucket: relationalStore.ValuesBucket = memoryToBucket(memory);
    await store.update(bucket, predicates);
  }

  /**
   * 仅更新 summary 字段(用于手动编辑摘要)。
   */
  async updateSummary(memoryId: string, newSummary: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.updateSummaryWithStore(store, memoryId, newSummary);
  }

  async updateSummaryWithStore(
    store: relationalStore.RdbStore,
    memoryId: string,
    newSummary: string
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memoryId);
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_MEMORY_SUMMARY] = newSummary;
    bucket[COLUMN_MEMORY_SUMMARY_VERSION] = Date.now(); // 简化:用时间戳保证递增
    bucket[COLUMN_UPDATED_AT] = Date.now();
    await store.update(bucket, predicates);
  }

  /**
   * 仅更新 enabled 字段。
   */
  async setEnabled(memoryId: string, enabled: boolean): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.setEnabledWithStore(store, memoryId, enabled);
  }

  async setEnabledWithStore(
    store: relationalStore.RdbStore,
    memoryId: string,
    enabled: boolean
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memoryId);
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_MEMORY_ENABLED] = enabled ? 1 : 0;
    bucket[COLUMN_UPDATED_AT] = Date.now();
    await store.update(bucket, predicates);
  }

  // ===== 删除 =====

  /**
   * 删除单条 Memory(按 ID)。
   */
  async removeById(memoryId: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.removeByIdWithStore(store, memoryId);
  }

  async removeByIdWithStore(
    store: relationalStore.RdbStore,
    memoryId: string
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_ID, memoryId);
    await store.delete(predicates);
  }

  /**
   * 按 chatId 删除所有 Memory(级联清理用)。
   * 同时清理继承关系(inheritedFromMemoryId 指向被删 Memory 的记录也会被清理,
   * 但通常继承方位于不同 Chat,不应在此调用)。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('removeByChatId: chatId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_CHAT_ID, chatId);
    await store.delete(predicates);
  }

  /**
   * 按 branchId 删除该 Branch 自产的记忆(inheritedFromMemoryId 为 null)。
   * 继承来的记忆不删除(由原 Branch 持有)。
   * 用于单独清除某 Branch 的记忆时。
   */
  async removeOwnedByBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('removeOwnedByBranch: branchId empty');
    }
    // RdbPredicates 不支持 IS NULL,需要用谓词isNull
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.and();
    predicates.isNull(COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID);
    await store.delete(predicates);
  }

  /**
   * 删除 Branch 中 endPosition >= threshold 的所有 Memory(用于编辑/切换 Swipe 后使摘要失效)。
   * 不区分继承/自产,因为失效后需要重新总结。
   * 注意:这是硬删除。v12 推荐使用 softInvalidateFromPositionWithStore 进行软失效。
   */
  async invalidateFromPositionWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    thresholdPosition: number
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('invalidateFromPosition: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.and();
    predicates.greaterThanOrEqualTo(COLUMN_MEMORY_END_POSITION, thresholdPosition);
    await store.delete(predicates);
  }

  /**
   * v12: 软失效 Branch 中 endPosition >= threshold 的所有 Memory。
   * 设置 invalidated=1,不删除数据,保留可追溯性。
   * 失效记忆不再注入 Prompt,后台按需重建。
   * 只失效当前 Branch 的记忆,不影响其他 Branch。
   */
  async softInvalidateFromPositionWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    thresholdPosition: number
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('softInvalidateFromPosition: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.and();
    predicates.greaterThanOrEqualTo(COLUMN_MEMORY_END_POSITION, thresholdPosition);
    predicates.and();
    predicates.equalTo(COLUMN_MEMORY_INVALIDATED, 0);
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_MEMORY_INVALIDATED] = 1;
    bucket[COLUMN_UPDATED_AT] = nowMillis();
    await store.update(bucket, predicates);
  }

  /**
   * 软失效"覆盖了指定消息位置"的 Memory。
   *
   * 与 softInvalidateFromPosition 的区别:
   * - 此处只失效该消息位置落在记忆覆盖范围([startPosition, endPosition])内的记忆
   * - 不误伤范围在指定位置之后的独立章节(章节是过去历史快照,不受后续剧情改变影响)
   * - 用于"重新生成/swipe 切换某条消息"时,仅失效真正受影响的记忆
   */
  async softInvalidateCoveringPositionWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    position: number
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('softInvalidateCoveringPosition: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, branchId);
    predicates.and();
    predicates.lessThanOrEqualTo(COLUMN_MEMORY_START_POSITION, position);
    predicates.and();
    predicates.greaterThanOrEqualTo(COLUMN_MEMORY_END_POSITION, position);
    predicates.and();
    predicates.equalTo(COLUMN_MEMORY_INVALIDATED, 0);
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_MEMORY_INVALIDATED] = 1;
    bucket[COLUMN_UPDATED_AT] = nowMillis();
    await store.update(bucket, predicates);
  }

  // ===== Fork 支持 =====

  /**
   * 为 fork 复制祖先 Memory 到子 Branch(标记 inheritedFromMemoryId)。
   * 只复制 endPosition <= forkPosition 且未失效的祖先 Memory(分叉点之前可用的)。
   *
   * v12 复制策略:
   * - 创建新的 Memory 记录(新 ID),branchId = childBranchId
   * - inheritedFromMemoryId = 原 Memory ID(标记继承)
   * - 保留 summary / startMessageId / endMessageId / positions / createdAt
   * - 保留 v12 字段(memoryType / title / detail / importance / keywordsJson / sourceHash)
   * - invalidated 重置为 false(子 Branch 新起点)
   * - updatedAt 设为当前时间(标记继承时间)
   * - 只复制 core / chapter / rolling 类型(不复制已失效的)
   *
   * 原 Memory 不删除,继续归祖先 Branch 所有。
   */
  async copyAncestorMemoriesThroughPositionWithStore(
    store: relationalStore.RdbStore,
    sourceBranchId: string,
    childBranchId: string,
    forkPosition: number
  ): Promise<void> {
    if (sourceBranchId.length === 0) {
      throw DatabaseError.invalidData('copyAncestorMemories: sourceBranchId empty');
    }
    if (childBranchId.length === 0) {
      throw DatabaseError.invalidData('copyAncestorMemories: childBranchId empty');
    }
    // 读取源 Branch 中 endPosition <= forkPosition 且未失效的 Memory
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_MEMORIES);
    predicates.equalTo(COLUMN_MEMORY_BRANCH_ID, sourceBranchId);
    predicates.and();
    predicates.lessThanOrEqualTo(COLUMN_MEMORY_END_POSITION, forkPosition);
    predicates.and();
    predicates.equalTo(COLUMN_MEMORY_INVALIDATED, 0);
    predicates.orderByAsc(COLUMN_MEMORY_END_POSITION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const ancestors: ChatMemory[] = [];
    try {
      while (rs.goToNextRow()) {
        ancestors.push(memoryFromRow(rs));
      }
    } finally {
      rs.close();
    }

    if (ancestors.length === 0) {
      return;
    }

    const now: number = nowMillis();
    for (let i = 0; i < ancestors.length; i++) {
      const ancestor: ChatMemory = ancestors[i];
      // 创建继承副本(新 ID),保留所有字段,invalidated 重置为 false
      const inherited: ChatMemory = {
        id: generateUuid(),
        chatId: ancestor.chatId,
        branchId: childBranchId,
        startMessageId: ancestor.startMessageId,
        endMessageId: ancestor.endMessageId,
        startPosition: ancestor.startPosition,
        endPosition: ancestor.endPosition,
        summary: ancestor.summary,
        createdAt: ancestor.createdAt,
        updatedAt: now,
        enabled: ancestor.enabled,
        summaryVersion: ancestor.summaryVersion,
        inheritedFromMemoryId: ancestor.id,
        memoryType: ancestor.memoryType,
        title: ancestor.title,
        detail: ancestor.detail,
        importance: ancestor.importance,
        keywordsJson: ancestor.keywordsJson,
        sourceHash: ancestor.sourceHash,
        invalidated: false,
        worldId: ancestor.worldId
      };
      await this.insertWithStore(store, inherited);
    }
  }
}
