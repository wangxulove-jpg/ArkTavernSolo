/**
 * ChatArchiveValidator ArkTavern 聊天归档校验器
 *
 * 对外部 JSON 文件进行严格的 Schema 校验,输出类型安全的 ArkTavernChatArchive 结构。
 * 用于 ChatArchiveImportService 的导入预览与写入流程。
 *
 * 设计原则:
 * - 不使用 any
 * - 不直接信任 JSON.parse 返回的对象字面量
 * - 所有字段显式类型校验,非法字段返回错误
 * - 未知字段不直接拒绝,记录 hasUnknownFields 标志
 * - 时间字段必须是有限非负整数
 * - role / status / source / senderType / visibility 必须为合法枚举
 * - 禁止原型污染字段(__proto__ / constructor / prototype)
 *
 * 不依赖:
 * - ArkUI
 * - 数据库
 */

import {
  ARCHIVE_FORMAT,
  ARCHIVE_VERSION,
  MAX_ARCHIVE_CONVERSATIONS,
  MAX_ARCHIVE_MESSAGES_PER_CONVERSATION,
  MAX_ARCHIVE_MESSAGE_CONTENT_LENGTH,
  MAX_ARCHIVE_JSON_DEPTH,
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
  ArkTavernChatArchive
} from './ChatArchiveSchema';

/** 校验错误 */
export interface ChatArchiveValidationError {
  /** 错误字段路径(如 "conversations[0].messages[1].role") */
  readonly path: string;
  /** 错误码 */
  readonly code: string;
  /** 错误描述 */
  readonly message: string;
}

/** 校验结果 */
export interface ChatArchiveValidationResult {
  /** 是否通过 */
  readonly ok: boolean;
  /** 解析后的归档对象(ok=false 时为 null) */
  readonly archive: ArkTavernChatArchive | null;
  /** 错误列表(ok=true 时为空数组) */
  readonly errors: ChatArchiveValidationError[];
  /** 是否检测到未知字段 */
  readonly hasUnknownFields: boolean;
}

/** 未知字段标志(用于在解析过程中传递是否检测到未知字段) */
export interface UnknownFlag {
  unknown: boolean;
}

/** 原型污染字段黑名单 */
const PROTOTYPE_POLLUTION_KEYS: string[] = ['__proto__', 'constructor', 'prototype'];

/**
 * 校验并解析归档 JSON 字符串。
 *
 * @param jsonText UTF-8 编码的 JSON 字符串
 * @returns 校验结果
 */
