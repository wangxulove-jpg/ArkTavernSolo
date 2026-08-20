/**
 * Repository 映射工具
 *
 * 职责:
 * - 枚举字符串与 ChatRole / ChatMessageStatus / ChatMessageSource 之间的显式解析
 * - boolean 与 INTEGER 0/1 的安全转换
 * - 时间戳和 sequence 的校验
 * - 判断 source 是否可持久化
 *
 * 规则:
 * - 禁止 `as ChatRole` 直接断言
 * - 非法枚举抛 DatabaseError(InvalidData)
 * - 不修改输入对象
 */

import { ChatRole } from '../models/ChatRole';
import { ChatMessageStatus, MessageSenderType, MessageVisibility } from '../models/ChatMessage';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { DatabaseError } from '../models/DatabaseError';

export function parseChatRole(value: string): ChatRole {
  if (value === ChatRole.System) return ChatRole.System;
  if (value === ChatRole.User) return ChatRole.User;
  if (value === ChatRole.Assistant) return ChatRole.Assistant;
  throw DatabaseError.invalidData(`unknown role`);
}

export function chatRoleToString(role: ChatRole): string {
  return role;
}

export function parseChatMessageStatus(value: string): ChatMessageStatus {
  if (value === ChatMessageStatus.Streaming) return ChatMessageStatus.Streaming;
  if (value === ChatMessageStatus.Completed) return ChatMessageStatus.Completed;
  if (value === ChatMessageStatus.Cancelled) return ChatMessageStatus.Cancelled;
  if (value === ChatMessageStatus.Failed) return ChatMessageStatus.Failed;
  throw DatabaseError.invalidData(`unknown status`);
}

export function chatMessageStatusToString(status: ChatMessageStatus): string {
  return status;
}

export function parseChatMessageSource(
  value: string | null
): ChatMessageSource | undefined {
  if (value === null || value === '') return undefined;
  if (value === ChatMessageSource.Conversation) return ChatMessageSource.Conversation;
  if (value === ChatMessageSource.CharacterPrompt) return ChatMessageSource.CharacterPrompt;
  if (value === ChatMessageSource.CharacterFirstMessage) return ChatMessageSource.CharacterFirstMessage;
  if (value === ChatMessageSource.LorebookBefore) return ChatMessageSource.LorebookBefore;
  if (value === ChatMessageSource.LorebookAfter) return ChatMessageSource.LorebookAfter;
  if (value === ChatMessageSource.ExternalSystem) return ChatMessageSource.ExternalSystem;
  throw DatabaseError.invalidData(`unknown source`);
}

export function chatMessageSourceToString(
  source: ChatMessageSource | undefined
): string | null {
  if (source === undefined) return null;
  return source;
}

/**
 * 解析消息发送者类型(v10 多人世界引入)。
 * - 旧消息可能存在 senderType 为空或列不存在,统一回退为 'user'
 * - 'assistant' / 'system' 视为兼容旧角色:assistant → 'character',system → 'narrator'
 *   (仅在历史数据迁移未覆盖时出现,新写入必须使用 'user'/'character'/'narrator')
 */
export function parseMessageSenderType(
  value: string | null
): MessageSenderType {
  if (value === null || value === '') return 'user';
  if (value === 'user') return 'user';
  if (value === 'character') return 'character';
  if (value === 'narrator') return 'narrator';
  if (value === 'assistant') return 'character';
  if (value === 'system') return 'narrator';
  throw DatabaseError.invalidData(`unknown sender_type: ${value}`);
}

export function messageSenderTypeToString(senderType: MessageSenderType): string {
  return senderType;
}

/**
 * 解析消息可见范围(v11 私聊引入)。
 * - 旧消息可能存在 visibility 为空或列不存在,统一回退为 'public'
 */
export function parseMessageVisibility(value: string | null): MessageVisibility {
  if (value === null || value === '') return 'public';
  if (value === 'public') return 'public';
  if (value === 'private') return 'private';
  if (value === 'narrator') return 'narrator';
  throw DatabaseError.invalidData(`unknown visibility: ${value}`);
}

export function messageVisibilityToString(visibility: MessageVisibility): string {
  return visibility;
}

export function booleanToInt(value: boolean): number {
  return value ? 1 : 0;
}

export function intToBoolean(value: number): boolean {
  if (value === 0) return false;
  if (value === 1) return true;
  throw DatabaseError.invalidData(`invalid boolean value: ${value}`);
}

export function isValidTimestamp(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

export function isValidSequence(value: number): boolean {
  return Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

export function isPersistableSource(
  source: ChatMessageSource | undefined
): boolean {
  if (source === undefined) return true;
  return source === ChatMessageSource.Conversation
    || source === ChatMessageSource.CharacterFirstMessage
    || source === ChatMessageSource.ExternalSystem;
}

export function resolveIsStreaming(
  status: ChatMessageStatus,
  isStreaming: boolean | undefined
): number {
  const expected: boolean = status === ChatMessageStatus.Streaming;
  if (isStreaming !== undefined && isStreaming !== expected) {
    throw DatabaseError.invalidData('status and isStreaming contradict');
  }
  return expected ? 1 : 0;
}

export function extractCauseMessage(err: Object): string {
  if (err === null || err === undefined) {
    return '';
  }
  if (typeof err === 'object') {
    const obj: Object = err as Object;
    const code: Object | undefined = Reflect.has(obj, 'code')
      ? (obj as Record<string, Object>).code
      : undefined;
    const msg: Object | undefined = Reflect.has(obj, 'message')
      ? (obj as Record<string, Object>).message
      : undefined;
    if (typeof code === 'number' && typeof msg === 'string') {
      return `code=${code} message=${msg}`;
    }
    if (typeof msg === 'string') {
      return msg;
    }
  }
  return 'unknown error';
}

export function isConstraintViolation(err: Object): boolean {
  const cause: string = extractCauseMessage(err);
  const lower: string = cause.toLowerCase();
  return lower.indexOf('unique') >= 0
    || lower.indexOf('constraint') >= 0
    || lower.indexOf('primary key') >= 0;
}
