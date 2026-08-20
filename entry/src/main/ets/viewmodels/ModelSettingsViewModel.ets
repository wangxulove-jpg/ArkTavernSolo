/**
 * ModelSettingsViewModel 模型设置 ViewModel
 *
 * 管理模型配置页面的状态与操作,作为页面与 ModelService 之间的唯一桥梁。
 *
 * 设计原则:
 * - 不依赖具体 ArkUI 页面实例
 * - 不使用全局单例、不使用 any
  * - API Key 从 KeyStore 读取并回显到编辑字段,保存/测试后刷新
 * - 不从 KeyStore 读取并回显原密钥;已有密钥只显示"已配置"
 * - 编辑配置不输入新 Key 时保留旧 Key;新建必须 API Key
 * - 防止重复点击保存、删除和测试连接
 * - 支持 Provider 预设模式:DeepSeek 自动填充 URL/Model,只填 Key 即可
 *
 * 状态机:
 * - selectedConfigId === null:新建模式
 * - selectedConfigId !== null:编辑模式
 */

import { ModelService } from '../services/ModelService';
import { ProviderConfig } from '../models/ProviderConfig';
import { ProviderType } from '../models/ProviderType';
import { ChatResponse } from '../models/ChatResponse';
import {
  ModelServiceError,
  ModelServiceErrorType,
  isModelServiceError
} from '../models/ModelServiceError';
import {
  ProviderPreset,
  ModelOption,
  getPreset,
  hasPreset
} from '../models/ProviderPreset';
import { ModelListItem, ModelListResult } from '../models/ModelListResult';
import { generateUuid } from '../utils/Uuid';
import {
  TEMPERATURE_DEFAULT,
  TOP_P_DEFAULT,
  MAX_TOKENS_DEFAULT,
  STREAM_DEFAULT,
  ENABLED_DEFAULT,
  TEMPERATURE_MIN,
  TEMPERATURE_MAX,
  TOP_P_MIN,
  TOP_P_MAX,
  MAX_TOKENS_MIN,
  MAX_TOKENS_MAX
} from '../models/ProviderConfig';

interface ValidationResult {
  readonly valid: boolean;
  readonly message: string;
}

/**
 * 模型设置 ViewModel。
 * 使用 @Observed 装饰,使页面能响应字段变更。
 */
@Observed
export class ModelSettingsViewModel {
  // ===== 列表状态 =====
  configs: ProviderConfig[] = [];
  currentConfigId: string | null = null;

  // ===== 表单状态 =====
  selectedConfigId: string | null = null;
  name: string = '';
  providerType: ProviderType = ProviderType.OpenAICompatible;
  baseUrl: string = '';
  modelName: string = '';
  apiKey: string = '';
  temperature: number = TEMPERATURE_DEFAULT;
  topP: number = TOP_P_DEFAULT;
  maxTokens: number = MAX_TOKENS_DEFAULT;
  stream: boolean = STREAM_DEFAULT;
  enabled: boolean = ENABLED_DEFAULT;
  apiKeyConfigured: boolean = false;

  // ===== 预设模式状态 =====
  /** 当前 Provider 的预设(无预设时为 null) */
  activePreset: ProviderPreset | null = null;
  /** 预设模式下选中的模型索引(-1 表示无) */
  selectedModelIndex: number = -1;
  /** 使用预设模式(baseUrl/modelName 自动填充,页面隐藏对应输入) */
  get isPresetMode(): boolean {
    return this.activePreset !== null;
  }

  // ===== 动态模型列表状态 =====
  /** 动态获取的模型列表(null 表示未获取,使用预设) */
  dynamicModels: ModelOption[] | null = null;
  /** 是否正在获取模型列表 */
  isFetchingModels: boolean = false;
  /** 模型获取状态消息 */
  fetchModelsMessage: string = '';
  /** 动态获取的模型列表来源 */
  private dynamicModelsSource: 'api' | 'preset' | null = null;
  /** 实际展示的模型列表 */
  get displayedModels(): ModelOption[] {
    if (this.dynamicModels !== null) {
      return this.dynamicModels;
    }
    if (this.activePreset !== null) {
      return this.activePreset.availableModels;
    }
    return [];
  }
  /** 是否有可展示的模型列表(预设或动态获取) */
  get hasModelList(): boolean {
    return this.displayedModels.length > 0;
  }
  /** 动态获取的来源 */
  get modelsSource(): string {
    return this.dynamicModelsSource !== null ? this.dynamicModelsSource : 'preset';
  }

