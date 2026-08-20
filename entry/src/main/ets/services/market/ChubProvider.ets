/**
 * ChubProvider Chub 公共只读角色卡 Provider
 *
 * 基于 Chub 官方 Swagger(gateway.chub.ai/openapi.json)修正后的实现。
 *
 * 端点(均为 HTTPS,不需要 API Key):
 * - 列表/搜索:GET https://gateway.chub.ai/search
 *   2026 变更:所有参数放入 query string(旧 POST body 格式已被服务端忽略)。
 *   query: { search, sort, tags, nsfw, nsfl, explore, first, cursor }
 *   sort 新枚举值:download_count / id / rating / rating_count / last_activity_at /
 *     trending_downloads / n_favorites / created_at / star_count / name / timeline / random 等
 *   tags 为标签名(替代旧 searchtag),first 为每页条数(GraphQL 风格,非偏移),
 *   cursor 为分页游标(响应返回,空表示第一页)
 *   返回: { data: { count, nodes: [...], page, cursor } }(nodes 中每项含 fullPath/id/name/topics/
 *          avatar_url/max_res_url/starCount/lastActivityAt/projectSpace 等字段)
 * - 详情:GET https://gateway.chub.ai/api/characters/{fullPath}?full=true
 *   其中 {fullPath} = "creator/project-slug"
 *   Swagger 同时支持 /api/characters/{project_id}?full=true(数字 ID)
 *   返回: { errors, node: {...}, nodes, permissions, is_favorite }
 *   node.definition 含完整字段: first_message / example_dialogs / alternate_greetings /
 *     personality / scenario / system_prompt / post_history_instructions /
 *     embedded_lorebook / extensions 等
 * - PNG 下载:直接使用 node.max_res_url(完整 HTTPS URL,如
 *     https://avatars.charhub.io/avatars/<path>/chara_card_v2.png)
 * - 头像:直接使用 node.avatar_url(完整 HTTPS URL,webp 格式)
 *
 * 重大修正(对比上一版):
 * - BASE_URL: api.chub.ai → gateway.chub.ai
 * - 搜索改为 GET query string(2026 API 变更,旧 POST body 被忽略)
 * - 排序枚举改为新值(旧 recommended/latest/top 被忽略)
 * - searchtag → tags,分页 first/last 偏移 → first 页大小 + cursor 游标
 * - DETAIL_PATH: /api/characters/{remoteId} → /api/characters/{fullPath}?full=true
 * - 搜索响应: nodes → data.nodes,page.next → 通过 data.cursor 判断
 * - 列表字段: path → fullPath, tags → topics, download_count → starCount,
 *   updated_at → lastActivityAt(ISO 字符串), nsfw → nsfw_image, format → primaryFormat
 * - 详情字段: mes_example → example_dialogs, character_book → embedded_lorebook
 * - PNG 下载:不再拼接 baseUrl,直接使用响应中的完整 URL
 *
 * 安全要求:
 * - 强制 HTTPS
 * - 设置连接超时 10s,读取超时 30s
 * - 限制响应体大小 10MB
 * - 不重定向到本地/私有网络(由 HttpClient 层兜底)
 * - 不记录请求体、Authorization Header
 * - 日志只记录 host、path(不含 query)、状态码、响应前 200 字符(脱敏)
 *
 * 错误处理:
 * - 网络错误转换为 NetworkError
 * - 响应解析失败返回 Parse 错误
 * - 字段缺失使用默认值(不抛错)
 */

import { HttpClient, HttpRequestOptions, HttpMethod, HttpHeaders, HttpResponse } from '../../network/core/HttpClient';
import { NetworkError, NetworkErrorType, createNetworkError } from '../../models/NetworkError';
import { MarketCharacter, createMarketCharacter } from '../../models/MarketCharacter';
import {
  MarketCharacterDetail,
  createMarketCharacterDetail,
  truncateMarketText
} from '../../models/MarketCharacterDetail';
import { MarketQuery, MarketPageResult, MarketSort, createMarketPageResult } from '../../models/MarketQuery';
import { MarketProvider } from './MarketProvider';
import { Logger } from '../../utils/Logger';
import http from '@ohos.net.http';

