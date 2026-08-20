/**
 * ChatArchiveService 聊天归档导出服务
 *
 * 职责:
 * - 查询单个对话及全部消息、分支、Swipe
 * - 查询当前角色全部对话
 * - 按消息实际顺序排序
 * - 转换为 ArkTavernChatArchive v1
 * - 生成 UTF-8 JSON
 * - 保存到用户选择的位置(通过 DocumentViewPicker)
 * - 返回导出统计
 *
 * 依赖:
 * - ChatPersistenceService(查询会话)
 * - MessageRepository(查询消息)
 * - ConversationBranchPersistenceService(查询分支、消息链接、Swipe 选择)
 * - MessageSwipeRepository(查询 Swipe 候选组与候选)
 * - CharacterService(查询角色信息)
 *
 * 不依赖:
 * - ArkUI / 页面
 * - Provider / PromptBuilder
 *
 * 日志规则:
 * - 只记录数量、SHA-256 前 8 位、阶段
 * - 严禁记录消息正文、API Key、完整文件路径
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Chat } from '../models/Chat';
import { ChatMessage, ChatMessageStatus, MessageSenderType, MessageVisibility } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { Character } from '../models/Character';
import {
  ConversationBranch,
  BranchMessageLink,
  BranchSwipeSelection,
  ConversationBranchSummary
} from '../models/ConversationBranch';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate
} from '../models/MessageSwipe';
import { ChatRepository } from '../repositories/ChatRepository';
import { MessageRepository, StoredChatMessage } from '../repositories/MessageRepository';
import { MessageSwipeRepository } from '../repositories/MessageSwipeRepository';
import { ConversationBranchRepository } from '../repositories/ConversationBranchRepository';
import { CharacterRepository } from '../repositories/CharacterRepository';
import { Logger } from '../utils/Logger';
import { nowMillis } from '../utils/Time';
import {
  ARCHIVE_FORMAT,
  ARCHIVE_VERSION,
  ARCHIVE_FILE_EXTENSION,
  ArchiveScope,
  ArchiveMessageRole,
  ArchiveMessageStatus,
  ArchiveMessageSource,
  ArchiveMessageSenderType,
  ArchiveMessageVisibility,
  ArchiveCharacterInfo,
  ArchiveSwipeCandidate,
  ArchiveSwipeGroup,
  ArchiveBranchMessageLink,
  ArchiveBranchSwipeSelection,
  ArchiveBranch,
  ArchiveMessage,
  ArchiveConversation,
  ArkTavernChatArchive,
  ChatArchiveExportStats
} from '../parser/ChatArchiveSchema';

const LOG_TAG: string = 'ChatArchiveService';

/** 单次查询消息的分页大小 */
const MESSAGE_PAGE_SIZE: number = 200;