export function validateChatArchiveJson(jsonText: string): ChatArchiveValidationResult {
  // 1. JSON 解析
  let root: Record<string, Object>;
  try {
    const parsed: Object = JSON.parse(jsonText);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return fail([
        { path: 'root', code: 'type_error', message: 'JSON 顶层必须是对象' }
      ]);
    }
    root = parsed as Record<string, Object>;
  } catch (e) {
    return fail([
      { path: 'root', code: 'json_parse_error', message: 'JSON 不完整或格式无效: ' + String(e) }
    ]);
  }

  // 2. 原型污染检查
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(root, 'root');
  if (protoError !== null) {
    return fail([protoError]);
  }

  // 3. JSON 嵌套深度检查
  const depthError: ChatArchiveValidationError | null = checkJsonDepth(jsonText);
  if (depthError !== null) {
    return fail([depthError]);
  }

  let hasUnknown: boolean = false;
  const errors: ChatArchiveValidationError[] = [];

  // 4. format
  const format: string = getStringField(root, 'format', '');
  if (format !== ARCHIVE_FORMAT) {
    errors.push({
      path: 'format',
      code: 'invalid_value',
      message: 'format 必须为 "' + ARCHIVE_FORMAT + '",实际: "' + format + '"'
    });
  }

  // 5. version
  const versionRaw: Object | undefined = root['version'];
  if (versionRaw === undefined || typeof versionRaw !== 'number') {
    errors.push({
      path: 'version',
      code: 'type_error',
      message: 'version 必须为数字'
    });
  } else if (!Number.isFinite(versionRaw) || !Number.isInteger(versionRaw)) {
    errors.push({
      path: 'version',
      code: 'invalid_value',
      message: 'version 必须为有限整数'
    });
  } else if (versionRaw > ARCHIVE_VERSION) {
    // 高于当前支持的版本,直接拒绝
    return fail([{
      path: 'version',
      code: 'unsupported_version',
      message: '该聊天归档版本(' + String(versionRaw) + ')高于当前 App 支持版本(' + String(ARCHIVE_VERSION) + ')'
    }]);
  } else if (versionRaw < ARCHIVE_VERSION) {
    errors.push({
      path: 'version',
      code: 'unsupported_version',
      message: '该聊天归档版本(' + String(versionRaw) + ')低于当前 App 支持版本(' + String(ARCHIVE_VERSION) + ')'
    });
  }

  // 6. scope
  const scope: string = getStringField(root, 'scope', '');
  if (scope !== 'single' && scope !== 'character') {
    errors.push({
      path: 'scope',
      code: 'invalid_value',
      message: 'scope 必须为 "single" 或 "character",实际: "' + scope + '"'
    });
  }
  const validScope: ArchiveScope = scope === 'character' ? 'character' : 'single';

  // 7. exportedAt
  const exportedAt: number = getTimestampField(root, 'exportedAt', 'exportedAt', errors);
  if (exportedAt < 0) {
    errors.push({
      path: 'exportedAt',
      code: 'invalid_value',
      message: 'exportedAt 不能为负数'
    });
  }

  // 8. appVersion
  const appVersion: string = getStringField(root, 'appVersion', '');

  // 9. character
  const characterRaw: Object | undefined = root['character'];
  if (characterRaw === undefined || characterRaw === null) {
    errors.push({
      path: 'character',
      code: 'missing',
      message: '缺少 character 字段'
    });
  } else if (typeof characterRaw !== 'object' || Array.isArray(characterRaw)) {
    errors.push({
      path: 'character',
      code: 'type_error',
      message: 'character 必须为对象'
    });
  } else {
    const charErrors: ChatArchiveValidationError[] = [];
    const charUnknown: boolean = checkUnknownFields(characterRaw as Record<string, Object>, 'character', ['sourceCharacterId', 'name', 'avatarName']);
    if (charUnknown) {
      hasUnknown = true;
    }
    const character: ArchiveCharacterInfo = parseCharacterInfo(characterRaw as Record<string, Object>, charErrors);
    errors.push(...charErrors);
    if (errors.length > 0) {
      // 继续解析 conversations,但最终返回失败
    }
  }

  // 10. conversations
  const conversationsRaw: Object | undefined = root['conversations'];
  if (conversationsRaw === undefined || conversationsRaw === null) {
    errors.push({
      path: 'conversations',
      code: 'missing',
      message: '缺少 conversations 字段'
    });
    return fail(errors);
  }
  if (!Array.isArray(conversationsRaw)) {
    errors.push({
      path: 'conversations',
      code: 'type_error',
      message: 'conversations 必须为数组'
    });
    return fail(errors);
  }
  if (conversationsRaw.length > MAX_ARCHIVE_CONVERSATIONS) {
    errors.push({
      path: 'conversations',
      code: 'too_many',
      message: '对话数超过上限 ' + String(MAX_ARCHIVE_CONVERSATIONS)
    });
    return fail(errors);
  }

  // 解析 conversations
  const conversations: ArchiveConversation[] = [];
  const convArr: Object[] = conversationsRaw as Object[];
  for (let i: number = 0; i < convArr.length; i++) {
    const convErrors: ChatArchiveValidationError[] = [];
    const convUnknown: UnknownFlag = { unknown: false };
    const conv: ArchiveConversation | null = parseConversation(
      convArr[i], i, convErrors, convUnknown
    );
    if (convUnknown.unknown) {
      hasUnknown = true;
    }
    if (conv === null) {
      errors.push(...convErrors);
      continue;
    }
    conversations.push(conv);
    errors.push(...convErrors);
  }

  if (errors.length > 0) {
    return fail(errors);
  }

  // 重新解析 character(因为之前可能因 errors > 0 而提前返回)
  let character: ArchiveCharacterInfo;
  if (typeof root['character'] === 'object' && root['character'] !== null && !Array.isArray(root['character'])) {
    const charErrors: ChatArchiveValidationError[] = [];
    character = parseCharacterInfo(root['character'] as Record<string, Object>, charErrors);
  } else {
    character = { sourceCharacterId: '', name: '', avatarName: '' };
  }

  const archive: ArkTavernChatArchive = {
    format: ARCHIVE_FORMAT,
    version: ARCHIVE_VERSION,
    scope: validScope,
    exportedAt: exportedAt,
    appVersion: appVersion,
    character: character,
    conversations: conversations
  };

  return {
    ok: true,
    archive: archive,
    errors: [],
    hasUnknownFields: hasUnknown
  };
}

