/**
 * MessageRepository
 *
 * 职责:
 * - Message 的 CRUD 操作
 * - 按 chatId 分页查询,按 sequence_number 稳定排序
 * - 批量插入(事务,整批回滚)
 * - source 持久化白名单校验
 * - status 与 isStreaming 一致性校验
 * - 提供 WithStore 内部方法供事务组合使用
 *
 * 不负责:
 * - Chat 操作(见 ChatRepository)
 * - 级联删除(见 ChatPersistenceOperations)
 * - 业务逻辑
 *
 * 规则:
 * - insert 前检查 Chat 是否存在,不允许孤儿消息
 * - insertMany 在事务中只检查一次 Chat 是否存在
 * - source 为 CharacterPrompt/LorebookBefore/LorebookAfter 时拒绝持久化
 * - status 与 isStreaming 矛盾时拒绝持久化
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatMessage, ChatMessageStatus, MessageSenderType, MessageVisibility } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { DatabaseError } from '../models/DatabaseError';
import { nowMillis } from '../utils/Time';
import {
  TABLE_MESSAGES,
  TABLE_CHATS,
  COLUMN_ID,
  COLUMN_CHAT_ID,
  COLUMN_ROLE,
  COLUMN_CONTENT,
  COLUMN_STATUS,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_ERROR_MESSAGE,
  COLUMN_IS_STREAMING,
  COLUMN_SOURCE,
  COLUMN_SENDER_TYPE,
  COLUMN_SENDER_CHARACTER_ID,
  COLUMN_SCENE_ID,
  COLUMN_GENERATION_BATCH_ID,
  COLUMN_VISIBILITY,
  COLUMN_RECIPIENT_CHARACTER_IDS_JSON,
  COLUMN_PARTICIPANT_IDS_JSON,
  COLUMN_WITNESS_IDS_JSON,
  COLUMN_REPLY_TARGET_CHARACTER_IDS_JSON
} from '../database/DatabaseConstants';
import {
  parseChatRole,
  chatRoleToString,
  parseChatMessageStatus,
  chatMessageStatusToString,
  parseChatMessageSource,
  chatMessageSourceToString,
  parseMessageSenderType,
  messageSenderTypeToString,
  parseMessageVisibility,
  messageVisibilityToString,
  intToBoolean,
  isValidTimestamp,
  isValidSequence,
  isPersistableSource,
  resolveIsStreaming,
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

const DEFAULT_LIMIT: number = 50;
const MAX_LIMIT: number = 200;
const EMPTY_SEQUENCE: number = 0;

export interface MessageInsertRecord {
  readonly message: ChatMessage;
  readonly sequenceNumber: number;
}

export interface MessagePageOptions {
  readonly limit?: number;
  readonly offset?: number;
  readonly ascending?: boolean;
}

export interface StoredChatMessage {
  readonly chatId: string;
  readonly sequenceNumber: number;
  readonly message: ChatMessage;
}

/**
 * 校验消息并构建 ValuesBucket。
 * 不修改输入 message 对象。
 * 不包含 chat_id 和 sequence_number(由调用方附加)。
 */
