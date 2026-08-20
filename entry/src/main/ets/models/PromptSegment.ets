/**
 * 提示词段模型
 *
 * 定义 Prompt 构建中各段的顺序和内容。
 * 不依赖 ArkUI,纯数据模型。
 *
 * 固定顺序:
 * PromptPreset → BeforeCharacter → Character → AfterCharacter
 *   → DialogueExamples → MemoryCore → MemoryChapter → MemoryRolling → MemoryLegacy
 *   → Conversation → PostHistory
 *
 * v12 多层记忆:
 * - MemoryCore:核心长期事实(最高优先级)
 * - MemoryChapter:章节摘要(按时间顺序)
 * - MemoryRolling:近期滚动摘要
 * - MemoryLegacy:旧数据迁移摘要
 * - MemorySummary:旧版单段摘要(兼容)
 */

import { ChatRole } from './ChatRole';
import { ChatMessageSource } from './ChatMessageSource';

/**
 * 提示词段位置枚举。
 * 顺序即构建时的排列顺序。
 */
export enum PromptSegmentPosition {
  BeforeCharacter = 'BeforeCharacter',
  PromptPreset = 'PromptPreset',
  Character = 'Character',
  AfterCharacter = 'AfterCharacter',
  /** 对话示例(mes_example),位于聊天历史之前 */
  DialogueExamples = 'DialogueExamples',
  /** v12: 核心长期事实(最高优先级记忆) */
  MemoryCore = 'MemoryCore',
  /** v12: 章节摘要(按时间顺序) */
  MemoryChapter = 'MemoryChapter',
  /** v12: 近期滚动摘要 */
  MemoryRolling = 'MemoryRolling',
  /** v12: 旧数据迁移摘要(只读) */
  MemoryLegacy = 'MemoryLegacy',
  /** 旧版单段长期记忆摘要(兼容,新代码应使用 MemoryCore/Chapter/Rolling) */
  MemorySummary = 'MemorySummary',
  /** 聊天历史(Conversation) */
  Conversation = 'Conversation',
  /** Post-History Instructions,位于聊天历史之后 */
  PostHistory = 'PostHistory'
}

/**
 * 提示词段。
 * 每个段包含位置、角色、内容和优先级(用于同位置排序)。
 */
export interface PromptSegment {
  readonly id: string;
  readonly position: PromptSegmentPosition;
  readonly role: ChatRole;
  readonly content: string;
  /** 优先级,数值越大越靠前。同位置内按 priority 降序排列 */
  readonly priority: number;
  /** 消息来源标签(用于 HistoryTrimmer 识别可裁剪与受保护消息) */
  readonly source: ChatMessageSource;
}

/**
 * 创建提示词段。
 */
export function createPromptSegment(
  id: string,
  position: PromptSegmentPosition,
  role: ChatRole,
  content: string,
  priority: number = 0,
  source: ChatMessageSource = ChatMessageSource.Conversation
): PromptSegment {
  return {
    id: id,
    position: position,
    role: role,
    content: content,
    priority: priority,
    source: source
  };
}

/**
 * 位置排序权重,用于 segments 排序。
 */
const POSITION_ORDER: Record<string, number> = {
  'PromptPreset': 0,
  'BeforeCharacter': 1,
  'Character': 2,
  'AfterCharacter': 3,
  'DialogueExamples': 4,
  'MemoryCore': 5,
  'MemoryChapter': 6,
  'MemoryRolling': 7,
  'MemoryLegacy': 8,
  'MemorySummary': 9,
  'Conversation': 10,
  'PostHistory': 11
};

/**
 * 按 position → priority 降序排列 segments。
 * 返回新数组,不修改原数组。
 */
export function sortSegments(segments: PromptSegment[]): PromptSegment[] {
  const sorted: PromptSegment[] = [...segments];
  sorted.sort((a: PromptSegment, b: PromptSegment): number => {
    const posOrderA: number = POSITION_ORDER[a.position] ?? 99;
    const posOrderB: number = POSITION_ORDER[b.position] ?? 99;
    if (posOrderA !== posOrderB) {
      return posOrderA - posOrderB;
    }
    // 同位置:priority 降序
    return b.priority - a.priority;
  });
  return sorted;
}
