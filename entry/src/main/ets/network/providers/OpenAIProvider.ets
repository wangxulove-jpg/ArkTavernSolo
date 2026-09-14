/**
 * OpenAIProvider OpenAI-compatible 非流式 Provider
 *
 * 实现 OpenAI Chat Completions 非流式请求。
 * 通过依赖注入获得 HttpClient 和 ProviderKeyStore,不直接依赖平台 API。
 *
 * 设计原则:
 * - 不缓存 API Key,每次请求前从 ProviderKeyStore 读取
 * - 请求完成后不保留 Key 引用
 * - 不保存 Config 到成员变量
 * - 不创建全局单例
 * - 不依赖页面或 ViewModel
 * - 不直接读 Preferences
 *
 * 安全要求:
 * - API Key 只在运行时构造 Header,不保存到成员变量
 * - 不记录完整 Header、Authorization、请求 Body、响应原文
 * - 不把 API Key 放入错误对象
 * - 最多记录 host(不含查询参数)
 *
 * URL 规则:
 * - 复用 OpenAiUrlBuilder
 * - 不复制第二套 URL 拼接逻辑
 * - URL 校验失败映射为 InvalidRequest
 *
 * 请求体:
 * - stream 强制为 false
 * - 即使传入 request.stream=true,也不发送流式请求
 * - 消息顺序保持不变
 * - content 不被 trim 或修改
 * - 不添加 SillyTavern Prompt / Character / Lorebook / tools / extra_body
 */

import { ProviderConfig, isValidTemperature, isValidTopP, isValidMaxTokens } from '../../models/ProviderConfig';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatResponse, createChatResponse, ChatResponseOptions } from '../../models/ChatResponse';
import { NetworkError, NetworkErrorType, createNetworkError, errorTypeFromStatusCode } from '../../models/NetworkError';
import { HttpClient, HttpMethod, HttpRequestOptions, HttpResponse, HttpHeaders } from '../core/HttpClient';
import { ProviderKeyStore } from '../../storage/ProviderKeyStore';
import { AiProvider } from './AiProvider';
import {
  OpenAIChatRequestBody,
  OpenAIRequestMessage,
  OpenAIChatResponseBody,
  OpenAIResponseFormat,
  roleToString,
  extractResponseBody,
  extractErrorDetail,
  truncateErrorMessage
} from './OpenAITypes';
import { buildChatCompletionsUrl, buildModelsUrl, UrlBuildResult } from '../streaming/OpenAiUrlBuilder';
import { Logger } from '../../utils/Logger';
import { ModelListItem } from '../../models/ModelListResult';
import {
  ChatStreamCallbacks,
  ChatStreamHandle
} from '../../models/ChatStreamTypes';
import { OpenAIStreamSession, StreamLauncher } from './OpenAIStreamSession';
/** 日志标签 */
const LOG_TAG: string = 'OpenAIProvider';

/**
 * OpenAI-compatible Provider(非流式 + 流式)。
 *
 * 构造时注入 HttpClient(非流式)、ProviderKeyStore(密钥)和可选的 streamLauncher(流式)。
 * 不内部 new 任何平台实现。
 *
 * streamLauncher 可选:未提供时 streamChat 抛 NotSupported。
 * 这样非流式场景(T-1.4)不需要注入流式传输层。
 */
export class OpenAIProvider extends AiProvider {
  private readonly httpClient: HttpClient;
  private readonly providerKeyStore: ProviderKeyStore;
  private readonly streamLauncher: StreamLauncher | null;

  /**
   * 构造 OpenAIProvider。
   *
   * @param httpClient HTTP 客户端抽象(如 HarmonyHttpClient)
   * @param providerKeyStore Provider 密钥管理
   * @param streamLauncher 流式请求发起函数(可选,流式场景需要)
   *        设备代码示例:
   *        const transport = new HttpStreamTransport();
   *        const provider = new OpenAIProvider(httpClient, keyStore,
   *          (opts, cbs) => transport.requestStream(opts, cbs));
   */
  constructor(
    httpClient: HttpClient,
    providerKeyStore: ProviderKeyStore,
    streamLauncher?: StreamLauncher
  ) {
    super();
    this.httpClient = httpClient;
    this.providerKeyStore = providerKeyStore;
    this.streamLauncher = streamLauncher !== undefined ? streamLauncher : null;
  }

