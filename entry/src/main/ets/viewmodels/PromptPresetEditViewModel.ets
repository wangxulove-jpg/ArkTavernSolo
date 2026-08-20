/**
 * PromptPresetEditViewModel 预设编辑状态管理
 *
 * 页面与 PromptPresetService 之间的唯一桥梁。
 * 不直接依赖 Repository、DbHelper 或 Preferences。
 *
 * 表单状态通过 getFormState() 返回快照给页面,由页面 @State formState 持有。
 * 每次初始化根据 presetId 重新加载,支持切换 Preset 编辑。
 */

import { PromptPreset } from '../models/PromptPreset';
import { PromptPresetService } from '../services/PromptPresetService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetEditViewModel';

// ===== 表单状态快照 =====

export interface PromptPresetEditFormState {
  nameInput: string;
  descriptionInput: string;
  systemPromptInput: string;
  overrideTemperature: boolean;
  temperatureInput: string;
  overrideTopP: boolean;
  topPInput: string;
  overrideMaxOutputTokens: boolean;
  maxOutputTokensInput: string;
  overrideContextWindow: boolean;
  contextWindowInput: string;
}

export function emptyFormState(): PromptPresetEditFormState {
  return {
    nameInput: '',
    descriptionInput: '',
    systemPromptInput: '',
    overrideTemperature: false,
    temperatureInput: '',
    overrideTopP: false,
    topPInput: '',
    overrideMaxOutputTokens: false,
    maxOutputTokensInput: '',
    overrideContextWindow: false,
    contextWindowInput: ''
  };
}

export function copyFormState(state: PromptPresetEditFormState): PromptPresetEditFormState {
  return {
    nameInput: state.nameInput,
    descriptionInput: state.descriptionInput,
    systemPromptInput: state.systemPromptInput,
    overrideTemperature: state.overrideTemperature,
    temperatureInput: state.temperatureInput,
    overrideTopP: state.overrideTopP,
    topPInput: state.topPInput,
    overrideMaxOutputTokens: state.overrideMaxOutputTokens,
    maxOutputTokensInput: state.maxOutputTokensInput,
    overrideContextWindow: state.overrideContextWindow,
    contextWindowInput: state.contextWindowInput
  };
}

function formStateFromPreset(preset: PromptPreset): PromptPresetEditFormState {
  return {
    nameInput: preset.name,
    descriptionInput: preset.description,
    systemPromptInput: preset.systemPrompt,
    overrideTemperature: preset.temperature !== undefined,
    temperatureInput: preset.temperature !== undefined ? preset.temperature.toString() : '',
    overrideTopP: preset.topP !== undefined,
    topPInput: preset.topP !== undefined ? preset.topP.toString() : '',
    overrideMaxOutputTokens: preset.maxOutputTokens !== undefined,
    maxOutputTokensInput: preset.maxOutputTokens !== undefined ? preset.maxOutputTokens.toString() : '',
    overrideContextWindow: preset.contextWindow !== undefined,
    contextWindowInput: preset.contextWindow !== undefined ? preset.contextWindow.toString() : ''
  };
}

// ===== 路由参数解析 =====

export interface ParsedPresetEditRoute {
  readonly presetId: string | undefined;
  readonly error: string | undefined;
}

export function parsePresetEditRouteParam(param: Object | undefined): ParsedPresetEditRoute {
  if (param === undefined) {
    return { presetId: undefined, error: undefined };
  }
  const record = param as Record<string, Object | undefined>;
  const idVal = record['presetId'];
  if (idVal === undefined) {
    return { presetId: undefined, error: '页面参数错误:缺少 presetId' };
  }
  if (typeof idVal !== 'string') {
    return { presetId: undefined, error: '页面参数错误:presetId 类型无效' };
  }
  if (idVal.length === 0) {
    return { presetId: undefined, error: undefined };
  }
  return { presetId: idVal, error: undefined };
}

// ===== ViewModel =====

export class PromptPresetEditViewModel {
  isEditing: boolean = false;
  editingPresetId: string = '';

  private readonly presetService: PromptPresetService;
  private disposed: boolean = false;
  private initializedPresetId: string | undefined = undefined;

  constructor(presetService: PromptPresetService) {
    this.presetService = presetService;
  }

