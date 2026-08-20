/**
 * ProviderConfig Provider 配置模型
 *
 * 定义 AI Provider 的配置信息。
 * 不包含 API Key 明文,API Key 通过 id 对应的 KeyStore alias 管理。
 *
 * 安全要求:
 * - 不包含 API Key 明文
 * - 不包含 Authorization 头
 * - baseUrl 不在模型构造时偷偷追加路径
 * - 不使用 any
 * - 提供安全默认值
 * - 提供复制或更新配置的明确方式
 * - createdAt、updatedAt 使用毫秒时间戳
 * - 不依赖 ArkUI
 */

import { ProviderType } from './ProviderType';

// ===== 集中定义校验常量 =====

/** temperature 最小值 */
export const TEMPERATURE_MIN: number = 0.0;
/** temperature 最大值 */
export const TEMPERATURE_MAX: number = 2.0;
/** temperature 默认值 */
export const TEMPERATURE_DEFAULT: number = 0.7;

/** topP 最小值 */
export const TOP_P_MIN: number = 0.0;
/** topP 最大值 */
export const TOP_P_MAX: number = 1.0;
/** topP 默认值 */
export const TOP_P_DEFAULT: number = 1.0;

/** maxTokens 最小值 */
export const MAX_TOKENS_MIN: number = 1;
/** maxTokens 最大值 */
export const MAX_TOKENS_MAX: number = 32768;
/** maxTokens 默认值 */
export const MAX_TOKENS_DEFAULT: number = 1024;

/** stream 默认值 */
export const STREAM_DEFAULT: boolean = true;
/** enabled 默认值 */
export const ENABLED_DEFAULT: boolean = true;

/** 默认上下文窗口大小(未显式配置时使用,64k = 65536) */
export const CONTEXT_WINDOW_DEFAULT: number = 65536;

// ===== 校验函数 =====

/**
 * 校验 temperature 是否在有效范围内。
 * @param value 待校验值
 * @returns 是否有效
 */
export function isValidTemperature(value: number): boolean {
  return value >= TEMPERATURE_MIN && value <= TEMPERATURE_MAX;
}

/**
 * 校验 topP 是否在有效范围内。
 * @param value 待校验值
 * @returns 是否有效
 */
export function isValidTopP(value: number): boolean {
  return value >= TOP_P_MIN && value <= TOP_P_MAX;
}

/**
 * 校验 maxTokens 是否在有效范围内。
 * @param value 待校验值
 * @returns 是否有效
 */
export function isValidMaxTokens(value: number): boolean {
  return Number.isInteger(value) && value >= MAX_TOKENS_MIN && value <= MAX_TOKENS_MAX;
}

/**
 * 校验 id 是否非空。
 * @param value 待校验值
 * @returns 是否有效
 */
export function isValidId(value: string): boolean {
  return value.length > 0;
}

/**
 * 校验配置名称是否非空。
 * @param value 待校验值
 * @returns 是否有效
 */
export function isValidName(value: string): boolean {
  return value.length > 0;
}

/**
 * 校验 Base URL 是否非空。
 * @param value 待校验值
 * @returns 是否有效
 */
export function isValidBaseUrl(value: string): boolean {
  return value.length > 0;
}

/**
 * 校验模型名称是否非空。
 * @param value 待校验值
 * @returns 是否有效
 */
export function isValidModelName(value: string): boolean {
  return value.length > 0;
}

// ===== 配置模型 =====

/**
 * Provider 配置模型。
 * 不可变对象,通过 withUpdates 创建新实例。
 * 不包含 API Key 明文。
 */
export class ProviderConfig {
  /** 唯一标识(对应 KeyStore alias 中的 providerId) */
  readonly id: string;
  /** 配置名称(用户可见) */
  readonly name: string;
  /** Provider 类型 */
  readonly type: ProviderType;
  /** Base URL(不自动追加路径) */
  readonly baseUrl: string;
  /** 模型名称 */
  readonly modelName: string;
  /** 采样温度 */
  readonly temperature: number;
  /** 核采样概率 */
  readonly topP: number;
  /** 最大生成 token 数 */
  readonly maxTokens: number;
  /** 上下文窗口大小(可选)。未提供时使用 CONTEXT_WINDOW_DEFAULT(65536, 64k)。 */
  readonly contextWindow?: number;
  /** 是否流式请求 */
  readonly stream: boolean;
  /** 是否启用 */
  readonly enabled: boolean;
  /** 创建时间(毫秒时间戳) */
  readonly createdAt: number;
  /** 更新时间(毫秒时间戳) */
  readonly updatedAt: number;

  constructor(
    id: string,
    name: string,
    type: ProviderType,
    baseUrl: string,
    modelName: string,
    temperature: number,
    topP: number,
    maxTokens: number,
    stream: boolean,
    enabled: boolean,
    createdAt: number,
    updatedAt: number,
    contextWindow?: number
  ) {
    this.id = id;
    this.name = name;
    this.type = type;
    this.baseUrl = baseUrl;
    this.modelName = modelName;
    this.temperature = temperature;
    this.topP = topP;
    this.maxTokens = maxTokens;
    this.contextWindow = contextWindow;
    this.stream = stream;
    this.enabled = enabled;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
  }

  /**
   * 创建带默认值的 ProviderConfig 实例。
   * @param id 唯一标识
   * @param name 配置名称
   * @param type Provider 类型
   * @param baseUrl Base URL
   * @param modelName 模型名称
   * @returns ProviderConfig 实例
   */
  static create(
    id: string,
    name: string,
    type: ProviderType,
    baseUrl: string,
    modelName: string
  ): ProviderConfig {
    const now: number = Date.now();
    return new ProviderConfig(
      id,
      name,
      type,
      baseUrl,
      modelName,
      TEMPERATURE_DEFAULT,
      TOP_P_DEFAULT,
      MAX_TOKENS_DEFAULT,
      STREAM_DEFAULT,
      ENABLED_DEFAULT,
      now,
      now
    );
  }

  /**
   * 创建副本并更新部分字段,updatedAt 自动刷新。
   * @param name 新名称(传 undefined 保持原值)
   * @param type 新类型(传 undefined 保持原值)
   * @param baseUrl 新 Base URL(传 undefined 保持原值)
   * @param modelName 新模型名称(传 undefined 保持原值)
   * @param temperature 新 temperature(传 undefined 保持原值)
   * @param topP 新 topP(传 undefined 保持原值)
   * @param maxTokens 新 maxTokens(传 undefined 保持原值)
   * @param stream 新 stream(传 undefined 保持原值)
   * @param enabled 新 enabled(传 undefined 保持原值)
   * @returns 新的 ProviderConfig 实例
   */
  withUpdates(
    name?: string,
    type?: ProviderType,
    baseUrl?: string,
    modelName?: string,
    temperature?: number,
    topP?: number,
    maxTokens?: number,
    stream?: boolean,
    enabled?: boolean,
    contextWindow?: number
  ): ProviderConfig {
    return new ProviderConfig(
      this.id,
      name !== undefined ? name : this.name,
      type !== undefined ? type : this.type,
      baseUrl !== undefined ? baseUrl : this.baseUrl,
      modelName !== undefined ? modelName : this.modelName,
      temperature !== undefined ? temperature : this.temperature,
      topP !== undefined ? topP : this.topP,
      maxTokens !== undefined ? maxTokens : this.maxTokens,
      stream !== undefined ? stream : this.stream,
      enabled !== undefined ? enabled : this.enabled,
      this.createdAt,
      Date.now(),
      contextWindow !== undefined ? contextWindow : this.contextWindow
    );
  }
}
