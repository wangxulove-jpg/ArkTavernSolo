/**
 * SseParser SSE 增量解析器
 *
 * 有状态的增量 SSE(Server-Sent Events)帧解析器。
 * 支持:
 * - 增量分包(一个事件跨多个 chunk)
 * - 多事件合并(一个 chunk 含多个事件)
 * - 换行兼容(\n / \r\n / \r,含跨 chunk 边界)
 * - 标准字段(data/event/id/retry)与注释行
 * - 多行 data 合并
 * - [DONE] 结束标记识别
 * - 缓冲区上限保护
 *
 * 不解析 JSON,不访问 OpenAI/Claude 等 Provider 字段。
 * 不依赖 @ohos.net.http、rcp、hilog 或任何设备 API。
 * 所有方法纯逻辑,可在本地单元测试运行。
 */

import { SseEvent, SseParseError, SseParseResult } from './SseTypes';

/** 缓冲区最大长度(字节,按 UTF-16 码元计数)。超过将触发不可恢复错误。 */
const MAX_BUFFER_LENGTH: number = 65536;
/** 错误 rawData 最大保留长度(字符)。 */
const MAX_ERROR_RAW_LENGTH: number = 256;
/** [DONE] 标记。 */
const DONE_MARK: string = '[DONE]';
// 脱敏正则(内联实现,避免依赖 Logger 模块的 hilog)
const BEARER_PATTERN: RegExp = /Bearer\s+[A-Za-z0-9._-]+/g;
const SK_TOKEN_PATTERN: RegExp = /sk-[A-Za-z0-9._-]{8,}/g;
const REDACTED: string = '[REDACTED]';

/**
 * 对字符串脱敏(内联实现,避免依赖 Logger 模块导致本地测试需 hilog)。
 * @param s 原始字符串
 * @returns 脱敏后的字符串
 */
function redactForError(s: string): string {
  let r: string = s.replace(BEARER_PATTERN, 'Bearer ' + REDACTED);
  r = r.replace(SK_TOKEN_PATTERN, '[sk-redacted]');
  return r;
}

/**
 * SSE 解析器。
 * 状态:缓冲区(buffer) + 当前事件累积字段(currentEvent/retry/id/dataLines/dataLineCount)。
 */
export class SseParser {
  private buffer: string = '';
  private currentEvent: string = '';
  private currentId: string = '';
  private currentRetry: number | undefined = undefined;
  private currentDataLines: string[] = [];
  private hasData: boolean = false;
  private hasEvent: boolean = false;
  private hasId: boolean = false;

  /**
   * 喂入一个 chunk。
   * 解析出所有以空行结尾的完整事件,剩余不完整内容保留在缓冲区。
   *
   * @param chunk 数据块(字符串)
   * @returns 本次解析出的事件与错误
   */
  feed(chunk: string): SseParseResult {
    const events: SseEvent[] = [];
    const errors: SseParseError[] = [];

    if (chunk.length === 0) {
      return { events: events, errors: errors };
    }

    // 检查缓冲区溢出(累加后)
    const newLen: number = this.buffer.length + chunk.length;
    if (newLen > MAX_BUFFER_LENGTH) {
      const err: SseParseError = this.buildOverflowError(newLen);
      errors.push(err);
      this.resetInternal();
      return { events: events, errors: errors };
    }

    this.buffer += chunk;
    this.consumeCompleteLines(events, errors);

    return { events: events, errors: errors };
  }

