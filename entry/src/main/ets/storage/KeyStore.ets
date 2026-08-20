/**
 * KeyStore 安全存储抽象接口
 *
 * 平台无关的敏感数据(API Key 等)存储接口。
 * 业务层只依赖此接口,不直接调用 Asset Store / HUKS 等平台 API。
 *
 * 设计原则:
 * - alias 是非敏感索引(由 AliasBuilder 构建)
 * - secret 是唯一允许包含 API Key 的参数
 * - 所有错误转换为 SecureStorageError
 * - 不暴露 AssetMap / HUKS session handle 给业务层
 * - 后续 T-1.2 可基于此接口实现多 Provider 密钥
 *
 * 语义约定:
 * - save: upsert(已存在则覆盖,不存在则创建)
 * - read: 不存在返回 null,不抛 NotFound
 * - update: 不存在抛 NotFound(与 save 区分)
 * - remove: 幂等(不存在也返回成功)
 * - exists: 不读取明文,仅查询属性
 *
 * 错误处理:
 * 所有失败均通过 Promise.reject 抛出 SecureStorageError 对象。
 * 调用方应使用 try/catch 捕获并将 e as SecureStorageError。
 */

import { SecureStorageError } from '../models/SecureStorageError';

/**
 * 安全存储抽象接口。
 * 使用抽象类以支持 ArkTS 严格模式并提供明确契约。
 */
export abstract class KeyStore {
  /**
   * 保存(或覆盖)secret。
   * upsert 语义:已存在则覆盖,不存在则创建。
   *
   * @param alias 非敏感索引(由 AliasBuilder 构建)
   * @param secret 敏感明文(仅此参数允许包含 API Key)
   * @returns Promise,void 表示成功
   * @throws SecureStorageError 当 alias 非法、secret 非法、平台错误时
   */
  abstract save(alias: string, secret: string): Promise<void>;

  /**
   * 读取 secret。
   * 不存在时返回 null,不抛 NotFound。
   *
   * @param alias 非敏感索引
   * @returns Promise<string | null>,secret 明文或 null
   * @throws SecureStorageError 当 alias 非法、平台错误时
   */
  abstract read(alias: string): Promise<string | null>;

  /**
   * 更新 secret。
   * 不存在时抛 NotFound(与 save 的 upsert 语义区分)。
   *
   * @param alias 非敏感索引
   * @param secret 新的敏感明文
   * @returns Promise,void 表示成功
   * @throws SecureStorageError 当 alias 非法、secret 非法、NotFound、平台错误时
   */
  abstract update(alias: string, secret: string): Promise<void>;

  /**
   * 删除 secret。
   * 幂等语义:不存在也返回成功,不抛 NotFound。
   *
   * @param alias 非敏感索引
   * @returns Promise,void 表示成功
   * @throws SecureStorageError 当 alias 非法、平台错误时
   */
  abstract remove(alias: string): Promise<void>;

  /**
   * 判断 alias 是否存在。
   * 不读取明文,仅查询属性。
   *
   * @param alias 非敏感索引
   * @returns Promise<boolean>,存在返回 true
   * @throws SecureStorageError 当 alias 非法、平台错误时
   */
  abstract exists(alias: string): Promise<boolean>;
}

/**
 * 类型守卫:判断未知对象是否为 SecureStorageError。
 * 用于 catch 块中安全类型断言。
 *
 * @param obj 未知对象
 * @returns 是 SecureStorageError 返回 true
 */
export function isSecureStorageError(obj: Object): boolean {
  return obj instanceof SecureStorageError;
}
