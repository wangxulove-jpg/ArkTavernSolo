/**
 * ChapterMemoryIndexer 章节记忆实体索引器(v46)
 *
 * 职责:
 * - 解析章节摘要中的实体(人名/地点/时间),支持 v46 新格式头部行与旧格式 Markdown 段
 * - 跨章节合并实体 → 章节映射(EntityIndex),供会话记忆 detail 持久化与按需加载匹配
 * - 按实体分组章节(记忆管理页"按人物·事件"视图,纯展示层重排,不修改章节内容)
 * - 实体名包含匹配(ASCII 忽略大小写,非 ASCII 精确包含,与 MemoryService.matchMemoryKeywords 规则一致)
 *
 * 设计约束:
 * - 纯函数,零外部依赖(仅依赖 ChatMemory 模型)
 * - 解析失败的章节返回空实体,不抛错
 * - 不存储消息正文,只处理 summary 文本
 */

import { ChatMemory } from '../models/ChatMemory';

/** 实体种类 */
export type EntityKind = 'person' | 'place' | 'time';

/** 单条实体索引项:实体名 → 关联章节 */
export interface EntityIndexEntry {
  /** 实体名(人名/地点/时间) */
  readonly name: string;
  /** 实体种类 */
  readonly kind: EntityKind;
  /** 关联章节 Memory ID 列表(去重,按章节时间正序) */
  readonly chapterIds: string[];
}

/** 实体索引(序列化到会话记忆 detail 字段) */
export interface EntityIndex {
  /** 全部实体项 */
  readonly entries: EntityIndexEntry[];
}

/** 章节解析出的实体集合 */
export interface ChapterEntities {
  /** 人名列表 */
  readonly persons: string[];
  /** 地点列表 */
  readonly places: string[];
  /** 时间列表 */
  readonly times: string[];
}

/** 实体分组视图项(记忆管理页展示) */
export interface EntityChapterGroup {
  /** 实体名 */
  readonly name: string;
  /** 实体种类 */
  readonly kind: EntityKind;
  /** 该实体涉及的章节(时间正序) */
  readonly chapters: ChatMemory[];
}

/** 实体种类显示名 */
const ENTITY_KIND_LABELS: Record<EntityKind, string> = {
  'person': '人物',
  'place': '地点',
  'time': '时间'
};

/** 实体名拆分分隔符(顿号/逗号/分号/斜杠) */
const NAME_DELIMITER: RegExp = new RegExp('[、,，;；/\\s]+');

/** 空实体集合 */
const EMPTY_ENTITIES: ChapterEntities = { persons: [], places: [], times: [] };

/** 实体名长度上限(超过视为解析噪音丢弃) */
const MAX_ENTITY_NAME_LENGTH: number = 12;

/** 空索引 */
export function createEmptyEntityIndex(): EntityIndex {
  return { entries: [] };
}

/**
 * 解析单条章节摘要的实体。
 * - v46 新格式:开头元数据行 `参与者: xx(身份), yy` / `地点: xx` / `时间: xx`(冒号支持半角/全角)
 * - 旧格式回退:`## 参与者` 段按分隔符切名;`## 时间与地点` 段首句作时间
 * - 全部解析失败返回空集合
 */
