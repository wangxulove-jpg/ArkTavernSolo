/**
 * ChatMemory 分支感知长期记忆模型
 *
 * 表示某个 Conversation Branch 上一段消息范围的摘要。
 * - 绑定到具体 Branch(branchId),不同 Branch 的记忆独立
 * - 通过 startPosition/endPosition 记录覆盖范围
 * - inheritedFromMemoryId 标记从祖先 Branch 继承而来(共享,不复制)
 *
 * v12 多层记忆扩展:
 * - memoryType: 记忆类型(core/chapter/rolling/legacy)
 * - title: 记忆标题(章节标题或核心记忆标签)
 * - detail: 详细内容(比 summary 更丰富)
 * - importance: 重要度(0-100,用于注入优先级排序)
 * - keywordsJson: 关键词 JSON 数组(用于相关记忆匹配)
 * - sourceHash: 源内容哈希(用于检测源消息变化)
 * - invalidated: 是否已失效(编辑/删除/Swipe 切换后标记,不再注入 Prompt)
 *
 * 设计约束:
 * - 不存储消息正文,只存储 summary / detail
 * - 范围 [startPosition, endPosition] 闭区间
 * - 同一 Branch 可有多条 Memory(覆盖不同范围/不同类型)
 * - 删除 Branch 时,继承来的共享祖先 Memory 不得被误删
 * - 失效记忆(invalidated=true)不注入 Prompt,但保留数据以便追溯
 */

/** 记忆类型枚举(v12 引入) */
export type MemoryType = 'core' | 'chapter' | 'rolling' | 'legacy';

/** 默认记忆类型:旧数据迁移后为 'rolling' */
export const DEFAULT_MEMORY_TYPE: MemoryType = 'rolling';

/**
 * 单条长期记忆。
 */
export interface ChatMemory {
  /** 主键 ID(UUID) */
  readonly id: string;
  /** 所属 Chat ID */
  readonly chatId: string;
  /** 所属 Branch ID(记忆绑定到 Branch) */
  readonly branchId: string;
  /** 起始消息 ID(范围起点,闭区间) */
  readonly startMessageId: string;
  /** 结束消息 ID(范围终点,闭区间) */
  readonly endMessageId: string;
  /** 起始 position(闭区间) */
  readonly startPosition: number;
  /** 结束 position(闭区间) */
  readonly endPosition: number;
  /** 摘要文本(简短摘要,兼容旧字段) */
  summary: string;
  /** 创建时间(ms) */
  readonly createdAt: number;
  /** 最后更新时间(ms) */
  updatedAt: number;
  /** 是否启用(禁用时不注入 Prompt) */
  enabled: boolean;
  /** 摘要版本号(每次更新 +1) */
  summaryVersion: number;
  /**
   * 继承自祖先 Branch 的 Memory ID。
   * - undefined:本 Branch 自产的记忆,删除 Branch 时应清理
   * - 非 undefined:从祖先继承,删除 Branch 时不得删除该 Memory(由原 Branch 持有)
   */
  readonly inheritedFromMemoryId?: string;
  /** v12: 记忆类型(core/chapter/rolling/legacy),默认 'rolling' */
  memoryType: MemoryType;
  /** v12: 记忆标题(章节标题或核心记忆标签),默认 '' */
  title: string;
  /** v12: 详细内容(比 summary 更丰富的章节摘要),默认 '' */
  detail: string;
  /** v12: 重要度(0-100,用于注入优先级排序),默认 0 */
  importance: number;
  /** v12: 关键词 JSON 数组字符串(用于相关记忆匹配),默认 '[]' */
  keywordsJson: string;
  /** v12: 源内容哈希(用于检测源消息变化),默认 '' */
  sourceHash: string;
  /** v12: 是否已失效(编辑/删除/Swipe 切换后标记,不再注入 Prompt),默认 false */
  invalidated: boolean;
}

/**
 * Memory 摘要要项(用于总结提示词)
 */
export interface MemorySummaryPoints {
  /** 人物关系 */
  relationships: boolean;
  /** 重要事实 */
  facts: boolean;
  /** 已发生事件 */
  events: boolean;
  /** 用户偏好 */
  userPreferences: boolean;
  /** 承诺和目标 */
  commitments: boolean;
  /** 未解决事项 */
  openIssues: boolean;
  /** 角色当前情绪与状态 */
  characterState: boolean;
}

/**
 * Memory 触发条件(满足任一即触发增量总结)
 */
export interface MemoryTriggerConfig {
  /** 未总结消息数达到阈值 */
  messageCountThreshold: number;
  /** 未总结文本字符数达到阈值 */
  charLengthThreshold: number;
  /** 是否启用上下文预算检查 */
  enableContextBudgetCheck: boolean;
}

