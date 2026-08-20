/**
 * MarketSourceMetadata 市场来源元数据
 *
 * 用于在导入角色卡后,记录来源信息,便于:
 * - 已导入标记(列表/详情显示)
 * - 检查更新(本阶段不实现自动更新,只记录)
 * - 跳转来源
 * - 防止重复导入
 *
 * 存储位置:
 * - 角色 extensions.arktavern.market(随角色卡保存)
 * - 本地 MarketImportedMapStore(快速查找,不依赖角色 extensions)
 *
 * 约束:
 * - 不覆盖第三方已有 extensions
 * - 不保存完整角色卡数据
 * - 不保存 API Key 或认证信息
 */

/**
 * 市场来源元数据(存储于角色卡 extensions.arktavern.market)。
 */
export interface MarketSourceMetadata {
  /** Provider 标识(如 'chub') */
  readonly providerId: string;
  /** Provider 内部唯一标识 */
  readonly remoteId: string;
  /** 来源页面 URL(可空) */
  readonly sourceUrl: string;
  /** 远程角色最后更新时间(毫秒,0 表示未知) */
  readonly remoteUpdatedAt: number;
  /** 远程角色卡版本(可空) */
  readonly remoteVersion: string;
  /** 导入时间戳(毫秒) */
  readonly importedAt: number;
}

/**
 * 创建 MarketSourceMetadata。
 */
export function createMarketSourceMetadata(
  providerId: string,
  remoteId: string,
  sourceUrl: string,
  remoteUpdatedAt: number,
  remoteVersion: string,
  importedAt: number
): MarketSourceMetadata {
  return {
    providerId: providerId,
    remoteId: remoteId,
    sourceUrl: sourceUrl,
    remoteUpdatedAt: remoteUpdatedAt,
    remoteVersion: remoteVersion,
    importedAt: importedAt
  };
}

/**
 * extensions.arktavern.market 命名空间键。
 */
export const MARKET_EXTENSION_NAMESPACE: string = 'arktavern';
export const MARKET_EXTENSION_KEY: string = 'market';

/**
 * 将 MarketSourceMetadata 序列化为 JSON 字符串(用于存储到角色卡 extensions)。
 */
export function serializeMarketSourceMetadata(meta: MarketSourceMetadata): string {
  return JSON.stringify({
    providerId: meta.providerId,
    remoteId: meta.remoteId,
    sourceUrl: meta.sourceUrl,
    remoteUpdatedAt: meta.remoteUpdatedAt,
    remoteVersion: meta.remoteVersion,
    importedAt: meta.importedAt
  });
}

/**
 * 从 JSON 字符串反序列化 MarketSourceMetadata。
 * 解析失败返回 null(不抛错,容错处理)。
 */
export function deserializeMarketSourceMetadata(json: string): MarketSourceMetadata | null {
  if (json.length === 0) {
    return null;
  }
  try {
    const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    const providerId: string = typeof obj['providerId'] === 'string'
      ? (obj['providerId'] as string) : '';
    const remoteId: string = typeof obj['remoteId'] === 'string'
      ? (obj['remoteId'] as string) : '';
    if (providerId.length === 0 || remoteId.length === 0) {
      return null;
    }
    const sourceUrl: string = typeof obj['sourceUrl'] === 'string'
      ? (obj['sourceUrl'] as string) : '';
    const remoteUpdatedAt: number = typeof obj['remoteUpdatedAt'] === 'number'
      ? (obj['remoteUpdatedAt'] as number) : 0;
    const remoteVersion: string = typeof obj['remoteVersion'] === 'string'
      ? (obj['remoteVersion'] as string) : '';
    const importedAt: number = typeof obj['importedAt'] === 'number'
      ? (obj['importedAt'] as number) : 0;
    return createMarketSourceMetadata(
      providerId, remoteId, sourceUrl,
      remoteUpdatedAt, remoteVersion, importedAt
    );
  } catch (e) {
    return null;
  }
}
