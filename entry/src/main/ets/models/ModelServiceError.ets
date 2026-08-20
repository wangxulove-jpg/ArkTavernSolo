/**
 * ModelServiceError ModelService 业务编排错误模型
 *
 * 定义 ModelService 层统一的错误类型与错误对象。
 * 用于 ProviderConfigStore / ProviderKeyStore / AiProvider 之间的协调失败场景。
 *
 * 安全要求:
 * - 错误对象不得保存 API Key、Authorization、secret
 * - causeMessage 必须经脱敏后存储(复用通用脱敏正则)
 * - 不保存完整配置 JSON
 * - 不保存请求/响应正文
 *
 * 与 NetworkError / PreferencesError / SecureStorageError 的关系:
 * - ModelService 是上层编排者,需要区分底层错误来源
 * - 底层错误通过 causeMessage 保留脱敏后的原始消息
 * - 业务语义错误(如 ConfigNotFound / ApiKeyMissing)由 ModelService 显式抛出
 * - 继承自 Error 以满足 ArkTS 严格模式的 arkts-limited-throw 规则
 */

// Bearer token 脱敏正则
const BEARER_PATTERN: RegExp = /Bearer\s+[A-Za-z0-9._-]+/g;
// sk- 开头的 API Key 脱敏正则
const SK_TOKEN_PATTERN: RegExp = /sk-[A-Za-z0-9._-]{8,}/g;
const REDACTED: string = '[REDACTED]';

/**
 * ModelService 错误类型枚举。
 */
export enum ModelServiceErrorType {
  /** ModelService 未初始化(未调用 initialize) */
  NotInitialized = 'NotInitialized',
  /** 指定 id 的配置不存在 */
  ConfigNotFound = 'ConfigNotFound',
  /** 当前未选中任何 Provider 配置 */
  NoCurrentConfig = 'NoCurrentConfig',
  /** 当前配置已禁用(enabled=false) */
  ConfigDisabled = 'ConfigDisabled',
  /** API Key 未配置 */
  ApiKeyMissing = 'ApiKeyMissing',
  /** 不支持的 Provider 类型(如 Claude / Gemini) */
  UnsupportedProvider = 'UnsupportedProvider',
  /** 配置 id 已存在(createConfig 重复) */
  ConfigAlreadyExists = 'ConfigAlreadyExists',
  /** 存储层失败(Preferences 或 Asset Store) */
  StorageFailure = 'StorageFailure',
  /** 网络层失败(Provider 请求失败) */
  NetworkFailure = 'NetworkFailure',
  /** 部分失败(如配置保存成功但密钥保存失败,已回滚但仍可能残留) */
  PartialFailure = 'PartialFailure',
  /** 配置无效(如 model name 为空) */
  InvalidConfig = 'InvalidConfig',
  /** 未知错误 */
  Unknown = 'Unknown'
}

/**
 * ModelService 错误对象。
 * 继承自 Error,满足 ArkTS 的 arkts-limited-throw 规则。
 * 不包含 API Key、Authorization、完整配置 JSON 或请求/响应正文。
 */
export class ModelServiceError extends Error {
  /** 错误类型 */
  readonly type: ModelServiceErrorType;
  /** 是否可重试 */
  readonly retryable: boolean;
  /** 原因消息(可选,已脱敏) */
  readonly causeMessage?: string;

  constructor(
    type: ModelServiceErrorType,
    message: string,
    retryable: boolean,
    causeMessage?: string
  ) {
    super(message);
    this.type = type;
    this.retryable = retryable;
    this.causeMessage = causeMessage;
    this.name = 'ModelServiceError';
  }
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
function defaultRetryable(type: ModelServiceErrorType): boolean {
  switch (type) {
    case ModelServiceErrorType.StorageFailure:
    case ModelServiceErrorType.NetworkFailure:
      return true;
    case ModelServiceErrorType.NotInitialized:
    case ModelServiceErrorType.ConfigNotFound:
    case ModelServiceErrorType.NoCurrentConfig:
    case ModelServiceErrorType.ConfigDisabled:
    case ModelServiceErrorType.ApiKeyMissing:
    case ModelServiceErrorType.UnsupportedProvider:
    case ModelServiceErrorType.ConfigAlreadyExists:
    case ModelServiceErrorType.PartialFailure:
    case ModelServiceErrorType.InvalidConfig:
    case ModelServiceErrorType.Unknown:
      return false;
    default:
      return false;
  }
}

/**
 * 创建 ModelService 错误对象。
 * causeMessage 如果提供,会自动脱敏后存储。
 *
 * @param type 错误类型
 * @param message 错误消息(不含敏感信息)
 * @param causeMessage 原始原因消息(可选,会自动脱敏)
 * @returns ModelService 错误对象
 */
export function createModelServiceError(
  type: ModelServiceErrorType,
  message: string,
  causeMessage?: string
): ModelServiceError {
  const retryable: boolean = defaultRetryable(type);
  const redactedCause: string | undefined = causeMessage !== undefined
    ? redactCause(causeMessage)
    : undefined;
  return new ModelServiceError(type, message, retryable, redactedCause);
}

/**
 * 类型守卫:判断未知对象是否为 ModelServiceError。
 * @param obj 未知对象
 * @returns 是 ModelServiceError 返回 true
 */
export function isModelServiceError(obj: Object): boolean {
  return obj instanceof ModelServiceError;
}
