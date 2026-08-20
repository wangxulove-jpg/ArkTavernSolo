/**
 * AiCharacterGenerationService AI 角色卡生成服务
 *
 * 职责:
 * 1. 根据创意输入构建 system prompt 和 user prompt
 * 2. 通过 ModelService.streamCurrentChat 流式生成 V2 JSON
 * 3. 流式过程中累积响应,但**不写入数据库**
 * 4. 生成结束后调用 CharacterCardV2Fixer 清理 Markdown 与提取 JSON
 * 5. 调用 CharacterCardV2Validator 校验
 * 6. 校验失败时触发受控格式修复(最多 1 次):将原 JSON 和错误类别发送给同一模型,要求只返回修正后的完整 V2 JSON
 * 7. 返回 AiGenerationResult
 *
 * 请求次数约束(G-AI-BUILDER-2-FIX):
 * - 初始生成请求:1 次
 * - 格式修复请求:最多 1 次(MAX_REPAIR_ATTEMPTS = 1)
 * - 总请求上限:2 次
 * - 第二次仍失败立即停止,不发起第三次请求
 *
 * 不在本服务:
 * - UI 状态(由 ViewModel 管理)
 * - 数据库写入(由 CharacterService.importFromParsed 在用户点击保存时执行)
 * - 头像生成(Phase 1 不实现)
 *
 * 隐私约束:
 * - 不向日志输出 API Key / Authorization / 完整创意内容 / 完整模型响应 / 完整角色卡正文
 * - 错误日志只记录请求阶段、状态码、错误类型
 * - 不修改 PromptBuilder / ChatService / Prompt Preset
 *
 * 请求隔离:
 * - 只发送 system + user 两条消息,不携带聊天历史/分支/记忆/当前角色卡/世界书/Prompt Preset
 * - 调用 ModelService.streamCurrentChat,options 由本服务显式构造(temperature 较低、maxTokens 较大、不流式也可以)
 *
 * 生成取消:
 * - 通过 ChatStreamHandle.abort() 取消流式请求
 * - 通过 generationId 防止旧回调写入已切换的 ViewModel
 */

import { ModelService } from '../ModelService';
import { ProviderConfig } from '../../models/ProviderConfig';
import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ChatRequestOptions } from '../../models/ChatRequest';
import { ChatStreamHandle, ChatStreamCallbacks, ChatDelta, ChatStreamResult } from '../../models/ChatStreamTypes';
import { NetworkError } from '../../models/NetworkError';
import { Logger } from '../../utils/Logger';
import { generateUuid } from '../../utils/Uuid';
import {
  AiCharacterInput,
  createEmptyAiCharacterInput
} from '../../models/AiCharacterInput';
import {
  AiGenerationResult,
  AiGenerationStatus,
  AiGenerationMeta,
  AiValidationError,
  AI_GENERATION_VERSION
} from '../../models/AiGenerationResult';
import { validateV2CharacterCard } from '../../parser/CharacterCardV2Validator';
import { extractJsonObject } from '../../parser/CharacterCardV2Fixer';
import { ParsedCharacterCard } from '../../parser/CharacterCardJsonParser';

const LOG_TAG: string = 'AiCharGen';

/** 生成温度(较低,提高 JSON 结构稳定性) */
const GENERATION_TEMPERATURE: number = 0.7;
/** 生成 top_p */
const GENERATION_TOP_P: number = 0.95;
/** 生成最大 token 数(角色卡字段较多,需要较大空间) */
const GENERATION_MAX_TOKENS: number = 8192;
/**
 * 受控格式修复最大次数(G-AI-BUILDER-2-FIX)。
 *
 * 语义:初始生成请求失败后,最多再发起 1 次格式修复请求。
 * 即总请求上限 = 1(初始) + 1(修复) = 2 次。
 * 第二次仍失败立即停止,不发起第三次请求。
 */
const MAX_REPAIR_ATTEMPTS: number = 1;

/**
 * 流式生成回调。
 */
export interface AiGenerationCallbacks {
  /** 流开始(已发起请求,等待响应) */
  onStart?: () => void;
  /** 收到增量内容(可多次,用于显示生成进度) */
  onDelta: (accumulatedContent: string) => void;
  /** 完成(成功或失败都会调用,onError 之后调用) */
  onComplete: (result: AiGenerationResult) => void;
  /** 网络错误(可选,错误统一通过 onComplete 返回,此回调用于早期错误感知) */
  onError?: (error: NetworkError) => void;
}

/**
 * 单字段重新生成回调。
 */
export interface AiFieldRegenCallbacks {
  /** 完成回调。fieldValue 为新生成的字段内容(失败时为 null) */
  onComplete: (fieldValue: string | null, errorMessage: string) => void;
}

/**
 * 流式生成句柄。
 */
export interface AiGenerationHandle {
  /** 中止生成(幂等) */
  abort(): void;
  /** 查询是否已结束 */
  isDone(): boolean;
}

/**
 * AiGenerationHandle 的默认实现(避免对象字面量在 ArkTS 严格模式下被拒)。
 */
class AiGenerationHandleImpl implements AiGenerationHandle {
  private abortFn: () => void;
  private isDoneFn: () => boolean;

