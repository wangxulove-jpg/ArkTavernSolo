/**
 * ChatViewModel 聊天页面状态管理
 *
 * 页面与 ChatService 之间的唯一桥梁。
 * 页面不直接处理流式 handle、不直接调用 Provider/KeyStore/ConfigStore。
 *
 * 设计原则:
 * - @Observed 装饰,ArkUI 可直接绑定
 * - 只调用 ChatService
 * - send 防止重复点击
 * - 空输入不能发送
 * - 无当前模型时不能发送
 * - 初始化时读取当前配置
 * - 页面退出时调用 dispose
 * - 不出现 @Builder 参数导致状态不刷新的问题
 * - messages 始终以新引用赋值,确保 ArkUI 检测到变化
 */

import { ChatService, ChatState, ChatServiceCallbacks } from '../services/ChatService';
import { ModelService } from '../services/ModelService';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { Chat } from '../models/Chat';
import {
  ChatStatusState,
  ChatStatusEntry,
  createEmptyChatStatusState,
  createChatStatusEntry
} from '../models/ChatStatusState';
import { ProviderConfig } from '../models/ProviderConfig';
import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import { PromptPresetService } from '../services/PromptPresetService';
import { PromptPreset } from '../models/PromptPreset';
import { ImpersonateCandidate } from '../models/ImpersonateCandidate';
import { Logger } from '../utils/Logger';
import { MessageSwipeSummary } from '../models/MessageSwipe';
import { TokenBudget } from '../models/TokenBudget';
import { AppServices } from '../services/AppServices';
import { LorebookService } from '../services/LorebookService';
import { Lorebook, LorebookEntry, LorebookPosition, LorebookEntryUpdates } from '../models/Lorebook';
import { AiLorebookService, AiLorebookMode, AiLorebookInput } from '../services/ai/AiLorebookService';
import {
  AiLorebookChangeSet,
  AiLorebookAdd,
  AiLorebookUpdate,
  AiLorebookDelete
} from '../models/LorebookAiTypes';
import {
  ConversationBranchSummary,
  ConversationRecordCounts
} from '../models/ConversationBranch';

const LOG_TAG: string = 'ChatViewModel';

/**
 * 世界书面板单本书展示数据。
 */
export interface LorebookPanelBook {
  readonly lorebookId: string;
  readonly name: string;
  readonly isCharacterBook: boolean;
  readonly entries: LorebookEntry[];
}

/**
 * 世界书面板展示数据(角色专属书在前,全局书在后)。
 */
export interface LorebookPanelData {
  readonly books: LorebookPanelBook[];
}

@Observed
export class ChatViewModel {
  messages: ChatMessage[] = [];
  statusState: ChatStatusState = createEmptyChatStatusState();
  lorebookPanelData: LorebookPanelData | null = null;
  inputText: string = '';
  isGenerating: boolean = false;
  statusMessage: string = '';
  errorMessage: string = '';
  currentModelName: string = '';
  characterName: string = '';
  currentPresetName: string = '';
  hasCurrentModel: boolean = false;
  canRegenerate: boolean = false;
  userScrolledUp: boolean = false;
  copyToast: string = '';
  isInitializing: boolean = true;
  isSessionReady: boolean = false;
  initError: string = '';
  swipeSummaries: MessageSwipeSummary[] = [];
  isSwipeOperating: boolean = false;
  swipeError: string = '';

  // ===== 代写候选状态 =====
  impersonateCandidates: ImpersonateCandidate[] = [];
  isImpersonateGenerating: boolean = false;

  // ===== 用户性格总结状态 =====
  isExtractingUserPersona: boolean = false;
  isSummarizingUserPersona: boolean = false;

  // ===== T-4.5 会话列表状态 =====
  sessions: Chat[] = [];
  showSessionList: boolean = false;
  isLoadingSessions: boolean = false;
  isSessionOperating: boolean = false;
  sessionError: string = '';
  pendingDeleteChatId: string = '';
  showDeleteSessionConfirm: boolean = false;

  // ===== T-6.4B-1 Branch 状态 =====
  branches: ConversationBranchSummary[] = [];
  activeBranchId: string = '';
  recordCounts: ConversationRecordCounts | undefined = undefined;
  isBranchOperating: boolean = false;
  showBranchList: boolean = false;

  // ===== Prompt Cache 命中率 =====
  lastCachedTokens: number | undefined = undefined;
  lastPromptTokens: number | undefined = undefined;
  lastCacheHitRatio: number | undefined = undefined;

  private chatService: ChatService;
  private modelService: ModelService;
  private characterService: CharacterService;
  private promptPresetService: PromptPresetService;
  private disposed: boolean = false;
  private aiLorebookService: AiLorebookService | null = null;

  // ===== 流式 UI 节流(避免高频 delta 在同一事件循环 tick 内被 ArkUI 合并) =====
  private flushTimerId: number = -1;
  private lastFlushTime: number = 0;
  private static readonly FLUSH_INTERVAL_MS: number = 16;

  onMessagesUpdate?: (messages: ChatMessage[]) => void;
  onStatusUpdate?: (state: ChatStatusState) => void;
  onCacheStatsUpdate?: (cachedTokens: number, promptTokens: number, hitRatio: number) => void;

  constructor(
    chatService: ChatService,
    modelService: ModelService,
    characterService: CharacterService,
    promptPresetService: PromptPresetService
  ) {
    this.chatService = chatService;
    this.modelService = modelService;
    this.characterService = characterService;
    this.promptPresetService = promptPresetService;
  }

