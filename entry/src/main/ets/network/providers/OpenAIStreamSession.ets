/**
 * OpenAIStreamSession OpenAI 流式请求会话
 *
 * 封装单次流式请求的完整生命周期:
 * - 状态机(Idle → Connecting → Streaming → Completed/Cancelled/Failed)
 * - SseParser 累积解析
 * - OpenAiSseDeltaParser 解析每个 SSE event 的 data
 * - delta 拼接、finish_reason、usage、[DONE] 识别
 * - abort 幂等,迟到回调忽略
 *
 * 复用:
 * - SseParser(不复制第二套 SSE 解析器)
 * - OpenAiSseDeltaParser(不复制第二套 delta 解析器)
 * - OpenAiUrlBuilder(通过 OpenAIProvider 传入 URL)
 * - NetworkError(错误模型)
 *
 * 安全要求:
 * - 不记录 API Key、Authorization、原始 SSE data、完整回复
 * - 错误消息脱敏,最长 512 字符
 * - 不把 API Key 放入错误对象
 *
 * 不依赖 ArkUI,不依赖页面,不缓存 API Key。
 */

import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState,
  ChatStreamResult,
  ChatDelta,
  isStreamTerminalState,
  StreamToolCallResult
} from '../../models/ChatStreamTypes';
import {
  NetworkError,
  NetworkErrorType,
  createNetworkError,
  errorTypeFromStatusCode
} from '../../models/NetworkError';
import { SseParser } from '../streaming/SseParser';
import { SseEvent, SseParseError } from '../streaming/SseTypes';
import {
  parseOpenAiDelta,
  OpenAiDeltaResult,
  OpenAiToolCallDelta
} from '../streaming/OpenAiSseDeltaParser';
import { TransportCallbacks } from '../streaming/StreamTransportTypes';
import { TransportRequestOptions, TransportAbortHandle } from '../streaming/HttpStreamTransport';
import { Logger } from '../../utils/Logger';


/** 日志标签 */
const LOG_TAG: string = 'OpenAIStreamSession';

/** 错误消息最大长度 */
const MAX_ERROR_MESSAGE_LENGTH: number = 512;

/** usage 字段提取所需的三个键 */
interface UsageFields {
  readonly promptTokens: number;
  readonly completionTokens: number;
  readonly totalTokens: number;
  readonly cachedTokens: number | undefined;
}

/** id 和 model 元数据提取结果 */
interface IdAndModel {
  readonly id: string;
  readonly model: string;
}

/**
 * Phase 4A-3: 按 index 累积的工具调用条目。
 *
 * OpenAI 流式协议: tool_calls 按 index 分组, 首次包含 id + name,
 * 后续仅包含 arguments 增量片段。累积完成后转为 StreamToolCallResult。
 */
interface AccumulatedToolCall {
  index: number;
  toolCallId: string;
  name: string;
  argumentsAccumulated: string;
}

/**
 * 安全获取 Record<string, Object> 的数字属性。
 */
function getNumberField(obj: Record<string, Object>, key: string): number | undefined {
  const val: Object | undefined = obj[key];
  if (val === undefined || val === null) {
    return undefined;
  }
  if (typeof val === 'number') {
    return val;
  }
  return undefined;
}

/**
 * 安全获取 Record<string, Object> 的对象属性。
 */
function getObjectField(obj: Record<string, Object>, key: string): Record<string, Object> | null {
  const val: Object | undefined = obj[key];
  if (val === undefined || val === null) {
    return null;
  }
  if (val === null || typeof val !== 'object') {
    return null;
  }
  return val as Record<string, Object>;
}

/**
 * 从 SSE event data 的 JSON 对象中提取 usage 字段。
 * @param root 解析后的 JSON 对象
 * @returns UsageFields,缺失任一字段返回 null
 */
