/**
 * ChatSessionService 会话生命周期(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - buildGreetingPool:构建开场白池([firstMessage(非空时)] + alternateGreetings)
 * - initializeGreetingSwipeCandidates:开场白候选初始化为首条消息的 Swipe 候选
 * - buildChapterTitlePreview:章节标题开场白预览(前 20 字符)
 * - listSessions:列出当前聊天上下文下的会话
 * - loadLorebookPrefs:加载世界书全局默认激活方式与深度注入偏好
 * - reloadSwipeStateAfterNewSession:新建会话后重新加载 Swipe 状态
 *
 * 依赖与宿主(ArkTS 说明):
 * - 会话状态(character / currentChatId / swipeSummaries / lastAssistantMessageId /
 *   lorebookActivationDefault / lorebookInjectionDepth)仍由 ChatService 持有,
 *   经 ChatSessionHost 函数属性回调读写——与搬运前 this.xxx 语义一致;
 *   类内同名 getter/setter/方法转发,使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ChatSessionService(仅日志来源标注变化)。
 */

import { Character } from '../models/Character';
import { Chat } from '../models/Chat';
import { LorebookActivationMode } from '../models/Lorebook';
import { MessageSwipeSummary } from '../models/MessageSwipe';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { PersistedChatSession } from '../models/PersistedChatSession';
import { generateUuid } from '../utils/Uuid';
import { ChatPersistenceService } from './ChatPersistenceService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import {
  LOREBOOK_ACTIVATION_DEFAULT_PREFS_KEY,
  LOREBOOK_INJECTION_DEPTH_PREFS_KEY,
  DEFAULT_LOREBOOK_ACTIVATION_MODE,
  DEFAULT_LOREBOOK_INJECTION_DEPTH
} from './ChatTextContract';

const LOG_TAG: string = 'ChatSessionService';

/** 会话服务依赖(全部为只读引用,null 表示未装配) */
export interface ChatSessionDeps {
  /** 会话持久化服务 */
  persistenceService: ChatPersistenceService | null;
  /** 消息候选持久化服务(开场白候选初始化 / Swipe 摘要加载) */
  swipePersistenceService: MessageSwipePersistenceService | null;
  /** 全局偏好(世界书激活方式 / 深度注入) */
  appPreferences: AppPreferences | null;
}

/**
 * 宿主回调:会话状态读写与宿主私有能力。
 * 读取即最新、写入即生效(与搬运前 this.xxx 语义一致)。
 */
export interface ChatSessionHost {
  /** 当前角色读取 */
  getCharacter: () => Character | null;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 当前会话的 Swipe 摘要列表整体替换 */
  setSwipeSummaries: (summaries: MessageSwipeSummary[]) => void;
  /** 最后一条非 firstMessage 的 Assistant 消息 id 更新 */
  setLastAssistantMessageId: (assistantMessageId: string) => void;
  /** 重算最后一条非 firstMessage 的 Assistant 消息 id(宿主私有辅助) */
  updateLastAssistantMessageId: () => void;
  /** 世界书全局默认激活方式更新 */
  setLorebookActivationDefault: (mode: LorebookActivationMode) => void;
  /** 世界书深度注入位置更新 */
  setLorebookInjectionDepth: (depth: number) => void;
  /** 当前角色更新 */
  setCharacter: (character: Character | null) => void;
  /** 当前会话 id 更新 */
  setCurrentChatId: (chatId: string | undefined) => void;
  /** 当前会话 Chat 对象更新 */
  setCurrentChat: (chat: Chat | null) => void;
  /** 消息列表整体替换 */
  setMessages: (messages: ChatMessage[]) => void;
  /** 当前会话最大 sequenceNumber 更新 */
  setCurrentSequenceNumber: (sequenceNumber: number) => void;
  /** 会话是否已初始化读取 */
  getContextInitialized: () => boolean;
  /** 会话是否已初始化更新 */
  setContextInitialized: (initialized: boolean) => void;
  /** 初始化进行中的 Promise 读取(防止并发) */
  getInitializingPromise: () => Promise<void> | null;
  /** 初始化进行中的 Promise 更新 */
  setInitializingPromise: (promise: Promise<void> | null) => void;
  /** 宿主是否已释放 */
  isDisposed: () => boolean;
  /** 从当前角色卡解析声明式状态 Schema(宿主私有能力) */
  syncStatusSchemaFromCharacter: () => void;
  /** 从当前会话 statusConfigJson 同步内存状态(宿主私有能力) */
  syncStatusStateFromCurrentChat: () => void;
  /** 清空前端交互记录(宿主私有能力) */
  clearFrontendInteractions: () => void;
  /** 加载自动记忆总结开关偏好(宿主私有能力) */
  loadMemoryAutoSummaryPref: () => Promise<void>;
  /** 加载状态输出指令开关偏好(宿主私有能力) */
  loadStatusInstructionPref: () => Promise<void>;
  /** 加载记忆关键词检索开关偏好(宿主私有能力) */
  loadMemoryPrefs: () => Promise<void>;
  /** 刷新 Branch 状态(宿主私有能力) */
  refreshBranchState: () => Promise<void>;
}

