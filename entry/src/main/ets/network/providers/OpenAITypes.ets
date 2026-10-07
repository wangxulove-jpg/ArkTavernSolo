/**
 * OpenAITypes OpenAI Chat Completions 类型定义与安全解析
 *
 * 定义 OpenAI-compatible Chat Completions 的请求体、响应体、错误体结构,
 * 并提供从 JSON.parse 结果安全提取字段的类型守卫与辅助函数。
 *
 * 安全要求:
 * - JSON.parse 结果不能直接断言为接口,必须通过类型守卫或安全提取函数访问字段
 * - 不使用 any
 * - 不使用 as unknown as Xxx 逃避校验
 * - 不引入第三方 JSON schema 库
 * - 解析逻辑不放入页面或 NetworkError
 *
 * 纯逻辑实现,不依赖设备 API,可在本地单元测试运行。
 */

import { ChatRole } from '../../models/ChatRole';

// ===== 请求体类型定义 =====

/**
 * OpenAI 图片块里的 image_url 对象。
 *
 * detail 为可选:
 * - 'low':服务端先降采样(如 512×512),更快更省 token
 * - 'high' / 'original' / 'auto':保留原图
 * - 非视觉端点会忽略该字段
 */
export interface OpenAIImageUrl {
  readonly url: string;
  readonly detail?: string;
}

/**
 * OpenAI 多模态内容块(仅用于带图片的消息)。
 *
 * 注意:ArkTS 严格模式下"对象字面量赋给 interface 联合类型"不可用,
 * 故这里用**单接口 + 可选字段**,由 `type` 决定哪些字段有效:
 * - type='text'      → text 有效
 * - type='image_url' → image_url 有效
 * JSON.stringify 会丢弃 undefined 字段,不会产出脏键。
 */
export interface OpenAIContentPart {
  readonly type: string;
  readonly text?: string;
  readonly image_url?: OpenAIImageUrl;
}

/**
 * OpenAI Chat Completions 请求消息。
 *
 * Phase 4A-3 扩展:
 * - tool_calls: 仅 role="assistant" 时使用, 回传上一轮 AI 的工具调用
 * - tool_call_id: 仅 role="tool" 时使用, 关联到对应 tool_calls.id
 *
 * 视觉扩展:
 * - content 为 string(纯文本,默认,聊天主链路)
 * - content 为 OpenAIContentPart[](该消息带图片时,仅用户主动触发的视觉任务)
 */
export interface OpenAIRequestMessage {
  readonly role: string;
  readonly content: string | OpenAIContentPart[];
  readonly tool_calls?: Object[];
  readonly tool_call_id?: string;
}

/**
 * OpenAI response_format 对象(仅支持 json_object 类型)。
 */
export interface OpenAIResponseFormat {
  readonly type: string;
}

/**
 * OpenAI Chat Completions 非流式请求体。
 * stream 强制为 false。
 *
 * reasoning_effort 为可选字段:
 * - undefined / '':不发送该字段(跟随 Provider 默认)
 * - 'none' / 'low' / 'medium' / 'high':发送对应档位
 *
 * response_format 为可选字段:
 * - undefined:不发送该字段
 * - {type: "json_object"}:强制 JSON 输出模式
 *
 * Phase 4A-3:
 * - tools: 可选, 工具定义数组 (Provider Adapter 转换后注入)
 * - tool_choice: 可选, "auto" / "none" / {type:"function", function:{name}}
 *                当 tools 非空时, 默认发送 "auto"
 */
export interface OpenAIChatRequestBody {
  readonly model: string;
  readonly messages: OpenAIRequestMessage[];
  readonly temperature: number;
  readonly top_p: number;
  readonly max_tokens: number;
  readonly stream: boolean;
  readonly reasoning_effort?: string;
  readonly response_format?: OpenAIResponseFormat;
  readonly tools?: Object[];
  readonly tool_choice?: string;
}

/**
 * OpenAI tool_calls 中的 function 对象 (Phase 4A-3)。
 */
export interface OpenAIToolCallFunctionPayload {
  readonly name: string;
  readonly arguments: string;
}

/**
 * OpenAI tool_calls 数组中的对象 (Phase 4A-3)。
 */
