/**
 * CharacterCardJsonParser 角色卡 JSON 解析器
 *
 * 解析多种角色卡格式:
 * - ArkTavern schemaVersion=1(camelCase, character 包装)
 * - SillyTavern V1(扁平 snake_case,无 spec)
 * - SillyTavern V2/V3(chara_card_v2 / chara_card_v3,data 包装,snake_case)
 *
 * 返回统一的 ParsedCharacterCard 中间格式,由 CharacterService 转换为内部 Character 模型。
 * 兼容 Tavern Card V1/V2/V3,保留未知 extensions 字段。
 *
 * 约束:
 * - 不依赖 ArkUI
 * - 不依赖网络/存储/数据库
 * - 纯逻辑解析,可本地单元测试
 * - 不抛出原始 JSON 解析异常,返回明确错误类型
 */

/** 解析后的角色卡世界书条目 */
export interface ParsedCharacterBookEntry {
  /** 关键词列表 */
  keys: string[];
  /** 次关键词列表 */
  secondaryKeys: string[];
  /** 条目内容 */
  content: string;
  /** 是否启用 */
  enabled: boolean;
  /** 是否为常驻条目 */
  constant: boolean;
  /** 是否选择触发 */
  selective: boolean;
  /** 位置标识(before_char / after_char) */
  position: string;
  /** 优先级 */
  priority: number;
  /** 名称(可选) */
  name: string;
  /** 备注(可选) */
  comment: string;
  /** 插入顺序 */
  insertionOrder: number;
  /** 是否大小写敏感 */
  caseSensitive: boolean;
  /** 原始 ID */
  id: number;
  /** 未知扩展字段 */
  extensions: Record<string, Object>;
}

/** 解析后的角色卡世界书 */
export interface ParsedCharacterBook {
  /** 条目列表 */
  entries: ParsedCharacterBookEntry[];
  /** 未知扩展字段 */
  extensions: Record<string, Object>;
}

/** 解析后的角色卡中间格式 */
export interface ParsedCharacterCard {
  /** 角色名称(必填) */
  name: string;
  /** 角色描述 */
  description: string;
  /** 性格描述 */
  personality: string;
  /** 场景/世界观 */
  scenario: string;
  /** 开场白 */
  firstMessage: string;
  /** 系统提示词 */
  systemPrompt: string;
  /** 头像 URI(通常来自 PNG 文件,JSON 导入时为空) */
  avatarUri: string;
  /** 来源格式标识 */
  sourceFormat: string;
  /** ===== Tavern Card V2 扩展字段 ===== */
  /** 对话示例 */
  mesExample: string;
  /** 创作者备注(元数据) */
  creatorNotes: string;
  /** Post-History Instructions */
  postHistoryInstructions: string;
  /** 备用开场白列表 */
  alternateGreetings: string[];
  /** 标签列表(元数据) */
  tags: string[];
  /** 创作者名(元数据) */
  creator: string;
  /** 角色卡版本(元数据) */
  characterVersion: string;
  /** 未知扩展字段(原样保存) */
  extensions: Record<string, Object>;
  /** 角色专属世界书(可能为 null) */
  characterBook: ParsedCharacterBook | null;
  /**
   * 角色对用户的称呼(v9 引入)。
   * 仅从 ArkTavern 扩展 extensions.arktavern.user_name_override 读取,
   * 不主动读取 V2 spec 的 data.user_name(避免覆盖用户已有角色卡数据)。
   * 留空时由 ChatService 按优先级回退到全局用户称呼。
   */
  userName: string;
}

/** 解析结果:成功或失败 */
export class ParseResult {
  readonly success: boolean;
  readonly card: ParsedCharacterCard | null;
  readonly error: string | null;

  private constructor(success: boolean, card: ParsedCharacterCard | null, error: string | null) {
    this.success = success;
    this.card = card;
    this.error = error;
  }

