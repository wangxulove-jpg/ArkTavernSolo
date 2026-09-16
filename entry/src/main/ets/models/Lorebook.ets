/**
 * Lorebook 世界书数据模型
 *
 * 定义世界书和条目的数据结构、校验规则和不可变更新。
 * 不依赖 ArkUI,可用于服务层和持久化层。
 *
 * 约束:
 * - name 必填,最长 100 字符
 * - entry name 必填,最长 100 字符
 * - entry content 必填,最长 100000 字符
 * - keys 至少一个有效关键词,constant 条目除外
 * - 不加入向量匹配、正则表达式、递归扫描、概率触发
 */

import { generateUuid } from '../utils/Uuid';

/**
 * 条目插入位置。
 * 本阶段只支持 BeforeCharacter 和 AfterCharacter。
 */
export enum LorebookPosition {
  BeforeCharacter = 'BeforeCharacter',
  AfterCharacter = 'AfterCharacter'
}

/**
 * 世界书激活方式。
 * - FollowGlobal: 跟随全局默认激活方式
 * - FullInject: 全量注入(所有 enabled 条目稳定注入头部,缓存最优)
 * - OnDemand: 按需激活(constant 注入头部 + 关键词命中注入深度位置,省上下文)
 * - OnDemandPinned: 按需锁定(首次按需匹配后固定注入到记忆之后、对话之前,
 *   按会话持久化;仅在手动记忆总结成功后用全量对话重新匹配刷新,缓存友好)
 */
export enum LorebookActivationMode {
  FollowGlobal = 'FollowGlobal',
  FullInject = 'FullInject',
  OnDemand = 'OnDemand',
  OnDemandPinned = 'OnDemandPinned'
}

/**
 * 世界书条目模型。
 */
export interface LorebookEntry {
  readonly id: string;
  readonly name: string;
  readonly keys: string[];
  readonly secondaryKeys: string[];
  /** 正则触发模式(可选):非空时,任一被扫消息命中该正则视为关键词触发 */
  readonly regex: string;
  readonly content: string;
  readonly enabled: boolean;
  readonly constant: boolean;
  readonly selective: boolean;
  readonly position: LorebookPosition;
  readonly priority: number;
  readonly createdAt: number;
  readonly updatedAt: number;
}

/**
 * 世界书模型。
 */
export interface Lorebook {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  readonly enabled: boolean;
  /** 激活方式,FollowGlobal 表示跟随全局默认 */
  readonly activationMode: LorebookActivationMode;
  /** 注入预算(字符),0 表示使用默认预算 12000 */
  readonly injectionBudgetChars: number;
  /** 关键词扫描深度(最近 N 条消息),0 表示使用默认 10 */
  readonly scanDepth: number;
  readonly entries: LorebookEntry[];
  readonly createdAt: number;
  readonly updatedAt: number;
}

const MAX_NAME_LENGTH: number = 100;
const MAX_ENTRY_CONTENT_LENGTH: number = 100000;
const MAX_ENTRY_REGEX_LENGTH: number = 2000;
const MAX_DESCRIPTION_LENGTH: number = 100000;
const MAX_INJECTION_BUDGET_CHARS: number = 200000;
/** 扫描深度上限(最近 N 条消息) */
const MAX_SCAN_DEPTH: number = 50;

/**
 * 创建世界书条目。
 */
