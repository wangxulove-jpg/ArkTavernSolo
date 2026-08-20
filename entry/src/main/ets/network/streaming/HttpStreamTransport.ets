/**
 * HttpStreamTransport 基于 @ohos.net.http 的流式 HTTP 传输层
 *
 * 使用 @ohos.net.http 的 requestInStream + on('dataReceive') 实现增量接收。
 * 通过 Utf8StreamDecoder 将 ArrayBuffer 字节增量解码为字符串。
 * 通过状态机实现幂等 abort 和单次 complete/error 通知。
 *
 * 依赖:
 * - @kit.NetworkKit 的 @ohos.net.http(requestInStream / dataReceive / dataEnd / destroy)
 * - Utf8StreamDecoder(纯逻辑 UTF-8 增量解码)
 * - StreamTransportTypes(状态机)
 * - NetworkError(错误模型)
 *
 * 不包含 OpenAI/Claude 等 Provider 业务逻辑。
 * 不在日志中输出请求头、Authorization 或请求正文。
 */

import http from '@ohos.net.http';
import { NetworkError, NetworkErrorType, createNetworkError } from '../../models/NetworkError';
import { Utf8StreamDecoder } from './Utf8StreamDecoder';
import { TransportState, TransportCallbacks, isTerminalState, canTransitionTo } from './StreamTransportTypes';

/**
 * 流式 HTTP 传输选项。
 */
export interface TransportRequestOptions {
  /** 请求 URL */
  readonly url: string;
  /** HTTP 方法('GET'/'POST'/'PUT'/'PATCH'/'DELETE') */
  readonly method: string;
  /** 请求头(可选) */
  readonly headers?: Map<string, string>;
  /** 请求体字符串(可选) */
  readonly body?: string;
  /** 连接超时(毫秒,可选) */
  readonly connectTimeoutMs?: number;
  /** 读取超时(毫秒,可选) */
  readonly readTimeoutMs?: number;
}

/**
 * 中止句柄实现。
 * 内部持有对传输对象的引用,调用 abort 时触发传输层取消。
 */
export interface TransportAbortHandle {
  /** 中止请求(幂等) */
  abort(): void;
  /** 查询是否已中止 */
  isAborted(): boolean;
}

/**
 * 基于 @ohos.net.http 的流式 HTTP 传输层。
 * 每个请求使用独立的 HttpRequest 对象,不复用。
 */
export class HttpStreamTransport {
  /**
   * 发起流式 HTTP 请求。
   *
   * @param options 请求选项
   * @param callbacks 流式回调
   * @returns 中止句柄
   */
  requestStream(options: TransportRequestOptions, callbacks: TransportCallbacks): TransportAbortHandle {
    const ctx: RequestContext = new RequestContext(options, callbacks);
    ctx.start();
    return ctx;
  }
}

/**
 * 单个请求的上下文。
 * 封装状态机、解码器、HttpRequest 生命周期。
 * 实现 TransportAbortHandle 接口,支持直接作为中止句柄返回。
 */
class RequestContext implements TransportAbortHandle {
  private readonly options: TransportRequestOptions;
  private readonly callbacks: TransportCallbacks;
  private readonly decoder: Utf8StreamDecoder = new Utf8StreamDecoder();
  private state: TransportState = TransportState.IDLE;
  private httpRequest: http.HttpRequest | null = null;
  private statusCode: number = 0;
  private aborted: boolean = false;
  /** headersReceive 先于 Promise resolve 时缓存的响应头 */
  private pendingHeaders: Map<string, string> | null = null;
  /** 标记 headersReceive 已触发(无论 statusCode 是否已知) */
  private headersReceived: boolean = false;
  /** dataEnd 先于 Promise resolve 时缓存的完成信号 */
  private dataEndPending: boolean = false;

  constructor(options: TransportRequestOptions, callbacks: TransportCallbacks) {
    this.options = options;
    this.callbacks = callbacks;
  }