export function parseChapterEntities(summary: string): ChapterEntities {
  if (summary.length === 0) {
    return EMPTY_ENTITIES;
  }
  const lines: string[] = summary.split('\n');
  const persons: string[] = [];
  const places: string[] = [];
  const times: string[] = [];

  // 1. 优先解析 v46 头部元数据行
  for (let i = 0; i < lines.length && i < 10; i++) {
    const line: string = lines[i].trim();
    if (line.startsWith('##')) {
      // 已进入 Markdown 正文,头部区结束
      break;
    }
    const personsMatch: RegExpMatchArray | null = matchMetaLine(line, '参与者');
    if (personsMatch !== null) {
      appendNames(persons, personsMatch[1]);
      continue;
    }
    const placeMatch: RegExpMatchArray | null = matchMetaLine(line, '地点');
    if (placeMatch !== null) {
      appendNames(places, placeMatch[1]);
      continue;
    }
    const timeMatch: RegExpMatchArray | null = matchMetaLine(line, '时间');
    if (timeMatch !== null) {
      const value: string = stripParenthetical(timeMatch[1].trim());
      if (value.length > 0 && value.length <= 20) {
        times.push(value);
      }
      continue;
    }
  }
  if (persons.length > 0 || places.length > 0 || times.length > 0) {
    return { persons, places, times };
  }

  // 2. 旧格式回退:解析 Markdown 段
  const participantBody: string = extractSectionBody(summary, '参与者');
  if (participantBody.length > 0) {
    appendNames(persons, participantBody);
  }
  const timePlaceBody: string = extractSectionBody(summary, '时间与地点');
  if (timePlaceBody.length > 0) {
    // 首句(到第一个标点为止)作为时间,≤20 字
    const firstSentence: string = splitFirstSentence(timePlaceBody);
    if (firstSentence.length > 0 && firstSentence.length <= 20) {
      times.push(firstSentence);
    }
  }
  return { persons, places, times };
}

/**
 * 跨章节合并实体索引。
 * 同名同种类实体合并 chapterIds(去重);输出按 人物 → 地点 → 时间,
 * 同种类内按关联章节数降序。
 */
export function buildEntityIndex(chapters: ChatMemory[]): EntityIndex {
  const entries: EntityIndexEntry[] = [];
  const keySet: Set<string> = new Set<string>();
  // key = kind + '\n' + name,保持插入顺序
  const keys: string[] = [];
  const entryMap: Map<string, EntityIndexEntry> = new Map<string, EntityIndexEntry>();

  const sorted: ChatMemory[] = chapters.slice().sort(
    (a: ChatMemory, b: ChatMemory): number => a.createdAt - b.createdAt
  );

  for (let i = 0; i < sorted.length; i++) {
    const chapter: ChatMemory = sorted[i];
    const entities: ChapterEntities = parseChapterEntities(chapter.summary);
    collectEntry(entryMap, keys, keySet, entities.persons, 'person', chapter.id);
    collectEntry(entryMap, keys, keySet, entities.places, 'place', chapter.id);
    collectEntry(entryMap, keys, keySet, entities.times, 'time', chapter.id);
  }

  for (let i = 0; i < keys.length; i++) {
    const entry: EntityIndexEntry | undefined = entryMap.get(keys[i]);
    if (entry !== undefined) {
      entries.push(entry);
    }
  }
  // 人物 → 地点 → 时间;同种类按章节数降序
  const kindOrder: Record<EntityKind, number> = { 'person': 0, 'place': 1, 'time': 2 };
  entries.sort((a: EntityIndexEntry, b: EntityIndexEntry): number => {
    const kindDiff: number = kindOrder[a.kind] - kindOrder[b.kind];
    if (kindDiff !== 0) {
      return kindDiff;
    }
    return b.chapterIds.length - a.chapterIds.length;
  });
  return { entries };
}

/**
 * 按实体分组章节(记忆管理页"按人物·事件"视图)。
 * 返回按实体涉及章节数降序的分组;无实体的章节不出现在任何分组。
 */
export function groupChaptersByEntity(chapters: ChatMemory[]): EntityChapterGroup[] {
  const groupMap: Map<string, EntityChapterGroup> = new Map<string, EntityChapterGroup>();
  const keys: string[] = [];

  const sorted: ChatMemory[] = chapters.slice().sort(
    (a: ChatMemory, b: ChatMemory): number => a.createdAt - b.createdAt
  );

  for (let i = 0; i < sorted.length; i++) {
    const chapter: ChatMemory = sorted[i];
    const entities: ChapterEntities = parseChapterEntities(chapter.summary);
    appendGroup(groupMap, keys, entities.persons, 'person', chapter);
    appendGroup(groupMap, keys, entities.places, 'place', chapter);
    appendGroup(groupMap, keys, entities.times, 'time', chapter);
  }

  const groups: EntityChapterGroup[] = [];
  for (let i = 0; i < keys.length; i++) {
    const group: EntityChapterGroup | undefined = groupMap.get(keys[i]);
    if (group !== undefined) {
      groups.push(group);
    }
  }
  groups.sort((a: EntityChapterGroup, b: EntityChapterGroup): number =>
    b.chapters.length - a.chapters.length
  );
  return groups;
}