/** 默认触发配置:6 条消息或 4000 字符 */
export const DEFAULT_MEMORY_TRIGGER: MemoryTriggerConfig = {
  messageCountThreshold: 6,
  charLengthThreshold: 4000,
  enableContextBudgetCheck: true
};

/** 默认 Memory 摘要要项(全选) */
export const DEFAULT_SUMMARY_POINTS: MemorySummaryPoints = {
  relationships: true,
  facts: true,
  events: true,
  userPreferences: true,
  commitments: true,
  openIssues: true,
  characterState: true
};

/**
 * 工厂函数:创建新的 ChatMemory。
 * v12 新字段使用默认值,可通过 withMemoryType / withDetail 等单独设置。
 */
export function createChatMemory(
  id: string,
  chatId: string,
  branchId: string,
  startMessageId: string,
  endMessageId: string,
  startPosition: number,
  endPosition: number,
  summary: string,
  now: number,
  inheritedFromMemoryId?: string
): ChatMemory {
  return {
    id,
    chatId,
    branchId,
    startMessageId,
    endMessageId,
    startPosition,
    endPosition,
    summary,
    createdAt: now,
    updatedAt: now,
    enabled: true,
    summaryVersion: 1,
    inheritedFromMemoryId,
    memoryType: DEFAULT_MEMORY_TYPE,
    title: '',
    detail: '',
    importance: 0,
    keywordsJson: '[]',
    sourceHash: '',
    invalidated: false
  };
}

/**
 * 不可变更新:summary 字段。
 */
export function withUpdatedSummary(memory: ChatMemory, newSummary: string, now: number): ChatMemory {
  return {
    id: memory.id,
    chatId: memory.chatId,
    branchId: memory.branchId,
    startMessageId: memory.startMessageId,
    endMessageId: memory.endMessageId,
    startPosition: memory.startPosition,
    endPosition: memory.endPosition,
    summary: newSummary,
    createdAt: memory.createdAt,
    updatedAt: now,
    enabled: memory.enabled,
    summaryVersion: memory.summaryVersion + 1,
    inheritedFromMemoryId: memory.inheritedFromMemoryId,
    memoryType: memory.memoryType,
    title: memory.title,
    detail: memory.detail,
    importance: memory.importance,
    keywordsJson: memory.keywordsJson,
    sourceHash: memory.sourceHash,
    invalidated: memory.invalidated
  };
}

/**
 * 不可变更新:endPosition / endMessageId(扩展范围)。
 */
export function withExtendedRange(
  memory: ChatMemory,
  newEndMessageId: string,
  newEndPosition: number,
  newSummary: string,
  now: number
): ChatMemory {
  return {
    id: memory.id,
    chatId: memory.chatId,
    branchId: memory.branchId,
    startMessageId: memory.startMessageId,
    endMessageId: newEndMessageId,
    startPosition: memory.startPosition,
    endPosition: newEndPosition,
    summary: newSummary,
    createdAt: memory.createdAt,
    updatedAt: now,
    enabled: memory.enabled,
    summaryVersion: memory.summaryVersion + 1,
    inheritedFromMemoryId: memory.inheritedFromMemoryId,
    memoryType: memory.memoryType,
    title: memory.title,
    detail: memory.detail,
    importance: memory.importance,
    keywordsJson: memory.keywordsJson,
    sourceHash: memory.sourceHash,
    invalidated: memory.invalidated
  };
}

/**
 * 不可变更新:enabled 字段。
 */
export function withEnabled(memory: ChatMemory, enabled: boolean, now: number): ChatMemory {
  return {
    id: memory.id,
    chatId: memory.chatId,
    branchId: memory.branchId,
    startMessageId: memory.startMessageId,
    endMessageId: memory.endMessageId,
    startPosition: memory.startPosition,
    endPosition: memory.endPosition,
    summary: memory.summary,
    createdAt: memory.createdAt,
    updatedAt: now,
    enabled,
    summaryVersion: memory.summaryVersion,
    inheritedFromMemoryId: memory.inheritedFromMemoryId,
    memoryType: memory.memoryType,
    title: memory.title,
    detail: memory.detail,
    importance: memory.importance,
    keywordsJson: memory.keywordsJson,
    sourceHash: memory.sourceHash,
    invalidated: memory.invalidated
  };
}

/**
 * v12 不可变更新:memoryType 字段。
 */
