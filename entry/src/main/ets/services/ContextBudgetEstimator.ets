/**
 * ContextBudgetEstimator 上下文预算估算与分段统计(v8.1)
 *
 * 职责:
 * - 对 PromptBuilder 输出的 messages 列表按 source 分组统计 Token
 * - 提供 ContextBudgetStats 给 UI 展示分类占用
 * - 不重新构建 Prompt(复用已有 messages)
 * - 不持久化任何数据
 *
 * 设计:
 * - 纯函数式服务,无状态
 * - 内部调用 TokenCounter.estimateMessage(已支持单条估算)
 * - 不修改 PromptBuilder
 * - 不影响实际请求
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { TokenCounter } from './TokenCounter';
import { TokenBudget } from '../models/TokenBudget';

const LOG_TAG: string = 'BudgetEstimator';

/**
 * 单个分段的 Token 统计。
 */
export interface SegmentTokenStat {
  /** 显示名称 */
  label: string;
  /** 来源标签 */
  source: ChatMessageSource;
  /** 段内消息数 */
  messageCount: number;
  /** 段内 Token 总数 */
  tokenCount: number;
  /** 该段在总输入中占比(0~1) */
  ratio: number;
}

/**
 * 上下文预算完整统计。
 */
export interface ContextBudgetStats {
  /** 模型上下文上限 */
  contextWindow: number;
  /** 预留输出 Token */
  reservedOutputTokens: number;
  /** 输入可用预算 */
  availableInputTokens: number;
  /** 实际输入 Token(分段之和) */
  totalInputTokens: number;
  /** 剩余可用 Token(可为负) */
  remainingInputTokens: number;
  /** 占用百分比(0~1,可超过 1) */
  usageRatio: number;
  /** 是否超预算 */
  exceedsBudget: boolean;
  /** 是否估算值(始终 true,因使用本地估算器) */
  isEstimated: boolean;
  /** 分段统计(按显示顺序) */
  segments: SegmentTokenStat[];
  /** 预留输出 Token 的分段(作为最后一项展示) */
  reservedSegment: SegmentTokenStat;
}

/**
 * 估算上下文预算的纯函数式服务。
 */
export class ContextBudgetEstimator {
  private readonly tokenCounter: TokenCounter;

  constructor(tokenCounter: TokenCounter) {
    this.tokenCounter = tokenCounter;
  }

