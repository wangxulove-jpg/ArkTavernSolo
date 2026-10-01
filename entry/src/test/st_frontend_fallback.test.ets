/**
 * ST 卡散落前端回退检测测试(bridge 层纯函数)
 *
 * 覆盖:
 * - 开场白 ```html 围栏剥取(整卡即前端:整个开场白就是一个前端页面)
 * - 开场白裸 HTML(≥512 字符且含 body/div)整段提取;短 HTML 与纯文本不误判
 * - 备用开场白检测
 * - regex_scripts[].replaceString 美化正则界面检测(来源标注带脚本名)
 * - 多候选取最大块
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  detectStFrontendHtml,
  extractHtmlBlockFromText,
  StFrontendFallback
} from '../main/ets/bridge/StFrontendFallback';
import { createCharacter, Character } from '../main/ets/models/Character';

/** 生成指定长度的 HTML 文本(保证含 div 开标签) */
function bigHtml(chars: number): string {
  const head: string = '<div class="app">';
  const tail: string = '</div>';
  const body: string = 'x'.repeat(Math.max(0, chars - head.length - tail.length));
  return head + body + tail;
}

/** 构造仅带开场白/备用开场白/extensions 的角色 */
function makeCharacter(
  firstMessage: string,
  alternateGreetings: string[],
  extensions: Record<string, Object>
): Character {
  return createCharacter('id-1', '测试角色', '', '', '', firstMessage, '',
    '', '', '', '', alternateGreetings, [], '', '', extensions);
}

/** 构造一条美化正则脚本记录(ArkTS 禁非空对象字面量,逐键赋值) */
function makeRegexScript(name: string, replaceString: string): Record<string, Object> {
  const script: Record<string, Object> = {};
  script['scriptName'] = name;
  script['findRegex'] = 'x';
  script['replaceString'] = replaceString;
  return script;
}

/** 构造带 regex_scripts 的 extensions */
function makeScriptExtensions(scripts: Object[]): Record<string, Object> {
  const ext: Record<string, Object> = {};
  ext['regex_scripts'] = scripts;
  return ext;
}

export default function stFrontendFallbackTest() {
  describe('stFrontendFallback', () => {
    it('fenced_html_in_greeting_strips_fence', 0, () => {
      const html: string = bigHtml(600);
      const first: string = '欢迎来到这个世界。\n```html\n' + html + '\n```\n继续对话吧。';
      const result: StFrontendFallback | null = detectStFrontendHtml(makeCharacter(first, [], {}));
      expect(result !== null).assertTrue();
      expect(result!.html).assertEqual(html);
      expect(result!.source).assertEqual('开场白');
    });

    it('bare_long_html_in_greeting_extracted_whole', 0, () => {
      const html: string = bigHtml(700);
      const result: StFrontendFallback | null = detectStFrontendHtml(makeCharacter(html, [], {}));
      expect(result !== null).assertTrue();
      expect(result!.html).assertEqual(html);
    });

    it('short_html_not_misjudged', 0, () => {
      const shortHtml: string = '<div class="status">HP 100</div>';
      const result: StFrontendFallback | null =
        detectStFrontendHtml(makeCharacter('你好' + shortHtml + '冒险开始', [], {}));
      expect(result === null).assertTrue();
    });

    it('plain_text_returns_null', 0, () => {
      const result: StFrontendFallback | null =
        detectStFrontendHtml(makeCharacter('普通开场白,没有任何标记', [], {}));
      expect(result === null).assertTrue();
    });

    it('alternate_greeting_detected', 0, () => {
      const html: string = bigHtml(600);
      const greetings: string[] = ['纯文本开场白', '```html\n' + html + '\n```'];
      const result: StFrontendFallback | null = detectStFrontendHtml(makeCharacter('', greetings, {}));
      expect(result !== null).assertTrue();
      expect(result!.source).assertEqual('备用开场白 2');
    });

    it('regex_script_replace_string_detected_with_name', 0, () => {
      const html: string = bigHtml(800);
      const script: Record<string, Object> = makeRegexScript('新状态栏', '```html\n' + html + '\n```');
      const scripts: Object[] = [script];
      const result: StFrontendFallback | null =
        detectStFrontendHtml(makeCharacter('', [], makeScriptExtensions(scripts)));
      expect(result !== null).assertTrue();
      expect(result!.source).assertEqual('正则:新状态栏');
      expect(result!.html).assertEqual(html);
    });

    it('largest_candidate_wins', 0, () => {
      const smallHtml: string = bigHtml(600);
      const bigOne: string = bigHtml(2000);
      const script: Record<string, Object> = makeRegexScript('主界面', bigOne);
      const scripts: Object[] = [script];
      const first: string = '```html\n' + smallHtml + '\n```';
      const result: StFrontendFallback | null =
        detectStFrontendHtml(makeCharacter(first, [], makeScriptExtensions(scripts)));
      expect(result !== null).assertTrue();
      expect(result!.html).assertEqual(bigOne);
      expect(result!.source).assertEqual('正则:主界面');
    });

    it('multiple_fences_pick_longest', 0, () => {
      const shortOne: string = bigHtml(600);
      const longOne: string = bigHtml(1200);
      const text: string = '```html\n' + shortOne + '\n```\n中间说明\n```html\n' + longOne + '\n```';
      const extracted: string = extractHtmlBlockFromText(text);
      expect(extracted).assertEqual(longOne);
    });

    it('oversize_regex_scripts_still_scanned_but_arktavern_first', 0, () => {
      // arktavern.frontend 存在时上层(extractFrontendSpec)优先,本检测只做兜底;
      // 此处验证检测本身对多脚本数组逐条扫描:第二脚本的 HTML 也能检出
      const html: string = bigHtml(900);
      const s1: Record<string, Object> = makeRegexScript('正文美化', '**{{match}}**');
      const s2: Record<string, Object> = makeRegexScript('手机界面', html);
      const scripts: Object[] = [s1, s2];
      const result: StFrontendFallback | null =
        detectStFrontendHtml(makeCharacter('', [], makeScriptExtensions(scripts)));
      expect(result !== null).assertTrue();
      expect(result!.source).assertEqual('正则:手机界面');
    });
  });
}
