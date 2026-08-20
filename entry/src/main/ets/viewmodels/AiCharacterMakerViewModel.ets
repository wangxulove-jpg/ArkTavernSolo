/**
 * AiCharacterMakerViewModel AI 制作角色卡创意输入 ViewModel
 *
 * 管理创意输入表单状态、生成流程编排、流式进度回调。
 *
 * 职责:
 * 1. 持有创意输入字段(可观察,供 UI 双向绑定)
 * 2. 持有生成状态机(Idle/Generating/Cancelled)
 * 3. 持有流式累积文本(用于实时显示生成进度)
 * 4. 调用 AiCharacterGenerationService.generate
 * 5. 接收结果后通过 onGenerationComplete 回调通知页面跳转到预览页
 * 6. 持久化草稿到 AppPreferences(防止短暂切换丢失)
 * 7. 取消生成(取消后保留用户输入,不保存半成品)
 *
 * 不直接:
 * - 调用 network/ 模块(通过 AiCharacterGenerationService → ModelService)
 * - 调用 CharacterService(由预览页的 ViewModel 调用)
 * - 操作 RDB
 *
 * 隐私约束:
 * - 不向日志输出完整创意内容
 * - 不缓存 API Key
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import {
  AiCharacterInput,
  createEmptyAiCharacterInput,
  validateAiCharacterInput
} from '../models/AiCharacterInput';
import {
  AiGenerationResult,
  AiGenerationStatus
} from '../models/AiGenerationResult';
import {
  AiCharacterGenerationService,
  AiGenerationHandle,
  AiGenerationCallbacks
} from '../services/ai/AiCharacterGenerationService';
import { ParsedCharacterCard } from '../parser/CharacterCardJsonParser';

const LOG_TAG: string = 'AiCharMakerVM';

// 草稿持久化键
const KEY_DRAFT_CONCEPT: string = 'ai_draft_concept';
const KEY_DRAFT_NAME: string = 'ai_draft_name';
const KEY_DRAFT_BACKSTORY: string = 'ai_draft_backstory';
const KEY_DRAFT_PERSONALITY: string = 'ai_draft_personality';
const KEY_DRAFT_RELATION: string = 'ai_draft_relation';
const KEY_DRAFT_SPEECH: string = 'ai_draft_speech';
const KEY_DRAFT_BOOK: string = 'ai_draft_book';
const KEY_DRAFT_GREETINGS: string = 'ai_draft_greetings';
const KEY_DRAFT_MES_EXAMPLE: string = 'ai_draft_mes_example';
const KEY_DRAFT_USE_CURRENT: string = 'ai_draft_use_current';
const KEY_DRAFT_CONFIG_ID: string = 'ai_draft_config_id';

/** AppStorage 中临时传递生成卡片的键(给 Preview 页面读取) */
export const PENDING_AI_CARD_KEY: string = 'pendingAiCard';
/** AppStorage 中临时传递原始创意输入的键(给 Preview 页面用于重新生成) */
export const PENDING_AI_INPUT_KEY: string = 'pendingAiInput';

/**
 * 生成状态。
 */
export enum AiMakerState {
  /** 空闲 */
  Idle = 'Idle',
  /** 正在生成 */
  Generating = 'Generating',
  /** 已取消 */
  Cancelled = 'Cancelled'
}

/**
 * AI 制作角色卡创意输入 ViewModel。
 *
 * @Observed 装饰使 ArkUI 能观察字段变更并触发重绘。
 */
@Observed
export class AiCharacterMakerViewModel {
  // ===== 创意输入字段(双向绑定) =====
  conceptDescription: string = '';
  name: string = '';
  backstory: string = '';
  personalityKeywords: string = '';
  relationshipWithUser: string = '';
  speechStyle: string = '';
  generateCharacterBook: boolean = false;
  generateMultipleGreetings: boolean = false;
  generateMesExample: boolean = true;

  // ===== 模型选择 =====
  /** 始终为 true:跟随当前模型(G-AI-BUILDER-2 起不在页面暴露模型/Provider 选择) */
  useCurrentModel: boolean = true;
  /** 已废弃:保留字段以兼容旧草稿,不再使用 */
  configId: string = '';

