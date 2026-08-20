/**
 * ChatArchiveImportService 聊天归档导入服务
 *
 * 职责:
 * - 读取并校验外部 .arktchat.json 文件
 * - 生成导入预览统计(不写数据库)
 * - 计算文件 SHA-256 与对话指纹(用于重复检测)
 * - 按事务将归档数据写入现有数据库
 * - 重新生成本地 ID,恢复消息父子/分支/Swipe 关系
 * - 返回导入结果(成功/失败/跳过)
 *
 * 依赖:
 * - DbHelper(事务)
 * - ChatRepository / MessageRepository / MessageSwipeRepository / ConversationBranchRepository
 * - CharacterRepository(角色匹配)
 * - ChatArchiveValidator(JSON Schema 校验)
 *
 * 不依赖:
 * - ArkUI / 页面
 * - Provider / PromptBuilder
 *
 * 日志规则:
 * - 只记录 archive version、文件大小、对话数、消息数、SHA-256 前 8 位、阶段、错误码
 * - 严禁输出消息正文、system prompt、完整文件路径、完整 SHA-256
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatRepository } from '../repositories/ChatRepository';
import { MessageRepository } from '../repositories/MessageRepository';
import { MessageSwipeRepository } from '../repositories/MessageSwipeRepository';
import { ConversationBranchRepository } from '../repositories/ConversationBranchRepository';
import { CharacterRepository } from '../repositories/CharacterRepository';
import {
  ChatArchiveValidationError,
  validateChatArchiveJson
} from '../parser/ChatArchiveValidator';
import {
  ARCHIVE_FORMAT,
  ARCHIVE_VERSION,
  MAX_ARCHIVE_FILE_SIZE,
  ArchiveMessage,
  ArchiveConversation,
  ArchiveSwipeCandidate,
  ArchiveSwipeGroup,
  ArchiveBranch,
  ArkTavernChatArchive,
  ChatArchivePreviewStats,
  ChatArchiveImportResult,
  ChatArchiveImportConversationResult,
  ChatArchiveDuplicateInfo
} from '../parser/ChatArchiveSchema';
import { Chat, createChat } from '../models/Chat';
import { ChatMessage, ChatMessageStatus, MessageSenderType, MessageVisibility, createChatMessage, mergeChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import {
  MessageSwipeGroup,
  MessageSwipeCandidate,
  createSwipeCandidate
} from '../models/MessageSwipe';
import {
  ConversationBranch
} from '../models/ConversationBranch';
import { Character } from '../models/Character';
import { Logger } from '../utils/Logger';
import { nowMillis } from '../utils/Time';
import { generateUuid } from '../utils/Uuid';

const LOG_TAG: string = 'ChatArchiveImport';

/** 同一标题重复时追加的后缀 */
const DUPLICATE_TITLE_SUFFIX: string = '（导入）';

/** 对话指纹用的消息摘要最大长度 */
const FINGERPRINT_SUMMARY_LEN: number = 200;

/** SHA-256 输出长度截断(前 8 位,用于日志) */
const SHA256_LOG_PREFIX_LEN: number = 8;

/**
 * 导入选项(由 UI 层根据预览和用户选择传入)。
 */
export interface ChatArchiveImportOptions {
  /** 目标角色 ID(用户在预览页选择,空表示不绑定角色) */
  readonly targetCharacterId: string;
  /** 文件 URI(由文件选择器返回) */
  readonly fileUri: string;
  /** 显示用文件名 */
  readonly fileName: string;
  /** 是否强制导入(用户在重复提示中选择"仍然导入"时为 true) */
  readonly forceImport: boolean;
}

/**
 * 预览阶段产物:已校验的归档 + 统计 + SHA-256 + 重复检测结果。
 * UI 层持有此对象,在用户确认后调用 performImport 写入数据库。
 */
export interface ChatArchivePreviewPayload {
  readonly archive: ArkTavernChatArchive;
  readonly stats: ChatArchivePreviewStats;
  readonly duplicates: ChatArchiveDuplicateInfo[];
  /** 完整 SHA-256(Base64),用于日志和重复检测 */
  readonly sha256Full: string;
}

