/**
 * PromptSegment 排序测试(v45: 新增 LorebookPinned 固定世界书段)
 *
 * 验证:
 * - LorebookPinned 位于 MemorySummary 之后、Conversation 之前
 *   (即"记忆 → 世界书 → 历史"的核心顺序保证)
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
          'memory', PromptSegmentPosition.MemorySummary, ChatRole.System, 'mem', 0, ChatMessageSource.MemorySummary
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
      expect(positions.join(',')).assertEqual(
        PromptSegmentPosition.PromptPreset + ','
        + PromptSegmentPosition.MemorySummary + ','
        + PromptSegmentPosition.LorebookPinned + ','
        + PromptSegmentPosition.Conversation + ','
        + PromptSegmentPosition.PostHistory
      );
    });

    it('lorebook_pinned_memory_before_conversation', 0, () => {
      const segments: PromptSegment[] = [
        createPromptSegment('m', PromptSegmentPosition.MemorySummary, ChatRole.System, 'm'),
        createPromptSegment('p', PromptSegmentPosition.LorebookPinned, ChatRole.System, 'p'),
        createPromptSegment('c', PromptSegmentPosition.Conversation, ChatRole.User, 'c')
      ];
      const orders: PromptSegmentPosition[] = sortSegments(segments)
        .map((s: PromptSegment): PromptSegmentPosition => s.position);
      const mi: number = orders.indexOf(PromptSegmentPosition.MemorySummary);
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
  });
}
