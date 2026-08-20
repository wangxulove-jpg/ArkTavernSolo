/**
 * AiGenerationResult AI 角色卡生成结果与元数据
 *
 * 表示一次 AI 生成/修复流程的最终结果。
 * 包括校验通过的角色卡中间格式(可能为 null 表示生成失败)、
 * 原始响应文本(供"查看原始响应")、校验错误列表、自动修复次数等。
 *
 * 隐私约束:
 * - 不包含 API Key / Authorization / Header
 * - 不包含完整 ProviderConfig(只保留 providerId 和 modelId 两个标识)
 * - generationVersion 只记录生成流程版本号,不记录完整 prompt
 *
 * 不依赖 ArkUI,不使用 any。
 */

import { ParsedCharacterCard } from '../parser/CharacterCardJsonParser';

/**
 * 生成状态。
 */
export enum AiGenerationStatus {
  /** 成功:生成并通过校验 */
  Success = 'Success',
  /** 失败:生成或自动修复后仍无法通过校验 */
  Failed = 'Failed',
  /** 已取消:用户主动停止 */
  Cancelled = 'Cancelled'
}

/**
 * 生成来源元数据(写入 extensions.arktavern.ai_generation)。
 */
export interface AiGenerationMeta {
  /** Provider ID */
  readonly providerId: string;
  /** 模型名称 */
  readonly modelId: string;
  /** 生成时间戳(ms) */
  readonly generatedAt: number;
  /** 生成流程版本号 */
  readonly generationVersion: string;
}

/**
 * 单次校验错误记录。
 */
export interface AiValidationError {
  /** 错误字段路径(如 "data.name" / "data.alternate_greetings") */
  readonly field: string;
  /** 错误类型(如 "missing" / "type_error" / "too_large") */
  readonly code: string;
  /** 错误描述 */
  readonly message: string;
}

/**
 * AI 生成结果。
 */
export interface AiGenerationResult {
  /** 生成状态 */
  readonly status: AiGenerationStatus;
  /** 校验通过的角色卡(失败或取消时为 null) */
  readonly card: ParsedCharacterCard | null;
  /** 原始模型响应文本(供"查看原始响应") */
  readonly rawResponse: string;
  /** 校验错误列表(空数组表示无错误) */
  readonly errors: AiValidationError[];
  /** 自动修复已执行次数(0 表示未触发自动修复) */
  readonly autoFixAttempts: number;
  /** 是否达到自动修复上限后停止 */
  readonly autoFixExhausted: boolean;
  /** 生成元数据(取消时可为 null) */
  readonly meta: AiGenerationMeta | null;
  /** 错误消息(状态为 Failed 时的用户可见消息,取消时为空) */
  readonly errorMessage: string;
}

/**
 * 创建成功结果。
 */
export function createSuccessResult(
  card: ParsedCharacterCard,
  rawResponse: string,
  autoFixAttempts: number,
  meta: AiGenerationMeta
): AiGenerationResult {
  return {
    status: AiGenerationStatus.Success,
    card: card,
    rawResponse: rawResponse,
    errors: [],
    autoFixAttempts: autoFixAttempts,
    autoFixExhausted: false,
    meta: meta,
    errorMessage: ''
  };
}

/**
 * 创建失败结果。
 */
export function createFailedResult(
  rawResponse: string,
  errors: AiValidationError[],
  autoFixAttempts: number,
  autoFixExhausted: boolean,
  meta: AiGenerationMeta | null,
  errorMessage: string
): AiGenerationResult {
  return {
    status: AiGenerationStatus.Failed,
    card: null,
    rawResponse: rawResponse,
    errors: errors,
    autoFixAttempts: autoFixAttempts,
    autoFixExhausted: autoFixExhausted,
    meta: meta,
    errorMessage: errorMessage
  };
}

/**
 * 创建取消结果。
 */
export function createCancelledResult(rawResponse: string): AiGenerationResult {
  return {
    status: AiGenerationStatus.Cancelled,
    card: null,
    rawResponse: rawResponse,
    errors: [],
    autoFixAttempts: 0,
    autoFixExhausted: false,
    meta: null,
    errorMessage: ''
  };
}

/**
 * 当前生成流程版本号(用于 extensions.arktavern.ai_generation.generationVersion)。
 */
export const AI_GENERATION_VERSION: string = '1.0';

/**
 * 默认创作者标识(用于 AI 生成角色卡)。
 */
export const AI_DEFAULT_CREATOR: string = 'AI Generated';

/**
 * 默认角色卡版本。
 */
export const AI_DEFAULT_CHARACTER_VERSION: string = '1.0';
