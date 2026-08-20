/**
 * CharacterRepository
 *
 * 职责:
 * - Character 的 CRUD 操作
 * - 列表稳定排序(created_at ASC → updated_at ASC → id ASC)
 * - 事务批量导入(insertManyIfMissing),按 ID 跳过已存在记录
 * - 安全校验和行映射,损坏数据抛 InvalidData
 * - 不打印角色字段
 *
 * 不负责:
 * - 头像文件操作(见 CharacterAssetStore)
 * - 当前角色选择(见 CharacterSelectionStore)
 * - 业务逻辑(见 CharacterService)
 * - 级联删除 Chat / Message
 *
 * 规则:
 * - insert 时 ID 重复映射为 AlreadyExists
 * - update 时 id 不可修改,不存在返回 NotFound
 * - remove 幂等
 * - 不修改输入 Character 对象
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { Character } from '../models/Character';
import { DatabaseError } from '../models/DatabaseError';
import {
  TABLE_CHARACTERS,
  COLUMN_ID,
  COLUMN_NAME,
  COLUMN_DESCRIPTION,
  COLUMN_PERSONALITY,
  COLUMN_SCENARIO,
  COLUMN_FIRST_MESSAGE,
  COLUMN_SYSTEM_PROMPT,
  COLUMN_AVATAR_URI,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_MES_EXAMPLE,
  COLUMN_CREATOR_NOTES,
  COLUMN_POST_HISTORY_INSTRUCTIONS,
  COLUMN_ALTERNATE_GREETINGS_JSON,
  COLUMN_TAGS_JSON,
  COLUMN_CREATOR,
  COLUMN_CHARACTER_VERSION,
  COLUMN_EXTENSIONS_JSON,
  COLUMN_CHARACTER_BOOK_ID,
  COLUMN_SORT_ORDER,
  COLUMN_USER_NAME
} from '../database/DatabaseConstants';
import {
  isValidTimestamp,
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

const LOG_TAG: string = 'CharacterRepository';

/**
 * 批量导入结果。
 * 不包含角色 ID 列表或角色字段,只返回计数。
 */
export interface CharacterImportResult {
  readonly insertedCount: number;
  readonly skippedExistingCount: number;
  readonly totalCount: number;
}

/**
 * 将 Character 转换为 ValuesBucket。
 * alternateGreetings / tags / extensions 序列化为 JSON 字符串存储。
 * 不修改输入对象。
 */
function characterToBucket(character: Character): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_ID] = character.id;
  bucket[COLUMN_NAME] = character.name;
  bucket[COLUMN_DESCRIPTION] = character.description;
  bucket[COLUMN_PERSONALITY] = character.personality;
  bucket[COLUMN_SCENARIO] = character.scenario;
  bucket[COLUMN_FIRST_MESSAGE] = character.firstMessage;
  bucket[COLUMN_SYSTEM_PROMPT] = character.systemPrompt;
  bucket[COLUMN_AVATAR_URI] = character.avatarUri;
  bucket[COLUMN_CREATED_AT] = character.createdAt;
  bucket[COLUMN_UPDATED_AT] = character.updatedAt;
  bucket[COLUMN_MES_EXAMPLE] = character.mesExample;
  bucket[COLUMN_CREATOR_NOTES] = character.creatorNotes;
  bucket[COLUMN_POST_HISTORY_INSTRUCTIONS] = character.postHistoryInstructions;
  bucket[COLUMN_ALTERNATE_GREETINGS_JSON] = JSON.stringify(character.alternateGreetings);
  bucket[COLUMN_TAGS_JSON] = JSON.stringify(character.tags);
  bucket[COLUMN_CREATOR] = character.creator;
  bucket[COLUMN_CHARACTER_VERSION] = character.characterVersion;
  bucket[COLUMN_EXTENSIONS_JSON] = JSON.stringify(character.extensions);
  bucket[COLUMN_CHARACTER_BOOK_ID] = character.characterBookId;
  bucket[COLUMN_SORT_ORDER] = character.sortOrder;
  bucket[COLUMN_USER_NAME] = character.userName;
  return bucket;
}

/**
 * 从 ResultSet 当前行读取 Character。
 * 兼容旧版本(数据库未升级时新列可能不存在,getColumnIndex 返回 -1)。
 * 非法字段抛 InvalidData,不返回半合法对象。
 */
