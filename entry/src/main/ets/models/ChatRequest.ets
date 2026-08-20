/**
 * ChatRequest 聊天请求模型
 *
 * 与 OpenAI Chat Completions 常用字段兼容,保持 Provider 无关。
 *
 * 安全要求:
 * - 不包含 URL
 * - 不包含 API Key
 * - 不包含 Header
 * - 不包含 UI 状态
 *
 * 本阶段不加入:
 * - images / audio
 * - SillyTavern Prompt
 * - Character / Lorebook
 */

import { ChatMessage } from './ChatMessage';
import { TEMPERATURE_DEFAULT, TOP_P_DEFAULT, MAX_TOKENS_DEFAULT } from './ProviderConfig';

/**
 * 聊天请求选项(不含 model,由 ModelService 填充)。
 */
export interface ChatRequestOptions {
  /** 采样温度 */
  readonly temperature: number;
  /** 核采样概率 */
  readonly topP: number;
  /** 最大生成 token 数 */
  readonly maxTokens: number;
  /** 是否流式请求 */
  readonly stream: boolean;
  /**
   * 思考强度(可选):
   * - '' 跟随 Provider 默认(不发送 reasoning_effort 字段)
   * - 'none' 关闭思考
   * - 'low' / 'medium' / 'high' 三档
   * Provider 不支持时自动忽略。
   */
  readonly reasoningEffort?: string;
  /**
   * 是否强制 JSON 输出模式(可选):
   * - true 时向 OpenAI-compatible Provider 发送 response_format={type:"json_object"}
   * - Provider 不支持时自动忽略
   * - 要求 prompt 中必须包含 "JSON" 字样,否则部分 Provider 会报错
   */
  readonly responseFormatJson?: boolean;
}

/**
 * 聊天请求模型。
 */
export interface ChatRequest {
  /** 模型名称 */
  readonly model: string;
  /** 消息列表(顺序保持不变) */
  readonly messages: ChatMessage[];
  /** 采样温度 */
  readonly temperature: number;
  /** 核采样概率 */
  readonly topP: number;
  /** 最大生成 token 数 */
  readonly maxTokens: number;
  /** 是否流式请求 */
  readonly stream: boolean;
  /**
   * 思考强度(可选):
   * - '' 或 undefined 跟随 Provider 默认(不发送 reasoning_effort 字段)
   * - 'none' 关闭思考
   * - 'low' / 'medium' / 'high' 三档
   * Provider 不支持时自动忽略。
   */
  readonly reasoningEffort?: string;
  /**
   * 是否强制 JSON 输出模式(可选):
   * - true 时向 OpenAI-compatible Provider 发送 response_format={type:"json_object"}
   * - Provider 不支持时自动忽略
   */
  readonly responseFormatJson?: boolean;
}

/**
 * 创建聊天请求,带安全默认值。
 * @param model 模型名称
 * @param messages 消息列表
 * @returns ChatRequest 实例
 */
export function createChatRequest(
  model: string,
  messages: ChatMessage[]
): ChatRequest {
  return {
    model: model,
    messages: messages,
    temperature: TEMPERATURE_DEFAULT,
    topP: TOP_P_DEFAULT,
    maxTokens: MAX_TOKENS_DEFAULT,
    stream: true
  };
}
