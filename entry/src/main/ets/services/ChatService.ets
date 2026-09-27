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
import { LorebookPinService } from './LorebookPinService';
import { LorebookStickyService, StickyResolveResult } from './LorebookStickyService';
import { PromptBuilder, PromptBuildContext, PromptBuildResult, MemoryLayersInjection } from './PromptBuilder';
import { TokenCounter } from './TokenCounter';
import { HistoryTrimmer } from './HistoryTrimmer';
import { RecentMessageSelector } from './RecentMessageSelector';
import { ChatPersistenceService } from './ChatPersistenceService';
import { ChatBackgroundService } from './ChatBackgroundService';
import { PromptPresetService } from './PromptPresetService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { ConversationBranchPersistenceService, EditedBranchGenerationTarget } from './ConversationBranchPersistenceService';
import { MemoryService, MemorySummaryResult } from './MemoryService';
import { ContextBudgetService } from './ContextBudgetService';
import { ChatMemoryModeService, ChatMemoryMode } from './ChatMemoryModeService';
import {
  MemoryLoadRefService,
  MemoryLoadRef
} from './MemoryLoadRefService';
import {
  matchEntityChapterIds,
  parseEntityIndexJson,
  EntityIndex,
  EntityIndexEntry
} from './ChapterMemoryIndexer';
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
import { Character, buildCharacterSystemContent } from '../models/Character';
import { Lorebook, LorebookEntry, LorebookActivationMode } from '../models/Lorebook';
import { MacroContext } from '../models/MacroContext';
import { ProviderConfig } from '../models/ProviderConfig';
import { TokenBudget } from '../models/TokenBudget';
import {
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
  ChatStatusSchemaEntry,
  createEmptyChatStatusState,
  createChatStatusEntry,
  serializeChatStatusState,
  parseChatStatusState,
  extractStatusSchema,
  findStatusSchemaByName
} from '../models/ChatStatusState';
import { ChatState, ChatServiceCallbacks } from '../models/ChatServiceContract';
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
import { planRequest, RequestPlanDeps, RequestPlanResult } from './ChatRequestPlan';
import { ChatRequestBuilder, ChatRequestBuilderDeps, ChatRequestHost } from './ChatRequestBuilder';
import { ChatOneShotGenerator, ChatOneShotDeps, ChatOneShotHost } from './ChatOneShotGenerator';
import {
  GLOBAL_USER_NAME_KEY,
  STATUS_INSTRUCTION_PREFS_KEY,
  LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY,
  LOREBOOK_INJECTION_DEPTH_PREFS_KEY,
  MEMORY_KEYWORD_RETRIEVAL_PREFS_KEY,
  MEMORY_AUTO_SUMMARY_PREFS_KEY,
  STICKY_REMINDER_MAX_ITEMS,
  DEFAULT_LOREBOOK_ACTIVATION_MODE,
  DEFAULT_LOREBOOK_INJECTION_DEPTH,
  pushFrontendInteractionRecord,
  buildFrontendInteractionText,
  buildStatusValuesText,
  buildStatusRuleText,
  buildStatusInstructionText,
  buildStickyReminderText,
  pickHotStickyNames
} from './ChatTextContract';

const LOG_TAG: string = 'ChatService';

/** 启动阶段超时(毫秒),收到首个 onStart/onDelta/onComplete/onError 后清除 */
const START_TIMEOUT_MS: number = 15000;

/** 默认用户名(本阶段固定值,后续可扩展为用户设置) */
const DEFAULT_USER_NAME: string = 'User';


/** delta 持久化节流间隔(毫秒) */
const PERSISTENCE_THROTTLE_MS: number = 400;

/** delta 持久化触发的最小字符增量 */
const PERSISTENCE_MIN_CHARS: number = 64;

