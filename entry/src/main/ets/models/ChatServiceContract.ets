/**
 * ChatServiceContract 聊天服务对外契约(自 ChatService 迁出)
 *
 * 内容:
 * - ChatState:聊天流式状态机枚举
 * - ChatServiceCallbacks:聊天服务回调契约
 *
 * 迁出原因:ChatOneShotGenerator 等拆分模块与 ChatViewModel 均需引用本契约;
 * 置于 models 层,避免契约绕行 services 与服务间圆形依赖。
 */

import { ChatMessage } from './ChatMessage';
import { ChatStatusState } from './ChatStatusState';

/**
 * 聊天状态枚举。
 */
export enum ChatState {
  Idle = 'Idle',
  Sending = 'Sending',
  Streaming = 'Streaming',
  Completed = 'Completed',
  Cancelled = 'Cancelled',
  Failed = 'Failed'
}

/**
 * 聊天服务回调。
 */
export interface ChatServiceCallbacks {
  /** 消息列表变更 */
  onMessagesChanged: (messages: ChatMessage[]) => void;
  /** 状态变更 */
  onStateChanged: (state: ChatState) => void;
  /** 错误消息 */
  onError: (message: string) => void;
  /**
   * 助手最终消息完成回调 (可选)。
   *
   * @param assistantMessageId 真实助手消息 ID
   * @param performanceHintJson 可选 Hint JSON (无则空字符串)
   */
  onAssistantMessageFinalized?: (
    assistantMessageId: string,
    performanceHintJson: string
  ) => void;
  /**
   * 角色状态变更回调(CHAT-STATUS-1A,可选)。
   *
   * 触发时机:
   * - 会话初始化 / 切换 / 新建后加载到状态
   * - AI 回复完成后合并更新状态
   * - 用户通过 updateStatusState 增删改锁字段后
   *
   * 用途: ChatViewModel 实现此回调,把最新状态同步到 ChatPage 顶部状态卡片。
   */
  onStatusChanged?: (state: ChatStatusState) => void;
  /**
   * 缓存命中率更新回调(可选)。
   *
   * 触发时机:AI 回复完成后,从 Provider 响应中提取缓存统计。
   *
   * @param cachedTokens 缓存命中的 token 数
   * @param promptTokens 总输入 prompt token 数
   * @param hitRatio 缓存命中率 (cachedTokens / promptTokens, 0~1)
   */
  onCacheStatsUpdate?: (cachedTokens: number, promptTokens: number, hitRatio: number) => void;
}
