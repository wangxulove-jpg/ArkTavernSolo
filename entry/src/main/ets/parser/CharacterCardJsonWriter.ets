/**
 * CharacterCardJsonWriter 角色卡 JSON 导出器
 *
 * 支持:
 * - ArkTavern schemaVersion=1(camelCase,character 包装)— 向后兼容
 * - SillyTavern chara_card_v2(spec=data 包装,snake_case)— 完整 V2 字段
 *
 * 保留所有 V2 字段和未知 extensions,导入后导出不丢字段。
 * 不包含 API Key、模型配置、聊天记录或本地绝对路径。
 *
 * 约束:
 * - 不依赖 ArkUI
 * - 不依赖网络/存储/数据库
 * - 纯逻辑序列化,可本地单元测试
 */

import { Character } from '../models/Character';

/** ArkTavern 导出格式:角色数据字段(camelCase) */
export interface ArkTavernCharacterData {
  name: string;
  description: string;
  personality: string;
  scenario: string;
  firstMessage: string;
  systemPrompt: string;
  avatarUri: string;
  mesExample: string;
  creatorNotes: string;
  postHistoryInstructions: string;
  alternateGreetings: string[];
  tags: string[];
  creator: string;
  characterVersion: string;
  extensions: Record<string, Object>;
  characterBookId: string;
  createdAt: number;
  updatedAt: number;
}

/** ArkTavern 导出格式(schemaVersion=1,内部使用) */
export interface ArkTavernCharacterCard {
  /** 格式版本,固定为 1 */
  schemaVersion: number;
  /** 角色数据 */
  character: ArkTavernCharacterData;
}

/** V2 chara_card data 字段(snake_case) */
export interface CharaCardV2Data {
  name: string;
  description: string;
  personality: string;
  scenario: string;
  first_mes: string;
  mes_example: string;
  system_prompt: string;
  post_history_instructions: string;
  creator_notes: string;
  alternate_greetings: string[];
  tags: string[];
  creator: string;
  character_version: string;
  extensions: Record<string, Object>;
}

/** V2 chara_card 顶层结构 */
export interface CharaCardV2 {
  spec: string;
  spec_version: string;
  data: CharaCardV2Data;
}

/**
 * 将 Character 序列化为 ArkTavern JSON 字符串(schemaVersion=1)。
 * 包含所有 V2 字段,向后兼容旧版导入器。
 *
 * 不包含 id(导入时重新生成)、API Key、模型配置、聊天记录。
 *
 * @param character 角色数据
 * @returns 格式化 JSON 字符串
 */
export function writeCharacterToJson(character: Character): string {
  const charData: ArkTavernCharacterData = {
    name: character.name,
    description: character.description,
    personality: character.personality,
    scenario: character.scenario,
    firstMessage: character.firstMessage,
    systemPrompt: character.systemPrompt,
    avatarUri: character.avatarUri,
    mesExample: character.mesExample,
    creatorNotes: character.creatorNotes,
    postHistoryInstructions: character.postHistoryInstructions,
    alternateGreetings: character.alternateGreetings,
    tags: character.tags,
    creator: character.creator,
    characterVersion: character.characterVersion,
    extensions: character.extensions,
    characterBookId: character.characterBookId,
    createdAt: character.createdAt,
    updatedAt: character.updatedAt
  };
  const card: ArkTavernCharacterCard = {
    schemaVersion: 1,
    character: charData
  };
  return JSON.stringify(card, null, 2);
}

/**
 * 为导出构建 extensions 字段:
 * - 浅拷贝原 extensions(不修改原对象)
 * - 若 character.userName 非空,写入 extensions.arktavern.user_name_override
 * - 若 character.userName 为空,移除 extensions.arktavern.user_name_override(若有)
 *
 * 不写入 V2/V3 标准字段 data.user_name,遵守需求 10:
 * "导出标准 Tavern Card V2/PNG 时,不把本地称呼写入标准字段;如需保留,写入 extensions.arktavern.user_name_override"。
 */
function buildExportExtensions(character: Character): Record<string, Object> {
  const result: Record<string, Object> = {};
  const sourceKeys: string[] = Object.keys(character.extensions);
  for (let i = 0; i < sourceKeys.length; i++) {
    const key: string = sourceKeys[i];
    result[key] = character.extensions[key];
  }
  if (character.userName.trim().length > 0) {
    const existingArkTavern: Object | undefined = result['arktavern'];
    const arktavern: Record<string, Object> = {};
    if (typeof existingArkTavern === 'object' && existingArkTavern !== null
      && !Array.isArray(existingArkTavern)) {
      const source: Record<string, Object> = existingArkTavern as Record<string, Object>;
      const keys: string[] = Object.keys(source);
      for (let i = 0; i < keys.length; i++) {
        arktavern[keys[i]] = source[keys[i]];
      }
    }
    arktavern['user_name_override'] = character.userName;
    result['arktavern'] = arktavern;
  }
  return result;
}

