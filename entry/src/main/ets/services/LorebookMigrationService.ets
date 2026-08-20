/**
 * LorebookMigrationService 世界书 Preferences→RDB 迁移服务
 *
 * 职责:
 * - 检查迁移 marker
 * - 从 Legacy LorebookStore 读取旧数据
 * - 调用 Repository 迁移
 * - 验证迁移完整性
 * - 检查当前世界书 ID
 * - 写入 marker
 * - 返回迁移统计
 *
 * 不负责:
 * - 页面状态
 * - 世界书匹配
 * - Prompt 注入
 * - CRUD
 * - 当前聊天
 * - Token 计算
 */

import { Lorebook, LorebookEntry } from '../models/Lorebook';
import { LorebookStore } from '../storage/LorebookStore';
import { LorebookSelectionStore } from '../storage/LorebookSelectionStore';
import { LorebookRepository, LorebookImportResult } from '../repositories/LorebookRepository';
import { AppPreferences } from '../storage/AppPreferences';
import {
  LorebookMigrationResult,
  makeCompletedResult,
  makeSkippedResult
} from '../models/LorebookMigrationResult';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LorebookMigration';
const MARKER_KEY: string = 'lorebook_rdb_migration_v1_complete';

export class LorebookMigrationService {
  private readonly legacyStore: LorebookStore;
  private readonly repository: LorebookRepository;
  private readonly selectionStore: LorebookSelectionStore;
  private readonly appPreferences: AppPreferences;

  constructor(
    legacyStore: LorebookStore,
    repository: LorebookRepository,
    selectionStore: LorebookSelectionStore,
    appPreferences: AppPreferences
  ) {
    this.legacyStore = legacyStore;
    this.repository = repository;
    this.selectionStore = selectionStore;
    this.appPreferences = appPreferences;
  }

  async migrateIfNeeded(): Promise<LorebookMigrationResult> {
    // 1. 检查 marker
    const marker: boolean =
      await this.appPreferences.getBoolean(MARKER_KEY, false);
    if (marker) {
      return makeSkippedResult();
    }

    // 2. 从旧 LorebookStore 读取全部 Lorebook
    const legacyBooks: Lorebook[] = await this.legacyStore.list();
    let legacyEntryCount: number = 0;
    for (let i = 0; i < legacyBooks.length; i++) {
      legacyEntryCount += legacyBooks[i].entries.length;
    }

    // 3. 读取旧当前世界书 ID
    const oldCurrentId: string | null =
      await this.legacyStore.getCurrentLorebookId();

    // 4. 调用 repository.insertManyIfMissing()
    const importResult: LorebookImportResult =
      await this.repository.insertManyIfMissing(legacyBooks);

    // 5. 验证每个旧 Lorebook 和 Entry 均存在于 RDB
    await this.verifyMigration(legacyBooks);

    // 6. 检查当前世界书 ID
    let currentLorebookPreserved: boolean = false;
    if (oldCurrentId !== null && oldCurrentId.length > 0) {
      const rdbExists: boolean = await this.repository.exists(oldCurrentId);
      if (rdbExists) {
        currentLorebookPreserved = true;
      } else {
        // RDB 不存在,清空选择
        await this.selectionStore.setCurrentLorebookId(null);
        Logger.warn(LOG_TAG, 'current lorebook not found in RDB, cleared');
      }
    } else {
      // 旧 ID 为空,保持空
      currentLorebookPreserved = true;
    }

    // 7. 写 marker=true
    try {
      await this.appPreferences.putBoolean(MARKER_KEY, true);
    } catch (e) {
      Logger.error(LOG_TAG, 'marker write failed: ' + String(e));
      throw new Error('LorebookMigration marker write failed');
    }

    const result: LorebookMigrationResult = makeCompletedResult(
      legacyBooks.length,
      legacyEntryCount,
      importResult.insertedLorebookCount,
      importResult.insertedEntryCount,
      importResult.skippedExistingLorebookCount,
      currentLorebookPreserved
    );

    return result;
  }

  /**
   * 验证每个旧 Lorebook 和 Entry 均存在于 RDB。
   * 验证失败时抛出异常,不写 marker。
   */
  private async verifyMigration(legacyBooks: Lorebook[]): Promise<void> {
    for (let i = 0; i < legacyBooks.length; i++) {
      const legacyLb: Lorebook = legacyBooks[i];
      const rdbLb: Lorebook | null = await this.repository.getById(legacyLb.id);
      if (rdbLb === null) {
        throw new Error(`LorebookMigration verify: lorebook not found in RDB`);
      }

      // 验证每个 legacy Entry
      const rdbEntryIds: Set<string> = new Set();
      for (let j = 0; j < rdbLb.entries.length; j++) {
        rdbEntryIds.add(rdbLb.entries[j].id);
      }

      for (let j = 0; j < legacyLb.entries.length; j++) {
        const legacyEntry: LorebookEntry = legacyLb.entries[j];
        if (!rdbEntryIds.has(legacyEntry.id)) {
          throw new Error(`LorebookMigration verify: entry missing in RDB`);
        }
      }
    }
  }
}