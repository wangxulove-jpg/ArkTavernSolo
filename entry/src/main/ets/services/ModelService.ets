/**
 * ModelService 业务编排服务
 *
 * 统一编排 ProviderConfigStore、ProviderKeyStore、AiProvider,
 * 为页面/ViewModel 提供单一入口的业务 API。
 *
 * 设计原则:
 * - 页面只调用 ModelService,不直接接触 Store / KeyStore / Provider
 * - 不缓存 API Key,不将 Key 写入成员变量/Preferences/日志
 * - 不依赖 ArkUI 页面或 ViewModel,不创建全局单例
 * - 所有错误转换为 ModelServiceError
 *
 * 事务策略:
 * - createConfig:先配置后密钥;密钥失败回滚配置删除
 * - updateConfig:先配置后密钥;密钥失败不回滚配置
 * - deleteConfig:先配置后密钥;密钥失败不回滚(密钥残留可接受)
 * - testConnection:不修改正式配置;临时 Key 通过临时 alias,测试后清理
 */

import { common } from '@kit.AbilityKit';
import { ProviderConfig } from '../models/ProviderConfig';
import { ChatRequest, ChatRequestOptions } from '../models/ChatRequest';
import { ChatResponse } from '../models/ChatResponse';
import { ChatMessage, createChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState
} from '../models/ChatStreamTypes';
import { NetworkError } from '../models/NetworkError';
import {
  PreferencesError,
  PreferencesErrorType,
  isPreferencesError
} from '../models/PreferencesError';
import { SecureStorageError } from '../models/SecureStorageError';
import {
  ModelServiceError,
  ModelServiceErrorType,
  createModelServiceError
} from '../models/ModelServiceError';
import { ProviderType } from '../models/ProviderType';
import { ModelListResult, ModelListItem } from '../models/ModelListResult';
import { getPreset } from '../models/ProviderPreset';
import { ProviderConfigStore } from '../storage/ProviderConfigStore';
import { ProviderKeyStore } from '../storage/ProviderKeyStore';
import { AiProvider } from '../network/providers/AiProvider';
import { Logger } from '../utils/Logger';
import {
  ProviderFactory,
  DefaultProviderFactory,
  isOpenAICompatibleType,
  cloneConfigWithId,
  toNetworkError,
  createUnknownNetworkError
} from './ProviderFactory';

const LOG_TAG: string = 'ModelService';
const TEST_ALIAS_PREFIX: string = '__test__.';

/**
 * ModelService 业务编排服务。
 */
export class ModelService {
  private readonly configStore: ProviderConfigStore;
  private readonly keyStore: ProviderKeyStore;
  private readonly providerFactory: ProviderFactory;
  private initialized: boolean = false;

  constructor(
    configStore: ProviderConfigStore,
    keyStore: ProviderKeyStore,
    providerFactory?: ProviderFactory
  ) {
    this.configStore = configStore;
    this.keyStore = keyStore;
    this.providerFactory = providerFactory !== undefined
      ? providerFactory
      : new DefaultProviderFactory(keyStore);
  }

  async initialize(context: common.Context): Promise<void> {
    try {
      await this.configStore.initialize(context);
      this.initialized = true;
    } catch (e) {
      throw this.wrapStorageError(e, 'initialize failed');
    }
  }

  isInitialized(): boolean {
    return this.initialized;
  }

  async listConfigs(): Promise<ProviderConfig[]> {
    this.requireInitialized();
    try {
      return await this.configStore.list();
    } catch (e) {
      throw this.wrapStorageError(e, 'listConfigs failed');
    }
  }

  async getConfig(id: string): Promise<ProviderConfig | null> {
    this.requireInitialized();
    if (id.length === 0) {
      throw createModelServiceError(
        ModelServiceErrorType.ConfigNotFound, 'getConfig: id is empty'
      );
    }
    try {
      return await this.configStore.getById(id);
    } catch (e) {
      throw this.wrapStorageError(e, 'getConfig failed id=' + id);
    }
  }

  async getCurrentConfig(): Promise<ProviderConfig | null> {
    this.requireInitialized();
    try {
      return await this.configStore.getCurrent();
    } catch (e) {
      throw this.wrapStorageError(e, 'getCurrentConfig failed');
    }
  }

