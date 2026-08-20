/**
 * AssetStoreKeyStore 基于 Asset Store Kit 的 KeyStore 实现
 *
 * 使用 HarmonyOS Asset Store Kit(@ohos.security.asset)实现安全存储。
 * API Key 等敏感数据存储在 Tag.SECRET 中,由平台加密保护。
 * 应用无需自行管理 AES 密钥、IV、authTag 和密文。
 *
 * 安全配置:
 * - SECRET:存储敏感明文(API Key)
 * - ALIAS:仅存储非敏感索引
 * - ACCESSIBILITY:DEVICE_FIRST_UNLOCKED(设备首次解锁后可访问)
 * - AUTH_TYPE:NONE(不要求用户认证)
 * - SYNC_TYPE:NEVER(不同步到云或其他设备)
 * - IS_PERSISTENT:不设置(默认 false,应用卸载时删除)
 * - DATA_LABEL_*:不存储 API Key
 *
 * API 起始版本:
 * - asset.add/remove/update/query: since 11
 * - util.TextEncoder.encodeInto: since 9
 * - util.TextDecoder.decodeToString: since 12
 *
 * 本实现已通过 API 23 真机验证。
 */

import asset from '@ohos.security.asset';
import util from '@ohos.util';
import { BusinessError } from '@ohos.base';
import { KeyStore } from './KeyStore';
import { SecureStorageErrorType, createSecureStorageError, fromPlatformError } from '../models/SecureStorageError';
import { isValidAlias, isValidSecret, utf8ByteLength, getMaxSecretBytes } from './AliasBuilder';
import { Logger } from '../utils/Logger';

/** Asset Store NOT_FOUND 错误码 */
const ASSET_NOT_FOUND_CODE: number = 24000002;

/**
 * 基于 Asset Store Kit 的 KeyStore 实现。
 *
 * 所有方法:
 * - 成功时 resolve
 * - 失败时 reject 一个 SecureStorageError 对象
 * - 日志只记录 alias 和操作类型,不记录 secret
 */
export class AssetStoreKeyStore extends KeyStore {
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = new util.TextDecoder('utf-8');

