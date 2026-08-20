/**
 * PreferencesError 非敏感配置存储错误模型
 *
 * 定义 Preferences 层(用户首选项)统一的错误类型与错误对象。
 * 与 NetworkError、SecureStorageError 完全隔离,不混用。
 *
 * 安全要求:
 * - 错误对象不得保存完整配置 JSON
 * - 不保存 API Key、Authorization、secret
 * - causeMessage 必须经脱敏后存储
 * - platformCode 可记录(仅数字,非敏感)
 *
 * 与 SecureStorageError 的区别:
 * - SecureStorageError 用于敏感数据(Asset Store),错误对象中绝对不含明文
 * - PreferencesError 用于非敏感数据,但同样不保存完整配置 JSON 以降低泄露面
 * - 不存在(NotFound)与损坏(CorruptedData)必须区分
 * - 单个损坏配置可跳过并报告(skippedCount),整个 JSON 无法解析返回 CorruptedData
 */

// Bearer token 脱敏正则
const BEARER_PATTERN: RegExp = /Bearer\s+[A-Za-z0-9._-]+/g;
// sk- 开头的 API Key 脱敏正则
const SK_TOKEN_PATTERN: RegExp = /sk-[A-Za-z0-9._-]{8,}/g;
const REDACTED: string = '[REDACTED]';

/**
 * Preferences 错误类型枚举。
 */
export enum PreferencesErrorType {
  /** 未初始化(未调用 initialize) */
  NotInitialized = 'NotInitialized',
  /** Key 非法(空、过长、含非法字符) */
  InvalidKey = 'InvalidKey',
  /** Value 非法(类型不匹配、超出范围) */
  InvalidValue = 'InvalidValue',
  /** 序列化失败(对象转 JSON 失败) */
  SerializationFailed = 'SerializationFailed',
  /** 反序列化失败(JSON 解析失败,但非空字符串) */
  DeserializationFailed = 'DeserializationFailed',
  /** 不支持的 schema 版本 */
  UnsupportedVersion = 'UnsupportedVersion',
  /** 数据损坏(整个 JSON 无法解析或缺少必要结构) */
  CorruptedData = 'CorruptedData',
  /** 指定 id 的配置已存在 */
  AlreadyExists = 'AlreadyExists',
  /** 指定 id 的配置不存在 */
  NotFound = 'NotFound',
  /** 当前选中 id 非法(不存在或为空字符串) */
  InvalidSelection = 'InvalidSelection',
  /** Preferences 存储服务不可用 */
  StorageUnavailable = 'StorageUnavailable',
  /** 未知错误 */
  Unknown = 'Unknown'
}

/**
 * Preferences 错误对象。
 * 继承自 Error,满足 ArkTS 严格模式的 arkts-limited-throw 规则(仅允许 throw Error 子类)。
 * 不包含完整配置 JSON、API Key 或 Authorization。
 */
export class PreferencesError extends Error {
  /** 错误类型 */
  readonly type: PreferencesErrorType;
  /** 是否可重试 */
  readonly retryable: boolean;
  /** 平台错误码(可选,仅数字) */
  readonly platformCode?: number;
  /** 原因消息(可选,已脱敏) */
  readonly causeMessage?: string;