  supportsToolCalling(): boolean {
    return false;
  }

  async fetchModels(baseUrl: string, apiKey: string): Promise<ModelListItem[]> {
    const urlResult: UrlBuildResult = buildModelsUrl(baseUrl);
    if (!urlResult.success) {
      throw createNetworkError(
        NetworkErrorType.InvalidRequest,
        urlResult.error,
        { retryable: false }
      );
    }

    const headers: HttpHeaders = new Map<string, string>();
    headers.set('Accept', 'application/json');
    headers.set('Authorization', 'Bearer ' + apiKey);

    const options: HttpRequestOptions = {
      method: HttpMethod.GET,
      url: urlResult.url,
      headers: headers,
      connectTimeoutMs: 15000,
      readTimeoutMs: 30000
    };

    const response: HttpResponse = await this.httpClient.request(options);

    if (response.statusCode === 401) {
      throw createNetworkError(
        NetworkErrorType.Authentication,
        'Authentication failed',
        { retryable: false, statusCode: 401 }
      );
    }

    if (response.statusCode >= 400) {
      throw createNetworkError(
        errorTypeFromStatusCode(response.statusCode),
        'Models request failed: ' + response.statusCode.toString(),
        { retryable: response.statusCode >= 500, statusCode: response.statusCode }
      );
    }

    const body: string = response.body;
    if (body.length === 0) {
      return [];
    }

    const models: ModelListItem[] = parseModelsResponse(body);
    return models;
  }

  /**
   * 发送非流式聊天请求。
   *
   * 流程:
   * 1. 校验 config 和 request
   * 2. 从 ProviderKeyStore 读取 API Key
   * 3. 构造 URL(复用 OpenAiUrlBuilder)
   * 4. 构造请求体(强制 stream=false)
   * 5. 构造 Header(含 Authorization: Bearer)
   * 6. 通过 HttpClient 发起 POST 请求
   * 7. 解析响应并返回 ChatResponse
   * 8. 映射 HTTP/网络/解析错误为 NetworkError
   *
   * @param config Provider 配置
   * @param request 聊天请求
   * @returns 聊天响应
   * @throws NetworkError 当 API Key 不存在、网络错误、鉴权失败、解析失败时
   */
  async sendChat(config: ProviderConfig, request: ChatRequest): Promise<ChatResponse> {
    // 1. 校验请求
    const validationError: NetworkError | null = validateRequest(request);
    if (validationError !== null) {
      // 显式赋值确保类型为 NetworkError(非 null),满足 arkts-limited-throw
      const err: NetworkError = validationError;
      throw err;
    }

    // 2. 读取 API Key
    const apiKey: string | null = await this.providerKeyStore.readKey(config.id);
    if (apiKey === null) {
      Logger.warn(LOG_TAG, 'API Key not found providerId=' + config.id);
      throw createNetworkError(
        NetworkErrorType.Authentication,
        'API Key not configured for provider ' + config.id
      );
    }
    if (apiKey.trim().length === 0) {
      Logger.warn(LOG_TAG, 'API Key is empty providerId=' + config.id);
      throw createNetworkError(
        NetworkErrorType.Authentication,
        'API Key is empty for provider ' + config.id
      );
    }

    // 3. 构造 URL
    const urlResult = buildChatCompletionsUrl(config.baseUrl);
    if (!urlResult.success) {
      Logger.warn(LOG_TAG, 'URL build failed providerId=' + config.id);
      throw createNetworkError(
        NetworkErrorType.InvalidRequest,
        'Invalid base URL: ' + urlResult.error
      );
    }

    // 4. 构造请求体(强制 stream=false)
    const body: string = buildRequestBody(request);

    // 5. 构造 Header
    const headers: HttpHeaders = buildHeaders(apiKey);

    // 6. 发起请求
    const options: HttpRequestOptions = {
      method: HttpMethod.POST,
      url: urlResult.url,
      headers: headers,
      body: body,
      connectTimeoutMs: 30000,
      readTimeoutMs: 60000
    };

    let response: HttpResponse;
    try {
      response = await this.httpClient.request(options);
    } catch (e) {
      // HttpClient 已将错误转换为 NetworkError,此处重新抛出
      if (e instanceof NetworkError) {
        throw e;
      }
      // 兜底:不应发生,HttpClient 始终 reject NetworkError
      throw createNetworkError(
        NetworkErrorType.Unknown,
        'Unexpected error from HttpClient',
        { causeMessage: String(e) }
      );
    }

    // 7. 解析响应
    return parseResponse(response, config.id);
  }

