/**
 * MarketService 市场业务编排服务
 *
 * 作为市场 UI 与 Provider 之间的编排层:
 * - 管理 Provider 列表(第一版仅 Chub)
 * - 委托当前 Provider 执行搜索/详情/下载
 * - 缓存最近一次列表结果(5 分钟过期)
 * - 加载用户偏好(hideNsfw / hideImported / providerId / sort / searchHistory)
 *
 * 不实现:
 * - 角色卡导入(由 MarketImportService 负责)
 * - API Key 管理(公共浏览接口不需要)
 *
 * 安全:
 * - 不缓存完整角色卡数据
 * - 日志不记录完整 URL(含 query)
 */

import { HttpClient } from '../../network/core/HttpClient';
import { MarketProvider } from './MarketProvider';
import { ChubProvider } from './ChubProvider';
import { MarketCacheStore } from './MarketCacheStore';
import { MarketImportedMapStore } from './MarketImportedMapStore';
import {
  MarketQuery,
  MarketPageResult,
  MarketSort,
  createDefaultMarketQuery
} from '../../models/MarketQuery';
import { MarketCharacter } from '../../models/MarketCharacter';
import { MarketCharacterDetail } from '../../models/MarketCharacterDetail';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'MarketService';

/**
 * 市场服务,管理 Provider 并提供统一访问入口。
 */
export class MarketService {
  private providers: Map<string, MarketProvider> = new Map<string, MarketProvider>();
  private cache: MarketCacheStore;
  private importedMap: MarketImportedMapStore;
  private currentProviderId: string = 'chub';

  constructor(httpClient: HttpClient, cache: MarketCacheStore, importedMap: MarketImportedMapStore) {
    this.cache = cache;
    this.importedMap = importedMap;
    // 注册 Provider(第一版仅 Chub)
    const chub: MarketProvider = new ChubProvider(httpClient);
    this.providers.set(chub.providerId, chub);
  }

  /**
   * 列出所有可用 Provider。
   */
  listProviders(): MarketProvider[] {
    const result: MarketProvider[] = [];
    this.providers.forEach((p: MarketProvider) => {
      result.push(p);
    });
    return result;
  }

  /**
   * 获取当前活跃 Provider。
   */
  getCurrentProvider(): MarketProvider {
    const p: MarketProvider | undefined = this.providers.get(this.currentProviderId);
    if (p === undefined) {
      // 兜底:取第一个
      const first: MarketProvider = this.providers.values().next().value as MarketProvider;
      return first;
    }
    return p;
  }

  /**
   * 切换当前 Provider。
   */
  async setCurrentProvider(providerId: string): Promise<void> {
    if (!this.providers.has(providerId)) {
      Logger.warn(LOG_TAG, 'setCurrentProvider: unknown provider ' + providerId);
      return;
    }
    this.currentProviderId = providerId;
    await this.cache.setProviderId(providerId);
  }

  /**
   * 加载用户偏好到 MarketQuery。
   */
  async loadQueryPreferences(): Promise<MarketQuery> {
    const base: MarketQuery = createDefaultMarketQuery();
    const hideNsfw: boolean = await this.cache.getHideNsfw();
    const hideImported: boolean = await this.cache.getHideImported();
    const sort: MarketSort = await this.cache.getSort();
    const providerId: string = await this.cache.getProviderId();
    if (this.providers.has(providerId)) {
      this.currentProviderId = providerId;
    }
    return {
      search: base.search,
      sort: sort,
      tag: base.tag,
      creator: base.creator,
      hideNsfw: hideNsfw,
      hideImported: hideImported,
      page: base.page,
      pageSize: base.pageSize,
      cursor: base.cursor
    };
  }

  /**
   * 搜索角色卡,委托当前 Provider。
   * 列表缓存由 ViewModel 在刷新/加载更多完成后统一写入整段列表。
   */
  async searchCharacters(query: MarketQuery): Promise<MarketPageResult> {
    const provider: MarketProvider = this.getCurrentProvider();
    const result: MarketPageResult = await provider.searchCharacters(query);
    return result;
  }

