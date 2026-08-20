/**
 * SecureStorageError 安全存储错误模型
 *
 * 定义安全存储层(KeyStore)统一的错误类型与错误对象。
 * 与 NetworkError 完全隔离,不混用。
 *
 * 安全要求:
 * - 错误对象不得保存 secret
 * - 不保存 AssetMap
 * - 不保存查询结果对象
 * - causeMessage 必须经脱敏后存储
 * - platformCode 可记录(仅数字,非敏感)
 */

// Bearer token 脱敏正则
const BEARER_PATTERN: RegExp = /Bearer\s+[A-Za-z0-9._-]+/g;
// sk- 开头的 API Key 脱敏正则
const SK_TOKEN_PATTERN: RegExp = /sk-[A-Za-z0-9._-]{8,}/g;
const REDACTED: string = '[REDACTED]';

/**
 * 安全存储错误类型枚举。
 */
export enum SecureStorageErrorType {
  /** alias 非法(空、含非法字符、过长) */
  InvalidAlias = 'InvalidAlias',
  /** secret 非法(空) */
  InvalidSecret = 'InvalidSecret',
  /** secret 超过最大允许字节数 */
  SecretTooLarge = 'SecretTooLarge',
  /** 指定 alias 的资产不存在 */
  NotFound = 'NotFound',
  /** 指定 alias 的资产已存在(冲突) */
  AlreadyExists = 'AlreadyExists',
  /** 访问被拒绝(权限不足) */
  AccessDenied = 'AccessDenied',
  /** 设备锁屏状态不匹配 */
  DeviceLocked = 'DeviceLocked',
  /** 存储服务不可用 */
  StorageUnavailable = 'StorageUnavailable',
  /** UTF-8 编解码失败 */
  EncodingFailed = 'EncodingFailed',
  /** 平台底层错误(数据损坏、数据库错误、IPC 失败等) */
  PlatformError = 'PlatformError',
  /** 未知错误 */
  Unknown = 'Unknown'
}

/**
 * 安全存储错误对象。
 * 继承自 Error,满足 ArkTS 严格模式的 arkts-limited-throw 规则(仅允许 throw Error 子类)。
 * 不包含 secret、AssetMap 或查询结果对象。
 */
export class SecureStorageError extends Error {
  /** 错误类型 */
  readonly type: SecureStorageErrorType;
  /** 是否可重试 */
  readonly retryable: boolean;
  /** 平台错误码(可选,仅数字) */
  readonly platformCode?: number;
  /** 原因消息(可选,已脱敏) */
  readonly causeMessage?: string;