const LOG_TAG: string = 'ChubProvider';
const PROVIDER_ID: string = 'chub';
const PROVIDER_DISPLAY_NAME: string = 'Chub';
/** Chub 官方 API 网关地址(2026 修正) */
const BASE_URL: string = 'https://gateway.chub.ai';
/** 搜索端点(POST,Swagger operationId: proxy_search_search_post) */
const SEARCH_PATH: string = '/search';
/** 详情端点前缀(Swagger: GET /api/{namespace}/{creator_name}/{project_name}?full=true)
 * namespace 固定为 "characters"(角色卡命名空间),后跟 fullPath "creator/project-slug" */
const DETAIL_PATH_PREFIX: string = '/api/characters/';
/** Chub 站点角色卡页面基础 URL(用于构造 sourceUrl,跳转到浏览器查看) */
const SOURCE_BASE_URL: string = 'https://chub.ai/characters/';
const USER_AGENT: string = 'ArkTavern/1.0 (HarmonyOS NEXT)';
const CONNECT_TIMEOUT_MS: number = 10000;
const READ_TIMEOUT_MS: number = 30000;
const MAX_RESPONSE_BYTES: number = 10 * 1024 * 1024; // 10MB
/** PNG 二进制最大字节数(50MB,与 MarketImportService.MAX_PNG_BYTES 一致) */
const MAX_PNG_BYTES: number = 50 * 1024 * 1024;
/** Chub 搜索响应日志最大预览长度 */
const RESPONSE_PREVIEW_LEN: number = 200;

/**
 * Chub 公共只读角色卡 Provider 实现。
 */
export class ChubProvider implements MarketProvider {
  readonly providerId: string = PROVIDER_ID;
  readonly displayName: string = PROVIDER_DISPLAY_NAME;

  private readonly httpClient: HttpClient;

  constructor(httpClient: HttpClient) {
    this.httpClient = httpClient;
  }

  requiresAuth(): boolean {
    return false;
  }

  /**
   * 搜索角色卡。
   * 空搜索词时返回推荐列表(sort 字段决定排序)。
   *
   * 2026 API 变更:所有参数改为 URL query string,
   * 排序用新枚举值,tag 用 tags,分页改用 cursor(不再用 first/last 偏移)。
   */
  async searchCharacters(query: MarketQuery): Promise<MarketPageResult> {
    const url: string = buildSearchUrl(query);
    const headers: HttpHeaders = buildJsonHeaders();
    const options: HttpRequestOptions = {
      method: HttpMethod.GET,
      url: url,
      headers: headers,
      connectTimeoutMs: CONNECT_TIMEOUT_MS,
      readTimeoutMs: READ_TIMEOUT_MS
    };

    const response: HttpResponse = await this.sendRequest(options);
    if (response.statusCode !== 200) {
      // 记录 404/500 等错误响应预览,便于诊断
      Logger.error(LOG_TAG, 'search failed status=' + response.statusCode.toString()
        + ' preview=' + truncateForLog(response.body, RESPONSE_PREVIEW_LEN));
      throw createNetworkError(
        errorTypeFromStatus(response.statusCode),
        'Chub search failed: ' + response.statusCode.toString(),
        { retryable: response.statusCode >= 500, statusCode: response.statusCode }
      );
    }
    return parseSearchResponse(response.body);
  }

  /**
   * 获取角色卡详情(完整字段)。
   * remoteId 为 Chub 的 fullPath(creator/project-slug)。
   */
  async getCharacterDetail(remoteId: string): Promise<MarketCharacterDetail> {
    if (remoteId.length === 0) {
      throw createNetworkError(
        NetworkErrorType.InvalidRequest,
        'Chub detail: remoteId is empty'
      );
    }
    // remoteId = "creator/project-slug",直接拼接到 /api/characters/{fullPath}
    // 不对 remoteId 做 encodeURI(Chub 项目 slug 不含需要编码的字符,如含斜杠会被误编)
    const url: string = BASE_URL + DETAIL_PATH_PREFIX + remoteId + '?full=true';
    const headers: HttpHeaders = buildJsonHeaders();
    const options: HttpRequestOptions = {
      method: HttpMethod.GET,
      url: url,
      headers: headers,
      connectTimeoutMs: CONNECT_TIMEOUT_MS,
      readTimeoutMs: READ_TIMEOUT_MS
    };

    const response: HttpResponse = await this.sendRequest(options);
    if (response.statusCode !== 200) {
      Logger.error(LOG_TAG, 'detail failed status=' + response.statusCode.toString()
        + ' remoteId=' + remoteId
        + ' preview=' + truncateForLog(response.body, RESPONSE_PREVIEW_LEN));
      throw createNetworkError(
        errorTypeFromStatus(response.statusCode),
        'Chub detail failed: ' + response.statusCode.toString(),
        { retryable: response.statusCode >= 500, statusCode: response.statusCode }
      );
    }
    return parseDetailResponse(response.body, remoteId);
  }

