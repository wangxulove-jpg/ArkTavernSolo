/**
 * PersonaRepositoryMapper
 *
 * 职责:
 * - Persona 行映射(ResultSet → Persona / Persona → ValuesBucket)
 * - PersonaPosition 整数 ↔ 枚举转换
 * - 数据校验
 *
 * 不负责:
 * - SQL 执行
 * - 事务管理
 * - 业务逻辑
 */

import { relationalStore } from '@kit.ArkData';
import { Persona } from '../models/Persona';
import { PersonaPosition, parsePersonaPosition } from '../models/PersonaPosition';
import { DatabaseError } from '../models/DatabaseError';
import { isValidTimestamp } from './RepositoryMappers';
import {
  COLUMN_PERSONA_ID,
  COLUMN_PERSONA_NAME,
  COLUMN_PERSONA_DESCRIPTION,
  COLUMN_PERSONA_AVATAR_URI,
  COLUMN_PERSONA_POSITION,
  COLUMN_PERSONA_DEPTH,
  COLUMN_PERSONA_CREATED_AT,
  COLUMN_PERSONA_UPDATED_AT
} from '../database/DatabaseConstants';

/**
 * 从 ResultSet 行构建 Persona
 */
export function personaFromRow(
  rs: relationalStore.ResultSet
): Persona {
  const id: string = rs.getString(rs.getColumnIndex(COLUMN_PERSONA_ID));
  if (id.length === 0) {
    throw DatabaseError.invalidData('persona id is empty');
  }
  const name: string = rs.getString(rs.getColumnIndex(COLUMN_PERSONA_NAME));
  if (name.length === 0) {
    throw DatabaseError.invalidData('persona name is empty');
  }
  const description: string = rs.getString(rs.getColumnIndex(COLUMN_PERSONA_DESCRIPTION));
  const avatarUri: string = rs.getString(rs.getColumnIndex(COLUMN_PERSONA_AVATAR_URI));
  const positionInt: number = rs.getLong(rs.getColumnIndex(COLUMN_PERSONA_POSITION));
  const position: PersonaPosition = parsePersonaPosition(positionInt);
  const depth: number = rs.getLong(rs.getColumnIndex(COLUMN_PERSONA_DEPTH));
  const createdAt: number = rs.getLong(rs.getColumnIndex(COLUMN_PERSONA_CREATED_AT));
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('persona createdAt invalid');
  }
  const updatedAt: number = rs.getLong(rs.getColumnIndex(COLUMN_PERSONA_UPDATED_AT));
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('persona updatedAt invalid');
  }
  return {
    id: id,
    name: name,
    description: description,
    avatarUri: avatarUri,
    position: position,
    depth: depth,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 将 Persona 转为 ValuesBucket
 */
export function personaToBucket(
  persona: Persona
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_PERSONA_ID] = persona.id;
  bucket[COLUMN_PERSONA_NAME] = persona.name;
  bucket[COLUMN_PERSONA_DESCRIPTION] = persona.description;
  bucket[COLUMN_PERSONA_AVATAR_URI] = persona.avatarUri;
  bucket[COLUMN_PERSONA_POSITION] = persona.position;
  bucket[COLUMN_PERSONA_DEPTH] = persona.depth;
  bucket[COLUMN_PERSONA_CREATED_AT] = persona.createdAt;
  bucket[COLUMN_PERSONA_UPDATED_AT] = persona.updatedAt;
  return bucket;
}

/**
 * 校验 Persona(Repository 级别)
 */
export function validatePersona(persona: Persona): void {
  if (persona.id.length === 0) {
    throw DatabaseError.invalidData('persona id is empty');
  }
  if (persona.name.length === 0) {
    throw DatabaseError.invalidData('persona name is empty');
  }
  if (!isValidTimestamp(persona.createdAt)) {
    throw DatabaseError.invalidData('persona createdAt invalid');
  }
  if (!isValidTimestamp(persona.updatedAt)) {
    throw DatabaseError.invalidData('persona updatedAt invalid');
  }
}
