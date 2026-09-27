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
import { ChatMessageStatus } from '../models/ChatMessage';
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

  // ===== 搬运方法(原 ChatService 成员,逐字搬出) =====

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
