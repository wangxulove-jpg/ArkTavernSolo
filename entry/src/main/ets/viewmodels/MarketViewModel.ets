/**
 * MarketViewModel 市场 ViewModel
 *
 * 管理市场列表/搜索/分页/防抖/UI 状态。
 *
 * 核心职责:
 * 1. 列表加载(首页、下拉刷新)
 * 2. 分页加载(滚动到底部加载更多)
 * 3. 搜索防抖(350ms,空搜索恢复默认推荐列表)
 * 4. 请求取消(operationId 机制,新请求覆盖旧请求)
 * 5. 去重(跨页去重,providerId + remoteId)
 * 6. 筛选(排序、NSFW、已导入、标签、创作者)
 * 7. 已导入状态管理(显示标记,本地过滤)
 * 8. 翻译开关 + 隐私弹窗 + 批量翻译触发
 *
 * 不直接:
 * - 调用 network/ 模块(通过 MarketService / MarketTranslationService)
 * - 调用 CharacterService(通过 MarketImportService,在详情 ViewModel 中)
 * - 操作 Preferences(通过 MarketService)
 */

import { MarketService } from '../services/market/MarketService';
import { MarketTranslationService } from '../services/market/MarketTranslationService';
import {
  MarketQuery,
  MarketPageResult,
  MarketSort,
  DEFAULT_MARKET_PAGE_SIZE
} from '../models/MarketQuery';
import { MarketCharacter, marketCharacterKey } from '../models/MarketCharacter';
import { MarketTranslationResult } from '../models/MarketTranslation';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MarketViewModel';
const DEBOUNCE_MS: number = 350;

@Observed
export class MarketViewModel {
  // ===== 列表状态 =====
  items: MarketCharacter[] = [];
  loading: boolean = false;
  refreshing: boolean = false;
  loadingMore: boolean = false;
  hasMore: boolean = true;
  errorMessage: string = '';

  // ===== 查询参数 =====
  searchInput: string = '';
  appliedSearch: string = '';
  sort: MarketSort = MarketSort.Recommended;
  hideNsfw: boolean = true;
  hideImported: boolean = false;
  /** 仅显示中文角色(本地过滤:标签含中文、或名称/简介中文字符占比>=30%) */
  chineseOnly: boolean = false;
  tag: string = '';
  creator: string = '';
  providerId: string = 'chub';

  // ===== 已导入状态 =====
  /** key: providerId|remoteId,value: 本地角色 ID(空字符串也表示未导入) */
  importedMap: Map<string, string> = new Map<string, string>();

  // ===== UI 弹窗状态 =====
  /** NSFW 警告弹窗:用户尝试关闭 NSFW 隐藏时弹出 */
  showNsfwConfirm: boolean = false;
  private pendingNsfwValue: boolean = true;

  /** 翻译隐私提示弹窗:首次开启翻译时弹出 */
  showTranslatePrivacy: boolean = false;

  // ===== 翻译状态 =====
  /** "翻译为中文"开关状态(默认关闭) */
  translateEnabled: boolean = false;
  /** 内存中翻译结果,key: remoteId */
  translations: Map<string, MarketTranslationResult> = new Map<string, MarketTranslationResult>();

  /** 搜索历史(用于搜索框下拉提示) */
  searchHistory: string[] = [];

  /** UI 状态变化回调(由页面绑定,绕开 @Observed 联合类型观察不可靠的问题) */
  onStateChanged: (() => void) | null = null;

  // ===== 内部状态 =====
  private marketService: MarketService;
  /** 翻译服务(可选,未注入时翻译功能不可用) */
  private translationService: MarketTranslationService | null;
  /** 操作 ID,每次新请求自增,旧请求返回时若 opId 不匹配则忽略结果 */
  private operationId: number = 0;
  /** 防抖定时器 ID,-1 表示无定时器 */
  private debounceTimerId: number = -1;
  /** 下一页游标(空字符串表示无更多数据,由 Chub 响应返回) */
  private nextCursor: string = '';
  /** 翻译任务 generationId,在 refresh/loadMore/筛选切换时递增,
   *  旧翻译回调到达时若 genId 不匹配则丢弃,避免写入陈旧结果 */
  private translationGenerationId: number = 0;

  constructor(service: MarketService, translationService: MarketTranslationService | null = null) {
    this.marketService = service;
    this.translationService = translationService;
  }