  // ===== 交互状态 =====
  isLoading: boolean = false;
  isSaving: boolean = false;
  isTesting: boolean = false;
  statusMessage: string = '';
  errorMessage: string = '';
  /** API Key 显隐切换(页面自行掩码,非系统 Password) */
  showApiKey: boolean = true;

  // ===== 当前配置摘要卡状态 =====
  /** 当前配置的 API Key 明文(用于主页摘要卡显示,空=未配置) */
  currentConfigApiKeyDisplay: string = '';

  // ===== UI-2 编辑页状态 =====
  /** 编辑页当前 Tab:0=连接,1=参数 */
  activeEditTab: number = 0;
  /** 服务商选择 Sheet 是否打开 */
  providerSheetOpen: boolean = false;
  /** 模型选择 Sheet 是否打开 */
  modelSheetOpen: boolean = false;

  // ===== 字段级错误(供编辑页显示) =====
  nameError: string = '';
  apiKeyError: string = '';

  private modelService: ModelService;

  constructor(modelService: ModelService) {
    this.modelService = modelService;
  }

  // ===== 公共方法 =====

  async initialize(): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.configs = await this.modelService.listConfigs();
      const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
      this.currentConfigId = current !== null ? current.id : null;
      await this.loadCurrentConfigApiKey(this.currentConfigId);
      if (this.configs.length > 0) {
        await this.selectConfig(this.configs[0].id);
      } else {
        this.startCreate();
      }
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '加载配置失败');
    } finally {
      this.isLoading = false;
    }
  }

  async selectConfig(id: string): Promise<void> {
    this.selectedConfigId = id;
    this.apiKey = '';
    this.errorMessage = '';
    this.statusMessage = '';
    this.clearFieldErrors();
    try {
      const config: ProviderConfig | null = await this.modelService.getConfig(id);
      if (config === null) {
        this.errorMessage = '配置不存在';
        return;
      }
      this.populateForm(config);
      const existingKey: string | null = await this.modelService.readApiKey(id);
      this.apiKey = existingKey !== null ? existingKey : '';
      this.apiKeyConfigured = existingKey !== null;
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '读取配置失败');
    }
  }

  async refreshConfigList(): Promise<void> {
    try {
      this.configs = await this.modelService.listConfigs();
      const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
      this.currentConfigId = current !== null ? current.id : null;
      await this.loadCurrentConfigApiKey(this.currentConfigId);
    } catch (_e) {
      // 静默刷新,不干扰当前操作
    }
  }

  startCreate(): void {
    this.selectedConfigId = null;
    this.name = '';
    this.providerType = ProviderType.OpenAICompatible;
    this.baseUrl = '';
    this.modelName = '';
    this.apiKey = '';
    this.temperature = TEMPERATURE_DEFAULT;
    this.topP = TOP_P_DEFAULT;
    this.maxTokens = MAX_TOKENS_DEFAULT;
    this.stream = STREAM_DEFAULT;
    this.enabled = ENABLED_DEFAULT;
    this.apiKeyConfigured = false;
    this.errorMessage = '';
    this.statusMessage = '';
    this.dynamicModels = null;
    this.dynamicModelsSource = null;
    this.fetchModelsMessage = '';
    this.applyPresetForType(ProviderType.OpenAICompatible);
  }

  /**
   * 切换 Provider 类型。
   * 页面 Select onChange 时调用,自动应用预设。
   */
  onProviderTypeChange(type: ProviderType): void {
    this.providerType = type;
    this.errorMessage = '';
    this.applyPresetForType(type);
  }

  async save(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';

    const validation: ValidationResult = this.validateForm();
    if (!validation.valid) {
      this.errorMessage = validation.message;
      return;
    }

    this.isSaving = true;
    try {
      if (this.selectedConfigId === null) {
        await this.saveNew();
      } else {
        await this.saveUpdate();
      }
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '保存失败');
    } finally {
      this.isSaving = false;
    }
  }

  async deleteSelected(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    if (this.selectedConfigId === null) {
      this.errorMessage = '新建模式无法删除';
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    this.statusMessage = '';
    const targetId: string = this.selectedConfigId;
    try {
      await this.modelService.deleteConfig(targetId);
      this.configs = await this.modelService.listConfigs();
      const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
      this.currentConfigId = current !== null ? current.id : null;
      await this.loadCurrentConfigApiKey(this.currentConfigId);
      if (this.configs.length > 0) {
        await this.selectConfig(this.configs[0].id);
      } else {
        this.startCreate();
      }
      this.statusMessage = '已删除';
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '删除失败');
    } finally {
      this.isSaving = false;
    }
  }

  async setCurrent(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    if (this.selectedConfigId === null) {
      this.errorMessage = '请先保存配置';
      return;
    }
    if (!this.isSupportedType(this.providerType)) {
      this.errorMessage = '当前不支持的 Provider 类型';
      return;
    }
    this.isSaving = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      await this.modelService.setCurrentConfig(this.selectedConfigId);
      this.currentConfigId = this.selectedConfigId;
      await this.loadCurrentConfigApiKey(this.currentConfigId);
      this.statusMessage = '已设为当前配置';
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '设置当前配置失败');
    } finally {
      this.isSaving = false;
    }
  }

  async testConnection(): Promise<void> {
    if (this.isTesting) {
      return;
    }
    const validation: ValidationResult = this.validateForm();
    if (!validation.valid) {
      this.errorMessage = validation.message;
      return;
    }
    if (!this.isSupportedType(this.providerType)) {
      this.errorMessage = '当前不支持的 Provider 类型';
      return;
    }
    this.isTesting = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const tempConfig: ProviderConfig = this.buildFormConfig(
        this.selectedConfigId !== null ? this.selectedConfigId : generateUuid()
      );
      const apiKeyParam: string | undefined = this.apiKey.length > 0 ? this.apiKey : undefined;
      const response: ChatResponse = await this.modelService.testConnection(tempConfig, apiKeyParam);
      this.statusMessage = this.formatTestResult(response);
    } catch (e) {
      this.errorMessage = this.toUserMessage(e, '连接测试失败');
    } finally {
      if (this.selectedConfigId !== null) {
        const existingKey: string | null = await this.modelService.readApiKey(this.selectedConfigId);
        this.apiKey = existingKey !== null ? existingKey : '';
      } else {
        this.apiKey = '';
      }
      this.isTesting = false;
    }
  }

  clearApiKeyInput(): void {
    this.apiKey = '';
  }

  canFetchModels(): boolean {
    const hasKey: boolean = this.apiKey.trim().length > 0 || this.apiKeyConfigured;
    const hasUrl: boolean = this.baseUrl.trim().length > 0;
    return hasKey && hasUrl && this.isSupportedType(this.providerType);
  }

  async fetchModels(): Promise<void> {
    if (this.isFetchingModels) {
      return;
    }
    if (!this.canFetchModels()) {
      this.fetchModelsMessage = '需要填写 API Key 和 Base URL';
      return;
    }
    this.isFetchingModels = true;
    this.fetchModelsMessage = '';
    try {
      const tempConfig: ProviderConfig = this.buildFormConfig(
        this.selectedConfigId !== null ? this.selectedConfigId : generateUuid()
      );
      const apiKeyParam: string | undefined = this.apiKey.length > 0 ? this.apiKey : undefined;
      const result: ModelListResult = await this.modelService.fetchAvailableModels(tempConfig, apiKeyParam);
      const options: ModelOption[] = [];
      for (let i = 0; i < result.models.length; i++) {
        const m: ModelListItem = result.models[i];
        const opt: ModelOption = {
          id: m.id,
          displayName: m.id,
          description: m.ownedBy.length > 0 ? m.ownedBy : undefined
        };
        options.push(opt);
      }
      this.dynamicModels = options;
      this.dynamicModelsSource = result.source;
      this.fetchModelsMessage = '已获取 ' + options.length.toString() + ' 个模型';
      this.syncModelIndexFromName(this.modelName);
    } catch (e) {
      this.dynamicModels = null;
      this.dynamicModelsSource = null;
      this.fetchModelsMessage = this.toUserMessage(e, '获取模型列表失败');
    } finally {
      this.isFetchingModels = false;
    }
  }

  // ===== UI-2 编辑页交互方法 =====

  /** 切换编辑页 Tab */
  setActiveEditTab(index: number): void {
    if (index >= 0 && index <= 1) {
      this.activeEditTab = index;
    }
  }

  /** 打开服务商选择 Sheet */
  openProviderSheet(): void {
    this.providerSheetOpen = true;
  }

  /** 关闭服务商选择 Sheet(不修改选择) */
  closeProviderSheet(): void {
    this.providerSheetOpen = false;
  }

  /** 在 Sheet 中选择 Provider */
  selectProviderFromSheet(type: ProviderType): void {
    this.providerSheetOpen = false;
    this.onProviderTypeChange(type);
  }

  /** 打开模型选择 Sheet */
  openModelSheet(): void {
    if (this.displayedModels.length === 0) {
      return;
    }
    this.modelSheetOpen = true;
  }

  /** 关闭模型选择 Sheet(不修改选择) */
  closeModelSheet(): void {
    this.modelSheetOpen = false;
  }

  /** 在 Sheet 中选择模型 */
  selectModelFromSheet(index: number): void {
    this.modelSheetOpen = false;
    this.onModelSelect(index);
  }

  /** 清空字段级错误 */
  clearFieldErrors(): void {
    this.nameError = '';
    this.apiKeyError = '';
  }

  /**
   * 检查表单是否有效,不设置全局错误信息,但可填充字段级错误。
   * 返回 true 表示可以保存/测试。
   */
  checkFormValid(): boolean {
    this.clearFieldErrors();
    if (this.name.trim().length === 0) {
      this.nameError = '请输入配置名称';
      return false;
    }
    if (!this.isSupportedType(this.providerType)) {
      return false;
    }
    if (this.selectedConfigId === null && this.apiKey.trim().length === 0) {
      this.apiKeyError = '请输入 API Key';
      return false;
    }
    return true;
  }

  dispose(): void {
    this.apiKey = '';
    this.errorMessage = '';
    this.statusMessage = '';
  }

  isSupportedType(type: ProviderType): boolean {
    return type === ProviderType.OpenAICompatible
      || type === ProviderType.OpenAI
      || type === ProviderType.DeepSeek
      || type === ProviderType.MiMo
      || type === ProviderType.OpenRouter
      || type === ProviderType.OpenCodeGo
      || type === ProviderType.SiliconFlow;
  }

  // ===== 内部方法 =====

  private populateForm(config: ProviderConfig): void {
    this.name = config.name;
    this.providerType = config.type;
    this.baseUrl = config.baseUrl;
    this.modelName = config.modelName;
    this.temperature = config.temperature;
    this.topP = config.topP;
    this.maxTokens = config.maxTokens;
    this.stream = config.stream;
    this.enabled = config.enabled;
    this.dynamicModels = null;
    this.dynamicModelsSource = null;
    this.fetchModelsMessage = '';
    const preset: ProviderPreset | null = getPreset(config.type);
    this.activePreset = preset;
    if (preset !== null) {
      this.syncModelIndexFromName(config.modelName);
    } else {
      this.selectedModelIndex = -1;
    }
  }

  private syncModelIndexFromName(modelName: string): void {
    const models: ModelOption[] = this.displayedModels;
    for (let i = 0; i < models.length; i++) {
      if (models[i].id === modelName) {
        this.selectedModelIndex = i;
        return;
      }
    }
    this.selectedModelIndex = -1;
  }

  /**
   * 根据 Provider 类型应用预设。
   */
  private applyPresetForType(type: ProviderType): void {
    const preset: ProviderPreset | null = getPreset(type);
    this.activePreset = preset;
    this.dynamicModels = null;
    this.dynamicModelsSource = null;
    this.fetchModelsMessage = '';

    if (preset !== null) {
      this.baseUrl = preset.defaultBaseUrl;
      this.selectedModelIndex = 0;
      this.modelName = preset.defaultModel.id;
      // 自动命名
      if (this.name.length === 0 || this.name === this.modelName) {
        this.name = preset.defaultModel.displayName;
      }
    } else {
      this.selectedModelIndex = -1;
      // 从预设模式切换回自定义模式时,清空 baseUrl/modelName
      if (type !== ProviderType.DeepSeek) {
        this.baseUrl = '';
        this.modelName = '';
      }
    }
  }

  /**
   * 切换预设模式下的模型选择。
   */
  onModelSelect(index: number): void {
    const models: ModelOption[] = this.displayedModels;
    if (index >= 0 && index < models.length) {
      this.selectedModelIndex = index;
      this.modelName = models[index].id;
      const oldDisplayName: string = (this.selectedModelIndex >= 0 && this.selectedModelIndex < models.length)
        ? models[this.selectedModelIndex].displayName
        : '';
      if (this.name.length === 0 || this.name === oldDisplayName || this.name === this.modelName) {
        this.name = models[index].displayName;
      }
    }
  }

  private async saveNew(): Promise<void> {
    const id: string = generateUuid();
    const config: ProviderConfig = this.buildFormConfig(id);
    const apiKeyToSave: string = this.apiKey;
    await this.modelService.createConfig(config, apiKeyToSave);
    this.configs = await this.modelService.listConfigs();
    const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (current === null) {
      await this.modelService.setCurrentConfig(id);
      this.currentConfigId = id;
    } else {
      this.currentConfigId = current.id;
    }
    this.selectedConfigId = id;
    this.errorMessage = '';
    this.clearFieldErrors();
    this.populateForm(config);
    this.statusMessage = '配置保存成功';
    const savedKey: string | null = await this.modelService.readApiKey(id);
    this.apiKey = savedKey !== null ? savedKey : '';
    this.apiKeyConfigured = savedKey !== null;
    await this.loadCurrentConfigApiKey(this.currentConfigId);
  }

  private async saveUpdate(): Promise<void> {
    const config: ProviderConfig = this.buildFormConfig(this.selectedConfigId as string);
    const apiKeyParam: string | undefined = this.apiKey.length > 0 ? this.apiKey : undefined;
    await this.modelService.updateConfig(config, apiKeyParam);
    this.configs = await this.modelService.listConfigs();
    const current: ProviderConfig | null = await this.modelService.getCurrentConfig();
    this.currentConfigId = current !== null ? current.id : null;
    this.errorMessage = '';
    this.clearFieldErrors();
    this.populateForm(config);
    this.statusMessage = '配置保存成功';
    const savedKey: string | null = await this.modelService.readApiKey(this.selectedConfigId as string);
    this.apiKey = savedKey !== null ? savedKey : '';
    if (this.currentConfigId === (this.selectedConfigId as string)) {
      await this.loadCurrentConfigApiKey(this.currentConfigId);
    }
  }

  private buildFormConfig(id: string): ProviderConfig {
    const now: number = Date.now();
    return new ProviderConfig(
      id,
      this.name,
      this.providerType,
      this.baseUrl,
      this.modelName,
      this.temperature,
      this.topP,
      this.maxTokens,
      this.stream,
      this.enabled,
      now,
      now
    );
  }

  private validateForm(): ValidationResult {
    if (this.name.trim().length === 0) {
      return { valid: false, message: '请输入配置名称' };
    }
    if (!this.isSupportedType(this.providerType)) {
      return { valid: false, message: '该 Provider 类型暂未支持' };
    }

    if (this.isPresetMode) {
      // 预设模式:baseUrl/modelName 由预设生成,不要求用户填写,但仍需非空
      if (this.baseUrl.trim().length === 0) {
        return { valid: false, message: '预设 Base URL 未配置' };
      }
      if (this.modelName.trim().length === 0) {
        return { valid: false, message: '请选择模型' };
      }
    } else {
      // 自定义模式:要求用户填写 baseUrl 和 modelName
      if (this.baseUrl.trim().length === 0) {
        return { valid: false, message: '请输入 Base URL' };
      }
      if (!this.isValidUrl(this.baseUrl)) {
        return { valid: false, message: 'Base URL 格式不合法' };
      }
      if (this.modelName.trim().length === 0) {
        return { valid: false, message: '请输入模型名称' };
      }
    }

    if (this.temperature < TEMPERATURE_MIN || this.temperature > TEMPERATURE_MAX) {
      return { valid: false, message: 'Temperature 必须在 ' + TEMPERATURE_MIN + ' ~ ' + TEMPERATURE_MAX };
    }
    if (this.topP < TOP_P_MIN || this.topP > TOP_P_MAX) {
      return { valid: false, message: 'Top P 必须在 ' + TOP_P_MIN + ' ~ ' + TOP_P_MAX };
    }
    if (!Number.isInteger(this.maxTokens) || this.maxTokens < MAX_TOKENS_MIN || this.maxTokens > MAX_TOKENS_MAX) {
      return { valid: false, message: 'Max Tokens 必须为整数且在 ' + MAX_TOKENS_MIN + ' ~ ' + MAX_TOKENS_MAX };
    }
    if (this.selectedConfigId === null && this.apiKey.trim().length === 0) {
      return { valid: false, message: '新建配置必须输入 API Key' };
    }
    return { valid: true, message: '' };
  }

  private isValidUrl(url: string): boolean {
    if (url.startsWith('https://') && url.length > 8) {
      return true;
    }
    if (url.startsWith('http://') && url.length > 7) {
      return true;
    }
    return false;
  }

  private formatTestResult(response: ChatResponse): string {
    const parts: string[] = ['连接成功'];
    if (response.model !== undefined && response.model.length > 0) {
      parts.push('模型: ' + response.model);
    }
    if (response.totalTokens !== undefined) {
      parts.push('tokens: ' + response.totalTokens.toString());
    } else if (response.promptTokens !== undefined && response.completionTokens !== undefined) {
      parts.push('tokens: ' + (response.promptTokens + response.completionTokens).toString());
    }
    return parts.join(' | ');
  }

  private toUserMessage(e: Object, fallback: string): string {
    if (isModelServiceError(e)) {
      const err: ModelServiceError = e as ModelServiceError;
      switch (err.type) {
        case ModelServiceErrorType.ConfigNotFound:
          return '配置不存在';
        case ModelServiceErrorType.ConfigAlreadyExists:
          return '配置已存在';
        case ModelServiceErrorType.ApiKeyMissing:
          return 'API Key 未配置';
        case ModelServiceErrorType.UnsupportedProvider:
          return '该 Provider 类型暂未支持';
        case ModelServiceErrorType.NoCurrentConfig:
          return '未选择当前配置';
        case ModelServiceErrorType.ConfigDisabled:
          return '当前配置已禁用';
        case ModelServiceErrorType.NotInitialized:
          return '服务未初始化';
        case ModelServiceErrorType.NetworkFailure:
          return '网络连接失败,请检查网络或 Base URL';
        case ModelServiceErrorType.StorageFailure:
          return '存储失败,请重试';
        case ModelServiceErrorType.PartialFailure:
          return '部分操作失败,请重试';
        default:
          return fallback;
      }
    }
    return fallback;
  }

  private async loadCurrentConfigApiKey(configId: string | null): Promise<void> {
    if (configId !== null) {
      const key: string | null = await this.modelService.readApiKey(configId);
      this.currentConfigApiKeyDisplay = key !== null ? key : '';
    } else {
      this.currentConfigApiKeyDisplay = '';
    }
  }
}