/**
 * HarmonyHttpClient 基于 @ohos.net.http 的非流式 HTTP 客户端
 *
 * 实现 HttpClient 接口的普通 request 方法,用于非流式 AI Provider 请求。
 * 流式方法 requestStream 明确抛出 NotSupported,流式场景由 HttpStreamTransport 承担,
 * 本类不复制 HttpStreamTransport 逻辑。
 *
 * 依赖:
 * - @ohos.net.http(createHttp / request / destroy)
 * - @ohos.util.TextDecoder(ArrayBuffer → UTF-8 字符串)
 * - NetworkError(错误模型)
 *
 * 设计原则:
 * - 每次请求使用独立 HttpRequest,不复用
 * - 请求完成/失败/超时后 destroy
 * - 不使用 any
 * - 不记录完整 Header、请求 Body、响应原文
 * - 不实现自动重试
 * - 不重用已结束 HttpRequest
 *
 * 安全要求:
 * - 不记录 Authorization
 * - 不记录请求 Body
 * - 不记录响应原文
 * - 最多记录 host(不含查询参数)
 */

import http from '@ohos.net.http';
import util from '@ohos.util';
import {
  NetworkError,
  NetworkErrorType,
  createNetworkError
} from '../../models/NetworkError';
import {
  HttpClient,
  HttpMethod,
  HttpHeaders,
  HttpRequestOptions,
  HttpResponse,
  StreamCallbacks,
  AbortHandle
} from './HttpClient';
import { Logger } from '../../utils/Logger';

/** 日志标签 */
const LOG_TAG: string = 'HarmonyHttpClient';

/**
 * 基于 @ohos.net.http 的非流式 HTTP 客户端实现。
 */
export class HarmonyHttpClient implements HttpClient {
  /**
   * 发送普通 HTTP 请求,等待完整响应后返回。
   *
   * 每次请求使用独立的 HttpRequest,请求完成后 destroy。
   * 不实现自动重试。
   *
   * @param options 请求选项
   * @returns HTTP 响应
   * @throws NetworkError 当发生网络/超时/鉴权等错误时(以 reject 形式抛出)
   */
  request(options: HttpRequestOptions): Promise<HttpResponse> {
    return new Promise<HttpResponse>((resolve, reject) => {
      const host: string = extractHost(options.url);

      const httpRequest: http.HttpRequest = http.createHttp();
      const httpOptions: http.HttpRequestOptions = buildHttpOptions(options);

      httpRequest.request(options.url, httpOptions)
        .then((response: http.HttpResponse) => {
          try {
            const statusCode: number = response.responseCode;
            const headers: HttpHeaders = convertHeaders(response.header);
            const body: string = convertResponseBody(response.result);

            const result: HttpResponse = {
              statusCode: statusCode,
              headers: headers,
              body: body
            };
            resolve(result);
          } finally {
            destroyQuietly(httpRequest);
          }
        })
        .catch((err: BusinessError) => {
          destroyQuietly(httpRequest);
          const netErr: NetworkError = convertBusinessError(err);
          Logger.error(LOG_TAG, 'request failed host=' + host + ' type=' + netErr.type);
          reject(netErr);
        });
    });
  }

  /**
   * 发送流式 HTTP 请求。
   *
   * 本类不实现流式请求,明确抛出 NotSupported 错误。
   * 流式场景请使用 HttpStreamTransport。
   *
   * @param options 请求选项
   * @param callbacks 流式回调
   * @returns 中止句柄(不会返回,直接抛错)
   * @throws NetworkError 始终抛出 NotSupported
   */
  requestStream(_options: HttpRequestOptions, callbacks: StreamCallbacks): AbortHandle {
    const err: NetworkError = createNetworkError(
      NetworkErrorType.Unknown,
      'HarmonyHttpClient does not support streaming, use HttpStreamTransport instead'
    );
    callbacks.onError(err);
    // 返回一个空的 AbortHandle 以满足接口契约
    return new NoopAbortHandle();
  }
}

// ===== 辅助函数 =====

/**
 * 从 URL 提取 host(不含查询参数,不含路径)。
 * 用于日志记录,不记录完整 Base URL。
 *
 * @param url 完整 URL
 * @returns host(如 "https://api.example.com"),解析失败返回 '[unknown]'
 */
export function extractHost(url: string): string {
  if (url.length === 0) {
    return '[empty]';
  }
  // 查找协议分隔符
  const protocolEnd: number = url.indexOf('://');
  if (protocolEnd < 0) {
    return '[unknown]';
  }
  // 查找 host 后的路径起点
  const pathStart: number = url.indexOf('/', protocolEnd + 3);
  if (pathStart < 0) {
    // 无路径,整个 URL 即为 host(去除可能的查询参数)
    const queryStart: number = url.indexOf('?', protocolEnd + 3);
    if (queryStart < 0) {
      return url;
    }
    return url.substring(0, queryStart);
  }
  return url.substring(0, pathStart);
}

/**
 * 构建 @ohos.net.http 的 HttpRequestOptions。
 *
 * @param options 统一请求选项
 * @returns HarmonyOS HTTP 请求选项
 */