/**
 * 将 Character 序列化为 SillyTavern V2 chara_card JSON 字符串。
 * 保留所有 V2 字段和未知 extensions,导入后导出不丢字段。
 *
 * 不包含 avatarUri / characterBookId / createdAt / updatedAt
 * (V2 规范未定义这些字段,avatarUri 来自 PNG 文件,
 *  characterBookId 是内部关联 ID)。
 *
 * 本地 user_name 不写入 V2 标准字段 data.user_name,仅写入
 * extensions.arktavern.user_name_override(遵守需求 10)。
 *
 * @param character 角色数据
 * @returns 格式化 JSON 字符串(spec=chara_card_v2)
 */
export function writeCharacterToV2Json(character: Character): string {
  const data: CharaCardV2Data = {
    name: character.name,
    description: character.description,
    personality: character.personality,
    scenario: character.scenario,
    first_mes: character.firstMessage,
    mes_example: character.mesExample,
    system_prompt: character.systemPrompt,
    post_history_instructions: character.postHistoryInstructions,
    creator_notes: character.creatorNotes,
    alternate_greetings: character.alternateGreetings,
    tags: character.tags,
    creator: character.creator,
    character_version: character.characterVersion,
    extensions: buildExportExtensions(character)
  };
  const card: CharaCardV2 = {
    spec: 'chara_card_v2',
    spec_version: '2.0',
    data: data
  };
  return JSON.stringify(card, null, 2);
}

/**
 * 将 Character 序列化为 SillyTavern V3 chara_card JSON 字符串。
 * V3 数据结构与 V2 相同,仅 spec 和 spec_version 不同。
 *
 * @param character 角色数据
 * @returns 格式化 JSON 字符串(spec=chara_card_v3)
 */
export function writeCharacterToV3Json(character: Character): string {
  const data: CharaCardV2Data = {
    name: character.name,
    description: character.description,
    personality: character.personality,
    scenario: character.scenario,
    first_mes: character.firstMessage,
    mes_example: character.mesExample,
    system_prompt: character.systemPrompt,
    post_history_instructions: character.postHistoryInstructions,
    creator_notes: character.creatorNotes,
    alternate_greetings: character.alternateGreetings,
    tags: character.tags,
    creator: character.creator,
    character_version: character.characterVersion,
    extensions: buildExportExtensions(character)
  };
  const card: CharaCardV2 = {
    spec: 'chara_card_v3',
    spec_version: '3.0',
    data: data
  };
  return JSON.stringify(card, null, 2);
}

/** 敏感字段黑名单,导出时不应出现在 JSON 中 */
const SENSITIVE_KEYS: string[] = [
  'apiKey', 'api_key', 'secret', 'authorization',
  'token', 'password', 'key', 'credential'
];

/**
 * 验证导出 JSON 不包含敏感字段。
 * 用于测试验证,确保导出内容安全。
 *
 * @param jsonString 导出 JSON 字符串
 * @returns 包含敏感字段的键名列表,为空表示安全
 */
export function findSensitiveKeys(jsonString: string): string[] {
  const lower: string = jsonString.toLowerCase();
  const found: string[] = [];
  for (let i = 0; i < SENSITIVE_KEYS.length; i++) {
    const key: string = SENSITIVE_KEYS[i];
    // 仅匹配 JSON 键名(用 "key": 模式,区分键名和值)
    const keyWithColon: string = '"' + key.toLowerCase() + '":';
    if (lower.includes(keyWithColon)) {
      found.push(key);
    }
  }
  return found;
}

/**
 * 生成安全的导出文件名。
 * 移除非法字符,限制长度,确保文件系统兼容。
 *
 * @param characterName 角色名称
 * @returns 安全的文件名(不含扩展名)
 */
export function sanitizeFileName(characterName: string): string {
  // 移除或替换文件系统非法字符
  let sanitized: string = characterName.replace(/[<>:"/\\|?*\x00-\x1f]/g, '_');
  // 移除首尾空格和点
  sanitized = sanitized.trim().replace(/^\.+|\.+$/g, '');
  // 限制长度(留出扩展名空间)
  if (sanitized.length > 200) {
    sanitized = sanitized.substring(0, 200);
  }
  // 空名称兜底
  if (sanitized.length === 0) {
    sanitized = 'character';
  }
  return sanitized + '.json';
}
