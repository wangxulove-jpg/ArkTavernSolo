/**
 * AiCharacterPreviewViewModel AI 制作角色卡预览编辑 ViewModel
 *
 * 接收 Maker 页面通过 AppStorage 传递的 ParsedCharacterCard 和原始创意输入,
 * 提供编辑、保存、单字段重新生成、导出能力。
 *
 * 职责:
 * 1. 加载 AppStorage 中的待处理卡片(PENDING_AI_CARD_KEY)
 * 2. 持有可编辑的字段表单状态
 * 3. 保存:调用 CharacterService.importFromParsed
 * 4. 单字段重新生成:调用 AiCharacterGenerationService.regenerateField
 * 5. 整张卡重新生成:通知调用方回退到 Maker 页面
 * 6. 导出 JSON/PNG:复用 CharacterService 的导出能力
 *
 * 不直接:
 * - 调用 network/(通过 GenerationService → ModelService)
 * - 操作 RDB(通过 CharacterService)
 *
 * 隐私约束:
 * - 不向日志输出完整角色卡正文
 * - 不缓存 API Key
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import { CharacterService } from '../services/CharacterService';
import { Character } from '../models/Character';
import {
  AiCharacterGenerationService,
  AiGenerationHandle,
  AiFieldRegenCallbacks
} from '../services/ai/AiCharacterGenerationService';
import {
  ParsedCharacterCard,
  ParsedCharacterBook,
  ParsedCharacterBookEntry
} from '../parser/CharacterCardJsonParser';
import { AiCharacterInput } from '../models/AiCharacterInput';
import { PENDING_AI_CARD_KEY, PENDING_AI_INPUT_KEY } from './AiCharacterMakerViewModel';

const LOG_TAG: string = 'AiCharPreviewVM';

/**
 * 单字段重新生成状态。
 */
export enum FieldRegenState {
  Idle = 'Idle',
  Regenerating = 'Regenerating',
  Done = 'Done',
  Failed = 'Failed'
}

/**
 * 字段重新生成结果回调。
 */
export interface FieldRegenResult {
  /** 字段路径(如 "data.description") */
  fieldPath: string;
  /** 新值(失败时为 null) */
  value: string | null;
  /** 错误信息(成功时为空字符串) */
  error: string;
}

/**
 * AI 制作角色卡预览编辑 ViewModel。
 */
@Observed
export class AiCharacterPreviewViewModel {
  // ===== 卡片字段(可编辑) =====
  name: string = '';
  description: string = '';
  personality: string = '';
  scenario: string = '';
  firstMessage: string = '';
  mesExample: string = '';
  creatorNotes: string = '';
  systemPrompt: string = '';
  postHistoryInstructions: string = '';
  alternateGreetings: string[] = [];
  tags: string[] = [];
  creator: string = '';
  characterVersion: string = '';
  extensionsJson: string = '{}';
  characterBookJson: string = '';

  // ===== 状态 =====
  /** 是否已加载卡片 */
  loaded: boolean = false;
  /** 错误信息 */
  errorMessage: string = '';
  /** 是否正在保存 */
  isSaving: boolean = false;
  /** 是否正在重新生成整张卡 */
  isRegeneratingFull: boolean = false;
  /** 当前正在重新生成的字段(空字符串表示无) */
  regeneratingField: string = '';
  /** 字段重新生成状态 */
  fieldRegenState: FieldRegenState = FieldRegenState.Idle;
  /** 字段重新生成错误信息 */
  fieldRegenError: string = '';
  /** 已保存的角色 ID(保存成功后设置,用于后续导出) */
  savedCharacterId: string = '';
  /** 原始响应文本(供"查看原始响应") */
  rawResponse: string = '';
  /** 原始创意输入(供"重新生成整张卡"回退使用) */
  originalInput: AiCharacterInput | null = null;