  /**
   * 下载角色卡 PNG 字节。
   * 流程:
   * 1. 调用 getCharacterDetail 获取详情响应中的 max_res_url(完整 HTTPS URL)
   * 2. 用 @ohos.net.http 直接下载二进制(HttpClient.body 是 string,不适合二进制)
   * 3. 返回 Uint8Array 字节
   * 失败或 URL 为空时返回 null,调用方(MarketImportService)回退到 downloadJson。
   *
   * 安全:
   * - 仅允许 HTTPS URL
   * - 设置连接/读取超时
   * - 限制最大字节数 50MB
   * - 跟随 HTTPS 重定向(@ohos.net.http 默认行为)
   * - 日志只记录 host 和状态码,不记录 URL 完整路径(可能含 token)
   */
  async downloadPng(remoteId: string): Promise<Uint8Array | null> {
    if (remoteId.length === 0) {
      Logger.warn(LOG_TAG, 'downloadPng: empty remoteId');
      return null;
    }
    let pngUrl: string = '';
    try {
      const detail: MarketCharacterDetail = await this.getCharacterDetail(remoteId);
      pngUrl = detail.pngDownloadUrl;
    } catch (e) {
      Logger.warn(LOG_TAG, 'downloadPng: getCharacterDetail failed: ' + String(e));
      return null;
    }
    if (pngUrl.length === 0) {
      Logger.warn(LOG_TAG, 'downloadPng: no pngDownloadUrl in detail');
      return null;
    }
    if (!pngUrl.startsWith('https://')) {
      Logger.warn(LOG_TAG, 'downloadPng: non-https url rejected');
      return null;
    }
    return await downloadBinary(pngUrl, MAX_PNG_BYTES);
  }

  /**
   * 下载角色卡 JSON(Tavern Card V2 格式)。
   * 从详情响应的 definition 字段构造 V2 JSON。
   */
  async downloadJson(remoteId: string): Promise<string> {
    const detail: MarketCharacterDetail = await this.getCharacterDetail(remoteId);
    if (detail.rawCardJson.length > 0) {
      return detail.rawCardJson;
    }
    // 兜底:构造最小 V2 JSON
    return buildFallbackV2Json(detail);
  }

  /**
   * 获取来源页面 URL(用户可点击跳转到 Chub 站点)。
   */
  getSourceUrl(remoteId: string): string {
    return SOURCE_BASE_URL + remoteId;
  }

  // ===== 内部方法 =====

  /**
   * 发送请求并校验响应体大小。
   */
  private async sendRequest(options: HttpRequestOptions): Promise<HttpResponse> {
    const response: HttpResponse = await this.httpClient.request(options);
    // 校验响应体大小(粗略估算:UTF-8 字符数 ≈ 字节数)
    if (response.body.length > MAX_RESPONSE_BYTES) {
      throw createNetworkError(
        NetworkErrorType.InvalidRequest,
        'Response too large'
      );
    }
    return response;
  }
}

// ===== 辅助函数 =====

/**
 * 构建 JSON 请求头。
 */
function buildJsonHeaders(): HttpHeaders {
  const headers: HttpHeaders = new Map<string, string>();
  headers.set('Accept', 'application/json');
  headers.set('Content-Type', 'application/json');
  headers.set('User-Agent', USER_AGENT);
  return headers;
}

/**
 * 通过 @ohos.net.http 直接下载二进制字节。
 * 用于 PNG 下载场景(HttpClient.body 是 string,不适合二进制)。
 *
 * 行为:
 * - 强制使用 GET 方法
 * - 设置 User-Agent 和 Accept(允许 image/png 和通配)
 * - 使用 ARRAY_BUFFER 数据类型接收二进制
 * - 跟随 HTTPS 重定向(@ohos.net.http 默认行为)
 * - 限制最大字节数 maxSize,超限返回 null
 * - 日志只记录 host 与状态码
 *
 * @param url 完整 HTTPS URL
 * @param maxSize 最大允许字节数
 * @returns Uint8Array 字节,失败返回 null
 */