function extractUsage(root: Record<string, Object>): UsageFields | null {
  const usageObj: Record<string, Object> | null = getObjectField(root, 'usage');
  if (usageObj === null) {
    return null;
  }
  const promptTokens: number | undefined = getNumberField(usageObj, 'prompt_tokens');
  const completionTokens: number | undefined = getNumberField(usageObj, 'completion_tokens');
  const totalTokens: number | undefined = getNumberField(usageObj, 'total_tokens');
  if (promptTokens === undefined || completionTokens === undefined || totalTokens === undefined) {
    return null;
  }
  let cachedTokens: number | undefined = undefined;
  const detailsObj: Record<string, Object> | null = getObjectField(usageObj, 'prompt_tokens_details');
  if (detailsObj !== null) {
    cachedTokens = getNumberField(detailsObj, 'cached_tokens');
  }
  return {
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    totalTokens: totalTokens,
    cachedTokens: cachedTokens
  };
}

/**
 * 从 SSE event data 的 JSON 对象中提取 id 和 model 字段。
 */
function extractIdAndModel(root: Record<string, Object>): IdAndModel {
  const idVal: Object | undefined = root['id'];
  const modelVal: Object | undefined = root['model'];
  const id: string = (typeof idVal === 'string') ? idVal : '';
  const model: string = (typeof modelVal === 'string') ? modelVal : '';
  return { id: id, model: model };
}

/**
 * 截断错误消息,防止过长。
 */
function truncateErrorMessage(message: string): string {
  if (message.length <= MAX_ERROR_MESSAGE_LENGTH) {
    return message;
  }
  return message.substring(0, MAX_ERROR_MESSAGE_LENGTH) + '...[truncated]';
}

/**
 * 流式请求发起函数类型。
 * 由 OpenAIProvider 提供,内部调用 HttpStreamTransport.requestStream。
 */
export type StreamLauncher = (
  options: TransportRequestOptions,
  callbacks: TransportCallbacks
) => TransportAbortHandle;

/**
 * OpenAI 流式会话。
 * 每次调用 OpenAIProvider.streamChat 创建一个独立会话,互不干扰。
 */
export class OpenAIStreamSession implements ChatStreamHandle {
  private callbacks: ChatStreamCallbacks | null = null;
  private readonly sseParser: SseParser = new SseParser();
  private state: ChatStreamState = ChatStreamState.Idle;
  private transportHandle: TransportAbortHandle | null = null;

  // 累积状态
  private accumulatedContent: string = '';
  private accumulatedReasoning: string = '';
  private finishReason: string | undefined = undefined;
  private model: string | undefined = undefined;
  private providerRequestId: string | undefined = undefined;
  private usage: UsageFields | null = null;
  private receivedDone: boolean = false;
  private sequence: number = 0;
  private deltaCount: number = 0;
  private eventCount: number = 0;
  private chunkCount: number = 0;
  private hasNonRecoverableError: boolean = false;
  private abortRequested: boolean = false;
  /** onComplete 是否已触发(确保只触发一次) */
  private completeFired: boolean = false;
  /** onError 是否已触发(确保只触发一次) */
  private errorFired: boolean = false;
  /** headers 收到前缓存的 chunks(等待 handleHeaders 后处理) */
  private pendingChunks: string[] = [];
  /**
   * Phase 4A-3: 按 index 累积的工具调用条目列表。
   *
   * 只在收到 delta.tool_calls 时累积, 完成后转为 StreamToolCallResult。
   * 不解析聊天正文 / Markdown / JSON 代码块。
   */
  private accumulatedToolCalls: AccumulatedToolCall[] = [];

