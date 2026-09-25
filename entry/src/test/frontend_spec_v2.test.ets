/**
 * 前端页面规格与 Bridge v2 消息序列化测试(frontend-card-contract v2)
 *
 * 覆盖:
 * - extractFrontendSpec:字符串写法=全屏兼容;对象写法的 mode/title/size/chrome 解析与容错
 * - buildMessagesJson:limit 归一化(默认/上限/非法)、角色过滤、空内容跳过、时间正序
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  extractFrontendSpec,
  extractFrontendHtml,
  buildMessagesJson,
  FrontendSpec,
  FrontendMessageEntry
} from '../main/ets/bridge/CardFrontendBridge';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';

/** 构造 { arktavern: { frontend: <任意> } } */
function makeExtensions(frontend: Object): Record<string, Object> {
  const ark: Record<string, Object> = {};
  ark['frontend'] = frontend;
  const ext: Record<string, Object> = {};
  ext['arktavern'] = ark;
  return ext;
}

/** 构造 { arktavern: { frontend: {...} } },frontendObj 为字段表 */
function makeFrontendObject(html: string): Record<string, Object> {
  const fo: Record<string, Object> = {};
  fo['html'] = html;
  return fo;
}

let msgSeq: number = 0;

function msg(role: ChatRole, content: string): ChatMessage {
  msgSeq++;
  return createChatMessage('m' + msgSeq.toString(), role, content, 1700000000000 + msgSeq);
}

function parseMessages(json: string): FrontendMessageEntry[] {
  return JSON.parse(json) as FrontendMessageEntry[];
}

