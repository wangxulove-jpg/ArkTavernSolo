/**
 * Logger 日志工具模块
 *
 * 基于 HarmonyOS hilog 提供分级日志能力。
 * 内置敏感信息脱敏,确保 API Key、Bearer Token 等不会出现在日志中。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'ArkTavern';
const REDACTED: string = '[REDACTED]';

// 敏感字段名(小写,用于大小写不敏感匹配)
const SENSITIVE_KEYS: string[] = [
  'apikey',
  'api_key',
  'authorization',
  'accesstoken',
  'refreshtoken',
  'secret',
  'password'
];

// Bearer token 正则
const BEARER_PATTERN: RegExp = /Bearer\s+[A-Za-z0-9._-]+/g;
// sk- 开头的 API Key 正则
const SK_TOKEN_PATTERN: RegExp = /sk-[A-Za-z0-9._-]{8,}/g;

/**
 * 判断字段名是否敏感(大小写不敏感)。
 * @param key 字段名
 * @returns 敏感返回 true
 */
export function isSensitiveKey(key: string): boolean {
  const lower: string = key.toLowerCase();
  for (let i = 0; i < SENSITIVE_KEYS.length; i++) {
    if (lower === SENSITIVE_KEYS[i]) {
      return true;
    }
  }
  return false;
}

/**
 * 脱敏 Bearer token。
 * @param s 原始字符串
 * @returns 脱敏后的字符串
 */
function redactBearer(s: string): string {
  return s.replace(BEARER_PATTERN, 'Bearer ' + REDACTED);
}

/**
 * 脱敏 sk- 开头的 API Key。
 * @param s 原始字符串
 * @returns 脱敏后的字符串
 */
function redactSkToken(s: string): string {
  return s.replace(SK_TOKEN_PATTERN, '[sk-redacted]');
}

/**
 * 对普通字符串脱敏(处理 Bearer token 和 sk- 开头的 token)。
 * @param s 原始字符串
 * @returns 脱敏后的字符串
 */
function redactPlain(s: string): string {
  let result: string = redactBearer(s);
  result = redactSkToken(result);
  return result;
}

/**
 * 对 JSON 字符串中的敏感字段值脱敏。
 * 使用正则匹配,不解析 JSON 对象,避免类型问题。
 * 匹配 "key" : "value" 模式(大小写不敏感),替换 value 为 [REDACTED]。
 *
 * @param jsonStr JSON 字符串
 * @returns 脱敏后的 JSON 字符串
 */
function redactJsonFields(jsonStr: string): string {
  let result: string = jsonStr;
  for (let i = 0; i < SENSITIVE_KEYS.length; i++) {
    const key: string = SENSITIVE_KEYS[i];
    const pattern: RegExp = new RegExp('"' + key + '"\\s*:\\s*"[^"]*"', 'gi');
    result = result.replace(pattern, '"' + key + '":"' + REDACTED + '"');
  }
  return result;
}

/**
 * 对字符串脱敏。
 * 尝试判断是否为 JSON,是则按 JSON 字段脱敏,否则按普通字符串脱敏。
 * JSON 解析失败时不抛异常,退化为普通字符串脱敏,不输出疑似密钥。
 *
 * @param value 字符串
 * @returns 脱敏后的字符串
 */
export function redactString(value: string): string {
  // 尝试判断是否为合法 JSON
  let isJson: boolean = false;
  try {
    JSON.parse(value);
    isJson = true;
  } catch (e) {
    isJson = false;
  }

  if (isJson) {
    return redactJsonFields(value);
  }
  return redactPlain(value);
}

/**
 * 对键值对象脱敏。
 * 敏感字段的值替换为 [REDACTED],非敏感字段的值按普通字符串脱敏。
 *
 * @param value 键值对象
 * @returns 脱敏后的 JSON 字符串
 */
export function redactMap(value: Record<string, string>): string {
  const result: Record<string, string> = {};
  const keys: string[] = Object.keys(value);
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    if (isSensitiveKey(k)) {
      result[k] = REDACTED;
    } else {
      result[k] = redactPlain(value[k]);
    }
  }
  try {
    return JSON.stringify(result);
  } catch (e) {
    return '[redact-map-failed]';
  }
}

/**
 * 统一脱敏入口。
 * 支持普通字符串、JSON 字符串、明确类型的键值对象。
 *
 * @param value 字符串或键值对象
 * @returns 脱敏后的字符串
 */
export function redact(value: string | Record<string, string>): string {
  if (typeof value === 'string') {
    return redactString(value);
  }
  return redactMap(value);
}

/**
 * 格式化日志消息(message + 可选 details)。
 * details 在拼接前先脱敏,message 也做普通字符串脱敏。
 *
 * @param message 主消息
 * @param details 可选详情
 * @returns 格式化后的安全字符串
 */
function formatMessage(message: string, details?: string | Record<string, string>): string {
  const safeMessage: string = redactPlain(message);
  if (details === undefined || details === null) {
    return safeMessage;
  }
  const safeDetails: string = redact(details);
  return safeMessage + ' | ' + safeDetails;
}

/**
 * 日志工具类,提供分级日志方法。
 * 所有日志在输出前均经过脱敏处理。
 */
export class Logger {
  /**
   * 输出 debug 级别日志。
   * @param message 主消息
   * @param details 可选详情(会先脱敏)
   */
  static debug(message: string, details?: string | Record<string, string>): void {
    const formatted: string = formatMessage(message, details);
    hilog.debug(LOG_DOMAIN, LOG_TAG, '%{public}s', formatted);
  }

  /**
   * 输出 info 级别日志。
   * @param message 主消息
   * @param details 可选详情(会先脱敏)
   */
  static info(message: string, details?: string | Record<string, string>): void {
    const formatted: string = formatMessage(message, details);
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', formatted);
  }

  /**
   * 输出 warn 级别日志。
   * @param message 主消息
   * @param details 可选详情(会先脱敏)
   */
  static warn(message: string, details?: string | Record<string, string>): void {
    const formatted: string = formatMessage(message, details);
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', formatted);
  }

  /**
   * 输出 error 级别日志。
   * @param message 主消息
   * @param details 可选详情(会先脱敏)
   */
  static error(message: string, details?: string | Record<string, string>): void {
    const formatted: string = formatMessage(message, details);
    hilog.error(LOG_DOMAIN, LOG_TAG, '%{public}s', formatted);
  }
}
