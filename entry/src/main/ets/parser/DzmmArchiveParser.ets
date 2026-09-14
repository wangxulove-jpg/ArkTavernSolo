/**
 * DzmmArchiveParser DZMM 导出聊天记录转换器
 *
 * 职责:
 * - 识别 DZMM 导出的 JSON 聊天记录格式
 * - 将 DZMM 结构转换为 ArkTavern 标准的 ArkTavernChatArchive(v1)
 * - 让上层 ChatArchiveImportService 能复用同一套预览 / 去重 / 落库逻辑
 *
 * 设计原则(解耦 / 可扩展):
 * - 本文件是 DZMM 与 ArkTavern 之间唯一转换点,不依赖 UI / 数据库 / 网络
 * - 所有字段读取走类型安全的辅助函数,不使用 any,不直接信任 JSON.parse 结果
 * - 角色信息 DZMM 无实体,转换时置空 sourceCharacterId/name,由上层预览弹窗让用户手动绑定
 * - 分支映射采用"平铺策略":整个文件 = 1 个对话 + 1 个 Root 分支,消息按时间升序
 * - 后续如需还原 chunk.children 分支,只需在此文件内扩展,不影响其他模块
 *
 * 日志规则:
 * - 不在转换器内输出日志;仅抛出带描述的错误供上层转译为用户提示
 */

import {
  ARCHIVE_FORMAT,
  ARCHIVE_VERSION,
  ArchiveScope,
  ArchiveMessage,
  ArchiveMessageRole,
  ArchiveMessageSource,
  ArchiveMessageSenderType,
  ArchiveBranch,
  ArchiveBranchMessageLink,
  ArchiveConversation,
  ArkTavernChatArchive,
  ArchiveCharacterInfo
} from './ChatArchiveSchema';

// ===== DZMM 原始结构描述(仅用于读取,不做强类型反序列化) =====

/** DZMM 导出文件顶层结构 */
export interface DzmmChatArchive {
  /** 来源对话 ID */
  readonly chatId: string;
  /** 对话元信息 */
  readonly chat: DzmmChat;
  /** 按 chunk 分组的消息 */
  readonly messages: DzmmChunk[];
  /** 导出时间(ISO 字符串) */
  readonly exportedAt: string;
}

/** DZMM 对话元信息 */
export interface DzmmChat {
  /** 对话标题(可能为空) */
  readonly title: string;
  /** 来源角色卡 ID(仅用于追踪,不作本地主键) */
  readonly cardId: string;
  /** 创建时间(ISO 字符串) */
  readonly createdAt: string;
  /** chunk 定义(含 children 分支关系,首版暂不还原) */
  readonly chunks: DzmmChunkDef[];
}

/** DZMM chunk 定义 */
export interface DzmmChunkDef {
  readonly id: string;
  /** 子 chunk id(分支关系,暂不使用) */
  readonly children: string[];
}

/** DZMM 单个 chunk 内的消息分组 */
export interface DzmmChunk {
  readonly chunkId: string;
  readonly messages: DzmmMessage[];
}

/** DZMM 单条消息 */
export interface DzmmMessage {
  readonly role: string;
  readonly content: string;
  /** 创建时间(毫秒) */
  readonly createAt: number;
  /** 是否为系统内部消息 */
  readonly isInternalMessage: boolean;
  /** AI 生成批次 ID(assistant 消息可能有) */
  readonly generationId: string;
}

/** 转换结果:带内部排序号的中间结构 */
interface SortedEntry {
  readonly seq: number;
  readonly createAt: number;
  readonly sourceMessageId: string;
  readonly role: string;
  readonly content: string;
  readonly isInternalMessage: boolean;
  /** AI 生成批次 ID(assistant 消息可有,user 消息为空) */
  readonly generationId: string;
}

/** 解析错误说明常量 */
const ERR_NOT_DZMM_TOP = '不是有效的 DZMM 聊天导出文件:缺少顶层 chat / messages';
const ERR_BAD_CHAT = 'DZMM 文件 chat 字段无效';
const ERR_BAD_MESSAGES = 'DZMM 文件 messages 字段无效';

/**
 * DZMM 导入使用的固定对话级 sourceBranchId 前缀(区分于 ArkTavern 原生归档)。
 */
const DZMM_ROOT_BRANCH_PREFIX: string = 'dzmm-root-';

/**
 * 检测给定 JSON 文本是否为 DZMM 导出格式。
 * 判定规则:DZMM 无 format 字段,且有 chat 对象 + messages 数组结构特征;
 * 与 ArkTavern(format=ArkTavernChatArchive)互相排斥。
 */
export function isDzmmChatArchive(jsonText: string, parsedRoot: Record<string, Object> | null): boolean {
  // 已经解析过则用传入的 root,避免重复解析
  const root: Record<string, Object> | null = parsedRoot !== null ? parsedRoot : tryParseObject(jsonText);
  if (root === null) {
    return false;
  }
  // ArkTavern 归档有 format 标记,排除
  const format: string = getStr(root, 'format', '');
  if (format === ARCHIVE_FORMAT) {
    return false;
  }
  // DZMM 特征:chat 对象 + messages 数组
  const chatRaw: Object | undefined = root['chat'];
  const messagesRaw: Object | undefined = root['messages'];
  if (typeof chatRaw !== 'object' || chatRaw === null || Array.isArray(chatRaw)) {
    return false;
  }
  if (!Array.isArray(messagesRaw)) {
    return false;
  }
  return true;
}

