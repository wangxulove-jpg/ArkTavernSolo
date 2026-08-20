/**
 * LorebookRepositoryMapper
 *
 * 职责:
 * - Lorebook / LorebookEntry 行映射
 * - keys JSON 编解码
 * - position 显式解析
 * - boolean 0/1 转换
 * - 数据校验
 *
 * 不负责:
 * - SQL 执行
 * - 事务管理
 * - 业务逻辑
 */

import { relationalStore } from '@kit.ArkData';
import { Lorebook, LorebookEntry, LorebookPosition } from '../models/Lorebook';
import { DatabaseError } from '../models/DatabaseError';
import { isValidTimestamp } from './RepositoryMappers';
import {
  COLUMN_LOREBOOK_ID,
  COLUMN_LOREBOOK_NAME,
  COLUMN_LOREBOOK_DESCRIPTION,
  COLUMN_LOREBOOK_ENABLED,
  COLUMN_LOREBOOK_CREATED_AT,
  COLUMN_LOREBOOK_UPDATED_AT,
  COLUMN_ENTRY_ID,
  COLUMN_ENTRY_LOREBOOK_ID,
  COLUMN_ENTRY_NAME,
  COLUMN_ENTRY_KEYS_JSON,
  COLUMN_ENTRY_SECONDARY_KEYS_JSON,
  COLUMN_ENTRY_CONTENT,
  COLUMN_ENTRY_ENABLED,
  COLUMN_ENTRY_CONSTANT,
  COLUMN_ENTRY_SELECTIVE,
  COLUMN_ENTRY_POSITION,
  COLUMN_ENTRY_PRIORITY,
  COLUMN_ENTRY_CREATED_AT,
  COLUMN_ENTRY_UPDATED_AT
} from '../database/DatabaseConstants';

const POSITION_AFTER_CHARACTER: string = 'AfterCharacter';
const POSITION_BEFORE_CHARACTER: string = 'BeforeCharacter';

/**
 * 将 boolean 转为 0 或 1
 */
export function booleanToInt(value: boolean): number {
  return value ? 1 : 0;
}

/**
 * 将 0 或 1 转为 boolean
 */
export function intToBoolean(value: number): boolean {
  return value !== 0;
}

/**
 * 将字符串数组编码为 JSON 字符串
 */
export function encodeKeysJson(keys: string[]): string {
  return JSON.stringify(keys);
}

/**
 * 将 JSON 字符串解码为字符串数组。
 * 损坏数据返回 InvalidData。
 */
export function decodeKeysJson(json: string): string[] {
  let parsed: Object;
  try {
    parsed = JSON.parse(json) as Object;
  } catch (e) {
    throw DatabaseError.invalidData('keys_json parse failed');
  }
  if (!Array.isArray(parsed)) {
    throw DatabaseError.invalidData('keys_json is not an array');
  }
  const arr: Object[] = parsed as Object[];
  const result: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    if (typeof arr[i] !== 'string') {
      throw DatabaseError.invalidData('keys_json element is not a string');
    }
    result.push(arr[i] as string);
  }
  return result;
}

/**
 * 将 LorebookPosition 转为数据库字符串
 */
export function positionToString(position: LorebookPosition): string {
  if (position === LorebookPosition.AfterCharacter) {
    return POSITION_AFTER_CHARACTER;
  }
  return POSITION_BEFORE_CHARACTER;
}

/**
 * 将数据库字符串解析为 LorebookPosition
 */
export function parsePosition(value: string): LorebookPosition {
  if (value === POSITION_AFTER_CHARACTER) {
    return LorebookPosition.AfterCharacter;
  }
  if (value === POSITION_BEFORE_CHARACTER) {
    return LorebookPosition.BeforeCharacter;
  }
  throw DatabaseError.invalidData(`unknown position: ${value}`);
}

/**
 * 从 ResultSet 行构建 LorebookEntry
 */
