/**
 * ChatSessionListViewModel 对话记录 Tab 列表状态管理
 *
 * 专为"对话记录"Tab 设计,与 ChatViewModel 解耦:
 * - 只读会话列表(不创建新会话,不切换上下文)
 * - 加载每个会话关联的角色(头像 / 名称)
 * - 加载每个会话最后一条消息摘要
 * - 提供重命名接口
 *
 * 不依赖:
 * - ChatService(避免初始化会话副作用)
 * - Provider / PromptBuilder / TokenCounter
 *
 * 复用:
 * - ChatPersistenceService.listAllSessions / getLatestMessagePreview / renameSession
 * - CharacterService.getById(批量查询角色)
 *
 * 状态:
 * - sessions: ChatSessionListItem[](含 Chat / Character / preview)
 * - 通过 reload 全量重建 sessions 数组(新引用触发 ArkUI ForEach 重渲染)
 * - 重命名成功后只更新对应项(保留列表顺序)
 */

import { Chat } from '../models/Chat';
import { Character } from '../models/Character';
import { ChatPersistenceService } from '../services/ChatPersistenceService';
import { CharacterService } from '../services/CharacterService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatSessionListViewModel';

/** 未知角色显示名称 */
export const UNKNOWN_CHARACTER_NAME: string = '未知角色';

/** 会话列表项(含角色与最后消息摘要) */
export interface ChatSessionListItem {
  readonly chat: Chat;
  /** 关联角色(普通助手会话或角色已删除时为 null) */
  readonly character: Character | null;
  /** 角色是否已删除(true:角色已删除,显示"未知角色";false:正常角色或普通助手) */
  readonly isCharacterDeleted: boolean;
  /** 最后一条消息预览(空字符串表示无消息) */
  readonly lastMessagePreview: string;
  /** 最后更新时间戳(优先 lastMessageAt,否则 updatedAt) */
  readonly displayTimestamp: number;
}

