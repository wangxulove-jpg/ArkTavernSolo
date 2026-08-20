/**
 * ConversationMode 对话模式
 *
 * G-DATA-1A 引入,用于区分单聊和多人聊天。
 * - Single: 单聊(普通助手对话或单一角色对话)
 * - Group: 多人聊天(2~8 个角色成员,共享同一 Chat)
 *
 * 持久化到 chats.conversation_mode 列(TEXT NOT NULL DEFAULT 'single')。
 * 旧数据迁移后统一视为 Single,不从 character_id 反推模式。
 */

export enum ConversationMode {
  Single = 'single',
  Group = 'group'
}

/**
 * 将字符串安全解析为 ConversationMode。
 * - 空字符串、null、未知值统一回退为 Single(向后兼容旧数据)
 * - 仅 'group' 显式返回 Group
 */
export function parseConversationMode(value: string | null): ConversationMode {
  if (value === ConversationMode.Group) {
    return ConversationMode.Group;
  }
  return ConversationMode.Single;
}

export function conversationModeToString(mode: ConversationMode): string {
  return mode;
}
