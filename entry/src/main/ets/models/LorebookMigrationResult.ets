/**
 * LorebookMigrationResult 迁移统计模型
 *
 * 仅包含统计数据,不包含 Lorebook ID、名称、keys、content 等敏感信息。
 */
export interface LorebookMigrationResult {
  readonly attempted: boolean;
  readonly legacyLorebookCount: number;
  readonly legacyEntryCount: number;
  readonly insertedLorebookCount: number;
  readonly insertedEntryCount: number;
  readonly skippedExistingLorebookCount: number;
  readonly currentLorebookPreserved: boolean;
  readonly completed: boolean;
}

/**
 * 创建已完成的迁移结果。
 */
export function makeCompletedResult(
  legacyLorebookCount: number,
  legacyEntryCount: number,
  insertedLorebookCount: number,
  insertedEntryCount: number,
  skippedExistingLorebookCount: number,
  currentLorebookPreserved: boolean
): LorebookMigrationResult {
  return {
    attempted: true,
    legacyLorebookCount: legacyLorebookCount,
    legacyEntryCount: legacyEntryCount,
    insertedLorebookCount: insertedLorebookCount,
    insertedEntryCount: insertedEntryCount,
    skippedExistingLorebookCount: skippedExistingLorebookCount,
    currentLorebookPreserved: currentLorebookPreserved,
    completed: true
  };
}

/**
 * 创建跳过的迁移结果(marker 已为 true)。
 */
export function makeSkippedResult(): LorebookMigrationResult {
  return {
    attempted: false,
    legacyLorebookCount: 0,
    legacyEntryCount: 0,
    insertedLorebookCount: 0,
    insertedEntryCount: 0,
    skippedExistingLorebookCount: 0,
    currentLorebookPreserved: false,
    completed: false
  };
}