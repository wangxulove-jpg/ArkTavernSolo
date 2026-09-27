/**
 * ChatTextContract ChatService 契约常量与文本纯函数(自 ChatService 下沉)
 *
 * 内容:
 * - Preferences key 常量:全局用户称呼 / 状态指令 / 世界书激活方式与深度 / 记忆开关 / 代写与续写引导
 * - 世界书全局默认值常量(DEFAULT_LOREBOOK_*)
 * - 前端交互记录与角色状态文本纯函数(便于单测;ChatService 对应方法委托这些实现)
 *
 * 页面与 ViewModel 直接引用本模块,不再经 ChatService 转出。
 */

import { ChatStatusEntry, ChatStatusSchemaEntry } from '../models/ChatStatusState';
import { LorebookEntry, LorebookActivationMode } from '../models/Lorebook';

/** 全局用户称呼 Preferences key(v9 引入,存储在 AppPreferences 中的字符串) */
export const GLOBAL_USER_NAME_KEY: string = 'global_user_name';

/** 状态输出指令开关 Preferences key(全局,跨会话,默认 true) */
export const STATUS_INSTRUCTION_PREFS_KEY: string = 'status_instruction_enabled';

/** 世界书全局默认激活方式 Preferences key(全局,跨会话,默认 StickyOnDemand) */
export const LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY: string = 'lorebook_activation_default';

/** 世界书深度注入位置 Preferences key(全局,跨会话,整数 0-8,默认 0=对话之后) */
export const LOREBOOK_INJECTION_DEPTH_PREFS_KEY: string = 'lorebook_injection_depth';
/** v44: 记忆关键词检索开关(MemoryKeyword 注入段),默认关闭以保缓存命中率 */
export const MEMORY_KEYWORD_RETRIEVAL_PREFS_KEY: string = 'memory_keyword_retrieval';

/** 世界书全局默认激活方式默认值(v46: 改为 StickyOnDemand,append-only 保缓存前缀) */
export const DEFAULT_LOREBOOK_ACTIVATION_MODE: LorebookActivationMode = LorebookActivationMode.StickyOnDemand;

/** 世界书深度注入默认深度(v46: 默认 0=全部消息之后,不打断对话前缀) */
export const DEFAULT_LOREBOOK_INJECTION_DEPTH: number = 0;

/** 自动记忆总结开关 Preferences key(全局,跨会话,默认 false) */
export const MEMORY_AUTO_SUMMARY_PREFS_KEY: string = 'memory_auto_summary_enabled';

/** 前端卡交互记录:最多保留条数(v50,契约 v3 appendInteraction) */
export const FRONTEND_INTERACTION_MAX_ITEMS: number = 30;
/** 前端卡交互记录:注入提示词时的字符上限(超出从最旧开始丢) */
export const FRONTEND_INTERACTION_MAX_CHARS: number = 2000;
/** v47: 尾部「当前仍生效的设定」提醒最多列出的条目数(只列条目名,控制体积) */
export const STICKY_REMINDER_MAX_ITEMS: number = 12;

// ===== 纯函数(便于单测;ChatService 对应方法均委托这些实现) =====

/**
 * 交互记录入队:空文本忽略并返回 false;超条数从最旧丢;超字符数从最旧继续丢(至少保留 1 条)。
 */
export function pushFrontendInteractionRecord(records: string[], text: string): boolean {
  const content: string = text.trim();
  if (content.length === 0) {
    return false;
  }
  records.push(content);
  while (records.length > FRONTEND_INTERACTION_MAX_ITEMS) {
    records.shift();
  }
  let total: number = 0;
  for (let i = 0; i < records.length; i++) {
    total += records[i].length;
  }
  while (records.length > 1 && total > FRONTEND_INTERACTION_MAX_CHARS) {
    const removed: string | undefined = records.shift();
    total -= removed !== undefined ? removed.length : 0;
  }
  return true;
}

/**
 * 构建「前端交互记录」提示词段文本:无记录返回空串(PromptBuilder 据此不产生段)。
 * 不带时间戳:省 token,内容 append-only 对前缀缓存友好。
 */
export function buildFrontendInteractionText(records: string[]): string {
  if (records.length === 0) {
    return '';
  }
  const lines: string[] = [];
  for (let i = 0; i < records.length; i++) {
    lines.push('- ' + records[i]);
  }
  return '【前端交互记录】\n'
    + '以下是玩家在角色卡界面里的操作(按发生顺序),仅供你了解玩家做过什么,不要在正文中复述本段:\n'
    + lines.join('\n');
}

/**
 * 状态字段指令行:「- 金币｜说明:钱｜当前值:999(由界面/玩家设定)｜已锁定(不可更新)」。
 * 当前值让模型看到玩家/界面改过什么(零额外请求)。
 * 仅用于一次性请求(重新生成字段 / AI 修改状态)——那种请求不走缓存。
 */
