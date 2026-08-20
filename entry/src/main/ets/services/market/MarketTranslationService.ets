/**
 * MarketTranslationService 市场翻译服务
 *
 * 复用 ModelService.sendChat 实现市场角色卡预览字段的中文翻译。
 *
 * 设计原则:
 * - 仅翻译市场预览字段(名称/简介/标签/创作者备注)
 * - 不翻译 remoteId、creator 用户名、来源 URL、Provider 名称
 * - 不翻译 PNG/JSON 原始角色卡、extensions、System Prompt、对话示例、世界书完整内容
 * - 翻译结果只用于市场 UI 展示,不写入 Character 模型或角色卡 extensions
 * - 不在日志中打印待翻译原文或翻译结果
 * - 失败时继续显示原文(返回 null,UI 显示原文)
 * - 页面离开后忽略过期结果(使用 operationId 机制)
 * - 不自动翻译隐藏的 NSFW 内容(由调用方过滤后传入)
 *
 * 性能策略:
 * - 批量翻译(每批最多 8 张卡)
 * - 防抖(350ms)
 * - 顺序处理批次(并发限制为 1,避免短时大量请求)
 * - 优先从缓存读取,缓存命中不发起请求
 * - 翻译缓存 30 天 TTL,远程角色更新时间或字段 hash 变化时自动失效
 */

import { ModelService } from '../ModelService';
import { MarketCacheStore, MarketTranslationCacheEntry } from './MarketCacheStore';
import { MarketCharacter } from '../../models/MarketCharacter';
import { MarketCharacterDetail } from '../../models/MarketCharacterDetail';
import {
  MarketTranslationResult,
  MarketDetailTranslation,
  hashString,
  hashStringArray
} from '../../models/MarketTranslation';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'MarketTranslationService';
/** 防抖时间(毫秒) */
const DEBOUNCE_MS: number = 350;
/** 单批最大卡片数 */
const BATCH_MAX_SIZE: number = 8;
/** 翻译温度(低温度保证稳定性) */
const TRANSLATE_TEMPERATURE: number = 0.3;
const TRANSLATE_TOP_P: number = 1.0;
/** 批量翻译最大输出 token */
const BATCH_MAX_TOKENS: number = 2048;
/** 详情翻译最大输出 token */
const DETAIL_MAX_TOKENS: number = 4096;

const BATCH_SYSTEM_PROMPT: string =
  'You are a translation assistant. Translate the given character card fields to Simplified Chinese. ' +
  'Rules: 1) Preserve proper nouns (names, places, works) in their original language; ' +
  '2) Keep each tag short (max 8 Chinese characters); ' +
  '3) Do NOT translate or modify the "id" field; ' +
  '4) Return ONLY a JSON array, no explanation, no markdown fences. ' +
  'Output format: [{"id":"...","name":"...","summary":"...","tags":["..."]}]';

const DETAIL_SYSTEM_PROMPT: string =
  'You are a translation assistant. Translate the given character card detail fields to Simplified Chinese. ' +
  'Rules: 1) Preserve proper nouns (names, places, works) in their original language; ' +
  '2) Keep each tag short (max 8 Chinese characters); ' +
  '3) Return ONLY a JSON object, no explanation, no markdown fences. ' +
  'Output format: {"name":"...","summary":"...","tags":["..."],"description":"...","personality":"...","scenario":"...","firstMessage":"...","creatorNotes":"..."}';

/**
 * 市场翻译服务。
 * 列表阶段批量翻译 + 防抖 + 缓存命中跳过。
 * 详情阶段同步翻译,复用列表缓存。
 */
export class MarketTranslationService {
  private readonly modelService: ModelService;
  private readonly cache: MarketCacheStore;
  /** 自增操作 ID,用于过期检测 */
  private operationId: number = 0;
  /** 防抖定时器 ID,-1 表示无任务 */
  private debounceTimerId: number = -1;

  constructor(modelService: ModelService, cache: MarketCacheStore) {
    this.modelService = modelService;
    this.cache = cache;
  }

