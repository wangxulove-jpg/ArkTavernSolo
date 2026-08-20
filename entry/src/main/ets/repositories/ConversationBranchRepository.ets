/**
 * ConversationBranchRepository(T-6.4A)
 *
 * 职责:
 * - conversation_branches / chat_branch_state /
 *   conversation_branch_messages / conversation_branch_swipe_selections 的 CRUD
 * - 提供 WithStore 方法供 Service 层在事务中组合调用
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
import {
  ConversationBranch,
  BranchMessageLink,
  BranchSwipeSelection,
  ConversationBranchSummary,
  ConversationRecordCounts,
  createRootBranch,
  createChildBranch,
  createBranchMessageLink,
  createBranchSwipeSelection,
  touchBranch
} from '../models/ConversationBranch';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import {
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
  COLUMN_ID,
  COLUMN_CHAT_ID,
  COLUMN_PARENT_BRANCH_ID,
  COLUMN_FORK_MESSAGE_ID,
  COLUMN_NAME,
  COLUMN_IS_ROOT,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_LAST_MESSAGE_AT,
  COLUMN_ACTIVE_BRANCH_ID,
  COLUMN_BRANCH_ID,
  COLUMN_POSITION,
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_CANDIDATE_INDEX
} from '../database/DatabaseConstants';
import {
  branchFromRow,
  branchToBucket,
  branchMessageLinkFromRow,
  branchMessageLinkToBucket,
  branchSwipeSelectionFromRow,
  branchSwipeSelectionToBucket,
  extractCauseMessage
} from './ConversationBranchRepositoryMapper';
import { isConstraintViolation } from './RepositoryMappers';

export class ConversationBranchRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  // ===== Branch 查询 =====

  async getBranch(branchId: string): Promise<ConversationBranch | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getBranchWithStore(store, branchId);
  }

  async getBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<ConversationBranch | null> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('getBranch: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCHES);
    predicates.equalTo(COLUMN_ID, branchId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return branchFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async getRootBranch(chatId: string): Promise<ConversationBranch | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getRootBranchWithStore(store, chatId);
  }

  async getRootBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ConversationBranch | null> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('getRootBranch: chatId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCHES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_IS_ROOT, 1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return branchFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async getActiveBranch(chatId: string): Promise<ConversationBranch | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getActiveBranchWithStore(store, chatId);
  }

  async getActiveBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ConversationBranch | null> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('getActiveBranch: chatId empty');
    }
    const statePredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_BRANCH_STATE);
    statePredicates.equalTo(COLUMN_CHAT_ID, chatId);
    const stateRs: relationalStore.ResultSet = await store.query(statePredicates);
    let activeBranchId: string = '';
    try {
      if (stateRs.goToFirstRow()) {
        const col: number = stateRs.getColumnIndex(COLUMN_ACTIVE_BRANCH_ID);
        if (col >= 0) {
          activeBranchId = stateRs.getString(col);
        }
      }
    } finally {
      stateRs.close();
    }
    if (activeBranchId.length === 0) {
      return null;
    }
    return await this.getBranchWithStore(store, activeBranchId);
  }

  async listBranches(chatId: string): Promise<ConversationBranchSummary[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listBranchesWithStore(store, chatId);
  }

  async listBranchesWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ConversationBranchSummary[]> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('listBranches: chatId empty');
    }
    // 查询全部 Branches
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCHES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const branches: ConversationBranch[] = [];
    try {
      while (rs.goToNextRow()) {
        branches.push(branchFromRow(rs));
      }
    } finally {
      rs.close();
    }
    // 查询 active branch
    const activeBranch: ConversationBranch | null =
      await this.getActiveBranchWithStore(store, chatId);
    const activeId: string = activeBranch !== null ? activeBranch.id : '';
    // 查询每个 Branch 的 messageCount
    const summaries: ConversationBranchSummary[] = [];
    for (let i = 0; i < branches.length; i++) {
      const count: number = await this.countMessagesWithStore(store, branches[i].id);
      summaries.push({
        id: branches[i].id,
        parentBranchId: branches[i].parentBranchId,
        forkMessageId: branches[i].forkMessageId,
        name: branches[i].name,
        isRoot: branches[i].isRoot,
        messageCount: count,
        createdAt: branches[i].createdAt,
        updatedAt: branches[i].updatedAt,
        lastMessageAt: branches[i].lastMessageAt,
        isActive: branches[i].id === activeId
      });
    }
    return summaries;
  }

  // ===== Message Links =====

  async listMessageLinks(branchId: string): Promise<BranchMessageLink[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listMessageLinksWithStore(store, branchId);
  }

  async listMessageLinksWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<BranchMessageLink[]> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('listMessageLinks: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_MESSAGES);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.orderByAsc(COLUMN_POSITION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const links: BranchMessageLink[] = [];
    try {
      while (rs.goToNextRow()) {
        links.push(branchMessageLinkFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return links;
  }

  async listMessageIds(branchId: string): Promise<string[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listMessageIdsWithStore(store, branchId);
  }

  async listMessageIdsWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<string[]> {
    const links: BranchMessageLink[] = await this.listMessageLinksWithStore(store, branchId);
    const ids: string[] = [];
    for (let i = 0; i < links.length; i++) {
      ids.push(links[i].messageId);
    }
    return ids;
  }

  async countMessages(branchId: string): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.countMessagesWithStore(store, branchId);
  }

  async countMessagesWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<number> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('countMessages: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_MESSAGES);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.rowCount;
    } finally {
      rs.close();
    }
  }

  /**
   * 获取 Branch 中指定 messageId 的 position,不存在返回 -1。
   */
  async getMessagePosition(
    branchId: string,
    messageId: string
  ): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getMessagePositionWithStore(store, branchId, messageId);
  }

  async getMessagePositionWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    messageId: string
  ): Promise<number> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('getMessagePosition: branchId empty');
    }
    if (messageId.length === 0) {
      throw DatabaseError.invalidData('getMessagePosition: messageId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_MESSAGES);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.equalTo(COLUMN_ID, messageId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return -1;
      }
      const col: number = rs.getColumnIndex(COLUMN_POSITION);
      if (col < 0) {
        return -1;
      }
      return rs.getLong(col);
    } finally {
      rs.close();
    }
  }

  /**
   * 获取 Branch 中最大 position(空 Branch 返回 -1)。
   */
  async getMaxPositionWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_MESSAGES);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.orderByDesc(COLUMN_POSITION);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return -1;
      }
      const col: number = rs.getColumnIndex(COLUMN_POSITION);
      if (col < 0) {
        return -1;
      }
      return rs.getLong(col);
    } finally {
      rs.close();
    }
  }

  // ===== Swipe Selections =====

  async getSwipeSelection(
    branchId: string,
    assistantMessageId: string
  ): Promise<BranchSwipeSelection | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getSwipeSelectionWithStore(store, branchId, assistantMessageId);
  }

  async getSwipeSelectionWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    assistantMessageId: string
  ): Promise<BranchSwipeSelection | null> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('getSwipeSelection: branchId empty');
    }
    if (assistantMessageId.length === 0) {
      throw DatabaseError.invalidData('getSwipeSelection: assistantMessageId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return branchSwipeSelectionFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async listSwipeSelections(branchId: string): Promise<BranchSwipeSelection[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.listSwipeSelectionsWithStore(store, branchId);
  }

  async listSwipeSelectionsWithStore(
    store: relationalStore.RdbStore,
    branchId: string
  ): Promise<BranchSwipeSelection[]> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('listSwipeSelections: branchId empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS);
    predicates.equalTo(COLUMN_BRANCH_ID, branchId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const selections: BranchSwipeSelection[] = [];
    try {
      while (rs.goToNextRow()) {
        selections.push(branchSwipeSelectionFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return selections;
  }

  // ===== Record Counts =====

  async getRecordCounts(chatId: string): Promise<ConversationRecordCounts> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getRecordCountsWithStore(store, chatId);
  }

  async getRecordCountsWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ConversationRecordCounts> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('getRecordCounts: chatId empty');
    }
    // 当前 Branch 消息数
    const activeBranch: ConversationBranch | null =
      await this.getActiveBranchWithStore(store, chatId);
    let currentBranchMessageCount: number = 0;
    if (activeBranch !== null) {
      currentBranchMessageCount = await this.countMessagesWithStore(store, activeBranch.id);
    }
    // Branch 总数
    const branchPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCHES);
    branchPredicates.equalTo(COLUMN_CHAT_ID, chatId);
    const branchRs: relationalStore.ResultSet = await store.query(branchPredicates);
    const totalBranchCount: number = branchRs.rowCount;
    branchRs.close();
    // 唯一 Message 数(该 Chat 在所有 Branch 中保存的唯一 Message)
    // 通过 querySql 统计 distinct message_id
    const uniqueMsgRs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(DISTINCT ${COLUMN_ID}) AS cnt FROM ${TABLE_CONVERSATION_BRANCH_MESSAGES} ` +
      `WHERE ${COLUMN_BRANCH_ID} IN (SELECT ${COLUMN_ID} FROM ${TABLE_CONVERSATION_BRANCHES} WHERE ${COLUMN_CHAT_ID} = '${chatId}')`
    );
    let totalUniqueMessageCount: number = 0;
    try {
      if (uniqueMsgRs.goToFirstRow()) {
        const col: number = uniqueMsgRs.getColumnIndex('cnt');
        if (col >= 0) {
          totalUniqueMessageCount = uniqueMsgRs.getLong(col);
        }
      }
    } finally {
      uniqueMsgRs.close();
    }
    // Candidate 总数(该 Chat 中保存的 Candidate 总数)
    const candRs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS cnt FROM message_swipe_candidates ` +
      `WHERE assistant_message_id IN (SELECT id FROM messages WHERE chat_id = '${chatId}')`
    );
    let totalSwipeCandidateCount: number = 0;
    try {
      if (candRs.goToFirstRow()) {
        const col: number = candRs.getColumnIndex('cnt');
        if (col >= 0) {
          totalSwipeCandidateCount = candRs.getLong(col);
        }
      }
    } finally {
      candRs.close();
    }
    return {
      currentBranchMessageCount: currentBranchMessageCount,
      totalUniqueMessageCount: totalUniqueMessageCount,
      totalSwipeCandidateCount: totalSwipeCandidateCount,
      totalBranchCount: totalBranchCount
    };
  }

  // ===== 事务内部方法(WithStore) =====

  /**
   * 创建 Root Branch(事务内部方法)。
   * 不检查 Chat 存在性,由调用方负责。
   */
  async createRootBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<ConversationBranch> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('createRootBranch: chatId empty');
    }
    // 检查是否已存在 Root Branch
    const existing: ConversationBranch | null =
      await this.getRootBranchWithStore(store, chatId);
    if (existing !== null) {
      return existing;
    }
    const branch: ConversationBranch = createRootBranch(chatId);
    try {
      await store.insert(TABLE_CONVERSATION_BRANCHES, branchToBucket(branch));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('createRootBranch');
      }
      throw DatabaseError.queryFailed(`createRootBranch: ${extractCauseMessage(err)}`);
    }
    return branch;
  }

  /**
   * 创建 Child Branch(事务内部方法)。
   * 不检查 parent / forkMessage 存在性,由调用方负责。
   */
  async createChildBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    parentBranchId: string,
    forkMessageId: string,
    name: string
  ): Promise<ConversationBranch> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('createChildBranch: chatId empty');
    }
    if (parentBranchId.length === 0) {
      throw DatabaseError.invalidData('createChildBranch: parentBranchId empty');
    }
    if (forkMessageId.length === 0) {
      throw DatabaseError.invalidData('createChildBranch: forkMessageId empty');
    }
    const branch: ConversationBranch = createChildBranch(chatId, parentBranchId, forkMessageId, name);
    try {
      await store.insert(TABLE_CONVERSATION_BRANCHES, branchToBucket(branch));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('createChildBranch');
      }
      throw DatabaseError.queryFailed(`createChildBranch: ${extractCauseMessage(err)}`);
    }
    return branch;
  }

  /**
   * 设置 Active Branch(事务内部方法,upsert)。
   */
  async setActiveBranchWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    branchId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('setActiveBranch: chatId empty');
    }
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('setActiveBranch: branchId empty');
    }
    const now: number = nowMillis();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_CHAT_ID] = chatId;
    bucket[COLUMN_ACTIVE_BRANCH_ID] = branchId;
    bucket[COLUMN_UPDATED_AT] = now;
    try {
      // 尝试 insert,冲突则 update
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_CHAT_BRANCH_STATE);
      predicates.equalTo(COLUMN_CHAT_ID, chatId);
      const affected: number = await store.update(bucket, predicates);
      if (affected === 0) {
        await store.insert(TABLE_CHAT_BRANCH_STATE, bucket);
      }
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('setActiveBranch');
      }
      throw DatabaseError.queryFailed(`setActiveBranch: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 插入 Message Link(事务内部方法)。
   */
  async insertMessageLinkWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    messageId: string,
    position: number
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('insertMessageLink: branchId empty');
    }
    if (messageId.length === 0) {
      throw DatabaseError.invalidData('insertMessageLink: messageId empty');
    }
    if (!Number.isInteger(position) || position < 0) {
      throw DatabaseError.invalidData('insertMessageLink: invalid position');
    }
    const link: BranchMessageLink = createBranchMessageLink(branchId, messageId, position);
    try {
      await store.insert(TABLE_CONVERSATION_BRANCH_MESSAGES, branchMessageLinkToBucket(link));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('insertMessageLink');
      }
      throw DatabaseError.queryFailed(`insertMessageLink: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 复制 sourceBranch 中 position 0 到 forkPosition(含)的全部 Message Links 到新 Branch。
   */
  async copyMessageLinksThroughPositionWithStore(
    store: relationalStore.RdbStore,
    sourceBranchId: string,
    targetBranchId: string,
    forkPosition: number
  ): Promise<void> {
    if (sourceBranchId.length === 0) {
      throw DatabaseError.invalidData('copyMessageLinks: sourceBranchId empty');
    }
    if (targetBranchId.length === 0) {
      throw DatabaseError.invalidData('copyMessageLinks: targetBranchId empty');
    }
    if (!Number.isInteger(forkPosition) || forkPosition < 0) {
      throw DatabaseError.invalidData('copyMessageLinks: invalid forkPosition');
    }
    // 查询 sourceBranch 中 position <= forkPosition 的全部 links
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_MESSAGES);
    predicates.equalTo(COLUMN_BRANCH_ID, sourceBranchId);
    predicates.lessThanOrEqualTo(COLUMN_POSITION, forkPosition);
    predicates.orderByAsc(COLUMN_POSITION);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const links: BranchMessageLink[] = [];
    try {
      while (rs.goToNextRow()) {
        links.push(branchMessageLinkFromRow(rs));
      }
    } finally {
      rs.close();
    }
    // 复制到 targetBranch(position 保持不变)
    const now: number = nowMillis();
    for (let i = 0; i < links.length; i++) {
      const newLink: BranchMessageLink = {
        branchId: targetBranchId,
        messageId: links[i].messageId,
        position: links[i].position,
        createdAt: now
      };
      try {
        await store.insert(TABLE_CONVERSATION_BRANCH_MESSAGES, branchMessageLinkToBucket(newLink));
      } catch (err) {
        if (isConstraintViolation(err)) {
          throw DatabaseError.constraintFailed('copyMessageLinks');
        }
        throw DatabaseError.queryFailed(`copyMessageLinks: ${extractCauseMessage(err)}`);
      }
    }
  }

  /**
   * 更新 Branch 的 updatedAt / lastMessageAt。
   */
  async touchBranchWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    now: number
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('touchBranch: branchId empty');
    }
    if (!Number.isFinite(now) || now < 0) {
      throw DatabaseError.invalidData('touchBranch: invalid timestamp');
    }
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_UPDATED_AT] = now;
    bucket[COLUMN_LAST_MESSAGE_AT] = now;
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCHES);
    predicates.equalTo(COLUMN_ID, branchId);
    try {
      const affected: number = await store.update(bucket, predicates);
      if (affected === 0) {
        throw DatabaseError.notFound('touchBranch: branch not found');
      }
    } catch (err) {
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.queryFailed(`touchBranch: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * Upsert Swipe Selection(事务内部方法)。
   */
  async upsertSwipeSelectionWithStore(
    store: relationalStore.RdbStore,
    branchId: string,
    assistantMessageId: string,
    candidateIndex: number
  ): Promise<void> {
    if (branchId.length === 0) {
      throw DatabaseError.invalidData('upsertSwipeSelection: branchId empty');
    }
    if (assistantMessageId.length === 0) {
      throw DatabaseError.invalidData('upsertSwipeSelection: assistantMessageId empty');
    }
    if (!Number.isInteger(candidateIndex) || candidateIndex < 0) {
      throw DatabaseError.invalidData('upsertSwipeSelection: invalid candidateIndex');
    }
    const now: number = nowMillis();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_BRANCH_ID] = branchId;
    bucket[COLUMN_SWIPE_ASSISTANT_MESSAGE_ID] = assistantMessageId;
    bucket[COLUMN_CANDIDATE_INDEX] = candidateIndex;
    bucket[COLUMN_UPDATED_AT] = now;
    try {
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS);
      predicates.equalTo(COLUMN_BRANCH_ID, branchId);
      predicates.equalTo(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID, assistantMessageId);
      const affected: number = await store.update(bucket, predicates);
      if (affected === 0) {
        await store.insert(TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS, bucket);
      }
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('upsertSwipeSelection');
      }
      throw DatabaseError.queryFailed(`upsertSwipeSelection: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 复制指定 messageIds 的 SwipeSelections 从 sourceBranch 到 targetBranch。
   */
  async copySwipeSelectionsForMessageIdsWithStore(
    store: relationalStore.RdbStore,
    sourceBranchId: string,
    targetBranchId: string,
    messageIds: string[]
  ): Promise<void> {
    if (sourceBranchId.length === 0) {
      throw DatabaseError.invalidData('copySwipeSelections: sourceBranchId empty');
    }
    if (targetBranchId.length === 0) {
      throw DatabaseError.invalidData('copySwipeSelections: targetBranchId empty');
    }
    if (messageIds.length === 0) {
      return;
    }
    // 查询 sourceBranch 的全部 SwipeSelections
    const sourceSelections: BranchSwipeSelection[] =
      await this.listSwipeSelectionsWithStore(store, sourceBranchId);
    const messageIdSet: Set<string> = new Set(messageIds);
    for (let i = 0; i < sourceSelections.length; i++) {
      const sel: BranchSwipeSelection = sourceSelections[i];
      if (messageIdSet.has(sel.assistantMessageId)) {
        await this.upsertSwipeSelectionWithStore(
          store, targetBranchId, sel.assistantMessageId, sel.candidateIndex
        );
      }
    }
  }

  /**
   * 删除指定 Chat 的全部 Branch 相关数据(事务内部方法)。
   * 删除顺序:SwipeSelections → MessageLinks → BranchState → Branches
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    if (chatId.length === 0) {
      throw DatabaseError.invalidData('removeByChatId: chatId empty');
    }
    // 查询该 Chat 的全部 branchIds
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCHES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const branchIds: string[] = [];
    try {
      while (rs.goToNextRow()) {
        const col: number = rs.getColumnIndex(COLUMN_ID);
        if (col >= 0) {
          branchIds.push(rs.getString(col));
        }
      }
    } finally {
      rs.close();
    }
    // 删除 SwipeSelections
    for (let i = 0; i < branchIds.length; i++) {
      const selPredicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS);
      selPredicates.equalTo(COLUMN_BRANCH_ID, branchIds[i]);
      await store.delete(selPredicates);
    }
    // 删除 MessageLinks
    for (let i = 0; i < branchIds.length; i++) {
      const linkPredicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCH_MESSAGES);
      linkPredicates.equalTo(COLUMN_BRANCH_ID, branchIds[i]);
      await store.delete(linkPredicates);
    }
    // 删除 BranchState
    const statePredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_BRANCH_STATE);
    statePredicates.equalTo(COLUMN_CHAT_ID, chatId);
    await store.delete(statePredicates);
    // 删除 Branches
    const branchPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCHES);
    branchPredicates.equalTo(COLUMN_CHAT_ID, chatId);
    await store.delete(branchPredicates);
  }

  // ===== v5 完整性检查 =====

  /**
   * 检查 v5 Branch 数据完整性(只读,事务内部方法)。
   *
   * 用于诊断运行时事务失败问题。不修改任何数据。
   * 只输出计数和需要修复的 chatId 列表。
   */
  async checkV5IntegrityWithStore(
    store: relationalStore.RdbStore
  ): Promise<V5IntegrityReport> {
    // 1. 检查表是否存在
    const branchTableExists: boolean = await this.tableExistsWithStore(store, TABLE_CONVERSATION_BRANCHES);
    const branchStateTableExists: boolean = await this.tableExistsWithStore(store, TABLE_CHAT_BRANCH_STATE);
    const branchMessagesTableExists: boolean = await this.tableExistsWithStore(store, TABLE_CONVERSATION_BRANCH_MESSAGES);
    const branchSwipeSelectionsTableExists: boolean = await this.tableExistsWithStore(store, TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS);

    // 2. 读取 user_version
    let userVersion: number = 0;
    try {
      const versionRs: relationalStore.ResultSet = await store.querySql('PRAGMA user_version');
      try {
        if (versionRs.goToFirstRow()) {
          const ci: number = versionRs.getColumnIndex('user_version');
          if (ci >= 0) {
            userVersion = versionRs.getLong(ci);
          }
        }
      } finally {
        versionRs.close();
      }
    } catch (e) {
      // ignore
    }

    // 如果表不存在,返回空报告
    if (!branchTableExists || !branchStateTableExists) {
      return {
        userVersion: userVersion,
        branchTableExists: branchTableExists,
        branchStateTableExists: branchStateTableExists,
        branchMessagesTableExists: branchMessagesTableExists,
        branchSwipeSelectionsTableExists: branchSwipeSelectionsTableExists,
        totalChats: 0,
        totalRootBranches: 0,
        totalActiveStates: 0,
        chatsWithoutRoot: 0,
        chatsWithoutActiveState: 0,
        chatsWithMultipleRoots: 0,
        chatsWithInvalidActiveBranch: 0,
        chatIdsWithoutRoot: [],
        chatIdsWithoutActiveState: []
      };
    }

    // 3. 查询所有 Chat ID
    const chatIds: string[] = await this.listAllChatIdsWithStore(store);

    // 4. 查询每个 Chat 的 Root Branch 数量
    const chatIdsWithoutRoot: string[] = [];
    const chatIdsWithMultipleRoots: string[] = [];
    let totalRootBranches: number = 0;
    for (let i = 0; i < chatIds.length; i++) {
      const cid: string = chatIds[i];
      const rootCount: number = await this.countRootBranchesWithStore(store, cid);
      totalRootBranches += rootCount;
      if (rootCount === 0) {
        chatIdsWithoutRoot.push(cid);
      } else if (rootCount > 1) {
        chatIdsWithMultipleRoots.push(cid);
      }
    }

    // 5. 查询每个 Chat 的 Active State
    const chatIdsWithoutActiveState: string[] = [];
    let totalActiveStates: number = 0;
    let chatsWithInvalidActiveBranch: number = 0;
    for (let i = 0; i < chatIds.length; i++) {
      const cid: string = chatIds[i];
      const activeBranchId: string | null = await this.getActiveBranchIdWithStore(store, cid);
      if (activeBranchId === null) {
        // 没有 Active State
        // 但如果该 Chat 有 Root Branch,则算作 missing active state
        const rootCount: number = await this.countRootBranchesWithStore(store, cid);
        if (rootCount > 0) {
          chatIdsWithoutActiveState.push(cid);
        }
      } else {
        totalActiveStates++;
        // 验证 Active Branch 属于该 Chat
        const branch: ConversationBranch | null = await this.getBranchWithStore(store, activeBranchId);
        if (branch === null || branch.chatId !== cid) {
          chatsWithInvalidActiveBranch++;
        }
      }
    }

    return {
      userVersion: userVersion,
      branchTableExists: branchTableExists,
      branchStateTableExists: branchStateTableExists,
      branchMessagesTableExists: branchMessagesTableExists,
      branchSwipeSelectionsTableExists: branchSwipeSelectionsTableExists,
      totalChats: chatIds.length,
      totalRootBranches: totalRootBranches,
      totalActiveStates: totalActiveStates,
      chatsWithoutRoot: chatIdsWithoutRoot.length,
      chatsWithoutActiveState: chatIdsWithoutActiveState.length,
      chatsWithMultipleRoots: chatIdsWithMultipleRoots.length,
      chatsWithInvalidActiveBranch: chatsWithInvalidActiveBranch,
      chatIdsWithoutRoot: chatIdsWithoutRoot,
      chatIdsWithoutActiveState: chatIdsWithoutActiveState
    };
  }

  /**
   * 检查表是否存在(只读)。
   */
  private async tableExistsWithStore(
    store: relationalStore.RdbStore,
    table: string
  ): Promise<boolean> {
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT name FROM sqlite_master WHERE type='table' AND name='${table}'`
      );
      try {
        return rs.goToFirstRow();
      } finally {
        rs.close();
      }
    } catch (e) {
      return false;
    }
  }

  /**
   * 查询所有 Chat ID(只读)。
   */
  private async listAllChatIdsWithStore(
    store: relationalStore.RdbStore
  ): Promise<string[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates('chats');
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const ids: string[] = [];
    try {
      while (rs.goToNextRow()) {
        const col: number = rs.getColumnIndex(COLUMN_ID);
        if (col >= 0) {
          ids.push(rs.getString(col));
        }
      }
    } finally {
      rs.close();
    }
    return ids;
  }

  /**
   * 统计指定 Chat 的 Root Branch 数量(只读)。
   */
  private async countRootBranchesWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CONVERSATION_BRANCHES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_IS_ROOT, 1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.rowCount;
    } finally {
      rs.close();
    }
  }

  /**
   * 获取指定 Chat 的 Active Branch ID(只读)。
   * 不存在返回 null。
   */
  private async getActiveBranchIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<string | null> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHAT_BRANCH_STATE);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      const col: number = rs.getColumnIndex(COLUMN_ACTIVE_BRANCH_ID);
      if (col < 0) {
        return null;
      }
      return rs.getString(col);
    } finally {
      rs.close();
    }
  }
}

/**
 * v5 完整性检查报告(Repository 层)。
 */
export interface V5IntegrityReport {
  readonly userVersion: number;
  readonly branchTableExists: boolean;
  readonly branchStateTableExists: boolean;
  readonly branchMessagesTableExists: boolean;
  readonly branchSwipeSelectionsTableExists: boolean;
  readonly totalChats: number;
  readonly totalRootBranches: number;
  readonly totalActiveStates: number;
  readonly chatsWithoutRoot: number;
  readonly chatsWithoutActiveState: number;
  readonly chatsWithMultipleRoots: number;
  readonly chatsWithInvalidActiveBranch: number;
  readonly chatIdsWithoutRoot: string[];
  readonly chatIdsWithoutActiveState: string[];
}
