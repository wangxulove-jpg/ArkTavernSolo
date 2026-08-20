/**
 * PromptPreset 领域模型
 *
 * 定义 PromptPreset 的数据结构、创建/更新/校验函数。
 * 不依赖 ArkUI、RDB、页面或 Provider 实现。
 *
 * 安全要求:
 * - 不包含 API Key / Base URL / Provider Secret
 * - 不包含用户聊天正文 / Character Prompt / Lorebook 匹配结果
 * - 不包含宏替换结果 / HistoryTrimmer 输出
 * - 不绑定 Provider ID 或 Model ID
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';
import { DatabaseError } from './DatabaseError';

// ===== 校验常量 =====

const NAME_MAX_LENGTH: number = 100;
const DESCRIPTION_MAX_LENGTH: number = 1000;
const TEMPERATURE_MIN: number = 0.0;
const TEMPERATURE_MAX: number = 2.0;
const TOP_P_MIN: number = 0.0;
const TOP_P_MAX: number = 1.0;
const MAX_OUTPUT_TOKENS_MIN: number = 1;
const MAX_OUTPUT_TOKENS_MAX: number = 131072;
const CONTEXT_WINDOW_MIN: number = 512;
const CONTEXT_WINDOW_MAX: number = 1000000;

// ===== 模型接口 =====

/**
 * PromptPreset 领域模型。
 * 不可变:更新通过 updatePromptPreset 返回新对象。
 */
export interface PromptPreset {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly systemPrompt: string;

  readonly temperature?: number;
  readonly topP?: number;
  readonly maxOutputTokens?: number;
  readonly contextWindow?: number;

  readonly createdAt: number;
  readonly updatedAt: number;
}

/**
 * 创建 PromptPreset 的参数。
 */
export interface CreatePromptPresetOptions {
  readonly id?: string;
  readonly name: string;
  readonly description?: string;
  readonly systemPrompt?: string;
  readonly temperature?: number;
  readonly topP?: number;
  readonly maxOutputTokens?: number;
  readonly contextWindow?: number;
  readonly createdAt?: number;
}

/**
 * 更新 PromptPreset 的参数。
 * 可选数字字段 undefined 表示不修改,通过 clear 字段清空为 undefined。
 */
export interface PromptPresetUpdates {
  readonly name?: string;
  readonly description?: string;
  readonly systemPrompt?: string;
  readonly temperature?: number;
  readonly topP?: number;
  readonly maxOutputTokens?: number;
  readonly contextWindow?: number;
  readonly clearTemperature?: boolean;
  readonly clearTopP?: boolean;
  readonly clearMaxOutputTokens?: boolean;
  readonly clearContextWindow?: boolean;
}

// ===== 工厂函数 =====

/**
 * 创建 PromptPreset 实例。
 * @param options 创建参数
 * @returns 新的 PromptPreset 实例
 */
export function createPromptPreset(
  options: CreatePromptPresetOptions
): PromptPreset {
  const id: string = options.id !== undefined && options.id.length > 0
    ? options.id
    : generateUuid();
  const name: string = options.name.trim();
  const description: string = options.description !== undefined
    ? options.description
    : '';
  const systemPrompt: string = options.systemPrompt !== undefined
    ? options.systemPrompt
    : '';
  const now: number = options.createdAt !== undefined
    ? options.createdAt
    : nowMillis();

  const preset: PromptPreset = {
    id: id,
    name: name,
    description: description,
    systemPrompt: systemPrompt,
    temperature: options.temperature,
    topP: options.topP,
    maxOutputTokens: options.maxOutputTokens,
    contextWindow: options.contextWindow,
    createdAt: now,
    updatedAt: now
  };

  validatePromptPreset(preset);
  return preset;
}

/**
 * 更新 PromptPreset,返回新对象。
 * 不修改输入 preset。
 *
 * @param preset 原始 Preset
 * @param updates 更新参数
 * @returns 新的 PromptPreset 实例
 */
