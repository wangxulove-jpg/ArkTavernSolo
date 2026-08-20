/**
 * ChatMessageDataSource 消息列表懒加载数据源
 *
 * 目的:
 * - 替代 ForEach 全量构建,改用 LazyForEach 只构建可视区域 + 缓存的气泡组件
 * - 解决 100+ 条消息时 ForEach 全量构建组件导致内存峰值和崩溃的问题
 *
 * 设计:
 * - 实现 ArkUI IDataSource 接口,配合 LazyForEach 使用
 * - 包装 ChatMessageRenderState[](稳定实例,key = messageId)
 * - 数据变化时通过 DataChangeListener 通知 LazyForEach 增量更新
 * - 不持有业务逻辑,仅做数据源代理
 *
 * 关键约束:
 * - totalCount / getData 必须同步快速返回(被 LazyForEach 高频调用)
 * - setStates 触发 onDataReloaded,LazyForEach 按 key 复用已有组件
 * - 同一 messageId 始终对应同一 RenderState 实例(由 ChatPage.syncRenderStates 保证)
 * - 不存储敏感数据
 */

import { ChatMessageRenderState } from '../models/ChatMessageRenderState';

export class ChatMessageDataSource implements IDataSource {
  /** 当前数据源持有的渲染状态列表(按消息顺序) */
  private states: ChatMessageRenderState[] = [];
  /** 注册的 DataChangeListener 列表(LazyForEach 内部注册) */
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.states.length;
  }

  getData(index: number): ChatMessageRenderState {
    if (index < 0 || index >= this.states.length) {
      throw new RangeError('ChatMessageDataSource index out of range: ' + index.toString());
    }
    return this.states[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /**
   * 替换全部数据(新数组引用)。
   * 触发 onDataReloaded,LazyForEach 按 key 复用已有组件、构建新组件、回收离开组件。
   */
  setStates(states: ChatMessageRenderState[]): void {
    this.states = states;
    this.notifyReload();
  }

  /**
   * 获取当前数据引用(用于长度判断等只读场景)。
   */
  getStates(): ChatMessageRenderState[] {
    return this.states;
  }

  /**
   * 清空数据源(页面销毁时调用)。
   */
  clear(): void {
    this.states = [];
    this.notifyReload();
  }

  private notifyReload(): void {
    for (let i: number = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}
