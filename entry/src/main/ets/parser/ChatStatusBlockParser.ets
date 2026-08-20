/**
 * ChatStatusBlockParser 状态块解析器
 *
 * 从 AI 回复文本中提取并剥离隐藏的状态块:
 *   <|status|>
 *   {"字段名":"值"}
 *   <|/status|>
 *
 * 兼容多种模型输出格式:
 * 1. 标准标记块 <|status|> ... <|/status|>
 * 2. Markdown JSON 代码块围栏 ```json ... ```
 * 3. 末尾裸 JSON 对象 {...}
 *
 * 职责:
 * - 提取中间 JSON 并逐键转为 ChatStatusEntry(fromUser=false, locked=false)
 * - 剥离状态块及其前后多余换行,返回干净正文
 *
 * 约束:
 * - 不依赖 ArkUI / 网络层
 * - JSON 解析失败仅剥离标记、返回空数组,不抛错
 */

import { ChatStatusEntry, createChatStatusEntry } from '../models/ChatStatusState';

/** 状态块开始标记 */
export const STATUS_BLOCK_OPEN: string = '<|status|>';
/** 状态块结束标记 */
export const STATUS_BLOCK_CLOSE: string = '<|/status|>';

/**
 * 状态块提取结果。
 */
export interface ChatStatusExtractionResult {
  /** 剥离状态块后的正文 */
  readonly cleanContent: string;
  /** 从状态块解析出的字段(可能为空) */
  readonly parsedEntries: ChatStatusEntry[];
}

/**
 * 从回复文本中提取并剥离状态块。
 * @param content 完整回复文本
 * @returns 干净正文 + 解析出的字段
 */
export function extractStatusBlock(content: string): ChatStatusExtractionResult {
  // 1. 标准标记块
  const openIdx: number = content.lastIndexOf(STATUS_BLOCK_OPEN);
  if (openIdx >= 0) {
    const closeIdx: number = content.indexOf(STATUS_BLOCK_CLOSE, openIdx + STATUS_BLOCK_OPEN.length);
    if (closeIdx >= 0) {
      const inner: string = content.substring(openIdx + STATUS_BLOCK_OPEN.length, closeIdx);
      const parsedEntries: ChatStatusEntry[] = parseStatusJson(inner);
      const before: string = content.substring(0, openIdx);
      const after: string = content.substring(closeIdx + STATUS_BLOCK_CLOSE.length);
      const cleanContent: string = (before + after).trim();
      return { cleanContent: cleanContent, parsedEntries: parsedEntries };
    }
    // 有开始标记但无结束标记:剥离开始标记及其后的内容
    const clean: string = content.substring(0, openIdx);
    return { cleanContent: clean.trim(), parsedEntries: [] };
  }

  // 2. Markdown JSON 代码块围栏
  const fenceStart: number = content.indexOf('```');
  if (fenceStart >= 0) {
    const fenceInner: string | null = extractJsonFenceInner(content, fenceStart);
    if (fenceInner !== null) {
      const entries: ChatStatusEntry[] = parseStatusJson(fenceInner);
      if (entries.length > 0) {
        const fenceEnd: number = content.lastIndexOf('```');
        const clean: string = (content.substring(0, fenceStart) + content.substring(fenceEnd + 3)).trim();
        return { cleanContent: clean, parsedEntries: entries };
      }
    }
  }

  // 3. 末尾裸 JSON 对象
  const raw: string | null = extractTrailingJsonObject(content);
  if (raw !== null) {
    const entries: ChatStatusEntry[] = parseStatusJson(raw);
    if (entries.length > 0) {
      const idx: number = content.lastIndexOf(raw);
      const clean: string = content.substring(0, idx).trim();
      return { cleanContent: clean, parsedEntries: entries };
    }
  }

  // 4. 兜底:正文中残留的状态 JSON(标准标记已识别但 JSON 解析失败,或模型未按标准标记输出)。
  //    只要存在 <|status|> 开始标记,强制剥离该标记块(即使 JSON 解析失败),避免状态块残留到聊天气泡。
  if (content.indexOf(STATUS_BLOCK_OPEN) >= 0) {
    const openIdx: number = content.indexOf(STATUS_BLOCK_OPEN);
    const closeIdx: number = content.indexOf(STATUS_BLOCK_CLOSE, openIdx + STATUS_BLOCK_OPEN.length);
    if (closeIdx >= 0) {
      const before: string = content.substring(0, openIdx);
      const after: string = content.substring(closeIdx + STATUS_BLOCK_CLOSE.length);
      return { cleanContent: (before + after).trim(), parsedEntries: [] };
    }
    // 有开始标记但无结束标记:剥离开始标记及其后的内容
    return { cleanContent: content.substring(0, openIdx).trim(), parsedEntries: [] };
  }

  // 5. 兜底:整条回复就是纯状态 JSON(以 { 开头、以 } 结尾的单层对象),
  //   未解析出字段时也将其剥离,避免纯状态 JSON 直接显示在聊天气泡里。
  const pureJson: string | null = extractPureJsonObject(content);
  if (pureJson !== null) {
    return { cleanContent: '', parsedEntries: [] };
  }

  return { cleanContent: content, parsedEntries: [] };
}