  // ===== 生成状态 =====
  /** 当前状态 */
  state: AiMakerState = AiMakerState.Idle;
  /** 流式累积文本(用于实时显示生成进度) */
  accumulatedText: string = '';
  /** 错误信息(空字符串表示无错误) */
  errorMessage: string = '';
  /** 隐私提示是否已确认(首次生成前显示) */
  privacyConfirmed: boolean = false;

  // ===== 内部状态 =====
  private generationService: AiCharacterGenerationService;
  private prefs: AppPreferences;
  private generationHandle: AiGenerationHandle | null = null;
  /** 完成回调(由页面注入,用于跳转到预览页) */
  private onCompleteCallback: ((result: AiGenerationResult) => void) | null = null;

  constructor(generationService: AiCharacterGenerationService, prefs: AppPreferences) {
    this.generationService = generationService;
    this.prefs = prefs;
  }

  // ===== 生命周期 =====

  /**
   * 加载草稿。由页面 aboutToAppear 调用。
   */
  async loadDraft(): Promise<void> {
    try {
      this.conceptDescription = await this.prefs.getString(KEY_DRAFT_CONCEPT, '');
      this.name = await this.prefs.getString(KEY_DRAFT_NAME, '');
      this.backstory = await this.prefs.getString(KEY_DRAFT_BACKSTORY, '');
      this.personalityKeywords = await this.prefs.getString(KEY_DRAFT_PERSONALITY, '');
      this.relationshipWithUser = await this.prefs.getString(KEY_DRAFT_RELATION, '');
      this.speechStyle = await this.prefs.getString(KEY_DRAFT_SPEECH, '');
      this.generateCharacterBook = await this.prefs.getBoolean(KEY_DRAFT_BOOK, false);
      this.generateMultipleGreetings = await this.prefs.getBoolean(KEY_DRAFT_GREETINGS, false);
      this.generateMesExample = await this.prefs.getBoolean(KEY_DRAFT_MES_EXAMPLE, true);
      this.useCurrentModel = true;
      this.configId = '';
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadDraft failed: ' + String(e));
    }
  }

  /**
   * 保存草稿(自动调用,防抖由调用方控制)。
   */
  async saveDraft(): Promise<void> {
    try {
      await this.prefs.putString(KEY_DRAFT_CONCEPT, this.conceptDescription);
      await this.prefs.putString(KEY_DRAFT_NAME, this.name);
      await this.prefs.putString(KEY_DRAFT_BACKSTORY, this.backstory);
      await this.prefs.putString(KEY_DRAFT_PERSONALITY, this.personalityKeywords);
      await this.prefs.putString(KEY_DRAFT_RELATION, this.relationshipWithUser);
      await this.prefs.putString(KEY_DRAFT_SPEECH, this.speechStyle);
      await this.prefs.putBoolean(KEY_DRAFT_BOOK, this.generateCharacterBook);
      await this.prefs.putBoolean(KEY_DRAFT_GREETINGS, this.generateMultipleGreetings);
      await this.prefs.putBoolean(KEY_DRAFT_MES_EXAMPLE, this.generateMesExample);
      await this.prefs.putBoolean(KEY_DRAFT_USE_CURRENT, this.useCurrentModel);
      await this.prefs.putString(KEY_DRAFT_CONFIG_ID, this.configId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'saveDraft failed: ' + String(e));
    }
  }

  /**
   * 清空草稿(生成成功并跳转后调用)。
   */
  async clearDraft(): Promise<void> {
    this.conceptDescription = '';
    this.name = '';
    this.backstory = '';
    this.personalityKeywords = '';
    this.relationshipWithUser = '';
    this.speechStyle = '';
    this.generateCharacterBook = false;
    this.generateMultipleGreetings = false;
    this.generateMesExample = true;
    this.useCurrentModel = true;
    this.configId = '';
    await this.saveDraft();
  }

  /**
   * 释放资源,取消生成。
   * 由页面 aboutToDisappear 调用。
   */
  dispose(): void {
    this.cancelGeneration();
  }

  /**
   * 设置完成回调。
   */
  setOnCompleteCallback(cb: (result: AiGenerationResult) => void): void {
    this.onCompleteCallback = cb;
  }