export interface OpenAIToolCallPayload {
  readonly id: string;
  readonly type: string;
  readonly function: OpenAIToolCallFunctionPayload;
}

/**
 * OpenAI tools 数组中的 function 对象 (Phase 4A-3)。
 */
export interface OpenAIToolDefFunctionPayload {
  readonly name: string;
  readonly description: string;
  readonly parameters: Object;
}

/**
 * OpenAI tools 数组中的对象 (Phase 4A-3)。
 */
export interface OpenAIToolDefPayload {
  readonly type: string;
  readonly function: OpenAIToolDefFunctionPayload;
}

// ===== 响应体类型定义 =====

/**
 * OpenAI Chat Completions 响应中的 message 对象。
 */
export interface OpenAIResponseMessage {
  readonly role: string;
  readonly content: string;
}

/**
 * OpenAI Chat Completions 响应中的 choice 对象。
 */
export interface OpenAIChoice {
  readonly index: number;
  readonly message: OpenAIResponseMessage;
  readonly finish_reason: string;
}

/**
 * OpenAI Chat Completions 响应中的 usage 对象。
 */
export interface OpenAIUsage {
  readonly prompt_tokens: number;
  readonly completion_tokens: number;
  readonly total_tokens: number;
  readonly cached_tokens?: number;
}

/**
 * OpenAI Chat Completions 标准响应体。
 */
export interface OpenAIChatResponseBody {
  readonly id: string;
  readonly model: string;
  readonly choices: OpenAIChoice[];
  readonly usage?: OpenAIUsage;
}

// ===== 错误响应类型定义 =====

/**
 * OpenAI 错误响应中的 error 详情对象。
 */
export interface OpenAIErrorDetail {
  readonly message: string;
  readonly type?: string;
  readonly code?: string;
}

/**
 * OpenAI 错误响应体。
 */
export interface OpenAIErrorBody {
  readonly error: OpenAIErrorDetail;
}

// ===== 安全提取辅助函数 =====

/**
 * 判断值是否为非 null 对象。
 * @param val 待检查的值
 * @returns 是非 null 对象返回 true
 */
function isObject(val: Object): boolean {
  return val !== null && typeof val === 'object';
}

/**
 * 安全获取 Record<string, Object> 的字符串属性。
 * @param obj 目标对象
 * @param key 属性名
 * @returns 属性值字符串;属性不存在或非字符串则返回 undefined
 */
function getStringField(obj: Record<string, Object>, key: string): string | undefined {
  const val: Object | undefined = obj[key];
  if (val === undefined || val === null) {
    return undefined;
  }
  if (typeof val === 'string') {
    return val;
  }
  return undefined;
}

/**
 * 安全获取 Record<string, Object> 的数字属性。
 * @param obj 目标对象
 * @param key 属性名
 * @returns 属性值数字;属性不存在或非数字则返回 undefined
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
 * @param obj 目标对象
 * @param key 属性名
 * @returns 属性值 Record;属性不存在或非对象则返回 null
 */
function getObjectField(obj: Record<string, Object>, key: string): Record<string, Object> | null {
  const val: Object | undefined = obj[key];
  if (val === undefined || val === null) {
    return null;
  }
  if (!isObject(val)) {
    return null;
  }
  return val as Record<string, Object>;
}

/**
 * 安全获取 choices 数组。
 * @param obj 目标对象
 * @returns choices 数组(Object[]);不存在或非数组则返回 null
 */
function getChoicesArray(obj: Record<string, Object>): Object[] | null {
  const val: Object | undefined = obj['choices'];
  if (val === undefined || val === null) {
    return null;
  }
  if (!Array.isArray(val)) {
    return null;
  }
  return val as Object[];
}

// ===== 请求体构建 =====

/**
 * 将 ChatRole 转换为 OpenAI API 角色字符串。
 * @param role 聊天角色枚举
 * @returns OpenAI API 角色字符串
 */
export function roleToString(role: ChatRole): string {
  switch (role) {
    case ChatRole.System:
      return 'system';
    case ChatRole.User:
      return 'user';
    case ChatRole.Assistant:
      return 'assistant';
    default:
      return 'user';
  }
}