  static ok(card: ParsedCharacterCard): ParseResult {
    return new ParseResult(true, card, null);
  }

  static fail(error: string): ParseResult {
    return new ParseResult(false, null, error);
  }
}

/** 最大文件大小:10MB */
const MAX_FILE_SIZE_BYTES: number = 10 * 1024 * 1024;

/** 字段最大长度:5000 字符(与 Character 模型一致) */
const MAX_FIELD_LENGTH: number = 5000;

/** 备用开场白最大数量 */
const MAX_ALTERNATE_GREETINGS: number = 20;

/** 标签最大数量 */
const MAX_TAGS: number = 30;

/**
 * 解析角色卡 JSON 字符串。
 * 自动识别:
 * - ArkTavern schemaVersion=1
 * - SillyTavern V1(无 spec,扁平结构)
 * - SillyTavern V2/V3(spec=chara_card_v2 或 chara_card_v3)
 *
 * @param jsonString 原始 JSON 字符串
 * @returns ParseResult 包含解析结果或错误信息
 */
export function parseCharacterJson(jsonString: string): ParseResult {
  if (jsonString.length > MAX_FILE_SIZE_BYTES) {
    return ParseResult.fail('文件过大,不能超过 10MB');
  }

  let root: Object;
  try {
    root = JSON.parse(jsonString) as Object;
  } catch (e) {
    return ParseResult.fail('文件格式无效,无法解析 JSON');
  }

  if (typeof root !== 'object' || root === null) {
    return ParseResult.fail('JSON 顶层必须是对象');
  }

  const rootObj: Record<string, Object> = root as Record<string, Object>;

  if (typeof rootObj['schemaVersion'] === 'number') {
    return parseArkTavernFormat(rootObj);
  }

  if (typeof rootObj['spec'] === 'string') {
    const spec: string = rootObj['spec'] as string;
    if (spec === 'chara_card_v2' || spec === 'chara_card_v3') {
      return parseCharaCardFormat(rootObj, spec);
    }
    return ParseResult.fail('不支持的角色卡版本: ' + spec);
  }

  // 无 spec 和 schemaVersion,尝试按 SillyTavern V1 扁平格式解析
  return parseV1FlatFormat(rootObj);
}

/**
 * 从 extensions 字段中提取 ArkTavern 自定义 user_name_override 字段。
 *
 * 路径:extensions.arktavern.user_name_override
 * - extensions 不存在 / 非对象 → 空字符串
 * - arktavern 不存在 / 非对象 → 空字符串
 * - user_name_override 不是字符串 → 空字符串
 *
 * 不会读取 V2 spec 的 data.user_name,避免覆盖用户已有角色卡数据。
 * 留空时由 ChatService 按优先级回退到全局用户称呼。
 */
function extractArkTavernUserName(extensions: Record<string, Object>): string {
  const arktavern: Object | undefined = extensions['arktavern'];
  if (typeof arktavern !== 'object' || arktavern === null || Array.isArray(arktavern)) {
    return '';
  }
  const arktavernObj: Record<string, Object> = arktavern as Record<string, Object>;
  const userName: Object | undefined = arktavernObj['user_name_override'];
  if (typeof userName !== 'string') {
    return '';
  }
  return truncateField((userName as string).trim(), MAX_FIELD_LENGTH);
}

/**
 * 解析 ArkTavern schemaVersion=1 格式(camelCase, character 包装)。
 */