  get canSend(): boolean {
    return !this.busy && this.hasCurrentModel && this.inputText.trim().length > 0
      && this.isSessionReady;
  }

  get canStop(): boolean {
    return this.isGenerating;
  }

  get busy(): boolean {
    return this.isGenerating || this.isSwipeOperating || this.isBranchOperating
      || this.isImpersonateGenerating;
  }

  async initialize(characterId?: string, forceNew: boolean = false): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isInitializing = true;
    this.isSessionReady = false;
    this.initError = '';

    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config !== null && config.enabled) {
        this.hasCurrentModel = true;
        this.currentModelName = config.name + ' · ' + config.modelName;
      } else if (config !== null && !config.enabled) {
        this.hasCurrentModel = false;
        this.currentModelName = '模型已禁用';
      } else {
        this.hasCurrentModel = false;
        this.currentModelName = '尚未配置模型';
      }
    } catch (e) {
      this.hasCurrentModel = false;
      this.currentModelName = '加载配置失败';
      Logger.error(LOG_TAG, 'initialize model config failed: ' + String(e));
    }

    let character: Character | null = null;
    try {
      if (characterId !== undefined && characterId.length > 0) {
        character = await this.characterService.getById(characterId);
      } else {
        character = await this.characterService.getCurrentCharacter();
      }
      if (character !== null) {
        this.characterName = character.name;
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'load character failed: ' + String(e));
    }

    await this.refreshCurrentPresetName();

    try {
      await this.chatService.initializeSession(
        character !== null ? character : undefined,
        forceNew
      );
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.syncStatusState();
      this.isSessionReady = true;
      this.canRegenerate = this.chatService.canRegenerate();
      await this.refreshBranchState();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.initError = '会话初始化失败,请重试';
      Logger.error(LOG_TAG, 'initializeSession failed: ' + msg);
    } finally {
      this.isInitializing = false;
    }
  }

  async send(): Promise<void> {
    if (this.disposed || !this.canSend) {
      return;
    }
    const content: string = this.inputText;
    if (content.trim().length === 0) {
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = true;
    this.canRegenerate = false;
    this.userScrolledUp = false;

    const callbacks: ChatServiceCallbacks = this.createCallbacks();

    try {
      await this.chatService.sendMessage(content, callbacks);
      this.inputText = '';
    } catch (e) {
      this.isGenerating = false;
      this.errorMessage = this.toUserError(String(e));
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'send failed: ' + String(e));
    }
  }

  async regenerate(): Promise<void> {
    if (this.disposed) {
      return;
    }
    if (this.busy) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | busy');
      return;
    }
    if (!this.canRegenerate) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | cannot_regenerate');
      return;
    }
    if (!this.isSessionReady) {
      Logger.warn(LOG_TAG, 'Regenerate | eligibility_denied | session_not_ready');
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = true;
    this.canRegenerate = false;
    this.userScrolledUp = false;

    const callbacks: ChatServiceCallbacks = this.createCallbacks();

    try {
      await this.chatService.regenerateLastResponse(callbacks);
    } catch (e) {
      this.isGenerating = false;
      this.errorMessage = this.toUserError(String(e));
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'regenerate failed: ' + String(e));
    }
  }

  stop(): void {
    this.chatService.stopGeneration();
    this.isGenerating = false;
    this.statusMessage = '已停止';
    this.canRegenerate = this.chatService.canRegenerate();
    this.flushMessagesNow();
  }

  async impersonate(): Promise<void> {
    if (this.disposed || this.busy) {
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';
    this.impersonateCandidates = [];
    this.isImpersonateGenerating = true;
    try {
      const candidates: ImpersonateCandidate[] =
        await this.chatService.generateImpersonateCandidates();
      Logger.info(LOG_TAG, 'impersonate got candidates: ' + candidates.length);
      for (let i = 0; i < candidates.length; i++) {
        Logger.info(LOG_TAG, '  candidate[' + i + ']: ' + candidates[i].content);
      }
      this.impersonateCandidates = candidates;
      this.isImpersonateGenerating = false;
    } catch (e) {
      this.isImpersonateGenerating = false;
      this.errorMessage = this.toUserError(String(e));
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'impersonate failed: ' + String(e));
    }
  }

  selectImpersonateCandidate(index: number): void {
    if (index < 0 || index >= this.impersonateCandidates.length) {
      return;
    }
    this.inputText = this.impersonateCandidates[index].content;
    this.impersonateCandidates = [];
  }

  dismissImpersonateCandidates(): void {
    this.impersonateCandidates = [];
  }

  async extractUserFromCharacter(): Promise<void> {
    if (this.disposed || this.busy) {
      return;
    }
    this.isExtractingUserPersona = true;
    try {
      const extractResult: string = await this.chatService.extractUserFromCharacter();
      const existingSummary: string = this.userPersonaSummary;
      let combined: string = extractResult;
      if (existingSummary.length > 0 && !existingSummary.includes(extractResult)) {
        combined = existingSummary + '\n' + extractResult;
      }
      await this.chatService.updateCurrentChatUserPersonaSummary(combined);
      this.statusMessage = '';
    } catch (e) {
      this.errorMessage = this.toUserError(String(e));
    } finally {
      this.isExtractingUserPersona = false;
    }
  }

  async summarizeUserPersona(): Promise<void> {
    if (this.disposed || this.busy) {
      return;
    }
    this.isSummarizingUserPersona = true;
    try {
      const summaryResult: string = await this.chatService.summarizeUserPersona();
      const existingSummary: string = this.userPersonaSummary;
      let combined: string = summaryResult;
      if (existingSummary.length > 0 && !existingSummary.includes(summaryResult)) {
        combined = existingSummary + '\n' + summaryResult;
      }
      await this.chatService.updateCurrentChatUserPersonaSummary(combined);
      this.statusMessage = '';
    } catch (e) {
      this.errorMessage = this.toUserError(String(e));
    } finally {
      this.isSummarizingUserPersona = false;
    }
  }

  get userPersonaSummary(): string {
    const chat: Chat | null = this.chatService.getCurrentChat();
    if (chat === null) {
      return '';
    }
    return chat.userPersonaSummary;
  }

  async clearUserPersonaSummary(): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      await this.chatService.updateCurrentChatUserPersonaSummary('');
    } catch (e) {
      this.errorMessage = this.toUserError(String(e));
    }
  }

  async autoContinue(): Promise<void> {
    if (this.disposed || this.busy) {
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = true;
    this.canRegenerate = false;
    this.userScrolledUp = false;
    const callbacks: ChatServiceCallbacks = this.createCallbacks();
    try {
      await this.chatService.autoContinue(callbacks);
    } catch (e) {
      this.isGenerating = false;
      this.errorMessage = this.toUserError(String(e));
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'autoContinue failed: ' + String(e));
    }
  }

  async sendNarrator(): Promise<void> {
    if (this.disposed || !this.canSend) {
      return;
    }
    const content: string = this.inputText;
    if (content.trim().length === 0) {
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = true;
    this.canRegenerate = false;
    this.userScrolledUp = false;
    const callbacks: ChatServiceCallbacks = this.createCallbacks();
    try {
      await this.chatService.narratorMessage(content, callbacks);
      this.inputText = '';
    } catch (e) {
      this.isGenerating = false;
      this.errorMessage = this.toUserError(String(e));
      this.statusMessage = '';
      Logger.error(LOG_TAG, 'sendNarrator failed: ' + String(e));
    }
  }

  async sendNarratorOnly(): Promise<void> {
    if (this.disposed || !this.canSend) {
      return;
    }
    const content: string = this.inputText;
    if (content.trim().length === 0) {
      return;
    }
    this.errorMessage = '';
    this.statusMessage = '';
    const callbacks: ChatServiceCallbacks = this.createCallbacks();
    try {
      await this.chatService.narratorMessageOnly(content, callbacks);
      this.inputText = '';
    } catch (e) {
      this.errorMessage = this.toUserError(String(e));
      Logger.error(LOG_TAG, 'sendNarratorOnly failed: ' + String(e));
    }
  }

  async markMessageIncludeInMemory(messageId: string, include: boolean): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.chatService.markMessageIncludeInMemory(messageId, include);
    this.flushMessagesNow();
  }

  clear(): void {
    this.chatService.clearConversation();
    this.messages = [];
    this.errorMessage = '';
    this.statusMessage = '';
    this.isGenerating = false;
    this.canRegenerate = false;
    this.userScrolledUp = false;
    this.flushMessagesNow();
    if (this.onMessagesUpdate !== undefined) {
      this.onMessagesUpdate([]);
    }
  }

  updateInput(value: string): void {
    this.inputText = value;
  }

  // ===== Swipe 方法 =====

  getSwipeSummary(messageId: string): MessageSwipeSummary | undefined {
    return this.chatService.getSwipeSummary(messageId);
  }

  canOperateSwipe(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && this.isSessionReady
      && this.chatService.canOperateSwipe(messageId);
  }

  async swipePrevious(messageId: string): Promise<void> {
    if (this.disposed || this.isGenerating || this.isSwipeOperating) {
      return;
    }
    this.isSwipeOperating = true;
    this.swipeError = '';
    try {
      await this.chatService.activatePreviousCandidate(messageId);
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.swipeError = this.toUserError(String(e));
      Logger.error(LOG_TAG, 'swipePrevious failed: ' + String(e));
    } finally {
      this.isSwipeOperating = false;
    }
  }

  async swipeNext(messageId: string): Promise<void> {
    if (this.disposed || this.isGenerating || this.isSwipeOperating) {
      return;
    }
    this.isSwipeOperating = true;
    this.swipeError = '';
    try {
      await this.chatService.activateNextCandidate(messageId);
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.swipeError = this.toUserError(String(e));
      Logger.error(LOG_TAG, 'swipeNext failed: ' + String(e));
    } finally {
      this.isSwipeOperating = false;
    }
  }

  async regenerateAsNewCandidate(): Promise<void> {
    await this.regenerate();
  }

  // ===== T-4.5 会话列表方法 =====

  async openSessionList(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.showSessionList = true;
    this.sessionError = '';
    await this.refreshSessions();
  }

  closeSessionList(): void {
    this.showSessionList = false;
  }

  async refreshCurrentPresetName(): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      const presets: PromptPreset[] = await this.promptPresetService.getSelectedPresets();
      const names: string[] = [];
      for (let i = 0; i < presets.length; i++) {
        names.push(presets[i].name);
      }
      this.currentPresetName = names.join('、');
    } catch (e) {
      this.currentPresetName = '';
      Logger.warn(LOG_TAG, 'refresh preset name failed: ' + String(e));
    }
  }

  async refreshSessions(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoadingSessions = true;
    try {
      this.sessions = await this.chatService.listSessions();
    } catch (e) {
      this.sessionError = '加载会话列表失败';
      Logger.error(LOG_TAG, 'refreshSessions failed: ' + String(e));
    } finally {
      this.isLoadingSessions = false;
    }
  }

  async createNewSession(): Promise<void> {
    if (this.disposed || this.isSessionOperating || this.busy) {
      return;
    }
    this.isSessionOperating = true;
    this.sessionError = '';
    try {
      await this.chatService.startNewSession();
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.canRegenerate = this.chatService.canRegenerate();
      this.syncBranchState();
      this.syncStatusState();
      this.errorMessage = '';
      this.statusMessage = '';
      await this.refreshSessions();
    } catch (e) {
      this.sessionError = this.toSessionOpError(String(e));
      Logger.error(LOG_TAG, 'createNewSession failed: ' + String(e));
    } finally {
      this.isSessionOperating = false;
    }
  }

  async selectSession(chatId: string): Promise<void> {
    if (this.disposed || this.isSessionOperating || this.busy) {
      return;
    }
    if (chatId.length === 0) {
      return;
    }
    if (this.isCurrentSession(chatId)) {
      this.showSessionList = false;
      return;
    }
    this.isSessionOperating = true;
    this.sessionError = '';
    try {
      await this.chatService.switchSession(chatId);
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.canRegenerate = this.chatService.canRegenerate();
      this.syncBranchState();
      this.syncStatusState();
      this.errorMessage = '';
      this.statusMessage = '';
      this.showSessionList = false;
      await this.refreshSessions();
    } catch (e) {
      this.sessionError = this.toSessionOpError(String(e));
      Logger.error(LOG_TAG, 'selectSession failed: ' + String(e));
    } finally {
      this.isSessionOperating = false;
    }
  }

  requestDeleteSession(chatId: string): void {
    if (this.disposed || this.isSessionOperating || this.busy) {
      return;
    }
    if (chatId.length === 0) {
      return;
    }
    this.pendingDeleteChatId = chatId;
    this.showDeleteSessionConfirm = true;
    this.sessionError = '';
  }

  cancelDeleteSession(): void {
    this.pendingDeleteChatId = '';
    this.showDeleteSessionConfirm = false;
  }

  async confirmDeleteSession(): Promise<void> {
    if (this.disposed || this.isSessionOperating || this.busy) {
      return;
    }
    const chatId: string = this.pendingDeleteChatId;
    if (chatId.length === 0) {
      this.showDeleteSessionConfirm = false;
      return;
    }
    this.isSessionOperating = true;
    this.showDeleteSessionConfirm = false;
    try {
      await this.chatService.deleteSession(chatId);
      this.messages = [...this.chatService.getMessages()];
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
      this.canRegenerate = this.chatService.canRegenerate();
      this.syncBranchState();
      this.syncStatusState();
      this.errorMessage = '';
      this.statusMessage = '';
      this.pendingDeleteChatId = '';
      await this.refreshSessions();
    } catch (e) {
      this.sessionError = this.toSessionOpError(String(e));
      this.pendingDeleteChatId = '';
      Logger.error(LOG_TAG, 'confirmDeleteSession failed: ' + String(e));
    } finally {
      this.isSessionOperating = false;
    }
  }

  isCurrentSession(chatId: string): boolean {
    const currentId: string | undefined = this.chatService.getCurrentChatId();
    return currentId !== undefined && currentId === chatId;
  }

  get canOperateSessions(): boolean {
    return !this.isGenerating && !this.isSessionOperating && this.isSessionReady;
  }

  getSessionTitle(chat: Chat): string {
    return chat.title.length > 0 ? chat.title : '新对话';
  }

  getSessionSubtitle(chat: Chat): string {
    const ts: number = chat.lastMessageAt > 0 ? chat.lastMessageAt : chat.updatedAt;
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return month + '-' + day + ' ' + hour + ':' + minute;
  }

  private toSessionOpError(message: string): string {
    if (message.includes('请先停止当前回复')) {
      return '请先停止当前回复';
    }
    if (message.includes('会话操作进行中')) {
      return '操作进行中,请稍候';
    }
    if (message.includes('会话不存在') || message.includes('已删除')) {
      return '会话不存在或已删除';
    }
    if (message.includes('不属于当前聊天上下文')) {
      return '会话不属于当前上下文';
    }
    if (message.includes('会话 id 为空')) {
      return '会话 id 无效';
    }
    return '会话操作失败,请重试';
  }

  getMessageStatusText(message: ChatMessage): string {
    if (message.role !== ChatRole.Assistant) {
      return '';
    }
    if (message.status === ChatMessageStatus.Streaming) {
      return '生成中…';
    }
    if (message.status === ChatMessageStatus.Cancelled) {
      return '已停止';
    }
    if (message.status === ChatMessageStatus.Failed) {
      return message.errorMessage !== undefined ? message.errorMessage : '生成失败';
    }
    return '';
  }

  isMessageStatusError(message: ChatMessage): boolean {
    return message.status === ChatMessageStatus.Cancelled
      || message.status === ChatMessageStatus.Failed;
  }

  // ===== T-6.4B-1 Branch 方法 =====

  private syncBranchState(): void {
    this.branches = this.chatService.getBranches();
    this.activeBranchId = this.chatService.getActiveBranchId();
    this.recordCounts = this.chatService.getRecordCounts();
  }

  private syncStatusState(): void {
    this.statusState = this.chatService.getChatStatusState();
    if (this.onStatusUpdate !== undefined) {
      this.onStatusUpdate(this.statusState);
    }
  }

  async refreshBranchState(): Promise<void> {
    if (this.disposed) {
      return;
    }
    await this.chatService.refreshBranchState();
    this.syncBranchState();
  }

  canContinueFromAssistant(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && !this.isBranchOperating
      && this.isSessionReady
      && this.chatService.canContinueFromAssistant(messageId);
  }

  async continueFromAssistant(messageId: string): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (!this.canContinueFromAssistant(messageId)) {
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.continueFromAssistant(messageId, callbacks);
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '创建分支失败,请重试';
      Logger.error(LOG_TAG, 'continueFromAssistant failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  canGenerateFromUserMessage(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && !this.isBranchOperating
      && this.isSessionReady
      && this.chatService.canGenerateFromUserMessage(messageId);
  }

  async generateFromUserMessage(messageId: string): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (!this.canGenerateFromUserMessage(messageId)) {
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.generateFromUserMessage(messageId, callbacks);
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '创建分支失败,请重试';
      Logger.error(LOG_TAG, 'generateFromUserMessage failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  canRegenerateAssistantMessage(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && !this.isBranchOperating
      && this.isSessionReady
      && this.chatService.canRegenerateAssistantMessage(messageId);
  }

  async regenerateAssistantMessage(messageId: string): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (!this.canRegenerateAssistantMessage(messageId)) {
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.regenerateAssistantMessage(messageId, callbacks);
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '创建分支失败,请重试';
      Logger.error(LOG_TAG, 'regenerateAssistantMessage failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  canEditUserMessage(messageId: string): boolean {
    return !this.isGenerating && !this.isSwipeOperating && !this.isBranchOperating
      && this.isSessionReady
      && this.chatService.canEditUserMessage(messageId);
  }

  async editUserMessageAndGenerate(
    messageId: string,
    editedContent: string
  ): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (!this.canEditUserMessage(messageId)) {
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.editUserMessageAndGenerate(messageId, editedContent, callbacks);
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '创建分支失败,请重试';
      Logger.error(LOG_TAG, 'editUserMessageAndGenerate failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  async editNarratorMessage(messageId: string, editedContent: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.errorMessage = '';
    try {
      await this.chatService.editNarratorMessage(messageId, editedContent);
      this.flushMessagesNow();
    } catch (e) {
      this.errorMessage = this.toUserError(String(e));
      Logger.error(LOG_TAG, 'editNarratorMessage failed: ' + String(e));
    }
  }

  async switchBranch(branchId: string): Promise<void> {
    if (this.disposed || this.busy || this.isBranchOperating) {
      return;
    }
    if (branchId.length === 0) {
      return;
    }
    if (branchId === this.activeBranchId) {
      this.showBranchList = false;
      return;
    }
    this.isBranchOperating = true;
    this.errorMessage = '';
    this.statusMessage = '';
    try {
      const callbacks: ChatServiceCallbacks = this.createCallbacks();
      await this.chatService.switchBranch(branchId, callbacks);
      this.messages = [...this.chatService.getMessages()];
      this.swipeSummaries = this.chatService.getSwipeSummaries();
      this.syncBranchState();
      this.canRegenerate = this.chatService.canRegenerate();
      this.showBranchList = false;
      if (this.onMessagesUpdate !== undefined) {
        this.onMessagesUpdate([...this.messages]);
      }
    } catch (e) {
      this.errorMessage = '切换分支失败,请重试';
      Logger.error(LOG_TAG, 'switchBranch failed: ' + String(e));
    } finally {
      this.isBranchOperating = false;
    }
  }

  openBranchList(): void {
    if (this.disposed) {
      return;
    }
    this.showBranchList = true;
  }

  closeBranchList(): void {
    this.showBranchList = false;
  }

  getBranchDisplayName(branch: ConversationBranchSummary): string {
    return branch.isRoot ? '主分支' : '分支';
  }

  getBranchSubtitle(branch: ConversationBranchSummary): string {
    return branch.messageCount.toString() + ' 条消息'
      + (branch.isActive ? ' · 当前' : '');
  }

  getBranchStatusText(): string {
    if (this.recordCounts === undefined) {
      return '';
    }
    const current: number = this.recordCounts.currentBranchMessageCount;
    const total: number = this.recordCounts.totalUniqueMessageCount;
    const branches: number = this.recordCounts.totalBranchCount;
    return '当前分支 ' + current.toString() + ' 条 · 全部消息 ' + total.toString()
      + ' 条 · ' + branches.toString() + ' 个分支';
  }

  getCurrentChatId(): string | undefined {
    return this.chatService.getCurrentChatId();
  }

  getCurrentChatUserNameOverride(): string {
    const chat: Chat | null = this.chatService.getCurrentChat();
    return chat !== null ? chat.userNameOverride : '';
  }

  async getResolvedUserName(): Promise<string> {
    return await this.chatService.resolveUserName();
  }

  async updateUserNameOverride(override: string | null): Promise<void> {
    await this.chatService.updateCurrentChatUserNameOverride(override);
  }

  /** 获取当前聊天的锁定 Persona ID */
  getCurrentChatPersonaId(): string {
    const chat: Chat | null = this.chatService.getCurrentChat();
    return chat !== null ? chat.personaId : '';
  }

  /** 获取当前角色的默认 Persona ID */
  getCharacterDefaultPersonaId(): string {
    return this.chatService.getCharacterDefaultPersonaId();
  }

  /** 更新当前聊天的锁定 Persona ID(null 清除锁定) */
  async updateChatPersonaId(personaId: string | null): Promise<void> {
    await this.chatService.updateCurrentChatPersonaId(personaId);
  }

  // ===== CHAT-STATUS-1A: 角色状态字段操作 =====

  requestStatusFieldGeneration(): void {
    this.chatService.requestStatusFieldGeneration();
  }

  async generateStatusFields(): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    const result: ChatStatusState | null = await this.chatService.generateStatusFieldsNow();
    if (result === null) {
      return false;
    }
    this.statusState = result;
    if (this.onStatusUpdate !== undefined) {
      this.onStatusUpdate(result);
    }
    return true;
  }

  addStatusField(name: string): void {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return;
    }
    const entries: ChatStatusEntry[] = this.statusState.entries.slice();
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].name === trimmed) {
        return;
      }
    }
    entries.push(createChatStatusEntry(trimmed, '', true, false));
    this.chatService.updateStatusState({ entries: entries });
    this.syncStatusState();
  }

  removeStatusField(name: string): void {
    const next: ChatStatusEntry[] = [];
    const entries: ChatStatusEntry[] = this.statusState.entries;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].name !== name) {
        next.push(entries[i]);
      }
    }
    this.chatService.updateStatusState({ entries: next });
    this.syncStatusState();
  }

  renameStatusField(oldName: string, newName: string): void {
    const trimmed: string = newName.trim();
    if (trimmed.length === 0 || trimmed === oldName) {
      return;
    }
    const next: ChatStatusEntry[] = [];
    const entries: ChatStatusEntry[] = this.statusState.entries;
    for (let i = 0; i < entries.length; i++) {
      const e: ChatStatusEntry = entries[i];
      if (e.name === oldName) {
        next.push(createChatStatusEntry(trimmed, e.value, e.fromUser, e.locked));
      } else {
        next.push(e);
      }
    }
    this.chatService.updateStatusState({ entries: next });
    this.syncStatusState();
  }

  setStatusFieldLocked(name: string, locked: boolean): void {
    const next: ChatStatusEntry[] = [];
    const entries: ChatStatusEntry[] = this.statusState.entries;
    for (let i = 0; i < entries.length; i++) {
      const e: ChatStatusEntry = entries[i];
      if (e.name === name) {
        next.push(createChatStatusEntry(e.name, e.value, e.fromUser, locked));
      } else {
        next.push(e);
      }
    }
    this.chatService.updateStatusState({ entries: next });
    this.syncStatusState();
  }

  setStatusFieldValue(name: string, value: string): void {
    const next: ChatStatusEntry[] = [];
    const entries: ChatStatusEntry[] = this.statusState.entries;
    for (let i = 0; i < entries.length; i++) {
      const e: ChatStatusEntry = entries[i];
      if (e.name === name) {
        next.push(createChatStatusEntry(e.name, value, e.fromUser, e.locked));
      } else {
        next.push(e);
      }
    }
    this.chatService.updateStatusState({ entries: next });
    this.syncStatusState();
  }

  getLastBuiltRequestMessages(): ChatMessage[] | undefined {
    return this.chatService.getLastBuiltRequestMessages();
  }

  async buildEstimateMessages(): Promise<void> {
    await this.chatService.buildEstimateMessages();
  }

  invalidateEstimateCache(): void {
    this.chatService.invalidateEstimateCache();
  }

  getLastTokenBudget(): TokenBudget | undefined {
    return this.chatService.getLastTokenBudget();
  }

  // ===== 状态/世界书滑动面板(T-7.x) =====

  async loadLorebookPanelData(): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      const lorebookService: LorebookService = AppServices.getLorebookService();
      const globalBook: Lorebook | null = await lorebookService.getCurrentLorebook();
      let characterBook: Lorebook | null = null;
      const character: Character | null = this.chatService.getCharacter();
      if (character !== null && character.characterBookId.length > 0) {
        characterBook = await lorebookService.getById(character.characterBookId);
      }
      const books: LorebookPanelBook[] = [];
      if (characterBook !== null) {
        books.push(this.buildPanelBook(characterBook, true));
      }
      if (globalBook !== null) {
        books.push(this.buildPanelBook(globalBook, false));
      }
      this.lorebookPanelData = books.length > 0 ? { books: books } : null;
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadLorebookPanelData failed: ' + String(e));
      this.lorebookPanelData = null;
    }
  }

  private buildPanelBook(book: Lorebook, isCharacterBook: boolean): LorebookPanelBook {
    const sorted: LorebookEntry[] = book.entries.slice();
    sorted.sort((a: LorebookEntry, b: LorebookEntry): number => {
      if (a.priority !== b.priority) {
        return b.priority - a.priority;
      }
      return a.name.localeCompare(b.name);
    });
    return {
      lorebookId: book.id,
      name: book.name,
      isCharacterBook: isCharacterBook,
      entries: sorted
    };
  }

  async aiModifyStatus(prompt: string): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    const result: ChatStatusState | null = await this.chatService.modifyStatusWithPrompt(prompt);
    if (result === null) {
      return false;
    }
    this.syncStatusState();
    return true;
  }

  async aiProposeWorldbookChanges(
    mode: AiLorebookMode,
    instruction: string
  ): Promise<AiLorebookChangeSet | null> {
    if (this.disposed) {
      return null;
    }
    try {
      const lorebookService: LorebookService = AppServices.getLorebookService();
      const globalBook: Lorebook | null = await lorebookService.getCurrentLorebook();
      let characterBook: Lorebook | null = null;
      const character: Character | null = this.chatService.getCharacter();
      if (character !== null && character.characterBookId.length > 0) {
        characterBook = await lorebookService.getById(character.characterBookId);
      }
      const input: AiLorebookInput = {
        globalBook: globalBook,
        characterBook: characterBook,
        recentMessages: this.messages,
        instruction: instruction,
        mode: mode
      };
      return await this.getAiLorebookService().proposeChanges(input);
    } catch (e) {
      Logger.warn(LOG_TAG, 'aiProposeWorldbookChanges failed: ' + String(e));
      return null;
    }
  }

  async applyLorebookChangeSet(changes: AiLorebookChangeSet): Promise<boolean> {
    if (this.disposed) {
      return false;
    }
    let anyFailed: boolean = false;
    const lorebookService: LorebookService = AppServices.getLorebookService();
    try {
      for (let i = 0; i < changes.adds.length; i++) {
        const a: AiLorebookAdd = changes.adds[i];
        try {
          await lorebookService.addEntry(
            a.lorebookId,
            a.name,
            a.keys,
            [],
            a.content,
            true,
            a.constant,
            false,
            a.position === 'AfterCharacter'
              ? LorebookPosition.AfterCharacter : LorebookPosition.BeforeCharacter,
            a.priority
          );
        } catch (e) {
          anyFailed = true;
          Logger.warn(LOG_TAG, 'apply add failed: ' + String(e));
        }
      }
      for (let i = 0; i < changes.updates.length; i++) {
        const u: AiLorebookUpdate = changes.updates[i];
        try {
          const updates: LorebookEntryUpdates = {};
          if (u.name !== undefined) {
            updates.name = u.name;
          }
          if (u.keys !== undefined) {
            updates.keys = u.keys;
          }
          if (u.content !== undefined) {
            updates.content = u.content;
          }
          if (u.position !== undefined) {
            updates.position = u.position === 'AfterCharacter'
              ? LorebookPosition.AfterCharacter : LorebookPosition.BeforeCharacter;
          }
          if (u.priority !== undefined) {
            updates.priority = u.priority;
          }
          await lorebookService.updateEntry(u.lorebookId, u.entryId, updates);
        } catch (e) {
          anyFailed = true;
          Logger.warn(LOG_TAG, 'apply update failed: ' + String(e));
        }
      }
      for (let i = 0; i < changes.deletes.length; i++) {
        const d: AiLorebookDelete = changes.deletes[i];
        try {
          await lorebookService.removeEntry(d.lorebookId, d.entryId);
        } catch (e) {
          anyFailed = true;
          Logger.warn(LOG_TAG, 'apply delete failed: ' + String(e));
        }
      }
      if (!anyFailed) {
        await this.loadLorebookPanelData();
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'applyLorebookChangeSet failed: ' + String(e));
      anyFailed = true;
    }
    return !anyFailed;
  }

  async toggleLorebookEntryEnabled(
    lorebookId: string,
    entryId: string,
    enabled: boolean
  ): Promise<void> {
    if (this.disposed) {
      return;
    }
    try {
      const lorebookService: LorebookService = AppServices.getLorebookService();
      const updates: LorebookEntryUpdates = { enabled: enabled };
      await lorebookService.updateEntry(lorebookId, entryId, updates);
      await this.loadLorebookPanelData();
    } catch (e) {
      Logger.warn(LOG_TAG, 'toggleLorebookEntryEnabled failed: ' + String(e));
    }
  }

  private getAiLorebookService(): AiLorebookService {
    if (this.aiLorebookService === null) {
      this.aiLorebookService = new AiLorebookService(
        AppServices.getModelService(),
        AppServices.getLorebookService()
      );
    }
    return this.aiLorebookService;
  }

  get isDisposed(): boolean {
    return this.disposed;
  }

  async reloadAfterBranchChange(): Promise<void> {
    if (this.disposed) {
      return;
    }
    const callbacks: ChatServiceCallbacks = this.createCallbacks();
    await this.chatService.reloadAfterExternalBranchChange(callbacks);
    this.messages = [...this.chatService.getMessages()];
    this.swipeSummaries = this.chatService.getSwipeSummaries();
    this.syncBranchState();
    this.canRegenerate = this.chatService.canRegenerate();
    if (this.onMessagesUpdate !== undefined) {
      this.onMessagesUpdate([...this.messages]);
    }
  }

  unfreezeLorebookEntries(): void {
    this.chatService.unfreezeLorebookEntries();
  }

  triggerManualMemorySummary(): void {
    this.chatService.triggerManualMemorySummary();
  }

  setMemoryAutoSummaryEnabled(enabled: boolean): void {
    this.chatService.setMemoryAutoSummaryEnabled(enabled);
  }

  isMemoryAutoSummaryEnabled(): boolean {
    return this.chatService.isMemoryAutoSummaryEnabled();
  }

  setStatusInstructionEnabled(enabled: boolean): void {
    this.chatService.setStatusInstructionEnabled(enabled);
  }

  isStatusInstructionEnabled(): boolean {
    return this.chatService.isStatusInstructionEnabled();
  }

  dispose(): void {
    this.disposed = true;
    if (this.flushTimerId !== -1) {
      clearTimeout(this.flushTimerId);
      this.flushTimerId = -1;
    }
    this.chatService.dispose();
  }

  // ===== 流式 UI 节流实现 =====

  private scheduleMessagesFlush(): void {
    if (this.flushTimerId !== -1) {
      return;
    }
    const now: number = Date.now();
    const elapsed: number = now - this.lastFlushTime;
    if (elapsed >= ChatViewModel.FLUSH_INTERVAL_MS) {
      this.flushMessages();
    } else {
      const delay: number = ChatViewModel.FLUSH_INTERVAL_MS - elapsed;
      this.flushTimerId = setTimeout((): void => {
        this.flushMessages();
      }, delay);
    }
  }

  private flushMessages(): void {
    this.flushTimerId = -1;
    this.lastFlushTime = Date.now();
    if (this.disposed) {
      return;
    }
    if (this.onMessagesUpdate !== undefined) {
      this.onMessagesUpdate([...this.messages]);
    }
  }

  private flushMessagesNow(): void {
    if (this.flushTimerId !== -1) {
      clearTimeout(this.flushTimerId);
      this.flushTimerId = -1;
    }
    this.flushMessages();
  }

  // ===== 内部方法 =====

  private createCallbacks(): ChatServiceCallbacks {
    return {
      onMessagesChanged: (messages: ChatMessage[]): void => {
        if (this.disposed) {
          return;
        }
        this.messages = messages;
        this.scheduleMessagesFlush();
      },
      onStateChanged: (state: ChatState): void => {
        if (this.disposed) {
          return;
        }
        this.updateStateFromChatState(state);
      },
      onError: (message: string): void => {
        if (this.disposed) {
          return;
        }
        this.errorMessage = this.toUserError(message);
        this.statusMessage = '';
      },
      onStatusChanged: (state: ChatStatusState): void => {
        if (this.disposed) {
          return;
        }
        this.statusState = state;
        if (this.onStatusUpdate !== undefined) {
          this.onStatusUpdate(state);
        }
      },
      onCacheStatsUpdate: (cachedTokens: number, promptTokens: number, hitRatio: number): void => {
        if (this.disposed) {
          return;
        }
        this.lastCachedTokens = cachedTokens;
        this.lastPromptTokens = promptTokens;
        this.lastCacheHitRatio = hitRatio;
        if (this.onCacheStatsUpdate !== undefined) {
          this.onCacheStatsUpdate(cachedTokens, promptTokens, hitRatio);
        }
      }
    };
  }

  private updateStateFromChatState(state: ChatState): void {
    switch (state) {
      case ChatState.Sending:
        this.isGenerating = true;
        this.statusMessage = '发送中…';
        this.syncBranchState();
        break;
      case ChatState.Streaming:
        this.isGenerating = true;
        this.statusMessage = '生成中…';
        break;
      case ChatState.Completed:
        this.isGenerating = false;
        this.statusMessage = '';
        this.canRegenerate = this.chatService.canRegenerate();
        this.swipeSummaries = this.chatService.getSwipeSummaries();
        this.syncBranchState();
        this.flushMessagesNow();
        break;
      case ChatState.Cancelled:
        this.isGenerating = false;
        this.statusMessage = '已停止';
        this.canRegenerate = this.chatService.canRegenerate();
        this.swipeSummaries = this.chatService.getSwipeSummaries();
        this.syncBranchState();
        this.flushMessagesNow();
        break;
      case ChatState.Failed:
        this.isGenerating = false;
        this.statusMessage = '';
        this.canRegenerate = this.chatService.canRegenerate();
        this.swipeSummaries = this.chatService.getSwipeSummaries();
        this.syncBranchState();
        this.flushMessagesNow();
        break;
      default:
        break;
    }
  }

  private toUserError(message: string): string {
    if (message.includes('No current provider config') || message.includes('尚未配置')) {
      return '尚未配置模型,请前往模型设置';
    }
    if (message.includes('disabled')) {
      return '当前模型已禁用,请前往模型设置';
    }
    if (message.includes('model name is empty') || message.includes('model name')) {
      return '模型名称未配置,请前往模型设置选择具体模型';
    }
    if (message.includes('API Key') || message.includes('api key') || message.includes('apiKey')) {
      return 'API Key 未配置,请前往模型设置';
    }
    if (message.includes('Authentication') || message.includes('401') || message.includes('Unauthorized')) {
      return '鉴权失败,请检查 API Key 是否正确';
    }
    if (message.includes('RateLimit') || message.includes('429')) {
      return '请求频率过高,请稍后重试';
    }
    if (message.includes('Timeout') || message.includes('timeout') || message.includes('超时')) {
      return '请求超时,请检查网络后重试';
    }
    if (message.includes('Network') || message.includes('connect') || message.includes('ECONNREFUSED')) {
      return '网络连接失败,请检查网络设置';
    }
    if (message.includes('Server') || message.includes('500') || message.includes('502') || message.includes('503')) {
      return '服务器错误,请稍后重试';
    }
    if (message.includes('Parse') || message.includes('parse') || message.includes('Invalid JSON')) {
      return '响应解析失败,请重试';
    }
    if (message.includes('Cancelled') || message.includes('cancel')) {
      return '已取消';
    }
    if (message.includes('空回复')) {
      return '模型返回了空回复,请重试';
    }
    if (message.includes('disposed')) {
      return '页面已退出,请重新进入';
    }
    return '请求失败,请重试';
  }
}
