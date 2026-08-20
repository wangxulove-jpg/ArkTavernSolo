/**
 * MarketCacheStore 市场轻量缓存与用户偏好存储
 *
 * 通过 AppPreferences 持久化市场 Tab 的用户偏好与轻量缓存。
 *
 * 存储:
 * - 内容安全设置(hideNsfw)
 * - 隐藏已导入(hideImported)
 * - 最近 Provider 选择(providerId)
 * - 最近排序(sort)
 * - 最近搜索历史(最近 10 条)
 * - 最近一次列表缓存(带时间戳,过期重新请求)
 *
 * 不存储:
 * - 完整角色卡数据(导入前的临时数据)
 * - API Key
 * - 用户身份信息
 *
 * 过期策略:
 * - 列表缓存默认 5 分钟过期
 * - 搜索历史永久保存(直到清理)
 */

import { AppPreferences } from '../../storage/AppPreferences';
import { MarketSort } from '../../models/MarketQuery';
import { MarketCharacter } from '../../models/MarketCharacter';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'MarketCacheStore';
const KEY_HIDE_NSFW: string = 'market_hide_nsfw';
const KEY_HIDE_IMPORTED: string = 'market_hide_imported';
const KEY_CHINESE_ONLY: string = 'market_chinese_only';
const KEY_PROVIDER_ID: string = 'market_provider_id';
const KEY_SORT: string = 'market_sort';
const KEY_SEARCH_HISTORY: string = 'market_search_history';
const KEY_LAST_LIST_CACHE: string = 'market_last_list_cache';
const KEY_LAST_LIST_CACHE_TS: string = 'market_last_list_cache_ts';
const KEY_TRANSLATE_ENABLED: string = 'market_translate_enabled';
const KEY_TRANSLATE_CACHE: string = 'market_translate_cache';
const LIST_CACHE_TTL_MS: number = 5 * 60 * 1000; // 5 分钟
const MAX_SEARCH_HISTORY: number = 10;
/** 翻译缓存条目最大数量 */
const MAX_TRANSLATE_ENTRIES: number = 200;
/** 翻译缓存过期时间(30 天) */
const TRANSLATE_CACHE_TTL_MS: number = 30 * 24 * 60 * 60 * 1000;

/**
 * 市场缓存与偏好存储。
 */
export class MarketCacheStore {
  private prefs: AppPreferences;

  constructor(prefs: AppPreferences) {
    this.prefs = prefs;
  }

  // ===== 内容安全 =====

  async getHideNsfw(): Promise<boolean> {
    return await this.prefs.getBoolean(KEY_HIDE_NSFW, true);
  }

  async setHideNsfw(value: boolean): Promise<void> {
    await this.prefs.putBoolean(KEY_HIDE_NSFW, value);
  }

  async getHideImported(): Promise<boolean> {
    return await this.prefs.getBoolean(KEY_HIDE_IMPORTED, false);
  }

  async setHideImported(value: boolean): Promise<void> {
    await this.prefs.putBoolean(KEY_HIDE_IMPORTED, value);
  }

  // ===== 仅中文筛选 =====

  /**
   * 读取"仅中文角色"开关状态(默认关闭)。
   */
  async getChineseOnly(): Promise<boolean> {
    return await this.prefs.getBoolean(KEY_CHINESE_ONLY, false);
  }

  /**
   * 保存"仅中文角色"开关状态。
   */
  async setChineseOnly(value: boolean): Promise<void> {
    await this.prefs.putBoolean(KEY_CHINESE_ONLY, value);
  }

  // ===== Provider 与排序 =====

  async getProviderId(): Promise<string> {
    return await this.prefs.getString(KEY_PROVIDER_ID, 'chub');
  }

  async setProviderId(id: string): Promise<void> {
    if (id.length === 0) {
      return;
    }
    await this.prefs.putString(KEY_PROVIDER_ID, id);
  }

  async getSort(): Promise<MarketSort> {
    const v: string = await this.prefs.getString(KEY_SORT, MarketSort.Recommended);
    if (v === MarketSort.Latest) {
      return MarketSort.Latest;
    }
    if (v === MarketSort.Top) {
      return MarketSort.Top;
    }
    return MarketSort.Recommended;
  }

  async setSort(sort: MarketSort): Promise<void> {
    await this.prefs.putString(KEY_SORT, sort);
  }

  // ===== 搜索历史 =====

