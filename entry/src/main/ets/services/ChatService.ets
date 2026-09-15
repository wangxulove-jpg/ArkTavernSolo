/**
 * ChatService 聊天服务
 * (T-6.3 Mainline Stability Regression & Recovery Hardening)
 *
 * 管理一次临时对话的消息列表与流式生成生命周期。
 * 页面只通过 ChatViewModel 访问,不直接调用此服务。
 *
 * 设计原则:
 * - 只通过 ModelService 发送请求,不直接操作 Provider/KeyStore/ConfigStore
 * - 不缓存 API Key
 * - 不记录用户消息或模型回复全文到日志
 * - 同一时间只允许一个生成请求
 * - 不依赖 ArkUI 页面实例
 * - 不使用全局单例、不使用 any
 * - 生命周期跟随 ChatPage,dispose 后不可复用
 *
 * 状态机:Idle → Sending → Streaming → Completed/Cancelled/Failed
 * - Completed/Cancelled/Failed 为终态,不可再转换
 * - 迟到回调(delta/complete/error)在终态后忽略
 *
 * 生成类型(T-6.3):
 * - NormalResponse: 首次 Assistant 回复,走 ChatPersistenceService
 * - SwipeCandidate: 候选回复,走 MessageSwipePersistenceService
 * - 所有异步路径基于统一 ActiveGenerationContext 判断迟到回调
 * - 清理上下文前必须完成最终状态持久化
 *
 * 不可变更新:
 * - 每次更新创建新的 ChatMessage 对象和新的 messages 数组
 * - 不原地修改数组元素
 * - 回调始终传递新数组副本
 */

import { ModelService } from './ModelService';
import { LorebookService } from './LorebookService';
import { PromptBuilder, PromptBuildContext, PromptBuildResult, MemoryLayersInjection, MemoryKeywordHit } from './PromptBuilder';
import { TokenCounter } from './TokenCounter';
import { HistoryTrimmer } from './HistoryTrimmer';
import { RecentMessageSelector } from './RecentMessageSelector';
import { AppendUserAndAssistantResult, ChatPersistenceService } from './ChatPersistenceService';
import { ChatBackgroundService } from './ChatBackgroundService';
import { PromptPresetService } from './PromptPresetService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { ConversationBranchPersistenceService, EditedBranchGenerationTarget } from './ConversationBranchPersistenceService';
import { MemoryService, MemorySummaryResult } from './MemoryService';
import { ContextBudgetService } from './ContextBudgetService';
import { AppPreferences } from '../storage/AppPreferences';
import {
  ConversationBranch,
  ConversationBranchSummary,
  ConversationRecordCounts
} from '../models/ConversationBranch';
import {
  MessageSwipeSummary,
  MessageSwipeCandidateUpdates,
  MessageSwipeState,
  MAX_SWIPE_CANDIDATES
} from '../models/MessageSwipe';
import { ImpersonateCandidate } from '../models/ImpersonateCandidate';
import { ChatMessage, ChatMessageStatus, createChatMessage, mergeChatMessage } from '../models/ChatMessage';
import { ChatMemory } from '../models/ChatMemory';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatRequest, ChatRequestOptions } from '../models/ChatRequest';
import { ChatResponse } from '../models/ChatResponse';
import { ChatRole } from '../models/ChatRole';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatStreamState,
  ChatDelta,
  ChatStreamResult,
  isStreamTerminalState
} from '../models/ChatStreamTypes';
import { NetworkError } from '../models/NetworkError';
import { Character, buildCharacterSystemContent, resolveCharacterDisplayName } from '../models/Character';
import { Lorebook, LorebookActivationMode } from '../models/Lorebook';
import { MacroContext } from '../models/MacroContext';
import { ProviderConfig } from '../models/ProviderConfig';
import { TokenBudget, DEFAULT_CONTEXT_WINDOW, DEFAULT_RESERVED_OUTPUT_TOKENS } from '../models/TokenBudget';
import {
  calculateSafetyMargin,
  DEFAULT_RECENT_WINDOW_TARGET,
  MIN_COMPLETE_TURNS,
  ContextBudgetConfig
} from '../models/ContextBudgetConfig';
import { ContextHistorySelection } from '../models/ContextHistorySelection';
import { HistoryTrimResult } from '../models/HistoryTrimResult';
import { PersistedChatSession } from '../models/PersistedChatSession';
import { Chat } from '../models/Chat';
import {
  ChatStatusState,
  ChatStatusEntry,
  createEmptyChatStatusState,
  createChatStatusEntry,
  serializeChatStatusState,
  parseChatStatusState
} from '../models/ChatStatusState';
import { extractStatusBlock } from '../parser/ChatStatusBlockParser';
import {
  PromptPresetRequestSnapshot,
  EffectiveGenerationSettings,
  resolveEffectiveGenerationSettings,
  createSnapshotWithoutPreset,
  createSnapshotWithPresets
} from './PromptPresetRuntimeResolver';
import { PromptPreset } from '../models/PromptPreset';
import { Persona } from '../models/Persona';
import { AppServices } from './AppServices';
import { WorldGroupService } from './WorldGroupService';
import { WorldGroup } from '../models/WorldGroup';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatService';

/** 启动阶段超时(毫秒),收到首个 onStart/onDelta/onComplete/onError 后清除 */
const START_TIMEOUT_MS: number = 15000;

/** 默认用户名(本阶段固定值,后续可扩展为用户设置) */
const DEFAULT_USER_NAME: string = 'User';

/** 全局用户称呼 Preferences key(v9 引入,存储在 AppPreferences 中的字符串) */
export const GLOBAL_USER_NAME_KEY: string = 'global_user_name';

/** 状态输出指令开关 Preferences key(全局,跨会话,默认 true) */
export const STATUS_INSTRUCTION_PREFS_KEY: string = 'status_instruction_enabled';

/** 世界书全局默认激活方式 Preferences key(全局,跨会话,默认 OnDemand) */
export const LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY: string = 'lorebook_activation_default';

/** 世界书深度注入位置 Preferences key(全局,跨会话,整数 0-8,默认 2) */
export const LOREBOOK_INJECTION_DEPTH_PREFS_KEY: string = 'lorebook_injection_depth';
/** v44: 记忆关键词检索开关(MemoryKeyword 注入段),默认关闭以保缓存命中率 */
export const MEMORY_KEYWORD_RETRIEVAL_PREFS_KEY: string = 'memory_keyword_retrieval';

/** 世界书全局默认激活方式默认值 */
const DEFAULT_LOREBOOK_ACTIVATION_MODE: LorebookActivationMode = LorebookActivationMode.OnDemand;

/** 世界书深度注入默认深度 */
const DEFAULT_LOREBOOK_INJECTION_DEPTH: number = 2;

/** 自动记忆总结开关 Preferences key(全局,跨会话,默认 false) */
export const MEMORY_AUTO_SUMMARY_PREFS_KEY: string = 'memory_auto_summary_enabled';

/** 代写(🎭3候选)引导指令 Preferences key(全局,跨会话;空=用内置默认中文提示词) */
export const IMPRES_GUIDE_KEY: string = 'impres_guide_prompt';

/** 续写(⚡单次)引导指令 Preferences key(全局,跨会话;空=用内置默认中文提示词) */
export const CONTINUE_GUIDE_KEY: string = 'continue_guide_prompt';

/** delta 持久化节流间隔(毫秒) */
const PERSISTENCE_THROTTLE_MS: number = 400;

/** 续写单次请求解析结果:用户下一句发言 + 角色回应 */
interface AutoContinueTurn {
  user: string;
  assistant: string;
}

/** delta 持久化触发的最小字符增量 */
const PERSISTENCE_MIN_CHARS: number = 64;

/**
 * 聊天状态枚举。
 */
export enum ChatState {
  Idle = 'Idle',
  Sending = 'Sending',
  Streaming = 'Streaming',
  Completed = 'Completed',
  Cancelled = 'Cancelled',
  Failed = 'Failed'
}

/**
 * 聊天服务回调。
 */
export interface ChatServiceCallbacks {
  /** 消息列表变更 */
  onMessagesChanged: (messages: ChatMessage[]) => void;
  /** 状态变更 */
  onStateChanged: (state: ChatState) => void;
  /** 错误消息 */
  onError: (message: string) => void;
  /**
   * 助手最终消息完成回调 (可选)。
   *
   * @param assistantMessageId 真实助手消息 ID
   * @param performanceHintJson 可选 Hint JSON (无则空字符串)
   */
  onAssistantMessageFinalized?: (
    assistantMessageId: string,
    performanceHintJson: string
  ) => void;
  /**
   * 角色状态变更回调(CHAT-STATUS-1A,可选)。
   *
   * 触发时机:
   * - 会话初始化 / 切换 / 新建后加载到状态
   * - AI 回复完成后合并更新状态
   * - 用户通过 updateStatusState 增删改锁字段后
   *
   * 用途: ChatViewModel 实现此回调,把最新状态同步到 ChatPage 顶部状态卡片。
   */
  onStatusChanged?: (state: ChatStatusState) => void;
  /**
   * 缓存命中率更新回调(可选)。
   *
   * 触发时机:AI 回复完成后,从 Provider 响应中提取缓存统计。
   *
   * @param cachedTokens 缓存命中的 token 数
   * @param promptTokens 总输入 prompt token 数
   * @param hitRatio 缓存命中率 (cachedTokens / promptTokens, 0~1)
   */
  onCacheStatsUpdate?: (cachedTokens: number, promptTokens: number, hitRatio: number) => void;
}


/** 默认流式请求选项 */
const DEFAULT_OPTIONS: ChatRequestOptions = {
  temperature: 0.7,
  topP: 1.0,
  maxTokens: 1024,
  stream: true
};

/**
 * CHAT-STATUS-1A: 按字段名在条目列表中查找(精确匹配)。
 * @returns 找到的条目,未找到返回 null
 */
function findStatusEntryByName(
  entries: ChatStatusEntry[],
  name: string
): ChatStatusEntry | null {
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].name === name) {
      return entries[i];
    }
  }
  return null;
}

/**
 * CHAT-STATUS-1A: 尝试把整段响应作为 JSON 解析出状态字段(兜底)。
 * 处理:
 * - 纯 JSON 对象 {"字段名":"值"}
 * - 单层包装 {"status": {...}} / {"data": {...}}
 * - 双重编码 "{\"字段名\":\"值\"}"
 */
function parseStatusJsonWhole(content: string): ChatStatusEntry[] {
  const trimmed: string = stripFencesForStatus(content);
  if (trimmed.length === 0) {
    return [];
  }
  let parsed: Object | null = tryParseJson(trimmed);
  // 双重编码:解析结果是字符串,再解析一次
  if (parsed !== null && typeof parsed === 'string') {
    parsed = tryParseJson(parsed as string);
  }
  if (parsed === null || typeof parsed !== 'object') {
    return [];
  }
  const root: Record<string, Object> = parsed as Record<string, Object>;
  const entries: ChatStatusEntry[] = collectScalarEntries(root);
  if (entries.length > 0) {
    return entries;
  }
  // 单层包装:取第一个对象值键的内层
  const keys: string[] = Object.keys(root);
  for (let i = 0; i < keys.length; i++) {
    const val: Object | undefined = root[keys[i]];
    if (val !== null && typeof val === 'object') {
      const innerEntries: ChatStatusEntry[] = collectScalarEntries(val as Record<string, Object>);
      if (innerEntries.length > 0) {
        return innerEntries;
      }
    }
  }
  return [];
}

function tryParseJson(text: string): Object | null {
  try {
    return JSON.parse(text) as Object;
  } catch (e) {
    return null;
  }
}

function collectScalarEntries(obj: Record<string, Object>): ChatStatusEntry[] {
  const entries: ChatStatusEntry[] = [];
  const keys: string[] = Object.keys(obj);
  for (let i = 0; i < keys.length; i++) {
    const name: string = keys[i].trim();
    if (name.length === 0) {
      continue;
    }
    const raw: Object | undefined = obj[keys[i]];
    const value: string = statusScalarToString(raw);
    if (value.length === 0) {
      continue;
    }
    entries.push(createChatStatusEntry(name, value, false, false));
  }
  return entries;
}

function statusScalarToString(raw: Object | undefined): string {
  if (raw === undefined || raw === null) {
    return '';
  }
  if (typeof raw === 'string') {
    return (raw as string).trim();
  }
  if (typeof raw === 'number') {
    return String(raw as number);
  }
  if (typeof raw === 'boolean') {
    return String(raw as boolean);
  }
  return '';
}

function stripFencesForStatus(text: string): string {
  let s: string = text.trim();
  if (s.startsWith('```')) {
    const nl: number = s.indexOf('\n');
    s = nl >= 0 ? s.substring(nl + 1) : s.substring(3);
  }
  if (s.endsWith('```')) {
    s = s.substring(0, s.length - 3);
  }
  return s.trim();
}

/**
 * 聊天服务。
 * 生命周期跟随 ChatPage,dispose 后不可复用。
 */

/**
 * 生成类型(T-6.3 / T-6.4B-1.2):
 * - NormalResponse: 普通生成,持久化走 ChatPersistenceService.updateMessage
 * - SwipeCandidate: 候选生成,持久化走 MessageSwipePersistenceService.updateCandidate
 * - BranchRegeneration: 重新生成新分支,持久化走 ChatPersistenceService.updateMessage(新 Assistant 在新 Branch 中)
 */
export enum ChatGenerationKind {
  NormalResponse = 'NormalResponse',
  SwipeCandidate = 'SwipeCandidate',
  BranchRegeneration = 'BranchRegeneration',
  AutoContinue = 'AutoContinue',
  Narrator = 'Narrator'
}

/**
 * 活动生成上下文(T-6.3 / T-6.4B-1.2)。
 * 一次请求生命周期内不可变。所有异步回调通过 operationId + 关键字段联合判断迟到。
 * 不持久化,不记录完整 ID。
 */
interface ActiveGenerationContext {
  readonly operationId: number;
  readonly kind: ChatGenerationKind;
  readonly chatId: string;
  readonly assistantMessageId: string;
  readonly swipeCandidateIndex?: number;
  readonly branchId?: string;
  readonly forkMessageId?: string;
  readonly autoContinueStep?: 'impersonate' | 'response'; // legacy, kept for DB compat
}

export class ChatService {
  private messages: ChatMessage[] = [];
  private state: ChatState = ChatState.Idle;
  private currentHandle: ChatStreamHandle | null = null;
  private currentAssistantId: string | null = null;
  private disposed: boolean = false;
  private startTimerId: number = -1;
  private readonly modelService: ModelService;
  private readonly lorebookService: LorebookService | null;
  private readonly promptBuilder: PromptBuilder | null;
  private readonly tokenCounter: TokenCounter | null;
  private readonly historyTrimmer: HistoryTrimmer | null;
  /**
   * RecentMessageSelector 最近原始消息窗口选择器(v8.3 Phase 2)。
   * - 在 PromptBuilder 之前筛选最近窗口,去重已被记忆覆盖的旧原文
   * - 无状态,可被多个 ChatService 共享
   * - 为 null 时回退到旧行为(把全部 sourceMessages 传给 PromptBuilder)
   */
  private readonly recentMessageSelector: RecentMessageSelector | null;
  private readonly persistenceService: ChatPersistenceService | null;
  private readonly promptPresetService: PromptPresetService | null;
  /** 当前角色(用于 PromptBuilder 构建) */
  private character: Character | null = null;
  /**
   * 世界书全局默认激活方式(跨会话)。
   * 书级 activationMode = FollowGlobal 时使用此值解析有效模式。
   * 默认 OnDemand。
   */
  private lorebookActivationDefault: LorebookActivationMode = DEFAULT_LOREBOOK_ACTIVATION_MODE;
  /** 世界书深度注入位置(0-8,跨会话)。默认 2 */
  private lorebookInjectionDepth: number = DEFAULT_LOREBOOK_INJECTION_DEPTH;
  /** v44: 记忆关键词检索开关(默认关,保持缓存命中率) */
  private memoryKeywordRetrievalEnabled: boolean = false;
  /**
   * Prompt Cache 优化:是否启用自动记忆总结。
   * 默认 false(关闭自动总结,保持 Memory 段稳定)。
   * 用户可手动触发记忆总结(手动触发时立即执行一次,然后冻结)。
   */
  private memoryAutoSummaryEnabled: boolean = false;
  /** 最近一次使用的回调(用于 stopGeneration/clearConversation 通知状态) */
  private lastCallbacks: ChatServiceCallbacks | null = null;
  /** 最近一次 Prompt 构建后的 Token 预算(只读,用于页面查询) */
  private lastTokenBudget: TokenBudget | undefined = undefined;
  /** 最近一次历史裁剪结果(只读) */
  private lastHistoryTrimResult: HistoryTrimResult | undefined = undefined;
  /** 最后一次构建的请求消息(用于 UI 上下文占用估算,可能与实际发送的裁剪后消息不同) */
  private lastBuiltRequestMessages: ChatMessage[] | undefined = undefined;

  // ===== 持久化状态 =====
  /** 当前会话 id(未初始化时为 undefined) */
  private currentChatId: string | undefined = undefined;
  /** 当前会话 Chat 对象(用于读取 userNameOverride 等字段) */
  private currentChat: Chat | null = null;
  /** 当前会话的角色状态(CHAT-STATUS-1A,随会话切换加载,AI 回复后合并更新) */
  private currentStatusState: ChatStatusState = createEmptyChatStatusState();
  /** CHAT-STATUS-1A: 是否请求下一次回复重新生成/优化字段(点击"AI 生成"按钮设置) */
  private statusFieldGenerationRequested: boolean = false;
  /** CHAT-STATUS-1A: 是否正在执行一次性的字段生成请求(防止并发) */
  private statusGenerationInProgress: boolean = false;
  /**
   * 状态输出指令开关。
   * true=向模型注入状态输出指令(AI 回复时附带状态 JSON);
   * false=不注入状态指令,AI 只返回纯正文(不返回状态 JSON)。
   * 可由用户在记忆管理页手动切换。默认 true。
   */
  private statusInstructionEnabled: boolean = true;
  /** 当前会话的最大 sequenceNumber(空会话为 0) */
  private currentSequenceNumber: number = 0;
  /** 会话是否已初始化 */
  private contextInitialized: boolean = false;
  /** 初始化进行中的 Promise(防止并发) */
  private initializingPromise: Promise<void> | null = null;

  // ===== 流式 delta 持久化节流 =====
  /** 节流定时器 id */
  private persistenceTimerId: number = -1;
  /** 上次持久化时的 Assistant content 长度 */
  private lastPersistedContentLength: number = 0;
  /** 待持久化的 Assistant id */
  private pendingPersistAssistantId: string | null = null;
  /** T-6.4A-R6: 当前在飞的 Swipe Candidate 持久化 Promise(delta 或 final),
   * 用于串行化 updateCandidate 调用,防止嵌套事务 */
  private pendingSwipePersistPromise: Promise<void> | null = null;

  /** MessageSwipePersistenceService 消息候选持久化服务 */
  private readonly swipePersistenceService: MessageSwipePersistenceService | null;
  /** ConversationBranchPersistenceService 对话分支持久化服务(T-6.4A,用于活动 Branch 加载) */
  private readonly branchPersistenceService: ConversationBranchPersistenceService | null;
  /** ChatBackgroundService(用于读取 per-chat 思考强度) */
  private readonly chatBackgroundService: ChatBackgroundService | null;
  /** MemoryService 长期记忆业务服务(v8,用于注入摘要和触发增量总结) */
  private readonly memoryService: MemoryService | null;
  /** ContextBudgetService per-chat 上下文预算服务(v8.1,覆盖 effectiveSettings) */
  private readonly contextBudgetService: ContextBudgetService | null;
  /** 当前会话的 Swipe 摘要列表 */
  private swipeSummaries: MessageSwipeSummary[] = [];
  /** 当前生成操作标识(用于阻止迟到回调),每次启动/停止递增 */
  private generationOperationId: number = 0;
  /**
   * 当前活动生成上下文(T-6.3)。
   * - 覆盖 NormalResponse 和 SwipeCandidate 两种生成
   * - 在最终状态持久化后才由 clearActiveGeneration 清除
   * - 迟到回调通过 isCurrentGeneration 判断
   */
  private activeGeneration: ActiveGenerationContext | null = null;
  /** 最后一条非 firstMessage 的 Assistant 消息 ID(用于判断可 Swipe 范围) */
  private lastAssistantMessageId: string = '';
  /** Swipe 浏览/切换操作进行中(用于互斥) */
  private swipeOperationInProgress: boolean = false;

  // ===== T-6.4B-1 Branch 状态 =====
  /** 当前会话的 Branch 摘要列表 */
  private branches: ConversationBranchSummary[] = [];
  /** 当前活动 Branch ID */
  private activeBranchId: string = '';
  /** 当前会话的 Branch 记录数量统计 */
  private recordCounts: ConversationRecordCounts | undefined = undefined;
  /** Branch 操作进行中(创建 Child / 切换),用于与生成 / Swipe / 会话操作互斥 */
  private branchOperationInProgress: boolean = false;

  /** AppPreferences(用于读取全局用户称呼,v9 引入) */
  private readonly appPreferences: AppPreferences | null;

  constructor(
    modelService: ModelService,
    lorebookService: LorebookService | null = null,
    promptBuilder: PromptBuilder | null = null,
    tokenCounter: TokenCounter | null = null,
    historyTrimmer: HistoryTrimmer | null = null,
    persistenceService: ChatPersistenceService | null = null,
    promptPresetService: PromptPresetService | null = null,
    swipePersistenceService: MessageSwipePersistenceService | null = null,
    branchPersistenceService: ConversationBranchPersistenceService | null = null,
    chatBackgroundService: ChatBackgroundService | null = null,
    memoryService: MemoryService | null = null,
    contextBudgetService: ContextBudgetService | null = null,
    appPreferences: AppPreferences | null = null,
    recentMessageSelector: RecentMessageSelector | null = null
  ) {
    this.modelService = modelService;
    this.lorebookService = lorebookService;
    this.promptBuilder = promptBuilder;
    this.tokenCounter = tokenCounter;
    this.historyTrimmer = historyTrimmer;
    this.persistenceService = persistenceService;
    this.promptPresetService = promptPresetService;
    this.swipePersistenceService = swipePersistenceService;
    this.branchPersistenceService = branchPersistenceService;
    this.chatBackgroundService = chatBackgroundService;
    this.memoryService = memoryService;
    this.contextBudgetService = contextBudgetService;
    this.appPreferences = appPreferences;
    this.recentMessageSelector = recentMessageSelector;
  }

  /**
   * 初始化角色聊天上下文(无持久化版本)。
   * 有角色时:
   * - 注入 firstMessage 作为 Assistant 开场消息
   * - Character System Prompt 由 PromptBuilder 在每次发送/重新生成时动态生成,
   *   不存储到 this.messages(避免与 PromptBuilder 重复注入)
   * 无角色时:不做任何初始化。
   * 只在消息列表为空时生效,防止重复注入。
   *
   * 此方法不访问数据库,用于无 persistenceService 的场景(如旧测试)。
   * 新代码应使用 initializeSession()。
   *
   * @returns 是否添加了 firstMessage(用于通知页面显示开场白)
   */
  initContext(character: Character | null): boolean {
    this.character = character;
    this.contextInitialized = true;
    if (this.messages.length > 0) {
      return false;
    }
    if (character === null) {
      return false;
    }

    const newMessages: ChatMessage[] = [];

    if (character.firstMessage.length > 0) {
      const firstMsg: ChatMessage = {
        id: 'msg-' + generateUuid(),
        role: ChatRole.Assistant,
        content: character.firstMessage,
        createdAt: Date.now(),
        isStreaming: false,
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.CharacterFirstMessage
      };
      newMessages.push(firstMsg);
    }

    this.messages = newMessages;
    return character.firstMessage.length > 0;
  }

