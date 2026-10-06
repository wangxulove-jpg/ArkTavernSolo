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
 * - 命中分块保留原始语法源码(source,供未加载占位展示)
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

    // ===== v52: 本地图片库语法 ![描述](arkimg:名字) =====

    it('remote_image_marked_as_remote_kind', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('![风景](https://example.com/k.png)');
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.kind).assertEqual('remote');
        expect(img.name).assertEqual('');
      }
    });

    it('local_image_becomes_local_chunk', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('![微笑](arkimg:微笑)');
      expect(chunks.length).assertEqual(1);
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.kind).assertEqual('local');
        expect(img.name).assertEqual('微笑');
        // 本地图的 URL 由渲染层按当前角色解析,解析层只登记名字
        expect(img.url).assertEqual('');
        expect(img.alt).assertEqual('微笑');
      }
    });

    it('local_image_name_keeps_original_case', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('![OK](arkimg:OK_1)');
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.name).assertEqual('OK_1');
      }
    });

    it('local_and_remote_images_keep_order', 0, () => {
      const content: string = '![网图](https://example.com/l.png)\n中间文字\n![本地](arkimg:开心)';
      const chunks: ChatRenderChunk[] = parseChatChunks(content);
      expect(chunks.length).assertEqual(3);
      const first: ImageChatRenderChunk | null = asImage(chunks[0]);
      const third: ImageChatRenderChunk | null = asImage(chunks[2]);
      expect(first !== null).assertTrue();
      expect(third !== null).assertTrue();
      if (first !== null) {
        expect(first.kind).assertEqual('remote');
      }
      if (third !== null) {
        expect(third.kind).assertEqual('local');
        expect(third.name).assertEqual('开心');
      }
    });

    it('local_image_name_with_space_not_extracted', 0, () => {
      // 名字含空格不合法(库侧也会拒绝),解析层不抽取,原样留作文本
      const chunks: ChatRenderChunk[] = parseChatChunks('![x](arkimg:bad name)');
      for (let i = 0; i < chunks.length; i++) {
        expect(chunks[i].type).assertEqual('text');
      }
    });

    it('arkimg_without_name_stays_text', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('![x](arkimg:)');
      for (let i = 0; i < chunks.length; i++) {
        expect(chunks[i].type).assertEqual('text');
      }
    });

    it('local_image_unclosed_arkimg_stays_text_streaming', 0, () => {
      // 流式未闭合(缺右括号):不抽取,按文本显示,闭合后再抽取
      const chunks: ChatRenderChunk[] = parseChatChunks('正在输出 ![笑](arkimg:笑');
      const joined: string = joinTextChunks(chunks);
      expect(joined.indexOf('正在输出') >= 0).assertTrue();
      expect(joined.indexOf('arkimg:笑') >= 0).assertTrue();
    });

    it('markdown_image_keeps_raw_source_text', 0, () => {
      // 未加载时占位展示原始语法,故分块需保留原文
      const chunks: ChatRenderChunk[] = parseChatChunks('![风景](https://example.com/m.png)');
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.source).assertEqual('![风景](https://example.com/m.png)');
      }
    });

    it('img_tag_keeps_raw_source_text', 0, () => {
      const raw: string = '<img alt="CG" src="https://example.com/n.png">';
      const chunks: ChatRenderChunk[] = parseChatChunks(raw);
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.source).assertEqual(raw);
      }
    });

    it('local_image_keeps_raw_source_text', 0, () => {
      const chunks: ChatRenderChunk[] = parseChatChunks('![微笑](arkimg:微笑)');
      const img: ImageChatRenderChunk | null = asImage(chunks[0]);
      expect(img !== null).assertTrue();
      if (img !== null) {
        expect(img.source).assertEqual('![微笑](arkimg:微笑)');
      }
    });
  });
}
