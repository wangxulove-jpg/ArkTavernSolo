/**
 * HistoryTrimmer 历史裁剪服务
 *
 * 当 PromptBuilder 生成的最终请求消息超过输入 Token 预算时,
 * 按确定性规则裁剪最旧的可裁剪聊天历史,使请求尽可能回到预算范围内。
 *
 * 职责:
 * - 接收最终请求消息 + 可用 Token 预算,返回裁剪后的消息
 * - 保护 System 消息、Character Prompt、firstMessage、当前 User 消息
 * - 按完整 User/Assistant 轮次从旧到新删除
 * - 不修改输入数组和原始消息对象
 * - 不修改消息正文,不截断
 * - 无状态、不访问 ArkUI / Provider / ChatService
 *
 * 非职责(后续阶段):
 * - 摘要压缩
 * - 消息内容截断
 * - 单条消息按字符截断
 * - 向量检索 / 长期记忆
 * - Preset / UI Token 展示
 *
 * 裁剪原则:
 * - 不超预算:返回与输入等长的新数组,removedMessageCount=0
 * - 超预算:从旧到新扫描,优先按完整 User/Assistant 轮次删除
 * - 极端超预算:删除所有可裁剪历史后仍超预算,exceedsBudgetAfterTrim=true
 * - 受保护消息一律不删
 *
 * 终止条件:
 * - 每轮至少删除一个可裁剪单元
 * - 最多执行可裁剪单元数量次循环
 * - 立即停止条件:达到预算 / 删无可删 / 连续受保护连续段
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatRole } from '../models/ChatRole';
import { TokenCounter, estimateMessagesTokens } from './TokenCounter';
import { HistoryTrimResult, createHistoryTrimResult } from '../models/HistoryTrimResult';

/** 单次裁剪最多循环次数(避免 O(n²) 失控) */
const MAX_TRIM_ITERATIONS: number = 256;

/**
 * 裁剪选项。
 */
export interface HistoryTrimOptions {
  /** 可用输入 Token 数 */
  readonly availableInputTokens: number;
  /** 显式受保护消息 ID 列表(可选) */
  readonly protectedMessageIds?: string[];
}

/**
 * 一个可裁剪单元(用于轮次删除)。
 */
interface TrimUnit {
  readonly indices: number[];
  readonly tokens: number;
  readonly priority: number;
}

const TRIM_PRIORITY_LOW: number = 0;
const TRIM_PRIORITY_MEDIUM: number = 1;
const TRIM_PRIORITY_PROTECTED: number = 2;

/**
 * 历史裁剪服务。
 *
 * 无状态,只依赖注入的 TokenCounter 做估算。
 */
export class HistoryTrimmer {
  private readonly tokenCounter: TokenCounter;

  constructor(tokenCounter: TokenCounter) {
    this.tokenCounter = tokenCounter;
  }

