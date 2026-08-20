/**
 * AiProvider AI Provider 抽象接口
 *
 * 定义所有 AI Provider(OpenAI-compatible / Claude / Gemini 等)的统一契约。
 * 包含非流式方法 sendChat 和流式方法 streamChat。
 *
 * 设计原则:
 * - Provider 不依赖页面或 ViewModel
 * - Provider 不直接读 Preferences
 * - Provider 通过依赖注入获得 HttpClient 和 ProviderKeyStore
 * - Provider 不缓存 API Key
 *
 * 安全要求:
 * - 实现类不得在日志中输出 API Key、Authorization 或请求正文
 * - 实现类不得将 API Key 放入错误对象
 * - 流式实现不得在日志中输出完整 delta、原始 SSE data 或完整回复
 */

import { ProviderConfig } from '../../models/ProviderConfig';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatResponse } from '../../models/ChatResponse';
import { NetworkError } from '../../models/NetworkError';
import { ModelListItem } from '../../models/ModelListResult';
import {
  ChatStreamCallbacks,
  ChatStreamHandle
} from '../../models/ChatStreamTypes';

/**
 * AI Provider 抽象接口。
 * 使用抽象类以支持 ArkTS 严格模式并提供明确契约。
 *
 * 所有实现类必须实现 sendChat 和 streamChat 方法。
 */
export abstract class AiProvider {
  /**
   * 发送非流式聊天请求,等待完整响应后返回。
   *
   * 实现要求:
   * 1. 从 ProviderKeyStore 读取 config.id 对应的 API Key
   * 2. 构造 Provider 特定的 URL
   * 3. 构造请求体(强制 stream=false)
   * 4. 通过 HttpClient 发起 POST 请求
   * 5. 解析响应并返回 ChatResponse
   * 6. 映射 HTTP/网络/解析错误为 NetworkError
   *
   * @param config Provider 配置(不含 API Key)
   * @param request 聊天请求
   * @returns 聊天响应
   * @throws NetworkError 当 API Key 不存在、网络错误、鉴权失败、解析失败时
   */
  abstract sendChat(config: ProviderConfig, request: ChatRequest): Promise<ChatResponse>;

  /**
   * 发送流式聊天请求,通过回调增量返回内容。
   *
   * 实现要求:
   * 1. 从 ProviderKeyStore 读取 config.id 对应的 API Key
   * 2. 构造 Provider 特定的 URL
   * 3. 构造请求体(强制 stream=true)
   * 4. 构造 Header(含 Authorization)
   * 5. 通过流式传输层(如 HttpStreamTransport)发起 POST 请求
   * 6. SSE 数据链路:HttpStreamTransport.onData → SseParser.feed → OpenAiSseDeltaParser → callbacks.onDelta
   * 7. 正确识别 [DONE] 与无 [DONE] 的兼容完成
   * 8. 支持 abort 主动取消
   * 9. 支持 usage 和 finish_reason 解析
   * 10. 错误映射为 NetworkError
   * 11. 状态单向终态,complete/error/cancel 只发生一次
   *
   * 生命周期:
   * - 同步返回 ChatStreamHandle,调用方可立即调用 abort
   * - 请求开始时触发 onStart(可选)
   * - 收到 delta 时触发 onDelta(可多次,顺序保持)
   * - 正常结束触发 onComplete(一次)或错误触发 onError(一次)
   * - abort 后触发 onError(Cancelled),不触发 onComplete
   *
   * @param config Provider 配置(不含 API Key)
   * @param request 聊天请求
   * @param callbacks 流式回调
   * @returns 流式请求句柄(可用于查询状态和取消)
   */
  abstract streamChat(
    config: ProviderConfig,
    request: ChatRequest,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle;

  /**
   * Phase 4A-3: 声明 Provider 是否支持原生 structured tool calling。
   *
   * - 默认返回 false (向后兼容)
   * - 支持 Tool Calling 的 Provider (如 OpenAIProvider) 重写此方法返回 true
   * - ChatService 只在 supported=true 时向 request 注入 tools
   * - 不支持时, 普通聊天完全保持原行为
   */
  supportsToolCalling(): boolean {
    return false;
  }

  abstract fetchModels(baseUrl: string, apiKey: string): Promise<ModelListItem[]>;
}

/**
 * 类型守卫:判断未知对象是否为 NetworkError。
 * 用于 catch 块中安全类型断言。
 *
 * @param obj 未知对象
 * @returns 是 NetworkError 返回 true
 */
export function isNetworkError(obj: Object): boolean {
  if (obj === null || obj === undefined) {
    return false;
  }
  // NetworkError 是 interface,无法用 instanceof 判断;
  // 通过鸭子类型检查必需字段。
  const candidate = obj as NetworkError;
  return typeof candidate.type === 'string'
    && typeof candidate.message === 'string'
    && typeof candidate.retryable === 'boolean';
}