  /**
   * 发起请求。
   * 注册回调后调用 requestInStream。
   */
  start(): void {
    try {
      this.httpRequest = http.createHttp();
      this.registerCallbacks();
      const httpOptions: http.HttpRequestOptions = this.buildHttpOptions();
      this.transitionTo(TransportState.RECEIVING);
      // requestInStream 返回 Promise<number>(状态码)
      this.httpRequest.requestInStream(this.options.url, httpOptions)
        .then((code: number) => {
          this.statusCode = code;
          // 如果 headersReceive 已触发但当时 statusCode 未知(=0),现在补发 onHeaders
          if (this.headersReceived && this.pendingHeaders !== null) {
            const cached: Map<string, string> = this.pendingHeaders;
            this.pendingHeaders = null;
            this.invokeOnHeaders(cached);
          }
          // 如果 dataEnd 已触发但当时 statusCode 未知(=0),现在补发完成
          if (this.dataEndPending) {
            this.dataEndPending = false;
            this.handleDataEnd();
          }
        })
        .catch((err: BusinessError) => {
          this.handleError(err);
        });
    } catch (e) {
      this.handleError(e as BusinessError);
    }
  }

  /**
   * 中止请求(幂等)。
   * 多次调用不会崩溃,终态后调用无效。
   */
  abort(): void {
    if (this.aborted) {
      return;
    }
    this.aborted = true;
    if (isTerminalState(this.state)) {
      return;
    }
    this.transitionTo(TransportState.ABORTED);
    this.cleanup();
    const err: NetworkError = createNetworkError(
      NetworkErrorType.Cancelled,
      'Request aborted by user'
    );
    this.callbacks.onError(err);
  }

  /**
   * 查询是否已中止。
   */
  isAborted(): boolean {
    return this.aborted;
  }

  /**
   * 注册 @ohos.net.http 的事件回调。
   */
  private registerCallbacks(): void {
    if (this.httpRequest === null) {
      return;
    }
    const req: http.HttpRequest = this.httpRequest;

    req.on('headersReceive', (header: Object) => {
      this.handleHeaders(header);
    });

    req.on('dataReceive', (data: ArrayBuffer) => {
      this.handleDataReceive(data);
    });

    req.on('dataEnd', () => {
      this.handleDataEnd();
    });
  }

  /**
   * 处理响应头。
   * headersReceive 事件可能在 requestInStream Promise resolve 之前触发,
   * 此时 statusCode 仍为 0。缓存 headers,等 Promise resolve 后补发 onHeaders。
   */
  private handleHeaders(header: Object): void {
    if (isTerminalState(this.state)) {
      return;
    }
    const headers: Map<string, string> = convertHeaders(header);
    this.headersReceived = true;

    if (this.statusCode === 0) {
      // Promise 还未 resolve,缓存 headers,等 statusCode 已知后再触发
      this.pendingHeaders = headers;
      return;
    }

    this.invokeOnHeaders(headers);
  }

  /**
   * 触发 onHeaders 回调(使用当前已知 statusCode)。
   */
  private invokeOnHeaders(headers: Map<string, string>): void {
    if (isTerminalState(this.state)) {
      return;
    }
    if (this.callbacks.onHeaders !== undefined) {
      this.callbacks.onHeaders(this.statusCode, headers);
    }
  }

  /**
   * 处理数据块。
   * 如果 statusCode 未知(Promise 还未 resolve),仍传递给 onData。
   * OpenAIStreamSession 会在 handleHeaders 中检查状态码并处理错误。
   */
  private handleDataReceive(data: ArrayBuffer): void {
    if (isTerminalState(this.state)) {
      return;
    }
    const bytes: Uint8Array = new Uint8Array(data);
    const byteLength: number = bytes.length;
    const chunk: string = this.decoder.feed(bytes);
    if (chunk.length > 0) {
      this.callbacks.onData(chunk, byteLength);
    }
  }

