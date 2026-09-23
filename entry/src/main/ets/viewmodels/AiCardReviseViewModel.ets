/**
 * AiCardReviseViewModel 导入角色卡→看详情→提建议→AI 重做 ViewModel
 *
 * 职责:
 * 1. 导入 JSON/PNG 角色卡并解析为 ParsedCharacterCard
 * 2. 暴露卡详情供 UI 展示
 * 3. 收集用户修改建议
 * 4. 调用 AiCharacterGenerationService.reviseCharacterCard 基于原卡+建议重新生成
 * 5. 成功后把新卡写入 AppStorage(pendingAiCard),供 AiCharacterPreviewPage 预览/保存
 *
 * 保留策略:
 * - 世界书(character_book)与扩展字段由本 VM 在原卡与结果间回填,避免 AI 再生时丢失
 * - 即“只改建议部分,未提及内容与数据尽可能保留”
 *
 * 不直接:
 * - 调用 network/(通过 GenerationService → ModelService)
 * - 操作 RDB(由 AiCharacterPreviewPage 保存时经 CharacterService)
 */

import { Logger } from '../utils/Logger';
import { CharacterService } from '../services/CharacterService';
import {
  AiCharacterGenerationService,
  AiGenerationHandle,
  FRONTEND_OMITTED_MARKER
} from '../services/ai/AiCharacterGenerationService';
import {
  ParsedCharacterCard,
  ParseResult,
  ParsedCharacterBook
} from '../parser/CharacterCardJsonParser';
import {
  AiGenerationResult,
  AiGenerationStatus
} from '../models/AiGenerationResult';
import { PENDING_AI_CARD_KEY, PENDING_AI_PNG_URI_KEY } from './AiCharacterMakerViewModel';

const LOG_TAG: string = 'AiCardReviseVM';

@Observed
export class AiCardReviseViewModel {
  // ===== 导入状态 =====
  importing: boolean = false;
  importError: string = '';
  parsedCard: ParsedCharacterCard | null = null;
  /** PNG 导入时来源图片文件 URI(用于保存时把卡图当封面) */
  pngSourceUri: string = '';

  // ===== 建议 =====
  suggestions: string = '';
  /** 是否允许 AI 修改世界书(默认关闭;开启才会把世界书发给 AI 并按建议修改) */
  includeWorldbook: boolean = false;

  // ===== AI 重做状态 =====
  aiWorking: boolean = false;
  aiError: string = '';
  /** 生成过程中累计字符数(用于进度显示) */
  aiProgressChars: number = 0;

  // ===== 内部 =====
  private characterService: CharacterService;
  private generationService: AiCharacterGenerationService;
  private reviseHandle: AiGenerationHandle | null = null;
  /** 页面注入:AI 生成完成(成功会携带新卡)回调 */
  private onReviseCompleteCallback:
    ((success: boolean, errorMessage: string) => void) | null = null;

  constructor(characterService: CharacterService, generationService: AiCharacterGenerationService) {
    this.characterService = characterService;
    this.generationService = generationService;
  }

  setOnReviseComplete(cb: (success: boolean, errorMessage: string) => void): void {
    this.onReviseCompleteCallback = cb;
  }

  dispose(): void {
    this.cancelRevise();
  }

  // ===== 导入解析 =====