  constructor(abortFn: () => void, isDoneFn: () => boolean) {
    this.abortFn = abortFn;
    this.isDoneFn = isDoneFn;
  }

  abort(): void {
    this.abortFn();
  }

  isDone(): boolean {
    return this.isDoneFn();
  }
}

/**
 * AI 角色卡生成服务。
 */
export class AiCharacterGenerationService {
  private modelService: ModelService;

  constructor(modelService: ModelService) {
    this.modelService = modelService;
  }

  /**
   * 流式生成 V2 角色卡。
   *
   * @param input 创意输入
   * @param useCurrentModel true=跟随当前 ProviderConfig;false=使用指定 configId
   * @param configId 指定 ProviderConfig ID(useCurrentModel=false 时必填)
   * @param callbacks 流式回调
   * @returns 生成句柄(用于取消)
   */
  generate(
    input: AiCharacterInput,
    useCurrentModel: boolean,
    configId: string,
    callbacks: AiGenerationCallbacks
  ): AiGenerationHandle {
    const state: GenerationState = {
      aborted: false,
      done: false,
      accumulated: '',
      meta: null,
      autoFixAttempts: 0,
      streamHandle: null,
      abortChecker: null
    };

    // 异步执行
    this.executeGeneration(input, useCurrentModel, configId, state, callbacks).then(
      (): void => { /* 正常完成 */ },
      (err: Object): void => {
        if (state.done) {
          return;
        }
        state.done = true;
        Logger.error(LOG_TAG, 'generation unexpected error: ' + String(err));
        const result: AiGenerationResult = createFailed(
          state.accumulated,
          [],
          state.autoFixAttempts,
          false,
          state.meta,
          '生成失败: ' + String(err)
        );
        try {
          callbacks.onComplete(result);
        } catch (e) {
          Logger.error(LOG_TAG, 'onComplete throw: ' + String(e));
        }
      }
    );

    const handle: AiGenerationHandle = new AiGenerationHandleImpl(
      (): void => {
        if (state.done) {
          return;
        }
        state.aborted = true;
      },
      (): boolean => state.done
    );
    return handle;
  }

  /**
   * 重新生成单个字段。
   *
   * @param fieldPath 字段路径(如 "data.description")
   * @param currentCard 当前完整角色卡(用于提供上下文)
   * @param useCurrentModel 是否跟随当前模型
   * @param configId 指定模型 ID
   * @param callbacks 完成回调
   * @returns 生成句柄
   */
  regenerateField(    fieldPath: string,
    currentCard: ParsedCharacterCard,
    useCurrentModel: boolean,
    configId: string,
    callbacks: AiFieldRegenCallbacks
  ): AiGenerationHandle {
    const state: GenerationState = {
      aborted: false,
      done: false,
      accumulated: '',
      meta: null,
      autoFixAttempts: 0,
      streamHandle: null,
      abortChecker: null
    };

    this.executeFieldRegen(fieldPath, currentCard, useCurrentModel, configId, state, callbacks).then(
      (): void => { /* 正常完成 */ },
      (err: Object): void => {
        if (state.done) {
          return;
        }
        state.done = true;
        Logger.error(LOG_TAG, 'field regen unexpected error: ' + String(err));
        try {
          callbacks.onComplete(null, '字段重新生成失败: ' + String(err));
        } catch (e) {
          Logger.error(LOG_TAG, 'onComplete throw: ' + String(e));
        }
      }
    );

    const handle: AiGenerationHandle = new AiGenerationHandleImpl(
      (): void => {
        if (state.done) {
          return;
        }
        state.aborted = true;
      },
      (): boolean => state.done
    );
    return handle;
  }

  /**
   * 优化现有角色卡(ARK-UI-LAYOUT-OPT-02 后新增功能)。
   *
   * 语义:不改变角色卡的内容与设定,而是根据角色卡已有内容,
   * 让 AI 将其重写为规范、完整的 Tavern Card V2 JSON 结构。
   * 主要用于导入 PNG/JSON 角色卡时,内容字段不完整/结构混乱的整理。
   *
   * 约束:
   * - 保持角色名称、设定、性格、场景等核心内容一致,不重新创作
   * - 只整理字段归属、补全缺失字段(空字段补空串/空数组)、统一语言风格
   * - 不修改头像 / 世界书已有条目内容
   *
   * @param card 现有角色卡(来自导入解析)
   * @param useCurrentModel true=跟随当前 ProviderConfig;false=使用指定 configId
   * @param configId 指定 ProviderConfig ID
   * @param callbacks 流式回调
   * @returns 生成句柄(用于取消)
   */
  optimizeCharacterCard(
    card: ParsedCharacterCard,
    useCurrentModel: boolean,
    configId: string,
    callbacks: AiGenerationCallbacks
  ): AiGenerationHandle {
    const state: GenerationState = {
      aborted: false,
      done: false,
      accumulated: '',
      meta: null,
      autoFixAttempts: 0,
      streamHandle: null,
      abortChecker: null
    };

    this.executeOptimize(card, useCurrentModel, configId, state, callbacks).then(
      (): void => { /* 正常完成 */ },
      (err: Object): void => {
        if (state.done) {
          return;
        }
        state.done = true;
        Logger.error(LOG_TAG, 'optimize unexpected error: ' + String(err));
        const result: AiGenerationResult = createFailed(
          state.accumulated,
          [],
          state.autoFixAttempts,
          false,
          state.meta,
          '优化失败: ' + String(err)
        );
        try {
          callbacks.onComplete(result);
        } catch (e) {
          Logger.error(LOG_TAG, 'onComplete throw: ' + String(e));
        }
      }
    );

    const handle: AiGenerationHandle = new AiGenerationHandleImpl(
      (): void => {
        if (state.done) {
          return;
        }
        state.aborted = true;
      },
      (): boolean => state.done
    );
    return handle;
  }

