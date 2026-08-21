/**
 * Persona 用户身份数据模型
 *
 * 定义用户身份的数据结构、校验规则和不可变更新。
 * 不依赖 ArkUI,可用于服务层和持久化层。
 *
 * 约束:
 * - name 必填,最长 100 字符
 * - description 最长 5000 字符
 * - id 使用 'ps-' 前缀 + UUID
 */

import { generateUuid } from '../utils/Uuid';
import { PersonaPosition } from './PersonaPosition';

/**
 * 用户身份模型。
 */
export interface Persona {
  /** 唯一标识('ps-' + UUID) */
  readonly id: string;
  /** 名称(必填,最长 100 字符,替换 {{user}}) */
  readonly name: string;
  /** 描述(最长 5000 字符) */
  readonly description: string;
  /** 头像 URI */
  readonly avatarUri: string;
  /** 注入位置 */
  readonly position: PersonaPosition;
  /** AtDepth 时插入深度(默认 4) */
  readonly depth: number;
  /** 创建时间戳(毫秒) */
  readonly createdAt: number;
  /** 更新时间戳(毫秒) */
  readonly updatedAt: number;
}

const MAX_NAME_LENGTH: number = 100;
const MAX_DESCRIPTION_LENGTH: number = 5000;
const DEFAULT_DEPTH: number = 4;
const ID_PREFIX: string = 'ps-';

/**
 * 创建新 Persona,自动填充 id 和时间戳。
 */
export function createPersona(
  name: string,
  description: string = '',
  avatarUri: string = '',
  position: PersonaPosition = PersonaPosition.BeforeCharacter,
  depth: number = DEFAULT_DEPTH
): Persona {
  const now: number = Date.now();
  return {
    id: ID_PREFIX + generateUuid(),
    name: name.trim(),
    description: description.trim(),
    avatarUri: avatarUri.trim(),
    position: position,
    depth: depth > 0 ? depth : DEFAULT_DEPTH,
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 校验 Persona 数据。
 * @returns 错误信息字符串,如果校验通过返回 null
 */
export function validatePersona(persona: Persona): string | null {
  if (persona.name.trim().length === 0) {
    return '身份名称不能为空';
  }
  if (persona.name.length > MAX_NAME_LENGTH) {
    return '身份名称不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (persona.description.length > MAX_DESCRIPTION_LENGTH) {
    return '身份描述不能超过' + MAX_DESCRIPTION_LENGTH + '个字符';
  }
  return null;
}

/**
 * Persona 更新字段。
 */
export interface PersonaUpdates {
  name?: string;
  description?: string;
  avatarUri?: string;
  position?: PersonaPosition;
  depth?: number;
}

/**
 * 不可变更新 Persona 字段。
 * 返回新 Persona 对象,不修改原对象。
 */
export function updatePersona(
  persona: Persona,
  updates: PersonaUpdates
): Persona {
  const depth: number = updates.depth !== undefined
    ? (updates.depth > 0 ? updates.depth : DEFAULT_DEPTH)
    : persona.depth;
  return {
    id: persona.id,
    name: updates.name !== undefined ? updates.name.trim() : persona.name,
    description: updates.description !== undefined ? updates.description.trim() : persona.description,
    avatarUri: updates.avatarUri !== undefined ? updates.avatarUri.trim() : persona.avatarUri,
    position: updates.position !== undefined ? updates.position : persona.position,
    depth: depth,
    createdAt: persona.createdAt,
    updatedAt: Date.now()
  };
}
