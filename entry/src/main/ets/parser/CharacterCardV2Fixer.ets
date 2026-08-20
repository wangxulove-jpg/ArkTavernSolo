/**
 * CharacterCardV2Fixer V2 角色卡文本清理与 JSON 提取
 *
 * 提供:
 * 1. 去除 AI 返回的 Markdown 代码块标记(```json ... ```)
 * 2. 从包含额外文字的响应中提取第一个完整 JSON 对象
 * 3. 不使用正则表达式直接解析整个 JSON(只用字符串查找定位边界)
 *
 * 设计原则:
 * - 纯函数,无副作用
 * - 不依赖 ArkUI
 * - 不调用任何网络或模型服务
 * - 自动修复循环逻辑由 AiCharacterGenerationService 编排(本模块只做文本清理)
 *
 * 不在本模块:
 * - 类型校验(由 CharacterCardV2Validator 负责)
 * - 调用模型重新生成(由 AiCharacterGenerationService 负责)
 */

/**
 * 清理 AI 返回的文本,去除 Markdown 代码块标记,提取完整 JSON 对象。
 *
 * 处理顺序:
 * 1. 去除首尾空白
 * 2. 如果以 ``` 开头,去除代码块标记(支持 ```json / ```JSON / ``` 等变体)
 * 3. 如果响应前后有额外文字,提取第一个完整 JSON 对象(从第一个 { 到对应的 })
 *
 * @param raw AI 返回的原始文本
 * @returns 提取的 JSON 字符串(可能仍为无效 JSON,由调用方 JSON.parse 处理)
 */
export function extractJsonObject(raw: string): string {
  if (raw.length === 0) {
    return '';
  }

  let s: string = raw.trim();
  if (s.length === 0) {
    return '';
  }

  // 去除 Markdown 代码块开始标记
  // 支持: ```json / ```JSON / ```javascript / ``` 等变体
  if (s.startsWith('```')) {
    // 找到第一个换行符,跳过整行(代码块语言标记)
    const firstNewline: number = s.indexOf('\n');
    if (firstNewline >= 0) {
      s = s.substring(firstNewline + 1);
    } else {
      // 只有 ``` 没有换行,直接去除三个反引号
      s = s.substring(3);
    }
  }

  // 去除 Markdown 代码块结束标记
  // 结束标记可能在末尾或后面跟空白
  if (s.endsWith('```')) {
    s = s.substring(0, s.length - 3);
  } else {
    // 可能在结束 ``` 前后有空白
    const lastFence: number = s.lastIndexOf('```');
    if (lastFence >= 0 && lastFence === s.length - 3) {
      s = s.substring(0, lastFence);
    }
  }

  s = s.trim();
  if (s.length === 0) {
    return '';
  }

  // 提取第一个完整 JSON 对象
  return findFirstJsonObject(s);
}

/**
 * 从字符串中查找第一个完整 JSON 对象。
 *
 * 算法:从第一个 { 开始,逐字符扫描,计数 { 和 }(考虑字符串字面量和转义),
 * 当计数归零时返回完整对象字符串。
 *
 * 不使用正则表达式(规范要求)。
 *
 * @param s 已去除代码块标记的字符串
 * @returns 提取的 JSON 对象字符串(未找到时返回原字符串)
 */
function findFirstJsonObject(s: string): string {
  const start: number = s.indexOf('{');
  if (start < 0) {
    return s;
  }

  let depth: number = 0;
  let inString: boolean = false;
  let escape: boolean = false;
  let end: number = -1;

  for (let i: number = start; i < s.length; i++) {
    const ch: string = s.charAt(i);

    if (inString) {
      if (escape) {
        escape = false;
      } else if (ch === '\\') {
        escape = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
    } else if (ch === '{') {
      depth++;
    } else if (ch === '}') {
      depth--;
      if (depth === 0) {
        end = i;
        break;
      }
      if (depth < 0) {
        // 异常:右括号多于左括号,从 start 到此处返回
        end = i;
        break;
      }
    }
  }

  if (end < 0) {
    // 未找到完整对象,返回从 start 到末尾的字符串
    return s.substring(start);
  }
  return s.substring(start, end + 1);
}
