/**
 * TokenBudget 上下文 Token 预算模型
 *
 * 描述一次最终 Prompt 的 Token 预算结果。
 * 用于:
 * - 估算当前 Prompt 占用
 * - 提示上下文窗口是否足够
 * - 为下一阶段 HistoryTrimmer 提供输入
 *
 * 设计原则:
 * - 纯数据模型,不依赖 ArkUI
 * - 不读取 Provider 或 Preferences
 * - 字段含义明确,避免使用含义模糊的 maxTokens
 */

import { ChatMessage } from './ChatMessage';

/**
 * 上下文 Token 预算结果。
 */
export interface TokenBudget {
  /** Provider 声明的上下文窗口大小(总 Token 上限) */
  readonly contextWindow: number;
  /** 预留给模型输出回答的 Token 数 */
  readonly reservedOutputTokens: number;
  /** 可用于输入的 Token 上限(contextWindow - reservedOutputTokens,非负) */
  readonly availableInputTokens: number;
  /** 实际估算的输入 Token 总数 */
  readonly estimatedInputTokens: number;
  /** 剩余可用的输入 Token 数(可为负数,表示超预算) */
  readonly remainingInputTokens: number;
  /** 是否超出输入预算 */
  readonly exceedsBudget: boolean;
}

/**
 * 默认上下文窗口大小(在 ProviderConfig 未提供 contextWindow 时使用)。
 * 集中管理,不允许散落在多个文件中。
 */
export const DEFAULT_CONTEXT_WINDOW: number = 32768;

/**
 * 默认预留给输出的 Token 数(在 ProviderConfig 未提供时使用)。
 * 集中管理。
 */
export const DEFAULT_RESERVED_OUTPUT_TOKENS: number = 2048;

/**
 * 创建 TokenBudget。
 * 自动处理配置值异常:
 * - contextWindow < 0 → 0
 * - reservedOutputTokens < 0 → 0
 * - reservedOutputTokens > contextWindow → availableInputTokens = 0
 * - remainingInputTokens 允许为负
 *
 * @param messages 已构建的最终请求消息列表(用于记录条数信息,可选)
 * @param estimatedInputTokens 估算的输入 Token 总数
 * @param contextWindow 上下文窗口大小
 * @param reservedOutputTokens 预留给输出的 Token 数
 * @returns TokenBudget 实例
 */
export function createTokenBudget(
  estimatedInputTokens: number,
  contextWindow: number,
  reservedOutputTokens: number
): TokenBudget {
  const safeContext: number = contextWindow < 0 ? 0 : contextWindow;
  const safeReserved: number = reservedOutputTokens < 0 ? 0 : reservedOutputTokens;
  const safeInput: number = estimatedInputTokens < 0 ? 0 : estimatedInputTokens;

  const available: number = safeContext > safeReserved ? safeContext - safeReserved : 0;
  const remaining: number = available - safeInput;
  const exceeds: boolean = safeInput > available;

  return {
    contextWindow: safeContext,
    reservedOutputTokens: safeReserved,
    availableInputTokens: available,
    estimatedInputTokens: safeInput,
    remainingInputTokens: remaining,
    exceedsBudget: exceeds
  };
}

/**
 * 将 messages 数组的 length 记录为非敏感元信息(用于日志)。
 * 不返回任何消息内容。
 */
export function describeMessagesCount(messages: ChatMessage[]): number {
  return messages.length;
}