// ===== 响应解析 =====

/**
 * 从解析后的 JSON 对象提取 OpenAIErrorDetail。
 * @param obj 解析后的 JSON 对象
 * @returns 错误详情;非错误响应返回 null
 */
export function extractErrorDetail(obj: Record<string, Object>): OpenAIErrorDetail | null {
  const errorObj: Record<string, Object> | null = getObjectField(obj, 'error');
  if (errorObj === null) {
    return null;
  }
  const message: string | undefined = getStringField(errorObj, 'message');
  if (message === undefined) {
    // 错误对象存在但无 message 字段
    return {
      message: 'Server returned error object without message',
      type: getStringField(errorObj, 'type'),
      code: getStringField(errorObj, 'code')
    };
  }
  return {
    message: message,
    type: getStringField(errorObj, 'type'),
    code: getStringField(errorObj, 'code')
  };
}

/**
 * 从 HTTP 错误响应体提取服务端错误详情。
 *
 * 兼容多种服务商错误体格式:
 * - OpenAI 标准: {"error": {"message": "...", "code": "..."}}
 * - Gemini OpenAI 兼容层: [{"error": {"message": "...", "status": "..."}}] (数组包裹)
 * - 纯文本错误页
 *
 * @param body HTTP 错误响应体
 * @returns 错误详情;无法提取时返回 null
 */
export function extractErrorDetailFromBody(body: string): OpenAIErrorDetail | null {
  const trimmed: string = body.trim();
  if (trimmed.length === 0) {
    return null;
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(trimmed);
  } catch (e) {
    return null;
  }
  if (parsed === undefined || parsed === null) {
    return null;
  }
  // Gemini OpenAI 兼容层把错误响应包成数组 [{error: {...}}]
  if (Array.isArray(parsed)) {
    const arr: Object[] = parsed as Object[];
    if (arr.length === 0) {
      return null;
    }
    const first: Object = arr[0];
    if (first !== null && typeof first === 'object') {
      return extractErrorDetail(first as Record<string, Object>);
    }
    return null;
  }
  if (typeof parsed === 'object') {
    return extractErrorDetail(parsed as Record<string, Object>);
  }
  return null;
}

/**
 * 根据 HTTP 状态码与服务端错误详情生成面向用户的友好错误提示(中文)。
 *
 * 直接用于聊天气泡 / Toast 等展示场景,给出可操作的修复建议,
 * 并附带服务端返回的真实原因(截断)。
 *
 * @param statusCode HTTP 状态码(0 表示未知)
 * @param detail 服务端错误详情(可为 null)
 * @returns 友好错误提示文本
 */
export function buildFriendlyHttpError(statusCode: number, detail: OpenAIErrorDetail | null): string {
  const serverMsg: string = detail !== null ? detail.message.trim() : '';

  let hint: string;
  if (statusCode === 401 || statusCode === 403) {
    hint = '鉴权失败：API Key 无效或未配置，请到模型设置中检查';
  } else if (statusCode === 429) {
    hint = '请求过于频繁，触发限流，请稍后重试或降低发送频率';
  } else if (statusCode === 408) {
    hint = '请求超时，请稍后重试';
  } else if (statusCode === 404) {
    hint = '模型或接口不存在，请到模型设置中更换模型';
  } else if (statusCode === 400) {
    hint = '请求参数被服务端拒绝，请检查上下文长度与消息格式';
  } else if (statusCode >= 500 && statusCode < 600) {
    hint = '服务端繁忙或负载过高';
  } else {
    hint = '请求失败';
  }

  let result: string = '模型请求失败：' + hint;
  if (statusCode > 0) {
    result += '（HTTP ' + statusCode.toString() + '）';
  }
  if (serverMsg.length > 0) {
    result += '；服务端返回：' + truncateErrorMessage(serverMsg, 200);
  }
  if (statusCode >= 500 && statusCode < 600) {
    result += '；请稍后重试，或更换为其他可用模型';
  }
  return result;
}

/**
 * 从单个 choice 对象安全提取 OpenAIChoice。
 * @param choiceObj choices 数组中的一个元素
 * @returns 解析结果,success=false 时 error 描述原因
 */

