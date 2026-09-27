/**
 * 前端卡交互回传 + 气泡 HTML 折叠测试(v50,契约 v3)
 *
 * 覆盖:
 * - 交互记录缓冲:空文本拒绝、超条数丢最旧、超字符数保最新
 * - 前端交互记录提示词段文本:空态返回空串、格式
 * - 状态输出指令(一次性请求用):包含当前值(界面/玩家设定)、locked 字段单列且严禁输出、无 schema/全 locked 不注入
 * - 状态段拆分(主聊天链路):规则段不含当前值(逐轮逐字不变,保前缀缓存)、当前值段只含值,
 *   两段同进同出;无 schema/全 locked 时两段均为空串
 * - PromptSegment 排序:StatusRule 位于 DialogueExamples 之后、MemoryCore 之前;
 *   FrontendInteraction 位于 Conversation 之后、PostHistory 之前
 * - v47 粘滞提醒:提醒文本只含条目名、按"已加载顺序"挑选仍命中的条目并去重、空则不出段
 * - ChatTextParser:整页 HTML 围栏折叠成一行、普通代码块不受影响、短 HTML 不折叠、
 *   嵌套渲染(extractFrontendHtml=false)不再二次折叠
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  pushFrontendInteractionRecord,
  buildFrontendInteractionText,
  buildStatusInstructionText,
  buildStatusRuleText,
  buildStatusValuesText,
  buildStickyReminderText,
  pickHotStickyNames,
  formatStatusFieldInstructionLine,
  FRONTEND_INTERACTION_MAX_ITEMS,
  FRONTEND_INTERACTION_MAX_CHARS
} from '../main/ets/services/ChatTextContract';
import { ChatStatusEntry, ChatStatusSchemaEntry } from '../main/ets/models/ChatStatusState';
import { LorebookEntry, LorebookPosition } from '../main/ets/models/Lorebook';
import {
  PromptSegmentPosition,
  createPromptSegment,
  sortSegments,
  PromptSegment
} from '../main/ets/models/PromptSegment';
import { ChatRole } from '../main/ets/models/ChatRole';
import { ChatMessageSource } from '../main/ets/models/ChatMessageSource';
import {
  parseChatChunks,
  ChatRenderChunk,
  ChatTextSegment,
  ChatTextParserOptions
} from '../main/ets/parser/ChatTextParser';

/** 分块统计(ArkTS 不允许无类型对象字面量,故显式声明接口) */
interface ChunkStats {
  collapsible: number;
  textChunks: number;
  sawNeedleCode: number;
}

/** 重复字符(避免依赖 String.repeat) */
function repeatStr(ch: string, n: number): string {
  let s: string = '';
  for (let i = 0; i < n; i++) {
    s += ch;
  }
  return s;
}

function schemaEntry(name: string, desc: string, locked: boolean): ChatStatusSchemaEntry {
  return { name: name, desc: desc, type: 'string', locked: locked };
}

function statusEntry(name: string, value: string, fromUser: boolean): ChatStatusEntry {
  return { name: name, value: value, fromUser: fromUser, locked: false };
}

/** 构建测试用世界书条目(仅 id/name 参与断言,其余字段固定) */
function stickyEntry(id: string, name: string): LorebookEntry {
  return {
    id: id,
    name: name,
    keys: [],
    secondaryKeys: [],
    regex: '',
    content: name + '的内容',
    enabled: true,
    constant: false,
    selective: false,
    position: LorebookPosition.BeforeCharacter,
    priority: 0,
    createdAt: 1000,
    updatedAt: 1000
  };
}