  // ===== 内部状态 =====
  private characterService: CharacterService;
  private generationService: AiCharacterGenerationService;
  private prefs: AppPreferences;
  private parsedCard: ParsedCharacterCard | null = null;
  private fieldRegenHandle: AiGenerationHandle | null = null;
  /** 字段重新生成回调(由页面注入) */
  private onFieldRegenCompleteCallback: ((result: FieldRegenResult) => void) | null = null;

  constructor(
    characterService: CharacterService,
    generationService: AiCharacterGenerationService,
    prefs: AppPreferences
  ) {
    this.characterService = characterService;
    this.generationService = generationService;
    this.prefs = prefs;
  }

  // ===== 生命周期 =====

  /**
   * 从 AppStorage 加载待处理的卡片。
   * 由页面 aboutToAppear 调用。
   */
  loadPendingCard(): boolean {
    const cardValue: ParsedCharacterCard | null | undefined =
      AppStorage.get<ParsedCharacterCard | null>(PENDING_AI_CARD_KEY);
    const card: ParsedCharacterCard | null = cardValue === undefined ? null : cardValue;
    const inputValue: AiCharacterInput | null | undefined =
      AppStorage.get<AiCharacterInput | null>(PENDING_AI_INPUT_KEY);
    const input: AiCharacterInput | null = inputValue === undefined ? null : inputValue;

    if (card === null) {
      this.errorMessage = '未找到待预览的角色卡';
      this.loaded = false;
      return false;
    }

    this.parsedCard = card;
    this.originalInput = input;
    this.name = card.name;
    this.description = card.description;
    this.personality = card.personality;
    this.scenario = card.scenario;
    this.firstMessage = card.firstMessage;
    this.mesExample = card.mesExample;
    this.creatorNotes = card.creatorNotes;
    this.systemPrompt = card.systemPrompt;
    this.postHistoryInstructions = card.postHistoryInstructions;
    this.alternateGreetings = card.alternateGreetings.slice();
    this.tags = card.tags.slice();
    this.creator = card.creator;
    this.characterVersion = card.characterVersion;

    // extensions 序列化为格式化 JSON
    try {
      this.extensionsJson = JSON.stringify(card.extensions, null, 2);
    } catch (e) {
      this.extensionsJson = '{}';
    }

    // character_book 序列化为格式化 JSON
    if (card.characterBook !== null) {
      try {
        this.characterBookJson = JSON.stringify(card.characterBook, null, 2);
      } catch (e) {
        this.characterBookJson = '';
      }
    } else {
      this.characterBookJson = '';
    }

    this.loaded = true;
    this.errorMessage = '';
    return true;
  }

  /**
   * 释放资源。
   */
  dispose(): void {
    this.cancelFieldRegen();
  }

  /**
   * 设置字段重新生成完成回调。
   */
  setOnFieldRegenComplete(cb: (result: FieldRegenResult) => void): void {
    this.onFieldRegenCompleteCallback = cb;
  }

  // ===== 保存 =====

  /**
   * 检查是否存在同名角色(trim 后精确匹配)。
   * 同名不是绝对禁止,由调用方决定是否提示用户。
   */
  async hasDuplicateName(): Promise<boolean> {
    try {
      const trimmedName: string = this.name.trim();
      if (trimmedName.length === 0) {
        return false;
      }
      const all: Character[] = await this.characterService.list();
      for (let i: number = 0; i < all.length; i++) {
        if (all[i].name.trim() === trimmedName) {
          return true;
        }
      }
      return false;
    } catch (e) {
      Logger.warn(LOG_TAG, 'hasDuplicateName failed: ' + String(e));
      return false;
    }
  }

