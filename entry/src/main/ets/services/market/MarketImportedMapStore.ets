/**
 * MarketImportedMapStore 已导入市场角色映射存储
 *
 * 用于快速查询本地角色卡是否已从市场导入(避免重复导入),
 * 以及根据 providerId + remoteId 查找本地角色 ID。
 *
 * 存储:
 * - 单个 Preferences key 存储完整映射 JSON
 * - key: 'market_imported_map'
 * - value: JSON 字符串,结构: { "<providerId>:<remoteId>": "<localCharacterId>" }
 *
 * 同步策略:
 * - 导入成功后立即写入
 * - 删除角色时移除对应映射(由 MarketImportService 调用)
 * - 不保证与 RDB 角色表完全一致(可能存在孤儿映射,需调用方处理)
 *
 * 不存储:
 * - 角色卡完整数据
 * - API Key
 * - 来源 URL(在角色卡 extensions 中)
 */

import { AppPreferences } from '../../storage/AppPreferences';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'MarketImportedMapStore';
const MAP_KEY: string = 'market_imported_map';

/**
 * 已导入市场角色映射存储。
 * 通过 AppPreferences 持久化,提供 put/get/remove/contains 操作。
 */
export class MarketImportedMapStore {
  private prefs: AppPreferences;

  constructor(prefs: AppPreferences) {
    this.prefs = prefs;
  }

  /**
   * 记录一条导入映射。
   * 同一 providerId + remoteId 已存在时覆盖(保留最新 localCharacterId)。
   */
  async put(providerId: string, remoteId: string, localCharacterId: string): Promise<void> {
    if (providerId.length === 0 || remoteId.length === 0 || localCharacterId.length === 0) {
      return;
    }
    const map: Record<string, string> = await this.loadMap();
    const key: string = this.buildKey(providerId, remoteId);
    map[key] = localCharacterId;
    await this.saveMap(map);
  }

  /**
   * 查询 providerId + remoteId 对应的本地角色 ID。
   * 不存在返回空字符串。
   */
  async get(providerId: string, remoteId: string): Promise<string> {
    const map: Record<string, string> = await this.loadMap();
    const key: string = this.buildKey(providerId, remoteId);
    const v: string | undefined = map[key];
    return v !== undefined ? v : '';
  }

  /**
   * 判断是否已导入。
   */
  async contains(providerId: string, remoteId: string): Promise<boolean> {
    const id: string = await this.get(providerId, remoteId);
    return id.length > 0;
  }

  /**
   * 移除一条映射(删除角色时调用)。
   * 幂等:不存在也返回成功。
   */
  async remove(providerId: string, remoteId: string): Promise<void> {
    const map: Record<string, string> = await this.loadMap();
    const key: string = this.buildKey(providerId, remoteId);
    if (map[key] !== undefined) {
      const filtered: Record<string, string> = this.removeKey(map, key);
      await this.saveMap(filtered);
    }
  }

  /**
   * 移除指定本地角色 ID 的所有映射。
   * 用于删除角色时清理(可能存在多个 providerId/remoteId 指向同一角色)。
   */
  async removeByLocalId(localCharacterId: string): Promise<void> {
    if (localCharacterId.length === 0) {
      return;
    }
    const map: Record<string, string> = await this.loadMap();
    let changed: boolean = false;
    const keys: string[] = Object.keys(map);
    const filtered: Record<string, string> = {};
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (map[k] === localCharacterId) {
        changed = true;
      } else {
        filtered[k] = map[k];
      }
    }
    if (changed) {
      await this.saveMap(filtered);
    }
  }

  /**
   * 复制 map 并移除指定 key(不修改原 map)。
   * ArkTS 不支持 `delete map[key]`,通过重新构建对象实现。
   */
  private removeKey(map: Record<string, string>, keyToRemove: string): Record<string, string> {
    const result: Record<string, string> = {};
    const keys: string[] = Object.keys(map);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (k !== keyToRemove) {
        result[k] = map[k];
      }
    }
    return result;
  }

  /**
   * 加载完整映射(用于 UI 检查多个角色是否已导入)。
   */
  async getAll(): Promise<Record<string, string>> {
    return await this.loadMap();
  }

  /**
   * 构造映射 key。
   * key 格式: '<providerId>:<remoteId>'
   * 注意:remoteId 可能包含 '/'(Chub 格式为 'creator/project'),key 不做转义,
   * 因为同一 providerId 内 remoteId 唯一,只需保证拼接可逆且不冲突。
   */
  private buildKey(providerId: string, remoteId: string): string {
    return providerId + ':' + remoteId;
  }

  /**
   * 加载映射 JSON。解析失败时返回空对象(不抛错,容错处理)。
   */
  private async loadMap(): Promise<Record<string, string>> {
    try {
      const json: string = await this.prefs.getString(MAP_KEY, '');
      if (json.length === 0) {
        return {};
      }
      const parsed: Object = JSON.parse(json);
      if (typeof parsed !== 'object' || parsed === null) {
        return {};
      }
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      const result: Record<string, string> = {};
      const keys: string[] = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const k: string = keys[i];
        const v: Object | undefined = obj[k];
        if (v !== undefined && v !== null && typeof v === 'string') {
          result[k] = v as string;
        }
      }
      return result;
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadMap parse failed: ' + String(e));
      return {};
    }
  }

  /**
   * 保存映射 JSON。
   */
  private async saveMap(map: Record<string, string>): Promise<void> {
    try {
      const json: string = JSON.stringify(map);
      await this.prefs.putString(MAP_KEY, json);
    } catch (e) {
      Logger.error(LOG_TAG, 'saveMap failed: ' + String(e));
      throw new Error(String(e));
    }
  }
}
