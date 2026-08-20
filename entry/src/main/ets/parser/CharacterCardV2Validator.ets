/**
 * CharacterCardV2Validator Tavern Card V2 校验器
 *
 * 对 AI 生成的 JSON 进行 V2 spec 和字段类型校验,补齐缺失可选字段,
 * 输出统一的 ParsedCharacterCard 中间格式(供 CharacterService.importFromParsed 使用)。
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不使用 any
 * - 不使用正则表达式解析整个 JSON(只用 JSON.parse)
 * - 关键字段类型错误时拒绝(返回 errors)
 * - 可选字段缺失时补齐默认值
 * - 限制异常大字段(防止恶意/异常输入)
 *
 * 校验顺序:
 * 1. JSON.parse
 * 2. spec / spec_version
 * 3. data 对象存在
 * 4. data.name 必填且为字符串
 * 5. 其他字段类型校验
 * 6. 缺失可选字段补齐默认值
 * 7. character_book 结构校验
 * 8. extensions 必须为对象
 * 9. 所有数组字段即使为空也必须是数组
 */

import {
  ParsedCharacterCard,
  ParsedCharacterBook,
  ParsedCharacterBookEntry
} from './CharacterCardJsonParser';
import {
  AiValidationError,
  AiGenerationMeta,
  AI_GENERATION_VERSION,
  AI_DEFAULT_CREATOR,
  AI_DEFAULT_CHARACTER_VERSION
} from '../models/AiGenerationResult';

/**
 * 校验结果。
 */
export interface V2ValidationResult {
  /** 是否通过(无致命错误) */
  readonly ok: boolean;
  /** 校验通过的角色卡(ok=false 时为 null) */
  readonly card: ParsedCharacterCard | null;
  /** 校验错误列表(ok=true 时为空数组) */
  readonly errors: AiValidationError[];
}

/** 单字段最大字符数(防止异常大字段) */
const MAX_FIELD_LENGTH: number = 50000;
/** 数组最大长度(防止异常大数组) */
const MAX_ARRAY_LENGTH: number = 200;
/** character_book.entries 最大条目数 */
const MAX_BOOK_ENTRIES: number = 200;

/**
 * 校验并补齐 V2 角色卡。
 *
 * @param raw AI 返回的原始 JSON 字符串(已去除 Markdown 代码块)
 * @param meta 生成元数据(用于写入 extensions.arktavern.ai_generation)
 * @returns 校验结果
 */
