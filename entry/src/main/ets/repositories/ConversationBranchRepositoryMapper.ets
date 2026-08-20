/**
 * ConversationBranchRepositoryMapper(T-6.4A)
 *
 * 职责:
 * - ResultSet → ConversationBranch / BranchMessageLink / BranchSwipeSelection
 * - 模型 → ValuesBucket
 * - 共享工具从 RepositoryMappers 导入
 *
 * 规则:
 * - 禁止 `as` 断言
 * - 非法值抛 DatabaseError.invalidData
 * - 不记录正文
 */

import { relationalStore } from '@kit.ArkData';
import {
  ConversationBranch,
  BranchMessageLink,
  BranchSwipeSelection
} from '../models/ConversationBranch';
import { DatabaseError } from '../models/DatabaseError';
import {
  COLUMN_ID,
  COLUMN_CHAT_ID,
  COLUMN_PARENT_BRANCH_ID,
  COLUMN_FORK_MESSAGE_ID,
  COLUMN_NAME,
  COLUMN_IS_ROOT,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_LAST_MESSAGE_AT,
  COLUMN_BRANCH_ID,
  COLUMN_POSITION,
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_CANDIDATE_INDEX
} from '../database/DatabaseConstants';
import {
  booleanToInt,
  intToBoolean,
  isValidTimestamp,
  isValidSequence,
  extractCauseMessage
} from './RepositoryMappers';

/**
 * 从 ResultSet 读取 ConversationBranch(当前行)。
 */
export function branchFromRow(rs: relationalStore.ResultSet): ConversationBranch {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('branch: id empty');
  }
  const chatId: string = rs.getString(rs.getColumnIndex(COLUMN_CHAT_ID));
  if (chatId.length === 0) {
    throw DatabaseError.invalidData('branch: chatId empty');
  }
  // parent_branch_id 可空
  const parentCol: number = rs.getColumnIndex(COLUMN_PARENT_BRANCH_ID);
  const parentBranchId: string | undefined =
    (parentCol >= 0 && !rs.isColumnNull(parentCol))
      ? rs.getString(parentCol) : undefined;
  // fork_message_id 可空
  const forkCol: number = rs.getColumnIndex(COLUMN_FORK_MESSAGE_ID);
  const forkMessageId: string | undefined =
    (forkCol >= 0 && !rs.isColumnNull(forkCol))
      ? rs.getString(forkCol) : undefined;
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_NAME));
  const isRootInt: number = rs.getLong(rs.getColumnIndex(COLUMN_IS_ROOT));
  const isRoot: boolean = intToBoolean(isRootInt);
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('branch: invalid createdAt');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('branch: invalid updatedAt');
  }
  const lastMessageAt: number = rs.getLong(rs.getColumnIndex(COLUMN_LAST_MESSAGE_AT));
  if (!isValidTimestamp(lastMessageAt)) {
    throw DatabaseError.invalidData('branch: invalid lastMessageAt');
  }
  return {
    id: id,
    chatId: chatId,
    parentBranchId: parentBranchId,
    forkMessageId: forkMessageId,
    name: name,
    isRoot: isRoot,
    createdAt: createdAt,
    updatedAt: updatedAt,
    lastMessageAt: lastMessageAt
  };
}

/**
 * ConversationBranch → ValuesBucket。
 */
export function branchToBucket(branch: ConversationBranch): relationalStore.ValuesBucket {
  if (branch.id.length === 0) {
    throw DatabaseError.invalidData('branch: id empty');
  }
  if (branch.chatId.length === 0) {
    throw DatabaseError.invalidData('branch: chatId empty');
  }
  if (!isValidTimestamp(branch.createdAt)) {
    throw DatabaseError.invalidData('branch: invalid createdAt');
  }
  if (!isValidTimestamp(branch.updatedAt)) {
    throw DatabaseError.invalidData('branch: invalid updatedAt');
  }
  if (!isValidTimestamp(branch.lastMessageAt)) {
    throw DatabaseError.invalidData('branch: invalid lastMessageAt');
  }
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = branch.id;
  bucket[COLUMN_CHAT_ID] = branch.chatId;
  bucket[COLUMN_PARENT_BRANCH_ID] = branch.parentBranchId !== undefined
    ? branch.parentBranchId : null;
  bucket[COLUMN_FORK_MESSAGE_ID] = branch.forkMessageId !== undefined
    ? branch.forkMessageId : null;
  bucket[COLUMN_NAME] = branch.name;
  bucket[COLUMN_IS_ROOT] = booleanToInt(branch.isRoot);
  bucket[COLUMN_CREATED_AT] = branch.createdAt;
  bucket[COLUMN_UPDATED_AT] = branch.updatedAt;
  bucket[COLUMN_LAST_MESSAGE_AT] = branch.lastMessageAt;
  return bucket;
}