  /**
   * 启动流式会话。
   *
   * @param requestUrl 已构建的完整 URL
   * @param requestBody 请求体 JSON 字符串(强制 stream=true)
   * @param headers 请求头 Map(含 Authorization)
   * @param callbacks 流式回调
   * @param launcher 流式请求发起函数(由 Provider 注入,内部调用 HttpStreamTransport)
   */
  start(
    requestUrl: string,
    requestBody: string,
    headers: Map<string, string>,
    callbacks: ChatStreamCallbacks,
    launcher: StreamLauncher
  ): void {
    if (isStreamTerminalState(this.state)) {
      return;
    }
    this.callbacks = callbacks;
    this.state = ChatStreamState.Connecting;
    if (this.callbacks.onStart !== undefined) {
      this.callbacks.onStart();
    }

    const transportOptions: TransportRequestOptions = {
      url: requestUrl,
      method: 'POST',
      headers: headers,
      body: requestBody,
      connectTimeoutMs: 30000,
      readTimeoutMs: 120000
    };

    const transportCallbacks: TransportCallbacks = {
      onHeaders: (statusCode: number, _headers: Map<string, string>) => {
        this.handleHeaders(statusCode);
      },
      onData: (chunk: string, _byteLength: number) => {
        this.handleData(chunk);
      },
      onComplete: (statusCode: number) => {
        this.handleComplete(statusCode);
      },
      onError: (error: NetworkError) => {
        this.handleError(error);
      }
    };

    try {
      this.transportHandle = launcher(transportOptions, transportCallbacks);
    } catch (e) {
      this.handleError(createNetworkError(
        NetworkErrorType.Unknown,
        'Failed to start stream request',
        { causeMessage: String(e) }
      ));
    }

    // 如果在 launcher 同步调用中已 abort,此处再确保终止
    if (this.abortRequested && this.transportHandle !== null) {
      this.transportHandle.abort();
    }
  }

  /**
   * 在 start() 之前触发错误(用于校验失败、读 Key 失败等)。
   * 如果已经 start 或已进入终态,则忽略(由状态机保护)。
   *
   * @param callbacks 流式回调(在 start 之前传入,因为还没赋值给 this.callbacks)
   * @param error 网络错误对象
   */
  failBeforeStart(callbacks: ChatStreamCallbacks, error: NetworkError): void {
    if (isStreamTerminalState(this.state)) {
      return;
    }
    this.callbacks = callbacks;
    this.state = ChatStreamState.Failed;
    Logger.error(LOG_TAG, 'failBeforeStart type=' + error.type + ' msg=' + error.message);
    this.safeOnError(error);
  }

  /**
   * 中止请求(幂等)。
   * 状态切换为 Cancelled,触发 onError(Cancelled),不触发 onComplete。
   */
  abort(): void {
    if (isStreamTerminalState(this.state)) {
      return;
    }
    this.abortRequested = true;
    this.state = ChatStreamState.Cancelled;

    // 终止底层传输
    if (this.transportHandle !== null) {
      try {
        this.transportHandle.abort();
      } catch (e) {
        // 忽略 abort 异常
      }
      this.transportHandle = null;
    }

    const err: NetworkError = createNetworkError(
      NetworkErrorType.Cancelled,
      'Stream aborted by user'
    );
    this.safeOnError(err);
  }

  /**
   * 查询当前状态。
   */
  getState(): ChatStreamState {
    return this.state;
  }

  // ===== 内部处理 =====

  /**
   * 处理响应头。
   * 非 2xx 状态码直接映射为错误。
   * 成功后处理 headers 收到前缓存的 chunks。
   */
  private handleHeaders(statusCode: number): void {
    if (isStreamTerminalState(this.state)) {
      return;
    }

    if (statusCode < 200 || statusCode >= 300) {
      const errorType: NetworkErrorType = errorTypeFromStatusCode(statusCode);
      const err: NetworkError = createNetworkError(
        errorType,
        'Stream HTTP ' + statusCode.toString(),
        { statusCode: statusCode }
      );
      this.handleError(err);
      return;
    }

    this.state = ChatStreamState.Streaming;

    // 处理 headers 收到前缓存的 chunks
    for (let i = 0; i < this.pendingChunks.length; i++) {
      if (isStreamTerminalState(this.state)) {
        this.pendingChunks = [];
        return;
      }
      this.processChunk(this.pendingChunks[i]);
    }
    this.pendingChunks = [];
  }