function buildValidatedMessageBucket(
  message: ChatMessage,
  chatId: string,
  sequenceNumber: number
): relationalStore.ValuesBucket {
  if (message.id === '') {
    throw DatabaseError.invalidData('message.id empty');
  }
  if (chatId === '') {
    throw DatabaseError.invalidData('chatId empty');
  }
  if (message.status === undefined) {
    throw DatabaseError.invalidData('message.status undefined');
  }
  if (!isValidSequence(sequenceNumber)) {
    throw DatabaseError.invalidData('sequenceNumber invalid');
  }
  if (!isValidTimestamp(message.createdAt)) {
    throw DatabaseError.invalidData('message.createdAt invalid');
  }
  if (message.updatedAt !== undefined && !isValidTimestamp(message.updatedAt)) {
    throw DatabaseError.invalidData('message.updatedAt invalid');
  }
  parseChatRole(message.role);
  parseChatMessageStatus(message.status);
  if (!isPersistableSource(message.source)) {
    throw DatabaseError.invalidData('source not persistable');
  }

  // v10 多人世界字段校验
  // - senderType 默认为 'user'(向后兼容旧消息)
  // - senderType === 'character' 时 senderCharacterId 必填
  // - senderType === 'user' 或 'narrator' 时 senderCharacterId 必须为空
  const senderType: MessageSenderType =
    message.senderType !== undefined ? message.senderType : 'user';
  messageSenderTypeToString(senderType);
  if (senderType === 'character') {
    if (message.senderCharacterId === undefined || message.senderCharacterId === '') {
      throw DatabaseError.invalidData('sender_character_id empty for character message');
    }
  } else {
    if (message.senderCharacterId !== undefined && message.senderCharacterId !== '') {
      throw DatabaseError.invalidData(
        `sender_character_id must be empty for ${senderType} message`
      );
    }
  }

  const status: ChatMessageStatus = message.status;
  const isStreamingInt: number = resolveIsStreaming(status, message.isStreaming);

  // v11 私聊字段校验
  // - visibility 默认 'public'
  // - visibility='private' 时 recipientCharacterIds 必填且非空
  // - visibility='public' 或 'narrator' 时 recipientCharacterIds 必须为空
  const visibility: MessageVisibility =
    message.visibility !== undefined ? message.visibility : 'public';
  messageVisibilityToString(visibility);
  const recipientIds: string[] =
    message.recipientCharacterIds !== undefined ? [...message.recipientCharacterIds] : [];
  const participantIds: string[] =
    message.participantIds !== undefined ? [...message.participantIds] : [];
  const witnessIds: string[] =
    message.witnessIds !== undefined ? [...message.witnessIds] : [];
  // v14 G-CONTROL-2A: 公开消息回复目标(独立于私聊 recipient)
  // - 仅 visibility='public' 时允许填写
  // - visibility='private'/'narrator' 时必须为空(回复目标只对公开消息有意义)
  const replyTargetIds: string[] =
    message.replyTargetCharacterIds !== undefined ? [...message.replyTargetCharacterIds] : [];
  if (visibility === 'private' || visibility === 'narrator') {
    if (replyTargetIds.length > 0) {
      throw DatabaseError.invalidData(
        `reply_target_character_ids must be empty for ${visibility} message`
      );
    }
  }
  if (visibility === 'private') {
    if (recipientIds.length === 0) {
      throw DatabaseError.invalidData('recipient_character_ids empty for private message');
    }
  } else {
    if (recipientIds.length > 0) {
      throw DatabaseError.invalidData(
        `recipient_character_ids must be empty for ${visibility} message`
      );
    }
  }

  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = message.id;
  bucket[COLUMN_CHAT_ID] = chatId;
  bucket[COLUMN_ROLE] = chatRoleToString(message.role);
  bucket[COLUMN_CONTENT] = message.content;
  bucket[COLUMN_STATUS] = chatMessageStatusToString(status);
  bucket[COLUMN_CREATED_AT] = message.createdAt;
  bucket[COLUMN_UPDATED_AT] = message.updatedAt !== undefined ? message.updatedAt : null;
  bucket[COLUMN_SEQUENCE_NUMBER] = sequenceNumber;
  bucket[COLUMN_ERROR_MESSAGE] = message.errorMessage !== undefined ? message.errorMessage : null;
  bucket[COLUMN_IS_STREAMING] = isStreamingInt;
  bucket[COLUMN_SOURCE] = chatMessageSourceToString(message.source);
  bucket[COLUMN_SENDER_TYPE] = messageSenderTypeToString(senderType);
  bucket[COLUMN_SENDER_CHARACTER_ID] =
    senderType === 'character'
      ? (message.senderCharacterId !== undefined ? message.senderCharacterId : null)
      : null;
  bucket[COLUMN_SCENE_ID] =
    message.sceneId !== undefined && message.sceneId !== '' ? message.sceneId : null;
  bucket[COLUMN_GENERATION_BATCH_ID] =
    message.generationBatchId !== undefined && message.generationBatchId !== ''
      ? message.generationBatchId
      : null;
  bucket[COLUMN_VISIBILITY] = messageVisibilityToString(visibility);
  bucket[COLUMN_RECIPIENT_CHARACTER_IDS_JSON] =
    recipientIds.length > 0 ? JSON.stringify(recipientIds) : null;
  bucket[COLUMN_PARTICIPANT_IDS_JSON] =
    participantIds.length > 0 ? JSON.stringify(participantIds) : null;
  bucket[COLUMN_WITNESS_IDS_JSON] =
    witnessIds.length > 0 ? JSON.stringify(witnessIds) : null;
  bucket[COLUMN_REPLY_TARGET_CHARACTER_IDS_JSON] =
    replyTargetIds.length > 0 ? JSON.stringify(replyTargetIds) : null;
  return bucket;
}