  /**
   * 执行角色卡优化(内部实现)。
   */
  private async executeOptimize(
    card: ParsedCharacterCard,
    useCurrentModel: boolean,
    configId: string,
    state: GenerationState,
    callbacks: AiGenerationCallbacks
  ): Promise<void> {
    const config: ProviderConfig | null = useCurrentModel
      ? await this.modelService.getCurrentConfig()
      : await this.modelService.getConfig(configId);
    if (config === null) {
      state.done = true;
      callbacks.onComplete(createFailed(
        '', [], 0, false, null, '未找到可用的 Provider 配置,请先在模型设置中配置'
      ));
      return;
    }
    if (config.modelName.trim().length === 0) {
      state.done = true;
      callbacks.onComplete(createFailed(
        '', [], 0, false, null, '当前 Provider 配置未指定模型名称'
      ));
      return;
    }
    const hasKey: boolean = await this.modelService.hasApiKey(config.id);
    if (!hasKey) {
      state.done = true;
      callbacks.onComplete(createFailed(
        '', [], 0, false, null, '当前 Provider 配置未设置 API Key'
      ));
      return;
    }

    const meta: AiGenerationMeta = {
      providerId: config.id,
      modelId: config.modelName,
      generatedAt: Date.now(),
      generationVersion: AI_GENERATION_VERSION
    };
    state.meta = meta;

    // 构造优化消息(保持内容,重写为规范 V2 JSON)
    const messages: ChatMessage[] = buildOptimizeMessages(card);
    const options: ChatRequestOptions = {
      temperature: GENERATION_TEMPERATURE,
      topP: GENERATION_TOP_P,
      maxTokens: GENERATION_MAX_TOKENS,
      stream: true
    };

    const rawResponse: string = await this.streamMessages(
      messages, options, state, callbacks, '优化失败'
    );
    if (state.aborted) {
      state.done = true;
      callbacks.onComplete(createCancelledResult(rawResponse));
      return;
    }
    if (rawResponse.length === 0) {
      state.done = true;
      callbacks.onComplete(createFailed(
        '', [], 0, false, meta, '优化失败:模型返回空响应'
      ));
      return;
    }

    // 校验 + 自动修复(复用生成路径)
    const finalResult: AiGenerationResult = await this.validateAndAutoFix(
      rawResponse, meta, state, callbacks, messages, options, createEmptyAiCharacterInput()
    );
    state.done = true;
    callbacks.onComplete(finalResult);
  }

  // ===== 内部实现 =====

  private async executeGeneration(
    input: AiCharacterInput,
    useCurrentModel: boolean,
    configId: string,
    state: GenerationState,
    callbacks: AiGenerationCallbacks
  ): Promise<void> {
    // 1. 解析 ProviderConfig,准备 meta
    const config: ProviderConfig | null = useCurrentModel
      ? await this.modelService.getCurrentConfig()
      : await this.modelService.getConfig(configId);
    if (config === null) {
      state.done = true;
      const result: AiGenerationResult = createFailed(
        '', [], 0, false, null, '未找到可用的 Provider 配置,请先在模型设置中配置'
      );
      callbacks.onComplete(result);
      return;
    }
    if (config.modelName.trim().length === 0) {
      state.done = true;
      const result: AiGenerationResult = createFailed(
        '', [], 0, false, null, '当前 Provider 配置未指定模型名称'
      );
      callbacks.onComplete(result);
      return;
    }
    const hasKey: boolean = await this.modelService.hasApiKey(config.id);
    if (!hasKey) {
      state.done = true;
      const result: AiGenerationResult = createFailed(
        '', [], 0, false, null, '当前 Provider 配置未设置 API Key'
      );
      callbacks.onComplete(result);
      return;
    }

    const meta: AiGenerationMeta = {
      providerId: config.id,
      modelId: config.modelName,
      generatedAt: Date.now(),
      generationVersion: AI_GENERATION_VERSION
    };
    state.meta = meta;

    // 2. 构造 messages
    const messages: ChatMessage[] = buildGenerationMessages(input);
    const options: ChatRequestOptions = {
      temperature: GENERATION_TEMPERATURE,
      topP: GENERATION_TOP_P,
      maxTokens: GENERATION_MAX_TOKENS,
      stream: true
    };

    // 3. 流式生成
    const rawResponse: string = await this.streamMessages(
      messages, options, state, callbacks, '生成失败'
    );
    if (state.aborted) {
      state.done = true;
      callbacks.onComplete(createCancelledResult(rawResponse));
      return;
    }
    if (rawResponse.length === 0) {
      state.done = true;
      const result: AiGenerationResult = createFailed(
        '', [], 0, false, meta, '生成失败:模型返回空响应'
      );
      callbacks.onComplete(result);
      return;
    }

    // 4. 校验 + 自动修复
    const finalResult: AiGenerationResult = await this.validateAndAutoFix(
      rawResponse, meta, state, callbacks, messages, options, input
    );
    state.done = true;
    callbacks.onComplete(finalResult);
  }