  /**
   * 处理网络 chunk。
   * 如果状态仍是 Connecting(headers 还未收到),缓存 chunk,等 handleHeaders 后再处理。
   * 这样可以确保错误状态码(401/429/500)在解析 SSE 前被识别。
   */
  private handleData(chunk: string): void {
    if (isStreamTerminalState(this.state)) {
      return;
    }
    if (chunk.length === 0) {
      return;
    }
    // 如果 headers 还没收到(state 仍是 Connecting),缓存 chunk
    if (this.state === ChatStreamState.Connecting) {
      this.pendingChunks.push(chunk);
      return;
    }
    this.processChunk(chunk);
  }

  /**
   * 实际处理 chunk:传入 SseParser,解析事件。
   */
  private processChunk(chunk: string): void {
    this.chunkCount++;

    const result = this.sseParser.feed(chunk);
    const events: SseEvent[] = result.events;
    const errors: SseParseError[] = result.errors;

    // 处理解析错误(不可恢复的立即终止)
    for (let i = 0; i < errors.length; i++) {
      const parseError: SseParseError = errors[i];
      if (!parseError.recoverable) {
        this.hasNonRecoverableError = true;
        const err: NetworkError = createNetworkError(
          NetworkErrorType.Parse,
          'SSE parse error: ' + parseError.message
        );
        this.handleError(err);
        return;
      }
      // 可恢复错误记录日志
      Logger.warn(LOG_TAG, 'SSE recoverable error: ' + parseError.message);
    }

    // 处理事件
    for (let i = 0; i < events.length; i++) {
      if (isStreamTerminalState(this.state)) {
        return;
      }
      this.handleEvent(events[i]);
    }
  }

  /**
   * 处理单个 SSE 事件。
   */
  private handleEvent(event: SseEvent): void {
    this.eventCount++;

    // [DONE] 标记
    if (event.isDone) {
      this.receivedDone = true;
      return;
    }

    // 解析 delta
    const deltaResult: OpenAiDeltaResult = parseOpenAiDelta(event.data);

    // 解析错误
    if (deltaResult.parseError !== undefined) {
      // 尝试从 parseError 中识别服务端错误对象
      const err: NetworkError = createNetworkError(
        NetworkErrorType.Parse,
        truncateErrorMessage('SSE delta parse error: ' + deltaResult.parseError)
      );
      this.handleError(err);
      return;
    }

    // 尝试从 data 中提取 usage、id、model(只在非 [DONE] 且非空 data 时)
    this.tryExtractMetadata(event.data);

    // finish_reason
    if (deltaResult.finishReason !== undefined && deltaResult.finishReason.length > 0) {
      this.finishReason = deltaResult.finishReason;
    }

    // Phase 4A-3: 累积 tool_calls 增量 (按 index 关联, 不执行, 不解析正文)
    if (deltaResult.toolCallDeltas !== undefined) {
      this.accumulateToolCallDeltas(deltaResult.toolCallDeltas);
    }

    // reasoning_content delta (思考模型如 DeepSeek-R1/QwQ)
    if (deltaResult.reasoningContent !== undefined && deltaResult.reasoningContent.length > 0) {
      this.accumulatedReasoning += deltaResult.reasoningContent;
    }

    // content delta
    if (deltaResult.hasContent && deltaResult.content.length > 0) {
      this.accumulatedContent += deltaResult.content;
      const delta: ChatDelta = {
        content: deltaResult.content,
        accumulatedContent: this.accumulatedContent,
        finishReason: deltaResult.finishReason,
        sequence: this.sequence,
        reasoningContent: deltaResult.reasoningContent
      };
      this.sequence++;
      this.deltaCount++;
      this.safeOnDelta(delta);
    } else if (deltaResult.reasoningContent !== undefined && deltaResult.reasoningContent.length > 0) {
      // 思考模型可能只有 reasoning_content 没有 content,仍然触发 onDelta
      const delta: ChatDelta = {
        content: '',
        accumulatedContent: this.accumulatedContent,
        finishReason: deltaResult.finishReason,
        sequence: this.sequence,
        reasoningContent: deltaResult.reasoningContent
      };
      this.sequence++;
      this.deltaCount++;
      this.safeOnDelta(delta);
    }
    // 空 content 或 role-only 事件不触发 onDelta,但不算错误
  }

