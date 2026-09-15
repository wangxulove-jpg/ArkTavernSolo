/**
 * WorldGroupService 世界分组(章节记忆共享)业务服务
 *
 * 封装 WorldGroupRepository + ChatRepository,提供世界分组 CRUD、
 * 分组内会话查询与移动。
 *
 * 设计原则:
 * - 不依赖 ArkUI
 * - 不直接操作 SQL
 * - 删除分组时仅清空成员 chat 的 worldId,不删除会话
 */

import {
  WorldGroup,
  WorldGroupUpdates,
  createWorldGroup,
  validateWorldGroup,
  updateWorldGroup
} from '../models/WorldGroup';
import { Chat } from '../models/Chat';
import { WorldGroupRepository } from '../repositories/WorldGroupRepository';
import { ChatRepository } from '../repositories/ChatRepository';

export class WorldGroupService {
  private readonly worldGroupRepository: WorldGroupRepository;
  private readonly chatRepository: ChatRepository | null;

  constructor(
    worldGroupRepository: WorldGroupRepository,
    chatRepository: ChatRepository | null
  ) {
    this.worldGroupRepository = worldGroupRepository;
    this.chatRepository = chatRepository;
  }

  // ===== 世界分组 CRUD =====

  async list(): Promise<WorldGroup[]> {
    return await this.worldGroupRepository.list();
  }

  async getById(id: string): Promise<WorldGroup | null> {
    return await this.worldGroupRepository.getById(id);
  }

  async create(name: string, description: string = ''): Promise<WorldGroup> {
    const group: WorldGroup = createWorldGroup(name, description);
    const error: string | null = validateWorldGroup(group);
    if (error !== null) {
      throw new Error(error);
    }
    await this.worldGroupRepository.insert(group);
    return group;
  }

  async update(id: string, updates: WorldGroupUpdates): Promise<WorldGroup> {
    const existing: WorldGroup | null = await this.worldGroupRepository.getById(id);
    if (existing === null) {
      throw new Error('WorldGroup not found: ' + id);
    }
    const updated: WorldGroup = updateWorldGroup(existing, updates);
    const error: string | null = validateWorldGroup(updated);
    if (error !== null) {
      throw new Error(error);
    }
    await this.worldGroupRepository.update(updated);
    return updated;
  }

  /**
   * 删除世界分组。
   * 仅删除分组记录并清空成员 chat 的 worldId(不删会话)。
   */
  async removeWorldGroup(id: string): Promise<void> {
    if (this.chatRepository !== null) {
      const chats: Chat[] = await this.chatRepository.listByWorldId(id);
      for (let i = 0; i < chats.length; i++) {
        await this.chatRepository.updateWorldId(chats[i].id, '');
      }
    }
    await this.worldGroupRepository.remove(id);
  }

  // ===== 分组内会话 =====

  async listChatsInWorld(worldId: string): Promise<Chat[]> {
    if (this.chatRepository === null) {
      return [];
    }
    return await this.chatRepository.listByWorldId(worldId);
  }

  /**
   * 组内按 createdAt 降序的第一条会话。
   */
  async latestChatInWorld(worldId: string): Promise<Chat | null> {
    const chats: Chat[] = await this.listChatsInWorld(worldId);
    if (chats.length === 0) {
      return null;
    }
    let latest: Chat = chats[0];
    for (let i = 1; i < chats.length; i++) {
      if (chats[i].createdAt > latest.createdAt) {
        latest = chats[i];
      }
    }
    return latest;
  }

  /**
   * 将会话移入/移出世界分组。
   * worldId 为 null 时清空该会话的分组(移出)。
   */
  async moveChatToWorld(chatId: string, worldId: string | null): Promise<void> {
    if (this.chatRepository === null) {
      throw new Error('ChatRepository not available');
    }
    await this.chatRepository.updateWorldId(chatId, worldId === null ? '' : worldId);
  }
}