  // ===== 生命周期 =====

  /**
   * 加载用户偏好并刷新第一页。
   * 由页面 aboutToAppear 调用。
   */
  async load(): Promise<void> {
    await this.loadPreferences();
    await this.refresh();
  }

  /**
   * 释放资源,取消所有进行中的请求和定时器。
   * 由页面 aboutToDisappear 调用。
   */
  dispose(): void {
    this.operationId++; // 让所有进行中的请求结果作废
    this.translationGenerationId++; // 让所有进行中的翻译回调作废
    this.cancelDebounce();
    if (this.translationService !== null) {
      this.translationService.cancelAll();
    }
  }

  // ===== 加载与刷新 =====

  /**
   * 刷新第一页(重置分页)。
   * 取消所有进行中的请求与翻译任务。
   */
  async refresh(): Promise<void> {
    this.operationId++;
    this.translationGenerationId++;
    const opId: number = this.operationId;
    // 取消待执行的翻译任务(已发出的请求无法中止,但结果会被 MarketTranslationService 内部 opId 丢弃)
    if (this.translationService !== null) {
      this.translationService.cancelAll();
    }
    this.refreshing = true;
    this.errorMessage = '';
    this.nextCursor = '';
    this.hasMore = true;
    this.cancelDebounce();
    // 清空内存翻译(避免显示陈旧翻译)
    this.translations = new Map<string, MarketTranslationResult>();
    try {
      const query: MarketQuery = this.buildQuery('');
      const result: MarketPageResult = await this.marketService.searchCharacters(query);
      if (opId !== this.operationId) {
        return;
      }
      // 检查已导入状态
      const newMap: Map<string, string> = await this.marketService.checkImportedBatch(result.items);
      if (opId !== this.operationId) {
        return;
      }
      // 应用本地过滤(仅中文 + 隐藏已导入)
      let finalItems: MarketCharacter[] = this.applyLocalFilters(result.items, newMap);
      this.importedMap = newMap;
      this.items = finalItems;
      this.nextCursor = result.nextCursor;
      this.hasMore = result.nextCursor.length > 0;
      // 仅中文筛选开启时,可能本地过滤后不足一页,需要补足
      if (this.chineseOnly && this.hasMore && finalItems.length < DEFAULT_MARKET_PAGE_SIZE) {
        await this.fillMoreToReach(opId, DEFAULT_MARKET_PAGE_SIZE);
        if (opId !== this.operationId) {
          return;
        }
      }
      // 翻译触发
      this.maybeTranslateVisible();
    } catch (e) {
      if (opId !== this.operationId) {
        return;
      }
      this.errorMessage = this.formatError(e);
      Logger.error(LOG_TAG, 'refresh failed: ' + String(e));
    } finally {
      if (opId === this.operationId) {
        this.refreshing = false;
        this.notifyStateChanged();
      }
    }
  }