  // ===== 偏好 =====

  /**
   * 读取"翻译为中文"开关状态(默认关闭)。
   */
  async isTranslateEnabled(): Promise<boolean> {
    return await this.cache.getTranslateEnabled();
  }

  /**
   * 保存"翻译为中文"开关状态。
   */
  async setTranslateEnabled(value: boolean): Promise<void> {
    await this.cache.setTranslateEnabled(value);
  }

  // ===== 列表翻译 =====

  /**
   * 读取单条翻译(仅从缓存,不发起网络请求)。
   * @returns 缓存命中返回翻译结果;未命中返回 null
   */
  async getCachedTranslation(item: MarketCharacter): Promise<MarketTranslationResult | null> {
    const fieldHash: number = computeListFieldHash(item);
    const entry: MarketTranslationCacheEntry | null = await this.cache.getTranslation(
      item.providerId, item.remoteId, item.updatedAt, fieldHash
    );
    if (entry === null) {
      return null;
    }
    return {
      name: entry.translatedName,
      summary: entry.translatedSummary,
      tags: entry.translatedTags.slice(),
      creatorNotes: entry.translatedCreatorNotes
    };
  }

  /**
   * 批量翻译当前可见卡片(防抖 + 顺序批次)。
   * 已缓存的条目跳过,未缓存的发起批量请求。
   * 页面离开时调用 cancelAll() 取消所有待执行任务。
   *
   * @param items 当前可见的卡片列表
   * @param onResult 单条翻译完成回调(只在新翻译完成时调用,缓存命中的不调用)
   */
  translateItems(
    items: MarketCharacter[],
    onResult: (remoteId: string, translation: MarketTranslationResult) => void
  ): void {
    this.operationId++;
    const opId: number = this.operationId;

    if (this.debounceTimerId !== -1) {
      clearTimeout(this.debounceTimerId);
      this.debounceTimerId = -1;
    }

    this.debounceTimerId = setTimeout((): void => {
      this.debounceTimerId = -1;
      this.executeBatchTranslation(opId, items, onResult);
    }, DEBOUNCE_MS);
  }

  /**
   * 取消所有翻译请求(页面离开时调用)。
   * 已发出的 HTTP 请求无法中止,但其结果会被忽略。
   */
  cancelAll(): void {
    this.operationId++;
    if (this.debounceTimerId !== -1) {
      clearTimeout(this.debounceTimerId);
      this.debounceTimerId = -1;
    }
  }

  // ===== 详情翻译 =====

