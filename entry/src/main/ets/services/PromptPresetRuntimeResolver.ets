/**
 * PromptPresetRuntimeResolver 运行时参数解析器
 *
 * 纯函数,不依赖 ArkUI、RDB、Provider 或页面。
 * 负责将 base(模型配置) + preset(PromptPreset) + runtimeOverrides
 * 按优先级合并为最终生效的生成参数。
 *
 * 优先级(从高到低):
 * 1. Runtime Override(单次请求显式覆盖)
 * 2. 已选 Prompt Preset 中定义的字段(多个 Preset 按选择顺序,后选覆盖先选)
 * 3. 当前 Model/Provider 配置中已定义的字段
 *
 * 要求:
 * - 每个字段独立计算
 * - 0 是 temperature 和 topP 的合法值
 * - 使用显式 undefined 判断,不能用真假判断
 * - 不修改 base、presets 或 runtimeOverrides
 * - 返回新对象
 */

import { PromptPreset } from '../models/PromptPreset';

/**
 * 单次请求的显式运行时覆盖参数。
 * 当前 MVP 无单次请求参数 UI,但预留此层。
 */
export interface RuntimeGenerationOverrides {
  readonly temperature?: number;
  readonly topP?: number;
  readonly maxOutputTokens?: number;
  readonly contextWindow?: number;
}

/**
 * 最终生效的生成参数。
 * 所有字段均可选,undefined 表示使用 Provider 默认值。
 */
export interface EffectiveGenerationSettings {
  readonly temperature?: number;
  readonly topP?: number;
  readonly maxOutputTokens?: number;
  readonly contextWindow?: number;
}

/**
 * 请求级 Preset 快照。
 * 在每次 sendMessage/regenerate 开始时读取一次,请求启动后不受中途切换影响。
 * 不包含 API Key / Base URL / Header / 聊天正文 / Character Prompt / Lorebook content。
 */
export interface PromptPresetRequestSnapshot {
  readonly presetId?: string;
  readonly presetSystemPrompt?: string;
  readonly generationSettings: EffectiveGenerationSettings;
}

/**
 * 按优先级合并生成参数。
 *
 * 优先级: runtimeOverrides > presets > base
 * 多个 Preset 按数组顺序依次覆盖,后选 Preset 的字段覆盖先选。
 * 每个字段独立计算,undefined 表示不覆盖。
 * 不修改 base、presets 或 runtimeOverrides。
 *
 * @param base 模型/Provider 配置的基准值
 * @param presets 已选 PromptPreset 列表(可选)
 * @param runtimeOverrides 单次请求显式覆盖(可选)
 * @returns 合并后的 EffectiveGenerationSettings
 */
export function resolveEffectiveGenerationSettings(
  base: EffectiveGenerationSettings,
  presets?: PromptPreset[],
  runtimeOverrides?: RuntimeGenerationOverrides
): EffectiveGenerationSettings {
  let temperature: number | undefined = base.temperature;
  let topP: number | undefined = base.topP;
  let maxOutputTokens: number | undefined = base.maxOutputTokens;
  let contextWindow: number | undefined = base.contextWindow;

  // Presets 覆盖(已定义的字段,按选择顺序后选覆盖先选)
  if (presets !== undefined && presets !== null) {
    for (let i = 0; i < presets.length; i++) {
      const preset: PromptPreset = presets[i];
      if (preset.temperature !== undefined) {
        temperature = preset.temperature;
      }
      if (preset.topP !== undefined) {
        topP = preset.topP;
      }
      if (preset.maxOutputTokens !== undefined) {
        maxOutputTokens = preset.maxOutputTokens;
      }
      if (preset.contextWindow !== undefined) {
        contextWindow = preset.contextWindow;
      }
    }
  }

  // Runtime Override 覆盖(最高优先级)
  if (runtimeOverrides !== undefined && runtimeOverrides !== null) {
    if (runtimeOverrides.temperature !== undefined) {
      temperature = runtimeOverrides.temperature;
    }
    if (runtimeOverrides.topP !== undefined) {
      topP = runtimeOverrides.topP;
    }
    if (runtimeOverrides.maxOutputTokens !== undefined) {
      maxOutputTokens = runtimeOverrides.maxOutputTokens;
    }
    if (runtimeOverrides.contextWindow !== undefined) {
      contextWindow = runtimeOverrides.contextWindow;
    }
  }

  const result: EffectiveGenerationSettings = {
    temperature: temperature,
    topP: topP,
    maxOutputTokens: maxOutputTokens,
    contextWindow: contextWindow
  };

  validateEffectiveGenerationSettings(result);
  return result;
}

/**
 * 校验合并后的生成参数。
 * 非法组合抛 Error。
 *
 * @param settings 合并后的参数
 */
export function validateEffectiveGenerationSettings(
  settings: EffectiveGenerationSettings
): void {
  // temperature 范围
  if (settings.temperature !== undefined) {
    if (!Number.isFinite(settings.temperature) ||
      settings.temperature < 0.0 || settings.temperature > 2.0) {
      throw new Error('temperature 必须在 0 到 2 之间');
    }
  }

  // topP 范围
  if (settings.topP !== undefined) {
    if (!Number.isFinite(settings.topP) ||
      settings.topP < 0.0 || settings.topP > 1.0) {
      throw new Error('topP 必须在 0 到 1 之间');
    }
  }

  // maxOutputTokens 必须是正整数
  if (settings.maxOutputTokens !== undefined) {
    if (!Number.isInteger(settings.maxOutputTokens) ||
      settings.maxOutputTokens <= 0) {
      throw new Error('最大输出 Token 必须是正整数');
    }
  }

  // contextWindow 必须是正整数
  if (settings.contextWindow !== undefined) {
    if (!Number.isInteger(settings.contextWindow) ||
      settings.contextWindow <= 0) {
      throw new Error('上下文窗口必须是正整数');
    }
  }

  // maxOutputTokens >= contextWindow 时拒绝
  if (settings.maxOutputTokens !== undefined &&
    settings.contextWindow !== undefined) {
    if (settings.maxOutputTokens >= settings.contextWindow) {
      throw new Error('预设的最大输出 Token 必须小于上下文窗口');
    }
  }
}

/**
 * 从 EffectiveGenerationSettings 创建空的请求快照(无 Preset)。
 * @param settings 生效的生成参数
 * @returns 快照
 */
export function createSnapshotWithoutPreset(
  settings: EffectiveGenerationSettings
): PromptPresetRequestSnapshot {
  return {
    presetId: undefined,
    presetSystemPrompt: undefined,
    generationSettings: settings
  };
}

/**
 * 从多个已选 Preset 和合并后的参数创建请求快照。
 * 多个 Preset 的 systemPrompt 按选择顺序以空行拼接。
 * @param presets 已选 Preset 列表
 * @param settings 合并后的生成参数
 * @returns 快照
 */
export function createSnapshotWithPresets(
  presets: PromptPreset[],
  settings: EffectiveGenerationSettings
): PromptPresetRequestSnapshot {
  const parts: string[] = [];
  for (let i = 0; i < presets.length; i++) {
    const sp: string = presets[i].systemPrompt.trim();
    if (sp.length > 0) {
      parts.push(sp);
    }
  }
  const combined: string = parts.join('\n\n');
  return {
    presetId: undefined,
    presetSystemPrompt: combined.length > 0 ? combined : undefined,
    generationSettings: settings
  };
}