function downloadBinary(url: string, maxSize: number): Promise<Uint8Array | null> {
  return new Promise<Uint8Array | null>((resolve, reject) => {
    const host: string = extractHostFromUrl(url);

    const httpRequest: http.HttpRequest = http.createHttp();
    const headerObj: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': 'image/png,image/*,*/*;q=0.8'
    };
    const httpOptions: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headerObj,
      connectTimeout: CONNECT_TIMEOUT_MS,
      readTimeout: READ_TIMEOUT_MS,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    };

    httpRequest.request(url, httpOptions)
      .then((response: http.HttpResponse) => {
        try {
          const statusCode: number = response.responseCode;
          if (statusCode !== 200) {
            Logger.warn(LOG_TAG, 'downloadBinary non-200 status=' + statusCode.toString());
            resolve(null);
            return;
          }
          const result: Object = response.result;
          if (result === undefined || result === null) {
            Logger.warn(LOG_TAG, 'downloadBinary: empty body');
            resolve(null);
            return;
          }
          if (!(result instanceof ArrayBuffer)) {
            Logger.warn(LOG_TAG, 'downloadBinary: non-ArrayBuffer body');
            resolve(null);
            return;
          }
          const buffer: ArrayBuffer = result as ArrayBuffer;
          if (buffer.byteLength > maxSize) {
            Logger.warn(LOG_TAG, 'downloadBinary: body too large size=' + buffer.byteLength.toString());
            resolve(null);
            return;
          }
          resolve(new Uint8Array(buffer));
        } finally {
          destroyHttpQuietly(httpRequest);
        }
      })
      .catch((err: BusinessError) => {
        destroyHttpQuietly(httpRequest);
        Logger.warn(LOG_TAG, 'downloadBinary failed host=' + host + ' code=' + err.code.toString());
        // 不抛错,返回 null 让调用方回退到 JSON 导入
        resolve(null);
      });
  });
}

/**
 * 从 URL 中提取 host(含协议),用于日志记录。
 * 不记录路径和查询参数(可能含 token)。
 */
function extractHostFromUrl(url: string): string {
  if (url.length === 0) {
    return '[empty]';
  }
  const protocolEnd: number = url.indexOf('://');
  if (protocolEnd < 0) {
    return '[unknown]';
  }
  const pathStart: number = url.indexOf('/', protocolEnd + 3);
  if (pathStart < 0) {
    return url;
  }
  return url.substring(0, pathStart);
}

/**
 * 安全销毁 HttpRequest,不抛异常。
 */
function destroyHttpQuietly(httpRequest: http.HttpRequest): void {
  try {
    httpRequest.destroy();
  } catch (e) {
    // 忽略
  }
}

/**
 * 将 MarketSort 映射为 Chub 2026 新 sort 枚举值。
 * 旧值 recommended/latest/top 已被 API 废弃(服务端直接忽略),改为:
 * - Recommended → n_favorites(最多收藏,数据池完整)
 * - Latest → created_at(最新创建)
 * - Top → download_count(下载最多)
 */
function mapSort(sort: MarketSort): string {
  switch (sort) {
    case MarketSort.Latest:
      return 'created_at';
    case MarketSort.Top:
      return 'download_count';
    case MarketSort.Recommended:
    default:
      return 'n_favorites';
  }
}

/**
 * 构建 Chub 搜索 URL(全部参数放入 query string)。
 * 2026 API:GET /search?search=..&sort=..&tags=..&nsfw=..&nsfl=..&explore=..&first=..&cursor=..
 * - first 为每页条数(GraphQL 风格,不是偏移)
 * - cursor 为空字符串时表示第一页
 * - 无 search/tag/cursor 时不携带对应参数
 */