/**
 * 从 ResultSet 当前行读取 ChatMessage。
 * 不读取 chat_id 和 sequence_number(持久化关系字段)。
 * 枚举字符串经显式校验,非法值抛 InvalidData。
 */
function messageFromRow(rs: relationalStore.ResultSet): ChatMessage {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  const role: ChatRole = parseChatRole(rs.getString(rs.getColumnIndex(COLUMN_ROLE)));
  const content: string = rs.getString(rs.getColumnIndex(COLUMN_CONTENT));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));

  const updatedAtCol: number = rs.getColumnIndex(COLUMN_UPDATED_AT);
  const updatedAt: number | undefined =
    (updatedAtCol >= 0 && !rs.isColumnNull(updatedAtCol))
      ? rs.getLong(updatedAtCol)
      : undefined;

  const statusStr: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  const status: ChatMessageStatus = parseChatMessageStatus(statusStr);

  const isStreamingCol: number = rs.getColumnIndex(COLUMN_IS_STREAMING);
  const isStreaming: boolean = intToBoolean(rs.getLong(isStreamingCol));

  const errorMessageCol: number = rs.getColumnIndex(COLUMN_ERROR_MESSAGE);
  const errorMessage: string | undefined =
    (errorMessageCol >= 0 && !rs.isColumnNull(errorMessageCol))
      ? rs.getString(errorMessageCol)
      : undefined;

  const sourceCol: number = rs.getColumnIndex(COLUMN_SOURCE);
  const sourceStr: string | null =
    (sourceCol >= 0 && !rs.isColumnNull(sourceCol))
      ? rs.getString(sourceCol)
      : null;
  const source: ChatMessageSource | undefined = parseChatMessageSource(sourceStr);

  // v10 多人世界字段(sender_type 列在旧库可能不存在,getColumnIndex 返回 -1 时回退 'user')
  const senderTypeCol: number = rs.getColumnIndex(COLUMN_SENDER_TYPE);
  const senderTypeStr: string | null =
    (senderTypeCol >= 0 && !rs.isColumnNull(senderTypeCol))
      ? rs.getString(senderTypeCol)
      : null;
  const senderType: MessageSenderType = parseMessageSenderType(senderTypeStr);

  const senderCharacterIdCol: number = rs.getColumnIndex(COLUMN_SENDER_CHARACTER_ID);
  const senderCharacterId: string | undefined =
    (senderCharacterIdCol >= 0 && !rs.isColumnNull(senderCharacterIdCol))
      ? rs.getString(senderCharacterIdCol)
      : undefined;

  const sceneIdCol: number = rs.getColumnIndex(COLUMN_SCENE_ID);
  const sceneId: string | undefined =
    (sceneIdCol >= 0 && !rs.isColumnNull(sceneIdCol))
      ? rs.getString(sceneIdCol)
      : undefined;

  const generationBatchIdCol: number = rs.getColumnIndex(COLUMN_GENERATION_BATCH_ID);
  const generationBatchId: string | undefined =
    (generationBatchIdCol >= 0 && !rs.isColumnNull(generationBatchIdCol))
      ? rs.getString(generationBatchIdCol)
      : undefined;

  // v11 私聊字段(列在旧库可能不存在,getColumnIndex 返回 -1 时回退默认值)
  const visibilityCol: number = rs.getColumnIndex(COLUMN_VISIBILITY);
  const visibilityStr: string | null =
    (visibilityCol >= 0 && !rs.isColumnNull(visibilityCol))
      ? rs.getString(visibilityCol)
      : null;
  const visibility: MessageVisibility = parseMessageVisibility(visibilityStr);

  const recipientIdsCol: number = rs.getColumnIndex(COLUMN_RECIPIENT_CHARACTER_IDS_JSON);
  const recipientIdsJson: string | null =
    (recipientIdsCol >= 0 && !rs.isColumnNull(recipientIdsCol))
      ? rs.getString(recipientIdsCol)
      : null;
  const recipientCharacterIds: string[] | undefined =
    recipientIdsJson !== null && recipientIdsJson.length > 0
      ? parseStringArrayJson(recipientIdsJson)
      : undefined;

  const participantIdsCol: number = rs.getColumnIndex(COLUMN_PARTICIPANT_IDS_JSON);
  const participantIdsJson: string | null =
    (participantIdsCol >= 0 && !rs.isColumnNull(participantIdsCol))
      ? rs.getString(participantIdsCol)
      : null;
  const participantIds: string[] | undefined =
    participantIdsJson !== null && participantIdsJson.length > 0
      ? parseStringArrayJson(participantIdsJson)
      : undefined;

  const witnessIdsCol: number = rs.getColumnIndex(COLUMN_WITNESS_IDS_JSON);
  const witnessIdsJson: string | null =
    (witnessIdsCol >= 0 && !rs.isColumnNull(witnessIdsCol))
      ? rs.getString(witnessIdsCol)
      : null;
  const witnessIds: string[] | undefined =
    witnessIdsJson !== null && witnessIdsJson.length > 0
      ? parseStringArrayJson(witnessIdsJson)
      : undefined;

  // v14 G-CONTROL-2A: 公开消息回复目标(列在旧库可能不存在,getColumnIndex 返回 -1 时回退 undefined)
  const replyTargetIdsCol: number = rs.getColumnIndex(COLUMN_REPLY_TARGET_CHARACTER_IDS_JSON);
  const replyTargetIdsJson: string | null =
    (replyTargetIdsCol >= 0 && !rs.isColumnNull(replyTargetIdsCol))
      ? rs.getString(replyTargetIdsCol)
      : null;
  const replyTargetCharacterIds: string[] | undefined =
    replyTargetIdsJson !== null && replyTargetIdsJson.length > 0
      ? parseStringArrayJson(replyTargetIdsJson)
      : undefined;

  return {
    id: id,
    role: role,
    content: content,
    createdAt: createdAt,
    updatedAt: updatedAt,
    isStreaming: isStreaming,
    errorMessage: errorMessage,
    status: status,
    source: source,
    senderType: senderType,
    senderCharacterId: senderCharacterId,
    sceneId: sceneId,
    generationBatchId: generationBatchId,
    visibility: visibility,
    recipientCharacterIds: recipientCharacterIds,
    participantIds: participantIds,
    witnessIds: witnessIds,
    replyTargetCharacterIds: replyTargetCharacterIds
  };
}