  /**
   * 保存为本地角色。
   * 复用 CharacterService.importFromParsed,自动处理 character_book。
   * 同名角色不会覆盖:importFromParsed 内部生成独立 UUID。
   */
  async save(): Promise<boolean> {
    if (this.parsedCard === null) {
      this.errorMessage = '尚未加载角色卡';
      return false;
    }
    this.isSaving = true;
    this.errorMessage = '';
    try {
      // 从可编辑字段重建 ParsedCharacterCard
      const cardToSave: ParsedCharacterCard = this.buildCardFromForm();
      const saved: Character = await this.characterService.importFromParsed(cardToSave);
      this.savedCharacterId = saved.id;

      // 通知角色列表刷新
      const v: number = AppStorage.get<number>('characterListVersion') ?? 0;
      AppStorage.setOrCreate<number>('characterListVersion', v + 1);

      // 清理 AppStorage 中的临时传递槽位
      AppStorage.setOrCreate<ParsedCharacterCard | null>(PENDING_AI_CARD_KEY, null);
      AppStorage.setOrCreate<AiCharacterInput | null>(PENDING_AI_INPUT_KEY, null);

      this.isSaving = false;
      return true;
    } catch (e) {
      this.isSaving = false;
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'save failed: ' + String(e));
      return false;
    }
  }

  // ===== 单字段重新生成 =====

  /**
   * 重新生成单个字段。
   * @param fieldPath 字段路径(如 "data.description")
   */
  regenerateField(fieldPath: string): void {
    if (this.parsedCard === null) {
      return;
    }
    if (this.fieldRegenState === FieldRegenState.Regenerating) {
      return;
    }
    this.regeneratingField = fieldPath;
    this.fieldRegenState = FieldRegenState.Regenerating;
    this.fieldRegenError = '';

    // 使用当前表单状态作为上下文(包含最新编辑)
    const currentCard: ParsedCharacterCard = this.buildCardFromForm();
    const useCurrent: boolean = true; // 字段重新生成都用当前模型
    const callbacks: AiFieldRegenCallbacks = {
      onComplete: (fieldValue: string | null, errorMessage: string): void => {
        if (this.fieldRegenState !== FieldRegenState.Regenerating) {
          return;
        }
        if (fieldValue === null) {
          this.fieldRegenState = FieldRegenState.Failed;
          this.fieldRegenError = errorMessage.length > 0 ? errorMessage : '字段重新生成失败';
          this.regeneratingField = '';
        } else {
          // 应用新值到对应字段
          this.applyFieldValue(fieldPath, fieldValue);
          this.fieldRegenState = FieldRegenState.Done;
          this.fieldRegenError = '';
          this.regeneratingField = '';
          // 更新 parsedCard 以便后续保存
          this.parsedCard = this.buildCardFromForm();
        }
        // 通知页面
        if (this.onFieldRegenCompleteCallback !== null) {
          this.onFieldRegenCompleteCallback({
            fieldPath: fieldPath,
            value: fieldValue,
            error: errorMessage
          });
        }
      }
    };

    this.fieldRegenHandle = this.generationService.regenerateField(
      fieldPath, currentCard, useCurrent, '', callbacks
    );
  }

  /**
   * 取消字段重新生成。
   *
   * 顺序(G-AI-BUILDER-2-FIX):先失效 state,再 abort 请求。
   * 这样迟到回调到达时 fieldRegenState 已不是 Regenerating,会被忽略。
   */
  cancelFieldRegen(): void {
    if (this.fieldRegenState !== FieldRegenState.Regenerating) {
      return;
    }
    // 1. 先失效 state,迟到回调将被忽略
    this.fieldRegenState = FieldRegenState.Idle;
    this.regeneratingField = '';
    // 2. 再 abort 请求
    if (this.fieldRegenHandle !== null) {
      try {
        this.fieldRegenHandle.abort();
      } catch (e) {
        Logger.warn(LOG_TAG, 'field regen abort throw: ' + String(e));
      }
      this.fieldRegenHandle = null;
    }
  }

  /**
   * 清除字段重新生成状态(回到 Idle)。
   */
  clearFieldRegenState(): void {
    this.fieldRegenState = FieldRegenState.Idle;
    this.fieldRegenError = '';
    this.regeneratingField = '';
  }

  // ===== 导出 =====

  /**
   * 导出为 V2 JSON 字符串。
   * 要求角色已保存。
   */
  async exportToJson(): Promise<string> {
    if (this.savedCharacterId.length === 0) {
      throw new Error('请先保存角色后再导出');
    }
    return await this.characterService.exportToV2JsonWithBook(this.savedCharacterId);
  }

  /**
   * 导出为 PNG(保存到指定文件 URI)。
   * 要求角色已保存。
   */
  async exportToPng(uri: string): Promise<void> {
    if (this.savedCharacterId.length === 0) {
      throw new Error('请先保存角色后再导出');
    }
    await this.characterService.exportPngToFile(this.savedCharacterId, uri);
  }

  // ===== 内部方法 =====

  /**
   * 从表单字段重建 ParsedCharacterCard。
   */
  private buildCardFromForm(): ParsedCharacterCard {
    // 解析 extensions JSON
    let extensions: Record<string, Object> = {};
    try {
      const parsed: Object = JSON.parse(this.extensionsJson);
      if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
        extensions = parsed as Record<string, Object>;
      }
    } catch (e) {
      // extensions 无效时保留原值(不阻塞保存)
      if (this.parsedCard !== null) {
        extensions = this.parsedCard.extensions;
      }
    }

    // 解析 character_book JSON
    let characterBook: ParsedCharacterBook | null = null;
    if (this.characterBookJson.trim().length > 0) {
      try {
        const parsed: Object = JSON.parse(this.characterBookJson);
        if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
          const book: Record<string, Object> = parsed as Record<string, Object>;
          const entriesRaw: Object | undefined = book['entries'];
          const entries: ParsedCharacterBookEntry[] = [];
          if (Array.isArray(entriesRaw)) {
            const arr: Object[] = entriesRaw as Object[];
            for (let i: number = 0; i < arr.length; i++) {
              // 复用 validator 中的解析逻辑 - 这里简化处理
              const entryObj: Object = arr[i];
              if (typeof entryObj === 'object' && entryObj !== null && !Array.isArray(entryObj)) {
                const entry: ParsedCharacterBookEntry = parseBookEntrySimplified(entryObj as Record<string, Object>, i);
                entries.push(entry);
              }
            }
          }
          let bookExtensions: Record<string, Object> = {};
          const extRaw: Object | undefined = book['extensions'];
          if (extRaw !== undefined && extRaw !== null
            && typeof extRaw === 'object' && !Array.isArray(extRaw)) {
            bookExtensions = extRaw as Record<string, Object>;
          }
          characterBook = { entries: entries, extensions: bookExtensions };
        }
      } catch (e) {
        // character_book 无效时使用原值
        if (this.parsedCard !== null) {
          characterBook = this.parsedCard.characterBook;
        }
      }
    }

    return {
      name: this.name,
      description: this.description,
      personality: this.personality,
      scenario: this.scenario,
      firstMessage: this.firstMessage,
      systemPrompt: this.systemPrompt,
      avatarUri: '',
      sourceFormat: 'chara_card_v2',
      mesExample: this.mesExample,
      creatorNotes: this.creatorNotes,
      postHistoryInstructions: this.postHistoryInstructions,
      alternateGreetings: this.alternateGreetings.slice(),
      tags: this.tags.slice(),
      creator: this.creator.length === 0 ? 'AI Generated' : this.creator,
      characterVersion: this.characterVersion.length === 0 ? '1.0' : this.characterVersion,
      extensions: extensions,
      characterBook: characterBook,
      userName: ''
    };
  }

  /**
   * 应用单字段重新生成的结果到对应字段。
   */
  private applyFieldValue(fieldPath: string, value: string): void {
    switch (fieldPath) {
      case 'data.name':
        this.name = value;
        break;
      case 'data.description':
        this.description = value;
        break;
      case 'data.personality':
        this.personality = value;
        break;
      case 'data.scenario':
        this.scenario = value;
        break;
      case 'data.first_mes':
        this.firstMessage = value;
        break;
      case 'data.mes_example':
        this.mesExample = value;
        break;
      case 'data.creator_notes':
        this.creatorNotes = value;
        break;
      case 'data.system_prompt':
        this.systemPrompt = value;
        break;
      case 'data.post_history_instructions':
        this.postHistoryInstructions = value;
        break;
      case 'data.alternate_greetings':
        try {
          const arr: Object = JSON.parse(value);
          if (Array.isArray(arr)) {
            const strs: string[] = [];
            const a: Object[] = arr as Object[];
            for (let i: number = 0; i < a.length; i++) {
              if (typeof a[i] === 'string') {
                strs.push(a[i] as string);
              }
            }
            this.alternateGreetings = strs;
          }
        } catch (e) {
          // 解析失败,忽略
        }
        break;
      case 'data.tags':
        try {
          const arr: Object = JSON.parse(value);
          if (Array.isArray(arr)) {
            const strs: string[] = [];
            const a: Object[] = arr as Object[];
            for (let i: number = 0; i < a.length; i++) {
              if (typeof a[i] === 'string') {
                strs.push(a[i] as string);
              }
            }
            this.tags = strs;
          }
        } catch (e) {
          // 解析失败,忽略
        }
        break;
      default:
        // 未知字段,忽略
        break;
    }
  }
}