  /**
   * 通知流结束。
   * 如果缓冲区还有未以空行结尾的内容,尝试作为最后一个事件解析。
   * 内容明显不完整时返回 recoverable=false 错误。
   *
   * @returns 最后的事件与错误
   */
  finish(): SseParseResult {
    const events: SseEvent[] = [];
    const errors: SseParseError[] = [];

    // 流结束时如果缓冲区非空,尝试作为最后一个事件
    if (this.buffer.length > 0) {
      const remaining: string = this.buffer;
      this.buffer = '';
      // 将剩余内容作为最后一行处理(可能没有行尾)
      if (remaining.length > 0) {
        this.processLine(remaining, events, errors);
      }
      // flush 当前累积的事件
      const evt: SseEvent | null = this.flushCurrentEvent();
      if (evt !== null) {
        events.push(evt);
      }
    } else {
      // 缓冲区空,但如果之前有累积字段,也尝试 flush
      const evt: SseEvent | null = this.flushCurrentEvent();
      if (evt !== null) {
        events.push(evt);
      }
    }

    return { events: events, errors: errors };
  }

  /**
   * 重置解析器状态,可复用。
   */
  reset(): void {
    this.resetInternal();
  }

  /**
   * 获取当前缓冲区长度(用于诊断)。
   * @returns 缓冲区字符串长度
   */
  getBufferedLength(): number {
    return this.buffer.length;
  }

  /**
   * 消费缓冲区中所有以换行结尾的完整行。
   * 空行触发事件 flush。
   */
  private consumeCompleteLines(events: SseEvent[], errors: SseParseError[]): void {
    while (this.buffer.length > 0) {
      const lineEnd: LineEnd = findLineEnd(this.buffer);
      if (!lineEnd.found) {
        break; // 剩余不完整行,保留
      }
      const line: string = this.buffer.substring(0, lineEnd.lineEndIndex);
      this.buffer = this.buffer.substring(lineEnd.nextStartIndex);
      this.processLine(line, events, errors);
    }
  }

  /**
   * 处理一行(已去除行尾换行符)。
   * 空行 → flush 当前事件;非空 → 累积字段。
   */
  private processLine(line: string, events: SseEvent[], errors: SseParseError[]): void {
    if (line.length === 0) {
      // 空行:dispatch 当前事件
      const evt: SseEvent | null = this.flushCurrentEvent();
      if (evt !== null) {
        events.push(evt);
      }
      return;
    }

    // 注释行(以冒号开头)
    if (line.charAt(0) === ':') {
      return;
    }

    // 解析字段名与值
    const colonIdx: number = line.indexOf(':');
    let field: string;
    let value: string;
    if (colonIdx < 0) {
      // 无冒号:整行为字段名,值为空
      field = line;
      value = '';
    } else {
      field = line.substring(0, colonIdx);
      value = line.substring(colonIdx + 1);
      // 值前导单个空格去除(SSE 规范:冒号后如有一个空格则去除)
      if (value.length > 0 && value.charAt(0) === ' ') {
        value = value.substring(1);
      }
    }

    this.applyField(field, value, errors);
  }

  /**
   * 应用一个字段到当前事件累积器。
   * 未知字段忽略,非法 retry 产生 recoverable 错误但不阻断。
   */
  private applyField(field: string, value: string, errors: SseParseError[]): void {
    if (field === 'data') {
      this.currentDataLines.push(value);
      this.hasData = true;
    } else if (field === 'event') {
      this.currentEvent = value;
      this.hasEvent = true;
    } else if (field === 'id') {
      // id 不允许包含 NULL 字符
      if (value.indexOf('\0') < 0) {
        this.currentId = value;
        this.hasId = true;
      }
    } else if (field === 'retry') {
      const parsed: number = Number.parseInt(value, 10);
      if (Number.isNaN(parsed) || parsed < 0) {
        // 非法 retry 值,产生可恢复错误,但不阻断其他字段
        errors.push(this.buildError('Invalid retry value: ' + value, value, true));
      } else {
        this.currentRetry = parsed;
      }
    }
    // 未知字段忽略
  }