  private async executeFieldRegen(
    fieldPath: string,
    currentCard: ParsedCharacterCard,
    useCurrentModel: boolean,
    configId: string,
    state: GenerationState,
    callbacks: AiFieldRegenCallbacks
  ): Promise<void> {
    const config: ProviderConfig | null = useCurrentModel
      ? await this.modelService.getCurrentConfig()
      : await this.modelService.getConfig(configId);
    if (config === null || config.modelName.trim().length === 0) {
      state.done = true;
      callbacks.onComplete(null, '未找到可用的 Provider 配置');
      return;
    }

    const messages: ChatMessage[] = buildFieldRegenMessages(fieldPath, currentCard);
    const options: ChatRequestOptions = {
      temperature: GENERATION_TEMPERATURE,
      topP: GENERATION_TOP_P,
      maxTokens: GENERATION_MAX_TOKENS,
      stream: true
    };

    const rawResponse: string = await this.streamMessages(
      messages, options, state, null, '字段重新生成失败'
    );
    if (state.aborted) {
      state.done = true;
      callbacks.onComplete(null, '已取消');
      return;
    }
    if (rawResponse.length === 0) {
      state.done = true;
      callbacks.onComplete(null, '模型返回空响应');
      return;
    }

    // 字段重新生成只要求返回纯文本字段值(无 JSON 包装)
    // 去除可能的代码块标记(模型可能误用 ```)
    let fieldValue: string = rawResponse.trim();
    if (fieldPath === 'data.alternate_greetings' || fieldPath === 'data.tags') {
      // 数组字段:尝试 JSON.parse
      try {
        const arr: Object = JSON.parse(fieldValue);
        if (Array.isArray(arr)) {
          const strs: string[] = [];
          const a: Object[] = arr as Object[];
          for (let i: number = 0; i < a.length; i++) {
            if (typeof a[i] === 'string') {
              strs.push(a[i] as string);
            }
          }
          state.done = true;
          callbacks.onComplete(JSON.stringify(strs), '');
          return;
        }
      } catch (e) {
        // 不是 JSON,继续作为字符串处理
      }
    }
    // 去除可能的首尾代码块标记
    if (fieldValue.startsWith('```')) {
      const firstNl: number = fieldValue.indexOf('\n');
      if (firstNl >= 0) {
        fieldValue = fieldValue.substring(firstNl + 1);
      }
    }
    if (fieldValue.endsWith('```')) {
      fieldValue = fieldValue.substring(0, fieldValue.length - 3);
    }
    fieldValue = fieldValue.trim();

    state.done = true;
    callbacks.onComplete(fieldValue, '');
  }

  /**
   * 流式生成消息,累积响应文本。
   * @param callbacks 主回调(可为 null,字段重新生成时无 onDelta)
   * @param errorPrefix 错误前缀
   * @returns 完整响应文本(取消时返回已累积的内容)
   */
  private async streamMessages(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    state: GenerationState,
    callbacks: AiGenerationCallbacks | null,
    errorPrefix: string
  ): Promise<string> {
    return new Promise<string>((resolve: (s: string) => void): void => {
      const streamCallbacks: ChatStreamCallbacks = {
        onStart: (): void => {
          if (callbacks !== null && callbacks.onStart !== undefined) {
            try {
              callbacks.onStart();
            } catch (e) {
              Logger.warn(LOG_TAG, 'onStart throw: ' + String(e));
            }
          }
        },
        onDelta: (delta: ChatDelta): void => {
          if (state.aborted) {
            return;
          }
          const content: string = delta.content !== undefined ? delta.content : '';
          if (content.length > 0) {
            state.accumulated += content;
            if (callbacks !== null) {
              try {
                callbacks.onDelta(state.accumulated);
              } catch (e) {
                Logger.warn(LOG_TAG, 'onDelta throw: ' + String(e));
              }
            }
          }
        },
        onComplete: (result: ChatStreamResult): void => {
          // 优先使用 result.content(已聚合),否则用累积值
          const finalContent: string = result.content !== undefined && result.content.length > 0
            ? result.content
            : state.accumulated;
          resolve(finalContent);
        },
        onError: (error: NetworkError): void => {
          Logger.error(LOG_TAG, errorPrefix + ' status=' + String(error.statusCode)
            + ' type=' + error.type + ' msg=' + error.message);
          if (callbacks !== null && callbacks.onError !== undefined) {
            try {
              callbacks.onError(error);
            } catch (e) {
              Logger.warn(LOG_TAG, 'onError throw: ' + String(e));
            }
          }
          resolve(state.accumulated);
        }
      };

      const handle: ChatStreamHandle = this.modelService.streamCurrentChat(
        messages, options, streamCallbacks
      );

      // 检查 abort 信号
      // 由于 ArkTS 没有 Promise.race 的中断支持,这里通过定期检查 state.aborted 实现
      // 但 streamChat 已经在 Provider 层处理流完成,我们只需要保存 handle 供 abort
      // 真正的 abort 由调用方通过 handle.abort() 触发
      // 此处我们保存 handle 到 state 供外部 abort
      state.streamHandle = handle;

      // 监听 abort:定期检查并主动 abort 内部 handle
      // 简化处理:如果 state.aborted 在 stream 完成前为 true,内部 handle 已被外部调用 abort
      // 这里通过 setInterval 检查
      state.abortChecker = setInterval((): void => {
        if (state.aborted && state.streamHandle !== null) {
          try {
            state.streamHandle.abort();
          } catch (e) {
            // 忽略
          }
          if (state.abortChecker !== null) {
            clearInterval(state.abortChecker);
            state.abortChecker = null;
          }
        }
      }, 200);
    }).then((s: string): string => {
      // 清理 abort checker
      if (state.abortChecker !== null) {
        clearInterval(state.abortChecker);
        state.abortChecker = null;
      }
      return s;
    });
  }

