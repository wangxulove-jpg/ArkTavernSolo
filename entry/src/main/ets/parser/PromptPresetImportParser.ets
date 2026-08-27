/**
 * PromptPresetImportParser 提示词预设导入解析器
 *
 * 将提示词预设 JSON 文件解析为可入库的预设列表。
 * 支持两种形态:
 * 1. 单个预设对象:{ name, description, systemPrompt, ... }
 * 2. 预设对象数组:[{...}, {...}]
 *
 * 采用白名单方式读取已知字段,忽略未知字段(如 id/createdAt/updatedAt,
 * 导入时统一重新生成)。字段合法性由 createPromptPreset 校验。
 *
 * 纯逻辑、不依赖 ArkUI。
 */

import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetImportParser';

/** 解析后的提示词预设中间格式(导入入库用,id/createdAt 等由创建逻辑重新生成)。 */
export interface ParsedPromptPresetImport {
  readonly name: string;
  readonly description: string;
  readonly systemPrompt: string;
  readonly temperature?: number;
  readonly topP?: number;
  readonly maxOutputTokens?: number;
  readonly contextWindow?: number;
}

/** 单个预设的最大字符数(防止超大文件撑爆数据库) */
const MAX_SYSTEM_PROMPT_LENGTH: number = 100000;
/** 单次导入最大预设数 */
const MAX_IMPORT_COUNT: number = 200;

/**
 * 解析提示词预设导入文本。
 * @param text JSON 文本
 * @param fallbackName 命名缺失时使用的兜底名称(通常取文件名)
 * @returns 解析后的预设列表
 * @throws JSON 无效时抛出 Error
 */
export function parsePromptPresetImport(
  text: string,
  fallbackName: string = ''
): ParsedPromptPresetImport[] {
  let root: Object;
  try {
    root = JSON.parse(text) as Object;
  } catch (e) {
    throw new Error('文件不是有效的 JSON');
  }

  // 数组:每个元素为一个预设;对象:视为单个预设
  let items: Object[];
  if (Array.isArray(root)) {
    items = root as Object[];
  } else if (typeof root === 'object' && root !== null) {
    items = [root];
  } else {
    throw new Error('提示词预设文件必须是对象或对象数组');
  }

  if (items.length === 0) {
    throw new Error('文件中没有任何预设');
  }
  const limit: number = Math.min(items.length, MAX_IMPORT_COUNT);
  const result: ParsedPromptPresetImport[] = [];
  for (let i = 0; i < limit; i++) {
    const item: Object = items[i];
    if (typeof item !== 'object' || item === null || Array.isArray(item)) {
      continue;
    }
    const parsed: ParsedPromptPresetImport | null =
      parseSingle(item as Record<string, Object>, i, fallbackName);
    if (parsed !== null) {
      result.push(parsed);
    }
  }
  return result;
}

/** 解析单条预设;命名缺失且无兜底时跳过。 */
function parseSingle(
  raw: Record<string, Object>,
  index: number,
  fallbackName: string
): ParsedPromptPresetImport | null {
  // 兼容多种命名键:name / preset_name / key(存在多种预设文件格式)
  const name: string = readString(raw, 'name')
    || readString(raw, 'preset_name')
    || readString(raw, 'title');
  const finalName: string = name.trim().length > 0
    ? name.trim()
    : (fallbackName.length > 0 ? fallbackName : '');
  if (finalName.length === 0) {
    return null;
  }

  const systemPrompt: string = readString(raw, 'systemPrompt')
    || readString(raw, 'system_prompt')
    || readString(raw, 'prompt')
    || readString(raw, 'content');
  const cappedPrompt: string = systemPrompt.length > MAX_SYSTEM_PROMPT_LENGTH
    ? systemPrompt.substring(0, MAX_SYSTEM_PROMPT_LENGTH)
    : systemPrompt;

  const result: ParsedPromptPresetImport = {
    name: finalName,
    description: readString(raw, 'description'),
    systemPrompt: cappedPrompt,
    temperature: readOptionalNumber(raw, 'temperature'),
    topP: readOptionalNumber(raw, 'topP'),
    maxOutputTokens: readOptionalNumber(raw, 'maxOutputTokens'),
    contextWindow: readOptionalNumber(raw, 'contextWindow')
  };

  Logger.info(LOG_TAG, 'parsed preset[' + index + ']: ' + result.name);
  return result;
}

function readString(raw: Record<string, Object>, key: string): string {
  const v: Object | undefined = raw[key];
  if (typeof v === 'string') {
    return (v as string).trim();
  }
  return '';
}

function readOptionalNumber(raw: Record<string, Object>, key: string): number | undefined {
  const v: Object | undefined = raw[key];
  if (typeof v === 'number' && Number.isFinite(v as number)) {
    return v as number;
  }
  if (typeof v === 'string') {
    const n: number = Number.parseFloat(v as string);
    if (Number.isFinite(n)) {
      return n;
    }
  }
  return undefined;
}