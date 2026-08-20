/**
 * PromptPresetRepositoryMapper
 *
 * 职责:
 * - PromptPreset 行映射(ResultSet → PromptPreset)
 * - PromptPreset → ValuesBucket 转换
 * - 可选数字字段 NULL/undefined 映射
 * - 数据校验
 *
 * 不负责:
 * - SQL 执行
 * - 事务管理
 * - 业务逻辑
 *
 * 安全:
 * - 数据库损坏抛 DatabaseError.InvalidData
 * - 错误信息不包含 systemPrompt、description、name、SQL、ValuesBucket
 */

import { relationalStore } from '@kit.ArkData';
import { PromptPreset } from '../models/PromptPreset';
import { DatabaseError } from '../models/DatabaseError';
import { isValidTimestamp } from './RepositoryMappers';
import {
  COLUMN_PRESET_ID,
  COLUMN_PRESET_NAME,
  COLUMN_PRESET_DESCRIPTION,
  COLUMN_PRESET_SYSTEM_PROMPT,
  COLUMN_PRESET_TEMPERATURE,
  COLUMN_PRESET_TOP_P,
  COLUMN_PRESET_MAX_OUTPUT_TOKENS,
  COLUMN_PRESET_CONTEXT_WINDOW,
  COLUMN_PRESET_CREATED_AT,
  COLUMN_PRESET_UPDATED_AT
} from '../database/DatabaseConstants';

/**
 * 从 ResultSet 当前行读取 PromptPreset。
 * 非法字段抛 InvalidData,不返回半合法对象。
 * 错误信息不含 systemPrompt、description、name。
 */
export function promptPresetFromRow(
  rs: relationalStore.ResultSet
): PromptPreset {
  const ciId: number = rs.getColumnIndex(COLUMN_PRESET_ID);
  const id: string = rs.getString(ciId);
  if (id.length === 0) {
    throw DatabaseError.invalidData('preset id empty');
  }

  const ciName: number = rs.getColumnIndex(COLUMN_PRESET_NAME);
  const name: string = rs.getString(ciName);
  if (name.length === 0) {
    throw DatabaseError.invalidData('preset name empty');
  }

  const ciDesc: number = rs.getColumnIndex(COLUMN_PRESET_DESCRIPTION);
  const description: string = rs.getString(ciDesc);

  const ciSp: number = rs.getColumnIndex(COLUMN_PRESET_SYSTEM_PROMPT);
  const systemPrompt: string = rs.getString(ciSp);

  const ciTemp: number = rs.getColumnIndex(COLUMN_PRESET_TEMPERATURE);
  let temperature: number | undefined = undefined;
  if (!rs.isColumnNull(ciTemp)) {
    const value: number = rs.getDouble(ciTemp);
    if (!Number.isFinite(value)) {
      throw DatabaseError.invalidData('preset temperature invalid');
    }
    temperature = value;
  }

  const ciTopP: number = rs.getColumnIndex(COLUMN_PRESET_TOP_P);
  let topP: number | undefined = undefined;
  if (!rs.isColumnNull(ciTopP)) {
    const value: number = rs.getDouble(ciTopP);
    if (!Number.isFinite(value)) {
      throw DatabaseError.invalidData('preset topP invalid');
    }
    topP = value;
  }

  const ciMaxTokens: number = rs.getColumnIndex(COLUMN_PRESET_MAX_OUTPUT_TOKENS);
  let maxOutputTokens: number | undefined = undefined;
  if (!rs.isColumnNull(ciMaxTokens)) {
    const value: number = rs.getLong(ciMaxTokens);
    if (!Number.isInteger(value) || value <= 0) {
      throw DatabaseError.invalidData('preset maxOutputTokens invalid');
    }
    maxOutputTokens = value;
  }

  const ciCw: number = rs.getColumnIndex(COLUMN_PRESET_CONTEXT_WINDOW);
  let contextWindow: number | undefined = undefined;
  if (!rs.isColumnNull(ciCw)) {
    const value: number = rs.getLong(ciCw);
    if (!Number.isInteger(value) || value <= 0) {
      throw DatabaseError.invalidData('preset contextWindow invalid');
    }
    contextWindow = value;
  }

  const ciCa: number = rs.getColumnIndex(COLUMN_PRESET_CREATED_AT);
  const createdAt: number = rs.getLong(ciCa);
  if (!isValidTimestamp(createdAt)) {
    throw DatabaseError.invalidData('preset createdAt invalid');
  }

  const ciUa: number = rs.getColumnIndex(COLUMN_PRESET_UPDATED_AT);
  const updatedAt: number = rs.getLong(ciUa);
  if (!isValidTimestamp(updatedAt)) {
    throw DatabaseError.invalidData('preset updatedAt invalid');
  }

  return {
    id: id,
    name: name,
    description: description,
    systemPrompt: systemPrompt,
    temperature: temperature,
    topP: topP,
    maxOutputTokens: maxOutputTokens,
    contextWindow: contextWindow,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

/**
 * 将 PromptPreset 转换为 ValuesBucket。
 * 不修改输入对象。
 * 可选数字字段 undefined 写为 null。
 *
 * @param preset PromptPreset 实例
 * @returns ValuesBucket
 */
export function buildPromptPresetValues(
  preset: PromptPreset
): relationalStore.ValuesBucket {
  const bucket: relationalStore.ValuesBucket = {};
  bucket[COLUMN_PRESET_ID] = preset.id;
  bucket[COLUMN_PRESET_NAME] = preset.name;
  bucket[COLUMN_PRESET_DESCRIPTION] = preset.description;
  bucket[COLUMN_PRESET_SYSTEM_PROMPT] = preset.systemPrompt;
  bucket[COLUMN_PRESET_TEMPERATURE] = preset.temperature !== undefined
    ? preset.temperature
    : null;
  bucket[COLUMN_PRESET_TOP_P] = preset.topP !== undefined
    ? preset.topP
    : null;
  bucket[COLUMN_PRESET_MAX_OUTPUT_TOKENS] = preset.maxOutputTokens !== undefined
    ? preset.maxOutputTokens
    : null;
  bucket[COLUMN_PRESET_CONTEXT_WINDOW] = preset.contextWindow !== undefined
    ? preset.contextWindow
    : null;
  bucket[COLUMN_PRESET_CREATED_AT] = preset.createdAt;
  bucket[COLUMN_PRESET_UPDATED_AT] = preset.updatedAt;
  return bucket;
}