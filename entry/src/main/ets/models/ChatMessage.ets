/**
 * ChatMessage 聊天消息模型
 *
 * 定义通用的聊天消息结构。
 * 当前只是通用消息模型,不加入 Character、Lorebook、Swipe 等后续字段。
 *
 * 要求:
 * - 不加入 ArkUI 状态装饰器
 * - 不依赖 ViewModel
 * - 不使用 any
 */

import { ChatRole } from './ChatRole';
import { ChatMessageSource } from './ChatMessageSource';

/**
 * 消息发送者类型(v10 多人世界引入)。
 * - user: 用户消息
 * - character: 角色消息(senderCharacterId 必填)
 * - narrator: 旁白/系统描述
 */
export type MessageSenderType = 'user' | 'character' | 'narrator';

/**
 * 消息可见范围(v11 多人世界私聊引入)。
 * - public: 公开发言,当前所有在场角色可知
 * - private: 私下交谈,仅 recipientCharacterIds 中的角色可知
 * - narrator: 旁白动作,作为场景描述处理,知情范围由参与者/目击者判断
 */
export type MessageVisibility = 'public' | 'private' | 'narrator';

/**
 * Assistant 消息状态。
 */
export enum ChatMessageStatus {
  /** 流式生成中 */
  Streaming = 'streaming',
  /** 已完成 */
  Completed = 'completed',
  /** 已取消(用户停止) */
  Cancelled = 'cancelled',
  /** 生成失败 */
  Failed = 'failed'
}

/**
 * 聊天消息模型。
 */
export interface ChatMessage {
  /** 消息唯一标识 */
  readonly id: string;
  /** 消息角色 */
  readonly role: ChatRole;
  /** 消息内容 */
  readonly content: string;
  /** 创建时间(毫秒时间戳) */
  readonly createdAt: number;
  /** 更新时间(可选,毫秒时间戳) */
  readonly updatedAt?: number;
  /** 是否正在流式生成中(与 status 字段冗余,保留兼容) */
  readonly isStreaming?: boolean;
  /** 错误信息(生成失败时) */
  readonly errorMessage?: string;
  /** Assistant 消息状态 */
  readonly status?: ChatMessageStatus;
  /**
   * 消息来源(可选,内部辅助标记)。
   * - PromptBuilder 输出的临时消息会标注 source
   * - ChatService.messages 中的持久化消息无此字段(默认 Conversation)
   * - HistoryTrimmer 据此判断哪些消息可裁剪
   * - 不会写入网络请求 JSON(Provider 不识别)
   */
  readonly source?: ChatMessageSource;
  /**
   * 发送者类型(v10 多人世界引入)。
   * - 'user': 用户消息(默认,旧消息兼容)
   * - 'character': 角色消息,senderCharacterId 必填
   * - 'narrator': 旁白消息
   */
  readonly senderType?: MessageSenderType;
  /** 角色消息时填入 character.id;user/narrator 消息留空 */
  readonly senderCharacterId?: string;
  /** 所属场景 ID(v10 多人世界,可选) */
  readonly sceneId?: string;
  /** 生成批次 ID(同一轮多角色消息共享同一批次) */
  readonly generationBatchId?: string;
  /**
   * 消息可见范围(v11 私聊引入,可选,默认 'public')。
   * - 'public': 公开发言
   * - 'private': 私下交谈(仅 recipientCharacterIds 可见)
   * - 'narrator': 旁白动作
   */
  readonly visibility?: MessageVisibility;
  /**
   * 私聊目标角色 ID 列表(v11 私聊引入)。
   * 仅 visibility='private' 时有效;为空表示公开消息或旁白消息。
   */
  readonly recipientCharacterIds?: string[];
  /**
   * 参与者角色 ID 列表(v11 私聊引入)。
   * 包含用户(以 'user' 占位)与所有参与该消息的角色。
   * 用于记忆事件的 participantIds 字段。
   */
  readonly participantIds?: string[];
  /**
   * 目击者角色 ID 列表(v11 私聊引入)。
   * 用于旁白动作或私聊被目击的场景,默认为空。
   */
  readonly witnessIds?: string[];
  /**
   * 公开消息回复目标角色 ID 列表(v14 G-CONTROL-2A 引入)。
   *
   * 语义:本轮要求哪些角色回复(独立于私聊可见性)。
   * - undefined / 空数组:全员回复(默认)
   * - 非空数组:仅指定角色按 speakerOrder 回复
   *
   * 仅用于 visibility='public' 的用户消息。
   * 与 recipientCharacterIds(私聊可见性)语义完全分离。
   */
  readonly replyTargetCharacterIds?: string[];
}

