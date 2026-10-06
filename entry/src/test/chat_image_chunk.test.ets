/**
 * 消息内网络图片分块测试(解析层)
 *
 * 覆盖:
 * - markdown ![](url) 与 <img src> 两种语法抽取为 image 分块(url/alt 正确)
 * - img 标签属性顺序/引号风格/alt 可选
 * - 图片与文本/表格混合时分块顺序与原文一致
 * - http:// 不抽取:markdown 保持文本、img 走消毒
 * - 无图片文本分块输出与现状一致(回归)
 * - 未闭合 <img src= 流式片段按文本显示
 */

import { describe, it, expect } from '@ohos/hypium';
import { parseChatChunks, ChatRenderChunk, ImageChatRenderChunk } from '../main/ets/parser/ChatTextParser';

/** 判别式窄化辅助:取 image 分块(非 image 返回 null) */
function asImage(c: ChatRenderChunk): ImageChatRenderChunk | null {
  if (c.type === 'image') {
    return c;
  }
  return null;
}

/** 统计文本分块拼接后的全文(回归对比用) */
function joinTextChunks(chunks: ChatRenderChunk[]): string {
  let s: string = '';
  for (let i = 0; i < chunks.length; i++) {
    const c: ChatRenderChunk = chunks[i];
    if (c.type === 'text') {
      for (let j = 0; j < c.segments.length; j++) {
        s += c.segments[j].text;
      }
      s += '\n';
    }
  }
  return s;
}

export default function chatImageChunkTest() {
  describe('chatImageChunk', () => {
    it('markdown_image_becomes_single_image_chunk', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('![风景](https://example.com/a.png)');
      expect(chunks.length).assertEqual(1);
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.url).assertEqual('https://example.com/a.png');
        expect(img.alt).assertEqual('风景');
      }
    });

    it('markdown_image_empty_alt', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('![](https://example.com/b.png)');
      expect(chunks.length).assertEqual(1);
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.url).assertEqual('https://example.com/b.png');
        expect(img.alt).assertEqual('');
      }
    });

    it('img_tag_double_quote_with_alt', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('<img src="https://example.com/c.png" alt="CG">');
      expect(chunks.length).assertEqual(1);
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.url).assertEqual('https://example.com/c.png');
        expect(img.alt).assertEqual('CG');
      }
    });

    it('img_tag_single_quote_alt_first', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks("<img alt='说明' src='https://example.com/d.png' style='width:100%'>");
      expect(chunks.length).assertEqual(1);
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.url).assertEqual('https://example.com/d.png');
        expect(img.alt).assertEqual('说明');
      }
    });

    it('image_between_text_keeps_order', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('前面一段文字\n![图](https://example.com/e.png)\n后面一段文字');
      expect(chunks.length).assertEqual(3);
      expect(chunks[0].type).assertEqual('text');
      expect(chunks[1].type).assertEqual('image');
      expect(chunks[2].type).assertEqual('text');
      const img: ImageChatRenderChunk | null = asImage(chunks[1]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.url).assertEqual('https://example.com/e.png');
      }
    });

    it('image_between_table_keeps_order', 0, () => {
      const content: string = '|表头1|表头2|\n|---|---|\n|甲|乙|\n![图](https://example.com/f.png)\n结尾文字';
      const chunks: ChatRenderChunk[] = parseChatChunks(content);
      // 表格在前、图片居中、文本在尾
      expect(chunks.length).assertEqual(3);
      expect(chunks[0].type).assertEqual('table');
      expect(chunks[1].type).assertEqual('image');
      expect(chunks[2].type).assertEqual('text');
    });

    it('http_markdown_stays_text', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('看这张 http://example.com/g.png 图');
      expect(chunks.length).assertEqual(1);
      expect(chunks[0].type).assertEqual('text');
      // http 不抽取,图片语法按文本显示
      const joined: string = joinTextChunks(chunks);
      expect(joined.indexOf('http://example.com/g.png') >= 0).assertTrue();
    });

    it('http_img_tag_sanitized', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('前<img src="http://example.com/h.png">后');
      // http img 不抽取,标签被消毒删除,只剩前后文本
      for (let i = 0; i < chunks.length; i++) {
        expect(chunks[i].type).assertEqual('text');
      }
      const joined: string = joinTextChunks(chunks);
      expect(joined.indexOf('<img') >= 0).assertFalse();
      expect(joined.indexOf('h.png') >= 0).assertFalse();
      expect(joined.indexOf('前') >= 0).assertTrue();
      expect(joined.indexOf('后') >= 0).assertTrue();
    });

    it('no_image_regression', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('普通文本\n\n**加粗**与[链接](https://example.com)');
      expect(chunks.length).assertEqual(1);
      expect(chunks[0].type).assertEqual('text');
    });

    it('unclosed_img_tag_streaming_stays_text', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('正在输出<img src="https://example.com/i');
      // 未闭合标签(无 >)不命中抽取也不命中消毒,按普通文本原样显示;闭合后才被抽取为图片分块
      const joined: string = joinTextChunks(chunks);
      expect(joined.indexOf('正在输出') >= 0).assertTrue();
      expect(joined.indexOf('<img') >= 0).assertTrue();
      expect(joined.indexOf('example.com/i') >= 0).assertTrue();
    });

    it('multiple_images_keep_order', 0, () => {
      const content: string = '![一](https://example.com/1.png)\n中段文字\n![二](https://example.com/2.png)';
      const chunks: ChatRenderChunk[] = parseChatChunks(content);
      expect(chunks.length).assertEqual(3);
      expect(chunks[0].type).assertEqual('image');
      expect(chunks[1].type).assertEqual('text');
      expect(chunks[2].type).assertEqual('image');
      const img1: ImageChatRenderChunk | null = asImage(chunks[0]);
      const img2: ImageChatRenderChunk | null = asImage(chunks[2]);
      expect(img1 !== null).assertTrue();
      expect(img2 !== null).assertTrue();
      if (img1 !== null) {
        expect(img1.url).assertEqual('https://example.com/1.png');
      }
      if (img2 !== null) {
        expect(img2.url).assertEqual('https://example.com/2.png');
      }
    });

    it('image_only_message_single_chunk', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('<img src="https://example.com/j.png">');
      expect(chunks.length).assertEqual(1);
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.url).assertEqual('https://example.com/j.png');
      }
    });
  });
}
