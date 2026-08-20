/**
 * MarketQuery 市场查询参数
 *
 * 定义统一的查询参数,不与 Provider 原始 API 参数耦合。
 * Provider 负责将 MarketQuery 转换为自身 API 请求格式。
 */

/**
 * 市场排序方式。
 */
export enum MarketSort {
  /** 推荐 */
  Recommended = 'recommended',
  /** 最新 */
  Latest = 'latest',
  /** 热门 */
  Top = 'top'
}

/**
 * 市场查询参数。
 */
export interface MarketQuery {
  /** 搜索关键词(可空,空表示无关键词过滤) */
  readonly search: string;
  /** 排序方式 */
  readonly sort: MarketSort;
  /** 标签过滤(可空,空表示无标签过滤) */
  readonly tag: string;
  /** 创作者过滤(可空,空表示无创作者过滤) */
  readonly creator: string;
  /** 是否隐藏 NSFW 内容(默认 true) */
  readonly hideNsfw: boolean;
  /** 是否隐藏已导入角色(默认 false) */
  readonly hideImported: boolean;
  /** 分页起始偏移(0-based,兼容保留;Chub 实际用 cursor 分页) */
  readonly page: number;
  /** 每页条数 */
  readonly pageSize: number;
  /** 分页游标(空字符串表示第一页,由上次响应返回) */
  readonly cursor: string;
}

/**
 * 默认每页条数。
 */
export const DEFAULT_MARKET_PAGE_SIZE: number = 24;

/**
 * 创建默认 MarketQuery(推荐排序,无过滤,隐藏 NSFW)。
 */
export function createDefaultMarketQuery(): MarketQuery {
  return {
    search: '',
    sort: MarketSort.Recommended,
    tag: '',
    creator: '',
    hideNsfw: true,
    hideImported: false,
    page: 0,
    pageSize: DEFAULT_MARKET_PAGE_SIZE,
    cursor: ''
  };
}

/**
 * 市场查询结果分页。
 */
export interface MarketPageResult {
  /** 当前页角色列表 */
  readonly items: import('../models/MarketCharacter').MarketCharacter[];
  /** 下一页游标(空字符串表示无更多数据) */
  readonly nextCursor: string;
  /** 当前页码 */
  readonly page: number;
}

/**
 * 创建 MarketPageResult。
 */
export function createMarketPageResult(
  items: import('../models/MarketCharacter').MarketCharacter[],
  page: number,
  nextCursor: string
): MarketPageResult {
  return {
    items: items,
    page: page,
    nextCursor: nextCursor
  };
}