/** 统计分块里的折叠块数量,并检查是否存在包含指定文本的代码片段 */
function inspectChunks(chunks: ChatRenderChunk[], needle: string): ChunkStats {
  let collapsible: number = 0;
  let textChunks: number = 0;
  let sawNeedleCode: number = 0;
  for (let i = 0; i < chunks.length; i++) {
    const chunk: ChatRenderChunk = chunks[i];
    if (chunk.type === 'collapsible') {
      collapsible++;
    } else if (chunk.type === 'text') {
      textChunks++;
      for (let j = 0; j < chunk.segments.length; j++) {
        const seg: ChatTextSegment = chunk.segments[j];
        if (seg.code && seg.text.indexOf(needle) >= 0) {
          sawNeedleCode++;
        }
      }
    }
  }
  const stats: ChunkStats = {
    collapsible: collapsible,
    textChunks: textChunks,
    sawNeedleCode: sawNeedleCode
  };
  return stats;
}

export default function frontendInteractionTest() {
  describe('FrontendInteractionBuffer', () => {
    it('rejects_empty_and_trims_text', 0, () => {
      const records: string[] = [];
      expect(pushFrontendInteractionRecord(records, '   ')).assertFalse();
      expect(pushFrontendInteractionRecord(records, '  买了 3 瓶药水  ')).assertTrue();
      expect(records.length).assertEqual(1);
      expect(records[0]).assertEqual('买了 3 瓶药水');
    });

    it('drops_oldest_over_item_limit', 0, () => {
      const records: string[] = [];
      for (let i = 0; i < FRONTEND_INTERACTION_MAX_ITEMS + 5; i++) {
        pushFrontendInteractionRecord(records, 'op' + i.toString());
      }
      expect(records.length).assertEqual(FRONTEND_INTERACTION_MAX_ITEMS);
      expect(records[0]).assertEqual('op5');
    });

    it('trims_over_char_limit_keeping_newest', 0, () => {
      const records: string[] = [];
      const big: string = repeatStr('x', FRONTEND_INTERACTION_MAX_CHARS - 100);
      pushFrontendInteractionRecord(records, big + 'A');
      pushFrontendInteractionRecord(records, big + 'B');
      expect(records.length).assertEqual(1);
      expect(records[0].charAt(records[0].length - 1)).assertEqual('B');
    });

    it('block_text_empty_state_and_format', 0, () => {
      expect(buildFrontendInteractionText([])).assertEqual('');
      const text: string = buildFrontendInteractionText(['买了药水', '进入森林']);
      expect(text.indexOf('【前端交互记录】') >= 0).assertTrue();
      expect(text.indexOf('- 买了药水') >= 0).assertTrue();
      expect(text.indexOf('- 进入森林') >= 0).assertTrue();
    });
  });

  describe('FrontendInteractionStatusInstruction', () => {
    it('includes_current_value_and_source', 0, () => {
      const schema: ChatStatusSchemaEntry[] = [
        schemaEntry('金币', '钱', false),
        schemaEntry('称号', '身份', true)
      ];
      const entries: ChatStatusEntry[] = [
        statusEntry('金币', '999', true),
        statusEntry('称号', 'S级', false)
      ];
      const text: string = buildStatusInstructionText(schema, entries, false);
      expect(text.indexOf('当前值:999') >= 0).assertTrue();
      expect(text.indexOf('(由界面/玩家设定)') >= 0).assertTrue();
      // locked 字段仍列出供参考,但要求模型严禁输出
      expect(text.indexOf('称号') >= 0).assertTrue();
      expect(text.indexOf('严禁输出') >= 0).assertTrue();
      expect(text.indexOf('已锁定(不可更新)') >= 0).assertTrue();
    });

    it('empty_value_shows_placeholder', 0, () => {
      const line: string = formatStatusFieldInstructionLine('天气', '', '', false, false);
      expect(line).assertEqual('- 天气｜当前值:(空)');
    });

    it('not_injected_without_schema_or_all_locked', 0, () => {
      expect(buildStatusInstructionText([], [], false)).assertEqual('');
      const allLocked: ChatStatusSchemaEntry[] = [schemaEntry('称号', '', true)];
      expect(buildStatusInstructionText(allLocked, [], false)).assertEqual('');
    });

    it('regenerate_branch_outputs_json_only', 0, () => {
      const schema: ChatStatusSchemaEntry[] = [schemaEntry('金币', '钱', false)];
      const text: string = buildStatusInstructionText(schema, [statusEntry('金币', '5', false)], true);
      expect(text.indexOf('只输出一个 JSON 对象') >= 0).assertTrue();
      expect(text.indexOf('<|status|>') >= 0).assertFalse();
    });
  });

  describe('StatusSegmentSplit', () => {
    const schema: ChatStatusSchemaEntry[] = [
      schemaEntry('金币', '钱', false),
      schemaEntry('心情', '当前情绪', false),
      schemaEntry('称号', '身份', true)
    ];

    it('rule_text_has_format_and_field_list_without_values', 0, () => {
      const rule: string = buildStatusRuleText(schema);
      // 格式块与字段清单在规则段
      expect(rule.indexOf('<|status|>') >= 0).assertTrue();
      expect(rule.indexOf('<|/status|>') >= 0).assertTrue();
      expect(rule.indexOf('- 金币｜说明:钱') >= 0).assertTrue();
      // locked 字段只标注锁定,不出现值
      expect(rule.indexOf('- 称号｜说明:身份｜已锁定(不可更新)') >= 0).assertTrue();
      expect(rule.indexOf('严禁输出') >= 0).assertTrue();
      // 规则段严禁携带当前值(否则每轮变化会击穿前缀缓存)
      expect(rule.indexOf('当前值') >= 0).assertFalse();
      expect(rule.indexOf('999') >= 0).assertFalse();
    });

    it('rule_text_is_independent_of_entries', 0, () => {
      // 同一 schema 下,规则段不随状态值变化(缓存命中的前提)
      const a: string = buildStatusRuleText(schema);
      const b: string = buildStatusRuleText(schema);
      expect(a).assertEqual(b);
      expect(a.indexOf('900') >= 0).assertFalse();
    });

    it('values_text_only_carries_current_values', 0, () => {
      const entries: ChatStatusEntry[] = [
        statusEntry('金币', '999', true),
        statusEntry('心情', '平静', false)
      ];
      const values: string = buildStatusValuesText(schema, entries);
      expect(values.indexOf('【角色状态当前值】') >= 0).assertTrue();
      expect(values.indexOf('- 金币:999(由界面/玩家设定)') >= 0).assertTrue();
      expect(values.indexOf('- 心情:平静') >= 0).assertTrue();
      // locked 字段也列出当前值供参考,并标注锁定
      expect(values.indexOf('- 称号:(空)｜已锁定') >= 0).assertTrue();
      // 当前值段不重复格式规则,保持体积最小
      expect(values.indexOf('<|status|>') >= 0).assertFalse();
      expect(values.indexOf('严禁新增或删除') >= 0).assertFalse();
    });

    it('both_empty_without_schema_or_all_locked', 0, () => {
      expect(buildStatusRuleText([])).assertEqual('');
      expect(buildStatusValuesText([], [])).assertEqual('');
      const allLocked: ChatStatusSchemaEntry[] = [schemaEntry('称号', '', true)];
      expect(buildStatusRuleText(allLocked)).assertEqual('');
      expect(buildStatusValuesText(allLocked, [])).assertEqual('');
    });
  });

  describe('StickyReminderText', () => {
    it('lists_entry_names_without_content', 0, () => {
      const text: string = buildStickyReminderText(['灯塔维护规则', '东堤地图']);
      expect(text.indexOf('【当前仍生效的设定】') >= 0).assertTrue();
      expect(text.indexOf('- 灯塔维护规则') >= 0).assertTrue();
      expect(text.indexOf('- 东堤地图') >= 0).assertTrue();
      // 提醒只带条目名,正文内容不重复出现
      expect(text.indexOf('不得在夜间关闭') >= 0).assertFalse();
    });

    it('empty_names_produce_no_segment', 0, () => {
      expect(buildStickyReminderText([])).assertEqual('');
      expect(pickHotStickyNames([], [], 5).length).assertEqual(0);
    });

    it('pick_hot_names_follows_loaded_order_and_dedupes', 0, () => {
      const loaded: LorebookEntry[] = [stickyEntry('a', '阿尔法'), stickyEntry('b', '贝塔'),
        stickyEntry('c', '伽马')];
      // 本轮只命中 a 与 c(且 matched 顺序与 loaded 不同、含重复)
      const matched: LorebookEntry[] = [stickyEntry('c', '伽马'), stickyEntry('a', '阿尔法'),
        stickyEntry('a', '阿尔法')];
      // 顺序跟随 loaded(首次命中顺序),不是 matched;同一 id 只出现一次
      expect(pickHotStickyNames(loaded, matched, 0).join(',')).assertEqual('阿尔法,伽马');
    });

    it('pick_hot_names_respects_max', 0, () => {
      const loaded: LorebookEntry[] = [stickyEntry('a', '阿尔法'), stickyEntry('b', '贝塔')];
      const matched: LorebookEntry[] = [stickyEntry('a', '阿尔法'), stickyEntry('b', '贝塔')];
      expect(pickHotStickyNames(loaded, matched, 1).join(',')).assertEqual('阿尔法');
      // 无命中 → 空(不产生提醒段)
      expect(pickHotStickyNames(loaded, [], 5).length).assertEqual(0);
    });
  });

  describe('FrontendInteractionSegmentOrder', () => {
    it('between_conversation_and_post_history', 0, () => {
      const segments: PromptSegment[] = [
        createPromptSegment('post', PromptSegmentPosition.PostHistory, ChatRole.System, 'post', 0,
          ChatMessageSource.CharacterPostHistory),
        createPromptSegment('fe', PromptSegmentPosition.FrontendInteraction, ChatRole.System, 'fe', 0,
          ChatMessageSource.FrontendInteraction),
        createPromptSegment('conv', PromptSegmentPosition.Conversation, ChatRole.User, 'hi', 0,
          ChatMessageSource.Conversation)
      ];
      const positions: string = sortSegments(segments)
        .map((s: PromptSegment): PromptSegmentPosition => s.position)
        .join(',');
      expect(positions).assertEqual(
        PromptSegmentPosition.Conversation + ','
        + PromptSegmentPosition.FrontendInteraction + ','
        + PromptSegmentPosition.PostHistory
      );
    });
  });

  describe('FrontendHtmlFolding', () => {
    it('folds_full_page_html_and_keeps_normal_code', 0, () => {
      const page: string = '<!DOCTYPE html><html><body><div id="app">'
        + repeatStr('x', 700)
        + '</div><style>body{color:red}</style><script>var a=1;</script></body></html>';
      const content: string = '开场白正文\n\n```html\n' + page + '\n```\n\n```js\nvar keepMe = 1;\n```';
      const seen: ChunkStats = inspectChunks(parseChatChunks(content), 'keepMe');
      expect(seen.collapsible).assertEqual(1);
      expect(seen.sawNeedleCode).assertEqual(1);
      expect(seen.textChunks > 0).assertTrue();
    });

    it('keeps_short_html_inline', 0, () => {
      const seen: ChunkStats = inspectChunks(parseChatChunks('```html\n<div>hi</div>\n```'), 'hi');
      expect(seen.collapsible).assertEqual(0);
    });

    it('does_not_fold_again_inside_collapsible', 0, () => {
      const inner: string = '```\n<div>' + repeatStr('y', 700) + '</div>\n```';
      const options: ChatTextParserOptions = {
        enableMarkdown: true,
        enableDialogue: true,
        extractFrontendHtml: false
      };
      const seen: ChunkStats = inspectChunks(parseChatChunks(inner, options), 'yyy');
      expect(seen.collapsible).assertEqual(0);
    });

    it('unclosed_fence_is_left_alone', 0, () => {
      const content: string = '流式输出中\n\n```html\n<div>' + repeatStr('z', 700);
      const seen: ChunkStats = inspectChunks(parseChatChunks(content), 'zzz');
      expect(seen.collapsible).assertEqual(0);
    });
  });
}