  /**
   * 校验 + 受控格式修复。
   *
   * G-AI-BUILDER-2-FIX:
   * - 初始请求已在调用方完成,本方法只负责校验和最多 1 次修复。
   * - 修复请求只包含:原始无效输出 + JSON Schema + 错误类别,不重新发送完整用户描述以外的隐私数据。
   * - 修复目的仅为修正 JSON 格式和字段结构,不让模型扩展、改写或重新设计角色。
   * - 最多发起 1 次修复请求(MAX_REPAIR_ATTEMPTS = 1),第二次仍失败立即停止。
   */
  private async validateAndAutoFix(
    rawResponse: string,
    meta: AiGenerationMeta,
    state: GenerationState,
    callbacks: AiGenerationCallbacks | null,
    originalMessages: ChatMessage[],
    options: ChatRequestOptions,
    input: AiCharacterInput
  ): Promise<AiGenerationResult> {
    // 1. 清理 Markdown + 提取 JSON
    const cleaned: string = extractJsonObject(rawResponse);
    if (cleaned.length === 0) {
      return createFailed(
        rawResponse,
        [{ field: 'root', code: 'empty', message: '响应为空,无法提取 JSON' }],
        0, false, meta, '响应为空,无法提取 JSON'
      );
    }

    // 2. 校验
    let result = validateV2CharacterCard(cleaned, meta);
    if (result.ok) {
      return createSuccess(result.card!, rawResponse, 0, meta);
    }

    // 3. 受控格式修复(最多 MAX_REPAIR_ATTEMPTS 次)
    let lastErrors: AiValidationError[] = result.errors;
    let currentRaw: string = cleaned;

    while (state.autoFixAttempts < MAX_REPAIR_ATTEMPTS && !state.aborted) {
      state.autoFixAttempts++;
      Logger.warn(LOG_TAG, 'repair attempt=' + String(state.autoFixAttempts)
        + ' errors=' + String(lastErrors.length));

      const fixMessages: ChatMessage[] = buildAutoFixMessages(currentRaw, lastErrors, input);
      const fixResponse: string = await this.streamMessages(
        fixMessages, options, state, callbacks, '格式修复失败'
      );

      if (state.aborted) {
        return createCancelledResult(rawResponse);
      }

      const fixCleaned: string = extractJsonObject(fixResponse);
      if (fixCleaned.length === 0) {
        // 修复失败:返回最后一次校验错误
        return createFailed(
          rawResponse, lastErrors, state.autoFixAttempts, false, meta,
          '格式修复失败:模型返回空响应'
        );
      }

      currentRaw = fixCleaned;
      result = validateV2CharacterCard(fixCleaned, meta);
      if (result.ok) {
        return createSuccess(result.card!, rawResponse, state.autoFixAttempts, meta);
      }
      lastErrors = result.errors;
    }

    // 4. 修复次数已达上限
    const exhausted: boolean = state.autoFixAttempts >= MAX_REPAIR_ATTEMPTS;
    const errorMessage: string = exhausted
      ? '已进行 ' + String(state.autoFixAttempts) + ' 次格式修复仍无法通过校验,请手动处理或返回修改创意'
      : '生成失败,请重试或修改创意描述';
    return createFailed(
      rawResponse, lastErrors, state.autoFixAttempts, exhausted, meta, errorMessage
    );
  }
}

// ===== 内部类型与函数 =====

interface GenerationState {
  aborted: boolean;
  done: boolean;
  accumulated: string;
  meta: AiGenerationMeta | null;
  autoFixAttempts: number;
  streamHandle: ChatStreamHandle | null;
  abortChecker: number | null;
}

function createFailed(
  rawResponse: string,
  errors: AiValidationError[],
  autoFixAttempts: number,
  autoFixExhausted: boolean,
  meta: AiGenerationMeta | null,
  errorMessage: string
): AiGenerationResult {
  return {
    status: AiGenerationStatus.Failed,
    card: null,
    rawResponse: rawResponse,
    errors: errors,
    autoFixAttempts: autoFixAttempts,
    autoFixExhausted: autoFixExhausted,
    meta: meta,
    errorMessage: errorMessage
  };
}

