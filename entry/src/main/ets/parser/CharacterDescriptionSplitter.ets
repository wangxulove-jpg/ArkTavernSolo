/**
 * CharacterDescriptionSplitter 角色卡描述字段代码拆分器
 *
 * 背景:
 * 部分角色卡(尤其是中文人设卡)把所有设定都塞进「describe」字段,导致性格/场景/
 * 开场白/系统提示/示例对话等标准字段为空。本模块用**纯规则**把这些内容**忠实拆分**
 * 到标准 Tavern Card V2/V3 字段,完全不依赖 AI。
 *
 * 设计原则:
 * - 非破坏:只「搬运」内容,不删原文;识别不了的内容保留在 description。
 * - 启发式触发:仅当检测到 >= MIN_SECTIONS 个结构化标题时才拆分,避免把自由文本卡切坏。
 * - 字段映射对齐标准 Tavern Card V2/V3:
 *     name / description / personality / scenario / first_mes / system_prompt / mes_example
 * - 本模块只产出「建议的拆分结果」,是否覆盖已有字段由调用方决定(字段非空保留原值)。
 *
 * 约束:
 * - 纯逻辑,无 AI、无网络、无 ArkUI、无数据库,可本地单元测试。
 * - 不使用 regex 字面量(用 new RegExp),不使用 any/unknown,不使用结构类型。
 */

import { ParsedCharacterCard } from './CharacterCardJsonParser';

/** 拆分结果(description 为保留在描述字段的剩余内容;其余为各字段命中的内容) */
export interface DescriptionSplitResult {
  readonly name: string;
  readonly description: string;
  readonly personality: string;
  readonly scenario: string;
  readonly firstMessage: string;
  readonly systemPrompt: string;
  readonly mesExample: string;
}

/** 逻辑分段:标题 + 正文 */
interface Segment {
  title: string;
  body: string;
}

/** 触发拆分所需的最少结构化标题数量 */
const MIN_SECTIONS: number = 2;

// ===== 标题识别(用 new RegExp,避免 regex 字面量) =====
const RE_MD_HEADING: RegExp = new RegExp('^#{1,6}\\s');
const RE_CN_BRACKET: RegExp = new RegExp('^【.+】\\s*$');
const RE_SQ_BRACKET: RegExp = new RegExp('^\\[.+\\]\\s*$');
const RE_CN_NUM: RegExp = new RegExp('^[一二三四五六七八九十]+[、.．]\\s*');
const RE_DIGIT_NUM: RegExp = new RegExp('^\\d+[、.．)）]\\s*');
const RE_LIST_MARK: RegExp = new RegExp('^[-*·•]\\s*');

// ===== 各字段关键字(用于小节归类;含中英文常见写法以扩大覆盖) =====
const NAME_KEYS: string[] = ['姓名', '角色名', '名字', '昵称', 'name', 'nickname', 'role'];
const PERSONALITY_KEYS: string[] = [
  '性格', '人格', '说话风格', '口癖', '语气', '语言风格', '说话方式', '讲话', '言谈',
  '行为习惯', '个性', 'personality', 'speech', 'tone', 'manner'
];
const SYSTEM_KEYS: string[] = [
  '系统指令', '系统提示', '系统', '输出规则', '禁止', '规则', '扮演指南', '角色扮演指南',
  '注意事项', '注意', '不要', '不能', '行为准则', '准则', '指南', '指令', '要求', '限制',
  '元指令', 'system prompt', 'system instruction', 'instruction', 'guideline', 'rule', 'rules',
  'systemper', '禁止事项', 'set instructions'
];
const SCENARIO_KEYS: string[] = [
  '场景', '世界观', '相遇', '初始情境', '初始', '情境', '背景设定', '设定背景',
  'setting', 'scenario', 'world', '背景介绍'
];
const FIRST_MES_KEYS: string[] = [
  '开场白', '首次对话', '首次', '开场', '初始问候',
  'first message', 'first_mes', 'greeting'
];
const MES_EXAMPLE_KEYS: string[] = [
  '示例对话', '对话示例', '对话范例', '范例', '例子', '对话例子',
  'example', 'examples', 'dialogue example', 'dialogue examples'
];

/**
 * 拆分角色卡描述文本。
 *
 * @param text 角色卡 description 字段的全文
 * @returns 拆分结果。若未检测到足够的结构化标题,返回空拆分(description 保持原文)。
 */