/**
 * 从 message 对象解析最终正文文本。
 *
 * 兼容各服务商差异:
 * - OpenAI 标准: message.content 为字符串
 * - Gemini OpenAI 兼容层: 思考型模型的 message.content 可能为 null,
 *   思考内容放在 message.thinking_content;content 也可能为多段数组
 *   (如 [{"type":"text","text":"..."}])
 * - 部分代理把思考字段命名为 message.reasoning
 *
 * @param messageObj message 对象
 * @returns 正文文本;无法解析时返回 undefined
 */
function resolveMessageContent(messageObj: Record<string, Object>): string | undefined {
  const content: string | undefined = getStringField(messageObj, 'content');
  if (content !== undefined) {
    return content;
  }
  // content 非字符串(如 string[] 多段)时,直接尝试拼接全部文本段
  const contentVal: Object | undefined = messageObj['content'] as Object | undefined;
  if (contentVal !== undefined && contentVal !== null && Array.isArray(contentVal)) {
    const partsText: string | undefined = extractTextFromParts(contentVal as Object[]);
    if (partsText !== undefined) {
      return partsText;
    }
  }
  // 回退: 思考字段(Gemini thinking_content / 部分代理 reasoning)
  const thinking: string | undefined = getStringField(messageObj, 'thinking_content');
  if (thinking !== undefined && thinking.trim().length > 0) {
    return thinking;
  }
  const reasoning: string | undefined = getStringField(messageObj, 'reasoning');
  if (reasoning !== undefined && reasoning.trim().length > 0) {
    return reasoning;
  }
  return undefined;
}

/**
 * 从 content 多段数组([{"type":"text","text":"..."}])提取文本并拼接。
 * 支持嵌套数组。无任何文本段时返回 undefined。
 */
function extractTextFromParts(parts: Object[]): string | undefined {
  let acc: string = '';
  for (let i = 0; i < parts.length; i++) {
    const part: Object = parts[i];
    if (part !== null && typeof part === 'object') {
      const record: Record<string, Object> = part as Record<string, Object>;
      const text: string | undefined = getStringField(record, 'text');
      if (text !== undefined) {
        acc += text;
        continue;
      }
      const subVal: Object | undefined = record['content'] as Object | undefined;
      if (subVal !== undefined && subVal !== null && Array.isArray(subVal)) {
        const sub: string | undefined = extractTextFromParts(subVal as Object[]);
        if (sub !== undefined) {
          acc += sub;
        }
      }
    } else if (Array.isArray(part)) {
      const sub: string | undefined = extractTextFromParts(part as Object[]);
      if (sub !== undefined) {
        acc += sub;
      }
    }
  }
  return acc.length > 0 ? acc : undefined;
}

export function extractChoice(choiceObj: Object): ChoiceExtractResult {
  if (!isObject(choiceObj)) {
    return { success: false, error: 'choice is not an object', choice: undefined };
  }
  const record: Record<string, Object> = choiceObj as Record<string, Object>;

  const messageObj: Record<string, Object> | null = getObjectField(record, 'message');
  if (messageObj === null) {
    return { success: false, error: 'choice.message is missing or not an object', choice: undefined };
  }

  const content: string | undefined = resolveMessageContent(messageObj);
  if (content === undefined) {
    return { success: false, error: 'choice.message.content is missing or not a string', choice: undefined };
  }

  const role: string | undefined = getStringField(messageObj, 'role');
  const finishReason: string | undefined = getStringField(record, 'finish_reason');
  const indexVal: number | undefined = getNumberField(record, 'index');

  return {
    success: true,
    error: '',
    choice: {
      index: indexVal !== undefined ? indexVal : 0,
      message: {
        role: role !== undefined ? role : 'assistant',
        content: content
      },
      finish_reason: finishReason !== undefined ? finishReason : ''
    }
  };
}

/**
 * choice 提取结果。
 */
export interface ChoiceExtractResult {
  readonly success: boolean;
  readonly error: string;
  readonly choice?: OpenAIChoice;
}

