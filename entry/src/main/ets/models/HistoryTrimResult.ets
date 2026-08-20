/**
 * HistoryTrimResult 历史裁剪结果模型
 *
 * 描述 HistoryTrimmer 对请求消息的一次裁剪结果。
 * 用于:
 * - ChatService 更新 lastHistoryTrimResult
 * - 测试验证
 * - 未来 UI 提示(本阶段不暴露给页面)
 *
 * 设计原则:
 * - 纯数据模型,不依赖 ArkUI
 * - 不修改输入数组
 * - 不修改原始消息对象
 * - 字段含义明确,直接可读
 */

import { ChatMessage } from './ChatMessage';

/**
 * 历史裁剪结果。
 */
export interface HistoryTrimResult {
  /** 裁剪后的消息列表(可能是与原数组相同引用,但仍是新数组以避免歧义) */
  readonly messages: ChatMessage[];
  /** 裁剪前估算的输入 Token 数 */
  readonly originalTokenCount: number;
  /** 裁剪后估算的输入 Token 数 */
  readonly finalTokenCount: number;
  /** 被裁剪的消息数量 */
  readonly removedMessageCount: number;
  /** 被裁剪的消息 ID 列表(测试可读;生产 hilog 不输出) */
  readonly removedMessageIds: string[];
  /** 裁剪前是否超出预算 */
  readonly exceedsBudgetBeforeTrim: boolean;
  /** 裁剪后是否仍超出预算 */
  readonly exceedsBudgetAfterTrim: boolean;
}

/**
 * 创建 HistoryTrimResult 工厂。
 * 自动计算 removedMessageCount(若 caller 未提供)。
 */
export function createHistoryTrimResult(
  messages: ChatMessage[],
  originalTokenCount: number,
  finalTokenCount: number,
  removedMessageIds: string[],
  exceedsBudgetBeforeTrim: boolean,
  exceedsBudgetAfterTrim: boolean
): HistoryTrimResult {
  return {
    messages: messages,
    originalTokenCount: originalTokenCount,
    finalTokenCount: finalTokenCount,
    removedMessageCount: removedMessageIds.length,
    removedMessageIds: removedMessageIds,
    exceedsBudgetBeforeTrim: exceedsBudgetBeforeTrim,
    exceedsBudgetAfterTrim: exceedsBudgetAfterTrim
  };
}
