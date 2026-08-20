/**
 * MarketCharacter 市场角色卡统一模型
 *
 * 用于市场 UI 展示的角色卡列表项,与 Provider 原始响应结构解耦。
 * Provider 必须在调用 UI 前完成字段映射,不允许把原始 JSON 透传到 UI。
 *
 * 字段约束:
 * - providerId: Provider 标识(如 'chub')
 * - remoteId: Provider 内部唯一标识(Chub 为 'creator/project')
 * - sourceUrl: 来源页面 URL(可空)
 * - avatarUrl: 远程头像 URL(可空,列表与详情分开)
 * - 不包含角色卡完整数据(开场白、对话示例、character_book 等),
 *   这些字段在详情阶段由 MarketCharacterDetail 承载
 */

/**
 * 市场角色卡列表项。
 */
export interface MarketCharacter {
  /** Provider 标识(如 'chub') */
  readonly providerId: string;
  /** Provider 内部唯一标识(Chub 为 'creator/project') */
  readonly remoteId: string;
  /** 角色名称 */
  readonly name: string;
  /** 创作者名 */
  readonly creator: string;
  /** 简短介绍(描述前 N 行截断,UI 展示用) */
  readonly summary: string;
  /** 远程头像 URL(可空,展示用,不写入本地角色) */
  readonly avatarUrl: string;
  /** 标签列表 */
  readonly tags: string[];
  /** 评分(0~5,-1 表示无数据) */
  readonly rating: number;
  /** 下载量(-1 表示无数据) */
  readonly downloadCount: number;
  /** 更新时间(毫秒,0 表示无数据) */
  readonly updatedAt: number;
  /** 是否为 NSFW 内容 */
  readonly nsfw: boolean;
  /** 来源页面 URL(可空) */
  readonly sourceUrl: string;
  /** 角色卡格式标识(如 'tavern_card_v2', 'tavern_card_v3') */
  readonly cardFormat: string;
  /** 是否包含角色专属世界书 */
  readonly hasCharacterBook: boolean;
}

/**
 * 创建 MarketCharacter,保证默认值与不可变性。
 */
export function createMarketCharacter(
  providerId: string,
  remoteId: string,
  name: string,
  creator: string,
  summary: string,
  avatarUrl: string,
  tags: string[],
  rating: number,
  downloadCount: number,
  updatedAt: number,
  nsfw: boolean,
  sourceUrl: string,
  cardFormat: string,
  hasCharacterBook: boolean
): MarketCharacter {
  return {
    providerId: providerId,
    remoteId: remoteId,
    name: name,
    creator: creator,
    summary: summary,
    avatarUrl: avatarUrl,
    tags: tags,
    rating: rating,
    downloadCount: downloadCount,
    updatedAt: updatedAt,
    nsfw: nsfw,
    sourceUrl: sourceUrl,
    cardFormat: cardFormat,
    hasCharacterBook: hasCharacterBook
  };
}

/**
 * 用作 ForEach key 的稳定字符串。
 */
export function marketCharacterKey(item: MarketCharacter): string {
  return item.providerId + ':' + item.remoteId;
}
