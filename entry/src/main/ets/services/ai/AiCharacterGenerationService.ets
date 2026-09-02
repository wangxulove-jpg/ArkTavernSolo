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
  AiCharacterType
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
import { ParsedCharacterCard, ParsedCharacterBook } from '../../parser/CharacterCardJsonParser';
import { getModelCapability } from '../../models/ModelCapabilities';
import { estimateMessagesTokens } from '../TokenCounter';

const LOG_TAG: string = 'AiCharGen';

/** 生成温度(较低,提高 JSON 结构稳定性) */
const GENERATION_TEMPERATURE: number = 0.7;
/** 生成 top_p */
const GENERATION_TOP_P: number = 0.95;
/**
 * AI 角色卡生成的目标输出 token 上限(高于旧固定值 8192,以适应大型角色卡)。
 * 实际生效值会再取 min(该目标, 模型能力上限, contextWindow - 输入 - 安全边际)。
 */
const GENERATION_TARGET_MAX_TOKENS: number = 32768;
/** 输出上限的保底值(防止因上下文/能力导致预算过低) */
const GENERATION_MIN_OUTPUT_TOKENS: number = 2048;
/** 输出预留安全边际(占上下文窗口,避免输出挤占输入导致越界) */
const GENERATION_OUTPUT_SAFETY_MARGIN: number = 1024;
/** 能力表中未知模型时的输出上限兜底(比旧 8192 略有提升) */
const DEFAULT_MAX_OUTPUT_TOKENS: number = 16384;
/** 能力表中未知模型时的上下文窗口兜底 */
const DEFAULT_CONTEXT_WINDOW: number = 32768;
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
   * 计算本次生成/优化/字段重生成的输出 token 上限。
   *
   * 规则:取 min(目标上限 32768, 模型能力表中的输出上限, contextWindow - 输入 token - 安全边际),
   * 且不低于保底值,从而既适应大型角色卡,又不越界。
   *
   * @param config 当前 ProviderConfig
   * @param messages 本次请求的消息(用于估算输入 token)
   * @returns 输出 token 上限(正整数)
   */
  private computeOutputMaxTokens(config: ProviderConfig, messages: ChatMessage[]): number {
    const capability = getModelCapability(config.modelName);
    const modelMaxOut: number = capability !== null
      ? capability.maxOutputTokensLimit
      : DEFAULT_MAX_OUTPUT_TOKENS;
    const contextWindow: number = config.contextWindow !== undefined && config.contextWindow > 0
      ? config.contextWindow
      : (capability !== null ? capability.contextWindow : DEFAULT_CONTEXT_WINDOW);
    const inputTokens: number = estimateMessagesTokens(messages);

    const targetBudget: number = Math.min(GENERATION_TARGET_MAX_TOKENS, modelMaxOut);
    const remaining: number = contextWindow - inputTokens - GENERATION_OUTPUT_SAFETY_MARGIN;
    const budget: number = Math.min(targetBudget, remaining);
    return Math.max(GENERATION_MIN_OUTPUT_TOKENS, budget);
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
      truncated: false,
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
      truncated: false,
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
   * 基于已有角色卡+用户修改建议重新生成一张新的完整 V3 角色卡。
   *
   * 语义:
   * - 把原卡内容作为**背景信息**提供给模型
   * - 只按用户给出的修改建议调整对应内容;未提及的字段保持原样
   * - 输出一张新的完整 Tavern Card V3 JSON(与生成/优化路径同级别的校验+自动修复)
   *
   * @param card 原始角色卡(来自导入解析)
   * @param suggestions 用户的自由修改建议
   * @param useCurrentModel true=跟随当前 ProviderConfig;false=使用指定 configId
   * @param configId 指定 ProviderConfig ID
   * @param includeWorldbook true=把原卡世界书发给 AI 并按建议修改;false=不在输入中包含世界书(默认,避免丢失/走样)
   * @param callbacks 流式回调
   * @returns 生成句柄(用于取消)
   */
  reviseCharacterCard(
    card: ParsedCharacterCard,
    suggestions: string,
    useCurrentModel: boolean,
    configId: string,
    includeWorldbook: boolean,
    callbacks: AiGenerationCallbacks
  ): AiGenerationHandle {
    const state: GenerationState = {
      aborted: false,
      done: false,
      accumulated: '',
      truncated: false,
      meta: null,
      autoFixAttempts: 0,
      streamHandle: null,
      abortChecker: null
    };

    this.executeRevise(card, suggestions, useCurrentModel, configId, includeWorldbook, state, callbacks).then(
      (): void => { /* 正常完成 */ },
      (err: Object): void => {
        if (state.done) {
          return;
        }
        state.done = true;
        Logger.error(LOG_TAG, 'revise unexpected error: ' + String(err));
        const result: AiGenerationResult = createFailed(
          state.accumulated,
          [],
          state.autoFixAttempts,
          false,
          state.meta,
          '重新生成失败: ' + String(err)
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
   * 执行“基于原卡+修改建议重新生成”(内部实现)。
   */
  private async executeRevise(
    card: ParsedCharacterCard,
    suggestions: string,
    useCurrentModel: boolean,
    configId: string,
    includeWorldbook: boolean,
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

    const messages: ChatMessage[] = buildReviseMessages(card, suggestions, includeWorldbook);
    const options: ChatRequestOptions = {
      temperature: GENERATION_TEMPERATURE,
      topP: GENERATION_TOP_P,
      maxTokens: this.computeOutputMaxTokens(config, messages),
      stream: true
    };

    const rawResponse: string = await this.streamMessages(
      messages, options, state, callbacks, '重新生成失败'
    );
    if (state.aborted) {
      state.done = true;
      callbacks.onComplete(createCancelledResult(rawResponse));
      return;
    }
    if (rawResponse.length === 0) {
      state.done = true;
      callbacks.onComplete(createFailed(
        '', [], 0, false, meta, '重新生成失败:模型返回空响应'
      ));
      return;
    }
    if (state.truncated) {
      state.done = true;
      callbacks.onComplete(createFailed(
        '', [], 0, false, meta,
        '重新生成失败:角色卡内容过大,超出模型单次输出上限,建议精简内容或分段生成'
      ));
      return;
    }

    const finalResult: AiGenerationResult = await this.validateAndAutoFix(
      rawResponse, meta, state, callbacks, messages, options,
      buildReviseSystemPrompt(),
      JSON.stringify(buildOptimizeCardContent(card), null, 2)
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
      maxTokens: this.computeOutputMaxTokens(config, messages),
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
    if (state.truncated) {
      state.done = true;
      const result: AiGenerationResult = createFailed(
        '', [], 0, false, meta,
        '生成失败:角色卡内容过大,超出模型单次输出上限,建议精简内容或分段生成'
      );
      callbacks.onComplete(result);
      return;
    }

    // 4. 校验 + 自动修复
    const finalResult: AiGenerationResult = await this.validateAndAutoFix(
      rawResponse, meta, state, callbacks, messages, options, buildSystemPrompt(input), ''
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
      maxTokens: this.computeOutputMaxTokens(config, messages),
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
          const reasoning: string = delta.reasoningContent !== undefined ? delta.reasoningContent : '';
          if (content.length > 0) {
            state.accumulated += content;
            if (callbacks !== null) {
              try {
                callbacks.onDelta(state.accumulated);
              } catch (e) {
                Logger.warn(LOG_TAG, 'onDelta throw: ' + String(e));
              }
            }
          } else if (reasoning.length > 0) {
            state.accumulated += reasoning;
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
          // 检测是否因超长被截断(finish_reason === "length"),供上层给出"卡片过大"提示
          state.truncated = result.finishReason !== undefined && result.finishReason === 'length';
          // 优先使用 result.content(已聚合),否则用累积值
          // 如果 content 和累积值都为空,尝试使用 reasoningContent(思考模型回退)
          let finalContent: string = result.content !== undefined && result.content.length > 0
            ? result.content
            : state.accumulated;
          if (finalContent.length === 0 && result.reasoningContent !== undefined
            && result.reasoningContent.length > 0) {
            finalContent = result.reasoningContent;
          }
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
    autoFixSystemPrompt: string,
    autoFixContext: string
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

      const fixMessages: ChatMessage[] = buildAutoFixMessages(currentRaw, lastErrors, autoFixSystemPrompt, autoFixContext);
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
  /** 上次流式响应是否因超长被截断(finish_reason === "length") */
  truncated: boolean;
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
 *
 * @param originalJson 上一次输出的 JSON(可能有错误)
 * @param errors 校验错误列表
 * @param systemPrompt 与首次请求一致的 system prompt(生成用 buildSystemPrompt,优化用优化提示词)
 * @param contextText 附加上下文(优化时传入原始角色卡内容,以保持设定不变;生成为空串)
 */
function buildAutoFixMessages(
  originalJson: string,
  errors: AiValidationError[],
  systemPrompt: string,
  contextText: string
): ChatMessage[] {
  // 把错误格式化为简短描述
  const errorList: string[] = [];
  for (let i: number = 0; i < errors.length; i++) {
    const e: AiValidationError = errors[i];
    errorList.push('- [' + e.code + '] ' + e.field + ': ' + e.message);
  }
  const errorsText: string = errorList.join('\n');

  const contextBlock: string = contextText.length > 0
    ? '\n\n【原始角色卡内容(以此为准,保持角色设定不变)】:\n' + contextText
    : '';

  const userPrompt: string = '上一次生成的 JSON 校验失败,错误如下:\n\n'
    + errorsText
    + '\n\n原始 JSON(可能有错误,请基于此修正):\n'
    + originalJson
    + contextBlock
    + '\n\n请只修正 JSON 的格式与字段结构,保持角色设定不变,不要改写角色内容或重新设计角色。'
    + '只输出修正后的完整 Tavern Card V3 JSON,不要输出其他任何文字、解释、Markdown 代码块标记。'
    + '必须包含 spec="chara_card_v3"、spec_version="3.0" 和 data 对象。';

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
  if (currentCard.nickname.length > 0) {
    context['nickname'] = currentCard.nickname;
  }
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
 * 构造“基于原卡+修改建议重新生成”的请求消息。
 *
 * 语义:原卡内容作为背景信息;只按用户建议修改对应内容,未提及字段保持原样;
 * 输出一张新的完整 Tavern Card V3 JSON。
 */
function buildReviseMessages(
  card: ParsedCharacterCard,
  suggestions: string,
  includeWorldbook: boolean
): ChatMessage[] {
  const systemPrompt: string = buildReviseSystemPrompt();
  const cardContent: Record<string, Object> = buildOptimizeCardContent(card);
  // 仅当用户显式要求修改世界书时,才把原卡世界书并入输入,让 AI 有据可依地修改
  if (includeWorldbook && card.characterBook !== null) {
    cardContent['character_book'] = serializeCharacterBookObject(card.characterBook);
  }
  const serializedContent: string = JSON.stringify(cardContent, null, 2);
  const trimmedSuggestions: string = suggestions.trim();

  let userPrompt: string = '以下是原始角色卡内容(作为背景信息):\n\n'
    + serializedContent
    + '\n\n【用户的修改建议】:\n'
    + (trimmedSuggestions.length > 0 ? trimmedSuggestions : '(无)')
    + '\n\n请以原卡为蓝本,依据以上修改建议重新生成一张新的完整 Tavern Card V3 角色卡。要求:'
    + '\n- 以修改建议为准进行调整;建议要求补全/丰富/替换时,可充实空缺或薄弱的字段、替换不合适或占位性的开场白'
    + '\n- 未提及的合理内容尽量保留,不做与建议无关的多余删改'
    + '\n- 不得改名/换角(除非建议明确要求改角色名)'
    + '\n- 保持角色核心身份与世界观基调一致,不引入与建议无关的冲突设定';
  if (includeWorldbook) {
    userPrompt += '\n- 若修改建议涉及角色世界书(character_book),请按要求修改对应条目;未在建议中明确提及的条目必须原样保留,不得丢失、删减或篡改其内容/关键词';
  }
  userPrompt += '\n- 只输出完整 JSON,不要输出任何其他文字或 Markdown 代码块。';

  return [
    createChatMessage('ai-rev-sys-' + generateUuid(), ChatRole.System, systemPrompt, Date.now()),
    createChatMessage('ai-rev-usr-' + generateUuid(), ChatRole.User, userPrompt, Date.now())
  ];
}

/** 供 "让 AI 修改世界书" 嵌入提示用的序列化世界书条目。 */
interface SerializableBookEntry {
  readonly id: number;
  readonly keys: string[];
  readonly secondary_keys: string[];
  readonly comment: string;
  readonly content: string;
  readonly constant: boolean;
  readonly selective: boolean;
  readonly insertion_order: number;
  readonly enabled: boolean;
  readonly position: string;
  readonly case_sensitive: boolean;
  readonly useRegex: boolean;
  readonly priority: number;
  readonly name: string;
  readonly extensions: Record<string, Object>;
}

/** 供 "让 AI 修改世界书" 嵌入提示用的序列化世界书。 */
interface SerializableBook {
  readonly name: string;
  readonly description: string;
  readonly scan_depth: number;
  readonly token_budget: number;
  readonly recursive_scanning: boolean;
  readonly extensions: Record<string, Object>;
  readonly entries: SerializableBookEntry[];
}

/**
 * 把 ParsedCharacterBook 序列化为标准 SillyTavern character_book JSON 对象,
 * 供 "让 AI 修改世界书" 时嵌入到发给模型的角色卡内容中(与 Lorebook 导出一致)。
 */
function serializeCharacterBookObject(book: ParsedCharacterBook): SerializableBook {
  const entriesObj: SerializableBookEntry[] = [];
  for (let i = 0; i < book.entries.length; i++) {
    const e = book.entries[i];
    const entry: SerializableBookEntry = {
      id: e.id,
      keys: e.keys.slice(),
      secondary_keys: e.secondaryKeys.slice(),
      comment: e.comment,
      content: e.content,
      constant: e.constant,
      selective: e.selective,
      insertion_order: e.insertionOrder,
      enabled: e.enabled,
      position: e.position,
      case_sensitive: e.caseSensitive,
      useRegex: e.useRegex,
      priority: e.priority,
      name: e.name,
      extensions: e.extensions
    };
    entriesObj.push(entry);
  }
  const result: SerializableBook = {
    name: book.name,
    description: book.description,
    scan_depth: book.scanDepth,
    token_budget: book.tokenBudget,
    recursive_scanning: book.recursiveScanning,
    extensions: book.extensions,
    entries: entriesObj
  };
  return result;
}

/**
 * “基于原卡+修改建议重新生成”的 system prompt(供首次请求与自动修复复用)。
 */
function buildReviseSystemPrompt(): string {
  return '你是 Tavern Card V3 角色卡修改助手。'
    + '用户会给你一张已有的角色卡作为背景信息,并提出修改建议。'
    + '你需要以原卡为蓝本,依据修改建议调整对应内容;'
    + '建议要求补全缺失字段、生成合适开场白或清理脚本类文本时,可相应充实或调整,'
    + '未提及的合理内容尽量保留,然后输出一张新的完整 Tavern Card V3 角色卡。'
    + '\n\n最高优先级(必须遵守):'
    + '\n- 以修改建议为准,不擅自做与建议无关的多余改动'
    + '\n- 除非建议明确要求改名,否则 name / nickname 保持原值'
    + '\n- 保持角色核心身份与世界观基调一致,不得更换角色身份或引入与建议无关的冲突设定'
    + '\n\n输出要求:'
    + '\n- **只输出**标准 Tavern Card V3 JSON,不要输出 Markdown 代码块标记、解释、标题或其他任何文字'
    + '\n- JSON 必须可被 JSON.parse 直接解析'
    + '\n- 必须包含 spec="chara_card_v3"、spec_version="3.0" 和 data 对象'
    + buildOptimizeJsonStructure()
    + buildRenderCapabilityNote();
}

/**
 * 本 App 聊天渲染能力说明。
 *
 * 让修改/生成角色卡时,AI 知道 App 能把 first_mes / 世界书内容安全渲染成
 * Markdown、可折叠块、分支选项、轻量 HTML 与隐藏指令块,从而按需使用这些能力。
 * 这些能力对 AI 是可选引导,不是强制;AI 应按建议判断是否使用。
 */
function buildRenderCapabilityNote(): string {
  return '\n\n【本 App 的聊天渲染能力,可在 first_mes(开场白)与正文中安全使用】'
    + '\n- Markdown:`**加粗**`、`### 小标题`、`1. 列表`、`| 栏位 | 值 |` 表格等都会正常排版'
    + '\n- 折叠块:`<details><summary>标题</summary>正文</details>`(平时收起,点击展开;适合放角色状态/属性/物品/面板等,避免刷屏)'
    + '\n- 分支选项:`<branches>\n[选项1]\n[选项2]\n[选项3]\n</branches>` 每行一个 `[...]` 选项,渲染为可点击选项,用户点击后作为其发言发送'
    + '\n- 隐藏指令块:`<思考>...</思考>`、`<变量思考>...</变量思考>`、`<upstore>...</upstore>` 仅用于引导,不会显示给用户'
    + '\n- 轻量 HTML:`<div>/<p>/<span style="color:...">/<strong>/<br>/<hr>` 会渲染为可读排版(标签剥离、换行与分隔线保留,背景/边框样式不显示),可用于判定框/面板结构'
    + '\n- 骰子宏:`{{roll 1d20}}`、`{{roll::2d6+3}}` 会解析为随机掷骰结果'
    + '\n\n延续性要求(重要):若角色卡的首条消息(first_mes)使用了折叠状态栏/分支选项等展示形式,'
    + '请把这些展示形式作为该角色**持续遵循的界面规范**:建议在 system_prompt 或 post_history_instructions 中明确要求'
    + '角色在后续**每次回复都持续输出并更新**同样格式的折叠状态栏 / 分支选项,位置与结构保持一致,'
    + '不能只在开场白出现一次就丢失。'
    + '\n注意:是否使用上述能力以用户的修改建议为准;若建议涉及"状态栏/选项/面板",用上面语法;普通叙事保持自然文字即可。';
}

/**
 * Tavern Card V3 角色卡的 JSON 结构要求(生成/修改/优化共用)。
 */
function buildOptimizeJsonStructure(): string {
  return '\n\nJSON 结构要求(所有字段必填,数组字段即使为空也必须是空数组,extensions 即使为空也必须是空对象):'
    + '\n{'
    + '\n  "spec": "chara_card_v3",'
    + '\n  "spec_version": "3.0",'
    + '\n  "data": {'
    + '\n    "name": "角色名称(保持原值)",'
    + '\n    "nickname": "角色昵称/别名(没有则留空)",'
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
}

/**
 * 将现有角色卡序列化为紧凑对象,供优化请求读取。
 */
function buildOptimizeCardContent(card: ParsedCharacterCard): Record<string, Object> {
  const cardContent: Record<string, Object> = {};
  cardContent['name'] = card.name;
  cardContent['nickname'] = card.nickname;
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
  return cardContent;
}

/**
 * 构造系统 prompt。
 */
function buildSystemPrompt(input: AiCharacterInput): string {
  const typeGuidance: string = buildTypeGuidance(input.characterType);

  return '你是 Tavern Card V3 角色卡生成助手。'
    + '用户会给你一个角色创意,你需要生成符合 Tavern Card V3 规范的完整角色卡 JSON。'
    + '\n\n输出要求:'
    + '\n- **只输出**标准 Tavern Card V3 JSON,不要输出 Markdown 代码块标记、解释、标题或其他任何文字'
    + '\n- 不要输出模型推理过程'
    + '\n- JSON 必须可被 JSON.parse 直接解析'
    + '\n- 内容语言:跟随创意描述所用语言'
    + '\n- 详细程度:标准(每个字段 4-8 句话)'
    + typeGuidance
    + '\n\nJSON 结构要求(所有字段必填,数组字段即使为空也必须是空数组,extensions 即使为空也必须是空对象):'
    + '\n{'
    + '\n  "spec": "chara_card_v3",'
    + '\n  "spec_version": "3.0",'
    + '\n  "data": {'
    + '\n    "name": "角色名称(必须是一个自然、具体、贴切的名字,如人物本名或昵称)",'
    + '\n    "nickname": "角色昵称/别名(非空时优先用于{{char}}替换;若角色名已是常用称呼则留空)",'
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
    + '\n- nickname 是角色的别名/昵称(如角色有常用简称、花名、代号等可填入;若角色名本身已是常用称呼则留空字符串)'
    + '\n- 保持角色设定统一,不矛盾'
    + '\n- 清晰描述角色身份、经历、外貌和行为习惯'
    + '\n- 性格不能只是关键词堆积,应说明角色说话方式和性格特点'
    + '\n- 场景应说明角色与用户如何相遇,不替用户决定行为或说话'
    + '\n- 不预设用户的心理活动'
    + '\n- 开场白应为用户保留互动空间'
    + '\n- 多个开场白之间应有明显差异'
    + '\n- alternate_greetings 数组中,每个元素是一个完整开场白(可包含多个自然段),不要按段落拆成多个元素,数量控制在合理范围(建议 3-10 个)'
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
 * 根据角色卡类型生成额外指导文本。
 */
function buildTypeGuidance(characterType: AiCharacterType): string {
  if (characterType === 'narrator') {
    return '\n\n角色卡类型:叙述者(Narrator)'
      + '\n这是一张叙述者角色卡,不是具体的角色人物。关键要求:'
      + '\n- name 应为叙述者身份名称(如 "Narrator"、"旁白"、"讲故事的人" 等),不是角色名'
      + '\n- system_prompt 必须明确指定:以第三人称视角叙述,描写场景、角色行动和世界,永远不要代替 {{user}} 说话或行动'
      + '\n- description 应描述叙述者的叙事风格(如全知视角、有限视角、文学风格等),而非角色外貌'
      + '\n- personality 应描述叙事偏好(如倾向于悬疑、温馨、黑暗等氛围),而非角色性格'
      + '\n- scenario 描述故事的世界观和初始情境,不预设 {{user}} 的身份'
      + '\n- first_mes 应以叙述者视角展开场景描写,为 {{user}} 留出自由互动的空间'
      + '\n- 开场白不要包含"你"或 {{user}} 的行为描述,只描述环境和 NPC';
  }
  if (characterType === 'multiScene') {
    return '\n\n角色卡类型:多人场景(Multi-Character Scene)'
      + '\n这是一张多人场景角色卡,包含多个角色。关键要求:'
      + '\n- name 应为场景名称(如 "末日酒馆"、"星际学院" 等),不是单个角色名'
      + '\n- system_prompt 必须明确指定:以第三人称视角叙述,描写每个角色的行动和对话,保持各角色性格和说话方式差异,永远不要代替 {{user}} 说话或行动'
      + '\n- description 应描述场景中各角色的身份、外貌和行为习惯,每个角色需要独立段落'
      + '\n- personality 应描述场景的整体氛围和各角色之间的互动关系'
      + '\n- scenario 描述场景设定和 {{user}} 进入场景的方式'
      + '\n- first_mes 应展示场景全貌和各角色的初始状态,多个角色应有各自的对话和行为'
      + '\n- character_book 中应为每个角色创建独立条目,便于按关键词触发对应角色信息'
      + '\n- tags 应包含 "multi-character" 标签';
  }
  return '';
}

/**
 * 构造用户 prompt(基于创意输入)。
 */
function buildUserPrompt(input: AiCharacterInput): string {
  const parts: string[] = [];
  parts.push('\n请根据以下创意生成 Tavern Card V3 角色卡。');

  if (input.characterType === 'narrator') {
    parts.push('\n【角色卡类型】叙述者 — 这不是具体角色,而是一个第三人称叙述者角色卡');
  } else if (input.characterType === 'multiScene') {
    parts.push('\n【角色卡类型】多人场景 — 这不是单个角色,而是一个包含多个角色的场景卡');
  }

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

  parts.push('\n请只输出标准 Tavern Card V3 JSON,不要输出任何其他文字或 Markdown 代码块。');

  return parts.join('\n');
}
