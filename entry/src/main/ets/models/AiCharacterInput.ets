/**
 * AiCharacterInput AI 角色卡创意输入模型
 *
 * 用户在"AI 制作角色卡"页面填写的创意输入。
 * 所有字段为 readonly,通过工厂函数创建。
 *
 * 设计原则:
 * - 不包含 API Key / Authorization / Header
 * - 不依赖 ArkUI
 * - 不使用 any
 * - 字段全部为基本类型或基本类型数组,便于序列化与日志脱敏
 */

/**
 * AI 角色卡创意输入。
 *
 * 用户只需填写 conceptDescription 即可生成,其余字段均为可选辅助信息。
 * 所有字符串字段允许为空字符串,由生成服务负责处理。
 */
export interface AiCharacterInput {
  /** 角色创意描述(必填,用户主要输入) */
  readonly conceptDescription: string;
  /** 角色名称(可留空让 AI 生成) */
  readonly name: string;
  /** 世界观或故事背景 */
  readonly backstory: string;
  /** 性格关键词(逗号或换行分隔) */
  readonly personalityKeywords: string;
  /** 角色与用户的关系 */
  readonly relationshipWithUser: string;
  /** 对话风格 */
  readonly speechStyle: string;
  /** 是否生成角色专属世界书 */
  readonly generateCharacterBook: boolean;
  /** 是否生成多个开场白 */
  readonly generateMultipleGreetings: boolean;
  /** 是否生成对话示例 */
  readonly generateMesExample: boolean;
}

/**
 * 默认创意输入(全部字段为空或默认值)。
 */
export function createEmptyAiCharacterInput(): AiCharacterInput {
  return {
    conceptDescription: '',
    name: '',
    backstory: '',
    personalityKeywords: '',
    relationshipWithUser: '',
    speechStyle: '',
    generateCharacterBook: false,
    generateMultipleGreetings: false,
    generateMesExample: true
  };
}

/**
 * 校验创意输入是否可发起生成。
 * 只要求 conceptDescription 非空(去除空白后)。
 * @param input 创意输入
 * @returns 错误信息,null 表示通过
 */
export function validateAiCharacterInput(input: AiCharacterInput): string | null {
  if (input.conceptDescription.trim().length === 0) {
    return '请填写角色创意描述';
  }
  return null;
}