/** 默认流式请求选项 */
const DEFAULT_OPTIONS: ChatRequestOptions = {
  temperature: 0.7,
  topP: 1.0,
  maxTokens: 20480,
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
  /** v45: 按需锁定世界书会话钉选服务(OnDemandPinned) */
  private readonly lorebookPinService: LorebookPinService | null;
  /** v46: LorebookStickyService 粘滞按需世界书会话命中服务(StickyOnDemand) */
  private readonly lorebookStickyService: LorebookStickyService | null;
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
   * 声明式状态 Schema(arktavern-card-extensions v1):角色卡声明的允许状态字段集合。
   * 由 character.extensions.arktavern.status.fields 解析;为空表示状态功能整体禁用。
   */
  private statusSchema: ChatStatusSchemaEntry[] = [];
  /**
   * 状态输出指令开关。
   * true=向模型注入状态输出指令(AI 回复时附带状态 JSON);
   * false=不注入状态指令,AI 只返回纯正文(不返回状态 JSON)。
   * 可由用户在记忆管理页手动切换。默认 true。
   */
  private statusInstructionEnabled: boolean = true;
  /**
   * 前端卡交互记录(契约 v3 appendInteraction)。
   * 角色卡界面里的轻交互由页面调 Bridge 攒到这里:不写聊天历史、不触发模型请求,
   * 只在下一轮正常请求时作为「前端交互记录」提示词段注入(尾部动态区,滚动窗口 30 条/2000 字符)。
   * 会话级内存态:切会话/重启即清。
   */
  private frontendInteractions: string[] = [];
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
  /** v46: 按需加载记忆引用服务(appPreferences 可用时创建) */
  private readonly memoryLoadRefService: MemoryLoadRefService | null;
  /** v50: 会话级记忆模式服务(manual/auto + 章节注入数) */
  private readonly chatMemoryModeService: ChatMemoryModeService | null;
  /** 请求构建与注入(P2:自本类抽离,服务依赖与宿主回调在构造期装配) */
  private readonly requestBuilder: ChatRequestBuilder;
  /** 单次生成(代写/性格提取/续写)(P2-2:自本类抽离,服务依赖与宿主回调在构造期装配) */
  private readonly oneShotGenerator: ChatOneShotGenerator;

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
    recentMessageSelector: RecentMessageSelector | null = null,
    lorebookPinService: LorebookPinService | null = null,
    lorebookStickyService: LorebookStickyService | null = null,
    chatMemoryModeService: ChatMemoryModeService | null = null
  ) {
    this.modelService = modelService;
    this.lorebookService = lorebookService;
    this.lorebookPinService = lorebookPinService;
    this.lorebookStickyService = lorebookStickyService;
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
    this.memoryLoadRefService = appPreferences !== null
      ? new MemoryLoadRefService(appPreferences)
      : null;
    this.recentMessageSelector = recentMessageSelector;
    this.chatMemoryModeService = chatMemoryModeService;
    const builderDeps: ChatRequestBuilderDeps = {
      promptBuilder: this.promptBuilder,
      tokenCounter: this.tokenCounter,
      recentMessageSelector: this.recentMessageSelector,
      lorebookService: this.lorebookService,
      lorebookPinService: this.lorebookPinService,
      lorebookStickyService: this.lorebookStickyService,
      memoryService: this.memoryService,
      memoryLoadRefService: this.memoryLoadRefService,
      chatMemoryModeService: this.chatMemoryModeService,
      contextBudgetService: this.contextBudgetService
    };
    const builderHost: ChatRequestHost = {
      getCurrentChat: (): Chat | null => this.currentChat,
      getCurrentChatId: (): string | undefined => this.currentChatId,
      getCharacter: (): Character | null => this.character,
      getMessages: (): ChatMessage[] => this.messages,
      getActiveBranchId: (): string => this.activeBranchId,
      getLorebookActivationDefault: (): LorebookActivationMode => this.lorebookActivationDefault,
      getLorebookInjectionDepth: (): number => this.lorebookInjectionDepth,
      getMemoryKeywordRetrievalEnabled: (): boolean => this.memoryKeywordRetrievalEnabled,
      resolveUserName: (): Promise<string> => this.resolveUserName(),
      resolveEffectivePersona: (): Promise<Persona | null> => this.resolveEffectivePersona(),
      buildStatusRule: (): string => this.buildStatusRule(),
      appendStatusValuesMessage: (messages: ChatMessage[]): ChatMessage[] =>
        this.appendStatusValuesMessage(messages),
      buildFrontendInteractionBlock: (): string => this.buildFrontendInteractionBlock()
    };
    this.requestBuilder = new ChatRequestBuilder(builderDeps, builderHost);

    const oneShotDeps: ChatOneShotDeps = {
      modelService: this.modelService,
      persistenceService: this.persistenceService,
      appPreferences: this.appPreferences
    };
    const oneShotHost: ChatOneShotHost = {
      isDisposed: (): boolean => this.disposed,
      isBusy: (): boolean => this.isBusy(),
      getCharacter: (): Character | null => this.character,
      getMessages: (): ChatMessage[] => this.messages,
      setMessages: (messages: ChatMessage[]): void => {
        this.messages = messages;
      },
      getCurrentChat: (): Chat | null => this.currentChat,
      getCurrentChatId: (): string | undefined => this.currentChatId,
      getLastCallbacks: (): ChatServiceCallbacks | null => this.lastCallbacks,
      setLastCallbacks: (callbacks: ChatServiceCallbacks | null): void => {
        this.lastCallbacks = callbacks;
      },
      getGenerationOperationId: (): number => this.generationOperationId,
      setGenerationOperationId: (operationId: number): void => {
        this.generationOperationId = operationId;
      },
      getCurrentSequenceNumber: (): number => this.currentSequenceNumber,
      setCurrentSequenceNumber: (sequenceNumber: number): void => {
        this.currentSequenceNumber = sequenceNumber;
      },
      getCurrentAssistantId: (): string | null => this.currentAssistantId,
      setCurrentAssistantId: (assistantId: string | null): void => {
        this.currentAssistantId = assistantId;
      },
      resolveUserName: (): Promise<string> => this.resolveUserName(),
      createPresetRequestSnapshot: (): Promise<PromptPresetRequestSnapshot> =>
        this.createPresetRequestSnapshot(),
      buildRequestMessages: (presetSystemPrompt?: string): Promise<ChatMessage[]> =>
        this.buildRequestMessages(presetSystemPrompt),
      setState: (state: ChatState, callbacks: ChatServiceCallbacks | null): void => {
        this.setState(state, callbacks);
      },
      emitMessages: (callbacks: ChatServiceCallbacks | null): void => {
        this.emitMessages(callbacks);
      },
      persistChatActivity: (): void => {
        this.persistChatActivity();
      }
    };
    this.oneShotGenerator = new ChatOneShotGenerator(oneShotDeps, oneShotHost);
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
    this.syncStatusSchemaFromCharacter();
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
    this.syncStatusSchemaFromCharacter();
    // v50: 前端交互记录是会话级内存态,切会话/新会话即清(避免把上一会话的界面操作带进新上下文)
    this.clearFrontendInteractions();

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

  /**
   * 代写/性格提取/续写族(原六方法整块抽至 services/ChatOneShotGenerator,P2-2)。
   * 以下为保留原签名的薄包装,调用点不变。
   */
  async extractUserFromCharacter(): Promise<string> {
    return this.oneShotGenerator.extractUserFromCharacter();
  }

  async summarizeUserPersona(): Promise<string> {
    return this.oneShotGenerator.summarizeUserPersona();
  }

  async generateImpersonateCandidates(): Promise<ImpersonateCandidate[]> {
    return this.oneShotGenerator.generateImpersonateCandidates();
  }

  async autoContinue(callbacks: ChatServiceCallbacks): Promise<void> {
    return this.oneShotGenerator.autoContinue(callbacks);
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
      this.persistFinalAndCleanup(
        this.currentAssistantId, expectedOperationId,
        ctx !== null ? ctx.kind : null,
        ChatState.Cancelled, this.lastCallbacks, null, true
      );
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
   * 返回当前角色卡的状态 Schema JSON(arktavern-card-extensions v1)。
   * 空数组 JSON '[]'(无声明/状态功能禁用)。
   */
  getStatusSchemaJson(): string {
    return JSON.stringify(this.statusSchema);
  }

  // ===== 前端卡交互记录(契约 v3 appendInteraction):零请求地把界面操作带进下一轮上下文 =====

  /**
   * 追加一条前端界面交互记录(角色卡页面经 Bridge appendInteraction 调用)。
   * 只入内存缓冲:不写聊天历史、不进聊天气泡、不触发模型请求;
   * 下一轮正常请求时由 buildFrontendInteractionBlock 作为提示词段注入。
   * 滚动窗口:最多 30 条、2000 字符(超出从最旧开始丢)。
   * @returns true=已记录;false=空文本或已销毁
   */
  appendFrontendInteraction(text: string): boolean {
    if (this.disposed) {
      return false;
    }
    return pushFrontendInteractionRecord(this.frontendInteractions, text);
  }

  /** 清空前端交互记录(会话切换/新会话时调用;内存态,不持久化) */
  clearFrontendInteractions(): void {
    if (this.frontendInteractions.length > 0) {
      this.frontendInteractions = [];
    }
  }

  /** 是否有待注入的前端交互记录(供 UI/测试查询) */
  hasFrontendInteractions(): boolean {
    return this.frontendInteractions.length > 0;
  }

  /**
   * 构建「前端交互记录」提示词段文本;无记录返回空串(PromptBuilder 据此不产生段)。
   */
  buildFrontendInteractionBlock(): string {
    return buildFrontendInteractionText(this.frontendInteractions);
  }

  /**
   * CHAT-STATUS-1A: 请求下一次回复重新生成/优化角色状态字段。
   * 由"AI 生成"按钮调用,在下一轮 buildStatusInstruction 时生效,回复完成后复位。
   */
  requestStatusFieldGeneration(): void {
    this.statusFieldGenerationRequested = true;
  }

  /**
   * 更新角色状态(声明式 v1):以 next 覆盖非 locked 已声明字段的值,其余字段值保留。
   * - 未声明字段一律丢弃(不能新增);已声明字段不能删除/改名
   * - locked 字段值不接受变更;清空 = 置空值展示
   * - 无 schema 声明 → 状态整体为空(禁用)
   * 校验、持久化并通知 UI。
   */
  updateStatusState(next: ChatStatusState): void {
    this.currentStatusState = this.normalizeStatusForSchema(next);
    this.persistStatusConfig();
    this.emitStatusChanged(this.lastCallbacks);
  }

  /** 声明式归一:把待更新状态重塑为「schema 声明的字段集合」,过滤/锁定规则见 updateStatusState */
  private normalizeStatusForSchema(next: ChatStatusState): ChatStatusState {
    const schema: ChatStatusSchemaEntry[] = this.statusSchema;
    if (schema.length === 0) {
      return createEmptyChatStatusState();
    }
    const cur: ChatStatusEntry[] = this.currentStatusState.entries;
    const nextEntries: ChatStatusEntry[] = next.entries;
    const out: ChatStatusEntry[] = [];
    for (let i = 0; i < schema.length; i++) {
      const s: ChatStatusSchemaEntry = schema[i];
      const curE: ChatStatusEntry | null = findStatusEntryByName(cur, s.name);
      const nextE: ChatStatusEntry | null = findStatusEntryByName(nextEntries, s.name);
      let val: string = '';
      let fromUser: boolean = false;
      if (s.locked) {
        val = curE !== null ? curE.value : '';
        fromUser = curE !== null ? curE.fromUser : false;
      } else if (nextE !== null) {
        val = nextE.value;
        fromUser = nextE.fromUser;
      } else if (curE !== null) {
        val = curE.value;
        fromUser = curE.fromUser;
      }
      out.push(createChatStatusEntry(s.name, val, fromUser, s.locked));
    }
    return { entries: out };
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
    // 声明式 v1:有 schema 但状态尚未生成(新会话/首轮)时,用声明字段的空值骨架填充,
    // 保证状态入口/面板在首次 AI 输出前即可显示全部声明字段(空值待填)。
    this.seedStatusFromSchema();
  }

  /** 状态骨架与声明联动:无 schema 清空(禁用);有 schema 且骨架空时用空值字段初始化 */
  private seedStatusFromSchema(): void {
    if (this.statusSchema.length === 0) {
      if (this.currentStatusState.entries.length !== 0) {
        this.currentStatusState = createEmptyChatStatusState();
      }
      return;
    }
    if (this.currentStatusState.entries.length > 0) {
      return;
    }
    const entries: ChatStatusEntry[] = [];
    for (let i = 0; i < this.statusSchema.length; i++) {
      const s: ChatStatusSchemaEntry = this.statusSchema[i];
      entries.push(createChatStatusEntry(s.name, '', false, s.locked));
    }
    this.currentStatusState = { entries: entries };
  }

  /**
   * 从当前角色卡解析声明式状态 Schema(extensions.arktavern.status.fields)。
   * 空数组 = 状态功能整体禁用(不注入指令、不显示入口、getState 为空)。
   */
  private syncStatusSchemaFromCharacter(): void {
    if (this.character !== null) {
      this.statusSchema = extractStatusSchema(this.character.extensions);
    } else {
      this.statusSchema = [];
    }
  }

  /**
   * 合并 AI 本轮输出的状态字段(纯计算,不修改状态)——声明式 v1。
   * - 只保留 statusSchema 声明过的字段(未声明字段一律忽略,AI 无权新增/删除)
   * - locked 字段:禁止 AI 更新值,始终保留现值
   * - 非 locked 声明字段:用 AI 本轮输出更新;本轮未输出则保留现值(骨架不随轮次消失)
   * - 结果按 schema 顺序重建,刷新 fromUser 之外的部分
   */
  private computeMergedStatus(parsedEntries: ChatStatusEntry[]): ChatStatusState {
    const schema: ChatStatusSchemaEntry[] = this.statusSchema;
    const oldEntries: ChatStatusEntry[] = this.currentStatusState.entries;
    const nextEntries: ChatStatusEntry[] = [];
    for (let i = 0; i < schema.length; i++) {
      const s: ChatStatusSchemaEntry = schema[i];
      const cur: ChatStatusEntry | null = findStatusEntryByName(oldEntries, s.name);
      const existedBefore: boolean = cur !== null;
      if (s.locked) {
        // 锁定字段:值恒定,保留现值(无则置空占位展示)
        nextEntries.push(createChatStatusEntry(s.name, existedBefore ? cur!.value : '', existedBefore ? cur!.fromUser : false, true));
        continue;
      }
      const match: ChatStatusEntry | null = findStatusEntryByName(parsedEntries, s.name);
      if (match !== null) {
        nextEntries.push(createChatStatusEntry(s.name, match.value, existedBefore ? cur!.fromUser : false, s.locked));
      } else if (existedBefore) {
        nextEntries.push(createChatStatusEntry(s.name, cur!.value, cur!.fromUser, s.locked));
      } else {
        nextEntries.push(createChatStatusEntry(s.name, '', false, s.locked));
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

      const parseContent = (content: string): ChatStatusState | null => {
        const extraction = extractStatusBlock(content);
        if (extraction.parsedEntries.length === 0) {
          Logger.warn(LOG_TAG, 'generateStatusFieldsNow: no valid status block parsed, content=' +
            content.substring(0, 200));
          return null;
        }
        this.currentStatusState = this.computeMergedStatus(extraction.parsedEntries);
        this.statusFieldGenerationRequested = false;
        this.persistStatusConfig();
        return this.currentStatusState;
      };
      return await this.runStatusOneShotStream(
        messages, options, 'generateStatusFieldsNow', parseContent
      );
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

      const parseContent = (content: string): ChatStatusState | null => {
        const extraction = extractStatusBlock(content);
        if (extraction.parsedEntries.length === 0) {
          // 兜底:若标记块/围栏/裸 JSON 均未解析出字段,尝试把整段响应作为 JSON 对象解析
          const fallbackEntries: ChatStatusEntry[] = parseStatusJsonWhole(content);
          if (fallbackEntries.length > 0) {
            this.currentStatusState = this.computeMergedStatus(fallbackEntries);
            this.persistStatusConfig();
            return this.currentStatusState;
          }
          Logger.warn(LOG_TAG, 'modifyStatusWithPrompt: no valid status block parsed');
          return null;
        }
        this.currentStatusState = this.computeMergedStatus(extraction.parsedEntries);
        this.persistStatusConfig();
        return this.currentStatusState;
      };
      return await this.runStatusOneShotStream(
        messages, options, 'modifyStatusWithPrompt', parseContent
      );
    } finally {
      this.statusGenerationInProgress = false;
    }
  }

  /**
   * 状态一次性请求公共骨架:Promise/settled 封装 + 流式调用与异常兜底。
   * onComplete 的解析逻辑由调用方以 parseContent 提供(返回合并后的状态或 null)。
   */
  private runStatusOneShotStream(
    messages: ChatMessage[],
    options: ChatRequestOptions,
    logPrefix: string,
    parseContent: (content: string) => ChatStatusState | null
  ): Promise<ChatStatusState | null> {
    return new Promise<ChatStatusState | null>((resolve: Function): void => {
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
          finish(parseContent(result.content));
        },
        onError: (e: NetworkError): void => {
          Logger.warn(LOG_TAG, logPrefix + ': stream error=' +
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
        || modeVal === LorebookActivationMode.OnDemand
        || modeVal === LorebookActivationMode.OnDemandPinned) {
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
          // v45: 手动总结成功后刷新 OnDemandPinned 会话钉选(记忆段与世界书段一起变化)
          this.refreshLorebookPinAsync(chatId, branchMessages);
          // v46: 手动总结成功后刷新 StickyOnDemand 会话粘滞命中(重算全量对话匹配)
          this.refreshLorebookStickyAsync(chatId, branchMessages);
        }
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'ManualMemorySummary | forced chapter exception: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * v45: 手动记忆总结成功后刷新 OnDemandPinned(按需锁定)会话钉选。
   * 按当前角色绑定世界书 + 全部对话消息重新全量关键词匹配,替换原钉选。
   * 后台执行,失败仅记录日志。
   */
  private refreshLorebookPinAsync(chatId: string, messages: ChatMessage[]): void {
    if (this.lorebookPinService === null || this.lorebookService === null) {
      return;
    }
    if (this.character === null || this.character.characterBookId.length === 0) {
      return;
    }
    const bookId: string = this.character.characterBookId;
    this.lorebookService.getById(bookId)
      .then((book: Lorebook | null): Promise<void> => {
        if (book === null || !book.enabled) {
          return Promise.resolve();
        }
        return this.lorebookPinService!.refreshPinnedEntries(chatId, book, messages);
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'ManualMemorySummary | lorebook pin refresh failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * v46: 手动记忆总结成功后刷新 StickyOnDemand(粘滞按需)会话命中。
   * 按当前角色绑定世界书 + 全部对话消息重新全量关键词匹配,整体替换原集合。
   * 后台执行,失败仅记录日志。
   */
  private refreshLorebookStickyAsync(chatId: string, messages: ChatMessage[]): void {
    if (this.lorebookStickyService === null || this.lorebookService === null) {
      return;
    }
    if (this.character === null || this.character.characterBookId.length === 0) {
      return;
    }
    const bookId: string = this.character.characterBookId;
    this.lorebookService.getById(bookId)
      .then((book: Lorebook | null): Promise<void> => {
        if (book === null || !book.enabled) {
          return Promise.resolve();
        }
        return this.lorebookStickyService!.refreshStickyEntries(chatId, book, messages);
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'ManualMemorySummary | lorebook sticky refresh failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * v45.1: 手动刷新世界书激活内容(OnDemandPinned 按需锁定模式)。
   * 用户切换开场白/生成新章节后调用:按当前会话全部消息重新关键词匹配,
   * 替换 chat_lorebook_pins 钉选记录并落库(刷新后即锁定)。
   * v46: StickyOnDemand 粘滞模式同样支持,按模式分派刷新。
   * @return true=已刷新; false=无可刷新(会话未初始化/无角色书/书未启用/服务不可用/异常)
   */
  async refreshLorebookPinNow(): Promise<boolean> {
    if (this.currentChatId === undefined || this.currentChatId.length === 0
      || this.lorebookService === null
      || (this.lorebookPinService === null && this.lorebookStickyService === null)) {
      return false;
    }
    if (this.character === null || this.character.characterBookId.length === 0) {
      return false;
    }
    try {
      const book: Lorebook | null = await this.lorebookService.getById(this.character.characterBookId);
      if (book === null || !book.enabled) {
        return false;
      }
      const effectiveMode: LorebookActivationMode =
        book.activationMode !== LorebookActivationMode.FollowGlobal
          ? book.activationMode : this.lorebookActivationDefault;
      const messages: ChatMessage[] = this.messages.slice();
      if (effectiveMode === LorebookActivationMode.StickyOnDemand) {
        if (this.lorebookStickyService === null) {
          return false;
        }
        await this.lorebookStickyService.refreshStickyEntries(this.currentChatId, book, messages);
        Logger.info(LOG_TAG, 'ManuallyRefreshLorebookSticky | refreshed chatId=' + this.currentChatId
          + ' book=' + book.id);
        return true;
      }
      if (this.lorebookPinService === null) {
        return false;
      }
      await this.lorebookPinService.refreshPinnedEntries(this.currentChatId, book, messages);
      Logger.info(LOG_TAG, 'ManuallyRefreshLorebookPin | refreshed chatId=' + this.currentChatId
        + ' book=' + book.id);
      return true;
    } catch (e) {
      Logger.warn(LOG_TAG, 'ManuallyRefreshLorebookPin | failed: ' + String(e));
      return false;
    }
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
   * CHAT-STATUS-1A: 追加角色状态**当前值** system message。
   *
   * 位置固定为请求的**最后一条**(不再依赖"最后一个 system 消息"这种数据相关的位置):
   * 该段每轮都可能变化(模型更新 / 卡片界面 setState / 一键重新生成),
   * 只有钉在最末,它之前的稳定前缀(含整段对话历史)才能持续命中缓存。
   *
   * 格式要求与字段清单已拆到 PromptBuilder 的 StatusRule 稳定段,此处只带当前值。
   */
  private appendStatusValuesMessage(messages: ChatMessage[]): ChatMessage[] {
    // 状态输出指令开关:关闭时不注入状态指令,AI 只返回纯正文(不返回状态 JSON)
    if (!this.statusInstructionEnabled) {
      return messages;
    }
    const values: string = buildStatusValuesText(this.statusSchema, this.currentStatusState.entries);
    if (values.length === 0) {
      return messages;
    }
    const valuesMessage: ChatMessage = mergeChatMessage(
      createChatMessage(generateUuid(), ChatRole.System, values, Date.now()),
      {
        source: ChatMessageSource.StatusValues,
        sourceName: '角色状态当前值'
      }
    );
    const result: ChatMessage[] = messages.slice();
    result.push(valuesMessage);
    return result;
  }

  /**
   * 构建状态**稳定段**文本(格式规则 + 字段清单,不含当前值),供 PromptBuilder 注入稳定前缀。
   * 关闭状态指令或无可用字段时返回空串(PromptBuilder 据此不产生段)。
   */
  private buildStatusRule(): string {
    if (!this.statusInstructionEnabled) {
      return '';
    }
    return buildStatusRuleText(this.statusSchema);
  }

  /**
   * 构建状态输出指令文本(规则与当前值合并,声明式 v1)。
   * 仅供**一次性请求**使用(重新生成字段 / AI 修改状态),这类请求不走前缀缓存。
   * - 无声明 schema → 返回空字符串(不注入状态指令,状态功能整体禁用)
   * - 请求刷新字段 → 让 AI 只输出所有已声明字段的最新值(一次性请求)
   * - 正常路径 → 让 AI 在正文后输出状态块,只更新已声明字段,禁止增删字段
   */
  private buildStatusInstruction(): string {
    return buildStatusInstructionText(this.statusSchema, this.currentStatusState.entries, this.statusFieldGenerationRequested);
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
      this.persistFinalAndCleanup(
        assistantId, operationId, context.kind,
        ChatState.Failed, callbacks, errorMessage, false
      );
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
        if (context.kind === ChatGenerationKind.SwipeCandidate) {
          Logger.warn(LOG_TAG, 'Regenerate | failed');
        }
        Logger.warn(LOG_TAG, 'stream failed: ' + error.message);
        // 持久化最终 Failed 状态,完成后才清理上下文
        this.persistFinalAndCleanup(
          assistantId, operationId, context.kind,
          ChatState.Failed, callbacks, error.message, false
        );
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
      } else {
        // v50: 会话级记忆模式触发(方法内部读模式:'auto' 才总结,
        // 未设置时回退全局 memoryAutoSummaryEnabled 开关)
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
   * 构建请求消息列表(通过 PromptBuilder 统一构建;实现已抽至 services/ChatRequestBuilder)。
   *
   * @param presetSystemPrompt Preset 附加 System Prompt(可选,已宏替换)
   * @param excludeMessageId 排除的消息 id(候选生成时使用;可选)
   */
  private async buildRequestMessages(
    presetSystemPrompt?: string,
    excludeMessageId?: string
  ): Promise<ChatMessage[]> {
    return this.requestBuilder.build(presetSystemPrompt, excludeMessageId);
  }





  /**
   * 异步触发长期记忆增量总结。
   *
   * v50: 会话级记忆模式(优先):
   * - 'auto'(自动章节归档): 达章节阈值时调用 tryAutoChapterMemory
   *   只追加章节,**不回退 rolling 覆盖更新**(保缓存前缀)
   * - 'manual'(手动): 不自动总结
   * - 会话未设置时由 ChatMemoryModeService 回退全局 memoryAutoSummaryEnabled 开关
   *
   * 兼容:chatMemoryModeService 为 null(旧测试构造)时走旧全局开关
   * + tryGenerateMultiLayerMemory(章节优先,回退 rolling)。
   *
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
    const memoryService: MemoryService = this.memoryService;
    if (this.chatMemoryModeService !== null) {
      // v50: 会话级记忆模式——'auto' 自动章节归档(不回退 rolling 覆盖,保缓存)
      const modeService: ChatMemoryModeService = this.chatMemoryModeService;
      modeService.getMemoryMode(chatId)
        .then((mode: ChatMemoryMode): Promise<void> => {
          if (mode !== 'auto') {
            return Promise.resolve();
          }
          return memoryService.tryAutoChapterMemory(chatId, branchId, branchMessages)
            .then((result): void => {
              this.handleBackgroundMemoryResult(result);
            });
        })
        .catch((e: Object): void => {
          Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=exception: '
            + (e instanceof Error ? e.message : String(e)));
        });
      return;
    }
    // 兼容:无会话模式服务时走旧全局开关 + 多层回退(章节优先,回退 rolling)
    if (!this.memoryAutoSummaryEnabled) {
      return;
    }
    memoryService.tryGenerateMultiLayerMemory(chatId, branchId, branchMessages)
      .then((result): void => {
        this.handleBackgroundMemoryResult(result);
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=exception: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /** 后台记忆总结结果处理:失败仅记日志,成功通知记忆变更。 */
  private handleBackgroundMemoryResult(result: MemorySummaryResult): void {
    if (!result.success) {
      Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=failed'
        + (result.error !== undefined ? ' err=' + result.error : ''));
    } else {
      this.notifyMemoryChanged();
    }
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
    const deps: RequestPlanDeps = {
      tokenCounter: this.tokenCounter,
      historyTrimmer: this.historyTrimmer,
      contextBudgetService: this.contextBudgetService
    };
    const result: RequestPlanResult =
      await planRequest(requestMessages, effectiveSettings, this.currentChatId, deps);
    this.lastTokenBudget = result.budget;
    this.lastHistoryTrimResult = result.trimResult;
    if (result.trimmed) {
      // 更新 lastBuiltRequestMessages 为裁剪后的最终消息,
      // 让 UI 上下文占用统计反映实际发送给模型的内容。
      this.lastBuiltRequestMessages = result.finalMessages;
    }
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
      this.persistFinalAndCleanup(
        assistantId, context.operationId, context.kind,
        ChatState.Failed, callbacks, '请求启动超时,请重试', false
      );
    }, START_TIMEOUT_MS);
  }

  /**
   * 生成收尾公共尾部:持久化最终状态 → Swipe 标志 → 活跃时间 → 清理上下文 → 置终态 → 通知。
   * 供失败路径(handleStartFailure / onError / startStartTimer)与取消路径(stopGeneration)共用。
   * @param kind SwipeCandidate 时同步摘要生成标志;null 表示无活动上下文(stop 的 ctx 为空场景)。
   * @param errorMessage 非 null 表示失败路径(打失败日志并回调 onError);null 表示取消路径。
   * @param clearAssistantIdAfterPersist 是否在持久化完成后清空 currentAssistantId
   *        (stopGeneration 为 true;失败路径已在调用前清空,传 false 保持原时序)。
   */
  private persistFinalAndCleanup(
    assistantId: string | null,
    operationId: number,
    kind: ChatGenerationKind | null,
    finalState: ChatState,
    callbacks: ChatServiceCallbacks | null,
    errorMessage: string | null,
    clearAssistantIdAfterPersist: boolean
  ): void {
    this.persistFinalAssistant(assistantId).then((): void => {
      if (errorMessage !== null) {
        Logger.warn(LOG_TAG, 'GenerationFinal | kind=' + kind + ' stage=message_failed_persisted');
        Logger.warn(LOG_TAG, 'generation finalized status=failed');
      }
      if (kind === ChatGenerationKind.SwipeCandidate) {
        this.updateSwipeSummaryGeneratingFlag(false);
      }
      this.persistChatActivity();
      this.clearActiveGeneration(operationId);
      if (clearAssistantIdAfterPersist) {
        this.currentAssistantId = null;
      }
      this.setState(finalState, callbacks);
      if (errorMessage !== null && callbacks !== null) {
        callbacks.onError(errorMessage);
      }
    }).catch((_e: Object): void => {
      this.clearActiveGeneration(operationId);
      if (clearAssistantIdAfterPersist) {
        this.currentAssistantId = null;
      }
      this.setState(finalState, callbacks);
      if (errorMessage !== null && callbacks !== null) {
        callbacks.onError(errorMessage);
      }
    });
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
   * 候选激活公共执行块:互斥锁 + 持久化切换 + reload + 时间戳 + 记忆失效 + 通知。
   * activatePreviousCandidate / activateNextCandidate / activateCandidateIndex 共用;
   * 调用方已完成 canOperateSwipe / isBusy / 索引合法性校验。
   */
  private async doActivateCandidate(assistantMessageId: string, targetIndex: number): Promise<void> {
    if (this.swipePersistenceService === null || this.currentChatId === undefined) {
      return;
    }
    this.swipeOperationInProgress = true;
    try {
      await this.swipePersistenceService.activateCandidate(assistantMessageId, targetIndex);
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
    await this.doActivateCandidate(assistantMessageId, newIndex);
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
    await this.doActivateCandidate(assistantMessageId, newIndex);
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
    await this.doActivateCandidate(assistantMessageId, target);
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




  /**
   * 删除单条消息(聊天泡"删除"功能)。
   *
   * 规则:
   * - 首条消息(本会话开场白)不可删除,避免破坏会话结构
   * - 删除前失效覆盖该消息位置的记忆(章节/核心等,避免记忆引用已删内容)
   * - 若为 Assistant 消息,同步清理其 Swipe 候选数据
   * - 物理删除数据库记录并从内存列表移除
   *
   * @param messageId 待删除的消息 ID
   */
  async deleteMessage(messageId: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    if (this.isGenerating()) {
      throw new Error('请先停止当前回复');
    }
    if (this.swipeOperationInProgress) {
      throw new Error('请先完成当前 Swipe 操作');
    }
    const idx: number = this.findMessageIndexById(messageId);
    if (idx <= 0) {
      throw new Error('首条消息不可删除');
    }
    if (idx >= this.messages.length) {
      return;
    }
    // 删除前失效覆盖该位置的记忆(不阻塞删除)
    this.invalidateMemoryFromMessagePosition(messageId);
    // Assistant 消息:清理 Swipe 候选数据
    if (this.swipePersistenceService !== null) {
      try {
        await this.swipePersistenceService.removeSwipeState(messageId);
      } catch (e) {
        Logger.warn(LOG_TAG, 'deleteMessage | clear swipe failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }
    // 物理删除数据库记录
    if (this.persistenceService !== null) {
      await this.persistenceService.removeMessage(messageId);
    }
    // 移除内存列表(不可变更新:构造新数组并整体替换)
    const next: ChatMessage[] = this.messages.slice();
    next.splice(idx, 1);
    this.messages = next;
    if (this.currentAssistantId === messageId) {
      this.currentAssistantId = null;
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
    // 不可变更新:构造新数组并整体替换
    const next: ChatMessage[] = this.messages.slice();
    next[idx] = updated;
    this.messages = next;
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      await this.persistenceService.updateMessage(messageId, updated);
    }
  }

  /**
   * 编辑角色回复内容(仅改当前激活的文本,不重新生成)。
   *
   * - 仅对 Assistant 消息生效
   * - 编辑会改变剧情内容,因此失效覆盖该消息位置的记忆(与 re-swipe/删除一致)
   * - Swipe 候选记录保留不动(只更新激活消息本身)
   *
   * @param messageId 目标 Assistant 消息 ID
   * @param editedContent 编辑后的内容
   */
  async editAssistantMessage(messageId: string, editedContent: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ChatService disposed');
    }
    const idx: number = this.findMessageIndexById(messageId);
    if (idx < 0) {
      return;
    }
    const msg: ChatMessage = this.messages[idx];
    if (msg.role !== ChatRole.Assistant) {
      return;
    }
    const updated: ChatMessage = mergeChatMessage(msg, {
      content: editedContent,
      updatedAt: Date.now()
    });
    // 不可变更新:构造新数组并整体替换
    const next: ChatMessage[] = this.messages.slice();
    next[idx] = updated;
    this.messages = next;
    if (this.persistenceService !== null && this.currentChatId !== undefined) {
      await this.persistenceService.updateMessage(messageId, updated);
    }
    // 编辑内容会改变剧情,失效覆盖该位置的记忆(章节/核心等)
    this.invalidateMemoryFromMessagePosition(messageId);
  }
}
