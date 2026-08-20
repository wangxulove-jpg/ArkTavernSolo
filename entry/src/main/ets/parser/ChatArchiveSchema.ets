/**
 * ChatArchiveSchema ArkTavern 聊天归档格式定义
 *
 * 定义 ArkTavernChatArchive v1 格式的 TypeScript 类型结构。
 * 用于聊天记录的导出与导入,确保跨设备、跨安装的可移植性。
 *
 * 设计原则:
 * - 只导出真实存在的数据库字段,不虚构字段
 * - 所有 ID 在导出时加 source 前缀,仅用于来源追踪
 * - 导入时重新生成 local ID,不直接使用外部 ID 作为主键
 * - 保留分支、Swipe、候选回复等完整结构,不静默压平
 * - 不包含 API Key、Access Token、本地路径、用户凭证、调试日志
 *
 * 不依赖:
 * - ArkUI
 * - 数据库
 * - 网络模块
 */

/** 归档格式标识,固定为 "ArkTavernChatArchive" */
export const ARCHIVE_FORMAT: string = 'ArkTavernChatArchive';

/** 归档格式主版本号 */
export const ARCHIVE_VERSION: number = 1;

/** 归档范围 */
export type ArchiveScope = 'single' | 'character';

/** 消息角色(与 ChatRole 对齐) */
export type ArchiveMessageRole = 'user' | 'assistant' | 'system';

/** 消息状态(与 ChatMessageStatus 对齐) */
export type ArchiveMessageStatus = 'streaming' | 'completed' | 'cancelled' | 'failed';

/** 消息来源(只持久化 Conversation / CharacterFirstMessage / ExternalSystem) */
export type ArchiveMessageSource = 'conversation' | 'characterFirstMessage' | 'externalSystem';

/** 发送者类型(与 MessageSenderType 对齐) */
export type ArchiveMessageSenderType = 'user' | 'character' | 'narrator';

/** 消息可见范围(与 MessageVisibility 对齐) */
export type ArchiveMessageVisibility = 'public' | 'private' | 'narrator';

/** 文件扩展名(含前导点) */
export const ARCHIVE_FILE_EXTENSION: string = '.arktchat.json';

/** 最大文件大小:50 MB */
export const MAX_ARCHIVE_FILE_SIZE: number = 50 * 1024 * 1024;

/** 最大对话数 */
export const MAX_ARCHIVE_CONVERSATIONS: number = 1000;

/** 单个对话最大消息数 */
export const MAX_ARCHIVE_MESSAGES_PER_CONVERSATION: number = 100000;

/** 单条消息内容最大长度 */
export const MAX_ARCHIVE_MESSAGE_CONTENT_LENGTH: number = 1000000;

/** 最大 JSON 嵌套深度 */
export const MAX_ARCHIVE_JSON_DEPTH: number = 64;

/** 角色来源信息(用于导入时角色匹配) */
export interface ArchiveCharacterInfo {
  /** 来源角色 ID(仅用于追踪,不作为本地主键) */
  readonly sourceCharacterId: string;
  /** 来源角色名称(允许重名,不能仅凭名称匹配) */
  readonly name: string;
  /** 头像文件名(仅元数据,不包含图片二进制) */
  readonly avatarName: string;
}

/** 消息候选(Swipe Candidate) */
export interface ArchiveSwipeCandidate {
  /** 来源候选 ID(仅用于追踪) */
  readonly sourceCandidateId: string;
  /** 候选索引(非负整数,从 0 开始) */
  readonly candidateIndex: number;
  /** 候选内容 */
  readonly content: string;
  /** 候选状态 */
  readonly status: ArchiveMessageStatus;
  /** 错误信息(可选) */
  readonly errorMessage: string;
  /** 是否流式生成中(导入时通常为 false,流式状态不应导出) */
  readonly isStreaming: boolean;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒,0 表示无) */
  readonly updatedAt: number;
}