  /**
   * Phase 4A-3: 累积 tool_calls 增量片段。
   *
   * - 按 index 关联同一个工具调用
   * - 首次出现时记录 id + name (后续覆盖忽略)
   * - arguments 增量片段按顺序拼接
   * - 不执行工具, 不解析半截 JSON
    * - 完成后由 buildResult 转为 StreamToolCallResult 列表
   */
  private accumulateToolCallDeltas(deltas: OpenAiToolCallDelta[]): void {
    for (let i = 0; i < deltas.length; i++) {
      const d: OpenAiToolCallDelta = deltas[i];
      // 查找已存在的 index
      let entry: AccumulatedToolCall | null = null;
      for (let j = 0; j < this.accumulatedToolCalls.length; j++) {
        if (this.accumulatedToolCalls[j].index === d.index) {
          entry = this.accumulatedToolCalls[j];
          break;
        }
      }
      if (entry === null) {
        // 新增条目
        const newEntry: AccumulatedToolCall = {
          index: d.index,
          toolCallId: d.id,
          name: d.name,
          argumentsAccumulated: d.argumentsDelta
        };
        this.accumulatedToolCalls.push(newEntry);
      } else {
        // 已有条目: 累积 arguments (id 和 name 只在首次出现, 后续为空字符串)
        if (d.id.length > 0 && entry.toolCallId.length === 0) {
          entry.toolCallId = d.id;
        }
        if (d.name.length > 0 && entry.name.length === 0) {
          entry.name = d.name;
        }
        entry.argumentsAccumulated += d.argumentsDelta;
      }
    }
  }

  /**
   * 尝试从 SSE event data 中提取 usage、id、model 元数据。
   * 非 JSON 或无对应字段时静默忽略。
   */
  private tryExtractMetadata(data: string): void {
    const trimmed: string = data.trim();
    if (trimmed.length === 0) {
      return;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(trimmed);
    } catch (e) {
      return;
    }
    if (parsed === null || typeof parsed !== 'object') {
      return;
    }
    const root: Record<string, Object> = parsed as Record<string, Object>;

    // usage(任一事件都可能携带,通常在最后)
    const usageFields: UsageFields | null = extractUsage(root);
    if (usageFields !== null) {
      this.usage = usageFields;
    }

    // id 和 model
    const meta = extractIdAndModel(root);
    if (meta.id.length > 0 && this.providerRequestId === undefined) {
      this.providerRequestId = meta.id;
    }
    if (meta.model.length > 0 && this.model === undefined) {
      this.model = meta.model;
    }
  }

  /**
   * 处理网络层完成。
   * 触发 SseParser.finish,处理剩余事件,然后决定完成或失败。
   */
  private handleComplete(statusCode: number): void {
    if (isStreamTerminalState(this.state)) {
      return;
    }

    // flush SseParser 剩余内容
    const finishResult = this.sseParser.finish();
    const finishEvents: SseEvent[] = finishResult.events;
    const finishErrors: SseParseError[] = finishResult.errors;

    for (let i = 0; i < finishErrors.length; i++) {
      if (!finishErrors[i].recoverable) {
        this.hasNonRecoverableError = true;
        const err: NetworkError = createNetworkError(
          NetworkErrorType.Parse,
          'SSE finish error: ' + finishErrors[i].message
        );
        this.handleError(err);
        return;
      }
    }

    for (let i = 0; i < finishEvents.length; i++) {
      if (isStreamTerminalState(this.state)) {
        return;
      }
      this.handleEvent(finishEvents[i]);
    }

    if (isStreamTerminalState(this.state)) {
      return;
    }

    // 判定完成或失败
    if (this.hasNonRecoverableError) {
      this.handleError(createNetworkError(
        NetworkErrorType.Parse,
        'Non-recoverable SSE error during stream'
      ));
      return;
    }

    // 无 [DONE] 但有有效内容,允许兼容完成
    if (!this.receivedDone && this.deltaCount === 0 && this.finishReason === undefined) {
      // 无 content、无 finish_reason、无 [DONE]、连接直接结束 → 兼容性错误
      this.handleError(createNetworkError(
        NetworkErrorType.Parse,
        'Stream ended without content, finish_reason, or [DONE]'
      ));
      return;
    }

    // 正常完成
    this.state = ChatStreamState.Completed;
    const result: ChatStreamResult = this.buildResult();
    this.safeOnComplete(result);
  }

