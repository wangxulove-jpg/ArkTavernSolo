/**
 * ForkChatOptions 从分支创建独立对话的选项
 *
 * 用于 ForkChatService,定义两种模式:
 * - FullHistory:携带完整历史(从根到目标消息)
 * - MemoryOnly:只携带记忆(可选保留最后 2~4 条消息作为上下文)
 *
 * 新会话:
 * - 创建新 chatId 和新 branchId
 * - 关联同一角色(继承 sourceChat.characterId)
 * - 与原会话完全独立(后续互不影响)
 *
 * 设计约束:
 * - 不存储消息正文(由 Service 在事务内读取并复制)
 * - 不依赖 ArkUI
 */

/**
 * Fork 模式枚举。
 */
export enum ForkChatMode {
  /** 携带完整历史:复制从根到目标消息的全部路径 */
  FullHistory = 'fullHistory',
  /** 只携带记忆:不复制旧消息,可选保留最后 2~4 条 */
  MemoryOnly = 'memoryOnly'
}

/**
 * FullHistory 模式选项。
 */
export interface FullHistoryForkOptions {
  /** Fork 模式(固定为 FullHistory) */
  readonly mode: ForkChatMode.FullHistory;
  /** 源 Chat ID */
  readonly sourceChatId: string;
  /** 源 Branch ID */
  readonly sourceBranchId: string;
  /** 分叉消息 ID(复制到此消息含本身) */
  readonly forkMessageId: string;
  /** 新会话标题(可选,默认"独立对话") */
  readonly title?: string;
}

/**
 * MemoryOnly 模式选项。
 */
export interface MemoryOnlyForkOptions {
  /** Fork 模式(固定为 MemoryOnly) */
  readonly mode: ForkChatMode.MemoryOnly;
  /** 源 Chat ID */
  readonly sourceChatId: string;
  /** 源 Branch ID */
  readonly sourceBranchId: string;
  /** 新会话标题(可选) */
  readonly title?: string;
  /** 保留最后 N 条消息作为上下文(0~4,默认 0 表示不保留) */
  readonly keepRecentMessages?: number;
}

/** Fork 选项联合类型 */
export type ForkChatOptions = FullHistoryForkOptions | MemoryOnlyForkOptions;

/**
 * Fork 结果。
 */
export interface ForkChatResult {
  /** 新创建的 Chat ID */
  readonly chatId: string;
  /** 新创建的 Root Branch ID */
  readonly branchId: string;
  /** 复制的消息数(FullHistory 模式),MemoryOnly 模式为保留的最近消息数 */
  readonly copiedMessageCount: number;
  /** 复制的 Memory 数量 */
  readonly copiedMemoryCount: number;
}