function buildSearchUrl(query: MarketQuery): string {
  const parts: string[] = [];
  if (query.search.length > 0) {
    parts.push('search=' + encodeURIComponent(query.search));
  }
  parts.push('sort=' + mapSort(query.sort));
  if (query.tag.length > 0) {
    parts.push('tags=' + encodeURIComponent(query.tag));
  }
  parts.push('nsfw=' + (query.hideNsfw ? 'false' : 'true'));
  parts.push('nsfl=false');
  parts.push('explore=false');
  parts.push('first=' + query.pageSize.toString());
  if (query.cursor.length > 0) {
    parts.push('cursor=' + encodeURIComponent(query.cursor));
  }
  return BASE_URL + SEARCH_PATH + '?' + parts.join('&');
}

/**
 * 从 HTTP 状态码映射错误类型。
 */
function errorTypeFromStatus(statusCode: number): NetworkErrorType {
  if (statusCode === 400) {
    return NetworkErrorType.InvalidRequest;
  }
  if (statusCode === 401 || statusCode === 403) {
    return NetworkErrorType.Authentication;
  }
  if (statusCode === 408) {
    return NetworkErrorType.Timeout;
  }
  if (statusCode === 429) {
    return NetworkErrorType.RateLimit;
  }
  if (statusCode >= 500 && statusCode <= 599) {
    return NetworkErrorType.Server;
  }
  if (statusCode === 404) {
    return NetworkErrorType.InvalidRequest;
  }
  return NetworkErrorType.Unknown;
}

/**
 * 截取响应体前 N 字符用于日志(脱敏:不记录完整内容)。
 */
function truncateForLog(body: string, maxLen: number): string {
  if (body.length <= maxLen) {
    return body;
  }
  return body.substring(0, maxLen) + '...';
}

/**
 * 解析搜索响应 JSON,转换为 MarketPageResult。
 * 2026 实际响应结构:
 *   { data: { count: number, nodes: [...], page: number, previous_cursor, cursor } }
 * cursor 为下一页游标(空字符串表示无更多数据)。
 */
function parseSearchResponse(body: string): MarketPageResult {
  let parsed: Record<string, Object>;
  try {
    parsed = JSON.parse(body) as Record<string, Object>;
  } catch (e) {
    throw createNetworkError(
      NetworkErrorType.Parse,
      'Chub search response parse failed'
    );
  }
  // 提取 data 字段(2026 实际响应在 data.nodes 中)
  const dataRaw: Object | undefined = parsed['data'];
  let nodesArr: Object[];
  let page: number = 0;
  let nextCursor: string = '';
  if (dataRaw !== undefined && dataRaw !== null) {
    const dataObj: Record<string, Object> = dataRaw as Record<string, Object>;
    const nodesRaw: Object | undefined = dataObj['nodes'];
    if (nodesRaw === undefined || nodesRaw === null) {
      nodesArr = [];
    } else {
      nodesArr = nodesRaw as Object[];
    }
    // 当前页页码
    const pageRaw: Object | undefined = dataObj['page'];
    if (typeof pageRaw === 'number') {
      page = pageRaw as number;
    }
    // 下一页游标(响应中为 null 或无字段时表示无更多数据)
    const cursorRaw: Object | undefined = dataObj['cursor'];
    if (cursorRaw !== undefined && cursorRaw !== null && typeof cursorRaw === 'string') {
      nextCursor = cursorRaw as string;
    }
  } else {
    // 兜底:旧版结构直接取顶层 nodes(无游标,不触发加载更多)
    const nodesRaw: Object | undefined = parsed['nodes'];
    nodesArr = (nodesRaw === undefined || nodesRaw === null) ? [] : nodesRaw as Object[];
  }

  const items: MarketCharacter[] = [];
  for (let i = 0; i < nodesArr.length; i++) {
    const node: Record<string, Object> = nodesArr[i] as Record<string, Object>;
    const character: MarketCharacter | null = mapChubNodeToMarketCharacter(node);
    if (character !== null) {
      items.push(character);
    }
  }

  return createMarketPageResult(items, page, nextCursor);
}

/**
 * 解析详情响应 JSON,转换为 MarketCharacterDetail。
 * 实际响应结构(2026 实测):
 *   { errors: null, node: {...}, nodes, permissions, is_favorite }
 * node.definition 含完整字段:
 *   first_message / example_dialogs / alternate_greetings / personality /
 *   scenario / system_prompt / post_history_instructions / embedded_lorebook /
 *   extensions / character_version 等
 */