function characterFromRow(rs: relationalStore.ResultSet): Character {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('character.id empty');
  }
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_NAME));
  if (name.length === 0) {
    throw DatabaseError.invalidData('character.name empty');
  }
  const description: string = rs.getString(rs.getColumnIndex(COLUMN_DESCRIPTION));
  const personality: string = rs.getString(rs.getColumnIndex(COLUMN_PERSONALITY));
  const scenario: string = rs.getString(rs.getColumnIndex(COLUMN_SCENARIO));
  const firstMessage: string = rs.getString(rs.getColumnIndex(COLUMN_FIRST_MESSAGE));
  const systemPrompt: string = rs.getString(rs.getColumnIndex(COLUMN_SYSTEM_PROMPT));
  const avatarUri: string = rs.getString(rs.getColumnIndex(COLUMN_AVATAR_URI));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_CREATED_AT));
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_UPDATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('character.createdAt invalid');
  }
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('character.updatedAt invalid');
  }

  // ===== V2 扩展字段(向后兼容:列不存在或解析失败时使用默认值) =====
  const mesExample: string = readStringColumnSafe(rs, COLUMN_MES_EXAMPLE, '');
  const creatorNotes: string = readStringColumnSafe(rs, COLUMN_CREATOR_NOTES, '');
  const postHistoryInstructions: string = readStringColumnSafe(rs, COLUMN_POST_HISTORY_INSTRUCTIONS, '');
  const alternateGreetings: string[] = readStringArrayColumnSafe(rs, COLUMN_ALTERNATE_GREETINGS_JSON);
  const tags: string[] = readStringArrayColumnSafe(rs, COLUMN_TAGS_JSON);
  const creator: string = readStringColumnSafe(rs, COLUMN_CREATOR, '');
  const characterVersion: string = readStringColumnSafe(rs, COLUMN_CHARACTER_VERSION, '');
  const extensions: Record<string, Object> = readObjectColumnSafe(rs, COLUMN_EXTENSIONS_JSON);
  const characterBookId: string = readStringColumnSafe(rs, COLUMN_CHARACTER_BOOK_ID, '');
  const sortOrder: number = readLongColumnSafe(rs, COLUMN_SORT_ORDER, 0);
  const userName: string = readStringColumnSafe(rs, COLUMN_USER_NAME, '');

  return {
    id: id,
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMessage,
    systemPrompt: systemPrompt,
    avatarUri: avatarUri,
    mesExample: mesExample,
    creatorNotes: creatorNotes,
    postHistoryInstructions: postHistoryInstructions,
    alternateGreetings: alternateGreetings,
    tags: tags,
    creator: creator,
    characterVersion: characterVersion,
    extensions: extensions,
    characterBookId: characterBookId,
    userName: userName,
    sortOrder: sortOrder,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 安全读取字符串列,列不存在或类型错误时返回默认值。
 */
function readStringColumnSafe(rs: relationalStore.ResultSet, columnName: string, defaultValue: string): string {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return defaultValue;
  }
  try {
    const value: string = rs.getString(col);
    return value !== null && value !== undefined ? value : defaultValue;
  } catch (e) {
    return defaultValue;
  }
}

/**
 * 安全读取整数列(用于 sort_order 等可空数值字段)。
 * 列不存在或类型错误时返回默认值。
 */
function readLongColumnSafe(rs: relationalStore.ResultSet, columnName: string, defaultValue: number): number {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return defaultValue;
  }
  try {
    return rs.getLong(col);
  } catch (e) {
    return defaultValue;
  }
}

/**
 * 安全读取字符串数组列(JSON 字符串)。
 * 列不存在或解析失败时返回空数组。
 */
function readStringArrayColumnSafe(rs: relationalStore.ResultSet, columnName: string): string[] {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return [];
  }
  try {
    const raw: string = rs.getString(col);
    if (raw === null || raw === undefined || raw.length === 0) {
      return [];
    }
    const parsed: Object = JSON.parse(raw) as Object;
    if (!Array.isArray(parsed)) {
      return [];
    }
    const arr: Object[] = parsed as Object[];
    const result: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      if (typeof item === 'string') {
        result.push(item as string);
      }
    }
    return result;
  } catch (e) {
    return [];
  }
}

/**
 * 安全读取对象列(JSON 字符串)。
 * 列不存在或解析失败时返回空对象。
 */
function readObjectColumnSafe(rs: relationalStore.ResultSet, columnName: string): Record<string, Object> {
  const col: number = rs.getColumnIndex(columnName);
  if (col < 0) {
    return {};
  }
  try {
    const raw: string = rs.getString(col);
    if (raw === null || raw === undefined || raw.length === 0) {
      return {};
    }
    const parsed: Object = JSON.parse(raw) as Object;
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return {};
    }
    return parsed as Record<string, Object>;
  } catch (e) {
    return {};
  }
}