  /**
   * 加载下一页。
   * 防止重复加载、刷新中、无更多数据时直接返回。
   * chineseOnly 开启时,本地过滤后不足一页会循环拉取后续页,直到达到目标数量或无更多。
   */
  async loadMore(): Promise<void> {
    if (this.loadingMore || this.refreshing || !this.hasMore) {
      return;
    }
    this.loadingMore = true;
    this.translationGenerationId++;
    const opId: number = this.operationId;
    const genId: number = this.translationGenerationId;
    try {
      const targetBatchSize: number = DEFAULT_MARKET_PAGE_SIZE;
      const accumulated: MarketCharacter[] = [];
      const accumulatedImportedMap: Map<string, string> = new Map<string, string>();
      let cursor: string = this.nextCursor;
      let stillHasMore: boolean = true;

      // 循环拉取直到满足目标数量或远程无更多数据
      while (accumulated.length < targetBatchSize && stillHasMore) {
        if (opId !== this.operationId) {
          return;
        }
        const query: MarketQuery = this.buildQuery(cursor);
        const result: MarketPageResult = await this.marketService.searchCharacters(query);
        if (opId !== this.operationId) {
          return;
        }
        // 跨页去重(包括已加载 items 与本批已累积)
        const seen: Set<string> = new Set<string>();
        for (let i = 0; i < this.items.length; i++) {
          seen.add(marketCharacterKey(this.items[i]));
        }
        for (let i = 0; i < accumulated.length; i++) {
          seen.add(marketCharacterKey(accumulated[i]));
        }
        const dedupedNewItems: MarketCharacter[] = [];
        for (let i = 0; i < result.items.length; i++) {
          const item: MarketCharacter = result.items[i];
          const key: string = marketCharacterKey(item);
          if (!seen.has(key)) {
            dedupedNewItems.push(item);
            seen.add(key);
          }
        }

        // 检查已导入状态(仅新条目)
        const newMap: Map<string, string> = await this.marketService.checkImportedBatch(dedupedNewItems);
        if (opId !== this.operationId) {
          return;
        }
        // 合并到本批 importedMap
        newMap.forEach((value: string, key: string) => {
          accumulatedImportedMap.set(key, value);
        });

        // 应用本地过滤(仅中文 + 隐藏已导入)
        const filtered: MarketCharacter[] = this.applyLocalFilters(dedupedNewItems, accumulatedImportedMap);
        for (let i = 0; i < filtered.length; i++) {
          accumulated.push(filtered[i]);
        }

        cursor = result.nextCursor;
        stillHasMore = result.nextCursor.length > 0;

        // 防止死循环:本次远程返回空数据时停止
        if (result.items.length === 0) {
          stillHasMore = false;
          break;
        }
        // 非 chineseOnly 模式下一次请求即可
        if (!this.chineseOnly) {
          break;
        }
      }

      if (opId !== this.operationId) {
        return;
      }

      // 合并到主 importedMap
      const mergedMap: Map<string, string> = new Map<string, string>();
      this.importedMap.forEach((value: string, key: string) => {
        mergedMap.set(key, value);
      });
      accumulatedImportedMap.forEach((value: string, key: string) => {
        mergedMap.set(key, value);
      });

      // 合并 items(去重保险)
      if (accumulated.length > 0) {
        const existingKeys: Set<string> = new Set<string>();
        for (let i = 0; i < this.items.length; i++) {
          existingKeys.add(marketCharacterKey(this.items[i]));
        }
        const mergedItems: MarketCharacter[] = [];
        for (let i = 0; i < this.items.length; i++) {
          mergedItems.push(this.items[i]);
        }
        for (let i = 0; i < accumulated.length; i++) {
          const key: string = marketCharacterKey(accumulated[i]);
          if (!existingKeys.has(key)) {
            mergedItems.push(accumulated[i]);
            existingKeys.add(key);
          }
        }
        this.items = mergedItems;
      }
      this.importedMap = mergedMap;
      this.nextCursor = cursor;
      this.hasMore = stillHasMore;
      // 翻译触发(新加载的条目)
      if (genId === this.translationGenerationId) {
        this.maybeTranslateVisible();
      }
    } catch (e) {
      if (opId !== this.operationId) {
        return;
      }
      this.errorMessage = this.formatError(e);
      Logger.error(LOG_TAG, 'loadMore failed: ' + String(e));
    } finally {
      if (opId === this.operationId) {
        this.loadingMore = false;
        this.notifyStateChanged();
      }
    }
  }

