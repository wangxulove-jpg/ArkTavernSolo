/**
 * MemoryTriggerPolicy 记忆触发策略(P3-2③ 自 MemoryService 逐字抽离)
 *
 * 职责:增量总结/章节生成的阈值判定,以及归档边界(最新 chapter/rolling 的 endPosition)解析。
 * 依赖:MemoryPersistenceService / 阈值配置构造期注入(字段与 MemoryService 同名 → 搬运体逐字一致);
 *      世界分组解析 resolveWorldIdByChat 为宿主私有能力,经 MemoryTriggerHost 函数属性回调。
 *
 * v45 归档边界语义:世界分组会话(chatId 非空)同时计入"同会话"的世界共享章节/滚动记忆,
 * 避免 fork 新分支后误判"全部未归档"而重复总结整段对话。
 */

import { ChatMessage } from '../models/ChatMessage';
import {
  ChatMemory,
  MemoryTriggerConfig,
  ChapterTriggerConfig
} from '../models/ChatMemory';
import { MemoryPersistenceService } from './MemoryPersistenceService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MemoryTriggerPolicy';

/** v45: 归档边界解析结果(最新 chapter/rolling 的 endPosition 与其摘要)。 */
export interface ArchivedPosition {
  readonly position: number;
  readonly prevSummary: string;
}

/**
 * 宿主契约:世界分组解析能力(函数属性写法)。
 */
export interface MemoryTriggerHost {
  resolveWorldIdByChat: (chatId: string) => Promise<string>;
}

export class MemoryTriggerPolicy {
  private readonly memoryPersistence: MemoryPersistenceService;
  private readonly triggerConfig: MemoryTriggerConfig;
  private readonly chapterConfig: ChapterTriggerConfig;
  private readonly host: MemoryTriggerHost;

  constructor(
    memoryPersistence: MemoryPersistenceService,
    triggerConfig: MemoryTriggerConfig,
    chapterConfig: ChapterTriggerConfig,
    host: MemoryTriggerHost
  ) {
    this.memoryPersistence = memoryPersistence;
    this.triggerConfig = triggerConfig;
    this.chapterConfig = chapterConfig;
    this.host = host;
  }

  /**
   * 判断是否应该触发增量总结(rolling 模式,旧 API)。
   *
   * @param branchId 当前 Branch ID
   * @param branchMessages 当前 Branch 的全部消息(按 position ASC)
   * @returns true 表示需要触发
   */
  async shouldTriggerSummary(
    branchId: string,
    branchMessages: ChatMessage[]
  ): Promise<boolean> {
    if (branchMessages.length === 0) {
      return false;
    }
    try {
      const latest: ChatMemory | null = await this.memoryPersistence.getLatestByBranch(branchId);
      const summarizedPos: number = latest !== null ? latest.endPosition : -1;
      // 统计未总结的消息数和字符数
      let unsummarizedCount: number = 0;
      let unsummarizedChars: number = 0;
      for (let i = 0; i < branchMessages.length; i++) {
        if (i > summarizedPos) {
          unsummarizedCount++;
          unsummarizedChars += branchMessages[i].content.length;
        }
      }
      if (unsummarizedCount >= this.triggerConfig.messageCountThreshold) {
        return true;
      }
      if (unsummarizedChars >= this.triggerConfig.charLengthThreshold) {
        return true;
      }
      return false;
    } catch (e) {
      Logger.warn(LOG_TAG, 'shouldTriggerSummary failed: ' + String(e));
      return false;
    }
  }

  /**
   * v12: 判断是否应该触发章节生成。
   * 规则:未归档消息数或字符数达到阈值。
   *
   * "未归档"定义:position > 最新 chapter memory 的 endPosition。
   * 若无 chapter memory,则与最新 rolling memory 的 endPosition 比较。
   *
   * v45: 世界分组会话(chatId 非空)同时计入"同会话"的世界共享章节/滚动记忆,
   * 避免 fork 新分支后误判"全部未归档"而重复总结整段对话。
   *
   * @param branchId 当前 Branch ID
   * @param branchMessages 当前 Branch 的全部消息(按 position ASC)
   * @param chatId 当前 Chat ID(v45 世界感知归档边界,默认 '' 不启用)
   * @returns true 表示需要触发章节生成
   */
  async shouldGenerateChapter(
    branchId: string,
    branchMessages: ChatMessage[],
    chatId: string = ''
  ): Promise<boolean> {
    if (branchMessages.length === 0) {
      return false;
    }
    try {
      const archived: ArchivedPosition =
        await this.resolveArchivedPosition(branchId, chatId);
      const archivedPos: number = archived.position;

      let unarchivedCount: number = 0;
      let unarchivedChars: number = 0;
      for (let i = 0; i < branchMessages.length; i++) {
        if (i > archivedPos) {
          unarchivedCount++;
          unarchivedChars += branchMessages[i].content.length;
        }
      }
      if (unarchivedCount >= this.chapterConfig.messageCountThreshold) {
        return true;
      }
      if (unarchivedChars >= this.chapterConfig.charLengthThreshold) {
        return true;
      }
      return false;
    } catch (e) {
      Logger.warn(LOG_TAG, 'shouldGenerateChapter failed: ' + String(e));
      return false;
    }
  }

  /**
   * v45: 解析归档边界(最新 chapter/rolling 的 endPosition)与其摘要。
   * - 优先读本 Branch 的有效记忆
   * - 世界分组会话(chatId 非空)补充"同会话"的世界共享 chapter/rolling
   *   (跨会话 position 不可比,只认本会话;修复 fork 后归档边界丢失)
   */
  async resolveArchivedPosition(
    branchId: string,
    chatId: string
  ): Promise<ArchivedPosition> {
    const allValid: ChatMemory[] = await this.memoryPersistence.listValidByBranch(branchId);
    let archivedPos: number = -1;
    let prevSummary: string = '';
    for (let i = 0; i < allValid.length; i++) {
      const m: ChatMemory = allValid[i];
      if (m.memoryType === 'chapter' || m.memoryType === 'rolling') {
        if (m.endPosition > archivedPos) {
          archivedPos = m.endPosition;
          prevSummary = m.summary;
        }
      }
    }
    if (chatId.length > 0) {
      const worldId: string = await this.host.resolveWorldIdByChat(chatId);
      if (worldId.length > 0) {
        const worldChapters: ChatMemory[] =
          await this.memoryPersistence.listValidByWorldAndType(worldId, 'chapter');
        const worldRolling: ChatMemory[] =
          await this.memoryPersistence.listValidByWorldAndType(worldId, 'rolling');
        for (let i = 0; i < worldChapters.length; i++) {
          const m: ChatMemory = worldChapters[i];
          if (m.chatId === chatId && m.endPosition > archivedPos) {
            archivedPos = m.endPosition;
            prevSummary = m.summary;
          }
        }
        for (let i = 0; i < worldRolling.length; i++) {
          const m: ChatMemory = worldRolling[i];
          if (m.chatId === chatId && m.endPosition > archivedPos) {
            archivedPos = m.endPosition;
            prevSummary = m.summary;
          }
        }
      }
    }
    return { position: archivedPos, prevSummary: prevSummary };
  }
}