export class ChatArchiveImportService {
  private readonly dbHelper: DbHelper;
  private readonly chatRepository: ChatRepository;
  private readonly messageRepository: MessageRepository;
  private readonly swipeRepository: MessageSwipeRepository;
  private readonly branchRepository: ConversationBranchRepository;
  private readonly characterRepository: CharacterRepository;

  constructor(
    dbHelper: DbHelper,
    chatRepository: ChatRepository,
    messageRepository: MessageRepository,
    swipeRepository: MessageSwipeRepository,
    branchRepository: ConversationBranchRepository,
    characterRepository: CharacterRepository
  ) {
    this.dbHelper = dbHelper;
    this.chatRepository = chatRepository;
    this.messageRepository = messageRepository;
    this.swipeRepository = swipeRepository;
    this.branchRepository = branchRepository;
    this.characterRepository = characterRepository;
  }

  // ===== 阶段 1: 预览 =====

  /**
   * 读取并校验文件,生成预览。不写数据库。
   *
   * @param fileUri 文件 URI
   * @param fileName 显示用文件名
   * @param currentCharacterId 当前角色 ID(用于匹配判断)
   * @throws Error 文件读取失败 / 超大 / JSON 无效 / Schema 不通过
   */
  async buildPreview(
    fileUri: string,
    fileName: string,
    currentCharacterId: string
  ): Promise<ChatArchivePreviewPayload> {
    if (fileUri.length === 0) {
      throw new Error('fileUri 不能为空');
    }
    Logger.info(LOG_TAG, 'buildPreview start file=' + fileName);

    // 1. 读取文件
    const fileBytes: Uint8Array = await this.readFileBytes(fileUri);
    if (fileBytes.length > MAX_ARCHIVE_FILE_SIZE) {
      throw new Error('文件超过最大限制 ' + String(MAX_ARCHIVE_FILE_SIZE) + ' 字节');
    }

    // 2. 计算 SHA-256
    const sha256Full: string = await this.computeSha256(fileBytes);
    const sha256Prefix: string = sha256Full.substring(0, SHA256_LOG_PREFIX_LEN);
    Logger.info(LOG_TAG, 'buildPreview size=' + String(fileBytes.length) + ' sha=' + sha256Prefix);

    // 3. UTF-8 解码 + JSON 解析 + Schema 校验
    const jsonText: string = this.decodeUtf8(fileBytes);
    const validationResult = validateChatArchiveJson(jsonText);
    if (!validationResult.ok || validationResult.archive === null) {
      const firstError: ChatArchiveValidationError = validationResult.errors[0];
      const errMsg: string = firstError !== undefined
        ? firstError.message
        : '归档校验失败';
      Logger.warn(LOG_TAG, 'validate failed code=' + (firstError !== undefined ? firstError.code : 'unknown'));
      throw new Error(errMsg);
    }
    const archive: ArkTavernChatArchive = validationResult.archive;

    // 4. 计算预览统计
    const stats: ChatArchivePreviewStats = this.computePreviewStats(
      archive, fileName, fileBytes.length, currentCharacterId, sha256Full, validationResult.hasUnknownFields
    );

    // 5. 重复检测(基于现有 Chat 列表 + 对话指纹)
    const duplicates: ChatArchiveDuplicateInfo[] = await this.detectDuplicates(archive);

    Logger.info(
      LOG_TAG,
      'buildPreview done convs=' + String(stats.conversationCount)
        + ' msgs=' + String(stats.messageCount)
        + ' dup=' + String(duplicates.length)
    );

    return {
      archive: archive,
      stats: stats,
      duplicates: duplicates,
      sha256Full: sha256Full
    };
  }

  // ===== 阶段 2: 写入数据库 =====

