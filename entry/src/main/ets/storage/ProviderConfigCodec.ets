/**
 * ProviderConfigCodec - ProviderConfig 序列化/反序列化纯逻辑模块。
 * 纯 ArkTS 逻辑,不依赖设备 API,可在本地单元测试运行。
 *
 * JSON Schema (schemaVersion=1):
 * { schemaVersion: 1, configs: [{ id, name, type, baseUrl, modelName,
 *   temperature, topP, maxTokens, stream, enabled, createdAt, updatedAt }] }
 *
 * 安全要求:
 * - 不序列化敏感字段(apiKey/secret/token/password 等),编码前做防御检查
 * - 不使用 any/untyped literal,JSON.parse 结果必须经类型守卫
 * - 单个坏配置跳过不影响其他;整个 JSON 无法解析返回 CorruptedData
 * - 旧 schema 版本返回 UnsupportedVersion;错误信息不回显完整原始 JSON
 */

import { ProviderConfig, isValidTemperature, isValidTopP, isValidMaxTokens } from '../models/ProviderConfig';
import { ProviderType } from '../models/ProviderType';
import { PreferencesErrorType, createPreferencesError, PreferencesError } from '../models/PreferencesError';

/** 当前支持的 schema 版本 */
export const CURRENT_SCHEMA_VERSION: number = 1;

/** 敏感字段名(小写,用于大小写不敏感匹配) */
const SENSITIVE_FIELDS: string[] = [
  'apikey',
  'api_key',
  'secret',
  'authorization',
  'token',
  'password'
];

/** ProviderConfig 单条配置的 V1 JSON 结构(不含敏感字段) */
export interface ProviderConfigItemV1 {
  readonly id: string;
  readonly name: string;
  readonly type: string;
  readonly baseUrl: string;
  readonly modelName: string;
  readonly temperature: number;
  readonly topP: number;
  readonly maxTokens: number;
  readonly stream: boolean;
  readonly enabled: boolean;
  readonly createdAt: number;
  readonly updatedAt: number;
  /** 上下文窗口大小(可选,缺省时回退为默认值) */
  readonly contextWindow?: number;
}

/** 完整 JSON 结构(V1) */
export interface ProviderConfigSchemaV1 {
  readonly schemaVersion: number;
  readonly configs: ProviderConfigItemV1[];
}

/**
 * 解码结果。
 * success=false 表示整个 JSON 无法解析或结构非法;success=true 时 configs 为有效配置,
 * skippedCount 为跳过的无效配置数。
 */
export interface CodecDecodeResult {
  readonly success: boolean;
  readonly configs: ProviderConfig[];
  readonly skippedCount: number;
  /** 跳过原因摘要(不含完整 JSON) */
  readonly errors: string[];
  readonly error?: PreferencesError;
}

interface ExtractStringResult {
  readonly success: boolean;
  readonly value: string;
  readonly error: string;
}

interface ExtractNumberResult {
  readonly success: boolean;
  readonly value: number;
  readonly error: string;
}

interface ExtractBooleanResult {
  readonly success: boolean;
  readonly value: boolean;
  readonly error: string;
}

interface TryParseItemResult {
  readonly success: boolean;
  readonly item?: ProviderConfigItemV1;
  readonly error: string;
}

/** 判断字段名是否为敏感字段(大小写不敏感) */
export function isSensitiveField(name: string): boolean {
  const lower: string = name.toLowerCase();
  for (let i = 0; i < SENSITIVE_FIELDS.length; i++) {
    if (lower === SENSITIVE_FIELDS[i]) {
      return true;
    }
  }
  return false;
}

/** 判断字符串是否为合法的 ProviderType 枚举值 */
export function isValidProviderTypeValue(value: string): boolean {
  return value === ProviderType.OpenAICompatible ||
    value === ProviderType.OpenAI ||
    value === ProviderType.DeepSeek ||
    value === ProviderType.MiMo ||
    value === ProviderType.OpenRouter ||
    value === ProviderType.Claude ||
    value === ProviderType.Gemini ||
    value === ProviderType.OpenCodeGo ||
    value === ProviderType.SiliconFlow ||
    value === ProviderType.Zhipu ||
    value === ProviderType.Qwen ||
    value === ProviderType.Kimi ||
    value === ProviderType.Volcengine ||
    value === ProviderType.MiniMax;
}