  /**
   * 翻译详情(同步请求,详情字段不缓存)。
   * 列表阶段已缓存的字段(name/summary/tags)会从缓存读取,不重新翻译。
   * 失败时返回 null,UI 应继续显示原文。
   */
  async translateDetail(detail: MarketCharacterDetail): Promise<MarketDetailTranslation | null> {
    try {
      const base: MarketCharacter = detail.base;
      const listHash: number = computeListFieldHash(base);
      const listEntry: MarketTranslationCacheEntry | null = await this.cache.getTranslation(
        base.providerId, base.remoteId, base.updatedAt, listHash
      );

      // 构造待翻译字段
      const fieldsToTranslate: Record<string, Object> = {};
      fieldsToTranslate['description'] = detail.description;
      fieldsToTranslate['personality'] = detail.personality;
      fieldsToTranslate['scenario'] = detail.scenario;
      fieldsToTranslate['firstMessage'] = detail.firstMessagePreview;
      fieldsToTranslate['creatorNotes'] = detail.creatorNotes;

      if (listEntry === null) {
        // 列表阶段未缓存,也翻译基础字段
        fieldsToTranslate['name'] = base.name;
        fieldsToTranslate['summary'] = base.summary;
        fieldsToTranslate['tags'] = base.tags.slice();
      }

      const config = await this.modelService.getCurrentConfig();
      if (config === null) {
        Logger.warn(LOG_TAG, 'translateDetail: no current config');
        return null;
      }
      const modelName: string = config.modelName.trim();
      if (modelName.length === 0) {
        Logger.warn(LOG_TAG, 'translateDetail: empty model name');
        return null;
      }

      const userPrompt: string = JSON.stringify(fieldsToTranslate);
      const messages: ChatMessage[] = [
        createChatMessage('mt-sys', ChatRole.System, DETAIL_SYSTEM_PROMPT, Date.now()),
        createChatMessage('mt-usr', ChatRole.User, userPrompt, Date.now())
      ];
      const request: ChatRequest = {
        model: modelName,
        messages: messages,
        temperature: TRANSLATE_TEMPERATURE,
        topP: TRANSLATE_TOP_P,
        maxTokens: DETAIL_MAX_TOKENS,
        stream: false
      };

      const response = await this.modelService.sendChat(request);
      const parsed: Record<string, Object> | null = parseDetailResponse(response.content);
      if (parsed === null) {
        Logger.warn(LOG_TAG, 'translateDetail: parse failed');
        return null;
      }

      // 合并列表缓存
      const name: string = listEntry !== null
        ? listEntry.translatedName
        : getStringField(parsed, 'name', base.name);
      const summary: string = listEntry !== null
        ? listEntry.translatedSummary
        : getStringField(parsed, 'summary', base.summary);
      const tags: string[] = listEntry !== null
        ? listEntry.translatedTags.slice()
        : getStringArrayField(parsed, 'tags', base.tags.slice());
      const creatorNotes: string = getStringField(parsed, 'creatorNotes', '');

      // 写回列表缓存(如果之前没有)
      if (listEntry === null) {
        const entry: MarketTranslationCacheEntry = {
          providerId: base.providerId,
          remoteId: base.remoteId,
          remoteUpdatedAt: base.updatedAt,
          fieldHash: listHash,
          translatedName: name,
          translatedSummary: summary,
          translatedTags: tags.slice(),
          translatedCreatorNotes: creatorNotes,
          translatedAt: Date.now()
        };
        await this.cache.putTranslation(entry);
      }

      return {
        name: name,
        summary: summary,
        tags: tags,
        creatorNotes: creatorNotes,
        description: getStringField(parsed, 'description', detail.description),
        personality: getStringField(parsed, 'personality', detail.personality),
        scenario: getStringField(parsed, 'scenario', detail.scenario),
        firstMessagePreview: getStringField(parsed, 'firstMessage', detail.firstMessagePreview)
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'translateDetail failed: ' + String(e));
      return null;
    }
  }

  // ===== 缓存管理 =====

  /**
   * 清空全部翻译缓存。
   */
  async clearTranslationCache(): Promise<void> {
    await this.cache.clearTranslationCache();
  }

  // ===== 内部方法 =====

  /**
   * 执行批量翻译(防抖后调用)。
   */
  private async executeBatchTranslation(
    opId: number,
    items: MarketCharacter[],
    onResult: (remoteId: string, translation: MarketTranslationResult) => void
  ): Promise<void> {
    if (opId !== this.operationId) {
      return;
    }

    // 过滤掉已缓存的
    const pending: MarketCharacter[] = [];
    for (let i: number = 0; i < items.length; i++) {
      if (opId !== this.operationId) {
        return;
      }
      const item: MarketCharacter = items[i];
      const hash: number = computeListFieldHash(item);
      const cached: MarketTranslationCacheEntry | null = await this.cache.getTranslation(
        item.providerId, item.remoteId, item.updatedAt, hash
      );
      if (cached === null) {
        pending.push(item);
      }
    }

    if (pending.length === 0) {
      return;
    }

    // 顺序处理批次(并发限制为 1)
    for (let i: number = 0; i < pending.length; i += BATCH_MAX_SIZE) {
      if (opId !== this.operationId) {
        return;
      }
      const end: number = Math.min(i + BATCH_MAX_SIZE, pending.length);
      const batch: MarketCharacter[] = pending.slice(i, end);
      await this.translateBatch(opId, batch, onResult);
    }
  }