/**
 * 从解析后的 JSON 对象提取完整的 OpenAIChatResponseBody。
 *
 * 校验规则:
 * - choices 必须存在且至少有一项
 * - 第一个 choice 的 message.content 必须为字符串
 * - content 为 null 返回 ParseError
 * - usage 可选
 * - model 可选
 * - id 可选(映射到 providerRequestId)
 *
 * @param obj 解析后的 JSON 对象
 * @returns 解析结果,success=false 时 error 描述原因
 */
export function extractResponseBody(obj: Object): ResponseExtractResult {
  if (!isObject(obj)) {
    return { success: false, error: 'Response is not an object', body: undefined };
  }
  // Gemini OpenAI 兼容层偶发把错误响应包装成数组 [{error: {...}}](2xx/非 2xx 都可能)
  if (Array.isArray(obj)) {
    const arr: Object[] = obj as Object[];
    for (let i = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      if (item !== null && typeof item === 'object') {
        const itemError: OpenAIErrorDetail | null = extractErrorDetail(item as Record<string, Object>);
        if (itemError !== null) {
          return { success: false, error: itemError.message, body: undefined, isErrorBody: true };
        }
      }
    }
    return { success: false, error: 'Response is an array without error object', body: undefined };
  }
  const root: Record<string, Object> = obj as Record<string, Object>;

  // 检查错误响应
  const errorDetail: OpenAIErrorDetail | null = extractErrorDetail(root);
  if (errorDetail !== null) {
    return { success: false, error: errorDetail.message, body: undefined, isErrorBody: true };
  }

  // 提取 choices
  const choicesArr: Object[] | null = getChoicesArray(root);
  if (choicesArr === null || choicesArr.length === 0) {
    return { success: false, error: 'choices is missing or empty', body: undefined };
  }

  // 提取第一个 choice
  const firstChoiceResult: ChoiceExtractResult = extractChoice(choicesArr[0]);
  if (!firstChoiceResult.success || firstChoiceResult.choice === undefined) {
    return { success: false, error: firstChoiceResult.error, body: undefined };
  }

  // 提取 usage(可选)
  const usageObj: Record<string, Object> | null = getObjectField(root, 'usage');
  let usage: OpenAIUsage | undefined = undefined;
  if (usageObj !== null) {
    const promptTokens: number | undefined = getNumberField(usageObj, 'prompt_tokens');
    const completionTokens: number | undefined = getNumberField(usageObj, 'completion_tokens');
    const totalTokens: number | undefined = getNumberField(usageObj, 'total_tokens');
    if (promptTokens !== undefined && completionTokens !== undefined && totalTokens !== undefined) {
      // 提取 prompt_tokens_details.cached_tokens (可选, OpenAI/DeepSeek Prompt Cache)
      let cachedTokens: number | undefined = undefined;
      const detailsObj: Record<string, Object> | null = getObjectField(usageObj, 'prompt_tokens_details');
      if (detailsObj !== null) {
        cachedTokens = getNumberField(detailsObj, 'cached_tokens');
      }
      usage = {
        prompt_tokens: promptTokens,
        completion_tokens: completionTokens,
        total_tokens: totalTokens,
        cached_tokens: cachedTokens
      };
    }
  }

  // 提取 id(可选)和 model(可选)
  const id: string | undefined = getStringField(root, 'id');
  const model: string | undefined = getStringField(root, 'model');

  const body: OpenAIChatResponseBody = {
    id: id !== undefined ? id : '',
    model: model !== undefined ? model : '',
    choices: [firstChoiceResult.choice],
    usage: usage
  };

  return { success: true, error: '', body: body };
}

/**
 * 响应体提取结果。
 */
export interface ResponseExtractResult {
  readonly success: boolean;
  readonly error: string;
  readonly body?: OpenAIChatResponseBody;
  /** 是否为错误响应体(包含 error 字段) */
  readonly isErrorBody?: boolean;
}

/**
 * 截断服务端错误消息,防止过长消息进入错误对象。
 * @param message 原始消息
 * @param maxLength 最大长度(默认 512)
 * @returns 截断后的消息
 */
export function truncateErrorMessage(message: string, maxLength: number = 512): string {
  if (message.length <= maxLength) {
    return message;
  }
  return message.substring(0, maxLength) + '...[truncated]';
}
