/**
 * ChatMemory Repository Mapper
 *
 * 职责:
 * - ResultSet → ChatMemory
 * - 模型 → ValuesBucket
 * - 不记录正文
 */

import { relationalStore } from '@kit.ArkData';
import { ChatMemory, MemoryType, DEFAULT_MEMORY_TYPE } from '../models/ChatMemory';
import { DatabaseError } from '../models/DatabaseError';
import {
  COLUMN_MEMORY_ID,
  COLUMN_MEMORY_CHAT_ID,
  COLUMN_MEMORY_BRANCH_ID,
  COLUMN_MEMORY_START_MESSAGE_ID,
  COLUMN_MEMORY_END_MESSAGE_ID,
  COLUMN_MEMORY_START_POSITION,
  COLUMN_MEMORY_END_POSITION,
  COLUMN_MEMORY_SUMMARY,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_MEMORY_ENABLED,
  COLUMN_MEMORY_SUMMARY_VERSION,
  COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID,
  COLUMN_MEMORY_TYPE,
  COLUMN_MEMORY_TITLE,
  COLUMN_MEMORY_DETAIL,
  COLUMN_MEMORY_IMPORTANCE,
  COLUMN_MEMORY_KEYWORDS_JSON,
  COLUMN_MEMORY_SOURCE_HASH,
  COLUMN_MEMORY_INVALIDATED
} from '../database/DatabaseConstants';
import {
  booleanToInt,
  intToBoolean,
  isValidTimestamp,
  isValidSequence
} from './RepositoryMappers';

/** 合法记忆类型集合 */
const VALID_MEMORY_TYPES: Set<string> = new Set(['core', 'chapter', 'rolling', 'legacy']);

/** 将字符串安全转换为 MemoryType,非法值回退为默认 */
function parseMemoryType(raw: string): MemoryType {
  if (VALID_MEMORY_TYPES.has(raw)) {
    return raw as MemoryType;
  }
  return DEFAULT_MEMORY_TYPE;
}

/**
 * 从 ResultSet 读取 ChatMemory(当前行)。
 * v12: 同时读取 memoryType / title / detail / importance / keywordsJson / sourceHash / invalidated。
 *      旧表(v8~v11 迁移中)这些列由 ALTER 添加 DEFAULT 值,读取安全。
 */