/** 将 ProviderType 字符串值转换为枚举(调用前应先用 isValidProviderTypeValue 校验) */
function parseProviderType(value: string): ProviderType {
  switch (value) {
    case ProviderType.OpenAICompatible:
      return ProviderType.OpenAICompatible;
    case ProviderType.OpenAI:
      return ProviderType.OpenAI;
    case ProviderType.DeepSeek:
      return ProviderType.DeepSeek;
    case ProviderType.MiMo:
      return ProviderType.MiMo;
    case ProviderType.OpenRouter:
      return ProviderType.OpenRouter;
    case ProviderType.Claude:
      return ProviderType.Claude;
    case ProviderType.Gemini:
      return ProviderType.Gemini;
    case ProviderType.OpenCodeGo:
      return ProviderType.OpenCodeGo;
    case ProviderType.SiliconFlow:
      return ProviderType.SiliconFlow;
    case ProviderType.Zhipu:
      return ProviderType.Zhipu;
    case ProviderType.Qwen:
      return ProviderType.Qwen;
    case ProviderType.Kimi:
      return ProviderType.Kimi;
    case ProviderType.Volcengine:
      return ProviderType.Volcengine;
    case ProviderType.MiniMax:
      return ProviderType.MiniMax;
    default:
      // 不应到达此处,调用方应先校验
      return ProviderType.OpenAICompatible;
  }
}

/** 判断时间戳是否合法(非负有限数) */
function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && value >= 0;
}

/** 检查对象是否包含敏感字段(编码前防御性检查,防止未来扩展时误存密钥) */
export function containsSensitiveFields(obj: Record<string, Object>): boolean {
  const keys: string[] = Object.keys(obj);
  for (let i = 0; i < keys.length; i++) {
    if (isSensitiveField(keys[i])) {
      return true;
    }
  }
  return false;
}

/** 将单个 ProviderConfig 编码为 V1 JSON 项(显式列出字段,确保不含敏感字段) */
export function encodeConfigItem(config: ProviderConfig): ProviderConfigItemV1 {
  const item: ProviderConfigItemV1 = {
    id: config.id,
    name: config.name,
    type: config.type,
    baseUrl: config.baseUrl,
    modelName: config.modelName,
    temperature: config.temperature,
    topP: config.topP,
    maxTokens: config.maxTokens,
    stream: config.stream,
    enabled: config.enabled,
    createdAt: config.createdAt,
    updatedAt: config.updatedAt
  };
  if (config.contextWindow !== undefined) {
    const out: ProviderConfigItemV1 = {
      id: item.id,
      name: item.name,
      type: item.type,
      baseUrl: item.baseUrl,
      modelName: item.modelName,
      temperature: item.temperature,
      topP: item.topP,
      maxTokens: item.maxTokens,
      stream: item.stream,
      enabled: item.enabled,
      createdAt: item.createdAt,
      updatedAt: item.updatedAt,
      contextWindow: config.contextWindow
    };
    return out;
  }
  return item;
}

