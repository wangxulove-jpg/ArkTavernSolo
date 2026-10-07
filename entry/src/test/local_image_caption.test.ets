/**
 * 本地图片「AI 自动命名」纯函数与请求体多模态用例
 *
 * 覆盖:
 * - 任务指令必须含 "JSON" 字样(response_format=json_object 的硬要求)
 * - 解析模型返回:纯 JSON / ```json 围栏 / 前后夹带文字 / 非 JSON / 数组 / 空字段 / 超长描述
 * - 名字消毒:sanitizeImageName 去非法字符与空白、截断、兜底
 * - buildRequestBody:带图时只有**最后一条 user 消息**变内容块数组;不带图时行为完全不变
 * - validateRequest:带图但没有 user 消息 → InvalidRequest
 *
 * 全部为纯函数层用例:不碰网络 / DB / 图片文件。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  LOCAL_IMAGE_CAPTION_INSTRUCTION,
  CAPTION_GUIDANCE_MAX_LENGTH,
  CaptionParseFailure,
  ImageCaptionSuggestion,
  buildCaptionInstruction,
  classifyCaptionFailure,
  parseImageCaptionResponse,
  summarizeRawResponse
} from '../main/ets/models/LocalImageCaption';
import {
  IMAGE_NAME_MAX_LENGTH,
  IMAGE_DESCRIPTION_MAX_LENGTH,
  sanitizeImageName
} from '../main/ets/models/LocalImage';
import { buildRequestBody, validateRequest } from '../main/ets/network/providers/OpenAIProvider';
import { ChatRequest } from '../main/ets/models/ChatRequest';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';

const DATA_URL: string = 'data:image/png;base64,AAAA';

/** 构造一个最小可用请求 */
function makeRequest(messages: ChatMessage[], images?: string[]): ChatRequest {
  return {
    model: 'test-model',
    messages: messages,
    temperature: 0.3,
    topP: 0.9,
    maxTokens: 300,
    stream: false,
    imageDataUrls: images
  };
}

/** 从请求体 JSON 里取出 messages 数组(取不到返回空数组) */
function parseMessages(json: string): Object[] {
  const root: Object = JSON.parse(json) as Object;
  const record: Record<string, Object> = root as Record<string, Object>;
  const messages: Object | undefined = record['messages'];
  if (messages !== undefined && Array.isArray(messages)) {
    return messages as Object[];
  }
  return [];
}

/** 从一条消息对象里取字段 */
function readField(message: Object, key: string): Object | undefined {
  const record: Record<string, Object> = message as Record<string, Object>;
  return record[key];
}

