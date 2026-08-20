/**
 * MessageSwipeRepositoryMapper
 *
 * 职责:
 * - MessageSwipeGroup / MessageSwipeCandidate 与 ResultSet / ValuesBucket 之间的安全映射
 * - 枚举字符串的显式解析,禁止 `as` 或 `as unknown as`
 * - boolean 与 INTEGER 0/1 的安全转换
 * - 时间戳和 candidateIndex 校验
 *
 * 规则:
 * - 损坏数据统一返回 DatabaseError.InvalidData
 * - 错误中不得包含 Candidate content 或 errorMessage 原文
 * - 不修改输入对象
 */

import { relationalStore } from '@kit.ArkData';
import { ChatMessageStatus } from '../models/ChatMessage';
import { DatabaseError } from '../models/DatabaseError';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  isValidCandidateIndex,
  isValidSwipeTimestamp
} from '../models/MessageSwipe';
import {
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX,
  COLUMN_SWIPE_CANDIDATE_ID,
  COLUMN_SWIPE_CANDIDATE_INDEX,
  COLUMN_CHAT_ID,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_ERROR_MESSAGE,
  COLUMN_IS_STREAMING,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';
import {
  parseChatMessageStatus,
  chatMessageStatusToString,
  intToBoolean,
  booleanToInt,
  isValidTimestamp,
  extractCauseMessage
} from './RepositoryMappers';

// ===== Group 映射 =====

/**
 * 从 ResultSet 当前行读取 MessageSwipeGroup。
 */
export function swipeGroupFromRow(rs: relationalStore.ResultSet): MessageSwipeGroup {
  const assistantMessageId: string = rs.getString(rs.getColumnIndex(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID));
  if (assistantMessageId.length === 0) {
    throw DatabaseError.invalidData('group: assistantMessageId empty');
  }

  const chatId: string = rs.getString(rs.getColumnIndex(COLUMN_CHAT_ID));
  if (chatId.length === 0) {
    throw DatabaseError.invalidData('group: chatId empty');
  }

  const activeIndex: number = rs.getLong(rs.getColumnIndex(COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX));
  if (!isValidCandidateIndex(activeIndex)) {
    throw DatabaseError.invalidData('group: activeCandidateIndex invalid');
  }

  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidSwipeTimestamp(createdAt)) {
    throw DatabaseError.invalidData('group: createdAt invalid');
  }

  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidSwipeTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('group: updatedAt invalid');
  }

  return {
    assistantMessageId: assistantMessageId,
    chatId: chatId,
    activeCandidateIndex: activeIndex,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 构建 Group 的 ValuesBucket。
 */
export function swipeGroupToBucket(group: MessageSwipeGroup): relationalStore.ValuesBucket {
  if (group.assistantMessageId.length === 0) {
    throw DatabaseError.invalidData('group: assistantMessageId empty');
  }
  if (group.chatId.length === 0) {
    throw DatabaseError.invalidData('group: chatId empty');
  }
  if (!isValidCandidateIndex(group.activeCandidateIndex)) {
    throw DatabaseError.invalidData('group: activeCandidateIndex invalid');
  }
  if (!isValidSwipeTimestamp(group.createdAt)) {
    throw DatabaseError.invalidData('group: createdAt invalid');
  }
  if (!isValidSwipeTimestamp(group.updatedAt)) {
    throw DatabaseError.invalidData('group: updatedAt invalid');
  }

  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_SWIPE_ASSISTANT_MESSAGE_ID] = group.assistantMessageId;
  bucket[COLUMN_CHAT_ID] = group.chatId;
  bucket[COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX] = group.activeCandidateIndex;
  bucket[COLUMN_CREATED_AT] = group.createdAt;
  bucket[COLUMN_UPDATED_AT] = group.updatedAt;
  return bucket;
}

// ===== Candidate 映射 =====

/**
 * 从 ResultSet 当前行读取 MessageSwipeCandidate。
 */