export class CharacterRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  /**
   * 校验 Character 字段。
   * 不校验业务层名称长度等规则(由 CharacterService 负责)。
   */
  private validateCharacter(character: Character): void {
    if (character.id.length === 0) {
      throw DatabaseError.invalidData('character.id empty');
    }
    if (character.name.length === 0) {
      throw DatabaseError.invalidData('character.name empty');
    }
    if (!isValidTimestamp(character.createdAt)) {
      throw DatabaseError.invalidData('character.createdAt invalid');
    }
    if (!isValidTimestamp(character.updatedAt)) {
      throw DatabaseError.invalidData('character.updatedAt invalid');
    }
  }

  async insert(character: Character): Promise<void> {
    this.validateCharacter(character);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      await store.insert(TABLE_CHARACTERS, characterToBucket(character));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('character.insert');
      }
      throw DatabaseError.queryFailed(`character.insert: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 在给定 store 上直接插入,不检查唯一性。
   * 调用方(事务组合)需自行处理冲突。
   */
  async insertWithStore(
    store: relationalStore.RdbStore,
    character: Character
  ): Promise<void> {
    this.validateCharacter(character);
    try {
      await store.insert(TABLE_CHARACTERS, characterToBucket(character));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('character.insert');
      }
      throw DatabaseError.queryFailed(`character.insert: ${extractCauseMessage(err)}`);
    }
  }

  async getById(id: string): Promise<Character | null> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('character.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.getByIdWithStore(store, id);
  }

  /**
   * 在事务内查询指定 Character。
   * G-MEMORY-1A: 供 GroupCharacterMemoryService 在事务内校验角色存在。
   * 由调用方持有 store 和事务。
   */
  async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<Character | null> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('character.getByIdWithStore: id empty');
    }
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTERS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return characterFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async list(): Promise<Character[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTERS);
    predicates.orderByAsc(COLUMN_SORT_ORDER);
    predicates.orderByAsc(COLUMN_CREATED_AT);
    predicates.orderByAsc(COLUMN_UPDATED_AT);
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const characters: Character[] = [];
      while (rs.goToNextRow()) {
        characters.push(characterFromRow(rs));
      }
      return characters;
    } finally {
      rs.close();
    }
  }

  async update(character: Character): Promise<void> {
    this.validateCharacter(character);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_NAME] = character.name;
    bucket[COLUMN_DESCRIPTION] = character.description;
    bucket[COLUMN_PERSONALITY] = character.personality;
    bucket[COLUMN_SCENARIO] = character.scenario;
    bucket[COLUMN_FIRST_MESSAGE] = character.firstMessage;
    bucket[COLUMN_SYSTEM_PROMPT] = character.systemPrompt;
    bucket[COLUMN_AVATAR_URI] = character.avatarUri;
    bucket[COLUMN_UPDATED_AT] = character.updatedAt;
    bucket[COLUMN_MES_EXAMPLE] = character.mesExample;
    bucket[COLUMN_CREATOR_NOTES] = character.creatorNotes;
    bucket[COLUMN_POST_HISTORY_INSTRUCTIONS] = character.postHistoryInstructions;
    bucket[COLUMN_ALTERNATE_GREETINGS_JSON] = JSON.stringify(character.alternateGreetings);
    bucket[COLUMN_TAGS_JSON] = JSON.stringify(character.tags);
    bucket[COLUMN_CREATOR] = character.creator;
    bucket[COLUMN_CHARACTER_VERSION] = character.characterVersion;
    bucket[COLUMN_EXTENSIONS_JSON] = JSON.stringify(character.extensions);
    bucket[COLUMN_CHARACTER_BOOK_ID] = character.characterBookId;
    bucket[COLUMN_SORT_ORDER] = character.sortOrder;
    bucket[COLUMN_USER_NAME] = character.userName;

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTERS);
    predicates.equalTo(COLUMN_ID, character.id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`character.update: ${extractCauseMessage(err)}`);
    }
    if (affected === 0) {
      throw DatabaseError.notFound('character.update');
    }
  }

  async remove(id: string): Promise<void> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('character.remove: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTERS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(`character.remove: ${extractCauseMessage(err)}`);
    }
  }

  async count(): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        `SELECT COUNT(*) AS cnt FROM ${TABLE_CHARACTERS}`
      );
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
    } catch (err) {
      throw DatabaseError.queryFailed(`character.count: ${extractCauseMessage(err)}`);
    }
  }

  async exists(id: string): Promise<boolean> {
    if (id.length === 0) {
      return false;
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTERS);
    predicates.equalTo(COLUMN_ID, id);
    try {
      const rs: relationalStore.ResultSet = await store.query(predicates);
      try {
        return rs.goToFirstRow();
      } finally {
        rs.close();
      }
    } catch (err) {
      throw DatabaseError.queryFailed(`character.exists: ${extractCauseMessage(err)}`);
    }
  }

  /**
   * 查询当前最大 sort_order(用于新建角色时分配新值)。
   * 空表返回 -1(新建角色 sortOrder = 0)。
   */
  async getMaxSortOrder(): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTERS);
    predicates.orderByDesc(COLUMN_SORT_ORDER);
    predicates.limitAs(1);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToNextRow()) {
        return -1;
      }
      const col: number = rs.getColumnIndex(COLUMN_SORT_ORDER);
      if (col < 0) {
        return -1;
      }
      return rs.getLong(col);
    } finally {
      rs.close();
    }
  }

  /**
   * 交换两个角色的 sort_order(用于上移/下移)。
   * 使用事务保证原子性。
   */
  async swapSortOrder(idA: string, idB: string): Promise<void> {
    if (idA.length === 0 || idB.length === 0 || idA === idB) {
      throw DatabaseError.invalidData('swapSortOrder: invalid ids');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.dbHelper.runInTransaction(
      async (s: relationalStore.RdbStore): Promise<void> => {
        const orderA: number = await this.getSortOrderByIdWithStore(s, idA);
        const orderB: number = await this.getSortOrderByIdWithStore(s, idB);
        await this.updateSortOrderWithStore(s, idA, orderB);
        await this.updateSortOrderWithStore(s, idB, orderA);
      },
      'character_swap_sort_order'
    );
  }

  private async getSortOrderByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTERS);
    predicates.equalTo(COLUMN_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToNextRow()) {
        throw DatabaseError.notFound('character not found');
      }
      const col: number = rs.getColumnIndex(COLUMN_SORT_ORDER);
      if (col < 0) {
        return 0;
      }
      return rs.getLong(col);
    } finally {
      rs.close();
    }
  }

  private async updateSortOrderWithStore(
    store: relationalStore.RdbStore,
    id: string,
    sortOrder: number
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHARACTERS);
    predicates.equalTo(COLUMN_ID, id);
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_SORT_ORDER] = sortOrder;
    await store.update(bucket, predicates);
  }

  /**
   * 事务批量导入:按 Character ID 判定,已存在则跳过。
   *
   * - 必须使用事务
   * - 已存在 ID 跳过(不覆盖)
   * - 任意新记录插入失败则整批新增部分回滚
   * - 已存在的记录不受影响
   * - 空数组直接返回
   * - 重复执行结果确定
   * - 不生成新 ID(迁移时保留原 ID)
   * - 不修改输入数组或 Character 对象
   */
  async insertManyIfMissing(
    characters: Character[]
  ): Promise<CharacterImportResult> {
    if (characters.length === 0) {
      return {
        insertedCount: 0,
        skippedExistingCount: 0,
        totalCount: 0
      };
    }

    // 事务前预校验所有记录
    for (let i = 0; i < characters.length; i++) {
      this.validateCharacter(characters[i]);
    }

    let inserted: number = 0;
    let skipped: number = 0;
    const total: number = characters.length;

    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        for (let i = 0; i < characters.length; i++) {
          const c: Character = characters[i];
          // 检查是否已存在(事务内)
          const predicates: relationalStore.RdbPredicates =
            new relationalStore.RdbPredicates(TABLE_CHARACTERS);
          predicates.equalTo(COLUMN_ID, c.id);
          const existRs: relationalStore.ResultSet = await store.query(predicates);
          let alreadyExists: boolean = false;
          try {
            alreadyExists = existRs.goToFirstRow();
          } finally {
            existRs.close();
          }
          if (alreadyExists) {
            skipped++;
            continue;
          }
          try {
            await store.insert(TABLE_CHARACTERS, characterToBucket(c));
            inserted++;
          } catch (err) {
            if (isConstraintViolation(err)) {
              // 并发情况下可能刚好被插入,计为跳过
              skipped++;
              continue;
            }
            // 其他错误转换为 DatabaseError,触发事务回滚
            throw DatabaseError.queryFailed(
              `character.insertManyIfMissing: ${extractCauseMessage(err)}`
            );
          }
        }
      }
    );

    return {
      insertedCount: inserted,
      skippedExistingCount: skipped,
      totalCount: total
    };
  }
}