/** 将 ProviderConfig 列表编码为 JSON 字符串(编码前执行敏感字段防御检查) */
export function encodeConfigs(configs: ProviderConfig[]): string {
  for (let i = 0; i < configs.length; i++) {
    const config: ProviderConfig = configs[i];
    const obj: Record<string, Object> = {
      'id': config.id,
      'name': config.name,
      'type': config.type,
      'baseUrl': config.baseUrl,
      'modelName': config.modelName,
      'temperature': config.temperature,
      'topP': config.topP,
      'maxTokens': config.maxTokens,
      'stream': config.stream,
      'enabled': config.enabled,
      'createdAt': config.createdAt,
      'updatedAt': config.updatedAt
    };
    if (containsSensitiveFields(obj)) {
      throw createPreferencesError(
        PreferencesErrorType.SerializationFailed,
        'ProviderConfig contains sensitive field',
        undefined,
        undefined
      );
    }
  }

  const items: ProviderConfigItemV1[] = [];
  for (let i = 0; i < configs.length; i++) {
    items.push(encodeConfigItem(configs[i]));
  }

  const schema: ProviderConfigSchemaV1 = {
    schemaVersion: CURRENT_SCHEMA_VERSION,
    configs: items
  };

  try {
    return JSON.stringify(schema);
  } catch (e) {
    throw createPreferencesError(
      PreferencesErrorType.SerializationFailed,
      'JSON.stringify failed',
      undefined,
      e instanceof Error ? e.message : String(e)
    );
  }
}

/** 从 Object 安全提取字符串字段 */
function extractString(obj: Object, key: string): ExtractStringResult {
  const record: Record<string, Object> = obj as Record<string, Object>;
  const value: Object | undefined = record[key];
  if (value === undefined) {
    return { success: false, value: '', error: 'missing field: ' + key };
  }
  if (typeof value !== 'string') {
    return { success: false, value: '', error: 'field is not string: ' + key };
  }
  return { success: true, value: value, error: '' };
}

/** 从 Object 安全提取数字字段 */
function extractNumber(obj: Object, key: string): ExtractNumberResult {
  const record: Record<string, Object> = obj as Record<string, Object>;
  const value: Object | undefined = record[key];
  if (value === undefined) {
    return { success: false, value: 0, error: 'missing field: ' + key };
  }
  if (typeof value !== 'number') {
    return { success: false, value: 0, error: 'field is not number: ' + key };
  }
  if (!Number.isFinite(value)) {
    return { success: false, value: 0, error: 'field is not finite: ' + key };
  }
  return { success: true, value: value, error: '' };
}

/** 从 Object 安全提取布尔字段 */
function extractBoolean(obj: Object, key: string): ExtractBooleanResult {
  const record: Record<string, Object> = obj as Record<string, Object>;
  const value: Object | undefined = record[key];
  if (value === undefined) {
    return { success: false, value: false, error: 'missing field: ' + key };
  }
  if (typeof value !== 'boolean') {
    return { success: false, value: false, error: 'field is not boolean: ' + key };
  }
  return { success: true, value: value, error: '' };
}

