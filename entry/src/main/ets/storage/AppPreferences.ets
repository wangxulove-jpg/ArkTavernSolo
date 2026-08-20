/**
 * AppPreferences HarmonyOS Preferences Kit 封装
 *
 * 基于 @ohos.data.preferences (ArkData) 提供非敏感配置的 Key-Value 持久化能力。
 * 业务层(Service / ProviderConfigStore)通过本类访问 Preferences,不直接调用平台 API。
 *
 * 设计原则:
 * - 只保存非敏感配置(字符串、数字、布尔)
 * - 不保存 API Key、Authorization、secret(这些走 KeyStore)
 * - 不依赖 Provider 业务结构
 * - 所有错误转换为 PreferencesError
 * - 不缓存值,每次都从 Preferences 实例读取
 * - 写入后必须 flush(XML 存储模式需要显式落盘)
 *
 * Context 生命周期:
 * - 使用 ApplicationContext 或 UIAbility Context
 * - 不保存短生命周期 Page Context
 * - Preferences 实例由平台缓存,跨调用复用
 *
 * 并发说明:
 * - HarmonyOS Preferences 不保证进程并发安全
 * - 本类不做并发控制,由上层 ProviderConfigStore 通过 Promise 串行化保证写安全
 *
 * 实际使用的 HarmonyOS API:
 * - @kit.ArkData 的 preferences.getPreferences(context, name): Promise<Preferences>(since 9)
 * - Preferences.put(key, value): Promise<void>(since 9,覆盖已存在的 key)
 * - Preferences.get(key, defValue): Promise<ValueType>(since 9)
 * - Preferences.has(key): Promise<boolean>(since 9)
 * - Preferences.delete(key): Promise<void>(since 9)
 * - Preferences.clear(): Promise<void>(since 9,清空所有 key)
 * - Preferences.flush(): Promise<void>(since 9,XML 模式下显式落盘)
 */

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import {
  PreferencesErrorType,
  createPreferencesError,
  fromPlatformError,
  PreferencesError
} from '../models/PreferencesError';
import { Logger } from '../utils/Logger';

/** 日志标签 */
const LOG_TAG: string = 'AppPreferences';

/** Preferences 文件名 */
const PREFERENCES_STORE_NAME: string = 'arktavern_solo_settings';

/**
 * HarmonyOS Preferences Kit 封装。
 * 提供基础 Key-Value 操作,不知道 Provider 业务结构。
 */
export class AppPreferences {
  /** Preferences 实例(初始化后非空) */
  private prefs: preferences.Preferences | null = null;
  /** Preferences 文件名 */
  private readonly storeName: string;

  /**
   * 构造 AppPreferences。
   * 默认使用 arktavern_settings 作为文件名。
   *
   * @param storeName Preferences 文件名(可选,默认 arktavern_settings)
   */
  constructor(storeName: string = PREFERENCES_STORE_NAME) {
    this.storeName = storeName;
  }

  /**
   * 初始化 Preferences 实例。
   * 必须在所有读写操作前调用。
   *
   * @param context ApplicationContext 或 UIAbility Context
   * @throws PreferencesError 当平台初始化失败时
   */
  async initialize(context: common.Context): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(context, this.storeName);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'initialize failed code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 检查是否已初始化。
   * @returns 已初始化返回 true
   */
  isInitialized(): boolean {
    return this.prefs !== null;
  }

  /**
   * 获取 Preferences 实例(内部使用)。
   * @returns Preferences 实例
   * @throws PreferencesError 当未初始化时
   */
  private requirePrefs(): preferences.Preferences {
    if (this.prefs === null) {
      throw createPreferencesError(
        PreferencesErrorType.NotInitialized,
        'AppPreferences not initialized',
        undefined,
        undefined
      );
    }
    return this.prefs;
  }