export default function frontendSpecV2Test() {
  describe('FrontendSpecV2', () => {
    it('no_extensions_returns_empty_spec', 0, () => {
      const ext: Record<string, Object> = {};
      const spec: FrontendSpec = extractFrontendSpec(ext);
      expect(spec.html).assertEqual('');
      expect(spec.mode).assertEqual('fullscreen');
      expect(spec.chrome).assertEqual('auto');
    });

    it('legacy_string_is_fullscreen', 0, () => {
      const spec: FrontendSpec = extractFrontendSpec(makeExtensions('<html></html>'));
      expect(spec.html).assertEqual('<html></html>');
      expect(spec.mode).assertEqual('fullscreen');
      expect(spec.title).assertEqual('');
      expect(spec.sizeWidth).assertEqual(0);
      expect(spec.sizeHeight).assertEqual('');
      expect(spec.chrome).assertEqual('auto');
      expect(extractFrontendHtml(makeExtensions('<html></html>')).length).assertEqual(13);
    });

    it('object_panel_parses_mode_title_size', 0, () => {
      const fo: Record<string, Object> = makeFrontendObject('<html>a</html>');
      fo['mode'] = 'panel';
      fo['title'] = '世界地图';
      const size: Record<string, Object> = {};
      size['width'] = 420;
      size['height'] = '70%';
      fo['size'] = size;
      const spec: FrontendSpec = extractFrontendSpec(makeExtensions(fo));
      expect(spec.html).assertEqual('<html>a</html>');
      expect(spec.mode).assertEqual('panel');
      expect(spec.title).assertEqual('世界地图');
      expect(spec.sizeWidth).assertEqual(420);
      expect(spec.sizeHeight).assertEqual('70%');
      expect(spec.chrome).assertEqual('auto');
    });

    it('object_chrome_none_is_immersive', 0, () => {
      const fo: Record<string, Object> = makeFrontendObject('<html>b</html>');
      fo['mode'] = 'fullscreen';
      fo['chrome'] = 'none';
      expect(extractFrontendSpec(makeExtensions(fo)).chrome).assertEqual('none');
    });

    it('object_chrome_unknown_falls_back_to_auto', 0, () => {
      const fo: Record<string, Object> = makeFrontendObject('<html>c</html>');
      fo['chrome'] = 'fullscreen';
      expect(extractFrontendSpec(makeExtensions(fo)).chrome).assertEqual('auto');
    });

    it('object_unknown_mode_falls_back_to_fullscreen', 0, () => {
      const fo: Record<string, Object> = makeFrontendObject('<html>d</html>');
      fo['mode'] = 'float';
      expect(extractFrontendSpec(makeExtensions(fo)).mode).assertEqual('fullscreen');
    });

    it('object_without_html_returns_empty_spec', 0, () => {
      const fo: Record<string, Object> = {};
      fo['mode'] = 'panel';
      const spec: FrontendSpec = extractFrontendSpec(makeExtensions(fo));
      expect(spec.html).assertEqual('');
      expect(spec.mode).assertEqual('fullscreen');
      expect(spec.chrome).assertEqual('auto');
    });

    it('size_width_string_is_coerced_to_number', 0, () => {
      const fo: Record<string, Object> = makeFrontendObject('<html>e</html>');
      const size: Record<string, Object> = {};
      size['width'] = '360';
      size['height'] = 520;
      fo['size'] = size;
      const spec: FrontendSpec = extractFrontendSpec(makeExtensions(fo));
      expect(spec.sizeWidth).assertEqual(360);
      // height 非字符串 → 未指定(保持既有契约:只有字符串百分比/数值写法)
      expect(spec.sizeHeight).assertEqual('');
    });
  });

  describe('BridgeMessagesV2', () => {
    it('empty_messages_returns_empty_array', 0, () => {
      const list: ChatMessage[] = [];
      expect(buildMessagesJson(list, 0)).assertEqual('[]');
    });

    it('returns_messages_in_chronological_order', 0, () => {
      const list: ChatMessage[] = [
        msg(ChatRole.User, '你好'),
        msg(ChatRole.Assistant, '你好呀')
      ];
      const parsed: FrontendMessageEntry[] = parseMessages(buildMessagesJson(list, 50));
      expect(parsed.length).assertEqual(2);
      expect(parsed[0].role).assertEqual('user');
      expect(parsed[0].content).assertEqual('你好');
      expect(parsed[1].role).assertEqual('assistant');
      expect(parsed[1].content).assertEqual('你好呀');
    });

    it('skips_system_and_empty_content', 0, () => {
      const list: ChatMessage[] = [
        msg(ChatRole.System, '系统设定'),
        msg(ChatRole.User, '问题'),
        msg(ChatRole.Assistant, ''),
        msg(ChatRole.Assistant, '回答')
      ];
      const parsed: FrontendMessageEntry[] = parseMessages(buildMessagesJson(list, 50));
      expect(parsed.length).assertEqual(2);
      expect(parsed[0].content).assertEqual('问题');
      expect(parsed[1].content).assertEqual('回答');
    });

    it('limit_keeps_latest_entries', 0, () => {
      const list: ChatMessage[] = [
        msg(ChatRole.User, '1'),
        msg(ChatRole.Assistant, '2'),
        msg(ChatRole.User, '3'),
        msg(ChatRole.Assistant, '4')
      ];
      const parsed: FrontendMessageEntry[] = parseMessages(buildMessagesJson(list, 2));
      expect(parsed.length).assertEqual(2);
      expect(parsed[0].content).assertEqual('3');
      expect(parsed[1].content).assertEqual('4');
    });

    it('invalid_limit_falls_back_to_default', 0, () => {
      const list: ChatMessage[] = [];
      for (let i = 0; i < 60; i++) {
        list.push(msg(ChatRole.User, 'm' + i.toString()));
      }
      // 0 / 负数 / NaN 一律按默认 50 处理
      expect(parseMessages(buildMessagesJson(list, 0)).length).assertEqual(50);
      expect(parseMessages(buildMessagesJson(list, -5)).length).assertEqual(50);
      expect(parseMessages(buildMessagesJson(list, NaN)).length).assertEqual(50);
    });

    it('limit_above_max_is_clamped', 0, () => {
      const list: ChatMessage[] = [];
      for (let i = 0; i < 260; i++) {
        list.push(msg(ChatRole.User, 'm' + i.toString()));
      }
      expect(parseMessages(buildMessagesJson(list, 999)).length).assertEqual(200);
    });

    it('limit_floors_fractional_value', 0, () => {
      const list: ChatMessage[] = [
        msg(ChatRole.User, '1'),
        msg(ChatRole.User, '2'),
        msg(ChatRole.User, '3')
      ];
      expect(parseMessages(buildMessagesJson(list, 2.9)).length).assertEqual(2);
    });
  });
}