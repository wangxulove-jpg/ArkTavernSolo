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
  /** v12: 章节摘要(受保护,不进入聊天历史) */
  MemoryChapter = 'memoryChapter',
  /** v12: 近期滚动摘要(受保护,不进入聊天历史) */
  MemoryRolling = 'memoryRolling',
  /** v12: 旧数据迁移摘要(受保护,不进入聊天历史) */
  MemoryLegacy = 'memoryLegacy',
  /** Character Post-History Instructions(受保护,不进入聊天历史) */
  CharacterPostHistory = 'characterPostHistory',
  /** W5C2: 跨会话上下文(摘要+记忆,受保护,不进入聊天历史) */
  CrossSessionContext = 'crossSessionContext'
}