  /**
   * 翻译单批卡片。
   */
  private async translateBatch(
    opId: number,
    batch: MarketCharacter[],
    onResult: (remoteId: string, translation: MarketTranslationResult) => void
  ): Promise<void> {
    try {
      const config = await this.modelService.getCurrentConfig();
      if (config === null) {
        Logger.warn(LOG_TAG, 'translateBatch: no current config');
        return;
      }
      const modelName: string = config.modelName.trim();
      if (modelName.length === 0) {
        Logger.warn(LOG_TAG, 'translateBatch: empty model name');
        return;
      }

      // 构造 user prompt(JSON 数组,包含 id 用于回填)
      const itemsJson: Object[] = [];
      for (let i: number = 0; i < batch.length; i++) {
        const item: MarketCharacter = batch[i];
        const obj: Record<string, Object> = {};
        obj['id'] = item.remoteId;
        obj['name'] = item.name;
        obj['summary'] = item.summary;
        obj['tags'] = item.tags.slice();
        itemsJson.push(obj);
      }
      const userPrompt: string = JSON.stringify(itemsJson);

      const messages: ChatMessage[] = [
        createChatMessage('mt-sys', ChatRole.System, BATCH_SYSTEM_PROMPT, Date.now()),
        createChatMessage('mt-usr', ChatRole.User, userPrompt, Date.now())
      ];
      const request: ChatRequest = {
        model: modelName,
        messages: messages,
        temperature: TRANSLATE_TEMPERATURE,
        topP: TRANSLATE_TOP_P,
        maxTokens: BATCH_MAX_TOKENS,
        stream: false
      };

      const response = await this.modelService.sendChat(request);

      if (opId !== this.operationId) {
        return;
      }

      const parsed: Record<string, MarketTranslationResult> | null = parseBatchResponse(response.content, batch);
      if (parsed === null) {
        Logger.warn(LOG_TAG, 'translateBatch: parse failed');
        return;
      }

      // 写入缓存并回调
      for (let i: number = 0; i < batch.length; i++) {
        if (opId !== this.operationId) {
          return;
        }
        const item: MarketCharacter = batch[i];
        const t: MarketTranslationResult | undefined = parsed[item.remoteId];
        if (t === undefined) {
          continue;
        }
        const entry: MarketTranslationCacheEntry = {
          providerId: item.providerId,
          remoteId: item.remoteId,
          remoteUpdatedAt: item.updatedAt,
          fieldHash: computeListFieldHash(item),
          translatedName: t.name,
          translatedSummary: t.summary,
          translatedTags: t.tags.slice(),
          translatedCreatorNotes: '',
          translatedAt: Date.now()
        };
        await this.cache.putTranslation(entry);
        if (opId !== this.operationId) {
          return;
        }
        onResult(item.remoteId, t);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'translateBatch failed: ' + String(e));
    }
  }
}

// ===== 辅助函数 =====

/**
 * 计算列表阶段字段 hash(name + summary + tags)。
 * 用于检测原文是否变化,变化时缓存自动失效。
 */
function computeListFieldHash(item: MarketCharacter): number {
  const nameHash: number = hashString(item.name);
  const summaryHash: number = hashString(item.summary);
  const tagsHash: number = hashStringArray(item.tags);
  // 组合 hash(顺序敏感)
  return (nameHash ^ (summaryHash * 31) ^ (tagsHash * 67)) >>> 0;
}

/**
 * 从 JSON 对象中安全读取字符串字段。
 * 类型不匹配时返回默认值(原文)。
 */
function getStringField(obj: Record<string, Object>, key: string, defaultValue: string): string {
  const v: Object | undefined = obj[key];
  if (typeof v === 'string') {
    return v;
  }
  return defaultValue;
}

/**
 * 从 JSON 对象中安全读取字符串数组字段。
 * 类型不匹配时返回默认值(原文)。
 */