  /**
   * 发送流式聊天请求,通过回调增量返回内容。
   *
   * 流程(异步执行,streamChat 同步返回 ChatStreamHandle):
   * 1. 立即创建 OpenAIStreamSession 并返回(调用方可立即 abort)
   * 2. 校验 streamLauncher 不为 null
   * 3. 校验 request(复用 validateRequest)
   * 4. 从 ProviderKeyStore 读取 API Key
   * 5. 构造 URL(复用 buildChatCompletionsUrl)
   * 6. 构造请求体(强制 stream=true,复用 buildRequestBody(request, true))
   * 7. 构造 Header(复用 buildHeaders)
   * 8. 调用 session.start() 启动流式请求
   * 9. 任一步骤失败 → 调用 session.failBeforeStart(callbacks, error)
   *
   * 安全要求:
   * - API Key 只在构造 Header 时使用,不保存到成员变量
   * - 请求完成后不保留 Key 引用
   * - 不记录 API Key、Authorization、请求 Body、完整回复
   *
   * @param config Provider 配置
   * @param request 聊天请求
   * @param callbacks 流式回调
   * @returns 流式请求句柄(可立即用于 abort)
   */
  streamChat(
    config: ProviderConfig,
    request: ChatRequest,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    // 立即创建 session 并返回(调用方可立即 abort)
    const session: OpenAIStreamSession = new OpenAIStreamSession();

    // 异步执行校验、读 Key、构造请求、启动 session
    this.startStreamAsync(config, request, callbacks, session);

    return session;
  }

  /**
   * streamChat 的异步执行体。
   * 分离出来以保持 streamChat 同步返回 handle 的契约。
   */
  private async startStreamAsync(
    config: ProviderConfig,
    request: ChatRequest,
    callbacks: ChatStreamCallbacks,
    session: OpenAIStreamSession
  ): Promise<void> {
    // 1. 校验 streamLauncher
    if (this.streamLauncher === null) {
      session.failBeforeStart(callbacks, createNetworkError(
        NetworkErrorType.Unknown,
        'Stream launcher not configured for this provider'
      ));
      return;
    }
    const launcher: StreamLauncher = this.streamLauncher;

    // 2. 校验 request(复用 validateRequest)
    const validationError: NetworkError | null = validateRequest(request);
    if (validationError !== null) {
      session.failBeforeStart(callbacks, validationError);
      return;
    }

    // 3. 读取 API Key
    let apiKey: string | null;
    try {
      apiKey = await this.providerKeyStore.readKey(config.id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'readKey failed providerId=' + config.id);
      session.failBeforeStart(callbacks, createNetworkError(
        NetworkErrorType.Authentication,
        'Failed to read API Key for provider ' + config.id
      ));
      return;
    }
    if (apiKey === null) {
      Logger.warn(LOG_TAG, 'API Key not found providerId=' + config.id);
      session.failBeforeStart(callbacks, createNetworkError(
        NetworkErrorType.Authentication,
        'API Key not configured for provider ' + config.id
      ));
      return;
    }
    if (apiKey.trim().length === 0) {
      Logger.warn(LOG_TAG, 'API Key is empty providerId=' + config.id);
      session.failBeforeStart(callbacks, createNetworkError(
        NetworkErrorType.Authentication,
        'API Key is empty for provider ' + config.id
      ));
      return;
    }

    // 4. 构造 URL
    const urlResult = buildChatCompletionsUrl(config.baseUrl);
    if (!urlResult.success) {
      Logger.warn(LOG_TAG, 'URL build failed providerId=' + config.id);
      session.failBeforeStart(callbacks, createNetworkError(
        NetworkErrorType.InvalidRequest,
        'Invalid base URL: ' + urlResult.error
      ));
      return;
    }

    // 5. 构造请求体(强制 stream=true)
    const body: string = buildRequestBody(request, true);

    // 6. 构造 Header(API Key 只在此处运行时使用)
    const headers: HttpHeaders = buildHeaders(apiKey);

    // 7. 启动 session(如果 session 已被 abort,start 会直接返回)
    session.start(urlResult.url, body, headers, callbacks, launcher);

    // 8. 释放 Key 引用(局部变量随函数结束被回收)
    // apiKey 不保存到成员变量,此处无需显式置空
  }
}

