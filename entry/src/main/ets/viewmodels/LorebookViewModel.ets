/**
 * LorebookViewModel 世界书页面状态管理
 *
 * 世界书页面的唯一 ViewModel,管理世界书和条目的 CRUD。
 * 不直接操作 LorebookStore 或 Preferences。
 */

import {
  Lorebook,
  LorebookEntry,
  LorebookPosition,
  LorebookActivationMode,
  LorebookEntryUpdates,
  isValidActivationMode
} from '../models/Lorebook';
import { LorebookService, DEFAULT_MAX_INJECTION_CHARS } from '../services/LorebookService';
import { CharacterService } from '../services/CharacterService';
import { CharacterBookRef } from '../repositories/CharacterRepository';
import { parseLorebookJson, parseLorebookSource, serializeLorebook } from '../parser/LorebookJsonParser';
import { AppPreferences } from '../storage/AppPreferences';
import {
  LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY,
  LOREBOOK_INJECTION_DEPTH_PREFS_KEY
} from '../services/ChatService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LorebookViewModel';

/** 全局默认激活方式可选值(全局默认没有 FollowGlobal) */
const GLOBAL_MODE_FULL_INJECT: LorebookActivationMode = LorebookActivationMode.FullInject;
const GLOBAL_MODE_ON_DEMAND: LorebookActivationMode = LorebookActivationMode.OnDemand;
/** 注入预算上限(与模型校验一致) */
const MAX_INJECTION_BUDGET_CHARS: number = 200000;

/** 世界书字符统计(供界面判断加载方式)。 */
export interface LorebookStats {
  /** 全部条目数 */
  totalEntries: number;
  /** 全部条目字符总数 */
  totalChars: number;
  /** 启用条目数 */
  enabledEntries: number;
  /** 启用条目字符总数 */
  enabledChars: number;
  /** constant 条目字符总数 */
  constantChars: number;
}

@Observed
export class LorebookViewModel {
  lorebooks: Lorebook[] = [];
  currentLorebookId: string | null = null;
  loading: boolean = false;
  errorMessage: string = '';
  /** 世界书 id → 绑定的角色引用(id + name),供世界书页面展示绑定关系 */
  boundCharacterMap: Record<string, CharacterBookRef[]> = {};

  /** 数据变更回调,用于页面将 @State 变量同步到 ViewModel */
  onDataUpdate: (() => void) | null = null;

  /** 展开的世界书 ID(用于显示条目列表) */
  expandedLorebookId: string | null = null;

  /** 世界书编辑对话框 */
  showLorebookDialog: boolean = false;
  editingLorebook: Lorebook | null = null;
  editLorebookName: string = '';
  editLorebookDescription: string = '';
  /** 编辑对话框:激活方式(0=跟随全局/1=全量/2=按需) */
  editLorebookActivationMode: number = 0;
  /** 编辑对话框:注入预算(字符,空=默认) */
  editLorebookBudget: string = '';

  /** 条目编辑对话框 */
  showEntryDialog: boolean = false;
  editingEntry: LorebookEntry | null = null;
  editingEntryLorebookId: string = '';
  editEntryName: string = '';
  editEntryKeys: string = '';
  editEntrySecondaryKeys: string = '';
  editEntryContent: string = '';
  editEntryEnabled: boolean = true;
  editEntryConstant: boolean = false;
  editEntrySelective: boolean = false;
  editEntryPosition: number = 0; // 0=BeforeCharacter, 1=AfterCharacter
  editEntryPriority: number = 0;

  /** 删除确认 */
  deleteTargetLorebook: Lorebook | null = null;
  deleteTargetEntry: LorebookEntry | null = null;
  deleteTargetEntryLorebookId: string = '';

  /** 全局默认激活方式(FullInject / OnDemand),默认 OnDemand */
  globalActivationMode: LorebookActivationMode = GLOBAL_MODE_ON_DEMAND;
  /** 全局深度注入位置(0-8),默认 2 */
  globalInjectionDepth: number = 2;

  private readonly service: LorebookService;
  private readonly characterService: CharacterService;
  private readonly appPreferences: AppPreferences;

