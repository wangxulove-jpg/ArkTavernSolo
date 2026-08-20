/**
 * MessageSwipe 领域模型
 *
 * 定义 Assistant 消息的多候选回复(Swipe)数据结构。
 * 不依赖 ArkUI、RDB、页面。
 *
 * 核心语义:
 * - 每条 Assistant 消息最多一个 MessageSwipeGroup
 * - Group 跟踪当前激活的 Candidate 索引
 * - Candidate 是 Assistant 回复的副本,支持多个候选
 * - 激活候选时,候选内容物化到 messages 表
 * - 旧消息懒创建 Candidate 0
 */

import { ChatMessageStatus } from './ChatMessage';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

// ===== 常量 =====

/** 单条消息的最大候选数量(含 Candidate 0) */
export const MAX_SWIPE_CANDIDATES: number = 8;

// ===== 领域模型 =====

export interface MessageSwipeGroup {
  readonly assistantMessageId: string;
  readonly chatId: string;
  readonly activeCandidateIndex: number;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface MessageSwipeCandidate {
  readonly id: string;
  readonly assistantMessageId: string;
  readonly candidateIndex: number;
  readonly content: string;
  readonly status: ChatMessageStatus;
  readonly errorMessage?: string;
  readonly isStreaming: boolean;
  readonly createdAt: number;
  readonly updatedAt?: number;
}

export interface MessageSwipeState {
  readonly group: MessageSwipeGroup;
  readonly candidates: MessageSwipeCandidate[];
}

/**
 * Swipe UI 摘要模型。
 * 页面只使用此摘要,不持有全部 Candidate content。
 */
export interface MessageSwipeSummary {
  readonly assistantMessageId: string;
  readonly activeCandidateIndex: number;
  readonly candidateCount: number;
  readonly isGeneratingCandidate: boolean;
}

// ===== 创建/更新参数 =====

export interface CreateSwipeCandidateOptions {
  readonly id?: string;
  readonly content?: string;
  readonly status?: ChatMessageStatus;
  readonly errorMessage?: string;
  readonly isStreaming?: boolean;
  readonly createdAt?: number;
}

export interface MessageSwipeCandidateUpdates {
  readonly content?: string;
  readonly status?: ChatMessageStatus;
  readonly errorMessage?: string | undefined;
  readonly isStreaming?: boolean;
}

// ===== 校验 =====

/**
 * 校验 candidateIndex 是否合法。
 * 必须为非负整数。
 */
export function isValidCandidateIndex(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

/**
 * 校验时间戳。
 * 必须为有限非负整数。
 */
export function isValidSwipeTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

/**
 * 校验候选状态与 isStreaming 的一致性。
 */
export function validateSwipeCandidateStatus(
  status: ChatMessageStatus,
  isStreaming: boolean
): void {
  if (isStreaming && status !== ChatMessageStatus.Streaming) {
    throw new Error('isStreaming=true requires status=Streaming');
  }
  if (!isStreaming && status === ChatMessageStatus.Streaming) {
    throw new Error('status=Streaming requires isStreaming=true');
  }
}

/**
 * 校验候选对象。
 */
export function validateSwipeCandidate(candidate: MessageSwipeCandidate): void {
  if (candidate.assistantMessageId.length === 0) {
    throw new Error('assistantMessageId must not be empty');
  }
  if (!isValidCandidateIndex(candidate.candidateIndex)) {
    throw new Error('candidateIndex must be non-negative integer');
  }
  if (!isValidSwipeTimestamp(candidate.createdAt)) {
    throw new Error('createdAt invalid');
  }
  if (candidate.updatedAt !== undefined && !isValidSwipeTimestamp(candidate.updatedAt)) {
    throw new Error('updatedAt invalid');
  }
  validateSwipeCandidateStatus(candidate.status, candidate.isStreaming);
}

// ===== 纯函数 =====

/**
 * 创建新候选。
 * 不修改输入对象。
 */
export function createSwipeCandidate(
  assistantMessageId: string,
  candidateIndex: number,
  options?: CreateSwipeCandidateOptions
): MessageSwipeCandidate {
  if (!isValidCandidateIndex(candidateIndex)) {
    throw new Error('candidateIndex must be non-negative integer');
  }
  if (assistantMessageId.length === 0) {
    throw new Error('assistantMessageId must not be empty');
  }

  const now: number = nowMillis();
  const status: ChatMessageStatus = options?.status ?? ChatMessageStatus.Completed;
  const isStreaming: boolean = options?.isStreaming ?? false;
  validateSwipeCandidateStatus(status, isStreaming);

  return {
    id: options?.id ?? generateUuid(),
    assistantMessageId: assistantMessageId,
    candidateIndex: candidateIndex,
    content: options?.content ?? '',
    status: status,
    errorMessage: options?.errorMessage,
    isStreaming: isStreaming,
    createdAt: options?.createdAt ?? now,
    updatedAt: undefined
  };
}

/**
 * 更新候选。
 * 不修改输入对象。
 */
export function updateSwipeCandidate(
  candidate: MessageSwipeCandidate,
  updates: MessageSwipeCandidateUpdates
): MessageSwipeCandidate {
  const newStatus: ChatMessageStatus = updates.status ?? candidate.status;
  const newIsStreaming: boolean = updates.isStreaming ?? candidate.isStreaming;
  validateSwipeCandidateStatus(newStatus, newIsStreaming);

  return {
    id: candidate.id,
    assistantMessageId: candidate.assistantMessageId,
    candidateIndex: candidate.candidateIndex,
    content: updates.content ?? candidate.content,
    status: newStatus,
    errorMessage: updates.errorMessage !== undefined ? updates.errorMessage : candidate.errorMessage,
    isStreaming: newIsStreaming,
    createdAt: candidate.createdAt,
    updatedAt: nowMillis()
  };
}