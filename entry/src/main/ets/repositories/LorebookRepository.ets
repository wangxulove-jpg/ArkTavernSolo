/**
 * LorebookRepository
 *
 * 职责:
 * - Lorebook 聚合 CRUD(主记录 + Entries)
 * - 事务管理
 * - 聚合更新为差量同步
 * - 删除 Lorebook 同时删除 Entries
 *
 * 不负责:
 * - 当前 Lorebook 选择(Persisted 在 Preferences)
 * - 关键词匹配
 * - Prompt 注入
 * - 业务逻辑
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { Lorebook, LorebookEntry } from '../models/Lorebook';
import { DatabaseError } from '../models/DatabaseError';
import {
  TABLE_LOREBOOKS,
  TABLE_LOREBOOK_ENTRIES,
  COLUMN_LOREBOOK_ID,
  COLUMN_ENTRY_ID,
  COLUMN_ENTRY_LOREBOOK_ID,
  COLUMN_ENTRY_PRIORITY,
  COLUMN_ENTRY_CREATED_AT,
  COLUMN_LOREBOOK_CREATED_AT,
  COLUMN_LOREBOOK_UPDATED_AT
} from '../database/DatabaseConstants';
import {
  lorebookFromMainRow,
  lorebookEntryFromRow,
  lorebookToBucket,
  lorebookEntryToBucket,
  validateLorebook,
  validateLorebookEntry
} from './LorebookRepositoryMapper';
import {
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

const LOG_TAG: string = 'LorebookRepository';

export interface LorebookImportResult {
  readonly insertedLorebookCount: number;
  readonly insertedEntryCount: number;
  readonly skippedExistingLorebookCount: number;
  readonly totalLorebookCount: number;
  readonly totalEntryCount: number;
}

export class LorebookRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async insert(lorebook: Lorebook): Promise<void> {
    validateLorebook(lorebook);
    for (let i = 0; i < lorebook.entries.length; i++) {
      validateLorebookEntry(lorebook.entries[i]);
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.insertWithStore(store, lorebook);
  }

  async insertWithStore(
    store: relationalStore.RdbStore,
    lorebook: Lorebook
  ): Promise<void> {
    try {
      await store.insert(TABLE_LOREBOOKS, lorebookToBucket(lorebook));
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('lorebook.insert');
      }
      throw DatabaseError.queryFailed(
        `lorebook.insert: ${extractCauseMessage(err)}`
      );
    }
    for (let i = 0; i < lorebook.entries.length; i++) {
      const entry: LorebookEntry = lorebook.entries[i];
      try {
        await store.insert(
          TABLE_LOREBOOK_ENTRIES,
          lorebookEntryToBucket(entry, lorebook.id)
        );
      } catch (err) {
        if (isConstraintViolation(err)) {
          throw DatabaseError.constraintFailed('lorebook.insert.entry');
        }
        throw DatabaseError.queryFailed(
          `lorebook.insert.entry: ${extractCauseMessage(err)}`
        );
      }
    }
  }

  async getById(id: string): Promise<Lorebook | null> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOKS);
    predicates.equalTo(COLUMN_LOREBOOK_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      const lorebook: Lorebook = lorebookFromMainRow(rs);
      const entries: LorebookEntry[] = await this.listEntriesByLorebookId(
        store,
        id
      );
      return {
        id: lorebook.id,
        name: lorebook.name,
        description: lorebook.description,
        enabled: lorebook.enabled,
        entries: entries,
        createdAt: lorebook.createdAt,
        updatedAt: lorebook.updatedAt
      };
    } finally {
      rs.close();
    }
  }

  async list(): Promise<Lorebook[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const lorebooks: Lorebook[] = [];
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOKS);
    predicates.orderByAsc(COLUMN_LOREBOOK_CREATED_AT);
    predicates.orderByAsc(COLUMN_LOREBOOK_UPDATED_AT);
    predicates.orderByAsc(COLUMN_LOREBOOK_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      while (rs.goToNextRow()) {
        lorebooks.push(lorebookFromMainRow(rs));
      }
    } finally {
      rs.close();
    }

    if (lorebooks.length === 0) {
      return [];
    }

    // 读取所有 Entry 及其 lorebook_id,在内存按 lorebookId 分组
    const entryGroups: Map<string, LorebookEntry[]> = new Map();
    const entryPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOK_ENTRIES);
    entryPredicates.orderByDesc(COLUMN_ENTRY_PRIORITY);
    entryPredicates.orderByAsc(COLUMN_ENTRY_CREATED_AT);
    entryPredicates.orderByAsc(COLUMN_ENTRY_ID);
    const entryRs: relationalStore.ResultSet = await store.query(entryPredicates);
    try {
      while (entryRs.goToNextRow()) {
        const entry: LorebookEntry = lorebookEntryFromRow(entryRs);
        const lid: string = entryRs.getString(
          entryRs.getColumnIndex(COLUMN_ENTRY_LOREBOOK_ID)
        );
        let group: LorebookEntry[] | undefined = entryGroups.get(lid);
        if (group === undefined) {
          group = [];
          entryGroups.set(lid, group);
        }
        group.push(entry);
      }
    } finally {
      entryRs.close();
    }

    const result: Lorebook[] = [];
    for (let i = 0; i < lorebooks.length; i++) {
      const book: Lorebook = lorebooks[i];
      const entries: LorebookEntry[] | undefined = entryGroups.get(book.id);
      result.push({
        id: book.id,
        name: book.name,
        description: book.description,
        enabled: book.enabled,
        entries: entries !== undefined ? entries : [],
        createdAt: book.createdAt,
        updatedAt: book.updatedAt
      });
    }
    return result;
  }

  async update(lorebook: Lorebook): Promise<void> {
    validateLorebook(lorebook);
    for (let i = 0; i < lorebook.entries.length; i++) {
      validateLorebookEntry(lorebook.entries[i]);
    }

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.dbHelper.runInTransaction(
      async (txStore: relationalStore.RdbStore): Promise<void> => {
        // 1. 确认 Lorebook 存在
        const existing: Lorebook | null = await this.getByIdWithStore(
          txStore,
          lorebook.id
        );
        if (existing === null) {
          throw DatabaseError.notFound('lorebook.update');
        }

        // 2. 更新主记录
        const bucket: relationalStore.ValuesBucket = lorebookToBucket(lorebook);
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_LOREBOOKS);
        predicates.equalTo(COLUMN_LOREBOOK_ID, lorebook.id);
        let affected: number;
        try {
          affected = await txStore.update(bucket, predicates);
        } catch (err) {
          throw DatabaseError.queryFailed(
            `lorebook.update: ${extractCauseMessage(err)}`
          );
        }
        if (affected === 0) {
          throw DatabaseError.notFound('lorebook.update');
        }

        // 3. 读取数据库已有 Entry ID
        const dbEntryIds: Set<string> = new Set();
        for (let i = 0; i < existing.entries.length; i++) {
          dbEntryIds.add(existing.entries[i].id);
        }

        // 4. 输入 Entry ID
        const inputEntryIds: Set<string> = new Set();
        for (let i = 0; i < lorebook.entries.length; i++) {
          const eid: string = lorebook.entries[i].id;
          if (inputEntryIds.has(eid)) {
            throw DatabaseError.invalidData('duplicate entry id in input');
          }
          inputEntryIds.add(eid);
        }

        // 5. 删除:DB 存在但输入不存在
        for (let i = 0; i < existing.entries.length; i++) {
          const dbId: string = existing.entries[i].id;
          if (!inputEntryIds.has(dbId)) {
            await this.removeEntryWithStore(txStore, dbId);
          }
        }

        // 6. 插入/更新:输入存在的
        for (let i = 0; i < lorebook.entries.length; i++) {
          const entry: LorebookEntry = lorebook.entries[i];
          if (dbEntryIds.has(entry.id)) {
            // 更新
            await this.updateEntryWithStore(
              txStore,
              entry,
              lorebook.id
            );
          } else {
            // 验证 Entry ID 不属于其他 Lorebook
            const owner: string | null = await this.findEntryOwner(
              txStore,
              entry.id
            );
            if (owner !== null) {
              throw DatabaseError.constraintFailed(
                'entry id belongs to another lorebook'
              );
            }
            // 插入
            await this.insertEntryWithStore(
              txStore,
              entry,
              lorebook.id
            );
          }
        }
      }
    );
  }

  async remove(id: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.dbHelper.runInTransaction(
      async (txStore: relationalStore.RdbStore): Promise<void> => {
        // 先检查是否存在
        const exists: boolean = await this.existsWithStore(txStore, id);
        if (!exists) {
          return;
        }
        // 删除所有 Entries
        const entryPredicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_LOREBOOK_ENTRIES);
        entryPredicates.equalTo(COLUMN_ENTRY_LOREBOOK_ID, id);
        try {
          await txStore.delete(entryPredicates);
        } catch (err) {
          throw DatabaseError.queryFailed(
            `lorebook.remove.entries: ${extractCauseMessage(err)}`
          );
        }
        // 删除 Lorebook
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_LOREBOOKS);
        predicates.equalTo(COLUMN_LOREBOOK_ID, id);
        try {
          await txStore.delete(predicates);
        } catch (err) {
          throw DatabaseError.queryFailed(
            `lorebook.remove: ${extractCauseMessage(err)}`
          );
        }
      }
    );
  }

  async count(): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS cnt FROM ${TABLE_LOREBOOKS}`
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
  }

  async exists(id: string): Promise<boolean> {
    if (id.length === 0) {
      return false;
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    return await this.existsWithStore(store, id);
  }

  // ===== Internal Methods =====

  private async existsWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<boolean> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOKS);
    predicates.equalTo(COLUMN_LOREBOOK_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      return rs.goToFirstRow();
    } finally {
      rs.close();
    }
  }

  private async getByIdWithStore(
    store: relationalStore.RdbStore,
    id: string
  ): Promise<Lorebook | null> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOKS);
    predicates.equalTo(COLUMN_LOREBOOK_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      const lorebook: Lorebook = lorebookFromMainRow(rs);
      const entries: LorebookEntry[] = await this.listEntriesByLorebookId(
        store,
        id
      );
      return {
        id: lorebook.id,
        name: lorebook.name,
        description: lorebook.description,
        enabled: lorebook.enabled,
        entries: entries,
        createdAt: lorebook.createdAt,
        updatedAt: lorebook.updatedAt
      };
    } finally {
      rs.close();
    }
  }

  private async insertEntryWithStore(
    store: relationalStore.RdbStore,
    entry: LorebookEntry,
    lorebookId: string
  ): Promise<void> {
    try {
      await store.insert(
        TABLE_LOREBOOK_ENTRIES,
        lorebookEntryToBucket(entry, lorebookId)
      );
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.constraintFailed('lorebook.insertEntry');
      }
      throw DatabaseError.queryFailed(
        `lorebook.insertEntry: ${extractCauseMessage(err)}`
      );
    }
  }

  private async updateEntryWithStore(
    store: relationalStore.RdbStore,
    entry: LorebookEntry,
    lorebookId: string
  ): Promise<void> {
    const bucket: relationalStore.ValuesBucket =
      lorebookEntryToBucket(entry, lorebookId);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOK_ENTRIES);
    predicates.equalTo(COLUMN_ENTRY_ID, entry.id);
    try {
      await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `lorebook.updateEntry: ${extractCauseMessage(err)}`
      );
    }
  }

  private async removeEntryWithStore(
    store: relationalStore.RdbStore,
    entryId: string
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOK_ENTRIES);
    predicates.equalTo(COLUMN_ENTRY_ID, entryId);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `lorebook.removeEntry: ${extractCauseMessage(err)}`
      );
    }
  }

  private async listEntriesByLorebookId(
    store: relationalStore.RdbStore,
    lorebookId: string
  ): Promise<LorebookEntry[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOK_ENTRIES);
    predicates.equalTo(COLUMN_ENTRY_LOREBOOK_ID, lorebookId);
    predicates.orderByDesc(COLUMN_ENTRY_PRIORITY);
    predicates.orderByAsc(COLUMN_ENTRY_CREATED_AT);
    predicates.orderByAsc(COLUMN_ENTRY_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const entries: LorebookEntry[] = [];
      while (rs.goToNextRow()) {
        entries.push(lorebookEntryFromRow(rs));
      }
      return entries;
    } finally {
      rs.close();
    }
  }

  private async listAllEntries(
    store: relationalStore.RdbStore
  ): Promise<LorebookEntry[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOK_ENTRIES);
    predicates.orderByDesc(COLUMN_ENTRY_PRIORITY);
    predicates.orderByAsc(COLUMN_ENTRY_CREATED_AT);
    predicates.orderByAsc(COLUMN_ENTRY_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const entries: LorebookEntry[] = [];
      while (rs.goToNextRow()) {
        entries.push(lorebookEntryFromRow(rs));
      }
      return entries;
    } finally {
      rs.close();
    }
  }

  private async findEntryOwner(
    store: relationalStore.RdbStore,
    entryId: string
  ): Promise<string | null> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_LOREBOOK_ENTRIES);
    predicates.equalTo(COLUMN_ENTRY_ID, entryId);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      const ci: number = rs.getColumnIndex(COLUMN_ENTRY_LOREBOOK_ID);
      if (ci < 0) {
        return null;
      }
      return rs.getString(ci);
    } finally {
      rs.close();
    }
  }

  async insertManyIfMissing(
    lorebooks: Lorebook[]
  ): Promise<LorebookImportResult> {
    if (lorebooks.length === 0) {
      return {
        insertedLorebookCount: 0,
        insertedEntryCount: 0,
        skippedExistingLorebookCount: 0,
        totalLorebookCount: 0,
        totalEntryCount: 0
      };
    }

    // 预校验全部 Lorebook 和 Entry
    for (let i = 0; i < lorebooks.length; i++) {
      validateLorebook(lorebooks[i]);
      for (let j = 0; j < lorebooks[i].entries.length; j++) {
        validateLorebookEntry(lorebooks[i].entries[j]);
      }
    }

    // 检查 legacy 输入内是否有重复 Lorebook ID
    const legacyIds: Set<string> = new Set();
    for (let i = 0; i < lorebooks.length; i++) {
      if (legacyIds.has(lorebooks[i].id)) {
        throw DatabaseError.invalidData('duplicate lorebook id in input');
      }
      legacyIds.add(lorebooks[i].id);
    }

    // 检查 legacy 输入内是否有重复 Entry ID
    const allEntryIds: Set<string> = new Set();
    for (let i = 0; i < lorebooks.length; i++) {
      for (let j = 0; j < lorebooks[i].entries.length; j++) {
        const eid: string = lorebooks[i].entries[j].id;
        if (allEntryIds.has(eid)) {
          throw DatabaseError.invalidData('duplicate entry id in input');
        }
        allEntryIds.add(eid);
      }
    }

    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    let insertedLorebookCount: number = 0;
    let insertedEntryCount: number = 0;
    let skippedExistingLorebookCount: number = 0;

    await this.dbHelper.runInTransaction(
      async (txStore: relationalStore.RdbStore): Promise<void> => {
        // 查询已存在的 Lorebook
        const existingIds: Set<string> = new Set();
        for (let i = 0; i < lorebooks.length; i++) {
          const exists: boolean = await this.existsWithStore(
            txStore,
            lorebooks[i].id
          );
          if (exists) {
            existingIds.add(lorebooks[i].id);
            skippedExistingLorebookCount++;
          }
        }

        // 对缺失的 Lorebook 插入完整聚合
        for (let i = 0; i < lorebooks.length; i++) {
          const lb: Lorebook = lorebooks[i];
          if (existingIds.has(lb.id)) {
            continue;
          }
          await this.insertWithStore(txStore, lb);
          insertedLorebookCount++;
          insertedEntryCount += lb.entries.length;
        }
      }
    );

    return {
      insertedLorebookCount: insertedLorebookCount,
      insertedEntryCount: insertedEntryCount,
      skippedExistingLorebookCount: skippedExistingLorebookCount,
      totalLorebookCount: lorebooks.length,
      totalEntryCount: allEntryIds.size
    };
  }
}