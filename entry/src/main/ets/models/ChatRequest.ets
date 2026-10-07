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
 * - audio
 * - SillyTavern Prompt
 * - Character / Lorebook
 *
 * 视觉输入(可选):
 * - 仅 `imageDataUrls` 一个字段,语义 = **附加到最后一条 user 消息**的图片(data URL 列表)。
 * - 只有"非流式一次性任务"(如本地图片 AI 命名)走 `ModelService.sendChat(request)` 时才会带上;
 *   `ChatRequestOptions` 与流式路径不承载该字段(聊天主链路不带图)。
 * - Provider 侧只在字段非空时把该条消息的 content 从字符串改写为内容块数组。
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
  /**
   * 视觉输入(可选):附加到**最后一条 user 消息**的图片 data URL 列表。
   *
   * - 空 / undefined:行为与改造前完全一致(消息 content 仍为字符串)
   * - 非空:该条 user 消息的 content 改写为内容块数组(文本块 + 图片块)
   * - 若最后一条消息不是 user,Provider 返回 InvalidRequest(图片只能放 user 消息;
   *   DeepSeek / OpenAI 兼容端点均要求图片位于 user 消息)
   */
  readonly imageDataUrls?: string[];
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