  /**
   * 保存(或覆盖)secret。
   * 使用 CONFLICT_RESOLUTION=OVERWRITE 实现 upsert 语义。
   *
   * @param alias 非敏感索引
   * @param secret 敏感明文
   */
  async save(alias: string, secret: string): Promise<void> {
    this.validateAliasOrThrow(alias);
    this.validateSecretOrThrow(secret);

    const aliasBytes: Uint8Array = this.encodeText(alias);
    const secretBytes: Uint8Array = this.encodeText(secret);

    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.ALIAS, aliasBytes);
    attributes.set(asset.Tag.SECRET, secretBytes);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);

    try {
      await asset.add(attributes);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn('KeyStore save failed', 'alias=' + alias + ' code=' + err.code);
      throw fromPlatformError(err.code, err.message, SecureStorageErrorType.PlatformError);
    }
  }

  /**
   * 读取 secret。
   * 不存在时返回 null,不抛 NotFound。
   *
   * @param alias 非敏感索引
   * @returns secret 明文或 null
   */
  async read(alias: string): Promise<string | null> {
    this.validateAliasOrThrow(alias);

    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, this.encodeText(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);

    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results.length === 0) {
        return null;
      }
      const first: asset.AssetMap = results[0];
      const secretValue: asset.Value | undefined = first.get(asset.Tag.SECRET);
      if (secretValue === undefined) {
        Logger.warn('KeyStore read no SECRET', 'alias=' + alias);
        return null;
      }
      const secretBytes: Uint8Array = secretValue as Uint8Array;
      const secret: string = this.decodeText(secretBytes);
      return secret;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === ASSET_NOT_FOUND_CODE) {
        return null;
      }
      Logger.warn('KeyStore read failed', 'alias=' + alias + ' code=' + err.code);
      throw fromPlatformError(err.code, err.message, SecureStorageErrorType.PlatformError);
    }
  }

  /**
   * 更新 secret。
   * 不存在时抛 NotFound(与 save 的 upsert 语义区分)。
   *
   * @param alias 非敏感索引
   * @param secret 新的敏感明文
   */
  async update(alias: string, secret: string): Promise<void> {
    this.validateAliasOrThrow(alias);
    this.validateSecretOrThrow(secret);

    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, this.encodeText(alias));

    const attributesToUpdate: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributesToUpdate.set(asset.Tag.SECRET, this.encodeText(secret));

    try {
      await asset.update(query, attributesToUpdate);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.warn('KeyStore update failed', 'alias=' + alias + ' code=' + err.code);
      if (err.code === ASSET_NOT_FOUND_CODE) {
        throw createSecureStorageError(
          SecureStorageErrorType.NotFound,
          'Asset not found for update',
          err.code,
          err.message
        );
      }
      throw fromPlatformError(err.code, err.message, SecureStorageErrorType.PlatformError);
    }
  }

  /**
   * 删除 secret。
   * 幂等语义:不存在也返回成功,不抛 NotFound。
   *
   * @param alias 非敏感索引
   */
  async remove(alias: string): Promise<void> {
    this.validateAliasOrThrow(alias);

    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, this.encodeText(alias));

    try {
      await asset.remove(query);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === ASSET_NOT_FOUND_CODE) {
        // 幂等:不存在视为删除成功
        return;
      }
      Logger.warn('KeyStore remove failed', 'alias=' + alias + ' code=' + err.code);
      throw fromPlatformError(err.code, err.message, SecureStorageErrorType.PlatformError);
    }
  }

  /**
   * 判断 alias 是否存在。
   * 使用 RETURN_TYPE=ATTRIBUTES,不读取明文。
   *
   * @param alias 非敏感索引
   * @returns 存在返回 true
   */
  async exists(alias: string): Promise<boolean> {
    this.validateAliasOrThrow(alias);

    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, this.encodeText(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);

    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      const exists: boolean = results.length > 0;
      return exists;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      if (err.code === ASSET_NOT_FOUND_CODE) {
        return false;
      }
      Logger.warn('KeyStore exists failed', 'alias=' + alias + ' code=' + err.code);
      throw fromPlatformError(err.code, err.message, SecureStorageErrorType.PlatformError);
    }
  }

  // ===== 内部方法 =====

  /**
   * 校验 alias,非法时抛 InvalidAlias。
   * @param alias 待校验 alias
   */
  private validateAliasOrThrow(alias: string): void {
    if (!isValidAlias(alias)) {
      throw createSecureStorageError(
        SecureStorageErrorType.InvalidAlias,
        'Invalid alias format',
        undefined,
        undefined
      );
    }
  }

  /**
   * 校验 secret,非法时抛 InvalidSecret 或 SecretTooLarge。
   * @param secret 待校验 secret
   */
  private validateSecretOrThrow(secret: string): void {
    if (secret.length === 0) {
      throw createSecureStorageError(
        SecureStorageErrorType.InvalidSecret,
        'Secret is empty',
        undefined,
        undefined
      );
    }
    const byteLen: number = utf8ByteLength(secret);
    if (byteLen > getMaxSecretBytes()) {
      throw createSecureStorageError(
        SecureStorageErrorType.SecretTooLarge,
        'Secret exceeds maximum allowed ' + getMaxSecretBytes().toString() + ' bytes, actual=' + byteLen.toString(),
        undefined,
        undefined
      );
    }
  }

  /**
   * UTF-8 编码字符串为 Uint8Array。
   * 失败时抛 EncodingFailed。
   *
   * @param text 待编码字符串
   * @returns UTF-8 字节数组
   */
  private encodeText(text: string): Uint8Array {
    try {
      return this.encoder.encodeInto(text);
    } catch (e) {
      throw createSecureStorageError(
        SecureStorageErrorType.EncodingFailed,
        'UTF-8 encoding failed',
        undefined,
        (e as Error).message
      );
    }
  }

  /**
   * UTF-8 解码 Uint8Array 为字符串。
   * 失败时抛 EncodingFailed。
   *
   * @param bytes UTF-8 字节数组
   * @returns 解码后的字符串
   */
  private decodeText(bytes: Uint8Array): string {
    try {
      return this.decoder.decodeToString(bytes);
    } catch (e) {
      throw createSecureStorageError(
        SecureStorageErrorType.EncodingFailed,
        'UTF-8 decoding failed',
        undefined,
        (e as Error).message
      );
    }
  }
}
