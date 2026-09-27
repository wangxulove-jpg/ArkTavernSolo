/**
 * PromptSegment 排序测试(v45: 新增 LorebookPinned 固定世界书段;v46: 新增 LorebookSticky 粘滞世界书段)
 *
 * 验证:
 * - LorebookPinned 位于 MemorySummary 之后、Conversation 之前
 *   (即"记忆 → 世界书 → 历史"的核心顺序保证)
 * - LorebookSticky 位于 Conversation 之后、PostHistory 之前
 *   (尾部动态区,append-only 保缓存前缀)
 * - 同位置内按 priority 降序
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  PromptSegmentPosition,
  createPromptSegment,
  sortSegments,
  PromptSegment
} from '../main/ets/models/PromptSegment';
import { ChatRole } from '../main/ets/models/ChatRole';
import { ChatMessageSource } from '../main/ets/models/ChatMessageSource';

export default function promptSegmentOrderTest() {
  describe('PromptSegmentOrder', () => {
    it('LorebookPinned_between_memory_and_conversation', 0, () => {
      const segments: PromptSegment[] = [
        createPromptSegment(
          'conversation', PromptSegmentPosition.Conversation, ChatRole.User, 'hi', 0, ChatMessageSource.Conversation
        ),
        createPromptSegment(
          'core', PromptSegmentPosition.MemoryCore, ChatRole.System, 'core', 0, ChatMessageSource.MemoryCore
        ),
        createPromptSegment(
          'pinned', PromptSegmentPosition.LorebookPinned, ChatRole.System, 'lore', 50, ChatMessageSource.LorebookPinned
        ),
        createPromptSegment(
          'post', PromptSegmentPosition.PostHistory, ChatRole.System, 'post', 0, ChatMessageSource.CharacterPostHistory
        ),
        createPromptSegment(
          'preset', PromptSegmentPosition.PromptPreset, ChatRole.System, 'preset', 0, ChatMessageSource.PromptPresetSystem
        )
      ];

      const sorted: PromptSegment[] = sortSegments(segments);
      const positions: PromptSegmentPosition[] = sorted.map((s: PromptSegment): PromptSegmentPosition => s.position);

      // hypium assertEqual 用 === 比较,数组字面量每次引用不同,改为字符串比较
      // (契约:PromptPreset(0) → MemoryCore(8) → LorebookPinned(9) → Conversation(16) → PostHistory(19),
      //  见 POSITION_ORDER)
      expect(positions.join(',')).assertEqual(
        PromptSegmentPosition.PromptPreset + ','
        + PromptSegmentPosition.MemoryCore + ','
        + PromptSegmentPosition.LorebookPinned + ','
        + PromptSegmentPosition.Conversation + ','
        + PromptSegmentPosition.PostHistory
      );
    });

    it('lorebook_pinned_memory_before_conversation', 0, () => {
      const segments: PromptSegment[] = [
        createPromptSegment('m', PromptSegmentPosition.MemoryCore, ChatRole.System, 'm'),
        createPromptSegment('p', PromptSegmentPosition.LorebookPinned, ChatRole.System, 'p'),
        createPromptSegment('c', PromptSegmentPosition.Conversation, ChatRole.User, 'c')
      ];
      const orders: PromptSegmentPosition[] = sortSegments(segments)
        .map((s: PromptSegment): PromptSegmentPosition => s.position);
      const mi: number = orders.indexOf(PromptSegmentPosition.MemoryCore);
      const pi: number = orders.indexOf(PromptSegmentPosition.LorebookPinned);
      const ci: number = orders.indexOf(PromptSegmentPosition.Conversation);
      expect(mi).assertLess(pi);
      expect(pi).assertLess(ci);
    });

    it('same_position_sorted_by_priority_desc', 0, () => {
      const segments: PromptSegment[] = [
        createPromptSegment('low', PromptSegmentPosition.LorebookPinned, ChatRole.System, 'low', 10),
        createPromptSegment('high', PromptSegmentPosition.LorebookPinned, ChatRole.System, 'high', 100)
      ];
      const sorted: PromptSegment[] = sortSegments(segments);
      expect(sorted[0].id).assertEqual('high');
      expect(sorted[1].id).assertEqual('low');
    });

    it('memory_session_between_core_and_chapter', 0, () => {
      const segments: PromptSegment[] = [
        createPromptSegment('chapter', PromptSegmentPosition.MemoryChapter, ChatRole.System, 'ch'),
        createPromptSegment('session', PromptSegmentPosition.MemorySession, ChatRole.System, 'ss'),
        createPromptSegment('core', PromptSegmentPosition.MemoryCore, ChatRole.System, 'co'),
        createPromptSegment('conversation', PromptSegmentPosition.Conversation, ChatRole.User, 'hi')
      ];
      const sorted: PromptSegment[] = sortSegments(segments);
      const positions: PromptSegmentPosition[] = sorted
        .map((s: PromptSegment): PromptSegmentPosition => s.position);
      const coreIdx: number = positions.indexOf(PromptSegmentPosition.MemoryCore);
      const sessionIdx: number = positions.indexOf(PromptSegmentPosition.MemorySession);
      const chapterIdx: number = positions.indexOf(PromptSegmentPosition.MemoryChapter);
      expect(coreIdx).assertLess(sessionIdx);
      expect(sessionIdx).assertLess(chapterIdx);
    });

    it('status_rule_between_dialogue_examples_and_memory_core', 0, () => {
      const segments: PromptSegment[] = [
        createPromptSegment('core', PromptSegmentPosition.MemoryCore, ChatRole.System, 'm'),
        createPromptSegment('rule', PromptSegmentPosition.StatusRule, ChatRole.System, 'r'),
        createPromptSegment('example', PromptSegmentPosition.DialogueExamples, ChatRole.System, 'e'),
        createPromptSegment('conversation', PromptSegmentPosition.Conversation, ChatRole.User, 'hi')
      ];
      const positions: PromptSegmentPosition[] = sortSegments(segments)
        .map((s: PromptSegment): PromptSegmentPosition => s.position);
      const exampleIdx: number = positions.indexOf(PromptSegmentPosition.DialogueExamples);
      const ruleIdx: number = positions.indexOf(PromptSegmentPosition.StatusRule);
      const coreIdx: number = positions.indexOf(PromptSegmentPosition.MemoryCore);
      // 稳定前缀:对话示例 → 状态规则 → 记忆 → 对话
      expect(exampleIdx).assertLess(ruleIdx);
      expect(ruleIdx).assertLess(coreIdx);
      expect(coreIdx).assertLess(positions.indexOf(PromptSegmentPosition.Conversation));
    });

    it('frontend_interaction_between_conversation_and_post_history', 0, () => {
      const segments: PromptSegment[] = [
        createPromptSegment('post', PromptSegmentPosition.PostHistory, ChatRole.System, 'post'),
        createPromptSegment('fe', PromptSegmentPosition.FrontendInteraction, ChatRole.System, 'fe'),
        createPromptSegment('conversation', PromptSegmentPosition.Conversation, ChatRole.User, 'hi')
      ];
      const positions: PromptSegmentPosition[] = sortSegments(segments)
        .map((s: PromptSegment): PromptSegmentPosition => s.position);
      const conversationIdx: number = positions.indexOf(PromptSegmentPosition.Conversation);
      const feIdx: number = positions.indexOf(PromptSegmentPosition.FrontendInteraction);
      const postIdx: number = positions.indexOf(PromptSegmentPosition.PostHistory);
      // 尾部动态区:对话 → 前端交互记录 → Post-History
      // (粘滞世界书全文 v47 起不再占独立段位,改由 ChatService 按锚点插进 Conversation 内部)
      expect(conversationIdx).assertLess(feIdx);
      expect(feIdx).assertLess(postIdx);
    });
  });
}
