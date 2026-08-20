/**
 * OpenAiSseDeltaParser OpenAI SSE Delta 解析器
 *
 * 解析 OpenAI-compatible Chat Completions SSE 事件中的 data 字段。
 * 从每个 SSE 事件中提取 assistant delta content,识别 [DONE] 和 finish_reason。
 *
 * 纯逻辑实现,不依赖设备 API,可在本地单元测试运行。
 * 不使用 any,所有 JSON 字段通过类型守卫安全访问。
 * 不包含敏感信息(API Key / Authorization 等)。
 */

/** [DONE] 结束标记 */
const DONE_MARK: string = '[DONE]';

/**
 * Delta 解析结果。
 */
export interface OpenAiDeltaResult {
  /** 提取到的内容片段(可能为空字符串) */
  readonly content: string;
  /** 是否包含有效 content 字段(即使值为空字符串) */
  readonly hasContent: boolean;
  /** 是否为 [DONE] 结束标记 */
  readonly done: boolean;
  /** finish_reason(可选,如 "stop" / "length" / "tool_calls") */
  readonly finishReason?: string;
  /** 解析错误信息(可选,不含敏感数据) */
  readonly parseError?: string;
  /**
   * Phase 4A-3: 工具调用增量片段列表 (可选)。
   *
   * - OpenAI 流式协议中, tool_calls 按 index 分组, arguments 是增量字符串
   * - 首次出现时包含 id 和 function.name, 后续仅包含 function.arguments 增量
   * - 上层 (OpenAIStreamSession) 按 index 累积, 完成后转为 ArkWebChatToolCall
   */
  readonly toolCallDeltas?: OpenAiToolCallDelta[];
}

/**
 * Phase 4A-3: OpenAI 工具调用增量片段 (来自 delta.tool_calls[i])。
 *
 * - index: 用于在多次 delta 中关联同一个工具调用
 * - id: 工具调用 ID (仅首次出现, 后续为空字符串)
 * - name: 工具名 (仅首次出现, 后续为空字符串)
 * - argumentsDelta: 参数 JSON 增量片段 (多次出现, 上层按 index 累积拼接)
 */
export interface OpenAiToolCallDelta {
  readonly index: number;
  readonly id: string;
  readonly name: string;
  readonly argumentsDelta: string;
}

/**
 * 无内容的成功结果(delta.role 事件、空 choices 等)。
 */
function emptyResult(): OpenAiDeltaResult {
  return {
    content: '',
    hasContent: false,
    done: false
  };
}

/**
 * [DONE] 结果。
 */
function doneResult(): OpenAiDeltaResult {
  return {
    content: '',
    hasContent: false,
    done: true
  };
}

/**
 * 错误结果。
 */
function errorResult(message: string): OpenAiDeltaResult {
  return {
    content: '',
    hasContent: false,
    done: false,
    parseError: message
  };
}

/**
 * 安全类型守卫:判断值是否为对象(非 null)。
 */
function isObject(val: Object): boolean {
  return val !== null && typeof val === 'object';
}

/**
 * 安全获取 Record<string, Object> 的字符串属性。
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
 * 安全获取 Record<string, Object> 的对象属性。
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

/**
 * 从单个 choice 对象中提取 delta.content 和 finish_reason。
 *
 * @param choice choices 数组中的一个元素(Object)
 * @returns 解析结果
 */
function parseChoice(choice: Object): OpenAiDeltaResult {
  if (!isObject(choice)) {
    return emptyResult();
  }
  const choiceRecord: Record<string, Object> = choice as Record<string, Object>;

  // 提取 finish_reason
  const finishReason: string | undefined = getStringField(choiceRecord, 'finish_reason');

  // 提取 delta 对象
  const delta: Record<string, Object> | null = getObjectField(choiceRecord, 'delta');
  if (delta === null) {
    // 有 finish_reason 但无 delta(如最后一个事件)
    if (finishReason !== undefined) {
      return {
        content: '',
        hasContent: false,
        done: false,
        finishReason: finishReason
      };
    }
    return emptyResult();
  }

  // 提取 delta.content
  const contentVal: Object | undefined = delta['content'];
  let content: string = '';
  let hasContent: boolean = false;

  if (contentVal !== undefined && contentVal !== null) {
    if (typeof contentVal === 'string') {
      content = contentVal;
      hasContent = true;
    }
    // content 为 null 时视为无内容(OpenAI 首帧 delta.role 事件)
  }

  // 提取 delta.role(不产生 content,但表示正常事件)
  const role: string | undefined = getStringField(delta, 'role');
  if (role !== undefined) {
    // delta.role 事件:可能有 content 也可能没有
  }

  // Phase 4A-3: 提取 delta.tool_calls 增量
  const toolCallDeltas: OpenAiToolCallDelta[] | undefined = extractToolCallDeltas(delta);

  const result: OpenAiDeltaResult = {
    content: content,
    hasContent: hasContent,
    done: false
  };

  if (finishReason !== undefined && finishReason !== null && finishReason !== 'null') {
    if (toolCallDeltas !== undefined) {
      return {
        content: result.content,
        hasContent: result.hasContent,
        done: false,
        finishReason: finishReason,
        toolCallDeltas: toolCallDeltas
      };
    }
    // 使用展开方式构造,避免对象字面量类型问题
    return {
      content: result.content,
      hasContent: result.hasContent,
      done: false,
      finishReason: finishReason
    };
  }

  if (toolCallDeltas !== undefined) {
    return {
      content: result.content,
      hasContent: result.hasContent,
      done: false,
      toolCallDeltas: toolCallDeltas
    };
  }

  return result;
}

