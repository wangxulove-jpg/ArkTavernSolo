/**
 * ContextBudgetSnapshotStore 上下文预算快照存储(v8.1)
 *
 * 职责:
 * - 持有最近一次构建的 Prompt 分段统计(ContextBudgetStats)
 * - 在 ChatPage 与 ContextBudgetPage 之间共享快照(无需序列化)
 * - 仅内存,不持久化
 *
 * 设计:
 * - 单例,进程内共享
 * - 仅保存最近一次快照 + 对应 chatId
 * - ChatPage 在每次 prompt 重建后调用 setSnapshot
 * - ContextBudgetPage 在 aboutToAppear 调用 getSnapshot 读取
 * - chatId 不匹配时返回 null(避免显示陈旧数据)
 *
 * 不依赖:
 * - ArkUI / AppStorage
 * - 数据库 / Preferences
 * - 任何业务服务
 */

import { ChatMessage } from '../models/ChatMessage';
import { TokenBudget } from '../models/TokenBudget';

/**
 * 上下文预算快照(budget + 请求消息)。
 * 由 ChatPage 写入,ContextBudgetPage 读取。
 */
export interface ContextBudgetSnapshot {
  /** 快照对应的 Chat ID */
  readonly chatId: string;
  /** 最近一次构建的 TokenBudget(可能为 undefined) */
  readonly budget: TokenBudget | undefined;
  /** 最近一次构建的请求消息(可能为 undefined) */
  readonly requestMessages: ChatMessage[] | undefined;
}

/**
 * 上下文预算快照存储(单例)。
 */
export class ContextBudgetSnapshotStore {
  private static instance: ContextBudgetSnapshotStore | null = null;
  private snapshot: ContextBudgetSnapshot | null = null;

  private constructor() {
  }

  static getInstance(): ContextBudgetSnapshotStore {
    if (ContextBudgetSnapshotStore.instance === null) {
      ContextBudgetSnapshotStore.instance = new ContextBudgetSnapshotStore();
    }
    return ContextBudgetSnapshotStore.instance;
  }

  /**
   * 写入快照(覆盖式)。
   */
  setSnapshot(snapshot: ContextBudgetSnapshot): void {
    this.snapshot = snapshot;
  }

  /**
   * 读取指定 Chat 的快照。chatId 不匹配返回 null。
   */
  getSnapshot(chatId: string): ContextBudgetSnapshot | null {
    if (this.snapshot === null) {
      return null;
    }
    if (this.snapshot!.chatId !== chatId) {
      return null;
    }
    return this.snapshot;
  }

  /**
   * 清除快照(切换 Chat 或退出时调用)。
   */
  clear(): void {
    this.snapshot = null;
  }
}