  /**
   * 获取角色详情。
   */
  async getCharacterDetail(remoteId: string): Promise<MarketCharacterDetail> {
    const provider: MarketProvider = this.getCurrentProvider();
    return await provider.getCharacterDetail(remoteId);
  }

  /**
   * 下载角色卡 PNG 字节(优先格式)。
   * Provider 不提供 PNG 时返回 null。
   */
  async downloadPng(remoteId: string): Promise<Uint8Array | null> {
    const provider: MarketProvider = this.getCurrentProvider();
    return await provider.downloadPng(remoteId);
  }

  /**
   * 下载角色卡 JSON 字符串(Tavern Card V2)。
   */
  async downloadJson(remoteId: string): Promise<string> {
    const provider: MarketProvider = this.getCurrentProvider();
    return await provider.downloadJson(remoteId);
  }

  /**
   * 获取来源页面 URL。
   */
  getSourceUrl(remoteId: string): string {
    const provider: MarketProvider = this.getCurrentProvider();
    return provider.getSourceUrl(remoteId);
  }

  // ===== 偏好操作 =====

  async setHideNsfw(value: boolean): Promise<void> {
    await this.cache.setHideNsfw(value);
  }

  async setHideImported(value: boolean): Promise<void> {
    await this.cache.setHideImported(value);
  }

  async setSort(sort: MarketSort): Promise<void> {
    await this.cache.setSort(sort);
  }

  async getSearchHistory(): Promise<string[]> {
    return await this.cache.getSearchHistory();
  }

  async addSearchHistory(query: string): Promise<void> {
    await this.cache.addSearchHistory(query);
  }

  async clearSearchHistory(): Promise<void> {
    await this.cache.clearSearchHistory();
  }

  // ===== 已导入状态 =====

  async isImported(providerId: string, remoteId: string): Promise<boolean> {
    return await this.importedMap.contains(providerId, remoteId);
  }

  /**
   * 批量检查已导入状态,返回每个角色的 importedLocalCharacterId(空表示未导入)。
   * 用于列表 UI 显示"已导入"标记。
   */
  async checkImportedBatch(items: MarketCharacter[]): Promise<Map<string, string>> {
    const result: Map<string, string> = new Map<string, string>();
    const all: Record<string, string> = await this.importedMap.getAll();
    for (let i = 0; i < items.length; i++) {
      const item: MarketCharacter = items[i];
      const key: string = item.providerId + ':' + item.remoteId;
      const localId: string | undefined = all[key];
      result.set(item.providerId + '|' + item.remoteId, localId !== undefined ? localId : '');
    }
    return result;
  }

  /**
   * 获取缓存存储(供 MarketImportService 调用)。
   */
  getCacheStore(): MarketCacheStore {
    return this.cache;
  }

  /**
   * 记录一条已浏览角色卡到永久缓存。
   */
  async markCharacterBrowsed(item: MarketCharacter): Promise<void> {
    await this.cache.putBrowsedCharacter(item);
  }

  /**
   * 缓存整段已加载列表(重启后直接展示)。
   */
  async cacheList(items: MarketCharacter[]): Promise<void> {
    await this.cache.setLastListCache(items);
  }

  /**
   * 读取上次缓存的列表(无缓存返回空数组)。
   */
  async getCachedList(): Promise<MarketCharacter[]> {
    return await this.cache.getLastListCache();
  }

  /**
   * 获取市场缓存大小(字节,近似)。
   */
  async getCacheSizeBytes(): Promise<number> {
    return await this.cache.countCacheBytes();
  }

  /**
   * 清除全部市场缓存(已浏览角色卡 + 最近列表 + 翻译缓存)。
   * 保留用户偏好设置。
   */
  async clearMarketCaches(): Promise<void> {
    await this.cache.clearAllCaches();
  }

  /**
   * 获取导入映射存储(供 MarketImportService 调用)。
   */
  getImportedMapStore(): MarketImportedMapStore {
    return this.importedMap;
  }
}
