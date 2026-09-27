/**
 * ChatMessageSource 消息来源标签
 *
 * 用于在 PromptBuilder 输出中标识每条请求消息的来源,
 * HistoryTrimmer 据此判断哪些消息受保护,不可删除。
 *
 * 重要约束:
 * - source 字段为内部辅助标记,不会写入网络请求 JSON(OpenAIProvider 不识别)
 * - 不需要持久化(请求消息是临时构造的)
 * - 不依赖字符串前缀或正文内容判断
 */

export enum ChatMessageSource {
  /** 真实聊天历史(可裁剪) */
  Conversation = 'conversation',
  /** Character System Prompt(受保护) */
  CharacterPrompt = 'characterPrompt',
  /** Character firstMessage(受保护) */
  CharacterFirstMessage = 'characterFirstMessage',
  /** BeforeCharacter 世界书 System(受保护) */
  LorebookBefore = 'lorebookBefore',
  /** AfterCharacter 世界书 System(受保护) */
  LorebookAfter = 'lorebookAfter',
  /** 外部注入的合法 System 消息(受保护) */
  ExternalSystem = 'externalSystem',
  /** Prompt Preset System Prompt(受保护,不持久化) */
  PromptPresetSystem = 'promptPresetSystem',
  /** Character mes_example 对话示例(受保护,不进入聊天历史) */
  CharacterMesExample = 'characterMesExample',
  /** 长期记忆摘要(受保护,不进入聊天历史,分支独立) */
  MemorySummary = 'memorySummary',
  /** v12: 核心长期事实(受保护,不进入聊天历史) */
  MemoryCore = 'memoryCore',
  /** v46: 会话记忆(跨会话入口级摘要,受保护,不进入聊天历史) */
  MemorySession = 'memorySession',
  /** v12: 章节摘要(受保护,不进入聊天历史) */
  MemoryChapter = 'memoryChapter',
  /** v12: 近期滚动摘要(受保护,不进入聊天历史) */
  MemoryRolling = 'memoryRolling',
  /** v12: 旧数据迁移摘要(受保护,不进入聊天历史) */
  MemoryLegacy = 'memoryLegacy',
  /** Character Post-History Instructions(受保护,不进入聊天历史) */
  CharacterPostHistory = 'characterPostHistory',
  /** Persona 描述,角色定义之前(受保护,Phase 2A) */
  PersonaBefore = 'personaBefore',
  /** Persona 描述,角色定义之后(受保护,Phase 2A) */
  PersonaAfter = 'personaAfter',
  /** W5C2: 跨会话上下文(摘要+记忆,受保护,不进入聊天历史) */
  CrossSessionContext = 'crossSessionContext',
  /** 旁白叙述指令(senderType='narrator'的System消息,受保护) */
  NarratorInstruction = 'narratorInstruction',
  /** OnDemand 世界书深度注入(受保护,不进入聊天历史) */
  LorebookDepth = 'lorebookDepth',
  /** OnDemandPinned 固定世界书(受保护,记忆之后、对话之前,不进入聊天历史) */
  LorebookPinned = 'lorebookPinned',
  /** StickyOnDemand 粘滞条目全文(受保护;v47 起按锚点插进对话历史,不再固定挂尾部,不进入聊天历史) */
  LorebookSticky = 'lorebookSticky',
  /**
   * v47: 粘滞生效提醒(受保护,固定为请求尾部易变区)。
   * 只列"已加载且本轮仍命中"的条目名,不含内容;用来把注意力拉回已固定在
   * 对话历史里的粘滞条目,避免其随对话推进被淡忘。
   */
  StickyReminder = 'stickyReminder',
  /** v50: 角色卡前端界面交互记录(受保护,粘滞世界书之后、PostHistory 之前,不进入聊天历史) */
  FrontendInteraction = 'frontendInteraction',
  /**
   * 角色状态输出规则(稳定段)。
   * 只含格式要求与字段清单(字段名/说明/locked 标记),不含每轮变化的当前值,
   * 因此注入到稳定前缀(对话示例之后、记忆之前),作为缓存命中前缀的一部分。
   */
  StatusRule = 'statusRule',
  /**
   * 角色状态当前值(易变段)。
   * 每轮都可能变化(模型更新 / 卡片界面 setState / 一键重新生成),
   * 固定追加在请求最末,保证它前面的全部内容仍命中前缀缓存。
   */
  StatusValues = 'statusValues'
}