function getStringArrayField(obj: Record<string, Object>, key: string, defaultValue: string[]): string[] {
  const v: Object | undefined = obj[key];
  if (Array.isArray(v)) {
    const arr: Object[] = v as Object[];
    const result: string[] = [];
    for (let i: number = 0; i < arr.length; i++) {
      const t: Object = arr[i];
      if (typeof t === 'string') {
        result.push(t);
      }
    }
    return result;
  }
  return defaultValue;
}

/**
 * 去除 Markdown 代码围栏(如 ```json ... ```)。
 */
function stripMarkdownJson(text: string): string {
  let t: string = text.trim();
  if (t.startsWith('```')) {
    const firstNewline: number = t.indexOf('\n');
    if (firstNewline > 0) {
      t = t.substring(firstNewline + 1);
    }
    const endFence: number = t.lastIndexOf('```');
    if (endFence >= 0) {
      t = t.substring(0, endFence);
    }
    t = t.trim();
  }
  return t;
}

/**
 * 从可能含前后缀的文本中提取 JSON 片段。
 * @param text 原始文本
 * @param firstChar 起始字符('[' 或 '{')
 * @param lastChar 结束字符(']' 或 '}')
 */
function extractJson(text: string, firstChar: string, lastChar: string): string {
  const start: number = text.indexOf(firstChar);
  if (start < 0) {
    return text;
  }
  const end: number = text.lastIndexOf(lastChar);
  if (end <= start) {
    return text;
  }
  return text.substring(start, end + 1);
}

/**
 * 解析批量翻译响应。
 * 期望格式:[{"id":"...","name":"...","summary":"...","tags":["..."]}, ...]
 * 仅接受 batch 中存在的 id,避免 LLM 幻觉导致回填错乱。
 */
function parseBatchResponse(
  content: string,
  batch: MarketCharacter[]
): Record<string, MarketTranslationResult> | null {
  const stripped: string = stripMarkdownJson(content);
  const jsonStr: string = extractJson(stripped, '[', ']');
  let parsed: Object;
  try {
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    return null;
  }
  if (!Array.isArray(parsed)) {
    return null;
  }
  const arr: Object[] = parsed as Object[];

  // 构造合法 ID 集合
  const validIds: Record<string, boolean> = {};
  for (let i: number = 0; i < batch.length; i++) {
    validIds[batch[i].remoteId] = true;
  }

  const result: Record<string, MarketTranslationResult> = {};
  for (let i: number = 0; i < arr.length; i++) {
    const obj: Object = arr[i];
    if (typeof obj !== 'object' || obj === null) {
      continue;
    }
    const r: Record<string, Object> = obj as Record<string, Object>;
    const idRaw: Object | undefined = r['id'];
    if (typeof idRaw !== 'string') {
      continue;
    }
    if (!validIds[idRaw]) {
      continue;
    }
    const nameRaw: Object | undefined = r['name'];
    const summaryRaw: Object | undefined = r['summary'];
    const tagsRaw: Object | undefined = r['tags'];
    if (typeof nameRaw !== 'string' || typeof summaryRaw !== 'string') {
      continue;
    }
    const tags: string[] = [];
    if (Array.isArray(tagsRaw)) {
      const tagsArr: Object[] = tagsRaw as Object[];
      for (let j: number = 0; j < tagsArr.length; j++) {
        const t: Object = tagsArr[j];
        if (typeof t === 'string') {
          tags.push(t);
        }
      }
    }
    result[idRaw] = {
      name: nameRaw,
      summary: summaryRaw,
      tags: tags,
      creatorNotes: ''
    };
  }
  return result;
}

/**
 * 解析详情翻译响应。
 * 期望格式:{"name":"...","summary":"...","tags":["..."],"description":"...","personality":"...","scenario":"...","firstMessage":"...","creatorNotes":"..."}
 */
function parseDetailResponse(content: string): Record<string, Object> | null {
  const stripped: string = stripMarkdownJson(content);
  const jsonStr: string = extractJson(stripped, '{', '}');
  let parsed: Object;
  try {
    parsed = JSON.parse(jsonStr);
  } catch (e) {
    return null;
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return null;
  }
  return parsed as Record<string, Object>;
}
