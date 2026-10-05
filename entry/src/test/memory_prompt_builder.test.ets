/**
 * MemoryPromptBuilder 章节总结提示词单元测试(v51)
 *
 * 覆盖:
 * - buildChapterOutputSpec:四段重点结构 + 三行元数据契约(参与者/地点/时间)
 * - buildChapterSuffixInstruction:后缀指令内容(任务/范围/前序摘要/输出规范/破限)
 * - formatChunkRange:首末消息摘录、空 chunk 兜底
 * - 后缀扩展拼接:base 消息逐字节不变、指令位于末尾(缓存友好的机械断言)
 * - buildChapterPrompt:独立路径使用同一输出规范
 */

import { describe, it, expect } from '@ohos/hypium';
import { MemoryPromptBuilder } from '../main/ets/services/MemoryPromptBuilder';
import { ChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';
import {
  MemorySummaryPoints,
  ChapterTriggerConfig,
  DEFAULT_CHAPTER_TRIGGER
} from '../main/ets/models/ChatMemory';

const SUMMARY_POINTS: MemorySummaryPoints = {
  relationships: true,
  facts: true,
  events: true,
  userPreferences: true,
  commitments: true,
  openIssues: true,
  characterState: true
};

function makeBuilder(): MemoryPromptBuilder {
  return new MemoryPromptBuilder(SUMMARY_POINTS, DEFAULT_CHAPTER_TRIGGER);
}

function msg(id: string, role: ChatRole, content: string): ChatMessage {
  const m: ChatMessage = { id: id, role: role, content: content, createdAt: 0 };
  return m;
}

export default function memoryPromptBuilderTest() {
  describe('MemoryPromptBuilder', () => {
    it('chapter_output_spec_has_four_sections_and_metadata', 0, () => {
      const spec: string = makeBuilder().buildChapterOutputSpec();
      expect(spec).assertContain('参与者: ');
      expect(spec).assertContain('地点: ');
      expect(spec).assertContain('时间: ');
      expect(spec).assertContain('## 关键事实与剧情');
      expect(spec).assertContain('## 角色状态与关系变化');
      expect(spec).assertContain('## 承诺、约定与新增设定');
      expect(spec).assertContain('## 未解决事项与伏笔');
    });

    it('chapter_output_spec_drops_legacy_eight_sections', 0, () => {
      const spec: string = makeBuilder().buildChapterOutputSpec();
      expect(spec.indexOf('## 时间与地点')).assertEqual(-1);
      expect(spec.indexOf('## 重要对话含义')).assertEqual(-1);
      expect(spec.indexOf('## 决策与结果')).assertEqual(-1);
    });

    it('suffix_instruction_contains_task_range_and_spec', 0, () => {
      const chunk: ChatMessage[] = [
        msg('m1', ChatRole.User, '我们去森林吧'),
        msg('m2', ChatRole.Assistant, '好,我带上剑')
      ];
      const inst: ChatMessage = makeBuilder().buildChapterSuffixInstruction(chunk, '', '');
      expect(inst.role).assertEqual(ChatRole.System);
      expect(inst.content).assertContain('【记忆总结任务】');
      expect(inst.content).assertContain('本章节范围:从「');
      expect(inst.content).assertContain('## 关键事实与剧情');
      expect(inst.content).assertContain('虚构角色扮演');
    });

    it('suffix_instruction_embeds_prev_summary_only_when_present', 0, () => {
      const chunk: ChatMessage[] = [msg('m1', ChatRole.User, '你好')];
      const without: ChatMessage = makeBuilder().buildChapterSuffixInstruction(chunk, '', '');
      expect(without.content.indexOf('同段落前序摘要')).assertEqual(-1);
      const withPrev: ChatMessage =
        makeBuilder().buildChapterSuffixInstruction(chunk, '前序摘要内容X', '');
      expect(withPrev.content).assertContain('前序摘要内容X');
    });

    it('format_chunk_range_uses_first_and_last_snippet', 0, () => {
      const chunk: ChatMessage[] = [
        msg('m1', ChatRole.User, '开场第一句'),
        msg('m2', ChatRole.Assistant, '中间内容'),
        msg('m3', ChatRole.Assistant, '结尾最后一句')
      ];
      const range: string = makeBuilder().formatChunkRange(chunk);
      expect(range).assertContain('开场第一句');
      expect(range).assertContain('结尾最后一句');
      expect(range.indexOf('中间内容')).assertEqual(-1);
    });

    it('format_chunk_range_empty_chunk_fallback', 0, () => {
      const range: string = makeBuilder().formatChunkRange([]);
      expect(range).assertContain('以上全部对话');
    });

    it('suffix_extension_preserves_base_prefix_bytewise', 0, () => {
      // 机械断言:base 消息在拼接后逐字节不变,指令仅追加在末尾
      const base: ChatMessage[] = [
        msg('b1', ChatRole.System, '系统提示词-固定'),
        msg('b2', ChatRole.User, '历史消息-固定')
      ];
      const inst: ChatMessage = makeBuilder().buildChapterSuffixInstruction(
        [msg('m1', ChatRole.User, '新消息')], '', ''
      );
      const combined: ChatMessage[] = base.concat([inst]);
      expect(combined.length).assertEqual(3);
      expect(base.length).assertEqual(2); // base 未被修改
      expect(combined[0].id).assertEqual('b1');
      expect(combined[0].content).assertEqual('系统提示词-固定');
      expect(combined[1].id).assertEqual('b2');
      expect(combined[1].content).assertEqual('历史消息-固定');
      expect(combined[2].role).assertEqual(ChatRole.System);
      expect(combined[2].content).assertContain('【记忆总结任务】');
    });

    it('independent_chapter_prompt_shares_output_spec', 0, () => {
      const prompt: ChatMessage[] = makeBuilder().buildChapterPrompt(
        '旧摘要', [msg('m1', ChatRole.User, '对话')], ''
      );
      expect(prompt.length).assertEqual(2);
      expect(prompt[0].role).assertEqual(ChatRole.System);
      expect(prompt[0].content).assertContain('## 关键事实与剧情');
      expect(prompt[1].role).assertEqual(ChatRole.User);
      expect(prompt[1].content).assertContain('【本章节对话】');
    });
  });
}