function parseDetailResponse(body: string, remoteId: string): MarketCharacterDetail {
  let parsed: Record<string, Object>;
  try {
    parsed = JSON.parse(body) as Record<string, Object>;
  } catch (e) {
    throw createNetworkError(
      NetworkErrorType.Parse,
      'Chub detail response parse failed'
    );
  }
  const nodeRaw: Object | undefined = parsed['node'];
  if (nodeRaw === undefined || nodeRaw === null) {
    throw createNetworkError(
      NetworkErrorType.Parse,
      'Chub detail: missing node'
    );
  }
  const node: Record<string, Object> = nodeRaw as Record<string, Object>;

  // 构造列表项基础字段
  const baseOrNull: MarketCharacter | null = mapChubNodeToMarketCharacter(node);
  if (baseOrNull === null) {
    throw createNetworkError(
      NetworkErrorType.Parse,
      'Chub detail: missing id or name in node'
    );
  }
  const base: MarketCharacter = baseOrNull;

  // 从 definition 提取完整字段
  const defRaw: Object | undefined = node['definition'];
  const def: Record<string, Object> = defRaw !== undefined && defRaw !== null
    ? defRaw as Record<string, Object> : {};

  const description: string = getStringField(def, 'description');
  const personality: string = getStringField(def, 'personality');
  const scenario: string = getStringField(def, 'scenario');
  const firstMessage: string = getStringField(def, 'first_message');
  const firstMessagePreview: string = truncateMarketText(firstMessage, 500);
  const creatorNotes: string = getStringField(def, 'creator_notes') !== ''
    ? getStringField(def, 'creator_notes')
    : getStringField(node, 'description');
  const postHistoryInstructions: string = getStringField(def, 'post_history_instructions');
  const characterVersion: string = getStringField(def, 'character_version');
  // Chub 实际字段为 example_dialogs(不是 mes_example)
  const mesExample: string = getStringField(def, 'example_dialogs');
  const hasMessageExample: boolean = mesExample.length > 0;

  // 备用开场白
  const altGreetings: string[] = getStringArrayField(def, 'alternate_greetings');
  const altGreetingsPreview: string[] = [];
  for (let i = 0; i < altGreetings.length && i < 5; i++) {
    altGreetingsPreview.push(truncateMarketText(altGreetings[i], 200));
  }

  // 角色世界书(Chub 字段为 embedded_lorebook)
  let characterBookEntryCount: number = 0;
  const bookRaw: Object | undefined = def['embedded_lorebook'];
  if (bookRaw !== undefined && bookRaw !== null) {
    const bookObj: Record<string, Object> = bookRaw as Record<string, Object>;
    const entriesRaw: Object | undefined = bookObj['entries'];
    if (entriesRaw !== undefined && entriesRaw !== null) {
      const entriesArr: Object[] = entriesRaw as Object[];
      characterBookEntryCount = entriesArr.length;
    }
  }

  // PNG 下载 URL(node 顶层的 max_res_url,完整 HTTPS URL)
  const pngDownloadUrl: string = getStringField(node, 'max_res_url');

  // 完整角色卡 JSON(从 definition 构造 Tavern Card V2)
  const rawCardJson: string = buildV2JsonFromDefinition(def, base.name);

  return createMarketCharacterDetail(
    base,
    description,
    personality,
    scenario,
    firstMessagePreview,
    altGreetingsPreview,
    altGreetings.length,
    hasMessageExample,
    creatorNotes,
    postHistoryInstructions,
    characterBookEntryCount,
    characterVersion,
    rawCardJson,
    pngDownloadUrl
  );
}

/**
 * 将 Chub node 对象映射为 MarketCharacter。
 * 字段缺失时使用默认值,不抛错。
 *
 * 关键字段映射(2026 实测):
 * - id: project_id(number,内部 ID)
 * - name: 角色名
 * - fullPath: "creator/project-slug"(完整路径,作为 remoteId)
 * - tagline: 简短介绍(代替 summary)
 * - description: 完整描述(tagline 为空时截取前 200 字符)
 * - topics: 标签数组(代替 tags)
 * - starCount: 星数(代替 download_count)
 * - lastActivityAt: ISO 时间字符串(代替 updated_at 数字时间戳)
 * - rating: number
 * - ratingCount: number
 * - nsfw_image: boolean(代替 nsfw)
 * - primaryFormat: 卡格式(可能为 null)
 * - avatar_url: 头像 URL(完整 HTTPS)
 * - max_res_url: PNG 角色卡 URL(完整 HTTPS)
 * - projectSpace: 命名空间(固定 "characters")
 */