  /**
   * 初始化表单状态。
   * @param presetId undefined 或空字符串表示新建模式,非空表示编辑模式。
   * 同一个实例可多次调用以切换编辑不同 Preset。
   */
  async initialize(presetId?: string): Promise<void> {
    if (this.disposed) {
      return;
    }

    // 同一 presetId 重复调用:跳过
    if (presetId === this.initializedPresetId && this.initializedPresetId !== undefined) {
      return;
    }

    this.initializedPresetId = presetId;

    if (presetId !== undefined && presetId.length > 0) {
      this.isEditing = true;
      this.editingPresetId = presetId;
      try {
        const preset: PromptPreset | null = await this.presetService.getById(presetId);
        if (preset !== null) {
          // 加载成功:通过 getFormState 返回快照
          this.isEditing = true;
          this.editingPresetId = presetId;
        } else {
          this.isEditing = false;
          this.editingPresetId = '';
        }
      } catch (e) {
        this.isEditing = false;
        this.editingPresetId = '';
        Logger.error(LOG_TAG, 'load preset failed');
      }
    } else {
      this.isEditing = false;
      this.editingPresetId = '';
    }
  }

  /**
   * 返回当前表单状态快照。页面通过 @State 持有该快照实现响应式。
   */
  async getFormState(presetId?: string): Promise<PromptPresetEditFormState> {
    if (presetId !== undefined && presetId.length > 0) {
      try {
        const preset: PromptPreset | null = await this.presetService.getById(presetId);
        if (preset !== null) {
          return formStateFromPreset(preset);
        }
      } catch (e) {
        Logger.error(LOG_TAG, 'form population failed');
      }
    }
    return emptyFormState();
  }

  /**
   * 校验并保存预设。
   * @param formState 当前表单状态
   * @returns 保存成功返回 true,失败返回 false 并设置对应错误
   */
  async save(formState: PromptPresetEditFormState): Promise<boolean> {
    if (this.disposed) {
      return false;
    }

    // 校验 name
    const name: string = formState.nameInput.trim();
    if (name.length === 0) {
      return false;
    }
    if (name.length > 100) {
      return false;
    }

    // 校验 description
    const description: string = formState.descriptionInput;
    if (description.length > 1000) {
      return false;
    }

    // 解析数值字段
    let temperature: number | undefined = undefined;
    let clearTemperature: boolean = false;
    let topP: number | undefined = undefined;
    let clearTopP: boolean = false;
    let maxOutputTokens: number | undefined = undefined;
    let clearMaxOutputTokens: boolean = false;
    let contextWindow: number | undefined = undefined;
    let clearContextWindow: boolean = false;

    if (formState.overrideTemperature) {
      const parsed: number = parseFloat(formState.temperatureInput);
      if (isNaN(parsed) || !Number.isFinite(parsed)) {
        return false;
      }
      if (parsed < 0.0 || parsed > 2.0) {
        return false;
      }
      temperature = parsed;
    } else {
      clearTemperature = true;
    }

    if (formState.overrideTopP) {
      const parsed: number = parseFloat(formState.topPInput);
      if (isNaN(parsed) || !Number.isFinite(parsed)) {
        return false;
      }
      if (parsed < 0.0 || parsed > 1.0) {
        return false;
      }
      topP = parsed;
    } else {
      clearTopP = true;
    }

    if (formState.overrideMaxOutputTokens) {
      const parsed: number = parseInt(formState.maxOutputTokensInput);
      if (isNaN(parsed) || !Number.isInteger(parsed) || parsed <= 0) {
        return false;
      }
      if (parsed < 1 || parsed > 131072) {
        return false;
      }
      maxOutputTokens = parsed;
    } else {
      clearMaxOutputTokens = true;
    }

    if (formState.overrideContextWindow) {
      const parsed: number = parseInt(formState.contextWindowInput);
      if (isNaN(parsed) || !Number.isInteger(parsed) || parsed <= 0) {
        return false;
      }
      if (parsed < 512 || parsed > 1000000) {
        return false;
      }
      contextWindow = parsed;
    } else {
      clearContextWindow = true;
    }

    // maxOutputTokens < contextWindow 校验
    if (maxOutputTokens !== undefined && contextWindow !== undefined) {
      if (maxOutputTokens >= contextWindow) {
        return false;
      }
    }

    // 保存
    try {
      if (this.isEditing) {
        await this.presetService.update(this.editingPresetId, {
          name: name,
          description: description,
          systemPrompt: formState.systemPromptInput,
          temperature: temperature,
          topP: topP,
          maxOutputTokens: maxOutputTokens,
          contextWindow: contextWindow,
          clearTemperature: clearTemperature,
          clearTopP: clearTopP,
          clearMaxOutputTokens: clearMaxOutputTokens,
          clearContextWindow: clearContextWindow
        });
      } else {
        const created: PromptPreset = await this.presetService.create({
          name: name,
          description: description,
          systemPrompt: formState.systemPromptInput,
          temperature: temperature,
          topP: topP,
          maxOutputTokens: maxOutputTokens,
          contextWindow: contextWindow
        });
        await this.presetService.addSelectedPresetId(created.id);
      }
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'save failed: ' + String(e));
      return false;
    }
  }

  dispose(): void {
    this.disposed = true;
  }
}