function createCancelledResult(rawResponse: string): AiGenerationResult {
  return {
    status: AiGenerationStatus.Cancelled,
    card: null,
    rawResponse: rawResponse,
    errors: [],
    autoFixAttempts: 0,
    autoFixExhausted: false,
    meta: null,
    errorMessage: ''
  };
}

function createSuccess(
  card: ParsedCharacterCard,
  rawResponse: string,
  autoFixAttempts: number,
  meta: AiGenerationMeta
): AiGenerationResult {
  return {
    status: AiGenerationStatus.Success,
    card: card,
    rawResponse: rawResponse,
    errors: [],
    autoFixAttempts: autoFixAttempts,
    autoFixExhausted: false,
    meta: meta,
    errorMessage: ''
  };
}

/**
 * 构造生成请求的 system + user 消息。
 */
function buildGenerationMessages(input: AiCharacterInput): ChatMessage[] {
  const systemPrompt: string = buildSystemPrompt(input);
  const userPrompt: string = buildUserPrompt(input);

  return [
    createChatMessage('ai-char-sys-' + generateUuid(), ChatRole.System, systemPrompt, Date.now()),
    createChatMessage('ai-char-usr-' + generateUuid(), ChatRole.User, userPrompt, Date.now())
  ];
}

/**
 * 构造自动修复请求的消息。
 */
function buildAutoFixMessages(
  originalJson: string,
  errors: AiValidationError[],
  input: AiCharacterInput
): ChatMessage[] {
  const systemPrompt: string = buildSystemPrompt(input);

  // 把错误格式化为简短描述
  const errorList: string[] = [];
  for (let i: number = 0; i < errors.length; i++) {
    const e: AiValidationError = errors[i];
    errorList.push('- [' + e.code + '] ' + e.field + ': ' + e.message);
  }
  const errorsText: string = errorList.join('\n');

  const userPrompt: string = '上一次生成的 JSON 校验失败,错误如下:\n\n'
    + errorsText
    + '\n\n原始 JSON(可能有错误,请基于此修正):\n'
    + originalJson
    + '\n\n请只输出修正后的完整 Tavern Card V2 JSON,不要输出其他任何文字、解释、Markdown 代码块标记。'
    + '必须包含 spec="chara_card_v2"、spec_version="2.0" 和 data 对象。';

  return [
    createChatMessage('ai-fix-sys-' + generateUuid(), ChatRole.System, systemPrompt, Date.now()),
    createChatMessage('ai-fix-usr-' + generateUuid(), ChatRole.User, userPrompt, Date.now())
  ];
}

/**
 * 构造单字段重新生成的消息。
 */
function buildFieldRegenMessages(
  fieldPath: string,
  currentCard: ParsedCharacterCard
): ChatMessage[] {
  // 提取字段路径短名(如 "data.description" → "description")
  const fieldName: string = fieldPath.startsWith('data.')
    ? fieldPath.substring(5)
    : fieldPath;

  const systemPrompt: string = '你是角色卡字段生成助手。'
    + '用户会给你一个角色卡上下文和一个目标字段名,你需要**只重新生成**该字段的内容,不要修改其他字段。'
    + '\n\n要求:'
    + '\n- 保持与现有角色设定统一'
    + '\n- 字段内容应该清晰、自然、符合角色身份'
    + '\n- 不要输出 JSON 包装、Markdown 代码块、解释、标题或其他文字'
    + '\n- 直接输出字段值即可'
    + '\n- 如果字段是数组(如 alternate_greetings / tags),输出 JSON 数组格式';

  // 构造角色上下文(只保留必要字段)
  const context: Record<string, Object> = {};
  context['name'] = currentCard.name;
  context['description'] = currentCard.description;
  context['personality'] = currentCard.personality;
  context['scenario'] = currentCard.scenario;
  context['first_mes'] = currentCard.firstMessage;
  if (currentCard.alternateGreetings.length > 0) {
    context['alternate_greetings'] = currentCard.alternateGreetings.slice();
  }

  const userPrompt: string = '角色卡上下文:\n'
    + JSON.stringify(context, null, 2)
    + '\n\n请重新生成字段: ' + fieldName
    + '\n只输出该字段的内容,不要修改其他字段,不要输出其他文字。';

  return [
    createChatMessage('ai-field-sys-' + generateUuid(), ChatRole.System, systemPrompt, Date.now()),
    createChatMessage('ai-field-usr-' + generateUuid(), ChatRole.User, userPrompt, Date.now())
  ];
}

/**
 * 构造角色卡优化请求的消息(ARK-UI-LAYOUT-OPT-02)。
 *
 * 语义:保持现有角色卡内容,让 AI 重写为规范、完整的 Tavern Card V2 JSON 结构。
 * 不改变角色设定,不重新创作,只整理字段归属与补全缺失字段。
 */
