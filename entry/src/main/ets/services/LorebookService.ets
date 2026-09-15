/**
 * LorebookService 世界书业务服务
 *
 * 封装 LorebookRepository + LorebookSelectionStore,提供世界书 CRUD、条目管理、关键词匹配和注入构建。
 * 页面只通过 ViewModel 访问,不直接操作 Repository。
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不缓存 API Key
 * - 不存储聊天记录
 * - 匹配逻辑纯逻辑,不依赖网络
 * - 不持有 Legacy LorebookStore
 * - 不直接操作 SQL
 */

import {
  Lorebook,
  LorebookEntry,
  LorebookPosition,
  LorebookUpdates,
  LorebookEntryUpdates,
  createLorebook,
  createLorebookEntry,
  updateLorebook,
  addEntryToLorebook,
  removeEntryFromLorebook,
  updateEntryInLorebook,
  validateLorebook,
  validateLorebookEntry
} from '../models/Lorebook';
import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { LorebookRepository } from '../repositories/LorebookRepository';
import { LorebookSelectionStore } from '../storage/LorebookSelectionStore';
import { ParsedLorebookFile, buildLorebookFromParsed } from '../parser/LorebookJsonParser';

/** 默认扫描最近消息数 */
const DEFAULT_SCAN_MESSAGES: number = 10;
/** 默认最大注入字符数 */
const DEFAULT_MAX_INJECTION_CHARS: number = 12000;

/**
 * 注入结果。
 */
export interface LorebookInjection {
  /** BeforeCharacter 位置的 System 消息内容 */
  before: string;
  /** AfterCharacter 位置的 System 消息内容 */
  after: string;
}

export class LorebookService {
  private readonly repository: LorebookRepository;
  private readonly selectionStore: LorebookSelectionStore;
  private initialized: boolean = false;
  private readonly maxScanMessages: number;
  private readonly maxInjectionChars: number;