export function buildHttpOptions(options: HttpRequestOptions): http.HttpRequestOptions {
  const methodVal: http.RequestMethod = convertMethod(options.method);
  const headerObj: Record<string, string> = convertHeadersToObject(options.headers);

  const opts: http.HttpRequestOptions = {
    method: methodVal,
    header: headerObj,
    connectTimeout: options.connectTimeoutMs,
    readTimeout: options.readTimeoutMs,
    expectDataType: http.HttpDataType.STRING
  };

  if (options.body !== undefined && options.body.length > 0) {
    opts.extraData = options.body;
  }

  return opts;
}

/**
 * 将 HttpMethod 转换为 @ohos.net.http 的 RequestMethod。
 * @param method HTTP 方法枚举
 * @returns HarmonyOS HTTP RequestMethod
 */
function convertMethod(method: HttpMethod): http.RequestMethod {
  switch (method) {
    case HttpMethod.GET:
      return http.RequestMethod.GET;
    case HttpMethod.POST:
      return http.RequestMethod.POST;
    case HttpMethod.PUT:
      return http.RequestMethod.PUT;
    case HttpMethod.DELETE:
      return http.RequestMethod.DELETE;
    default:
      // HttpMethod.PATCH 及其他未支持的方法回退为 GET
      // 当前 Provider 仅使用 POST
      return http.RequestMethod.GET;
  }
}

/**
 * 将 Map<string, string> 头转为 Record<string, string>。
 * ArkTS 不支持动态索引,使用显式构建。
 * @param headers 请求头 Map(可选)
 * @returns Record<string, string>
 */
function convertHeadersToObject(headers?: HttpHeaders): Record<string, string> {
  const result: Record<string, string> = {};
  if (headers !== undefined) {
    headers.forEach((value: string, key: string) => {
      result[key] = value;
    });
  }
  return result;
}

/**
 * 将 @ohos.net.http 的响应头对象转为 Map。
 * @param header 响应头对象
 * @returns Map<string, string>
 */
function convertHeaders(header: Object): HttpHeaders {
  const result: HttpHeaders = new Map<string, string>();
  if (header === null || header === undefined) {
    return result;
  }
  const record: Record<string, Object> = header as Record<string, Object>;
  const keys: string[] = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    const v: Object | undefined = record[k];
    if (v !== undefined && v !== null) {
      result.set(k, v.toString());
    }
  }
  return result;
}

/**
 * 将响应体转换为 UTF-8 字符串。
 * 处理 string/Object/ArrayBuffer 三种响应类型(@ohos.net.http 的 result 字段可能返回这三种)。
 *
 * @param result 原始响应体
 * @returns UTF-8 字符串
 */
function convertResponseBody(result: string | Object | ArrayBuffer): string {
  if (typeof result === 'string') {
    return result;
  }
  if (result instanceof ArrayBuffer) {
    // 使用 TextDecoder.decodeToString 将 ArrayBuffer 转为 UTF-8 字符串
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(result));
  }
  // Object 类型(已设置 expectDataType=STRING 时通常不会走到这里,兜底处理)
  if (typeof result === 'object' && result !== null) {
    return JSON.stringify(result);
  }
  // 兜底:转字符串
  return String(result);
}

/**
 * 安全销毁 HttpRequest,不抛异常。
 * @param httpRequest HTTP 请求对象
 */
function destroyQuietly(httpRequest: http.HttpRequest): void {
  try {
    httpRequest.destroy();
  } catch (e) {
    // 忽略销毁异常
  }
}

/**
 * 将 BusinessError 转为 NetworkError。
 *
 * 映射规则:
 * - 2300000 系列网络错误 → Network
 * - 2300025/2300026 超时 → Timeout
 * - 2300006 连接被拒绝 → Network
 * - 2300023 请求取消 → Cancelled
 * - 其他 → Unknown
 *
 * @param err 平台 BusinessError
 * @returns 网络错误对象
 */
export function convertBusinessError(err: BusinessError): NetworkError {
  const code: number = err.code;
  // 空消息或 undefined 时使用默认值
  const rawMsg: string = err.message !== undefined ? err.message : '';
  const msg: string = rawMsg.length > 0 ? rawMsg : 'Unknown error';

  // 2300000 系列是网络错误
  if (code === 2300000) {
    return createNetworkError(NetworkErrorType.Network, msg, { causeMessage: msg });
  }
  // 2300025/2300026 等超时
  if (code === 2300025 || code === 2300026) {
    return createNetworkError(NetworkErrorType.Timeout, msg, { causeMessage: msg });
  }
  // 2300006 连接被拒绝
  if (code === 2300006) {
    return createNetworkError(NetworkErrorType.Network, msg, { causeMessage: msg });
  }
  // 2300023 请求取消(abort)
  if (code === 2300023) {
    return createNetworkError(NetworkErrorType.Cancelled, msg);
  }
  // 其他未知错误
  return createNetworkError(NetworkErrorType.Unknown, msg, { causeMessage: msg });
}

/**
 * 空操作的中止句柄。
 * 用于 requestStream 抛错时满足接口契约。
 */
class NoopAbortHandle implements AbortHandle {
  abort(): void {
    // no-op
  }
  isAborted(): boolean {
    return false;
  }
}