/**
 * 解析状态块内的 JSON 对象为字段列表。
 * - 键作为字段名,值为 string/number/boolean 时转为字符串
 * - 空值、空字符串跳过
 * - 解析失败返回空数组
 */
function parseStatusJson(inner: string): ChatStatusEntry[] {
  const trimmed: string = stripCodeFence(inner.trim());
  if (trimmed.length === 0) {
    return [];
  }
  try {
    const obj: Record<string, Object> = JSON.parse(trimmed) as Record<string, Object>;
    const entries: ChatStatusEntry[] = [];
    const keys: string[] = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      const name: string = keys[i].trim();
      if (name.length === 0) {
        continue;
      }
      const raw: Object | undefined = obj[keys[i]];
      const value: string = valueToString(raw);
      if (value.length === 0) {
        continue;
      }
      entries.push(createChatStatusEntry(name, value, false, false));
    }
    return entries;
  } catch (e) {
    return [];
  }
}

/**
 * 去掉首尾的 ``` 围栏及可选的 json 语言标记。
 */
function stripCodeFence(text: string): string {
  let result: string = text.trim();
  if (result.startsWith('```')) {
    result = result.substring(3).trimStart();
    if (result.startsWith('json')) {
      result = result.substring(4).trimStart();
    }
  }
  if (result.endsWith('```')) {
    result = result.substring(0, result.length - 3).trimEnd();
  }
  return result;
}

/**
 * 从指定 fence 起点提取围栏内部的 JSON 文本(跳过 ```json 标记)。
 * 返回 null 表示内部不是有效的非空 JSON 对象。
 */
function extractJsonFenceInner(content: string, fenceStart: number): string | null {
  const after: string = content.substring(fenceStart + 3);
  const afterTrimmed: string = after.trimStart();
  let jsonStart: number = fenceStart + 3 + (after.length - afterTrimmed.length);
  if (afterTrimmed.startsWith('json')) {
    jsonStart += 4;
  }
  const fenceEnd: number = content.indexOf('```', jsonStart);
  if (fenceEnd < 0) {
    return null;
  }
  const inner: string = content.substring(jsonStart, fenceEnd).trim();
  if (inner.length === 0) {
    return null;
  }
  const stripped: string = stripCodeFence(inner);
  try {
    const obj: Record<string, Object> = JSON.parse(stripped) as Record<string, Object>;
    if (Object.keys(obj).length === 0) {
      return null;
    }
    return stripped;
  } catch (e) {
    return null;
  }
}

/**
 * 提取文本末尾的裸 JSON 对象(最后一个 {...}),返回 null 表示不存在或非对象。
 */
function extractTrailingJsonObject(content: string): string | null {
  const lastBrace: number = content.lastIndexOf('}');
  if (lastBrace < 0) {
    return null;
  }
  const firstBrace: number = content.lastIndexOf('{', lastBrace);
  if (firstBrace < 0) {
    return null;
  }
  const candidate: string = content.substring(firstBrace, lastBrace + 1);
  try {
    const obj: Record<string, Object> = JSON.parse(candidate) as Record<string, Object>;
    if (Object.keys(obj).length === 0) {
      return null;
    }
    return candidate;
  } catch (e) {
    return null;
  }
}

/**
 * 判断整条内容是否就是纯 JSON 对象(可能带少量首尾空白)。
 * 用于剥离"模型只输出了状态 JSON、没有正文"的情况。
 * 仅识别整条(trim 后)以 { 开头、以 } 结尾且开头前无正文的输入,避免误伤正常回复末尾的 JSON。
 */
function extractPureJsonObject(content: string): string | null {
  const trimmed: string = content.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    return null;
  }
  const lastBrace: number = trimmed.lastIndexOf('}');
  const firstBrace: number = trimmed.indexOf('{');
  if (firstBrace !== 0) {
    return null;
  }
  // 整条 = 一个 JSON 对象,开头前无任何正文
  const candidate: string = trimmed.substring(firstBrace, lastBrace + 1);
  try {
    const obj: Record<string, Object> = JSON.parse(candidate) as Record<string, Object>;
    if (Object.keys(obj).length === 0) {
      return null;
    }
    return candidate;
  } catch (e) {
    return null;
  }
}

/**
 * 将 JSON 基本类型值安全转为字符串。
 */
function valueToString(raw: Object | undefined): string {
  if (raw === undefined || raw === null) {
    return '';
  }
  if (typeof raw === 'string') {
    return (raw as string).trim();
  }
  if (typeof raw === 'number') {
    return String(raw as number);
  }
  if (typeof raw === 'boolean') {
    return String(raw as boolean);
  }
  return '';
}