  /**
   * 读取字符串值。
   * 不存在时返回 defValue,不抛 NotFound。
   *
   * @param key 键名(非空,长度 ≤ 1024 字节)
   * @param defValue 默认值
   * @returns 字符串值或默认值
   * @throws PreferencesError 当未初始化、key 非法、平台错误时
   */
  async getString(key: string, defValue: string): Promise<string> {
    this.validateKey(key);
    const prefs: preferences.Preferences = this.requirePrefs();
    try {
      const value: preferences.ValueType = await prefs.get(key, defValue);
      if (typeof value === 'string') {
        return value;
      }
      // 类型不匹配,返回默认值(不抛错,容错处理)
      Logger.warn(LOG_TAG, 'getString type mismatch, return default key=' + key);
      return defValue;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'getString failed key=' + key + ' code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 写入字符串值。
   * 已存在的 key 会被覆盖。写入后自动 flush。
   *
   * @param key 键名(非空,长度 ≤ 1024 字节)
   * @param value 字符串值
   * @throws PreferencesError 当未初始化、key 非法、平台错误时
   */
  async putString(key: string, value: string): Promise<void> {
    this.validateKey(key);
    const prefs: preferences.Preferences = this.requirePrefs();
    try {
      await prefs.put(key, value);
      await prefs.flush();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'putString failed key=' + key + ' code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 读取布尔值。
   * 不存在时返回 defValue,不抛 NotFound。
   *
   * @param key 键名(非空,长度 ≤ 1024 字节)
   * @param defValue 默认值
   * @returns 布尔值或默认值
   * @throws PreferencesError 当未初始化、key 非法、平台错误时
   */
  async getBoolean(key: string, defValue: boolean): Promise<boolean> {
    this.validateKey(key);
    const prefs: preferences.Preferences = this.requirePrefs();
    try {
      const value: preferences.ValueType = await prefs.get(key, defValue);
      if (typeof value === 'boolean') {
        return value;
      }
      // 类型不匹配,返回默认值(不抛错,容错处理)
      Logger.warn(LOG_TAG, 'getBoolean type mismatch, return default key=' + key);
      return defValue;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'getBoolean failed key=' + key + ' code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 写入布尔值。
   * 已存在的 key 会被覆盖。写入后自动 flush。
   *
   * @param key 键名(非空,长度 ≤ 1024 字节)
   * @param value 布尔值
   * @throws PreferencesError 当未初始化、key 非法、平台错误时
   */
  async putBoolean(key: string, value: boolean): Promise<void> {
    this.validateKey(key);
    const prefs: preferences.Preferences = this.requirePrefs();
    try {
      await prefs.put(key, value);
      await prefs.flush();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'putBoolean failed key=' + key + ' code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 删除指定 key。
   * 幂等:不存在也返回成功。
   * 删除后自动 flush。
   *
   * @param key 键名
   * @throws PreferencesError 当未初始化、key 非法、平台错误时
   */
  async delete(key: string): Promise<void> {
    this.validateKey(key);
    const prefs: preferences.Preferences = this.requirePrefs();
    try {
      await prefs.delete(key);
      await prefs.flush();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'delete failed key=' + key + ' code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 判断 key 是否存在。
   * @param key 键名
   * @returns 存在返回 true
   * @throws PreferencesError 当未初始化、key 非法、平台错误时
   */
  async has(key: string): Promise<boolean> {
    this.validateKey(key);
    const prefs: preferences.Preferences = this.requirePrefs();
    try {
      const exists: boolean = await prefs.has(key);
      return exists;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'has failed key=' + key + ' code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 清空所有 key。
   * 清空后自动 flush。
   *
   * @throws PreferencesError 当未初始化、平台错误时
   */
  async clear(): Promise<void> {
    const prefs: preferences.Preferences = this.requirePrefs();
    try {
      await prefs.clear();
      await prefs.flush();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'clear failed code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 显式 flush。
   * 一般情况下 putString/delete/clear 已自动 flush,本方法用于特殊场景。
   *
   * @throws PreferencesError 当未初始化、平台错误时
   */
  async flush(): Promise<void> {
    const prefs: preferences.Preferences = this.requirePrefs();
    try {
      await prefs.flush();
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'flush failed code=' + err.code.toString());
      throw fromPlatformError(
        err.code,
        err.message,
        PreferencesErrorType.StorageUnavailable
      );
    }
  }

  /**
   * 校验 key 是否合法。
   * @param key 待校验 key
   * @throws PreferencesError 当 key 为空或过长时
   */
  private validateKey(key: string): void {
    if (key.length === 0) {
      throw createPreferencesError(
        PreferencesErrorType.InvalidKey,
        'Key is empty',
        undefined,
        undefined
      );
    }
    // MAX_KEY_LENGTH = 1024 字节,这里按字符长度保守判断(UTF-8 字节数 ≥ 字符数)
    if (key.length > 1024) {
      throw createPreferencesError(
        PreferencesErrorType.InvalidKey,
        'Key exceeds maximum length',
        undefined,
        undefined
      );
    }
  }
}
