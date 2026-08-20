/**
 * MarketTranslation 市场角色卡翻译结果模型
 *
 * 仅用于市场 UI 展示,不写入本地角色卡或 extensions。
 * 翻译结果只覆盖预览字段(名称/简介/标签/创作者备注),
 * 不翻译 remoteId、creator 用户名、来源 URL、Provider 名称、
 * PNG/JSON 原始角色卡、extensions、System Prompt、对话示例、世界书完整内容。
 *
 * 不可变性:所有字段 readonly,通过工厂函数创建。
 */

/**
 * 市场列表项翻译结果。
 */
export interface MarketTranslationResult {
  /** 翻译后的角色名称 */
  readonly name: string;
  /** 翻译后的简介 */
  readonly summary: string;
  /** 翻译后的标签列表(顺序与原文一致) */
  readonly tags: string[];
  /** 翻译后的创作者备注(列表阶段不展示,留空即可) */
  readonly creatorNotes: string;
}

/**
 * 市场详情翻译结果。
 * 包含列表阶段所有字段,并扩展详情阶段字段。
 */
export interface MarketDetailTranslation {
  /** 列表阶段字段 */
  readonly name: string;
  readonly summary: string;
  readonly tags: string[];
  readonly creatorNotes: string;
  /** 详情阶段字段 */
  readonly description: string;
  readonly personality: string;
  readonly scenario: string;
  readonly firstMessagePreview: string;
}

/**
 * 创建空翻译结果(用于占位)。
 */
export function createEmptyMarketTranslationResult(): MarketTranslationResult {
  return {
    name: '',
    summary: '',
    tags: [],
    creatorNotes: ''
  };
}

/**
 * 创建空详情翻译结果(用于占位)。
 */
export function createEmptyMarketDetailTranslation(): MarketDetailTranslation {
  return {
    name: '',
    summary: '',
    tags: [],
    creatorNotes: '',
    description: '',
    personality: '',
    scenario: '',
    firstMessagePreview: ''
  };
}

/**
 * 简单字符串 hash(用于翻译缓存键)。
 * FNV-1a 32位变体,稳定且分布良好。
 */
export function hashString(text: string): number {
  if (text.length === 0) {
    return 0;
  }
  let hash: number = 2166136261;
  for (let i: number = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 16777619);
  }
  // 转为无符号 32 位
  return hash >>> 0;
}

/**
 * 计算字符串数组的 hash(用于 tags 列表)。
 */
export function hashStringArray(arr: string[]): number {
  if (arr.length === 0) {
    return 0;
  }
  return hashString(arr.join('|'));
}
