/**
 * LorebookJsonParser 世界书 JSON 解析器
 *
 * 解析 SillyTavern 世界书(Lorebook / World Info)JSON 文件,
 * 采用白名单方式只读取已知字段,忽略 extensions 等无用大字段,
 * 避免超出 RDB 共享块 2MB 上限。
 *
 * 支持字段:
 * - 顶层:{ name, description, scan_depth, token_budget, recursive_scanning, entries }
 * - 条目:{ keys, secondary_keys, comment, content, constant, selective,
 *          insertion_order/priority, enabled, position, case_sensitive }
 *
 * 纯逻辑、不依赖 ArkUI、不引入 UI 状态。
 */

import {
  Lorebook,
  LorebookEntry,
  LorebookPosition,
  createLorebook,
  createLorebookEntry,
  validateLorebookEntry
} from '../models/Lorebook';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LorebookJsonParser';

/** 单个世界书文件最大条目数(防止超大文件撑爆数据库) */
const MAX_ENTRIES: number = 2000;
/** 单条内容最大长度(字符) */
const MAX_CONTENT_LENGTH: number = 100000;

/** 解析后的世界书文件中间格式 */
export interface ParsedLorebookFile {
  readonly name: string;
  readonly description: string;
  readonly enabled: boolean;
  readonly entries: LorebookEntry[];
}

/** 字段读取上限:超出则视为无效数据,防止恶意/超大字段 */
const ENTRY_NAME_LIMIT: number = 100;

/**
 * 解析世界书 JSON 文本。
 * @param fallbackName 当 JSON 无书名时使用的兜底书名(通常取文件名)。
 * @throws 文本不是合法 JSON 或结构无效时抛出 Error
 */
export function parseLorebookJson(text: string, fallbackName: string = ''): ParsedLorebookFile {
  let root: Object;
  try {
    root = JSON.parse(text) as Object;
  } catch (e) {
    throw new Error('文件不是有效的 JSON 世界书');
  }
  if (typeof root !== 'object' || root === null || Array.isArray(root)) {
    throw new Error('文件不是有效的世界书');
  }
  const obj: Record<string, Object> = root as Record<string, Object>;

  const name: string = readString(obj, 'name', '').trim();
  const description: string = readString(obj, 'description', '').trim();
  const enabled: boolean = readBool(obj, 'enabled', true);

  // entries 可能存在两种形态:
  // 1. 数组:SillyTavern 标准 [[{...}, {...}]
  // 2. 对象(以序号为键):部分导出工具(如 TavernAI / 部分世界书导出)使用
  const entriesList: Object[] = extractEntriesList(obj);
  const entries: LorebookEntry[] = [];
  const limit: number = Math.min(entriesList.length, MAX_ENTRIES);
  for (let i = 0; i < limit; i++) {
    const item: Object = entriesList[i];
    if (typeof item !== 'object' || item === null || Array.isArray(item)) {
      continue;
    }
    const entry: LorebookEntry | null = parseEntry(item as Record<string, Object>, i);
    if (entry !== null) {
      entries.push(entry);
    }
  }

  // 兜底书名
  const finalName: string = name.length > 0
    ? name
    : (fallbackName.length > 0 ? fallbackName : '导入的世界书');
  return {
    name: finalName,
    description: description,
    enabled: enabled,
    entries: entries
  };
}

/**
 * 提取条目列表。
 * - 数组:原样返回
 * - 对象(以 "0","1",... 为键):返回其值,并按 displayIndex→order→uid 稳定排序
 * - 既不是数组也不是对象:抛错
 */
function extractEntriesList(obj: Record<string, Object>): Object[] {
  const v: Object | undefined = obj['entries'];
  if (v === undefined || v === null) {
    return [];
  }
  if (Array.isArray(v)) {
    return v as Object[];
  }
  if (typeof v === 'object') {
    const rec: Record<string, Object> = v as Record<string, Object>;
    const values: Object[] = [];
    const sortKeys: number[] = [];
    const recKeys: string[] = Object.keys(rec);
    for (let i = 0; i < recKeys.length; i++) {
      const item: Object = rec[recKeys[i]];
      if (typeof item === 'object' && item !== null && !Array.isArray(item)) {
        const m: Record<string, Object> = item as Record<string, Object>;
        values.push(item);
        sortKeys.push(readEntrySortIndex(m));
      }
    }
    // 稳定排序(displayIndex 优先,其次 order,再次 uid)
    const ndx: number[] = [];
    for (let i = 0; i < values.length; i++) {
      ndx.push(i);
    }
    ndx.sort((a: number, b: number): number => {
      if (sortKeys[a] !== sortKeys[b]) {
        return sortKeys[a] - sortKeys[b];
      }
      return a - b;
    });
    const ordered: Object[] = [];
    for (let i = 0; i < ndx.length; i++) {
      ordered.push(values[ndx[i]]);
    }
    return ordered;
  }
  throw new Error('世界书 entries 必须是数组或对象');
}

/** 计算对象形态条目的排序键(displayIndex→order→uid,缺失按顺序补位)。 */
function readEntrySortIndex(m: Record<string, Object>): number {
  let v: number = readNumber(m, 'displayIndex', -1);
  if (v >= 0) {
    return v;
  }
  v = readNumber(m, 'order', -1);
  if (v >= 0) {
    return v;
  }
  return readNumber(m, 'uid', -1);
}