// ===== 内部辅助函数 =====

function fail(errors: ChatArchiveValidationError[]): ChatArchiveValidationResult {
  return {
    ok: false,
    archive: null,
    errors: errors,
    hasUnknownFields: false
  };
}

function checkPrototypePollution(obj: Record<string, Object>, path: string): ChatArchiveValidationError | null {
  const keys: string[] = Object.keys(obj);
  for (let i: number = 0; i < keys.length; i++) {
    if (PROTOTYPE_POLLUTION_KEYS.indexOf(keys[i]) >= 0) {
      return {
        path: path + '.' + keys[i],
        code: 'prototype_pollution',
        message: '禁止的原型污染字段: ' + keys[i]
      };
    }
  }
  return null;
}

function checkJsonDepth(jsonText: string): ChatArchiveValidationError | null {
  let depth: number = 0;
  let maxDepth: number = 0;
  let inString: boolean = false;
  let escape: boolean = false;
  for (let i: number = 0; i < jsonText.length; i++) {
    const ch: string = jsonText.charAt(i);
    if (escape) {
      escape = false;
      continue;
    }
    if (ch === '\\') {
      escape = true;
      continue;
    }
    if (inString) {
      if (ch === '"') {
        inString = false;
      }
      continue;
    }
    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === '{' || ch === '[') {
      depth++;
      if (depth > maxDepth) {
        maxDepth = depth;
      }
      if (maxDepth > MAX_ARCHIVE_JSON_DEPTH) {
        return {
          path: 'root',
          code: 'depth_exceeded',
          message: 'JSON 嵌套深度超过上限 ' + String(MAX_ARCHIVE_JSON_DEPTH)
        };
      }
    } else if (ch === '}' || ch === ']') {
      depth--;
    }
  }
  return null;
}

function getStringField(obj: Record<string, Object>, key: string, defaultValue: string): string {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'string') {
    return v as string;
  }
  return defaultValue;
}

function getNumberField(obj: Record<string, Object>, key: string, defaultValue: number): number {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'number') {
    return v as number;
  }
  return defaultValue;
}

function getTimestampField(
  obj: Record<string, Object>,
  key: string,
  path: string,
  errors: ChatArchiveValidationError[]
): number {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    errors.push({
      path: path,
      code: 'missing',
      message: '缺少 ' + key + ' 字段'
    });
    return -1;
  }
  if (typeof v !== 'number') {
    errors.push({
      path: path,
      code: 'type_error',
      message: key + ' 必须为数字'
    });
    return -1;
  }
  const num: number = v as number;
  if (!Number.isFinite(num) || !Number.isInteger(num) || num < 0) {
    errors.push({
      path: path,
      code: 'invalid_value',
      message: key + ' 必须为有限非负整数'
    });
    return -1;
  }
  return num;
}

function getBooleanField(obj: Record<string, Object>, key: string, defaultValue: boolean): boolean {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return defaultValue;
  }
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  return defaultValue;
}

function getStringArrayField(
  obj: Record<string, Object>,
  key: string,
  path: string,
  errors: ChatArchiveValidationError[]
): string[] {
  const v: Object | undefined = obj[key];
  if (v === undefined || v === null) {
    return [];
  }
  if (!Array.isArray(v)) {
    errors.push({
      path: path,
      code: 'type_error',
      message: key + ' 必须为数组'
    });
    return [];
  }
  const arr: Object[] = v as Object[];
  const result: string[] = [];
  for (let i: number = 0; i < arr.length; i++) {
    const item: Object = arr[i];
    if (typeof item === 'string') {
      result.push(item as string);
    } else {
      errors.push({
        path: path + '[' + String(i) + ']',
        code: 'type_error',
        message: key + ' 数组元素必须为字符串'
      });
    }
  }
  return result;
}

function checkUnknownFields(
  obj: Record<string, Object>,
  path: string,
  knownKeys: string[]
): boolean {
  const keys: string[] = Object.keys(obj);
  for (let i: number = 0; i < keys.length; i++) {
    if (knownKeys.indexOf(keys[i]) < 0) {
      return true;
    }
  }
  return false;
}

function parseCharacterInfo(
  obj: Record<string, Object>,
  errors: ChatArchiveValidationError[]
): ArchiveCharacterInfo {
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(obj, 'character');
  if (protoError !== null) {
    errors.push(protoError);
  }
  return {
    sourceCharacterId: getStringField(obj, 'sourceCharacterId', ''),
    name: getStringField(obj, 'name', ''),
    avatarName: getStringField(obj, 'avatarName', '')
  };
}

