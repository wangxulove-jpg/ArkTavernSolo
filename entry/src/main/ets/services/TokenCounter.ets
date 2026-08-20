/**
 * TokenCounter 简易 Token 估算服务
 *
 * 为最终发送给模型的 Prompt 提供稳定、可测试的 Token 估算能力。
 * 本阶段不引入第三方 tokenizer 或网络调用。
 *
 * 职责:
 * - 文本 Token 估算
 * - 单条消息 Token 估算(包含固定结构开销)
 * - 完整 Prompt Token 统计
 * - 上下文预算结果计算
 *
 * 非职责(后续阶段):
 * - 删除历史消息
 * - 截断 Prompt
 * - 自动压缩
 * - Summary
 * - 不同模型的精确 tokenizer
 *
 * 设计原则:
 * - 独立、无状态服务
 * - 不持有聊天状态
 * - 不依赖 ArkUI
 * - 不访问页面
 * - 不访问 Provider 网络层
 * - 不修改输入字符串、消息数组、消息对象
 * - 相同输入每次结果一致
 *
 * 估算规则(确定性):
 * 1. CJK 字符(中日韩统一表意/平假/片假/其他东亚宽字符):每字符 1 Token
 * 2. ASCII 标点符号:每标点 1 Token
 * 3. 空白(空格/制表/换行):连续空白序列 1 Token(以空白字符类型分组)
 * 4. 拉丁词(连续 ASCII 字母/数字):按 4 字符向上取整为 1 Token 单位
 * 5. 拉丁词中的标点/空白会打断单词
 * 6. 其他 Unicode code point(emoji、符号、代理对的低/高代理单独出现):
 *    每个完整 code point 1 Token
 *
 * 消息级开销:
 * - 每条消息固定 4 Token(包含 role / 分隔等)
 * - 整个 Prompt 结尾固定 2 Token(包含终止符)
 */

import { ChatMessage } from '../models/ChatMessage';
import { TokenBudget, createTokenBudget } from '../models/TokenBudget';

// ===== 集中定义估算常量 =====

/** 单条消息固定结构开销 */
const MESSAGE_FIXED_OVERHEAD: number = 4;

/** 整个 Prompt 结尾开销 */
const PROMPT_TRAILING_OVERHEAD: number = 2;

/** 拉丁词每多少字符计 1 Token(向上取整) */
const LATIN_TOKEN_CHARS: number = 4;

// ===== Unicode 分类判定 =====

/**
 * CJK 字符 Unicode 区段集合。
 * 包含:
 * - CJK 统一表意符号(U+4E00 - U+9FFF)
 * - CJK 统一表意符号扩展 A(U+3400 - U+4DBF)
 * - CJK 统一表意符号扩展 B-F(U+20000 - U+2FA1F,通过代理对处理)
 * - CJK 兼容表意符号(U+F900 - U+FAFF)
 * - CJK 符号和标点(U+3000 - U+303F)
 * - 平假名(U+3040 - U+309F)
 * - 片假名(U+30A0 - U+30FF)
 * - 片假名音标扩展(U+31F0 - U+31FF)
 * - 韩文音节(U+AC00 - U+D7AF)
 * - 韩文字母(U+1100 - U+11FF,U+3130 - U+318F)
 * - 全角 ASCII(U+FF00 - U+FFEF)
 *
 * 注:Emoji 的 CJK 兼容形式也常落在 U+FE00-U+FE0F 区域,但 Emoji 仍走"其他 code point 1 Token"分支。
 */
function isCjkCodePoint(cp: number): boolean {
  if (cp >= 0x4E00 && cp <= 0x9FFF) { return true; }
  if (cp >= 0x3400 && cp <= 0x4DBF) { return true; }
  if (cp >= 0xF900 && cp <= 0xFAFF) { return true; }
  if (cp >= 0x3000 && cp <= 0x303F) { return true; }
  if (cp >= 0x3040 && cp <= 0x309F) { return true; }
  if (cp >= 0x30A0 && cp <= 0x30FF) { return true; }
  if (cp >= 0x31F0 && cp <= 0x31FF) { return true; }
  if (cp >= 0xAC00 && cp <= 0xD7AF) { return true; }
  if (cp >= 0x1100 && cp <= 0x11FF) { return true; }
  if (cp >= 0x3130 && cp <= 0x318F) { return true; }
  if (cp >= 0xFF00 && cp <= 0xFFEF) { return true; }
  return false;
}

