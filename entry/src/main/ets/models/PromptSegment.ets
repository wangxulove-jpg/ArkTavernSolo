/**
 * 提示词段模型
 *
 * 定义 Prompt 构建中各段的顺序和内容。
 * 不依赖 ArkUI,纯数据模型。
 *
 * 固定顺序:
 * PromptPreset → BeforeCharacter → Character → AfterCharacter
 *   → DialogueExamples → StatusRule(稳定状态规则)
 *   → MemoryCore → LorebookPinned(OnDemandPinned世界书)
 *   → MemorySession → MemoryChapter → MemoryRolling → MemoryLegacy
 *   → Conversation → FrontendInteraction(v50 前端交互记录) → PostHistory
 *   → (追加在请求最末) StickyReminder 粘滞生效提醒 → StatusValues 状态当前值
 *
 * 不在该列表内的段:
 * - StickyOnDemand 粘滞世界书全文:由 ChatService 按锚点插进 Conversation 段内部
 *   (首次命中位置),不再固定挂在对话之后。
 *
 * 缓存友好约定:
 * - 变化频率越低的内容越靠前;每轮都可能变的「状态当前值」固定放最后一条,
 *   使其之前的所有内容(含整段对话历史)始终处于稳定前缀中。
 *
 * v12 多层记忆:
 * - MemoryCore:核心长期事实(最高优先级)
 * - LorebookPinned:OnDemandPinned 固定世界书(核心记忆之后、会话记忆之前)
 * - MemorySession:会话记忆(跨会话入口级摘要)
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
  PromptPreset = 'PromptPreset',
  BeforeCharacter = 'BeforeCharacter',
  /** Persona 描述,角色定义之前(Phase 2A) */
  PersonaBefore = 'PersonaBefore',
  Character = 'Character',
  /** Persona 描述,角色定义之后(Phase 2A) */
  PersonaAfter = 'PersonaAfter',
  AfterCharacter = 'AfterCharacter',
  /** 对话示例(mes_example),位于聊天历史之前 */
  DialogueExamples = 'DialogueExamples',
  /**
   * 角色状态输出规则(稳定段:格式要求 + 字段清单,不含当前值)。
   * 内容只随角色卡 schema 变化(极小概率),因此放在稳定前缀里,
   * 与每轮变化的状态当前值分离,避免后者把整段对话历史拖出缓存。
   */
  StatusRule = 'StatusRule',
  /** v12: 核心长期事实(最高优先级记忆) */
  MemoryCore = 'MemoryCore',
  /** OnDemandPinned 固定世界书(核心记忆之后、会话记忆之前,随手动记忆总结一起更新) */
  LorebookPinned = 'LorebookPinned',
  /** v46: 会话记忆(跨会话入口级摘要,世界书钉选段之后) */
  MemorySession = 'MemorySession',
  /** v12: 章节摘要(按时间顺序) */
  MemoryChapter = 'MemoryChapter',
  /** v12: 近期滚动摘要 */
  MemoryRolling = 'MemoryRolling',
  /** v12: 旧数据迁移摘要(只读) */
  MemoryLegacy = 'MemoryLegacy',
  /** 记忆关键词检索命中的历史章节(可选开关,位置固定,靠近对话) */
  MemoryKeyword = 'MemoryKeyword',
  /** 旧版单段长期记忆摘要(兼容,新代码应使用 MemoryCore/Chapter/Rolling) */
  MemorySummary = 'MemorySummary',
  /** 聊天历史(Conversation)。v47 起粘滞世界书全文也按锚点插在这一段内部 */
  Conversation = 'Conversation',
  /**
   * v50: 角色卡前端界面交互记录(契约 v3 appendInteraction)。
   * 由页面轻交互攒下(不请求模型),位于聊天历史之后、PostHistory 之前(尾部动态区)。
   */
  FrontendInteraction = 'FrontendInteraction',
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
  /** 来源显示名(可选,仅供"上下文顺序"展示层使用,不进入网络请求) */
  readonly sourceName?: string;
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
  source: ChatMessageSource = ChatMessageSource.Conversation,
  sourceName?: string
): PromptSegment {
  return {
    id: id,
    position: position,
    role: role,
    content: content,
    priority: priority,
    source: source,
    sourceName: sourceName
  };
}

/**
 * 位置排序权重,用于 segments 排序。
 */
const POSITION_ORDER: Record<string, number> = {
  'PromptPreset': 0,
  'BeforeCharacter': 1,
  'PersonaBefore': 2,
  'Character': 3,
  'PersonaAfter': 4,
  'AfterCharacter': 5,
  'DialogueExamples': 6,
  'StatusRule': 7,
  'MemoryCore': 8,
  'LorebookPinned': 9,
  'MemorySession': 10,
  'MemoryChapter': 11,
  'MemoryRolling': 12,
  'MemoryLegacy': 13,
  'MemoryKeyword': 14,
  'MemorySummary': 15,
  'Conversation': 16,
  'FrontendInteraction': 17,
  'PostHistory': 18
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