  constructor(
    service: LorebookService,
    characterService: CharacterService,
    appPreferences: AppPreferences
  ) {
    this.service = service;
    this.characterService = characterService;
    this.appPreferences = appPreferences;
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      this.lorebooks = await this.service.list();
      this.currentLorebookId = await this.service.getCurrentLorebookId();
      await this.loadGlobalSettings();
      await this.refreshBoundCharacters();
      this.notifyDataUpdate();
    } catch (e) {
      this.errorMessage = '加载世界书列表失败';
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.loading = false;
    }
  }

  /**
   * 加载全局默认激活方式与深度注入偏好(AppPreferences)。
   */
  async loadGlobalSettings(): Promise<void> {
    try {
      const modeVal: string = await this.appPreferences.getString(
        LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY, '');
      if (modeVal === GLOBAL_MODE_FULL_INJECT || modeVal === GLOBAL_MODE_ON_DEMAND) {
        this.globalActivationMode = modeVal as LorebookActivationMode;
      } else {
        this.globalActivationMode = GLOBAL_MODE_ON_DEMAND;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadGlobalSettings mode failed: ' + String(e));
      this.globalActivationMode = GLOBAL_MODE_ON_DEMAND;
    }
    try {
      const depthStr: string = await this.appPreferences.getString(
        LOREBOOK_INJECTION_DEPTH_PREFS_KEY, '');
      const parsed: number = Number(depthStr);
      this.globalInjectionDepth = Number.isFinite(parsed) && parsed >= 0 && parsed <= 8
        ? Math.floor(parsed) : 2;
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadGlobalSettings depth failed: ' + String(e));
      this.globalInjectionDepth = 2;
    }
  }

  /**
   * 设置全局默认激活方式并持久化。
   */
  async setGlobalActivationMode(mode: LorebookActivationMode): Promise<void> {
    this.globalActivationMode = mode;
    try {
      await this.appPreferences.putString(LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY, mode);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setGlobalActivationMode failed: ' + String(e));
    }
    this.notifyDataUpdate();
  }

  /**
   * 设置全局深度注入位置并持久化(0-8)。
   */
  async setGlobalInjectionDepth(depth: number): Promise<void> {
    const clamped: number = Math.max(0, Math.min(8, Math.floor(depth)));
    this.globalInjectionDepth = clamped;
    try {
      await this.appPreferences.putString(LOREBOOK_INJECTION_DEPTH_PREFS_KEY, String(clamped));
    } catch (e) {
      Logger.warn(LOG_TAG, 'setGlobalInjectionDepth failed: ' + String(e));
    }
    this.notifyDataUpdate();
  }

  /** 重建"世界书 → 绑定角色"映射(轻量查询所有世界书的反向绑定) */
  private async refreshBoundCharacters(): Promise<void> {
    const map: Record<string, CharacterBookRef[]> = {};
    for (let i = 0; i < this.lorebooks.length; i++) {
      const bookId: string = this.lorebooks[i].id;
      try {
        map[bookId] = await this.characterService.getCharactersBoundToBook(bookId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'refreshBoundCharacters failed for ' + bookId + ': ' + String(e));
        map[bookId] = [];
      }
    }
    this.boundCharacterMap = map;
  }

  /** 获取某世界书绑定的角色引用列表 */
  getBoundCharacters(bookId: string): CharacterBookRef[] {
    return this.boundCharacterMap[bookId] ?? [];
  }

  /** 是否存在绑定到该世界书的角色 */
  hasBoundCharacters(bookId: string): boolean {
    return this.getBoundCharacters(bookId).length > 0;
  }

  /** 解除角色与某世界书的绑定 */
  async unbindCharacter(bookId: string, characterId: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.characterService.update(characterId, { characterBookId: '' });
      await this.refreshBoundCharacters();
      this.notifyDataUpdate();
    } catch (e) {
      this.errorMessage = '解除绑定失败: ' + String(e);
      Logger.error(LOG_TAG, 'unbindCharacter failed: ' + String(e));
    }
  }

  /**
   * 从文件 URI 导入世界书(JSON)。
   * 读取文本 → 白名单解析 → 批量入库 → 刷新列表。失败时抛错,由页面提示。
   */
  async importLorebookFile(uri: string): Promise<Lorebook> {
    this.errorMessage = '';
    const text: string = await this.characterService.readFileContent(uri);
    const fallbackName: string = basenameWithoutExtension(uri);
    const parsed = parseLorebookJson(text, fallbackName);
    const book: Lorebook = await this.service.importLorebook(parsed);
    await this.load();
    return book;
  }

  /** 将某世界书绑定到指定角色(通过 character_book_id)。失败时抛错。 */
  async bindLorebookToCharacter(bookId: string, characterId: string): Promise<void> {
    await this.characterService.update(characterId, { characterBookId: bookId });
    this.bumpCharacterListVersion();
    await this.refreshBoundCharacters();
    this.notifyDataUpdate();
  }

  /** 获取可选绑定角色列表(id + name,轻量)。失败返回空数组。 */
  async listCharactersForBinding(): Promise<CharacterBookRef[]> {
    try {
      const chars = await this.characterService.listSummaries();
      const refs: CharacterBookRef[] = [];
      for (let i = 0; i < chars.length; i++) {
        refs.push({ id: chars[i].id, name: chars[i].name });
      }
      return refs;
    } catch (e) {
      Logger.warn(LOG_TAG, 'listCharactersForBinding failed: ' + String(e));
      return [];
    }
  }

  /** 生成世界书源码 JSON(供"查看源码"编辑器)。 */
  async loadLorebookSource(id: string): Promise<string> {
    const book: Lorebook | null = await this.service.getById(id);
    if (book === null) {
      throw new Error('世界书不存在或已被删除');
    }
    return serializeLorebook(book);
  }

  /** 把编辑后的源码 JSON 保存回世界书(整册替换)。失败抛错。 */
  async saveLorebookSource(id: string, jsonText: string): Promise<void> {
    // 宽松解析保留全部条目,不做静默过滤;无效条目由保存层校验并明确报错,
    // 保证保存后展开看到的内容与 JSON 一致,不偷偷丢条目/丢内容。
    const parsed = parseLorebookSource(jsonText, '导入的世界书');
    await this.service.replaceLorebookContent(id, parsed);
    await this.load();
  }

  /** 通知首页角色列表刷新版本号(角色绑定世界书变化后让列表重新加载)。 */
  private bumpCharacterListVersion(): void {
    const v: number = AppStorage.get<number>('characterListVersion') ?? 0;
    AppStorage.setOrCreate<number>('characterListVersion', v + 1);
  }

  private notifyDataUpdate(): void {
    if (this.onDataUpdate !== null) {
      this.onDataUpdate();
    }
  }

  isCurrent(lorebook: Lorebook): boolean {
    return this.currentLorebookId === lorebook.id;
  }

  /** 切换展开/折叠 */
  toggleExpand(lorebookId: string): void {
    if (this.expandedLorebookId === lorebookId) {
      this.expandedLorebookId = null;
    } else {
      this.expandedLorebookId = lorebookId;
    }
  }

  // ===== 世界书编辑 =====

  showNewLorebookDialog(): void {
    this.editingLorebook = null;
    this.editLorebookName = '';
    this.editLorebookDescription = '';
    // 新建默认按需激活(安全默认,可按需在编辑里切全量)
    this.editLorebookActivationMode = 2;
    this.editLorebookBudget = '';
    this.showLorebookDialog = true;
  }

  showEditLorebookDialog(lorebook: Lorebook): void {
    this.editingLorebook = lorebook;
    this.editLorebookName = lorebook.name;
    this.editLorebookDescription = lorebook.description;
    // 每本书直接二选一:遗留 FollowGlobal 书按全局默认解析后显示,保存即固化
    this.editLorebookActivationMode = this.resolveEditActivationMode(lorebook.activationMode);
    this.editLorebookBudget = lorebook.injectionBudgetChars > 0
      ? String(lorebook.injectionBudgetChars) : '';
    this.showLorebookDialog = true;
  }

  closeLorebookDialog(): void {
    this.showLorebookDialog = false;
    this.editingLorebook = null;
  }

  async saveLorebook(): Promise<boolean> {
    this.errorMessage = '';
    if (this.editLorebookName.trim().length === 0) {
      this.errorMessage = '世界书名称不能为空';
      return false;
    }
    const activationMode: LorebookActivationMode = this.numberToActivationMode(this.editLorebookActivationMode);
    const budget: number = this.parseBudget(this.editLorebookBudget);
    try {
      if (this.editingLorebook === null) {
        await this.service.create(
          this.editLorebookName, this.editLorebookDescription,
          activationMode, budget
        );
      } else {
        await this.service.update(this.editingLorebook.id, {
          name: this.editLorebookName,
          description: this.editLorebookDescription,
          activationMode: activationMode,
          injectionBudgetChars: budget
        });
      }
      this.showLorebookDialog = false;
      this.editingLorebook = null;
      await this.load();
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'saveLorebook failed: ' + String(e));
      return false;
    }
  }

  /**
   * 编辑弹窗显示档位:每本书直接二选一(1=全量/2=按需)。
   * 遗留 FollowGlobal 书按全局默认解析为当前生效档位,保存后固化为具体值。
   */
  private resolveEditActivationMode(mode: LorebookActivationMode): number {
    if (mode === LorebookActivationMode.FollowGlobal) {
      return this.globalActivationMode === GLOBAL_MODE_FULL_INJECT ? 1 : 2;
    }
    return this.activationModeToNumber(mode);
  }

  /**
   * 激活方式枚举 → UI 档位(1=全量/2=按需,0 仅供遗留 FollowGlobal 展示)。
   */
  activationModeToNumber(mode: LorebookActivationMode): number {
    if (mode === LorebookActivationMode.FullInject) {
      return 1;
    }
    if (mode === LorebookActivationMode.OnDemand) {
      return 2;
    }
    return 0;
  }

  /**
   * UI 档位 → 激活方式枚举(编辑保存时不会产生 0)。
   */
  numberToActivationMode(value: number): LorebookActivationMode {
    if (value === 1) {
      return LorebookActivationMode.FullInject;
    }
    if (value === 2) {
      return LorebookActivationMode.OnDemand;
    }
    return LorebookActivationMode.FollowGlobal;
  }

  /**
   * 解析注入预算输入(空/非法为 0,上限 200000)。
   */
  parseBudget(input: string): number {
    const trimmed: string = input.trim();
    if (trimmed.length === 0) {
      return 0;
    }
    const parsed: number = parseInt(trimmed);
    if (isNaN(parsed) || parsed < 0) {
      return 0;
    }
    return Math.min(parsed, MAX_INJECTION_BUDGET_CHARS);
  }

  /**
   * 世界书字符统计(供界面判断加载方式)。
   */
  computeLorebookStats(lorebook: Lorebook): LorebookStats {
    let totalEntries: number = 0;
    let totalChars: number = 0;
    let enabledEntries: number = 0;
    let enabledChars: number = 0;
    let constantChars: number = 0;
    for (let i = 0; i < lorebook.entries.length; i++) {
      const entry: LorebookEntry = lorebook.entries[i];
      totalEntries++;
      totalChars += entry.content.length;
      if (entry.enabled) {
        enabledEntries++;
        enabledChars += entry.content.length;
        if (entry.constant) {
          constantChars += entry.content.length;
        }
      }
    }
    return {
      totalEntries: totalEntries,
      totalChars: totalChars,
      enabledEntries: enabledEntries,
      enabledChars: enabledChars,
      constantChars: constantChars
    };
  }

  /** 数字紧凑格式化:K/W 单位(千/万)。 */
  formatCompact(n: number): string {
    if (n >= 10000) {
      return (n / 10000).toFixed(1) + 'W';
    }
    if (n >= 1000) {
      return (n / 1000).toFixed(1) + 'K';
    }
    return String(n);
  }

  /** 生效注入预算:书级 >0 用之,否则默认预算。 */
  effectiveBudget(lorebook: Lorebook): number {
    return lorebook.injectionBudgetChars > 0
      ? lorebook.injectionBudgetChars : DEFAULT_MAX_INJECTION_CHARS;
  }

  /** 全量/跟随全局且启用字符超预算时的告警文本,不超时返回空串。
   *  modeOverride 用于编辑弹窗按当前 UI 档位即时判断(不传则按书级设置)。 */
  computeBudgetWarning(lorebook: Lorebook, modeOverride?: LorebookActivationMode): string {
    const mode: LorebookActivationMode = modeOverride !== undefined
      ? modeOverride : lorebook.activationMode;
    if (mode === LorebookActivationMode.OnDemand) {
      return '';
    }
    const stats: LorebookStats = this.computeLorebookStats(lorebook);
    const budget: number = this.effectiveBudget(lorebook);
    if (stats.enabledChars > budget && stats.enabledEntries > 0) {
      return '超出注入预算 ' + this.formatCompact(budget)
        + ',全部发送会被截断,建议切换按需加载';
    }
    return '';
  }

  /** 编辑弹窗按 UI 档位(1=全量/2=按需)即时判断超预算告警。 */
  computeBudgetWarningForUi(lorebook: Lorebook, uiMode: number): string {
    const mode: LorebookActivationMode = uiMode === 1
      ? LorebookActivationMode.FullInject : LorebookActivationMode.OnDemand;
    return this.computeBudgetWarning(lorebook, mode);
  }

  /** 编辑弹窗统计行文本:条目数/字符/启用/预算。 */
  buildDialogStatsLine(lorebook: Lorebook): string {
    const stats: LorebookStats = this.computeLorebookStats(lorebook);
    return '共 ' + stats.totalEntries + ' 条目 · '
      + this.formatCompact(stats.totalChars) + ' 字符'
      + ' · 启用 ' + this.formatCompact(stats.enabledChars)
      + ' · 预算 ' + this.formatCompact(this.effectiveBudget(lorebook));
  }

  /**
   * 获取激活方式显示文本(书列表徽标)。
   */
  getActivationModeText(mode: LorebookActivationMode): string {
    if (mode === LorebookActivationMode.FullInject) {
      return '全量';
    }
    if (mode === LorebookActivationMode.OnDemand) {
      return '按需';
    }
    return '跟随全局';
  }

  async setCurrentLorebook(id: string | null): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.setCurrentLorebookId(id);
      this.currentLorebookId = await this.service.getCurrentLorebookId();
      this.notifyDataUpdate();
    } catch (e) {
      this.errorMessage = '设置失败: ' + String(e);
      Logger.error(LOG_TAG, 'setCurrentLorebook failed: ' + String(e));
    }
  }

  async deleteLorebook(id: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.remove(id);
      this.deleteTargetLorebook = null;
      if (this.expandedLorebookId === id) {
        this.expandedLorebookId = null;
      }
      await this.load();
    } catch (e) {
      this.errorMessage = '删除失败: ' + String(e);
      Logger.error(LOG_TAG, 'deleteLorebook failed: ' + String(e));
    }
  }

  async toggleLorebookEnabled(lorebook: Lorebook): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.update(lorebook.id, { enabled: !lorebook.enabled });
      await this.load();
    } catch (e) {
      this.errorMessage = '操作失败: ' + String(e);
      Logger.error(LOG_TAG, 'toggleLorebookEnabled failed: ' + String(e));
    }
  }

  // ===== 条目编辑 =====

  showNewEntryDialog(lorebookId: string): void {
    this.editingEntry = null;
    this.editingEntryLorebookId = lorebookId;
    this.editEntryName = '';
    this.editEntryKeys = '';
    this.editEntrySecondaryKeys = '';
    this.editEntryContent = '';
    this.editEntryEnabled = true;
    this.editEntryConstant = false;
    this.editEntrySelective = false;
    this.editEntryPosition = 0;
    this.editEntryPriority = 0;
    this.showEntryDialog = true;
  }

  showEditEntryDialog(lorebookId: string, entry: LorebookEntry): void {
    this.editingEntry = entry;
    this.editingEntryLorebookId = lorebookId;
    this.editEntryName = entry.name;
    this.editEntryKeys = entry.keys.join(', ');
    this.editEntrySecondaryKeys = entry.secondaryKeys.join(', ');
    this.editEntryContent = entry.content;
    this.editEntryEnabled = entry.enabled;
    this.editEntryConstant = entry.constant;
    this.editEntrySelective = entry.selective;
    this.editEntryPosition = entry.position === LorebookPosition.AfterCharacter ? 1 : 0;
    this.editEntryPriority = entry.priority;
    this.showEntryDialog = true;
  }

  closeEntryDialog(): void {
    this.showEntryDialog = false;
    this.editingEntry = null;
  }

  async saveEntry(): Promise<boolean> {
    this.errorMessage = '';
    if (this.editEntryName.trim().length === 0) {
      this.errorMessage = '条目名称不能为空';
      return false;
    }
    if (this.editEntryContent.trim().length === 0) {
      this.errorMessage = '条目内容不能为空';
      return false;
    }
    const keys: string[] = this.parseKeysString(this.editEntryKeys);
    const secondaryKeys: string[] = this.parseKeysString(this.editEntrySecondaryKeys);
    if (!this.editEntryConstant && keys.length === 0) {
      this.errorMessage = '非恒定条目至少需要一个关键词';
      return false;
    }
    const position: LorebookPosition = this.editEntryPosition === 1
      ? LorebookPosition.AfterCharacter : LorebookPosition.BeforeCharacter;

    try {
      if (this.editingEntry === null) {
        await this.service.addEntry(
          this.editingEntryLorebookId,
          this.editEntryName, keys, secondaryKeys, this.editEntryContent,
          this.editEntryEnabled, this.editEntryConstant, this.editEntrySelective,
          position, this.editEntryPriority
        );
      } else {
        const updates: LorebookEntryUpdates = {
          name: this.editEntryName,
          keys: keys,
          secondaryKeys: secondaryKeys,
          content: this.editEntryContent,
          enabled: this.editEntryEnabled,
          constant: this.editEntryConstant,
          selective: this.editEntrySelective,
          position: position,
          priority: this.editEntryPriority
        };
        await this.service.updateEntry(this.editingEntryLorebookId, this.editingEntry.id, updates);
      }
      this.showEntryDialog = false;
      this.editingEntry = null;
      await this.load();
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'saveEntry failed: ' + String(e));
      return false;
    }
  }

  async deleteEntry(lorebookId: string, entryId: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.removeEntry(lorebookId, entryId);
      this.deleteTargetEntry = null;
      this.deleteTargetEntryLorebookId = '';
      await this.load();
    } catch (e) {
      this.errorMessage = '删除失败: ' + String(e);
      Logger.error(LOG_TAG, 'deleteEntry failed: ' + String(e));
    }
  }

  // ===== 工具方法 =====

  /**
   * 解析关键词字符串(逗号或换行分隔)。
   */
  private parseKeysString(input: string): string[] {
    const result: string[] = [];
    // 先按换行分割,再按逗号分割
    const lines: string[] = input.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const parts: string[] = lines[i].split(',');
      for (let j = 0; j < parts.length; j++) {
        const trimmed: string = parts[j].trim();
        if (trimmed.length > 0) {
          result.push(trimmed);
        }
      }
    }
    return result;
  }

  /**
   * 获取 Position 显示文本。
   */
  getPositionText(position: string): string {
    if (position === LorebookPosition.AfterCharacter) {
      return '角色后';
    }
    return '角色前';
  }

  /**
   * 获取条目数量与字符统计文本(书列表)。
   */
  getEntryCountText(lorebook: Lorebook): string {
    const stats: LorebookStats = this.computeLorebookStats(lorebook);
    if (stats.totalEntries === 0) {
      return '无条目';
    }
    let text: string = stats.totalEntries + ' 个条目 · '
      + this.formatCompact(stats.totalChars) + ' 字符';
    if (stats.constantChars > 0) {
      text += ' · 恒定 ' + this.formatCompact(stats.constantChars);
    }
    return text;
  }
}

/** 从文件 URI 中提取不含扩展名的文件名(用于世界书无书名时的兜底)。 */
function basenameWithoutExtension(uri: string): string {
  const idx: number = uri.lastIndexOf('/');
  let name: string = idx >= 0 ? uri.substring(idx + 1) : uri;
  // picker 返回的 uri 中非 ASCII 文件名可能为 percent 编码,需解码后才是真实文件名
  try {
    name = decodeURIComponent(name);
  } catch (e) {
    // 非合法编码则原样使用
  }
  // 去掉可能的查询串
  const qIdx: number = name.indexOf('?');
  if (qIdx >= 0) {
    name = name.substring(0, qIdx);
  }
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}