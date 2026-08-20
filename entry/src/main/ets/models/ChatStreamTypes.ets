/**
 * ChatStreamTypes 流式聊天类型定义
 *
 * 定义 Provider 流式聊天所需的回调、增量、结果、句柄和状态类型。
 * 与具体 Provider(OpenAI / Claude / Gemini)无关,所有 Provider 复用同一套类型。
 *
 * 设计原则:
 * - 不包含 API Key / Authorization / 完整 Header
 * - 不包含原始 SSE data / 完整请求 Body / 完整回复原文
 * - 不引用 ProviderConfig
 * - 不依赖 ArkUI
 * - 不使用 any
 * - 状态单向终态:Idle → Connecting → Streaming → Completed/Cancelled/Failed
 * - complete / error / cancel 只能发生一次
 * - 迟到回调不能改变终态
 *
 * 生命周期:
 * 1. 调用方通过 Provider.streamChat 获得同步返回的 ChatStreamHandle
 * 2. Provider 内部发起请求,触发 onStart(可选)
 * 3. 收到 delta 时触发 onDelta(可多次)
 * 4. 正常结束触发 onComplete(一次) 或 错误触发 onError(一次)
 * 5. 调用方可随时调用 handle.abort() 主动取消
 * 6. 终态后所有迟到回调被忽略
 */

import { NetworkError } from './NetworkError';

/** Tool call result from streaming (replaces ArkWebChatToolCall from removed module) */
export interface StreamToolCallResult {
  readonly toolCallId: string;
  readonly name: string;
  readonly argumentsJson: string;
}

/**
 * 流式状态。
 * 单向终态:Idle → Connecting → Streaming → Completed/Cancelled/Failed。
 * Completed / Cancelled / Failed 为终态,不可再转换。
 */
export enum ChatStreamState {
  /** 初始状态,尚未发起请求 */
  Idle = 'Idle',
  /** 请求已发起,等待响应头/首个数据 */
  Connecting = 'Connecting',
  /** 正在接收数据,触发 onDelta */
  Streaming = 'Streaming',
  /** 正常完成(onComplete 已调用) */
  Completed = 'Completed',
  /** 已取消(abort 已调用) */
  Cancelled = 'Cancelled',
  /** 已失败(onError 已调用) */
  Failed = 'Failed'
}

/**
 * 判断状态是否为终态(不可再转换)。
 * @param state 当前状态
 * @returns 终态返回 true
 */
export function isStreamTerminalState(state: ChatStreamState): boolean {
  return state === ChatStreamState.Completed
    || state === ChatStreamState.Cancelled
    || state === ChatStreamState.Failed;
}

/**
 * 增量内容。
 * 每次收到服务端 delta 时构造并通过 onDelta 传递给调用方。
 */
export interface ChatDelta {
  /** 本次增量内容(允许为空字符串,调用方可忽略) */
  readonly content: string;
  /** 截至本次增量的累积内容(可选,便于调用方一次显示) */
  readonly accumulatedContent?: string;
  /** finish_reason(可选,通常在最后一个 delta 中出现) */
  readonly finishReason?: string;
  /** 序号(从 0 开始,每次 delta 递增 1) */
  readonly sequence: number;
}

/**
 * 流式完成结果。
 * onComplete 触发时传递给调用方。
 */
export interface ChatStreamResult {
  /** 完整回复内容(所有非空 delta 按顺序拼接) */
  readonly content: string;
  /** 结束原因(如 "stop" / "length" / "content_filter"),可选 */
  readonly finishReason?: string;
  /** 实际生成使用的模型名称(可选,服务端可能回填) */
  readonly model?: string;
  /** 输入 prompt token 数(可选) */
  readonly promptTokens?: number;
  /** 输出 completion token 数(可选) */
  readonly completionTokens?: number;
  /** 总 token 数(可选) */
  readonly totalTokens?: number;
  /** Provider 请求 ID(可选,映射自响应 id 字段) */
  readonly providerRequestId?: string;
  /** 缓存命中 token 数(可选,Provider 返回 prompt_tokens_details.cached_tokens 时填充) */
  readonly cachedTokens?: number;
  /** 网络层 chunk 数(诊断用) */
  readonly chunkCount: number;
  /** SSE event 数(诊断用) */
  readonly eventCount: number;
  /** 非空 content delta 数(诊断用) */
  readonly deltaCount: number;
  /** 是否收到 [DONE] 标记(兼容服务端不发送 [DONE] 时为 false) */
  readonly receivedDone: boolean;
  /**
   * Phase 4A-2: 可选演出 Hint JSON 字符串 (透传字段,默认空字符串)。
   *
   * 来源限制 (AGENTS.md Phase 4A-2 §performanceHintJson 来源):
   *   - 只允许来自 Provider 返回的结构化字段 (如 OpenAI response.metadata.performanceHintJson)
   *   - 禁止从 Markdown / JSON 文本 / 括号内容 / 关键词匹配提取
   *   - 没有该字段时为 undefined 或空字符串
   *
   * 用途: ChatService.onComplete 把此字段回调给 ChatViewModel。
   *
   * 不修改: 请求 URL / 请求体 / API Key / 流式解析协议 / 重试 / 重新生成。
   */
  readonly performanceHintJson?: string;
  /**
   * Phase 4A-3: Provider 原生返回的工具调用列表 (可选)。
   *
   * - 由 Provider Adapter 从流式响应中累积解析得到 (按 toolCallId 拼接 arguments 增量)
   * - finishReason="tool_calls" 时, 此字段包含完整工具调用列表
   * - ChatService 在收到 toolCalls 后, 先执行工具, 再将结果作为 toolResults 回传继续对话
   * - 不解析聊天正文 / Markdown / JSON 代码块
   */
  readonly toolCalls?: StreamToolCallResult[];
}

/**
 * 流式回调集合。
 * 调用方提供实现,Provider 在不同阶段触发对应回调。
 *
 * 约束:
 * - onStart 可选,最多调用一次
 * - onDelta 可调用多次,顺序与服务端返回一致
 * - onComplete 与 onError 互斥,最多调用一次
 * - 终态后所有迟到回调被忽略
 */
export interface ChatStreamCallbacks {
  /** 请求已发起,开始等待响应(可选) */
  onStart?: () => void;
  /** 收到增量内容(可多次) */
  onDelta: (delta: ChatDelta) => void;
  /** 流式完成(与 onError 互斥,最多一次) */
  onComplete: (result: ChatStreamResult) => void;
  /** 发生错误(与 onComplete 互斥,最多一次) */
  onError: (error: NetworkError) => void;
}

/**
 * 流式请求句柄。
 * 调用方通过此句柄查询状态或主动取消。
 */
export interface ChatStreamHandle {
  /** 中止请求(幂等,多次调用不崩溃) */
  abort(): void;
  /** 查询当前状态 */
  getState(): ChatStreamState;
}
