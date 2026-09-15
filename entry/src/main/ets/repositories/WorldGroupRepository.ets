/**
 * WorldGroupRepository
 *
 * 职责:
 * - worlds 表的世界分组 CRUD(复用休眠的 worlds 表作为世界分组实体)
 * - 行→WorldGroup 映射(内联)
 *
 * 不负责:
 * - 会话分组关系(chats.world_id 由 ChatRepository 维护)
 * - 业务逻辑
 * - 世界模式(WorldStateService)的既有数据域
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { WorldGroup, validateWorldGroup } from '../models/WorldGroup';
import { DatabaseError } from '../models/DatabaseError';
import {
  TABLE_WORLDS,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_DESCRIPTION,
  COLUMN_STATUS,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT
} from '../database/DatabaseConstants';
import {
  extractCauseMessage,
  isConstraintViolation,
  isValidTimestamp
} from './RepositoryMappers';

/**
 * 从 ResultSet 当前行构建 WorldGroup。
 */
function worldGroupFromRow(rs: relationalStore.ResultSet): WorldGroup {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('worldGroup id is empty');
  }
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_NAME));
  const description: string = rs.getString(rs.getColumnIndex(COLUMN_DESCRIPTION));
  const status: string = rs.getString(rs.getColumnIndex(COLUMN_STATUS));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('worldGroup createdAt invalid');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('worldGroup updatedAt invalid');
  }
  return {
    id: id,
    name: name,
    description: description,
    status: status,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 将 WorldGroup 转为 ValuesBucket。
 */
function worldGroupToBucket(group: WorldGroup): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = group.id;
  bucket[COLUMN_NAME] = group.name;
  bucket[COLUMN_DESCRIPTION] = group.description;
  bucket[COLUMN_STATUS] = group.status;
  bucket[COLUMN_CREATED_AT] = group.createdAt;
  bucket[COLUMN_UPDATED_AT] = group.updatedAt;
  return bucket;
}

export class WorldGroupRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async list(): Promise<WorldGroup[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.orderByAsc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const groups: WorldGroup[] = [];
    try {
      while (rs.goToNextRow()) {
        groups.push(worldGroupFromRow(rs));
      }
    } finally {
      rs.close();
    }
    return groups;
  }

  async getById(id: string): Promise<WorldGroup | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return worldGroupFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async insert(group: WorldGroup): Promise<void> {
    validateWorldGroup(group);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_WORLDS, worldGroupToBucket(group));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('worldGroup.insert');
      }
      throw DatabaseError.queryFailed(
        `worldGroup.insert: ${extractCauseMessage(err)}`
      );
    }
  }

  async update(group: WorldGroup): Promise<void> {
    validateWorldGroup(group);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = worldGroupToBucket(group);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, group.id);
    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `worldGroup.update: ${extractCauseMessage(err)}`
      );
    }
    if (affected === 0) {
      throw DatabaseError.notFound('worldGroup.update');
    }
  }

  async remove(id: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_WORLDS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `worldGroup.remove: ${extractCauseMessage(err)}`
      );
    }
  }
}