  /**
   * 新增 ProviderConfig,可选同时保存 API Key。
   * 事务:先配置后密钥;密钥失败回滚配置删除。
   */
  async createConfig(config: ProviderConfig, apiKey?: string): Promise<void> {
    this.requireInitialized();

    try {
      await this.configStore.save(config);
    } catch (e) {
      throw this.wrapCreateConfigError(e, config.id);
    }

    if (apiKey !== undefined && apiKey.length > 0) {
      try {
        await this.keyStore.saveKey(config.id, apiKey);
      } catch (e) {
        Logger.warn(LOG_TAG, 'createConfig key failed, rollback id=' + config.id);
        await this.rollbackConfigDelete(config.id);
        throw this.wrapKeyError(e, ModelServiceErrorType.PartialFailure,
          'createConfig key save failed, config rolled back');
      }
      return;
    }
  }

  /**
   * 更新 ProviderConfig,可选同时更新 API Key。
   * apiKey=undefined 保留原密钥;apiKey='' 清除密钥;apiKey 非空替换密钥。
   */
  async updateConfig(config: ProviderConfig, apiKey?: string): Promise<void> {
    this.requireInitialized();

    try {
      await this.configStore.update(config);
    } catch (e) {
      throw this.wrapUpdateConfigError(e, config.id);
    }

    if (apiKey === undefined) {
      return;
    }

    if (apiKey.length === 0) {
      try {
        await this.keyStore.removeKey(config.id);
      } catch (e) {
        throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
          'updateConfig key remove failed');
      }
      return;
    }