// ===== 请求校验与构建 =====

/**
 * 校验 ChatRequest。
 *
 * 校验规则:
 * - messages 非空
 * - model 非空
 * - temperature 合法
 * - topP 合法
 * - maxTokens 合法
 *
 * @param request 聊天请求
 * @returns 校验失败返回 NetworkError,通过返回 null
 */
export function validateRequest(request: ChatRequest): NetworkError | null {
  if (request.model.length === 0) {
    return createNetworkError(
      NetworkErrorType.InvalidRequest,
      'Model name is empty'
    );
  }
  if (request.messages.length === 0) {
    return createNetworkError(
      NetworkErrorType.InvalidRequest,
      'Messages array is empty'
    );
  }
  if (!isValidTemperature(request.temperature)) {
    return createNetworkError(
      NetworkErrorType.InvalidRequest,
      'Invalid temperature: ' + request.temperature.toString()
    );
  }
  if (!isValidTopP(request.topP)) {
    return createNetworkError(
      NetworkErrorType.InvalidRequest,
      'Invalid topP: ' + request.topP.toString()
    );
  }
  if (!isValidMaxTokens(request.maxTokens)) {
    return createNetworkError(
      NetworkErrorType.InvalidRequest,
      'Invalid maxTokens: ' + request.maxTokens.toString()
    );
  }
  return null;
}

/**
 * 构建请求体 JSON 字符串。
 * 默认强制 stream=false(非流式);传入 forceStream=true 时强制 stream=true(流式)。
 * 即使传入 request.stream 值不同,也以 forceStream 参数为准。
 *
 * 请求体结构:
 * {
 *   "model": "...",
 *   "messages": [{ "role": "...", "content": "..." }],
 *   "temperature": 0.7,
 *   "top_p": 1.0,
 *   "max_tokens": 1024,
 *   "stream": false | true,
 *   "tools": [...] (可选, Phase 4A-3),
 *   "tool_choice": "auto" (可选, 当 tools 非空时)
 * }
 *
 * Phase 4A-3 工具结果回传:
 * - request.priorToolCalls 非空时, 追加一条 assistant 消息 (含 tool_calls 字段)
 * - request.toolResults 非空时, 每条结果追加一条 role:"tool" 消息
 *
 * @param request 聊天请求
 * @param forceStream 强制 stream 值(默认 false)
 * @returns JSON 字符串
 */