  /**
   * 执行导入:为每个 conversation 创建独立事务。
   * 单个 conversation 失败不影响其他。
   */
  async performImport(
    payload: ChatArchivePreviewPayload,
    options: ChatArchiveImportOptions
  ): Promise<ChatArchiveImportResult> {
    const targetCharacterId: string = options.targetCharacterId;
    const archive: ArkTavernChatArchive = payload.archive;

    Logger.info(
      LOG_TAG,
      'performImport start convs=' + String(archive.conversations.length)
        + ' char=' + (targetCharacterId.length > 0 ? targetCharacterId.substring(0, 8) : 'none')
    );

    const results: ChatArchiveImportConversationResult[] = [];
    const importedIds: string[] = [];
    let successCount: number = 0;
    let failedCount: number = 0;
    let skippedCount: number = 0;
    let totalMessageCount: number = 0;

    for (let i: number = 0; i < archive.conversations.length; i++) {
      const conv: ArchiveConversation = archive.conversations[i];
      try {
        const localChatId: string = await this.importSingleConversation(
          conv, targetCharacterId, i
        );
        results.push({
          success: true,
          sourceTitle: conv.title,
          localConversationId: localChatId,
          messageCount: conv.messages.length,
          errorMessage: ''
        });
        importedIds.push(localChatId);
        successCount++;
        totalMessageCount += conv.messages.length;
        Logger.info(LOG_TAG, 'imported conv[' + String(i) + '] msgs=' + String(conv.messages.length));
      } catch (e) {
        const errMsg: string = (e as Error).message ?? String(e);
        Logger.error(LOG_TAG, 'import conv[' + String(i) + '] failed: ' + errMsg);
        results.push({
          success: false,
          sourceTitle: conv.title,
          localConversationId: '',
          messageCount: 0,
          errorMessage: errMsg
        });
        failedCount++;
      }
    }

    return {
      successCount: successCount,
      failedCount: failedCount,
      skippedCount: skippedCount,
      totalMessageCount: totalMessageCount,
      conversationResults: results,
      importedConversationIds: importedIds
    };
  }

  // ===== 内部:文件读取与解码 =====

