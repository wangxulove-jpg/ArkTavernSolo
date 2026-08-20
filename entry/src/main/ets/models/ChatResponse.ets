/**
 * ChatResponse 聊天响应模型
 *
 * Provider 返回的统一聊天响应结构。
 * 仅包含业务需要的非敏感字段,不包含 API Key、Authorization、完整响应头或原始 JSON。
 *
 * 安全要求:
 * - 不包含 API Key 或 Authorization
 * - 不包含完整响应 Header
 * - 不包含原始 JSON 字符串
 * - 不引用 ProviderConfig
 * - 不依赖 ArkUI
 * - 不使用 any
 */

/**
 * 聊天响应模型。
 * 所有字段除 content 外均为可选,以兼容不同 Provider 返回差异。
 */
export interface ChatResponse {
  /** assistant 回复文本(允许为空字符串,由调用方决定是否接受) */
  readonly content: string;
  /** 结束原因(如 "stop" / "length" / "tool_calls"),可选 */
  readonly finishReason?: string;
  /** 实际生成使用的模型名称(可选,服务端可能回填) */
  readonly model?: string;
  /** 输入 prompt token 数(可选,服务端提供时填充) */
  readonly promptTokens?: number;
  /** 输出 completion token 数(可选) */
  readonly completionTokens?: number;
  /** 总 token 数(可选) */
  readonly totalTokens?: number;
  /** Provider 请求 ID(可选,映射自响应 id 字段,用于问题排查) */
  readonly providerRequestId?: string;
  /** 缓存命中 token 数(可选,Provider 返回 prompt_tokens_details.cached_tokens 时填充) */
  readonly cachedTokens?: number;
}

/**
 * 创建聊天响应。
 *
 * @param content assistant 回复文本
 * @param options 可选字段
 * @returns ChatResponse 实例
 */
export function createChatResponse(
  content: string,
  options?: ChatResponseOptions
): ChatResponse {
  if (options === undefined) {
    return {
      content: content
    };
  }
  // 一次性构造完整对象,避免给 readonly 字段赋值
  return {
    content: content,
    finishReason: options.finishReason,
    model: options.model,
    promptTokens: options.promptTokens,
    completionTokens: options.completionTokens,
    totalTokens: options.totalTokens,
    providerRequestId: options.providerRequestId,
    cachedTokens: options.cachedTokens
  };
}

/**
 * ChatResponse 可选字段。
 */
export interface ChatResponseOptions {
  readonly finishReason?: string;
  readonly model?: string;
  readonly promptTokens?: number;
  readonly completionTokens?: number;
  readonly totalTokens?: number;
  readonly providerRequestId?: string;
  readonly cachedTokens?: number;
}