function buildOptimizeMessages(card: ParsedCharacterCard): ChatMessage[] {
  const systemPrompt: string = '你是 Tavern Card V2 角色卡整理助手。'
    + '用户会给你一个现有角色卡的内容,你需要**保持角色设定不变**,将其整理为规范、完整的 Tavern Card V2 JSON。'
    + '\n\n核心原则:'
    + '\n- **不重新创作**:保留角色名称、描述、性格、场景、开场白等原有内容与设定,不添加原创设定'
    + '\n- **不删减有效信息**:将原有内容按字段语义归类到正确字段,不丢失已有设定'
    + '\n- **结构匹配**:根据内容判断它属于 description / personality / scenario / first_mes / system_prompt 等哪个字段'
    + '\n- **补全结构**:缺失字段填空字符串或空数组,但不得虚构内容填充必填字段(name 除外,保留原值)'
    + '\n- **语言风格统一**:仅做轻度润色与标点/换行整理,保持原有语言'
    + '\n- 不要修改头像、不要修改角色书已有条目内容'
    + '\n\n输出要求:'
    + '\n- **只输出**标准 Tavern Card V2 JSON,不要输出 Markdown 代码块标记、解释、标题或其他任何文字'
    + '\n- JSON 必须可被 JSON.parse 直接解析'
    + '\n- 必须包含 spec="chara_card_v2"、spec_version="2.0" 和 data 对象'
    + '\n\nJSON 结构要求(所有字段必填,数组字段即使为空也必须是空数组,extensions 即使为空也必须是空对象):'
    + '\n{'
    + '\n  "spec": "chara_card_v2",'
    + '\n  "spec_version": "2.0",'
    + '\n  "data": {'
    + '\n    "name": "角色名称(保持原值)",'
    + '\n    "description": "角色身份、经历、外貌和行为习惯的描述",'
    + '\n    "personality": "性格描述",'
    + '\n    "scenario": "场景设定",'
    + '\n    "first_mes": "开场白",'
    + '\n    "mes_example": "对话示例(空则空字符串)",'
    + '\n    "creator_notes": "创作者备注(空则空字符串)",'
    + '\n    "system_prompt": "System Prompt(空则空字符串)",'
    + '\n    "post_history_instructions": "Post-History Instructions(空则空字符串)",'
    + '\n    "alternate_greetings": [],'
    + '\n    "character_book": {"name": "", "description": "", "scan_depth": 100, "token_budget": 500, "recursive_scanning": false, "extensions": {}, "entries": []},'
    + '\n    "tags": [],'
    + '\n    "creator": "创作者名(空则空字符串)",'
    + '\n    "character_version": "角色卡版本(空则空字符串)",'
    + '\n    "extensions": {}'
    + '\n  }'
    + '\n}';

  // 构造现有卡片内容(序列化为紧凑 JSON,便于模型读取)
  const cardContent: Record<string, Object> = {};
  cardContent['name'] = card.name;
  cardContent['description'] = card.description;
  cardContent['personality'] = card.personality;
  cardContent['scenario'] = card.scenario;
  cardContent['first_mes'] = card.firstMessage;
  cardContent['system_prompt'] = card.systemPrompt;
  cardContent['mes_example'] = card.mesExample;
  cardContent['creator_notes'] = card.creatorNotes;
  cardContent['post_history_instructions'] = card.postHistoryInstructions;
  if (card.alternateGreetings.length > 0) {
    cardContent['alternate_greetings'] = card.alternateGreetings.slice();
  }
  if (card.tags.length > 0) {
    cardContent['tags'] = card.tags.slice();
  }
  if (card.creator.length > 0) {
    cardContent['creator'] = card.creator;
  }

  const userPrompt: string = '以下是需要整理的现有角色卡内容:\n\n'
    + JSON.stringify(cardContent, null, 2)
    + '\n\n请保持以上角色设定与内容不变,将其整理为规范、完整的 Tavern Card V2 JSON。'
    + '只输出 JSON,不要输出任何其他文字或 Markdown 代码块。';

  return [
    createChatMessage('ai-opt-sys-' + generateUuid(), ChatRole.System, systemPrompt, Date.now()),
    createChatMessage('ai-opt-usr-' + generateUuid(), ChatRole.User, userPrompt, Date.now())
  ];
}

/**
 * 构造系统 prompt。
 */
