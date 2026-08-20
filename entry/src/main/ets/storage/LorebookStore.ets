/**
 * LorebookStore 世界书持久化
 *
 * 使用 Preferences 保存世界书列表,基于 arktavern_settings。
 * 模式与 CharacterStore 一致,但不使用 RDB。
 *
 * key 设计:
 * - 'lorebook_list_v1' : 世界书列表 JSON 数组(schemaVersion=1)
 * - 'current_lorebook_id_v1' : 当前选中世界书 ID
 *
 * 约束:
 * - 损坏数据不能导致应用崩溃
 * - 删除当前世界书时清空当前世界书 ID
 * - 不存 API Key 或聊天记录
 * - 不依赖 Provider 业务结构
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Lorebook, LorebookEntry, LorebookPosition, validateLorebook } from '../models/Lorebook';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LorebookStore';
const KEY_LOREBOOK_LIST: string = 'lorebook_list_v1';
const KEY_CURRENT_LOREBOOK_ID: string = 'current_lorebook_id_v1';

export class LorebookStore {
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
      throw new Error('LorebookStore initialize failed');
    }
  }

  private requireInit(): preferences.Preferences {
    if (!this.initialized || this.prefs === null) {
      throw new Error('LorebookStore not initialized');
    }
    return this.prefs;
  }

  async list(): Promise<Lorebook[]> {
    const prefs: preferences.Preferences = this.requireInit();
    try {
      const raw: string | null = await prefs.get(KEY_LOREBOOK_LIST, '') as string | null;
      if (raw === null || raw.length === 0) {
        return [];
      }
      const parsed: Object = JSON.parse(raw);
      if (!Array.isArray(parsed)) {
        Logger.warn(LOG_TAG, 'list: data is not array, reset');
        await prefs.put(KEY_LOREBOOK_LIST, '[]');
        await prefs.flush();
        return [];
      }
      const lorebooks: Lorebook[] = [];
      const arr: Object[] = parsed as Object[];
      let skippedCount: number = 0;
      for (let i = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        if (typeof item['id'] !== 'string' || typeof item['name'] !== 'string') {
          skippedCount++;
          continue;
        }
        try {
          const lb: Lorebook = this.deserializeLorebook(item);
          lorebooks.push(lb);
        } catch (_e) {
          skippedCount++;
        }
      }
      if (skippedCount > 0) {
        Logger.warn(LOG_TAG, 'list: skipped ' + skippedCount.toString() + ' corrupted entries');
      }
      return lorebooks;
    } catch (e) {
      Logger.warn(LOG_TAG, 'list parse failed, reset: ' + String(e));
      try {
        await prefs.put(KEY_LOREBOOK_LIST, '[]');
        await prefs.flush();
      } catch (_e) {
        // ignore
      }
      return [];
    }
  }

  async getById(id: string): Promise<Lorebook | null> {
    const lorebooks: Lorebook[] = await this.list();
    for (let i = 0; i < lorebooks.length; i++) {
      if (lorebooks[i].id === id) {
        return lorebooks[i];
      }
    }
    return null;
  }

  async save(lorebook: Lorebook): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    const error: string | null = validateLorebook(lorebook);
    if (error !== null) {
      throw new Error('LorebookStore save: ' + error);
    }
    const lorebooks: Lorebook[] = await this.list();
    for (let i = 0; i < lorebooks.length; i++) {
      if (lorebooks[i].id === lorebook.id) {
        throw new Error('LorebookStore save: duplicate id: ' + lorebook.id);
      }
    }
    lorebooks.push(lorebook);
    await prefs.put(KEY_LOREBOOK_LIST, JSON.stringify(lorebooks));
    await prefs.flush();
  }

  async update(lorebook: Lorebook): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    const error: string | null = validateLorebook(lorebook);
    if (error !== null) {
      throw new Error('LorebookStore update: ' + error);
    }
    const lorebooks: Lorebook[] = await this.list();
    let found: boolean = false;
    for (let i = 0; i < lorebooks.length; i++) {
      if (lorebooks[i].id === lorebook.id) {
        lorebooks[i] = lorebook;
        found = true;
        break;
      }
    }
    if (!found) {
      throw new Error('LorebookStore update: not found: ' + lorebook.id);
    }
    await prefs.put(KEY_LOREBOOK_LIST, JSON.stringify(lorebooks));
    await prefs.flush();
  }

  async remove(id: string): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    const lorebooks: Lorebook[] = await this.list();
    const updated: Lorebook[] = [];
    for (let i = 0; i < lorebooks.length; i++) {
      if (lorebooks[i].id !== id) {
        updated.push(lorebooks[i]);
      }
    }
    await prefs.put(KEY_LOREBOOK_LIST, JSON.stringify(updated));
    const currentId: string | null = await this.getCurrentLorebookId();
    if (currentId === id) {
      await prefs.put(KEY_CURRENT_LOREBOOK_ID, '');
    }
    await prefs.flush();
  }

  async setCurrentLorebookId(id: string | null): Promise<void> {
    const prefs: preferences.Preferences = this.requireInit();
    if (id !== null) {
      const exists: Lorebook | null = await this.getById(id);
      if (exists === null) {
        throw new Error('LorebookStore setCurrentLorebookId: not found: ' + id);
      }
      await prefs.put(KEY_CURRENT_LOREBOOK_ID, id);
    } else {
      await prefs.put(KEY_CURRENT_LOREBOOK_ID, '');
    }
    await prefs.flush();
  }

  async getCurrentLorebookId(): Promise<string | null> {
    const prefs: preferences.Preferences = this.requireInit();
    try {
      const raw: string | null = await prefs.get(KEY_CURRENT_LOREBOOK_ID, '') as string | null;
      if (raw === null || raw.length === 0) {
        return null;
      }
      return raw;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getCurrentLorebookId failed: ' + String(e));
      return null;
    }
  }

  async getCurrentLorebook(): Promise<Lorebook | null> {
    const id: string | null = await this.getCurrentLorebookId();
    if (id === null) {
      return null;
    }
    return await this.getById(id);
  }

  /**
   * 反序列化单个世界书(含条目)。
   * 损坏条目跳过,不导致整个世界书丢失。
   */
  private deserializeLorebook(item: Record<string, Object>): Lorebook {
    const entries: LorebookEntry[] = [];
    const rawEntries: Object = item['entries'];
    if (Array.isArray(rawEntries)) {
      const arr: Object[] = rawEntries as Object[];
      for (let i = 0; i < arr.length; i++) {
        const entryItem: Record<string, Object> = arr[i] as Record<string, Object>;
        if (typeof entryItem['id'] !== 'string' || typeof entryItem['name'] !== 'string') {
          continue;
        }
        const entry: LorebookEntry = {
          id: entryItem['id'] as string,
          name: entryItem['name'] as string,
          keys: this.deserializeStringArray(entryItem['keys']),
          secondaryKeys: this.deserializeStringArray(entryItem['secondaryKeys']),
          content: typeof entryItem['content'] === 'string' ? entryItem['content'] as string : '',
          enabled: typeof entryItem['enabled'] === 'boolean' ? entryItem['enabled'] as boolean : true,
          constant: typeof entryItem['constant'] === 'boolean' ? entryItem['constant'] as boolean : false,
          selective: typeof entryItem['selective'] === 'boolean' ? entryItem['selective'] as boolean : false,
          position: typeof entryItem['position'] === 'string' ? (entryItem['position'] as LorebookPosition) : 'BeforeCharacter' as LorebookPosition,
          priority: typeof entryItem['priority'] === 'number' ? entryItem['priority'] as number : 0,
          createdAt: typeof entryItem['createdAt'] === 'number' ? entryItem['createdAt'] as number : Date.now(),
          updatedAt: typeof entryItem['updatedAt'] === 'number' ? entryItem['updatedAt'] as number : Date.now()
        };
        entries.push(entry);
      }
    }
    return {
      id: item['id'] as string,
      name: item['name'] as string,
      description: typeof item['description'] === 'string' ? item['description'] as string : '',
      enabled: typeof item['enabled'] === 'boolean' ? item['enabled'] as boolean : true,
      entries: entries,
      createdAt: typeof item['createdAt'] === 'number' ? item['createdAt'] as number : Date.now(),
      updatedAt: typeof item['updatedAt'] === 'number' ? item['updatedAt'] as number : Date.now()
    };
  }

  private deserializeStringArray(value: Object): string[] {
    if (!Array.isArray(value)) {
      return [];
    }
    const arr: Object[] = value as Object[];
    const result: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string') {
        result.push(arr[i] as string);
      }
    }
    return result;
  }
}