/**
 * ASCII 拉丁字母或数字。
 */
function isAsciiAlnum(ch: string): boolean {
  if (ch.length !== 1) {
    return false;
  }
  const code: number = ch.charCodeAt(0);
  return (code >= 0x30 && code <= 0x39)
    || (code >= 0x41 && code <= 0x5A)
    || (code >= 0x61 && code <= 0x7A);
}

/**
 * ASCII 标点(不含空白)。
 */
function isAsciiPunctuation(ch: string): boolean {
  if (ch.length !== 1) {
    return false;
  }
  const code: number = ch.charCodeAt(0);
  // 0x21-0x2F 0x3A-0x40 0x5B-0x60 0x7B-0x7E
  if (code >= 0x21 && code <= 0x2F) { return true; }
  if (code >= 0x3A && code <= 0x40) { return true; }
  if (code >= 0x5B && code <= 0x60) { return true; }
  if (code >= 0x7B && code <= 0x7E) { return true; }
  return false;
}

/**
 * ASCII 空白(空格/制表/换行/回车/换页/垂直制表)。
 */
function isAsciiWhitespace(ch: string): boolean {
  if (ch.length !== 1) {
    return false;
  }
  const code: number = ch.charCodeAt(0);
  return code === 0x20 || code === 0x09 || code === 0x0A
    || code === 0x0D || code === 0x0C || code === 0x0B;
}

// ===== 字符迭代器 =====

/**
 * 描述一个 Unicode code point 在 JavaScript 字符串中的表示。
 * length=2 表示代理对(emoji),length=1 表示单 UTF-16 单元。
 */
interface CodePointItem {
  /** 完整字符串片段(可能是代理对组合) */
  ch: string;
  /** 第一个 UTF-16 单元的 code point */
  code: number;
  /** 消耗的 UTF-16 单元数(1 或 2) */
  length: number;
}

/**
 * 按 Unicode code point 迭代字符串。
 * 正确处理 UTF-16 代理对(emoji 等),不把代理对拆成两个单位。
 *
 * 返回:每项 { ch: 单字符(可能为代理对组成的 emoji), code: 第一个 UTF-16 单元的 code point, length: 消耗的 UTF-16 单元数 }
 */
function iterateCodePoints(content: string): CodePointItem[] {
  const out: CodePointItem[] = [];
  const len: number = content.length;
  let i: number = 0;
  while (i < len) {
    const code: number = content.charCodeAt(i);
    // 跳过孤立的低代理字符(其前面没有高代理),防止未配对代理引发问题
    if (code >= 0xDC00 && code <= 0xDFFF) {
      const item: CodePointItem = { ch: content.substring(i, i + 1), code: code, length: 1 };
      out.push(item);
      i++;
      continue;
    }
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < len) {
      const next: number = content.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        // 合法代理对
        const pair: CodePointItem = { ch: content.substring(i, i + 2), code: code, length: 2 };
        out.push(pair);
        i += 2;
        continue;
      }
    }
    const single: CodePointItem = { ch: content.substring(i, i + 1), code: code, length: 1 };
    out.push(single);
    i++;
  }
  return out;
}

// ===== 文本估算 =====

/**
 * 估算文本 Token 数。
 *
 * 规则:
 * - 空字符串返回 0
 * - 不修改原始字符串
 * - CJK 字符:每个 1 Token
 * - ASCII 拉丁字母/数字连续段:每 4 字符向上取整 1 Token
 * - ASCII 标点:每个 1 Token
 * - 空白序列(同类空白连续出现):每段 1 Token(空字符串内无空白则 0)
 * - 其他 Unicode code point(emoji 等):每个 1 Token
 *
 * @param content 原始文本
 * @returns Token 数(非负整数)
 */