/** 文件名非法字符(Windows + 通用) */
const ILLEGAL_FILENAME_CHARS: RegExp = /[\\/:*?"<>|]/g;

/** 文件名最大长度(含扩展名) */
const MAX_FILENAME_LENGTH: number = 200;

export class ChatArchiveService {
  private readonly chatRepository: ChatRepository;
  private readonly messageRepository: MessageRepository;
  private readonly swipeRepository: MessageSwipeRepository;
  private readonly branchRepository: ConversationBranchRepository;
  private readonly characterRepository: CharacterRepository;

  constructor(
    chatRepository: ChatRepository,
    messageRepository: MessageRepository,
    swipeRepository: MessageSwipeRepository,
    branchRepository: ConversationBranchRepository,
    characterRepository: CharacterRepository
  ) {
    this.chatRepository = chatRepository;
    this.messageRepository = messageRepository;
    this.swipeRepository = swipeRepository;
    this.branchRepository = branchRepository;
    this.characterRepository = characterRepository;
  }

  /**
   * 导出单个对话到指定文件 URI。
   *
   * @param conversationId 对话 ID
   * @param targetUri DocumentViewPicker.save 返回的文件 URI
   * @returns 导出统计
   * @throws Error 对话不存在 / 文件写入失败
   */
  async exportConversation(
    conversationId: string,
    targetUri: string
  ): Promise<ChatArchiveExportStats> {
    if (conversationId.length === 0) {
      throw new Error('conversationId 不能为空');
    }
    if (targetUri.length === 0) {
      throw new Error('targetUri 不能为空');
    }
    Logger.info(LOG_TAG, 'exportConversation start id=' + conversationId.substring(0, 8));

    const chat: Chat | null = await this.chatRepository.getById(conversationId);
    if (chat === null) {
      throw new Error('对话不存在或已删除');
    }

    const archive: ArkTavernChatArchive = await this.buildArchiveForSingleChat(chat);
    const stats: ChatArchiveExportStats = this.computeStats(archive, targetUri, 'single');
    const json: string = JSON.stringify(archive, null, 2);
    await this.writeToFile(targetUri, json);

    Logger.info(
      LOG_TAG,
      'exportConversation done convs=' + String(stats.conversationCount)
        + ' msgs=' + String(stats.messageCount)
    );
    return stats;
  }

  /**
   * 导出指定角色的全部对话到文件 URI。
   *
   * @param characterId 角色 ID
   * @param targetUri DocumentViewPicker.save 返回的文件 URI
   * @returns 导出统计
   * @throws Error 角色不存在 / 无对话 / 文件写入失败
   */
  async exportCharacterConversations(
    characterId: string,
    targetUri: string
  ): Promise<ChatArchiveExportStats> {
    if (characterId.length === 0) {
      throw new Error('characterId 不能为空');
    }
    if (targetUri.length === 0) {
      throw new Error('targetUri 不能为空');
    }
    Logger.info(LOG_TAG, 'exportCharacter start charId=' + characterId.substring(0, 8));

    const character: Character | null = await this.characterRepository.getById(characterId);
    if (character === null) {
      throw new Error('角色不存在');
    }

    const chats: Chat[] = await this.chatRepository.listByExactCharacterId(
      characterId, { limit: 200, offset: 0 }
    );
    if (chats.length === 0) {
      throw new Error('该角色暂无对话记录');
    }

    const conversations: ArchiveConversation[] = [];
    for (let i: number = 0; i < chats.length; i++) {
      const conv: ArchiveConversation = await this.buildConversation(chats[i]);
      conversations.push(conv);
    }

    const characterInfo: ArchiveCharacterInfo = {
      sourceCharacterId: character.id,
      name: character.name,
      avatarName: this.extractAvatarName(character.avatarUri)
    };

    const archive: ArkTavernChatArchive = {
      format: ARCHIVE_FORMAT,
      version: ARCHIVE_VERSION,
      scope: 'character',
      exportedAt: nowMillis(),
      appVersion: '',
      character: characterInfo,
      conversations: conversations
    };

    const stats: ChatArchiveExportStats = this.computeStats(archive, targetUri, 'character');
    const json: string = JSON.stringify(archive, null, 2);
    await this.writeToFile(targetUri, json);

    Logger.info(
      LOG_TAG,
      'exportCharacter done convs=' + String(stats.conversationCount)
        + ' msgs=' + String(stats.messageCount)
    );
    return stats;
  }

  /**
   * 为单个对话构建归档对象。
   */
  private async buildArchiveForSingleChat(chat: Chat): Promise<ArkTavernChatArchive> {
    const conversation: ArchiveConversation = await this.buildConversation(chat);

    let characterInfo: ArchiveCharacterInfo = {
      sourceCharacterId: '',
      name: '',
      avatarName: ''
    };
    if (chat.characterId !== undefined && chat.characterId.length > 0) {
      const character: Character | null = await this.characterRepository.getById(chat.characterId);
      if (character !== null) {
        characterInfo = {
          sourceCharacterId: character.id,
          name: character.name,
          avatarName: this.extractAvatarName(character.avatarUri)
        };
      }
    }

    return {
      format: ARCHIVE_FORMAT,
      version: ARCHIVE_VERSION,
      scope: 'single',
      exportedAt: nowMillis(),
      appVersion: '',
      character: characterInfo,
      conversations: [conversation]
    };
  }

  /**
   * 为单个 Chat 构建 ArchiveConversation(含 messages / branches / swipeGroups)。
   */
  private async buildConversation(chat: Chat): Promise<ArchiveConversation> {
    // 1. 加载全部消息(分页拼接,按 sequence 升序)
    const messages: ArchiveMessage[] = await this.loadAllMessages(chat.id);

    // 2. 加载全部 Branch 摘要
    const branchSummaries: ConversationBranchSummary[] =
      await this.branchRepository.listBranches(chat.id);

    // 3. 加载每个 Branch 的 messageLinks 和 swipeSelections
    const branches: ArchiveBranch[] = [];
    for (let i: number = 0; i < branchSummaries.length; i++) {
      const summary: ConversationBranchSummary = branchSummaries[i];
      const links: BranchMessageLink[] =
        await this.branchRepository.listMessageLinks(summary.id);
      const selections: BranchSwipeSelection[] =
        await this.branchRepository.listSwipeSelections(summary.id);
      branches.push(this.toArchiveBranch(summary, links, selections));
    }

    // 4. 加载全部 Swipe 候选组
    const groups: MessageSwipeGroup[] =
      await this.swipeRepository.listGroupsByChatId(chat.id);
    const swipeGroups: ArchiveSwipeGroup[] = [];
    for (let i: number = 0; i < groups.length; i++) {
      const group: MessageSwipeGroup = groups[i];
      const candidates: MessageSwipeCandidate[] =
        await this.swipeRepository.listCandidates(group.assistantMessageId);
      swipeGroups.push(this.toArchiveSwipeGroup(group, candidates));
    }

    return {
      sourceConversationId: chat.id,
      title: chat.title,
      createdAt: chat.createdAt,
      updatedAt: chat.updatedAt,
      lastMessageAt: chat.lastMessageAt,
      userNameOverride: chat.userNameOverride,
      sortOrder: chat.sortOrder,
      messages: messages,
      branches: branches,
      swipeGroups: swipeGroups
    };
  }

  /**
   * 分页加载指定 Chat 的全部消息,按 sequence 升序拼接。
   */
  private async loadAllMessages(chatId: string): Promise<ArchiveMessage[]> {
    const result: ArchiveMessage[] = [];
    let offset: number = 0;
    while (true) {
      const records: StoredChatMessage[] = await this.messageRepository.listRecordsByChat(
        chatId, { limit: MESSAGE_PAGE_SIZE, offset: offset, ascending: true }
      );
      if (records.length === 0) {
        break;
      }
      for (let i: number = 0; i < records.length; i++) {
        result.push(this.toArchiveMessage(records[i].message, records[i].sequenceNumber));
      }
      if (records.length < MESSAGE_PAGE_SIZE) {
        break;
      }
      offset += records.length;
    }
    return result;
  }

  /**
   * 将 ChatMessage 转换为 ArchiveMessage。
   * 过滤掉非持久化 source(理论上不会出现,但保险起见)。
   */
  private toArchiveMessage(msg: ChatMessage, sequenceNumber: number): ArchiveMessage {
    const role: ArchiveMessageRole = this.roleToArchive(msg.role);
    const status: ArchiveMessageStatus = this.statusToArchive(
      msg.status !== undefined ? msg.status : ChatMessageStatus.Completed
    );
    const source: ArchiveMessageSource = this.sourceToArchive(msg.source);
    const senderType: ArchiveMessageSenderType = this.senderTypeToArchive(
      msg.senderType !== undefined ? msg.senderType : 'user'
    );
    const visibility: ArchiveMessageVisibility = this.visibilityToArchive(
      msg.visibility !== undefined ? msg.visibility : 'public'
    );
    return {
      sourceMessageId: msg.id,
      role: role,
      content: msg.content,
      createdAt: msg.createdAt,
      updatedAt: msg.updatedAt !== undefined ? msg.updatedAt : 0,
      order: sequenceNumber,
      status: status,
      errorMessage: msg.errorMessage !== undefined ? msg.errorMessage : '',
      source: source,
      senderType: senderType,
      senderCharacterId: msg.senderCharacterId !== undefined ? msg.senderCharacterId : '',
      sceneId: msg.sceneId !== undefined ? msg.sceneId : '',
      generationBatchId: msg.generationBatchId !== undefined ? msg.generationBatchId : '',
      visibility: visibility,
      recipientCharacterIds: msg.recipientCharacterIds !== undefined ? msg.recipientCharacterIds.slice() : [],
      participantIds: msg.participantIds !== undefined ? msg.participantIds.slice() : [],
      witnessIds: msg.witnessIds !== undefined ? msg.witnessIds.slice() : []
    };
  }

  /**
   * 将 ConversationBranchSummary + Links + Selections 转换为 ArchiveBranch。
   */
  private toArchiveBranch(
    summary: ConversationBranchSummary,
    links: BranchMessageLink[],
    selections: BranchSwipeSelection[]
  ): ArchiveBranch {
    const messageLinks: ArchiveBranchMessageLink[] = links.map(
      (link: BranchMessageLink): ArchiveBranchMessageLink => {
        return {
          sourceMessageId: link.messageId,
          position: link.position
        };
      }
    );
    const swipeSelections: ArchiveBranchSwipeSelection[] = selections.map(
      (sel: BranchSwipeSelection): ArchiveBranchSwipeSelection => {
        return {
          sourceAssistantMessageId: sel.assistantMessageId,
          candidateIndex: sel.candidateIndex
        };
      }
    );
    return {
      sourceBranchId: summary.id,
      parentSourceBranchId: summary.parentBranchId !== undefined ? summary.parentBranchId : '',
      forkSourceMessageId: summary.forkMessageId !== undefined ? summary.forkMessageId : '',
      name: summary.name,
      isRoot: summary.isRoot,
      createdAt: summary.createdAt,
      updatedAt: summary.updatedAt,
      lastMessageAt: summary.lastMessageAt,
      messageLinks: messageLinks,
      swipeSelections: swipeSelections
    };
  }

  /**
   * 将 MessageSwipeGroup + Candidates 转换为 ArchiveSwipeGroup。
   */
  private toArchiveSwipeGroup(
    group: MessageSwipeGroup,
    candidates: MessageSwipeCandidate[]
  ): ArchiveSwipeGroup {
    const archCandidates: ArchiveSwipeCandidate[] = candidates.map(
      (c: MessageSwipeCandidate): ArchiveSwipeCandidate => {
        return {
          sourceCandidateId: c.id,
          candidateIndex: c.candidateIndex,
          content: c.content,
          status: this.statusToArchive(c.status),
          errorMessage: c.errorMessage !== undefined ? c.errorMessage : '',
          isStreaming: c.isStreaming,
          createdAt: c.createdAt,
          updatedAt: c.updatedAt !== undefined ? c.updatedAt : 0
        };
      }
    );
    return {
      sourceAssistantMessageId: group.assistantMessageId,
      activeCandidateIndex: group.activeCandidateIndex,
      createdAt: group.createdAt,
      updatedAt: group.updatedAt,
      candidates: archCandidates
    };
  }

  private roleToArchive(role: ChatRole): ArchiveMessageRole {
    if (role === ChatRole.System) return 'system';
    if (role === ChatRole.User) return 'user';
    return 'assistant';
  }

  private statusToArchive(status: ChatMessageStatus): ArchiveMessageStatus {
    if (status === ChatMessageStatus.Streaming) return 'streaming';
    if (status === ChatMessageStatus.Completed) return 'completed';
    if (status === ChatMessageStatus.Cancelled) return 'cancelled';
    return 'failed';
  }

  private sourceToArchive(source: ChatMessageSource | undefined): ArchiveMessageSource {
    if (source === ChatMessageSource.CharacterFirstMessage) return 'characterFirstMessage';
    if (source === ChatMessageSource.ExternalSystem) return 'externalSystem';
    return 'conversation';
  }

  private senderTypeToArchive(senderType: MessageSenderType): ArchiveMessageSenderType {
    if (senderType === 'character') return 'character';
    if (senderType === 'narrator') return 'narrator';
    return 'user';
  }

  private visibilityToArchive(visibility: MessageVisibility): ArchiveMessageVisibility {
    if (visibility === 'private') return 'private';
    if (visibility === 'narrator') return 'narrator';
    return 'public';
  }

  /**
   * 从头像 URI 提取文件名(仅元数据)。
   * 如果不是文件 URI,返回空字符串。
   */
  private extractAvatarName(avatarUri: string): string {
    if (avatarUri.length === 0) {
      return '';
    }
    const lastSlash: number = avatarUri.lastIndexOf('/');
    if (lastSlash < 0 || lastSlash >= avatarUri.length - 1) {
      return '';
    }
    const name: string = avatarUri.substring(lastSlash + 1);
    // 限制长度
    if (name.length > 100) {
      return name.substring(0, 100);
    }
    return name;
  }

  /**
   * 计算导出统计。
   */
  private computeStats(
    archive: ArkTavernChatArchive,
    targetUri: string,
    scope: ArchiveScope
  ): ChatArchiveExportStats {
    let messageCount: number = 0;
    let branchCount: number = 0;
    let candidateCount: number = 0;
    for (let i: number = 0; i < archive.conversations.length; i++) {
      const conv: ArchiveConversation = archive.conversations[i];
      messageCount += conv.messages.length;
      branchCount += conv.branches.length;
      for (let j: number = 0; j < conv.swipeGroups.length; j++) {
        candidateCount += conv.swipeGroups[j].candidates.length;
      }
    }
    return {
      conversationCount: archive.conversations.length,
      messageCount: messageCount,
      branchCount: branchCount,
      candidateCount: candidateCount,
      targetUri: targetUri
    };
  }

  /**
   * 将 JSON 字符串写入文件 URI(UTF-8 编码)。
   */
  private async writeToFile(uri: string, content: string): Promise<void> {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(content);
      fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
    } catch (e) {
      Logger.error(LOG_TAG, 'writeToFile failed: ' + String(e));
      throw new Error('写入文件失败: ' + String(e));
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          Logger.warn(LOG_TAG, 'closeSync failed: ' + String(e));
        }
      }
    }
  }

  /**
   * 生成默认导出文件名。
   * 格式:角色名_对话标题_YYYYMMDD_HHmm.arktchat.json
   * 过滤非法字符 \ / : * ? " < > |
   */
  static generateFileName(
    characterName: string,
    conversationTitle: string,
    timestamp: number = nowMillis()
  ): string {
    const safeCharName: string = ChatArchiveService.sanitizeFileSegment(characterName, 'character');
    const safeConvName: string = ChatArchiveService.sanitizeFileSegment(conversationTitle, 'chat');
    const date: Date = new Date(timestamp);
    const year: number = date.getFullYear();
    const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
    const day: string = date.getDate().toString().padStart(2, '0');
    const hour: string = date.getHours().toString().padStart(2, '0');
    const minute: string = date.getMinutes().toString().padStart(2, '0');
    const name: string = safeCharName + '_' + safeConvName + '_' + year + month + day + '_' + hour + minute + ARCHIVE_FILE_EXTENSION;
    if (name.length > MAX_FILENAME_LENGTH) {
      // 保留扩展名,截断主体
      const extLen: number = ARCHIVE_FILE_EXTENSION.length;
      const truncated: string = name.substring(0, MAX_FILENAME_LENGTH - extLen);
      return truncated + ARCHIVE_FILE_EXTENSION;
    }
    return name;
  }

  /**
   * 生成角色全部对话的默认导出文件名。
   * 格式:角色名_all_YYYYMMDD_HHmm.arktchat.json
   */
  static generateCharacterFileName(
    characterName: string,
    timestamp: number = nowMillis()
  ): string {
    const safeCharName: string = ChatArchiveService.sanitizeFileSegment(characterName, 'character');
    const date: Date = new Date(timestamp);
    const year: number = date.getFullYear();
    const month: string = (date.getMonth() + 1).toString().padStart(2, '0');
    const day: string = date.getDate().toString().padStart(2, '0');
    const hour: string = date.getHours().toString().padStart(2, '0');
    const minute: string = date.getMinutes().toString().padStart(2, '0');
    const name: string = safeCharName + '_all_' + year + month + day + '_' + hour + minute + ARCHIVE_FILE_EXTENSION;
    if (name.length > MAX_FILENAME_LENGTH) {
      const extLen: number = ARCHIVE_FILE_EXTENSION.length;
      const truncated: string = name.substring(0, MAX_FILENAME_LENGTH - extLen);
      return truncated + ARCHIVE_FILE_EXTENSION;
    }
    return name;
  }

  /**
   * 清理文件名片段:替换非法字符,移除首尾空格/点,空值回退到 fallback。
   */
  private static sanitizeFileSegment(value: string, fallback: string): string {
    if (value.length === 0) {
      return fallback;
    }
    let s: string = value.replace(ILLEGAL_FILENAME_CHARS, '_');
    s = s.trim();
    s = s.replace(/^\.+|\.+$/g, '');
    if (s.length === 0) {
      return fallback;
    }
    if (s.length > 60) {
      s = s.substring(0, 60);
    }
    return s;
  }
}