export function splitCharacterDescription(text: string): DescriptionSplitResult {
  const empty: DescriptionSplitResult = {
    name: '', description: text, personality: '', scenario: '',
    firstMessage: '', systemPrompt: '', mesExample: ''
  };
  if (text.length === 0) {
    return empty;
  }

  const segments: Segment[] = extractSegments(text);
  if (segments.length < MIN_SECTIONS) {
    return empty;
  }

  const name: string = extractName(text);

  const personalityParts: string[] = [];
  const scenarioParts: string[] = [];
  const firstMessageParts: string[] = [];
  const systemPromptParts: string[] = [];
  const mesExampleParts: string[] = [];
  const descriptionParts: string[] = [];

  for (let i: number = 0; i < segments.length; i++) {
    const seg: Segment = segments[i];
    const block: string = seg.title.length > 0 ? (seg.title + '\n' + seg.body) : seg.body;
    const field: string = classifySegment(seg);
    if (field === 'personality') {
      personalityParts.push(block);
    } else if (field === 'scenario') {
      scenarioParts.push(block);
    } else if (field === 'firstMessage') {
      firstMessageParts.push(block);
    } else if (field === 'systemPrompt') {
      systemPromptParts.push(block);
    } else if (field === 'mesExample') {
      mesExampleParts.push(block);
    } else {
      descriptionParts.push(block);
    }
  }

  const description: string = joinNonEmpty(descriptionParts);
  const personality: string = joinNonEmpty(personalityParts);
  const scenario: string = joinNonEmpty(scenarioParts);
  const firstMessage: string = joinNonEmpty(firstMessageParts);
  const systemPrompt: string = joinNonEmpty(systemPromptParts);
  const mesExample: string = joinNonEmpty(mesExampleParts);

  // 兜底:若描述被拆空,保留原文,避免丢内容
  const finalDescription: string = description.length > 0 ? description : text;

  return {
    name: name,
    description: finalDescription,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMessage,
    systemPrompt: systemPrompt,
    mesExample: mesExample
  };
}

/**
 * 把文本按标题拆成分段。首个标题之前的内容作为「前言」分段(标题为空)。
 */
function extractSegments(text: string): Segment[] {
  const lines: string[] = text.split('\n');
  const headerIndices: number[] = [];
  for (let i: number = 0; i < lines.length; i++) {
    if (isHeaderLine(lines[i])) {
      headerIndices.push(i);
    }
  }

  const segments: Segment[] = [];
  if (headerIndices.length === 0) {
    return segments;
  }

  // 前言(第一个标题之前,非空才加入)
  const firstHeader: number = headerIndices[0];
  const preambleLines: string[] = lines.slice(0, firstHeader);
  const preamble: string = joinNonEmpty(preambleLines);
  if (preamble.length > 0) {
    segments.push({ title: '', body: preamble });
  }

  for (let i: number = 0; i < headerIndices.length; i++) {
    const start: number = headerIndices[i];
    const end: number = i + 1 < headerIndices.length ? headerIndices[i + 1] : lines.length;
    const title: string = lines[start].trim();
    const bodyLines: string[] = lines.slice(start + 1, end);
    const body: string = joinNonEmpty(bodyLines);
    segments.push({ title: title, body: body });
  }

  return segments;
}

/**
 * 判断一行是否为「标题」。
 * 覆盖:Markdown 标题、中括号/方括号小标题、中文数字/数字小标题、短「：」结尾标题、系统指令行。
 */
function isHeaderLine(line: string): boolean {
  const trimmed: string = line.trim();
  if (trimmed.length === 0) {
    return false;
  }
  if (RE_MD_HEADING.test(trimmed)) {
    return true;
  }
  if (RE_CN_BRACKET.test(trimmed)) {
    return true;
  }
  if (RE_SQ_BRACKET.test(trimmed)) {
    return true;
  }
  // 中文数字/数字小标题(但 "1. - 内容" 这类列表项不算标题)
  if (RE_DIGIT_NUM.test(trimmed)) {
    const rest: string = trimmed.replace(RE_DIGIT_NUM, '');
    if (!RE_LIST_MARK.test(rest)) {
      return true;
    }
  }
  if (RE_CN_NUM.test(trimmed)) {
    const rest: string = trimmed.replace(RE_CN_NUM, '');
    if (!RE_LIST_MARK.test(rest)) {
      return true;
    }
  }
  if (isSystemDirectiveLine(trimmed)) {
    return true;
  }
  // 短「：/:」结尾的标题(常见于 Section 标题)
  if (trimmed.length <= 30) {
    const hasColon: boolean = trimmed.endsWith('：') || trimmed.endsWith(':')
      || (trimmed.endsWith('）') && trimmed.indexOf('：') >= 0);
    if (hasColon) {
      return true;
    }
  }
  return false;
}