// ===== 辅助函数 =====

/**
 * 简化版 character_book entry 解析(用于从编辑表单重建)。
 */
function parseBookEntrySimplified(raw: Record<string, Object>, fallbackId: number): ParsedCharacterBookEntry {
  const keysRaw: Object | undefined = raw['keys'];
  const keys: string[] = [];
  if (Array.isArray(keysRaw)) {
    const arr: Object[] = keysRaw as Object[];
    for (let i: number = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string') {
        keys.push(arr[i] as string);
      }
    }
  }
  const secondaryKeysRaw: Object | undefined = raw['secondary_keys'];
  const secondaryKeys: string[] = [];
  if (Array.isArray(secondaryKeysRaw)) {
    const arr: Object[] = secondaryKeysRaw as Object[];
    for (let i: number = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string') {
        secondaryKeys.push(arr[i] as string);
      }
    }
  }
  const content: string = typeof raw['content'] === 'string' ? raw['content'] as string : '';
  const enabled: boolean = readBoolField(raw, 'enabled', true);
  const constant: boolean = readBoolField(raw, 'constant', false);
  const selective: boolean = readBoolField(raw, 'selective', false);
  const caseSensitive: boolean = readBoolField(raw, 'case_sensitive', false);
  const position: string = typeof raw['position'] === 'string' ? raw['position'] as string : 'before_char';
  const priority: number = readNumberField(raw, 'priority', 0);
  const insertionOrder: number = readNumberField(raw, 'insertion_order', 0);
  const name: string = typeof raw['name'] === 'string' ? raw['name'] as string : '';
  const comment: string = typeof raw['comment'] === 'string' ? raw['comment'] as string : '';
  const id: number = readNumberField(raw, 'id', fallbackId);

  let entryExtensions: Record<string, Object> = {};
  const extRaw: Object | undefined = raw['extensions'];
  if (extRaw !== undefined && extRaw !== null
    && typeof extRaw === 'object' && !Array.isArray(extRaw)) {
    entryExtensions = extRaw as Record<string, Object>;
  }

  return {
    keys: keys,
    secondaryKeys: secondaryKeys,
    content: content,
    enabled: enabled,
    constant: constant,
    selective: selective,
    position: position,
    priority: priority,
    name: name,
    comment: comment,
    insertionOrder: insertionOrder,
    caseSensitive: caseSensitive,
    id: id,
    extensions: entryExtensions
  };
}

function readBoolField(obj: Record<string, Object>, key: string, defaultValue: boolean): boolean {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  if (typeof v === 'number') {
    return (v as number) !== 0;
  }
  if (typeof v === 'string') {
    return (v as string) === 'true' || (v as string) === '1';
  }
  return defaultValue;
}

function readNumberField(obj: Record<string, Object>, key: string, defaultValue: number): number {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const n: number = Number(v);
    if (!isNaN(n)) {
      return n;
    }
  }
  if (typeof v === 'boolean') {
    return (v as boolean) ? 1 : 0;
  }
  return defaultValue;
}
