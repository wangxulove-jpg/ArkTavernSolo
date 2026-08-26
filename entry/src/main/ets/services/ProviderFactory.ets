/**
 * ProviderFactory Provider 工厂
 *
 * 根据 ProviderType 创建对应的 AiProvider 实例。
 * 每次调用 create 返回独立实例,避免共享状态。
 *
 * 当前正式支持:
 * - OpenAICompatible / OpenAI / DeepSeek / MiMo / OpenRouter → OpenAIProvider
 * - Claude / Gemini → UnsupportedProvider
 *
 * 设计原则:
 * - 不缓存 Provider 实例
 * - 不缓存 API Key
 * - 不依赖页面或 ViewModel
 */

import { ProviderConfig } from '../models/ProviderConfig';
import { ProviderType } from '../models/ProviderType';
import {
  ModelServiceError,
  ModelServiceErrorType,
  createModelServiceError
} from '../models/ModelServiceError';
import {
  NetworkError,
  NetworkErrorType
} from '../models/NetworkError';
import { ProviderKeyStore } from '../storage/ProviderKeyStore';
import { AiProvider } from '../network/providers/AiProvider';
import { OpenAIProvider } from '../network/providers/OpenAIProvider';
import { HttpClient } from '../network/core/HttpClient';
import { HarmonyHttpClient } from '../network/core/HarmonyHttpClient';
import {
  HttpStreamTransport,
  TransportRequestOptions,
  TransportAbortHandle
} from '../network/streaming/HttpStreamTransport';
import { TransportCallbacks } from '../network/streaming/StreamTransportTypes';
import { StreamLauncher } from '../network/providers/OpenAIStreamSession';

/**
 * Provider 工厂接口。
 * 每次调用 create 返回一个独立的 Provider 实例(避免共享状态)。
 */
export interface ProviderFactory {
  create(type: ProviderType): AiProvider;
}

/**
 * 默认 Provider 工厂实现:创建 OpenAIProvider 实例。
 */
export class DefaultProviderFactory implements ProviderFactory {
  private readonly keyStore: ProviderKeyStore;

  constructor(keyStore: ProviderKeyStore) {
    this.keyStore = keyStore;
  }

  create(type: ProviderType): AiProvider {
    if (!isOpenAICompatibleType(type)) {
      throw createModelServiceError(
        ModelServiceErrorType.UnsupportedProvider,
        'Unsupported provider type: ' + type
      );
    }
    const httpClient: HttpClient = new HarmonyHttpClient();
    const transport: HttpStreamTransport = new HttpStreamTransport();
    const launcher: StreamLauncher = (
      options: TransportRequestOptions,
      callbacks: TransportCallbacks
    ): TransportAbortHandle => {
      return transport.requestStream(options, callbacks);
    };
    return new OpenAIProvider(httpClient, this.keyStore, launcher);
  }
}

/**
 * 判断 ProviderType 是否为 OpenAI-compatible(当前正式支持)。
 */
export function isOpenAICompatibleType(type: ProviderType): boolean {
  return type === ProviderType.OpenAICompatible
    || type === ProviderType.OpenAI
    || type === ProviderType.DeepSeek
    || type === ProviderType.MiMo
    || type === ProviderType.OpenRouter
    || type === ProviderType.OpenCodeGo
    || type === ProviderType.SiliconFlow
    || type === ProviderType.Zhipu
    || type === ProviderType.Qwen
    || type === ProviderType.Kimi
    || type === ProviderType.Volcengine
    || type === ProviderType.MiniMax;
}

/**
 * 克隆配置并替换 id(用于 testConnection 的临时 alias)。
 */
export function cloneConfigWithId(src: ProviderConfig, newId: string): ProviderConfig {
  return new ProviderConfig(
    newId,
    src.name,
    src.type,
    src.baseUrl,
    src.modelName,
    src.temperature,
    src.topP,
    src.maxTokens,
    src.stream,
    src.enabled,
    src.createdAt,
    src.updatedAt
  );
}

/**
 * 将 ModelServiceError 转换为 NetworkError(用于 streamChat 的 onError 回调)。
 */
export function toNetworkError(error: ModelServiceError): NetworkError {
  return new NetworkError(
    errorTypeFromModelServiceError(error.type),
    error.message,
    error.retryable,
    undefined,
    undefined,
    error.causeMessage
  );
}

/**
 * 创建兜底 Unknown NetworkError。
 */
export function createUnknownNetworkError(message: string): NetworkError {
  return new NetworkError(
    NetworkErrorType.Unknown,
    message,
    false,
    undefined,
    undefined,
    undefined
  );
}

/**
 * 将 ModelServiceErrorType 映射为 NetworkErrorType。
 */
function errorTypeFromModelServiceError(type: ModelServiceErrorType): NetworkErrorType {
  switch (type) {
    case ModelServiceErrorType.ApiKeyMissing:
    case ModelServiceErrorType.UnsupportedProvider:
      return NetworkErrorType.InvalidRequest;
    default:
      return NetworkErrorType.Unknown;
  }
}
