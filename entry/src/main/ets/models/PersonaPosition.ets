/**
 * PersonaPosition 用户身份注入位置枚举
 *
 * 定义 Persona 描述注入到 Prompt 的位置:
 * - Disabled: 不注入描述
 * - BeforeCharacter: 角色定义之前(世界书之后)
 * - AfterCharacter: 角色定义之后(对话示例之前)
 * - AtDepth: 聊天历史指定深度
 *
 * 不依赖 ArkUI,可用于服务层和持久化层。
 */

export enum PersonaPosition {
  /** 不注入描述 */
  Disabled = 0,
  /** 角色定义之前 */
  BeforeCharacter = 1,
  /** 角色定义之后 */
  AfterCharacter = 2,
  /** 聊天历史指定深度 */
  AtDepth = 3
}

/**
 * 将 PersonaPosition 从数据库整数值解析为枚举。
 * 非法值抛 DatabaseError。
 */
export function parsePersonaPosition(value: number): PersonaPosition {
  if (value === PersonaPosition.Disabled) return PersonaPosition.Disabled;
  if (value === PersonaPosition.BeforeCharacter) return PersonaPosition.BeforeCharacter;
  if (value === PersonaPosition.AfterCharacter) return PersonaPosition.AfterCharacter;
  if (value === PersonaPosition.AtDepth) return PersonaPosition.AtDepth;
  return PersonaPosition.BeforeCharacter;
}

/**
 * 将 PersonaPosition 转为数据库整数值。
 */
export function personaPositionToInt(position: PersonaPosition): number {
  return position;
}