/** 提取并校验所有字段,组装为 ProviderConfigItemV1(失败返回 error,不含完整 JSON) */
function validateAndExtractFields(obj: Object): TryParseItemResult {
  const id: ExtractStringResult = extractString(obj, 'id');
  if (!id.success) { return { success: false, error: id.error }; }
  if (id.value.length === 0) { return { success: false, error: 'id is empty' }; }

  const name: ExtractStringResult = extractString(obj, 'name');
  if (!name.success) { return { success: false, error: name.error }; }
  if (name.value.length === 0) { return { success: false, error: 'name is empty' }; }

  const type: ExtractStringResult = extractString(obj, 'type');
  if (!type.success) { return { success: false, error: type.error }; }
  if (!isValidProviderTypeValue(type.value)) { return { success: false, error: 'invalid ProviderType: ' + type.value }; }

  const baseUrl: ExtractStringResult = extractString(obj, 'baseUrl');
  if (!baseUrl.success) { return { success: false, error: baseUrl.error }; }
  if (baseUrl.value.length === 0) { return { success: false, error: 'baseUrl is empty' }; }

  const modelName: ExtractStringResult = extractString(obj, 'modelName');
  if (!modelName.success) { return { success: false, error: modelName.error }; }
  if (modelName.value.length === 0) { return { success: false, error: 'modelName is empty' }; }

  const temperature: ExtractNumberResult = extractNumber(obj, 'temperature');
  if (!temperature.success) { return { success: false, error: temperature.error }; }
  if (!isValidTemperature(temperature.value)) { return { success: false, error: 'invalid temperature: ' + temperature.value.toString() }; }

  const topP: ExtractNumberResult = extractNumber(obj, 'topP');
  if (!topP.success) { return { success: false, error: topP.error }; }
  if (!isValidTopP(topP.value)) { return { success: false, error: 'invalid topP: ' + topP.value.toString() }; }

  const maxTokens: ExtractNumberResult = extractNumber(obj, 'maxTokens');
  if (!maxTokens.success) { return { success: false, error: maxTokens.error }; }
  if (!isValidMaxTokens(maxTokens.value)) { return { success: false, error: 'invalid maxTokens: ' + maxTokens.value.toString() }; }

  const stream: ExtractBooleanResult = extractBoolean(obj, 'stream');
  if (!stream.success) { return { success: false, error: stream.error }; }

  const enabled: ExtractBooleanResult = extractBoolean(obj, 'enabled');
  if (!enabled.success) { return { success: false, error: enabled.error }; }

  const createdAt: ExtractNumberResult = extractNumber(obj, 'createdAt');
  if (!createdAt.success) { return { success: false, error: createdAt.error }; }
  if (!isValidTimestamp(createdAt.value)) { return { success: false, error: 'invalid createdAt' }; }

  const updatedAt: ExtractNumberResult = extractNumber(obj, 'updatedAt');
  if (!updatedAt.success) { return { success: false, error: updatedAt.error }; }
  if (!isValidTimestamp(updatedAt.value)) { return { success: false, error: 'invalid updatedAt' }; }

  // contextWindow 可选字段(缺省时回退为默认值)
  let contextWindowValue: number | undefined = undefined;
  const contextWindowRaw: Object | undefined = (obj as Record<string, Object>)['contextWindow'];
  if (contextWindowRaw !== undefined) {
    if (typeof contextWindowRaw !== 'number' || !Number.isFinite(contextWindowRaw)) {
      return { success: false, error: 'contextWindow is not finite number' };
    }
    contextWindowValue = contextWindowRaw;
  }

  if (contextWindowValue !== undefined) {
    const itemWithContext: ProviderConfigItemV1 = {
      id: id.value, name: name.value, type: type.value, baseUrl: baseUrl.value, modelName: modelName.value,
      temperature: temperature.value, topP: topP.value, maxTokens: maxTokens.value,
      stream: stream.value, enabled: enabled.value, createdAt: createdAt.value, updatedAt: updatedAt.value,
      contextWindow: contextWindowValue
    };
    return { success: true, item: itemWithContext, error: '' };
  }

  const item: ProviderConfigItemV1 = {
    id: id.value, name: name.value, type: type.value, baseUrl: baseUrl.value, modelName: modelName.value,
    temperature: temperature.value, topP: topP.value, maxTokens: maxTokens.value,
    stream: stream.value, enabled: enabled.value, createdAt: createdAt.value, updatedAt: updatedAt.value
  };
  return { success: true, item: item, error: '' };
}

/** 尝试将一个 Object 解析为 ProviderConfigItemV1(失败返回 error,不含完整 JSON) */
function tryParseItem(obj: Object): TryParseItemResult {
  const record: Record<string, Object> = obj as Record<string, Object>;
  if (containsSensitiveFields(record)) {
    return { success: false, error: 'contains sensitive field' };
  }
  return validateAndExtractFields(obj);
}

/** 将单个 ProviderConfigItemV1 转换为 ProviderConfig 实例(已校验) */
export function itemToConfig(item: ProviderConfigItemV1): ProviderConfig {
  return new ProviderConfig(
    item.id,
    item.name,
    parseProviderType(item.type),
    item.baseUrl,
    item.modelName,
    item.temperature,
    item.topP,
    item.maxTokens,
    item.stream,
    item.enabled,
    item.createdAt,
    item.updatedAt,
    item.contextWindow
  );
}

/**
 * 从 JSON 字符串解码为 ProviderConfig 列表。
 * 空字符串/非 JSON/缺 schemaVersion → CorruptedData;
 * schemaVersion≠1 → UnsupportedVersion;
 * 单个配置项非法 → 跳过并记录,不影响其他配置。
 */
