/**
 * PersistedChatSession 持久化会话领域模型
 *
 * 表示一个从数据库加载或新建的完整会话视图:
 * - chat: 会话元数据
 * - messages: 按 sequence 升序的可见消息列表(仅含可持久化 source)
 *
 * 不含:
 * - 动态 Prompt 消息(CharacterPrompt / Lorebook*)
 * - 宏替换临时副本
 * - Token 统计结果
 * - HistoryTrimmer 裁剪结果
 *
 * 不依赖 ArkUI / RDB / 页面。
 */

import { Chat } from './Chat';
import { ChatMessage } from './ChatMessage';

export interface PersistedChatSession {
  readonly chat: Chat;
  readonly messages: ChatMessage[];
  /** 当前会话的最大 sequence_number(空会话为 0) */
  readonly maxSequenceNumber: number;
}

/**
 * 打开会话时的选项。
 * - characterId 为 undefined 表示普通助手聊天
 * - createIfMissing 为 true 时,如果不存在历史会话则创建新会话
 */
export interface OpenChatOptions {
  readonly characterId?: string;
  readonly createIfMissing?: boolean;
  readonly title?: string;
}