/**
 * 将 DZMM 聊天记录转换为 ArkTavernChatArchive(v1)。
 *
 * @param jsonText UTF-8 编码的 DZMM JSON 文本
 * @returns 标准 ArkTavernChatArchive(1 个对话,平铺消息,无角色绑定)
 * @throws Error 顶层结构不合法 / 字段类型错误时抛出
 */
export function parseDzmmChatArchive(jsonText: string): ArkTavernChatArchive {
  const root: Record<string, Object> | null = tryParseObject(jsonText);
  if (root === null) {
    throw new Error('JSON 解析失败,文件不是有效的 DZMM 聊天导出');
  }
  if (!isDzmmChatArchive('', root)) {
    throw new Error(ERR_NOT_DZMM_TOP);
  }

  // ---- chat ----
  const chatRaw: Object | undefined = root['chat'];
  if (typeof chatRaw !== 'object' || chatRaw === null || Array.isArray(chatRaw)) {
    throw new Error(ERR_BAD_CHAT);
  }
  const chat: Record<string, Object> = chatRaw as Record<string, Object>;
  const chatId: string = getStr(root, 'chatId', '');
  const title: string = getStr(chat, 'title', '');
  const cardId: string = getStr(chat, 'card_id', '');
  const createdAtIso: string = getStr(chat, 'created_at', '');
  const chatCreatedAt: number = parseIsoMillis(createdAtIso);

  // ---- messages: 平铺所有 chunk,按时间排序 ----
  const messagesRaw: Object | undefined = root['messages'];
  if (!Array.isArray(messagesRaw)) {
    throw new Error(ERR_BAD_MESSAGES);
  }
  const entries: SortedEntry[] = [];
  let seq: number = 0;
  const chunkArr: Object[] = messagesRaw as Object[];
  for (let ci: number = 0; ci < chunkArr.length; ci++) {
    const chunkEl: Object = chunkArr[ci];
    if (typeof chunkEl !== 'object' || chunkEl === null || Array.isArray(chunkEl)) {
      continue;
    }
    const chunk: Record<string, Object> = chunkEl as Record<string, Object>;
    const innerRaw: Object | undefined = chunk['messages'];
    if (!Array.isArray(innerRaw)) {
      continue;
    }
    const innerArr: Object[] = innerRaw as Object[];
    for (let mi: number = 0; mi < innerArr.length; mi++) {
      const mEl: Object = innerArr[mi];
      if (typeof mEl !== 'object' || mEl === null || Array.isArray(mEl)) {
        continue;
      }
      const m: Record<string, Object> = mEl as Record<string, Object>;
      const role: string = getStr(m, 'role', 'user');
      // 忽略完全无内容的占位消息
      const content: string = getStr(m, 'content', '');
      const createAt: number = getInt(m, 'createAt', 0);
      const isInternal: boolean = getBool(m, 'isInternalMessage', false);
      const generationId: string = getStr(m, 'generationId', '');
      seq++;
      entries.push({
        seq: seq,
        createAt: createAt,
        sourceMessageId: 'dzmm-' + String(seq),
        role: role,
        content: content,
        isInternalMessage: isInternal,
        generationId: generationId
      });
    }
  }

  // 稳定排序:时间升序,同时间按原本 seq 保持展示顺序。
  // ArkTS sort 不保证稳定,用 (createAt, seq) 组合保证确定性。
  entries.sort((a: SortedEntry, b: SortedEntry): number => {
    if (a.createAt !== b.createAt) {
      return a.createAt - b.createAt;
    }
    return a.seq - b.seq;
  });

  // 推导 conversation 时间:取最早/最晚消息时间,失败回退文件级时间
  let firstAt: number = 0;
  let lastAt: number = 0;
  for (let i: number = 0; i < entries.length; i++) {
    const t: number = entries[i].createAt;
    if (firstAt === 0 && t > 0) {
      firstAt = t;
    }
    if (t > lastAt) {
      lastAt = t;
    }
  }
  const convCreatedAt: number = chatCreatedAt > 0 ? chatCreatedAt : (firstAt > 0 ? firstAt : 0);
  const convLastMessageAt: number = lastAt > 0 ? lastAt : nowMillisSafe();

  // 构造 ArchiveMessage 数组
  const messages: ArchiveMessage[] = [];
  for (let i: number = 0; i < entries.length; i++) {
    const e: SortedEntry = entries[i];
    messages.push(toArchiveMessage(e, i + 1));
  }

  // 构造 Root 分支(平铺全部消息)
  const rootLinks: ArchiveBranchMessageLink[] = [];
  for (let i: number = 0; i < messages.length; i++) {
    rootLinks.push({ sourceMessageId: messages[i].sourceMessageId, position: i });
  }
  const rootBranchId: string = DZMM_ROOT_BRANCH_PREFIX + (chatId.length > 0 ? chatId : String(convCreatedAt));
  const rootBranch: ArchiveBranch = {
    sourceBranchId: rootBranchId,
    parentSourceBranchId: '',
    forkSourceMessageId: '',
    name: '',
    isRoot: true,
    createdAt: convCreatedAt,
    updatedAt: convLastMessageAt,
    lastMessageAt: convLastMessageAt,
    messageLinks: rootLinks,
    swipeSelections: []
  };

  const conversation: ArchiveConversation = {
    sourceConversationId: chatId,
    title: title,
    createdAt: convCreatedAt,
    updatedAt: convLastMessageAt,
    lastMessageAt: convLastMessageAt,
    userNameOverride: '',
    sortOrder: 0,
    messages: messages,
    branches: [rootBranch],
    swipeGroups: []
  };

  const character: ArchiveCharacterInfo = {
    sourceCharacterId: '',
    name: '',
    avatarName: ''
  };

  const scope: ArchiveScope = 'single';
  return {
    format: ARCHIVE_FORMAT,
    version: ARCHIVE_VERSION,
    scope: scope,
    exportedAt: nowMillisSafe(),
    appVersion: '',
    character: character,
    conversations: [conversation]
  };
}