function parseMessageRole(value: string): ArchiveMessageRole | null {
  if (value === 'user') return 'user';
  if (value === 'assistant') return 'assistant';
  if (value === 'system') return 'system';
  return null;
}

function parseMessageStatus(value: string): ArchiveMessageStatus | null {
  if (value === 'streaming') return 'streaming';
  if (value === 'completed') return 'completed';
  if (value === 'cancelled') return 'cancelled';
  if (value === 'failed') return 'failed';
  return null;
}

function parseMessageSource(value: string): ArchiveMessageSource | null {
  if (value === 'conversation') return 'conversation';
  if (value === 'characterFirstMessage') return 'characterFirstMessage';
  if (value === 'externalSystem') return 'externalSystem';
  return null;
}

function parseMessageSenderType(value: string): ArchiveMessageSenderType | null {
  if (value === 'user') return 'user';
  if (value === 'character') return 'character';
  if (value === 'narrator') return 'narrator';
  return null;
}

function parseMessageVisibility(value: string): ArchiveMessageVisibility | null {
  if (value === 'public') return 'public';
  if (value === 'private') return 'private';
  if (value === 'narrator') return 'narrator';
  return null;
}

function parseSwipeCandidate(
  obj: Record<string, Object>,
  path: string,
  errors: ChatArchiveValidationError[],
  unknownFlag: UnknownFlag
): ArchiveSwipeCandidate | null {
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(obj, path);
  if (protoError !== null) {
    errors.push(protoError);
    return null;
  }
  if (checkUnknownFields(obj, path, ['sourceCandidateId', 'candidateIndex', 'content', 'status', 'errorMessage', 'isStreaming', 'createdAt', 'updatedAt'])) {
    unknownFlag.unknown = true;
  }
  const sourceCandidateId: string = getStringField(obj, 'sourceCandidateId', '');
  const candidateIndex: number = getNumberField(obj, 'candidateIndex', -1);
  if (!Number.isInteger(candidateIndex) || candidateIndex < 0) {
    errors.push({
      path: path + '.candidateIndex',
      code: 'invalid_value',
      message: 'candidateIndex 必须为非负整数'
    });
    return null;
  }
  const content: string = getStringField(obj, 'content', '');
  if (content.length > MAX_ARCHIVE_MESSAGE_CONTENT_LENGTH) {
    errors.push({
      path: path + '.content',
      code: 'too_large',
      message: 'content 超过最大长度'
    });
    return null;
  }
  const statusStr: string = getStringField(obj, 'status', '');
  const status: ArchiveMessageStatus | null = parseMessageStatus(statusStr);
  if (status === null) {
    errors.push({
      path: path + '.status',
      code: 'invalid_value',
      message: 'status 不合法: ' + statusStr
    });
    return null;
  }
  const errorMessage: string = getStringField(obj, 'errorMessage', '');
  const isStreaming: boolean = getBooleanField(obj, 'isStreaming', false);
  const createdAt: number = getTimestampField(obj, 'createdAt', path + '.createdAt', errors);
  const updatedAt: number = getTimestampField(obj, 'updatedAt', path + '.updatedAt', errors);
  return {
    sourceCandidateId: sourceCandidateId,
    candidateIndex: candidateIndex,
    content: content,
    status: status,
    errorMessage: errorMessage,
    isStreaming: isStreaming,
    createdAt: createdAt,
    updatedAt: updatedAt
  };
}