/**
 * 安全解析 JSON 字符串为 string[]。
 * - 输入为空或非数组时返回空数组
 * - 数组元素必须为 string,非 string 元素跳过
 */
function parseStringArrayJson(json: string): string[] {
  try {
    const parsed: Object = JSON.parse(json);
    if (!Array.isArray(parsed)) {
      return [];
    }
    const arr: string[] = [];
    for (let i = 0; i < parsed.length; i++) {
      const item: Object = parsed[i];
      if (typeof item === 'string') {
        arr.push(item as string);
      }
    }
    return arr;
  } catch (e) {
    return [];
  }
}

function readSequenceNumber(rs: relationalStore.ResultSet): number {
  const ci: number = rs.getColumnIndex(COLUMN_SEQUENCE_NUMBER);
  if (ci < 0) {
    throw DatabaseError.invalidData('sequence_number column missing');
  }
  const val: number = rs.getLong(ci);
  if (!isValidSequence(val)) {
    throw DatabaseError.invalidData('sequence_number invalid in DB');
  }
  return val;
}

export class MessageRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async insert(
    message: ChatMessage,
    chatId: string,
    sequenceNumber: number
  ): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const exists: boolean = await this.chatExistsWithStore(store, chatId);
    if (!exists) {
      throw DatabaseError.notFound('message.insert: chat not found');
    }
    await this.insertWithStore(store, message, chatId, sequenceNumber);
  }

  /**
   * 在给定 store 上直接插入消息,不检查 Chat 是否存在。
   * 调用方(insert / insertMany)负责检查 Chat 存在性。
   * 用于事务组合,避免嵌套检查。
   */
  async insertWithStore(
    store: relationalStore.RdbStore,
    message: ChatMessage,
    chatId: string,
    sequenceNumber: number
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket =
      buildValidatedMessageBucket(message, chatId, sequenceNumber);
    try {
      await store.insert(TABLE_MESSAGES, bucket);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('message.insert');
      }
      throw DatabaseError.queryFailed(`message.insert: ${extractCauseMessage(err)}`);
    }
  }

  async insertMany(
    chatId: string,
    records: MessageInsertRecord[]
  ): Promise<void> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    if (records.length === 0) {
      return;
    }

    // 预校验所有记录(在事务开启前)
    for (let i = 0; i < records.length; i++) {
      const rec: MessageInsertRecord = records[i];
      buildValidatedMessageBucket(rec.message, chatId, rec.sequenceNumber);
    }

    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        // 事务中只检查一次 Chat 是否存在
        const exists: boolean = await this.chatExistsWithStore(store, chatId);
        if (!exists) {
          throw DatabaseError.notFound('message.insertMany: chat not found');
        }
        for (let i = 0; i < records.length; i++) {
          const rec: MessageInsertRecord = records[i];
          const bucket: relationalStore.ValuesBucket =
            buildValidatedMessageBucket(rec.message, chatId, rec.sequenceNumber);
          try {
            await store.insert(TABLE_MESSAGES, bucket);
          } catch (err) {
            if (isConstraintViolation(err)) {
              throw DatabaseError.constraintFailed(`message.insertMany[${i}]`);
            }
            throw DatabaseError.queryFailed(
              `message.insertMany[${i}]: ${extractCauseMessage(err)}`
            );
          }
        }
      }
    );
  }

  async getById(id: string): Promise<ChatMessage | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return messageFromRow(rs);
    } finally {
      rs.close();
    }
  }

  /**
   * 批量按 ID 查询消息(使用 RdbPredicates.in 安全参数化,不拼接 SQL)。
   * 返回 Map<id, ChatMessage>,调用方按需从 Map 取值。
   * 分批查询(每批 100 个 ID),避免 SQLite 参数数量上限。
   *
   * @param store 事务/连接复用 store
   * @param ids 要查询的消息 ID 列表
   * @returns Map<id, ChatMessage>(不存在的 ID 不会出现在 Map 中)
   */
  async listByIdsWithStore(
    store: relationalStore.RdbStore,
    ids: string[]
  ): Promise<Map<string, ChatMessage>> {
    const result: Map<string, ChatMessage> = new Map<string, ChatMessage>();
    if (ids.length === 0) {
      return result;
    }
    const BATCH_SIZE: number = 100;
    for (let i: number = 0; i < ids.length; i += BATCH_SIZE) {
      const end: number = Math.min(i + BATCH_SIZE, ids.length);
      const batch: string[] = ids.slice(i, end);
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_MESSAGES);
      predicates.in(COLUMN_ID, batch);
      const rs: relationalStore.ResultSet = await store.query(predicates);
      try {
        while (rs.goToNextRow()) {
          const msg: ChatMessage = messageFromRow(rs);
          result.set(msg.id, msg);
        }
      } finally {
        rs.close();
      }
    }
    return result;
  }

  async listByChat(
    chatId: string,
    options?: MessagePageOptions
  ): Promise<ChatMessage[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const limit: number =
      options !== undefined && options.limit !== undefined
        ? options.limit
        : DEFAULT_LIMIT;
    const offset: number =
      options !== undefined && options.offset !== undefined
        ? options.offset
        : 0;
    const ascending: boolean =
      options !== undefined && options.ascending !== undefined
        ? options.ascending
        : true;

    if (limit < 1 || limit > MAX_LIMIT) {
      throw DatabaseError.invalidData('limit out of range');
    }
    if (offset < 0) {
      throw DatabaseError.invalidData('offset out of range');
    }

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    if (ascending) {
      predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    } else {
      predicates.orderByDesc(COLUMN_SEQUENCE_NUMBER);
    }
    predicates.limitAs(limit);
    predicates.offsetAs(offset);

    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const messages: ChatMessage[] = [];
      while (rs.goToNextRow()) {
        messages.push(messageFromRow(rs));
      }
      return messages;
    } finally {
      rs.close();
    }
  }

  async listRecordsByChat(
    chatId: string,
    options?: MessagePageOptions
  ): Promise<StoredChatMessage[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const limit: number =
      options !== undefined && options.limit !== undefined
        ? options.limit
        : DEFAULT_LIMIT;
    const offset: number =
      options !== undefined && options.offset !== undefined
        ? options.offset
        : 0;
    const ascending: boolean =
      options !== undefined && options.ascending !== undefined
        ? options.ascending
        : true;

    if (limit < 1 || limit > MAX_LIMIT) {
      throw DatabaseError.invalidData('limit out of range');
    }
    if (offset < 0) {
      throw DatabaseError.invalidData('offset out of range');
    }

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    if (ascending) {
      predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    } else {
      predicates.orderByDesc(COLUMN_SEQUENCE_NUMBER);
    }
    predicates.limitAs(limit);
    predicates.offsetAs(offset);

    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const records: StoredChatMessage[] = [];
      while (rs.goToNextRow()) {
        const message: ChatMessage = messageFromRow(rs);
        const seq: number = readSequenceNumber(rs);
        records.push({
          chatId: chatId,
          sequenceNumber: seq,
          message: message
        });
      }
      return records;
    } finally {
      rs.close();
    }
  }

  async getMaxSequenceNumber(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const sql: string =
      `SELECT MAX(${COLUMN_SEQUENCE_NUMBER}) AS max_seq ` +
      `FROM ${TABLE_MESSAGES} ` +
      `WHERE ${COLUMN_CHAT_ID} = ?`;
    const rs: relationalStore.ResultSet =
      await store.querySql(sql, [chatId]);
    try {
      if (rs.goToFirstRow()) {
        const ci: number = rs.getColumnIndex('max_seq');
        if (ci >= 0 && !rs.isColumnNull(ci)) {
          const val: number = rs.getLong(ci);
          if (isValidSequence(val)) {
            return val;
          }
        }
      }
      return EMPTY_SEQUENCE;
    } finally {
      rs.close();
    }
  }

  async update(message: ChatMessage): Promise<void> {
    if (message.id === '') {
      throw DatabaseError.invalidData('message.id empty');
    }
    if (message.status === undefined) {
      throw DatabaseError.invalidData('message.status undefined');
    }
    if (!isValidTimestamp(message.createdAt)) {
      throw DatabaseError.invalidData('message.createdAt invalid');
    }
    if (message.updatedAt !== undefined && !isValidTimestamp(message.updatedAt)) {
      throw DatabaseError.invalidData('message.updatedAt invalid');
    }
    parseChatRole(message.role);
    parseChatMessageStatus(message.status);
    if (!isPersistableSource(message.source)) {
      throw DatabaseError.invalidData('source not persistable');
    }

    // v10 多人世界字段校验(同 buildValidatedMessageBucket)
    const senderType: MessageSenderType =
      message.senderType !== undefined ? message.senderType : 'user';
    messageSenderTypeToString(senderType);
    if (senderType === 'character') {
      if (message.senderCharacterId === undefined || message.senderCharacterId === '') {
        throw DatabaseError.invalidData('sender_character_id empty for character message');
      }
    } else {
      if (message.senderCharacterId !== undefined && message.senderCharacterId !== '') {
        throw DatabaseError.invalidData(
          `sender_character_id must be empty for ${senderType} message`
        );
      }
    }

    const status: ChatMessageStatus = message.status;
    const isStreamingInt: number = resolveIsStreaming(status, message.isStreaming);

    // v11 私聊字段校验(同 buildValidatedMessageBucket)
    const visibility: MessageVisibility =
      message.visibility !== undefined ? message.visibility : 'public';
    messageVisibilityToString(visibility);
    const recipientIds: string[] =
      message.recipientCharacterIds !== undefined ? [...message.recipientCharacterIds] : [];
    const participantIds: string[] =
      message.participantIds !== undefined ? [...message.participantIds] : [];
    const witnessIds: string[] =
      message.witnessIds !== undefined ? [...message.witnessIds] : [];
    if (visibility === 'private') {
      if (recipientIds.length === 0) {
        throw DatabaseError.invalidData('recipient_character_ids empty for private message');
      }
    } else {
      if (recipientIds.length > 0) {
        throw DatabaseError.invalidData(
          `recipient_character_ids must be empty for ${visibility} message`
        );
      }
    }

    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_ROLE] = chatRoleToString(message.role);
    bucket[COLUMN_CONTENT] = message.content;
    bucket[COLUMN_STATUS] = chatMessageStatusToString(status);
    bucket[COLUMN_UPDATED_AT] = message.updatedAt !== undefined ? message.updatedAt : null;
    bucket[COLUMN_ERROR_MESSAGE] = message.errorMessage !== undefined ? message.errorMessage : null;
    bucket[COLUMN_IS_STREAMING] = isStreamingInt;
    bucket[COLUMN_SOURCE] = chatMessageSourceToString(message.source);
    bucket[COLUMN_SENDER_TYPE] = messageSenderTypeToString(senderType);
  bucket[COLUMN_SENDER_CHARACTER_ID] =
    senderType === 'character'
      ? (message.senderCharacterId !== undefined ? message.senderCharacterId : null)
      : null;
  bucket[COLUMN_SCENE_ID] =
    message.sceneId !== undefined && message.sceneId !== '' ? message.sceneId : null;
  bucket[COLUMN_GENERATION_BATCH_ID] =
    message.generationBatchId !== undefined && message.generationBatchId !== ''
      ? message.generationBatchId
      : null;
  bucket[COLUMN_VISIBILITY] = messageVisibilityToString(visibility);
  bucket[COLUMN_RECIPIENT_CHARACTER_IDS_JSON] =
    recipientIds.length > 0 ? JSON.stringify(recipientIds) : null;
  bucket[COLUMN_PARTICIPANT_IDS_JSON] =
    participantIds.length > 0 ? JSON.stringify(participantIds) : null;
  bucket[COLUMN_WITNESS_IDS_JSON] =
    witnessIds.length > 0 ? JSON.stringify(witnessIds) : null;

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_ID, message.id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`message.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('message.update');
    }
  }

  async remove(id: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`message.remove: ${extractCauseMessage(err)}`);
    }
  }

  async removeByChatId(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.removeByChatIdWithStore(store, chatId);
  }

  /**
   * 在给定 store 上删除指定 chat 的所有消息,返回删除行数。
   * 用于事务组合,避免嵌套事务。
   * 对不存在的 chat 执行返回 0(幂等)。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    try {
      return await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `message.removeByChatId: ${extractCauseMessage(err)}`
      );
    }
  }

  async countByChatId(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const sql: string =
      `SELECT COUNT(*) AS cnt ` +
      `FROM ${TABLE_MESSAGES} ` +
      `WHERE ${COLUMN_CHAT_ID} = ?`;
    const rs: relationalStore.ResultSet =
      await store.querySql(sql, [chatId]);
    try {
      if (rs.goToFirstRow()) {
        const ci: number = rs.getColumnIndex('cnt');
        if (ci >= 0) {
          return rs.getLong(ci);
        }
      }
      return 0;
    } finally {
      rs.close();
    }
  }

  private async chatExistsWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.equalTo(COLUMN_ID, chatId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.goToFirstRow();
    } finally {
      rs.close();
    }
  }

  /**
   * 删除指定 chat 中 sequence_number > sequenceNumber 的所有消息。
   * 不删除 sequence_number 等于传入值的消息(保留边界 User 消息)。
   * 返回删除行数。对不存在的 chat 执行返回 0(幂等)。
   *
   * 使用 RdbPredicates.greaterThan,不拼接用户输入 SQL。
   */
  async removeAfterSequence(
    chatId: string,
    sequenceNumber: number
  ): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    if (!isValidSequence(sequenceNumber)) {
      throw DatabaseError.invalidData('sequenceNumber invalid');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.removeAfterSequenceWithStore(store, chatId, sequenceNumber);
  }

  /**
   * 在给定 store 上删除 sequence_number > sequenceNumber 的所有消息。
   * 用于事务组合,避免嵌套事务。
   * 不删除边界消息(sequence_number 等于传入值)。
   * 对不存在的 chat 执行返回 0(幂等)。
   */
  async removeAfterSequenceWithStore(
    store: relationalStore.RdbStore,
    chatId: string,
    sequenceNumber: number
  ): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    if (!isValidSequence(sequenceNumber)) {
      throw DatabaseError.invalidData('sequenceNumber invalid');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.greaterThan(COLUMN_SEQUENCE_NUMBER, sequenceNumber);
    try {
      return await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `message.removeAfterSequence: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 规范化指定 chat 中所有 Streaming 状态的异常中断消息:
   * - status: Streaming → Cancelled
   * - is_streaming: 1 → 0
   *
   * 用于应用启动后恢复会话时,把上次未正常结束的 Streaming 消息转为 Cancelled。
   * 不修改 Completed/Cancelled/Failed 消息。
   * 返回受影响行数。
   *
   * errorMessage 不被覆盖(保留原有值,通常为空)。
   */
  async normalizeInterruptedMessages(chatId: string): Promise<number> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_STATUS] = chatMessageStatusToString(ChatMessageStatus.Cancelled);
    bucket[COLUMN_IS_STREAMING] = 0;
    bucket[COLUMN_UPDATED_AT] = nowMillis();

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_STATUS, chatMessageStatusToString(ChatMessageStatus.Streaming));

    try {
      return await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `message.normalizeInterrupted: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * 查询指定消息的 chatId。
   * 用于 Swipe ensureSwipeState 时获取消息所属 Chat。
   * 消息不存在返回 null。
   */
  async getChatIdByMessageId(messageId: string): Promise<string | null> {
    if (messageId === '') {
      throw DatabaseError.invalidData('messageId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_ID, messageId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      const ci: number = rs.getColumnIndex(COLUMN_CHAT_ID);
      if (ci >= 0) {
        return rs.getString(ci);
      }
      return null;
    } finally {
      rs.close();
    }
  }

  /**
   * v10 多人世界:按 generationBatchId 删除同一轮消息。
   * 用于整轮生成失败时回滚(无半轮消息)。
   * 对不存在的批次返回 0(幂等)。
   */
  async removeByGenerationBatchId(generationBatchId: string): Promise<number> {
    if (generationBatchId === '') {
      throw DatabaseError.invalidData('generationBatchId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_GENERATION_BATCH_ID, generationBatchId);
    try {
      return await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `message.removeByGenerationBatchId: ${extractCauseMessage(err)}`
      );
    }
  }

  /**
   * v10 多人世界:按 generationBatchId 查询同一轮的所有消息。
   * 按 sequence_number 升序排序。
   */
  async listByGenerationBatchId(generationBatchId: string): Promise<ChatMessage[]> {
    if (generationBatchId === '') {
      throw DatabaseError.invalidData('generationBatchId empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_GENERATION_BATCH_ID, generationBatchId);
    predicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const messages: ChatMessage[] = [];
      while (rs.goToNextRow()) {
        messages.push(messageFromRow(rs));
      }
      return messages;
    } finally {
      rs.close();
    }
  }

  /**
   * v10 多人世界:按 senderCharacterId 查询该角色在指定 chat 中的最近消息。
   * 用于发言调度时统计角色最近连续发言次数。
   * 按 sequence_number 降序,limit 控制条数。
   */
  async listRecentByCharacter(
    chatId: string,
    senderCharacterId: string,
    limit: number
  ): Promise<ChatMessage[]> {
    if (chatId === '') {
      throw DatabaseError.invalidData('chatId empty');
    }
    if (senderCharacterId === '') {
      throw DatabaseError.invalidData('senderCharacterId empty');
    }
    if (limit < 1 || limit > MAX_LIMIT) {
      throw DatabaseError.invalidData('limit out of range');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    predicates.equalTo(COLUMN_CHAT_ID, chatId);
    predicates.equalTo(COLUMN_SENDER_CHARACTER_ID, senderCharacterId);
    predicates.orderByDesc(COLUMN_SEQUENCE_NUMBER);
    predicates.limitAs(limit);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const messages: ChatMessage[] = [];
      while (rs.goToNextRow()) {
        messages.push(messageFromRow(rs));
      }
      return messages;
    } finally {
      rs.close();
    }
  }
}
