/**
 * Time 工具模块
 *
 * 提供毫秒时间戳与 ISO 8601 字符串转换能力。
 * 不实现国际化日期格式化,保持简单。
 */

/**
 * 获取当前毫秒时间戳(UTC)。
 * @returns 毫秒时间戳
 */
export function nowMillis(): number {
  return Date.now();
}

/**
 * 获取当前 ISO 8601 字符串(UTC)。
 * @returns ISO 8601 格式字符串,如 "2026-07-15T12:34:56.789Z"
 */
export function nowIso(): string {
  return new Date().toISOString();
}

/**
 * 将毫秒时间戳转换为 ISO 8601 字符串。
 * 对非法时间戳抛出 Error,不产生 "Invalid Date" 文本。
 *
 * @param millis 毫秒时间戳
 * @returns ISO 8601 格式字符串
 * @throws Error 当 millis 非有限数或无法转换为有效日期时
 */
export function millisToIso(millis: number): string {
  if (!Number.isFinite(millis)) {
    throw new Error('Invalid timestamp: value is not finite');
  }
  const date: Date = new Date(millis);
  const time: number = date.getTime();
  if (Number.isNaN(time)) {
    throw new Error('Invalid timestamp: cannot convert to valid date');
  }
  return date.toISOString();
}
