/**
 * 自定义符号配色规则测试(解析层)
 *
 * 覆盖:
 * - 命中符号对的片段携带 symbolRuleId(= 符号对),且只存 id 不固化颜色(颜色由渲染层实时解析)
 * - 未传规则时解析行为不变(不产生 symbol 片段)
 * - 自定义符号优先于对白识别(给「」设规则后该片段不再是 dialogue)
 * - 未闭合/跨行不命中(安全降级为普通文本)
 * - 行内代码内不扫描(与对白识别一致)
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  parseChatText,
  createSegment,
  ChatTextSegment,
  ChatTextParserOptions
} from '../main/ets/parser/ChatTextParser';
import { ChatSymbolColorRule, createSymbolRule } from '../main/ets/utils/ChatTextColorTheme';

/** 构造带符号规则的解析选项 */
function optionsWith(rules: ChatSymbolColorRule[]): ChatTextParserOptions {
  return { enableMarkdown: true, enableDialogue: true, symbolRules: rules };
}

/** 查找指定文本的片段(未命中返回占位片段,便于断言失败时定位) */
function findSegment(segments: ChatTextSegment[], text: string): ChatTextSegment {
  for (let i = 0; i < segments.length; i++) {
    if (segments[i].text === text) {
      return segments[i];
    }
  }
  return createSegment('__missing__');
}

export default function chatSymbolColorTest() {
  describe('chatSymbolColor', () => {
    it('hit_pair_carries_rule_id', 0, () => {
      const rules: ChatSymbolColorRule[] = [createSymbolRule('【', '】', '#8B5CF6')];
      const segments: ChatTextSegment[] = parseChatText('前【内容】后', optionsWith(rules));
      const hit: ChatTextSegment = findSegment(segments, '【内容】');
      expect(hit.symbolRuleId).assertEqual('【】');
      expect(hit.colorRole).assertEqual('symbol');
      // 命中片段不固化颜色(颜色由渲染层从规则列表实时解析)
      expect(hit.text.indexOf('#')).assertEqual(-1);
    });

    it('no_rules_no_symbol_segment', 0, () => {
      const segments: ChatTextSegment[] = parseChatText('前【内容】后', {
        enableMarkdown: true,
        enableDialogue: true
      });
      for (let i = 0; i < segments.length; i++) {
        expect(segments[i].symbolRuleId).assertEqual('');
      }
    });

    it('symbol_wins_over_dialogue', 0, () => {
      const rules: ChatSymbolColorRule[] = [createSymbolRule('「', '」', '#EF4444')];
      const segments: ChatTextSegment[] = parseChatText('「对白」', optionsWith(rules));
      const hit: ChatTextSegment = findSegment(segments, '「对白」');
      expect(hit.symbolRuleId).assertEqual('「」');
      expect(hit.dialogue).assertFalse();
    });

    it('unclosed_or_crossline_not_hit', 0, () => {
      const rules: ChatSymbolColorRule[] = [createSymbolRule('【', '】', '#8B5CF6')];
      const unclosed: ChatTextSegment[] = parseChatText('未闭合【abc', optionsWith(rules));
      for (let i = 0; i < unclosed.length; i++) {
        expect(unclosed[i].symbolRuleId).assertEqual('');
      }
      const crossLine: ChatTextSegment[] = parseChatText('跨行【ab\ncd】', optionsWith(rules));
      for (let j = 0; j < crossLine.length; j++) {
        expect(crossLine[j].symbolRuleId).assertEqual('');
      }
    });

    it('multi_rules_bind_independently', 0, () => {
      const rules: ChatSymbolColorRule[] = [
        createSymbolRule('【', '】', '#8B5CF6'),
        createSymbolRule('「', '」', '#EF4444')
      ];
      const segments: ChatTextSegment[] = parseChatText('【甲】与「乙」', optionsWith(rules));
      expect(findSegment(segments, '【甲】').symbolRuleId).assertEqual('【】');
      expect(findSegment(segments, '「乙」').symbolRuleId).assertEqual('「」');
    });

    it('inline_code_not_scanned', 0, () => {
      const rules: ChatSymbolColorRule[] = [createSymbolRule('【', '】', '#8B5CF6')];
      const segments: ChatTextSegment[] = parseChatText('`【代码】` 与 【文本】', optionsWith(rules));
      const codeSeg: ChatTextSegment = findSegment(segments, '【代码】');
      expect(codeSeg.symbolRuleId).assertEqual('');
      expect(codeSeg.code).assertTrue();
      const textSeg: ChatTextSegment = findSegment(segments, '【文本】');
      expect(textSeg.symbolRuleId).assertEqual('【】');
    });
  });
}