/** 消息候选组(Swipe Group) */
export interface ArchiveSwipeGroup {
  /** 来源 Assistant 消息 ID(与 messages[].sourceMessageId 对应) */
  readonly sourceAssistantMessageId: string;
  /** 当前激活的候选索引 */
  readonly activeCandidateIndex: number;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
  /** 候选列表(至少 1 个) */
  readonly candidates: ArchiveSwipeCandidate[];
}

/** 分支消息链接 */
export interface ArchiveBranchMessageLink {
  /** 来源消息 ID(与 messages[].sourceMessageId 对应) */
  readonly sourceMessageId: string;
  /** 在分支中的位置(从 0 开始) */
  readonly position: number;
}

/** 分支候选选择 */
export interface ArchiveBranchSwipeSelection {
  /** 来源 Assistant 消息 ID */
  readonly sourceAssistantMessageId: string;
  /** 选中的候选索引(非负整数) */
  readonly candidateIndex: number;
}

/** 对话分支 */
export interface ArchiveBranch {
  /** 来源分支 ID(仅用于追踪) */
  readonly sourceBranchId: string;
  /** 父分支来源 ID(Root 分支为空字符串) */
  readonly parentSourceBranchId: string;
  /** 从哪条消息分叉(来源消息 ID,Root 为空字符串) */
  readonly forkSourceMessageId: string;
  /** 分支名称 */
  readonly name: string;
  /** 是否为 Root 分支 */
  readonly isRoot: boolean;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
  /** 最后消息时间(毫秒) */
  readonly lastMessageAt: number;
  /** 分支消息链接(position 升序) */
  readonly messageLinks: ArchiveBranchMessageLink[];
  /** 分支候选选择 */
  readonly swipeSelections: ArchiveBranchSwipeSelection[];
}

/** 归档消息 */
export interface ArchiveMessage {
  /** 来源消息 ID(仅用于追踪) */
  readonly sourceMessageId: string;
  /** 消息角色 */
  readonly role: ArchiveMessageRole;
  /** 消息内容 */
  readonly content: string;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒,0 表示无) */
  readonly updatedAt: number;
  /** 在对话中的顺序(sequence_number,从 1 开始) */
  readonly order: number;
  /** 消息状态 */
  readonly status: ArchiveMessageStatus;
  /** 错误信息(可选,空字符串表示无) */
  readonly errorMessage: string;
  /** 消息来源 */
  readonly source: ArchiveMessageSource;
  /** 发送者类型(默认 'user') */
  readonly senderType: ArchiveMessageSenderType;
  /** 角色消息时的发送者角色 ID(空字符串表示无) */
  readonly senderCharacterId: string;
  /** 场景 ID(多人世界,空字符串表示无) */
  readonly sceneId: string;
  /** 生成批次 ID(空字符串表示无) */
  readonly generationBatchId: string;
  /** 消息可见范围(默认 'public') */
  readonly visibility: ArchiveMessageVisibility;
  /** 私聊目标角色 ID 列表(空数组表示无) */
  readonly recipientCharacterIds: string[];
  /** 参与者 ID 列表(空数组表示无) */
  readonly participantIds: string[];
  /** 目击者 ID 列表(空数组表示无) */
  readonly witnessIds: string[];
}

/** 归档对话 */
export interface ArchiveConversation {
  /** 来源对话 ID(仅用于追踪) */
  readonly sourceConversationId: string;
  /** 对话标题 */
  readonly title: string;
  /** 创建时间(毫秒) */
  readonly createdAt: number;
  /** 更新时间(毫秒) */
  readonly updatedAt: number;
  /** 最后消息时间(毫秒) */
  readonly lastMessageAt: number;
  /** 对话级用户称呼覆盖(空字符串表示无) */
  readonly userNameOverride: string;
  /** 排序权重(越小越靠前) */
  readonly sortOrder: number;
  /** 消息列表(按 order 升序) */
  readonly messages: ArchiveMessage[];
  /** 分支列表(至少 1 个 Root 分支) */
  readonly branches: ArchiveBranch[];
  /** Swipe 候选组列表 */
  readonly swipeGroups: ArchiveSwipeGroup[];
}