/**
 * 实体包含匹配:返回在任一文本中命中的实体名列表。
 * ASCII 实体忽略大小写,非 ASCII 精确包含。
 */
export function matchEntities(index: EntityIndex, texts: string[]): string[] {
  const matched: string[] = [];
  for (let i = 0; i < index.entries.length; i++) {
    const entry: EntityIndexEntry = index.entries[i];
    if (isEntityHit(entry.name, texts)) {
      matched.push(entry.name);
    }
  }
  return matched;
}

/**
 * 实体匹配 → 关联章节 ID(按需加载用)。
 * 返回命中实体关联的全部章节 ID(去重)。
 */
export function matchEntityChapterIds(index: EntityIndex, texts: string[]): string[] {
  const idSet: Set<string> = new Set<string>();
  for (let i = 0; i < index.entries.length; i++) {
    const entry: EntityIndexEntry = index.entries[i];
    if (isEntityHit(entry.name, texts)) {
      for (let j = 0; j < entry.chapterIds.length; j++) {
        idSet.add(entry.chapterIds[j]);
      }
    }
  }
  return Array.from(idSet);
}

/** 序列化实体索引为 JSON(存会话记忆 detail 字段)。 */
export function serializeEntityIndex(index: EntityIndex): string {
  return JSON.stringify(index);
}

/** 解析会话记忆 detail 中的实体索引 JSON(损坏返回空索引)。 */
export function parseEntityIndexJson(json: string): EntityIndex {
  if (json.length === 0) {
    return createEmptyEntityIndex();
  }
  try {
    const parsed: Object = JSON.parse(json) as Object;
    const record: Record<string, Object> = parsed as Record<string, Object>;
    const rawEntries: Object | undefined = record['entries'];
    if (!Array.isArray(rawEntries)) {
      return createEmptyEntityIndex();
    }
    const arr: Object[] = rawEntries as Object[];
    const entries: EntityIndexEntry[] = [];
    for (let i = 0; i < arr.length; i++) {
      const item: Record<string, Object> = arr[i] as Record<string, Object>;
      const name: Object | undefined = item['name'];
      const kind: Object | undefined = item['kind'];
      const chapterIds: Object | undefined = item['chapterIds'];
      if (typeof name !== 'string' || typeof kind !== 'string' || !Array.isArray(chapterIds)) {
        continue;
      }
      const ids: string[] = [];
      const idArr: Object[] = chapterIds as Object[];
      for (let j = 0; j < idArr.length; j++) {
        if (typeof idArr[j] === 'string') {
          ids.push(idArr[j] as string);
        }
      }
      const kindValue: EntityKind =
        kind === 'person' || kind === 'place' || kind === 'time'
          ? kind as EntityKind : 'person';
      const entry: EntityIndexEntry = { name: name, kind: kindValue, chapterIds: ids };
      entries.push(entry);
    }
    return { entries: entries };
  } catch (_e) {
    return createEmptyEntityIndex();
  }
}

/** 实体种类显示名(供 UI)。 */
export function entityKindLabel(kind: EntityKind): string {
  return ENTITY_KIND_LABELS[kind];
}

// ===== 内部工具 =====

/** 匹配 `标签: 值` 元数据行(冒号支持半角/全角),返回 [full, value] 或 null。 */
function matchMetaLine(line: string, label: string): RegExpMatchArray | null {
  const reg: RegExp = new RegExp('^' + label + '[：:]\\s*(.+)$');
  return line.match(reg);
}

/** 去掉名字中的括号补充说明(全角/半角),如 `张三(主角)` → `张三`。 */
function stripParenthetical(name: string): string {
  const half: number = name.indexOf('(');
  const full: number = name.indexOf('（');
  let cut: number = name.length;
  if (half >= 0) {
    cut = Math.min(cut, half);
  }
  if (full >= 0) {
    cut = Math.min(cut, full);
  }
  return name.slice(0, cut).trim();
}