/**
 * 判断是否系统指令行(如 "System Instruction: ...",即使很长也视为标题)。
 */
function isSystemDirectiveLine(trimmed: string): boolean {
  const lower: string = trimmed.toLowerCase();
  if (lower.indexOf('system instruction') === 0) {
    return true;
  }
  if (lower.indexOf('system prompt') === 0) {
    return true;
  }
  if (lower.indexOf('systemp') === 0) {
    return true;
  }
  if (trimmed.indexOf('系统指令') === 0 || trimmed.indexOf('系统提示') === 0) {
    return true;
  }
  return false;
}

/**
 * 从整段文本提取角色名(优先取「姓名/Role/昵称」等带冒号的值)。
 */
function extractName(text: string): string {
  const lines: string[] = text.split('\n');
  for (let i: number = 0; i < lines.length; i++) {
    const trimmed: string = lines[i].trim();
    const value: string = extractNameFromLine(trimmed);
    if (value.length > 0 && !isPlaceholderName(value)) {
      return value;
    }
    // 也支持 "# Role: X" / "Role: X"
  }
  return '';
}

/**
 * 从单行提取名字。
 * 支持 "姓名：X" / "Role: X" / "name: X" 等,且能容忍前导的 Markdown 标题标记(#)、
 * 列表标记(- 或 * 或 圆点)与序号。
 */
function extractNameFromLine(line: string): string {
  let l: string = line.trim();
  const reHeading: RegExp = new RegExp('^#{1,6}\\s+');
  l = l.replace(reHeading, '');
  const reList: RegExp = new RegExp('^[-*·•]\\s+');
  l = l.replace(reList, '');
  const reNum: RegExp = new RegExp('^\\d+[、.．)）]\\s*');
  l = l.replace(reNum, '');
  const RE_NAME: RegExp = new RegExp('^(姓名|角色名|名字|昵称|name|nickname|role)\\s*[:：]\\s*(.+)$', 'i');
  const m: RegExpMatchArray | null = l.match(RE_NAME);
  if (m !== null && m.length > 2) {
    return m[2].trim();
  }
  return '';
}

/**
 * 判断是否为占位符名字(避免把 "Role"、"{{user}}" 等当名字)。
 */
function isPlaceholderName(value: string): boolean {
  const v: string = value.toLowerCase();
  if (v.indexOf('{{') >= 0) {
    return true;
  }
  if (v === 'role' || v === 'name' || v === 'nickname' || v === '角色' || v === '未命名') {
    return true;
  }
  const reDigits: RegExp = new RegExp('^\\d+$');
  if (reDigits.test(v)) {
    return true;
  }
  return false;
}

/**
 * 归类一个分段到字段。
 * 通过统计标题+正文中各字段关键字出现次数,取最高分;同分按优先级(mesExample > systemPrompt
 * > firstMessage > personality > scenario > description)。无命中则保留在 description。
 * 英文关键字做大小写不敏感匹配(先将文本转小写)。
 */
function classifySegment(seg: Segment): string {
  const hay: string = (seg.title + '\n' + seg.body).toLowerCase();

  const mesScore: number = countHits(hay, MES_EXAMPLE_KEYS);
  const systemScore: number = countHits(hay, SYSTEM_KEYS);
  const firstScore: number = countHits(hay, FIRST_MES_KEYS);
  const personalityScore: number = countHits(hay, PERSONALITY_KEYS);
  const scenarioScore: number = countHits(hay, SCENARIO_KEYS);

  // description 为兜底;命中更多高优先级字段的分段会覆盖它,同分时高优先级字段胜出
  let best: string = 'description';
  let bestScore: number = 0;

  if (mesScore > bestScore) {
    best = 'mesExample';
    bestScore = mesScore;
  }
  if (systemScore > bestScore) {
    best = 'systemPrompt';
    bestScore = systemScore;
  }
  if (firstScore > bestScore) {
    best = 'firstMessage';
    bestScore = firstScore;
  }
  if (personalityScore > bestScore) {
    best = 'personality';
    bestScore = personalityScore;
  }
  if (scenarioScore > bestScore) {
    best = 'scenario';
    bestScore = scenarioScore;
  }
  return best;
}