/** 归档根对象 */
export interface ArkTavernChatArchive {
  /** 格式标识,固定为 "ArkTavernChatArchive" */
  readonly format: string;
  /** 格式主版本号 */
  readonly version: number;
  /** 归档范围 */
  readonly scope: ArchiveScope;
  /** 导出时间(毫秒) */
  readonly exportedAt: number;
  /** 导出时的 App 版本 */
  readonly appVersion: string;
  /** 来源角色信息 */
  readonly character: ArchiveCharacterInfo;
  /** 对话列表 */
  readonly conversations: ArchiveConversation[];
}

/** 导出统计 */
export interface ChatArchiveExportStats {
  /** 对话数量 */
  readonly conversationCount: number;
  /** 消息总数 */
  readonly messageCount: number;
  /** 分支总数 */
  readonly branchCount: number;
  /** 候选总数 */
  readonly candidateCount: number;
  /** 导出文件 URI */
  readonly targetUri: string;
}

/** 导入预览统计 */
export interface ChatArchivePreviewStats {
  /** 文件名(显示用) */
  readonly fileName: string;
  /** 文件大小(字节) */
  readonly fileSize: number;
  /** 格式版本 */
  readonly version: number;
  /** 导出时间(毫秒) */
  readonly exportedAt: number;
  /** 来源角色名称 */
  readonly sourceCharacterName: string;
  /** 来源角色 ID */
  readonly sourceCharacterId: string;
  /** 对话数量 */
  readonly conversationCount: number;
  /** 消息总数 */
  readonly messageCount: number;
  /** 分支总数 */
  readonly branchCount: number;
  /** 候选总数 */
  readonly candidateCount: number;
  /** 最早消息时间(毫秒,0 表示无消息) */
  readonly earliestMessageAt: number;
  /** 最晚消息时间(毫秒,0 表示无消息) */
  readonly latestMessageAt: number;
  /** 是否存在 system 消息 */
  readonly hasSystemMessage: boolean;
  /** 是否存在分支(非 Root 分支数量 > 0) */
  readonly hasBranches: boolean;
  /** 是否存在未知字段(宽容解析时记录) */
  readonly hasUnknownFields: boolean;
  /** 是否匹配当前角色 */
  readonly matchesCurrentCharacter: boolean;
  /** SHA-256 哈希前 8 位(用于日志) */
  readonly sha256Prefix: string;
  /** 文件 SHA-256 完整哈希(Base64) */
  readonly sha256Full: string;
}

/** 导入单个对话结果 */
export interface ChatArchiveImportConversationResult {
  /** 是否成功 */
  readonly success: boolean;
  /** 来源对话标题 */
  readonly sourceTitle: string;
  /** 新创建的本地对话 ID(失败时为空字符串) */
  readonly localConversationId: string;
  /** 导入消息数 */
  readonly messageCount: number;
  /** 失败原因(成功时为空字符串) */
  readonly errorMessage: string;
}

/** 导入总体结果 */
export interface ChatArchiveImportResult {
  /** 成功导入的对话数 */
  readonly successCount: number;
  /** 失败的对话数 */
  readonly failedCount: number;
  /** 跳过的对话数(重复且用户选择跳过) */
  readonly skippedCount: number;
  /** 总消息数 */
  readonly totalMessageCount: number;
  /** 各对话详细结果 */
  readonly conversationResults: ChatArchiveImportConversationResult[];
  /** 新创建的本地对话 ID 列表(用于跳转查看) */
  readonly importedConversationIds: string[];
}

/** 重复检测信息 */
export interface ChatArchiveDuplicateInfo {
  /** 是否可能重复 */
  readonly possiblyDuplicate: boolean;
  /** 来源对话标题 */
  readonly sourceTitle: string;
  /** 对话指纹(用于日志,前 8 位) */
  readonly fingerprintPrefix: string;
}
