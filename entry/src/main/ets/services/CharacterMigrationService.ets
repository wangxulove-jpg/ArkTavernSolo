/**
 * CharacterMigrationService 角色数据迁移服务
 *
 * 职责:
 * - 检查迁移标记(character_rdb_migration_v1_complete)
 * - 读取旧 Preferences Character 列表
 * - 调用 CharacterRepository.insertManyIfMissing 导入 RDB
 * - 验证迁移结果(每个旧 ID 在 RDB 中存在)
 * - 检查当前角色 ID 指向的角色是否存在
 * - 设置迁移完成标记
 *
 * 不负责:
 * - UI
 * - 角色编辑
 * - PNG / JSON 解析
 * - 头像删除
 * - Chat 删除
 * - 删除旧 Preferences 数据
 *
 * 幂等性:
 * - 迁移标记为 true 时直接返回
 * - 中途崩溃后下次启动重新执行
 * - 已存在 ID 跳过,不产生重复角色
 * - 不生成新 ID,迁移时保留原 Character ID
 *
 * 日志:
 * - 只输出计数和状态
 * - 不输出角色 ID、名称、正文、avatarUri
 */
import { CharacterStore } from '../storage/CharacterStore';
import { CharacterSelectionStore } from '../storage/CharacterSelectionStore';
import { AppPreferences } from '../storage/AppPreferences';
import { CharacterRepository, CharacterImportResult } from '../repositories/CharacterRepository';
import { CharacterMigrationResult, createSkippedMigrationResult } from '../models/CharacterMigrationResult';
import { Character } from '../models/Character';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterMigration';
const MIGRATION_MARKER_KEY: string = 'character_rdb_migration_v1_complete';

export class CharacterMigrationService {
  private readonly characterStore: CharacterStore;
  private readonly characterRepository: CharacterRepository;
  private readonly characterSelectionStore: CharacterSelectionStore;
  private readonly appPreferences: AppPreferences;

  constructor(
    characterStore: CharacterStore,
    characterRepository: CharacterRepository,
    characterSelectionStore: CharacterSelectionStore,
    appPreferences: AppPreferences
  ) {
    this.characterStore = characterStore;
    this.characterRepository = characterRepository;
    this.characterSelectionStore = characterSelectionStore;
    this.appPreferences = appPreferences;
  }

  /**
   * 如果迁移标记未设置,执行迁移。
   * 已完成时直接返回 skipped 结果。
   *
   * @returns 迁移结果
   */
  async migrateIfNeeded(): Promise<CharacterMigrationResult> {
    const completed: boolean = await this.appPreferences.getBoolean(MIGRATION_MARKER_KEY, false);
    if (completed) {
      return createSkippedMigrationResult();
    }

    // 1. 读取旧 Preferences Character
    const legacyCharacters: Character[] = await this.characterStore.list();
    const legacyCount: number = legacyCharacters.length;

    // 2. 读取当前角色 ID
    const currentId: string | null = await this.characterStore.getCurrentCharacterId();

    // 3. 导入 RDB(insertManyIfMissing)
    const importResult: CharacterImportResult =
      await this.characterRepository.insertManyIfMissing(legacyCharacters);

    // 4. 验证迁移结果:每个旧角色 ID 在 RDB 中存在
    const allExist: boolean = await this.verifyAllExist(legacyCharacters);
    if (!allExist) {
      Logger.error(LOG_TAG, 'verify failed, not all legacy ids exist in RDB');
      // 不写标记,允许下次重试
      return {
        attempted: true,
        legacyCount: legacyCount,
        insertedCount: importResult.insertedCount,
        skippedExistingCount: importResult.skippedExistingCount,
        currentCharacterPreserved: false,
        completed: false
      };
    }

    // 5. 检查当前角色 ID
    let currentPreserved: boolean = true;
    if (currentId !== null && currentId.length > 0) {
      const exists: boolean = await this.characterRepository.exists(currentId);
      if (exists) {
        // 保留当前选择(迁移到 CharacterSelectionStore,与旧 CharacterStore 同 key)
        await this.characterSelectionStore.setCurrentCharacterId(currentId);
        currentPreserved = true;
      } else {
        // 当前角色 ID 指向不存在的角色,清空选择
        await this.characterSelectionStore.setCurrentCharacterId(null);
        currentPreserved = false;
      }
    } else {
      // 未设置当前角色,无需迁移
      currentPreserved = true;
    }

    // 6. 写入完成标记
    await this.appPreferences.putBoolean(MIGRATION_MARKER_KEY, true);

    return {
      attempted: true,
      legacyCount: legacyCount,
      insertedCount: importResult.insertedCount,
      skippedExistingCount: importResult.skippedExistingCount,
      currentCharacterPreserved: currentPreserved,
      completed: true
    };
  }

  /**
   * 验证每个旧角色 ID 在 RDB 中存在。
   */
  private async verifyAllExist(characters: Character[]): Promise<boolean> {
    for (let i = 0; i < characters.length; i++) {
      const exists: boolean = await this.characterRepository.exists(characters[i].id);
      if (!exists) {
        return false;
      }
    }
    return true;
  }
}