  /**
   * 对 PromptBuilder 输出的 messages 进行分段统计。
   *
   * @param messages PromptBuilder.build().messages(已按 position 排序)
   * @param budget 当前生效的 TokenBudget(从 ChatService.getLastTokenBudget 取得)
   * @returns 完整统计;若 budget 为 undefined 则只返回分段统计,预算字段为 0
   */
  estimate(
    messages: ChatMessage[],
    budget: TokenBudget | undefined
  ): ContextBudgetStats {
    // 按分段标签聚合
    const groups: Map<ChatMessageSource, ChatMessage[]> = new Map();
    for (let i = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      const source: ChatMessageSource = msg.source !== undefined
        ? msg.source : ChatMessageSource.ExternalSystem;
      const arr: ChatMessage[] | undefined = groups.get(source);
      if (arr === undefined) {
        groups.set(source, [msg]);
      } else {
        arr.push(msg);
      }
    }

    // 计算每段 Token
    const segmentStats: SegmentTokenStat[] = [];
    let totalInputTokens: number = 0;
    const orderedSources: ChatMessageSource[] = [
      ChatMessageSource.PromptPresetSystem,
      ChatMessageSource.ExternalSystem,
      ChatMessageSource.CharacterPrompt,
      ChatMessageSource.LorebookBefore,
      ChatMessageSource.LorebookAfter,
      ChatMessageSource.MemorySummary,
      ChatMessageSource.CharacterMesExample,
      ChatMessageSource.CharacterFirstMessage,
      ChatMessageSource.Conversation,
      ChatMessageSource.CharacterPostHistory
    ];

    for (let i = 0; i < orderedSources.length; i++) {
      const src: ChatMessageSource = orderedSources[i];
      const arr: ChatMessage[] | undefined = groups.get(src);
      if (arr === undefined || arr.length === 0) {
        continue;
      }
      let segTokens: number = 0;
      for (let j = 0; j < arr.length; j++) {
        segTokens += this.tokenCounter.estimateMessage(arr[j]);
      }
      totalInputTokens += segTokens;
      segmentStats.push({
        label: this.labelForSource(src),
        source: src,
        messageCount: arr.length,
        tokenCount: segTokens,
        ratio: 0 // 后续填充
      });
    }

    // 计算每段占比
    if (totalInputTokens > 0) {
      for (let i = 0; i < segmentStats.length; i++) {
        segmentStats[i] = {
          label: segmentStats[i].label,
          source: segmentStats[i].source,
          messageCount: segmentStats[i].messageCount,
          tokenCount: segmentStats[i].tokenCount,
          ratio: segmentStats[i].tokenCount / totalInputTokens
        };
      }
    }

    // 预算字段
    const contextWindow: number = budget !== undefined ? budget.contextWindow : 0;
    const reserved: number = budget !== undefined ? budget.reservedOutputTokens : 0;
    const available: number = budget !== undefined ? budget.availableInputTokens : 0;
    const remaining: number = budget !== undefined
      ? budget.remainingInputTokens : (available - totalInputTokens);
    const usageRatio: number = available > 0 ? totalInputTokens / available : 0;
    const exceeds: boolean = budget !== undefined
      ? budget.exceedsBudget : (available > 0 && totalInputTokens > available);

    const reservedSegment: SegmentTokenStat = {
      label: '为模型回复预留',
      source: ChatMessageSource.ExternalSystem, // 占位,无对应来源
      messageCount: 0,
      tokenCount: reserved,
      ratio: contextWindow > 0 ? reserved / contextWindow : 0
    };

    return {
      contextWindow,
      reservedOutputTokens: reserved,
      availableInputTokens: available,
      totalInputTokens,
      remainingInputTokens: remaining,
      usageRatio,
      exceedsBudget: exceeds,
      isEstimated: true,
      segments: segmentStats,
      reservedSegment
    };
  }

  /**
   * 将 source 转换为用户可读的中文名称。
   */
  private labelForSource(src: ChatMessageSource): string {
    switch (src) {
      case ChatMessageSource.PromptPresetSystem:
        return 'Prompt Preset';
      case ChatMessageSource.ExternalSystem:
        return 'System Prompt';
      case ChatMessageSource.CharacterPrompt:
        return '角色卡';
      case ChatMessageSource.LorebookBefore:
        return '角色世界书';
      case ChatMessageSource.LorebookAfter:
        return '全局世界书';
      case ChatMessageSource.MemorySummary:
        return '记忆摘要';
      case ChatMessageSource.CharacterMesExample:
        return '对话示例';
      case ChatMessageSource.CharacterFirstMessage:
        return '角色首条消息';
      case ChatMessageSource.Conversation:
        return '最近聊天历史';
      case ChatMessageSource.CharacterPostHistory:
        return 'Post-History Instructions';
      default:
        return '其他';
    }
  }
}

/**
 * 预算状态级别(用于 UI 颜色显示)。
 */
export enum BudgetLevel {
  /** 正常 < 70% */
  Normal = 'normal',
  /** 警告 70%~90% */
  Warning = 'warning',
  /** 高风险 90%~100% */
  High = 'high',
  /** 超预算 > 100% */
  Exceeded = 'exceeded'
}

/**
 * 根据使用比例计算状态级别。
 */
export function classifyBudgetLevel(usageRatio: number): BudgetLevel {
  if (usageRatio >= 1.0) {
    return BudgetLevel.Exceeded;
  }
  if (usageRatio >= 0.9) {
    return BudgetLevel.High;
  }
  if (usageRatio >= 0.7) {
    return BudgetLevel.Warning;
  }
  return BudgetLevel.Normal;
}