export function validateV2CharacterCard(
  raw: string,
  meta: AiGenerationMeta | null
): V2ValidationResult {
  const errors: AiValidationError[] = [];

  // 1. JSON.parse
  let root: Record<string, Object>;
  try {
    const parsed: Object = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return fail([
        { field: 'root', code: 'type_error', message: 'JSON 顶层必须是对象' }
      ]);
    }
    root = parsed as Record<string, Object>;
  } catch (e) {
    return fail([
      { field: 'root', code: 'json_parse_error', message: 'JSON 不完整或格式无效: ' + String(e) }
    ]);
  }

  // 2. spec / spec_version
  const spec: string = getStringField(root, 'spec', '');
  if (spec !== 'chara_card_v2' && spec !== 'chara_card_v3') {
    // 兼容 V3(spec 仍接受)
    errors.push({
      field: 'spec',
      code: 'invalid_value',
      message: 'spec 必须为 "chara_card_v2",实际: "' + spec + '"'
    });
  }
  const specVersion: string = getStringField(root, 'spec_version', '');
  if (specVersion !== '2.0' && specVersion !== '3.0') {
    errors.push({
      field: 'spec_version',
      code: 'invalid_value',
      message: 'spec_version 必须为 "2.0",实际: "' + specVersion + '"'
    });
  }

  // 3. data 对象
  const dataRaw: Object | undefined = root['data'];
  if (dataRaw === undefined || dataRaw === null) {
    return fail([
      { field: 'data', code: 'missing', message: '缺少 data 字段' }
    ]);
  }
  if (typeof dataRaw !== 'object' || Array.isArray(dataRaw)) {
    return fail([
      { field: 'data', code: 'type_error', message: 'data 必须为对象' }
    ]);
  }
  const data: Record<string, Object> = dataRaw as Record<string, Object>;

  // 4. data.name 必填
  const nameRaw: Object | undefined = data['name'];
  if (nameRaw === undefined || nameRaw === null) {
    return fail([
      { field: 'data.name', code: 'missing', message: '角色缺少名称(name)' }
    ]);
  }
  if (typeof nameRaw !== 'string') {
    return fail([
      { field: 'data.name', code: 'type_error', message: 'name 必须为字符串' }
    ]);
  }
  const name: string = (nameRaw as string).trim();
  if (name.length === 0) {
    return fail([
      { field: 'data.name', code: 'empty', message: '角色名称(name)不能为空' }
    ]);
  }
  if (isPlaceholderName(name)) {
    return fail([
      {
        field: 'data.name',
        code: 'placeholder_name',
        message: '角色名称(name)不能是占位符(如 Entry、Character、未命名、数字编号),请生成一个自然、贴切的名字'
      }
    ]);
  }

  // 5. 字符串字段类型校验 + 长度限制
  const description: string = getLimitedStringField(data, 'description', errors, 'data.description');
  const personality: string = getLimitedStringField(data, 'personality', errors, 'data.personality');
  const scenario: string = getLimitedStringField(data, 'scenario', errors, 'data.scenario');
  const firstMes: string = getLimitedStringField(data, 'first_mes', errors, 'data.first_mes');
  const mesExample: string = getLimitedStringField(data, 'mes_example', errors, 'data.mes_example');
  const creatorNotes: string = getLimitedStringField(data, 'creator_notes', errors, 'data.creator_notes');
  const systemPrompt: string = getLimitedStringField(data, 'system_prompt', errors, 'data.system_prompt');
  const postHistory: string = getLimitedStringField(
    data, 'post_history_instructions', errors, 'data.post_history_instructions'
  );

  // 6. creator / character_version
  const creator: string = getStringField(data, 'creator', AI_DEFAULT_CREATOR);
  const characterVersion: string = getStringField(data, 'character_version', AI_DEFAULT_CHARACTER_VERSION);

  // 7. 数组字段(alternate_greetings / tags)
  const alternateGreetings: string[] = getStringArrayField(
    data, 'alternate_greetings', errors, 'data.alternate_greetings'
  );
  const tags: string[] = getStringArrayField(data, 'tags', errors, 'data.tags');

  // 8. extensions 必须为对象
  const extensionsRaw: Object | undefined = data['extensions'];
  let extensions: Record<string, Object>;
  if (extensionsRaw === undefined || extensionsRaw === null) {
    extensions = {};
  } else if (typeof extensionsRaw !== 'object' || Array.isArray(extensionsRaw)) {
    errors.push({
      field: 'data.extensions',
      code: 'type_error',
      message: 'extensions 必须为对象'
    });
    extensions = {};
  } else {
    extensions = extensionsRaw as Record<string, Object>;
  }

  // 9. character_book 结构校验
  const characterBook: ParsedCharacterBook | null = parseCharacterBook(
    data['character_book'], errors
  );

  // 致命错误(任一 type_error / missing 则拒绝)
  const hasFatal: boolean = errors.some((e: AiValidationError): boolean =>
    e.code === 'missing' || e.code === 'type_error' || e.code === 'json_parse_error'
  );

  if (hasFatal) {
    return fail(errors);
  }

  // 10. 注入 arktavern.ai_generation 元数据(保留既有 extensions)
  if (meta !== null) {
    let arktavernExt: Record<string, Object> = {};
    const existingArktavern: Object | undefined = extensions['arktavern'];
    if (existingArktavern !== undefined && existingArktavern !== null
      && typeof existingArktavern === 'object' && !Array.isArray(existingArktavern)) {
      arktavernExt = existingArktavern as Record<string, Object>;
    }
    const aiGeneration: AiGenerationMeta = {
      providerId: meta.providerId,
      modelId: meta.modelId,
      generatedAt: meta.generatedAt,
      generationVersion: AI_GENERATION_VERSION
    };
    arktavernExt['ai_generation'] = aiGeneration;
    extensions['arktavern'] = arktavernExt;
  }

  const card: ParsedCharacterCard = {
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMes,
    systemPrompt: systemPrompt,
    avatarUri: '',
    sourceFormat: 'chara_card_v2',
    mesExample: mesExample,
    creatorNotes: creatorNotes,
    postHistoryInstructions: postHistory,
    alternateGreetings: alternateGreetings,
    tags: tags,
    creator: creator.length === 0 ? AI_DEFAULT_CREATOR : creator,
    characterVersion: characterVersion.length === 0 ? AI_DEFAULT_CHARACTER_VERSION : characterVersion,
    extensions: extensions,
    characterBook: characterBook,
    userName: ''
  };

  return { ok: true, card: card, errors: errors };
}