function parseArkTavernFormat(root: Record<string, Object>): ParseResult {
  const schemaVersion: number = root['schemaVersion'] as number;
  if (schemaVersion !== 1) {
    return ParseResult.fail('不支持的 ArkTavern schemaVersion: ' + String(schemaVersion));
  }

  const character: Object | undefined = root['character'] as Object | undefined;
  if (typeof character !== 'object' || character === null) {
    return ParseResult.fail('缺少 character 字段');
  }
  const charObj: Record<string, Object> = character as Record<string, Object>;

  const rawName: string = getStringField(charObj, 'name');
  if (rawName.trim().length === 0) {
    return ParseResult.fail('角色缺少名称(name),无法导入');
  }

  const extensions: Record<string, Object> = getObjectField(charObj, 'extensions');
  return ParseResult.ok({
    name: truncateField(rawName.trim(), MAX_FIELD_LENGTH),
    description: truncateField(getStringField(charObj, 'description'), MAX_FIELD_LENGTH),
    personality: truncateField(getStringField(charObj, 'personality'), MAX_FIELD_LENGTH),
    scenario: truncateField(getStringField(charObj, 'scenario'), MAX_FIELD_LENGTH),
    firstMessage: truncateField(getStringField(charObj, 'firstMessage'), MAX_FIELD_LENGTH),
    systemPrompt: truncateField(getStringField(charObj, 'systemPrompt'), MAX_FIELD_LENGTH),
    avatarUri: truncateField(getStringField(charObj, 'avatarUri'), MAX_FIELD_LENGTH),
    sourceFormat: 'arktavern_v1',
    mesExample: truncateField(getStringField(charObj, 'mesExample'), MAX_FIELD_LENGTH),
    creatorNotes: truncateField(getStringField(charObj, 'creatorNotes'), MAX_FIELD_LENGTH),
    postHistoryInstructions: truncateField(getStringField(charObj, 'postHistoryInstructions'), MAX_FIELD_LENGTH),
    alternateGreetings: truncateStringArray(getStringArrayField(charObj, 'alternateGreetings'), MAX_ALTERNATE_GREETINGS),
    tags: truncateStringArray(getStringArrayField(charObj, 'tags'), MAX_TAGS),
    creator: truncateField(getStringField(charObj, 'creator'), MAX_FIELD_LENGTH),
    characterVersion: truncateField(getStringField(charObj, 'characterVersion'), MAX_FIELD_LENGTH),
    extensions: extensions,
    characterBook: null,
    userName: extractArkTavernUserName(extensions)
  });
}

/**
 * 解析 SillyTavern V1 扁平格式(无 spec,无 schemaVersion)。
 * V1 仅支持基础字段,V2 字段使用默认空值。
 */
function parseV1FlatFormat(root: Record<string, Object>): ParseResult {
  // 必须包含 name 字段才视为 V1 格式
  const rawName: string = getStringField(root, 'name');
  if (rawName.trim().length === 0) {
    return ParseResult.fail('无法识别的角色卡格式,缺少 schemaVersion/spec/name 字段');
  }

  return ParseResult.ok({
    name: truncateField(rawName.trim(), MAX_FIELD_LENGTH),
    description: truncateField(getStringField(root, 'description'), MAX_FIELD_LENGTH),
    personality: truncateField(getStringField(root, 'personality'), MAX_FIELD_LENGTH),
    scenario: truncateField(getStringField(root, 'scenario'), MAX_FIELD_LENGTH),
    firstMessage: truncateField(getStringField(root, 'first_mes'), MAX_FIELD_LENGTH),
    systemPrompt: '',
    avatarUri: '',
    sourceFormat: 'chara_card_v1',
    mesExample: truncateField(getStringField(root, 'mes_example'), MAX_FIELD_LENGTH),
    creatorNotes: '',
    postHistoryInstructions: '',
    alternateGreetings: [],
    tags: truncateStringArray(getStringArrayField(root, 'tags'), MAX_TAGS),
    creator: '',
    characterVersion: '',
    extensions: {},
    characterBook: null,
    userName: ''
  });
}

/**
 * 解析 V2/V3 chara_card 格式。
 * V2 和 V3 的数据结构相同,仅 spec 和 spec_version 不同。
 */