export default function localImageCaptionTest() {
  describe('localImageCaption', () => {

    // ===== 任务指令 =====

    it('instruction_mentions_json', 0, () => {
      // 开启 response_format=json_object 时部分端点强制要求提示词含 "JSON"
      expect(LOCAL_IMAGE_CAPTION_INSTRUCTION.indexOf('JSON') >= 0).assertTrue();
    });

    // ===== 描述方向(用户自定义,拼在提示词最前) =====

    it('instruction_without_guidance_is_base', 0, () => {
      expect(buildCaptionInstruction('')).assertEqual(LOCAL_IMAGE_CAPTION_INSTRUCTION);
      expect(buildCaptionInstruction('   ')).assertEqual(LOCAL_IMAGE_CAPTION_INSTRUCTION);
    });

    it('guidance_is_prepended_before_base', 0, () => {
      const out: string = buildCaptionInstruction('用中性客观的措辞');
      expect(out.startsWith('用中性客观的措辞\n\n')).assertTrue();
      expect(out.endsWith(LOCAL_IMAGE_CAPTION_INSTRUCTION)).assertTrue();
    });

    it('guidance_is_trimmed_and_capped', 0, () => {
      expect(buildCaptionInstruction('  方向  ').startsWith('方向\n\n')).assertTrue();
      const long: string = '啊'.repeat(CAPTION_GUIDANCE_MAX_LENGTH + 30);
      const out: string = buildCaptionInstruction(long);
      expect(out.substring(0, out.indexOf('\n\n')).length).assertEqual(CAPTION_GUIDANCE_MAX_LENGTH);
    });

    // ===== 解析:命中 =====

    it('parse_plain_json', 0, () => {
      const r: ImageCaptionSuggestion | null =
        parseImageCaptionResponse('{"name":"开心","description":"张嘴大笑，适合高兴的场合"}');
      expect(r !== null).assertTrue();
      expect(r!.name).assertEqual('开心');
      expect(r!.description).assertEqual('张嘴大笑，适合高兴的场合');
    });

    it('parse_fenced_json', 0, () => {
      const raw: string = '```json\n{"name":"生气","description":"皱眉瞪眼"}\n```';
      const r: ImageCaptionSuggestion | null = parseImageCaptionResponse(raw);
      expect(r !== null).assertTrue();
      expect(r!.name).assertEqual('生气');
      expect(r!.description).assertEqual('皱眉瞪眼');
    });

    it('parse_json_with_surrounding_text', 0, () => {
      const raw: string = '好的，结果如下：{"name":"比耶","description":"手指比 V"} 以上。';
      const r: ImageCaptionSuggestion | null = parseImageCaptionResponse(raw);
      expect(r !== null).assertTrue();
      expect(r!.name).assertEqual('比耶');
    });

    it('parse_truncates_long_description', 0, () => {
      const long: string = '啊'.repeat(IMAGE_DESCRIPTION_MAX_LENGTH + 50);
      const raw: string = '{"name":"长","description":"' + long + '"}';
      const r: ImageCaptionSuggestion | null = parseImageCaptionResponse(raw);
      expect(r !== null).assertTrue();
      expect(r!.description.length <= IMAGE_DESCRIPTION_MAX_LENGTH).assertTrue();
    });

    // ===== 解析:未命中 =====

    it('parse_rejects_non_json', 0, () => {
      expect(parseImageCaptionResponse('我不知道这是什么') === null).assertTrue();
    });

    it('parse_extracts_object_from_array_wrapper', 0, () => {
      // 设计口径是"取首 { 到末 }",故模型多套了一层数组时仍能取出对象
      const r: ImageCaptionSuggestion | null = parseImageCaptionResponse('[{"name":"a"}]');
      expect(r !== null).assertTrue();
      expect(r!.name).assertEqual('a');
    });

    it('parse_rejects_empty_fields', 0, () => {
      expect(parseImageCaptionResponse('{"name":"","description":""}') === null).assertTrue();
    });

    // ===== 解析:键名容错 =====

    it('parse_accepts_chinese_and_alias_keys', 0, () => {
      const r1: ImageCaptionSuggestion | null =
        parseImageCaptionResponse('{"名称":"开心","描述":"张嘴大笑"}');
      expect(r1 !== null).assertTrue();
      expect(r1!.name).assertEqual('开心');
      expect(r1!.description).assertEqual('张嘴大笑');

      const r2: ImageCaptionSuggestion | null =
        parseImageCaptionResponse('{"图片名":"生气","desc":"皱眉瞪眼"}');
      expect(r2 !== null).assertTrue();
      expect(r2!.name).assertEqual('生气');
      expect(r2!.description).assertEqual('皱眉瞪眼');
    });

    // ===== 失败归类(决定给用户哪种提示) =====

    it('classify_truncated_wins_over_others', 0, () => {
      // finish_reason=length 时即便有花括号也判为截断(提示最可操作)
      expect(classifyCaptionFailure('{"name":"开心","desc', 'length')).assertEqual('truncated');
      expect(classifyCaptionFailure('随便一句话', 'length')).assertEqual('truncated');
    });

    it('classify_refusal_when_no_brace', 0, () => {
      const kind: CaptionParseFailure = classifyCaptionFailure('抱歉,我无法描述这张图片。', 'stop');
      expect(kind).assertEqual('refusal');
    });

    it('classify_malformed_when_brace_but_broken_json', 0, () => {
      expect(classifyCaptionFailure('{"name": "开心"', 'stop')).assertEqual('malformed');
      expect(classifyCaptionFailure('{"foo":"bar"}', 'stop')).assertEqual('malformed');
    });

    // ===== 原文摘要(展示用) =====

    it('summarize_flattens_and_truncates', 0, () => {
      expect(summarizeRawResponse('  抱歉,\n 我无法  描述 ', 40)).assertEqual('抱歉, 我无法 描述');
      const long: string = '啊'.repeat(200);
      const out: string = summarizeRawResponse(long, 10);
      expect(out.length).assertEqual(11);
      expect(out.endsWith('…')).assertTrue();
    });

    // ===== 名字消毒 =====

    it('sanitize_name_strips_whitespace_and_illegal_chars', 0, () => {
      expect(sanitizeImageName(' 开 心 (大) ', '旧名')).assertEqual('开心大');
      expect(sanitizeImageName('a"b`c|d', '旧名')).assertEqual('abcd');
    });

    it('sanitize_name_falls_back_when_empty', 0, () => {
      expect(sanitizeImageName('()[]', '旧名')).assertEqual('旧名');
      // 兜底名字也非法 → 返回空串,由调用方决定
      expect(sanitizeImageName('()', '非法 名')).assertEqual('');
    });

    it('sanitize_name_truncates_to_max_length', 0, () => {
      const long: string = '名'.repeat(IMAGE_NAME_MAX_LENGTH + 20);
      expect(sanitizeImageName(long, '旧名').length).assertEqual(IMAGE_NAME_MAX_LENGTH);
    });

    // ===== 请求体:带图 =====

    it('body_with_images_parts_only_on_last_user_message', 0, () => {
      const messages: ChatMessage[] = [
        createChatMessage('s', ChatRole.System, 'sys', 1),
        createChatMessage('u1', ChatRole.User, 'first', 1),
        createChatMessage('a', ChatRole.Assistant, 'reply', 1),
        createChatMessage('u2', ChatRole.User, 'second', 1)
      ];
      const json: string = buildRequestBody(makeRequest(messages, [DATA_URL]));
      const parsed: Object[] = parseMessages(json);
      expect(parsed.length).assertEqual(4);
      // 非目标消息仍是纯字符串
      expect(typeof readField(parsed[0], 'content')).assertEqual('string');
      expect(readField(parsed[1], 'content')).assertEqual('first');
      expect(typeof readField(parsed[2], 'content')).assertEqual('string');
      // 最后一条 user 消息变成内容块数组
      const parts: Object = readField(parsed[3], 'content')!;
      expect(Array.isArray(parts)).assertTrue();
      const list: Object[] = parts as Object[];
      expect(list.length).assertEqual(2);
      expect(readField(list[0], 'type')).assertEqual('text');
      expect(readField(list[0], 'text')).assertEqual('second');
      expect(readField(list[1], 'type')).assertEqual('image_url');
      const imageUrl: Object = readField(list[1], 'image_url')!;
      expect(readField(imageUrl, 'url')).assertEqual(DATA_URL);
      // 省 token:固定低清晰度档
      expect(readField(imageUrl, 'detail')).assertEqual('low');
    });

    it('body_with_images_omits_empty_text_part', 0, () => {
      const messages: ChatMessage[] = [
        createChatMessage('u', ChatRole.User, '', 1)
      ];
      const list: Object[] = parseMessages(buildRequestBody(makeRequest(messages, [DATA_URL]))) as Object[];
      // 空文本不产出空文本块
      expect(list.length).assertEqual(1);
      const parts: Object[] = readField(list[0], 'content') as Object[];
      expect(parts.length).assertEqual(1);
      expect(readField(parts[0], 'type')).assertEqual('image_url');
    });

    // ===== 请求体:不带图(行为不变) =====

    it('body_without_images_keeps_plain_string_content', 0, () => {
      const messages: ChatMessage[] = [
        createChatMessage('s', ChatRole.System, 'sys', 1),
        createChatMessage('u', ChatRole.User, 'hello', 1)
      ];
      const json: string = buildRequestBody(makeRequest(messages));
      expect(json.indexOf('image_url') < 0).assertTrue();
      const parsed: Object[] = parseMessages(json);
      expect(parsed.length).assertEqual(2);
      expect(typeof readField(parsed[0], 'content')).assertEqual('string');
      expect(readField(parsed[1], 'content')).assertEqual('hello');
      // 无图时消息对象只有 role/content 两个键(与改造前一致)
      const record: Record<string, Object> = parsed[1] as Record<string, Object>;
      expect(Object.keys(record).length).assertEqual(2);
    });

    // ===== 请求校验 =====

    it('validate_rejects_images_without_user_message', 0, () => {
      const messages: ChatMessage[] = [
        createChatMessage('s', ChatRole.System, 'sys', 1)
      ];
      expect(validateRequest(makeRequest(messages, [DATA_URL])) !== null).assertTrue();
      // 同样的消息不带图 → 通过
      expect(validateRequest(makeRequest(messages)) === null).assertTrue();
    });
  });
}