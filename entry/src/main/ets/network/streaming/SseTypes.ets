/**
 * SseTypes SSE 通用数据模型
 *
 * 定义 SSE(Server-Sent Events)解析所需的通用类型。
 * 不包含任何 Provider 特定字段(如 OpenAI choices/delta)。
 * 不使用 any,所有字段类型明确。
 */

/**
 * SSE 事件。
 * 对应 SSE 协议中以空行分隔的一个完整事件。
 */
export interface SseEvent {
  /** event 字段值(未指定时为默认 'message',这里保留原值或空字符串) */
  readonly event: string;
  /** data 字段值(多行 data 已按 \n 合并) */
  readonly data: string;
  /** id 字段值(可选) */
  readonly id?: string;
  /** retry 字段值(可选,毫秒) */
  readonly retry?: number;
  /** 是否为 [DONE] 结束标记 */
  readonly isDone: boolean;
}

/**
 * SSE 解析错误。
 * 单个事件的异常不应阻断后续事件解析。
 */
export interface SseParseError {
  /** 人类可读错误消息(不含敏感信息) */
  readonly message: string;
  /** 原始数据片段(已限制长度并脱敏,最多 256 字符) */
  readonly rawData: string;
  /** 是否可恢复(半包不算错误;非法 retry 等可恢复;缓冲溢出不可恢复) */
  readonly recoverable: boolean;
}

/**
 * SSE 解析结果。
 * feed/finish 的返回值。
 * events 和 errors 可同时存在(同一批数据中部分正常部分异常)。
 */
export interface SseParseResult {
  /** 本次解析产生的事件列表 */
  readonly events: SseEvent[];
  /** 本次解析产生的错误列表 */
  readonly errors: SseParseError[];
}