  /**
   * 处理数据结束。
   * 如果 Promise 还未 resolve(statusCode=0),缓存信号等 Promise resolve 后补发。
   */
  private handleDataEnd(): void {
    if (isTerminalState(this.state)) {
      return;
    }
    // 如果 statusCode 未知(Promise 还未 resolve),缓存 dataEnd 信号
    if (this.statusCode === 0) {
      this.dataEndPending = true;
      return;
    }
    // flush 解码器剩余字节
    const remaining: string = this.decoder.flush();
    if (remaining.length > 0) {
      this.callbacks.onData(remaining, 0);
    }
    this.transitionTo(TransportState.COMPLETED);
    this.callbacks.onComplete(this.statusCode);
    this.cleanup();
  }

  /**
   * 处理错误。
   */
  private handleError(err: BusinessError): void {
    if (isTerminalState(this.state)) {
      return;
    }
    const netErr: NetworkError = convertBusinessError(err);
    this.transitionTo(TransportState.ERRORED);
    this.callbacks.onError(netErr);
    this.cleanup();
  }

  /**
   * 状态转换(带校验)。
   */
  private transitionTo(to: TransportState): void {
    if (canTransitionTo(this.state, to)) {
      this.state = to;
    }
  }

  /**
   * 清理资源:移除事件监听,销毁 HttpRequest。
   */
  private cleanup(): void {
    if (this.httpRequest === null) {
      return;
    }
    const req: http.HttpRequest = this.httpRequest;
    try {
      req.off('headersReceive');
      req.off('dataReceive');
      req.off('dataEnd');
      req.destroy();
    } catch (e) {
      // 忽略清理异常
    }
    this.httpRequest = null;
  }

  /**
   * 构建 @ohos.net.http 的 HttpRequestOptions。
   */
  private buildHttpOptions(): http.HttpRequestOptions {
    const methodStr: string = this.options.method.toUpperCase();
    let methodVal: http.RequestMethod;
    switch (methodStr) {
      case 'GET':
        methodVal = http.RequestMethod.GET;
        break;
      case 'POST':
        methodVal = http.RequestMethod.POST;
        break;
      case 'PUT':
        methodVal = http.RequestMethod.PUT;
        break;
      case 'DELETE':
        methodVal = http.RequestMethod.DELETE;
        break;
      default:
        methodVal = http.RequestMethod.GET;
        break;
    }

    const opts: http.HttpRequestOptions = {
      method: methodVal,
      header: this.buildHeadersObject(),
      connectTimeout: this.options.connectTimeoutMs,
      readTimeout: this.options.readTimeoutMs
    };

    if (this.options.body !== undefined && this.options.body.length > 0) {
      opts.extraData = this.options.body;
    }

    return opts;
  }

  /**
   * 将 Map<string,string> 头转为 Record<string,string>。
   * ArkTS 不支持动态索引,使用显式构建。
   */
  private buildHeadersObject(): Record<string, string> {
    const result: Record<string, string> = {};
    if (this.options.headers !== undefined) {
      this.options.headers.forEach((value: string, key: string) => {
        result[key] = value;
      });
    }
    return result;
  }
}

/**
 * 将 @ohos.net.http 的 header 对象转为 Map。
 * header 可能是 Record<string,string> 或其他结构。
 */
function convertHeaders(header: Object): Map<string, string> {
  const result: Map<string, string> = new Map<string, string>();
  const record: Record<string, string> = header as Record<string, string>;
  const keys: string[] = Object.keys(record);
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    result.set(k, record[k]);
  }
  return result;
}

/**
 * 将 BusinessError 转为 NetworkError。
 */
function convertBusinessError(err: BusinessError): NetworkError {
  const code: number = err.code;
  const msg: string = err.message !== undefined ? err.message : 'Unknown error';

  // 2300000 系列是网络错误
  if (code === 2300000) {
    return createNetworkError(NetworkErrorType.Network, msg);
  }
  // 2300025/2300026 等超时
  if (code === 2300025 || code === 2300026) {
    return createNetworkError(NetworkErrorType.Timeout, msg);
  }
  // 2300006 连接被拒绝
  if (code === 2300006) {
    return createNetworkError(NetworkErrorType.Network, msg);
  }
  // 其他未知错误
  return createNetworkError(NetworkErrorType.Unknown, msg, { causeMessage: msg });
}