export class ChatSessionService {
  private readonly persistenceService: ChatPersistenceService | null;
  private readonly swipePersistenceService: MessageSwipePersistenceService | null;
  private readonly appPreferences: AppPreferences | null;
  private readonly host: ChatSessionHost;

  constructor(deps: ChatSessionDeps, host: ChatSessionHost) {
    this.persistenceService = deps.persistenceService;
    this.swipePersistenceService = deps.swipePersistenceService;
    this.appPreferences = deps.appPreferences;
    this.host = host;
  }

  // ===== 宿主状态与能力(同名 getter/setter/方法转发,保持搬运代码零改写) =====

  private get character(): Character | null {
    return this.host.getCharacter();
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private set swipeSummaries(value: MessageSwipeSummary[]) {
    this.host.setSwipeSummaries(value);
  }

  private set lastAssistantMessageId(value: string) {
    this.host.setLastAssistantMessageId(value);
  }

  private updateLastAssistantMessageId(): void {
    this.host.updateLastAssistantMessageId();
  }

  private set lorebookActivationDefault(value: LorebookActivationMode) {
    this.host.setLorebookActivationDefault(value);
  }

  private set lorebookInjectionDepth(value: number) {
    this.host.setLorebookInjectionDepth(value);
  }

  private set character(value: Character | null) {
    this.host.setCharacter(value);
  }

  private set currentChatId(value: string | undefined) {
    this.host.setCurrentChatId(value);
  }

  private set currentChat(value: Chat | null) {
    this.host.setCurrentChat(value);
  }

  private set messages(value: ChatMessage[]) {
    this.host.setMessages(value);
  }

  private set currentSequenceNumber(value: number) {
    this.host.setCurrentSequenceNumber(value);
  }

  private get contextInitialized(): boolean {
    return this.host.getContextInitialized();
  }

  private set contextInitialized(value: boolean) {
    this.host.setContextInitialized(value);
  }

  private get initializingPromise(): Promise<void> | null {
    return this.host.getInitializingPromise();
  }

  private set initializingPromise(value: Promise<void> | null) {
    this.host.setInitializingPromise(value);
  }

  private get disposed(): boolean {
    return this.host.isDisposed();
  }

  private syncStatusSchemaFromCharacter(): void {
    this.host.syncStatusSchemaFromCharacter();
  }

  private syncStatusStateFromCurrentChat(): void {
    this.host.syncStatusStateFromCurrentChat();
  }

  private clearFrontendInteractions(): void {
    this.host.clearFrontendInteractions();
  }

  private async loadMemoryAutoSummaryPref(): Promise<void> {
    return this.host.loadMemoryAutoSummaryPref();
  }

  private async loadStatusInstructionPref(): Promise<void> {
    return this.host.loadStatusInstructionPref();
  }

  private async loadMemoryPrefs(): Promise<void> {
    return this.host.loadMemoryPrefs();
  }

  private async refreshBranchState(): Promise<void> {
    return this.host.refreshBranchState();
  }

  // ===== 搬运方法(会话初始化族,P2-9b,原 ChatService 成员逐字搬出) =====

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


  async doInitializeSession(character?: Character, forceNew: boolean = false): Promise<void> {
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
  async createNewSession(characterId?: string): Promise<void> {
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


  // ===== 搬运方法(工具/查询族,P2-9a,原 ChatService 成员逐字搬出) =====

  /**
   * 构建开场白池:[firstMessage(非空时)] + alternateGreetings(trim 过滤空项)。
   */
  buildGreetingPool(): string[] {
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
  async initializeGreetingSwipeCandidates(
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
   * 章节标题开场白预览:前 20 字符,超长追加省略号。
   */
  buildChapterTitlePreview(greeting: string): string {
    const trimmed: string = greeting.trim();
    if (trimmed.length <= 20) {
      return trimmed;
    }
    return trimmed.substring(0, 20) + '…';
  }


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
   * 加载世界书全局默认激活方式与深度注入偏好。
   * 在会话初始化时调用(全局,跨会话)。
   */
  async loadLorebookPrefs(): Promise<void> {
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
   * createNewSession 之后重新加载 Swipe 状态。
   *
   * createNewSession 只把 alternate_greetings 持久化为首条开场白消息的
   * Swipe 候选 1..N,不会同步 this.swipeSummaries / this.lastAssistantMessageId。
   * 会话列表"新建对话"与"删除当前会话后回退新建"两条路径必须调用本方法,
   * 否则首条消息候选数读不到(开场白选择箭头不出现)且无法 Swipe。
   */
  async reloadSwipeStateAfterNewSession(): Promise<void> {
    this.swipeSummaries = [];
    this.lastAssistantMessageId = '';
    if (this.swipePersistenceService !== null && this.currentChatId !== undefined) {
      this.swipeSummaries =
        await this.swipePersistenceService.listSwipeSummariesByChatId(this.currentChatId);
    }
    this.updateLastAssistantMessageId();
  }

}