  constructor(
    type: SecureStorageErrorType,
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
    this.name = 'SecureStorageError';
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
function defaultRetryable(type: SecureStorageErrorType): boolean {
  switch (type) {
    case SecureStorageErrorType.StorageUnavailable:
    case SecureStorageErrorType.DeviceLocked:
      return true;
    case SecureStorageErrorType.InvalidAlias:
    case SecureStorageErrorType.InvalidSecret:
    case SecureStorageErrorType.SecretTooLarge:
    case SecureStorageErrorType.NotFound:
    case SecureStorageErrorType.AlreadyExists:
    case SecureStorageErrorType.AccessDenied:
    case SecureStorageErrorType.EncodingFailed:
    case SecureStorageErrorType.PlatformError:
    case SecureStorageErrorType.Unknown:
      return false;
    default:
      return false;
  }
}

/**
 * 从 Asset Store 平台错误码映射为安全存储错误类型。
 * 映射规则(基于 @ohos.security.asset ErrorCode):
 * - 201 (PERMISSION_DENIED) → AccessDenied
 * - 401 (INVALID_ARGUMENT) → PlatformError(参数错误由上层已校验,走到这里是平台拒绝)
 * - 24000001 (SERVICE_UNAVAILABLE) → StorageUnavailable
 * - 24000002 (NOT_FOUND) → NotFound
 * - 24000003 (DUPLICATED) → AlreadyExists
 * - 24000004 (ACCESS_DENIED) → AccessDenied
 * - 24000005 (STATUS_MISMATCH / 屏幕锁状态) → DeviceLocked
 * - 24000006 (OUT_OF_MEMORY) → StorageUnavailable
 * - 24000007 (DATA_CORRUPTED) → PlatformError
 * - 24000008 (DATABASE_ERROR) → PlatformError
 * - 24000009 (CRYPTO_ERROR) → PlatformError
 * - 24000010 (IPC_ERROR) → StorageUnavailable
 * - 24000011 (BMS_ERROR) → StorageUnavailable
 * - 24000012 (ACCOUNT_ERROR) → StorageUnavailable
 * - 24000013 (ACCESS_TOKEN_ERROR) → StorageUnavailable
 * - 24000014 (FILE_OPERATION_ERROR) → PlatformError
 * - 24000015 (GET_SYSTEM_TIME_ERROR) → PlatformError
 * - 24000016 (LIMIT_EXCEEDED) → SecretTooLarge
 * - 24000017 (UNSUPPORTED) → PlatformError
 * - 其他 → Unknown
 *
 * @param platformCode 平台错误码
 * @returns 对应的错误类型
 */
export function errorTypeFromPlatformCode(platformCode: number): SecureStorageErrorType {
  if (platformCode === 201 || platformCode === 24000004) {
    return SecureStorageErrorType.AccessDenied;
  }
  if (platformCode === 24000001 || platformCode === 24000006 ||
    platformCode === 24000010 || platformCode === 24000011 ||
    platformCode === 24000012 || platformCode === 24000013) {
    return SecureStorageErrorType.StorageUnavailable;
  }
  if (platformCode === 24000002) {
    return SecureStorageErrorType.NotFound;
  }
  if (platformCode === 24000003) {
    return SecureStorageErrorType.AlreadyExists;
  }
  if (platformCode === 24000005) {
    return SecureStorageErrorType.DeviceLocked;
  }
  if (platformCode === 24000016) {
    return SecureStorageErrorType.SecretTooLarge;
  }
  if (platformCode === 24000007 || platformCode === 24000008 ||
    platformCode === 24000009 || platformCode === 24000014 ||
    platformCode === 24000015 || platformCode === 24000017 ||
    platformCode === 401) {
    return SecureStorageErrorType.PlatformError;
  }
  return SecureStorageErrorType.Unknown;
}

/**
 * 创建安全存储错误对象。
 * causeMessage 如果提供,会自动脱敏后存储。
 *
 * @param type 错误类型
 * @param message 错误消息(不含敏感信息)
 * @param platformCode 平台错误码(可选)
 * @param causeMessage 原始原因消息(可选,会自动脱敏)
 * @returns 安全存储错误对象
 */
export function createSecureStorageError(
  type: SecureStorageErrorType,
  message: string,
  platformCode?: number,
  causeMessage?: string
): SecureStorageError {
  const retryable: boolean = defaultRetryable(type);
  const redactedCause: string | undefined = causeMessage !== undefined
    ? redactCause(causeMessage)
    : undefined;
  return new SecureStorageError(type, message, retryable, platformCode, redactedCause);
}

/**
 * 从平台 BusinessError 创建安全存储错误。
 * 自动根据 code 映射错误类型,并脱敏 message。
 *
 * @param platformCode 平台错误码
 * @param platformMessage 平台错误消息(会脱敏)
 * @param fallbackType 兜底错误类型(当 code 无法映射时)
 * @returns 安全存储错误对象
 */
export function fromPlatformError(
  platformCode: number,
  platformMessage: string,
  fallbackType: SecureStorageErrorType
): SecureStorageError {
  const mappedType: SecureStorageErrorType = errorTypeFromPlatformCode(platformCode);
  const finalType: SecureStorageErrorType = mappedType === SecureStorageErrorType.Unknown
    ? fallbackType
    : mappedType;
  return createSecureStorageError(
    finalType,
    SecureStorageErrorTypeMessage(finalType),
    platformCode,
    platformMessage
  );
}

/**
 * 根据错误类型返回默认人类可读消息。
 * @param type 错误类型
 * @returns 默认消息
 */
export function SecureStorageErrorTypeMessage(type: SecureStorageErrorType): string {
  switch (type) {
    case SecureStorageErrorType.InvalidAlias:
      return 'Invalid alias';
    case SecureStorageErrorType.InvalidSecret:
      return 'Invalid secret';
    case SecureStorageErrorType.SecretTooLarge:
      return 'Secret exceeds maximum allowed size';
    case SecureStorageErrorType.NotFound:
      return 'Asset not found';
    case SecureStorageErrorType.AlreadyExists:
      return 'Asset already exists';
    case SecureStorageErrorType.AccessDenied:
      return 'Access denied';
    case SecureStorageErrorType.DeviceLocked:
      return 'Device is locked';
    case SecureStorageErrorType.StorageUnavailable:
      return 'Secure storage service unavailable';
    case SecureStorageErrorType.EncodingFailed:
      return 'UTF-8 encoding or decoding failed';
    case SecureStorageErrorType.PlatformError:
      return 'Platform secure storage error';
    case SecureStorageErrorType.Unknown:
      return 'Unknown secure storage error';
    default:
      return 'Unknown secure storage error';
  }
}
