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
  AiGenerationHandle
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
      {
        onDelta: (content: string): void => {
          this.aiProgressChars = content.length;
        },
        onComplete: (result: AiGenerationResult): void => {
          this.aiWorking = false;
          let success: boolean = false;
          let errorMessage: string = result.errorMessage;
          if (result.status === AiGenerationStatus.Success && result.card !== null) {
            const merged: ParsedCharacterCard = mergePreservedFields(sourceCard, result.card);
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
 * 把原卡中 AI 再生时可能丢失的数据回填到新卡:
 * - 世界书(character_book):原卡有则保留
 * - 复用校验后的新卡文本字段
 * 保证“只改建议部分,未提及数据尽量不丢”。
 */
function mergePreservedFields(
  source: ParsedCharacterCard,
  generated: ParsedCharacterCard
): ParsedCharacterCard {
  const sourceBook: ParsedCharacterBook | null = source.characterBook;
  return {
    name: generated.name,
    nickname: generated.nickname,
    description: generated.description,
    personality: generated.personality,
    scenario: generated.scenario,
    firstMessage: generated.firstMessage,
    systemPrompt: generated.systemPrompt,
    avatarUri: source.avatarUri,
    sourceFormat: 'chara_card_v3',
    mesExample: generated.mesExample,
    creatorNotes: generated.creatorNotes,
    postHistoryInstructions: generated.postHistoryInstructions,
    alternateGreetings: generated.alternateGreetings,
    tags: generated.tags,
    creator: generated.creator,
    characterVersion: generated.characterVersion,
    extensions: generated.extensions,
    characterBook: sourceBook !== null ? sourceBook : generated.characterBook,
    userName: source.userName,
    groupOnlyGreetings: generated.groupOnlyGreetings,
    creatorNotesMultilingual: generated.creatorNotesMultilingual,
    source: generated.source,
    assets: generated.assets,
    creationDate: generated.creationDate,
    modificationDate: generated.modificationDate
  };
}