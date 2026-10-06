/**
 * LocalImageRepositoryMapper
 *
 * 职责:
 * - LocalImage 行映射(ResultSet → LocalImage)
 * - LocalImage → ValuesBucket 转换
 * - 旧 schema 列缺失时的安全回退
 * - 时间戳校验
 *
 * 不负责:
 * - SQL 执行
 * - 事务管理
 * - 业务逻辑
 *
 * 安全:
 * - 数据库损坏抛 DatabaseError.InvalidData
 * - 错误信息不包含 name、fileUri 内容
 */

import { relationalStore } from '@kit.ArkData';
import { LocalImage } from '../models/LocalImage';
import { DatabaseError } from '../models/DatabaseError';
import { isValidTimestamp } from './RepositoryMappers';
import {
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_IMAGE_NAME_KEY,
  COLUMN_IMAGE_FILE_URI,
  COLUMN_CHARACTER_ID,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';

/**
 * 安全读取字符串列:列不存在(ci < 0)时回退空字符串。
 */
function readString(rs: relationalStore.ResultSet, ci: number): string {
  if (ci < 0) {
    return '';
  }
  return rs.getString(ci);
}

/**
 * 安全读取整型列:列不存在(ci < 0)时回退 0。
 */
function readLong(rs: relationalStore.ResultSet, ci: number): number {
  if (ci < 0) {
    return 0;
  }
  return rs.getLong(ci);
}

/**
 * 从 ResultSet 当前行读取 LocalImage。
 * 非法时间戳抛 InvalidData,不返回半合法对象。
 * 错误信息不含 name、fileUri。
 */
export function localImageFromRow(
  rs: relationalStore.ResultSet
): LocalImage {
  const ciId: number = rs.getColumnIndex(COLUMN_ID);
  const id: string = readString(rs, ciId);
  if (id.length === 0) {
    throw DatabaseError.invalidData('local image id empty');
  }

  const ciName: number = rs.getColumnIndex(COLUMN_NAME);
  const name: string = readString(rs, ciName);

  const ciNameKey: number = rs.getColumnIndex(COLUMN_IMAGE_NAME_KEY);
  const nameKey: string = readString(rs, ciNameKey);

  const ciFileUri: number = rs.getColumnIndex(COLUMN_IMAGE_FILE_URI);
  const fileUri: string = readString(rs, ciFileUri);

  const ciCharacterId: number = rs.getColumnIndex(COLUMN_CHARACTER_ID);
  const characterId: string = readString(rs, ciCharacterId);

  const ciCreatedAt: number = rs.getColumnIndex(COLUMN_CREATED_AT);
  const createdAt: number = readLong(rs, ciCreatedAt);
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('local image createdAt invalid');
  }

  const ciUpdatedAt: number = rs.getColumnIndex(COLUMN_UPDATED_AT);
  const updatedAt: number = readLong(rs, ciUpdatedAt);
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('local image updatedAt invalid');
  }

  return {
    id: id,
    name: name,
    nameKey: nameKey,
    fileUri: fileUri,
    characterId: characterId,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 将 LocalImage 转换为 ValuesBucket(7 个键全部写入)。
 * 不修改输入对象。
 */
export function buildLocalImageValues(
  image: LocalImage
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = image.id;
  bucket[COLUMN_NAME] = image.name;
  bucket[COLUMN_IMAGE_NAME_KEY] = image.nameKey;
  bucket[COLUMN_IMAGE_FILE_URI] = image.fileUri;
  bucket[COLUMN_CHARACTER_ID] = image.characterId;
  bucket[COLUMN_CREATED_AT] = image.createdAt;
  bucket[COLUMN_UPDATED_AT] = image.updatedAt;
  return bucket;
}