export function updatePromptPreset(
  preset: PromptPreset,
  updates: PromptPresetUpdates
): PromptPreset {
  let temperature: number | undefined = preset.temperature;
  let topP: number | undefined = preset.topP;
  let maxOutputTokens: number | undefined = preset.maxOutputTokens;
  let contextWindow: number | undefined = preset.contextWindow;

  if (updates.clearTemperature !== undefined && updates.clearTemperature) {
    temperature = undefined;
  } else if (updates.temperature !== undefined) {
    temperature = updates.temperature;
  }

  if (updates.clearTopP !== undefined && updates.clearTopP) {
    topP = undefined;
  } else if (updates.topP !== undefined) {
    topP = updates.topP;
  }

  if (updates.clearMaxOutputTokens !== undefined && updates.clearMaxOutputTokens) {
    maxOutputTokens = undefined;
  } else if (updates.maxOutputTokens !== undefined) {
    maxOutputTokens = updates.maxOutputTokens;
  }

  if (updates.clearContextWindow !== undefined && updates.clearContextWindow) {
    contextWindow = undefined;
  } else if (updates.contextWindow !== undefined) {
    contextWindow = updates.contextWindow;
  }

  const result: PromptPreset = {
    id: preset.id,
    name: updates.name !== undefined ? updates.name.trim() : preset.name,
    description: updates.description !== undefined ? updates.description : preset.description,
    systemPrompt: updates.systemPrompt !== undefined ? updates.systemPrompt : preset.systemPrompt,
    temperature: temperature,
    topP: topP,
    maxOutputTokens: maxOutputTokens,
    contextWindow: contextWindow,
    createdAt: preset.createdAt,
    updatedAt: nowMillis()
  };

  validatePromptPreset(result);
  return result;
}

/**
 * 校验 PromptPreset 字段合法性。
 * 非法数据抛 DatabaseError.InvalidData。
 *
 * @param preset 待校验的 PromptPreset
 */
export function validatePromptPreset(preset: PromptPreset): void {
  if (preset.id.length === 0) {
    throw DatabaseError.invalidData('preset.id empty');
  }

  const trimmedName: string = preset.name.trim();
  if (trimmedName.length === 0) {
    throw DatabaseError.invalidData('preset.name empty');
  }
  if (preset.name.length > NAME_MAX_LENGTH) {
    throw DatabaseError.invalidData('preset.name too long');
  }

  if (preset.description.length > DESCRIPTION_MAX_LENGTH) {
    throw DatabaseError.invalidData('preset.description too long');
  }

  if (preset.temperature !== undefined) {
    if (!Number.isFinite(preset.temperature)) {
      throw DatabaseError.invalidData('preset.temperature not finite');
    }
    if (preset.temperature < TEMPERATURE_MIN || preset.temperature > TEMPERATURE_MAX) {
      throw DatabaseError.invalidData('preset.temperature out of range');
    }
  }

  if (preset.topP !== undefined) {
    if (!Number.isFinite(preset.topP)) {
      throw DatabaseError.invalidData('preset.topP not finite');
    }
    if (preset.topP < TOP_P_MIN || preset.topP > TOP_P_MAX) {
      throw DatabaseError.invalidData('preset.topP out of range');
    }
  }

  if (preset.maxOutputTokens !== undefined) {
    if (!Number.isInteger(preset.maxOutputTokens) || preset.maxOutputTokens <= 0) {
      throw DatabaseError.invalidData('preset.maxOutputTokens not positive integer');
    }
    if (preset.maxOutputTokens < MAX_OUTPUT_TOKENS_MIN ||
      preset.maxOutputTokens > MAX_OUTPUT_TOKENS_MAX) {
      throw DatabaseError.invalidData('preset.maxOutputTokens out of range');
    }
  }

  if (preset.contextWindow !== undefined) {
    if (!Number.isInteger(preset.contextWindow) || preset.contextWindow <= 0) {
      throw DatabaseError.invalidData('preset.contextWindow not positive integer');
    }
    if (preset.contextWindow < CONTEXT_WINDOW_MIN ||
      preset.contextWindow > CONTEXT_WINDOW_MAX) {
      throw DatabaseError.invalidData('preset.contextWindow out of range');
    }
  }

  if (!Number.isFinite(preset.createdAt) || !Number.isInteger(preset.createdAt) ||
    preset.createdAt < 0) {
    throw DatabaseError.invalidData('preset.createdAt invalid');
  }
  if (!Number.isFinite(preset.updatedAt) || !Number.isInteger(preset.updatedAt) ||
    preset.updatedAt < 0) {
    throw DatabaseError.invalidData('preset.updatedAt invalid');
  }
  if (preset.updatedAt < preset.createdAt) {
    throw DatabaseError.invalidData('preset.updatedAt < createdAt');
  }
}