function parseSwipeGroup(
  obj: Record<string, Object>,
  path: string,
  errors: ChatArchiveValidationError[],
  unknownFlag: UnknownFlag
): ArchiveSwipeGroup | null {
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(obj, path);
  if (protoError !== null) {
    errors.push(protoError);
    return null;
  }
  if (checkUnknownFields(obj, path, ['sourceAssistantMessageId', 'activeCandidateIndex', 'createdAt', 'updatedAt', 'candidates'])) {
    unknownFlag.unknown = true;
  }
  const sourceAssistantMessageId: string = getStringField(obj, 'sourceAssistantMessageId', '');
  if (sourceAssistantMessageId.length === 0) {
    errors.push({
      path: path + '.sourceAssistantMessageId',
      code: 'missing',
      message: 'sourceAssistantMessageId 不能为空'
    });
    return null;
  }
  const activeCandidateIndex: number = getNumberField(obj, 'activeCandidateIndex', -1);
  if (!Number.isInteger(activeCandidateIndex) || activeCandidateIndex < 0) {
    errors.push({
      path: path + '.activeCandidateIndex',
      code: 'invalid_value',
      message: 'activeCandidateIndex 必须为非负整数'
    });
    return null;
  }
  const createdAt: number = getTimestampField(obj, 'createdAt', path + '.createdAt', errors);
  const updatedAt: number = getTimestampField(obj, 'updatedAt', path + '.updatedAt', errors);
  const candidatesRaw: Object | undefined = obj['candidates'];
  if (candidatesRaw === undefined || candidatesRaw === null || !Array.isArray(candidatesRaw)) {
    errors.push({
      path: path + '.candidates',
      code: 'type_error',
      message: 'candidates 必须为数组'
    });
    return null;
  }
  const candidates: ArchiveSwipeCandidate[] = [];
  const candArr: Object[] = candidatesRaw as Object[];
  for (let i: number = 0; i < candArr.length; i++) {
    const item: Object = candArr[i];
    if (typeof item !== 'object' || item === null || Array.isArray(item)) {
      errors.push({
        path: path + '.candidates[' + String(i) + ']',
        code: 'type_error',
        message: 'candidate 必须为对象'
      });
      continue;
    }
    const candidate: ArchiveSwipeCandidate | null = parseSwipeCandidate(
      item as Record<string, Object>,
      path + '.candidates[' + String(i) + ']',
      errors,
      unknownFlag
    );
    if (candidate !== null) {
      candidates.push(candidate);
    }
  }
  if (candidates.length === 0) {
    errors.push({
      path: path + '.candidates',
      code: 'empty',
      message: 'candidates 至少需要 1 个候选'
    });
    return null;
  }
  return {
    sourceAssistantMessageId: sourceAssistantMessageId,
    activeCandidateIndex: activeCandidateIndex,
    createdAt: createdAt,
    updatedAt: updatedAt,
    candidates: candidates
  };
}

function parseBranchMessageLink(
  obj: Record<string, Object>,
  path: string,
  errors: ChatArchiveValidationError[],
  unknownFlag: UnknownFlag
): ArchiveBranchMessageLink | null {
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(obj, path);
  if (protoError !== null) {
    errors.push(protoError);
    return null;
  }
  if (checkUnknownFields(obj, path, ['sourceMessageId', 'position'])) {
    unknownFlag.unknown = true;
  }
  const sourceMessageId: string = getStringField(obj, 'sourceMessageId', '');
  if (sourceMessageId.length === 0) {
    errors.push({
      path: path + '.sourceMessageId',
      code: 'missing',
      message: 'sourceMessageId 不能为空'
    });
    return null;
  }
  const position: number = getNumberField(obj, 'position', -1);
  if (!Number.isInteger(position) || position < 0) {
    errors.push({
      path: path + '.position',
      code: 'invalid_value',
      message: 'position 必须为非负整数'
    });
    return null;
  }
  return {
    sourceMessageId: sourceMessageId,
    position: position
  };
}

function parseBranchSwipeSelection(
  obj: Record<string, Object>,
  path: string,
  errors: ChatArchiveValidationError[],
  unknownFlag: UnknownFlag
): ArchiveBranchSwipeSelection | null {
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(obj, path);
  if (protoError !== null) {
    errors.push(protoError);
    return null;
  }
  if (checkUnknownFields(obj, path, ['sourceAssistantMessageId', 'candidateIndex'])) {
    unknownFlag.unknown = true;
  }
  const sourceAssistantMessageId: string = getStringField(obj, 'sourceAssistantMessageId', '');
  if (sourceAssistantMessageId.length === 0) {
    errors.push({
      path: path + '.sourceAssistantMessageId',
      code: 'missing',
      message: 'sourceAssistantMessageId 不能为空'
    });
    return null;
  }
  const candidateIndex: number = getNumberField(obj, 'candidateIndex', -1);
  if (!Number.isInteger(candidateIndex) || candidateIndex < 0) {
    errors.push({
      path: path + '.candidateIndex',
      code: 'invalid_value',
      message: 'candidateIndex 必须为非负整数'
    });
    return null;
  }
  return {
    sourceAssistantMessageId: sourceAssistantMessageId,
    candidateIndex: candidateIndex
  };
}