export function formatStatusFieldInstructionLine(
  name: string, desc: string, value: string, fromUser: boolean, locked: boolean
): string {
  const descPart: string = desc.length > 0 ? '｜说明:' + desc : '';
  const lockedPart: string = locked ? '｜已锁定(不可更新)' : '';
  const valuePart: string = '｜当前值:' + (value.length > 0 ? value : '(空)');
  const sourcePart: string = fromUser ? '(由界面/玩家设定)' : '';
  return '- ' + name + descPart + valuePart + sourcePart + lockedPart;
}

/**
 * 是否存在可更新字段(全 locked / 空 schema 时返回 false,状态功能视为整体禁用)。
 * 规则段与当前值段必须用同一判据,保证两段同进同出。
 */
function hasUpdatableStatusFields(schema: ChatStatusSchemaEntry[]): boolean {
  for (let i = 0; i < schema.length; i++) {
    if (!schema[i].locked) {
      return true;
    }
  }
  return false;
}

/**
 * 构建状态**稳定段**文本:格式要求 + 字段清单(字段名/说明/locked 标记),**不含当前值**。
 *
 * 该文本只随角色卡 status schema 变化,同一张卡逐轮逐字相同,
 * 因此注入到稳定前缀(DialogueExamples 之后、记忆之前),命中缓存。
 *
 * @returns 无 schema / 无可更新字段时返回空串(不注入,状态功能整体禁用)
 */
export function buildStatusRuleText(schema: ChatStatusSchemaEntry[]): string {
  if (!hasUpdatableStatusFields(schema)) {
    return '';
  }
  const updatable: string[] = [];
  const lockedLines: string[] = [];
  for (let i = 0; i < schema.length; i++) {
    const e: ChatStatusSchemaEntry = schema[i];
    const descPart: string = e.desc.length > 0 ? '｜说明:' + e.desc : '';
    if (e.locked) {
      lockedLines.push('- ' + e.name + descPart + '｜已锁定(不可更新)');
    } else {
      updatable.push('- ' + e.name + descPart);
    }
  }
  const lockedText: string = lockedLines.length > 0
    ? '- 以下字段已锁定,严禁输出:\n' + lockedLines.join('\n') + '\n'
    : '';
  return '【角色状态输出规则】\n' +
    '在回复正文之后,单独输出一行 JSON 状态块,格式严格如下(正文中不要提及状态块):\n' +
    '<|status|>\n' +
    '{"字段名":"值"}\n' +
    '<|/status|>\n' +
    '- 状态块只能包含这些字段,字段名与数量必须完全一致,严禁新增或删除字段\n' +
    '- 每轮都要重新输出全部字段的最新值,反映当前进展;若剧情没有变化,值保持不变\n' +
    '- 需要输出的字段(逐行「字段名｜说明」,顺序固定):\n' +
    updatable.join('\n') + '\n' +
    lockedText;
}

/**
 * 构建状态**易变段**文本:只列各字段的当前值,不含格式要求与字段说明。
 *
 * 内容每轮都可能变(模型更新 / 卡片界面 setState / 一键重新生成),
 * 固定作为请求的最后一条消息追加,使其之前的内容(含整段对话历史)不受影响。
 *
 * @returns 无 schema / 无可更新字段时返回空串(不注入)
 */
export function buildStatusValuesText(
  schema: ChatStatusSchemaEntry[], entries: ChatStatusEntry[]
): string {
  if (!hasUpdatableStatusFields(schema)) {
    return '';
  }
  const lines: string[] = [];
  for (let i = 0; i < schema.length; i++) {
    const e: ChatStatusSchemaEntry = schema[i];
    let value: string = '';
    let fromUser: boolean = false;
    for (let j = 0; j < entries.length; j++) {
      if (entries[j].name === e.name) {
        value = entries[j].value;
        fromUser = entries[j].fromUser;
        break;
      }
    }
    const lockedPart: string = e.locked ? '｜已锁定' : '';
    const sourcePart: string = fromUser ? '(由界面/玩家设定)' : '';
    lines.push('- ' + e.name + ':' + (value.length > 0 ? value : '(空)') + sourcePart + lockedPart);
  }
  return '【角色状态当前值】\n' +
    '以下是各字段的最新状态,仅供你了解现状(输出仍是纯值),不要复述本段:\n' +
    lines.join('\n');
}

