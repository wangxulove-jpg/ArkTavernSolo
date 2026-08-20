/**
 * ProviderConfigStore ProviderConfig 列表持久化存储
 *
 * 基于 AppPreferences 与 ProviderConfigCodec 提供 ProviderConfig 的 CRUD 能力,
 * 同时维护"当前选中 Provider"状态(current_provider_id)。
 *
 * 设计原则:
 * - 不依赖 ProviderKeyStore(配置删除与密钥删除的协调属于上层 ModelService)
 * - 不依赖页面、网络、ArkUI
 * - 所有写操作通过 Promise 串行化避免并发覆盖
 * - 所有错误转换为 PreferencesError
 * - 日志只记录操作、配置数量、providerId,不记录配置 JSON
 *
 * 语义说明:
 * - save(config):新增,id 重复抛 AlreadyExists
 * - update(config):更新,不存在抛 NotFound
 * - remove(id):幂等删除,删除当前选中配置时自动清空 current_provider_id
 * - setCurrentProviderId(id):必须为已存在 id;传 null 清空选择
 * - getCurrentProviderId():返回当前选中 id,可能为 null
 * - getCurrent():返回当前选中配置,可能为 null
 * - exists(id):判断 id 是否存在
 * - list():按 createdAt 升序返回所有配置
 *
 * 并发写保护:
 * - 通过 writeChain Promise 链串行化所有写操作
 * - 每次写操作前 await 前一次写完成
 * - 读操作不串行化,直接读取 Preferences
 *
 * 损坏数据处理:
 * - 整个 JSON 无法解析 → 抛 CorruptedData
 * - 单个配置损坏 → 跳过并记录 skippedCount,返回有效配置
 * - 全部损坏 → 返回空列表
 *
 * Context 生命周期:
 * - 由上层(app container / ModelService)在合适时机调用 initialize(context)
 * - 使用 ApplicationContext 或 UIAbility Context
 * - 不保存短生命周期 Page Context
 */

import { common } from '@kit.AbilityKit';
import { AppPreferences } from './AppPreferences';
import {
  encodeConfigs,
  decodeConfigs,
  CodecDecodeResult
} from './ProviderConfigCodec';
import { ProviderConfig } from '../models/ProviderConfig';
import {
  PreferencesError,
  PreferencesErrorType,
  createPreferencesError,
  isPreferencesError
} from '../models/PreferencesError';
import { Logger } from '../utils/Logger';

/** 日志标签 */
const LOG_TAG: string = 'ProviderConfigStore';

/** ProviderConfig 列表的 Preferences key(带版本后缀) */
const KEY_PROVIDER_CONFIGS: string = 'provider_configs_v1';
/** 当前选中 Provider id 的 Preferences key */
const KEY_CURRENT_PROVIDER_ID: string = 'current_provider_id';

/**
 * ProviderConfig 列表持久化存储。
 * 通过 AppPreferences 提供读写,通过 ProviderConfigCodec 提供序列化。
 */
export class ProviderConfigStore {
  /** 底层 Preferences 封装 */
  private readonly prefs: AppPreferences;
  /** 写操作串行化链(读操作不走此链) */
  private writeChain: Promise<void> = Promise.resolve();

  /**
   * 构造 ProviderConfigStore。
   * 默认使用内置 AppPreferences 实例;测试可注入自定义实例。
   *
   * @param prefs 可选的 AppPreferences 实例(测试注入用)
   */
  constructor(prefs?: AppPreferences) {
    this.prefs = prefs !== undefined ? prefs : new AppPreferences();
  }

  /**
   * 初始化 Preferences。
   * 必须在所有读写操作前调用。
   *
   * @param context ApplicationContext 或 UIAbility Context
   * @throws PreferencesError 当平台初始化失败时
   */
  async initialize(context: common.Context): Promise<void> {
    await this.prefs.initialize(context);
  }

  /**
   * 检查是否已初始化。
   * @returns 已初始化返回 true
   */
  isInitialized(): boolean {
    return this.prefs.isInitialized();
  }