function parseBranch(
  obj: Record<string, Object>,
  path: string,
  errors: ChatArchiveValidationError[],
  unknownFlag: UnknownFlag
): ArchiveBranch | null {
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(obj, path);
  if (protoError !== null) {
    errors.push(protoError);
    return null;
  }
  if (checkUnknownFields(obj, path, ['sourceBranchId', 'parentSourceBranchId', 'forkSourceMessageId', 'name', 'isRoot', 'createdAt', 'updatedAt', 'lastMessageAt', 'messageLinks', 'swipeSelections'])) {
    unknownFlag.unknown = true;
  }
  const sourceBranchId: string = getStringField(obj, 'sourceBranchId', '');
  const parentSourceBranchId: string = getStringField(obj, 'parentSourceBranchId', '');
  const forkSourceMessageId: string = getStringField(obj, 'forkSourceMessageId', '');
  const name: string = getStringField(obj, 'name', '');
  const isRoot: boolean = getBooleanField(obj, 'isRoot', false);
  const createdAt: number = getTimestampField(obj, 'createdAt', path + '.createdAt', errors);
  const updatedAt: number = getTimestampField(obj, 'updatedAt', path + '.updatedAt', errors);
  const lastMessageAt: number = getTimestampField(obj, 'lastMessageAt', path + '.lastMessageAt', errors);
  const messageLinksRaw: Object | undefined = obj['messageLinks'];
  if (messageLinksRaw === undefined || messageLinksRaw === null || !Array.isArray(messageLinksRaw)) {
    errors.push({
      path: path + '.messageLinks',
      code: 'type_error',
      message: 'messageLinks 必须为数组'
    });
    return null;
  }
  const messageLinks: ArchiveBranchMessageLink[] = [];
  const linkArr: Object[] = messageLinksRaw as Object[];
  for (let i: number = 0; i < linkArr.length; i++) {
    const item: Object = linkArr[i];
    if (typeof item !== 'object' || item === null || Array.isArray(item)) {
      errors.push({
        path: path + '.messageLinks[' + String(i) + ']',
        code: 'type_error',
        message: 'messageLink 必须为对象'
      });
      continue;
    }
    const link: ArchiveBranchMessageLink | null = parseBranchMessageLink(
      item as Record<string, Object>,
      path + '.messageLinks[' + String(i) + ']',
      errors,
      unknownFlag
    );
    if (link !== null) {
      messageLinks.push(link);
    }
  }
  const swipeSelectionsRaw: Object | undefined = obj['swipeSelections'];
  let swipeSelections: ArchiveBranchSwipeSelection[] = [];
  if (swipeSelectionsRaw !== undefined && swipeSelectionsRaw !== null) {
    if (!Array.isArray(swipeSelectionsRaw)) {
      errors.push({
        path: path + '.swipeSelections',
        code: 'type_error',
        message: 'swipeSelections 必须为数组'
      });
      return null;
    }
    const selArr: Object[] = swipeSelectionsRaw as Object[];
    for (let i: number = 0; i < selArr.length; i++) {
      const item: Object = selArr[i];
      if (typeof item !== 'object' || item === null || Array.isArray(item)) {
        errors.push({
          path: path + '.swipeSelections[' + String(i) + ']',
          code: 'type_error',
          message: 'swipeSelection 必须为对象'
        });
        continue;
      }
      const sel: ArchiveBranchSwipeSelection | null = parseBranchSwipeSelection(
        item as Record<string, Object>,
        path + '.swipeSelections[' + String(i) + ']',
        errors,
        unknownFlag
      );
      if (sel !== null) {
        swipeSelections.push(sel);
      }
    }
  }
  return {
    sourceBranchId: sourceBranchId,
    parentSourceBranchId: parentSourceBranchId,
    forkSourceMessageId: forkSourceMessageId,
    name: name,
    isRoot: isRoot,
    createdAt: createdAt,
    updatedAt: updatedAt,
    lastMessageAt: lastMessageAt,
    messageLinks: messageLinks,
    swipeSelections: swipeSelections
  };
}