  /**
   * 在 refresh 后补足本地过滤后的目标数量。
   * 循环调用 searchCharacters 拉取后续页,直到达到 targetCount 或无更多。
   * 仅用于 chineseOnly 模式下本地过滤后不足一页的情况。
   */
  private async fillMoreToReach(opId: number, targetCount: number): Promise<void> {
    let cursor: string = this.nextCursor;
    let stillHasMore: boolean = this.hasMore;
    while (this.items.length < targetCount && stillHasMore) {
      if (opId !== this.operationId) {
        return;
      }
      const query: MarketQuery = this.buildQuery(cursor);
      const result: MarketPageResult = await this.marketService.searchCharacters(query);
      if (opId !== this.operationId) {
        return;
      }
      // 跨页去重
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < this.items.length; i++) {
        seen.add(marketCharacterKey(this.items[i]));
      }
      const dedupedNewItems: MarketCharacter[] = [];
      for (let i = 0; i < result.items.length; i++) {
        const item: MarketCharacter = result.items[i];
        const key: string = marketCharacterKey(item);
        if (!seen.has(key)) {
          dedupedNewItems.push(item);
          seen.add(key);
        }
      }
      const newMap: Map<string, string> = await this.marketService.checkImportedBatch(dedupedNewItems);
      if (opId !== this.operationId) {
        return;
      }
      // 合并到主 importedMap
      const mergedMap: Map<string, string> = new Map<string, string>();
      this.importedMap.forEach((value: string, key: string) => {
        mergedMap.set(key, value);
      });
      newMap.forEach((value: string, key: string) => {
        mergedMap.set(key, value);
      });
      this.importedMap = mergedMap;

      const filtered: MarketCharacter[] = this.applyLocalFilters(dedupedNewItems, mergedMap);
      if (filtered.length > 0) {
        const mergedItems: MarketCharacter[] = [];
        for (let i = 0; i < this.items.length; i++) {
          mergedItems.push(this.items[i]);
        }
        for (let i = 0; i < filtered.length; i++) {
          mergedItems.push(filtered[i]);
        }
        this.items = mergedItems;
      }
      cursor = result.nextCursor;
      stillHasMore = result.nextCursor.length > 0;
      if (result.items.length === 0) {
        stillHasMore = false;
        break;
      }
    }
    this.nextCursor = cursor;
    this.hasMore = stillHasMore;
  }

  // ===== 搜索 =====

  /**
   * 搜索框输入变化,触发防抖。
   * 不在每个字符变化时立即请求。
   */
  onSearchInput(value: string): void {
    this.searchInput = value;
    this.notifyStateChanged();
    this.cancelDebounce();
    this.debounceTimerId = setTimeout((): void => {
      void this.applySearch();
    }, DEBOUNCE_MS);
  }

  /**
   * 提交搜索(立即触发,跳过防抖)。
   * 由搜索按钮或回车键调用。
   */
  async submitSearch(): Promise<void> {
    this.cancelDebounce();
    await this.applySearch();
  }

  /**
   * 应用搜索词,空搜索恢复默认推荐列表。
   */
  private async applySearch(): Promise<void> {
    this.debounceTimerId = -1;
    const trimmed: string = this.searchInput.trim();
    if (trimmed === this.appliedSearch) {
      return;
    }
    this.appliedSearch = trimmed;
    await this.refresh();
    if (trimmed.length > 0) {
      try {
        await this.marketService.addSearchHistory(trimmed);
        await this.reloadSearchHistory();
      } catch (e) {
        Logger.warn(LOG_TAG, 'addSearchHistory failed: ' + String(e));
      }
    }
  }

  /**
   * 清空搜索词。
   */
  async clearSearch(): Promise<void> {
    this.searchInput = '';
    this.appliedSearch = '';
    this.notifyStateChanged();
    this.cancelDebounce();
    await this.refresh();
  }

  // ===== 筛选 =====

  /**
   * 设置排序方式。
   */
  async setSort(value: MarketSort): Promise<void> {
    if (this.sort === value) {
      return;
    }
    this.sort = value;
    this.notifyStateChanged();
    try {
      await this.marketService.setSort(value);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setSort save failed: ' + String(e));
    }
    await this.refresh();
  }

  /**
   * 设置是否隐藏 NSFW。
   * 当用户尝试关闭隐藏(即显示 NSFW)时,弹出二次确认。
   */
  setHideNsfw(value: boolean): void {
    if (this.hideNsfw === value) {
      return;
    }
    if (!value) {
      // 用户尝试显示 NSFW,需要二次确认
      this.pendingNsfwValue = value;
      this.showNsfwConfirm = true;
      this.notifyStateChanged();
      return;
    }
    // 隐藏 NSFW 不需要确认
    void this.applyHideNsfw(value);
  }

  /**
   * 确认显示 NSFW 内容。
   */
  async confirmShowNsfw(): Promise<void> {
    this.showNsfwConfirm = false;
    this.notifyStateChanged();
    await this.applyHideNsfw(this.pendingNsfwValue);
  }

  /**
   * 取消显示 NSFW。
   */
  cancelShowNsfw(): void {
    this.showNsfwConfirm = false;
    this.pendingNsfwValue = true;
    this.notifyStateChanged();
  }

  /**
   * 设置是否隐藏已导入角色。
   */
  async setHideImported(value: boolean): Promise<void> {
    if (this.hideImported === value) {
      return;
    }
    this.hideImported = value;
    this.notifyStateChanged();
    try {
      await this.marketService.setHideImported(value);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setHideImported save failed: ' + String(e));
    }
    await this.refresh();
  }

  /**
   * 设置"仅中文角色"开关。
   * 启用后本地过滤:标签含中文、或名称/简介中文字符占比>=30%。
   * 不足一页时 loadMore 会循环拉取后续页。
   */
  async setChineseOnly(value: boolean): Promise<void> {
    if (this.chineseOnly === value) {
      return;
    }
    this.chineseOnly = value;
    this.notifyStateChanged();
    try {
      await this.marketService.setChineseOnly(value);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setChineseOnly save failed: ' + String(e));
    }
    await this.refresh();
  }

  /**
   * 设置标签筛选(空字符串表示清除标签筛选)。
   */
  async setTag(value: string): Promise<void> {
    if (this.tag === value) {
      return;
    }
    this.tag = value;
    this.notifyStateChanged();
    await this.refresh();
  }

  /**
   * 设置创作者筛选(空字符串表示清除创作者筛选)。
   */
  async setCreator(value: string): Promise<void> {
    if (this.creator === value) {
      return;
    }
    this.creator = value;
    this.notifyStateChanged();
    await this.refresh();
  }

  /**
   * 切换 Provider(第一版仅 chub)。
   */
  async setProvider(id: string): Promise<void> {
    if (this.providerId === id) {
      return;
    }
    try {
      await this.marketService.setCurrentProvider(id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setProvider failed: ' + String(e));
    }
    this.providerId = id;
    this.notifyStateChanged();
    await this.refresh();
  }

  // ===== 翻译开关 =====

  /**
   * 设置翻译开关状态。
   * 开启时若首次(translateEnabled=false → true),先弹出隐私提示。
   * 关闭时立即生效并清空内存翻译。
   */
  setTranslateEnabled(value: boolean): void {
    if (this.translateEnabled === value) {
      return;
    }
    if (value) {
      // 开启前弹出隐私提示
      this.showTranslatePrivacy = true;
      this.notifyStateChanged();
      return;
    }
    // 关闭不需要确认
    void this.applyTranslateEnabled(false);
  }

  /**
   * 确认开启翻译(用户阅读隐私提示后)。
   */
  async confirmEnableTranslate(): Promise<void> {
    this.showTranslatePrivacy = false;
    this.notifyStateChanged();
    await this.applyTranslateEnabled(true);
  }

  /**
   * 取消开启翻译。
   */
  cancelEnableTranslate(): void {
    this.showTranslatePrivacy = false;
    this.notifyStateChanged();
  }

  /**
   * 应用翻译开关状态(已确认或关闭)。
   */
  private async applyTranslateEnabled(value: boolean): Promise<void> {
    this.translateEnabled = value;
    this.notifyStateChanged();
    if (this.translationService !== null) {
      try {
        await this.translationService.setTranslateEnabled(value);
      } catch (e) {
        Logger.warn(LOG_TAG, 'setTranslateEnabled save failed: ' + String(e));
      }
    }
    if (value) {
      // 开启:对当前可见 items 发起翻译
      this.maybeTranslateVisible();
    } else {
      // 关闭:递增 generationId + 清空内存翻译(避免旧回调写入陈旧结果)
      this.translationGenerationId++;
      this.translations = new Map<string, MarketTranslationResult>();
      if (this.translationService !== null) {
        this.translationService.cancelAll();
      }
    }
  }

  /**
   * 获取指定角色的翻译(优先内存,其次缓存)。
   * 返回 null 表示未翻译,UI 显示原文。
   */
  getTranslation(item: MarketCharacter): MarketTranslationResult | null {
    // 内存命中
    const memHit: MarketTranslationResult | undefined = this.translations.get(item.remoteId);
    if (memHit !== undefined) {
      return memHit;
    }
    return null;
  }

  /**
   * 对当前可见 items 发起批量翻译(若翻译开关已开启)。
   * 内部使用 MarketTranslationService 的防抖 + 批量机制。
   * 页面离开后由 dispose() 取消所有待执行任务。
   * 过期结果通过 translationGenerationId 在 onTranslationResult 中丢弃。
   */
  private maybeTranslateVisible(): void {
    if (!this.translateEnabled) {
      return;
    }
    if (this.translationService === null) {
      return;
    }
    if (this.items.length === 0) {
      return;
    }
    // 当前 generationId,回调时用于检测是否过期
    const genId: number = this.translationGenerationId;
    // 过滤掉已缓存的(只翻译未缓存的)
    const pending: MarketCharacter[] = [];
    for (let i = 0; i < this.items.length; i++) {
      const item: MarketCharacter = this.items[i];
      // 不自动翻译隐藏 NSFW 内容(已在 hideNsfw=true 时被服务端过滤,这里无需二次判断)
      pending.push(item);
    }
    if (pending.length === 0) {
      return;
    }
    this.translationService.translateItems(pending, (remoteId: string, t: MarketTranslationResult): void => {
      this.onTranslationResult(remoteId, t, genId);
    });
  }

  /**
   * 单条翻译完成回调。
   * 写入内存 Map,触发 UI 重渲染。
   * 通过 translationGenerationId 检测过期结果,避免写入已切换掉的列表。
   */
  private onTranslationResult(remoteId: string, translation: MarketTranslationResult, genId: number): void {
    if (genId !== this.translationGenerationId) {
      // 旧任务结果丢弃(用户已切换筛选/搜索)
      return;
    }
    if (!this.translateEnabled) {
      // 翻译已被关闭,丢弃结果
      return;
    }
    // 仅在 remoteId 仍存在于当前 items 中时写入
    let found: boolean = false;
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].remoteId === remoteId) {
        found = true;
        break;
      }
    }
    if (!found) {
      return;
    }
    const newMap: Map<string, MarketTranslationResult> = new Map<string, MarketTranslationResult>();
    this.translations.forEach((v: MarketTranslationResult, k: string) => {
      newMap.set(k, v);
    });
    newMap.set(remoteId, translation);
    this.translations = newMap;
    this.notifyStateChanged();
  }

  // ===== 已导入状态 =====

  /**
   * 判断指定角色是否已导入。
   */
  isImported(item: MarketCharacter): boolean {
    const key: string = item.providerId + '|' + item.remoteId;
    const v: string | undefined = this.importedMap.get(key);
    return v !== undefined && v.length > 0;
  }

  /**
   * 获取已导入角色的本地 ID(未导入返回空字符串)。
   */
  getImportedLocalId(item: MarketCharacter): string {
    const key: string = item.providerId + '|' + item.remoteId;
    const v: string | undefined = this.importedMap.get(key);
    if (v === undefined) {
      return '';
    }
    return v;
  }

  /**
   * 导入成功后更新 importedMap。
   * 由详情页导入成功后调用,触发列表"已导入"标记刷新。
   */
  markImported(providerId: string, remoteId: string, localId: string): void {
    const key: string = providerId + '|' + remoteId;
    const newMap: Map<string, string> = new Map<string, string>();
    this.importedMap.forEach((value: string, k: string) => {
      newMap.set(k, value);
    });
    newMap.set(key, localId);
    this.importedMap = newMap;
    this.notifyStateChanged();
  }

  // ===== 搜索历史 =====

  /**
   * 重新加载搜索历史(用于搜索框下拉提示)。
   */
  async reloadSearchHistory(): Promise<void> {
    try {
      this.searchHistory = await this.marketService.getSearchHistory();
    } catch (e) {
      Logger.warn(LOG_TAG, 'reloadSearchHistory failed: ' + String(e));
    }
  }

  /**
   * 清空搜索历史。
   */
  async clearSearchHistory(): Promise<void> {
    try {
      await this.marketService.clearSearchHistory();
      this.searchHistory = [];
    } catch (e) {
      Logger.warn(LOG_TAG, 'clearSearchHistory failed: ' + String(e));
    }
  }

  // ===== 内部方法 =====

  /**
   * 加载用户偏好到 ViewModel 状态。
   */
  private async loadPreferences(): Promise<void> {
    try {
      const query: MarketQuery = await this.marketService.loadQueryPreferences();
      this.hideNsfw = query.hideNsfw;
      this.hideImported = query.hideImported;
      this.sort = query.sort;
      this.providerId = this.marketService.getCurrentProvider().providerId;
      this.searchInput = '';
      this.appliedSearch = '';
      // 加载"仅中文"偏好
      this.chineseOnly = await this.marketService.getChineseOnly();
      // 加载翻译偏好
      if (this.translationService !== null) {
        this.translateEnabled = await this.translationService.isTranslateEnabled();
      } else {
        this.translateEnabled = false;
      }
      await this.reloadSearchHistory();
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadPreferences failed: ' + String(e));
    }
  }

  /**
   * 应用 hideNsfw 偏好并刷新。
   */
  private async applyHideNsfw(value: boolean): Promise<void> {
    this.hideNsfw = value;
    this.notifyStateChanged();
    try {
      await this.marketService.setHideNsfw(value);
    } catch (e) {
      Logger.warn(LOG_TAG, 'applyHideNsfw save failed: ' + String(e));
    }
    await this.refresh();
  }

  /**
   * 取消防抖定时器。
   */
  private cancelDebounce(): void {
    if (this.debounceTimerId !== -1) {
      clearTimeout(this.debounceTimerId);
      this.debounceTimerId = -1;
    }
  }

  /**
   * 通知页面 UI 状态已变化(由页面通过 onStateChanged 回调同步本地 @State)。
   * 绕开 @Observed 类在 `@State XxxViewModel | null` 联合类型下属性观察不可靠的问题。
   */
  private notifyStateChanged(): void {
    if (this.onStateChanged !== null) {
      this.onStateChanged();
    }
  }

  /**
   * 构造查询参数。
   * @param cursor 下一页游标(空字符串表示第一页)
   */
  private buildQuery(cursor: string): MarketQuery {
    return {
      search: this.appliedSearch,
      sort: this.sort,
      tag: this.tag,
      creator: this.creator,
      hideNsfw: this.hideNsfw,
      hideImported: this.hideImported,
      page: 0,
      pageSize: DEFAULT_MARKET_PAGE_SIZE,
      cursor: cursor
    };
  }

  /**
   * 过滤已导入角色(本地过滤)。
   */
  private filterImported(
    items: MarketCharacter[],
    map: Map<string, string>
  ): MarketCharacter[] {
    const result: MarketCharacter[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: MarketCharacter = items[i];
      const key: string = item.providerId + '|' + item.remoteId;
      const v: string | undefined = map.get(key);
      const imported: boolean = v !== undefined && v.length > 0;
      if (!imported) {
        result.push(item);
      }
    }
    return result;
  }

  /**
   * 应用本地过滤(仅中文 + 隐藏已导入)。
   * 由 refresh/loadMore 在写入 items 前调用。
   */
  private applyLocalFilters(
    items: MarketCharacter[],
    map: Map<string, string>
  ): MarketCharacter[] {
    let result: MarketCharacter[] = items;
    if (this.chineseOnly) {
      result = this.filterChineseOnly(result);
    }
    if (this.hideImported) {
      result = this.filterImported(result, map);
    }
    return result;
  }

  /**
   * 仅中文角色本地过滤。
   * 判定标准(优先级):
   * 1) 任一标签包含中文字符 → 通过
   * 2) 名称中文字符占比 >= 30% → 通过
   * 3) 简介中文字符占比 >= 30% → 通过
   * 4) 否则 → 不通过(标记为未知语言,不显示)
   */
  private filterChineseOnly(items: MarketCharacter[]): MarketCharacter[] {
    const result: MarketCharacter[] = [];
    for (let i = 0; i < items.length; i++) {
      if (this.isChineseCharacter(items[i])) {
        result.push(items[i]);
      }
    }
    return result;
  }

  /**
   * 判断角色卡是否为中文角色。
   */
  private isChineseCharacter(item: MarketCharacter): boolean {
    // 优先级 1:标签中含中文
    for (let i = 0; i < item.tags.length; i++) {
      if (this.containsChinese(item.tags[i])) {
        return true;
      }
    }
    // 优先级 2:名称中文字符占比 >= 30%
    if (item.name.length > 0 && this.chineseRatio(item.name) >= 0.3) {
      return true;
    }
    // 优先级 3:简介中文字符占比 >= 30%
    if (item.summary.length > 0 && this.chineseRatio(item.summary) >= 0.3) {
      return true;
    }
    return false;
  }

  /**
   * 文本中是否包含 CJK 统一表意文字字符。
   * Unicode 范围 0x4E00 ~ 0x9FFF。
   */
  private containsChinese(text: string): boolean {
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) {
        return true;
      }
    }
    return false;
  }

  /**
   * 计算中文字符占文本长度的比例(0~1)。
   * 空文本返回 0。
   */
  private chineseRatio(text: string): number {
    if (text.length === 0) {
      return 0;
    }
    let count: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) {
        count++;
      }
    }
    return count / text.length;
  }

  /**
   * 格式化错误消息。
   */
  private formatError(e: Object): string {
    return '加载失败: ' + String(e);
  }
}
