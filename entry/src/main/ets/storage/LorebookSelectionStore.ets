/**
 * LorebookSelectionStore 当前世界书选择存储
 *
 * 复用旧 Preferences 的 current_lorebook_id_v1 key,
 * 仅管理当前世界书 ID,不保存实体、Entry、keys 或 content。
 * 不依赖 RDB,不依赖页面。
 */

import { AppPreferences } from './AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LorebookSelectionStore';
const KEY_CURRENT_LOREBOOK_ID: string = 'current_lorebook_id_v1';

export class LorebookSelectionStore {
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
      throw new Error('LorebookSelectionStore not initialized');
    }
  }

  async getCurrentLorebookId(): Promise<string | null> {
    this.requireInit();
    try {
      const raw: string = await this.prefs.getString(KEY_CURRENT_LOREBOOK_ID, '');
      if (raw.length === 0) {
        return null;
      }
      return raw;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCurrentLorebookId failed: ' + String(e));
      return null;
    }
  }

  async setCurrentLorebookId(id: string | null): Promise<void> {
    this.requireInit();
    if (id !== null && id.length > 0) {
      await this.prefs.putString(KEY_CURRENT_LOREBOOK_ID, id);
    } else {
      await this.prefs.putString(KEY_CURRENT_LOREBOOK_ID, '');
    }
  }

  async clear(): Promise<void> {
    this.requireInit();
    await this.prefs.putString(KEY_CURRENT_LOREBOOK_ID, '');
  }
}