  /**
   * 列出所有 ProviderConfig。
   * 按 createdAt 升序排序,顺序稳定。
   *
   * @returns ProviderConfig 列表(可能为空)
   * @throws PreferencesError 当存储不可用或数据整体损坏时
   */
  async list(): Promise<ProviderConfig[]> {
    const json: string = await this.prefs.getString(KEY_PROVIDER_CONFIGS, '');
    if (json.length === 0) {
      return [];
    }
    const result: CodecDecodeResult = decodeConfigs(json);
    if (!result.success) {
      // 整体损坏,抛错
      if (result.error !== undefined) {
        throw result.error;
      }
      throw createPreferencesError(
        PreferencesErrorType.CorruptedData,
        'Decode failed without explicit error',
        undefined,
        undefined
      );
    }
    // 单个损坏跳过已记录,日志只记录数量
    if (result.skippedCount > 0) {
      Logger.warn(
        LOG_TAG,
        'list skippedCount=' + result.skippedCount.toString()
      );
    }
    // 按 createdAt 升序排序(稳定)
    const sorted: ProviderConfig[] = result.configs.slice();
    sorted.sort((a: ProviderConfig, b: ProviderConfig): number => {
      return a.createdAt - b.createdAt;
    });
    return sorted;
  }

  /**
   * 按 id 查询 ProviderConfig。
   *
   * @param id 配置 id
   * @returns 配置实例,不存在返回 null
   * @throws PreferencesError 当存储不可用或数据整体损坏时
   */
  async getById(id: string): Promise<ProviderConfig | null> {
    const all: ProviderConfig[] = await this.list();
    for (let i = 0; i < all.length; i++) {
      if (all[i].id === id) {
        return all[i];
      }
    }
    return null;
  }

