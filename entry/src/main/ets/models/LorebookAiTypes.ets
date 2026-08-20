/**
 * LorebookAiTypes AI 世界书修改类型
 *
 * 定义 AI 生成的世界书变更提案(新增/修改/删除)及其安全解析与校验。
 * 纯数据模型,不依赖 ArkUI / 网络 / 服务。
 *
 * 使用场景:
 * - AiLorebookService 让 AI 基于现有条目 + 近期对话输出变更集
 * - 页面预览变更集,用户确认后由 LorebookService 落库
 *
 * 约束:
 * - 不使用 any
 * - JSON.parse 结果必须经安全提取,不直接断言为接口
 * - 解析失败返回 null / 空变更集,不抛错
 */

import { extractJsonObject } from '../parser/CharacterCardV2Fixer';

/** 新增条目提案。 */
export interface AiLorebookAdd {
  readonly lorebookId: string;
  readonly name: string;
  readonly keys: string[];
  readonly content: string;
  readonly position: string;
  readonly priority: number;
  readonly constant: boolean;
}

/** 修改条目提案(字段可选,未提供表示不修改)。 */
export interface AiLorebookUpdate {
  readonly lorebookId: string;
  readonly entryId: string;
  readonly name?: string;
  readonly keys?: string[];
  readonly content?: string;
  readonly position?: string;
  readonly priority?: number;
}

/** 删除条目提案。 */
export interface AiLorebookDelete {
  readonly lorebookId: string;
  readonly entryId: string;
}

/** AI 世界书变更集。 */
export interface AiLorebookChangeSet {
  readonly adds: AiLorebookAdd[];
  readonly updates: AiLorebookUpdate[];
  readonly deletes: AiLorebookDelete[];
}

/**
 * 创建空变更集。
 */
export function createEmptyAiLorebookChangeSet(): AiLorebookChangeSet {
  return {
    adds: [],
    updates: [],
    deletes: []
  };
}

/**
 * 从 AI 返回文本解析变更集。
 * 失败(无法提取 JSON / 结构非法)返回 null,不抛错。
 *
 * 期望 JSON 结构:
 * {
 *   "adds": [{ "lorebookId": "...", "name": "...", "keys": [...], "content": "...",
 *              "position": "BeforeCharacter", "priority": 0, "constant": false }],
 *   "updates": [{ "lorebookId": "...", "entryId": "...", "content": "..." }],
 *   "deletes": [{ "lorebookId": "...", "entryId": "..." }]
 * }
 */
export function parseAiLorebookChangeSet(raw: string): AiLorebookChangeSet | null {
  if (raw.length === 0) {
    return null;
  }
  const extracted: string = extractJsonObject(raw);
  if (extracted.length === 0) {
    return null;
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(extracted);
  } catch (e) {
    return null;
  }
  if (parsed === null || typeof parsed !== 'object') {
    return null;
  }
  const root: Record<string, Object> = parsed as Record<string, Object>;

  const adds: AiLorebookAdd[] = [];
  const addItems: Record<string, Object>[] = getObjectArrayField(root, 'adds');
  for (let i = 0; i < addItems.length; i++) {
    const item: Record<string, Object> = addItems[i];
    const lorebookId: string = getStringField(item, 'lorebookId') ?? '';
    const name: string = getStringField(item, 'name') ?? '';
    const content: string = getStringField(item, 'content') ?? '';
    if (lorebookId.length === 0 || name.length === 0 || content.length === 0) {
      continue;
    }
    const position: string = getStringField(item, 'position') ?? 'BeforeCharacter';
    adds.push({
      lorebookId: lorebookId,
      name: name,
      keys: getStringArrayField(item, 'keys') ?? [],
      content: content,
      position: normalizePosition(position),
      priority: getNumberField(item, 'priority') ?? 0,
      constant: getBoolField(item, 'constant') ?? false
    });
  }

  const updates: AiLorebookUpdate[] = [];
  const updateItems: Record<string, Object>[] = getObjectArrayField(root, 'updates');
  for (let i = 0; i < updateItems.length; i++) {
    const item: Record<string, Object> = updateItems[i];
    const lorebookId: string = getStringField(item, 'lorebookId') ?? '';
    const entryId: string = getStringField(item, 'entryId') ?? '';
    if (lorebookId.length === 0 || entryId.length === 0) {
      continue;
    }
    const keys: string[] | undefined = getStringArrayField(item, 'keys');
    const name: string | undefined = getStringField(item, 'name');
    const content: string | undefined = getStringField(item, 'content');
    const position: string | undefined = getStringField(item, 'position');
    const priority: number | undefined = getNumberField(item, 'priority');
    updates.push({
      lorebookId: lorebookId,
      entryId: entryId,
      name: name !== undefined && name.length > 0 ? name : undefined,
      keys: keys,
      content: content !== undefined && content.length > 0 ? content : undefined,
      position: position !== undefined ? normalizePosition(position) : undefined,
      priority: priority
    });
  }

  const deletes: AiLorebookDelete[] = [];
  const deleteItems: Record<string, Object>[] = getObjectArrayField(root, 'deletes');
  for (let i = 0; i < deleteItems.length; i++) {
    const item: Record<string, Object> = deleteItems[i];
    const lorebookId: string = getStringField(item, 'lorebookId') ?? '';
    const entryId: string = getStringField(item, 'entryId') ?? '';
    if (lorebookId.length === 0 || entryId.length === 0) {
      continue;
    }
    deletes.push({ lorebookId: lorebookId, entryId: entryId });
  }

  return {
    adds: adds,
    updates: updates,
    deletes: deletes
  };
}

