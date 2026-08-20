/**
 * ConversationBranch 对话分支模型(T-6.4A)
 *
 * 为"从任意历史位置重新开始对话"提供数据底座。
 * 一个 Chat 可以拥有多个 Branch,每个 Branch 维护独立的:
 * - 消息路径(BranchMessageLink)
 * - Swipe Candidate 选择(BranchSwipeSelection)
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不依赖 RDB
 * - 不依赖 ChatService
 * - 不修改输入对象
 * - 使用 UUID
 * - position 和 candidateIndex 为非负整数
 * - 时间字段为有限非负整数
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

/**
 * 对话分支。
 */
export interface ConversationBranch {
  /** 分支唯一标识 */
  readonly id: string;
  /** 所属 Chat ID */
  readonly chatId: string;
  /** 父分支 ID(Root Branch 为 undefined) */
  readonly parentBranchId?: string;
  /** 从哪条 Message 创建(Root Branch 为 undefined) */
  readonly forkMessageId?: string;
  /** 分支名称 */
  readonly name: string;
  /** 是否为 Root Branch */
  readonly isRoot: boolean;
  /** 创建时间(毫秒时间戳) */
  readonly createdAt: number;
  /** 更新时间(毫秒时间戳) */
  readonly updatedAt: number;
  /** 最后消息时间(毫秒时间戳) */
  readonly lastMessageAt: number;
}

/**
 * Branch 与 Message 的关联(不保存正文)。
 */
export interface BranchMessageLink {
  /** 所属 Branch ID */
  readonly branchId: string;
  /** Message ID(对应 messages 表主键) */
  readonly messageId: string;
  /** 在 Branch 中的位置(从 0 连续增长) */
  readonly position: number;
  /** 创建时间(毫秒时间戳) */
  readonly createdAt: number;
}

/**
 * Branch 对 Assistant Message 的 Swipe Candidate 选择。
 */
export interface BranchSwipeSelection {
  /** 所属 Branch ID */
  readonly branchId: string;
  /** Assistant Message ID */
  readonly assistantMessageId: string;
  /** 选中的 Candidate 索引(非负整数) */
  readonly candidateIndex: number;
  /** 更新时间(毫秒时间戳) */
  readonly updatedAt: number;
}

/**
 * Branch 摘要(列表展示用)。
 */
export interface ConversationBranchSummary {
  readonly id: string;
  readonly parentBranchId?: string;
  readonly forkMessageId?: string;
  readonly name: string;
  readonly isRoot: boolean;
  readonly messageCount: number;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly lastMessageAt: number;
  readonly isActive: boolean;
}

/**
 * Chat 的记录数量统计。
 */
export interface ConversationRecordCounts {
  /** 当前 Branch 实际显示的消息数 */
  readonly currentBranchMessageCount: number;
  /** 该 Chat 在所有 Branch 中保存的唯一 Message 数 */
  readonly totalUniqueMessageCount: number;
  /** 该 Chat 中保存的 Candidate 总数 */
  readonly totalSwipeCandidateCount: number;
  /** 该 Chat 的 Branch 总数 */
  readonly totalBranchCount: number;
}

/**
 * 创建 Root Branch。
 */
export function createRootBranch(
  chatId: string,
  now: number = nowMillis()
): ConversationBranch {
  if (chatId.length === 0) {
    throw new Error('createRootBranch: chatId empty');
  }
  if (!Number.isFinite(now) || now < 0) {
    throw new Error('createRootBranch: invalid timestamp');
  }
  return {
    id: generateUuid(),
    chatId: chatId,
    parentBranchId: undefined,
    forkMessageId: undefined,
    name: '',
    isRoot: true,
    createdAt: now,
    updatedAt: now,
    lastMessageAt: now
  };
}

/**
 * 创建 Child Branch。
 */
export function createChildBranch(
  chatId: string,
  parentBranchId: string,
  forkMessageId: string,
  name: string,
  now: number = nowMillis()
): ConversationBranch {
  if (chatId.length === 0) {
    throw new Error('createChildBranch: chatId empty');
  }
  if (parentBranchId.length === 0) {
    throw new Error('createChildBranch: parentBranchId empty');
  }
  if (forkMessageId.length === 0) {
    throw new Error('createChildBranch: forkMessageId empty');
  }
  if (!Number.isFinite(now) || now < 0) {
    throw new Error('createChildBranch: invalid timestamp');
  }
  return {
    id: generateUuid(),
    chatId: chatId,
    parentBranchId: parentBranchId,
    forkMessageId: forkMessageId,
    name: name,
    isRoot: false,
    createdAt: now,
    updatedAt: now,
    lastMessageAt: now
  };
}

/**
 * 创建 BranchMessageLink。
 */
export function createBranchMessageLink(
  branchId: string,
  messageId: string,
  position: number,
  now: number = nowMillis()
): BranchMessageLink {
  if (branchId.length === 0) {
    throw new Error('createBranchMessageLink: branchId empty');
  }
  if (messageId.length === 0) {
    throw new Error('createBranchMessageLink: messageId empty');
  }
  if (!Number.isInteger(position) || position < 0) {
    throw new Error('createBranchMessageLink: invalid position');
  }
  if (!Number.isFinite(now) || now < 0) {
    throw new Error('createBranchMessageLink: invalid timestamp');
  }
  return {
    branchId: branchId,
    messageId: messageId,
    position: position,
    createdAt: now
  };
}

/**
 * 创建 BranchSwipeSelection。
 */
export function createBranchSwipeSelection(
  branchId: string,
  assistantMessageId: string,
  candidateIndex: number,
  now: number = nowMillis()
): BranchSwipeSelection {
  if (branchId.length === 0) {
    throw new Error('createBranchSwipeSelection: branchId empty');
  }
  if (assistantMessageId.length === 0) {
    throw new Error('createBranchSwipeSelection: assistantMessageId empty');
  }
  if (!Number.isInteger(candidateIndex) || candidateIndex < 0) {
    throw new Error('createBranchSwipeSelection: invalid candidateIndex');
  }
  if (!Number.isFinite(now) || now < 0) {
    throw new Error('createBranchSwipeSelection: invalid timestamp');
  }
  return {
    branchId: branchId,
    assistantMessageId: assistantMessageId,
    candidateIndex: candidateIndex,
    updatedAt: now
  };
}

/**
 * 更新 Branch 的 updatedAt 和 lastMessageAt(不可变更新)。
 */
export function touchBranch(
  branch: ConversationBranch,
  now: number = nowMillis()
): ConversationBranch {
  if (!Number.isFinite(now) || now < 0) {
    throw new Error('touchBranch: invalid timestamp');
  }
  return {
    id: branch.id,
    chatId: branch.chatId,
    parentBranchId: branch.parentBranchId,
    forkMessageId: branch.forkMessageId,
    name: branch.name,
    isRoot: branch.isRoot,
    createdAt: branch.createdAt,
    updatedAt: now,
    lastMessageAt: now
  };
}

/**
 * 校验 position 是否合法。
 */
export function isValidPosition(position: number): boolean {
  return Number.isInteger(position) && position >= 0;
}

/**
 * 校验 candidateIndex 是否合法。
 */
export function isValidCandidateIndex(index: number): boolean {
  return Number.isInteger(index) && index >= 0;
}
