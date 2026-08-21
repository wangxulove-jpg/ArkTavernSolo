/**
 * PersonaSelectionStore 全局默认 Persona ID 存储
 *
 * 复用 AppPreferences 存储 default_persona_id key,
 * 仅管理全局默认 Persona ID,不保存实体。
 * 不依赖 RDB,不依赖页面。
 */

import { AppPreferences } from './AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PersonaSelectionStore';
const KEY_DEFAULT_PERSONA_ID: string = 'default_persona_id_v1';

export class PersonaSelectionStore {
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
      throw new Error('PersonaSelectionStore not initialized');
    }
  }

  async getDefaultPersonaId(): Promise<string | null> {
    this.requireInit();
    try {
      const raw: string = await this.prefs.getString(KEY_DEFAULT_PERSONA_ID, '');
      if (raw.length === 0) {
        return null;
      }
      return raw;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getDefaultPersonaId failed: ' + String(e));
      return null;
    }
  }

  async setDefaultPersonaId(id: string | null): Promise<void> {
    this.requireInit();
    if (id !== null && id.length > 0) {
      await this.prefs.putString(KEY_DEFAULT_PERSONA_ID, id);
    } else {
      await this.prefs.putString(KEY_DEFAULT_PERSONA_ID, '');
    }
  }

  async clear(): Promise<void> {
    this.requireInit();
    await this.prefs.putString(KEY_DEFAULT_PERSONA_ID, '');
  }
}
