/**
 * MemoryPersistenceService(分支感知长期记忆持久化服务)
 *
 * 职责:
 * - 包装 ChatMemoryRepository 的 Service 层接口
 * - 提供事务内清理方法(供 ChatPersistenceOperations 调用)
 * - 提供 fork 时复制祖先 Memory 的方法(供 ConversationBranchPersistenceService 调用)
 *
 * 设计:
 * - 不直接实现业务逻辑(增量总结在 MemoryService)
 * - 不调用 ModelService(总结由 MemoryService 触发)
 * - 不暴露 Repository 实例给上层
 *
 * 分层约束:
 * - 可被 services/ 层其他服务调用
 * - 可被 repositories/ChatPersistenceOperations 在事务内调用
 * - 不引用具体页面类
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../database/DbHelper';
import { ChatMemory, MemoryType } from '../models/ChatMemory';
import { ChatMemoryRepository } from '../repositories/ChatMemoryRepository';

export class MemoryPersistenceService {
  private readonly dbHelper: DbHelper;
  private readonly repository: ChatMemoryRepository;

  constructor(dbHelper: DbHelper, repository: ChatMemoryRepository) {
    this.dbHelper = dbHelper;
    this.repository = repository;
  }

  /** 暴露 Repository(供 MemoryService 调用高级 API) */
  getRepository(): ChatMemoryRepository {
    return this.repository;
  }

  // ===== 查询 =====

  /**
   * 获取指定 Branch 的最新 Memory(endPosition 最大)。
   */
  async getLatestByBranch(branchId: string): Promise<ChatMemory | null> {
    return await this.repository.getLatestByBranch(branchId);
  }

  /**
   * 获取指定 Branch 的全部 Memory(按 endPosition ASC)。
   */
  async listByBranch(branchId: string): Promise<ChatMemory[]> {
    return await this.repository.listByBranch(branchId);
  }

  /**
   * v12: 获取指定 Branch 的有效 Memory(enabled=1 且 invalidated=0)。
   * 用于 PromptBuilder 注入和 MemoryService 多层记忆加载。
   */
  async listValidByBranch(branchId: string): Promise<ChatMemory[]> {
    return await this.repository.listValidByBranch(branchId);
  }

  /**
   * v12: 获取指定 Branch 某类型的有效 Memory(enabled=1 且 invalidated=0)。
   * 按 importance DESC, endPosition ASC 排序。
   */
  async listValidByBranchAndType(branchId: string, memoryType: MemoryType): Promise<ChatMemory[]> {
    return await this.repository.listValidByBranchAndType(branchId, memoryType);
  }

  /**
   * 按 ID 查询 Memory。
   */
  async getById(memoryId: string): Promise<ChatMemory | null> {
    return await this.repository.getById(memoryId);
  }

  // ===== 写入 =====

  /**
   * 插入新的 Memory。
   */
  async insert(memory: ChatMemory): Promise<void> {
    await this.repository.insert(memory);
  }

  /**
   * 更新 Memory(不可变字段保持不变)。
   */
  async update(memory: ChatMemory): Promise<void> {
    await this.repository.update(memory);
  }

  /**
   * 仅更新 summary 字段(用于手动编辑摘要)。
   */
  async updateSummary(memoryId: string, newSummary: string): Promise<void> {
    await this.repository.updateSummary(memoryId, newSummary);
  }

  /**
   * 仅更新 enabled 字段。
   */
  async setEnabled(memoryId: string, enabled: boolean): Promise<void> {
    await this.repository.setEnabled(memoryId, enabled);
  }

  // ===== 删除 =====

  /**
   * 删除单条 Memory。
   */
  async removeById(memoryId: string): Promise<void> {
    await this.repository.removeById(memoryId);
  }

  /**
   * 按 branchId 删除该 Branch 自产的记忆(继承的不删)。
   * 用于"清除当前分支记忆"功能。
   */
  async clearOwnedByBranch(branchId: string): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.repository.removeOwnedByBranchWithStore(store, branchId);
  }

  /**
   * 使 Branch 中 endPosition >= thresholdPosition 的 Memory 失效(硬删除)。
   * 用于编辑消息或切换 Swipe 后使摘要过期。
   * v12 推荐使用 softInvalidateFromPosition 进行软失效。
   */
  async invalidateFromPosition(branchId: string, thresholdPosition: number): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.repository.invalidateFromPositionWithStore(store, branchId, thresholdPosition);
  }

  /**
   * v12: 软失效 Branch 中 endPosition >= thresholdPosition 的 Memory。
   * 设置 invalidated=1,不删除数据,保留可追溯性。
   * 失效记忆不再注入 Prompt,后台按需重建。
   */
  async softInvalidateFromPosition(branchId: string, thresholdPosition: number): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.repository.softInvalidateFromPositionWithStore(store, branchId, thresholdPosition);
  }

  /**
   * v12: 软失效"覆盖了指定消息位置"的 Memory。
   * 只失效 startPosition <= position <= endPosition 的记忆(该消息落在记忆覆盖范围内),
   * 不误伤范围在指定位置之后的独立章节(章节是过去历史快照)。
   */
  async softInvalidateCoveringPosition(branchId: string, position: number): Promise<void> {
    const store: relationalStore.RdbStore = this.dbHelper.getStore();
    await this.repository.softInvalidateCoveringPositionWithStore(store, branchId, position);
  }

  // ===== 事务内清理(供 ChatPersistenceOperations 调用)=====

  /**
   * 事务内:按 chatId 删除所有 Memory。
   * 用于 Chat 删除时的级联清理。
   */
  async removeByChatIdWithStore(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    await this.repository.removeByChatIdWithStore(store, chatId);
  }

  // ===== Fork 支持(供 ConversationBranchPersistenceService 调用)=====

  /**
   * 事务内:为 fork 复制祖先 Memory 到子 Branch。
   * 只复制 endPosition <= forkPosition 且未失效的祖先 Memory(分叉点之前可用的)。
   * 复制品标记 inheritedFromMemoryId,不删除原 Memory。
   * v12: 保留所有多层记忆字段,invalidated 重置为 false。
   */
  async copyAncestorMemoriesThroughPositionWithStore(
    store: relationalStore.RdbStore,
    sourceBranchId: string,
    childBranchId: string,
    forkPosition: number
  ): Promise<void> {
    await this.repository.copyAncestorMemoriesThroughPositionWithStore(
      store, sourceBranchId, childBranchId, forkPosition
    );
  }
}