function parseCharaCardFormat(root: Record<string, Object>, spec: string): ParseResult {
  const data: Object | undefined = root['data'] as Object | undefined;
  if (typeof data !== 'object' || data === null) {
    return ParseResult.fail('缺少 data 字段');
  }
  const dataObj: Record<string, Object> = data as Record<string, Object>;

  const rawName: string = getStringField(dataObj, 'name');
  if (rawName.trim().length === 0) {
    return ParseResult.fail('角色缺少名称(name),无法导入');
  }

  // 解析 character_book
  const characterBook: ParsedCharacterBook | null = parseCharacterBook(dataObj['character_book']);

  // 解析 extensions(可能含 arktavern.user_name_override,但不读 V2 spec 的 data.user_name)
  const extensions: Record<string, Object> = getObjectField(dataObj, 'extensions');

  return ParseResult.ok({
    name: truncateField(rawName.trim(), MAX_FIELD_LENGTH),
    description: truncateField(getStringField(dataObj, 'description'), MAX_FIELD_LENGTH),
    personality: truncateField(getStringField(dataObj, 'personality'), MAX_FIELD_LENGTH),
    scenario: truncateField(getStringField(dataObj, 'scenario'), MAX_FIELD_LENGTH),
    firstMessage: truncateField(getStringField(dataObj, 'first_mes'), MAX_FIELD_LENGTH),
    systemPrompt: truncateField(getStringField(dataObj, 'system_prompt'), MAX_FIELD_LENGTH),
    avatarUri: '',
    sourceFormat: spec,
    mesExample: truncateField(getStringField(dataObj, 'mes_example'), MAX_FIELD_LENGTH),
    creatorNotes: truncateField(getStringField(dataObj, 'creator_notes'), MAX_FIELD_LENGTH),
    postHistoryInstructions: truncateField(getStringField(dataObj, 'post_history_instructions'), MAX_FIELD_LENGTH),
    alternateGreetings: truncateStringArray(getStringArrayField(dataObj, 'alternate_greetings'), MAX_ALTERNATE_GREETINGS),
    tags: truncateStringArray(getStringArrayField(dataObj, 'tags'), MAX_TAGS),
    creator: truncateField(getStringField(dataObj, 'creator'), MAX_FIELD_LENGTH),
    characterVersion: truncateField(getStringField(dataObj, 'character_version'), MAX_FIELD_LENGTH),
    extensions: extensions,
    characterBook: characterBook,
    userName: extractArkTavernUserName(extensions)
  });
}

/**
 * 解析 character_book 字段为 ParsedCharacterBook。
 * 输入为 null/非对象时返回 null。
 */
function parseCharacterBook(raw: Object | undefined): ParsedCharacterBook | null {
  if (typeof raw !== 'object' || raw === null) {
    return null;
  }
  const bookObj: Record<string, Object> = raw as Record<string, Object>;
  const rawEntries: Object | undefined = bookObj['entries'];
  if (typeof rawEntries !== 'object' || rawEntries === null) {
    return { entries: [], extensions: getObjectField(bookObj, 'extensions') };
  }

  // entries 可能是数组或对象(V2 中是对象,key 是数字字符串)
  const entriesList: ParsedCharacterBookEntry[] = [];
  if (Array.isArray(rawEntries)) {
    const arr: Object[] = rawEntries as Object[];
    for (let i = 0; i < arr.length; i++) {
      const entry: ParsedCharacterBookEntry | null = parseBookEntry(arr[i], i);
      if (entry !== null) {
        entriesList.push(entry);
      }
    }
  } else {
    const entriesObj: Record<string, Object> = rawEntries as Record<string, Object>;
    const keys: string[] = Object.keys(entriesObj);
    for (let i = 0; i < keys.length; i++) {
      const entryObj: Object | undefined = entriesObj[keys[i]];
      const numericId: number = Number.parseInt(keys[i], 10);
      const entry: ParsedCharacterBookEntry | null = parseBookEntry(
        entryObj,
        Number.isNaN(numericId) ? i : numericId
      );
      if (entry !== null) {
        entriesList.push(entry);
      }
    }
  }

  return {
    entries: entriesList,
    extensions: getObjectField(bookObj, 'extensions')
  };
}