function mapChubNodeToMarketCharacter(node: Record<string, Object>): MarketCharacter | null {
  const idStr: string = getStringField(node, 'id');
  const name: string = getStringField(node, 'name');
  if (idStr.length === 0 || name.length === 0) {
    return null;
  }
  // fullPath 优先(用于详情请求与 sourceUrl 构造),回退到 id
  const fullPath: string = getStringField(node, 'fullPath');
  const remoteId: string = fullPath.length > 0 ? fullPath : idStr;

  // creator: fullPath 第一段(creator/project-slug 的前半部分)
  let creator: string = '';
  if (fullPath.length > 0) {
    const slashIdx: number = fullPath.indexOf('/');
    if (slashIdx > 0) {
      creator = fullPath.substring(0, slashIdx);
    }
  }
  // 兜底:尝试 creatorName 字段(部分版本可能存在)
  if (creator.length === 0) {
    creator = getFirstNonEmptyString(node, ['creatorName', 'creator']);
  }

  // summary: tagline 优先,为空时截取 description 前 200 字符
  const tagline: string = getStringField(node, 'tagline');
  const description: string = getStringField(node, 'description');
  const summary: string = tagline.length > 0 ? tagline : truncateMarketText(description, 200);

  // 头像 URL(完整 HTTPS,直接使用)
  const avatarUrl: string = getFirstNonEmptyString(node, ['avatar_url', 'avatarUrl', 'avatar']);

  // 标签:Chub 实际字段为 topics(不是 tags)
  let tags: string[] = getStringArrayField(node, 'topics');
  if (tags.length === 0) {
    tags = getStringArrayField(node, 'tags');
  }

  // 数值字段
  const rating: number = getNumberField(node, 'rating');
  let downloadCount: number = getNumberField(node, 'starCount');
  if (downloadCount < 0) {
    const favCount: number = getNumberField(node, 'n_favorites');
    if (favCount >= 0) {
      downloadCount = favCount;
    }
  }

  // 更新时间:Chub 实际字段为 lastActivityAt(ISO 字符串)
  // 转换为毫秒时间戳(便于 UI 格式化)
  const updatedAt: number = parseIsoTimestamp(getStringField(node, 'lastActivityAt'));

  // NSFW:Chub 实际字段为 nsfw_image
  const nsfw: boolean = getBoolField(node, 'nsfw_image');
  // 卡格式:Chub 实际字段为 primaryFormat(可能为 null)
  const formatValue: string = getStringField(node, 'primaryFormat');
  const cardFormat: string = formatValue.length > 0 ? formatValue : 'tavern_card_v2';

  // 是否含世界书:列表响应通常不返回 embedded_lorebook 字段,默认 false
  // 详情响应中 def.embedded_lorebook 才有数据
  const hasCharacterBook: boolean = false;

  const sourceUrl: string = SOURCE_BASE_URL + remoteId;
  return createMarketCharacter(
    PROVIDER_ID, remoteId, name, creator, summary,
    avatarUrl, tags, rating, downloadCount, updatedAt, nsfw,
    sourceUrl, cardFormat, hasCharacterBook
  );
}

/**
 * 解析 ISO 8601 时间字符串为毫秒时间戳。
 * 解析失败返回 -1。
 */
function parseIsoTimestamp(iso: string): number {
  if (iso.length === 0) {
    return -1;
  }
  const ts: number = Date.parse(iso);
  if (isNaN(ts)) {
    return -1;
  }
  return ts;
}

/**
 * 从 definition 对象构造 Tavern Card V2 JSON 字符串。
 * 保留原始字段(若 definition 本身是完整 V2,则直接序列化)。
 *
 * Chub definition 字段与 V2 spec 字段名映射:
 * - first_message → first_mes
 * - example_dialogs → mes_example
 * - embedded_lorebook → character_book
 */
