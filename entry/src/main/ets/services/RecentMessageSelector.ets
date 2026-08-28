/**
 * RecentMessageSelector 最近原始消息窗口选择服务
 *
 * 职责:
 * - 以最后一次记忆总结结束位置为锚,选择其后的最近原始消息,作为 PromptBuilder 的 Conversation 段
 * - 与长期记忆范围去重:已被记忆覆盖且不在最近窗口的消息不注入原文
 * - 保留完整 User+Assistant 轮次,不拆开
 *
 * 窗口规则(缓存优先,append-only):
 * - 记忆存在时:窗口起点固定为 memoryEndPos + 1(最后一次总结覆盖后的第一条)
 * - 之后新消息只追加、不滑动、不丢弃已选中的老消息 → 发送前缀稳定 → 维持缓存命中率
 * - 直到下一次手动总结,锚点前移、窗口基数重置(保留条数 N 是总结后的基数,非硬性上限)
 * - 无记忆时:窗口从 0 开始(全部保留,没有摘要可作替代表示)
 *
 * 兜底规则:
 * - 刚总结完、窗口为空或很小时,至少保留最近若干完整 User+Assistant 轮次(MIN_COMPLETE_TURNS)与最后一条
 *
 * 去重规则:
 * - 若消息 position <= memoryEndPosition 且不在最近窗口内 → 不注入原文
 * - 最近窗口内的消息即使被记忆覆盖也保留原文(保证最近上下文连贯)
 *
 * 设计约束:
 * - 无状态、纯函数式
 * - 不修改输入数组
 * - 不访问数据库 / 网络 / ArkUI
 * - 不记录消息正文到日志
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { TokenCounter, estimateMessagesTokens } from './TokenCounter';
import {
  ContextHistorySelection,
  createEmptySelection
} from '../models/ContextHistorySelection';
import {
  DEFAULT_RECENT_WINDOW_TARGET,
  MIN_COMPLETE_TURNS
} from '../models/ContextBudgetConfig';

const LOG_TAG: string = 'RecentMsgSelector';

/**
 * 最近消息选择选项。
 */
export interface RecentMessageSelectionOptions {
  /** 目标保留条数(默认 30) */
  readonly targetCount?: number;
  /** 最少完整轮次(默认 2) */
  readonly minCompleteTurns?: number;
  /** 可用 Token 预算(用于历史段) */
  readonly availableTokens: number;
  /** 有效记忆覆盖的结束 position(-1 表示无记忆) */
  readonly memoryEndPosition: number;
}

/**
 * 最近原始消息选择器。
 */
export class RecentMessageSelector {
  private readonly tokenCounter: TokenCounter;

  constructor(tokenCounter: TokenCounter) {
    this.tokenCounter = tokenCounter;
  }

