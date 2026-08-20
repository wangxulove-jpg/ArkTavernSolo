/**
 * ChatPersistenceService
 *
 * 聊天会话持久化协调服务。
 * 负责:
 * - 协调 ChatRepository / MessageRepository / ChatPersistenceOperations
 * - 通过 DbHelper 事务保证关键操作的原子性
 * - 会话创建、加载、最近会话恢复
 * - 消息追加、更新、删除
 * - 流式中断消息规范化
 * - regenerate 删除旧消息 + 创建新消息(事务)
 *
 * 不依赖:
 * - ArkUI / 页面
 * - Provider / PromptBuilder / MacroReplacer / TokenCounter / HistoryTrimmer
 * - CharacterService(标题等元数据由调用方传入)
 *
 * 日志规则:
 * - 只记录数量、sequence、chatId 前缀
 * - 严禁记录消息正文、Character Prompt、世界书内容、宏替换结果、SQL、API Key
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatRepository } from '../repositories/ChatRepository';
import {
  MessageRepository,
  StoredChatMessage,
  MessagePageOptions
} from '../repositories/MessageRepository';
import { ChatPersistenceOperations } from '../repositories/ChatPersistenceOperations';
import { ConversationBranchPersistenceService } from './ConversationBranchPersistenceService';
import { Chat, createChat, updateChat } from '../models/Chat';
import { ChatMessage } from '../models/ChatMessage';
import { PersistedChatSession } from '../models/PersistedChatSession';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatPersistence';

/** 加载消息时的单页上限 */
const LOAD_MESSAGES_LIMIT: number = 200;

/** 默认会话标题(普通助手) */
const DEFAULT_TITLE_PLAIN: string = '新对话';

export interface AppendResult {
  readonly sequenceNumber: number;
}

export interface AppendUserAndAssistantResult {
  readonly userSequenceNumber: number;
  readonly assistantSequenceNumber: number;
}

/**
 * 聊天会话持久化服务。
 * 通过构造函数注入 DbHelper 和各 Repository,自身无页面状态。
 * branchPersistenceService 为可选参数,为 null 时跳过 Branch 操作(向后兼容旧测试)。
 */
export class ChatPersistenceService {
  private readonly dbHelper: DbHelper;
  private readonly chatRepository: ChatRepository;
  private readonly messageRepository: MessageRepository;
  private readonly chatPersistenceOperations: ChatPersistenceOperations;
  private readonly branchPersistenceService: ConversationBranchPersistenceService | null;

  constructor(
    dbHelper: DbHelper,
    chatRepository: ChatRepository,
    messageRepository: MessageRepository,
    chatPersistenceOperations: ChatPersistenceOperations,
    branchPersistenceService: ConversationBranchPersistenceService | null = null
  ) {
    this.dbHelper = dbHelper;
    this.chatRepository = chatRepository;
    this.messageRepository = messageRepository;
    this.chatPersistenceOperations = chatPersistenceOperations;
    this.branchPersistenceService = branchPersistenceService;
  }

  // ===== 会话级操作 =====

  /**
   * 打开指定角色(或普通助手)的最近未归档会话。
   * - characterId 为 undefined:查询 character_id IS NULL
   * - characterId 为字符串:查询 character_id = ?
   * - 不包含 archived
   * - 不存在返回 null
   *
   * 加载时自动规范化中断的 Streaming 消息为 Cancelled。
   *
   * @param characterId 角色 id(可选)
   * @returns 持久化会话,不存在返回 null
   */
  async openLatestSession(characterId?: string): Promise<PersistedChatSession | null> {
    const chat: Chat | null =
      await this.chatRepository.getLatestByCharacterId(characterId);
    if (chat === null) {
      return null;
    }
    return await this.loadSessionInternal(chat);
  }

