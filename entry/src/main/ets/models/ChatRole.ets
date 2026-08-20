/**
 * ChatRole 聊天角色枚举
 *
 * 定义消息的角色类型,与 OpenAI Chat Completions 兼容。
 * 本阶段不实现工具调用(Tool 角色),但预留枚举位。
 */

/**
 * 聊天消息角色类型枚举。
 */
export enum ChatRole {
  /** 系统消息(设定 AI 行为) */
  System = 'system',
  /** 用户消息 */
  User = 'user',
  /** AI 助手回复 */
  Assistant = 'assistant'
}
