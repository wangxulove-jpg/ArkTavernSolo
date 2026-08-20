/**
 * Lorebook 世界书数据模型
 *
 * 定义世界书和条目的数据结构、校验规则和不可变更新。
 * 不依赖 ArkUI,可用于服务层和持久化层。
 *
 * 约束:
 * - name 必填,最长 100 字符
 * - entry name 必填,最长 100 字符
 * - entry content 必填,最长 5000 字符
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
 * 世界书条目模型。
 */
export interface LorebookEntry {
  readonly id: string;
  readonly name: string;
  readonly keys: string[];
  readonly secondaryKeys: string[];
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
  readonly entries: LorebookEntry[];
  readonly createdAt: number;
  readonly updatedAt: number;
}

const MAX_NAME_LENGTH: number = 100;
const MAX_ENTRY_CONTENT_LENGTH: number = 5000;
const MAX_DESCRIPTION_LENGTH: number = 500;

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
  priority: number = 0
): LorebookEntry {
  const now: number = Date.now();
  return {
    id: 'lbe-' + generateUuid(),
    name: name.trim(),
    keys: filterEmptyStrings(keys),
    secondaryKeys: filterEmptyStrings(secondaryKeys),
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
  enabled: boolean = true
): Lorebook {
  const now: number = Date.now();
  return {
    id: 'lb-' + generateUuid(),
    name: name.trim(),
    description: description.trim(),
    enabled: enabled,
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
  if (!entry.constant && entry.keys.length === 0) {
    return '非恒定条目至少需要一个关键词';
  }
  return null;
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
  return null;
}

/**
 * 世界书更新字段。
 */
export interface LorebookUpdates {
  name?: string;
  description?: string;
  enabled?: boolean;
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