/**
 * 校验变更集。
 *
 * @param changes 变更集
 * @param allowedBookIds 允许操作的世界书 ID 列表(面板展示的两本)
 * @returns 错误信息列表(为空表示通过)
 */
export function validateAiChangeSet(
  changes: AiLorebookChangeSet,
  allowedBookIds: string[]
): string[] {
  const errors: string[] = [];
  for (let i = 0; i < changes.adds.length; i++) {
    const a: AiLorebookAdd = changes.adds[i];
    if (allowedBookIds.indexOf(a.lorebookId) < 0) {
      errors.push('新增条目目标世界书不在当前会话: ' + a.name);
    }
    if (a.name.length === 0) {
      errors.push('新增条目缺少名称');
    }
    if (a.content.length === 0) {
      errors.push('新增条目缺少内容');
    } else if (a.content.length > 5000) {
      errors.push('新增条目内容超长(>5000): ' + a.name);
    }
    if (!a.constant && a.keys.length === 0) {
      errors.push('非恒定新增条目缺少关键词: ' + a.name);
    }
  }
  for (let i = 0; i < changes.updates.length; i++) {
    const u: AiLorebookUpdate = changes.updates[i];
    if (allowedBookIds.indexOf(u.lorebookId) < 0) {
      errors.push('修改条目目标世界书不在当前会话');
    }
    if (u.entryId.length === 0) {
      errors.push('修改条目缺少条目 ID');
    }
    if (u.content !== undefined && u.content.length > 5000) {
      errors.push('修改条目内容超长(>5000): ' + (u.name !== undefined ? u.name : u.entryId));
    }
  }
  for (let i = 0; i < changes.deletes.length; i++) {
    const d: AiLorebookDelete = changes.deletes[i];
    if (allowedBookIds.indexOf(d.lorebookId) < 0) {
      errors.push('删除条目目标世界书不在当前会话');
    }
    if (d.entryId.length === 0) {
      errors.push('删除条目缺少条目 ID');
    }
  }
  return errors;
}

/**
 * 归一化 position 字符串为受支持值,非法值回退 BeforeCharacter。
 */
function normalizePosition(position: string): string {
  if (position === 'AfterCharacter') {
    return 'AfterCharacter';
  }
  return 'BeforeCharacter';
}

function getStringField(obj: Record<string, Object>, key: string): string | undefined {
  const val: Object | undefined = obj[key];
  if (val === undefined || val === null) {
    return undefined;
  }
  if (typeof val === 'string') {
    return val;
  }
  return undefined;
}

function getNumberField(obj: Record<string, Object>, key: string): number | undefined {
  const val: Object | undefined = obj[key];
  if (val === undefined || val === null) {
    return undefined;
  }
  if (typeof val === 'number') {
    return val;
  }
  return undefined;
}

function getBoolField(obj: Record<string, Object>, key: string): boolean | undefined {
  const val: Object | undefined = obj[key];
  if (val === undefined || val === null) {
    return undefined;
  }
  if (typeof val === 'boolean') {
    return val;
  }
  return undefined;
}

function getStringArrayField(obj: Record<string, Object>, key: string): string[] | undefined {
  const val: Object | undefined = obj[key];
  if (!(val instanceof Array)) {
    return undefined;
  }
  const result: string[] = [];
  const arr: Object[] = val as Object[];
  for (let i = 0; i < arr.length; i++) {
    if (typeof arr[i] === 'string') {
      result.push(arr[i] as string);
    }
  }
  return result;
}

function getObjectArrayField(
  obj: Record<string, Object>,
  key: string
): Record<string, Object>[] {
  const val: Object | undefined = obj[key];
  if (!(val instanceof Array)) {
    return [];
  }
  const result: Record<string, Object>[] = [];
  const arr: Object[] = val as Object[];
  for (let i = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (item !== null && typeof item === 'object') {
      result.push(item as Record<string, Object>);
    }
  }
  return result;
}