  /**
   * 从最新向前选择最近原始消息。
   *
   * @param messages 当前 Branch 的全部消息(按 position ASC)
   * @param options 选择选项
   * @returns 选择结果
   */
  select(
    messages: ChatMessage[],
    options: RecentMessageSelectionOptions
  ): ContextHistorySelection {
    if (messages.length === 0) {
      return createEmptySelection();
    }

    const targetCount: number = options.targetCount !== undefined
      ? options.targetCount : DEFAULT_RECENT_WINDOW_TARGET;
    const minTurns: number = options.minCompleteTurns !== undefined
      ? options.minCompleteTurns : MIN_COMPLETE_TURNS;
    const availableTokens: number = options.availableTokens > 0
      ? options.availableTokens : 0;
    const memoryEndPos: number = options.memoryEndPosition;

    // Step 1: 确定"最近窗口"起点(以最后一次记忆总结结束位置为锚,append-only)
    // - 记忆存在时:起点固定为 memoryEndPos+1(总结覆盖之后的第一条)
    //   此后新消息只追加、不滑动、不丢弃,发送前缀稳定 → 维持缓存命中率
    // - 无记忆时:从 0 开始,全部保留(没有摘要可作替代表示)
    const lastIndex: number = messages.length - 1;
    const windowStartIndex: number = memoryEndPos >= 0 ? memoryEndPos + 1 : 0;

    // Step 2: 标记每条消息是否应保留(去重 + 窗口)
    // - 窗口起点之后的消息一律保留(即使被记忆覆盖,保证最近上下文连贯)
    // - 窗口之外且被记忆覆盖的消息不保留(去重,由记忆摘要替代)
    // - 窗口之外且未被记忆覆盖的消息不会出现(窗口起点即记忆覆盖后第一条,天然无间隙)
    const shouldKeep: boolean[] = new Array(messages.length).fill(false);
    let dedupedCount: number = 0;
    for (let i = 0; i < messages.length; i++) {
      const inRecentWindow: boolean = i >= windowStartIndex;
      const coveredByMemory: boolean = memoryEndPos >= 0 && i <= memoryEndPos;
      if (inRecentWindow) {
        // 最近窗口内的消息一律保留(即使被记忆覆盖,保证连贯)
        shouldKeep[i] = true;
      } else {
        // 窗口外一律不保留(去重自动实现,早期原文由记忆摘要替代)
        shouldKeep[i] = false;
        if (coveredByMemory) {
          dedupedCount++;
        }
      }
    }

    // Step 3: 兜底保留最近完整轮次 + 最后一条
    // 刚手动总结完、窗口为空或很小时,保证模型仍能看到最新对话
    // 最少保留范围按"全部消息"计算,不依赖窗口标记,避免窗口为空时兜底失效
    const allKeep: boolean[] = new Array(messages.length).fill(true);
    const minKeepFromEnd: number = this.findMinKeepIndexFromEnd(
      messages, allKeep, minTurns
    );
    for (let i = minKeepFromEnd; i <= lastIndex; i++) {
      shouldKeep[i] = true;
    }

    // Step 4: 从后向前累加 Token,在预算内尽量多保留
    const selectedIndices: number[] = [];
    let accumulatedTokens: number = 0;
    let budgetExhausted: boolean = false;

    for (let i = lastIndex; i >= 0; i--) {
      if (!shouldKeep[i]) {
        continue;
      }
      const msg: ChatMessage = messages[i];
      const msgTokens: number = this.tokenCounter.estimateMessage(msg);

      // 检查是否超出预算(但必须保留 minKeepFromEnd..lastIndex 范围内的消息)
      const isMustKeep: boolean = i >= minKeepFromEnd;
      if (!isMustKeep && budgetExhausted) {
        break;
      }
      if (!isMustKeep && accumulatedTokens + msgTokens > availableTokens) {
        budgetExhausted = true;
        break;
      }
      accumulatedTokens += msgTokens;
      selectedIndices.push(i);
    }

    // Step 5: 按原顺序(ASC)输出
    selectedIndices.reverse();
    const recentMessages: ChatMessage[] = [];
    for (let i = 0; i < selectedIndices.length; i++) {
      recentMessages.push(messages[selectedIndices[i]]);
    }

    // 重新精确估算选中消息的 Token(含消息间结构开销)
    const estimatedTokens: number = estimateMessagesTokens(recentMessages);

    // 省略数 = 全部应保留消息数 - 实际选中数(不含去重部分)
    let totalEligibleCount: number = 0;
    for (let i = 0; i < shouldKeep.length; i++) {
      if (shouldKeep[i]) {
        totalEligibleCount++;
      }
    }
    const omittedCount: number = totalEligibleCount - recentMessages.length;

    return {
      recentMessages: recentMessages,
      summarizedRangeEndPosition: memoryEndPos,
      omittedMessageCount: omittedCount,
      estimatedTokens: estimatedTokens,
      targetCount: targetCount,
      selectedCount: recentMessages.length
    };
  }

  /**
   * 从末尾向前找到最少必须保留的起始索引。
   * 保证 [result, lastIndex] 范围内包含至少 minTurns 个完整 User+Assistant 轮次。
   *
   * 完整轮次定义:一条 User 紧跟一条 Assistant(允许中间有 System,但 User/Assistant 必须相邻配对)。
   * 若消息末尾是 User(待生成),该 User 也必须保留,但其前的 Assistant+User 对计入轮次。
   *
   * @return 起始索引(含),若不足 minTurns 则返回 0
   */
  private findMinKeepIndexFromEnd(
    messages: ChatMessage[],
    shouldKeep: boolean[],
    minTurns: number
  ): number {
    const lastIndex: number = messages.length - 1;
    let turnsFound: number = 0;
    let i: number = lastIndex;

    // 跳过末尾的 User(待生成场景),从其前一条开始找轮次
    if (messages[lastIndex].role === ChatRole.User) {
      i = lastIndex - 1;
    }

    while (i >= 1 && turnsFound < minTurns) {
      // 检查 [i-1, i] 是否构成 User + Assistant 对
      // 只在 shouldKeep 标记的范围内查找
      if (shouldKeep[i] && shouldKeep[i - 1]) {
        const curr: ChatMessage = messages[i];
        const prev: ChatMessage = messages[i - 1];
        // Assistant 在前,User 在后 → 不算完整轮次(反序)
        // User 在前,Assistant 在后 → 完整轮次
        if (prev.role === ChatRole.User && curr.role === ChatRole.Assistant) {
          turnsFound++;
          i -= 2;
          continue;
        }
      }
      i--;
    }

    // minKeepFromEnd = 找到的最小索引(或 0)
    // 必须包含末尾 User(如果有)
    const minIndex: number = Math.max(0, i + 1);
    // 确保包含末尾消息
    return Math.min(minIndex, lastIndex);
  }
}
