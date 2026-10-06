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

// ===== 注入位置(本地偏好,不属于 PromptPreset 实体) =====

/**
 * 预设注入位置。
 * - 'head': 注入到请求最前(现状默认)
 * - 'tail': 注入到聊天历史之后(PostHistory 位置),用于约束输出格式/风格/语气
 *
 * 说明:位置存本地 Preferences(见 storage/PromptPresetSelectionStore),
 * 不是 PromptPreset 的持久化字段,故本接口不增 position。
 */
export type PromptPresetPosition = 'head' | 'tail';

/** 默认注入位置(与历史行为一致:最前)。 */
export const DEFAULT_PRESET_POSITION: PromptPresetPosition = 'head';

/** 判断字符串是否为合法注入位置。 */
export function isPromptPresetPosition(value: string): boolean {
  return value === 'head' || value === 'tail';
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

// ===== 作用域(本地偏好,不属于 PromptPreset 实体) =====

/**
 * 预设作用域:决定该预设"在哪里生效"。
 * - 'global':所有角色卡的会话都生效(缺省值)
 * - 'character':仅绑定的那一张角色卡生效
 *
 * 说明:与 PromptPresetPosition 同口径——作用域存本地 Preferences
 * (见 storage/PromptPresetSelectionStore 的 prompt_preset_scopes_v1),
 * 不是 PromptPreset 的持久化字段,故本接口不增 scope。
 * "已选集合"仍是"是否启用",作用域只收窄生效范围。
 */
export type PresetScopeKind = 'global' | 'character';

/** 预设作用域 */
export interface PresetScope {
  readonly kind: PresetScopeKind;
  /** kind === 'character' 时非空;'global' 时为空串 */
  readonly characterId: string;
}

/** 缺省作用域(全局) */
export const DEFAULT_PRESET_SCOPE: PresetScope = { kind: 'global', characterId: '' };

/** character 作用域在本地偏好里的值前缀 */
const SCOPE_CHARACTER_PREFIX: string = 'char:';

/** 将作用域编码为本地偏好存储值:'global' | 'char:<characterId>' */
export function encodeScope(scope: PresetScope): string {
  if (scope.kind === 'character' && scope.characterId.length > 0) {
    return SCOPE_CHARACTER_PREFIX + scope.characterId;
  }
  return 'global';
}

/** 存储值是否合法 */
export function isValidScopeValue(value: string): boolean {
  if (value === 'global') {
    return true;
  }
  if (value.startsWith(SCOPE_CHARACTER_PREFIX)) {
    return value.length > SCOPE_CHARACTER_PREFIX.length;
  }
  return false;
}

/** 解码存储值;非法值按全局处理(与位置读取的丢弃策略一致) */
export function decodeScope(value: string): PresetScope {
  if (value.startsWith(SCOPE_CHARACTER_PREFIX)) {
    const characterId: string = value.substring(SCOPE_CHARACTER_PREFIX.length);
    if (characterId.length > 0) {
      return { kind: 'character', characterId: characterId };
    }
  }
  return DEFAULT_PRESET_SCOPE;
}

// ===== 受管"本地图片清单"预设的固定 id =====

/**
 * 受管预设:由 LocalImageService 按图片库自动维护正文,列表页只读、禁止删除。
 * 用固定 id 而非新增数据库列,避免改 PromptPreset 实体与校验器。
 */
const MANAGED_IMAGE_PRESET_PREFIX: string = 'arkimg-';
/** 全局图片清单预设的固定 id */
export const MANAGED_IMAGE_GLOBAL_PRESET_ID: string = 'arkimg-global';

/** 某角色专属图片清单预设的固定 id */
export function managedImageCharacterPresetId(characterId: string): string {
  return MANAGED_IMAGE_PRESET_PREFIX + 'char-' + characterId;
}

/** 是否为受管图片清单预设(含全局与各角色) */
export function isManagedImagePresetId(id: string): boolean {
  return id.startsWith(MANAGED_IMAGE_PRESET_PREFIX);
}

/**
 * 按作用域过滤预设(纯函数,便于单测)。
 *
 * 规则:
 * - 作用域缺省 / 值非法 → 视为 global
 * - global 恒保留
 * - character 仅在 characterId 匹配时保留(characterId 为空则一律不保留,
 *   避免角色专属预设泄漏到其它会话)
 *
 * @param presets 候选预设(通常是"已选"集合)
 * @param scopeValues presetId → 存储值('global' | 'char:<id>')
 * @param characterId 当前角色卡 id(null 表示无角色上下文)
 */
export function filterPresetsByScope(
  presets: PromptPreset[],
  scopeValues: Record<string, string>,
  characterId: string | null
): PromptPreset[] {
  const result: PromptPreset[] = [];
  for (let i = 0; i < presets.length; i++) {
    const preset: PromptPreset = presets[i];
    const raw: string | undefined = scopeValues[preset.id];
    const scope: PresetScope = raw !== undefined ? decodeScope(raw) : DEFAULT_PRESET_SCOPE;
    if (scope.kind === 'global') {
      result.push(preset);
      continue;
    }
    if (characterId !== null && characterId.length > 0 && scope.characterId === characterId) {
      result.push(preset);
    }
  }
  return result;
}