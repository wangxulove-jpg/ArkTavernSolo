/**
 * OpenAiUrlBuilder OpenAI URL 组合与请求体构建
 *
 * 安全的 URL 组合逻辑,处理用户输入的各种 Base URL 格式。
 * 构建最小 OpenAI-compatible Chat Completions 请求体。
 *
 * 纯逻辑实现,不依赖设备 API,可在本地单元测试运行。
 * 不使用 any,所有类型明确。
 * 不硬编码服务商域名,不包含 API Key。
 */

/** 聊天消息角色 */
export type ChatRole = 'user' | 'assistant' | 'system';

/** 聊天消息 */
export interface ChatMessage {
  readonly role: ChatRole;
  readonly content: string;
}

/** Chat Completions 请求体 */
export interface ChatCompletionsRequest {
  readonly model: string;
  readonly messages: ChatMessage[];
  readonly stream: boolean;
  readonly temperature: number;
}

/** URL 构建结果 */
export interface UrlBuildResult {
  /** 是否成功 */
  readonly success: boolean;
  /** 构建后的完整 URL(失败时为空字符串) */
  readonly url: string;
  /** 错误信息(成功时为空字符串) */
  readonly error: string;
}

/** /chat/completions 路径后缀 */
const CHAT_COMPLETIONS_SUFFIX: string = '/chat/completions';
/** /models 路径后缀 */
const MODELS_SUFFIX: string = '/models';
/** /v1 路径后缀 */
const V1_SUFFIX: string = '/v1';

/**
 * 构建完整的 Chat Completions URL。
 *
 * 处理规则:
 * 1. 去除首尾空格和末尾 /
 * 2. 如果已以 /chat/completions 结尾,不重复追加
 * 3. 如果以 /v1 结尾,追加 /chat/completions
 * 4. 其他情况,追加 /v1/chat/completions
 * 5. 仅允许 http 或 https 协议
 * 6. 不硬编码服务商域名
 *
 * @param baseUrl 用户输入的 Base URL
 * @returns 构建结果
 */
export function buildChatCompletionsUrl(baseUrl: string): UrlBuildResult {
  const url: string = baseUrl.trim();

  if (url.length === 0) {
    return { success: false, url: '', error: 'Base URL is empty' };
  }

  // 检查协议(大小写不敏感)
  const lowerUrl: string = url.toLowerCase();
  if (!lowerUrl.startsWith('http://') && !lowerUrl.startsWith('https://')) {
    return { success: false, url: '', error: 'Only http or https protocol is allowed' };
  }

  // 去除末尾 / (可能有多个)
  let cleaned: string = url;
  while (cleaned.length > 0 && cleaned.charAt(cleaned.length - 1) === '/') {
    cleaned = cleaned.substring(0, cleaned.length - 1);
  }

  if (cleaned.length === 0) {
    return { success: false, url: '', error: 'Base URL is empty after trimming' };
  }

  // 如果已以 /chat/completions 结尾,直接返回
  if (cleaned.endsWith(CHAT_COMPLETIONS_SUFFIX)) {
    return { success: true, url: cleaned, error: '' };
  }

  // 如果以 /v1 结尾,追加 /chat/completions
  if (cleaned.endsWith(V1_SUFFIX)) {
    return { success: true, url: cleaned + CHAT_COMPLETIONS_SUFFIX, error: '' };
  }

  // 其他情况,追加 /v1/chat/completions
  return { success: true, url: cleaned + V1_SUFFIX + CHAT_COMPLETIONS_SUFFIX, error: '' };
}

/**
 * 构建最小 OpenAI-compatible Chat Completions 请求体 JSON 字符串。
 *
 * 请求体结构:
 * {
 *   "model": "<model>",
 *   "messages": [{ "role": "user", "content": "<message>" }],
 *   "stream": true,
 *   "temperature": 0.7
 * }
 *
 * 不增加 SillyTavern Prompt、角色卡、世界书、宏替换、tools/function calling、图像或音频。
 *
 * @param model 模型名称
 * @param userMessage 用户测试消息
 * @returns JSON 字符串
 */
export function buildChatCompletionsBody(model: string, userMessage: string): string {
  const messages: ChatMessage[] = [
    { role: 'user', content: userMessage }
  ];
  const requestBody: ChatCompletionsRequest = {
    model: model,
    messages: messages,
    stream: true,
    temperature: 0.7
  };
  return JSON.stringify(requestBody);
}

export function buildModelsUrl(baseUrl: string): UrlBuildResult {
  const url: string = baseUrl.trim();

  if (url.length === 0) {
    return { success: false, url: '', error: 'Base URL is empty' };
  }

  const lowerUrl: string = url.toLowerCase();
  if (!lowerUrl.startsWith('http://') && !lowerUrl.startsWith('https://')) {
    return { success: false, url: '', error: 'Only http or https protocol is allowed' };
  }

  let cleaned: string = url;
  while (cleaned.length > 0 && cleaned.charAt(cleaned.length - 1) === '/') {
    cleaned = cleaned.substring(0, cleaned.length - 1);
  }

  if (cleaned.length === 0) {
    return { success: false, url: '', error: 'Base URL is empty after trimming' };
  }

  if (cleaned.endsWith(MODELS_SUFFIX)) {
    return { success: true, url: cleaned, error: '' };
  }

  if (cleaned.endsWith(V1_SUFFIX)) {
    return { success: true, url: cleaned + MODELS_SUFFIX, error: '' };
  }

  return { success: true, url: cleaned + V1_SUFFIX + MODELS_SUFFIX, error: '' };
}
