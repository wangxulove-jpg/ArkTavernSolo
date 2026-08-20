/**
 * CharacterMigrationResult 迁移结果模型
 *
 * 用于 Preferences→RDB 迁移结果汇报。
 * 不包含角色名称、正文、avatarUri、角色 ID 完整列表,只返回计数。
 */
export interface CharacterMigrationResult {
  /** 是否实际尝试了迁移(false 表示已完成,直接跳过) */
  readonly attempted: boolean;
  /** 旧 Preferences 中读取到的角色数量 */
  readonly legacyCount: number;
  /** 实际插入 RDB 的角色数量 */
  readonly insertedCount: number;
  /** 因 ID 已存在而跳过的角色数量 */
  readonly skippedExistingCount: number;
  /** 当前角色 ID 是否仍指向 RDB 中存在的角色 */
  readonly currentCharacterPreserved: boolean;
  /** 迁移是否完成(标记已写入) */
  readonly completed: boolean;
}

/**
 * 创建未尝试的迁移结果(已完成,直接跳过)。
 */
export function createSkippedMigrationResult(): CharacterMigrationResult {
  return {
    attempted: false,
    legacyCount: 0,
    insertedCount: 0,
    skippedExistingCount: 0,
    currentCharacterPreserved: true,
    completed: true
  };
}