export function estimateTextTokens(content: string): number {
  if (content.length === 0) {
    return 0;
  }

  const cps: CodePointItem[] = iterateCodePoints(content);
  let tokens: number = 0;

  let latinRun: number = 0; // 当前累积的拉丁字母/数字连续字符数
  let lastWasLatin: boolean = false;

  for (let i = 0; i < cps.length; i++) {
    const item: CodePointItem = cps[i];
    const ch: string = item.ch;
    const code: number = item.code;

    // CJK 字符:1 Token
    if (isCjkCodePoint(code)) {
      if (lastWasLatin && latinRun > 0) {
        tokens += Math.ceil(latinRun / LATIN_TOKEN_CHARS);
        latinRun = 0;
      }
      lastWasLatin = false;
      tokens++;
      continue;
    }

    // ASCII 拉丁字母/数字:累积到 4 字符统一结算
    if (code < 0x80 && isAsciiAlnum(ch)) {
      latinRun++;
      lastWasLatin = true;
      continue;
    }

    // 结束当前拉丁词段(若有)
    if (lastWasLatin && latinRun > 0) {
      tokens += Math.ceil(latinRun / LATIN_TOKEN_CHARS);
      latinRun = 0;
    }
    lastWasLatin = false;

    // ASCII 标点:1 Token
    if (code < 0x80 && isAsciiPunctuation(ch)) {
      tokens++;
      continue;
    }

    // ASCII 空白:每个空白字符计 1 Token(被代理对单独处理时,若 surrogate 之后跟随空白仍会计入)
    // 注:这里采用"每个空白字符 1 Token"的简化策略。
    // 若字符串中存在代理对组成的多字符序列,空白单独计 1 Token。
    if (code < 0x80 && isAsciiWhitespace(ch)) {
      tokens++;
      continue;
    }

    // 其他 Unicode code point(emoji、符号、未配对代理等):1 Token
    tokens++;
  }

  // 收尾:剩余拉丁词段
  if (lastWasLatin && latinRun > 0) {
    tokens += Math.ceil(latinRun / LATIN_TOKEN_CHARS);
  }

  return tokens;
}

// ===== 消息与 Prompt 估算 =====

/**
 * 估算单条消息 Token 数。
 * 等于固定开销 + 文本估算。
 *
 * @param message 聊天消息
 * @returns Token 数(非负整数)
 */
export function estimateMessageTokens(message: ChatMessage): number {
  const textTokens: number = estimateTextTokens(message.content);
  return MESSAGE_FIXED_OVERHEAD + textTokens;
}

/**
 * 估算多条消息 Token 总数(每条消息固定开销 + 整段 Prompt 结尾开销)。
 *
 * @param messages 消息列表
 * @returns Token 数(非负整数)
 */
export function estimateMessagesTokens(messages: ChatMessage[]): number {
  let total: number = 0;
  for (let i = 0; i < messages.length; i++) {
    total += MESSAGE_FIXED_OVERHEAD + estimateTextTokens(messages[i].content);
  }
  if (messages.length > 0) {
    total += PROMPT_TRAILING_OVERHEAD;
  }
  return total;
}

// ===== TokenCounter 服务 =====

/**
 * Token 估算服务。
 *
 * 无状态,不持有聊天状态。
 * 所有方法为纯函数式估算,不会修改输入。
 */
export class TokenCounter {
  /**
   * 估算文本 Token 数。
   * @param content 原始文本
   * @returns Token 数(非负整数)
   */
  estimateText(content: string): number {
    return estimateTextTokens(content);
  }

  /**
   * 估算单条消息 Token 数(含固定结构开销)。
   * @param message 聊天消息
   * @returns Token 数(非负整数)
   */
  estimateMessage(message: ChatMessage): number {
    return estimateMessageTokens(message);
  }

  /**
   * 估算多条消息 Token 总数(含固定结构开销 + 结尾开销)。
   * @param messages 消息列表
   * @returns Token 数(非负整数)
   */
  estimateMessages(messages: ChatMessage[]): number {
    return estimateMessagesTokens(messages);
  }

  /**
   * 计算上下文 Token 预算结果。
   *
   * @param messages 最终请求消息列表
   * @param contextWindow 上下文窗口大小
   * @param reservedOutputTokens 预留给输出的 Token 数
   * @returns TokenBudget
   */
  calculateBudget(
    messages: ChatMessage[],
    contextWindow: number,
    reservedOutputTokens: number
  ): TokenBudget {
    const inputTokens: number = estimateMessagesTokens(messages);
    return createTokenBudget(inputTokens, contextWindow, reservedOutputTokens);
  }
}
