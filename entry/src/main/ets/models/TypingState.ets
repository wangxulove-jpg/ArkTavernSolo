/**
 * TypingState 打字机状态
 *
 * @Observed class,字段赋值时触发 @ObjectLink 响应式更新。
 *
 * 用途:
 * - ChatMessageBubble 通过 @ObjectLink 持有 TypingState,响应字段变化
 * - ChatPage 维护 TypingState[] 数组,每次 flushMessages 时原地修改字段
 * - 避免 ForEach 在 key 不变时跳过 @Prop 更新的问题
 *
 * 设计:
 * - message 字段为 ChatMessage 引用(role/status/source/id 不变,无需响应式)
 * - content/isStreaming 是流式更新字段,原地赋值触发 @ObjectLink 响应
 * - ForEach 数据源为 typingStates,itemGenerator 直接通过 state.message 取 msg
 *   (避免 ForEach 内部使用 const 变量声明导致 ArkTS 编译错误)
 * - 不存储敏感数据
 */

import { ChatMessage } from './ChatMessage';

@Observed
export class TypingState {
  /** 对应的 ChatMessage 引用(role/status/source/id 不变) */
  readonly message: ChatMessage;
  /** 对应的 ChatMessage ID(创建后不变,用于在数组中查找) */
  readonly messageId: string;
  /** 当前内容(完整已接收的 content) */
  content: string = '';
  /** 是否正在流式生成中 */
  isStreaming: boolean = false;

  constructor(message: ChatMessage, content: string = '', isStreaming: boolean = false) {
    this.message = message;
    this.messageId = message.id;
    this.content = content;
    this.isStreaming = isStreaming;
  }
}