  async getSearchHistory(): Promise<string[]> {
    try {
      const json: string = await this.prefs.getString(KEY_SEARCH_HISTORY, '');
      if (json.length === 0) {
        return [];
      }
      const parsed: Object = JSON.parse(json);
      if (!Array.isArray(parsed)) {
        return [];
      }
      const arr: Object[] = parsed as Object[];
      const result: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        const item: Object = arr[i];
        if (typeof item === 'string') {
          result.push(item as string);
        }
      }
      return result;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getSearchHistory failed: ' + String(e));
      return [];
    }
  }

  async addSearchHistory(query: string): Promise<void> {
    const trimmed: string = query.trim();
    if (trimmed.length === 0) {
      return;
    }
    const current: string[] = await this.getSearchHistory();
    // 去重(大小写不敏感)
    const lower: string = trimmed.toLowerCase();
    const filtered: string[] = [];
    for (let i = 0; i < current.length; i++) {
      if (current[i].toLowerCase() !== lower) {
        filtered.push(current[i]);
      }
    }
    filtered.unshift(trimmed);
    // 限制长度
    const limited: string[] = filtered.slice(0, MAX_SEARCH_HISTORY);
    try {
      await this.prefs.putString(KEY_SEARCH_HISTORY, JSON.stringify(limited));
    } catch (e) {
      Logger.warn(LOG_TAG, 'addSearchHistory save failed: ' + String(e));
    }
  }

  async clearSearchHistory(): Promise<void> {
    await this.prefs.putString(KEY_SEARCH_HISTORY, '');
  }

  // ===== 列表缓存 =====

  /**
   * 读取最近一次缓存列表(若过期返回空数组)。
   */
  async getLastListCache(): Promise<MarketCharacter[]> {
    try {
      const tsStr: string = await this.prefs.getString(KEY_LAST_LIST_CACHE_TS, '0');
      const ts: number = parseInt(tsStr, 10);
      if (isNaN(ts) || ts === 0) {
        return [];
      }
      const now: number = Date.now();
      if (now - ts > LIST_CACHE_TTL_MS) {
        return [];
      }
      const json: string = await this.prefs.getString(KEY_LAST_LIST_CACHE, '');
      if (json.length === 0) {
        return [];
      }
      const parsed: Object = JSON.parse(json);
      if (!Array.isArray(parsed)) {
        return [];
      }
      const arr: Object[] = parsed as Object[];
      const result: MarketCharacter[] = [];
      for (let i = 0; i < arr.length; i++) {
        const item: Object = arr[i];
        if (typeof item === 'object' && item !== null) {
          const mc: MarketCharacter = item as MarketCharacter;
          result.push(mc);
        }
      }
      return result;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getLastListCache failed: ' + String(e));
      return [];
    }
  }

  /**
   * 保存最近一次缓存列表(带时间戳)。
   * 仅缓存前 24 条,避免占用过多 Preferences 空间。
   */
  async setLastListCache(items: MarketCharacter[]): Promise<void> {
    try {
      const limited: MarketCharacter[] = items.slice(0, 24);
      const json: string = JSON.stringify(limited);
      const now: number = Date.now();
      await this.prefs.putString(KEY_LAST_LIST_CACHE, json);
      await this.prefs.putString(KEY_LAST_LIST_CACHE_TS, now.toString());
    } catch (e) {
      Logger.warn(LOG_TAG, 'setLastListCache failed: ' + String(e));
    }
  }

  async clearLastListCache(): Promise<void> {
    await this.prefs.putString(KEY_LAST_LIST_CACHE, '');
    await this.prefs.putString(KEY_LAST_LIST_CACHE_TS, '0');
  }

  // ===== 翻译偏好 =====

  /**
   * 读取"翻译为中文"开关状态(默认关闭)。
   */
  async getTranslateEnabled(): Promise<boolean> {
    return await this.prefs.getBoolean(KEY_TRANSLATE_ENABLED, false);
  }

  /**
   * 保存"翻译为中文"开关状态。
   */
  async setTranslateEnabled(value: boolean): Promise<void> {
    await this.prefs.putBoolean(KEY_TRANSLATE_ENABLED, value);
  }

  // ===== 翻译缓存 =====

  /**
   * 读取翻译缓存(返回 null 表示无缓存或已过期)。
   * @param providerId Provider ID
   * @param remoteId 远程角色 ID
   * @param remoteUpdatedAt 远程角色更新时间(用于失效检测)
   * @param fieldHash 字段 hash(用于检测原文是否变化)
   */
  async getTranslation(
    providerId: string,
    remoteId: string,
    remoteUpdatedAt: number,
    fieldHash: number
  ): Promise<MarketTranslationCacheEntry | null> {
    try {
      const json: string = await this.prefs.getString(KEY_TRANSLATE_CACHE, '');
      if (json.length === 0) {
        return null;
      }
      const parsed: Object = JSON.parse(json);
      if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
        return null;
      }
      const root: Record<string, Object> = parsed as Record<string, Object>;
      const key: string = providerId + ':' + remoteId;
      const entryRaw: Object | undefined = root[key];
      if (entryRaw === undefined || entryRaw === null) {
        return null;
      }
      const entry: MarketTranslationCacheEntry = entryRaw as MarketTranslationCacheEntry;
      // 检查过期(30 天)
      const now: number = Date.now();
      if (now - entry.translatedAt > TRANSLATE_CACHE_TTL_MS) {
        return null;
      }
      // 检查 remoteUpdatedAt 是否变化
      if (entry.remoteUpdatedAt !== remoteUpdatedAt) {
        return null;
      }
      // 检查字段 hash 是否变化
      if (entry.fieldHash !== fieldHash) {
        return null;
      }
      return entry;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getTranslation failed: ' + String(e));
      return null;
    }
  }

  /**
   * 保存翻译缓存。超过最大数量时丢弃最早的条目(LRU 近似)。
   */
  async putTranslation(entry: MarketTranslationCacheEntry): Promise<void> {
    try {
      const json: string = await this.prefs.getString(KEY_TRANSLATE_CACHE, '');
      let root: Record<string, MarketTranslationCacheEntry> = {};
      if (json.length > 0) {
        const parsed: Object = JSON.parse(json);
        if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
          root = parsed as Record<string, MarketTranslationCacheEntry>;
        }
      }
      const key: string = entry.providerId + ':' + entry.remoteId;
      root[key] = entry;
      // 容量控制:超过最大数量时保留最新的 MAX_TRANSLATE_ENTRIES 条
      const keys: string[] = Object.keys(root);
      if (keys.length > MAX_TRANSLATE_ENTRIES) {
        const sortedEntries: MarketTranslationCacheEntry[] = [];
        for (let i: number = 0; i < keys.length; i++) {
          const v: MarketTranslationCacheEntry | undefined = root[keys[i]];
          if (v !== undefined) {
            sortedEntries.push(v);
          }
        }
        sortedEntries.sort((a: MarketTranslationCacheEntry, b: MarketTranslationCacheEntry): number => {
          return a.translatedAt - b.translatedAt;
        });
        // 保留最新的 MAX_TRANSLATE_ENTRIES 条,丢弃更早的
        const keepCount: number = MAX_TRANSLATE_ENTRIES;
        const keepStart: number = sortedEntries.length - keepCount;
        const trimmed: Record<string, MarketTranslationCacheEntry> = {};
        for (let i: number = keepStart; i < sortedEntries.length; i++) {
          const k: string = sortedEntries[i].providerId + ':' + sortedEntries[i].remoteId;
          trimmed[k] = sortedEntries[i];
        }
        root = trimmed;
      }
      await this.prefs.putString(KEY_TRANSLATE_CACHE, JSON.stringify(root));
    } catch (e) {
      Logger.warn(LOG_TAG, 'putTranslation save failed: ' + String(e));
    }
  }

  /**
   * 清空全部翻译缓存。
   */
  async clearTranslationCache(): Promise<void> {
    await this.prefs.putString(KEY_TRANSLATE_CACHE, '');
  }
}

/**
 * 翻译缓存条目。
 * 远程角色更新时间或字段 hash 变化时,旧翻译自动失效。
 */
export interface MarketTranslationCacheEntry {
  /** Provider ID */
  readonly providerId: string;
  /** 远程角色 ID */
  readonly remoteId: string;
  /** 远程角色更新时间(用于失效检测) */
  readonly remoteUpdatedAt: number;
  /** 原文字段 hash(用于失效检测) */
  readonly fieldHash: number;
  /** 翻译后的名称 */
  readonly translatedName: string;
  /** 翻译后的简介 */
  readonly translatedSummary: string;
  /** 翻译后的标签(顺序与原文一致) */
  readonly translatedTags: string[];
  /** 翻译后的创作者备注 */
  readonly translatedCreatorNotes: string;
  /** 翻译时间戳 */
  readonly translatedAt: number;
}
