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
import { MemoryService } from './MemoryService';
import { ContextBudgetService } from './ContextBudgetService';
import { ChatMemoryModeService } from './ChatMemoryModeService';
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
import { MessageSwipeSummary, MessageSwipeCandidateUpdates } from '../models/MessageSwipe';
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
import { ChatStatusState, ChatStatusEntry } from '../models/ChatStatusState';
import { ChatGenerationKind, ActiveGenerationContext } from '../models/ChatGenerationContext';
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
import { ChatStatusService, ChatStatusDeps, ChatStatusHost } from './ChatStatusService';
import { ChatSwipeController, ChatSwipeDeps, ChatSwipeHost } from './ChatSwipeController';
import { ConversationBranchService, ConversationBranchDeps, ConversationBranchHost } from './ConversationBranchService';
import { ChatMessageService, ChatMessageDeps, ChatMessageHost } from './ChatMessageService';
import { ChatContextMaintenanceService, ChatContextDeps, ChatContextHost } from './ChatContextMaintenanceService';
import { ChatSessionService, ChatSessionDeps, ChatSessionHost } from './ChatSessionService';
import { ChatMessageSender, ChatSendDeps, ChatSendHost } from './ChatMessageSender';
import {
  GLOBAL_USER_NAME_KEY,
  LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY,
  LOREBOOK_INJECTION_DEPTH_PREFS_KEY,
  MEMORY_KEYWORD_RETRIEVAL_PREFS_KEY,
  STICKY_REMINDER_MAX_ITEMS,
  DEFAULT_LOREBOOK_ACTIVATION_MODE,
  DEFAULT_LOREBOOK_INJECTION_DEPTH,
  pushFrontendInteractionRecord,
  buildFrontendInteractionText,
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
 * 聊天服务。
 * 生命周期跟随 ChatPage,dispose 后不可复用。
 */

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
  /** 角色状态簇(P2-3:自本类抽离,自带状态与宿主回调在构造期装配) */
  private readonly statusService: ChatStatusService;
  /** Swipe 浏览/切换簇(P2-4a:自本类抽离,状态仍在本类,经宿主回调读写) */
  private readonly swipeController: ChatSwipeController;
  /** Branch 查询/判定门面(P2-5:自本类抽离,状态仍在本类,经宿主回调读写) */
  private readonly branchService: ConversationBranchService;
  /** 消息级操作(删除/编辑)(P2-6:自本类抽离,状态仍在本类,经宿主回调读写) */
  private readonly messageService: ChatMessageService;
  /** 上下文维护(记忆总结/失效/世界书激活)(P2-7:自本类抽离,自带开关状态,经宿主回调读取) */
  private readonly contextMaintenance: ChatContextMaintenanceService;
  /** 会话生命周期(P2-9:自本类抽离,状态仍在本类,经宿主回调读写) */
  private readonly sessionService: ChatSessionService;
  /** 消息发起入口(P2-10:自本类抽离,状态仍在本类,经宿主回调读写) */
  private readonly messageSender: ChatMessageSender;

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

    const statusDeps: ChatStatusDeps = {
      modelService: this.modelService,
      persistenceService: this.persistenceService,
      appPreferences: this.appPreferences
    };
    const statusHost: ChatStatusHost = {
      isDisposed: (): boolean => this.disposed,
      isBusy: (): boolean => this.isBusy(),
      getCharacter: (): Character | null => this.character,
      getCurrentChat: (): Chat | null => this.currentChat,
      setCurrentChat: (chat: Chat | null): void => {
        this.currentChat = chat;
      },
      getCurrentChatId: (): string | undefined => this.currentChatId,
      getMessages: (): ChatMessage[] => this.messages,
      getLastCallbacks: (): ChatServiceCallbacks | null => this.lastCallbacks
    };
    this.statusService = new ChatStatusService(statusDeps, statusHost);

    const swipeDeps: ChatSwipeDeps = {
      swipePersistenceService: this.swipePersistenceService
    };
    const swipeHost: ChatSwipeHost = {
      isBusy: (): boolean => this.isBusy(),
      isGenerating: (): boolean => this.isGenerating(),
      getLastAssistantMessageId: (): string => this.lastAssistantMessageId,
      getSwipeSummaries: (): MessageSwipeSummary[] => this.swipeSummaries,
      setSwipeSummaries: (summaries: MessageSwipeSummary[]): void => {
        this.swipeSummaries = summaries;
      },
      getSwipeOperationInProgress: (): boolean => this.swipeOperationInProgress,
      setSwipeOperationInProgress: (inProgress: boolean): void => {
        this.swipeOperationInProgress = inProgress;
      },
      getCurrentChatId: (): string | undefined => this.currentChatId,
      getLastCallbacks: (): ChatServiceCallbacks | null => this.lastCallbacks,
      reloadCurrentSession: (): Promise<void> => this.reloadCurrentSession(),
      updateLastAssistantMessageId: (): void => this.updateLastAssistantMessageId(),
      persistChatTimestamp: (): void => this.persistChatTimestamp(),
      invalidateMemoryFromMessagePosition: (assistantMessageId: string): void => {
        this.invalidateMemoryFromMessagePosition(assistantMessageId);
      },
      emitMessages: (callbacks: ChatServiceCallbacks | null): void => {
        this.emitMessages(callbacks);
      },
      isDisposed: (): boolean => this.disposed,
      getGenerationOperationId: (): number => this.generationOperationId,
      setGenerationOperationId: (operationId: number): void => {
        this.generationOperationId = operationId;
      },
      getActiveGeneration: (): ActiveGenerationContext | null => this.activeGeneration,
      setActiveGeneration: (context: ActiveGenerationContext | null): void => {
        this.activeGeneration = context;
      },
      getCurrentAssistantId: (): string | null => this.currentAssistantId,
      setCurrentAssistantId: (assistantId: string | null): void => {
        this.currentAssistantId = assistantId;
      },
      getMessages: (): ChatMessage[] => this.messages,
      setMessages: (messages: ChatMessage[]): void => {
        this.messages = messages;
      },
      getLastPersistedContentLength: (): number => this.lastPersistedContentLength,
      setLastPersistedContentLength: (length: number): void => {
        this.lastPersistedContentLength = length;
      },
      getPendingPersistAssistantId: (): string | null => this.pendingPersistAssistantId,
      setPendingPersistAssistantId: (assistantId: string | null): void => {
        this.pendingPersistAssistantId = assistantId;
      },
      setState: (state: ChatState, callbacks: ChatServiceCallbacks | null): void => {
        this.setState(state, callbacks);
      },
      doStream: (assistantId: string, callbacks: ChatServiceCallbacks,
        context: ActiveGenerationContext): Promise<void> =>
        this.doStream(assistantId, callbacks, context)
    };
    this.swipeController = new ChatSwipeController(swipeDeps, swipeHost);

    const branchDeps: ConversationBranchDeps = {
      branchPersistenceService: this.branchPersistenceService,
      swipePersistenceService: this.swipePersistenceService,
      persistenceService: this.persistenceService
    };
    const branchHost: ConversationBranchHost = {
      isDisposed: (): boolean => this.disposed,
      isBusy: (): boolean => this.isBusy(),
      getCurrentChatId: (): string | undefined => this.currentChatId,
      getCurrentAssistantId: (): string | null => this.currentAssistantId,
      getMessages: (): ChatMessage[] => this.messages,
      findMessageById: (id: string): ChatMessage | undefined => this.findMessageById(id),
      getBranches: (): ConversationBranchSummary[] => this.branches,
      setBranches: (branches: ConversationBranchSummary[]): void => {
        this.branches = branches;
      },
      getActiveBranchId: (): string => this.activeBranchId,
      setActiveBranchId: (branchId: string): void => {
        this.activeBranchId = branchId;
      },
      getRecordCounts: (): ConversationRecordCounts | undefined => this.recordCounts,
      setRecordCounts: (counts: ConversationRecordCounts | undefined): void => {
        this.recordCounts = counts;
      },
      getBranchOperationInProgress: (): boolean => this.branchOperationInProgress,
      setBranchOperationInProgress: (inProgress: boolean): void => {
        this.branchOperationInProgress = inProgress;
      },
      getSwipeSummaries: (): MessageSwipeSummary[] => this.swipeSummaries,
      setSwipeSummaries: (summaries: MessageSwipeSummary[]): void => {
        this.swipeSummaries = summaries;
      },
      reloadCurrentSession: (): Promise<void> => this.reloadCurrentSession(),
      updateLastAssistantMessageId: (): void => this.updateLastAssistantMessageId(),
      getLastCallbacks: (): ChatServiceCallbacks | null => this.lastCallbacks,
      setLastCallbacks: (callbacks: ChatServiceCallbacks | null): void => {
        this.lastCallbacks = callbacks;
      },
      setState: (state: ChatState, callbacks: ChatServiceCallbacks | null): void => {
        this.setState(state, callbacks);
      },
      emitMessages: (callbacks: ChatServiceCallbacks | null): void => {
        this.emitMessages(callbacks);
      },
      getState: (): ChatState => this.state,
      getSwipeOperationInProgress: (): boolean => this.swipeOperationInProgress,
      getSessionOperationInProgress: (): boolean => this.sessionOperationInProgress,
      canRegenerate: (): boolean => this.canRegenerate(),
      getLastAssistantMessageId: (): string => this.lastAssistantMessageId,
      getActiveGeneration: (): ActiveGenerationContext | null => this.activeGeneration,
      setActiveGeneration: (context: ActiveGenerationContext | null): void => {
        this.activeGeneration = context;
      },
      setCurrentAssistantId: (assistantId: string | null): void => {
        this.currentAssistantId = assistantId;
      },
      setMessages: (messages: ChatMessage[]): void => {
        this.messages = messages;
      },
      getSummaryForMessage: (messageId: string): MessageSwipeSummary | undefined =>
        this.getSummaryForMessage(messageId),
      getGenerationOperationId: (): number => this.generationOperationId,
      setGenerationOperationId: (operationId: number): void => {
        this.generationOperationId = operationId;
      },
      getLastPersistedContentLength: (): number => this.lastPersistedContentLength,
      setLastPersistedContentLength: (length: number): void => {
        this.lastPersistedContentLength = length;
      },
      getPendingPersistAssistantId: (): string | null => this.pendingPersistAssistantId,
      setPendingPersistAssistantId: (assistantId: string | null): void => {
        this.pendingPersistAssistantId = assistantId;
      },
      doStream: (assistantId: string, callbacks: ChatServiceCallbacks,
        context: ActiveGenerationContext): Promise<void> =>
        this.doStream(assistantId, callbacks, context)
    };
    this.branchService = new ConversationBranchService(branchDeps, branchHost);

    const messageDeps: ChatMessageDeps = {
      persistenceService: this.persistenceService,
      swipePersistenceService: this.swipePersistenceService
    };
    const messageHost: ChatMessageHost = {
      isDisposed: (): boolean => this.disposed,
      isGenerating: (): boolean => this.isGenerating(),
      getSwipeOperationInProgress: (): boolean => this.swipeOperationInProgress,
      getMessages: (): ChatMessage[] => this.messages,
      setMessages: (messages: ChatMessage[]): void => {
        this.messages = messages;
      },
      getCurrentAssistantId: (): string | null => this.currentAssistantId,
      setCurrentAssistantId: (assistantId: string | null): void => {
        this.currentAssistantId = assistantId;
      },
      getCurrentChatId: (): string | undefined => this.currentChatId,
      findMessageIndexById: (messageId: string): number => this.findMessageIndexById(messageId),
      invalidateMemoryFromMessagePosition: (messageId: string): void => {
        this.invalidateMemoryFromMessagePosition(messageId);
      }
    };
    this.messageService = new ChatMessageService(messageDeps, messageHost);

    const contextDeps: ChatContextDeps = {
      memoryService: this.memoryService,
      chatMemoryModeService: this.chatMemoryModeService,
      lorebookService: this.lorebookService,
      lorebookPinService: this.lorebookPinService,
      lorebookStickyService: this.lorebookStickyService,
      appPreferences: this.appPreferences
    };
    const contextHost: ChatContextHost = {
      getCurrentChatId: (): string | undefined => this.currentChatId,
      getActiveBranchId: (): string => this.activeBranchId,
      getMessages: (): ChatMessage[] => this.messages,
      getCharacter: (): Character | null => this.character,
      getLorebookActivationDefault: (): LorebookActivationMode => this.lorebookActivationDefault
    };
    this.contextMaintenance = new ChatContextMaintenanceService(contextDeps, contextHost);
    const sessionDeps: ChatSessionDeps = {
      persistenceService: this.persistenceService,
      swipePersistenceService: this.swipePersistenceService,
      appPreferences: this.appPreferences
    };
    const sessionHost: ChatSessionHost = {
      getCharacter: (): Character | null => this.character,
      getCurrentChatId: (): string | undefined => this.currentChatId,
      setSwipeSummaries: (summaries: MessageSwipeSummary[]): void => {
        this.swipeSummaries = summaries;
      },
      setLastAssistantMessageId: (assistantMessageId: string): void => {
        this.lastAssistantMessageId = assistantMessageId;
      },
      updateLastAssistantMessageId: (): void => this.updateLastAssistantMessageId(),
      setLorebookActivationDefault: (mode: LorebookActivationMode): void => {
        this.lorebookActivationDefault = mode;
      },
      setLorebookInjectionDepth: (depth: number): void => {
        this.lorebookInjectionDepth = depth;
      },
      setCharacter: (character: Character | null): void => {
        this.character = character;
      },
      setCurrentChatId: (chatId: string | undefined): void => {
        this.currentChatId = chatId;
      },
      setCurrentChat: (chat: Chat | null): void => {
        this.currentChat = chat;
      },
      setMessages: (messages: ChatMessage[]): void => {
        this.messages = messages;
      },
      setCurrentSequenceNumber: (sequenceNumber: number): void => {
        this.currentSequenceNumber = sequenceNumber;
      },
      getContextInitialized: (): boolean => this.contextInitialized,
      setContextInitialized: (initialized: boolean): void => {
        this.contextInitialized = initialized;
      },
      getInitializingPromise: (): Promise<void> | null => this.initializingPromise,
      setInitializingPromise: (promise: Promise<void> | null): void => {
        this.initializingPromise = promise;
      },
      isDisposed: (): boolean => this.disposed,
      syncStatusSchemaFromCharacter: (): void => this.syncStatusSchemaFromCharacter(),
      syncStatusStateFromCurrentChat: (): void => this.syncStatusStateFromCurrentChat(),
      clearFrontendInteractions: (): void => this.clearFrontendInteractions(),
      loadMemoryAutoSummaryPref: (): Promise<void> => this.loadMemoryAutoSummaryPref(),
      loadStatusInstructionPref: (): Promise<void> => this.loadStatusInstructionPref(),
      loadMemoryPrefs: (): Promise<void> => this.loadMemoryPrefs(),
      refreshBranchState: (): Promise<void> => this.refreshBranchState(),
      getSessionOperationInProgress: (): boolean => this.sessionOperationInProgress,
      setSessionOperationInProgress: (inProgress: boolean): void => {
        this.sessionOperationInProgress = inProgress;
      },
      getSwipeOperationInProgress: (): boolean => this.swipeOperationInProgress,
      isGenerating: (): boolean => this.isGenerating(),
      flushPersistence: (): void => this.flushPersistence(),
      getCurrentChat: (): Chat | null => this.currentChat,
      getLastCallbacks: (): ChatServiceCallbacks | null => this.lastCallbacks,
      setState: (state: ChatState, callbacks: ChatServiceCallbacks | null): void => {
        this.setState(state, callbacks);
      },
      emitMessages: (callbacks: ChatServiceCallbacks | null): void => {
        this.emitMessages(callbacks);
      },
      setLastTokenBudget: (budget: TokenBudget | undefined): void => {
        this.lastTokenBudget = budget;
      },
      setLastHistoryTrimResult: (result: HistoryTrimResult | undefined): void => {
        this.lastHistoryTrimResult = result;
      },
      setCurrentAssistantId: (assistantId: string | null): void => {
        this.currentAssistantId = assistantId;
      },
      setActiveGeneration: (context: ActiveGenerationContext | null): void => {
        this.activeGeneration = context;
      }
    };
    this.sessionService = new ChatSessionService(sessionDeps, sessionHost);

    const sendDeps: ChatSendDeps = {
      persistenceService: this.persistenceService
    };
    const sendHost: ChatSendHost = {
      isDisposed: (): boolean => this.disposed,
      isBusy: (): boolean => this.isBusy(),
      getState: (): ChatState => this.state,
      getLastCallbacks: (): ChatServiceCallbacks | null => this.lastCallbacks,
      setLastCallbacks: (callbacks: ChatServiceCallbacks | null): void => {
        this.lastCallbacks = callbacks;
      },
      getGenerationOperationId: (): number => this.generationOperationId,
      setGenerationOperationId: (operationId: number): void => {
        this.generationOperationId = operationId;
      },
      getCurrentChatId: (): string | undefined => this.currentChatId,
      setCurrentSequenceNumber: (sequenceNumber: number): void => {
        this.currentSequenceNumber = sequenceNumber;
      },
      setLastPersistedContentLength: (length: number): void => {
        this.lastPersistedContentLength = length;
      },
      setPendingPersistAssistantId: (assistantId: string | null): void => {
        this.pendingPersistAssistantId = assistantId;
      },
      setState: (state: ChatState, callbacks: ChatServiceCallbacks | null): void => {
        this.setState(state, callbacks);
      },
      getMessages: (): ChatMessage[] => this.messages,
      setMessages: (messages: ChatMessage[]): void => {
        this.messages = messages;
      },
      setCurrentAssistantId: (assistantId: string | null): void => {
        this.currentAssistantId = assistantId;
      },
      getActiveGeneration: (): ActiveGenerationContext | null => this.activeGeneration,
      setActiveGeneration: (context: ActiveGenerationContext | null): void => {
        this.activeGeneration = context;
      },
      emitMessages: (callbacks: ChatServiceCallbacks | null): void => {
        this.emitMessages(callbacks);
      },
      doStream: (assistantId: string, callbacks: ChatServiceCallbacks,
        context: ActiveGenerationContext): Promise<void> =>
        this.doStream(assistantId, callbacks, context),
      isGenerating: (): boolean => this.isGenerating(),
      stopGeneration: (): void => this.stopGeneration()
    };
    this.messageSender = new ChatMessageSender(sendDeps, sendHost);
  }

  /** 初始化角色聊天上下文(无持久化版本;委托 ChatSessionService)。 */
  initContext(character: Character | null): boolean {
    return this.sessionService.initContext(character);
  }

  /** 异步初始化会话(持久化版本;委托 ChatSessionService)。 */
  async initializeSession(character?: Character, forceNew: boolean = false): Promise<void> {
    return this.sessionService.initializeSession(character, forceNew);
  }

  /** 构建开场白池(委托 ChatSessionService)。 */
  private buildGreetingPool(): string[] {
    return this.sessionService.buildGreetingPool();
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

  /** 新建章节(世界分组内切换开场白;委托 ChatSessionService)。 */
  async createChapter(greetingIndex: number): Promise<string> {
    return this.sessionService.createChapter(greetingIndex);
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

  /** 发送用户消息并开始流式生成(委托 ChatMessageSender)。 */
  async sendMessage(userContent: string, callbacks: ChatServiceCallbacks): Promise<void> {
    return this.messageSender.sendMessage(userContent, callbacks);
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

  /** Narrator:用户输入旁白文本,AI 以旁白身份回复(委托 ChatMessageSender)。 */
  async narratorMessage(content: string, callbacks: ChatServiceCallbacks): Promise<void> {
    return this.messageSender.narratorMessage(content, callbacks);
  }

  /** Narrator-Only:仅插入旁白描述消息,不触发 AI 生成(委托 ChatMessageSender)。 */
  async narratorMessageOnly(content: string, callbacks: ChatServiceCallbacks): Promise<void> {
    return this.messageSender.narratorMessageOnly(content, callbacks);
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

  /** 重新生成最后一条 Assistant 回复(创建 Conversation Branch 并流式生成;委托 ConversationBranchService)。 */
  async regenerateLastResponse(callbacks: ChatServiceCallbacks): Promise<void> {
    return this.branchService.regenerateLastResponse(callbacks);
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

  /** 清空当前对话(委托 ChatMessageSender)。 */
  clearConversation(): void {
    this.messageSender.clearConversation();
  }

  // ===== T-4.5 多会话操作 =====

  /** 会话操作进行中(防止并发新建/切换/删除) */
  private sessionOperationInProgress: boolean = false;

  /** 列出当前聊天上下文下的会话(委托 ChatSessionService)。 */
  async listSessions(): Promise<Chat[]> {
    return this.sessionService.listSessions();
  }

  /** 新建会话(委托 ChatSessionService)。 */
  async startNewSession(): Promise<void> {
    return this.sessionService.startNewSession();
  }

  /** 切换到指定会话(委托 ChatSessionService)。 */
  async switchSession(chatId: string): Promise<void> {
    return this.sessionService.switchSession(chatId);
  }

  /** 删除指定会话(委托 ChatSessionService)。 */
  async deleteSession(chatId: string): Promise<void> {
    return this.sessionService.deleteSession(chatId);
  }

  /**
   * 是否正在执行会话操作(新建/切换/删除)。
   * 用于页面禁用按钮。
   */
  isSessionOperationInProgress(): boolean {
    return this.sessionOperationInProgress;
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

  // ===== CHAT-STATUS-1A: 角色状态(实现已抽至 services/ChatStatusService,P2-3) =====

  /**
   * 获取当前会话的角色状态(只读)。
   */
  getChatStatusState(): ChatStatusState {
    return this.statusService.getChatStatusState();
  }

  /**
   * 返回当前角色卡的状态 Schema JSON(arktavern-card-extensions v1)。
   * 空数组 JSON '[]'(无声明/状态功能禁用)。
   */
  getStatusSchemaJson(): string {
    return this.statusService.getStatusSchemaJson();
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

  /** CHAT-STATUS-1A: 请求下一次回复重新生成/优化角色状态字段(委托 ChatStatusService)。 */
  requestStatusFieldGeneration(): void {
    this.statusService.requestStatusFieldGeneration();
  }

  /** 更新角色状态:归一(锁字段/未声明字段丢弃)后持久化并通知 UI(委托 ChatStatusService)。 */
  updateStatusState(next: ChatStatusState): void {
    this.statusService.updateStatusState(next);
  }

  /** 从当前会话的 statusConfigJson 同步内存状态(委托 ChatStatusService)。 */
  private syncStatusStateFromCurrentChat(): void {
    this.statusService.syncStatusStateFromCurrentChat();
  }

  /** 从当前角色卡解析声明式状态 Schema(委托 ChatStatusService)。 */
  private syncStatusSchemaFromCharacter(): void {
    this.statusService.syncStatusSchemaFromCharacter();
  }

  /** 合并 AI 本轮输出的状态字段并持久化、通知 UI(委托 ChatStatusService)。 */
  private applyStatusUpdate(
    parsedEntries: ChatStatusEntry[],
    callbacks: ChatServiceCallbacks
  ): void {
    this.statusService.applyStatusUpdate(parsedEntries, callbacks);
  }

  /** CHAT-STATUS-1A: 立即生成/优化角色状态字段(独立的一次性请求;委托 ChatStatusService)。 */
  async generateStatusFieldsNow(): Promise<ChatStatusState | null> {
    return this.statusService.generateStatusFieldsNow();
  }

  /** CHAT-STATUS-1A: 按用户指令立即修改角色状态字段(委托 ChatStatusService)。 */
  async modifyStatusWithPrompt(prompt: string): Promise<ChatStatusState | null> {
    return this.statusService.modifyStatusWithPrompt(prompt);
  }

  /** 设置状态输出指令开关(委托 ChatStatusService)。 */
  setStatusInstructionEnabled(enabled: boolean): void {
    this.statusService.setStatusInstructionEnabled(enabled);
  }

  /** 获取状态输出指令开关状态(委托 ChatStatusService)。 */
  isStatusInstructionEnabled(): boolean {
    return this.statusService.isStatusInstructionEnabled();
  }

  /** 加载状态输出指令开关偏好(委托 ChatStatusService)。 */
  private async loadStatusInstructionPref(): Promise<void> {
    return this.statusService.loadStatusInstructionPref();
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

  // ===== 上下文维护(记忆总结 / 记忆失效 / 世界书激活刷新,实现已抽至 services/ChatContextMaintenanceService,P2-7) =====

  /** Prompt Cache:手动触发记忆总结(强制生成章节并刷新世界书激活;委托 ChatContextMaintenanceService)。 */
  triggerManualMemorySummary(): void {
    this.contextMaintenance.triggerManualMemorySummary();
  }

  /** 手动刷新世界书激活内容(按模式分派 Pin/Sticky;委托 ChatContextMaintenanceService)。 */
  refreshLorebookPinNow(): Promise<boolean> {
    return this.contextMaintenance.refreshLorebookPinNow();
  }

  /** Prompt Cache:设置自动记忆总结开关(委托 ChatContextMaintenanceService)。 */
  setMemoryAutoSummaryEnabled(enabled: boolean): void {
    this.contextMaintenance.setMemoryAutoSummaryEnabled(enabled);
  }

  /** 自动记忆总结开关状态(委托 ChatContextMaintenanceService)。 */
  isMemoryAutoSummaryEnabled(): boolean {
    return this.contextMaintenance.isMemoryAutoSummaryEnabled();
  }

  /** CHAT-STATUS-1A: 追加角色状态**当前值** system message(委托 ChatStatusService)。 */
  private appendStatusValuesMessage(messages: ChatMessage[]): ChatMessage[] {
    return this.statusService.appendStatusValuesMessage(messages);
  }

  /** 构建状态**稳定段**文本(格式规则 + 字段清单;委托 ChatStatusService)。 */
  private buildStatusRule(): string {
    return this.statusService.buildStatusRule();
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
      this.statusService.resetFieldGenerationRequest();
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





  /** 异步触发长期记忆增量总结(委托 ChatContextMaintenanceService)。 */
  private triggerMemorySummaryAsync(): void {
    this.contextMaintenance.triggerMemorySummaryAsync();
  }

  /** 失效覆盖指定消息位置的记忆(软失效;委托 ChatContextMaintenanceService)。 */
  private invalidateMemoryFromMessagePosition(messageId: string): void {
    this.contextMaintenance.invalidateMemoryFromMessagePosition(messageId);
  }

  /** 加载自动记忆总结开关(全局偏好;委托 ChatContextMaintenanceService)。 */
  private async loadMemoryAutoSummaryPref(): Promise<void> {
    return this.contextMaintenance.loadMemoryAutoSummaryPref();
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

  // ===== Swipe 公开方法(实现已抽至 services/ChatSwipeController,P2-4a) =====

  /** 获取当前会话的 Swipe 摘要列表(副本;委托 ChatSwipeController)。 */
  getSwipeSummaries(): MessageSwipeSummary[] {
    return this.swipeController.getSwipeSummaries();
  }

  /** 获取指定 Assistant 消息的 Swipe 摘要(委托 ChatSwipeController)。 */
  getSwipeSummary(assistantMessageId: string): MessageSwipeSummary | undefined {
    return this.swipeController.getSwipeSummary(assistantMessageId);
  }

  /** 判断指定 Assistant 消息是否可操作 Swipe(只允许非生成状态下操作最后一条;委托 ChatSwipeController)。 */
  canOperateSwipe(assistantMessageId: string): boolean {
    return this.swipeController.canOperateSwipe(assistantMessageId);
  }

  /** 激活前一个候选(委托 ChatSwipeController)。 */
  async activatePreviousCandidate(assistantMessageId: string): Promise<void> {
    return this.swipeController.activatePreviousCandidate(assistantMessageId);
  }

  /** 激活下一个候选(委托 ChatSwipeController)。 */
  async activateNextCandidate(assistantMessageId: string): Promise<void> {
    return this.swipeController.activateNextCandidate(assistantMessageId);
  }

  /** 激活指定索引的候选(开场白选择等显式索引切换;委托 ChatSwipeController)。 */
  async activateCandidateIndex(assistantMessageId: string, index: number): Promise<void> {
    return this.swipeController.activateCandidateIndex(assistantMessageId, index);
  }

  /**
   * 为最后一条 Assistant 消息生成新的候选回复(委托 ChatSwipeController)。
   * 内部创建 Streaming 候选并启动流式请求(携带 SwipeCandidate 活动上下文)。
   */
  async generateAlternativeCandidate(): Promise<void> {
    return this.swipeController.generateAlternativeCandidate();
  }

  // ===== Swipe 内部辅助方法 =====

  /** 获取指定消息的 Swipe 摘要(委托 ChatSwipeController)。 */
  private getSummaryForMessage(messageId: string): MessageSwipeSummary | undefined {
    return this.swipeController.getSummaryForMessage(messageId);
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

  // ===== T-6.4B-1 Branch 公开方法(查询与判定已抽至 services/ConversationBranchService,P2-5) =====

  /** 获取 Branch 列表(副本;委托 ConversationBranchService)。 */
  getBranches(): ConversationBranchSummary[] {
    return this.branchService.getBranches();
  }

  /** 获取当前活动 Branch ID(委托 ConversationBranchService)。 */
  getActiveBranchId(): string {
    return this.branchService.getActiveBranchId();
  }

  /** 获取 Branch 记录数量统计(委托 ConversationBranchService)。 */
  getRecordCounts(): ConversationRecordCounts | undefined {
    return this.branchService.getRecordCounts();
  }

  /** 是否正在执行 Branch 操作(创建 Child / 切换;委托 ConversationBranchService)。 */
  isBranchOperating(): boolean {
    return this.branchService.isBranchOperating();
  }

  /** 判断指定 Assistant 消息是否可"从此处继续"创建 Child Branch(委托 ConversationBranchService)。 */
  canContinueFromAssistant(messageId: string): boolean {
    return this.branchService.canContinueFromAssistant(messageId);
  }

  /** 刷新 Branch 状态(branches / activeBranchId / recordCounts;委托 ConversationBranchService)。 */
  async refreshBranchState(): Promise<void> {
    return this.branchService.refreshBranchState();
  }

  /** 从历史 Assistant 创建 Child Branch(从此处继续;委托 ConversationBranchService)。 */
  async continueFromAssistant(
    messageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    return this.branchService.continueFromAssistant(messageId, callbacks);
  }

  /** 判断指定 User 消息是否可"从此处生成新回复"创建 Branch(委托 ConversationBranchService)。 */
  canGenerateFromUserMessage(messageId: string): boolean {
    return this.branchService.canGenerateFromUserMessage(messageId);
  }

  /** 判断指定历史 Assistant 消息是否可"重新生成此回复"(委托 ConversationBranchService)。 */
  canRegenerateAssistantMessage(messageId: string): boolean {
    return this.branchService.canRegenerateAssistantMessage(messageId);
  }

  /** 历史 Assistant"重新生成此回复"(fork 新 Branch 并流式生成;委托 ConversationBranchService)。 */
  async regenerateAssistantMessage(
    messageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    return this.branchService.regenerateAssistantMessage(messageId, callbacks);
  }

  /** 从历史 User 消息生成新回复(创建新 Branch 并启动 Provider;委托 ConversationBranchService)。 */
  async generateFromUserMessage(
    userMessageId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    return this.branchService.generateFromUserMessage(userMessageId, callbacks);
  }

  /** 判断指定历史 User 消息是否可"编辑"(委托 ConversationBranchService)。 */
  canEditUserMessage(messageId: string): boolean {
    return this.branchService.canEditUserMessage(messageId);
  }

  /** 编辑历史 User Message 并创建新 Branch + Streaming Assistant(委托 ConversationBranchService)。 */
  async editUserMessageAndGenerate(
    messageId: string,
    editedContent: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    return this.branchService.editUserMessageAndGenerate(messageId, editedContent, callbacks);
  }

  /** 切换 Active Branch 到 targetBranchId(事务内物化候选并同步;委托 ConversationBranchService)。 */
  async switchBranch(
    targetBranchId: string,
    callbacks: ChatServiceCallbacks
  ): Promise<void> {
    return this.branchService.switchBranch(targetBranchId, callbacks);
  }

  /** 外部 Branch 切换后重新加载当前会话并通知 UI(委托 ConversationBranchService)。 */
  async reloadAfterExternalBranchChange(callbacks: ChatServiceCallbacks): Promise<void> {
    return this.branchService.reloadAfterExternalBranchChange(callbacks);
  }




  // ===== 消息级操作(删除 / 编辑,实现已抽至 services/ChatMessageService,P2-6) =====

  /** 删除单条消息(委托 ChatMessageService)。 */
  async deleteMessage(messageId: string): Promise<void> {
    return this.messageService.deleteMessage(messageId);
  }

  /** 编辑旁白消息(仅 senderType=narrator 生效;委托 ChatMessageService)。 */
  async editNarratorMessage(messageId: string, editedContent: string): Promise<void> {
    return this.messageService.editNarratorMessage(messageId, editedContent);
  }

  /** 编辑角色回复内容(仅改当前激活文本,不重新生成;委托 ChatMessageService)。 */
  async editAssistantMessage(messageId: string, editedContent: string): Promise<void> {
    return this.messageService.editAssistantMessage(messageId, editedContent);
  }
}
