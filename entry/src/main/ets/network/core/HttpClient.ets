/**
 * HttpClient 网络核心抽象接口
 *
 * 定义 HTTP 请求/响应/流式的抽象接口。
 * 不与 @ohos.net.http 或 rcp 直接耦合,具体实现由后续 Provider 层提供。
 * 不内置任何 Provider 特定字段,不实现重试逻辑。
 */

import { NetworkError } from '../../models/NetworkError';

/**
 * HTTP 方法枚举。
 */
export enum HttpMethod {
  GET = 'GET',
  POST = 'POST',
  PUT = 'PUT',
  PATCH = 'PATCH',
  DELETE = 'DELETE'
}

/**
 * HTTP 请求头类型。
 * 使用 Map 避免动态索引写法,确保 ArkTS 严格模式兼容。
 * 头名建议使用小写,查找时大小写不敏感由实现层处理。
 */
export type HttpHeaders = Map<string, string>;

/**
 * HTTP 请求选项。
 */
export interface HttpRequestOptions {
  /** HTTP 方法 */
  readonly method: HttpMethod;
  /** 请求 URL(完整地址) */
  readonly url: string;
  /** 请求头(可选) */
  readonly headers?: HttpHeaders;
  /** 字符串请求体(可选,GET/DELETE 通常无) */
  readonly body?: string;
  /** 连接超时(毫秒,可选) */
  readonly connectTimeoutMs?: number;
  /** 读取超时(毫秒,可选) */
  readonly readTimeoutMs?: number;
}

/**
 * HTTP 响应。
 */
export interface HttpResponse {
  /** HTTP 状态码 */
  readonly statusCode: number;
  /** 响应头 */
  readonly headers: HttpHeaders;
  /** 响应体字符串 */
  readonly body: string;
}

/**
 * 流式请求回调。
 * 用于 SSE 等增量响应场景。
 */
export interface StreamCallbacks {
  /**
   * 收到数据块时调用。
   * @param chunk 增量数据块(字符串)
   */
  onData: (chunk: string) => void;
  /**
   * 流式响应完成时调用。
   * @param response 完整响应(含最终状态码与头,body 为聚合后内容或空)
   */
  onComplete: (response: HttpResponse) => void;
  /**
   * 发生错误时调用。
   * @param error 网络错误对象
   */
  onError: (error: NetworkError) => void;
}

/**
 * 请求中止句柄。
 * 用于主动取消进行中的请求(含流式请求)。
 */
export interface AbortHandle {
  /**
   * 中止请求。
   * 中止后应通过 StreamCallbacks.onError 回调 NetworkErrorType.Cancelled 错误。
   */
  abort(): void;
  /**
   * 查询请求是否已中止。
   * @returns 已中止返回 true
   */
  isAborted(): boolean;
}

/**
 * HTTP 客户端抽象接口。
 * 具体实现由后续任务基于 @ohos.net.http 或 rcp 完成。
 * 本接口不包含重试逻辑,重试由上层 RetryPolicy 处理。
 */
export interface HttpClient {
  /**
   * 发送普通 HTTP 请求,等待完整响应后返回。
   *
   * @param options 请求选项
   * @returns HTTP 响应
   * @throws NetworkError 当发生网络/超时/鉴权等错误时(具体实现以 reject 形式抛出)
   */
  request(options: HttpRequestOptions): Promise<HttpResponse>;

  /**
   * 发送流式 HTTP 请求,通过回调增量返回数据。
   * 适用于 SSE 流式输出场景。
   *
   * @param options 请求选项
   * @param callbacks 流式回调
   * @returns 中止句柄,可用于取消请求
   */
  requestStream(options: HttpRequestOptions, callbacks: StreamCallbacks): AbortHandle;
}