  /**
   * Flush 当前累积的事件。
   * 无 data 且无 event 字段时不产生事件(参考 SSE 规范:data 为空不 dispatch)。
   *
   * @returns 事件或 null(无内容可 dispatch)
   */
  private flushCurrentEvent(): SseEvent | null {
    // 无任何累积内容,返回 null
    if (!this.hasData && !this.hasEvent && !this.hasId) {
      return null;
    }

    // SSE 规范:data 为空字符串时不 dispatch。
    // 但 hasData=true 表示至少有一个 data: 行(可能值为空字符串),此时应 dispatch 空字符串。
    if (!this.hasData) {
      // 有 event/id 但无 data,按规范不 dispatch,但这里保留兼容性:不产生事件
      this.resetCurrentEvent();
      return null;
    }

    const data: string = this.currentDataLines.join('\n');
    const isDone: boolean = data.trim() === DONE_MARK;

    const evt: SseEvent = {
      event: this.currentEvent,
      data: data,
      id: this.hasId ? this.currentId : undefined,
      retry: this.currentRetry,
      isDone: isDone
    };

    this.resetCurrentEvent();
    return evt;
  }

  /**
   * 重置当前事件累积器。
   */
  private resetCurrentEvent(): void {
    this.currentEvent = '';
    this.currentId = '';
    this.currentRetry = undefined;
    this.currentDataLines = [];
    this.hasData = false;
    this.hasEvent = false;
    this.hasId = false;
  }

  /**
   * 重置内部状态(包括缓冲区与当前事件)。
   */
  private resetInternal(): void {
    this.buffer = '';
    this.resetCurrentEvent();
  }

  /**
   * 构建缓冲区溢出错误(不可恢复)。
   */
  private buildOverflowError(currentLen: number): SseParseError {
    const msg: string = 'SSE buffer overflow: ' + currentLen + ' > ' + MAX_BUFFER_LENGTH;
    return this.buildError(msg, this.buffer, false);
  }

  /**
   * 构建解析错误。
   * rawData 截断到 MAX_ERROR_RAW_LENGTH 并脱敏。
   *
   * @param message 错误消息
   * @param raw 原始数据
   * @param recoverable 是否可恢复
   */
  private buildError(message: string, raw: string, recoverable: boolean): SseParseError {
    const truncated: string = raw.length > MAX_ERROR_RAW_LENGTH
      ? raw.substring(0, MAX_ERROR_RAW_LENGTH)
      : raw;
    const safeRaw: string = redactForError(truncated);
    return {
      message: message,
      rawData: safeRaw,
      recoverable: recoverable
    };
  }
}

/**
 * 行尾查找结果。
 */
interface LineEnd {
  readonly found: boolean;
  readonly lineEndIndex: number;
  readonly nextStartIndex: number;
}

/**
 * 在 buffer 中查找第一个行尾(\n / \r\n / \r)。
 * 返回行内容结束索引(不含换行符)与下一行起始索引。
 *
 * @param buffer 缓冲区
 * @returns LineEnd 结构
 */
function findLineEnd(buffer: string): LineEnd {
  const len: number = buffer.length;
  let firstCr: number = -1;
  let firstLf: number = -1;

  // 扫描第一个 \r 或 \n
  for (let i = 0; i < len; i++) {
    const c: string = buffer.charAt(i);
    if (c === '\r') {
      firstCr = i;
      break;
    }
    if (c === '\n') {
      firstLf = i;
      break;
    }
  }

  if (firstCr < 0 && firstLf < 0) {
    return { found: false, lineEndIndex: 0, nextStartIndex: 0 };
  }

  if (firstLf >= 0) {
    // 单独 \n
    return { found: true, lineEndIndex: firstLf, nextStartIndex: firstLf + 1 };
  }

  // firstCr >= 0:检查是否 \r\n
  const crIdx: number = firstCr;
  if (crIdx + 1 < len && buffer.charAt(crIdx + 1) === '\n') {
    return { found: true, lineEndIndex: crIdx, nextStartIndex: crIdx + 2 };
  }
  // 单独 \r
  return { found: true, lineEndIndex: crIdx, nextStartIndex: crIdx + 1 };
}