/**
 * 统计文本中命中的关键字个数(每个关键字只计一次,避免重复累计放大)。
 */
function countHits(text: string, keys: string[]): number {
  let count: number = 0;
  for (let i: number = 0; i < keys.length; i++) {
    if (text.indexOf(keys[i]) >= 0) {
      count++;
    }
  }
  return count;
}

/**
 * 将若干非空片段用空行拼接;全空则返回空串。
 */
function joinNonEmpty(parts: string[]): string {
  const nonEmpty: string[] = [];
  for (let i: number = 0; i < parts.length; i++) {
    const p: string = parts[i].trim();
    if (p.length > 0) {
      nonEmpty.push(p);
    }
  }
  return nonEmpty.join('\n\n');
}

/**
 * 将代码拆分结果应用到角色卡。
 *
 * 策略(字段非空保留原值 + 非破坏):
 * - 每个文本字段(personality/scenario/firstMessage/systemPrompt/mesExample/name):
 *   原字段非空则保留原值,否则用拆分结果填充。
 * - 凡是"原字段非空、但拆分结果也非空"而未被采用的拆分块,追加回 description,保证不丢内容。
 * - 无结构化拆分结果时原样返回。
 */
export function applyDescriptionSplit(card: ParsedCharacterCard): ParsedCharacterCard {
  const split: DescriptionSplitResult = splitCharacterDescription(card.description);

  const hasSplit: boolean = split.personality.length > 0 || split.scenario.length > 0
    || split.firstMessage.length > 0 || split.systemPrompt.length > 0
    || split.mesExample.length > 0;
  if (!hasSplit) {
    return card;
  }

  const personality: string = card.personality.length > 0 ? card.personality : split.personality;
  const scenario: string = card.scenario.length > 0 ? card.scenario : split.scenario;
  const firstMessage: string = card.firstMessage.length > 0 ? card.firstMessage : split.firstMessage;
  const systemPrompt: string = card.systemPrompt.length > 0 ? card.systemPrompt : split.systemPrompt;
  const mesExample: string = card.mesExample.length > 0 ? card.mesExample : split.mesExample;
  const name: string = card.name.length > 0 ? card.name : split.name;

  let description: string = split.description;
  // 非破坏保证:未被采用(因原字段非空)的拆分内容追加回 description
  if (card.scenario.length > 0 && split.scenario.length > 0) {
    description = appendBlock(description, split.scenario);
  }
  if (card.personality.length > 0 && split.personality.length > 0) {
    description = appendBlock(description, split.personality);
  }
  if (card.firstMessage.length > 0 && split.firstMessage.length > 0) {
    description = appendBlock(description, split.firstMessage);
  }
  if (card.systemPrompt.length > 0 && split.systemPrompt.length > 0) {
    description = appendBlock(description, split.systemPrompt);
  }
  if (card.mesExample.length > 0 && split.mesExample.length > 0) {
    description = appendBlock(description, split.mesExample);
  }

  const result: ParsedCharacterCard = {
    name: name,
    description: description,
    personality: personality,
    scenario: scenario,
    firstMessage: firstMessage,
    systemPrompt: systemPrompt,
    avatarUri: card.avatarUri,
    sourceFormat: card.sourceFormat,
    mesExample: mesExample,
    creatorNotes: card.creatorNotes,
    postHistoryInstructions: card.postHistoryInstructions,
    alternateGreetings: card.alternateGreetings,
    tags: card.tags,
    creator: card.creator,
    characterVersion: card.characterVersion,
    extensions: card.extensions,
    characterBook: card.characterBook,
    userName: card.userName,
    nickname: card.nickname,
    groupOnlyGreetings: card.groupOnlyGreetings,
    creatorNotesMultilingual: card.creatorNotesMultilingual,
    source: card.source,
    assets: card.assets,
    creationDate: card.creationDate,
    modificationDate: card.modificationDate
  };
  return result;
}

/**
 * 把一个块追加到基础文本末尾(空行分隔)。
 */
function appendBlock(base: string, block: string): string {
  const b: string = block.trim();
  if (b.length === 0) {
    return base;
  }
  return base.length > 0 ? (base + '\n\n' + b) : b;
}
