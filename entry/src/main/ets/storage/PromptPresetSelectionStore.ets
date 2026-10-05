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
import { isPromptPresetPosition } from '../models/PromptPreset';

const LOG_TAG: string = 'PromptPresetSelectionStore';
const KEY_SELECTED_PRESET_IDS: string = 'selected_prompt_preset_ids_v1';
const KEY_LEGACY_CURRENT_PRESET_ID: string = 'current_prompt_preset_id_v1';
/** v51: 预设 → 注入位置映射(presetId → 'head'|'tail') */
const KEY_PRESET_POSITIONS: string = 'prompt_preset_positions_v1';

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

  // ===== v51: 预设注入位置(本地偏好,与"是否选中"无关) =====

  /**
   * 读取"预设 → 注入位置"映射(presetId → 'head'|'tail')。
   * 解析失败或值非法时丢弃该项(调用方按默认 head 处理)。
   */
  async getPositions(): Promise<Record<string, string>> {
    this.requireInit();
    let raw: string;
    try {
      raw = await this.prefs.getString(KEY_PRESET_POSITIONS, '');
    } catch (e) {
      Logger.warn(LOG_TAG, 'getPositions failed: ' + String(e));
      return {};
    }
    return this.parsePositions(raw);
  }

  /**
   * 设置单个预设的注入位置(位置值非法或 id 为空则忽略)。
   */
  async setPosition(presetId: string, position: string): Promise<void> {
    this.requireInit();
    if (presetId.length === 0 || !isPromptPresetPosition(position)) {
      return;
    }
    try {
      const current: Record<string, string> = await this.getPositions();
      current[presetId] = position;
      await this.prefs.putString(KEY_PRESET_POSITIONS, JSON.stringify(current));
    } catch (e) {
      Logger.warn(LOG_TAG, 'setPosition failed: ' + String(e));
    }
  }

  /**
   * 移除单个预设的注入位置记录(删除预设时调用)。
   */
  async removePosition(presetId: string): Promise<void> {
    this.requireInit();
    if (presetId.length === 0) {
      return;
    }
    try {
      const current: Record<string, string> = await this.getPositions();
      const keys: string[] = Object.keys(current);
      const next: Record<string, string> = {};
      let changed: boolean = false;
      for (let i = 0; i < keys.length; i++) {
        if (keys[i] === presetId) {
          changed = true;
          continue;
        }
        next[keys[i]] = current[keys[i]];
      }
      if (changed) {
        await this.prefs.putString(KEY_PRESET_POSITIONS, JSON.stringify(next));
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'removePosition failed: ' + String(e));
    }
  }

  /** 解析位置映射 JSON;非法项丢弃。 */
  private parsePositions(raw: string): Record<string, string> {
    const result: Record<string, string> = {};
    if (raw.length === 0) {
      return result;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(raw);
    } catch (e) {
      return result;
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return result;
    }
    const record: Record<string, Object> = parsed as Record<string, Object>;
    const keys: string[] = Object.keys(record);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const value: Object = record[key];
      if (key.length > 0 && typeof value === 'string' && isPromptPresetPosition(value as string)) {
        result[key] = value as string;
      }
    }
    return result;
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