function buildSystemPrompt(input: AiCharacterInput): string {
  return '你是 Tavern Card V2 角色卡生成助手。'
    + '用户会给你一个角色创意,你需要生成符合 Tavern Card V2 规范的完整角色卡 JSON。'
    + '\n\n输出要求:'
    + '\n- **只输出**标准 Tavern Card V2 JSON,不要输出 Markdown 代码块标记、解释、标题或其他任何文字'
    + '\n- 不要输出模型推理过程'
    + '\n- JSON 必须可被 JSON.parse 直接解析'
    + '\n- 内容语言:跟随创意描述所用语言'
    + '\n- 详细程度:标准(每个字段 4-8 句话)'
    + '\n\nJSON 结构要求(所有字段必填,数组字段即使为空也必须是空数组,extensions 即使为空也必须是空对象):'
    + '\n{'
    + '\n  "spec": "chara_card_v2",'
    + '\n  "spec_version": "2.0",'
    + '\n  "data": {'
    + '\n    "name": "角色名称(必须是一个自然、具体、贴切的名字,如人物本名或昵称)",'
    + '\n    "description": "角色身份、经历、外貌和行为习惯的描述",'
    + '\n    "personality": "性格描述(不能只是关键词堆积,应清晰说明角色说话方式和性格特点)",'
    + '\n    "scenario": "场景设定,说明角色与用户如何相遇(不替用户决定行为)",'
    + '\n    "first_mes": "开场白(为用户保留互动空间,不要替用户说话或预设用户心理)",'
    + '\n    "mes_example": "对话示例(体现角色语气和行为方式)",'
    + '\n    "creator_notes": "创作者备注",'
    + '\n    "system_prompt": "System Prompt(帮助模型稳定扮演角色)",'
    + '\n    "post_history_instructions": "Post-History Instructions(简洁)",'
    + '\n    "alternate_greetings": ["备用开场白(多个开场白之间应有明显差异)"],'
    + '\n    "character_book": {"name": "角色世界书名", "description": "世界书描述", "scan_depth": 100, '
    + '"token_budget": 500, "recursive_scanning": false, "extensions": {}, "entries": ['
    + '\n      {"name": "条目名称(简述该条目主题)", "keys": ["关键词"], "secondary_keys": [], "content": "条目内容", '
    + '"enabled": true, "insertion_order": 100, "case_sensitive": false, '
    + '"constant": false, "selective": true, "position": "before_char", "extensions": {}}'
    + '\n    ]},'
    + '\n    "tags": ["简短标签"],'
    + '\n    "creator": "AI Generated",'
    + '\n    "character_version": "1.0",'
    + '\n    "extensions": {}'
    + '\n  }'
    + '\n}'
    + '\n\n角色卡内容要求:'
    + '\n- name 必须是一个自然、贴切、有辨识度的角色名字(如人物本名、昵称或代号),禁止使用占位符(如 Entry、Character、未命名、数字编号等)'
    + '\n- 保持角色设定统一,不矛盾'
    + '\n- 清晰描述角色身份、经历、外貌和行为习惯'
    + '\n- 性格不能只是关键词堆积,应说明角色说话方式和性格特点'
    + '\n- 场景应说明角色与用户如何相遇,不替用户决定行为或说话'
    + '\n- 不预设用户的心理活动'
    + '\n- 开场白应为用户保留互动空间'
    + '\n- 多个开场白之间应有明显差异'
    + '\n- 对话示例应体现角色语气和行为方式'
    + '\n- System Prompt 应帮助模型稳定扮演角色'
    + '\n- Post-History Instructions 应简洁'
    + '\n- 标签保持简短'
    + '\n- 世界书只包含与角色和设定直接相关的信息,不要伪造无关条目'
    + '\n- 每个世界书条目都应有一个简洁的名称(name),概括该条目主题,不要留空或用 Entry、数字编号等占位符'
    + '\n- 如果用户未开启生成世界书,character_book 应为 {"name": "", "description": "", "scan_depth": 100, "token_budget": 500, "recursive_scanning": false, "extensions": {}, "entries": []}'
    + '\n- 如果用户未开启生成多个开场白,alternate_greetings 应为空数组 []'
    + '\n- 如果用户未开启生成对话示例,mes_example 应为空字符串 ""';
}

/**
 * 构造用户 prompt(基于创意输入)。
 */
function buildUserPrompt(input: AiCharacterInput): string {
  const parts: string[] = [];
  parts.push('请根据以下创意生成 Tavern Card V2 角色卡。');

  // 创意描述(必填)
  parts.push('\n【角色创意描述】');
  parts.push(input.conceptDescription.trim());

  // 名称(可选)
  if (input.name.trim().length > 0) {
    parts.push('\n【角色名称】');
    parts.push(input.name.trim());
  } else {
    parts.push('\n【角色名称】');
    parts.push('请根据创意自动生成一个自然、贴切、有辨识度的角色名字(如人物本名、昵称或代号),禁止使用 Entry、Character、未命名、数字编号等占位符');
  }

  // 世界观(可选)
  if (input.backstory.trim().length > 0) {
    parts.push('\n【世界观/故事背景】');
    parts.push(input.backstory.trim());
  }

  // 性格关键词(可选)
  if (input.personalityKeywords.trim().length > 0) {
    parts.push('\n【性格关键词】');
    parts.push(input.personalityKeywords.trim());
  }

  // 关系(可选)
  if (input.relationshipWithUser.trim().length > 0) {
    parts.push('\n【角色与用户的关系】');
    parts.push(input.relationshipWithUser.trim());
  }

  // 对话风格(可选)
  if (input.speechStyle.trim().length > 0) {
    parts.push('\n【对话风格】');
    parts.push(input.speechStyle.trim());
  }

  // 生成选项
  parts.push('\n【生成选项】');
  parts.push('- 生成角色专属世界书: ' + (input.generateCharacterBook ? '是' : '否'));
  parts.push('- 生成多个开场白: ' + (input.generateMultipleGreetings ? '是' : '否'));
  parts.push('- 生成对话示例: ' + (input.generateMesExample ? '是' : '否'));

  parts.push('\n请只输出标准 Tavern Card V2 JSON,不要输出任何其他文字或 Markdown 代码块。');

  return parts.join('\n');
}