/** 按分隔符拆分实体名并追加到目标列表(去重,长度 1~MAX_ENTITY_NAME_LENGTH)。 */
function appendNames(target: string[], raw: string): void {
  const tokens: string[] = raw.split(NAME_DELIMITER);
  for (let i = 0; i < tokens.length; i++) {
    const name: string = stripParenthetical(tokens[i].trim());
    if (name.length === 0 || name.length > MAX_ENTITY_NAME_LENGTH) {
      continue;
    }
    if (name.startsWith('#') || name.startsWith('【')) {
      continue;
    }
    if (!target.includes(name)) {
      target.push(name);
    }
  }
}

/** 提取 `## {sectionTitle}` Markdown 段的正文(到下一个 ## 或文本结束),无该段返回空。 */
function extractSectionBody(summary: string, sectionTitle: string): string {
  const reg: RegExp = new RegExp('##\\s*' + sectionTitle + '\\s*\\n([\\s\\S]*?)(?=\\n##|$)');
  const match: RegExpMatchArray | null = summary.match(reg);
  if (match === null || match.length < 2) {
    return '';
  }
  return match[1];
}

/** 取首句(到第一个句号/问号/叹号/换行为止)。 */
function splitFirstSentence(text: string): string {
  const reg: RegExp = new RegExp('[。！？!?\n]');
  const parts: string[] = text.trim().split(reg);
  if (parts.length === 0) {
    return '';
  }
  return parts[0].trim();
}

/** 实体名命中任一文本(ASCII 忽略大小写,非 ASCII 精确包含)。 */
function isEntityHit(name: string, texts: string[]): boolean {
  const isAscii: boolean = isAsciiOnly(name);
  for (let i = 0; i < texts.length; i++) {
    const text: string = texts[i];
    if (isAscii) {
      if (text.toLowerCase().includes(name.toLowerCase())) {
        return true;
      }
    } else if (text.includes(name)) {
      return true;
    }
  }
  return false;
}

function isAsciiOnly(str: string): boolean {
  for (let i = 0; i < str.length; i++) {
    if (str.charCodeAt(i) > 127) {
      return false;
    }
  }
  return true;
}

/** 收集实体 → 章节映射(Map 合并,保持首次插入顺序)。 */
function collectEntry(
  entryMap: Map<string, EntityIndexEntry>,
  keys: string[],
  keySet: Set<string>,
  names: string[],
  kind: EntityKind,
  chapterId: string
): void {
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    const key: string = kind + '\n' + name;
    const existing: EntityIndexEntry | undefined = entryMap.get(key);
    if (existing === undefined) {
      const entry: EntityIndexEntry = { name: name, kind: kind, chapterIds: [chapterId] };
      entryMap.set(key, entry);
      if (!keySet.has(key)) {
        keySet.add(key);
        keys.push(key);
      }
    } else if (!existing.chapterIds.includes(chapterId)) {
      const merged: EntityIndexEntry = {
        name: existing.name,
        kind: existing.kind,
        chapterIds: existing.chapterIds.concat([chapterId])
      };
      entryMap.set(key, merged);
    }
  }
}

/** 收集实体分组(Map 合并,保持首次插入顺序)。 */
function appendGroup(
  groupMap: Map<string, EntityChapterGroup>,
  keys: string[],
  names: string[],
  kind: EntityKind,
  chapter: ChatMemory
): void {
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    const key: string = kind + '\n' + name;
    const existing: EntityChapterGroup | undefined = groupMap.get(key);
    if (existing === undefined) {
      const group: EntityChapterGroup = { name: name, kind: kind, chapters: [chapter] };
      groupMap.set(key, group);
      if (!keys.includes(key)) {
        keys.push(key);
      }
    } else if (!existing.chapters.some((c: ChatMemory): boolean => c.id === chapter.id)) {
      const merged: EntityChapterGroup = {
        name: existing.name,
        kind: existing.kind,
        chapters: existing.chapters.concat([chapter])
      };
      groupMap.set(key, merged);
    }
  }
}