function parseMessage(
  obj: Record<string, Object>,
  path: string,
  errors: ChatArchiveValidationError[],
  unknownFlag: UnknownFlag
): ArchiveMessage | null {
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(obj, path);
  if (protoError !== null) {
    errors.push(protoError);
    return null;
  }
  if (checkUnknownFields(obj, path, ['sourceMessageId', 'role', 'content', 'createdAt', 'updatedAt', 'order', 'status', 'errorMessage', 'source', 'senderType', 'senderCharacterId', 'sceneId', 'generationBatchId', 'visibility', 'recipientCharacterIds', 'participantIds', 'witnessIds'])) {
    unknownFlag.unknown = true;
  }
  const sourceMessageId: string = getStringField(obj, 'sourceMessageId', '');
  const roleStr: string = getStringField(obj, 'role', '');
  const role: ArchiveMessageRole | null = parseMessageRole(roleStr);
  if (role === null) {
    errors.push({
      path: path + '.role',
      code: 'invalid_value',
      message: 'role 不合法: ' + roleStr
    });
    return null;
  }
  const content: string = getStringField(obj, 'content', '');
  if (content.length > MAX_ARCHIVE_MESSAGE_CONTENT_LENGTH) {
    errors.push({
      path: path + '.content',
      code: 'too_large',
      message: 'content 超过最大长度'
    });
    return null;
  }
  const createdAt: number = getTimestampField(obj, 'createdAt', path + '.createdAt', errors);
  const updatedAt: number = getTimestampField(obj, 'updatedAt', path + '.updatedAt', errors);
  const order: number = getNumberField(obj, 'order', -1);
  if (!Number.isInteger(order) || order < 0) {
    errors.push({
      path: path + '.order',
      code: 'invalid_value',
      message: 'order 必须为非负整数'
    });
    return null;
  }
  const statusStr: string = getStringField(obj, 'status', 'completed');
  const status: ArchiveMessageStatus | null = parseMessageStatus(statusStr);
  if (status === null) {
    errors.push({
      path: path + '.status',
      code: 'invalid_value',
      message: 'status 不合法: ' + statusStr
    });
    return null;
  }
  const errorMessage: string = getStringField(obj, 'errorMessage', '');
  const sourceStr: string = getStringField(obj, 'source', 'conversation');
  const source: ArchiveMessageSource | null = parseMessageSource(sourceStr);
  if (source === null) {
    errors.push({
      path: path + '.source',
      code: 'invalid_value',
      message: 'source 不合法: ' + sourceStr
    });
    return null;
  }
  const senderTypeStr: string = getStringField(obj, 'senderType', 'user');
  const senderType: ArchiveMessageSenderType | null = parseMessageSenderType(senderTypeStr);
  if (senderType === null) {
    errors.push({
      path: path + '.senderType',
      code: 'invalid_value',
      message: 'senderType 不合法: ' + senderTypeStr
    });
    return null;
  }
  const senderCharacterId: string = getStringField(obj, 'senderCharacterId', '');
  const sceneId: string = getStringField(obj, 'sceneId', '');
  const generationBatchId: string = getStringField(obj, 'generationBatchId', '');
  const visibilityStr: string = getStringField(obj, 'visibility', 'public');
  const visibility: ArchiveMessageVisibility | null = parseMessageVisibility(visibilityStr);
  if (visibility === null) {
    errors.push({
      path: path + '.visibility',
      code: 'invalid_value',
      message: 'visibility 不合法: ' + visibilityStr
    });
    return null;
  }
  const recipientCharacterIds: string[] = getStringArrayField(obj, 'recipientCharacterIds', path + '.recipientCharacterIds', errors);
  const participantIds: string[] = getStringArrayField(obj, 'participantIds', path + '.participantIds', errors);
  const witnessIds: string[] = getStringArrayField(obj, 'witnessIds', path + '.witnessIds', errors);
  // 校验 private visibility 必须有 recipientCharacterIds
  if (visibility === 'private' && recipientCharacterIds.length === 0) {
    errors.push({
      path: path + '.recipientCharacterIds',
      code: 'invalid_value',
      message: 'visibility=private 时 recipientCharacterIds 不能为空'
    });
  } else if (visibility !== 'private' && recipientCharacterIds.length > 0) {
    errors.push({
      path: path + '.recipientCharacterIds',
      code: 'invalid_value',
      message: 'visibility=' + visibility + ' 时 recipientCharacterIds 必须为空'
    });
  }
  return {
    sourceMessageId: sourceMessageId,
    role: role,
    content: content,
    createdAt: createdAt,
    updatedAt: updatedAt,
    order: order,
    status: status,
    errorMessage: errorMessage,
    source: source,
    senderType: senderType,
    senderCharacterId: senderCharacterId,
    sceneId: sceneId,
    generationBatchId: generationBatchId,
    visibility: visibility,
    recipientCharacterIds: recipientCharacterIds,
    participantIds: participantIds,
    witnessIds: witnessIds
  };
}