  /**
   * 判断指定 id 是否存在。
   *
   * @param id 配置 id
   * @returns 存在返回 true
   * @throws PreferencesError 当存储不可用或数据整体损坏时
   */
  async exists(id: string): Promise<boolean> {
    const all: ProviderConfig[] = await this.list();
    for (let i = 0; i < all.length; i++) {
      if (all[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /**
   * 新增 ProviderConfig。
   * id 重复时抛 AlreadyExists。
   *
   * @param config 待新增的配置
   * @returns Promise<void>
   * @throws PreferencesError 当 id 重复、存储失败或序列化失败时
   */
  async save(config: ProviderConfig): Promise<void> {
    await this.serializeWrite(async (): Promise<void> => {
      const current: ProviderConfig[] = await this.list();
      for (let i = 0; i < current.length; i++) {
        if (current[i].id === config.id) {
          throw createPreferencesError(
            PreferencesErrorType.AlreadyExists,
            'ProviderConfig already exists: ' + config.id,
            undefined,
            undefined
          );
        }
      }
      const next: ProviderConfig[] = current.slice();
      next.push(config);
      await this.persistConfigs(next);
    });
  }

  /**
   * 更新 ProviderConfig。
   * 不存在时抛 NotFound。
   * id 不可变(以传入 config.id 为准)。
   *
   * @param config 待更新的配置
   * @returns Promise<void>
   * @throws PreferencesError 当 id 不存在、存储失败或序列化失败时
   */
  async update(config: ProviderConfig): Promise<void> {
    await this.serializeWrite(async (): Promise<void> => {
      const current: ProviderConfig[] = await this.list();
      let found: boolean = false;
      const next: ProviderConfig[] = [];
      for (let i = 0; i < current.length; i++) {
        if (current[i].id === config.id) {
          next.push(config);
          found = true;
        } else {
          next.push(current[i]);
        }
      }
      if (!found) {
        throw createPreferencesError(
          PreferencesErrorType.NotFound,
          'ProviderConfig not found: ' + config.id,
          undefined,
          undefined
        );
      }
      await this.persistConfigs(next);
    });
  }

  /**
   * 删除 ProviderConfig。
   * 幂等:不存在也返回成功。
   * 若删除的是当前选中配置,自动清空 current_provider_id。
   *
   * @param id 配置 id
   * @returns Promise<void>
   * @throws PreferencesError 当存储失败时
   */
  async remove(id: string): Promise<void> {
    await this.serializeWrite(async (): Promise<void> => {
      const current: ProviderConfig[] = await this.list();
      const next: ProviderConfig[] = [];
      let found: boolean = false;
      for (let i = 0; i < current.length; i++) {
        if (current[i].id === id) {
          found = true;
          continue;
        }
        next.push(current[i]);
      }
      if (!found) {
        // 幂等,不抛错
        return;
      }
      await this.persistConfigs(next);
      // 检查并清理 current_provider_id
      const currentSelectedId: string | null = await this.readCurrentProviderIdUnsafe();
      if (currentSelectedId === id) {
        await this.prefs.delete(KEY_CURRENT_PROVIDER_ID);
      }
    });
  }

  /**
   * 设置当前选中的 Provider id。
   * id 必须为已存在配置;传 null 清空选择。
   *
   * @param id 配置 id 或 null
   * @returns Promise<void>
   * @throws PreferencesError 当 id 非空但不存在时
   */
  async setCurrentProviderId(id: string | null): Promise<void> {
    if (id === null) {
      await this.serializeWrite(async (): Promise<void> => {
        await this.prefs.delete(KEY_CURRENT_PROVIDER_ID);
      });
      return;
    }
    if (id.length === 0) {
      throw createPreferencesError(
        PreferencesErrorType.InvalidSelection,
        'Current provider id is empty',
        undefined,
        undefined
      );
    }
    await this.serializeWrite(async (): Promise<void> => {
      const exists: boolean = await this.exists(id);
      if (!exists) {
        throw createPreferencesError(
          PreferencesErrorType.InvalidSelection,
          'ProviderConfig does not exist: ' + id,
          undefined,
          undefined
        );
      }
      await this.prefs.putString(KEY_CURRENT_PROVIDER_ID, id);
    });
  }

  /**
   * 获取当前选中的 Provider id。
   *
   * @returns 当前选中 id,可能为 null
   * @throws PreferencesError 当存储不可用时
   */
  async getCurrentProviderId(): Promise<string | null> {
    return await this.readCurrentProviderIdUnsafe();
  }

  /**
   * 获取当前选中的 ProviderConfig。
   *
   * @returns 当前选中配置,可能为 null
   * @throws PreferencesError 当存储不可用或数据整体损坏时
   */
  async getCurrent(): Promise<ProviderConfig | null> {
    const id: string | null = await this.readCurrentProviderIdUnsafe();
    if (id === null) {
      return null;
    }
    return await this.getById(id);
  }

  // ===== 内部方法 =====

  /**
   * 读取 current_provider_id(无锁,内部使用)。
   * 空字符串视为未设置,返回 null。
   *
   * @returns 当前选中 id 或 null
   */
  private async readCurrentProviderIdUnsafe(): Promise<string | null> {
    const value: string = await this.prefs.getString(KEY_CURRENT_PROVIDER_ID, '');
    if (value.length === 0) {
      return null;
    }
    return value;
  }

  /**
   * 持久化 ProviderConfig 列表。
   * 由调用方负责串行化(serializeWrite)。
   *
   * @param configs 待持久化的配置列表
   * @throws PreferencesError 当序列化或存储失败时
   */
  private async persistConfigs(configs: ProviderConfig[]): Promise<void> {
    let json: string;
    try {
      json = encodeConfigs(configs);
    } catch (e) {
      // 编码失败(敏感字段或 JSON.stringify 失败)
      if (isPreferencesError(e as Object)) {
        throw e as PreferencesError;
      }
      throw createPreferencesError(
        PreferencesErrorType.SerializationFailed,
        'Encode failed',
        undefined,
        e instanceof Error ? e.message : String(e)
      );
    }
    await this.prefs.putString(KEY_PROVIDER_CONFIGS, json);
  }

  /**
   * 串行化写操作,避免并发覆盖。
   * 读操作不走此链,直接读取 Preferences。
   *
   * 实现说明:
   * - 每次 write 将自身 append 到 writeChain 末尾
   * - 后续 write 必须等待前一次完成(无论前一次成功或失败)
   * - 前一次失败不影响本次执行(吞掉前一次错误)
   * - 本次 task 的错误正常传播给调用方
   * - writeChain 本身永远不进入 rejected 状态(防止污染所有后续写)
   *
   * @param task 写操作任务
   * @returns Promise,完成后 resolve;失败时 reject(由调用方处理)
   */
  private serializeWrite(task: () => Promise<void>): Promise<void> {
    const previous: Promise<void> = this.writeChain;
    const next: Promise<void> = new Promise<void>((resolve: () => void, reject: (e: Object) => void): void => {
      // 先等待前一次写完成(无论成功或失败),再执行本次 task
      previous.then(async (): Promise<void> => {
        await task();
      }, async (err: Object): Promise<void> => {
        // 前一次写失败不影响本次执行,吞掉错误继续执行本次 task
        void err;
        await task();
      }).then((): void => {
        resolve();
      }, (e: Object): void => {
        reject(e);
      });
    });
    // writeChain 必须保持 fulfilled 状态,防止前一次失败污染所有后续写
    this.writeChain = next.then((): void => {}, (): void => {});
    return next;
  }
}