export function buildRequestBody(request: ChatRequest, forceStream: boolean = false): string {
  const messages: OpenAIRequestMessage[] = [];
  for (let i = 0; i < request.messages.length; i++) {
    const msg = request.messages[i];
    messages.push({
      role: roleToString(msg.role),
      content: msg.content
    });
  }

  const effort: string | undefined = request.reasoningEffort;
  const hasEffort: boolean = effort !== undefined && effort.length > 0;
  const hasJsonFormat: boolean = request.responseFormatJson === true;
  const responseFormat: OpenAIResponseFormat | undefined = hasJsonFormat
    ? { type: 'json_object' }
    : undefined;

  if (hasEffort && hasJsonFormat) {
    const requestBody: OpenAIChatRequestBody = {
      model: request.model,
      messages: messages,
      temperature: request.temperature,
      top_p: request.topP,
      max_tokens: request.maxTokens,
      stream: forceStream,
      reasoning_effort: effort as string,
      response_format: responseFormat as OpenAIResponseFormat
    };
    return JSON.stringify(requestBody);
  }

  if (hasEffort) {
    const requestBody: OpenAIChatRequestBody = {
      model: request.model,
      messages: messages,
      temperature: request.temperature,
      top_p: request.topP,
      max_tokens: request.maxTokens,
      stream: forceStream,
      reasoning_effort: effort as string
    };
    return JSON.stringify(requestBody);
  }

  if (hasJsonFormat) {
    const requestBody: OpenAIChatRequestBody = {
      model: request.model,
      messages: messages,
      temperature: request.temperature,
      top_p: request.topP,
      max_tokens: request.maxTokens,
      stream: forceStream,
      response_format: responseFormat as OpenAIResponseFormat
    };
    return JSON.stringify(requestBody);
  }

  const requestBody: OpenAIChatRequestBody = {
    model: request.model,
    messages: messages,
    temperature: request.temperature,
    top_p: request.topP,
    max_tokens: request.maxTokens,
    stream: forceStream
  };

  return JSON.stringify(requestBody);
}

/**
 * 构建请求头。
 * API Key 只在此处运行时构造,不保存到成员变量。
 *
 * @param apiKey API Key 明文
 * @returns 请求头 Map
 */
export function buildHeaders(apiKey: string): HttpHeaders {
  const headers: HttpHeaders = new Map<string, string>();
  headers.set('Content-Type', 'application/json');
  headers.set('Accept', 'application/json');
  headers.set('Authorization', 'Bearer ' + apiKey);
  return headers;
}

// ===== 响应解析 =====

/**
 * 解析 HTTP 响应并返回 ChatResponse。
 *
 * 解析规则:
 * - 2xx:解析 JSON 响应体,提取 content/finishReason/model/usage/id
 * - 401/403:Authentication
 * - 408:Timeout
 * - 429:RateLimit
 * - 400:InvalidRequest
 * - 404:InvalidRequest
 * - 500~599:Server
 * - 其他非 2xx:按状态码映射
 *
 * @param response HTTP 响应
 * @param providerId Provider ID(仅用于日志)
 * @returns 聊天响应
 * @throws NetworkError 当 HTTP 状态码非 2xx 或响应解析失败时
 */
export function parseResponse(response: HttpResponse, providerId: string): ChatResponse {
  const statusCode: number = response.statusCode;

  // 2xx 成功
  if (statusCode >= 200 && statusCode < 300) {
    return parseSuccessResponse(response.body, providerId);
  }

  // 非 2xx,映射为错误
  throw mapHttpError(statusCode, response.body);
}

/**
 * 解析成功的响应体。
 *
 * @param responseBody 响应体字符串
 * @param providerId Provider ID(仅用于日志)
 * @returns 聊天响应
 * @throws NetworkError 当 JSON 解析失败或响应结构不符合预期时
 */
function parseSuccessResponse(responseBody: string, providerId: string): ChatResponse {
  // 尝试 JSON 解析
  let parsed: Object;
  try {
    parsed = JSON.parse(responseBody);
  } catch (e) {
    Logger.error(LOG_TAG, 'JSON parse failed providerId=' + providerId);
    throw createNetworkError(
      NetworkErrorType.Parse,
      'Failed to parse response JSON'
    );
  }

  // 安全提取响应体
  const result = extractResponseBody(parsed);
  if (!result.success || result.body === undefined) {
    // 检查是否为错误响应体
    if (result.isErrorBody === true) {
      const truncatedMsg: string = truncateErrorMessage(result.error);
      throw createNetworkError(
        NetworkErrorType.Server,
        'Server returned error in 2xx response: ' + truncatedMsg,
        { causeMessage: result.error }
      );
    }
    // 可观测性:失败时打印原始响应体(截断),便于定位服务商响应结构差异(Gemini 等)
    Logger.error(LOG_TAG, 'Response extraction failed providerId=' + providerId + ' error=' + result.error
      + ' body=' + truncateErrorMessage(responseBody, 2000));
    throw createNetworkError(
      NetworkErrorType.Parse,
      'Invalid response structure: ' + result.error
    );
  }

  const body: OpenAIChatResponseBody = result.body;
  const firstChoice = body.choices[0];

  // 构建 ChatResponse(一次性构造 options,不依赖可变字段)
  const finishReason: string | undefined = firstChoice.finish_reason.length > 0
    ? firstChoice.finish_reason
    : undefined;
  const model: string | undefined = body.model.length > 0 ? body.model : undefined;
  const requestId: string | undefined = body.id.length > 0 ? body.id : undefined;

  let promptTokens: number | undefined = undefined;
  let completionTokens: number | undefined = undefined;
  let totalTokens: number | undefined = undefined;
  let cachedTokens: number | undefined = undefined;
  if (body.usage !== undefined) {
    promptTokens = body.usage.prompt_tokens;
    completionTokens = body.usage.completion_tokens;
    totalTokens = body.usage.total_tokens;
    cachedTokens = body.usage.cached_tokens;
  }

  const options: ChatResponseOptions = {
    finishReason: finishReason,
    model: model,
    providerRequestId: requestId,
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    totalTokens: totalTokens,
    cachedTokens: cachedTokens
  };

  return createChatResponse(firstChoice.message.content, options);
}