  /**
   * 处理错误。
   */
  private handleError(error: NetworkError): void {
    if (isStreamTerminalState(this.state)) {
      return;
    }
    this.state = ChatStreamState.Failed;
    this.transportHandle = null;
    Logger.error(LOG_TAG, 'error type=' + error.type + ' msg=' + error.message);
    this.safeOnError(error);
  }

  /**
   * 构建完成结果。
   */
  private buildResult(): ChatStreamResult {
    const promptTokens: number | undefined = this.usage !== null ? this.usage.promptTokens : undefined;
    const completionTokens: number | undefined = this.usage !== null ? this.usage.completionTokens : undefined;
    const totalTokens: number | undefined = this.usage !== null ? this.usage.totalTokens : undefined;
    const cachedTokens: number | undefined = this.usage !== null ? this.usage.cachedTokens : undefined;

    // Phase 4A-3: 将累积的 tool_calls 转为 StreamToolCallResult 列表
    // 只在累积非空时输出, 顺序按 index
    let toolCalls: StreamToolCallResult[] | undefined = undefined;
    if (this.accumulatedToolCalls.length > 0) {
      // 按 index 排序
      const sorted: AccumulatedToolCall[] = this.accumulatedToolCalls.slice();
      sorted.sort((a: AccumulatedToolCall, b: AccumulatedToolCall): number => a.index - b.index);
      toolCalls = [];
      for (let i = 0; i < sorted.length; i++) {
        const entry: AccumulatedToolCall = sorted[i];
        toolCalls.push({
          toolCallId: entry.toolCallId,
          name: entry.name,
          argumentsJson: entry.argumentsAccumulated
        });
      }
    }

    return {
      content: this.accumulatedContent,
      finishReason: this.finishReason,
      model: this.model,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      providerRequestId: this.providerRequestId,
      cachedTokens: cachedTokens,
      chunkCount: this.chunkCount,
      eventCount: this.eventCount,
      deltaCount: this.deltaCount,
      receivedDone: this.receivedDone,
      toolCalls: toolCalls,
      reasoningContent: this.accumulatedReasoning.length > 0 ? this.accumulatedReasoning : undefined
    };
  }

  // ===== 安全回调触发(终态后忽略迟到回调) =====

  private safeOnDelta(delta: ChatDelta): void {
    if (isStreamTerminalState(this.state)) {
      return;
    }
    if (this.callbacks !== null) {
      this.callbacks.onDelta(delta);
    }
  }

  private safeOnComplete(result: ChatStreamResult): void {
    // complete 只能触发一次;已触发过则忽略迟到调用
    if (this.completeFired) {
      return;
    }
    this.completeFired = true;
    if (this.callbacks !== null) {
      this.callbacks.onComplete(result);
    }
  }

  private safeOnError(error: NetworkError): void {
    // error 只能触发一次;已触发过则忽略迟到调用
    if (this.errorFired) {
      return;
    }
    this.errorFired = true;
    if (this.callbacks !== null) {
      this.callbacks.onError(error);
    }
  }
}