  /**
   * 异步初始化会话(持久化版本)。
   *
   * 流程:
   * 1. 尝试加载最近会话(openLatestSession)
   * 2. 若存在:恢复 messages 和 currentSequenceNumber
   * 3. 若不存在:创建新会话,有角色且 firstMessage 非空时注入开场白
   * 4. 标记 contextInitialized = true
   *
   * 同一 ChatService 实例只初始化一次。
   * 并发调用只执行一次,其他调用等待结果。
   * 初始化失败抛异常,页面应捕获并显示错误。
   *
   * @param character 当前角色(可选)
   */
  async initializeSession(character?: Character, forceNew: boolean = false): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot initialize session');
    }
    if (this.contextInitialized) {
      return;
    }
    if (this.initializingPromise !== null) {
      await this.initializingPromise;
      return;
    }
    const promise: Promise<void> = this.doInitializeSession(character, forceNew);
    this.initializingPromise = promise;
    try {
      await promise;
    } finally {
      this.initializingPromise = null;
    }
  }

  private async doInitializeSession(character?: Character, forceNew: boolean = false): Promise<void> {
    this.character = character !== undefined ? character : null;

    // 加载自动记忆总结开关(全局偏好,跨会话)
    this.loadMemoryAutoSummaryPref();

    // 加载状态输出指令开关(全局偏好,跨会话)
    this.loadStatusInstructionPref();

    // 加载世界书全局默认激活方式与深度注入偏好(全局,跨会话)
    this.loadLorebookPrefs();

    // 加载记忆关键词检索开关(v44,全局,跨会话)
    this.loadMemoryPrefs();

    // 无持久化服务:回退到同步 initContext
    if (this.persistenceService === null) {
      this.initContext(this.character);
      return;
    }

    const characterId: string | undefined =
      this.character !== null ? this.character.id : undefined;
    try {
      // forceNew=true:跳过 openLatestSession,直接创建新会话(角色卡"新建对话"入口)
      let session: PersistedChatSession | null = null;
      if (!forceNew) {
        session = await this.persistenceService.openLatestSession(characterId);
      }

      if (session !== null) {
        // 恢复已有会话
        this.currentChatId = session.chat.id;
        this.currentChat = session.chat;
        this.messages = session.messages.slice();
        this.currentSequenceNumber = session.maxSequenceNumber;
        // CHAT-STATUS-1A: 加载该会话的角色状态
        this.syncStatusStateFromCurrentChat();
      } else {
        // 创建新会话
        await this.createNewSession(characterId);
      }

      // 加载 Swipe summaries
      if (this.swipePersistenceService !== null && this.currentChatId !== undefined) {
        this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
        // 规范化中断的 Streaming Candidate
        const normalizedCount: number = await this.swipePersistenceService.normalizeInterruptedCandidates(this.currentChatId);
        if (normalizedCount > 0) {
          // 重新加载 messages(因中断 Candidate 可能已修改 messages)
          const session2: PersistedChatSession | null =
            await this.persistenceService.loadSession(this.currentChatId);
          if (session2 !== null) {
            this.messages = session2.messages.slice();
            this.currentSequenceNumber = session2.maxSequenceNumber;
          }
          // 重新加载 summaries
          this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
        }
      }
      // 更新 lastAssistantMessageId
      this.updateLastAssistantMessageId();
      // T-6.4B-1: 加载 Branch 状态(branches / activeBranchId / recordCounts)
      await this.refreshBranchState();

      this.contextInitialized = true;
    } catch (e) {
      // 保留原始错误类型(如 DatabaseError),不重复包装用户文案前缀
      // ViewModel 负责显示一次用户可读文案
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'initializeSession failed: ' + msg);
      if (e instanceof Error) {
        throw e;
      }
      throw new Error(msg);
    }
  }

  /**
   * 创建新会话并注入开场白(如果有角色且有开场白或备用开场白)。
   * 默认 title 使用角色名(无角色时为"新对话",由 persistenceService 兜底)。
   *
   * 开场白池构建:
   * - [firstMessage(非空时)] + alternateGreetings
   * - 池[0] 作为首条消息内容(CharacterFirstMessage,即 Candidate 0)
   * - 池[1..N] 作为 Swipe 候选(不激活,默认显示池[0])
   * - 用户后续可通过 Swipe 切换开场白
   *
   * 兼容:角色只有 alternateGreetings、firstMessage 为空时,
   * 池首条为 alternateGreetings[0],同样注入首条消息并允许切换其余备用开场白。
   */
  private async createNewSession(characterId?: string): Promise<void> {
    if (this.persistenceService === null) {
      return;
    }

    const greetingPool: string[] = this.buildGreetingPool();
    // 默认 title 优先用角色名(规范:名称=角色名),无角色时传 undefined 由 persistence 兜底为"新对话"
    const defaultTitle: string | undefined =
      this.character !== null && this.character.name.length > 0
        ? this.character.name
        : undefined;

    if (greetingPool.length > 0 && this.character !== null) {
      const firstMsg: ChatMessage = {
        id: 'msg-' + generateUuid(),
        role: ChatRole.Assistant,
        content: greetingPool[0],
        createdAt: Date.now(),
        isStreaming: false,
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.CharacterFirstMessage
      };
      const session: PersistedChatSession =
        await this.persistenceService.createSessionWithFirstMessage(
          characterId, defaultTitle, firstMsg
        );
      this.currentChatId = session.chat.id;
      this.currentChat = session.chat;
      this.messages = [firstMsg];
      this.currentSequenceNumber = 1;

      // 初始化池[1..N]作为首条消息的 Swipe 候选(池[0]已是 Candidate 0 内容)
      await this.initializeGreetingSwipeCandidates(firstMsg.id, greetingPool.slice(1));
    } else {
      const session: PersistedChatSession =
        await this.persistenceService.createSession(characterId, defaultTitle);
      this.currentChatId = session.chat.id;
      this.currentChat = session.chat;
      this.messages = [];
      this.currentSequenceNumber = 0;
    }
    // CHAT-STATUS-1A: 新会话无状态配置,重置为空态
    this.syncStatusStateFromCurrentChat();
  }

  /**
   * 构建开场白池:[firstMessage(非空时)] + alternateGreetings(trim 过滤空项)。
   */
  private buildGreetingPool(): string[] {
    if (this.character === null) {
      return [];
    }
    const pool: string[] = [];
    if (this.character.firstMessage.trim().length > 0) {
      pool.push(this.character.firstMessage.trim());
    }
    for (let i = 0; i < this.character.alternateGreetings.length; i++) {
      const greeting: string = this.character.alternateGreetings[i].trim();
      if (greeting.length > 0) {
        pool.push(greeting);
      }
    }
    return pool;
  }

  /**
   * 将开场白候选列表初始化为首条消息的 Swipe 候选。
   * - 调用 ensureSwipeState 创建 Group + Candidate 0(默认池[0]已是消息内容)
   * - 对 candidates[i] 调用 appendCandidate(activate=false)作为 Candidate 1..N
   * - 失败不阻塞会话创建,仅记录 warning
   *
   * @param firstMessageId 首条开场白消息的 ID
   * @param candidates 除池[0]外的其余候选内容
   */
  private async initializeGreetingSwipeCandidates(
    firstMessageId: string,
    candidates: string[]
  ): Promise<void> {
    if (this.swipePersistenceService === null) {
      return;
    }
    if (candidates.length === 0) {
      return;
    }
    try {
      // ensureSwipeState 创建 Group + Candidate 0(默认池[0]已是消息内容)
      await this.swipePersistenceService.ensureSwipeState(firstMessageId);
      // 逐个追加候选作为 Candidate 1..N,不 activate(默认显示池[0])
      for (let i = 0; i < candidates.length; i++) {
        const candidate: string = candidates[i];
        if (candidate.trim().length === 0) {
          continue;
        }
        try {
          await this.swipePersistenceService.appendCandidate(
            firstMessageId,
            {
              content: candidate,
              status: ChatMessageStatus.Completed,
              isStreaming: false
            },
            false // activate=false,保持池[0]为当前显示
          );
        } catch (e) {
          // 单条追加失败不阻塞其他条目
          Logger.warn(LOG_TAG, 'init greeting candidate failed idx=' + String(i)
            + ': ' + (e instanceof Error ? e.message : String(e)));
        }
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'initializeGreetingSwipeCandidates failed: '
        + (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 获取当前会话 id(未初始化时为 undefined)。
   */
  getCurrentChatId(): string | undefined {
    return this.currentChatId;
  }

  /**
   * 获取当前会话 Chat 对象(未初始化时为 null)。
   * 用于 UI 读取对话级 userNameOverride 字段。
   */
  getCurrentChat(): Chat | null {
    return this.currentChat;
  }

  /**
   * 获取开场白池副本:[firstMessage(非空时)] + alternateGreetings(trim 过滤空项)。
   * 供"新建章节"开场白选择器等 UI 预览使用。
   */
  getGreetingPool(): string[] {
    return this.buildGreetingPool();
  }

  /**
   * 新建章节(世界分组内切换开场白)。
   *
   * 流程(Stage 6 §4.4):
   * 1. 校验:角色存在、开场白索引有效、当前会话存在
   * 2. 确保当前会话所属世界分组(无分组时创建"角色名+的世界"并把当前会话移入)
   * 3. 计算章节序号 = 组内会话数 + 1,标题 = "第N章·开场白前20字"
   * 4. statusConfigJson 优先继承当前会话,否则取组内最近会话的
   * 5. 用选定开场白创建新会话(事务),初始化其余开场白为 Swipe 候选
   * 6. 切换到新会话(原会话保留,可切回)
   *
   * @param greetingIndex 开场白池索引(0 ≤ greetingIndex < 池长度)
   * @returns 新章节会话 id
   * @throws Error 前置校验失败 / 持久化失败(事务由 createSessionWithFirstMessage 保证)
   */
  async createChapter(greetingIndex: number): Promise<string> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.character === null) {
      throw new Error('当前无角色,无法新建章节');
    }
    if (this.currentChat === null || this.currentChatId === undefined) {
      throw new Error('当前无活跃会话');
    }
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    const greetingPool: string[] = this.buildGreetingPool();
    if (greetingIndex < 0 || greetingIndex >= greetingPool.length) {
      throw new Error('开场白索引无效');
    }

    // 2. 确保世界分组
    const worldGroupService: WorldGroupService = AppServices.getWorldGroupService();
    let worldId: string = this.currentChat.worldId;
    if (worldId.length === 0) {
      const group: WorldGroup =
        await worldGroupService.create(this.character.name + '的世界');
      await worldGroupService.moveChatToWorld(this.currentChat.id, group.id);
      worldId = group.id;
    }

    // 3. 章节序号与标题
    const worldChats: Chat[] = await worldGroupService.listChatsInWorld(worldId);
    const chapterNumber: number = worldChats.length + 1;
    const greeting: string = greetingPool[greetingIndex];
    const title: string = '第' + chapterNumber.toString() + '章·'
      + this.buildChapterTitlePreview(greeting);

    // 4. 状态配置继承
    let statusConfigJson: string = this.currentChat.statusConfigJson;
    if (statusConfigJson.length === 0) {
      const latest: Chat | null = await worldGroupService.latestChatInWorld(worldId);
      if (latest !== null) {
        statusConfigJson = latest.statusConfigJson;
      }
    }

    // 5. 创建新会话(选定开场白作为首条消息)
    const firstMsg: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.Assistant,
      content: greeting,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.CharacterFirstMessage
    };
    const session: PersistedChatSession = await this.persistenceService.createSessionWithFirstMessage(
      this.character.id, title, firstMsg
    );
    const newChatId: string = session.chat.id;
    await worldGroupService.moveChatToWorld(newChatId, worldId);
    if (statusConfigJson.length > 0) {
      await this.persistenceService.updateChatStatusConfig(newChatId, statusConfigJson);
    }
    // 其余开场白作为首条消息的 Swipe 候选
    await this.initializeGreetingSwipeCandidates(firstMsg.id, greetingPool.slice(1));

    // 6. 切换到新会话(复用公开 switchSession:flush + 加载 + 通知页面)
    await this.switchSession(newChatId);
    return newChatId;
  }

  /**
   * 章节标题开场白预览:前 20 字符,超长追加省略号。
   */
  private buildChapterTitlePreview(greeting: string): string {
    const trimmed: string = greeting.trim();
    if (trimmed.length <= 20) {
      return trimmed;
    }
    return trimmed.substring(0, 20) + '…';
  }

  /**
   * 解析当前生效的用户称呼。
   *
   * 优先级(v9 引入):
   * 1. 当前会话 userNameOverride 非空 -> 使用对话级覆盖
   * 2. 当前角色 userName 非空 -> 使用角色专属称呼
   * 3. AppPreferences 中 global_user_name 非空 -> 使用全局用户称呼
   * 4. 以上均空 -> 回退到 'User'
   *
   * AppPreferences 不可用或读取失败时静默回退到 DEFAULT_USER_NAME。
   *
   * @returns 当前生效的用户称呼
   */
  async resolveUserName(): Promise<string> {
    // 1. 对话级覆盖
    if (this.currentChat !== null && this.currentChat.userNameOverride.trim().length > 0) {
      return this.currentChat.userNameOverride.trim();
    }
    // 2. 角色专属称呼
    if (this.character !== null && this.character.userName.trim().length > 0) {
      return this.character.userName.trim();
    }
    // 3. Persona.name(有效身份名称)
    const persona: Persona | null = await this.resolveEffectivePersona();
    if (persona !== null && persona.name.trim().length > 0) {
      return persona.name.trim();
    }
    // 4. 全局用户称呼
    if (this.appPreferences !== null) {
      try {
        const globalName: string = await this.appPreferences.getString(GLOBAL_USER_NAME_KEY, '');
        if (globalName.trim().length > 0) {
          return globalName.trim();
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'resolveUserName: read global failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }
    // 5. 默认 'User'
    return DEFAULT_USER_NAME;
  }

  /**
   * 更新当前会话的对话级用户称呼覆盖。
   * - 传入非空字符串:写入并 trim
   * - 传入 null 或空字符串:清空覆盖(回退到角色或全局)
   *
   * 持久化通过 ChatPersistenceService.updateUserNameOverride 完成。
   * 内存中的 currentChat 同步更新。
   *
   * @param override 新的覆盖值(null 或空字符串表示清空)
   * @returns 更新后的 Chat 对象(无当前会话时返回 null)
   * @throws Error 当无 persistenceService 或会话不存在时
   */
  async updateCurrentChatUserNameOverride(override: string | null): Promise<Chat | null> {
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    if (this.currentChatId === undefined) {
      throw new Error('当前无活跃会话');
    }
    const normalized: string = override === null ? '' : override.trim();
    const updated: Chat = await this.persistenceService.updateUserNameOverride(
      this.currentChatId, normalized
    );
    this.currentChat = updated;
    return updated;
  }

  /**
   * 更新当前聊天的锁定 Persona ID。
   * @param personaId Persona ID(null 或空字符串清除锁定)
   * @returns 更新后的 Chat 对象(无当前会话时返回 null)
   */
  async updateCurrentChatPersonaId(personaId: string | null): Promise<Chat | null> {
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    if (this.currentChatId === undefined) {
      throw new Error('当前无活跃会话');
    }
    const effectiveId: string = personaId === null ? '' : personaId;
    const updated: Chat = await this.persistenceService.updateChatPersonaId(
      this.currentChatId, effectiveId
    );
    this.currentChat = updated;
    return updated;
  }

  async updateCurrentChatUserPersonaSummary(summary: string): Promise<Chat | null> {
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    if (this.currentChatId === undefined) {
      throw new Error('当前无活跃会话');
    }
    const updated: Chat = await this.persistenceService.updateUserPersonaSummary(
      this.currentChatId, summary
    );
    this.currentChat = updated;
    return updated;
  }

  /** 获取当前角色的默认 Persona ID */
  getCharacterDefaultPersonaId(): string {
    return this.character !== null ? this.character.defaultPersonaId : '';
  }

  /**
   * 解析当前聊天的有效 Persona。
   * 优先级:聊天锁定 > 角色默认 > 全局默认 > null
   */
  async resolveEffectivePersona(): Promise<Persona | null> {
    const chatPersonaId: string = this.currentChat !== null ? this.currentChat.personaId : '';
    const characterDefaultPersonaId: string = this.character !== null ? this.character.defaultPersonaId : '';
    try {
      const personaService = AppServices.getPersonaService();
      return await personaService.resolveEffectivePersona(chatPersonaId, characterDefaultPersonaId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'resolveEffectivePersona failed: ' + String(e));
      return null;
    }
  }

  /**
   * 会话是否已初始化(可用于页面判断是否可发送)。
   */
  isSessionReady(): boolean {
    return this.contextInitialized;
  }

  /**
   * 发送用户消息并开始流式生成。
   * 顺序:校验 → 创建 User 消息 → 持久化 → 创建 Assistant 占位 → 持久化 → 启动网络。
   *
   * 持久化策略:
   * - 有 persistenceService 时:先持久化 User + Streaming Assistant(事务),
   *   失败则不启动网络请求,页面显示错误
   * - 无 persistenceService 时:仅更新内存(兼容旧测试)
   */
  async sendMessage(userContent: string, callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot send message');
    }
    if (userContent.trim().length === 0) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'sendMessage rejected: busy state=' + this.state);
      return;
    }

    this.lastCallbacks = callbacks;
    this.generationOperationId++;

    // 1. 创建用户消息
    const userMsg: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.User,
      content: userContent,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation
    };

    // 2. 创建空 Assistant 占位消息
    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 3. 持久化(如果有 persistenceService)
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        const result =
          await this.persistenceService.appendUserAndStreamingAssistant(
            this.currentChatId, userMsg, assistantMsg
          );
        this.currentSequenceNumber = result.assistantSequenceNumber;
        this.lastPersistedContentLength = 0;
        this.pendingPersistAssistantId = assistantId;
      } catch (e) {
        // 持久化失败:不启动请求,显示错误
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.error(LOG_TAG, 'sendMessage persist failed: ' + msg);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('消息保存失败,请重试');
        return;
      }
    }

    // 4. 更新内存(持久化成功后)
    this.messages = [...this.messages, userMsg, assistantMsg];
    this.currentAssistantId = assistantId;
    // 建立 NormalResponse 活动上下文
    this.activeGeneration = {
      operationId: this.generationOperationId,
      kind: ChatGenerationKind.NormalResponse,
      chatId: this.currentChatId !== undefined ? this.currentChatId : '',
      assistantMessageId: assistantId
    };
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 5. 启动网络请求(失败也保留消息)
    this.doStream(assistantId, callbacks, this.activeGeneration);
  }

  async extractUserFromCharacter(): Promise<string> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.character === null) {
      throw new Error('当前会话无角色');
    }
    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new Error('未配置模型');
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      throw new Error('模型名称为空');
    }
    const char: Character = this.character;
    const charInfo: string = [
      '角色名: ' + char.name,
      char.description.length > 0 ? '描述: ' + char.description : '',
      char.personality.length > 0 ? '性格: ' + char.personality : '',
      char.scenario.length > 0 ? '场景: ' + char.scenario : '',
      char.mesExample.length > 0 ? '对话示例: ' + char.mesExample : ''
    ].filter((s: string) => s.length > 0).join('\n');

    const systemMsg: ChatMessage = {
      id: 'sys-extract-user',
      role: ChatRole.System,
      content: '你是一个角色分析专家。根据以下角色卡信息，分析并提取出与用户（{{user}}）互动相关的身份特征：\n- 用户在故事中扮演什么角色（如：朋友、恋人、同事、陌生人等）\n- 用户与角色的关系动态\n- 用户可能拥有的隐含特征（根据角色对用户的态度推断）\n\n输出格式：用2-3句话简洁描述，不要编造角色卡中没有的信息，只提取合理推断的内容。',
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };
    const userMsg: ChatMessage = {
      id: 'usr-extract-user',
      role: ChatRole.User,
      content: charInfo,
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };
    const request: ChatRequest = {
      model: modelName,
      messages: [systemMsg, userMsg],
      temperature: 0.3,
      topP: 0.9,
      maxTokens: 512,
      stream: false
    };
    const response: ChatResponse = await this.modelService.sendChat(request);
    const summary: string = response.content.trim();
    if (summary.length === 0) {
      throw new Error('AI 返回为空');
    }
    return summary;
  }

  async summarizeUserPersona(): Promise<string> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new Error('未配置模型');
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      throw new Error('模型名称为空');
    }
    const userMessages: string[] = [];
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].role === ChatRole.User) {
        userMessages.push(this.messages[i].content);
      }
    }
    if (userMessages.length === 0) {
      throw new Error('当前对话无用户消息');
    }
    let combined: string = userMessages.join('\n---\n');
    if (combined.length > 4000) {
      combined = combined.substring(combined.length - 4000);
    }
    const systemMsg: ChatMessage = {
      id: 'sys-summarize-user',
      role: ChatRole.System,
      content: '根据以下对话中用户的发言，总结这个用户的性格特征和说话风格：\n- 说话语气（如：温柔、强势、幽默、冷淡等）\n- 常用表达方式（如：喜欢用反问、喜欢简短回复、喜欢描写动作等）\n- 行为倾向（如：主动型、被动型、进攻型、回避型等）\n- 与角色的互动模式\n\n输出格式：用2-3句话简洁描述，不要逐条列举，要融合成连贯的性格总结。',
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };
    const userMsg: ChatMessage = {
      id: 'usr-summarize-user',
      role: ChatRole.User,
      content: '以下是用户的发言记录：\n\n' + combined,
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };
    const request: ChatRequest = {
      model: modelName,
      messages: [systemMsg, userMsg],
      temperature: 0.3,
      topP: 0.9,
      maxTokens: 512,
      stream: false
    };
    const response: ChatResponse = await this.modelService.sendChat(request);
    const summary: string = response.content.trim();
    if (summary.length === 0) {
      throw new Error('AI 返回为空');
    }
    return summary;
  }

  /**
   * 生成代写候选:AI 生成 3 条简短的用户消息候选,不持久化。
   *
   * 流程:
   * 1. 构建请求消息(复用 buildRequestMessages,保持缓存前缀稳定)
   * 2. 注入代写 System 指令(要求生成 3 条,用 --- 分隔)
   * 3. 非流式调用 ModelService.sendChat
   * 4. 解析响应,按 --- 拆分为最多 3 条候选
   *
   * 不修改 this.messages,不持久化任何消息。
   */
  async generateImpersonateCandidates(): Promise<ImpersonateCandidate[]> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'generateImpersonateCandidates rejected: busy');
      return [];
    }
    if (this.currentChatId === undefined) {
      throw new Error('会话未初始化');
    }

    const userName: string = await this.resolveUserName();
    const charName: string = this.character !== null ? resolveCharacterDisplayName(this.character) : 'Assistant';

    const recentCount: number = Math.min(this.messages.length, 6);
    const recentMessages: ChatMessage[] = this.messages.slice(this.messages.length - recentCount);

    const swapped: ChatMessage[] = recentMessages.map((msg: ChatMessage): ChatMessage => {
      let newRole: ChatRole = msg.role;
      if (msg.role === ChatRole.User) {
        newRole = ChatRole.Assistant;
      } else if (msg.role === ChatRole.Assistant) {
        newRole = ChatRole.User;
      }
      const swappedMsg: ChatMessage = {
        id: msg.id,
        role: newRole,
        content: msg.content,
        createdAt: msg.createdAt,
        status: msg.status,
        source: msg.source
      };
      return swappedMsg;
    });

    let impersonateContent: string =
      '你是' + userName + '，是正在和' + charName + '对话的人类玩家。\n\n' +
      '任务：以' + userName + '的身份，写出 3 条各不相同、简短的下一条发言。每条都必须是一句完整、可以单独成立的话或动作，' +
      '而不是同一个意思的继续或扩充。3 条应体现不同的语气或行动，彼此是不同选择。\n\n' +
      '规则：\n' +
      '- 以' + userName + '的第一人称发言\n' +
      '- 动作用星号括起来，例如：*微笑*、*转身走开*\n' +
      '- 每条占一行，是一条完整独立的回复\n' +
      '- 不要替' + charName + '发言\n' +
      '- 不要把一个回复拆成多行';
    if (this.currentChat !== null && this.currentChat.userPersonaSummary.length > 0) {
      impersonateContent += '\n\n' + userName + '的性格特征：' + this.currentChat.userPersonaSummary;
    }
    // 用户自定义代写引导(全局),非空时追加为额外引导方向
    if (this.appPreferences !== null) {
      try {
        const guide: string = await this.appPreferences.getString(IMPRES_GUIDE_KEY, '');
        if (guide.trim().length > 0) {
          impersonateContent += '\n\n额外引导：' + guide.trim();
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load impres guide failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }
    impersonateContent += '\n\n格式：\n1.\n2.\n3.';

    const impersonateSystem: ChatMessage = {
      id: 'sys-impersonate',
      role: ChatRole.System,
      content: impersonateContent,
      createdAt: Date.now(),
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.ExternalSystem
    };

    const requestMessages: ChatMessage[] = [impersonateSystem, ...swapped];

    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new Error('未配置模型');
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      throw new Error('模型名称为空');
    }

    const effectiveSettings: EffectiveGenerationSettings =
      resolveEffectiveGenerationSettings(
        {
          temperature: config.temperature,
          topP: config.topP,
          maxOutputTokens: config.maxTokens,
          contextWindow: config.contextWindow
        },
        []
      );

    const request: ChatRequest = {
      model: modelName,
      messages: requestMessages,
      temperature: effectiveSettings.temperature !== undefined ? effectiveSettings.temperature : 0.8,
      topP: effectiveSettings.topP !== undefined ? effectiveSettings.topP : 0.9,
      maxTokens: effectiveSettings.maxOutputTokens !== undefined ? effectiveSettings.maxOutputTokens : 4096,
      stream: false
    };

    const response: ChatResponse = await this.modelService.sendChat(request);
    Logger.info(LOG_TAG, 'generateImpersonateCandidates raw response: [' + response.content + ']');
    const result: ImpersonateCandidate[] = this.parseImpersonateCandidates(response.content);
    Logger.info(LOG_TAG, 'generateImpersonateCandidates parsed count: ' + result.length);
    return result;
  }

  private parseImpersonateCandidates(raw: string): ImpersonateCandidate[] {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      return [];
    }

    const candidates: ImpersonateCandidate[] = [];

    const jsonStart: number = trimmed.indexOf('[');
    const jsonEnd: number = trimmed.lastIndexOf(']');
    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      const jsonStr: string = trimmed.substring(jsonStart, jsonEnd + 1);
      try {
        const arr: object[] = JSON.parse(jsonStr) as object[];
        if (Array.isArray(arr)) {
          for (let i = 0; i < arr.length && candidates.length < 3; i++) {
            const val: string = String(arr[i]).trim();
            if (val.length > 0) {
              const candidate: ImpersonateCandidate = {
                index: candidates.length,
                content: val
              };
              candidates.push(candidate);
            }
          }
          if (candidates.length > 0) {
            return candidates;
          }
        }
      } catch (_e) {
        // JSON parse failed, fall through
      }
    }

    const parts: string[] = trimmed.split(/\n*---\n*/);
    for (let i = 0; i < parts.length && candidates.length < 3; i++) {
      const text: string = parts[i].trim();
      if (text.length > 0) {
        const candidate: ImpersonateCandidate = {
          index: candidates.length,
          content: text
        };
        candidates.push(candidate);
      }
    }
    if (candidates.length >= 2) {
      return candidates;
    }

    candidates.length = 0;
    const lines: string[] = trimmed.split(/\n/);
    for (let i = 0; i < lines.length && candidates.length < 3; i++) {
      const text: string = lines[i].trim().replace(/^[\d]+[.)\]]\s*/, '');
      if (text.length > 0) {
        const candidate: ImpersonateCandidate = {
          index: candidates.length,
          content: text
        };
        candidates.push(candidate);
      }
    }

    if (candidates.length === 0 && trimmed.length > 0) {
      const fallback: ImpersonateCandidate = { index: 0, content: trimmed };
      candidates.push(fallback);
    }
    return candidates;
  }

  /**
   * 续写(AutoContinue):单次请求 + 完整上下文。
   *
   * 流程:
   * 1. 复用 createPresetRequestSnapshot + buildRequestMessages 构建与正常发送一致的
   *    完整上下文(预设/世界书/人物卡/记忆/宏/状态指令),保持稳定 System 前缀以命中缓存。
   * 2. 在末尾追加中文续写指令(读 CONTINUE_GUIDE_KEY,支持用户自定义引导方向),
   *    要求模型先以 {{user}} 写下一句发言,再以 {{char}} 回应这条发言。
   *    不做角色对调,避免破坏前缀缓存。
   * 3. 单次非流式 sendChat → 解析 (userText, assistantText)。
   * 4. userMsg + assistantMsg 以最终状态一次性落地并 emit。
   *
   * 指令只进瞬时请求,不落库、不进入历史消息。
   */
  async autoContinue(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'autoContinue rejected: busy');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }

    this.lastCallbacks = callbacks;
    this.generationOperationId++;

    try {
      // 1. 构建完整上下文(稳定前缀,命中主线缓存)
      const snapshot: PromptPresetRequestSnapshot = await this.createPresetRequestSnapshot();
      const baseMessages: ChatMessage[] =
        await this.buildRequestMessages(snapshot.presetSystemPrompt);

      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config === null) {
        throw new Error('未配置模型');
      }
      const modelName: string = config.modelName.trim();
      if (modelName.length === 0) {
        throw new Error('模型名称为空');
      }

      // 2. 组装中文续写指令(默认 + 用户自定义引导),追加到消息末尾
      const userName: string = await this.resolveUserName();
      const charName: string =
        this.character !== null ? resolveCharacterDisplayName(this.character) : 'Assistant';
      // 破甲化续写指令:先锁定角色扮演状态与人设/剧情约束,再给出任务,
      // JSON 只作为输出格式放在最末尾,降低"完成任务+格式"对角色代入的稀释。
      let continueContent: string =
        '你是' + charName + '，正在与' + userName + '进行沉浸式角色扮演对话。' +
        '你拥有完整的人设、性格、语气与世界观，请始终以' + charName + '的身份说话和行动，' +
        '延续当前剧情的既定走向与氛围，按角色应该有的反应自然推进，' +
        '不跳出角色，不解释、不总结，也不以任何方式表明自己是 AI。\n\n' +
        '现在，先以' + userName + '的身份自然地说出下一句对' + charName + '说的话（一句简短完整的发言），' +
        '再以' + charName + '的身份，严格按人设与当前剧情对这句话做出符合角色性格的回应。\n\n' +
        '始终维持角色扮演状态，不得偏离' + charName + '的人设与既定剧情方向。\n\n' +
        '输出格式（仅作为结构标记，请继续以角色身份创作）：\n' +
        '{"user":"用户下一条发言","assistant":"角色对该发言的回应"}';
      if (this.appPreferences !== null) {
        try {
          const guide: string = await this.appPreferences.getString(CONTINUE_GUIDE_KEY, '');
          if (guide.trim().length > 0) {
            continueContent += '\n\n额外引导：' + guide.trim();
          }
        } catch (e) {
          Logger.warn(LOG_TAG, 'load continue guide failed: '
            + (e instanceof Error ? e.message : String(e)));
        }
      }
      const continueSystem: ChatMessage = {
        id: 'sys-auto-continue',
        role: ChatRole.System,
        content: continueContent,
        createdAt: Date.now(),
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.ExternalSystem
      };
      const requestMessages: ChatMessage[] = [...baseMessages, continueSystem];

      const settings: EffectiveGenerationSettings = snapshot.generationSettings;
      const request: ChatRequest = {
        model: modelName,
        messages: requestMessages,
        temperature: settings.temperature !== undefined ? settings.temperature : 0.8,
        topP: settings.topP !== undefined ? settings.topP : 0.9,
        maxTokens: settings.maxOutputTokens !== undefined ? settings.maxOutputTokens : 4096,
        stream: false
      };

      // 3. 单次非流式调用
      const response: ChatResponse = await this.modelService.sendChat(request);
      Logger.info(LOG_TAG, 'autoContinue raw response len=' + response.content.length);
      const parsed: AutoContinueTurn | null =
        this.parseAutoContinueTurn(response.content);
      if (parsed === null || parsed.user.trim().length === 0
        || parsed.assistant.trim().length === 0) {
        callbacks.onError('续写生成失败,请重试');
        this.setState(ChatState.Failed, callbacks);
        return;
      }

      // 4. 以最终状态一次性落地用户 + 角色
      const userMsg: ChatMessage = {
        id: 'msg-' + generateUuid(),
        role: ChatRole.User,
        content: parsed.user.trim(),
        createdAt: Date.now(),
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.Conversation
      };
      const assistantId: string = 'msg-' + generateUuid();
      const assistantMsg: ChatMessage = {
        id: assistantId,
        role: ChatRole.Assistant,
        content: parsed.assistant.trim(),
        createdAt: Date.now(),
        isStreaming: false,
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.Conversation,
        senderType: 'character',
        senderCharacterId: this.character !== null ? this.character.id : ''
      };

      if (this.persistenceService !== null) {
        const appendResult: AppendUserAndAssistantResult =
          await this.persistenceService.appendUserAndStreamingAssistant(
            this.currentChatId, userMsg, assistantMsg
          );
        this.currentSequenceNumber = appendResult.assistantSequenceNumber;
      }

      this.messages = [...this.messages, userMsg, assistantMsg];
      this.currentAssistantId = assistantId;
      this.setState(ChatState.Completed, callbacks);
      this.emitMessages(callbacks);
      this.persistChatActivity();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'autoContinue failed: ' + msg);
      this.setState(ChatState.Failed, callbacks);
      callbacks.onError('续写生成失败,请重试');
    }
  }

  /**
   * 解析续写响应:优先 JSON 对象 {"user":...,"assistant":...},回退按关键词切分。
   * @returns 解析出的 (user, assistant) 两段;无法解析时返回 null
   */
  private parseAutoContinueTurn(raw: string): AutoContinueTurn | null {
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      return null;
    }
    // 优先 JSON
    const jsonStart: number = trimmed.indexOf('{');
    const jsonEnd: number = trimmed.lastIndexOf('}');
    if (jsonStart >= 0 && jsonEnd > jsonStart) {
      const jsonStr: string = trimmed.substring(jsonStart, jsonEnd + 1);
      try {
        const obj: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;
        const u: string = typeof obj['user'] === 'string' ? obj['user'] as string : '';
        const a: string = typeof obj['assistant'] === 'string' ? obj['assistant'] as string : '';
        if (u.trim().length > 0 || a.trim().length > 0) {
          return { user: u, assistant: a };
        }
      } catch (_e) {
        // JSON 解析失败,走关键词回退
      }
    }
    // 回退:按 用户发言/角色回应 关键词切分
    const userMarkers: string[] = ['用户发言', '"user"', 'user:'];
    const assistMarkers: string[] = ['角色回应', '"assistant"', 'assistant:'];
    for (let i = 0; i < userMarkers.length; i++) {
      const ui: number = trimmed.indexOf(userMarkers[i]);
      if (ui < 0) {
        continue;
      }
      let start: number = ui + userMarkers[i].length;
      if (start < trimmed.length
        && (trimmed.charAt(start) === '：' || trimmed.charAt(start) === ':')) {
        start++;
      }
      let bestAssist: number = -1;
      let bestAssistLen: number = 0;
      for (let j = 0; j < assistMarkers.length; j++) {
        const ai: number = trimmed.indexOf(assistMarkers[j], start);
        if (ai >= 0 && (bestAssist < 0 || ai < bestAssist)) {
          bestAssist = ai;
          bestAssistLen = assistMarkers[j].length;
        }
      }
      if (bestAssist < 0) {
        continue;
      }
      const userText: string = trimmed.substring(start, bestAssist).trim();
      let asStart: number = bestAssist + bestAssistLen;
      if (asStart < trimmed.length
        && (trimmed.charAt(asStart) === '：' || trimmed.charAt(asStart) === ':')) {
        asStart++;
      }
      const assistantText: string = trimmed.substring(asStart).trim();
      if (userText.length > 0 || assistantText.length > 0) {
        return { user: userText, assistant: assistantText };
      }
    }
    return null;
  }

  /**
   * Narrator: 用户输入旁白文本,AI 以旁白身份回复。
   *
   * 流程:
   * 1. 创建 role=System, senderType='narrator' 的旁白消息
   * 2. 创建 role=Assistant, senderType='narrator' 的 Streaming 占位
   * 3. 注入旁白指令,AI 以叙述者视角回复
   */
  async narratorMessage(content: string, callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (content.trim().length === 0) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'narratorMessage rejected: busy');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }

    this.lastCallbacks = callbacks;
    this.generationOperationId++;

    const narratorMsg: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.System,
      content: content,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation,
      senderType: 'narrator',
      includeInMemory: false
    };

    const assistantId: string = 'msg-' + generateUuid();
    const assistantMsg: ChatMessage = {
      id: assistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation,
      senderType: 'narrator',
      senderCharacterId: '',
      includeInMemory: false
    };

    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        const result =
          await this.persistenceService.appendUserAndStreamingAssistant(
            this.currentChatId, narratorMsg, assistantMsg
          );
        this.currentSequenceNumber = result.assistantSequenceNumber;
        this.lastPersistedContentLength = 0;
        this.pendingPersistAssistantId = assistantId;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.error(LOG_TAG, 'narratorMessage persist failed: ' + msg);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('消息保存失败,请重试');
        return;
      }
    }

    this.messages = [...this.messages, narratorMsg, assistantMsg];
    this.currentAssistantId = assistantId;
    this.activeGeneration = {
      operationId: this.generationOperationId,
      kind: ChatGenerationKind.Narrator,
      chatId: this.currentChatId,
      assistantMessageId: assistantId
    };
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);
    this.doStream(assistantId, callbacks, this.activeGeneration);
  }

  /**
   * Narrator-Only: 仅插入旁白描述消息,不触发 AI 生成。
   */
  async narratorMessageOnly(content: string, callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (content.trim().length === 0) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'narratorMessageOnly rejected: busy');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }

    this.lastCallbacks = callbacks;
    this.generationOperationId++;

    const narratorMsg: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.System,
      content: content,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation,
      senderType: 'narrator',
      includeInMemory: false
    };

    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        const seq: number =
          await this.persistenceService.appendMessage(
            this.currentChatId, narratorMsg
          );
        this.currentSequenceNumber = seq;
      } catch (e) {
        const msg: string = e instanceof Error ? e.message : String(e);
        Logger.error(LOG_TAG, 'narratorMessageOnly persist failed: ' + msg);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('消息保存失败,请重试');
        return;
      }
    }

    this.messages = [...this.messages, narratorMsg];
    this.emitMessages(callbacks);
  }

  /**
   * 标记消息是否计入记忆摘要。
   */
  async markMessageIncludeInMemory(messageId: string, include: boolean): Promise<void> {
    if (this.disposed) {
      return;
    }
    const idx: number = this.findMessageIndexById(messageId);
    if (idx < 0) {
      return;
    }
    const msg: ChatMessage = this.messages[idx];
    const updated: ChatMessage = mergeChatMessage(msg, { includeInMemory: include });
    this.messages[idx] = updated;
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      try {
        await this.persistenceService.updateMessage(messageId, updated);
      } catch (e) {
        Logger.error(LOG_TAG, 'markMessageIncludeInMemory failed: ' + String(e));
      }
    }
  }

  private findMessageIndexById(messageId: string): number {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        return i;
      }
    }
    return -1;
  }

  private findLastAssistantIndex(): number {
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.Assistant) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 重新生成最后一条 Assistant 回复(T-6.4B-1.2: 创建 Conversation Branch)。
   *
   * 不再创建 MessageSwipeCandidate,改为:
   * 1. 找到目标 Assistant 前一条 User 消息作为 fork point
   * 2. 创建新的 Conversation Branch(同级或子级)
   * 3. 新 Branch 继承 fork point 之前及本身的路径,不继承旧 Assistant
   * 4. 在新 Branch 中创建新的 Streaming Assistant Message
   * 5. 启动 Provider,流式内容只写入新 Assistant Message
   * 6. 原 Branch、原 Assistant Message、原 Candidate 数据保持不变
   *
   * T-6.3: 与 send / swipe browse / session op 互斥(通过 isBusy)。
   */
  async regenerateLastResponse(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed, cannot regenerate');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'regenerateLastResponse rejected: busy state=' + this.state
        + ' swipeOp=' + this.swipeOperationInProgress.toString()
        + ' sessionOp=' + this.sessionOperationInProgress.toString());
      return;
    }
    if (!this.canRegenerate()) {
      return;
    }

    this.lastCallbacks = callbacks;
    await this.regenerateAsBranch(callbacks);
  }

  /**
   * T-6.4B-1.2: 重新生成为新 Conversation Branch。
   *
   * 流程:
   * 1. 找到目标 Assistant 前一条 User 消息作为 fork point
   * 2. 判断同级 Branch:
   *    - 当前 Active Branch 的 forkMessageId === forkUserMessageId → 同级
   *      (parent = activeBranch.parentBranchId)
   *    - 否则 → 子级 (parent = activeBranch.id)
   * 3. 创建新的 Streaming Assistant Message
   * 4. 调用 forkForRegeneration 在单一事务中创建新 Branch + 复制 Links + 插入 Assistant
   * 5. 重载 messages / swipeSummaries / branchState
   * 6. 建立 BranchRegeneration ActiveGenerationContext
   * 7. 调用 doStream 启动 Provider
   *
   * 失败处理:
   * - 事务失败:不创建半成品 Branch,不启动 Provider,不修改当前 Active Branch
   * - 显示错误提示
   *
   * 不修改:
   * - 原 Branch 的 Message Link
   * - 原 Assistant Message
   * - 旧 MessageSwipeCandidate 数据
   */
  private async regenerateAsBranch(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (this.lastAssistantMessageId.length === 0) {
      callbacks.onError('没有可重新生成的回复');
      return;
    }

    const chatId: string = this.currentChatId;
    const targetAssistantId: string = this.lastAssistantMessageId;

    // 1. 在 this.messages 中找到目标 Assistant,并向前查找最近的 User 消息
    let assistantIndex: number = -1;
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].id === targetAssistantId) {
        assistantIndex = i;
        break;
      }
    }
    if (assistantIndex < 0) {
      callbacks.onError('找不到目标回复');
      return;
    }
    let forkUserMessageId: string = '';
    for (let i = assistantIndex - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        forkUserMessageId = this.messages[i].id;
        break;
      }
    }
    if (forkUserMessageId.length === 0) {
      callbacks.onError('找不到原始用户消息');
      return;
    }

    // 2. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 3. 解析新 Branch 的 parent:
    //    fork 点在 Active Branch 自有消息区间 → 子级(parent = Active Branch);
    //    fork 点在复制前缀(回到祖先对话线)→ 挂到对应祖先,避免布局层级错位
    const parentBranchId: string =
      await this.branchPersistenceService.resolveForkParentBranchId(
        chatId, activeBranch.id, forkUserMessageId
      );

    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, forkUserMessageId, callbacks
    );
  }

  /**
   * T-6.4B-1.2 / T-6.4B-2 公共:从指定 User Message fork 新 Branch 并启动流式生成。
   *
   * 调用方负责:
   * - 校验 disposed / isBusy / persistenceService / branchPersistenceService
   * - 解析 forkUserMessageId(从 lastAssistant 前找,或直接传入历史 User 消息 ID)
   * - 解析 parentBranchId(同级 vs 子级,基于 activeBranch.forkMessageId)
   *
   * 本方法负责:
   * 1. 创建新 Streaming Assistant Message
   * 2. 调用 forkForRegeneration 在单一事务中创建 Branch + 复制 Links + 插入 Assistant
   * 3. 重载 messages / swipeSummaries / branchState
   * 4. 建立 BranchRegeneration ActiveGenerationContext
   * 5. 调用 doStream 启动 Provider
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  private async forkAndStreamFromUser(
    chatId: string,
    sourceBranchId: string,
    parentBranchId: string,
    forkUserMessageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    // 1. 创建新的 Streaming Assistant Message
    this.generationOperationId++;
    const operationId: number = this.generationOperationId;
    const newAssistantId: string = 'msg-' + generateUuid();
    const newAssistantMessage: ChatMessage = {
      id: newAssistantId,
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 2. 占用 Branch 操作互斥锁(保护事务 + reload 期间不被并发)
    this.branchOperationInProgress = true;
    let newBranchSummary: ConversationBranchSummary;
    try {
      newBranchSummary = await this.branchPersistenceService!.forkForRegeneration(
        chatId,
        sourceBranchId,
        parentBranchId,
        forkUserMessageId,
        newAssistantMessage
      );
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'forkAndStreamFromUser forkForRegeneration failed: ' + msg);
      this.branchOperationInProgress = false;
      callbacks.onError('创建分支失败,请重试');
      return;
    }

    // 3. 事务成功,重载内存状态(新 Branch 已成为 Active)
    try {
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'forkAndStreamFromUser reload failed: ' + msg);
      // Branch 已创建,继续执行生成,UI 状态可能与 DB 不一致但可恢复
    }

    // 3.5 修正 reload 丢失的 isStreaming 状态
    // reloadCurrentSession 从数据库加载 messages,数据库不保存 isStreaming=true,
    // 导致 placeholder 的 isStreaming 被重置为 false。
    // 在 emitMessages 之前修正 placeholder 为 Streaming 状态,确保 UI 正确显示打字机效果。
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === newAssistantId) {
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          isStreaming: true,
          status: ChatMessageStatus.Streaming
        });
      }
      return msg;
    });

    // 4. 建立 BranchRegeneration 活动上下文
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.BranchRegeneration,
      chatId: chatId,
      assistantMessageId: newAssistantId,
      branchId: newBranchSummary.id,
      forkMessageId: forkUserMessageId
    };

    // 5. 设置当前 Assistant ID 和持久化追踪
    this.currentAssistantId = newAssistantId;
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = newAssistantId;

    // 6. 释放 Branch 操作锁(后续通过 isBusy / activeGeneration 互斥)
    this.branchOperationInProgress = false;

    // 7. 进入 Sending 状态,通知 UI
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 8. 启动 Provider
    this.doStream(newAssistantId, callbacks, this.activeGeneration);
  }

  /**
   * 是否可重新生成。
   */
  canRegenerate(): boolean {
    if (this.state === ChatState.Sending || this.state === ChatState.Streaming) {
      return false;
    }
    // 至少有一条非 firstMessage 的 Assistant 消息
    return this.lastAssistantMessageId.length > 0;
  }

  /**
   * 停止当前生成。
   * T-6.3: 统一迟到回调防护,持久化最终 Cancelled 状态后才清理上下文。
   * 幂等:连续调用两次不会重复标记或写入。
   */
  stopGeneration(): void {
    // 捕获当前 operationId,用于清理时校验
    const expectedOperationId: number = this.generationOperationId;
    this.clearStartTimer();
    // 递增操作标识,拒绝后续迟到回调
    this.generationOperationId++;
    if (this.currentHandle !== null) {
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    if (this.state === ChatState.Sending || this.state === ChatState.Streaming) {
      const ctx: ActiveGenerationContext | null = this.activeGeneration;
      // 不调用 flushPersistence() — persistFinalAssistant 已包含完整最终状态,
      // 避免与 persistFinalAssistant 嵌套事务冲突(T-6.4A-R3)
      // 将当前 Assistant 消息标记为已取消(创建新对象和新数组)
      this.markAssistant(this.currentAssistantId, ChatMessageStatus.Cancelled, undefined, undefined);
      this.emitMessages(this.lastCallbacks);
      // 持久化最终 Cancelled 状态,完成后才清理上下文
      this.persistFinalAssistant(this.currentAssistantId).then((): void => {
        // Swipe 候选处理:更新摘要生成标志
        if (ctx !== null && ctx.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间(完成一次新生成)
        this.persistChatActivity();
        // 持久化后才清理活动上下文
        this.clearActiveGeneration(expectedOperationId);
        this.currentAssistantId = null;
        this.setState(ChatState.Cancelled, this.lastCallbacks);
      }).catch((_e: Object): void => {
        this.clearActiveGeneration(expectedOperationId);
        this.currentAssistantId = null;
        this.setState(ChatState.Cancelled, this.lastCallbacks);
      });
    }
  }

  /**
   * 是否正在生成。
   */
  isGenerating(): boolean {
    return this.state === ChatState.Sending || this.state === ChatState.Streaming;
  }

  /**
   * 是否正在执行 Swipe 浏览/切换操作(非生成)。
   * T-6.3: 用于和生成互斥。
   */
  isSwipeOperating(): boolean {
    return this.swipeOperationInProgress;
  }

  /**
   * 是否处于忙碌状态(生成中或 Swipe 操作中或会话操作中或 Branch 操作中)。
   * T-6.3: 统一忙碌判断,Service 层保护,不依赖按钮禁用。
   * T-6.4B-1: 增加 branchOperationInProgress 互斥。
   */
  isBusy(): boolean {
    return this.isGenerating()
      || this.swipeOperationInProgress
      || this.sessionOperationInProgress
      || this.branchOperationInProgress;
  }

  /**
   * 清空当前对话。如正在生成先停止。
   */
  clearConversation(): void {
    if (this.isGenerating()) {
      this.stopGeneration();
    }
    this.messages = [];
    this.currentAssistantId = null;
    this.setState(ChatState.Idle, this.lastCallbacks);
    this.emitMessages(this.lastCallbacks);
  }

  // ===== T-4.5 多会话操作 =====

  /** 会话操作进行中(防止并发新建/切换/删除) */
  private sessionOperationInProgress: boolean = false;

  /**
   * 列出当前聊天上下文下的会话。
   * - 有角色:使用 character.id 精确查询
   * - 无角色:查询 character_id IS NULL(仅普通助手会话)
   * - 始终排除 archived
   * - 排序:last_message_at DESC → updated_at DESC → id ASC
   * - 默认最多 50 条
   *
   * @returns 会话列表(可能为空)。无 persistenceService 时返回空数组。
   */
  async listSessions(): Promise<Chat[]> {
    if (this.persistenceService === null) {
      return [];
    }
    const characterId: string | undefined =
      this.character !== null ? this.character.id : undefined;
    return await this.persistenceService.listSessionsForContext(characterId);
  }

  /**
   * 新建会话。
   *
   * 流程:
   * 1. 校验:未生成、未在执行其他会话操作
   * 2. flush pending persistence
   * 3. 使用当前角色上下文创建新 Chat
   * 4. 有角色 firstMessage 时只创建一次
   * 5. 设置新的 currentChatId、currentSequenceNumber
   * 6. 用新数组替换 messages
   * 7. 通知 onMessagesChanged
   * 8. 清除上一次生成状态、错误状态和 Token 统计
   *
   * 不会:清空旧 Chat 数据 / 复用旧 chatId / 把旧 messages 写入新 Chat / 重复插入 firstMessage。
   *
   * @throws Error 生成中或会话操作进行中,或持久化失败
   */
  async startNewSession(): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isGenerating()) {
      throw new Error('请先停止当前回复');
    }
    if (this.sessionOperationInProgress) {
      throw new Error('会话操作进行中,请稍候');
    }
    if (this.swipeOperationInProgress) {
      throw new Error('请先完成当前 Swipe 操作');
    }
    this.sessionOperationInProgress = true;
    try {
      this.flushPersistence();
      const characterId: string | undefined =
        this.character !== null ? this.character.id : undefined;
      await this.createNewSession(characterId);
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      this.currentAssistantId = null;
      // 新建会话后重新加载 Swipe 摘要(首条开场白的 alternate_greetings 候选 1..N)
      await this.reloadSwipeStateAfterNewSession();
      this.activeGeneration = null;
      // T-6.4B-1: 新建会话后刷新 Branch 状态
      await this.refreshBranchState();
      this.setState(ChatState.Idle, this.lastCallbacks);
      this.emitMessages(this.lastCallbacks);
    } finally {
      this.sessionOperationInProgress = false;
    }
  }

  /**
   * 切换到指定会话。
   *
   * 流程:
   * 1. 校验:未生成、未在执行其他会话操作
   * 2. 验证 chatId 非空
   * 3. 相同 chatId 直接返回(不重复加载、不重复 firstMessage)
   * 4. flush pending persistence
   * 5. 加载目标会话(自动 normalize interrupted Streaming)
   * 6. 验证目标会话属于当前角色或普通助手上下文
   * 7. 替换 currentChatId、currentSequenceNumber、messages
   * 8. 通知页面更新
   * 9. 清除旧会话的 UI 临时状态
   *
   * 不会:自动发起模型请求 / 信任列表传入的 Chat 对象(在 Service 层再次校验)。
   *
   * @param chatId 目标会话 id
   * @throws Error 生成中、会话操作进行中、chatId 无效、目标不存在、目标不属于当前上下文
   */
  async switchSession(chatId: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isGenerating()) {
      throw new Error('请先停止当前回复');
    }
    if (this.sessionOperationInProgress) {
      throw new Error('会话操作进行中,请稍候');
    }
    if (this.swipeOperationInProgress) {
      throw new Error('请先完成当前 Swipe 操作');
    }
    if (chatId.length === 0) {
      throw new Error('会话 id 为空');
    }
    this.sessionOperationInProgress = true;
    try {
      if (this.currentChatId === chatId) {
        return;
      }
      this.flushPersistence();
      await this.switchToSessionInternal(chatId);
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      this.currentAssistantId = null;
      this.activeGeneration = null;
      this.setState(ChatState.Idle, this.lastCallbacks);
      this.emitMessages(this.lastCallbacks);
    } finally {
      this.sessionOperationInProgress = false;
    }
  }

  /**
   * 删除指定会话。
   *
   * - 删除非当前会话:删除 Chat 和 Message(事务),当前页面消息不变
   * - 删除当前会话:删除后按以下顺序回退:
   *   1. 查询当前上下文剩余会话
   *   2. 存在则加载最近一条
   *   3. 不存在则立即创建一条新会话(有角色 firstMessage 时加入)
   *   4. 页面立即更新为新会话消息
   *
   * @param chatId 待删除的会话 id
   * @throws Error 生成中、会话操作进行中、删除失败
   */
  async deleteSession(chatId: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isGenerating()) {
      throw new Error('请先停止当前回复');
    }
    if (this.sessionOperationInProgress) {
      throw new Error('会话操作进行中,请稍候');
    }
    if (this.swipeOperationInProgress) {
      throw new Error('请先完成当前 Swipe 操作');
    }
    if (chatId.length === 0) {
      throw new Error('会话 id 为空');
    }
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    this.sessionOperationInProgress = true;
    try {
      await this.persistenceService.deleteSession(chatId);

      if (chatId === this.currentChatId) {
        // 删除的是当前会话:查询剩余,自动切换或新建
        const characterId: string | undefined =
          this.character !== null ? this.character.id : undefined;
        const remaining: Chat[] =
          await this.persistenceService.listSessionsForContext(characterId, 50);
        if (remaining.length > 0) {
          // 列表已按 last_message_at DESC 排序,首条为最近会话
          await this.switchToSessionInternal(remaining[0].id);
        } else {
          // 无剩余会话,创建新会话
          await this.createNewSession(characterId);
          // 新建会话后重新加载 Swipe 摘要与 lastAssistantMessageId(首条开场白候选)
          await this.reloadSwipeStateAfterNewSession();
        }
        this.lastTokenBudget = undefined;
        this.lastHistoryTrimResult = undefined;
        this.currentAssistantId = null;
        this.activeGeneration = null;
        // T-6.4B-1: 删除会话后刷新 Branch 状态
        await this.refreshBranchState();
        this.setState(ChatState.Idle, this.lastCallbacks);
        this.emitMessages(this.lastCallbacks);
      }
    } finally {
      this.sessionOperationInProgress = false;
    }
  }

  /**
   * 是否正在执行会话操作(新建/切换/删除)。
   * 用于页面禁用按钮。
   */
  isSessionOperationInProgress(): boolean {
    return this.sessionOperationInProgress;
  }

  /**
   * 内部:切换到指定会话并替换当前状态(不持锁,由调用方持锁)。
   * 验证目标会话属于当前角色或普通助手上下文。
   */
  private async switchToSessionInternal(chatId: string): Promise<void> {
    if (this.persistenceService === null) {
      throw new Error('persistenceService unavailable');
    }
    const session: PersistedChatSession | null =
      await this.persistenceService.loadSession(chatId);
    if (session === null) {
      throw new Error('会话不存在或已删除');
    }
    // 验证上下文归属
    const expectedCharId: string | undefined =
      this.character !== null ? this.character.id : undefined;
    const actualCharId: string | undefined = session.chat.characterId;
    if (expectedCharId !== actualCharId) {
      throw new Error('目标会话不属于当前聊天上下文');
    }
    this.currentChatId = session.chat.id;
    this.currentChat = session.chat;
    this.messages = session.messages.slice();
    this.currentSequenceNumber = session.maxSequenceNumber;
    // 加载 Swipe summaries
    this.swipeSummaries = [];
    this.lastAssistantMessageId = '';
    if (this.swipePersistenceService !== null && this.currentChatId !== undefined) {
      this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
    }
    this.updateLastAssistantMessageId();
    // CHAT-STATUS-1A: 切换会话后加载该会话的角色状态
    this.syncStatusStateFromCurrentChat();
    // T-6.4B-1: 切换会话后刷新 Branch 状态
    await this.refreshBranchState();
  }

  /**
   * 获取当前消息列表(副本)。
   */
  getMessages(): ChatMessage[] {
    return this.messages.slice();
  }

  /**
   * 获取当前会话绑定的角色(只读)。
   * 供世界书面板等场景读取角色专属世界书关联(characterBookId)。
   */
  getCharacter(): Character | null {
    return this.character;
  }

  // ===== CHAT-STATUS-1A: 角色状态 =====

  /**
   * 获取当前会话的角色状态(只读)。
   */
  getChatStatusState(): ChatStatusState {
    return this.currentStatusState;
  }

  /**
   * CHAT-STATUS-1A: 请求下一次回复重新生成/优化角色状态字段。
   * 由"AI 生成"按钮调用,在下一轮 buildStatusInstruction 时生效,回复完成后复位。
   */
  requestStatusFieldGeneration(): void {
    this.statusFieldGenerationRequested = true;
  }

  /**
   * 整态替换角色状态(字段增删改锁等操作后由 ViewModel 调用)。
   * 校验、持久化并通知 UI。
   */
  updateStatusState(next: ChatStatusState): void {
    this.currentStatusState = next;
    this.persistStatusConfig();
    this.emitStatusChanged(this.lastCallbacks);
  }

  /**
   * 从当前会话的 statusConfigJson 同步内存状态。
   * 会话初始化 / 切换 / 新建后调用。
   */
  private syncStatusStateFromCurrentChat(): void {
    if (this.currentChat !== null) {
      this.currentStatusState = parseChatStatusState(this.currentChat.statusConfigJson);
    } else {
      this.currentStatusState = createEmptyChatStatusState();
    }
  }

  /**
   * 合并 AI 本轮输出的状态字段(纯计算,不修改状态)。
   * - 已存在字段:更新值,保留 fromUser/locked
   * - 新字段:追加(fromUser=false, locked=false)
   * - 未输出且 locked 的旧字段:保留
   * - 未输出且未锁定的旧字段:删除(允许 AI 优化删减字段)
   */
  private computeMergedStatus(parsedEntries: ChatStatusEntry[]): ChatStatusState {
    const oldEntries: ChatStatusEntry[] = this.currentStatusState.entries;
    const nextEntries: ChatStatusEntry[] = [];
    const matchedNames: string[] = [];
    for (let i = 0; i < oldEntries.length; i++) {
      const old: ChatStatusEntry = oldEntries[i];
      const match: ChatStatusEntry | null = findStatusEntryByName(parsedEntries, old.name);
      if (match !== null) {
        nextEntries.push(createChatStatusEntry(old.name, match.value, old.fromUser, old.locked));
        matchedNames.push(old.name);
      } else if (old.locked) {
        nextEntries.push(createChatStatusEntry(old.name, old.value, old.fromUser, old.locked));
      }
      // 未锁定且本轮未输出的字段:删除
    }
    for (let i = 0; i < parsedEntries.length; i++) {
      const p: ChatStatusEntry = parsedEntries[i];
      if (matchedNames.indexOf(p.name) < 0) {
        nextEntries.push(createChatStatusEntry(p.name, p.value, false, false));
      }
    }
    return { entries: nextEntries };
  }

  /**
   * 合并 AI 本轮输出的状态字段并持久化、通知 UI(流式回复完成路径)。
   */
  private applyStatusUpdate(
    parsedEntries: ChatStatusEntry[],
    callbacks: ChatServiceCallbacks
  ): void {
    this.currentStatusState = this.computeMergedStatus(parsedEntries);
    // 消耗一次性"重新生成字段"请求
    this.statusFieldGenerationRequested = false;
    this.persistStatusConfig();
    this.emitStatusChanged(callbacks);
  }

  /**
   * CHAT-STATUS-1A: 立即生成/优化角色状态字段(点击"AI 生成"按钮,独立的一次性请求)。
   *
   * - 不经过正常聊天消息流,不写入聊天历史
   * - 用角色信息 + 状态生成指令构造一次短请求,流式完成后解析状态块并合并
   * - 返回合并后的状态;失败返回 null(不修改现有状态)
   *
   * @returns 合并后的状态,失败返回 null
   */
  async generateStatusFieldsNow(): Promise<ChatStatusState | null> {
    if (this.disposed) {
      return null;
    }
    if (this.isBusy()) {
      return null;
    }
    if (this.statusGenerationInProgress) {
      return null;
    }
    if (this.character === null) {
      return null;
    }
    if (this.modelService === null) {
      return null;
    }
    this.statusGenerationInProgress = true;
    try {
      const messages: ChatMessage[] = [];
      const systemContent: string = buildCharacterSystemContent(this.character);
      if (systemContent.length > 0) {
        messages.push(createChatMessage(generateUuid(), ChatRole.System, systemContent, Date.now()));
      }
      // 强制使用"重新生成"指令(优先于状态维护指令)
      const wasRequested: boolean = this.statusFieldGenerationRequested;
      this.statusFieldGenerationRequested = true;
      const instruction: string = this.buildStatusInstruction();
      this.statusFieldGenerationRequested = wasRequested;
      if (instruction.length > 0) {
        messages.push(createChatMessage(generateUuid(), ChatRole.System, instruction, Date.now()));
      }
      // 附上最近的对话上下文,让字段贴合当前剧情
      this.appendRecentContextForStatus(messages);
      messages.push(createChatMessage(generateUuid(), ChatRole.User, '请根据角色信息与对话内容生成角色状态。', Date.now()));

      const options: ChatRequestOptions = {
        temperature: 0.6,
        topP: 1.0,
        maxTokens: 512,
        stream: true,
        responseFormatJson: true
      };

      return await new Promise<ChatStatusState | null>((resolve: Function): void => {
        let settled: boolean = false;
        const finish = (result: ChatStatusState | null): void => {
          if (!settled) {
            settled = true;
            resolve(result);
          }
        };
        const callbacks: ChatStreamCallbacks = {
          onDelta: (_delta: ChatDelta): void => {
            // 用 onComplete 的 result.content 做最终解析,忽略中间 delta
          },
          onComplete: (result: ChatStreamResult): void => {
            const extraction = extractStatusBlock(result.content);
            if (extraction.parsedEntries.length === 0) {
              Logger.warn(LOG_TAG, 'generateStatusFieldsNow: no valid status block parsed, content=' +
                result.content.substring(0, 200));
              finish(null);
              return;
            }
            this.currentStatusState = this.computeMergedStatus(extraction.parsedEntries);
            this.statusFieldGenerationRequested = false;
            this.persistStatusConfig();
            finish(this.currentStatusState);
          },
          onError: (e: NetworkError): void => {
            Logger.warn(LOG_TAG, 'generateStatusFieldsNow: stream error=' +
              (e.message !== undefined ? e.message : String(e)));
            finish(null);
          }
        };
        try {
          this.modelService!.streamCurrentChat(messages, options, callbacks);
        } catch (e) {
          finish(null);
        }
      });
    } finally {
      this.statusGenerationInProgress = false;
    }
  }

  /**
   * CHAT-STATUS-1A: 按用户指令立即修改角色状态字段(「AI 修改状态」,独立的一次性请求)。
   *
   * - 不经过正常聊天消息流,不写入聊天历史
   * - 用角色信息 + 标准状态输出指令 + 用户指令构造一次短请求,流式完成后解析状态块并合并
   * - 返回合并后的状态;失败返回 null(不修改现有状态)
   *
   * 说明:不使用 responseFormatJson(强制 JSON 会与 <|status|> 标记块指令冲突,
   * 导致模型输出不可解析),让模型按标记块格式输出,并提供整段 JSON 兜底解析。
   *
   * @param prompt 用户修改指令(如"把地点改成森林")
   * @returns 合并后的状态,失败返回 null
   */
  async modifyStatusWithPrompt(prompt: string): Promise<ChatStatusState | null> {
    if (this.disposed) {
      return null;
    }
    if (this.isBusy()) {
      return null;
    }
    if (this.statusGenerationInProgress) {
      return null;
    }
    if (this.character === null) {
      return null;
    }
    if (this.modelService === null) {
      return null;
    }
    const trimmedPrompt: string = prompt.trim();
    if (trimmedPrompt.length === 0) {
      return null;
    }
    this.statusGenerationInProgress = true;
    try {
      const messages: ChatMessage[] = [];
      const systemContent: string = buildCharacterSystemContent(this.character);
      if (systemContent.length > 0) {
        messages.push(createChatMessage(generateUuid(), ChatRole.System, systemContent, Date.now()));
      }
      // 使用标准"维护字段"指令(临时忽略一次性"重新生成"请求,避免指令冲突)
      const wasRequested: boolean = this.statusFieldGenerationRequested;
      this.statusFieldGenerationRequested = false;
      const instruction: string = this.buildStatusInstruction();
      this.statusFieldGenerationRequested = wasRequested;
      if (instruction.length > 0) {
        messages.push(createChatMessage(generateUuid(), ChatRole.System, instruction, Date.now()));
      }
      this.appendRecentContextForStatus(messages);
      messages.push(createChatMessage(
        generateUuid(),
        ChatRole.User,
        '请按以下要求修改角色状态,并输出更新后的完整状态块:\n' + trimmedPrompt,
        Date.now()
      ));

      const options: ChatRequestOptions = {
        temperature: 0.6,
        topP: 1.0,
        maxTokens: 512,
        stream: true
      };

      return await new Promise<ChatStatusState | null>((resolve: Function): void => {
        let settled: boolean = false;
        const finish = (result: ChatStatusState | null): void => {
          if (!settled) {
            settled = true;
            resolve(result);
          }
        };
        const callbacks: ChatStreamCallbacks = {
          onDelta: (_delta: ChatDelta): void => {
            // 用 onComplete 的 result.content 做最终解析,忽略中间 delta
          },
          onComplete: (result: ChatStreamResult): void => {
            const extraction = extractStatusBlock(result.content);
            if (extraction.parsedEntries.length === 0) {
              // 兜底:若标记块/围栏/裸 JSON 均未解析出字段,尝试把整段响应作为 JSON 对象解析
              const fallbackEntries: ChatStatusEntry[] = parseStatusJsonWhole(result.content);
              if (fallbackEntries.length > 0) {
                this.currentStatusState = this.computeMergedStatus(fallbackEntries);
                this.persistStatusConfig();
                finish(this.currentStatusState);
                return;
              }
              Logger.warn(LOG_TAG, 'modifyStatusWithPrompt: no valid status block parsed');
              finish(null);
              return;
            }
            this.currentStatusState = this.computeMergedStatus(extraction.parsedEntries);
            this.persistStatusConfig();
            finish(this.currentStatusState);
          },
          onError: (e: NetworkError): void => {
            Logger.warn(LOG_TAG, 'modifyStatusWithPrompt: stream error=' + String(e.message));
            finish(null);
          }
        };
        try {
          this.modelService!.streamCurrentChat(messages, options, callbacks);
        } catch (e) {
          finish(null);
        }
      });
    } finally {
      this.statusGenerationInProgress = false;
    }
  }

  /**
   * CHAT-STATUS-1A: 把最近的用户/助手对话按正序追加到消息列表末尾(供状态生成使用)。
   * 最多取最近 6 条非空对话,跳过 System 消息。
   */
  private appendRecentContextForStatus(messages: ChatMessage[]): void {
    const MAX_RECENT: number = 6;
    const recent: ChatMessage[] = [];
    for (let i = this.messages.length - 1; i >= 0 && recent.length < MAX_RECENT; i--) {
      const m: ChatMessage = this.messages[i];
      if ((m.role === ChatRole.User || m.role === ChatRole.Assistant) && m.content.length > 0) {
        recent.push(m);
      }
    }
    for (let i = recent.length - 1; i >= 0; i--) {
      messages.push(createChatMessage(generateUuid(), recent[i].role, recent[i].content, Date.now()));
    }
  }

  /**
   * 持久化当前状态到当前会话(fire-and-forget)。
   */
  private persistStatusConfig(): void {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const chatId: string = this.currentChatId;
    const json: string = serializeChatStatusState(this.currentStatusState);
    this.persistenceService.updateChatStatusConfig(chatId, json).then((updated: Chat): void => {
      this.currentChat = updated;
    }).catch((e: Object): void => {
      Logger.warn(LOG_TAG, 'persistStatusConfig failed: '
        + (e instanceof Error ? e.message : String(e)));
    });
  }

  /**
   * 通知角色状态变更。
   */
  private emitStatusChanged(callbacks: ChatServiceCallbacks | null): void {
    if (callbacks === null || callbacks.onStatusChanged === undefined) {
      return;
    }
    try {
      callbacks.onStatusChanged(this.currentStatusState);
    } catch (e) {
      Logger.warn(LOG_TAG, 'onStatusChanged threw: '
        + (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 设置状态输出指令开关。
   * @param enabled true=注入状态指令(AI 返回状态 JSON);false=不注入,AI 只返回纯正文
   */
  setStatusInstructionEnabled(enabled: boolean): void {
    this.statusInstructionEnabled = enabled;
    if (this.appPreferences !== null) {
      this.appPreferences.putString(STATUS_INSTRUCTION_PREFS_KEY, enabled ? 'true' : 'false')
        .then((): void => {}).catch((_e: Object): void => {});
    }
  }

  /**
   * 获取状态输出指令开关状态。
   */
  isStatusInstructionEnabled(): boolean {
    return this.statusInstructionEnabled;
  }

  private async loadStatusInstructionPref(): Promise<void> {
    if (this.appPreferences === null) {
      return;
    }
    try {
      const val: string = await this.appPreferences.getString(STATUS_INSTRUCTION_PREFS_KEY, 'true');
      this.statusInstructionEnabled = val !== 'false';
    } catch (_e) {
      this.statusInstructionEnabled = true;
    }
  }

  /**
   * 加载世界书全局默认激活方式与深度注入偏好。
   * 在会话初始化时调用(全局,跨会话)。
   */
  private async loadLorebookPrefs(): Promise<void> {
    if (this.appPreferences === null) {
      return;
    }
    try {
      const modeVal: string = await this.appPreferences.getString(
        LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY, '');
      if (modeVal === LorebookActivationMode.FullInject
        || modeVal === LorebookActivationMode.OnDemand) {
        this.lorebookActivationDefault = modeVal as LorebookActivationMode;
      } else {
        this.lorebookActivationDefault = DEFAULT_LOREBOOK_ACTIVATION_MODE;
      }
    } catch (_e) {
      this.lorebookActivationDefault = DEFAULT_LOREBOOK_ACTIVATION_MODE;
    }
    try {
      const depthStr: string = await this.appPreferences.getString(
        LOREBOOK_INJECTION_DEPTH_PREFS_KEY, '');
      const parsed: number = Number(depthStr);
      this.lorebookInjectionDepth = Number.isFinite(parsed) && parsed >= 0 && parsed <= 8
        ? Math.floor(parsed) : DEFAULT_LOREBOOK_INJECTION_DEPTH;
    } catch (_e) {
      this.lorebookInjectionDepth = DEFAULT_LOREBOOK_INJECTION_DEPTH;
    }
  }

  /**
   * 加载记忆关键词检索开关(v44,全局,跨会话)。默认关,保证缓存命中率。
   */
  private async loadMemoryPrefs(): Promise<void> {
    if (this.appPreferences === null) {
      return;
    }
    try {
      const val: string = await this.appPreferences.getString(
        MEMORY_KEYWORD_RETRIEVAL_PREFS_KEY, '');
      this.memoryKeywordRetrievalEnabled = val === 'on';
    } catch (_e) {
      this.memoryKeywordRetrievalEnabled = false;
    }
  }

  /**
   * 设置记忆关键词检索开关并持久化。
   */
  setMemoryKeywordRetrievalEnabled(enabled: boolean): void {
    this.memoryKeywordRetrievalEnabled = enabled;
    if (this.appPreferences !== null) {
      this.appPreferences.putString(MEMORY_KEYWORD_RETRIEVAL_PREFS_KEY, enabled ? 'on' : 'off')
        .then((): void => {}).catch((_e: Object): void => {});
    }
  }

  /**
   * 获取记忆关键词检索开关。
   */
  isMemoryKeywordRetrievalEnabled(): boolean {
    return this.memoryKeywordRetrievalEnabled;
  }

  /**
   * 设置世界书全局默认激活方式并持久化。
   * @param mode FullInject / OnDemand
   */
  setLorebookActivationDefault(mode: LorebookActivationMode): void {
    this.lorebookActivationDefault = mode;
    if (this.appPreferences !== null) {
      this.appPreferences.putString(LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY, mode)
        .then((): void => {}).catch((_e: Object): void => {});
    }
  }

  /**
   * 获取世界书全局默认激活方式。
   */
  getLorebookActivationDefault(): LorebookActivationMode {
    return this.lorebookActivationDefault;
  }

  /**
   * 设置世界书深度注入位置并持久化(0-8)。
   * @param depth 0 表示全部消息之后
   */
  setLorebookInjectionDepth(depth: number): void {
    const clamped: number = Math.max(0, Math.min(8, Math.floor(depth)));
    this.lorebookInjectionDepth = clamped;
    if (this.appPreferences !== null) {
      this.appPreferences.putString(LOREBOOK_INJECTION_DEPTH_PREFS_KEY, String(clamped))
        .then((): void => {}).catch((_e: Object): void => {});
    }
  }

  /**
   * 获取世界书深度注入位置。
   */
  getLorebookInjectionDepth(): number {
    return this.lorebookInjectionDepth;
  }

  /**
   * Prompt Cache:手动触发记忆总结。
   * 无论 memoryAutoSummaryEnabled 是否开启,都强制生成一个详细章节并同步更新核心记忆。
   * 总结完成后 Memory 段内容更新,但后续请求中 Memory 段将保持稳定直到下次手动触发。
   */
  triggerManualMemorySummary(): void {
    if (this.memoryService === null) {
      return;
    }
    if (this.currentChatId === undefined || this.currentChatId.length === 0) {
      return;
    }
    if (this.activeBranchId.length === 0) {
      return;
    }
    const chatId: string = this.currentChatId;
    const branchId: string = this.activeBranchId;
    const branchMessages: ChatMessage[] = this.messages.slice();
    // 不 await:后台执行,失败仅记录日志
    this.memoryService.forceGenerateChapterMemory(chatId, branchId, branchMessages)
      .then((result: MemorySummaryResult): void => {
        if (!result.success) {
          Logger.warn(LOG_TAG, 'ManualMemorySummary | forced chapter failed'
            + (result.error !== undefined ? ' err=' + result.error : ''));
        } else {
          this.notifyMemoryChanged();
          // v8.4: 窗口锚点由章节边界与保留条数动态派生,总结成功后无需额外持久化
        }
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'ManualMemorySummary | forced chapter exception: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * Prompt Cache:设置自动记忆总结开关。
   * @param enabled true=每次 AI 回复后自动触发记忆总结(默认行为,不利于缓存)
   *                false=关闭自动总结,用户需手动触发(推荐,有利于缓存)
   */
  setMemoryAutoSummaryEnabled(enabled: boolean): void {
    this.memoryAutoSummaryEnabled = enabled;
    if (this.appPreferences !== null) {
      this.appPreferences.putString(MEMORY_AUTO_SUMMARY_PREFS_KEY, enabled ? 'true' : 'false')
        .then((): void => {}).catch((_e: Object): void => {});
    }
  }

  isMemoryAutoSummaryEnabled(): boolean {
    return this.memoryAutoSummaryEnabled;
  }

  private async loadMemoryAutoSummaryPref(): Promise<void> {
    if (this.appPreferences === null) {
      return;
    }
    try {
      const val: string = await this.appPreferences.getString(MEMORY_AUTO_SUMMARY_PREFS_KEY, 'false');
      this.memoryAutoSummaryEnabled = val === 'true';
    } catch (_e) {
      this.memoryAutoSummaryEnabled = false;
    }
  }

  /**
   * CHAT-STATUS-1A: 注入角色状态输出指令 system message。
   * 仅当存在用户字段时注入,位置复刻 injectAvatarDialogueStrategy(最后一个 system 之后)。
   */
  private injectStatusInstruction(messages: ChatMessage[]): ChatMessage[] {
    // 状态输出指令开关:关闭时不注入状态指令,AI 只返回纯正文(不返回状态 JSON)
    if (!this.statusInstructionEnabled) {
      return messages;
    }
    const instruction: string = this.buildStatusInstruction();
    if (instruction.length === 0) {
      return messages;
    }
    const statusMessage: ChatMessage = createChatMessage(
      generateUuid(), ChatRole.System, instruction, Date.now()
    );
    let lastSystemIndex: number = -1;
    for (let i = 0; i < messages.length; i++) {
      if (messages[i].role === ChatRole.System) {
        lastSystemIndex = i;
      }
    }
    const result: ChatMessage[] = [];
    if (lastSystemIndex === -1) {
      result.push(statusMessage);
      for (let i = 0; i < messages.length; i++) {
        result.push(messages[i]);
      }
    } else {
      for (let i = 0; i <= lastSystemIndex; i++) {
        result.push(messages[i]);
      }
      result.push(statusMessage);
      for (let i = lastSystemIndex + 1; i < messages.length; i++) {
        result.push(messages[i]);
      }
    }
    return result;
  }

  /**
   * 构建状态输出指令文本。
   * - 请求重新生成:让 AI 重新生成/优化字段
   * - 无字段:让 AI 根据角色信息生成字段
   * - 有字段:保留更新其值,并可优化/新增字段
   */
  private buildStatusInstruction(): string {
    const names: string[] = [];
    const entries: ChatStatusEntry[] = this.currentStatusState.entries;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].name.length > 0) {
        names.push(entries[i].name);
      }
    }
    if (this.statusFieldGenerationRequested) {
      return '【角色状态输出规则】\n' +
        '请仔细阅读角色设定(描述/性格/场景),推断出最能体现该角色当前状态的具体维度。\n' +
        '只输出一个 JSON 对象,不要输出任何其他文字或解释:\n' +
        '{"字段名":"值"}\n' +
        '- 字段名必须贴合该角色的身份、处境与剧情,禁止套用 服装/地点/金币/心情 等通用模板,除非与角色真实相关\n' +
        '- 字段数量 3~6 个\n' +
        '- 值用简短中文短语,基于角色设定与当前对话合理推断';
    }
    if (names.length === 0) {
      return '【角色状态输出规则】\n' +
        '请仔细阅读角色设定(描述/性格/场景),推断出最能体现该角色当前状态的具体维度。在回复正文之后,单独输出一行 JSON 状态块,格式严格如下(正文中不要提及状态块):\n' +
        '<|status|>\n' +
        '{"字段名":"值"}\n' +
        '<|/status|>\n' +
        '- 字段名必须贴合该角色的身份、处境与剧情,禁止套用 服装/地点/金币/心情 等通用模板,除非与角色真实相关\n' +
        '- 字段数量 3~6 个\n' +
        '- 值用简短中文短语,基于角色设定与当前对话合理推断';
    }
    const fieldsText: string = names.join('、');
    return '【角色状态输出规则】\n' +
      '在回复正文之后,单独输出一行 JSON 状态块,格式严格如下(正文中不要提及状态块):\n' +
      '<|status|>\n' +
      '{"字段名":"值"}\n' +
      '<|/status|>\n' +
      '- 保留并更新这些字段:' + fieldsText + ';若剧情发展需要,可增删字段以贴合角色当前处境(总数 3~6 个)\n' +
      '- 字段名应贴合角色设定与剧情,不要套用通用模板\n' +
      '- 值用简短中文短语,基于角色设定与当前对话合理推断\n' +
      '- 每轮都要重新输出,反映最新进展';
  }

  /**
   * 获取最近一次 Prompt 构建的 Token 预算结果。
   * 仅在执行过 sendMessage/regenerateLastResponse 后才有值。
   *
   * @returns TokenBudget 或 undefined(未执行或 Token 统计失败)
   */
  getLastTokenBudget(): TokenBudget | undefined {
    return this.lastTokenBudget;
  }

  /**
   * 获取最近一次历史裁剪结果(只读)。
   * 页面暂时不使用。
   *
   * @returns HistoryTrimResult 或 undefined(未执行或裁剪失败)
   */
  getLastHistoryTrimResult(): HistoryTrimResult | undefined {
    return this.lastHistoryTrimResult;
  }

  /**
   * 获取最近一次构建的请求消息(用于 UI 上下文占用估算)。
   * 反映实际发送给模型的消息(若发生历史裁剪,则为裁剪后的最终消息)。
   */
  getLastBuiltRequestMessages(): ChatMessage[] | undefined {
    return this.lastBuiltRequestMessages;
  }

  /**
   * 主动构建请求消息用于上下文占用估算(不影响实际发送)。
   * 当 lastBuiltRequestMessages 为空时由 UI 调用,使预算指示器在发消息前即可显示。
   */
  async buildEstimateMessages(): Promise<void> {
    if (this.lastBuiltRequestMessages !== undefined) {
      return;
    }
    try {
      const snapshot: PromptPresetRequestSnapshot = await this.createPresetRequestSnapshot();
      this.lastBuiltRequestMessages = await this.buildRequestMessages(snapshot.presetSystemPrompt);
      await this.updateRequestPlan(this.lastBuiltRequestMessages, snapshot.generationSettings);
    } catch (e) {
      Logger.warn(LOG_TAG, 'buildEstimateMessages failed: ' + String(e));
    }
  }

  /**
   * 失效估算缓存,使下次 refreshBudgetSnapshot 重新构建请求消息。
   * 用于预算配置变更(如 recentWindowTarget 调整)后强制重算占用。
   */
  invalidateEstimateCache(): void {
    this.lastBuiltRequestMessages = undefined;
  }

  /**
   * 通知记忆变更,触发 ChatPage 重新计算上下文占用。
   * 记忆生成/更新/删除后调用,递增 chatMemoryVersion 让 ChatPage @Watch 响应。
   */
  private notifyMemoryChanged(): void {
    const v: number = AppStorage.get<number>('chatMemoryVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatMemoryVersion', v + 1);
  }

  /**
   * 释放资源,停止当前请求。dispose 后不可复用。
   * 释放前 flush 任何 pending delta 持久化。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.clearStartTimer();
    this.clearPersistenceTimer();
    if (this.currentHandle !== null) {
      this.currentHandle.abort();
      this.currentHandle = null;
    }
    // flush 任何 pending delta(不等待 Promise,尽力而为)
    this.flushPersistenceSync();
    this.messages = [];
    this.currentAssistantId = null;
    this.lastCallbacks = null;
    this.lastTokenBudget = undefined;
    this.lastHistoryTrimResult = undefined;
    this.lastBuiltRequestMessages = undefined;
    this.activeGeneration = null;
    this.swipeSummaries = [];
    this.state = ChatState.Idle;
  }

  // ===== 内部方法 =====

  /**
   * T-6.3 / T-6.4B-1.2: 统一迟到回调判断。
   * 检查 operationId、kind、chatId、assistantMessageId、(Swipe 时)candidateIndex、
   * (BranchRegeneration 时)branchId 和 forkMessageId。
   * 所有异步路径(delta / scheduled flush / immediate flush / complete / error / stop 后剩余回调
   * / Provider start 失败处理)必须调用本方法。
   */
  private isCurrentGeneration(context: ActiveGenerationContext): boolean {
    const current: ActiveGenerationContext | null = this.activeGeneration;
    if (current === null) {
      return false;
    }
    if (current.operationId !== context.operationId) {
      return false;
    }
    if (current.kind !== context.kind) {
      return false;
    }
    if (current.chatId !== context.chatId) {
      return false;
    }
    if (current.assistantMessageId !== context.assistantMessageId) {
      return false;
    }
    // Swipe 类型需校验 candidateIndex
    if (context.kind === ChatGenerationKind.SwipeCandidate) {
      const ctxIdx: number | undefined = context.swipeCandidateIndex;
      const curIdx: number | undefined = current.swipeCandidateIndex;
      if (ctxIdx !== curIdx) {
        return false;
      }
    }
    // BranchRegeneration 类型需校验 branchId 和 forkMessageId
    if (context.kind === ChatGenerationKind.BranchRegeneration) {
      if (current.branchId !== context.branchId) {
        return false;
      }
      if (current.forkMessageId !== context.forkMessageId) {
        return false;
      }
    }
    return true;
  }

  /**
   * T-6.3: 统一活动生成状态清理。
   * 只有 operationId 匹配时才能清理(防止迟到清理污染下一次生成)。
   * 顺序要求:调用方必须先 persist 最终状态后再调用本方法。
   * 本方法清除:persistence timer、activeGeneration、pending buffer、生成中 UI 状态标记。
   * 幂等:同一 operationId 多次调用安全。
   */
  private clearActiveGeneration(expectedOperationId: number): void {
    const current: ActiveGenerationContext | null = this.activeGeneration;
    if (current === null) {
      return;
    }
    if (current.operationId !== expectedOperationId) {
      return;
    }
    this.clearPersistenceTimer();
    this.pendingPersistAssistantId = null;
    this.pendingSwipePersistPromise = null;
    this.activeGeneration = null;
  }

  private async doStream(
    assistantId: string,
    callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext
  ): Promise<void> {
    // 捕获本次请求的 operationId,用于迟到回调判断
    const operationId: number = context.operationId;

    // 内部辅助:判断当前回调是否仍属于本次生成
    const isCurrent = (): boolean => {
      return this.isCurrentGeneration(context);
    };

    // 内部辅助:Provider start 失败 / 同步异常的统一处理。
    // 必须在标记 Failed 前完成最终状态持久化,然后再清理上下文。
    const handleStartFailure = (errorMessage: string): void => {
      // 上下文已被 stop 或新请求替换时,直接退出,避免污染新请求
      if (!isCurrent()) {
        Logger.warn(LOG_TAG, 'start failure ignored: stale context');
        return;
      }
      // 不调用 flushPersistence() — persistFinalAssistant 已包含完整最终状态,
      // 避免与 persistFinalAssistant 嵌套事务冲突(T-6.4A-R3)
      // 标记 Assistant 为 Failed(同时更新内存消息和 Swipe 候选,路由基于 activeGeneration.kind)
      this.finalizeAssistant(
        assistantId, '', ChatMessageStatus.Failed, errorMessage, callbacks
      );
      this.currentAssistantId = null;
      Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_start_failure');
      // 持久化最终 Failed 状态,完成后才清理上下文
      this.persistFinalAssistant(assistantId).then((): void => {
        Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
        Logger.warn(LOG_TAG, 'generation finalized status=failed');
        // Swipe:更新摘要生成标志
        if (context.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间
        this.persistChatActivity();
        // 清理活动上下文(仅当仍是本次 operationId)
        this.clearActiveGeneration(operationId);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError(errorMessage);
      }).catch((_e: Object): void => {
        this.clearActiveGeneration(operationId);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError(errorMessage);
      });
    };

    const streamCallbacks: ChatStreamCallbacks = {
      onStart: (): void => {
        this.clearStartTimer();
      },
      onDelta: (delta: ChatDelta): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        // 允许 Sending 与 Streaming 状态处理 delta:
        // streamCurrentChat 可能在同步/微任务阶段触发首帧 delta,
        // 此时 setState(Streaming) 尚未执行(state 仍为 Sending),
        // 严格守卫会丢弃所有 delta 导致回复内容为空。
        // 对齐 onComplete(行 1502)的守卫策略。
        if (this.state !== ChatState.Streaming && this.state !== ChatState.Sending) {
          Logger.warn(LOG_TAG, `onDelta DROPPED state=${String(this.state)}`);
          return;
        }
        if (!isCurrent()) {
          Logger.warn(LOG_TAG, 'stale callback ignored type=delta');
          return;
        }
        // T-6.4B-Closeout: 移除 delta 级 Regenerate 高频日志
        this.appendDelta(assistantId, delta.content, callbacks);
        // 节流持久化 delta(路由基于 activeGeneration.kind)
        this.schedulePersistenceFlush(assistantId);
      },
      onComplete: (result: ChatStreamResult): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        if (this.state !== ChatState.Streaming && this.state !== ChatState.Sending) {
          return;
        }
        if (!isCurrent()) {
          Logger.warn(LOG_TAG, 'stale callback ignored type=complete');
          return;
        }
        this.finalizeAssistantTurn(
          assistantId, result, callbacks, context, operationId
        );
      },
      onError: (error: NetworkError): void => {
        this.clearStartTimer();
        if (this.disposed) {
          return;
        }
        // stopGeneration 已将状态置为 Cancelled,迟到的 onError 忽略
        if (this.state === ChatState.Cancelled) {
          return;
        }
        if (!isCurrent()) {
          Logger.warn(LOG_TAG, 'stale callback ignored type=error');
          return;
        }
        // 不调用 flushPersistence() — persistFinalAssistant 已包含完整最终状态,
        // 避免与 persistFinalAssistant 嵌套事务冲突(T-6.4A-R3)
        this.finalizeAssistant(
          assistantId, '', ChatMessageStatus.Failed, error.message, callbacks
        );
        this.currentAssistantId = null;
        Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_error');
        // 持久化最终 Failed 状态,完成后才清理上下文
        this.persistFinalAssistant(assistantId).then((): void => {
          Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
          Logger.warn(LOG_TAG, 'generation finalized status=failed');
          // Swipe:更新摘要生成标志
          if (context.kind === ChatGenerationKind.SwipeCandidate) {
            Logger.warn(LOG_TAG, 'Regenerate | failed');
            this.updateSwipeSummaryGeneratingFlag(false);
          }
          // 更新 Chat 活跃时间
          this.persistChatActivity();
          // 清理活动上下文
          this.clearActiveGeneration(operationId);
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError(error.message);
          Logger.warn(LOG_TAG, 'stream failed: ' + error.message);
        }).catch((_e: Object): void => {
          this.clearActiveGeneration(operationId);
          this.setState(ChatState.Failed, callbacks);
          callbacks.onError(error.message);
        });
      }
    };

    // 启动超时保护(携带 context 用于迟到 timer 判断)
    this.startStartTimer(assistantId, callbacks, context);

    // 创建请求级 Preset 快照(每次请求开始时读取一次)
    let snapshot: PromptPresetRequestSnapshot;
    try {
      snapshot = await this.createPresetRequestSnapshot();
    } catch (e) {
      this.clearStartTimer();
      handleStartFailure(e instanceof Error ? e.message : String(e));
      return;
    }

    // 构建请求消息(通过 PromptBuilder 统一构建)
    // Swipe 候选生成时排除目标 Assistant(不将其当前正文作为历史)
    // T-6.4B-1.2: BranchRegeneration 也排除新空 Assistant(避免把空回复作为历史)
    const excludeId: string | undefined =
      (context.kind === ChatGenerationKind.SwipeCandidate
        || context.kind === ChatGenerationKind.BranchRegeneration)
        ? assistantId : undefined;
    let requestMessages: ChatMessage[];
    try {
      requestMessages = await this.buildRequestMessages(snapshot.presetSystemPrompt, excludeId);
    } catch (e) {
      this.clearStartTimer();
      handleStartFailure(String(e));
      return;
    }
    // 保存最近构建的请求消息,供 UI 估算上下文占用
    this.lastBuiltRequestMessages = requestMessages;

    // Narrator: 注入旁白叙述指令
    if (context.kind === ChatGenerationKind.Narrator) {
      const narratorInstruction: ChatMessage = {
        id: 'sys-narrator',
        role: ChatRole.System,
        content: 'You are now acting as the narrator/storyteller of this scene. ' +
          'Describe the scene, character actions, thoughts, and surroundings from a third-person perspective. ' +
          'Do NOT speak as the character — instead, narrate what happens. ' +
          'You may reference lorebook entries, world information, and character memories to enrich the narration. ' +
          'If the narrator instruction directs a specific character action, describe that action happening. ' +
          'If the narrator is observing or inquiring, provide descriptive narration about the scene, ' +
          'character inner thoughts, or world background as relevant.',
        createdAt: Date.now(),
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.ExternalSystem
      };
      requestMessages = [...requestMessages, narratorInstruction];
    }

    // 计算 Token 预算 → 超预算则裁剪 → 重算预算
    await this.updateRequestPlan(requestMessages, snapshot.generationSettings);

    // 固定段超预算时阻止 Provider 启动
    if (this.lastTokenBudget !== undefined && this.lastTokenBudget.exceedsBudget) {
      this.clearStartTimer();
      handleStartFailure('输入超出上下文窗口,请缩短对话或清除预设');
      return;
    }

    // 构建生效的请求选项(Preset 覆盖模型配置)
    // 读取 per-chat 思考强度(覆盖 Provider 默认)
    let perChatEffort: string = '';
    if (this.chatBackgroundService !== null && this.currentChatId !== undefined) {
      try {
        const stored: string = await this.chatBackgroundService.getReasoningEffort(this.currentChatId);
        perChatEffort = stored;
      } catch (e) {
        Logger.warn(LOG_TAG, 'getReasoningEffort failed: ' + String(e));
      }
    }

    const effectiveOptions: ChatRequestOptions = {
      temperature: snapshot.generationSettings.temperature !== undefined
        ? snapshot.generationSettings.temperature
        : DEFAULT_OPTIONS.temperature,
      topP: snapshot.generationSettings.topP !== undefined
        ? snapshot.generationSettings.topP
        : DEFAULT_OPTIONS.topP,
      maxTokens: snapshot.generationSettings.maxOutputTokens !== undefined
        ? snapshot.generationSettings.maxOutputTokens
        : DEFAULT_OPTIONS.maxTokens,
      stream: true,
      reasoningEffort: perChatEffort
    };

    try {
      const planMessages: ChatMessage[] = this.lastHistoryTrimResult !== undefined
        ? this.lastHistoryTrimResult.messages
        : requestMessages;
      this.currentHandle = this.modelService.streamCurrentChat(
        planMessages, effectiveOptions, streamCallbacks
      );
      this.setState(ChatState.Streaming, callbacks);
    } catch (e) {
      this.clearStartTimer();
      handleStartFailure(String(e));
    }
  }

  /**
   * 助手 Turn 最终完成流程。
   */
  private finalizeAssistantTurn(
    assistantId: string,
    result: ChatStreamResult,
    callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext,
    operationId: number
  ): void {
    if (this.disposed) {
      return;
    }
    // CHAT-STATUS-1A: 从完整回复中提取并剥离状态块,合并更新角色状态
    const extraction = extractStatusBlock(result.content);
    if (extraction.parsedEntries.length > 0) {
      this.applyStatusUpdate(extraction.parsedEntries, callbacks);
    } else {
      // 未解析到状态字段:仍复位一次性"生成字段"请求,避免 flag 残留导致后续对话
      // 一直被"只输出 JSON"指令污染(否则每次回复都会变成纯状态 JSON 而非正文)。
      this.statusFieldGenerationRequested = false;
    }
    const finalStatus: ChatMessageStatus = this.finalizeAssistant(
      assistantId, extraction.cleanContent, ChatMessageStatus.Completed, undefined, callbacks
    );
    this.currentAssistantId = null;

    if (finalStatus !== ChatMessageStatus.Failed
      && callbacks.onAssistantMessageFinalized !== undefined) {
      try {
        const hintJson: string = result.performanceHintJson ?? '';
        callbacks.onAssistantMessageFinalized(
          assistantId,
          hintJson
        );
      } catch (e) {
        Logger.warn(LOG_TAG, 'onAssistantMessageFinalized threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }

    // Prompt Cache 命中率回调
    if (result.cachedTokens !== undefined && result.promptTokens !== undefined
      && result.promptTokens > 0 && callbacks.onCacheStatsUpdate !== undefined) {
      const ratio: number = result.cachedTokens / result.promptTokens;
      try {
        callbacks.onCacheStatsUpdate(result.cachedTokens, result.promptTokens, ratio);
      } catch (e) {
        Logger.warn(LOG_TAG, 'onCacheStatsUpdate threw: ' +
          (e instanceof Error ? e.message : String(e)));
      }
    }

    this.persistFinalAssistant(assistantId).then((): void => {
      if (context.kind === ChatGenerationKind.SwipeCandidate) {
        this.updateSwipeSummaryGeneratingFlag(false);
      }
      this.persistChatActivity();
      this.clearActiveGeneration(operationId);
      this.updateLastAssistantMessageId();

      if (finalStatus === ChatMessageStatus.Failed) {
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('模型返回了空回复,请重试');
      } else {
        this.setState(ChatState.Completed, callbacks);
      }
      if (context.kind === ChatGenerationKind.SwipeCandidate) {
        this.invalidateMemoryFromMessagePosition(assistantId);
      } else if (this.memoryAutoSummaryEnabled) {
        this.triggerMemorySummaryAsync();
      }
    }).catch((_e: Object): void => {
      this.clearActiveGeneration(operationId);
      this.updateLastAssistantMessageId();
      if (context.kind === ChatGenerationKind.SwipeCandidate) {
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('候选回复持久化失败,请重试');
      } else if (finalStatus === ChatMessageStatus.Failed) {
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('模型返回了空回复,请重试');
      } else {
        this.setState(ChatState.Completed, callbacks);
      }
    });
  }

  /**
   * 创建请求级 Preset 快照。
   *
   * 每次 sendMessage/regenerate 开始时调用一次。
   * 读取当前 Preset,与模型配置合并为 EffectiveGenerationSettings。
   *
   * 读取失败规则:
   * - 当前 ID 不存在:清空选择,返回 null(使用模型配置)
   * - Repository 读取异常:抛出错误,阻止请求
   * - Preset 数据损坏:抛出错误,阻止请求
   *
   * @returns 请求快照
   * @throws Error 无法读取当前预设或数据损坏
   */
  private async createPresetRequestSnapshot(): Promise<PromptPresetRequestSnapshot> {
    // 1. 获取模型配置作为基准
    let baseTemperature: number | undefined = undefined;
    let baseTopP: number | undefined = undefined;
    let baseMaxOutputTokens: number | undefined = undefined;
    let baseContextWindow: number | undefined = undefined;
    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config !== null) {
        baseTemperature = config.temperature;
        baseTopP = config.topP;
        baseMaxOutputTokens = config.maxTokens;
        baseContextWindow = config.contextWindow;
      }
    } catch (e) {
      // 配置获取失败:使用空 base,后续由 DEFAULT_OPTIONS 兜底
      Logger.warn(LOG_TAG, 'createPresetRequestSnapshot getCurrentConfig failed: '
        + (e instanceof Error ? e.message : String(e)));
    }
    const base: EffectiveGenerationSettings = {
      temperature: baseTemperature,
      topP: baseTopP,
      maxOutputTokens: baseMaxOutputTokens,
      contextWindow: baseContextWindow
    };

    // 2. 获取当前 Preset
    if (this.promptPresetService === null) {
      return createSnapshotWithoutPreset(
        resolveEffectiveGenerationSettings(base)
      );
    }

    let presets: PromptPreset[] = [];
    try {
      presets = await this.promptPresetService.getSelectedPresets();
    } catch (e) {
      // Repository 读取失败:阻止请求
      throw new Error('无法读取当前提示词预设，请重试');
    }

    // Phase 4D-9: 预设加载诊断日志
    // 用于验证用户在设置 tab 选择的预设是否真正被加载到请求中
    Logger.info(LOG_TAG, 'createPresetRequestSnapshot: selected preset count='
      + presets.length.toString());

    if (presets.length === 0) {
      return createSnapshotWithoutPreset(
        resolveEffectiveGenerationSettings(base)
      );
    }

    // 3. 合并参数
    let settings: EffectiveGenerationSettings;
    try {
      settings = resolveEffectiveGenerationSettings(base, presets);
    } catch (e) {
      // 数据损坏:阻止请求
      throw new Error('无法读取当前提示词预设，请重试');
    }

    return createSnapshotWithPresets(presets, settings);
  }

  /**
   * 构建请求消息列表(通过 PromptBuilder 统一构建)。
   *
   * 角色、世界书和聊天历史由 PromptBuilder 按固定顺序组装。
   * 世界书内容不会写入 this.messages。
   * 无 PromptBuilder 或无角色时,返回原始消息列表(跳过 System 消息)。
   *
   * V2 字段支持:
   * - character.mesExample:作为 DialogueExamples 段(由 PromptBuilder 处理)
   * - character.postHistoryInstructions:作为 PostHistory 段(由 PromptBuilder 处理)
   * - character.systemPrompt + {{original}}:由 PromptBuilder 处理
   * - character.characterBookId:加载关联 Lorebook 作为 characterBook 参与匹配
   *
   * @param presetSystemPrompt Preset 附加 System Prompt(可选,已宏替换)
   */
  private async buildRequestMessages(
    presetSystemPrompt?: string,
    excludeMessageId?: string
  ): Promise<ChatMessage[]> {
    // Phase 4D-9: 诊断日志,确认 presetSystemPrompt 是否传入 PromptBuilder
    Logger.info(LOG_TAG, 'buildRequestMessages: presetSystemPrompt=' +
      (presetSystemPrompt !== undefined
        ? `len=${presetSystemPrompt.length}`
        : 'undefined'));

    // 确定用于构建 Prompt 的消息列表
    let sourceMessages: ChatMessage[];
    if (excludeMessageId !== undefined && excludeMessageId.length > 0) {
      // 排除目标 Assistant(候选生成时使用)
      sourceMessages = [];
      for (let i = 0; i < this.messages.length; i++) {
        if (this.messages[i].id !== excludeMessageId) {
          sourceMessages.push(this.messages[i]);
        }
      }
    } else {
      sourceMessages = this.messages;
    }

    if (this.promptBuilder === null) {
      // 无 PromptBuilder:跳过 System 消息,保留 User/Assistant
      const filtered: ChatMessage[] = [];
      for (let i = 0; i < sourceMessages.length; i++) {
        if (sourceMessages[i].role !== ChatRole.System) {
          filtered.push(sourceMessages[i]);
        }
      }
      return filtered;
    }

    // 世界书只加载角色绑定的那本,不加载全局当前世界书(每本书只服务绑定它的角色)
    let characterBook: Lorebook | undefined = undefined;
    if (this.character !== null
      && this.character.characterBookId.length > 0
      && this.lorebookService !== null) {
      try {
        const book: Lorebook | null = await this.lorebookService.getById(
          this.character.characterBookId
        );
        if (book !== null) {
          characterBook = book;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load character_book failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // 可观测性:记录本次请求实际加载到的角色绑定世界书,用于排查"世界书是否参与注入"
    Logger.info(LOG_TAG,
      'buildRequestMessages worldbook: characterBook=' + (characterBook !== undefined
        ? ('id=' + characterBook.id + ' name=' + characterBook.name + ' enabled=' + String(characterBook.enabled)
          + ' entries=' + String(characterBook.entries.length))
        : 'none')
      + ' characterBookId=' + (this.character !== null ? this.character.characterBookId : ''));

    // 通过 PromptBuilder.buildMacroContext 构建宏替换上下文
    // (包含 description / personality / scenario / mesExample / lastMessage / originalContent)
    // 用户称呼优先级:对话覆盖 > 角色设置 > 全局设置 > 'User'
    const resolvedUserName: string = await this.resolveUserName();
    const macroContext: MacroContext = this.promptBuilder.buildMacroContext(
      this.character,
      resolvedUserName,
      sourceMessages
    );

    // 长期记忆注入(v12 多层优先,回退单段)
    // v12: 优先使用 getMultiLayerInjectionContext 获取 Core/Chapter/Rolling/Legacy 分层记忆
    // 失败或无记忆时回退到空,不影响主流程
    // v8.3 Phase 2: 同时取得 memoryEndPosition 用于 RecentMessageSelector 去重
    let memoryLayers: MemoryLayersInjection | undefined = undefined;
    let memoryEndPosition: number = -1;
    if (this.memoryService !== null && this.activeBranchId.length > 0) {
      try {
        // v42: 传入当前 chat 的 worldId,世界分组内 core/chapter 跨会话共享
        const multi = await this.memoryService.getMultiLayerInjectionContext(
          this.activeBranchId,
          this.currentChat !== null ? this.currentChat.worldId : ''
        );
        if (multi.enabled) {
          // v12: 使用分层注入
          memoryLayers = {
            core: multi.core,
            chapter: multi.chapter,
            rolling: multi.rolling,
            legacy: multi.legacy
          };
          memoryEndPosition = multi.endPosition;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load multi-layer memory failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // v8.4: 窗口锚点改为"动态派生",由手动总结章节边界与保留条数实时计算。
    // - anchor = 章节边界(chapterBoundary) - recentWindowTarget
    //   => 窗口起点 = anchor + 1 = 章节边界往前 recentWindowTarget 条原文
    // - 章节只由手动记忆总结追加,不被自动/滚动记忆扩展 => 边界稳定,窗口不滑动
    // - 修改「记忆总结后保留条数」立即生效(无需重新手动总结)
    // - 未手动总结过(无章节)或消息不足时 anchor<0 => 全部原文
    // - 仅当记忆实际可用(memoryLayers 已加载)时才应用;防止记忆被清除/禁用后截断前缀
    let recentWindowTarget: number = DEFAULT_RECENT_WINDOW_TARGET;
    if (this.contextBudgetService !== null && this.currentChatId !== undefined
      && this.currentChatId.length > 0) {
      try {
        const budgetConfig: ContextBudgetConfig =
          await this.contextBudgetService.getBudget(this.currentChatId);
        if (budgetConfig.recentWindowTarget > 0) {
          recentWindowTarget = budgetConfig.recentWindowTarget;
        }
      } catch (_e) {
        // 读取失败用默认值
      }
    }
    if (memoryLayers !== undefined && this.memoryService !== null
      && this.activeBranchId.length > 0) {
      try {
        const chapterBoundary: number =
          await this.memoryService.getChapterBoundaryPosition(this.activeBranchId);
        const derivedAnchor: number = chapterBoundary - recentWindowTarget;
        memoryEndPosition = derivedAnchor >= 0 ? derivedAnchor : -1;
        Logger.info(LOG_TAG, 'buildRequestMessages | window anchor derived'
          + ' chapterBoundary=' + chapterBoundary
          + ' recentWindowTarget=' + recentWindowTarget
          + ' anchor=' + memoryEndPosition);
      } catch (e) {
        Logger.warn(LOG_TAG, 'load chapter boundary failed: ' + String(e));
      }
    }

    // 使用 RecentMessageSelector 选择最近原始消息窗口(缓存优先,append-only)
    // - 窗口以最后一次记忆总结结束位置为锚(memoryEndPosition),新消息只追加、不滑动
    // - 与长期记忆范围去重:已被记忆覆盖且不在最近窗口的消息不注入原文
    // - 刚总结完、窗口为空时兜底保留最近 MIN_COMPLETE_TURNS(2)完整轮次
    // - availableTokens 传一个宽松上限,让 RecentMessageSelector 主要做去重 + 窗口
    //   精确 Token 裁剪由后续 HistoryTrimmer 完成
    // - 为 null 时回退到旧行为(传全部 sourceMessages)
    let conversationMessages: ChatMessage[] = sourceMessages;
    if (this.recentMessageSelector !== null && this.tokenCounter !== null) {
      try {
        // recentWindowTarget 已在上方解析,直接复用(窗口锚点派生也使用同一值)
        const selection: ContextHistorySelection = this.recentMessageSelector.select(
          sourceMessages,
          {
            targetCount: recentWindowTarget,
            minCompleteTurns: MIN_COMPLETE_TURNS,
            availableTokens: Number.MAX_SAFE_INTEGER,
            memoryEndPosition: memoryEndPosition
          }
        );
        conversationMessages = selection.recentMessages;
        if (selection.selectedCount === 0 && sourceMessages.length > 0) {
          // 选择器异常返回空:回退到 sourceMessages,避免空请求
          Logger.warn(LOG_TAG, 'RecentMessageSelector returned empty, fallback to sourceMessages');
          conversationMessages = sourceMessages;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'RecentMessageSelector failed, fallback to sourceMessages: '
          + (e instanceof Error ? e.message : String(e)));
        conversationMessages = sourceMessages;
      }
    }

    // 解析有效 Persona
    const effectivePersona: Persona | null = await this.resolveEffectivePersona();

    // v44: 记忆关键词召回(可选,仅世界分组且开关开启;排除恒定注入的章节,最多 3 条)
    let memoryKeywordHits: MemoryKeywordHit[] | undefined = undefined;
    if (this.memoryKeywordRetrievalEnabled
      && this.memoryService !== null
      && this.currentChat !== null
      && this.currentChat.worldId.length > 0
      && memoryLayers !== undefined) {
      try {
        const texts: string[] = [];
        const endIdx: number = conversationMessages.length;
        for (let i = Math.max(0, endIdx - 20); i < endIdx; i++) {
          texts.push(conversationMessages[i].content);
        }
        const excludeIds: string[] = [];
        const chapters: ChatMemory[] | undefined = memoryLayers.chapter;
        if (chapters !== undefined) {
          for (let i = 0; i < chapters.length; i++) {
            excludeIds.push(chapters[i].id);
          }
        }
        const hits: ChatMemory[] = await this.memoryService.retrieveKeywordMemories(
          this.currentChat.worldId, texts, excludeIds, 3
        );
        if (hits.length > 0) {
          memoryKeywordHits = hits.map((m: ChatMemory): MemoryKeywordHit => ({
            title: m.title.length > 0 ? m.title : '历史记忆',
            detail: m.summary
          }));
          Logger.info(LOG_TAG, 'memory keyword retrieval hits=' + hits.length
            + ' worldId=' + this.currentChat.worldId);
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'memory keyword retrieval failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    const context: PromptBuildContext = {
      character: this.character !== null ? this.character : undefined,
      characterBook: characterBook,
      messages: conversationMessages,
      macroContext: macroContext,
      presetSystemPrompt: presetSystemPrompt,
      // v12: 优先使用分层注入;memoryLayers 为 undefined 时 PromptBuilder 回退到 memorySummary(此处不传)
      memoryLayers: memoryLayers,
      // 角色绑定书的激活方式兜底(书级 FollowGlobal 遗留数据时用全局默认) + 深度注入位置
      characterBookActivationMode: this.lorebookActivationDefault,
      lorebookDepth: this.lorebookInjectionDepth,
      // 记忆关键词召回命中(可选,开关开启时注入)
      memoryKeywordHits: memoryKeywordHits,
      // Persona 注入
      persona: effectivePersona !== null ? effectivePersona : undefined
      // enablePostHistoryInstructions 默认为 true
      // 后续可由 Preset 配置控制
    };

    const result: PromptBuildResult = this.promptBuilder.build(context);

    // CHAT-STATUS-1A: 注入角色状态输出指令(仅当存在用户字段时)
    const finalMessages: ChatMessage[] = this.injectStatusInstruction(result.messages);
    return finalMessages;
  }





  /**
   * 异步触发长期记忆增量总结。
   * v12: 优先调用 tryGenerateMultiLayerMemory(章节优先,回退 rolling),
   * 失败时回退到旧版 trySummarize,保证兼容性。
   * - 失败不抛出,不阻塞已完成状态
   * - 不调用 await,在后台执行
   * - 仅记录触发阶段,不记录消息内容
   */
  private triggerMemorySummaryAsync(): void {
    if (this.memoryService === null) {
      return;
    }
    if (this.currentChatId === undefined || this.currentChatId.length === 0) {
      return;
    }
    if (this.activeBranchId.length === 0) {
      return;
    }
    const chatId: string = this.currentChatId;
    const branchId: string = this.activeBranchId;
    const branchMessages: ChatMessage[] = this.messages.slice();
    // v12: 优先使用多层记忆生成(章节优先,回退 rolling)
    // 不 await:后台执行,失败仅记录日志
    this.memoryService.tryGenerateMultiLayerMemory(chatId, branchId, branchMessages)
      .then((result): void => {
        if (!result.success) {
          Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=failed'
            + (result.error !== undefined ? ' err=' + result.error : ''));
        } else {
          this.notifyMemoryChanged();
        }
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=exception: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * v12: 失效指定消息 position 之后的记忆(软失效)。
   * v12: 失效"覆盖了指定消息位置"的记忆(软失效)。
   * 用于 Swipe 切换、Swipe 候选生成完成、重新生成等场景。
   * - 找到 messageId 在 this.messages 中的索引作为 position
   * - 调用 memoryService.softInvalidateCoveringPosition(branchId, position)
   * - 只失效该消息落在记忆覆盖范围内的记忆,不误伤独立的章节历史快照
   * - 失败不阻塞,只记录 warn
   * - 不记录消息内容
   *
   * @param messageId 触发失效的消息 ID(该消息位置所在的记忆范围会被失效)
   */
  private invalidateMemoryFromMessagePosition(messageId: string): void {
    if (this.memoryService === null) {
      return;
    }
    if (this.activeBranchId.length === 0) {
      return;
    }
    // 查找消息 position(在 this.messages 中的索引)
    let position: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        position = i;
        break;
      }
    }
    if (position < 0) {
      return;
    }
    const branchId: string = this.activeBranchId;
    // 不 await:后台执行,失败仅记录日志
    this.memoryService.softInvalidateCoveringPosition(branchId, position)
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'MemoryInvalidate | failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * 统一更新请求计划:计算 Token 预算,若超预算则裁剪,再重算预算。
   * 失败不抛出,仅清空结果并记录安全日志。
   *
   * 记录中只输出 messages 数、Token 数与超预算标志,不记录任何消息内容。
   *
   * @param requestMessages PromptBuilder 输出的请求消息
   * @param effectiveSettings 生效的生成参数(含 contextWindow 和 maxOutputTokens)
   */
  private async updateRequestPlan(
    requestMessages: ChatMessage[],
    effectiveSettings: EffectiveGenerationSettings
  ): Promise<void> {
    if (this.tokenCounter === null) {
      // 无 TokenCounter:跳过,使用原始请求消息
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      return;
    }

    let contextWindow: number = DEFAULT_CONTEXT_WINDOW;
    let reserved: number = DEFAULT_RESERVED_OUTPUT_TOKENS;

    // 从 effectiveSettings 获取 contextWindow
    if (effectiveSettings.contextWindow !== undefined) {
      contextWindow = effectiveSettings.contextWindow;
    }

    // 从 effectiveSettings 获取 maxOutputTokens(预留输出)
    if (effectiveSettings.maxOutputTokens !== undefined &&
      effectiveSettings.maxOutputTokens > 0) {
      reserved = effectiveSettings.maxOutputTokens;
    }

    // v8.1: per-chat 上下文预算覆盖(由 ContextBudgetService 提供)
    // followModel=false 时,使用用户自定义值覆盖 effectiveSettings
    if (this.contextBudgetService !== null && this.currentChatId !== undefined) {
      try {
        const budget = await this.contextBudgetService.getBudget(this.currentChatId);
        if (!budget.followModel) {
          // 自定义值已在 Service 内部 clamp 到合法范围
          if (budget.customContextWindow > 0) {
            contextWindow = budget.customContextWindow;
          }
          if (budget.customReservedOutputTokens > 0) {
            reserved = budget.customReservedOutputTokens;
          }
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'contextBudgetService.getBudget failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // v8.3 Phase 2: 输入可用预算 = contextWindow - reserved - safetyMargin
    // 安全余量动态计算:
    // - 至少 MIN_SAFETY_MARGIN(1024)Token,避免小上下文窗口时余量不足
    // - 按 contextWindow 的 3% 计算,大上下文窗口时余量按比例增大
    // - 上限 MAX_SAFETY_MARGIN(8192)Token,避免超大上下文窗口(1M)时余量浪费
    // 安全余量用于 Token 估算误差和 Provider 包装(系统消息、JSON 序列化等附加 Token)
    const safetyMargin: number = calculateSafetyMargin(contextWindow);
    let available: number = contextWindow - reserved - safetyMargin;
    if (available < 0) {
      available = 0;
    }

    // 1) 首次预算估算(原始 Prompt)
    let currentMessages: ChatMessage[] = requestMessages;
    let originalTokens: number = 0;
    try {
      originalTokens = this.tokenCounter.estimateMessages(currentMessages);
    } catch (e) {
      Logger.warn(LOG_TAG, 'token estimate failed: ' + (e instanceof Error ? e.message : String(e)));
      this.lastTokenBudget = undefined;
      this.lastHistoryTrimResult = undefined;
      return;
    }
    const exceedsBefore: boolean = originalTokens > available;

    // 2) 必要时调用 HistoryTrimmer
    if (exceedsBefore && this.historyTrimmer !== null) {
      let trimResult: HistoryTrimResult | undefined = undefined;
      try {
        trimResult = this.historyTrimmer.trim(currentMessages, { availableInputTokens: available });
      } catch (e) {
        Logger.warn(LOG_TAG, 'history trim failed: ' + (e instanceof Error ? e.message : String(e)));
        this.lastHistoryTrimResult = undefined;
        this.lastTokenBudget = this.makeBudget(originalTokens, contextWindow, reserved, available);
        return;
      }
      this.lastHistoryTrimResult = trimResult;
      currentMessages = trimResult.messages;
      // 更新 lastBuiltRequestMessages 为裁剪后的最终消息,
      // 让 UI 上下文占用统计反映实际发送给模型的内容。
      this.lastBuiltRequestMessages = currentMessages;

      // 3) 重算 TokenBudget
      let finalTokens: number = trimResult.finalTokenCount;
      try {
        finalTokens = this.tokenCounter.estimateMessages(currentMessages);
      } catch (e) {
        // 异常时使用 trimResult 的值
        Logger.warn(LOG_TAG, 'token re-estimate failed: ' + (e instanceof Error ? e.message : String(e)));
      }
      this.lastTokenBudget = this.makeBudget(finalTokens, contextWindow, reserved, available);

      if (this.lastTokenBudget.exceedsBudget) {
        Logger.warn(LOG_TAG,
          'token budget exceeded after trim: inputTokens=' + finalTokens.toString()
            + ' availableTokens=' + available.toString());
      }
    } else {
      // 不超预算或无 HistoryTrimmer:不裁剪
      this.lastHistoryTrimResult = undefined;
      this.lastTokenBudget = this.makeBudget(originalTokens, contextWindow, reserved, available);
      this.logNormalEstimate(requestMessages.length, originalTokens, available);
    }
  }

  private logNormalEstimate(messages: number, inputTokens: number, available: number): void {
    if (inputTokens > available) {
      Logger.warn(LOG_TAG,
        'token budget exceeded: messages=' + messages.toString()
          + ' inputTokens=' + inputTokens.toString()
          + ' availableTokens=' + available.toString()
          + ' remainingTokens=' + (available - inputTokens).toString()
          + ' exceedsBudget=true');
    }
  }

  private makeBudget(inputTokens: number, contextWindow: number, reserved: number, available: number): TokenBudget {
    const remaining: number = available - inputTokens;
    const exceeds: boolean = inputTokens > available;
    return {
      contextWindow: contextWindow,
      reservedOutputTokens: reserved,
      availableInputTokens: available,
      estimatedInputTokens: inputTokens,
      remainingInputTokens: remaining,
      exceedsBudget: exceeds
    };
  }

  /**
   * 启动阶段超时定时器。
   * 如果在 START_TIMEOUT_MS 内没有收到 onStart/onDelta/onComplete/onError,
   * 中止请求并标记为失败。
   * T-6.3: 定时器触发时通过 isCurrentGeneration 校验,避免污染下一次生成。
   */
  private startStartTimer(
    assistantId: string,
    callbacks: ChatServiceCallbacks,
    context: ActiveGenerationContext
  ): void {
    this.clearStartTimer();
    this.startTimerId = setTimeout((): void => {
      this.startTimerId = -1;
      if (this.disposed) {
        return;
      }
      if (this.state !== ChatState.Sending && this.state !== ChatState.Streaming) {
        return;
      }
      // 上下文已被 stop 或新请求替换:迟到 timer 不处理
      if (!this.isCurrentGeneration(context)) {
        Logger.warn(LOG_TAG, 'stale callback ignored type=startTimer');
        return;
      }
      Logger.warn(LOG_TAG, 'start timeout fired');
      if (this.currentHandle !== null) {
        this.currentHandle.abort();
        this.currentHandle = null;
      }
      // flush 任何 pending delta
      this.flushPersistence();
      this.finalizeAssistant(
        assistantId, '', ChatMessageStatus.Failed, '请求启动超时,请重试', callbacks
      );
      this.currentAssistantId = null;
      Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=callback_start_timeout');
      // 持久化最终 Failed 状态,完成后才清理上下文
      this.persistFinalAssistant(assistantId).then((): void => {
        Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + context.kind + ' stage=message_failed_persisted');
        Logger.warn(LOG_TAG, 'generation finalized status=failed');
        // Swipe:更新摘要生成标志
        if (context.kind === ChatGenerationKind.SwipeCandidate) {
          this.updateSwipeSummaryGeneratingFlag(false);
        }
        // 更新 Chat 活跃时间
        this.persistChatActivity();
        // 清理活动上下文
        this.clearActiveGeneration(context.operationId);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('请求启动超时,请重试');
      }).catch((_e: Object): void => {
        this.clearActiveGeneration(context.operationId);
        this.setState(ChatState.Failed, callbacks);
        callbacks.onError('请求启动超时,请重试');
      });
    }, START_TIMEOUT_MS);
  }

  private clearStartTimer(): void {
    if (this.startTimerId !== -1) {
      clearTimeout(this.startTimerId);
      this.startTimerId = -1;
    }
  }

  private setState(state: ChatState, callbacks: ChatServiceCallbacks | null): void {
    if (this.disposed) {
      return;
    }
    if (this.state === state) {
      return;
    }
    this.state = state;
    if (callbacks !== null) {
      callbacks.onStateChanged(state);
    }
  }

  /**
   * 通知消息列表变更。
   * this.messages 已是不可变更新产生的新数组引用,直接传递避免额外复制。
   * callbacks 为 null 时跳过(用于 dispose 后或无回调场景)。
   */
  private emitMessages(callbacks: ChatServiceCallbacks | null): void {
    if (callbacks === null) {
      return;
    }
    callbacks.onMessagesChanged(this.messages);
  }

  /**
   * 追加 delta 内容到指定 Assistant 消息(创建新对象和新数组)。
   *
   * 优化:用 findIndex + slice + 替换目标元素,代替 map 全量遍历。
   * slice 浅拷贝比 map 快(不调用函数),且只对目标元素调用 mergeChatMessage。
   */
  private appendDelta(assistantId: string, delta: string, callbacks: ChatServiceCallbacks): void {
    if (delta.length === 0) {
      return;
    }
    const idx: number = this.messages.findIndex((m: ChatMessage): boolean => m.id === assistantId);
    if (idx < 0) {
      return;
    }
    const oldMsg: ChatMessage = this.messages[idx];
    // 完整不可变复制:使用 mergeChatMessage 保留所有字段
    const newMsg: ChatMessage = mergeChatMessage(oldMsg, {
      content: oldMsg.content + delta,
      updatedAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming
    });
    const newMessages: ChatMessage[] = this.messages.slice();
    newMessages[idx] = newMsg;
    this.messages = newMessages;
    this.emitMessages(callbacks);
  }

  /**
   * 完成 Assistant 消息(创建新对象和新数组)。
   * 空回复且状态为 Completed 时,改为 Failed。
   * T-6.3: 不在此方法内同步 Swipe 候选,候选持久化由 persistFinalAssistant 统一路由。
   * @returns 最终的消息状态(用于决定 ChatService state)
   */
  private finalizeAssistant(
    assistantId: string,
    content: string,
    status: ChatMessageStatus,
    errorMessage: string | undefined,
    callbacks: ChatServiceCallbacks
  ): ChatMessageStatus {
    let resultStatus: ChatMessageStatus = status;
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === assistantId) {
        // 优先使用传入的 content(来自 onComplete),否则保留已有 delta 累积内容
        const finalContent: string = content.length > 0 ? content : msg.content;
        // 空回复检查:完成时内容为空,标记为失败
        let finalStatus: ChatMessageStatus = status;
        let finalError: string | undefined = errorMessage;
        if (finalStatus === ChatMessageStatus.Completed && finalContent.length === 0) {
          finalStatus = ChatMessageStatus.Failed;
          finalError = '模型返回了空回复,请重试';
        }
        // 失败且内容为空时,补充默认错误信息
        if (finalStatus === ChatMessageStatus.Failed && finalContent.length === 0
          && (finalError === undefined || finalError.length === 0)) {
          finalError = '生成失败,未收到回复';
        }
        resultStatus = finalStatus;
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          content: finalContent,
          updatedAt: Date.now(),
          isStreaming: false,
          errorMessage: finalError,
          status: finalStatus
        });
      }
      return msg;
    });
    this.emitMessages(callbacks);
    return resultStatus;
  }

  /**
   * 标记指定 Assistant 消息状态(创建新对象和新数组)。
   */
  private markAssistant(
    assistantId: string | null,
    status: ChatMessageStatus,
    errorMessage: string | undefined,
    _content: string | undefined
  ): void {
    if (assistantId === null) {
      return;
    }
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === assistantId) {
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          content: _content !== undefined ? _content : msg.content,
          updatedAt: Date.now(),
          isStreaming: false,
          errorMessage: errorMessage !== undefined ? errorMessage : msg.errorMessage,
          status: status
        });
      }
      return msg;
    });
  }

  // ===== 持久化辅助方法 =====

  /**
   * 节流调度 delta 持久化。
   * - 累计 PERSISTENCE_THROTTLE_MS 毫秒或 PERSISTENCE_MIN_CHARS 字符后触发
   * - 已有定时器则不重复创建
   */
  private schedulePersistenceFlush(assistantId: string): void {
    if (this.persistenceService === null && this.swipePersistenceService === null) {
      return;
    }
    if (this.currentChatId === undefined) {
      return;
    }
    this.pendingPersistAssistantId = assistantId;

    // 检查字符增量是否已达到阈值
    const currentMsg: ChatMessage | undefined = this.findMessageById(assistantId);
    if (currentMsg !== undefined) {
      const charDelta: number = currentMsg.content.length - this.lastPersistedContentLength;
      if (charDelta >= PERSISTENCE_MIN_CHARS) {
        // 达到字符阈值,立即 flush
        this.flushPersistence();
        return;
      }
    }

    // 未达到字符阈值,启动/重置定时器
    if (this.persistenceTimerId === -1) {
      this.persistenceTimerId = setTimeout((): void => {
        this.persistenceTimerId = -1;
        this.flushPersistence();
      }, PERSISTENCE_THROTTLE_MS);
    }
  }

  /**
   * 强制 flush 当前 pending delta 持久化(异步,不等待)。
   * 用于 onComplete/onError/stopGeneration 时确保最后一批 delta 写入。
   * T-6.3: 路由基于 activeGeneration.kind
   *   - SwipeCandidate → MessageSwipePersistenceService.updateCandidate
   *   - NormalResponse / 无活动生成 → ChatPersistenceService.updateMessage
   */
  private flushPersistence(): void {
    this.clearPersistenceTimer();
    if (this.currentChatId === undefined) {
      return;
    }
    const assistantId: string | null = this.pendingPersistAssistantId;
    if (assistantId === null) {
      return;
    }
    const msg: ChatMessage | undefined = this.findMessageById(assistantId);
    if (msg === undefined) {
      return;
    }
    // 内容长度未变化则跳过
    if (msg.content.length === this.lastPersistedContentLength) {
      return;
    }
    this.lastPersistedContentLength = msg.content.length;

    const ctx: ActiveGenerationContext | null = this.activeGeneration;
    if (ctx !== null
      && ctx.kind === ChatGenerationKind.SwipeCandidate
      && this.swipePersistenceService !== null
      && ctx.swipeCandidateIndex !== undefined) {
      // 路由到 swipe 候选持久化
      const updates: MessageSwipeCandidateUpdates = {
        content: msg.content,
        status: ChatMessageStatus.Streaming,
        isStreaming: true
      };
      // T-6.4A-R6: 串行化 delta persist,防止与 final persist 嵌套事务
      const deltaP: Promise<void> = this.swipePersistenceService.updateCandidate(
        ctx.assistantMessageId,
        ctx.swipeCandidateIndex,
        updates
      ).then((): void => {
        // delta persist ok
      }).catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'swipe delta persist failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
      // 链接到 pendingSwipePersistPromise 尾部,确保串行
      if (this.pendingSwipePersistPromise !== null) {
        this.pendingSwipePersistPromise = this.pendingSwipePersistPromise.then((): Promise<void> => deltaP);
      } else {
        this.pendingSwipePersistPromise = deltaP;
      }
    } else if (this.persistenceService !== null) {
      // 正常持久化
      this.persistenceService.updateMessage(this.currentChatId, msg).catch(
        (e: Object): void => {
          Logger.warn(LOG_TAG, 'delta persist failed: '
            + (e instanceof Error ? e.message : String(e)));
        }
      );
    }
  }

  /**
   * 同步 flush(dispose 时使用)。
   * 只清除定时器,不发起异步写入(避免 dispose 后异步回调访问已释放状态)。
   */
  private flushPersistenceSync(): void {
    this.clearPersistenceTimer();
    this.pendingPersistAssistantId = null;
  }

  private clearPersistenceTimer(): void {
    if (this.persistenceTimerId !== -1) {
      clearTimeout(this.persistenceTimerId);
      this.persistenceTimerId = -1;
    }
  }

  /**
   * 持久化 Assistant 最终状态(Completed/Cancelled/Failed)。
   * 包含 1 次立即重试,失败仅记录 warning,不阻塞流程。
   * T-6.3: 路由基于 activeGeneration.kind
   *   - SwipeCandidate → MessageSwipePersistenceService.updateCandidate
   *   - NormalResponse / 无活动生成 → ChatPersistenceService.updateMessage
   *
   * 注意:调用方必须在 persist 完成后才调用 clearActiveGeneration。
   */
  private persistFinalAssistant(assistantId: string | null): Promise<void> {
    if (assistantId === null) {
      return Promise.resolve();
    }
    if (this.currentChatId === undefined) {
      return Promise.resolve();
    }
    const msg: ChatMessage | undefined = this.findMessageById(assistantId);
    if (msg === undefined) {
      return Promise.resolve();
    }
    this.lastPersistedContentLength = msg.content.length;
    this.pendingPersistAssistantId = null;

    // T-6.4A-R6: 停止后续 persistence timer,防止 delta flush 与 final persist 并发
    this.clearPersistenceTimer();
    // 异步写入,1 次重试,返回 Promise 供调用方等待
    // Swipe 路径:先等待在飞的 delta persist 完成,再开始唯一 final 事务
    const pending: Promise<void> | null = this.pendingSwipePersistPromise;
    if (pending !== null) {
      this.pendingSwipePersistPromise = null;
      return pending.then((): Promise<void> => this.persistWithRetry(msg, 1));
    }
    return this.persistWithRetry(msg, 1);
  }

  private persistWithRetry(msg: ChatMessage, retriesLeft: number): Promise<void> {
    if (this.currentChatId === undefined) {
      return Promise.resolve();
    }
    const chatId: string = this.currentChatId;
    const ctx: ActiveGenerationContext | null = this.activeGeneration;

    if (ctx !== null
      && ctx.kind === ChatGenerationKind.SwipeCandidate
      && this.swipePersistenceService !== null
      && ctx.swipeCandidateIndex !== undefined) {
      // 路由到 swipe 候选持久化(不再额外更新 MessageRepository,
      // 候选物化由 Swipe Service 在 activateCandidate 中完成)
      const updates: MessageSwipeCandidateUpdates = {
        content: msg.content,
        status: msg.status ?? ChatMessageStatus.Completed,
        errorMessage: msg.errorMessage !== undefined ? msg.errorMessage : undefined,
        isStreaming: msg.isStreaming ?? false
      };
      return this.swipePersistenceService.updateCandidate(
        ctx.assistantMessageId,
        ctx.swipeCandidateIndex,
        updates
      ).then((): void => {
      }).catch((e: Object): Promise<void> => {
        const msg2: string = e instanceof Error ? e.message : String(e);
        if (retriesLeft > 0) {
          Logger.warn(LOG_TAG, 'swipe final persist retry: ' + msg2);
          return this.persistWithRetry(msg, retriesLeft - 1);
        }
        Logger.warn(LOG_TAG, 'swipe final persist failed: ' + msg2);
        Logger.warn(LOG_TAG, 'SwipeRuntime | stage=final_persist_failed');
        return Promise.reject(new Error('swipe final persist failed'));
      });
    } else if (this.persistenceService !== null) {
      // 正常持久化
      return this.persistenceService.updateMessage(chatId, msg).then((): void => {
      }).catch((e: Object): Promise<void> => {
        const msg2: string = e instanceof Error ? e.message : String(e);
        if (retriesLeft > 0) {
          Logger.warn(LOG_TAG, 'final persist retry: ' + msg2);
          return this.persistWithRetry(msg, retriesLeft - 1);
        }
        Logger.warn(LOG_TAG, 'final persist failed: ' + msg2);
        return Promise.resolve();
      });
    }
    return Promise.resolve();
  }

  /**
   * 更新 Chat 活跃时间(异步,不等待)。
   * 同时更新 lastMessageAt 和 updatedAt。
   */
  private persistChatActivity(): void {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    this.persistenceService.updateChatActivity(this.currentChatId, Date.now()).catch(
      (e: Object): void => {
        Logger.warn(LOG_TAG, 'chat activity persist failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    );
  }

  /**
   * 仅更新 Chat 的 updatedAt(不修改 lastMessageAt)。
   * 用于 Swipe 切换候选等不改变对话内容的操作。
   */
  private persistChatTimestamp(): void {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    this.persistenceService.updateChatTimestamp(this.currentChatId, Date.now()).catch(
      (e: Object): void => {
        Logger.warn(LOG_TAG, 'chat timestamp persist failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    );
  }

  /**
   * 在 messages 中查找指定 id 的消息。
   */
  private findMessageById(id: string): ChatMessage | undefined {
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === id) {
        return this.messages[i];
      }
    }
    return undefined;
  }

  /**
   * 更新 lastAssistantMessageId 为最后一条 Assistant 消息 ID。
   *
   * V2 行为:
   * - 优先查找 Conversation 类型(或 undefined)的 Assistant 消息
   * - 若无,则查找 CharacterFirstMessage 类型的 Assistant 消息
   *   (允许 firstMessage 成为 Swipe 目标,用于切换 alternate_greetings)
   */
  private updateLastAssistantMessageId(): void {
    this.lastAssistantMessageId = '';
    // 第一遍:优先查找 Conversation 类型
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const msg: ChatMessage = this.messages[i];
      if (msg.role === ChatRole.Assistant &&
        (msg.source === undefined || msg.source === ChatMessageSource.Conversation)) {
        this.lastAssistantMessageId = msg.id;
        return;
      }
    }
    // 第二遍:无 Conversation 类型时,查找 CharacterFirstMessage 类型
    for (let i = this.messages.length - 1; i >= 0; i--) {
      const msg: ChatMessage = this.messages[i];
      if (msg.role === ChatRole.Assistant &&
        msg.source === ChatMessageSource.CharacterFirstMessage) {
        this.lastAssistantMessageId = msg.id;
        return;
      }
    }
  }

  /**
   * createNewSession 之后重新加载 Swipe 状态。
   *
   * createNewSession 只把 alternate_greetings 持久化为首条开场白消息的
   * Swipe 候选 1..N,不会同步 this.swipeSummaries / this.lastAssistantMessageId。
   * 会话列表"新建对话"与"删除当前会话后回退新建"两条路径必须调用本方法,
   * 否则首条消息候选数读不到(开场白选择箭头不出现)且无法 Swipe。
   */
  private async reloadSwipeStateAfterNewSession(): Promise<void> {
    this.swipeSummaries = [];
    this.lastAssistantMessageId = '';
    if (this.swipePersistenceService !== null && this.currentChatId !== undefined) {
      this.swipeSummaries =
        await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
    }
    this.updateLastAssistantMessageId();
  }

  // ===== Swipe 公开方法 =====

  /**
   * 获取当前会话的 Swipe 摘要列表(副本)。
   */
  getSwipeSummaries(): MessageSwipeSummary[] {
    return this.swipeSummaries.slice();
  }

  /**
   * 获取指定 Assistant 消息的 Swipe 摘要。
   */
  getSwipeSummary(assistantMessageId: string): MessageSwipeSummary | undefined {
    return this.getSummaryForMessage(assistantMessageId);
  }

  /**
   * 判断指定 Assistant 消息是否可操作 Swipe。
   * 只允许非生成状态下操作最后一条 Assistant 消息。
   */
  canOperateSwipe(assistantMessageId: string): boolean {
    if (this.isGenerating()) {
      return false;
    }
    if (assistantMessageId !== this.lastAssistantMessageId) {
      return false;
    }
    return true;
  }

  /**
   * 激活前一个候选。
   * T-6.3: 与生成 / session op / 其他 swipe 操作互斥(swipeOperationInProgress)。
   * 仅更新 updatedAt(不修改 lastMessageAt),避免会话反复置顶。
   */
  async activatePreviousCandidate(assistantMessageId: string): Promise<void> {
    if (!this.canOperateSwipe(assistantMessageId)) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'activatePreviousCandidate rejected: busy');
      return;
    }
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    if (summary === undefined) {
      return;
    }
    const newIndex: number = summary.activeCandidateIndex - 1;
    if (newIndex < 0) {
      return;
    }
    this.swipeOperationInProgress = true;
    try {
      await this.swipePersistenceService.activateCandidate(assistantMessageId, newIndex);
      // 重新加载 messages
      await this.reloadCurrentSession();
      // 重新加载 summaries
      this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      this.updateLastAssistantMessageId();
      // 仅更新 updatedAt,不修改 lastMessageAt
      this.persistChatTimestamp();
      // v12: 切换候选后,失效该 Assistant position 之后的记忆(内容已变化,旧摘要可能不准确)
      // 失败不阻塞,只记录 warn
      this.invalidateMemoryFromMessagePosition(assistantMessageId);
      this.emitMessages(this.lastCallbacks);
    } finally {
      this.swipeOperationInProgress = false;
    }
  }

  /**
   * 激活下一个候选。
   * T-6.3: 与生成 / session op / 其他 swipe 操作互斥(swipeOperationInProgress)。
   * 仅更新 updatedAt(不修改 lastMessageAt),避免会话反复置顶。
   */
  async activateNextCandidate(assistantMessageId: string): Promise<void> {
    if (!this.canOperateSwipe(assistantMessageId)) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'activateNextCandidate rejected: busy');
      return;
    }
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    if (summary === undefined) {
      return;
    }
    const newIndex: number = summary.activeCandidateIndex + 1;
    if (newIndex >= summary.candidateCount) {
      return;
    }
    this.swipeOperationInProgress = true;
    try {
      await this.swipePersistenceService.activateCandidate(assistantMessageId, newIndex);
      // 重新加载 messages
      await this.reloadCurrentSession();
      // 重新加载 summaries
      this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      this.updateLastAssistantMessageId();
      // 仅更新 updatedAt,不修改 lastMessageAt
      this.persistChatTimestamp();
      // v12: 切换候选后,失效该 Assistant position 之后的记忆(内容已变化,旧摘要可能不准确)
      // 失败不阻塞,只记录 warn
      this.invalidateMemoryFromMessagePosition(assistantMessageId);
      this.emitMessages(this.lastCallbacks);
    } finally {
      this.swipeOperationInProgress = false;
    }
  }

  /**
   * 激活指定索引的候选(开场白选择等场景的显式索引切换)。
   * 语义同 activateNextCandidate,但允许任意合法索引(含回绕到 Candidate 0)。
   * 索引越界时安全回退到 Candidate 0。
   */
  async activateCandidateIndex(assistantMessageId: string, index: number): Promise<void> {
    if (!this.canOperateSwipe(assistantMessageId)) {
      return;
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'activateCandidateIndex rejected: busy');
      return;
    }
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    if (summary === undefined) {
      return;
    }
    const target: number =
      index >= 0 && index < summary.candidateCount ? index : 0;
    if (target === summary.activeCandidateIndex) {
      return;
    }
    this.swipeOperationInProgress = true;
    try {
      await this.swipePersistenceService.activateCandidate(assistantMessageId, target);
      // 重新加载 messages
      await this.reloadCurrentSession();
      // 重新加载 summaries
      this.swipeSummaries = await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      this.updateLastAssistantMessageId();
      // 仅更新 updatedAt,不修改 lastMessageAt
      this.persistChatTimestamp();
      // v12: 切换候选后,失效该 Assistant position 之后的记忆
      this.invalidateMemoryFromMessagePosition(assistantMessageId);
      this.emitMessages(this.lastCallbacks);
    } finally {
      this.swipeOperationInProgress = false;
    }
  }

  /**
   * 为最后一条 Assistant 消息生成新的候选回复。
   * 内部创建 Streaming 候选,启动流式请求。
   *
   * T-6.3:
   * - 创建 SwipeCandidate ActiveGenerationContext(包含 candidateIndex)
   * - 与 normal send / swipe browse / session op 互斥(swipeOperationInProgress)
   * - 启动失败时通过 doStream 的 handleStartFailure 统一处理
   * - 持久化走 MessageSwipePersistenceService(由 flushPersistence/persistWithRetry 路由)
   */
  async generateAlternativeCandidate(): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | busy');
      return;
    }
    if (this.lastAssistantMessageId.length === 0) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_assistant_message');
      return;
    }
    if (this.swipePersistenceService === null) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_swipe_state');
      return;
    }
    if (this.lastCallbacks === null) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | missing_callbacks');
      return;
    }

    this.generationOperationId++;
    // 占用 swipe 操作互斥锁(保护 appendCandidate + reloadCurrentSession 期间不被并发)
    this.swipeOperationInProgress = true;

    const assistantMessageId: string = this.lastAssistantMessageId;
    const operationId: number = this.generationOperationId;
    const chatId: string = this.currentChatId !== undefined ? this.currentChatId : '';

    // 检查候选数量上限
    const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(assistantMessageId);
    let nextIndex: number = 0;
    if (summary !== undefined) {
      nextIndex = summary.candidateCount;
      if (nextIndex >= MAX_SWIPE_CANDIDATES) {
        Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | candidate_limit');
        this.swipeOperationInProgress = false;
        this.lastCallbacks.onError('该回复已达到候选数量上限');
        return;
      }
    }

    // 创建新候选(Streaming)并激活
    // T-6.4A-R6: 必须使用 appendCandidate 实际返回的 newIndex,
    // 不能使用 nextIndex(当 summary===undefined 时 nextIndex=0,
    // 但 ensureSwipeState 会先创建 Candidate 0,appendCandidate 实际创建 Candidate 1)
    let actualNewIndex: number = nextIndex;
    try {
      await this.swipePersistenceService.appendCandidate(
        assistantMessageId,
        {
          content: '',
          status: ChatMessageStatus.Streaming,
          isStreaming: true
        },
        true // activate
      );
      // T-6.4A-R6: appendCandidate 返回的 candidates 可能是事务内旧快照,
      // 不包含刚插入的 Candidate。事务已提交,重新查询获取最新数据。
      const freshState: MessageSwipeState | null =
        await this.swipePersistenceService.getSwipeState(assistantMessageId);
      if (freshState !== null) {
        let maxIdx: number = 0;
        for (let i = 0; i < freshState.candidates.length; i++) {
          if (freshState.candidates[i].candidateIndex > maxIdx) {
            maxIdx = freshState.candidates[i].candidateIndex;
          }
        }
        actualNewIndex = maxIdx;
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'Regenerate | failed | appendCandidate: ' + msg);
      this.swipeOperationInProgress = false;
      this.lastCallbacks.onError('创建候选回复失败: ' + msg);
      return;
    }

    // 更新 swipeSummaries(使用 actualNewIndex)
    if (summary !== undefined) {
      this.swipeSummaries = this.swipeSummaries.map(
        (s: MessageSwipeSummary): MessageSwipeSummary => {
          if (s.assistantMessageId === assistantMessageId) {
            return {
              assistantMessageId: s.assistantMessageId,
              activeCandidateIndex: actualNewIndex,
              candidateCount: actualNewIndex + 1,
              isGeneratingCandidate: true
            };
          }
          return s;
        }
      );
    } else {
      this.swipeSummaries.push({
        assistantMessageId: assistantMessageId,
        activeCandidateIndex: actualNewIndex,
        candidateCount: actualNewIndex + 1,
        isGeneratingCandidate: true
      });
    }

    // 建立 SwipeCandidate 活动上下文(替代旧 ActiveSwipeGeneration)
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.SwipeCandidate,
      chatId: chatId,
      assistantMessageId: assistantMessageId,
      swipeCandidateIndex: actualNewIndex
    };

    // 候选创建 + summary 更新完成,释放 swipe 操作锁;
    // 后续生成期间通过 activeGeneration 与 isBusy()(state=Sending/Streaming)互斥
    this.swipeOperationInProgress = false;

    // T-6.4A: 不再调用 reloadCurrentSession()。
    // 原因:reloadCurrentSession → loadSessionInternal → normalizeInterruptedMessages
    // 会把刚物化的 Streaming 候选改为 Cancelled,导致 DB 与内存状态不一致,
    // 重新进入页面时目标 Assistant 显示为空内容(旧历史"消失"Bug 根因)。
    // 正确做法:直接在完整内存历史中替换目标 Assistant 为 Streaming + 空 content,
    // 保留所有其他消息不变。
    this.replaceAssistantMessageInFullHistory(assistantMessageId);

    // 更新状态
    this.currentAssistantId = assistantMessageId;
    this.setState(ChatState.Sending, this.lastCallbacks);
    this.emitMessages(this.lastCallbacks);

    // 启动流式请求(携带 SwipeCandidate 上下文)
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = assistantMessageId;
    this.doStream(assistantMessageId, this.lastCallbacks, this.activeGeneration);
  }

  // ===== Swipe 内部辅助方法 =====

  /**
   * 获取指定消息的 Swipe 摘要。
   */
  private getSummaryForMessage(messageId: string): MessageSwipeSummary | undefined {
    for (let i = 0; i < this.swipeSummaries.length; i++) {
      if (this.swipeSummaries[i].assistantMessageId === messageId) {
        return this.swipeSummaries[i];
      }
    }
    return undefined;
  }

  /**
   * 更新 Swipe 摘要中的 isGeneratingCandidate 标志。
   * T-6.3: 基于当前 activeGeneration(必须为 SwipeCandidate)定位目标 Assistant。
   */
  private updateSwipeSummaryGeneratingFlag(isGenerating: boolean): void {
    const ctx: ActiveGenerationContext | null = this.activeGeneration;
    if (ctx === null || ctx.kind !== ChatGenerationKind.SwipeCandidate) {
      return;
    }
    const targetId: string = ctx.assistantMessageId;
    this.swipeSummaries = this.swipeSummaries.map(
      (s: MessageSwipeSummary): MessageSwipeSummary => {
        if (s.assistantMessageId === targetId) {
          return {
            assistantMessageId: s.assistantMessageId,
            activeCandidateIndex: s.activeCandidateIndex,
            candidateCount: s.candidateCount,
            isGeneratingCandidate: isGenerating
          };
        }
        return s;
      }
    );
  }

  /**
   * 从数据库重新加载当前会话的全部消息。
   */
  private async reloadCurrentSession(): Promise<void> {
    if (this.persistenceService === null || this.currentChatId === undefined) {
      return;
    }
    const session: PersistedChatSession | null =
      await this.persistenceService.loadSession(this.currentChatId);
    if (session !== null) {
      this.messages = session.messages.slice();
      this.currentChat = session.chat;
      this.currentSequenceNumber = session.maxSequenceNumber;
    }
  }

  /**
   * T-6.4A: 在完整页面历史中按 Message ID 查找目标 Assistant,
   * 只替换该消息为 Streaming + 空 content(用于重新生成候选),
   * 保留所有其他消息的 ID、内容、顺序、sequenceNumber 不变。
   *
   * 要求:
   * 1. 在完整页面历史中按 Message ID 查找;
   * 2. 只替换一项;
   * 3. 保留其他所有项;
   * 4. 返回新数组引用;
   * 5. 找不到时抛安全错误;
   * 6. 不使用请求裁剪后的数组更新 UI。
   */
  private replaceAssistantMessageInFullHistory(assistantMessageId: string): void {
    let found: boolean = false;
    this.messages = this.messages.map((msg: ChatMessage): ChatMessage => {
      if (msg.id === assistantMessageId) {
        found = true;
        // 完整不可变复制:使用 mergeChatMessage 保留所有字段
        return mergeChatMessage(msg, {
          content: '',
          updatedAt: Date.now(),
          isStreaming: true,
          errorMessage: undefined,
          status: ChatMessageStatus.Streaming
        });
      }
      return msg;
    });
    if (!found) {
      throw new Error('replaceAssistantMessageInFullHistory: target assistant not found');
    }
  }

  // ===== T-6.4B-1 Branch 公开方法 =====

  /**
   * 获取 Branch 列表(副本)。
   */
  getBranches(): ConversationBranchSummary[] {
    return this.branches.slice();
  }

  /**
   * 获取当前活动 Branch ID。
   */
  getActiveBranchId(): string {
    return this.activeBranchId;
  }

  /**
   * 获取 Branch 记录数量统计。
   */
  getRecordCounts(): ConversationRecordCounts | undefined {
    return this.recordCounts;
  }

  /**
   * 是否正在执行 Branch 操作(创建 Child / 切换)。
   */
  isBranchOperating(): boolean {
    return this.branchOperationInProgress;
  }

  /**
   * 判断指定 Assistant 消息是否可"从此处继续"创建 Child Branch。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = Assistant
   * - source = Conversation 或 undefined(兼容)
   * - 不是 CharacterFirstMessage
   * - status = Completed
   * - 不是当前正在生成的消息
   * - 位于当前 messages 列表中
   */
  canContinueFromAssistant(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    if (this.currentAssistantId !== null && this.currentAssistantId === messageId) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.Assistant) {
      return false;
    }
    if (msg.source === ChatMessageSource.CharacterFirstMessage) {
      return false;
    }
    if (msg.source !== undefined && msg.source !== ChatMessageSource.Conversation) {
      return false;
    }
    if (msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    return true;
  }

  /**
   * 刷新 Branch 状态(branches / activeBranchId / recordCounts)。
   * 在 initializeSession 完成后以及 Branch 操作后调用。
   * 失败不抛异常,仅记录 warning。
   */
  async refreshBranchState(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.branchPersistenceService === null) {
      return;
    }
    if (this.currentChatId === undefined) {
      return;
    }
    try {
      const chatId: string = this.currentChatId;
      const branches: ConversationBranchSummary[] =
        await this.branchPersistenceService.listBranches(chatId);
      const activeBranch: ConversationBranch | null =
        await this.branchPersistenceService.getActiveBranch(chatId);
      const counts: ConversationRecordCounts =
        await this.branchPersistenceService.getRecordCounts(chatId);
      this.branches = branches;
      this.activeBranchId = activeBranch !== null ? activeBranch.id : '';
      this.recordCounts = counts;
    } catch (e) {
      Logger.warn(LOG_TAG, 'refreshBranchState failed: '
        + (e instanceof Error ? e.message : String(e)));
    }
  }

  /**
   * 从历史 Assistant 创建 Child Branch(从此处继续)。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化
   * 2. 校验消息可继续(canContinueFromAssistant)
   * 3. 获取当前 Active Branch
   * 4. 获取该 Assistant 在当前 Branch 中选中的 Candidate index(若有)
   * 5. 调用 forkAtMessage 创建 Child Branch(自动成为 Active)
   * 6. 重新加载 messages / swipeSummaries / branches / recordCounts
   * 7. 创建新的 messages 数组引用
   * 8. 通知 UI
   *
   * 不会:
   * - 删除原 Branch 后续消息
   * - 复制 Message / Candidate 实体
   * - 原地修改 messages 数组
   * - 自动开始 Provider 请求
   * - 自动插入空 User 消息
   *
   * @param messageId 目标历史 Assistant 消息 ID
   * @param callbacks 回调集合
   */
  async continueFromAssistant(
    messageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'continueFromAssistant rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canContinueFromAssistant(messageId)) {
      Logger.warn(LOG_TAG, 'continueFromAssistant rejected: invalid message');
      callbacks.onError('该消息无法继续');
      return;
    }

    this.branchOperationInProgress = true;
    this.lastCallbacks = callbacks;
    try {
      const chatId: string = this.currentChatId;
      // 1. 获取当前 Active Branch
      const activeBranch: ConversationBranch | null =
        await this.branchPersistenceService.getActiveBranch(chatId);
      if (activeBranch === null) {
        throw new Error('当前会话无活动分支');
      }
      // 2. 获取该 Assistant 在当前 Branch 中选中的 Candidate index
      //    (用于 forkAtMessage 覆盖新 Branch 的选择,保留来源 Branch 当前显示的 Candidate)
      const summary: MessageSwipeSummary | undefined = this.getSummaryForMessage(messageId);
      const selectedCandidateIndex: number | undefined =
        summary !== undefined ? summary.activeCandidateIndex : undefined;
      // 3. 调用 forkAtMessage 创建 Child Branch(自动成为 Active)
      await this.branchPersistenceService.forkAtMessage(
        chatId,
        activeBranch.id,
        messageId,
        selectedCandidateIndex
      );
      // 4. 重新加载 messages / swipeSummaries / branchState
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      // 5. 通知 UI(新数组引用)
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'continueFromAssistant failed: ' + msg);
      callbacks.onError('创建分支失败,请重试');
    } finally {
      this.branchOperationInProgress = false;
    }
  }

  /**
   * T-6.4B-2: 判断指定 User 消息是否可"从此处生成新回复"创建 Branch。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = User
   * - status = Completed(或 undefined,兼容旧数据)
   * - 不是当前正在生成的消息(currentAssistantId 只可能是 Assistant,User 永远不匹配)
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 该 User 消息之后存在 Assistant 回复或后续消息(即不是最新一条尚未生成回复的 User)
   *   通过 indexOf(msg) < messages.length - 1 判断
   */
  canGenerateFromUserMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.User) {
      return false;
    }
    if (msg.status !== undefined && msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    // 必须有后续消息(后面存在 Assistant 回复或后续历史)
    // 最新一条尚未生成 Assistant 的 User 消息不显示该操作
    const idx: number = this.messages.indexOf(msg);
    if (idx < 0 || idx >= this.messages.length - 1) {
      return false;
    }
    return true;
  }

  /**
   * T-6.4B-3: 判断指定历史 Assistant 消息是否可"重新生成此回复"。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = Assistant
   * - source = Conversation 或 undefined(兼容旧数据)
   * - status = Completed
   * - 不是 CharacterFirstMessage
   * - 不是当前正在生成的消息(currentAssistantId)
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 前面存在对应的 User 消息(基于当前 Branch 有序路径向前查找)
   */
  canRegenerateAssistantMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    if (this.currentAssistantId !== null && this.currentAssistantId === messageId) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.Assistant) {
      return false;
    }
    if (msg.source === ChatMessageSource.CharacterFirstMessage) {
      return false;
    }
    if (msg.source !== undefined && msg.source !== ChatMessageSource.Conversation) {
      return false;
    }
    if (msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    // 基于当前 Active Branch 有序路径向前查找最近的 User
    const idx: number = this.messages.indexOf(msg);
    if (idx <= 0) {
      return false;
    }
    let hasPrevUser: boolean = false;
    for (let i = idx - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        hasPrevUser = true;
        break;
      }
    }
    return hasPrevUser;
  }

  /**
   * T-6.4B-3: 历史 Assistant "重新生成此回复"。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化、消息可重新生成
   * 2. 在当前 Active Branch 有序路径中定位目标 Assistant
   * 3. 向前查找最近的 User 消息作为 fork point
   * 4. 判断同级或子级 parentBranchId(复用 T-6.4B-1.2 规则)
   * 5. 调用 forkAndStreamFromUser 创建 Branch + Streaming Assistant + 启动 Provider
   *
   * 与"从此处继续"的区别:
   * - fork point 是目标 Assistant 前面的 User(不是 Assistant 本身)
   * - 新 Branch 不保留目标 Assistant 和后续历史
   * - 自动调用 Provider 生成新 Assistant
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async regenerateAssistantMessage(
    messageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'regenerateAssistantMessage rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canRegenerateAssistantMessage(messageId)) {
      Logger.warn(LOG_TAG, 'regenerateAssistantMessage rejected: invalid message');
      callbacks.onError('该消息无法重新生成');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 在当前 Active Branch 有序路径中定位目标 Assistant
    let assistantIndex: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        assistantIndex = i;
        break;
      }
    }
    if (assistantIndex < 0) {
      callbacks.onError('找不到目标回复');
      return;
    }

    // 2. 向前查找最近的 User 消息作为 fork point
    let forkUserMessageId: string = '';
    for (let i = assistantIndex - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.User) {
        forkUserMessageId = this.messages[i].id;
        break;
      }
    }
    if (forkUserMessageId.length === 0) {
      callbacks.onError('找不到原始用户消息');
      return;
    }

    // 3. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 4. 解析新 Branch 的 parent:
    //    fork 点在 Active Branch 自有消息区间 → 子级;在复制前缀 → 挂到祖先
    const parentBranchId: string =
      await this.branchPersistenceService.resolveForkParentBranchId(
        chatId, activeBranch.id, forkUserMessageId
      );

    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, forkUserMessageId, callbacks
    );
  }

  /**
   * T-6.4B-2: 从历史 User 消息生成新回复(创建新 Branch 并自动启动 Provider)。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化、消息可生成
   * 2. 获取当前 Active Branch
   * 3. 判断同级或子级 parentBranchId(复用 T-6.4B-1.2 规则)
   * 4. 调用 forkAndStreamFromUser 创建 Branch + Streaming Assistant + 启动 Provider
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async generateFromUserMessage(
    userMessageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'generateFromUserMessage rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canGenerateFromUserMessage(userMessageId)) {
      Logger.warn(LOG_TAG, 'generateFromUserMessage rejected: invalid message');
      callbacks.onError('该消息无法生成新回复');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 获取当前 Active Branch(完整 ConversationBranch,含 forkMessageId / parentBranchId)
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 2. 解析新 Branch 的 parent:
    //    fork 点在 Active Branch 自有消息区间 → 子级;在复制前缀 → 挂到祖先
    const parentBranchId: string =
      await this.branchPersistenceService.resolveForkParentBranchId(
        chatId, activeBranch.id, userMessageId
      );

    await this.forkAndStreamFromUser(
      chatId, activeBranch.id, parentBranchId, userMessageId, callbacks
    );
  }

  /**
   * T-6.4B-3.1: 判断指定历史 User 消息是否可"编辑"。
   *
   * 条件:
   * - 未处于忙碌状态
   * - branchPersistenceService 可用
   * - role = User
   * - status = Completed 或 undefined(兼容旧数据)
   * - content 非空
   * - 位于当前 messages 列表中(即位于当前 Active Branch)
   * - 后面存在消息(目标 User 不是最新一条)
   * - 前面存在消息(目标 User 不是第一条,有 anchor)
   */
  canEditUserMessage(messageId: string): boolean {
    if (this.isBusy()) {
      return false;
    }
    if (this.branchPersistenceService === null) {
      return false;
    }
    if (messageId.length === 0) {
      return false;
    }
    const msg: ChatMessage | undefined = this.findMessageById(messageId);
    if (msg === undefined) {
      return false;
    }
    if (msg.role !== ChatRole.User) {
      return false;
    }
    if (msg.status !== undefined && msg.status !== ChatMessageStatus.Completed) {
      return false;
    }
    if (msg.content.length === 0) {
      return false;
    }
    const idx: number = this.messages.indexOf(msg);
    if (idx <= 0) {
      // idx <= 0:第一条消息无 anchor,或不在列表
      return false;
    }
    if (idx >= this.messages.length - 1) {
      // 最新一条 User(后面无消息),不可编辑
      return false;
    }
    return true;
  }

  /**
   * T-6.4B-3.1: 编辑历史 User Message 并创建新 Branch + Streaming Assistant。
   *
   * 流程:
   * 1. 校验:未忙碌、服务可用、会话已初始化、消息可编辑、编辑内容非空且不同
   * 2. 在当前 Active Branch 有序路径中定位目标 User 和 anchor(前一条消息)
   * 3. 判断同级或子级 parentBranchId(基于 activeBranch.forkMessageId == anchorMessageId)
   * 4. 创建新的 Completed User Message(编辑后内容)和 Streaming Assistant Message
   * 5. 调用 editUserAndForkWithAssistant 原子事务
   * 6. 重载 messages / swipeSummaries / branchState
   * 7. 建立 BranchRegeneration ActiveGenerationContext
   * 8. 调用 doStream 启动 Provider
   *
   * 与"从此处生成新回复"的区别:
   * - 编辑:fork point = anchor(原 User 前一条),创建新 User,不继承原 User
   * - 从此处生成新回复:fork point = 原 User,继承原 User,只替换后面的 Assistant
   *
   * 事务失败:不启动 Provider,不切换 Active Branch,通过 callbacks.onError 报错。
   */
  async editUserMessageAndGenerate(
    messageId: string,
    editedContent: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'editUserMessageAndGenerate rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.persistenceService === null) {
      callbacks.onError('持久化服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (!this.canEditUserMessage(messageId)) {
      Logger.warn(LOG_TAG, 'editUserMessageAndGenerate rejected: invalid message');
      callbacks.onError('该消息无法编辑');
      return;
    }
    const trimmedContent: string = editedContent.trim();
    if (trimmedContent.length === 0) {
      callbacks.onError('编辑内容不能为空');
      return;
    }

    const chatId: string = this.currentChatId;
    this.lastCallbacks = callbacks;

    // 1. 在当前 Active Branch 有序路径中定位目标 User
    let userIndex: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        userIndex = i;
        break;
      }
    }
    if (userIndex <= 0) {
      callbacks.onError('找不到目标用户消息');
      return;
    }

    // 2. anchor = 目标 User 前一条消息(任何角色,通常是 Assistant 或 CharacterFirstMessage)
    const anchorMessageId: string = this.messages[userIndex - 1].id;

    // 3. 获取当前 Active Branch
    const activeBranch: ConversationBranch | null =
      await this.branchPersistenceService.getActiveBranch(chatId);
    if (activeBranch === null) {
      callbacks.onError('当前会话无活动分支');
      return;
    }
    if (activeBranch.id.length === 0) {
      callbacks.onError('活动分支无效');
      return;
    }

    // 4. 判断同级或子级
    //    同级条件:当前 Active Branch 非 Root 且 forkMessageId 等于本次 anchorMessageId
    //    (即当前 Branch 也是从同一个 anchor fork 出的编辑/再生分支)
    let parentBranchId: string;
    if (!activeBranch.isRoot
      && activeBranch.forkMessageId !== undefined
      && activeBranch.forkMessageId === anchorMessageId) {
      parentBranchId = activeBranch.parentBranchId !== undefined
        ? activeBranch.parentBranchId : activeBranch.id;
    } else {
      parentBranchId = activeBranch.id;
    }

    // 5. 创建新的 Completed User Message 和 Streaming Assistant Message
    this.generationOperationId++;
    const operationId: number = this.generationOperationId;
    const newUserMessage: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.User,
      content: trimmedContent,
      createdAt: Date.now(),
      isStreaming: false,
      status: ChatMessageStatus.Completed,
      source: ChatMessageSource.Conversation
    };
    const newAssistantMessage: ChatMessage = {
      id: 'msg-' + generateUuid(),
      role: ChatRole.Assistant,
      content: '',
      createdAt: Date.now(),
      isStreaming: true,
      status: ChatMessageStatus.Streaming,
      source: ChatMessageSource.Conversation
    };

    // 6. 调用原子事务创建 Branch + 新 User + 新 Assistant
    this.branchOperationInProgress = true;
    let editResult: EditedBranchGenerationTarget;
    try {
      editResult = await this.branchPersistenceService!.editUserAndForkWithAssistant(
        chatId,
        activeBranch.id,
        parentBranchId,
        messageId,
        anchorMessageId,
        newUserMessage,
        newAssistantMessage
      );
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'editUserMessageAndGenerate failed: ' + msg);
      this.branchOperationInProgress = false;
      callbacks.onError('创建分支失败,请重试');
      return;
    }

    // 7. 事务成功,重载内存状态(新 Branch 已成为 Active)
    try {
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'editUserMessageAndGenerate reload failed: ' + msg);
      // Branch 已创建,继续执行生成,UI 状态可能与 DB 不一致但可恢复
    }

    // 8. 建立 BranchRegeneration 活动上下文
    this.activeGeneration = {
      operationId: operationId,
      kind: ChatGenerationKind.BranchRegeneration,
      chatId: chatId,
      assistantMessageId: editResult.newAssistantMessageId,
      branchId: editResult.newBranchId,
      forkMessageId: anchorMessageId
    };

    // 9. 设置当前 Assistant ID 和持久化追踪
    this.currentAssistantId = editResult.newAssistantMessageId;
    this.lastPersistedContentLength = 0;
    this.pendingPersistAssistantId = editResult.newAssistantMessageId;

    // 10. 释放 Branch 操作锁
    this.branchOperationInProgress = false;

    // 11. 进入 Sending 状态,通知 UI
    this.setState(ChatState.Sending, callbacks);
    this.emitMessages(callbacks);

    // 12. 启动 Provider
    this.doStream(editResult.newAssistantMessageId, callbacks, this.activeGeneration);
  }

  /**
   * 切换 Active Branch 到 targetBranchId。
   *
   * 流程:
   * 1. 校验:未忙碌、branchPersistenceService 可用、会话已初始化
   * 2. 调用 switchActiveBranch(事务内物化 Candidate 到 messages 并同步 group active index)
   * 3. 重新加载 messages / swipeSummaries / branches / recordCounts
   * 4. 通知 UI
   *
   * @param targetBranchId 目标 Branch ID
   * @param callbacks 回调集合
   */
  async switchBranch(
    targetBranchId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isBusy()) {
      Logger.warn(LOG_TAG, 'switchBranch rejected: busy');
      callbacks.onError('操作进行中,请稍候');
      return;
    }
    if (this.branchPersistenceService === null) {
      callbacks.onError('分支服务不可用');
      return;
    }
    if (this.currentChatId === undefined) {
      callbacks.onError('会话未初始化');
      return;
    }
    if (targetBranchId.length === 0) {
      callbacks.onError('目标分支无效');
      return;
    }
    if (targetBranchId === this.activeBranchId) {
      // 已是当前分支,无操作
      return;
    }

    this.branchOperationInProgress = true;
    this.lastCallbacks = callbacks;
    try {
      const chatId: string = this.currentChatId;
      await this.branchPersistenceService.switchActiveBranch(chatId, targetBranchId);
      // 重新加载
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(chatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'switchBranch failed: ' + msg);
      callbacks.onError('切换分支失败,请重试');
    } finally {
      this.branchOperationInProgress = false;
    }
  }

  /**
   * T-6.4B-1.1: 外部 Branch 切换后重新加载当前会话。
   *
   * 当 BranchMapPage 通过 branchPersistenceService.switchActiveBranch 切换 Active Branch 后,
   * ChatPage 的 ChatService 需要重新从数据库加载消息和 Branch 状态。
   * 此方法不执行 switchActiveBranch(已由外部完成),只做 reload + 通知 UI。
   *
   * 流程:
   * 1. 重新加载 messages(从 DB,含 Active Branch 的 Candidate 投影)
   * 2. 重新加载 swipeSummaries
   * 3. 更新 lastAssistantMessageId
   * 4. 刷新 Branch 状态(branches / activeBranchId / recordCounts)
   * 5. 通知 UI(新数组引用)
   *
   * @param callbacks 回调集合
   */
  async reloadAfterExternalBranchChange(callbacks: ChatServiceCallbacks): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.currentChatId === undefined) {
      return;
    }
    try {
      await this.reloadCurrentSession();
      if (this.swipePersistenceService !== null) {
        this.swipeSummaries =
          await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
      }
      this.updateLastAssistantMessageId();
      await this.refreshBranchState();
      this.setState(ChatState.Idle, callbacks);
      this.emitMessages(callbacks);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      Logger.error(LOG_TAG, 'reloadAfterExternalBranchChange failed: ' + msg);
      callbacks.onError('重新加载会话失败');
    }
  }




  async editNarratorMessage(messageId: string, editedContent: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    const idx: number = this.findMessageIndexById(messageId);
    if (idx < 0) {
      return;
    }
    const msg: ChatMessage = this.messages[idx];
    if (msg.senderType !== 'narrator') {
      return;
    }
    const updated: ChatMessage = mergeChatMessage(msg, {
      content: editedContent,
      updatedAt: Date.now()
    });
    this.messages[idx] = updated;
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      await this.persistenceService.updateMessage(messageId, updated);
    }
  }
}