export function memoryFromRow(rs: relationalStore.ResultSet): ChatMemory {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('memory: id empty');
  }
  const chatId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_CHAT_ID));
  if (chatId.length === 0) {
    throw DatabaseError.invalidData('memory: chatId empty');
  }
  const branchId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_BRANCH_ID));
  if (branchId.length === 0) {
    throw DatabaseError.invalidData('memory: branchId empty');
  }
  const startMessageId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_START_MESSAGE_ID));
  if (startMessageId.length === 0) {
    throw DatabaseError.invalidData('memory: startMessageId empty');
  }
  const endMessageId: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_END_MESSAGE_ID));
  if (endMessageId.length === 0) {
    throw DatabaseError.invalidData('memory: endMessageId empty');
  }
  const startPosition: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_START_POSITION));
  if (!isValidSequence(startPosition)) {
    throw DatabaseError.invalidData('memory: invalid startPosition');
  }
  const endPosition: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_END_POSITION));
  if (!isValidSequence(endPosition)) {
    throw DatabaseError.invalidData('memory: invalid endPosition');
  }
  const summary: string = rs.getString(rs.getColumnIndex(COLUMN_MEMORY_SUMMARY));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('memory: invalid createdAt');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('memory: invalid updatedAt');
  }
  const enabledInt: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_ENABLED));
  const enabled: boolean = intToBoolean(enabledInt);
  const summaryVersion: number = rs.getLong(rs.getColumnIndex(COLUMN_MEMORY_SUMMARY_VERSION));
  if (!isValidSequence(summaryVersion)) {
    throw DatabaseError.invalidData('memory: invalid summaryVersion');
  }
  // inherited_from_memory_id 可空
  const inheritedCol: number = rs.getColumnIndex(COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID);
  const inheritedFromMemoryId: string | undefined =
    (inheritedCol >= 0 && !rs.isColumnNull(inheritedCol))
      ? rs.getString(inheritedCol) : undefined;

  // v12 多层记忆字段(旧数据迁移后 DEFAULT 值已由数据库填充)
  const memoryTypeCol: number = rs.getColumnIndex(COLUMN_MEMORY_TYPE);
  const memoryType: MemoryType = memoryTypeCol >= 0
    ? parseMemoryType(rs.getString(memoryTypeCol))
    : DEFAULT_MEMORY_TYPE;

  const titleCol: number = rs.getColumnIndex(COLUMN_MEMORY_TITLE);
  const title: string = titleCol >= 0 ? rs.getString(titleCol) : '';

  const detailCol: number = rs.getColumnIndex(COLUMN_MEMORY_DETAIL);
  const detail: string = detailCol >= 0 ? rs.getString(detailCol) : '';

  const importanceCol: number = rs.getColumnIndex(COLUMN_MEMORY_IMPORTANCE);
  const importance: number = importanceCol >= 0 ? rs.getLong(importanceCol) : 0;

  const keywordsCol: number = rs.getColumnIndex(COLUMN_MEMORY_KEYWORDS_JSON);
  const keywordsJson: string = keywordsCol >= 0 ? rs.getString(keywordsCol) : '[]';

  const sourceHashCol: number = rs.getColumnIndex(COLUMN_MEMORY_SOURCE_HASH);
  const sourceHash: string = sourceHashCol >= 0 ? rs.getString(sourceHashCol) : '';

  const invalidatedCol: number = rs.getColumnIndex(COLUMN_MEMORY_INVALIDATED);
  const invalidatedInt: number = invalidatedCol >= 0 ? rs.getLong(invalidatedCol) : 0;
  const invalidated: boolean = intToBoolean(invalidatedInt);

  return {
    id,
    chatId,
    branchId,
    startMessageId,
    endMessageId,
    startPosition,
    endPosition,
    summary,
    createdAt,
    updatedAt,
    enabled,
    summaryVersion,
    inheritedFromMemoryId,
    memoryType,
    title,
    detail,
    importance,
    keywordsJson,
    sourceHash,
    invalidated
  };
}

/**
 * ChatMemory → ValuesBucket(用于 insert / replace)。
 * v12: 包含所有多层记忆字段。
 */
export function memoryToBucket(memory: ChatMemory): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_MEMORY_ID] = memory.id;
  bucket[COLUMN_MEMORY_CHAT_ID] = memory.chatId;
  bucket[COLUMN_MEMORY_BRANCH_ID] = memory.branchId;
  bucket[COLUMN_MEMORY_START_MESSAGE_ID] = memory.startMessageId;
  bucket[COLUMN_MEMORY_END_MESSAGE_ID] = memory.endMessageId;
  bucket[COLUMN_MEMORY_START_POSITION] = memory.startPosition;
  bucket[COLUMN_MEMORY_END_POSITION] = memory.endPosition;
  bucket[COLUMN_MEMORY_SUMMARY] = memory.summary;
  bucket[COLUMN_CREATED_AT] = memory.createdAt;
  bucket[COLUMN_UPDATED_AT] = memory.updatedAt;
  bucket[COLUMN_MEMORY_ENABLED] = booleanToInt(memory.enabled);
  bucket[COLUMN_MEMORY_SUMMARY_VERSION] = memory.summaryVersion;
  if (memory.inheritedFromMemoryId !== undefined && memory.inheritedFromMemoryId.length > 0) {
    bucket[COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID] = memory.inheritedFromMemoryId;
  } else {
    bucket[COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID] = null;
  }
  bucket[COLUMN_MEMORY_TYPE] = memory.memoryType;
  bucket[COLUMN_MEMORY_TITLE] = memory.title;
  bucket[COLUMN_MEMORY_DETAIL] = memory.detail;
  bucket[COLUMN_MEMORY_IMPORTANCE] = memory.importance;
  bucket[COLUMN_MEMORY_KEYWORDS_JSON] = memory.keywordsJson;
  bucket[COLUMN_MEMORY_SOURCE_HASH] = memory.sourceHash;
  bucket[COLUMN_MEMORY_INVALIDATED] = booleanToInt(memory.invalidated);
  return bucket;
}
