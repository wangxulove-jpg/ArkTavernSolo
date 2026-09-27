/**
 * ChatUserIdentityService 用户称呼与 Persona(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - resolveUserName:解析当前生效的用户称呼(会话覆盖 > 角色称呼 > Persona > 全局 > 默认)
 * - updateCurrentChatUserNameOverride:更新对话级用户称呼覆盖
 * - updateCurrentChatPersonaId:更新对话级锁定 Persona
 * - updateCurrentChatUserPersonaSummary:更新对话级用户 Persona 摘要
 * - getCharacterDefaultPersonaId:当前角色的默认 Persona ID
 * - resolveEffectivePersona:解析当前聊天的有效 Persona(聊天锁定 > 角色默认 > 全局默认)
 *
 * 依赖与宿主(ArkTS 说明):
 * - 会话状态(currentChat / currentChatId / character)仍由 ChatService 持有,
 *   经 ChatUserIdentityHost 函数属性回调读写——与搬运前 this.xxx 语义一致;
 *   类内同名 getter/setter 转发,使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ChatUserIdentityService(仅日志来源标注变化)。
 */

import { Character } from '../models/Character';
import { Chat } from '../models/Chat';
import { Persona } from '../models/Persona';
import { ChatPersistenceService } from './ChatPersistenceService';
import { AppPreferences } from '../storage/AppPreferences';
import { AppServices } from './AppServices';
import { Logger } from '../utils/Logger';
import { GLOBAL_USER_NAME_KEY } from './ChatTextContract';

const LOG_TAG: string = 'ChatUserIdentityService';

/** 默认用户名(本阶段固定值,后续可扩展为用户设置) */
const DEFAULT_USER_NAME: string = 'User';

/** 用户身份服务依赖(全部为只读引用,null 表示未装配) */
export interface ChatUserIdentityDeps {
  /** 会话持久化服务(更新对话级称呼 / Persona / 摘要) */
  persistenceService: ChatPersistenceService | null;
  /** 全局偏好(读取全局用户称呼) */
  appPreferences: AppPreferences | null;
}

/**
 * 宿主回调:会话状态读写。
 * 读取即最新、写入即生效(与搬运前 this.xxx 语义一致)。
 */
export interface ChatUserIdentityHost {
  /** 当前会话 Chat 对象读取 */
  getCurrentChat: () => Chat | null;
  /** 当前会话 Chat 对象更新(持久化返回后回写) */
  setCurrentChat: (chat: Chat | null) => void;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 当前角色读取 */
  getCharacter: () => Character | null;
}

export class ChatUserIdentityService {
  private readonly persistenceService: ChatPersistenceService | null;
  private readonly appPreferences: AppPreferences | null;
  private readonly host: ChatUserIdentityHost;

  constructor(deps: ChatUserIdentityDeps, host: ChatUserIdentityHost) {
    this.persistenceService = deps.persistenceService;
    this.appPreferences = deps.appPreferences;
    this.host = host;
  }

  // ===== 宿主状态与能力(同名 getter/setter 转发,保持搬运代码零改写) =====

  private get currentChat(): Chat | null {
    return this.host.getCurrentChat();
  }

  private set currentChat(value: Chat | null) {
    this.host.setCurrentChat(value);
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private get character(): Character | null {
    return this.host.getCharacter();
  }

  // ===== 搬运方法(原 ChatService 成员,逐字搬出) =====

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

}