/**
 * 将 HTTP 错误状态码映射为 NetworkError。
 *
 * @param statusCode HTTP 状态码
 * @param responseBody 响应体(可能包含服务端错误详情)
 * @returns 网络错误对象
 */
export function mapHttpError(statusCode: number, responseBody: string): NetworkError {
  const errorType: NetworkErrorType = errorTypeFromStatusCode(statusCode);

  // 尝试从响应体提取服务端错误消息
  let serverMessage: string | undefined = undefined;
  let providerCode: string | undefined = undefined;
  if (responseBody.length > 0) {
    try {
      const parsed: Object = JSON.parse(responseBody);
      // 安全检查:JSON.parse 可能返回非对象(如 number/string/null)
      if (parsed !== null && typeof parsed === 'object') {
        const errorDetail = extractErrorDetail(parsed as Record<string, Object>);
        if (errorDetail !== null) {
          serverMessage = truncateErrorMessage(errorDetail.message);
          if (errorDetail.code !== undefined) {
            providerCode = errorDetail.code;
          }
        }
      } else {
        // 非 JSON 对象(如纯字符串/数字),截断作为 causeMessage
        serverMessage = truncateErrorMessage(responseBody);
      }
    } catch (e) {
      // 非 JSON 响应,使用截断的原始响应体作为 causeMessage
      if (responseBody.length > 0) {
        serverMessage = truncateErrorMessage(responseBody);
      }
    }
  }

  const message: string = serverMessage !== undefined
    ? 'HTTP ' + statusCode.toString() + ': ' + serverMessage
    : 'HTTP ' + statusCode.toString();

  return createNetworkError(
    errorType,
    message,
    {
      statusCode: statusCode,
      providerCode: providerCode,
      causeMessage: serverMessage
    }
  );
}

function parseModelsResponse(body: string): ModelListItem[] {
  let parsed: Object;
  try {
    parsed = JSON.parse(body);
  } catch (_e) {
    return [];
  }

  const record: Record<string, Object> = parsed as Record<string, Object>;
  const dataObj: Object | undefined = record['data'];
  if (dataObj === undefined || dataObj === null) {
    return [];
  }

  const dataArr: Object[] = dataObj as Object[];
  const result: ModelListItem[] = [];
  for (let i = 0; i < dataArr.length; i++) {
    const item: Record<string, Object> = dataArr[i] as Record<string, Object>;
    const idObj: Object | undefined = item['id'];
    if (idObj === undefined || idObj === null) {
      continue;
    }
    const id: string = idObj as string;
    if (id.length === 0) {
      continue;
    }
    const ownedByObj: Object | undefined = item['owned_by'];
    const ownedBy: string = (ownedByObj !== undefined && ownedByObj !== null)
      ? ownedByObj as string
      : '';
    const listItem: ModelListItem = { id: id, ownedBy: ownedBy };
    result.push(listItem);
  }
  return result;
}