  constructor(
    type: PreferencesErrorType,
    message: string,
    retryable: boolean,
    platformCode?: number,
    causeMessage?: string
  ) {
    super(message);
    this.type = type;
    this.retryable = retryable;
    this.platformCode = platformCode;
    this.causeMessage = causeMessage;
    this.name = 'PreferencesError';
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
function defaultRetryable(type: PreferencesErrorType): boolean {
  switch (type) {
    case PreferencesErrorType.StorageUnavailable:
      return true;
    case PreferencesErrorType.NotInitialized:
    case PreferencesErrorType.InvalidKey:
    case PreferencesErrorType.InvalidValue:
    case PreferencesErrorType.SerializationFailed:
    case PreferencesErrorType.DeserializationFailed:
    case PreferencesErrorType.UnsupportedVersion:
    case PreferencesErrorType.CorruptedData:
    case PreferencesErrorType.AlreadyExists:
    case PreferencesErrorType.NotFound:
    case PreferencesErrorType.InvalidSelection:
    case PreferencesErrorType.Unknown:
      return false;
    default:
      return false;
  }
}

/**
 * 从 Preferences 平台错误码映射为错误类型。
 * 映射规则(基于 @ohos.data.preferences 错误码):
 * - 401 (INVALID_ARGUMENT) → InvalidKey 或 InvalidValue(由上层判断)
 * - 801 (CAPABILITY_NOT_SUPPORTED) → StorageUnavailable
 * - 15500000 (INNER_ERROR) → StorageUnavailable
 * - 15500010 (DELETE_PERSIST_FILE_FAILED) → StorageUnavailable
 * - 15501001 (STAGE_MODE_ONLY) → StorageUnavailable
 * - 15501002 (INVALID_DATA_GROUP_ID) → InvalidKey
 * - 其他 → Unknown
 *
 * @param platformCode 平台错误码
 * @returns 对应的错误类型
 */
export function errorTypeFromPlatformCode(platformCode: number): PreferencesErrorType {
  if (platformCode === 801 || platformCode === 15500000 ||
    platformCode === 15500010 || platformCode === 15501001) {
    return PreferencesErrorType.StorageUnavailable;
  }
  if (platformCode === 15501002) {
    return PreferencesErrorType.InvalidKey;
  }
  if (platformCode === 401) {
    // 参数错误由上层已校验,走到这里是平台拒绝,统一归为 StorageUnavailable
    return PreferencesErrorType.StorageUnavailable;
  }
  return PreferencesErrorType.Unknown;
}

/**
 * 创建 Preferences 错误对象。
 * causeMessage 如果提供,会自动脱敏后存储。
 *
 * @param type 错误类型
 * @param message 错误消息(不含敏感信息)
 * @param platformCode 平台错误码(可选)
 * @param causeMessage 原始原因消息(可选,会自动脱敏)
 * @returns Preferences 错误对象
 */
export function createPreferencesError(
  type: PreferencesErrorType,
  message: string,
  platformCode?: number,
  causeMessage?: string
): PreferencesError {
  const retryable: boolean = defaultRetryable(type);
  const redactedCause: string | undefined = causeMessage !== undefined
    ? redactCause(causeMessage)
    : undefined;
  return new PreferencesError(type, message, retryable, platformCode, redactedCause);
}

/**
 * 从平台 BusinessError 创建 Preferences 错误。
 * 自动根据 code 映射错误类型,并脱敏 message。
 *
 * @param platformCode 平台错误码
 * @param platformMessage 平台错误消息(会脱敏)
 * @param fallbackType 兜底错误类型(当 code 无法映射时)
 * @returns Preferences 错误对象
 */
export function fromPlatformError(
  platformCode: number,
  platformMessage: string,
  fallbackType: PreferencesErrorType
): PreferencesError {
  const mappedType: PreferencesErrorType = errorTypeFromPlatformCode(platformCode);
  const finalType: PreferencesErrorType = mappedType === PreferencesErrorType.Unknown
    ? fallbackType
    : mappedType;
  return createPreferencesError(
    finalType,
    PreferencesErrorTypeMessage(finalType),
    platformCode,
    platformMessage
  );
}

/**
 * 根据错误类型返回默认人类可读消息。
 * @param type 错误类型
 * @returns 默认消息
 */
export function PreferencesErrorTypeMessage(type: PreferencesErrorType): string {
  switch (type) {
    case PreferencesErrorType.NotInitialized:
      return 'Preferences not initialized';
    case PreferencesErrorType.InvalidKey:
      return 'Invalid preferences key';
    case PreferencesErrorType.InvalidValue:
      return 'Invalid preferences value';
    case PreferencesErrorType.SerializationFailed:
      return 'Failed to serialize provider config';
    case PreferencesErrorType.DeserializationFailed:
      return 'Failed to deserialize provider config';
    case PreferencesErrorType.UnsupportedVersion:
      return 'Unsupported schema version';
    case PreferencesErrorType.CorruptedData:
      return 'Preferences data corrupted';
    case PreferencesErrorType.AlreadyExists:
      return 'Provider config already exists';
    case PreferencesErrorType.NotFound:
      return 'Provider config not found';
    case PreferencesErrorType.InvalidSelection:
      return 'Invalid current provider selection';
    case PreferencesErrorType.StorageUnavailable:
      return 'Preferences storage unavailable';
    case PreferencesErrorType.Unknown:
      return 'Unknown preferences error';
    default:
      return 'Unknown preferences error';
  }
}

/**
 * 类型守卫:判断未知对象是否为 PreferencesError。
 * 用于 catch 块中安全类型断言。
 *
 * @param obj 未知对象
 * @returns 是 PreferencesError 返回 true
 */
export function isPreferencesError(obj: Object): boolean {
  return obj instanceof PreferencesError;
}