function buildV2JsonFromDefinition(def: Record<string, Object>, fallbackName: string): string {
  // definition 中 name 可能为空,优先用 def.name,回退到 fallbackName
  const nameValue: string = getStringField(def, 'name');
  const name: string = nameValue.length > 0 ? nameValue : fallbackName;

  // 取出 extensions(若有,不覆盖第三方已有字段)
  const extensions: Record<string, Object> = getObjectField(def, 'extensions');

  // Chub embedded_lorebook 映射为 V2 character_book
  const bookRaw: Object | undefined = def['embedded_lorebook'];
  const characterBook: Object | null = (bookRaw !== undefined && bookRaw !== null) ? bookRaw : null;

  const v2Card: TavernCardV2Wrapper = {
    spec: 'chara_card_v2',
    spec_version: '2.0',
    data: {
      name: name,
      description: getStringField(def, 'description'),
      personality: getStringField(def, 'personality'),
      scenario: getStringField(def, 'scenario'),
      first_mes: getStringField(def, 'first_message'),
      mes_example: getStringField(def, 'example_dialogs'),
      creator_notes: getStringField(def, 'creator_notes'),
      system_prompt: getStringField(def, 'system_prompt'),
      post_history_instructions: getStringField(def, 'post_history_instructions'),
      alternate_greetings: getStringArrayField(def, 'alternate_greetings'),
      tags: getStringArrayField(def, 'tags'),
      creator: getStringField(def, 'creator'),
      character_version: getStringField(def, 'character_version'),
      extensions: extensions,
      character_book: characterBook
    }
  };
  try {
    return JSON.stringify(v2Card);
  } catch (e) {
    // 序列化失败,返回最小 JSON
    return '{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"' + fallbackName + '"}}';
  }
}

/**
 * 构造最小 V2 JSON(详情解析失败时的兜底)。
 */
function buildFallbackV2Json(detail: MarketCharacterDetail): string {
  const v2Card: TavernCardV2Wrapper = {
    spec: 'chara_card_v2',
    spec_version: '2.0',
    data: {
      name: detail.base.name,
      description: detail.description,
      personality: detail.personality,
      scenario: detail.scenario,
      first_mes: detail.firstMessagePreview,
      mes_example: '',
      creator_notes: detail.creatorNotes,
      system_prompt: '',
      post_history_instructions: detail.postHistoryInstructions,
      alternate_greetings: detail.alternateGreetingsPreview,
      tags: detail.base.tags,
      creator: detail.base.creator,
      character_version: detail.characterVersion,
      extensions: {},
      character_book: null
    }
  };
  return JSON.stringify(v2Card);
}

// ===== 类型定义 =====

interface TavernCardV2Wrapper {
  spec: string;
  spec_version: string;
  data: TavernCardV2Data;
}

interface TavernCardV2Data {
  name: string;
  description: string;
  personality: string;
  scenario: string;
  first_mes: string;
  mes_example: string;
  creator_notes: string;
  system_prompt: string;
  post_history_instructions: string;
  alternate_greetings: string[];
  tags: string[];
  creator: string;
  character_version: string;
  extensions: Record<string, Object>;
  character_book: Object | null;
}

// ===== JSON 字段访问辅助 =====

function getStringField(obj: Record<string, Object>, key: string): string {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  return String(v);
}

/**
 * 按顺序尝试多个 key,返回第一个非空字符串。
 * 都为空时返回空字符串。
 */
function getFirstNonEmptyString(obj: Record<string, Object>, keys: string[]): string {
  for (let i = 0; i < keys.length; i++) {
    const v: string = getStringField(obj, keys[i]);
    if (v.length > 0) {
      return v;
    }
  }
  return '';
}

function getNumberField(obj: Record<string, Object>, key: string): number {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return -1;
  }
  if (typeof v === 'number') {
    return v as number;
  }
  const n: number = Number(v);
  return isNaN(n) ? -1 : n;
}

function getBoolField(obj: Record<string, Object>, key: string): boolean {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return false;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  if (typeof v === 'string') {
    return (v as string).toLowerCase() === 'true';
  }
  return false;
}

function getStringArrayField(obj: Record<string, Object>, key: string): string[] {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return [];
  }
  if (Array.isArray(v)) {
    const arr: Object[] = v as Object[];
    const result: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      if (typeof item === 'string') {
        result.push(item as string);
      } else {
        result.push(String(item));
      }
    }
    return result;
  }
  return [];
}

function getObjectField(obj: Record<string, Object>, key: string): Record<string, Object> {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return {};
  }
  if (typeof v === 'object') {
    return v as Record<string, Object>;
  }
  return {};
}