export function lorebookEntryFromRow(
  rs: relationalStore.ResultSet
): LorebookEntry {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ENTRY_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('entry id is empty');
  }
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_ENTRY_NAME));
  const keysJson: string = rs.getString(rs.getColumnIndex(COLUMN_ENTRY_KEYS_JSON));
  const secondaryKeysJson: string = rs.getString(rs.getColumnIndex(COLUMN_ENTRY_SECONDARY_KEYS_JSON));
  const content: string = rs.getString(rs.getColumnIndex(COLUMN_ENTRY_CONTENT));
  const enabled: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_ENTRY_ENABLED)));
  const constant: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_ENTRY_CONSTANT)));
  const selective: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_ENTRY_SELECTIVE)));
  const position: LorebookPosition =
    parsePosition(rs.getString(rs.getColumnIndex(COLUMN_ENTRY_POSITION)));
  const priority: number = rs.getLong(rs.getColumnIndex(COLUMN_ENTRY_PRIORITY));
  if (!Number.isFinite(priority)) {
    throw DatabaseError.invalidData('entry priority is not finite');
  }
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_ENTRY_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('entry createdAt invalid');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_ENTRY_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('entry updatedAt invalid');
  }
  return {
    id: id,
    name: name,
    keys: decodeKeysJson(keysJson),
    secondaryKeys: decodeKeysJson(secondaryKeysJson),
    content: content,
    enabled: enabled,
    constant: constant,
    selective: selective,
    position: position,
    priority: priority,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 从 ResultSet 行构建 Lorebook 主记录(不含 entries)
 */
export function lorebookFromMainRow(
  rs: relationalStore.ResultSet
): Lorebook {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_LOREBOOK_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('lorebook id is empty');
  }
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_LOREBOOK_NAME));
  if (name.length === 0) {
    throw DatabaseError.invalidData('lorebook name is empty');
  }
  const description: string = rs.getString(rs.getColumnIndex(COLUMN_LOREBOOK_DESCRIPTION));
  const enabled: boolean = intToBoolean(rs.getLong(rs.getColumnIndex(COLUMN_LOREBOOK_ENABLED)));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_LOREBOOK_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('lorebook createdAt invalid');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_LOREBOOK_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('lorebook updatedAt invalid');
  }
  return {
    id: id,
    name: name,
    description: description,
    enabled: enabled,
    entries: [],
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 将 LorebookEntry 转为 ValuesBucket
 */
export function lorebookEntryToBucket(
  entry: LorebookEntry,
  lorebookId: string
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ENTRY_ID] = entry.id;
  bucket[COLUMN_ENTRY_LOREBOOK_ID] = lorebookId;
  bucket[COLUMN_ENTRY_NAME] = entry.name;
  bucket[COLUMN_ENTRY_KEYS_JSON] = encodeKeysJson(entry.keys);
  bucket[COLUMN_ENTRY_SECONDARY_KEYS_JSON] = encodeKeysJson(entry.secondaryKeys);
  bucket[COLUMN_ENTRY_CONTENT] = entry.content;
  bucket[COLUMN_ENTRY_ENABLED] = booleanToInt(entry.enabled);
  bucket[COLUMN_ENTRY_CONSTANT] = booleanToInt(entry.constant);
  bucket[COLUMN_ENTRY_SELECTIVE] = booleanToInt(entry.selective);
  bucket[COLUMN_ENTRY_POSITION] = positionToString(entry.position);
  bucket[COLUMN_ENTRY_PRIORITY] = entry.priority;
  bucket[COLUMN_ENTRY_CREATED_AT] = entry.createdAt;
  bucket[COLUMN_ENTRY_UPDATED_AT] = entry.updatedAt;
  return bucket;
}

/**
 * 将 Lorebook 主记录转为 ValuesBucket
 */
export function lorebookToBucket(
  lorebook: Lorebook
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_LOREBOOK_ID] = lorebook.id;
  bucket[COLUMN_LOREBOOK_NAME] = lorebook.name;
  bucket[COLUMN_LOREBOOK_DESCRIPTION] = lorebook.description;
  bucket[COLUMN_LOREBOOK_ENABLED] = booleanToInt(lorebook.enabled);
  bucket[COLUMN_LOREBOOK_CREATED_AT] = lorebook.createdAt;
  bucket[COLUMN_LOREBOOK_UPDATED_AT] = lorebook.updatedAt;
  return bucket;
}

/**
 * 校验 Lorebook 主记录
 */
export function validateLorebook(lorebook: Lorebook): void {
  if (lorebook.id.length === 0) {
    throw DatabaseError.invalidData('lorebook id is empty');
  }
  if (lorebook.name.length === 0) {
    throw DatabaseError.invalidData('lorebook name is empty');
  }
  if (!isValidTimestamp(lorebook.createdAt)) {
    throw DatabaseError.invalidData('lorebook createdAt invalid');
  }
  if (!isValidTimestamp(lorebook.updatedAt)) {
    throw DatabaseError.invalidData('lorebook updatedAt invalid');
  }
}

/**
 * 校验 LorebookEntry
 */
export function validateLorebookEntry(entry: LorebookEntry): void {
  if (entry.id.length === 0) {
    throw DatabaseError.invalidData('entry id is empty');
  }
  if (!Number.isFinite(entry.priority)) {
    throw DatabaseError.invalidData('entry priority is not finite');
  }
  if (!isValidTimestamp(entry.createdAt)) {
    throw DatabaseError.invalidData('entry createdAt invalid');
  }
  if (!isValidTimestamp(entry.updatedAt)) {
    throw DatabaseError.invalidData('entry updatedAt invalid');
  }
}