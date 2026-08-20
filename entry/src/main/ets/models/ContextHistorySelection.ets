/**
 * ContextHistorySelection 最近原始消息窗口选择结果
 *
 * 表示 PromptBuilder 应该注入的最近原始消息子集。
 * - 由 RecentMessageSelector 根据记忆覆盖范围 + Token 预算动态选择
 * - 旧消息若已被记忆覆盖且不在最近窗口内,不进入此列表(去重)
 * - 保留完整 User+Assistant 轮次,不拆开
 *
 * 设计约束:
 * - recentMessages 已按 position ASC 排序
 * - summarizedRangeEndPosition = -1 表示无有效记忆覆盖
 * - omittedMessageCount 不含被记忆覆盖而去重的消息(那部分由摘要替代)
 */

import { ChatMessage } from './ChatMessage';

/**
 * 最近消息窗口选择结果。
 */
export interface ContextHistorySelection {
  /** 选中的最近原始消息(按 position ASC) */
  readonly recentMessages: ChatMessage[];
  /** 有效记忆覆盖的结束 position(-1 表示无记忆覆盖) */
  readonly summarizedRangeEndPosition: number;
  /** 因 Token 预算不足而省略的消息数(不含记忆去重部分) */
  readonly omittedMessageCount: number;
  /** 选中消息的估算 Token 总数 */
  readonly estimatedTokens: number;
  /** 选择时使用的目标条数(用于诊断) */
  readonly targetCount: number;
  /** 实际选中的消息条数 */
  readonly selectedCount: number;
}

/**
 * 创建空的 ContextHistorySelection。
 */
export function createEmptySelection(): ContextHistorySelection {
  return {
    recentMessages: [],
    summarizedRangeEndPosition: -1,
    omittedMessageCount: 0,
    estimatedTokens: 0,
    targetCount: 0,
    selectedCount: 0
  };
}
