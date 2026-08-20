/**
 * PromptPresetRepository
 *
 * 职责:
 * - PromptPreset 的 CRUD 操作
 * - 列表稳定排序(updated_at DESC, id ASC)
 * - 安全校验和行映射,损坏数据抛 InvalidData
 * - 不打印 Preset 字段
 *
 * 不负责:
 * - 当前 Preset 选择(见 PromptPresetSelectionStore)
 * - 业务逻辑(见 PromptPresetService)
 * - 宏替换 / Prompt 注入 / Chat 接入
 *
 * 规则:
 * - insert 时 ID 重复映射为 AlreadyExists
 * - update 时 id 不可修改,不存在返回 NotFound
 * - remove 幂等
 * - 不修改输入 PromptPreset 对象
 * - ResultSet 所有路径关闭
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { PromptPreset } from '../models/PromptPreset';
import { DatabaseError } from '../models/DatabaseError';
import { validatePromptPreset } from '../models/PromptPreset';
import {
  TABLE_PROMPT_PRESETS,
  COLUMN_PRESET_ID,
  COLUMN_PRESET_NAME,
  COLUMN_PRESET_DESCRIPTION,
  COLUMN_PRESET_SYSTEM_PROMPT,
  COLUMN_PRESET_TEMPERATURE,
  COLUMN_PRESET_TOP_P,
  COLUMN_PRESET_MAX_OUTPUT_TOKENS,
  COLUMN_PRESET_CONTEXT_WINDOW,
  COLUMN_PRESET_UPDATED_AT
} from '../database/DatabaseConstants';
import {
  promptPresetFromRow,
  buildPromptPresetValues
} from './PromptPresetRepositoryMapper';
import {
  extractCauseMessage,
  isConstraintViolation
} from './RepositoryMappers';

const LOG_TAG: string = 'PromptPresetRepository';

export class PromptPresetRepository {
  private readonly dbHelper: DbHelper;

  constructor(dbHelper: DbHelper) {
    this.dbHelper = dbHelper;
  }

  async insert(preset: PromptPreset): Promise<void> {
    validatePromptPreset(preset);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = buildPromptPresetValues(preset);
    try {
      await store.insert(TABLE_PROMPT_PRESETS, bucket);
    } catch (err) {
      if (isConstraintViolation(err)) {
        throw DatabaseError.alreadyExists('preset.insert');
      }
      throw DatabaseError.queryFailed(
        `preset.insert: ${extractCauseMessage(err)}`
      );
    }
  }

  async getById(id: string): Promise<PromptPreset | null> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('preset.getById: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PROMPT_PRESETS);
    predicates.equalTo(COLUMN_PRESET_ID, id);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      if (!rs.goToFirstRow()) {
        return null;
      }
      return promptPresetFromRow(rs);
    } finally {
      rs.close();
    }
  }

  async list(): Promise<PromptPreset[]> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PROMPT_PRESETS);
    predicates.orderByDesc(COLUMN_PRESET_UPDATED_AT);
    predicates.orderByAsc(COLUMN_PRESET_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    try {
      const presets: PromptPreset[] = [];
      while (rs.goToNextRow()) {
        presets.push(promptPresetFromRow(rs));
      }
      return presets;
    } finally {
      rs.close();
    }
  }

  async update(preset: PromptPreset): Promise<void> {
    validatePromptPreset(preset);
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const bucket: relationalStore.ValuesBucket = {};
    bucket[COLUMN_PRESET_NAME] = preset.name;
    bucket[COLUMN_PRESET_DESCRIPTION] = preset.description;
    bucket[COLUMN_PRESET_SYSTEM_PROMPT] = preset.systemPrompt;
    bucket[COLUMN_PRESET_TEMPERATURE] = preset.temperature !== undefined
      ? preset.temperature
      : null;
    bucket[COLUMN_PRESET_TOP_P] = preset.topP !== undefined
      ? preset.topP
      : null;
    bucket[COLUMN_PRESET_MAX_OUTPUT_TOKENS] = preset.maxOutputTokens !== undefined
      ? preset.maxOutputTokens
      : null;
    bucket[COLUMN_PRESET_CONTEXT_WINDOW] = preset.contextWindow !== undefined
      ? preset.contextWindow
      : null;
    bucket[COLUMN_PRESET_UPDATED_AT] = preset.updatedAt;

    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PROMPT_PRESETS);
    predicates.equalTo(COLUMN_PRESET_ID, preset.id);

    let affected: number;
    try {
      affected = await store.update(bucket, predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `preset.update: ${extractCauseMessage(err)}`
      );
    }
    if (affected === 0) {
      throw DatabaseError.notFound('preset.update');
    }
  }

  async remove(id: string): Promise<void> {
    if (id.length === 0) {
      throw DatabaseError.invalidData('preset.remove: id empty');
    }
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PROMPT_PRESETS);
    predicates.equalTo(COLUMN_PRESET_ID, id);
    try {
      await store.delete(predicates);
    } catch (err) {
      throw DatabaseError.queryFailed(
        `preset.remove: ${extractCauseMessage(err)}`
      );
    }
  }

  async count(): Promise<number> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    const rs: relationalStore.ResultSet = await store.querySql(
      `SELECT COUNT(*) AS cnt FROM ${TABLE_PROMPT_PRESETS}`
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
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_PROMPT_PRESETS);
    predicates.equalTo(COLUMN_PRESET_ID, id);
    try {
      const rs: relationalStore.ResultSet = await store.query(predicates);
      try {
        return rs.goToFirstRow();
      } finally {
        rs.close();
      }
    } catch (err) {
      throw DatabaseError.queryFailed(
        `preset.exists: ${extractCauseMessage(err)}`
      );
    }
  }
}