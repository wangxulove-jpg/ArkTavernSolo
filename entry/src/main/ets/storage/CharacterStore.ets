/**
 * CharacterStore 角色持久化
 *
 * 使用 Preferences 保存角色列表,基于 AppPreferences 封装。
 * 模式与 ProviderConfigStore 一致,但数据为非敏感数据。
 *
 * key 设计:
 * - 'character_list_v1' : 角色列表 JSON 数组
 * - 'current_character_id_v1' : 当前选中角色 ID
 *
 * 约束:
 * - 损坏数据不能导致应用崩溃
 * - 删除当前角色时清空当前角色 ID
 * - 不存 API Key
 * - 本次不使用 RDB
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Character, validateCharacter } from '../models/Character';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterStore';
const KEY_CHARACTER_LIST: string = 'character_list_v1';
const KEY_CURRENT_CHARACTER_ID: string = 'current_character_id_v1';

export class CharacterStore {
  private prefs: preferences.Preferences | null = null;
  private initialized: boolean = false;

  async initialize(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    try {
      this.prefs = await preferences.getPreferences(context, 'arktavern_solo_settings');
      this.initialized = true;
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize failed: ' + String(e));
      throw new Error('CharacterStore initialize failed');
    }
  }

  private requireInit(): preferences.Preferences {
    if (!this.initialized || this.prefs === null) {
      throw new Error('CharacterStore not initialized');
    }
    return this.prefs;
  }

  async list(): Promise<Character[]> {
    const prefs: preferences.Preferences = this.requireInit();
    try {
      const raw: string | null = await prefs.get(KEY_CHARACTER_LIST, '') as string | null;
      if (raw === null || raw.length === 0) {
        return [];
      }
      const parsed: Object = JSON.parse(raw);
      if (!Array.isArray(parsed)) {
        Logger.warn(LOG_TAG, 'list: data is not array, reset');
        await prefs.put(KEY_CHARACTER_LIST, '[]');
        await prefs.flush();
        return [];
      }
      const characters: Character[] = (parsed as Object[]).filter((item: Object): boolean => {
        return typeof item === 'object' && item !== null
          && typeof (item as Record<string, Object>)['id'] === 'string'
          && typeof (item as Record<string, Object>)['name'] === 'string';
      }) as Character[];
      return characters;
    } catch (e) {
      Logger.warn(LOG_TAG, 'list parse failed, reset: ' + String(e));
      try {
        await prefs.put(KEY_CHARACTER_LIST, '[]');
        await prefs.flush();
      } catch (_e) {
        // ignore
      }
      return [];
    }
  }

  async getById(id: string): Promise<Character | null> {
    const characters: Character[] = await this.list();
    for (let i = 0; i < characters.length; i++) {
      if (characters[i].id === id) {
        return characters[i];
      }
    }
    return null;
  }

  async save(character: Character): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      throw new Error('CharacterStore save: ' + error);
    }
    const characters: Character[] = await this.list();
    for (let i = 0; i < characters.length; i++) {
      if (characters[i].id === character.id) {
        throw new Error('CharacterStore save: duplicate id: ' + character.id);
      }
    }
    characters.push(character);
    await prefs.put(KEY_CHARACTER_LIST, JSON.stringify(characters));
    await prefs.flush();
  }

  async update(character: Character): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    const error: string | null = validateCharacter(character);
    if (error !== null) {
      throw new Error('CharacterStore update: ' + error);
    }
    const characters: Character[] = await this.list();
    let found: boolean = false;
    for (let i = 0; i < characters.length; i++) {
      if (characters[i].id === character.id) {
        characters[i] = character;
        found = true;
        break;
      }
    }
    if (!found) {
      throw new Error('CharacterStore update: not found: ' + character.id);
    }
    await prefs.put(KEY_CHARACTER_LIST, JSON.stringify(characters));
    await prefs.flush();
  }

  async remove(id: string): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    const characters: Character[] = await this.list();
    const updated: Character[] = [];
    for (let i = 0; i < characters.length; i++) {
      if (characters[i].id !== id) {
        updated.push(characters[i]);
      }
    }
    await prefs.put(KEY_CHARACTER_LIST, JSON.stringify(updated));
    const currentId: string | null = await this.getCurrentCharacterId();
    if (currentId === id) {
      await prefs.put(KEY_CURRENT_CHARACTER_ID, '');
    }
    await prefs.flush();
  }

  async setCurrentCharacterId(id: string | null): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    if (id !== null) {
      const exists: Character | null = await this.getById(id);
      if (exists === null) {
        throw new Error('CharacterStore setCurrentCharacterId: not found: ' + id);
      }
      await prefs.put(KEY_CURRENT_CHARACTER_ID, id);
    } else {
      await prefs.put(KEY_CURRENT_CHARACTER_ID, '');
    }
    await prefs.flush();
  }

  async getCurrentCharacterId(): Promise<string | null> {
    const prefs: preferences.Preferences = this.requireInit();
    try {
      const raw: string | null = await prefs.get(KEY_CURRENT_CHARACTER_ID, '') as string | null;
      if (raw === null || raw.length === 0) {
        return null;
      }
      return raw;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCurrentCharacterId failed: ' + String(e));
      return null;
    }
  }

  async getCurrentCharacter(): Promise<Character | null> {
    const id: string | null = await this.getCurrentCharacterId();
    if (id === null) {
      return null;
    }
    return await this.getById(id);
  }
}