// ===== 内部辅助函数 =====

function fail(errors: AiValidationError[]): V2ValidationResult {
  return { ok: false, card: null, errors: errors };
}

/**
 * 判断角色名称是否为占位符(如 Entry1、Character、未命名、数字编号)。
 * 用于在 AI 生成时拦截无意义的占位名称,触发重新生成。
 */
function isPlaceholderName(name: string): boolean {
  const patterns: RegExp[] = [
    new RegExp('^entry[\\s0-9-_]*$', 'i'),
    new RegExp('^character[\\s0-9-_]*$', 'i'),
    new RegExp('^unnamed[\\s0-9-_]*$', 'i'),
    new RegExp('^placeholder[\\s0-9-_]*$', 'i'),
    new RegExp('^未命名[\\s0-9-_]*$'),
    new RegExp('^未知角色[\\s0-9-_]*$')
  ];
  for (let i = 0; i < patterns.length; i++) {
    if (patterns[i].test(name)) {
      return true;
    }
  }
  return false;
}

function getStringField(obj: Record<string, Object>, key: string, defaultValue: string): string {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'string') {
    return v as string;
  }
  // 数字/布尔强制转字符串(宽容处理)
  if (typeof v === 'number' || typeof v === 'boolean') {
    return String(v);
  }
  return defaultValue;
}

function getLimitedStringField(
  obj: Record<string, Object>,
  key: string,
  errors: AiValidationError[],
  errorField: string
): string {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return '';
  }
  if (typeof v !== 'string') {
    errors.push({
      field: errorField,
      code: 'type_error',
      message: errorField + ' 必须为字符串'
    });
    return '';
  }
  const s: string = v as string;
  if (s.length > MAX_FIELD_LENGTH) {
    errors.push({
      field: errorField,
      code: 'too_large',
      message: errorField + ' 超过最大长度 ' + String(MAX_FIELD_LENGTH) + ' 字符'
    });
    return s.substring(0, MAX_FIELD_LENGTH);
  }
  return s;
}

function getStringArrayField(
  obj: Record<string, Object>,
  key: string,
  errors: AiValidationError[],
  errorField: string
): string[] {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return [];
  }
  if (!Array.isArray(v)) {
    errors.push({
      field: errorField,
      code: 'type_error',
      message: errorField + ' 必须为数组'
    });
    return [];
  }
  const arr: Object[] = v as Object[];
  if (arr.length > MAX_ARRAY_LENGTH) {
    errors.push({
      field: errorField,
      code: 'too_large',
      message: errorField + ' 超过最大长度 ' + String(MAX_ARRAY_LENGTH)
    });
  }
  const result: string[] = [];
  const limit: number = Math.min(arr.length, MAX_ARRAY_LENGTH);
  for (let i: number = 0; i < limit; i++) {
    const item: Object = arr[i];
    if (typeof item === 'string') {
      result.push(item as string);
    } else if (typeof item === 'number' || typeof item === 'boolean') {
      result.push(String(item));
    } else {
      // 非字符串元素跳过(不致命)
    }
  }
  return result;
}