/** 解析单条世界书条目;非法条目返回 null(跳过)。 */
function parseEntry(raw: Record<string, Object>, index: number): LorebookEntry | null {
  // 兼容两种字段名:SillyTavern(keys/secondary_keys) 与对象形态导出(key/keysecondary)
  const keys: string[] = readKeyArray(raw, 'keys', 'key');
  const secondaryKeys: string[] = readKeyArray(raw, 'secondary_keys', 'keysecondary');
  const content: string = readString(raw, 'content', '');
  const entryName: string = readString(raw, 'name', '').trim();
  const name: string = entryName.length > 0
    ? entryName
    : (keys.length > 0 ? keys[0] : '条目 ' + String(index + 1));

  let enabled: boolean = readBool(raw, 'enabled', true);
  if (readBool(raw, 'disable', false)) {
    enabled = false;
  }
  const constant: boolean = readBool(raw, 'constant', false);
  const selective: boolean = readBool(raw, 'selective', false);
  const position: LorebookPosition = mapPosition(raw['position']);
  const insertionOrder: number = readNumber(raw, 'insertion_order', 0);
  const priority: number = readNumber(raw, 'priority', insertionOrder);

  // 内容过长则截断,避免撑爆单个条目
  const cappedContent: string = content.length > MAX_CONTENT_LENGTH
    ? content.substring(0, MAX_CONTENT_LENGTH)
    : content;
  if (cappedContent.trim().length === 0 && keys.length === 0 && !constant) {
    // 既无内容也无关键词且非常量,视为无效条目,跳过
    return null;
  }
  if (name.length > ENTRY_NAME_LIMIT) {
    // 名字过长,用关键词或序号替代
    return null;
  }

  try {
    const entry: LorebookEntry = createLorebookEntry(
      name,
      keys,
      secondaryKeys,
      cappedContent,
      enabled,
      constant,
      selective,
      position,
      priority
    );
    if (validateLorebookEntry(entry) !== null) {
      return null;
    }
    return entry;
  } catch (e) {
    Logger.warn(LOG_TAG, 'parseEntry failed index=' + index + ': ' + String(e));
    return null;
  }
}

/** 生成一个已经填充条目的 Lorebook(供入库)。 */
export function buildLorebookFromParsed(parsed: ParsedLorebookFile): Lorebook {
  const base: Lorebook = createLorebook(parsed.name, parsed.description, parsed.enabled);
  return {
    id: base.id,
    name: base.name,
    description: base.description,
    enabled: base.enabled,
    entries: parsed.entries,
    createdAt: base.createdAt,
    updatedAt: base.updatedAt
  };
}

// ===== 安全读取辅助 =====

function readString(raw: Record<string, Object>, key: string, fallback: string): string {
  const v: Object | undefined = raw[key];
  if (typeof v === 'string') {
    return v as string;
  }
  return fallback;
}

function readStringArray(raw: Record<string, Object>, key: string): string[] {
  const v: Object | undefined = raw[key];
  if (!Array.isArray(v)) {
    return [];
  }
  const arr: Object[] = v as Object[];
  const result: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    if (typeof arr[i] === 'string' && (arr[i] as string).trim().length > 0) {
      result.push((arr[i] as string).trim());
    }
  }
  return result;
}

/**
 * 读取关键词数组:优先读 primary(如 keys),为空/缺失时回退 secondary(如 key)。
 */
function readKeyArray(
  raw: Record<string, Object>,
  primary: string,
  fallback: string
): string[] {
  const primaryArr: string[] = readStringArray(raw, primary);
  if (primaryArr.length > 0) {
    return primaryArr;
  }
  return readStringArray(raw, fallback);
}

function readNumber(raw: Record<string, Object>, key: string, fallback: number): number {
  const v: Object | undefined = raw[key];
  if (typeof v === 'number' && Number.isFinite(v)) {
    return Math.floor(v as number);
  }
  if (typeof v === 'string') {
    const n: number = Number.parseInt(v as string, 10);
    if (Number.isFinite(n)) {
      return n;
    }
  }
  return fallback;
}

function readBool(raw: Record<string, Object>, key: string, fallback: boolean): boolean {
  const v: Object | undefined = raw[key];
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  if (typeof v === 'number') {
    return (v as number) !== 0;
  }
  return fallback;
}

/** 兼容多种 position 表示:字符串('before_char'/'after_char'/'0'/'1')或数字(0=前,非0=后)。 */
function mapPosition(raw: Object | undefined): LorebookPosition {
  if (typeof raw === 'string') {
    const s: string = (raw as string).toLowerCase();
    if (s === 'after_char' || s === '1') {
      return LorebookPosition.AfterCharacter;
    }
    if (s === 'before_char' || s === '0') {
      return LorebookPosition.BeforeCharacter;
    }
    return LorebookPosition.AfterCharacter;
  }
  if (typeof raw === 'number') {
    return (raw as number) === 0
      ? LorebookPosition.BeforeCharacter
      : LorebookPosition.AfterCharacter;
  }
  return LorebookPosition.BeforeCharacter;
}