export function withMemoryType(memory: ChatMemory, memoryType: MemoryType, now: number): ChatMemory {
  return {
    id: memory.id,
    chatId: memory.chatId,
    branchId: memory.branchId,
    startMessageId: memory.startMessageId,
    endMessageId: memory.endMessageId,
    startPosition: memory.startPosition,
    endPosition: memory.endPosition,
    summary: memory.summary,
    createdAt: memory.createdAt,
    updatedAt: now,
    enabled: memory.enabled,
    summaryVersion: memory.summaryVersion,
    inheritedFromMemoryId: memory.inheritedFromMemoryId,
    memoryType,
    title: memory.title,
    detail: memory.detail,
    importance: memory.importance,
    keywordsJson: memory.keywordsJson,
    sourceHash: memory.sourceHash,
    invalidated: memory.invalidated
  };
}

/**
 * v12 不可变更新:detail 字段(同时更新 updatedAt)。
 */
export function withDetail(memory: ChatMemory, detail: string, now: number): ChatMemory {
  return {
    id: memory.id,
    chatId: memory.chatId,
    branchId: memory.branchId,
    startMessageId: memory.startMessageId,
    endMessageId: memory.endMessageId,
    startPosition: memory.startPosition,
    endPosition: memory.endPosition,
    summary: memory.summary,
    createdAt: memory.createdAt,
    updatedAt: now,
    enabled: memory.enabled,
    summaryVersion: memory.summaryVersion,
    inheritedFromMemoryId: memory.inheritedFromMemoryId,
    memoryType: memory.memoryType,
    title: memory.title,
    detail,
    importance: memory.importance,
    keywordsJson: memory.keywordsJson,
    sourceHash: memory.sourceHash,
    invalidated: memory.invalidated
  };
}

/**
 * v12 不可变更新:title 字段。
 */
export function withTitle(memory: ChatMemory, title: string, now: number): ChatMemory {
  return {
    id: memory.id,
    chatId: memory.chatId,
    branchId: memory.branchId,
    startMessageId: memory.startMessageId,
    endMessageId: memory.endMessageId,
    startPosition: memory.startPosition,
    endPosition: memory.endPosition,
    summary: memory.summary,
    createdAt: memory.createdAt,
    updatedAt: now,
    enabled: memory.enabled,
    summaryVersion: memory.summaryVersion,
    inheritedFromMemoryId: memory.inheritedFromMemoryId,
    memoryType: memory.memoryType,
    title,
    detail: memory.detail,
    importance: memory.importance,
    keywordsJson: memory.keywordsJson,
    sourceHash: memory.sourceHash,
    invalidated: memory.invalidated
  };
}

/**
 * v12 不可变更新:invalidated 字段(标记失效/恢复)。
 */
export function withInvalidated(memory: ChatMemory, invalidated: boolean, now: number): ChatMemory {
  return {
    id: memory.id,
    chatId: memory.chatId,
    branchId: memory.branchId,
    startMessageId: memory.startMessageId,
    endMessageId: memory.endMessageId,
    startPosition: memory.startPosition,
    endPosition: memory.endPosition,
    summary: memory.summary,
    createdAt: memory.createdAt,
    updatedAt: now,
    enabled: memory.enabled,
    summaryVersion: memory.summaryVersion,
    inheritedFromMemoryId: memory.inheritedFromMemoryId,
    memoryType: memory.memoryType,
    title: memory.title,
    detail: memory.detail,
    importance: memory.importance,
    keywordsJson: memory.keywordsJson,
    sourceHash: memory.sourceHash,
    invalidated
  };
}

/**
 * v12 不可变更新:多字段批量更新(用于章节生成时一次性设置 title/detail/keywords/importance 等)。
 */
export function withMemoryMetadata(
  memory: ChatMemory,
  updates: MemoryMetadataUpdates,
  now: number
): ChatMemory {
  return {
    id: memory.id,
    chatId: memory.chatId,
    branchId: memory.branchId,
    startMessageId: memory.startMessageId,
    endMessageId: memory.endMessageId,
    startPosition: memory.startPosition,
    endPosition: memory.endPosition,
    summary: memory.summary,
    createdAt: memory.createdAt,
    updatedAt: now,
    enabled: memory.enabled,
    summaryVersion: memory.summaryVersion,
    inheritedFromMemoryId: memory.inheritedFromMemoryId,
    memoryType: updates.memoryType !== undefined ? updates.memoryType : memory.memoryType,
    title: updates.title !== undefined ? updates.title : memory.title,
    detail: updates.detail !== undefined ? updates.detail : memory.detail,
    importance: updates.importance !== undefined ? updates.importance : memory.importance,
    keywordsJson: updates.keywordsJson !== undefined ? updates.keywordsJson : memory.keywordsJson,
    sourceHash: updates.sourceHash !== undefined ? updates.sourceHash : memory.sourceHash,
    invalidated: memory.invalidated
  };
}

/** withMemoryMetadata 的更新参数 */
export interface MemoryMetadataUpdates {
  title?: string;
  detail?: string;
  importance?: number;
  keywordsJson?: string;
  sourceHash?: string;
  memoryType?: MemoryType;
}
