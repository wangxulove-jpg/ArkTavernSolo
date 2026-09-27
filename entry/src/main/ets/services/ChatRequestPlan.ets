/**
 * ChatRequestPlan 请求计划(Token 预算 + 历史裁剪)
 *
 * 自 ChatService.updateRequestPlan / makeBudget / logNormalEstimate 抽离(纯逻辑):
 * 计算输入可用预算 → 超预算则裁剪历史 → 重算预算;
 * 失败不抛出,返回空结果(预算/裁剪结果 undefined),由调用方按需回写与提示。
 *
 * 依赖经参数传入(不持有服务实例),便于单测;日志只输出条数/Token 数,不含消息内容。
 */

import { ChatMessage } from '../models/ChatMessage';
import { HistoryTrimResult } from '../models/HistoryTrimResult';
import { TokenBudget, DEFAULT_CONTEXT_WINDOW, DEFAULT_RESERVED_OUTPUT_TOKENS } from '../models/TokenBudget';
import { calculateSafetyMargin, ContextBudgetConfig } from '../models/ContextBudgetConfig';
import { EffectiveGenerationSettings } from './PromptPresetRuntimeResolver';
import { TokenCounter } from './TokenCounter';
import { HistoryTrimmer } from './HistoryTrimmer';
import { ContextBudgetService } from './ContextBudgetService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatRequestPlan';

/** 计划依赖(null 表示未装配,跳过对应能力) */
export interface RequestPlanDeps {
  tokenCounter: TokenCounter | null;
  historyTrimmer: HistoryTrimmer | null;
  contextBudgetService: ContextBudgetService | null;
}

/** 计划结果 */
export interface RequestPlanResult {
  /** 最终请求消息(未裁剪时为入参原样) */
  finalMessages: ChatMessage[];
  /** Token 预算(未统计或统计失败时 undefined) */
  budget: TokenBudget | undefined;
  /** 历史裁剪结果(未裁剪或裁剪失败时 undefined) */
  trimResult: HistoryTrimResult | undefined;
  /** 是否发生裁剪(调用方据此回写"最后请求消息") */
  trimmed: boolean;
}

/**
 * 计算请求计划:Token 预算,必要时裁剪,再重算预算。
 * 失败不抛出,仅返回空结果并记录安全日志。
 *
 * @param requestMessages PromptBuilder 输出的请求消息
 * @param effectiveSettings 生效的生成参数(含 contextWindow 和 maxOutputTokens)
 * @param chatId 当前会话 id(undefined 表示未初始化,跳过 per-chat 预算覆盖)
 * @param deps 统计/裁剪/预算依赖
 */
