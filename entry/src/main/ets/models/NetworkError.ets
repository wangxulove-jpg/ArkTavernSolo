/**
 * NetworkError 网络错误模型
 *
 * 定义网络层统一的错误类型与错误对象。
 * 提供从 HTTP 状态码到错误类型的纯函数映射。
 * 错误对象中不存储请求头、API Key 等敏感信息。
 *
 * 继承自 Error,满足 ArkTS 严格模式的 arkts-limited-throw 规则
 * (仅允许 throw Error 子类)。
 */

// Bearer token 脱敏正则
const BEARER_PATTERN: RegExp = /Bearer\s+[A-Za-z0-9._-]+/g;
// sk- 开头的 API Key 脱敏正则
const SK_TOKEN_PATTERN: RegExp = /sk-[A-Za-z0-9._-]{8,}/g;
const REDACTED: string = '[REDACTED]';

/**
 * 网络错误类型枚举。
 * Cancelled 与 Timeout 明确区分:Cancelled 是主动取消,Timeout 是等待超时。
 */
export enum NetworkErrorType {
  /** 网络连接错误(DNS 解析失败、连接拒绝等) */
  Network = 'Network',
  /** 请求超时(等待响应超时) */
  Timeout = 'Timeout',
  /** 鉴权失败(401/403 或 token 无效) */
  Authentication = 'Authentication',
  /** 限流(429) */
  RateLimit = 'RateLimit',
  /** 服务端错误(5xx) */
  Server = 'Server',
  /** 请求参数无效(400) */
  InvalidRequest = 'InvalidRequest',
  /** 响应解析失败 */
  Parse = 'Parse',
  /** 请求被主动取消(非超时) */
  Cancelled = 'Cancelled',
  /** 未知错误 */
  Unknown = 'Unknown'
}

/**
 * 网络错误对象。
 * 继承自 Error 以满足 ArkTS 的 arkts-limited-throw 规则。
 * 不包含请求头、API Key 等敏感字段。
 */
export class NetworkError extends Error {
  /** 错误类型 */
  readonly type: NetworkErrorType;
  /** HTTP 状态码(可选) */
  readonly statusCode?: number;
  /** Provider 特定错误码(可选) */
  readonly providerCode?: string;
  /** 是否可重试 */
  readonly retryable: boolean;
  /** 原因消息(可选,已脱敏) */
  readonly causeMessage?: string;

  constructor(
    type: NetworkErrorType,
    message: string,
    retryable: boolean,
    statusCode?: number,
    providerCode?: string,
    causeMessage?: string
  ) {
    super(message);
    this.type = type;
    this.retryable = retryable;
    this.statusCode = statusCode;
    this.providerCode = providerCode;
    this.causeMessage = causeMessage;
    this.name = 'NetworkError';
  }
}

/**
 * 创建网络错误的可选参数。
 */
export interface NetworkErrorOptions {
  /** HTTP 状态码 */
  statusCode?: number;
  /** Provider 特定错误码 */
  providerCode?: string;
  /** 是否可重试,未指定时按错误类型默认值 */
  retryable?: boolean;
  /** 原始原因消息(会自动脱敏后存储) */
  causeMessage?: string;
}

/**
 * 对原因消息做脱敏(内联实现,避免跨层依赖)。
 * @param cause 原始原因消息
 * @returns 脱敏后的原因消息
 */
function redactCause(cause: string): string {
  let result: string = cause.replace(BEARER_PATTERN, 'Bearer ' + REDACTED);
  result = result.replace(SK_TOKEN_PATTERN, '[sk-redacted]');
  return result;
}

/**
 * 根据错误类型返回默认是否可重试。
 * @param type 错误类型
 * @returns 默认是否可重试
 */
function defaultRetryable(type: NetworkErrorType): boolean {
  switch (type) {
    case NetworkErrorType.Network:
    case NetworkErrorType.Timeout:
    case NetworkErrorType.Server:
    case NetworkErrorType.RateLimit:
      return true;
    case NetworkErrorType.Authentication:
    case NetworkErrorType.InvalidRequest:
    case NetworkErrorType.Parse:
    case NetworkErrorType.Cancelled:
    case NetworkErrorType.Unknown:
      return false;
    default:
      return false;
  }
}

/**
 * 从 HTTP 状态码映射为错误类型。
 * 映射规则:
 * - 400 → InvalidRequest
 * - 401/403 → Authentication
 * - 408 → Timeout
 * - 429 → RateLimit
 * - 500~599 → Server
 * - 其他 → Unknown
 *
 * @param statusCode HTTP 状态码
 * @returns 对应的错误类型
 */
export function errorTypeFromStatusCode(statusCode: number): NetworkErrorType {
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
  return NetworkErrorType.Unknown;
}

/**
 * 创建网络错误对象。
 * causeMessage 如果提供,会自动脱敏后存储。
 *
 * @param type 错误类型
 * @param message 错误消息(不含敏感信息)
 * @param options 可选参数
 * @returns 网络错误对象
 */
export function createNetworkError(
  type: NetworkErrorType,
  message: string,
  options?: NetworkErrorOptions
): NetworkError {
  const retryable: boolean = options !== undefined && options.retryable !== undefined
    ? options.retryable
    : defaultRetryable(type);

  const statusCode: number | undefined = options !== undefined ? options.statusCode : undefined;
  const providerCode: string | undefined = options !== undefined ? options.providerCode : undefined;
  const causeMessage: string | undefined = options !== undefined && options.causeMessage !== undefined
    ? redactCause(options.causeMessage)
    : undefined;

  return new NetworkError(
    type,
    message,
    retryable,
    statusCode,
    providerCode,
    causeMessage
  );
}