    try {
      await this.keyStore.replaceKey(config.id, apiKey);
    } catch (e) {
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'updateConfig key replace failed');
    }
  }

  /**
   * 删除 ProviderConfig 及其 API Key。
   * 密钥删除失败不回滚(配置已删除,密钥残留可接受)。
   */
  async deleteConfig(id: string): Promise<void> {
    this.requireInitialized();

    try {
      await this.configStore.remove(id);
    } catch (e) {
      throw this.wrapStorageError(e, 'deleteConfig config remove failed id=' + id);
    }

    try {
      await this.keyStore.removeKey(id);
    } catch (e) {
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'deleteConfig key remove failed, config already deleted');
    }
  }

  async setCurrentConfig(id: string): Promise<void> {
    this.requireInitialized();
    try {
      await this.configStore.setCurrentProviderId(id);
    } catch (e) {
      throw this.wrapSetCurrentError(e, id);
    }
  }

  async hasApiKey(id: string): Promise<boolean> {
    this.requireInitialized();
    try {
      return await this.keyStore.hasKey(id);
    } catch (e) {
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'hasApiKey failed id=' + id);
    }
  }

  async readApiKey(id: string): Promise<string | null> {
    this.requireInitialized();
    try {
      return await this.keyStore.readKey(id);
    } catch (e) {
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'readApiKey failed id=' + id);
    }
  }

  /**
   * 使用当前配置发送非流式聊天请求。
   */
  async sendChat(request: ChatRequest): Promise<ChatResponse> {
    this.requireInitialized();
    const config: ProviderConfig = await this.resolveCurrentConfigForRequest();
    const provider: AiProvider = this.resolveProvider(config);
    try {
      return await provider.sendChat(config, request);
    } catch (e) {
      throw this.wrapNetworkError(e, 'sendChat failed');
    }
  }

  /**
   * 使用当前配置发送流式聊天请求。
   * 同步返回 handle,异步错误通过 callbacks.onError 传递。
   */
  streamChat(request: ChatRequest, callbacks: ChatStreamCallbacks): ChatStreamHandle {
    this.requireInitialized();
    const holder: StreamHandleHolder = createStreamHandleHolder();

    this.startStreamAsync(request, callbacks, holder).then((): void => {
      // 正常完成
    }, (err: Object): void => {
      if (!holder.fired) {
        holder.fired = true;
        const error: NetworkError = err instanceof ModelServiceError
          ? toNetworkError(err)
          : createUnknownNetworkError(String(err));
        callbacks.onError(error);
      }
    });

    return holder.handle;
  }

  /**
   * 使用当前配置发送流式聊天,ModelService 自动注入 modelName。
   * 调用方只需提供 messages 和 options,无需关心具体模型名称。
   */
  streamCurrentChat(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    this.requireInitialized();
    const holder: StreamHandleHolder = createStreamHandleHolder();

    this.startStreamWithMessagesAsync(messages, options, callbacks, holder).then((): void => {
      // 正常完成
    }, (err: Object): void => {
      if (!holder.fired) {
        holder.fired = true;
        const error: NetworkError = err instanceof ModelServiceError
          ? toNetworkError(err)
          : createUnknownNetworkError(String(err));
        callbacks.onError(error);
      }
    });

    return holder.handle;
  }

  /**
   * 使用指定配置发送流式聊天(G-RUNTIME-1C 模型配置快照)。
   *
   * 与 streamCurrentChat 区别:
   * - 调用方传入固定 ProviderConfig(快照),不再重新读取当前配置
   * - 一轮多角色生成时,A/B/C 使用同一快照,用户中途修改设置不影响本轮
   * - 单聊继续使用 streamChat / streamCurrentChat,行为不变
   *
   * 安全:
   * - config 不含 API Key 明文(ProviderConfig 模型本身不含)
   * - API Key 仍通过 KeyStore alias 在 Provider 内部解析
   *
   * @param config 固定的 ProviderConfig 快照
   * @param messages 请求消息
   * @param options 请求参数
   * @param callbacks 流式回调
   * @returns ChatStreamHandle
   */
  streamChatWithConfig(
    config: ProviderConfig,
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks
  ): ChatStreamHandle {
    this.requireInitialized();
    const holder: StreamHandleHolder = createStreamHandleHolder();

    this.startStreamWithConfigAsync(config, messages, options, callbacks, holder).then((): void => {
      // 正常完成
    }, (err: Object): void => {
      if (!holder.fired) {
        holder.fired = true;
        const error: NetworkError = err instanceof ModelServiceError
          ? toNetworkError(err)
          : createUnknownNetworkError(String(err));
        callbacks.onError(error);
      }
    });

    return holder.handle;
  }

  /**
   * 测试指定配置的连接(不修改正式配置)。
   * 传入 apiKey 时使用临时 alias,测试后清理。
   */
  async testConnection(config: ProviderConfig, apiKey?: string): Promise<ChatResponse> {
    this.requireInitialized();

    if (!isOpenAICompatibleType(config.type)) {
      throw createModelServiceError(
        ModelServiceErrorType.UnsupportedProvider,
        'testConnection unsupported type: ' + config.type
      );
    }

    const testAlias: string = TEST_ALIAS_PREFIX + config.id;
    let savedTempKey: boolean = false;

    if (apiKey !== undefined && apiKey.length > 0) {
      try {
        await this.keyStore.removeKey(testAlias);
        await this.keyStore.saveKey(testAlias, apiKey);
        savedTempKey = true;
      } catch (e) {
        throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
          'testConnection temp key save failed');
      }
    }

    const providerConfig: ProviderConfig = savedTempKey
      ? cloneConfigWithId(config, testAlias)
      : config;

    let hasKey: boolean;
    try {
      hasKey = await this.keyStore.hasKey(providerConfig.id);
    } catch (e) {
      await this.cleanupTestKey(savedTempKey, testAlias);
      throw this.wrapKeyError(e, ModelServiceErrorType.StorageFailure,
        'testConnection hasKey failed');
    }
    if (!hasKey) {
      await this.cleanupTestKey(savedTempKey, testAlias);
      throw createModelServiceError(
        ModelServiceErrorType.ApiKeyMissing,
        'testConnection API Key not configured for ' + config.id
      );
    }

    const testMessage: ChatMessage = createChatMessage(
      'test-msg', ChatRole.User, 'Hi', Date.now()
    );
    const testRequest: ChatRequest = {
      model: config.modelName,
      messages: [testMessage],
      temperature: config.temperature,
      topP: config.topP,
      maxTokens: 16,
      stream: false
    };

    const provider: AiProvider = this.resolveProvider(providerConfig);
    let response: ChatResponse;
    try {
      response = await provider.sendChat(providerConfig, testRequest);
    } catch (e) {
      await this.cleanupTestKey(savedTempKey, testAlias);
      throw this.wrapNetworkError(e, 'testConnection request failed');
    }

    await this.cleanupTestKey(savedTempKey, testAlias);
    return response;
  }

  async fetchAvailableModels(config: ProviderConfig, apiKey?: string): Promise<ModelListResult> {
    this.requireInitialized();

    if (!isOpenAICompatibleType(config.type)) {
      return this.fallbackToPreset(config.type);
    }

    let resolvedKey: string | null = null;
    if (apiKey !== undefined && apiKey.length > 0) {
      resolvedKey = apiKey;
    } else {
      try {
        resolvedKey = await this.keyStore.readKey(config.id);
      } catch (_e) {
        resolvedKey = null;
      }
    }

    if (resolvedKey === null) {
      throw createModelServiceError(
        ModelServiceErrorType.ApiKeyMissing,
        'API Key is required to fetch models'
      );
    }

    const provider: AiProvider = this.resolveProvider(config);
    // 对于无预设的自定义 Provider(如 OpenAICompatible),网络失败时
    // 不应静默回退为空列表(会让页面误显示"已获取 0 个模型"且无法切换),
    // 而应透传真实错误,引导用户修正 Base URL / /models 接口。
    let models: ModelListItem[] = [];
    let fetchError: ModelServiceError | null = null;
    try {
      models = await provider.fetchModels(config.baseUrl, resolvedKey as string);
    } catch (e) {
      fetchError = this.wrapNetworkError(e, 'fetchAvailableModels failed');
    }

    if (models.length > 0) {
      const result: ModelListResult = { models: models, source: 'api' };
      return result;
    }

    if (getPreset(config.type) === null) {
      if (fetchError !== null) {
        throw fetchError;
      }
      throw createModelServiceError(
        ModelServiceErrorType.NetworkFailure,
        'Model list is empty'
      );
    }

    if (fetchError !== null) {
      Logger.warn(LOG_TAG, 'fetchAvailableModels failed, falling back to preset');
    }
    return this.fallbackToPreset(config.type);
  }

  private fallbackToPreset(type: ProviderType): ModelListResult {
    const preset = getPreset(type);
    if (preset !== null) {
      const models: ModelListItem[] = [];
      for (let i = 0; i < preset.availableModels.length; i++) {
        const m = preset.availableModels[i];
        const item: ModelListItem = { id: m.id, ownedBy: '' };
        models.push(item);
      }
      const result: ModelListResult = { models: models, source: 'preset' };
      return result;
    }
    const result: ModelListResult = { models: [], source: 'preset' };
    return result;
  }

  // ===== 内部方法 =====

  private async startStreamAsync(
    request: ChatRequest,
    callbacks: ChatStreamCallbacks,
    holder: StreamHandleHolder
  ): Promise<void> {
    let config: ProviderConfig;
    try {
      config = await this.resolveCurrentConfigForRequest();
    } catch (e) {
      if (!holder.fired) {
        holder.fired = true;
        const err: ModelServiceError = e instanceof ModelServiceError
          ? e
          : createModelServiceError(ModelServiceErrorType.Unknown,
            'streamChat resolve config failed', String(e));
        callbacks.onError(toNetworkError(err));
      }
      return;
    }

    const provider: AiProvider = this.resolveProvider(config);

    const wrappedCallbacks: ChatStreamCallbacks = {
      onStart: callbacks.onStart,
      onDelta: callbacks.onDelta,
      onComplete: callbacks.onComplete,
      onError: (error: NetworkError): void => {
        holder.fired = true;
        callbacks.onError(error);
      }
    };

    const innerHandle: ChatStreamHandle = provider.streamChat(config, request, wrappedCallbacks);
    holder.setInner(innerHandle);
  }

  private async startStreamWithMessagesAsync(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks,
    holder: StreamHandleHolder
  ): Promise<void> {
    let config: ProviderConfig;
    try {
      config = await this.resolveCurrentConfigForRequest();
    } catch (e) {
      if (!holder.fired) {
        holder.fired = true;
        const err: ModelServiceError = e instanceof ModelServiceError
          ? e
          : createModelServiceError(ModelServiceErrorType.Unknown,
            'streamCurrentChat resolve config failed', String(e));
        callbacks.onError(toNetworkError(err));
      }
      return;
    }

    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      if (!holder.fired) {
        holder.fired = true;
        const err: ModelServiceError = createModelServiceError(
          ModelServiceErrorType.InvalidConfig,
          'model name is empty for config: ' + config.id
        );
        callbacks.onError(toNetworkError(err));
      }
      return;
    }

    const request: ChatRequest = {
      model: modelName,
      messages: messages,
      temperature: options.temperature,
      topP: options.topP,
      maxTokens: options.maxTokens,
      stream: options.stream,
      reasoningEffort: options.reasoningEffort,
      responseFormatJson: options.responseFormatJson
    };

    const provider: AiProvider = this.resolveProvider(config);

    const wrappedCallbacks: ChatStreamCallbacks = {
      onStart: callbacks.onStart,
      onDelta: callbacks.onDelta,
      onComplete: callbacks.onComplete,
      onError: (error: NetworkError): void => {
        holder.fired = true;
        callbacks.onError(error);
      }
    };

    const innerHandle: ChatStreamHandle = provider.streamChat(config, request, wrappedCallbacks);
    holder.setInner(innerHandle);
  }

  private async startStreamWithConfigAsync(
    config: ProviderConfig,
    messages: ChatMessage[],
    options: ChatRequestOptions,
    callbacks: ChatStreamCallbacks,
    holder: StreamHandleHolder
  ): Promise<void> {
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      if (!holder.fired) {
        holder.fired = true;
        const err: ModelServiceError = createModelServiceError(
          ModelServiceErrorType.InvalidConfig,
          'model name is empty for config: ' + config.id
        );
        callbacks.onError(toNetworkError(err));
      }
      return;
    }

    if (!isOpenAICompatibleType(config.type)) {
      if (!holder.fired) {
        holder.fired = true;
        const err: ModelServiceError = createModelServiceError(
          ModelServiceErrorType.UnsupportedProvider,
          'Unsupported provider type: ' + config.type
        );
        callbacks.onError(toNetworkError(err));
      }
      return;
    }

    const request: ChatRequest = {
      model: modelName,
      messages: messages,
      temperature: options.temperature,
      topP: options.topP,
      maxTokens: options.maxTokens,
      stream: options.stream,
      reasoningEffort: options.reasoningEffort,
      responseFormatJson: options.responseFormatJson
    };

    const provider: AiProvider = this.resolveProvider(config);

    const wrappedCallbacks: ChatStreamCallbacks = {
      onStart: callbacks.onStart,
      onDelta: callbacks.onDelta,
      onComplete: callbacks.onComplete,
      onError: (error: NetworkError): void => {
        holder.fired = true;
        callbacks.onError(error);
      }
    };

    const innerHandle: ChatStreamHandle = provider.streamChat(config, request, wrappedCallbacks);
    holder.setInner(innerHandle);
  }

  private async resolveCurrentConfigForRequest(): Promise<ProviderConfig> {
    let current: ProviderConfig | null;
    try {
      current = await this.configStore.getCurrent();
    } catch (e) {
      throw this.wrapStorageError(e, 'resolveCurrentConfig getCurrent failed');
    }
    if (current === null) {
      throw createModelServiceError(
        ModelServiceErrorType.NoCurrentConfig, 'No current provider config selected'
      );
    }
    if (!current.enabled) {
      throw createModelServiceError(
        ModelServiceErrorType.ConfigDisabled,
        'Current provider config is disabled: ' + current.id
      );
    }
    if (!isOpenAICompatibleType(current.type)) {
      throw createModelServiceError(
        ModelServiceErrorType.UnsupportedProvider,
        'Unsupported provider type: ' + current.type
      );
    }
    return current;
  }

  private resolveProvider(config: ProviderConfig): AiProvider {
    if (!isOpenAICompatibleType(config.type)) {
      throw createModelServiceError(
        ModelServiceErrorType.UnsupportedProvider,
        'Unsupported provider type: ' + config.type
      );
    }
    return this.providerFactory.create(config.type);
  }

  /**
   * Phase 4A-3: 查询当前 Provider 是否支持原生 Tool Calling。
   *
   * - 用于 ChatService 决定是否注入 tools
   * - 不支持时, 普通聊天完全保持原行为
   * - 调用方应在请求开始前调用 (异步读取当前配置)
   */
  async supportsToolCallingForCurrentProvider(): Promise<boolean> {
    this.requireInitialized();
    try {
      const config: ProviderConfig = await this.resolveCurrentConfigForRequest();
      const provider: AiProvider = this.resolveProvider(config);
      return provider.supportsToolCalling();
    } catch (e) {
      // 配置解析失败: 不支持 (兜底)
      return false;
    }
  }

  private requireInitialized(): void {
    if (!this.initialized) {
      throw createModelServiceError(
        ModelServiceErrorType.NotInitialized,
        'ModelService not initialized, call initialize(context) first'
      );
    }
  }

  private async rollbackConfigDelete(id: string): Promise<void> {
    try {
      await this.configStore.remove(id);
    } catch (e) {
      Logger.warn(LOG_TAG, 'rollbackConfigDelete failed id=' + id);
    }
  }

  private async cleanupTestKey(saved: boolean, alias: string): Promise<void> {
    if (!saved) {
      return;
    }
    try {
      await this.keyStore.removeKey(alias);
    } catch (e) {
      Logger.warn(LOG_TAG, 'cleanupTestKey failed alias=' + alias);
    }
  }

  private wrapStorageError(e: Object, context: string): ModelServiceError {
    if (isPreferencesError(e)) {
      const err: PreferencesError = e as PreferencesError;
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, context, this.combineCause(err.message, err.causeMessage)
      );
    }
    if (e instanceof SecureStorageError) {
      const err: SecureStorageError = e as SecureStorageError;
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, context, this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.StorageFailure, context + ': unknown error', String(e)
    );
  }

  private combineCause(message: string, causeMessage?: string): string {
    return causeMessage !== undefined ? message + ' | cause: ' + causeMessage : message;
  }

  private wrapCreateConfigError(e: Object, id: string): ModelServiceError {
    if (isPreferencesError(e)) {
      const err: PreferencesError = e as PreferencesError;
      if (err.type === PreferencesErrorType.AlreadyExists) {
        return createModelServiceError(
          ModelServiceErrorType.ConfigAlreadyExists, 'ProviderConfig already exists: ' + id
        );
      }
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, 'createConfig save failed', this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.StorageFailure, 'createConfig save failed: unknown error', String(e)
    );
  }

  private wrapUpdateConfigError(e: Object, id: string): ModelServiceError {
    if (isPreferencesError(e)) {
      const err: PreferencesError = e as PreferencesError;
      if (err.type === PreferencesErrorType.NotFound) {
        return createModelServiceError(
          ModelServiceErrorType.ConfigNotFound, 'ProviderConfig not found: ' + id
        );
      }
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, 'updateConfig failed', this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.StorageFailure, 'updateConfig failed: unknown error', String(e)
    );
  }

  private wrapKeyError(e: Object, targetType: ModelServiceErrorType, message: string): ModelServiceError {
    if (e instanceof SecureStorageError) {
      const err: SecureStorageError = e as SecureStorageError;
      return createModelServiceError(targetType, message, this.combineCause(err.message, err.causeMessage));
    }
    return createModelServiceError(targetType, message, String(e));
  }

  private wrapSetCurrentError(e: Object, id: string): ModelServiceError {
    if (isPreferencesError(e)) {
      const err: PreferencesError = e as PreferencesError;
      if (err.type === PreferencesErrorType.InvalidSelection) {
        return createModelServiceError(
          ModelServiceErrorType.ConfigNotFound, 'setCurrentConfig: config not found: ' + id
        );
      }
      return createModelServiceError(
        ModelServiceErrorType.StorageFailure, 'setCurrentConfig failed', this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.StorageFailure, 'setCurrentConfig failed: unknown error', String(e)
    );
  }

  private wrapNetworkError(e: Object, message: string): ModelServiceError {
    if (e instanceof NetworkError) {
      const err: NetworkError = e as NetworkError;
      return createModelServiceError(
        ModelServiceErrorType.NetworkFailure, message, this.combineCause(err.message, err.causeMessage)
      );
    }
    return createModelServiceError(
      ModelServiceErrorType.NetworkFailure, message + ': unknown error', String(e)
    );
  }
}

