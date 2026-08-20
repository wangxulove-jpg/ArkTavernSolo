/**
 * BranchMapDisplayInfo 分支地图节点展示信息(T-6.4B-1.2)
 *
 * 在 ConversationBranchSummary 基础上派生用于 BranchMap 节点展示的额外字段:
 * - fork User Message 短预览
 * - 分歧 Assistant Message 短预览
 * - fork 轮次序号
 *
 * 派生原则:
 * - 优先从现有 Message 和 BranchMessageLink 查询派生
 * - 不修改 Schema
 * - 不存储完整正文(预览已截断)
 * - 不依赖 ArkUI / Repository / Service
 *
 * 预览规则:
 * - 去除换行
 * - 合并多余空格
 * - User 预览最多约 16 个字符
 * - Assistant 预览最多约 32 个字符
 * - 超出显示省略号
 */

import { ConversationBranchSummary } from './ConversationBranch';

/**
 * BranchMap 节点展示信息。
 */
export interface BranchMapDisplayInfo {
  /** 对应 Branch 摘要(原始数据) */
  readonly summary: ConversationBranchSummary;
  /** Branch ID(summary.id 的别名,便于使用) */
  readonly branchId: string;
  /** 父 Branch ID(Root 为 undefined) */
  readonly parentBranchId?: string;
  /** fork Message ID(Root 为 undefined) */
  readonly forkMessageId?: string;
  /** fork 轮次序号(从 1 开始,Root 为 0) */
  readonly forkTurnNumber: number;
  /**
   * 当前 Branch 覆盖的最深轮次(= Branch 中 User 消息数)。
   * T-6.4B-2-R1: 用于节点延伸显示,高度 = (currentMaxTurn - forkTurnNumber + 1) × LEVEL_GAP。
   * Root 的 currentMaxTurn = Root 中 User 消息数。
   */
  readonly currentMaxTurn: number;
  /** fork User Message 短预览(Root 为空字符串) */
  readonly forkUserPreview: string;
  /** 分歧 Assistant Message 短预览(分支首条 Assistant,Root 为空字符串) */
  readonly firstDivergentAssistantPreview: string;
  /** 该 Branch 中消息数量 */
  readonly messageCount: number;
  /** 是否为 Root */
  readonly isRoot: boolean;
  /** 是否为当前 Active */
  readonly isActive: boolean;
  /** 创建时间 */
  readonly createdAt: number;
  /**
   * 地图节点唯一 ID。
   * 与 branchId 解耦:一个分支可以有多个地图节点(分叉起点 + 末端节点)。
   * 对于真实分支节点,nodeId = branchId。
   * 对于末端节点,nodeId = "head:" + branchId + ":" + turnNumber。
   */
  readonly nodeId: string;
  /** 是否为分支末端显示节点(用于显示当前对话位置) */
  readonly isTerminal: boolean;
  /** 是否为用户当前所在节点 */
  readonly isCurrent: boolean;
}

/** User 预览最大长度 */
const USER_PREVIEW_MAX: number = 16;

/** Assistant 预览最大长度 */
const ASSISTANT_PREVIEW_MAX: number = 32;

/**
 * 预览处理:去除换行、合并多余空格、截断并添加省略号。
 */
export function buildPreview(content: string, maxLen: number): string {
  if (content.length === 0) {
    return '';
  }
  // 去除换行
  let s: string = content.replace(/[\r\n]+/g, ' ');
  // 合并多余空格
  s = s.replace(/\s+/g, ' ').trim();
  if (s.length === 0) {
    return '';
  }
  if (s.length > maxLen) {
    return s.substring(0, maxLen) + '…';
  }
  return s;
}

/**
 * 构建 User 预览。
 */
export function buildUserPreview(content: string): string {
  return buildPreview(content, USER_PREVIEW_MAX);
}

/**
 * 构建 Assistant 预览。
 */
export function buildAssistantPreview(content: string): string {
  return buildPreview(content, ASSISTANT_PREVIEW_MAX);
}