/**
 * 解析单个 character_book 条目。
 */
function parseBookEntry(raw: Object | undefined, fallbackId: number): ParsedCharacterBookEntry | null {
  if (typeof raw !== 'object' || raw === null) {
    return null;
  }
  const obj: Record<string, Object> = raw as Record<string, Object>;
  const rawId: Object | undefined = obj['id'];
  let entryId: number = fallbackId;
  if (typeof rawId === 'number') {
    entryId = rawId as number;
  } else if (typeof rawId === 'string') {
    const parsed: number = Number.parseInt(rawId as string, 10);
    if (!Number.isNaN(parsed)) {
      entryId = parsed;
    }
  }

  return {
    keys: getStringArrayField(obj, 'keys'),
    secondaryKeys: getStringArrayField(obj, 'secondary_keys'),
    content: truncateField(getStringField(obj, 'content'), MAX_FIELD_LENGTH),
    enabled: getBooleanField(obj, 'enabled', true),
    constant: getBooleanField(obj, 'constant', false),
    selective: getBooleanField(obj, 'selective', false),
    position: getStringField(obj, 'position'),
    priority: getNumberField(obj, 'priority', 0),
    name: truncateField(getStringField(obj, 'name'), MAX_FIELD_LENGTH),
    comment: truncateField(getStringField(obj, 'comment'), MAX_FIELD_LENGTH),
    insertionOrder: getNumberField(obj, 'insertion_order', 0),
    caseSensitive: getBooleanField(obj, 'case_sensitive', false),
    id: entryId,
    extensions: getObjectField(obj, 'extensions')
  };
}

/**
 * 从对象中安全获取字符串字段。
 * 字段不存在或类型错误时返回空字符串。
 */
function getStringField(obj: Record<string, Object>, key: string): string {
  const value: Object | undefined = obj[key];
  if (typeof value === 'string') {
    return value as string;
  }
  return '';
}

/**
 * 从对象中安全获取字符串数组字段。
 */
function getStringArrayField(obj: Record<string, Object>, key: string): string[] {
  const value: Object | undefined = obj[key];
  if (Array.isArray(value)) {
    const arr: Object[] = value as Object[];
    const result: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      const item: Object = arr[i];
      if (typeof item === 'string') {
        result.push(item as string);
      }
    }
    return result;
  }
  return [];
}

/**
 * 从对象中安全获取对象字段(用于 extensions)。
 * 字段不存在或类型错误时返回空对象。
 */
function getObjectField(obj: Record<string, Object>, key: string): Record<string, Object> {
  const value: Object | undefined = obj[key];
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    return value as Record<string, Object>;
  }
  return {};
}

/**
 * 从对象中安全获取 boolean 字段。
 */
function getBooleanField(obj: Record<string, Object>, key: string, defaultValue: boolean): boolean {
  const value: Object | undefined = obj[key];
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  return defaultValue;
}

/**
 * 从对象中安全获取 number 字段。
 */
function getNumberField(obj: Record<string, Object>, key: string, defaultValue: number): number {
  const value: Object | undefined = obj[key];
  if (typeof value === 'number') {
    return value as number;
  }
  return defaultValue;
}

/**
 * 截断过长的字段。
 */
function truncateField(value: string, maxLength: number): string {
  if (value.length <= maxLength) {
    return value;
  }
  return value.substring(0, maxLength);
}

/**
 * 截断过长的字符串数组,限制元素数量。
 */
function truncateStringArray(arr: string[], maxCount: number): string[] {
  const result: string[] = [];
  const limit: number = Math.min(arr.length, maxCount);
  for (let i = 0; i < limit; i++) {
    const trimmed: string = arr[i].trim();
    if (trimmed.length > 0) {
      result.push(truncateField(trimmed, MAX_FIELD_LENGTH));
    }
  }
  return result;
}
