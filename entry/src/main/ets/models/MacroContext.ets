/**
 * MacroContext 宏替换上下文
 *
 * 纯数据模型,提供宏替换所需的上下文信息。
 * 不依赖 ArkUI,不读取 Preferences,不访问页面或系统时间。
 *
 * 支持的宏字段(均可选,为空时对应宏保持原样):
 * - characterName / userName:基础宏
 * - description / personality / scenario / mesExample:角色字段宏
 * - lastMessage:最后一条消息内容宏
 * - originalContent:{{original}} 宏替换内容
 */

/**
 * 宏替换上下文。
 */
export interface MacroContext {
  /** 当前角色名称(为空时角色宏保持原样) */
  readonly characterName: string;
  /** 当前用户名称(为空时用户宏保持原样) */
  readonly userName: string;
  /** 角色描述(供 {{description}} 使用) */
  readonly description?: string;
  /** 角色性格(供 {{personality}} 使用) */
  readonly personality?: string;
  /** 角色场景(供 {{scenario}} 使用) */
  readonly scenario?: string;
  /** 对话示例(供 {{mes_example}} 使用) */
  readonly mesExample?: string;
  /** 最后一条消息内容(供 {{lastMessage}} 使用) */
  readonly lastMessage?: string;
  /** 原始内容(供 {{original}} 使用,通常为默认组合的 System 内容) */
  readonly originalContent?: string;
}

/**
 * 创建宏替换上下文(基础版本,仅包含角色名和用户名)。
 */
export function createMacroContext(characterName: string, userName: string): MacroContext {
  return {
    characterName: characterName,
    userName: userName
  };
}

/**
 * 宏替换上下文构建器(链式)。
 * 用于在 PromptBuilder 中按需附加可选字段。
 */
export class MacroContextBuilder {
  private characterName: string;
  private userName: string;
  private descriptionVal?: string;
  private personalityVal?: string;
  private scenarioVal?: string;
  private mesExampleVal?: string;
  private lastMessageVal?: string;
  private originalContentVal?: string;

  constructor(characterName: string, userName: string) {
    this.characterName = characterName;
    this.userName = userName;
  }

  withDescription(value: string): MacroContextBuilder {
    this.descriptionVal = value;
    return this;
  }

  withPersonality(value: string): MacroContextBuilder {
    this.personalityVal = value;
    return this;
  }

  withScenario(value: string): MacroContextBuilder {
    this.scenarioVal = value;
    return this;
  }

  withMesExample(value: string): MacroContextBuilder {
    this.mesExampleVal = value;
    return this;
  }

  withLastMessage(value: string): MacroContextBuilder {
    this.lastMessageVal = value;
    return this;
  }

  withOriginalContent(value: string): MacroContextBuilder {
    this.originalContentVal = value;
    return this;
  }

  build(): MacroContext {
    return {
      characterName: this.characterName,
      userName: this.userName,
      description: this.descriptionVal,
      personality: this.personalityVal,
      scenario: this.scenarioVal,
      mesExample: this.mesExampleVal,
      lastMessage: this.lastMessageVal,
      originalContent: this.originalContentVal
    };
  }
}