  constructor(
    repository: LorebookRepository,
    selectionStore: LorebookSelectionStore,
    maxScanMessages: number = DEFAULT_SCAN_MESSAGES,
    maxInjectionChars: number = DEFAULT_MAX_INJECTION_CHARS
  ) {
    this.repository = repository;
    this.selectionStore = selectionStore;
    this.maxScanMessages = maxScanMessages;
    this.maxInjectionChars = maxInjectionChars;
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    await this.selectionStore.initialize();
    this.initialized = true;
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('LorebookService not initialized');
    }
  }

  // ===== 世界书 CRUD =====

  async list(): Promise<Lorebook[]> {
    this.requireInit();
    return await this.repository.list();
  }

  async getById(id: string): Promise<Lorebook | null> {
    this.requireInit();
    return await this.repository.getById(id);
  }

  async create(name: string, description: string = ''): Promise<Lorebook> {
    this.requireInit();
    const lorebook: Lorebook = createLorebook(name, description);
    const error: string | null = validateLorebook(lorebook);
    if (error !== null) {
      throw new Error(error);
    }
    await this.repository.insert(lorebook);
    return lorebook;
  }

  /**
   * 批量导入一本世界书(含条目)。
   * 供"导入世界书"文件功能使用;条目已在 parser 中白名单解析与校验。
   */
  async importLorebook(parsed: ParsedLorebookFile): Promise<Lorebook> {
    this.requireInit();
    const lorebook: Lorebook = buildLorebookFromParsed(parsed);
    const error: string | null = validateLorebook(lorebook);
    if (error !== null) {
      throw new Error(error);
    }
    await this.repository.insert(lorebook);
    return lorebook;
  }

  /**
   * 用解析后的内容整册替换已有世界书(保留原 id/createdAt,替换 name/description/entries)。
   * 供"查看源码"编辑器保存使用。任意条目不符合规则时明确报错,不静默丢弃内容。
   */
  async replaceLorebookContent(id: string, parsed: ParsedLorebookFile): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.repository.getById(id);
    if (existing === null) {
      throw new Error('LorebookService replaceLorebookContent: not found');
    }
    // 明确校验,而不是静默丢弃:发现无效条目直接报错,保证 JSON 与保存结果一致
    const invalidNames: string[] = [];
    for (let i = 0; i < parsed.entries.length; i++) {
      const err: string | null = validateLorebookEntry(parsed.entries[i]);
      if (err !== null) {
        invalidNames.push(parsed.entries[i].name);
      }
    }
    if (invalidNames.length > 0) {
      throw new Error('存在无效条目(' + invalidNames.join('、') + '),请检查 JSON 后重新保存');
    }
    const base: Lorebook = createLorebook(parsed.name, parsed.description, parsed.enabled);
    const next: Lorebook = {
      id: id,
      name: base.name,
      description: base.description,
      enabled: base.enabled,
      activationMode: base.activationMode,
      injectionBudgetChars: base.injectionBudgetChars,
      entries: parsed.entries,
      createdAt: existing.createdAt,
      updatedAt: Date.now()
    };
    const error: string | null = validateLorebook(next);
    if (error !== null) {
      throw new Error(error);
    }
    await this.repository.update(next);
    return next;
  }

  async update(id: string, updates: LorebookUpdates): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.repository.getById(id);
    if (existing === null) {
      throw new Error('LorebookService update: not found');
    }
    const updated: Lorebook = updateLorebook(existing, updates);
    const error: string | null = validateLorebook(updated);
    if (error !== null) {
      throw new Error(error);
    }
    await this.repository.update(updated);
    return updated;
  }

  async remove(id: string): Promise<void> {
    this.requireInit();
    // 检查是否是当前世界书
    const currentId: string | null = await this.selectionStore.getCurrentLorebookId();
    if (currentId === id) {
      await this.selectionStore.setCurrentLorebookId(null);
    }
    await this.repository.remove(id);
  }

  async setCurrentLorebookId(id: string | null): Promise<void> {
    this.requireInit();
    if (id !== null && id.length > 0) {
      const exists: boolean = await this.repository.exists(id);
      if (!exists) {
        throw new Error('LorebookService setCurrentLorebookId: not found');
      }
    }
    await this.selectionStore.setCurrentLorebookId(id);
  }

  async getCurrentLorebookId(): Promise<string | null> {
    this.requireInit();
    return await this.selectionStore.getCurrentLorebookId();
  }

  async getCurrentLorebook(): Promise<Lorebook | null> {
    this.requireInit();
    const id: string | null = await this.selectionStore.getCurrentLorebookId();
    if (id === null) {
      return null;
    }
    const lorebook: Lorebook | null = await this.repository.getById(id);
    if (lorebook === null) {
      // 记录不存在,清空选择
      await this.selectionStore.setCurrentLorebookId(null);
      return null;
    }
    return lorebook;
  }

  // ===== 条目管理 =====

  async addEntry(
    lorebookId: string,
    name: string,
    keys: string[],
    secondaryKeys: string[],
    content: string,
    enabled: boolean = true,
    constant: boolean = false,
    selective: boolean = false,
    position: LorebookPosition = LorebookPosition.BeforeCharacter,
    priority: number = 0
  ): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.repository.getById(lorebookId);
    if (existing === null) {
      throw new Error('LorebookService addEntry: lorebook not found');
    }
    const entry: LorebookEntry = createLorebookEntry(
      name, keys, secondaryKeys, content, enabled, constant, selective, position, priority
    );
    const error: string | null = validateLorebookEntry(entry);
    if (error !== null) {
      throw new Error(error);
    }
    const updated: Lorebook = addEntryToLorebook(existing, entry);
    await this.repository.update(updated);
    return updated;
  }

  async updateEntry(
    lorebookId: string,
    entryId: string,
    updates: LorebookEntryUpdates
  ): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.repository.getById(lorebookId);
    if (existing === null) {
      throw new Error('LorebookService updateEntry: lorebook not found');
    }
    let entryFound: boolean = false;
    for (let i = 0; i < existing.entries.length; i++) {
      if (existing.entries[i].id === entryId) {
        entryFound = true;
        break;
      }
    }
    if (!entryFound) {
      throw new Error('LorebookService updateEntry: entry not found');
    }
    const updated: Lorebook = updateEntryInLorebook(existing, entryId, updates);
    const updatedEntry: LorebookEntry | null = this.findEntry(updated, entryId);
    if (updatedEntry !== null) {
      const error: string | null = validateLorebookEntry(updatedEntry);
      if (error !== null) {
        throw new Error(error);
      }
    }
    await this.repository.update(updated);
    return updated;
  }

  async removeEntry(lorebookId: string, entryId: string): Promise<Lorebook> {
    this.requireInit();
    const existing: Lorebook | null = await this.repository.getById(lorebookId);
    if (existing === null) {
      throw new Error('LorebookService removeEntry: lorebook not found');
    }
    const updated: Lorebook = removeEntryFromLorebook(existing, entryId);
    await this.repository.update(updated);
    return updated;
  }

  // ===== 关键词匹配 =====

  /**
   * 匹配世界书条目(同步,需要调用方传入 lorebook)。
   */
  matchEntries(messages: ChatMessage[]): LorebookEntry[] {
    const lorebook: Lorebook | null = this.getCurrentLorebookSync();
    if (lorebook === null || !lorebook.enabled) {
      return [];
    }
    return this.matchEntriesForLorebook(lorebook, messages);
  }

  /**
   * 构建注入内容(同步,需要调用方传入 lorebook)。
   */
  buildInjection(messages: ChatMessage[]): LorebookInjection {
    const entries: LorebookEntry[] = this.matchEntries(messages);
    const beforeParts: string[] = [];
    const afterParts: string[] = [];

    for (let i = 0; i < entries.length; i++) {
      const entry: LorebookEntry = entries[i];
      if (entry.position === LorebookPosition.BeforeCharacter) {
        beforeParts.push(entry.content);
      } else {
        afterParts.push(entry.content);
      }
    }

    const result: LorebookInjection = {
      before: beforeParts.join('\n\n'),
      after: afterParts.join('\n\n')
    };
    return result;
  }

  // ===== 内部方法 =====

  private getCurrentLorebookSync(): Lorebook | null {
    return null;
  }

  async matchEntriesAsync(messages: ChatMessage[]): Promise<LorebookEntry[]> {
    this.requireInit();
    const lorebook: Lorebook | null = await this.getCurrentLorebook();
    if (lorebook === null || !lorebook.enabled) {
      return [];
    }
    return this.matchEntriesForLorebook(lorebook, messages);
  }

  async buildInjectionAsync(messages: ChatMessage[]): Promise<LorebookInjection> {
    this.requireInit();
    const lorebook: Lorebook | null = await this.getCurrentLorebook();
    if (lorebook === null || !lorebook.enabled) {
      const empty: LorebookInjection = { before: '', after: '' };
      return empty;
    }
    const entries: LorebookEntry[] = this.matchEntriesForLorebook(lorebook, messages);
    const beforeParts: string[] = [];
    const afterParts: string[] = [];

    for (let i = 0; i < entries.length; i++) {
      const entry: LorebookEntry = entries[i];
      if (entry.position === LorebookPosition.BeforeCharacter) {
        beforeParts.push(entry.content);
      } else {
        afterParts.push(entry.content);
      }
    }

    const result: LorebookInjection = {
      before: beforeParts.join('\n\n'),
      after: afterParts.join('\n\n')
    };
    return result;
  }

  matchEntriesForLorebook(
    lorebook: Lorebook,
    messages: ChatMessage[]
  ): LorebookEntry[] {
    // 收集最近 N 条 User/Assistant 消息文本
    const recentTexts: string[] = [];
    let count: number = 0;
    for (let i = messages.length - 1; i >= 0 && count < this.maxScanMessages; i--) {
      const msg: ChatMessage = messages[i];
      if (msg.role === ChatRole.User || msg.role === ChatRole.Assistant) {
        recentTexts.push(msg.content);
        count++;
      }
    }

    const matched: LorebookEntry[] = [];
    for (let i = 0; i < lorebook.entries.length; i++) {
      const entry: LorebookEntry = lorebook.entries[i];
      if (!entry.enabled) {
        continue;
      }
      if (entry.constant) {
        matched.push(entry);
      } else if (this.isEntryMatched(entry, recentTexts)) {
        matched.push(entry);
      }
    }

    // 按 priority 降序排序
    matched.sort((a: LorebookEntry, b: LorebookEntry): number => b.priority - a.priority);

    // 限制最大字符数
    const limited: LorebookEntry[] = [];
    let totalChars: number = 0;
    for (let i = 0; i < matched.length; i++) {
      const entryChars: number = matched[i].content.length;
      if (totalChars + entryChars <= this.maxInjectionChars) {
        limited.push(matched[i]);
        totalChars += entryChars;
      }
    }

    return limited;
  }

  /**
   * FullInject 头部:收集所有 enabled 条目(忽略 constant/keys 语义)。
   * 按 priority 降序 + 预算截断。预算 = 书级 injectionBudgetChars(0 用默认)。
   */
  collectAllEntries(lorebook: Lorebook): LorebookEntry[] {
    const enabled: LorebookEntry[] = [];
    for (let i = 0; i < lorebook.entries.length; i++) {
      if (lorebook.entries[i].enabled) {
        enabled.push(lorebook.entries[i]);
      }
    }
    return this.sortAndLimitEntries(enabled, this.budgetForLorebook(lorebook));
  }

  /**
   * OnDemand 头部:收集 enabled + constant 条目。
   * 按 priority 降序 + 预算截断。
   */
  collectConstantEntries(lorebook: Lorebook): LorebookEntry[] {
    const constants: LorebookEntry[] = [];
    for (let i = 0; i < lorebook.entries.length; i++) {
      const entry: LorebookEntry = lorebook.entries[i];
      if (entry.enabled && entry.constant) {
        constants.push(entry);
      }
    }
    return this.sortAndLimitEntries(constants, this.budgetForLorebook(lorebook));
  }

  /**
   * OnDemand 深度:收集非 constant 且关键词命中的条目。
   * 复用最近 N 条消息扫描与 selective 匹配逻辑,不注入头部。
   */
  matchKeywordEntries(lorebook: Lorebook, messages: ChatMessage[]): LorebookEntry[] {
    const recentTexts: string[] = [];
    let count: number = 0;
    for (let i = messages.length - 1; i >= 0 && count < this.maxScanMessages; i--) {
      const msg: ChatMessage = messages[i];
      if (msg.role === ChatRole.User || msg.role === ChatRole.Assistant) {
        recentTexts.push(msg.content);
        count++;
      }
    }
    const matched: LorebookEntry[] = [];
    for (let i = 0; i < lorebook.entries.length; i++) {
      const entry: LorebookEntry = lorebook.entries[i];
      if (!entry.enabled || entry.constant) {
        continue;
      }
      if (this.isEntryMatched(entry, recentTexts)) {
        matched.push(entry);
      }
    }
    return this.sortAndLimitEntries(matched, this.budgetForLorebook(lorebook));
  }

  /**
   * 计算书的注入预算:书级 injectionBudgetChars > 0 用之,否则用默认预算。
   */
  private budgetForLorebook(lorebook: Lorebook): number {
    return lorebook.injectionBudgetChars > 0 ? lorebook.injectionBudgetChars : this.maxInjectionChars;
  }

  /**
   * 按 priority 降序排序并按预算截断(累计字符不超预算)。
   */
  private sortAndLimitEntries(entries: LorebookEntry[], budget: number): LorebookEntry[] {
    const sorted: LorebookEntry[] = [...entries];
    sorted.sort((a: LorebookEntry, b: LorebookEntry): number => b.priority - a.priority);
    const limited: LorebookEntry[] = [];
    let totalChars: number = 0;
    for (let i = 0; i < sorted.length; i++) {
      const entryChars: number = sorted[i].content.length;
      if (totalChars + entryChars <= budget) {
        limited.push(sorted[i]);
        totalChars += entryChars;
      }
    }
    return limited;
  }

  private isEntryMatched(entry: LorebookEntry, texts: string[]): boolean {
    if (entry.selective) {
      const primaryMatched: boolean = this.matchAnyKey(entry.keys, texts);
      if (!primaryMatched) {
        return false;
      }
      if (entry.secondaryKeys.length === 0) {
        return true;
      }
      return this.matchAnyKey(entry.secondaryKeys, texts);
    } else {
      return this.matchAnyKey(entry.keys, texts);
    }
  }

  private matchAnyKey(keys: string[], texts: string[]): boolean {
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      if (key.length === 0) {
        continue;
      }
      for (let j = 0; j < texts.length; j++) {
        if (this.matchKeyInText(key, texts[j])) {
          return true;
        }
      }
    }
    return false;
  }

  private matchKeyInText(key: string, text: string): boolean {
    if (this.isAsciiOnly(key)) {
      const lowerKey: string = key.toLowerCase();
      const lowerText: string = text.toLowerCase();
      return lowerText.includes(lowerKey);
    } else {
      return text.includes(key);
    }
  }

  private isAsciiOnly(str: string): boolean {
    for (let i = 0; i < str.length; i++) {
      if (str.charCodeAt(i) > 127) {
        return false;
      }
    }
    return true;
  }

  private findEntry(lorebook: Lorebook, entryId: string): LorebookEntry | null {
    for (let i = 0; i < lorebook.entries.length; i++) {
      if (lorebook.entries[i].id === entryId) {
        return lorebook.entries[i];
      }
    }
    return null;
  }

  getEntriesByIds(lorebook: Lorebook, ids: string[]): LorebookEntry[] {
    const result: LorebookEntry[] = [];
    const idSet: Set<string> = new Set(ids);
    for (let i = 0; i < lorebook.entries.length; i++) {
      const entry: LorebookEntry = lorebook.entries[i];
      if (entry.enabled && idSet.has(entry.id)) {
        result.push(entry);
      }
    }
    return result;
  }
}