export function swipeCandidateFromRow(rs: relationalStore.ResultSet): MessageSwipeCandidate {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_SWIPE_CANDIDATE_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('candidate: id empty');
  }

  const assistantMessageId: string = rs.getString(rs.getColumnIndex(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID));
  if (assistantMessageId.length === 0) {
    throw DatabaseError.invalidData('candidate: assistantMessageId empty');
  }

  const candidateIndex: number = rs.getLong(rs.getColumnIndex(COLUMN_SWIPE_CANDIDATE_INDEX));
  if (!isValidCandidateIndex(candidateIndex)) {
    throw DatabaseError.invalidData('candidate: candidateIndex invalid');
  }

  const content: string = rs.getString(rs.getColumnIndex(COLUMN_CONTENT));

  const statusStr: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  const status: ChatMessageStatus = parseChatMessageStatus(statusStr);

  const errorMessageCol: number = rs.getColumnIndex(COLUMN_ERROR_MESSAGE);
  const errorMessage: string | undefined =
    (errorMessageCol >= 0 && !rs.isColumnNull(errorMessageCol))
      ? rs.getString(errorMessageCol)
      : undefined;

  const isStreamingInt: number = rs.getLong(rs.getColumnIndex(COLUMN_IS_STREAMING));
  const isStreaming: boolean = intToBoolean(isStreamingInt);

  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidSwipeTimestamp(createdAt)) {
    throw DatabaseError.invalidData('candidate: createdAt invalid');
  }

  const updatedAtCol: number = rs.getColumnIndex(COLUMN_UPDATED_AT);
  const updatedAt: number | undefined =
    (updatedAtCol >= 0 && !rs.isColumnNull(updatedAtCol))
      ? rs.getLong(updatedAtCol)
      : undefined;

  if (updatedAt !== undefined && !isValidSwipeTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('candidate: updatedAt invalid');
  }

  return {
    id: id,
    assistantMessageId: assistantMessageId,
    candidateIndex: candidateIndex,
    content: content,
    status: status,
    errorMessage: errorMessage,
    isStreaming: isStreaming,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 构建 Candidate 的 ValuesBucket。
 */
export function swipeCandidateToBucket(
  candidate: MessageSwipeCandidate
): relationalStore.ValuesBucket {
  if (candidate.id.length === 0) {
    throw DatabaseError.invalidData('candidate: id empty');
  }
  if (candidate.assistantMessageId.length === 0) {
    throw DatabaseError.invalidData('candidate: assistantMessageId empty');
  }
  if (!isValidCandidateIndex(candidate.candidateIndex)) {
    throw DatabaseError.invalidData('candidate: candidateIndex invalid');
  }
  if (!isValidSwipeTimestamp(candidate.createdAt)) {
    throw DatabaseError.invalidData('candidate: createdAt invalid');
  }
  if (candidate.updatedAt !== undefined && !isValidSwipeTimestamp(candidate.updatedAt)) {
    throw DatabaseError.invalidData('candidate: updatedAt invalid');
  }

  // 校验 status 与 isStreaming 一致性(通过 RepositoryMappers 的 resolveIsStreaming 逻辑)
  const isStreamingInt: number = resolveSwipeIsStreaming(candidate.status, candidate.isStreaming);

  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_SWIPE_CANDIDATE_ID] = candidate.id;
  bucket[COLUMN_SWIPE_ASSISTANT_MESSAGE_ID] = candidate.assistantMessageId;
  bucket[COLUMN_SWIPE_CANDIDATE_INDEX] = candidate.candidateIndex;
  bucket[COLUMN_CONTENT] = candidate.content;
  bucket[COLUMN_STATUS] = chatMessageStatusToString(candidate.status);
  bucket[COLUMN_ERROR_MESSAGE] = candidate.errorMessage !== undefined ? candidate.errorMessage : null;
  bucket[COLUMN_IS_STREAMING] = isStreamingInt;
  bucket[COLUMN_CREATED_AT] = candidate.createdAt;
  bucket[COLUMN_UPDATED_AT] = candidate.updatedAt !== undefined ? candidate.updatedAt : null;
  return bucket;
}

/**
 * 校验 status 与 isStreaming 一致性并返回整数 isStreaming 值。
 * 与 RepositoryMappers.resolveIsStreaming 行为一致,但参数类型为 boolean(非可选)。
 */
function resolveSwipeIsStreaming(
  status: ChatMessageStatus,
  isStreaming: boolean
): number {
  const expected: boolean = status === ChatMessageStatus.Streaming;
  if (isStreaming !== expected) {
    throw DatabaseError.invalidData('status and isStreaming contradict');
  }
  return expected ? 1 : 0;
}

/**
 * 构建 Candidate 更新用的 ValuesBucket。
 * 不包含 id, assistantMessageId, candidateIndex, createdAt(这些字段不可修改)。
 */
export function swipeCandidateUpdateToBucket(
  content: string,
  status: ChatMessageStatus,
  errorMessage: string | undefined,
  isStreaming: boolean,
  updatedAt: number
): relationalStore.ValuesBucket {
  const isStreamingInt: number = resolveSwipeIsStreaming(status, isStreaming);

  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_CONTENT] = content;
  bucket[COLUMN_STATUS] = chatMessageStatusToString(status);
  bucket[COLUMN_ERROR_MESSAGE] = errorMessage !== undefined ? errorMessage : null;
  bucket[COLUMN_IS_STREAMING] = isStreamingInt;
  bucket[COLUMN_UPDATED_AT] = updatedAt;
  return bucket;
}