export async function planRequest(
  requestMessages: ChatMessage[],
  effectiveSettings: EffectiveGenerationSettings,
  chatId: string | undefined,
  deps: RequestPlanDeps
): Promise<RequestPlanResult> {
  const tokenCounter: TokenCounter | null = deps.tokenCounter;
  if (tokenCounter === null) {
    // 无 TokenCounter:跳过,使用原始请求消息
    const skipped: RequestPlanResult = {
      finalMessages: requestMessages,
      budget: undefined,
      trimResult: undefined,
      trimmed: false
    };
    return skipped;
  }

  let contextWindow: number = DEFAULT_CONTEXT_WINDOW;
  let reserved: number = DEFAULT_RESERVED_OUTPUT_TOKENS;

  // 从 effectiveSettings 获取 contextWindow
  if (effectiveSettings.contextWindow !== undefined) {
    contextWindow = effectiveSettings.contextWindow;
  }

  // 从 effectiveSettings 获取 maxOutputTokens(预留输出)
  if (effectiveSettings.maxOutputTokens !== undefined &&
    effectiveSettings.maxOutputTokens > 0) {
    reserved = effectiveSettings.maxOutputTokens;
  }

  // v8.1: per-chat 上下文预算覆盖(由 ContextBudgetService 提供)
  // followModel=false 时,使用用户自定义值覆盖 effectiveSettings
  const contextBudgetService: ContextBudgetService | null = deps.contextBudgetService;
  if (contextBudgetService !== null && chatId !== undefined) {
    try {
      const budget: ContextBudgetConfig = await contextBudgetService.getBudget(chatId);
      if (!budget.followModel) {
        // 自定义值已在 Service 内部 clamp 到合法范围
        if (budget.customContextWindow > 0) {
          contextWindow = budget.customContextWindow;
        }
        if (budget.customReservedOutputTokens > 0) {
          reserved = budget.customReservedOutputTokens;
        }
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'contextBudgetService.getBudget failed: '
        + (e instanceof Error ? e.message : String(e)));
    }
  }

  // v8.3 Phase 2: 输入可用预算 = contextWindow - reserved - safetyMargin
  // 安全余量动态计算:
  // - 至少 MIN_SAFETY_MARGIN(1024)Token,避免小上下文窗口时余量不足
  // - 按 contextWindow 的 3% 计算,大上下文窗口时余量按比例增大
  // - 上限 MAX_SAFETY_MARGIN(8192)Token,避免超大上下文窗口(1M)时余量浪费
  // 安全余量用于 Token 估算误差和 Provider 包装(系统消息、JSON 序列化等附加 Token)
  const safetyMargin: number = calculateSafetyMargin(contextWindow);
  let available: number = contextWindow - reserved - safetyMargin;
  if (available < 0) {
    available = 0;
  }

  // 1) 首次预算估算(原始 Prompt)
  let currentMessages: ChatMessage[] = requestMessages;
  let originalTokens: number = 0;
  try {
    originalTokens = tokenCounter.estimateMessages(currentMessages);
  } catch (e) {
    Logger.warn(LOG_TAG, 'token estimate failed: ' + (e instanceof Error ? e.message : String(e)));
    const failed: RequestPlanResult = {
      finalMessages: requestMessages,
      budget: undefined,
      trimResult: undefined,
      trimmed: false
    };
    return failed;
  }
  const exceedsBefore: boolean = originalTokens > available;

  // 2) 必要时调用 HistoryTrimmer
  const historyTrimmer: HistoryTrimmer | null = deps.historyTrimmer;
  if (exceedsBefore && historyTrimmer !== null) {
    let trimResult: HistoryTrimResult | undefined = undefined;
    try {
      trimResult = historyTrimmer.trim(currentMessages, { availableInputTokens: available });
    } catch (e) {
      Logger.warn(LOG_TAG, 'history trim failed: ' + (e instanceof Error ? e.message : String(e)));
      const failed: RequestPlanResult = {
        finalMessages: requestMessages,
        budget: makeBudget(originalTokens, contextWindow, reserved, available),
        trimResult: undefined,
        trimmed: false
      };
      return failed;
    }
    currentMessages = trimResult.messages;

    // 3) 重算 TokenBudget
    let finalTokens: number = trimResult.finalTokenCount;
    try {
      finalTokens = tokenCounter.estimateMessages(currentMessages);
    } catch (e) {
      // 异常时使用 trimResult 的值
      Logger.warn(LOG_TAG, 'token re-estimate failed: ' + (e instanceof Error ? e.message : String(e)));
    }
    const budget: TokenBudget = makeBudget(finalTokens, contextWindow, reserved, available);
    if (budget.exceedsBudget) {
      Logger.warn(LOG_TAG,
        'token budget exceeded after trim: inputTokens=' + finalTokens.toString()
          + ' availableTokens=' + available.toString());
    }
    const trimmed: RequestPlanResult = {
      finalMessages: currentMessages,
      budget: budget,
      trimResult: trimResult,
      trimmed: true
    };
    return trimmed;
  }

  // 不超预算或无 HistoryTrimmer:不裁剪
  logNormalEstimate(requestMessages.length, originalTokens, available);
  const normal: RequestPlanResult = {
    finalMessages: requestMessages,
    budget: makeBudget(originalTokens, contextWindow, reserved, available),
    trimResult: undefined,
    trimmed: false
  };
  return normal;
}

/** 组装 TokenBudget */
function makeBudget(
  inputTokens: number, contextWindow: number, reserved: number, available: number
): TokenBudget {
  const remaining: number = available - inputTokens;
  const exceeds: boolean = inputTokens > available;
  return {
    contextWindow: contextWindow,
    reservedOutputTokens: reserved,
    availableInputTokens: available,
    estimatedInputTokens: inputTokens,
    remainingInputTokens: remaining,
    exceedsBudget: exceeds
  };
}

/** 未裁剪时的安全日志(仅在超预算但未裁剪时告警) */
function logNormalEstimate(messages: number, inputTokens: number, available: number): void {
  if (inputTokens > available) {
    Logger.warn(LOG_TAG,
      'token budget exceeded: messages=' + messages.toString()
        + ' inputTokens=' + inputTokens.toString()
        + ' availableTokens=' + available.toString()
        + ' remainingTokens=' + (available - inputTokens).toString()
        + ' exceedsBudget=true');
  }
}