export function createLorebookEntry(
  name: string,
  keys: string[],
  secondaryKeys: string[],
  content: string,
  enabled: boolean = true,
  constant: boolean = false,
  selective: boolean = false,
  position: LorebookPosition = LorebookPosition.BeforeCharacter,
  priority: number = 0,
  regex: string = ''
): LorebookEntry {
  const now: number = Date.now();
  return {
    id: 'lbe-' + generateUuid(),
    name: name.trim(),
    keys: filterEmptyStrings(keys),
    secondaryKeys: filterEmptyStrings(secondaryKeys),
    regex: regex.trim(),
    content: content.trim(),
    enabled: enabled,
    constant: constant,
    selective: selective,
    position: position,
    priority: priority,
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 创建世界书。
 */
export function createLorebook(
  name: string,
  description: string = '',
  enabled: boolean = true,
  activationMode: LorebookActivationMode = LorebookActivationMode.FollowGlobal,
  injectionBudgetChars: number = 0,
  scanDepth: number = 0
): Lorebook {
  const now: number = Date.now();
  return {
    id: 'lb-' + generateUuid(),
    name: name.trim(),
    description: description.trim(),
    enabled: enabled,
    activationMode: activationMode,
    injectionBudgetChars: injectionBudgetChars,
    scanDepth: scanDepth,
    entries: [],
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 校验世界书条目。
 * @returns 错误信息字符串,如果校验通过返回 null
 */
export function validateLorebookEntry(entry: LorebookEntry): string | null {
  if (entry.name.trim().length === 0) {
    return '条目名称不能为空';
  }
  if (entry.name.length > MAX_NAME_LENGTH) {
    return '条目名称不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (entry.content.trim().length === 0) {
    return '条目内容不能为空';
  }
  if (entry.content.length > MAX_ENTRY_CONTENT_LENGTH) {
    return '条目内容不能超过' + MAX_ENTRY_CONTENT_LENGTH + '个字符';
  }
  if (entry.regex.length > MAX_ENTRY_REGEX_LENGTH) {
    return '正则表达式不能超过' + MAX_ENTRY_REGEX_LENGTH + '个字符';
  }
  if (entry.regex.trim().length > 0 && !isValidRegex(entry.regex)) {
    return '正则表达式无法编译,请检查语法';
  }
  if (!entry.constant && entry.keys.length === 0 && entry.regex.trim().length === 0) {
    return '非恒定条目至少需要一个关键词或正则';
  }
  return null;
}

/**
 * 校验正则表达式能否编译。
 */
export function isValidRegex(pattern: string): boolean {
  try {
    new RegExp(pattern);
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 校验世界书。
 * @returns 错误信息字符串,如果校验通过返回 null
 */
export function validateLorebook(lorebook: Lorebook): string | null {
  if (lorebook.name.trim().length === 0) {
    return '世界书名称不能为空';
  }
  if (lorebook.name.length > MAX_NAME_LENGTH) {
    return '世界书名称不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (lorebook.description.length > MAX_DESCRIPTION_LENGTH) {
    return '世界书描述不能超过' + MAX_DESCRIPTION_LENGTH + '个字符';
  }
  if (!isValidActivationMode(lorebook.activationMode)) {
    return '激活方式不合法';
  }
  if (!Number.isFinite(lorebook.injectionBudgetChars) ||
    lorebook.injectionBudgetChars < 0 || lorebook.injectionBudgetChars > MAX_INJECTION_BUDGET_CHARS) {
    return '注入预算必须在 0 到 ' + MAX_INJECTION_BUDGET_CHARS + ' 之间';
  }
  if (!Number.isFinite(lorebook.scanDepth) ||
    lorebook.scanDepth < 0 || lorebook.scanDepth > MAX_SCAN_DEPTH) {
    return '扫描深度必须在 0 到 ' + MAX_SCAN_DEPTH + ' 之间';
  }
  return null;
}

/**
 * 判断激活方式是否为合法枚举值。
 */
export function isValidActivationMode(mode: LorebookActivationMode): boolean {
  return mode === LorebookActivationMode.FollowGlobal ||
    mode === LorebookActivationMode.FullInject ||
    mode === LorebookActivationMode.OnDemand;
}

/**
 * 世界书更新字段。
 */
export interface LorebookUpdates {
  name?: string;
  description?: string;
  enabled?: boolean;
  activationMode?: LorebookActivationMode;
  injectionBudgetChars?: number;
  scanDepth?: number;
}

/**
 * 不可变更新世界书。
 */
export function updateLorebook(
  lorebook: Lorebook,
  updates: LorebookUpdates
): Lorebook {
  return {
    id: lorebook.id,
    name: updates.name !== undefined ? updates.name.trim() : lorebook.name,
    description: updates.description !== undefined ? updates.description.trim() : lorebook.description,
    enabled: updates.enabled !== undefined ? updates.enabled : lorebook.enabled,
    activationMode: updates.activationMode !== undefined ? updates.activationMode : lorebook.activationMode,
    injectionBudgetChars: updates.injectionBudgetChars !== undefined
      ? updates.injectionBudgetChars : lorebook.injectionBudgetChars,
    scanDepth: updates.scanDepth !== undefined ? updates.scanDepth : lorebook.scanDepth,
    entries: lorebook.entries,
    createdAt: lorebook.createdAt,
    updatedAt: Date.now()
  };
}

/**
 * 条目更新字段。
 */
export interface LorebookEntryUpdates {
  name?: string;
  keys?: string[];
  secondaryKeys?: string[];
  regex?: string;
  content?: string;
  enabled?: boolean;
  constant?: boolean;
  selective?: boolean;
  position?: LorebookPosition;
  priority?: number;
}

/**
 * 不可变更新世界书条目。
 */
export function updateLorebookEntry(
  entry: LorebookEntry,
  updates: LorebookEntryUpdates
): LorebookEntry {
  return {
    id: entry.id,
    name: updates.name !== undefined ? updates.name.trim() : entry.name,
    keys: updates.keys !== undefined ? filterEmptyStrings(updates.keys) : entry.keys,
    secondaryKeys: updates.secondaryKeys !== undefined
      ? filterEmptyStrings(updates.secondaryKeys) : entry.secondaryKeys,
    regex: updates.regex !== undefined ? updates.regex.trim() : entry.regex,
    content: updates.content !== undefined ? updates.content.trim() : entry.content,
    enabled: updates.enabled !== undefined ? updates.enabled : entry.enabled,
    constant: updates.constant !== undefined ? updates.constant : entry.constant,
    selective: updates.selective !== undefined ? updates.selective : entry.selective,
    position: updates.position !== undefined ? updates.position : entry.position,
    priority: updates.priority !== undefined ? updates.priority : entry.priority,
    createdAt: entry.createdAt,
    updatedAt: Date.now()
  };
}

/**
 * 添加条目到世界书(不可变,返回新 Lorebook)。
 */
export function addEntryToLorebook(
  lorebook: Lorebook,
  entry: LorebookEntry
): Lorebook {
  return {
    id: lorebook.id,
    name: lorebook.name,
    description: lorebook.description,
    enabled: lorebook.enabled,
    activationMode: lorebook.activationMode,
    injectionBudgetChars: lorebook.injectionBudgetChars,
    scanDepth: lorebook.scanDepth,
    entries: [...lorebook.entries, entry],
    createdAt: lorebook.createdAt,
    updatedAt: Date.now()
  };
}

/**
 * 从世界书移除条目(不可变,返回新 Lorebook)。
 */
export function removeEntryFromLorebook(
  lorebook: Lorebook,
  entryId: string
): Lorebook {
  const newEntries: LorebookEntry[] = [];
  for (let i = 0; i < lorebook.entries.length; i++) {
    if (lorebook.entries[i].id !== entryId) {
      newEntries.push(lorebook.entries[i]);
    }
  }
  return {
    id: lorebook.id,
    name: lorebook.name,
    description: lorebook.description,
    enabled: lorebook.enabled,
    activationMode: lorebook.activationMode,
    injectionBudgetChars: lorebook.injectionBudgetChars,
    scanDepth: lorebook.scanDepth,
    entries: newEntries,
    createdAt: lorebook.createdAt,
    updatedAt: Date.now()
  };
}

/**
 * 更新世界书中的条目(不可变,返回新 Lorebook)。
 */
export function updateEntryInLorebook(
  lorebook: Lorebook,
  entryId: string,
  updates: LorebookEntryUpdates
): Lorebook {
  const newEntries: LorebookEntry[] = [];
  for (let i = 0; i < lorebook.entries.length; i++) {
    if (lorebook.entries[i].id === entryId) {
      newEntries.push(updateLorebookEntry(lorebook.entries[i], updates));
    } else {
      newEntries.push(lorebook.entries[i]);
    }
  }
  return {
    id: lorebook.id,
    name: lorebook.name,
    description: lorebook.description,
    enabled: lorebook.enabled,
    activationMode: lorebook.activationMode,
    injectionBudgetChars: lorebook.injectionBudgetChars,
    scanDepth: lorebook.scanDepth,
    entries: newEntries,
    createdAt: lorebook.createdAt,
    updatedAt: Date.now()
  };
}

/**
 * 过滤字符串数组中的空字符串。
 */
function filterEmptyStrings(arr: string[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const trimmed: string = arr[i].trim();
    if (trimmed.length > 0) {
      result.push(trimmed);
    }
  }
  return result;
}