/**
 * 创建聊天消息。
 * @param id 消息唯一标识
 * @param role 消息角色
 * @param content 消息内容
 * @param createdAt 创建时间(毫秒时间戳)
 * @returns ChatMessage 实例
 */
export function createChatMessage(
  id: string,
  role: ChatRole,
  content: string,
  createdAt: number
): ChatMessage {
  return {
    id: id,
    role: role,
    content: content,
    createdAt: createdAt
  };
}

/**
 * ChatMessage 字段覆盖接口(用于 mergeChatMessage)。
 * 所有字段可选,只指定需要修改的字段,其余从 base 复制。
 */
export interface ChatMessageOverrides {
  content?: string;
  updatedAt?: number;
  isStreaming?: boolean;
  errorMessage?: string;
  status?: ChatMessageStatus;
  source?: ChatMessageSource;
  senderType?: MessageSenderType;
  senderCharacterId?: string;
  sceneId?: string;
  generationBatchId?: string;
  visibility?: MessageVisibility;
  recipientCharacterIds?: string[];
  participantIds?: string[];
  witnessIds?: string[];
  replyTargetCharacterIds?: string[];
}

/**
 * 完整复制 ChatMessage(深拷贝数组字段)。
 * @param msg 源消息
 * @returns 新的 ChatMessage 对象,所有字段独立
 */
export function cloneChatMessage(msg: ChatMessage): ChatMessage {
  return {
    id: msg.id,
    role: msg.role,
    content: msg.content,
    createdAt: msg.createdAt,
    updatedAt: msg.updatedAt,
    isStreaming: msg.isStreaming,
    errorMessage: msg.errorMessage,
    status: msg.status,
    source: msg.source,
    senderType: msg.senderType,
    senderCharacterId: msg.senderCharacterId,
    sceneId: msg.sceneId,
    generationBatchId: msg.generationBatchId,
    visibility: msg.visibility,
    recipientCharacterIds: msg.recipientCharacterIds !== undefined
      ? msg.recipientCharacterIds.slice() : undefined,
    participantIds: msg.participantIds !== undefined
      ? msg.participantIds.slice() : undefined,
    witnessIds: msg.witnessIds !== undefined
      ? msg.witnessIds.slice() : undefined,
    replyTargetCharacterIds: msg.replyTargetCharacterIds !== undefined
      ? msg.replyTargetCharacterIds.slice() : undefined
  };
}

/**
 * 基于 base 创建新 ChatMessage,应用 overrides 覆盖指定字段。
 * 未在 overrides 中指定的字段从 base 完整复制(包括数组字段的深拷贝)。
 * @param base 基础消息
 * @param overrides 字段覆盖
 * @returns 新的 ChatMessage 对象
 */
export function mergeChatMessage(
  base: ChatMessage,
  overrides: ChatMessageOverrides
): ChatMessage {
  return {
    id: base.id,
    role: base.role,
    content: overrides.content !== undefined ? overrides.content : base.content,
    createdAt: base.createdAt,
    updatedAt: overrides.updatedAt !== undefined ? overrides.updatedAt : base.updatedAt,
    isStreaming: overrides.isStreaming !== undefined ? overrides.isStreaming : base.isStreaming,
    errorMessage: overrides.errorMessage !== undefined ? overrides.errorMessage : base.errorMessage,
    status: overrides.status !== undefined ? overrides.status : base.status,
    source: overrides.source !== undefined ? overrides.source : base.source,
    senderType: overrides.senderType !== undefined ? overrides.senderType : base.senderType,
    senderCharacterId: overrides.senderCharacterId !== undefined
      ? overrides.senderCharacterId : base.senderCharacterId,
    sceneId: overrides.sceneId !== undefined ? overrides.sceneId : base.sceneId,
    generationBatchId: overrides.generationBatchId !== undefined
      ? overrides.generationBatchId : base.generationBatchId,
    visibility: overrides.visibility !== undefined ? overrides.visibility : base.visibility,
    recipientCharacterIds: overrides.recipientCharacterIds !== undefined
      ? overrides.recipientCharacterIds.slice()
      : (base.recipientCharacterIds !== undefined ? base.recipientCharacterIds.slice() : undefined),
    participantIds: overrides.participantIds !== undefined
      ? overrides.participantIds.slice()
      : (base.participantIds !== undefined ? base.participantIds.slice() : undefined),
    witnessIds: overrides.witnessIds !== undefined
      ? overrides.witnessIds.slice()
      : (base.witnessIds !== undefined ? base.witnessIds.slice() : undefined),
    replyTargetCharacterIds: overrides.replyTargetCharacterIds !== undefined
      ? overrides.replyTargetCharacterIds.slice()
      : (base.replyTargetCharacterIds !== undefined ? base.replyTargetCharacterIds.slice() : undefined)
  };
}
