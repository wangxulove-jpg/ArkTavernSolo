/**
 * Chat 聊天会话模型
 *
 * 纯数据模型,不依赖 ArkUI、RDB 或页面。
 * id 默认使用 UUID,时间默认使用统一 Time 工具。
 * 所有更新返回新对象,不修改原对象。
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';
import { ConversationMode } from './ConversationMode';

export interface Chat {
  readonly id: string;
  readonly characterId?: string;
  readonly title: string;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly lastMessageAt: number;
  readonly isArchived: boolean;
  /**
   * 对话级用户称呼覆盖(可选,v9 引入)。
   * 留空时按角色 userName 或全局用户称呼回退;
   * 非空时仅影响本对话的 {{user}} 替换,不修改角色或全局设置。
   */
  readonly userNameOverride: string;
  /** 自定义排序权重(越小越靠前,v7 引入) */
  readonly sortOrder: number;
  /**
   * 对话模式(G-DATA-1A 引入)。
   * - Single: 单聊(普通助手或单一角色)
   * - Group: 多人聊天(characterId 必须为 null,参与者由 chat_participants 表维护)
   *
   * 兼容规则:
   * - 旧数据迁移后统一为 Single
   * - 现有 Chat 创建调用未显式传入 mode 时默认 Single
   */
  readonly conversationMode: ConversationMode;
  /**
   * 角色状态配置 JSON(每会话持久化,v34 引入)。
   * 存 ChatStatusState 的序列化字符串,仅单人聊天使用;留空表示无状态配置。
   */
  readonly statusConfigJson: string;
}

export interface CreateChatOptions {
  readonly id?: string;
  readonly characterId?: string;
  readonly title?: string;
  readonly createdAt?: number;
  readonly userNameOverride?: string;
  readonly sortOrder?: number;
  readonly conversationMode?: ConversationMode;
  readonly statusConfigJson?: string;
}

export interface ChatUpdates {
  readonly title?: string;
  readonly characterId?: string | null;
  readonly updatedAt?: number;
  readonly lastMessageAt?: number;
  readonly isArchived?: boolean;
  readonly userNameOverride?: string | null;
  readonly sortOrder?: number;
  readonly conversationMode?: ConversationMode;
  readonly statusConfigJson?: string;
}

export function createChat(options?: CreateChatOptions): Chat {
  const now: number = nowMillis();
  const id: string = options !== undefined && options.id !== undefined
    ? options.id
    : generateUuid();
  const characterId: string | undefined =
    options !== undefined && options.characterId !== undefined
      ? options.characterId
      : undefined;
  const title: string =
    options !== undefined && options.title !== undefined
      ? options.title
      : '';
  const createdAt: number =
    options !== undefined && options.createdAt !== undefined
      ? options.createdAt
      : now;
  const userNameOverride: string =
    options !== undefined && options.userNameOverride !== undefined
      ? options.userNameOverride
      : '';
  const sortOrder: number =
    options !== undefined && options.sortOrder !== undefined
      ? options.sortOrder
      : 0;
  const conversationMode: ConversationMode =
    options !== undefined && options.conversationMode !== undefined
      ? options.conversationMode
      : ConversationMode.Single;
  const statusConfigJson: string =
    options !== undefined && options.statusConfigJson !== undefined
      ? options.statusConfigJson
      : '';
  return {
    id: id,
    characterId: characterId,
    title: title,
    createdAt: createdAt,
    updatedAt: now,
    lastMessageAt: 0,
    isArchived: false,
    userNameOverride: userNameOverride,
    sortOrder: sortOrder,
    conversationMode: conversationMode,
    statusConfigJson: statusConfigJson
  };
}

export function updateChat(chat: Chat, updates: ChatUpdates): Chat {
  const characterId: string | undefined =
    updates.characterId !== undefined
      ? (updates.characterId === null ? undefined : updates.characterId)
      : chat.characterId;
  const title: string =
    updates.title !== undefined ? updates.title : chat.title;
  const updatedAt: number =
    updates.updatedAt !== undefined ? updates.updatedAt : nowMillis();
  const lastMessageAt: number =
    updates.lastMessageAt !== undefined ? updates.lastMessageAt : chat.lastMessageAt;
  const isArchived: boolean =
    updates.isArchived !== undefined ? updates.isArchived : chat.isArchived;
  // userNameOverride 支持 null(清空覆盖)与 undefined(不变)两种语义
  const userNameOverride: string =
    updates.userNameOverride !== undefined
      ? (updates.userNameOverride === null ? '' : updates.userNameOverride)
      : chat.userNameOverride;
  const sortOrder: number =
    updates.sortOrder !== undefined ? updates.sortOrder : chat.sortOrder;
  const conversationMode: ConversationMode =
    updates.conversationMode !== undefined ? updates.conversationMode : chat.conversationMode;
  const statusConfigJson: string =
    updates.statusConfigJson !== undefined ? updates.statusConfigJson : chat.statusConfigJson;
  return {
    id: chat.id,
    characterId: characterId,
    title: title,
    createdAt: chat.createdAt,
    updatedAt: updatedAt,
    lastMessageAt: lastMessageAt,
    isArchived: isArchived,
    userNameOverride: userNameOverride,
    sortOrder: sortOrder,
    conversationMode: conversationMode,
    statusConfigJson: statusConfigJson
  };
}