export function decodeConfigs(json: string): CodecDecodeResult {
  if (json.length === 0) {
    return {
      success: false,
      configs: [],
      skippedCount: 0,
      errors: ['empty json string'],
      error: createPreferencesError(
        PreferencesErrorType.CorruptedData,
        'Empty JSON string',
        undefined,
        undefined
      )
    };
  }

  let parsed: Object;
  try {
    parsed = JSON.parse(json);
  } catch (e) {
    return {
      success: false,
      configs: [],
      skippedCount: 0,
      errors: ['json parse failed'],
      error: createPreferencesError(
        PreferencesErrorType.CorruptedData,
        'JSON parse failed',
        undefined,
        e instanceof Error ? e.message : String(e)
      )
    };
  }

  const record: Record<string, Object> = parsed as Record<string, Object>;
  const schemaVersionField: Object | undefined = record['schemaVersion'];
  if (schemaVersionField === undefined) {
    return {
      success: false,
      configs: [],
      skippedCount: 0,
      errors: ['missing schemaVersion'],
      error: createPreferencesError(
        PreferencesErrorType.CorruptedData,
        'Missing schemaVersion field',
        undefined,
        undefined
      )
    };
  }
  if (typeof schemaVersionField !== 'number') {
    return {
      success: false,
      configs: [],
      skippedCount: 0,
      errors: ['schemaVersion is not number'],
      error: createPreferencesError(
        PreferencesErrorType.CorruptedData,
        'schemaVersion is not a number',
        undefined,
        undefined
      )
    };
  }
  const schemaVersion: number = schemaVersionField;
  if (schemaVersion !== CURRENT_SCHEMA_VERSION) {
    return {
      success: false,
      configs: [],
      skippedCount: 0,
      errors: ['unsupported schemaVersion: ' + schemaVersion.toString()],
      error: createPreferencesError(
        PreferencesErrorType.UnsupportedVersion,
        'Unsupported schema version: ' + schemaVersion.toString(),
        undefined,
        undefined
      )
    };
  }

  const configsField: Object | undefined = record['configs'];
  if (configsField === undefined) {
    return {
      success: false,
      configs: [],
      skippedCount: 0,
      errors: ['missing configs field'],
      error: createPreferencesError(
        PreferencesErrorType.CorruptedData,
        'Missing configs field',
        undefined,
        undefined
      )
    };
  }
  const configsRaw: Object = configsField;
  if (!Array.isArray(configsRaw)) {
    return {
      success: false,
      configs: [],
      skippedCount: 0,
      errors: ['configs is not array'],
      error: createPreferencesError(
        PreferencesErrorType.CorruptedData,
        'configs is not an array',
        undefined,
        undefined
      )
    };
  }

  const configsArray: Object[] = configsRaw as Object[];
  const validConfigs: ProviderConfig[] = [];
  const errors: string[] = [];
  let skippedCount: number = 0;

  for (let i = 0; i < configsArray.length; i++) {
    const itemObj: Object = configsArray[i];
    if (itemObj === null || typeof itemObj !== 'object') {
      skippedCount++;
      errors.push('item ' + i.toString() + ' is not object');
      continue;
    }
    const result: TryParseItemResult = tryParseItem(itemObj);
    if (!result.success || result.item === undefined) {
      skippedCount++;
      errors.push('item ' + i.toString() + ': ' + result.error);
      continue;
    }
    validConfigs.push(itemToConfig(result.item));
  }

  return {
    success: true,
    configs: validConfigs,
    skippedCount: skippedCount,
    errors: errors,
    error: undefined
  };
}

/** 编码解码往返测试辅助函数(本地测试用) */
export function roundTrip(configs: ProviderConfig[]): ProviderConfig[] {
  const json: string = encodeConfigs(configs);
  const result: CodecDecodeResult = decodeConfigs(json);
  if (!result.success) {
    throw new Error('roundTrip decode failed');
  }
  return result.configs;
}