  /**
   * 从文件 URI 导入并解析角色卡(自动识别 PNG / JSON)。
   */
  async startImportFile(uri: string): Promise<void> {
    this.importing = true;
    this.importError = '';
    this.parsedCard = null;
    this.pngSourceUri = '';
    this.suggestions = '';
    this.includeWorldbook = false;
    this.aiError = '';
    try {
      const lowerUri: string = uri.toLowerCase();
      let card: ParsedCharacterCard | null = null;
      if (lowerUri.endsWith('.png')) {
        this.pngSourceUri = uri;
        card = await this.importPng(uri);
      } else {
        card = await this.importJson(uri);
      }
      if (card === null) {
        return;
      }
      this.parsedCard = card;
    } catch (e) {
      this.importError = '导入失败: ' + String(e);
      Logger.error(LOG_TAG, 'startImportFile failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  private async importJson(uri: string): Promise<ParsedCharacterCard | null> {
    const jsonString: string = await this.characterService.readFileContent(uri);
    return this.parseAndValidate(jsonString);
  }

  private async importPng(uri: string): Promise<ParsedCharacterCard | null> {
    const pngImport = await this.characterService.importPngFromFile(uri);
    if (!pngImport.result.success) {
      this.importError = pngImport.result.error;
      return null;
    }
    return this.parseAndValidate(pngImport.result.jsonString);
  }

  private parseAndValidate(jsonString: string): ParsedCharacterCard | null {
    const result: ParseResult = this.characterService.parseCharacterJson(jsonString);
    if (!result.success || result.card === null) {
      this.importError = result.error !== null ? result.error : '导入失败';
      return null;
    }
    return result.card;
  }

  // ===== AI 重做 =====

  /**
   * 基于当前原卡 + 建议重新生成新角色卡。
   */
  startRevise(): void {
    if (this.parsedCard === null) {
      this.aiError = '请先导入一张角色卡';
      return;
    }
    if (this.aiWorking) {
      return;
    }
    this.aiWorking = true;
    this.aiError = '';
    this.aiProgressChars = 0;
    const sourceCard: ParsedCharacterCard = this.parsedCard;

    this.reviseHandle = this.generationService.reviseCharacterCard(
      sourceCard,
      this.suggestions,
      true,
      '',
      this.includeWorldbook,
      {
        onDelta: (content: string): void => {
          this.aiProgressChars = content.length;
        },
        onComplete: (result: AiGenerationResult): void => {
          this.aiWorking = false;
          let success: boolean = false;
          let errorMessage: string = result.errorMessage;
          if (result.status === AiGenerationStatus.Success && result.card !== null) {
            const merged: ParsedCharacterCard = mergePreservedFields(
              sourceCard, result.card, this.includeWorldbook, result.updatedFields ?? null
            );
            AppStorage.setOrCreate<ParsedCharacterCard | null>(PENDING_AI_CARD_KEY, merged);
            // 来源为 PNG 时,把卡图传给预览页,保存时用作封面
            AppStorage.setOrCreate<string>(PENDING_AI_PNG_URI_KEY, this.pngSourceUri);
            success = true;
            errorMessage = '';
          } else if (result.status === AiGenerationStatus.Failed) {
            this.aiError = errorMessage.length > 0 ? errorMessage : '重新生成失败';
          }
          if (this.onReviseCompleteCallback !== null) {
            this.onReviseCompleteCallback(success, errorMessage);
          }
        }
      }
    );
  }

  cancelRevise(): void {
    if (this.aiWorking && this.reviseHandle !== null) {
      try {
        this.reviseHandle.abort();
      } catch (e) {
        Logger.warn(LOG_TAG, 'cancel revise abort throw: ' + String(e));
      }
    }
    this.reviseHandle = null;
    this.aiWorking = false;
  }
}

/**
 * 判断 frontend 值是否为 AI 回显的省略占位(prompt 中超长 HTML 被省略展示,
 * AI 不应输出该字段;若回显了占位则视为未修改,保留原卡值)。
 */
function isOmittedFrontend(value: Object): boolean {
  if (typeof value === 'string') {
    return (value as string).indexOf(FRONTEND_OMITTED_MARKER) >= 0;
  }
  if (typeof value === 'object' && !Array.isArray(value)) {
    const html: Object | undefined = (value as Record<string, Object>)['html'];
    if (typeof html === 'string') {
      return (html as string).indexOf(FRONTEND_OMITTED_MARKER) >= 0;
    }
  }
  return false;
}

/**
 * 合并原卡与 AI 结果的 extensions:
 * - 以原卡 extensions 为基底:AI 输入未包含这些扩展(如 SillyTavern 的脚本类字段),原样保留避免丢失
 * - arktavern 命名空间做子键级合并:原卡为基底,AI 显式输出的子键(status/frontend 等)覆盖;
 *   AI 未输出的子键保留原值(如只改状态时 frontend 不丢);AI 回显省略占位的 frontend 保留原卡;
 *   AI 输出空 arktavern 对象视为未涉及,整体保留原卡
 */
function mergePreservedExtensions(
  source: Record<string, Object>,
  generated: Record<string, Object>
): Record<string, Object> {
  const result: Record<string, Object> = {};
  const sourceKeys: string[] = Object.keys(source);
  for (let i = 0; i < sourceKeys.length; i++) {
    const key: string = sourceKeys[i];
    result[key] = source[key];
  }
  const generatedArk: Object | undefined = generated['arktavern'];
  if (typeof generatedArk === 'object' && generatedArk !== null && !Array.isArray(generatedArk)) {
    const genArkObj: Record<string, Object> = generatedArk as Record<string, Object>;
    const genArkKeys: string[] = Object.keys(genArkObj);
    if (genArkKeys.length > 0) {
      const sourceArkRaw: Object | undefined = source['arktavern'];
      const sourceArk: Record<string, Object> =
        (typeof sourceArkRaw === 'object' && sourceArkRaw !== null && !Array.isArray(sourceArkRaw))
          ? sourceArkRaw as Record<string, Object> : {};
      const mergedArk: Record<string, Object> = {};
      const sKeys: string[] = Object.keys(sourceArk);
      for (let i = 0; i < sKeys.length; i++) {
        mergedArk[sKeys[i]] = sourceArk[sKeys[i]];
      }
      for (let i = 0; i < genArkKeys.length; i++) {
        const key: string = genArkKeys[i];
        const value: Object = genArkObj[key];
        if (key === 'frontend' && isOmittedFrontend(value)) {
          continue;
        }
        mergedArk[key] = value;
      }
      result['arktavern'] = mergedArk;
    }
  }
  return result;
}

/**
 * 判断 JSON 字段是否为 AI 本次显式输出(增量合并用)。
 * updatedFields 为 null 表示未知(旧流程),按全量更新处理保持旧行为。
 */
function isFieldUpdated(jsonKey: string, updatedFields: string[] | null): boolean {
  if (updatedFields === null) {
    return true;
  }
  return updatedFields.indexOf(jsonKey) >= 0;
}

/**
 * 把原卡中 AI 再生时可能丢失的数据回填到新卡(增量合并模式):
 * - 文本/数组字段:仅当 AI 本次显式输出该字段(updatedFields 含对应 JSON 键)时取 AI 值,
 *   否则保留原卡值——AI 未提及的内容不再被默认值清空
 * - 世界书(character_book):按用户意图决定来源
 *   - includeWorldbook=true(用户要求修改世界书):信任 AI 结果;若 AI 未返回世界书则回退原卡避免丢失
 *   - includeWorldbook=false:完全保留原卡世界书,避免 AI 再生导致丢失/走样
 * - extensions:原卡为基底回填,arktavern 在 AI 显式输出时取 AI 结果(见 mergePreservedExtensions)
 * - 头像/用户名/创建日期等运行时字段始终保留原卡
 * 保证"只改建议部分,未提及数据尽量不丢"。
 */
function mergePreservedFields(
  source: ParsedCharacterCard,
  generated: ParsedCharacterCard,
  includeWorldbook: boolean,
  updatedFields: string[] | null
): ParsedCharacterCard {
  const sourceBook: ParsedCharacterBook | null = source.characterBook;
  const resultBook: ParsedCharacterBook | null = includeWorldbook
    ? (generated.characterBook !== null ? generated.characterBook : sourceBook)
    : (sourceBook !== null ? sourceBook : generated.characterBook);
  return {
    name: generated.name,
    nickname: isFieldUpdated('nickname', updatedFields) ? generated.nickname : source.nickname,
    description: isFieldUpdated('description', updatedFields)
      ? generated.description : source.description,
    personality: isFieldUpdated('personality', updatedFields)
      ? generated.personality : source.personality,
    scenario: isFieldUpdated('scenario', updatedFields) ? generated.scenario : source.scenario,
    firstMessage: isFieldUpdated('first_mes', updatedFields)
      ? generated.firstMessage : source.firstMessage,
    systemPrompt: isFieldUpdated('system_prompt', updatedFields)
      ? generated.systemPrompt : source.systemPrompt,
    avatarUri: source.avatarUri,
    sourceFormat: 'chara_card_v3',
    mesExample: isFieldUpdated('mes_example', updatedFields)
      ? generated.mesExample : source.mesExample,
    creatorNotes: isFieldUpdated('creator_notes', updatedFields)
      ? generated.creatorNotes : source.creatorNotes,
    postHistoryInstructions: isFieldUpdated('post_history_instructions', updatedFields)
      ? generated.postHistoryInstructions : source.postHistoryInstructions,
    alternateGreetings: isFieldUpdated('alternate_greetings', updatedFields)
      ? generated.alternateGreetings : source.alternateGreetings,
    tags: isFieldUpdated('tags', updatedFields) ? generated.tags : source.tags,
    creator: isFieldUpdated('creator', updatedFields) ? generated.creator : source.creator,
    characterVersion: isFieldUpdated('character_version', updatedFields)
      ? generated.characterVersion : source.characterVersion,
    extensions: mergePreservedExtensions(source.extensions, generated.extensions),
    characterBook: resultBook,
    userName: source.userName,
    groupOnlyGreetings: isFieldUpdated('group_only_greetings', updatedFields)
      ? generated.groupOnlyGreetings : source.groupOnlyGreetings,
    creatorNotesMultilingual: isFieldUpdated('creator_notes_multilingual', updatedFields)
      ? generated.creatorNotesMultilingual : source.creatorNotesMultilingual,
    source: isFieldUpdated('source', updatedFields) ? generated.source : source.source,
    assets: isFieldUpdated('assets', updatedFields) ? generated.assets : source.assets,
    creationDate: source.creationDate,
    modificationDate: Date.now()
  };
}