// ===== 消息转换 =====

/**
 * 将 DZMM 中间条目转换为 ArchiveMessage。
 * 字段映射原则:只保留 DZMM 真实存在的信息,缺失字段填中性默认值。
 */
function toArchiveMessage(e: SortedEntry, order: number): ArchiveMessage {
  const role: ArchiveMessageRole = normalizeRole(e.role, e.isInternalMessage);
  // senderType 映射:
  // - user 消息 → 'user'
  // - system 消息 → 'narrator'(旁白,本地要求 senderCharacterId 为空,契合)
  // - assistant 消息 → 'character'(角色侧响应;DZMM 无角色实体,senderCharacterId 置空,
  //   由导入落库层根据用户绑定的角色填充或降级,见 ChatArchiveImportService.archiveMessageToLocal)
  const senderType: ArchiveMessageSenderType = role === 'user'
    ? 'user'
    : (role === 'system' ? 'narrator' : 'character');
  // isInternalMessage 标记为系统内部来源;否则一律视为普通会话消息
  const source: ArchiveMessageSource = e.isInternalMessage ? 'externalSystem' : 'conversation';
  return {
    sourceMessageId: e.sourceMessageId,
    role: role,
    content: e.content,
    createdAt: e.createAt > 0 ? e.createAt : 0,
    updatedAt: 0,
    order: order,
    status: 'completed',
    errorMessage: '',
    source: source,
    senderType: senderType,
    senderCharacterId: '',
    sceneId: '',
    generationBatchId: e.generationId.length > 0 ? e.generationId : '',
    visibility: 'public',
    recipientCharacterIds: [],
    participantIds: [],
    witnessIds: [],
    includeInMemory: true
  };
}

/**
 * 规范化角色。
 * DZMM 常规为 user / assistant;system 出现时保留;其他内部异常值归为 user。
 */
function normalizeRole(raw: string, isInternal: boolean): ArchiveMessageRole {
  // 内部标记且无明确 role 时,按 system(系统内部消息)处理
  if (isInternal && raw !== 'assistant' && raw !== 'user') {
    return 'system';
  }
  // DZMM 常规为 user / assistant;system 出现时保留;其他内部异常值归为 user
  if (raw === 'assistant') {
    return 'assistant';
  }
  if (raw === 'system') {
    return 'system';
  }
  return 'user';
}

// ===== 类型安全字段读取辅助 =====

/** 尝试将字符串解析为顶层对象;失败返回 null。 */
function tryParseObject(jsonText: string): Record<string, Object> | null {
  try {
    const parsed: Object = JSON.parse(jsonText);
    if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
      return parsed as Record<string, Object>;
    }
    return null;
  } catch (e) {
    return null;
  }
}

function getStr(o: Record<string, Object>, key: string, def: string): string {
  const v: Object | undefined = o[key];
  if (typeof v === 'string') {
    return v as string;
  }
  return def;
}

function getInt(o: Record<string, Object>, key: string, def: number): number {
  const v: Object | undefined = o[key];
  if (typeof v === 'number' && Number.isFinite(v as number)) {
    return v as number;
  }
  return def;
}

function getBool(o: Record<string, Object>, key: string, def: boolean): boolean {
  const v: Object | undefined = o[key];
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  return def;
}

/** ISO 8601 字符串 → 毫秒时间戳;非法返回 0。 */
function parseIsoMillis(iso: string): number {
  if (iso.length === 0) {
    return 0;
  }
  const t: number = Date.parse(iso);
  if (Number.isFinite(t) && !Number.isNaN(t)) {
    return t;
  }
  return 0;
}

/** 当前时间(毫秒),幂等安全。 */
function nowMillisSafe(): number {
  return Date.now();
}