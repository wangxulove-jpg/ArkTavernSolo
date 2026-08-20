/**
 * CharacterSelectionStore 当前角色选择存储
 *
 * 角色实体迁入 RDB 后,当前角色 ID 仍属于轻量用户偏好,继续使用 Preferences。
 * 复用旧 CharacterStore 的 'current_character_id_v1' key,升级后无需迁移当前选择值。
 *
 * 职责:
 * - 读取/设置/清空当前角色 ID
 * - 不保存完整 Character 列表
 * - 不保存角色正文
 * - 不依赖 RDB
 * - 不依赖页面
 *
 * 约束:
 * - 设置非空 ID 前由 CharacterService 验证角色存在
 * - 删除当前角色时清空选择
 * - 不缓存值
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterSelectionStore';
const PREFERENCES_NAME: string = 'arktavern_solo_settings';
const KEY_CURRENT_CHARACTER_ID: string = 'current_character_id_v1';

export class CharacterSelectionStore {
  private prefs: preferences.Preferences | null = null;
  private initialized: boolean = false;

  async initialize(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    try {
      this.prefs = await preferences.getPreferences(context, PREFERENCES_NAME);
      this.initialized = true;
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize failed: ' + String(e));
      throw new Error('CharacterSelectionStore initialize failed');
    }
  }

  private requireInit(): preferences.Preferences {
    if (!this.initialized || this.prefs === null) {
      throw new Error('CharacterSelectionStore not initialized');
    }
    return this.prefs;
  }

  /**
   * 读取当前角色 ID。
   * @returns 当前角色 ID;未设置或读取失败返回 null
   */
  async getCurrentCharacterId(): Promise<string | null> {
    const prefs: preferences.Preferences = this.requireInit();
    try {
      const raw: string = await prefs.get(KEY_CURRENT_CHARACTER_ID, '') as string;
      if (raw.length === 0) {
        return null;
      }
      return raw;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCurrentCharacterId failed: ' + String(e));
      return null;
    }
  }

  /**
   * 设置当前角色 ID。
   * 传入 null 清空选择。
   *
   * @param id 角色 ID 或 null
   */
  async setCurrentCharacterId(id: string | null): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    if (id !== null) {
      await prefs.put(KEY_CURRENT_CHARACTER_ID, id);
    } else {
      await prefs.put(KEY_CURRENT_CHARACTER_ID, '');
    }
    await prefs.flush();
  }

  /**
   * 清空当前角色选择。
   */
  async clear(): Promise<void> {
    await this.setCurrentCharacterId(null);
  }
}
