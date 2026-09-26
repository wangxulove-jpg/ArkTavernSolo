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
    // 实际请求顺序(与 PromptSegment.POSITION_ORDER 对齐)。
    // 必须包含全部来源:此前缺少 粘滞/按需锁定/深度注入/分层记忆 等来源,
    // 导致这些段既不显示在"分段占用"里,也不计入 totalInputTokens(占用被低估)。
    const orderedSources: ChatMessageSource[] = [
      ChatMessageSource.PromptPresetSystem,
      ChatMessageSource.LorebookBefore,
      ChatMessageSource.PersonaBefore,
      ChatMessageSource.CharacterPrompt,
      ChatMessageSource.PersonaAfter,
      ChatMessageSource.LorebookAfter,
      ChatMessageSource.CharacterMesExample,
      ChatMessageSource.MemoryCore,
      ChatMessageSource.LorebookPinned,
      ChatMessageSource.MemorySession,
      ChatMessageSource.MemoryChapter,
      ChatMessageSource.MemoryRolling,
      ChatMessageSource.MemoryLegacy,
      ChatMessageSource.MemorySummary,
      ChatMessageSource.CrossSessionContext,
      ChatMessageSource.CharacterFirstMessage,
      ChatMessageSource.NarratorInstruction,
      ChatMessageSource.ExternalSystem,
      ChatMessageSource.Conversation,
      ChatMessageSource.LorebookDepth,
      ChatMessageSource.LorebookSticky,
      ChatMessageSource.FrontendInteraction,
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
    return sourceDisplayLabel(src);
  }
}

/**
 * 将消息来源(source)转换为用户可读的中文名称。
 * 供分段统计与"发送顺序"展示共用,保证两处名称一致。
 * 名称中带"加载方式"说明(常量/命中/粘滞/钉选/深度/常驻…),便于在
 * "发送给模型的上下文顺序"里一眼看出每条是按哪种方式加载进来的。
 */
export function sourceDisplayLabel(src: ChatMessageSource): string {
  switch (src) {
    case ChatMessageSource.PromptPresetSystem:
      return '预设系统提示(常驻)';
    case ChatMessageSource.ExternalSystem:
      return 'System Prompt(会话内注入)';
    case ChatMessageSource.CharacterPrompt:
      return '角色卡定义(常驻)';
    case ChatMessageSource.LorebookBefore:
    // 按插入位置命名(角色前/后),而不是"角色/全局"——注入消息不区分来源书,
    // 全局书与角色书的条目都按 entry.position 归属这两段,避免误导用户以为加载了全局世界书
      return '世界书·角色前(常量/命中)';
    case ChatMessageSource.LorebookAfter:
      return '世界书·角色后(常量/命中)';
    case ChatMessageSource.LorebookPinned:
      return '世界书·按需锁定(会话钉选)';
    case ChatMessageSource.LorebookDepth:
      return '世界书·按需加载(深度注入)';
    case ChatMessageSource.LorebookSticky:
      return '世界书·粘滞按需(累积命中)';
    case ChatMessageSource.MemorySummary:
      return '记忆摘要(旧版兼容)';
    case ChatMessageSource.MemoryCore:
      return '核心记忆(常驻)';
    case ChatMessageSource.MemorySession:
      return '会话记忆(常驻)';
    case ChatMessageSource.MemoryChapter:
      return '章节记忆(按时间注入)';
    case ChatMessageSource.MemoryRolling:
      return '滚动记忆(近期摘要)';
    case ChatMessageSource.MemoryLegacy:
      return '旧记忆(迁移兼容)';
    case ChatMessageSource.PersonaBefore:
      return 'Persona(角色前/按深度)';
    case ChatMessageSource.PersonaAfter:
      return 'Persona(角色后)';
    case ChatMessageSource.CrossSessionContext:
      return '跨会话上下文(摘要)';
    case ChatMessageSource.CharacterMesExample:
      return '对话示例(常驻)';
    case ChatMessageSource.CharacterFirstMessage:
      return '角色首条消息';
    case ChatMessageSource.NarratorInstruction:
      return '旁白指令';
    case ChatMessageSource.Conversation:
      return '最近聊天历史(可裁剪)';
    case ChatMessageSource.FrontendInteraction:
      return '前端交互记录(卡片界面操作)';
    case ChatMessageSource.CharacterPostHistory:
      return 'Post-History(常驻)';
    default:
      return '其他';
  }
}

/**
 * 该来源的加载方式说明(一句话,供"上下文顺序"逐条展示)。
 * 无特别说明时返回空串(调用方不展示)。
 */
export function sourceMethodLabel(src: ChatMessageSource): string {
  switch (src) {
    case ChatMessageSource.LorebookSticky:
      return '加载方式:粘滞按需(StickyOnDemand)——关键词命中后常驻,只增不减,'
        + '追加在对话之后、PostHistory 之前(尾部 append-only 保缓存)';
    case ChatMessageSource.LorebookPinned:
      return '加载方式:按需锁定(OnDemandPinned)——本会话首次钉选后固定,'
        + '注入在核心记忆之后、会话记忆之前(随手动记忆总结刷新)';
    case ChatMessageSource.LorebookDepth:
      return '加载方式:按需加载(OnDemand)——关键词命中后按深度插入到对话内部,'
        + '每轮重新匹配(未命中的轮次不会出现)';
    case ChatMessageSource.FrontendInteraction:
      return '加载方式:角色卡前端界面交互(契约 v3 appendInteraction)——页面轻交互攒下,'
        + '不触发模型请求,下一轮随本段注入(最近 30 条/2000 字符,尾部滚动窗口)';
    case ChatMessageSource.LorebookBefore:
    case ChatMessageSource.LorebookAfter:
      return '加载方式:常量常驻 + 关键词命中(注入角色定义前/后)';
    case ChatMessageSource.MemoryCore:
    case ChatMessageSource.MemorySession:
    case ChatMessageSource.MemoryChapter:
    case ChatMessageSource.MemoryRolling:
    case ChatMessageSource.MemoryLegacy:
    case ChatMessageSource.MemorySummary:
      return '加载方式:长期记忆分层注入(不进入可见聊天记录)';
    case ChatMessageSource.Conversation:
      return '加载方式:可见聊天历史(超预算时可被裁剪)';
    case ChatMessageSource.CharacterFirstMessage:
      return '加载方式:角色卡开场白(对话流起点)';
    default:
      return '';
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