function parseConversation(
  obj: Object,
  index: number,
  errors: ChatArchiveValidationError[],
  unknownFlag: UnknownFlag
): ArchiveConversation | null {
  const path: string = 'conversations[' + String(index) + ']';
  if (typeof obj !== 'object' || obj === null || Array.isArray(obj)) {
    errors.push({
      path: path,
      code: 'type_error',
      message: 'conversation 必须为对象'
    });
    return null;
  }
  const convObj: Record<string, Object> = obj as Record<string, Object>;
  const protoError: ChatArchiveValidationError | null = checkPrototypePollution(convObj, path);
  if (protoError !== null) {
    errors.push(protoError);
    return null;
  }
  if (checkUnknownFields(convObj, path, ['sourceConversationId', 'title', 'createdAt', 'updatedAt', 'lastMessageAt', 'userNameOverride', 'sortOrder', 'messages', 'branches', 'swipeGroups'])) {
    unknownFlag.unknown = true;
  }
  const sourceConversationId: string = getStringField(convObj, 'sourceConversationId', '');
  const title: string = getStringField(convObj, 'title', '');
  const createdAt: number = getTimestampField(convObj, 'createdAt', path + '.createdAt', errors);
  const updatedAt: number = getTimestampField(convObj, 'updatedAt', path + '.updatedAt', errors);
  const lastMessageAt: number = getTimestampField(convObj, 'lastMessageAt', path + '.lastMessageAt', errors);
  const userNameOverride: string = getStringField(convObj, 'userNameOverride', '');
  const sortOrder: number = getNumberField(convObj, 'sortOrder', 0);

  // messages
  const messagesRaw: Object | undefined = convObj['messages'];
  if (messagesRaw === undefined || messagesRaw === null || !Array.isArray(messagesRaw)) {
    errors.push({
      path: path + '.messages',
      code: 'type_error',
      message: 'messages 必须为数组'
    });
    return null;
  }
  const msgArr: Object[] = messagesRaw as Object[];
  if (msgArr.length > MAX_ARCHIVE_MESSAGES_PER_CONVERSATION) {
    errors.push({
      path: path + '.messages',
      code: 'too_many',
      message: '消息数超过上限 ' + String(MAX_ARCHIVE_MESSAGES_PER_CONVERSATION)
    });
    return null;
  }
  const messages: ArchiveMessage[] = [];
  for (let i: number = 0; i < msgArr.length; i++) {
    const msg: ArchiveMessage | null = parseMessage(
      msgArr[i] as Record<string, Object>,
      path + '.messages[' + String(i) + ']',
      errors,
      unknownFlag
    );
    if (msg !== null) {
      messages.push(msg);
    }
  }

  // branches
  const branchesRaw: Object | undefined = convObj['branches'];
  if (branchesRaw === undefined || branchesRaw === null || !Array.isArray(branchesRaw)) {
    errors.push({
      path: path + '.branches',
      code: 'type_error',
      message: 'branches 必须为数组'
    });
    return null;
  }
  const branchArr: Object[] = branchesRaw as Object[];
  const branches: ArchiveBranch[] = [];
  for (let i: number = 0; i < branchArr.length; i++) {
    const branch: ArchiveBranch | null = parseBranch(
      branchArr[i] as Record<string, Object>,
      path + '.branches[' + String(i) + ']',
      errors,
      unknownFlag
    );
    if (branch !== null) {
      branches.push(branch);
    }
  }

  // swipeGroups
  const swipeGroupsRaw: Object | undefined = convObj['swipeGroups'];
  let swipeGroups: ArchiveSwipeGroup[] = [];
  if (swipeGroupsRaw !== undefined && swipeGroupsRaw !== null) {
    if (!Array.isArray(swipeGroupsRaw)) {
      errors.push({
        path: path + '.swipeGroups',
        code: 'type_error',
        message: 'swipeGroups 必须为数组'
      });
      return null;
    }
    const groupArr: Object[] = swipeGroupsRaw as Object[];
    for (let i: number = 0; i < groupArr.length; i++) {
      const group: ArchiveSwipeGroup | null = parseSwipeGroup(
        groupArr[i] as Record<string, Object>,
        path + '.swipeGroups[' + String(i) + ']',
        errors,
        unknownFlag
      );
      if (group !== null) {
        swipeGroups.push(group);
      }
    }
  }

  return {
    sourceConversationId: sourceConversationId,
    title: title,
    createdAt: createdAt,
    updatedAt: updatedAt,
    lastMessageAt: lastMessageAt,
    userNameOverride: userNameOverride,
    sortOrder: sortOrder,
    messages: messages,
    branches: branches,
    swipeGroups: swipeGroups
  };
}