function parseCharacterBook(
  raw: Object | undefined,
  errors: AiValidationError[]
): ParsedCharacterBook | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    errors.push({
      field: 'data.character_book',
      code: 'type_error',
      message: 'character_book 必须为对象'
    });
    return null;
  }
  const book: Record<string, Object> = raw as Record<string, Object>;

  // extensions(可选,必须为对象)
  let bookExtensions: Record<string, Object> = {};
  const extRaw: Object | undefined = book['extensions'];
  if (extRaw !== undefined && extRaw !== null) {
    if (typeof extRaw !== 'object' || Array.isArray(extRaw)) {
      errors.push({
        field: 'data.character_book.extensions',
        code: 'type_error',
        message: 'character_book.extensions 必须为对象'
      });
    } else {
      bookExtensions = extRaw as Record<string, Object>;
    }
  }

  // entries(可选,必须为数组)
  const entriesRaw: Object | undefined = book['entries'];
  if (entriesRaw === undefined || entriesRaw === null) {
    return { entries: [], extensions: bookExtensions };
  }
  if (!Array.isArray(entriesRaw)) {
    errors.push({
      field: 'data.character_book.entries',
      code: 'type_error',
      message: 'character_book.entries 必须为数组'
    });
    return { entries: [], extensions: bookExtensions };
  }
  const entriesArr: Object[] = entriesRaw as Object[];
  if (entriesArr.length > MAX_BOOK_ENTRIES) {
    errors.push({
      field: 'data.character_book.entries',
      code: 'too_large',
      message: 'character_book.entries 超过最大条目数 ' + String(MAX_BOOK_ENTRIES)
    });
  }
  const entries: ParsedCharacterBookEntry[] = [];
  const limit: number = Math.min(entriesArr.length, MAX_BOOK_ENTRIES);
  for (let i: number = 0; i < limit; i++) {
    const entry: ParsedCharacterBookEntry | null = parseBookEntry(entriesArr[i], i);
    if (entry !== null) {
      entries.push(entry);
    }
  }
  return { entries: entries, extensions: bookExtensions };
}

function parseBookEntry(raw: Object | undefined, fallbackId: number): ParsedCharacterBookEntry | null {
  if (raw === undefined || raw === null) {
    return null;
  }
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    return null;
  }
  const e: Record<string, Object> = raw as Record<string, Object>;

  const keys: string[] = readStringArray(e, 'keys');
  const secondaryKeys: string[] = readStringArray(e, 'secondary_keys');
  const content: string = readString(e, 'content', '');
  const enabled: boolean = readBool(e, 'enabled', true);
  const constant: boolean = readBool(e, 'constant', false);
  const selective: boolean = readBool(e, 'selective', false);
  const caseSensitive: boolean = readBool(e, 'case_sensitive', false);
  const position: string = readString(e, 'position', 'before_char');
  const priority: number = readNumber(e, 'priority', 0);
  const insertionOrder: number = readNumber(e, 'insertion_order', 0);
  const name: string = readString(e, 'name', '');
  const comment: string = readString(e, 'comment', '');
  const id: number = readNumber(e, 'id', fallbackId);

  // extensions(可选)
  let entryExtensions: Record<string, Object> = {};
  const extRaw: Object | undefined = e['extensions'];
  if (extRaw !== undefined && extRaw !== null
    && typeof extRaw === 'object' && !Array.isArray(extRaw)) {
    entryExtensions = extRaw as Record<string, Object>;
  }

  return {
    keys: keys,
    secondaryKeys: secondaryKeys,
    content: content,
    enabled: enabled,
    constant: constant,
    selective: selective,
    position: position,
    priority: priority,
    name: name,
    comment: comment,
    insertionOrder: insertionOrder,
    caseSensitive: caseSensitive,
    id: id,
    extensions: entryExtensions
  };
}

function readString(obj: Record<string, Object>, key: string, defaultValue: string): string {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number' || typeof v === 'boolean') {
    return String(v);
  }
  return defaultValue;
}

function readBool(obj: Record<string, Object>, key: string, defaultValue: boolean): boolean {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  if (typeof v === 'number') {
    return (v as number) !== 0;
  }
  if (typeof v === 'string') {
    return (v as string) === 'true' || (v as string) === '1';
  }
  return defaultValue;
}

function readNumber(obj: Record<string, Object>, key: string, defaultValue: number): number {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const n: number = Number(v);
    if (!isNaN(n)) {
      return n;
    }
  }
  if (typeof v === 'boolean') {
    return (v as boolean) ? 1 : 0;
  }
  return defaultValue;
}

function readStringArray(obj: Record<string, Object>, key: string): string[] {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return [];
  }
  if (!Array.isArray(v)) {
    return [];
  }
  const arr: Object[] = v as Object[];
  const result: string[] = [];
  const limit: number = Math.min(arr.length, MAX_ARRAY_LENGTH);
  for (let i: number = 0; i < limit; i++) {
    const item: Object = arr[i];
    if (typeof item === 'string') {
      result.push(item as string);
    } else if (typeof item === 'number' || typeof item === 'boolean') {
      result.push(String(item));
    }
  }
  return result;
}