/**
 * 构建状态输出指令文本(声明式 v1,规则与当前值合并为一段)。
 * 供**一次性请求**使用(重新生成字段 / AI 修改状态),这类请求短暂且不走前缀缓存。
 * 主聊天链路请改用 buildStatusRuleText(稳定前缀) + buildStatusValuesText(请求最末)。
 * - 无声明 schema / 全部 locked → 返回空串(不注入,状态功能整体禁用)
 * - regenerate=true → 只输出 JSON(一次性刷新字段)
 * - 正常路径 → 正文后附带 <|status|> 状态块;locked 字段单列作参考、严禁输出
 */
export function buildStatusInstructionText(
  schema: ChatStatusSchemaEntry[], entries: ChatStatusEntry[], regenerate: boolean
): string {
  if (schema.length === 0) {
    return '';
  }
  const updatable: string[] = [];
  const lockedLines: string[] = [];
  for (let i = 0; i < schema.length; i++) {
    const e: ChatStatusSchemaEntry = schema[i];
    let value: string = '';
    let fromUser: boolean = false;
    for (let j = 0; j < entries.length; j++) {
      if (entries[j].name === e.name) {
        value = entries[j].value;
        fromUser = entries[j].fromUser;
        break;
      }
    }
    const line: string = formatStatusFieldInstructionLine(e.name, e.desc, value, fromUser, e.locked);
    if (e.locked) {
      lockedLines.push(line);
    } else {
      updatable.push(line);
    }
  }
  if (updatable.length === 0) {
    return '';
  }
  const fieldsText: string = updatable.join('\n');
  const lockedText: string = lockedLines.length > 0
    ? '\n- 以下字段已锁定,仅列出当前值供你参考,严禁输出:\n' + lockedLines.join('\n')
    : '';
  if (regenerate) {
    return '【角色状态输出规则】\n' +
      '根据角色当前处境,为下面这些状态维度生成/刷新当前值。' +
      '只输出一个 JSON 对象,不要输出任何其他文字或解释:\n' +
      '{"字段名":"值"}\n' +
      '- 严格只包含这些字段,数量与字段名完全一致,不要新增或删除(列出格式为「字段名｜说明｜当前值」,' +
      '当前值仅供你了解现状,输出仍是纯值):\n' +
      fieldsText;
  }
  return '【角色状态输出规则】\n' +
    '在回复正文之后,单独输出一行 JSON 状态块,格式严格如下(正文中不要提及状态块):\n' +
    '<|status|>\n' +
    '{"字段名":"值"}\n' +
    '<|/status|>\n' +
    '- 状态块只能包含这些字段,字段名与数量必须完全一致,严禁新增或删除字段\n' +
    '- 下列每行的「当前值」反映最新状态(可能由玩家在卡片界面里调整过),仅供你了解现状,输出仍是纯值:\n' +
    fieldsText + lockedText + '\n' +
    '- 每轮都要重新输出全部字段的最新值,反映当前进展;若剧情没有变化,值保持不变';
}

/**
 * v47: 构建「当前仍生效的设定」提醒文本。
 * 只列条目名、不含内容;names 为空返回空串(PromptBuilder/调用方据此不产生段)。
 */
export function buildStickyReminderText(names: string[]): string {
  if (names.length === 0) {
    return '';
  }
  return '【当前仍生效的设定】\n'
    + '以下世界书条目已在对话中加载且仍然有效,涉及相关情节时请遵循'
    + '(完整内容在对话历史中,勿凭猜测改写):\n- '
    + names.join('\n- ');
}

/**
 * v47: 从"已加载的粘滞条目"中挑出"本轮仍然关键词命中"的条目名。
 * - 顺序按 loaded(首次命中顺序)而非 matched,保证提醒行内容稳定
 * - 去重:同一 id 只出现一次
 * - 最多 max 个(0 或负数表示不限制)
 */
export function pickHotStickyNames(
  loaded: LorebookEntry[], matched: LorebookEntry[], max: number
): string[] {
  if (loaded.length === 0 || matched.length === 0) {
    return [];
  }
  const hotIds: Set<string> = new Set();
  for (let i = 0; i < matched.length; i++) {
    hotIds.add(matched[i].id);
  }
  const names: string[] = [];
  const seen: Set<string> = new Set();
  for (let i = 0; i < loaded.length; i++) {
    const entry: LorebookEntry = loaded[i];
    if (!hotIds.has(entry.id) || seen.has(entry.id)) {
      continue;
    }
    if (max > 0 && names.length >= max) {
      break;
    }
    seen.add(entry.id);
    names.push(entry.name);
  }
  return names;
}

/** 代写(🎭3候选)引导指令 Preferences key(全局,跨会话;空=用内置默认中文提示词) */
export const IMPRES_GUIDE_KEY: string = 'impres_guide_prompt';

/** 续写(⚡单次)引导指令 Preferences key(全局,跨会话;空=用内置默认中文提示词) */
export const CONTINUE_GUIDE_KEY: string = 'continue_guide_prompt';
