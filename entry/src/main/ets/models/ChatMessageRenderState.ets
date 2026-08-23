import { Logger } from '../utils/Logger';
/**
 * ChatMessageRenderState 消息渲染状态(单角色聊天专用)
 *
 * 目的:
 * - 解决 ForEach 在固定 key 下复用 ChatMessageBubble 时,@Prop message 同步不可靠
 *   导致 Assistant 消息正文持续增长但 UI 不显示的根因。
 *
 * 设计:
 * - @Observed 装饰,字段赋值时触发 @ObjectLink 响应式更新
 * - ChatMessageBubble 通过 @ObjectLink renderState 接收,
 *   同一 messageId 始终对应同一个 RenderState 实例,
 *   ArkUI 字段赋值即可触发气泡重建,无需销毁组件实例
 *
 * 关键约束:
 * - messageId 在创建后不可变,用于 ForEach key
 * - message/content/isStreaming/status/source/role/errorMessage/updatedAt
 *   均为可观察字段,业务层 ChatMessage 变更时通过 applyMessage 同步更新
 * - 业务层 ChatMessage 仍使用不可变更新(mergeChatMessage),
 *   本类仅承载 UI 渲染所需字段,允许原地修改
 * - 不存储敏感数据
 *
 * 与 TypingState 区别:
 * - TypingState 仅 content + isStreaming,缺少 role/status/source 等 UI 必需字段
 * - 本类为单角色聊天重建的稳定展示对象,直接替代 ChatMessageBubble 的 @Prop message
 */

import { ChatMessage, ChatMessageStatus, MessageSenderType } from './ChatMessage';
import { ChatRole } from './ChatRole';
import { ChatMessageSource } from './ChatMessageSource';

@Observed
export class ChatMessageRenderState {
  /** 对应的 ChatMessage ID(创建后不变,ForEach key) */
  readonly messageId: string;
  /** 最新 ChatMessage 引用(完整业务数据,不可变更新) */
  message: ChatMessage;
  /** 当前消息正文(随流式持续增长) */
  content: string;
  /** 展示正文(显示层宏替换后的文本,供气泡渲染;默认与 content 相同) */
  displayContent: string;
  /** 是否正在流式生成中 */
  isStreaming: boolean;
  /** Assistant 消息状态 */
  status: ChatMessageStatus;
  /** 消息角色 */
  role: ChatRole;
  /** 消息来源(开场白等) */
  source: ChatMessageSource | undefined;
  /** 发送者类型(user/character/narrator) */
  senderType: MessageSenderType | undefined;
  /** 是否计入记忆摘要(v37 旁白重构) */
  includeInMemory: boolean | undefined;
  /** 错误信息(生成失败时) */
  errorMessage: string;
  /** 更新时间(毫秒时间戳) */
  updatedAt: number;

  constructor(message: ChatMessage) {
    this.messageId = message.id;
    this.message = message;
    this.content = message.content;
    this.displayContent = message.content;
    this.isStreaming = message.isStreaming === true;
    this.status = message.status !== undefined ? message.status : ChatMessageStatus.Completed;
    this.role = message.role;
    this.source = message.source;
    this.senderType = message.senderType;
    this.includeInMemory = message.includeInMemory;
    this.errorMessage = message.errorMessage !== undefined ? message.errorMessage : '';
    this.updatedAt = message.updatedAt !== undefined ? message.updatedAt : message.createdAt;
  }

  /**
   * 同步最新 ChatMessage 到 RenderState(原地修改 @Observed 字段)。
   * 业务层 ChatMessage 继续使用不可变更新,本方法只是把不可变对象的最新值
   * 拷贝到 RenderState 的可观察字段,触发 @ObjectLink 响应式刷新。
   *
   * 状态一致性不变量:
   * - Streaming → isStreaming=true
   * - Completed → isStreaming=false
   * - Failed → isStreaming=false
   * - Cancelled → isStreaming=false
   * 违反时记录警告(脱敏:仅 messageId 前缀),便于回归测试中快速发现状态泄漏。
   */
  applyMessage(message: ChatMessage): void {
    this.message = message;
    this.content = message.content;
    this.displayContent = message.content;
    this.isStreaming = message.isStreaming === true;
    this.status = message.status !== undefined ? message.status : ChatMessageStatus.Completed;
    this.source = message.source;
    this.senderType = message.senderType;
    this.includeInMemory = message.includeInMemory;
    this.errorMessage = message.errorMessage !== undefined ? message.errorMessage : '';
    this.updatedAt = message.updatedAt !== undefined ? message.updatedAt : message.createdAt;
    if (this.isStreaming) {
      if (this.status === ChatMessageStatus.Failed
        || this.status === ChatMessageStatus.Completed
        || this.status === ChatMessageStatus.Cancelled) {
        Logger.warn(`[RenderState] invariant violation mid=${this.messageId.slice(0,8)} status=${String(this.status)} isStreaming=true`);
      }
    }
  }

  /**
   * 设置展示正文(显示层宏替换后的文本)。
   * 保留 message.content 原文;气泡渲染用 displayContent,复制/编辑仍取原文。
   * @param text 替换后的展示文本
   */
  setDisplayContent(text: string): void {
    this.displayContent = text;
  }
}
