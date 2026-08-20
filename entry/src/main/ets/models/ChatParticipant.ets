/**
 * ChatParticipant 多人聊天参与者模型
 *
 * G-DATA-1A 引入。表示一个角色在某个多人 Chat 中的成员关系。
 * 纯数据模型,不依赖 ArkUI / RDB / 页面。
 *
 * 规则:
 * - 同一 Chat 内 characterId 唯一(PRIMARY KEY)
 * - 同一 Chat 内 speakerOrder 唯一(UNIQUE)
 * - speakerOrder 从 0 开始,顺序必须连续
 * - 成员总数 2~8
 * - 至少 2 个成员 isEnabled = true
 *
 * 持久化到 chat_participants 表。
 * 不包含角色权限、群昵称、发言权重、关系、位置、场景等扩展字段。
 */

import { nowMillis } from '../utils/Time';

export interface ChatParticipant {
  /** 所属 Chat ID */
  readonly chatId: string;
  /** 角色 ID(同 Chat 内唯一) */
  readonly characterId: string;
  /** 发言顺序(从 0 开始,同 Chat 内唯一且连续) */
  readonly speakerOrder: number;
  /** 是否启用(参与 AI 生成轮次) */
  readonly isEnabled: boolean;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
}

export interface CreateChatParticipantOptions {
  readonly chatId: string;
  readonly characterId: string;
  readonly speakerOrder: number;
  readonly isEnabled?: boolean;
  readonly createdAt?: number;
  readonly updatedAt?: number;
}

/**
 * 创建 ChatParticipant。
 * - chatId / characterId 不能为空
 * - speakerOrder 必须 >= 0
 * - isEnabled 默认 true
 * - createdAt / updatedAt 默认当前时间
 */
export function createChatParticipant(
  options: CreateChatParticipantOptions
): ChatParticipant {
  if (options.chatId === '') {
    throw new Error('ChatParticipant: chatId empty');
  }
  if (options.characterId === '') {
    throw new Error('ChatParticipant: characterId empty');
  }
  if (!Number.isFinite(options.speakerOrder) || options.speakerOrder < 0) {
    throw new Error('ChatParticipant: speakerOrder invalid');
  }
  const now: number = nowMillis();
  return {
    chatId: options.chatId,
    characterId: options.characterId,
    speakerOrder: options.speakerOrder,
    isEnabled: options.isEnabled !== undefined ? options.isEnabled : true,
    createdAt: options.createdAt !== undefined ? options.createdAt : now,
    updatedAt: options.updatedAt !== undefined ? options.updatedAt : now
  };
}
