/**
 * 上下文顺序标签 + 分段统计完整性测试(世界书加载方式可视化)
 *
 * 覆盖:
 * - sourceDisplayLabel:世界书各加载方式的名称(常量/命中、按需锁定、深度注入、粘滞按需)
 * - sourceMethodLabel:关键来源有加载方式说明,无关来源返回空串
 * - ContextBudgetEstimator.estimate:此前被漏掉的来源(粘滞/钉选/深度/分层记忆)
 *   必须出现在分段统计里并计入总输入 Token(修复"占用被低估")
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  ContextBudgetEstimator,
  sourceDisplayLabel,
  sourceMethodLabel,
  ContextBudgetStats,
  SegmentTokenStat
} from '../main/ets/services/ContextBudgetEstimator';
import { TokenCounter } from '../main/ets/services/TokenCounter';
import { ChatMessageSource } from '../main/ets/models/ChatMessageSource';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';

let seq: number = 0;

/** 构造带来源标记的请求消息 */
function srcMsg(source: ChatMessageSource, content: string, sourceName?: string): ChatMessage {
  seq++;
  const base: ChatMessage = createChatMessage('t' + seq.toString(), ChatRole.System, content, 1700000000000 + seq);
  const withSrc: ChatMessage = {
    id: base.id,
    role: base.role,
    content: base.content,
    createdAt: base.createdAt,
    source: source,
    sourceName: sourceName
  };
  return withSrc;
}

function segmentOf(stats: ContextBudgetStats, source: ChatMessageSource): SegmentTokenStat | null {
  for (let i = 0; i < stats.segments.length; i++) {
    if (stats.segments[i].source === source) {
      return stats.segments[i];
    }
  }
  return null;
}

export default function contextOrderLabelTest() {
  describe('ContextOrderLabel', () => {
    it('worldbook_labels_state_loading_method', 0, () => {
      expect(sourceDisplayLabel(ChatMessageSource.LorebookSticky)).assertContain('粘滞');
      expect(sourceDisplayLabel(ChatMessageSource.LorebookPinned)).assertContain('按需锁定');
      expect(sourceDisplayLabel(ChatMessageSource.LorebookDepth)).assertContain('深度注入');
      expect(sourceDisplayLabel(ChatMessageSource.LorebookBefore)).assertContain('常量');
      expect(sourceDisplayLabel(ChatMessageSource.LorebookAfter)).assertContain('常量');
    });

    it('memory_and_history_labels_are_explicit', 0, () => {
      expect(sourceDisplayLabel(ChatMessageSource.MemoryCore)).assertContain('核心记忆');
      expect(sourceDisplayLabel(ChatMessageSource.MemoryCore)).assertContain('常驻');
      expect(sourceDisplayLabel(ChatMessageSource.Conversation)).assertContain('可裁剪');
      expect(sourceDisplayLabel(ChatMessageSource.CrossSessionContext).length > 0).assertTrue();
    });

    it('method_label_explains_sticky_and_depth', 0, () => {
      expect(sourceMethodLabel(ChatMessageSource.LorebookSticky)).assertContain('StickyOnDemand');
      expect(sourceMethodLabel(ChatMessageSource.LorebookSticky)).assertContain('只增不减');
      expect(sourceMethodLabel(ChatMessageSource.LorebookDepth)).assertContain('OnDemand');
      expect(sourceMethodLabel(ChatMessageSource.LorebookPinned)).assertContain('OnDemandPinned');
    });

    it('method_label_empty_for_plain_sources', 0, () => {
      expect(sourceMethodLabel(ChatMessageSource.CharacterPrompt)).assertEqual('');
      expect(sourceMethodLabel(ChatMessageSource.PromptPresetSystem)).assertEqual('');
      expect(sourceMethodLabel(ChatMessageSource.CharacterPostHistory)).assertEqual('');
    });

    it('status_rule_and_values_have_distinct_labels', 0, () => {
      expect(sourceDisplayLabel(ChatMessageSource.StatusRule)).assertContain('角色状态输出规则');
      expect(sourceDisplayLabel(ChatMessageSource.StatusValues)).assertContain('角色状态当前值');
      // 两段必须能一眼区分稳定段与易变段
      expect(sourceDisplayLabel(ChatMessageSource.StatusRule) !==
        sourceDisplayLabel(ChatMessageSource.StatusValues)).assertTrue();
      expect(sourceMethodLabel(ChatMessageSource.StatusRule).length > 0).assertTrue();
      expect(sourceMethodLabel(ChatMessageSource.StatusValues).length > 0).assertTrue();
    });

    it('status_rule_and_values_are_counted_in_stats', 0, () => {
      const estimator: ContextBudgetEstimator = new ContextBudgetEstimator(new TokenCounter());
      const messages: ChatMessage[] = [
        srcMsg(ChatMessageSource.StatusRule, '【角色状态输出规则】...', '角色状态输出规则'),
        srcMsg(ChatMessageSource.Conversation, '你好'),
        srcMsg(ChatMessageSource.StatusValues, '【角色状态当前值】- 金币:999', '角色状态当前值')
      ];
      const stats: ContextBudgetStats = estimator.estimate(messages, undefined);
      expect(segmentOf(stats, ChatMessageSource.StatusRule) !== null).assertTrue();
      expect(segmentOf(stats, ChatMessageSource.StatusValues) !== null).assertTrue();
      expect(stats.segments.length).assertEqual(3);
    });

    it('sticky_segment_is_counted_in_stats', 0, () => {
      const estimator: ContextBudgetEstimator = new ContextBudgetEstimator(new TokenCounter());
      const messages: ChatMessage[] = [
        srcMsg(ChatMessageSource.Conversation, '你好'),
        srcMsg(ChatMessageSource.LorebookSticky, '【粘滞条目】灯塔维护规则', '粘滞命中灯塔维护规则(共1条)'),
        srcMsg(ChatMessageSource.CharacterPostHistory, '保持角色口吻')
      ];
      const stats: ContextBudgetStats = estimator.estimate(messages, undefined);
      const sticky: SegmentTokenStat | null = segmentOf(stats, ChatMessageSource.LorebookSticky);
      expect(sticky !== null).assertTrue();
      expect(sticky!.tokenCount > 0).assertTrue();
      expect(sticky!.label).assertContain('粘滞');
      // 总输入必须覆盖全部三段(修复前粘滞段被漏掉 → 总数偏小)
      expect(stats.totalInputTokens > sticky!.tokenCount).assertTrue();
    });

    it('pinned_and_layered_memory_are_counted_in_stats', 0, () => {
      const estimator: ContextBudgetEstimator = new ContextBudgetEstimator(new TokenCounter());
      const messages: ChatMessage[] = [
        srcMsg(ChatMessageSource.MemoryCore, '核心事实'),
        srcMsg(ChatMessageSource.LorebookPinned, '钉选条目'),
        srcMsg(ChatMessageSource.MemoryChapter, '章节摘要'),
        srcMsg(ChatMessageSource.Conversation, '最近一句')
      ];
      const stats: ContextBudgetStats = estimator.estimate(messages, undefined);
      expect(segmentOf(stats, ChatMessageSource.MemoryCore) !== null).assertTrue();
      expect(segmentOf(stats, ChatMessageSource.LorebookPinned) !== null).assertTrue();
      expect(segmentOf(stats, ChatMessageSource.MemoryChapter) !== null).assertTrue();
      expect(stats.segments.length).assertEqual(4);
    });
  });
}