/** 格式化时间戳为 MM-DD HH:mm */
export function formatSessionTimestamp(ts: number): string {
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

@Observed
export class ChatSessionListViewModel {
  /** 会话列表项(每次 reload 生成新数组,触发 ArkUI ForEach 重渲染) */
  sessions: ChatSessionListItem[] = [];
  /** 是否加载中 */
  isLoading: boolean = false;
  /** 错误信息(空表示无错误) */
  errorMessage: string = '';

  private readonly persistenceService: ChatPersistenceService;
  private readonly characterService: CharacterService;
  private disposed: boolean = false;

  constructor(
    persistenceService: ChatPersistenceService,
    characterService: CharacterService
  ) {
    this.persistenceService = persistenceService;
    this.characterService = characterService;
  }

  /**
   * 重新加载全部会话列表。
   * - 查询所有未归档会话
   * - 批量查询关联角色(已删除角色标记为 undefined,显示"未知角色")
   * - 批量查询最后一条消息预览
   * - 失败时保留旧列表,设置 errorMessage
   */
  async reload(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const chats: Chat[] = await this.persistenceService.listAllSessions();

      // 收集所有 characterId(去重),一次查询避免 N+1
      const characterIdSet: Set<string> = new Set<string>();
      for (let i = 0; i < chats.length; i++) {
        const cid: string | undefined = chats[i].characterId;
        if (cid !== undefined && cid.length > 0) {
          characterIdSet.add(cid);
        }
      }
      const characterMap: Map<string, Character | null> = new Map<string, Character | null>();
      const characterIds: string[] = Array.from(characterIdSet);
      for (let i = 0; i < characterIds.length; i++) {
        const id: string = characterIds[i];
        try {
          const c: Character | null = await this.characterService.getById(id);
          characterMap.set(id, c);
        } catch (e) {
          Logger.warn(LOG_TAG, 'load character failed: ' + String(e));
          characterMap.set(id, null);
        }
      }

      // 并行加载每个会话的最后消息预览(每个会话独立查询,失败不影响其他)
      const items: ChatSessionListItem[] = new Array(chats.length);
      for (let i = 0; i < chats.length; i++) {
        const chat: Chat = chats[i];
        let character: Character | null = null;
        let isDeleted: boolean = false;
        if (chat.characterId !== undefined && chat.characterId.length > 0) {
          const stored: Character | null | undefined = characterMap.get(chat.characterId);
          if (stored === undefined) {
            character = null;
            isDeleted = true;
          } else if (stored === null) {
            character = null;
            isDeleted = true;
          } else {
            character = stored;
            isDeleted = false;
          }
        }
        let preview: string = '';
        try {
          preview = await this.persistenceService.getLatestMessagePreview(chat.id);
        } catch (e) {
          Logger.warn(LOG_TAG, 'load preview failed: ' + String(e));
          preview = '';
        }
        const ts: number = chat.lastMessageAt > 0 ? chat.lastMessageAt : chat.updatedAt;
        items[i] = {
          chat: chat,
          character: character,
          isCharacterDeleted: isDeleted,
          lastMessagePreview: preview,
          displayTimestamp: ts
        };
      }
      this.sessions = items;
    } catch (e) {
      this.errorMessage = '加载会话列表失败';
      Logger.error(LOG_TAG, 'reload failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 重命名会话。
   * - 空标题拒绝(抛错,由调用方提示)
   * - 成功后原地更新 sessions 数组对应项(保持顺序,生成新引用触发 ForEach)
   *
   * @param chatId 会话 id
   * @param newTitle 新标题
   * @throws Error 标题为空 / 会话不存在 / 持久化失败
   */
  async renameSession(chatId: string, newTitle: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ViewModel disposed');
    }
    const updated: Chat = await this.persistenceService.renameSession(chatId, newTitle);
    // 原地更新对应项,保持列表顺序
    const newSessions: ChatSessionListItem[] = this.sessions.map((item: ChatSessionListItem): ChatSessionListItem => {
      if (item.chat.id === chatId) {
        return {
          chat: updated,
          character: item.character,
          isCharacterDeleted: item.isCharacterDeleted,
          lastMessagePreview: item.lastMessagePreview,
          displayTimestamp: item.displayTimestamp
        };
      }
      return item;
    });
    this.sessions = newSessions;
  }

  /**
   * 删除会话。
   * - 调用 persistenceService.deleteSession(同时删除 Chat 和所有 Message)
   * - 成功后从 sessions 数组移除对应项(生成新引用触发 ForEach)
   *
   * @param chatId 会话 id
   * @throws Error 持久化失败
   */
  async deleteSession(chatId: string): Promise<void> {
    if (this.disposed) {
      throw new Error('ViewModel disposed');
    }
    await this.persistenceService.deleteSession(chatId);
    const newSessions: ChatSessionListItem[] = this.sessions.filter((item: ChatSessionListItem): boolean => {
      return item.chat.id !== chatId;
    });
    this.sessions = newSessions;
  }

  /** 上移会话卡片 */
  async moveUp(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.errorMessage = '';
    try {
      await this.persistenceService.moveSessionUp(chatId);
      await this.reload();
    } catch (e) {
      this.errorMessage = '上移失败: ' + String(e);
      Logger.error(LOG_TAG, 'moveUp failed: ' + String(e));
    }
  }

  /** 下移会话卡片 */
  async moveDown(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.errorMessage = '';
    try {
      await this.persistenceService.moveSessionDown(chatId);
      await this.reload();
    } catch (e) {
      this.errorMessage = '下移失败: ' + String(e);
      Logger.error(LOG_TAG, 'moveDown failed: ' + String(e));
    }
  }

  /** 释放资源(防止后续异步操作) */
  dispose(): void {
    this.disposed = true;
    this.sessions = [];
  }
}