  /**
   * 裁剪消息列表直到 Token 数 <= availableInputTokens。
   *
   * @param messages PromptBuilder 输出的最终请求消息(已含 source 标签)
   * @param options 裁剪选项
   * @returns 裁剪结果
   */
  trim(messages: ChatMessage[], options: HistoryTrimOptions): HistoryTrimResult {
    const available: number = options.availableInputTokens > 0 ? options.availableInputTokens : 0;
    const protectedIds: Set<string> = new Set();
    if (options.protectedMessageIds !== undefined && options.protectedMessageIds !== null) {
      for (let i = 0; i < options.protectedMessageIds.length; i++) {
        protectedIds.add(options.protectedMessageIds[i]);
      }
    }

    const originalTokens: number = this.countTokensSafe(messages);
    const exceedsBefore: boolean = originalTokens > available;

    if (!exceedsBefore || messages.length === 0) {
      // 不超预算:返回新数组(内容相同)
      const copy: ChatMessage[] = messages.slice();
      return createHistoryTrimResult(
        copy,
        originalTokens,
        originalTokens,
        [],
        false,
        false
      );
    }

    // 标记可裁剪索引
    const trimPriority: number[] = new Array(messages.length).fill(TRIM_PRIORITY_PROTECTED);
    const lastIndex: number = messages.length - 1;
    for (let i = 0; i < messages.length; i++) {
      const m: ChatMessage = messages[i];
      if (i === lastIndex) {
        trimPriority[i] = TRIM_PRIORITY_PROTECTED;
        continue;
      }
      if (protectedIds.has(m.id)) {
        trimPriority[i] = TRIM_PRIORITY_PROTECTED;
        continue;
      }
      if (m.role === ChatRole.System) {
        trimPriority[i] = TRIM_PRIORITY_PROTECTED;
        continue;
      }
      if (m.source === ChatMessageSource.CrossSessionContext) {
        trimPriority[i] = TRIM_PRIORITY_LOW;
        continue;
      }
      if (m.source !== undefined && m.source !== ChatMessageSource.Conversation) {
        trimPriority[i] = TRIM_PRIORITY_PROTECTED;
        continue;
      }
      trimPriority[i] = TRIM_PRIORITY_MEDIUM;
    }

    const lowUnits: TrimUnit[] = [];
    const mediumUnits: TrimUnit[] = [];
    for (let i = 0; i < messages.length; i++) {
      if (trimPriority[i] === TRIM_PRIORITY_LOW) {
        this.appendToUnits(lowUnits, i, messages);
      } else if (trimPriority[i] === TRIM_PRIORITY_MEDIUM) {
        this.appendToUnits(mediumUnits, i, messages);
      }
    }

    const sortedUnits: TrimUnit[] = lowUnits.concat(mediumUnits);
    if (sortedUnits.length === 0) {
      const copy: ChatMessage[] = messages.slice();
      return createHistoryTrimResult(
        copy,
        originalTokens,
        originalTokens,
        [],
        true,
        true
      );
    }

    const removedSet: Set<number> = new Set<number>();
    const removedIds: string[] = [];
    let currentTokens: number = originalTokens;
    let iterations: number = 0;

    for (let u = 0; u < sortedUnits.length; u++) {
      if (currentTokens <= available) {
        break;
      }
      iterations++;
      if (iterations > MAX_TRIM_ITERATIONS) {
        break;
      }
      const unit: TrimUnit = sortedUnits[u];
      for (let k = 0; k < unit.indices.length; k++) {
        const idx: number = unit.indices[k];
        removedSet.add(idx);
        removedIds.push(messages[idx].id);
      }
      currentTokens = currentTokens - unit.tokens;
      if (currentTokens < 0) {
        currentTokens = 0;
      }
    }

    const exceedsAfter: boolean = currentTokens > available;

    // 构造裁剪后数组(按原顺序)
    const result: ChatMessage[] = [];
    for (let i = 0; i < messages.length; i++) {
      if (!removedSet.has(i)) {
        result.push(messages[i]);
      }
    }

    return createHistoryTrimResult(
      result,
      originalTokens,
      currentTokens,
      removedIds,
      true,
      exceedsAfter
    );
  }

  private appendToUnits(units: TrimUnit[], index: number, messages: ChatMessage[]): void {
    const m: ChatMessage = messages[index];
    const lastUnit: TrimUnit | undefined = units.length > 0 ? units[units.length - 1] : undefined;
    if (lastUnit !== undefined) {
      const lastIdx: number = lastUnit.indices[lastUnit.indices.length - 1];
      if (lastIdx === index - 1) {
        const newIndices: number[] = lastUnit.indices.slice();
        newIndices.push(index);
        const slice: ChatMessage[] = newIndices.map((i: number): ChatMessage => messages[i]);
        const tokens: number = estimateMessagesTokens(slice);
        units[units.length - 1] = { indices: newIndices, tokens: tokens, priority: TRIM_PRIORITY_LOW };
        return;
      }
    }
    const tokens: number = estimateMessagesTokens([m]);
    units.push({ indices: [index], tokens: tokens, priority: TRIM_PRIORITY_LOW });
  }

  /**
   * 安全计算消息列表 Token 数(捕获异常时返回估算值)。
   */
  private countTokensSafe(messages: ChatMessage[]): number {
    try {
      return this.tokenCounter.estimateMessages(messages);
    } catch (e) {
      return estimateMessagesTokens(messages);
    }
  }
}