  /**
   * 创建新会话。
   * - 使用 UUID 生成 chat.id
   * - characterId 可为空(普通助手)
   * - title 默认为"新对话"
   * - createdAt / updatedAt / lastMessageAt 使用当前时间
   * - 返回空 messages
   * - T-6.4A: 同一事务中创建 Root Branch + chat_branch_state
   *
   * @param characterId 角色 id(可选)
   * @param title 会话标题(可选,默认"新对话")
   * @returns 持久化会话(空消息列表)
   */
  async createSession(
    characterId?: string,
    title?: string
  ): Promise<PersistedChatSession> {
    const resolvedTitle: string = title !== undefined && title.length > 0
      ? title
      : DEFAULT_TITLE_PLAIN;
    const sortOrder: number = await this.nextSortOrder();
    const chat: Chat = createChat({
      id: generateUuid(),
      characterId: characterId,
      title: resolvedTitle,
      sortOrder: sortOrder
    });
    if (this.branchPersistenceService !== null) {
      try {
        await this.dbHelper.runInTransaction(
          async (store: relationalStore.RdbStore): Promise<void> => {
            await this.chatRepository.insertWithStore(store, chat);
            await this.branchPersistenceService!.ensureRootBranchWithStore(store, chat.id);
          },
          'session_create'
        );
      } catch (err) {
        if (err instanceof Error) {
          Logger.error(LOG_TAG, 'createSession failed: ' + err.message);
          throw err;
        }
        throw new Error(String(err));
      }
    } else {
      await this.chatRepository.insert(chat);
    }
    return {
      chat: chat,
      messages: [],
      maxSequenceNumber: 0
    };
  }