/**
 * Phase 4A-3: 从 delta 对象提取 tool_calls 增量片段数组。
 *
 * OpenAI 流式协议:
 *   "delta": {
 *     "tool_calls": [
 *       {
 *         "index": 0,
 *         "id": "call_abc",        // 首次出现
 *         "type": "function",
 *         "function": {
 *           "name": "avatar_perform",     // 首次出现
 *           "arguments": "{\"motion"      // 增量片段
 *         }
 *       }
 *     ]
 *   }
 *
 * @param delta delta 对象
 * @returns 增量数组;无 tool_calls 字段返回 undefined
 */
function extractToolCallDeltas(delta: Record<string, Object>): OpenAiToolCallDelta[] | undefined {
  const toolCallsVal: Object | undefined = delta['tool_calls'];
  if (toolCallsVal === undefined || toolCallsVal === null) {
    return undefined;
  }
  if (!Array.isArray(toolCallsVal)) {
    return undefined;
  }
  const arr: Object[] = toolCallsVal as Object[];
  if (arr.length === 0) {
    return undefined;
  }
  const result: OpenAiToolCallDelta[] = [];
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (!isObject(item)) {
      continue;
    }
    const record: Record<string, Object> = item as Record<string, Object>;
    // index
    const indexVal: Object | undefined = record['index'];
    let indexNum: number = 0;
    if (typeof indexVal === 'number') {
      indexNum = indexVal;
    }
    // id (可选, 仅首次出现)
    const idVal: Object | undefined = record['id'];
    const idStr: string = typeof idVal === 'string' ? idVal : '';
    // function (含 name + arguments 增量)
    const functionObj: Record<string, Object> | null = getObjectField(record, 'function');
    let nameStr: string = '';
    let argumentsDelta: string = '';
    if (functionObj !== null) {
      const nameVal: Object | undefined = functionObj['name'];
      nameStr = typeof nameVal === 'string' ? nameVal : '';
      const argsVal: Object | undefined = functionObj['arguments'];
      argumentsDelta = typeof argsVal === 'string' ? argsVal : '';
    }
    result.push({
      index: indexNum,
      id: idStr,
      name: nameStr,
      argumentsDelta: argumentsDelta
    });
  }
  return result.length > 0 ? result : undefined;
}

/**
 * 检查 data 是否为错误响应。
 * OpenAI 错误响应格式:{"error": {"message": "...", "type": "...", "code": "..."}}
 *
 * @param obj 解析后的 JSON 对象
 * @returns 错误消息字符串,非错误响应返回 null
 */
function extractError(obj: Record<string, Object>): string | null {
  const errorObj: Record<string, Object> | null = getObjectField(obj, 'error');
  if (errorObj === null) {
    return null;
  }
  const msg: string | undefined = getStringField(errorObj, 'message');
  if (msg !== undefined) {
    return msg;
  }
  return 'Server returned error object without message';
}

/**
 * 解析单个 SSE 事件的 data 字段。
 *
 * 处理以下情况:
 * - [DONE] 标记
 * - 正常 delta.content(含空字符串)
 * - delta.content 为 null(首帧 role 事件)
 * - choices 为空数组
 * - finish_reason
 * - usage-only 事件(无 choices)
 * - 非 JSON data
 * - 错误响应对象
 *
 * 不会因单个事件解析失败而抛出异常。
 *
 * @param data SSE 事件的 data 字段(已去除 "data: " 前缀)
 * @returns 解析结果
 */
export function parseOpenAiDelta(data: string): OpenAiDeltaResult {
  // 检查 [DONE]
  const trimmed: string = data.trim();
  if (trimmed === DONE_MARK) {
    return doneResult();
  }

  // 空字符串
  if (trimmed.length === 0) {
    return emptyResult();
  }

  // 尝试 JSON 解析
  let parsed: Object;
  try {
    parsed = JSON.parse(trimmed);
  } catch (e) {
    return errorResult('Non-JSON SSE data');
  }

  if (!isObject(parsed)) {
    return errorResult('JSON parsed to non-object');
  }

  const root: Record<string, Object> = parsed as Record<string, Object>;

  // 检查错误响应
  const errorMsg: string | null = extractError(root);
  if (errorMsg !== null) {
    return errorResult(errorMsg);
  }

  // 提取 choices
  const choices: Object[] | null = getChoicesArray(root);
  if (choices === null || choices.length === 0) {
    // usage-only 事件或其他无 choices 事件
    return emptyResult();
  }

  // 解析第一个 choice(对于非流式或简单流式,通常只有一个)
  const firstChoice: Object = choices[0];
  return parseChoice(firstChoice);
}
