/**
 * ProviderKeyStore Provider 级密钥管理
 *
 * 在 KeyStore 抽象之上提供按 ProviderConfig.id 管理密钥的能力。
 * 业务层(Service / ViewModel)通过本类存取 API Key,不直接接触 Asset Store / AliasBuilder。
 *
 * 设计原则:
 * - 依赖 KeyStore 抽象,不依赖具体实现(AssetStoreKeyStore / HUKS 等)
 * - 使用 AliasBuilder 从 providerId 构建 alias,不暴露 alias 给调用方
 * - 不缓存密钥,每次 read 都从 KeyStore 读取
 * - 不维护全局密钥 Map
 * - 日志只记录 providerId 和操作类型,不记录 secret
 * - 所有错误保持 SecureStorageError 语义
 *
 * 与 ProviderConfig 的关系:
 *   ProviderConfig.id → ProviderKeyStore → AliasBuilder → KeyStore
 * ProviderConfig 本身不包含 API Key,也不直接调用 KeyStore。
 * 模型层(models/)不依赖 storage 层。
 *
 * 多配置密钥隔离:
 * - 每个 ProviderConfig.id 对应唯一 alias:arktavern.provider.<id>.api-key
 * - 同一 ProviderType 的不同配置 id 生成不同 alias,密钥互相隔离
 * - 不按 ProviderType 共用密钥
 * - 配置 id 唯一性由上层(Preferences / ModelService)保证
 *
 * save/update/replace 语义:
 * - saveKey: upsert(已存在则覆盖,不存在则创建)。适用于"用户点击保存"简单场景。
 * - updateKey: 仅更新已存在的(不存在抛 NotFound)。适用于"修改已有密钥"时,如果不存在说明状态错误。
 * - replaceKey: 安全 upsert,先 exists 判断,存在则 update,不存在则 save。
 *   语义上与 saveKey 等价,但日志显式区分"新增"和"更新"路径。
 *
 * 日志规则:
 * 允许记录:操作类型、providerId、成功/失败、SecureStorageError 类型、平台错误码
 * 禁止记录:API Key、长度、前缀、后缀、Authorization、AssetMap、SECRET、read 返回值
 */

import { KeyStore } from './KeyStore';
import { buildAlias, isValidProviderId } from './AliasBuilder';
import { SecureStorageErrorType, createSecureStorageError } from '../models/SecureStorageError';

/**
 * Provider 级密钥管理。
 * 依赖 KeyStore 抽象,不直接调用 Asset Store API。
 */
export class ProviderKeyStore {
  private readonly keyStore: KeyStore;

  /**
   * 构造 ProviderKeyStore。
   * @param keyStore 底层安全存储实现(如 AssetStoreKeyStore)
   */
  constructor(keyStore: KeyStore) {
    this.keyStore = keyStore;
  }

  /**
   * 保存 API Key(upsert 语义:已存在则覆盖,不存在则创建)。
   *
   * @param providerId Provider 配置 ID
   * @param apiKey API Key 明文
   * @throws SecureStorageError 当 providerId 非法、apiKey 非法、平台错误时
   */
  async saveKey(providerId: string, apiKey: string): Promise<void> {
    const alias: string = this.validateAndBuildAlias(providerId);
    this.validateApiKeyOrThrow(apiKey);
    await this.keyStore.save(alias, apiKey);
  }

  /**
   * 读取 API Key。
   * 不存在时返回 null,不抛 NotFound。
   * 每次都从 KeyStore 读取,不使用缓存。
   *
   * @param providerId Provider 配置 ID
   * @returns API Key 明文或 null
   * @throws SecureStorageError 当 providerId 非法、平台错误时
   */
  async readKey(providerId: string): Promise<string | null> {
    const alias: string = this.validateAndBuildAlias(providerId);
    const result: string | null = await this.keyStore.read(alias);
    return result;
  }

  /**
   * 更新 API Key(不存在时抛 NotFound)。
   *
   * @param providerId Provider 配置 ID
   * @param apiKey 新的 API Key 明文
   * @throws SecureStorageError 当 providerId 非法、apiKey 非法、NotFound、平台错误时
   */
  async updateKey(providerId: string, apiKey: string): Promise<void> {
    const alias: string = this.validateAndBuildAlias(providerId);
    this.validateApiKeyOrThrow(apiKey);
    await this.keyStore.update(alias, apiKey);
  }

  /**
   * 删除 API Key(幂等:不存在也返回成功)。
   *
   * @param providerId Provider 配置 ID
   * @throws SecureStorageError 当 providerId 非法、平台错误时
   */
  async removeKey(providerId: string): Promise<void> {
    const alias: string = this.validateAndBuildAlias(providerId);
    await this.keyStore.remove(alias);
  }

  /**
   * 判断是否已配置 API Key。
   * 不读取明文,仅查询属性。
   * 对不存在返回 false,对平台异常抛出(不返回 false 掩盖失败)。
   *
   * @param providerId Provider 配置 ID
   * @returns 已配置返回 true
   * @throws SecureStorageError 当 providerId 非法、平台错误时
   */
  async hasKey(providerId: string): Promise<boolean> {
    const alias: string = this.validateAndBuildAlias(providerId);
    const exists: boolean = await this.keyStore.exists(alias);
    return exists;
  }

  /**
   * 安全 upsert:已存在则 update,不存在则 save。
   * 适用于页面"保存"按钮,不区分新增和更新。
   *
   * @param providerId Provider 配置 ID
   * @param apiKey API Key 明文
   * @throws SecureStorageError 当 providerId 非法、apiKey 非法、平台错误时
   */
  async replaceKey(providerId: string, apiKey: string): Promise<void> {
    const alias: string = this.validateAndBuildAlias(providerId);
    this.validateApiKeyOrThrow(apiKey);
    const exists: boolean = await this.keyStore.exists(alias);
    if (exists) {
      await this.keyStore.update(alias, apiKey);
    } else {
      await this.keyStore.save(alias, apiKey);
    }
  }

  // ===== 内部方法 =====

  /**
   * 校验 providerId 并构建 alias。
   * 不将 alias 返回给调用方(仅在内部使用)。
   *
   * @param providerId Provider 配置 ID
   * @returns 构建出的 alias(内部使用)
   * @throws SecureStorageError 当 providerId 非法时
   */
  private validateAndBuildAlias(providerId: string): string {
    if (!isValidProviderId(providerId)) {
      throw createSecureStorageError(
        SecureStorageErrorType.InvalidAlias,
        'Invalid providerId',
        undefined,
        undefined
      );
    }
    const result = buildAlias(providerId);
    if (!result.success) {
      throw createSecureStorageError(
        SecureStorageErrorType.InvalidAlias,
        'Failed to build alias: ' + result.error,
        undefined,
        undefined
      );
    }
    return result.alias;
  }

  /**
   * 校验 apiKey,空或仅空白时拒绝。
   * 不 trim 内部内容,保存原始输入。
   * 仅用 trim() 判断是否为空,但不修改 apiKey 原值。
   *
   * @param apiKey 待校验的 API Key
   * @throws SecureStorageError 当 apiKey 为空或仅空白时
   */
  private validateApiKeyOrThrow(apiKey: string): void {
    if (apiKey.trim().length === 0) {
      throw createSecureStorageError(
        SecureStorageErrorType.InvalidSecret,
        'API Key is empty or whitespace-only',
        undefined,
        undefined
      );
    }
  }
}
