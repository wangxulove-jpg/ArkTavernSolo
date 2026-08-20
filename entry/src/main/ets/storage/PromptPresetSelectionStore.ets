/**
 * PromptPresetSelectionStore 已选 Preset 集合存储
 *
 * 职责:
 * - 读取/设置/清空已选 Preset ID 集合(支持多选)
 * - 不保存 Preset 实体、systemPrompt、参数
 * - 不依赖 RDB、不依赖页面
 *
 * 约束:
 * - 设置非空 ID 前由 PromptPresetService 验证 Repository 中存在
 * - 空集合表示不使用 Preset
 * - 兼容旧的单选格式(单个 ID 字符串),首次读取时自动迁移
 */

import { AppPreferences } from './AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetSelectionStore';
const KEY_SELECTED_PRESET_IDS: string = 'selected_prompt_preset_ids_v1';
const KEY_LEGACY_CURRENT_PRESET_ID: string = 'current_prompt_preset_id_v1';

export class PromptPresetSelectionStore {
  private readonly prefs: AppPreferences;
  private initialized: boolean = false;

  constructor(prefs: AppPreferences) {
    this.prefs = prefs;
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('PromptPresetSelectionStore not initialized');
    }
  }

  async getSelectedPresetIds(): Promise<string[]> {
    this.requireInit();
    let raw: string;
    try {
      raw = await this.prefs.getString(KEY_SELECTED_PRESET_IDS, '');
    } catch (e) {
      Logger.warn(LOG_TAG, 'getSelectedPresetIds failed: ' + String(e));
      return [];
    }
    if (raw.length > 0) {
      const ids: string[] = this.parseIdList(raw);
      if (ids.length > 0) {
        return ids;
      }
    }
    // 新键为空时,尝试迁移旧的单选格式
    return await this.migrateLegacy();
  }

  async setSelectedPresetIds(ids: string[]): Promise<void> {
    this.requireInit();
    const deduped: string[] = this.dedupe(ids);
    if (deduped.length === 0) {
      await this.prefs.putString(KEY_SELECTED_PRESET_IDS, '');
    } else {
      await this.prefs.putString(KEY_SELECTED_PRESET_IDS, JSON.stringify(deduped));
    }
    // 迁移完成后旧键不再生效
    await this.prefs.putString(KEY_LEGACY_CURRENT_PRESET_ID, '');
  }

  async clear(): Promise<void> {
    this.requireInit();
    await this.prefs.putString(KEY_SELECTED_PRESET_IDS, '');
    await this.prefs.putString(KEY_LEGACY_CURRENT_PRESET_ID, '');
  }

  private parseIdList(raw: string): string[] {
    let parsed: Object;
    try {
      parsed = JSON.parse(raw);
    } catch (e) {
      return [];
    }
    if (!Array.isArray(parsed)) {
      return [];
    }
    const result: string[] = [];
    const arr: Object[] = parsed as Object[];
    for (let i = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string') {
        const id: string = arr[i] as string;
        if (id.length > 0) {
          result.push(id);
        }
      }
    }
    return this.dedupe(result);
  }

  private async migrateLegacy(): Promise<string[]> {
    let legacy: string;
    try {
      legacy = await this.prefs.getString(KEY_LEGACY_CURRENT_PRESET_ID, '');
    } catch (e) {
      return [];
    }
    if (legacy.length === 0) {
      return [];
    }
    const migrated: string[] = [legacy];
    await this.setSelectedPresetIds(migrated);
    return migrated;
  }

  private dedupe(ids: string[]): string[] {
    const result: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      if (id.length === 0) {
        continue;
      }
      let exists: boolean = false;
      for (let j = 0; j < result.length; j++) {
        if (result[j] === id) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        result.push(id);
      }
    }
    return result;
  }
}