  private async readFileBytes(fileUri: string): Promise<Uint8Array> {
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(fileUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(file.fd);
      const size: number = stat.size;
      if (size <= 0) {
        throw new Error('文件为空');
      }
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(file.fd, buf, { offset: 0, length: size });
      return new Uint8Array(buf);
    } catch (e) {
      throw new Error('读取文件失败: ' + String(e));
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          // ignore
        }
      }
    }
  }

  private decodeUtf8(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeWithStream(bytes);
  }

  private async computeSha256(bytes: Uint8Array): Promise<string> {
    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      await md.update({ data: bytes });
      const result: cryptoFramework.DataBlob = await md.digest();
      const helper: util.Base64Helper = new util.Base64Helper();
      return helper.encodeToStringSync(result.data, util.Type.BASIC);
    } catch (e) {
      Logger.warn(LOG_TAG, 'computeSha256 failed: ' + String(e));
      return '';
    }
  }

  // ===== 内部:预览统计 =====

  private computePreviewStats(
    archive: ArkTavernChatArchive,
    fileName: string,
    fileSize: number,
    currentCharacterId: string,
    sha256Full: string,
    hasUnknownFields: boolean
  ): ChatArchivePreviewStats {
    let messageCount: number = 0;
    let branchCount: number = 0;
    let candidateCount: number = 0;
    let hasSystemMessage: boolean = false;
    let hasBranches: boolean = false;
    let earliestAt: number = 0;
    let latestAt: number = 0;

    for (let i: number = 0; i < archive.conversations.length; i++) {
      const conv: ArchiveConversation = archive.conversations[i];
      messageCount += conv.messages.length;
      branchCount += conv.branches.length;
      for (let j: number = 0; j < conv.swipeGroups.length; j++) {
        candidateCount += conv.swipeGroups[j].candidates.length;
      }
      // 非 Root 分支计数
      for (let k: number = 0; k < conv.branches.length; k++) {
        if (!conv.branches[k].isRoot) {
          hasBranches = true;
        }
      }
      // 消息时间范围 / system 标记
      for (let m: number = 0; m < conv.messages.length; m++) {
        const msg: ArchiveMessage = conv.messages[m];
        if (msg.role === 'system') {
          hasSystemMessage = true;
        }
        const createdAt: number = msg.createdAt;
        if (earliestAt === 0 || (createdAt > 0 && createdAt < earliestAt)) {
          earliestAt = createdAt;
        }
        if (createdAt > latestAt) {
          latestAt = createdAt;
        }
      }
    }

    // 角色匹配判断
    const matchesCurrentCharacter: boolean =
      currentCharacterId.length > 0 &&
      archive.character.sourceCharacterId === currentCharacterId;

    return {
      fileName: fileName,
      fileSize: fileSize,
      version: archive.version,
      exportedAt: archive.exportedAt,
      sourceCharacterName: archive.character.name,
      sourceCharacterId: archive.character.sourceCharacterId,
      conversationCount: archive.conversations.length,
      messageCount: messageCount,
      branchCount: branchCount,
      candidateCount: candidateCount,
      earliestMessageAt: earliestAt,
      latestMessageAt: latestAt,
      hasSystemMessage: hasSystemMessage,
      hasBranches: hasBranches,
      hasUnknownFields: hasUnknownFields,
      matchesCurrentCharacter: matchesCurrentCharacter,
      sha256Prefix: sha256Full.substring(0, SHA256_LOG_PREFIX_LEN),
      sha256Full: sha256Full
    };
  }

  // ===== 内部:重复检测 =====

  /**
   * 基于对话指纹检测现有数据库中是否可能存在相同对话。
   * 指纹 = title + 消息数量 + 首条消息时间 + 末条消息时间 + 首条消息内容摘要
   */
  private async detectDuplicates(
    archive: ArkTavernChatArchive
  ): Promise<ChatArchiveDuplicateInfo[]> {
    const result: ChatArchiveDuplicateInfo[] = [];
    if (archive.conversations.length === 0) {
      return result;
    }
    // 一次性查询所有未归档会话
    let existingChats: Chat[] = [];
    try {
      existingChats = await this.chatRepository.list({ includeArchived: true, limit: 200, offset: 0 });
    } catch (e) {
      Logger.warn(LOG_TAG, 'detectDuplicates: list chats failed: ' + String(e));
      return result;
    }

    // 为现有 Chat 计算"标题 + 消息数"粗指纹,只有粗指纹匹配时才进一步检查
    const archiveFingerprints: string[] = archive.conversations.map(
      (conv: ArchiveConversation): string => this.computeConversationFingerprint(conv)
    );

    for (let i: number = 0; i < archive.conversations.length; i++) {
      const conv: ArchiveConversation = archive.conversations[i];
      const fp: string = archiveFingerprints[i];
      let possiblyDuplicate: boolean = false;
      // 检查是否已有同名会话(简化检测)
      for (let j: number = 0; j < existingChats.length; j++) {
        if (existingChats[j].title === conv.title) {
          possiblyDuplicate = true;
          break;
        }
      }
      if (!possiblyDuplicate) {
        // 进一步通过指纹检查(查询数据库需要按 chatId 加载消息,开销较大,这里仅当标题相同才认为可能重复)
      }
      result.push({
        possiblyDuplicate: possiblyDuplicate,
        sourceTitle: conv.title,
        fingerprintPrefix: fp.substring(0, SHA256_LOG_PREFIX_LEN)
      });
    }
    return result;
  }

  /**
   * 计算对话指纹字符串(用于日志和重复检测)。
   * 指纹 = title|msgCount|firstAt|lastAt|firstContentSummary
   */
  private computeConversationFingerprint(conv: ArchiveConversation): string {
    const msgCount: number = conv.messages.length;
    let firstAt: number = 0;
    let lastAt: number = 0;
    let firstSummary: string = '';
    if (msgCount > 0) {
      firstAt = conv.messages[0].createdAt;
      lastAt = conv.messages[msgCount - 1].createdAt;
      firstSummary = conv.messages[0].content.substring(0, FINGERPRINT_SUMMARY_LEN);
    }
    return conv.title + '|' + String(msgCount) + '|' + String(firstAt) + '|' + String(lastAt) + '|' + firstSummary;
  }

  // ===== 内部:单对话导入(独立事务) =====

  /**
   * 在独立事务中导入一个对话。
   * 失败时回滚,不影响其他对话。
   */
  private async importSingleConversation(
    archiveConv: ArchiveConversation,
    targetCharacterId: string,
    convIndex: number
  ): Promise<string> {
    // 1. 生成本地 Chat ID 与冲突标题
    const localChatId: string = generateUuid();
    const localTitle: string = await this.resolveUniqueTitle(archiveConv.title, convIndex);

    // 2. 创建 Chat
    const chat: Chat = createChat({
      id: localChatId,
      characterId: targetCharacterId.length > 0 ? targetCharacterId : undefined,
      title: localTitle,
      createdAt: archiveConv.createdAt,
      userNameOverride: archiveConv.userNameOverride,
      sortOrder: archiveConv.sortOrder
    });

    // 3. 在事务内插入 Chat + 消息 + 分支 + Swipe
    try {
      await this.dbHelper.runInTransaction(
        async (store: relationalStore.RdbStore): Promise<void> => {
          // 插入 Chat
          await this.chatRepository.insertWithStore(store, chat);

          // sourceMessageId → localMessageId 映射
          const messageIdMap: Map<string, string> = new Map<string, string>();
          // 按 order 升序排序(导入时归档已保证 order 升序,这里再排一次防止意外)
          const sortedMessages: ArchiveMessage[] = archiveConv.messages.slice().sort(
            (a: ArchiveMessage, b: ArchiveMessage): number => {
              if (a.order !== b.order) {
                return a.order - b.order;
              }
              if (a.createdAt !== b.createdAt) {
                return a.createdAt - b.createdAt;
              }
              return 0;
            }
          );

          // 插入消息(sequenceNumber 从 1 开始连续)
          for (let i: number = 0; i < sortedMessages.length; i++) {
            const archMsg: ArchiveMessage = sortedMessages[i];
            const localMsgId: string = generateUuid();
            messageIdMap.set(archMsg.sourceMessageId, localMsgId);
            const localMsg: ChatMessage = this.archiveMessageToLocal(archMsg, localMsgId);
            const sequenceNumber: number = i + 1;
            await this.messageRepository.insertWithStore(store, localMsg, localChatId, sequenceNumber);
          }

          // 插入 Branches(先 Root,再 Child;Child 的 parentBranchId / forkMessageId 需重映射)
          // sourceBranchId → localBranchId 映射
          const branchIdMap: Map<string, string> = new Map<string, string>();
          // 先处理 Root Branch
          const rootBranches: ArchiveBranch[] = archiveConv.branches.filter(
            (b: ArchiveBranch): boolean => b.isRoot
          );
          const childBranches: ArchiveBranch[] = archiveConv.branches.filter(
            (b: ArchiveBranch): boolean => !b.isRoot
          );

          // 必须有且仅有一个 Root Branch;若归档中没有,创建一个空 Root
          // 注意: createRootBranchWithStore 内部会调用 createRootBranch(chatId) 生成新 ID 并插入,
          // 必须使用其返回值作为 localRootBranchId,不能使用外部 createRootBranch 生成的 id
          // (外部 createRootBranch 的对象未被插入,其 id 在数据库中不存在)
          let localRootBranchId: string = '';
          if (rootBranches.length === 0) {
            const created: ConversationBranch =
              await this.branchRepository.createRootBranchWithStore(store, localChatId);
            localRootBranchId = created.id;
            // 修正时间戳为归档的创建时间(createRootBranchWithStore 默认用 nowMillis)
            await this.branchRepository.touchBranchWithStore(
              store, created.id, archiveConv.createdAt
            );
          } else {
            // 使用第一个 Root Branch 的数据,但生成新 ID
            const archRoot: ArchiveBranch = rootBranches[0];
            const created: ConversationBranch =
              await this.branchRepository.createRootBranchWithStore(store, localChatId);
            localRootBranchId = created.id;
            branchIdMap.set(archRoot.sourceBranchId, created.id);
            // 更新时间戳为归档的 lastMessageAt
            await this.branchRepository.touchBranchWithStore(
              store, created.id, archRoot.lastMessageAt > 0 ? archRoot.lastMessageAt : archiveConv.lastMessageAt
            );
          }
          // 设置 Active Branch 为 Root
          await this.branchRepository.setActiveBranchWithStore(store, localChatId, localRootBranchId);
          // 注:不在事务内验证 active branch,RDB 事务快照隔离会导致读不到刚写入的 state。
          // 正确性由事务提交后 loadSession 时 getActiveBranch 隐式验证。

          // 处理 Child Branches(按创建时间升序,确保 parent 已存在)
          const sortedChildBranches: ArchiveBranch[] = childBranches.slice().sort(
            (a: ArchiveBranch, b: ArchiveBranch): number => a.createdAt - b.createdAt
          );
          for (let i: number = 0; i < sortedChildBranches.length; i++) {
            const archBranch: ArchiveBranch = sortedChildBranches[i];
            const localParentId: string | undefined = branchIdMap.get(archBranch.parentSourceBranchId);
            const localForkMsgId: string | undefined = messageIdMap.get(archBranch.forkSourceMessageId);
            if (localParentId === undefined || localForkMsgId === undefined) {
              // 缺少父分支或 fork 消息,跳过该 Child Branch
              Logger.warn(LOG_TAG, 'skip child branch: parent or fork not found');
              continue;
            }
            const localChildBranch: ConversationBranch = await this.branchRepository.createChildBranchWithStore(
              store, localChatId, localParentId, localForkMsgId, archBranch.name
            );
            branchIdMap.set(archBranch.sourceBranchId, localChildBranch.id);
            // touch 时间戳
            await this.branchRepository.touchBranchWithStore(
              store, localChildBranch.id, archBranch.lastMessageAt > 0 ? archBranch.lastMessageAt : nowMillis()
            );
          }

          // 插入 BranchMessageLinks(每个 Branch 的 messageLinks,position 升序)
          for (let i: number = 0; i < archiveConv.branches.length; i++) {
            const archBranch: ArchiveBranch = archiveConv.branches[i];
            const localBranchId: string | undefined = branchIdMap.get(archBranch.sourceBranchId);
            if (localBranchId === undefined) {
              continue;
            }
            // 按 position 升序排序
            const sortedLinks = archBranch.messageLinks.slice().sort(
              (a, b): number => a.position - b.position
            );
            for (let j: number = 0; j < sortedLinks.length; j++) {
              const link = sortedLinks[j];
              const localMsgId: string | undefined = messageIdMap.get(link.sourceMessageId);
              if (localMsgId === undefined) {
                continue;
              }
              await this.branchRepository.insertMessageLinkWithStore(
                store, localBranchId, localMsgId, link.position
              );
            }
          }

          // 插入 Swipe Groups 与 Candidates
          for (let i: number = 0; i < archiveConv.swipeGroups.length; i++) {
            const archGroup: ArchiveSwipeGroup = archiveConv.swipeGroups[i];
            const localAssistantMsgId: string | undefined = messageIdMap.get(archGroup.sourceAssistantMessageId);
            if (localAssistantMsgId === undefined) {
              continue;
            }
            // 创建 Group
            const localGroup: MessageSwipeGroup = {
              assistantMessageId: localAssistantMsgId,
              chatId: localChatId,
              activeCandidateIndex: archGroup.activeCandidateIndex,
              createdAt: archGroup.createdAt,
              updatedAt: archGroup.updatedAt
            };
            await this.swipeRepository.insertGroupWithStore(store, localGroup);
            // 创建 Candidates(按 candidateIndex 升序)
            const sortedCandidates = archGroup.candidates.slice().sort(
              (a: ArchiveSwipeCandidate, b: ArchiveSwipeCandidate): number => a.candidateIndex - b.candidateIndex
            );
            for (let j: number = 0; j < sortedCandidates.length; j++) {
              const archCand: ArchiveSwipeCandidate = sortedCandidates[j];
              const localCandId: string = generateUuid();
              const localCand: MessageSwipeCandidate = createSwipeCandidate(
                localAssistantMsgId,
                archCand.candidateIndex,
                {
                  id: localCandId,
                  content: archCand.content,
                  status: this.archiveStatusToLocal(archCand.status),
                  errorMessage: archCand.errorMessage.length > 0 ? archCand.errorMessage : undefined,
                  isStreaming: false, // 导入时强制 false,流式状态不导出
                  createdAt: archCand.createdAt
                }
              );
              await this.swipeRepository.insertCandidateWithStore(store, localCand);
            }
          }

          // 插入 BranchSwipeSelections(每个 Branch 的 swipeSelections)
          for (let i: number = 0; i < archiveConv.branches.length; i++) {
            const archBranch: ArchiveBranch = archiveConv.branches[i];
            const localBranchId: string | undefined = branchIdMap.get(archBranch.sourceBranchId);
            if (localBranchId === undefined) {
              continue;
            }
            for (let j: number = 0; j < archBranch.swipeSelections.length; j++) {
              const sel = archBranch.swipeSelections[j];
              const localMsgId: string | undefined = messageIdMap.get(sel.sourceAssistantMessageId);
              if (localMsgId === undefined) {
                continue;
              }
              await this.branchRepository.upsertSwipeSelectionWithStore(
                store, localBranchId, localMsgId, sel.candidateIndex
              );
            }
          }

          // 更新 Chat 的 lastMessageAt 和 updatedAt
          const lastMessageAt: number = archiveConv.lastMessageAt > 0
            ? archiveConv.lastMessageAt
            : archiveConv.updatedAt;
          await this.chatRepository.updateLastMessageAtWithStore(
            store, localChatId, lastMessageAt, nowMillis()
          );
        },
        'chat_archive_import'
      );
      return localChatId;
    } catch (e) {
      const errMsg: string = (e as Error).message ?? String(e);
      throw new Error('导入对话失败: ' + errMsg);
    }
  }

  /**
   * 解析归档消息为本地 ChatMessage(重新生成本地 ID)。
   * 关键字段映射:role / content / status / source / senderType / visibility / 时间 / 数组字段。
   */
  private archiveMessageToLocal(archMsg: ArchiveMessage, localMsgId: string): ChatMessage {
    const role: ChatRole = this.archiveRoleToLocal(archMsg.role);
    const status: ChatMessageStatus = this.archiveStatusToLocal(archMsg.status);
    const source: ChatMessageSource = this.archiveSourceToLocal(archMsg.source);
    const senderType: MessageSenderType = this.archiveSenderTypeToLocal(archMsg.senderType);
    const visibility: MessageVisibility = this.archiveVisibilityToLocal(archMsg.visibility);

    let base: ChatMessage = createChatMessage(localMsgId, role, archMsg.content, archMsg.createdAt);
    base = mergeChatMessage(base, {
      updatedAt: archMsg.updatedAt > 0 ? archMsg.updatedAt : undefined,
      status: status,
      errorMessage: archMsg.errorMessage.length > 0 ? archMsg.errorMessage : undefined,
      source: source,
      senderType: senderType,
      senderCharacterId: archMsg.senderCharacterId.length > 0 ? archMsg.senderCharacterId : undefined,
      sceneId: archMsg.sceneId.length > 0 ? archMsg.sceneId : undefined,
      generationBatchId: archMsg.generationBatchId.length > 0 ? archMsg.generationBatchId : undefined,
      visibility: visibility,
      recipientCharacterIds: archMsg.recipientCharacterIds.length > 0 ? archMsg.recipientCharacterIds.slice() : undefined,
      participantIds: archMsg.participantIds.length > 0 ? archMsg.participantIds.slice() : undefined,
      witnessIds: archMsg.witnessIds.length > 0 ? archMsg.witnessIds.slice() : undefined,
      isStreaming: false
    });
    return base;
  }

  private archiveRoleToLocal(role: string): ChatRole {
    if (role === 'system') return ChatRole.System;
    if (role === 'user') return ChatRole.User;
    return ChatRole.Assistant;
  }

  private archiveStatusToLocal(status: string): ChatMessageStatus {
    if (status === 'streaming') return ChatMessageStatus.Streaming;
    if (status === 'cancelled') return ChatMessageStatus.Cancelled;
    if (status === 'failed') return ChatMessageStatus.Failed;
    return ChatMessageStatus.Completed;
  }

  private archiveSourceToLocal(source: string): ChatMessageSource {
    if (source === 'characterFirstMessage') return ChatMessageSource.CharacterFirstMessage;
    if (source === 'externalSystem') return ChatMessageSource.ExternalSystem;
    return ChatMessageSource.Conversation;
  }

  private archiveSenderTypeToLocal(senderType: string): MessageSenderType {
    if (senderType === 'character') return 'character';
    if (senderType === 'narrator') return 'narrator';
    return 'user';
  }

  private archiveVisibilityToLocal(visibility: string): MessageVisibility {
    if (visibility === 'private') return 'private';
    if (visibility === 'narrator') return 'narrator';
    return 'public';
  }

  /**
   * 解决标题冲突:若已存在同名 Chat,追加"（导入）"/"（导入 2）"等后缀。
   * 不覆盖现有对话。
   */
  private async resolveUniqueTitle(originalTitle: string, convIndex: number): Promise<string> {
    const trimmedTitle: string = originalTitle.trim().length > 0
      ? originalTitle.trim()
      : '导入的对话';
    try {
      const existing: Chat[] = await this.chatRepository.list({
        includeArchived: true, limit: 200, offset: 0
      });
      const existingTitles: Set<string> = new Set<string>();
      for (let i: number = 0; i < existing.length; i++) {
        existingTitles.add(existing[i].title);
      }
      if (!existingTitles.has(trimmedTitle)) {
        return trimmedTitle;
      }
      // 追加后缀
      let attempt: number = 1;
      while (true) {
        const suffix: string = attempt === 1
          ? DUPLICATE_TITLE_SUFFIX
          : DUPLICATE_TITLE_SUFFIX + ' ' + String(attempt);
        const candidate: string = trimmedTitle + suffix;
        if (!existingTitles.has(candidate)) {
          return candidate;
        }
        attempt++;
        if (attempt > 100) {
          // 防止死循环
          return trimmedTitle + '_' + String(nowMillis());
        }
      }
    } catch (e) {
      // 查询失败时,直接返回原标题(数据库会在插入时检查约束)
      return trimmedTitle;
    }
  }

  // ===== 角色匹配 =====

  /**
   * 角色匹配优先级:
   * 1. sourceCharacterId 精确匹配
   * 2. 名称匹配(返回所有同名角色)
   * 3. 找不到返回空数组(由 UI 让用户手动选择)
   */
  async findMatchingCharacters(
    sourceCharacterId: string,
    sourceCharacterName: string
  ): Promise<Character[]> {
    const all: Character[] = await this.characterRepository.list();
    const result: Character[] = [];
    // 优先级 1:精确 ID
    if (sourceCharacterId.length > 0) {
      for (let i: number = 0; i < all.length; i++) {
        if (all[i].id === sourceCharacterId) {
          result.push(all[i]);
          return result;
        }
      }
    }
    // 优先级 2:名称匹配(允许重名,返回所有同名)
    if (sourceCharacterName.length > 0) {
      for (let i: number = 0; i < all.length; i++) {
        if (all[i].name === sourceCharacterName) {
          result.push(all[i]);
        }
      }
    }
    return result;
  }

  /**
   * 列出全部角色(用于手动选择)。
   */
  async listAllCharacters(): Promise<Character[]> {
    return await this.characterRepository.list();
  }
}
