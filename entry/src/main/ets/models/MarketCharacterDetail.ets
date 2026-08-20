/**
 * MarketCharacterDetail 市场角色卡详情模型
 *
 * 用户点击市场列表中的角色卡后,从 Provider 获取完整详情,
 * 包含开场白、对话示例、创作者备注等列表阶段不返回的字段。
 *
 * 不直接包含 PNG 字节或完整 Tavern Card JSON,
 * 下载与解析由 MarketImportService 在导入阶段处理。
 */

import { MarketCharacter } from './MarketCharacter';

/**
 * 市场角色卡详情。
 * 列表项字段全部保留,额外补充详情阶段字段。
 */
export interface MarketCharacterDetail {
  /** 列表项基础字段 */
  readonly base: MarketCharacter;
  /** 完整描述(未截断) */
  readonly description: string;
  /** 性格描述 */
  readonly personality: string;
  /** 场景/世界观 */
  readonly scenario: string;
  /** 开场白预览(前 500 字符) */
  readonly firstMessagePreview: string;
  /** 备用开场白列表(预览,每条最多 200 字符) */
  readonly alternateGreetingsPreview: string[];
  /** 备用开场白总数 */
  readonly alternateGreetingsCount: number;
  /** 是否包含对话示例 */
  readonly hasMessageExample: boolean;
  /** 创作者备注 */
  readonly creatorNotes: string;
  /** Post-History Instructions */
  readonly postHistoryInstructions: string;
  /** 角色世界书条目数量(0 表示无) */
  readonly characterBookEntryCount: number;
  /** 角色卡版本(如 '2.0', '3.0') */
  readonly characterVersion: string;
  /** 完整角色卡 JSON(用于导入,可空;若为空,导入阶段需另行下载) */
  readonly rawCardJson: string;
  /** 远程 PNG 下载 URL(可空;若为空,导入阶段使用 JSON) */
  readonly pngDownloadUrl: string;
}

/**
 * 创建 MarketCharacterDetail,保证默认值与不可变性。
 */
export function createMarketCharacterDetail(
  base: MarketCharacter,
  description: string,
  personality: string,
  scenario: string,
  firstMessagePreview: string,
  alternateGreetingsPreview: string[],
  alternateGreetingsCount: number,
  hasMessageExample: boolean,
  creatorNotes: string,
  postHistoryInstructions: string,
  characterBookEntryCount: number,
  characterVersion: string,
  rawCardJson: string,
  pngDownloadUrl: string
): MarketCharacterDetail {
  return {
    base: base,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessagePreview: firstMessagePreview,
    alternateGreetingsPreview: alternateGreetingsPreview,
    alternateGreetingsCount: alternateGreetingsCount,
    hasMessageExample: hasMessageExample,
    creatorNotes: creatorNotes,
    postHistoryInstructions: postHistoryInstructions,
    characterBookEntryCount: characterBookEntryCount,
    characterVersion: characterVersion,
    rawCardJson: rawCardJson,
    pngDownloadUrl: pngDownloadUrl
  };
}

/**
 * 截断字符串到指定长度,超出部分用 ellipsis 表示。
 * @param text 原始文本
 * @param maxLen 最大长度(不含 ellipsis)
 * @returns 截断后的文本
 */
export function truncateMarketText(text: string, maxLen: number): string {
  if (text.length <= maxLen) {
    return text;
  }
  return text.substring(0, maxLen) + '…';
}