// ===== StreamHandleHolder =====

interface HolderState {
  inner: ChatStreamHandle | null;
}

interface StreamHandleHolder {
  fired: boolean;
  readonly handle: ChatStreamHandle;
  setInner(inner: ChatStreamHandle): void;
}

function createStreamHandleHolder(): StreamHandleHolder {
  const state: HolderState = { inner: null };
  const handle: ChatStreamHandle = new ProxyStreamHandle(state);
  return new StreamHandleHolderImpl(handle, state);
}

class ProxyStreamHandle implements ChatStreamHandle {
  private readonly state: HolderState;

  constructor(state: HolderState) {
    this.state = state;
  }

  abort(): void {
    if (this.state.inner !== null) {
      this.state.inner.abort();
    }
  }

  getState(): ChatStreamState {
    if (this.state.inner !== null) {
      return this.state.inner.getState();
    }
    return ChatStreamState.Idle;
  }
}

class StreamHandleHolderImpl implements StreamHandleHolder {
  fired: boolean = false;
  readonly handle: ChatStreamHandle;
  private readonly state: HolderState;

  constructor(handle: ChatStreamHandle, state: HolderState) {
    this.handle = handle;
    this.state = state;
  }

  setInner(inner: ChatStreamHandle): void {
    this.state.inner = inner;
  }
}