/**
 * 从 ResultSet 读取 BranchMessageLink(当前行)。
 */
export function branchMessageLinkFromRow(rs: relationalStore.ResultSet): BranchMessageLink {
  const branchId: string = rs.getString(rs.getColumnIndex(COLUMN_BRANCH_ID));
  if (branchId.length === 0) {
    throw DatabaseError.invalidData('link: branchId empty');
  }
  const messageId: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (messageId.length === 0) {
    throw DatabaseError.invalidData('link: messageId empty');
  }
  const position: number = rs.getLong(rs.getColumnIndex(COLUMN_POSITION));
  if (!isValidSequence(position)) {
    throw DatabaseError.invalidData('link: invalid position');
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('link: invalid createdAt');
  }
  return {
    branchId: branchId,
    messageId: messageId,
    position: position,
    createdAt: createdAt
  };
}

/**
 * BranchMessageLink → ValuesBucket。
 */
export function branchMessageLinkToBucket(link: BranchMessageLink): relationalStore.ValuesBucket {
  if (link.branchId.length === 0) {
    throw DatabaseError.invalidData('link: branchId empty');
  }
  if (link.messageId.length === 0) {
    throw DatabaseError.invalidData('link: messageId empty');
  }
  if (!isValidSequence(link.position)) {
    throw DatabaseError.invalidData('link: invalid position');
  }
  if (!isValidTimestamp(link.createdAt)) {
    throw DatabaseError.invalidData('link: invalid createdAt');
  }
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_BRANCH_ID] = link.branchId;
  bucket[COLUMN_ID] = link.messageId;
  bucket[COLUMN_POSITION] = link.position;
  bucket[COLUMN_CREATED_AT] = link.createdAt;
  return bucket;
}

/**
 * 从 ResultSet 读取 BranchSwipeSelection(当前行)。
 */
export function branchSwipeSelectionFromRow(rs: relationalStore.ResultSet): BranchSwipeSelection {
  const branchId: string = rs.getString(rs.getColumnIndex(COLUMN_BRANCH_ID));
  if (branchId.length === 0) {
    throw DatabaseError.invalidData('selection: branchId empty');
  }
  const assistantMessageId: string =
    rs.getString(rs.getColumnIndex(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID));
  if (assistantMessageId.length === 0) {
    throw DatabaseError.invalidData('selection: assistantMessageId empty');
  }
  const candidateIndex: number = rs.getLong(rs.getColumnIndex(COLUMN_CANDIDATE_INDEX));
  if (!isValidSequence(candidateIndex)) {
    throw DatabaseError.invalidData('selection: invalid candidateIndex');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('selection: invalid updatedAt');
  }
  return {
    branchId: branchId,
    assistantMessageId: assistantMessageId,
    candidateIndex: candidateIndex,
    updatedAt: updatedAt
  };
}

/**
 * BranchSwipeSelection → ValuesBucket。
 */
export function branchSwipeSelectionToBucket(
  sel: BranchSwipeSelection
): relationalStore.ValuesBucket {
  if (sel.branchId.length === 0) {
    throw DatabaseError.invalidData('selection: branchId empty');
  }
  if (sel.assistantMessageId.length === 0) {
    throw DatabaseError.invalidData('selection: assistantMessageId empty');
  }
  if (!isValidSequence(sel.candidateIndex)) {
    throw DatabaseError.invalidData('selection: invalid candidateIndex');
  }
  if (!isValidTimestamp(sel.updatedAt)) {
    throw DatabaseError.invalidData('selection: invalid updatedAt');
  }
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_BRANCH_ID] = sel.branchId;
  bucket[COLUMN_SWIPE_ASSISTANT_MESSAGE_ID] = sel.assistantMessageId;
  bucket[COLUMN_CANDIDATE_INDEX] = sel.candidateIndex;
  bucket[COLUMN_UPDATED_AT] = sel.updatedAt;
  return bucket;
}

export { extractCauseMessage };