  /**
   * 创建新会话并写入 firstMessage(事务)。
   * 用于角色首次进入聊天时注入开场白。
   * - firstMessage 的 sequenceNumber = 1
   * - Chat 和 firstMessage 在同一事务中创建
   * - T-6.4A: 同一事务中创建 Root Branch + state + BranchMessageLink(firstMessage, pos=0)
   * - 失败全部回滚
   *
   * @param characterId 角色 id(可选)
   * @param title 会话标题(可选)
   * @param firstMessage 开场白消息(可选,为空时仅创建空会话)
   * @returns 持久化会话(含 firstMessage 或空消息列表)
   */
  async createSessionWithFirstMessage(
    characterId?: string,
    title?: string,
    firstMessage?: ChatMessage
  ): Promise<PersistedChatSession> {
    const resolvedTitle: string = title !== undefined && title.length > 0
      ? title
      : DEFAULT_TITLE_PLAIN;
    const sortOrder: number = await this.nextSortOrder();
    const chat: Chat = createChat({
      id: generateUuid(),
      characterId: characterId,
      title: resolvedTitle,
      sortOrder: sortOrder
    });

    if (firstMessage === undefined) {
      if (this.branchPersistenceService !== null) {
        try {
          await this.dbHelper.runInTransaction(
            async (store: relationalStore.RdbStore): Promise<void> => {
              await this.chatRepository.insertWithStore(store, chat);
              await this.branchPersistenceService!.ensureRootBranchWithStore(store, chat.id);
            },
            'session_create'
          );
        } catch (err) {
          if (err instanceof Error) {
            Logger.error(LOG_TAG, 'createSession empty failed: ' + err.message);
            throw err;
          }
          throw new Error(String(err));
        }
      } else {
        await this.chatRepository.insert(chat);
      }
      return {
        chat: chat,
        messages: [],
        maxSequenceNumber: 0
      };
    }

    const now: number = nowMillis();
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.chatRepository.insertWithStore(store, chat);
          await this.messageRepository.insertWithStore(
            store, firstMessage, chat.id, 1
          );
          await this.chatRepository.updateLastMessageAtWithStore(
            store, chat.id, now, now
          );
          // T-6.4A-R1: 原子创建 Root Branch + state + Link(firstMessage, pos=0)
          // 避免快照隔离导致 getActiveBranch 读不到刚创建的 state
          if (this.branchPersistenceService !== null) {
            await this.branchPersistenceService!.ensureRootBranchAndAppendFirstMessageWithStore(
              store, chat.id, firstMessage.id
            );
          }
        },
        'session_create_with_first_message'
      );
    } catch (err) {
      if (err instanceof Error) {
        Logger.error(LOG_TAG, 'createSessionWithFirstMessage failed: ' + err.message);
        throw err;
      }
      Logger.error(LOG_TAG, 'createSessionWithFirstMessage failed: ' + String(err));
      throw new Error(String(err));
    }
    return {
      chat: chat,
      messages: [firstMessage],
      maxSequenceNumber: 1
    };
  }

  /**
   * 加载指定会话。
   * - 不存在返回 null
   * - 自动规范化中断的 Streaming 消息为 Cancelled
   * - 消息按 sequence_number 升序返回
   *
   * @param chatId 会话 id
   * @returns 持久化会话,不存在返回 null
   */
  async loadSession(chatId: string): Promise<PersistedChatSession | null> {
    const chat: Chat | null = await this.chatRepository.getById(chatId);
    if (chat === null) {
      return null;
    }
    return await this.loadSessionInternal(chat);
  }

  /**
   * 删除完整会话(事务)。
   * - 同时删除 Chat 和其所有 Message
   * - 幂等:不存在的 Chat 不抛错
   *
   * @param chatId 会话 id
   */
  async deleteSession(chatId: string): Promise<void> {
    await this.chatPersistenceOperations.removeChatWithMessages(chatId);
  }

  /**
   * 列出当前聊天上下文下的会话。
   * 用于 T-4.5 多会话列表。
   *
   * - characterId 为字符串:精确查询 character_id = ?
   * - characterId 为 undefined:精确查询 character_id IS NULL(仅普通助手会话)
   * - 始终排除 archived
   * - 排序:last_message_at DESC → updated_at DESC → id ASC
   * - 默认最多读取 50 条
   * - 返回新数组,不修改 Chat 对象
   * - 不查询消息正文
   * - 不做 N+1 消息数量查询
   *
   * @param characterId 角色 id(可选,undefined 表示普通助手)
   * @param limit 上限(可选,默认 50)
   * @returns 会话列表(可能为空)
   */
  async listSessionsForContext(
    characterId?: string,
    limit?: number
  ): Promise<Chat[]> {
    const effectiveLimit: number = limit !== undefined && limit > 0 ? limit : 50;
    const chats: Chat[] = await this.chatRepository.listByExactCharacterId(
      characterId, { limit: effectiveLimit, offset: 0 }
    );
    return chats;
  }

  /**
   * 列出所有未归档的单聊会话(不限角色上下文)。
   * 用于"对话记录"Tab 展示全部单聊会话。
   *
   * G-DATA-1B:仅返回 ConversationMode.Single,多人聊天(Group)不在单聊列表展示。
   *
   * - 不按 character_id 过滤(普通助手会话 + 角色会话都返回)
   * - 始终排除 archived
   * - 始终排除 conversation_mode = 'group'
   * - 排序:last_message_at DESC → updated_at DESC → id ASC
   * - 默认最多 50 条
   * - 不查询消息正文
   *
   * @param limit 上限(可选,默认 50)
   * @returns 单聊会话列表(可能为空)
   */
  async listAllSessions(limit?: number): Promise<Chat[]> {
    const effectiveLimit: number = limit !== undefined && limit > 0 ? limit : 50;
    const chats: Chat[] = await this.chatRepository.listSingleChats({
      limit: effectiveLimit,
      offset: 0
    });
    return chats;
  }

  /**
   * 获取会话最后一条消息的预览文本(用于列表展示)。
   *
   * - 按 sequence_number DESC 取第一条
   * - 不返回完整内容,只取前 100 字符
   * - 无消息返回空字符串
   * - 不区分 Branch(展示物理最后一条,UI 用途)
   *
   * @param chatId 会话 id
   * @returns 消息预览文本(可能为空字符串)
   */
  async getLatestMessagePreview(chatId: string): Promise<string> {
    try {
      const messages: ChatMessage[] = await this.messageRepository.listByChat(
        chatId, { limit: 1, offset: 0, ascending: false }
      );
      if (messages.length === 0) {
        return '';
      }
      const content: string = messages[0].content;
      // 截取前 100 字符作为预览(避免长消息占用过多内存)
      const MAX_PREVIEW: number = 100;
      return content.length > MAX_PREVIEW
        ? content.substring(0, MAX_PREVIEW)
        : content;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getLatestMessagePreview failed: ' + String(e));
      return '';
    }
  }

  /**
   * 重命名会话(仅修改 title,不动 character / messages / branch)。
   *
   * - 空标题拒绝(抛错)
   * - 不存在抛错
   * - 自动更新 updatedAt
   * - 不修改 lastMessageAt(重命名不算活动)
   *
   * @param chatId 会话 id
   * @param newTitle 新标题(trim 后非空)
   * @returns 更新后的 Chat
   * @throws Error 会话不存在 / 标题为空
   */
  async renameSession(chatId: string, newTitle: string): Promise<Chat> {
    const trimmed: string = newTitle.trim();
    if (trimmed.length === 0) {
      throw new Error('会话名称不能为空');
    }
    const existing: Chat | null = await this.chatRepository.getById(chatId);
    if (existing === null) {
      throw new Error('会话不存在或已删除');
    }
    if (existing.title === trimmed) {
      // 标题未变化,直接返回(避免无意义写入)
      return existing;
    }
    const updated: Chat = updateChat(existing, { title: trimmed });
    await this.chatRepository.update(updated);
    return updated;
  }

  /**
   * 更新会话的对话级用户称呼覆盖(v9 引入)。
   * - 传入空字符串等同于清空覆盖(回退到角色或全局)
   * - 持久化到 chat.user_name_override 列
   * - 不修改角色或全局设置
   *
   * @param chatId 会话 id
   * @param override 新的覆盖值(空字符串表示清空)
   * @returns 更新后的 Chat
   * @throws Error 会话不存在
   */
  async updateUserNameOverride(chatId: string, override: string): Promise<Chat> {
    const existing: Chat | null = await this.chatRepository.getById(chatId);
    if (existing === null) {
      throw new Error('会话不存在或已删除');
    }
    const trimmed: string = override.trim();
    if (existing.userNameOverride === trimmed) {
      // 值未变化,直接返回(避免无意义写入)
      return existing;
    }
    const updated: Chat = updateChat(existing, { userNameOverride: trimmed });
    await this.chatRepository.update(updated);
    return updated;
  }

  /**
   * 更新会话的角色状态配置 JSON(CHAT-STATUS-1A,v34 引入)。
   * - 序列化后的 ChatStatusState 字符串,写入 chat.status_config_json 列
   * - 不修改消息/角色/其它字段
   *
   * @param chatId 会话 id
   * @param statusConfigJson 序列化后的状态配置 JSON(空字符串表示清空)
   * @returns 更新后的 Chat
   * @throws Error 会话不存在
   */
  async updateChatStatusConfig(chatId: string, statusConfigJson: string): Promise<Chat> {
    const existing: Chat | null = await this.chatRepository.getById(chatId);
    if (existing === null) {
      throw new Error('会话不存在或已删除');
    }
    if (existing.statusConfigJson === statusConfigJson) {
      // 值未变化,直接返回(避免无意义写入)
      return existing;
    }
    const updated: Chat = updateChat(existing, { statusConfigJson: statusConfigJson });
    await this.chatRepository.update(updated);
    return updated;
  }

  /**
   * 创建新会话(不删除旧会话)。
   * 用于 T-4.5 多会话新建。
   *
   * - 创建全新的 Chat ID(旧会话保留)
   * - 有角色 firstMessage 时,事务创建 Chat 和 firstMessage
   * - 无 firstMessage 时创建空 Chat
   * - firstMessage 只持久化一次
   * - 不自动删除旧会话
   * - 不自动归档旧会话
   *
   * @param characterId 角色 id(可选)
   * @param firstMessage 开场白消息(可选,有值时持久化为 sequence=1)
   * @param title 会话标题(可选,默认"新对话")
   * @returns 持久化会话(含 firstMessage 或空消息列表)
   */
  async createNewSession(
    characterId?: string,
    firstMessage?: ChatMessage,
    title?: string
  ): Promise<PersistedChatSession> {
    if (firstMessage === undefined) {
      return await this.createSession(characterId, title);
    }
    return await this.createSessionWithFirstMessage(characterId, title, firstMessage);
  }

  // ===== 消息级操作 =====

  /**
   * 追加单条消息。
   * - 自动计算 next sequenceNumber = max(sequence_number) + 1
   * - 持久化成功后更新 Chat 活跃时间
   * - T-6.4A: 同一事务中将 Message 加入 Active Branch
   * - 返回分配的 sequenceNumber
   *
   * @param chatId 会话 id
   * @param message 待追加的消息
   * @returns 分配的 sequenceNumber
   */
  async appendMessage(
    chatId: string,
    message: ChatMessage
  ): Promise<number> {
    const maxSeq: number = await this.messageRepository.getMaxSequenceNumber(chatId);
    const nextSeq: number = maxSeq + 1;
    const now: number = nowMillis();
    if (this.branchPersistenceService !== null) {
      try {
        await this.dbHelper.runInTransaction(
          async (store: relationalStore.RdbStore): Promise<void> => {
            await this.messageRepository.insertWithStore(store, message, chatId, nextSeq);
            await this.chatRepository.updateLastMessageAtWithStore(store, chatId, now, now);
            await this.branchPersistenceService!.appendMessageToActiveBranchWithStore(
              store, chatId, message.id
            );
          },
          'message_append'
        );
      } catch (err) {
        if (err instanceof Error) {
          Logger.error(LOG_TAG, 'appendMessage failed: ' + err.message);
          throw err;
        }
        throw new Error(String(err));
      }
    } else {
      await this.messageRepository.insert(message, chatId, nextSeq);
      await this.updateChatActivity(chatId, now);
    }
    return nextSeq;
  }

  /**
   * 事务追加 User + Streaming Assistant 两条消息。
   * - User sequence = maxSeq + 1
   * - Assistant sequence = maxSeq + 2
   * - 两条消息在同一事务中创建
   * - T-6.4A: 同一事务中将两条消息加入 Active Branch
   * - 失败全部回滚
   *
   * @param chatId 会话 id
   * @param userMessage 用户消息
   * @param assistantMessage 助手占位消息(Streaming)
   * @returns 两条消息的 sequenceNumber
   */
  async appendUserAndStreamingAssistant(
    chatId: string,
    userMessage: ChatMessage,
    assistantMessage: ChatMessage
  ): Promise<AppendUserAndAssistantResult> {
    const maxSeq: number = await this.messageRepository.getMaxSequenceNumber(chatId);
    const userSeq: number = maxSeq + 1;
    const assistantSeq: number = maxSeq + 2;
    const now: number = nowMillis();

    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.messageRepository.insertWithStore(
            store, userMessage, chatId, userSeq
          );
          await this.messageRepository.insertWithStore(
            store, assistantMessage, chatId, assistantSeq
          );
          await this.chatRepository.updateLastMessageAtWithStore(
            store, chatId, now, now
          );
          // T-6.4A-R1: 原子追加 User + Assistant 到 Active Branch
          // 必须一次性追加,避免 RDB 快照隔离导致 position 冲突
          if (this.branchPersistenceService !== null) {
            await this.branchPersistenceService!.appendMessagePairToActiveBranchWithStore(
              store, chatId, userMessage.id, assistantMessage.id
            );
          }
        },
        'message_pair_append'
      );
    } catch (err) {
      if (err instanceof Error) {
        Logger.error(LOG_TAG, 'appendUserAndAssistant failed: ' + err.message);
        throw err;
      }
      Logger.error(LOG_TAG, 'appendUserAndAssistant failed: ' + String(err));
      throw new Error(String(err));
    }
    return {
      userSequenceNumber: userSeq,
      assistantSequenceNumber: assistantSeq
    };
  }

  /**
   * 更新消息(用于 Streaming delta / Complete / Cancelled / Failed)。
   * - 不更新 Chat 活跃时间(避免 delta 频繁写库)
   * - 最终状态(Complete/Cancel/Failed)后由调用方显式调用 updateChatActivity
   *
   * @param chatId 会话 id(保留参数,当前实现未使用,后续可校验归属)
   * @param message 待更新的消息
   */
  async updateMessage(
    chatId: string,
    message: ChatMessage
  ): Promise<void> {
    await this.messageRepository.update(message);
  }

  /**
   * 删除指定 sequenceNumber 之后的所有消息(不包含边界)。
   * - 使用 sequence_number > sequenceNumber
   * - 返回删除行数
   *
   * @param chatId 会话 id
   * @param sequenceNumber 边界 sequenceNumber(保留)
   * @returns 删除行数
   */
  async removeMessagesAfter(
    chatId: string,
    sequenceNumber: number
  ): Promise<number> {
    const deleted: number =
      await this.messageRepository.removeAfterSequence(chatId, sequenceNumber);
    return deleted;
  }

  /**
   * 删除指定 User 消息之后的所有消息(保留 User 本身)。
   * 用于 regenerate 场景。
   * - 通过 listRecordsByChat 查找 userMessageId 的 sequenceNumber
   * - 调用 removeAfterSequence 删除后续消息
   *
   * @param chatId 会话 id
   * @param userMessageId 用户消息 id
   * @returns 删除行数
   */
  async replaceMessagesAfterUser(
    chatId: string,
    userMessageId: string
  ): Promise<number> {
    const userSeq: number | null =
      await this.findSequenceById(chatId, userMessageId);
    if (userSeq === null) {
      Logger.warn(LOG_TAG, 'replaceMessagesAfterUser: user message not found');
      return 0;
    }
    return await this.removeMessagesAfter(chatId, userSeq);
  }

  /**
   * 事务执行 regenerate:
   * 1. 删除指定 User 消息之后的所有旧 Assistant 消息
   * 2. 创建新的 Streaming Assistant 消息
   *
   * - User 消息保留
   * - firstMessage 和更早历史保留
   * - 删除和创建在同一事务中,失败全部回滚
   * - T-6.4A: 同一事务中将新 Assistant 加入 Active Branch
   *   (旧 Assistant 的 BranchMessageLink 因 Message 被删成为孤儿,
   *    loadActiveBranchMessages 会跳过缺失的 Message,不影响显示)
   *
   * @param chatId 会话 id
   * @param userMessageId 用户消息 id
   * @param assistantMessage 新的 Assistant 占位消息
   * @returns 新 Assistant 的 sequenceNumber
   */
  async replaceMessagesAfterUserAndAppend(
    chatId: string,
    userMessageId: string,
    assistantMessage: ChatMessage
  ): Promise<number> {
    const userSeq: number | null =
      await this.findSequenceById(chatId, userMessageId);
    if (userSeq === null) {
      throw new Error('replaceMessagesAfterUserAndAppend: user message not found');
    }
    const assistantSeq: number = userSeq + 1;
    const now: number = nowMillis();

    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          await this.messageRepository.removeAfterSequenceWithStore(
            store, chatId, userSeq
          );
          await this.messageRepository.insertWithStore(
            store, assistantMessage, chatId, assistantSeq
          );
          await this.chatRepository.updateLastMessageAtWithStore(
            store, chatId, now, now
          );
          // T-6.4A: 将新 Assistant 加入 Active Branch
          if (this.branchPersistenceService !== null) {
            await this.branchPersistenceService!.appendMessageToActiveBranchWithStore(
              store, chatId, assistantMessage.id
            );
          }
        },
        'message_replace_after_user'
      );
    } catch (err) {
      if (err instanceof Error) {
        Logger.error(LOG_TAG, 'replaceAndAppend failed: ' + err.message);
        throw err;
      }
      Logger.error(LOG_TAG, 'replaceAndAppend failed: ' + String(err));
      throw new Error(String(err));
    }
    return assistantSeq;
  }

  /**
   * 更新 Chat 活跃时间。
   * - 同时更新 lastMessageAt 和 updatedAt
   *
   * @param chatId 会话 id
   * @param timestamp 时间戳(毫秒)
   */
  async updateChatActivity(
    chatId: string,
    timestamp: number
  ): Promise<void> {
    await this.chatRepository.updateLastMessageAt(chatId, timestamp, timestamp);
  }

  /**
   * 仅更新 Chat 的 updatedAt(不修改 lastMessageAt)。
   * 用于 Swipe 切换候选等不改变对话内容的操作。
   *
   * @param chatId 会话 id
   * @param timestamp 时间戳(毫秒)
   */
  async updateChatTimestamp(
    chatId: string,
    timestamp: number
  ): Promise<void> {
    await this.chatRepository.updateChatTimestamp(chatId, timestamp);
  }

  // ===== 内部方法 =====

  /**
   * 加载会话内部实现:
   * 1. 规范化中断的 Streaming 消息
   * 2. T-6.4A: 优先通过 Active Branch 加载消息路径(按 position ASC)
   *    - branchPersistenceService 存在时使用 Branch Link + SwipeSelection 投影
   *    - 否则回退到 MessageRepository.listRecordsByChat(按 sequence 升序)
   * 3. maxSequenceNumber 始终从 messages 表查询(全局最大值,不受 Branch 投影影响)
   */
  private async loadSessionInternal(chat: Chat): Promise<PersistedChatSession> {
    await this.messageRepository.normalizeInterruptedMessages(chat.id);

    let messages: ChatMessage[];
    let maxSeq: number;

    if (this.branchPersistenceService !== null) {
      // T-6.4A: 通过 Active Branch 加载消息路径(只读,不开启写事务)
      messages = await this.branchPersistenceService.loadActiveBranchMessages(chat.id);
      maxSeq = await this.messageRepository.getMaxSequenceNumber(chat.id);
    } else {
      // 回退:直接从 messages 表加载(无 Branch 支持)
      const options: MessagePageOptions = {
        limit: LOAD_MESSAGES_LIMIT,
        offset: 0,
        ascending: true
      };
      const records: StoredChatMessage[] =
        await this.messageRepository.listRecordsByChat(chat.id, options);
      messages = records.map(
        (rec: StoredChatMessage): ChatMessage => rec.message
      );
      maxSeq = records.length > 0
        ? records[records.length - 1].sequenceNumber
        : 0;
    }

    return {
      chat: chat,
      messages: messages,
      maxSequenceNumber: maxSeq
    };
  }

  /**
   * 查找指定消息 id 的 sequenceNumber。
   * 通过 listRecordsByChat 加载所有记录后匹配 id。
   * 未找到返回 null。
   */
  private async findSequenceById(
    chatId: string,
    messageId: string
  ): Promise<number | null> {
    const options: MessagePageOptions = {
      limit: LOAD_MESSAGES_LIMIT,
      offset: 0,
      ascending: true
    };
    const records: StoredChatMessage[] =
      await this.messageRepository.listRecordsByChat(chatId, options);
    for (let i = 0; i < records.length; i++) {
      if (records[i].message.id === messageId) {
        return records[i].sequenceNumber;
      }
    }
    return null;
  }

  /**
   * 计算下一个 sort_order(用于新建会话时分配)。
   * 空表返回 0。
   */
  private async nextSortOrder(): Promise<number> {
    const max: number = await this.chatRepository.getMaxSortOrder();
    return max < 0 ? 0 : max + 1;
  }

  /**
   * 上移会话卡片(与上一条交换 sort_order)。
   * 已是第一条时无操作返回。
   */
  async moveSessionUp(chatId: string): Promise<void> {
    const chats: Chat[] = await this.chatRepository.list({
      includeArchived: false,
      limit: 200,
      offset: 0
    });
    let index: number = -1;
    for (let i = 0; i < chats.length; i++) {
      if (chats[i].id === chatId) {
        index = i;
        break;
      }
    }
    if (index <= 0) {
      return;
    }
    await this.chatRepository.swapSortOrder(chatId, chats[index - 1].id);
  }

  /**
   * 下移会话卡片(与下一条交换 sort_order)。
   * 已是最后一条时无操作返回。
   */
  async moveSessionDown(chatId: string): Promise<void> {
    const chats: Chat[] = await this.chatRepository.list({
      includeArchived: false,
      limit: 200,
      offset: 0
    });
    let index: number = -1;
    for (let i = 0; i < chats.length; i++) {
      if (chats[i].id === chatId) {
        index = i;
        break;
      }
    }
    if (index < 0 || index >= chats.length - 1) {
      return;
    }
    await this.chatRepository.swapSortOrder(chatId, chats[index + 1].id);
  }
}