  // ===== 生成流程 =====

  /**
   * 开始生成。
   * 调用前应检查 validateInput() 和 privacyConfirmed。
   */
  startGeneration(): void {
    if (this.state === AiMakerState.Generating) {
      return;
    }
    const input: AiCharacterInput = this.buildInput();
    const error: string | null = validateAiCharacterInput(input);
    if (error !== null) {
      this.errorMessage = error;
      return;
    }

    this.state = AiMakerState.Generating;
    this.accumulatedText = '';
    this.errorMessage = '';

    const callbacks: AiGenerationCallbacks = {
      onStart: (): void => {
      },
      onDelta: (accumulated: string): void => {
        if (this.state !== AiMakerState.Generating) {
          return;
        }
        this.accumulatedText = accumulated;
      },
      onComplete: (result: AiGenerationResult): void => {
        if (this.state !== AiMakerState.Generating) {
          // 已被取消或重置,丢弃结果
          return;
        }
        this.state = AiMakerState.Idle;
        this.accumulatedText = result.rawResponse;

        if (result.status === AiGenerationStatus.Success) {
          // 持久化生成的卡片到 AppStorage(供 Preview 页面读取)
          AppStorage.setOrCreate<ParsedCharacterCard | null>(PENDING_AI_CARD_KEY, result.card);
          AppStorage.setOrCreate<AiCharacterInput | null>(PENDING_AI_INPUT_KEY, input);
          if (this.onCompleteCallback !== null) {
            this.onCompleteCallback(result);
          }
        } else if (result.status === AiGenerationStatus.Cancelled) {
          // 取消后保留用户输入,不报错
        } else {
          Logger.warn(LOG_TAG, 'generation failed: ' + result.errorMessage);
          this.errorMessage = result.errorMessage;
        }
      },
      onError: (): void => {
        // 错误统一通过 onComplete 返回,这里不做处理
      }
    };

    this.generationHandle = this.generationService.generate(
      input, this.useCurrentModel, this.configId, callbacks
    );

    // 异步保存草稿(防止页面切换丢失)
    void this.saveDraft();
  }

  /**
   * 取消生成(用户点击停止按钮)。
   * 取消后保留用户输入,不保存半成品。
   */
  cancelGeneration(): void {
    if (this.state !== AiMakerState.Generating) {
      return;
    }
    this.state = AiMakerState.Cancelled;
    if (this.generationHandle !== null) {
      try {
        this.generationHandle.abort();
      } catch (e) {
        Logger.warn(LOG_TAG, 'abort throw: ' + String(e));
      }
      this.generationHandle = null;
    }
    // 短暂延迟后回到 Idle 状态(让 UI 显示取消提示)
    setTimeout((): void => {
      if (this.state === AiMakerState.Cancelled) {
        this.state = AiMakerState.Idle;
      }
    }, 300);
  }

  /**
   * 清除错误信息。
   */
  clearError(): void {
    this.errorMessage = '';
  }

  /**
   * 重置所有输入与状态(放弃按钮调用)。
   */
  async resetAll(): Promise<void> {
    this.cancelGeneration();
    this.conceptDescription = '';
    this.name = '';
    this.backstory = '';
    this.personalityKeywords = '';
    this.relationshipWithUser = '';
    this.speechStyle = '';
    this.generateCharacterBook = false;
    this.generateMultipleGreetings = false;
    this.generateMesExample = true;
    this.useCurrentModel = true;
    this.configId = '';
    this.accumulatedText = '';
    this.errorMessage = '';
    this.privacyConfirmed = false;
    await this.clearDraft();
  }

  // ===== 内部方法 =====

  private buildInput(): AiCharacterInput {
    return {
      conceptDescription: this.conceptDescription,
      name: this.name,
      backstory: this.backstory,
      personalityKeywords: this.personalityKeywords,
      relationshipWithUser: this.relationshipWithUser,
      speechStyle: this.speechStyle,
      generateCharacterBook: this.generateCharacterBook,
      generateMultipleGreetings: this.generateMultipleGreetings,
      generateMesExample: this.generateMesExample
    };
  }
}
