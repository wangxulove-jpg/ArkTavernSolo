/**
 * MemoryLoadRefService 按需加载记忆引用服务(v46)
 *
 * 职责:
 * - 持久化"当前会话已按需加载的记忆引用"(memoryId + 锚点消息 ID)
 * - 锚点机制:加载时记录当时历史末尾消息 ID,后续构建请求时在锚点之后插入记忆块,
 *   新对话自然续在其后 → 前缀缓存命中保持
 * - 存储基于 AppPreferences(key: chat_memrefs_<chatId>,值为 MemoryLoadRef JSON 数组)
 * - 退出会话/杀进程后引用不丢失(满足"退出会话不导致记忆索引丢失")
 *
 * 设计约束:
 * - 不依赖 ArkUI
 * - JSON 解析失败返回空列表,不抛错
 * - 同一 memoryId 只保留一条引用(重复添加时更新锚点)
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'MemoryLoadRef';

/** 单条按需加载引用 */
export interface MemoryLoadRef {
  /** 被加载的记忆 ID(chapter/session) */
  readonly memoryId: string;
  /** 加载时的历史末尾消息 ID(注入锚点) */
  readonly anchorMessageId: string;
  /** 添加时间(ms) */
  readonly addedAt: number;
}

/** 单会话引用总量上限(防爆上下文) */
export const MEMORY_LOAD_REF_LIMIT: number = 16;

export class MemoryLoadRefService {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /** 读取会话的全部引用(JSON 损坏返回空数组)。 */
  async getRefs(chatId: string): Promise<MemoryLoadRef[]> {
    if (chatId.length === 0) {
      return [];
    }
    try {
      const raw: string = await this.preferences.getString(this.key(chatId), '[]');
      return MemoryLoadRefService.parseRefsJson(raw);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getRefs failed: ' + String(e));
      return [];
    }
  }

  /**
   * 添加引用(同 memoryId 去重:已存在时更新锚点与时间)。
   * 超过总量上限时返回 false(调用方提示/记录日志)。
   */
  async addRef(chatId: string, memoryId: string, anchorMessageId: string): Promise<boolean> {
    if (chatId.length === 0 || memoryId.length === 0) {
      return false;
    }
    try {
      const refs: MemoryLoadRef[] = await this.getRefs(chatId);
      const now: number = Date.now();
      const existingIdx: number = refs.findIndex(
        (r: MemoryLoadRef): boolean => r.memoryId === memoryId
      );
      if (existingIdx >= 0) {
        const updated: MemoryLoadRef[] = refs.slice();
        updated[existingIdx] = { memoryId: memoryId, anchorMessageId: anchorMessageId, addedAt: now };
        await this.saveRefs(chatId, updated);
        return true;
      }
      if (refs.length >= MEMORY_LOAD_REF_LIMIT) {
        Logger.warn(LOG_TAG, 'addRef refused: refs limit reached chatId=' + chatId.length
          + ' limit=' + MEMORY_LOAD_REF_LIMIT.toString());
        return false;
      }
      refs.push({ memoryId: memoryId, anchorMessageId: anchorMessageId, addedAt: now });
      await this.saveRefs(chatId, refs);
      return true;
    } catch (e) {
      Logger.warn(LOG_TAG, 'addRef failed: ' + String(e));
      return false;
    }
  }

  /** 移除引用(取消引用)。 */
  async removeRef(chatId: string, memoryId: string): Promise<void> {
    if (chatId.length === 0 || memoryId.length === 0) {
      return;
    }
    try {
      const refs: MemoryLoadRef[] = await this.getRefs(chatId);
      const remaining: MemoryLoadRef[] = refs.filter(
        (r: MemoryLoadRef): boolean => r.memoryId !== memoryId
      );
      if (remaining.length !== refs.length) {
        await this.saveRefs(chatId, remaining);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'removeRef failed: ' + String(e));
    }
  }

  /** 是否已引用指定记忆。 */
  async hasRef(chatId: string, memoryId: string): Promise<boolean> {
    const refs: MemoryLoadRef[] = await this.getRefs(chatId);
    return refs.some((r: MemoryLoadRef): boolean => r.memoryId === memoryId);
  }

  /** 清空会话引用。 */
  async clearRefs(chatId: string): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    try {
      await this.preferences.delete(this.key(chatId));
    } catch (e) {
      Logger.warn(LOG_TAG, 'clearRefs failed: ' + String(e));
    }
  }

  private key(chatId: string): string {
    return 'chat_memrefs_' + chatId;
  }

  private async saveRefs(chatId: string, refs: MemoryLoadRef[]): Promise<void> {
    await this.preferences.putString(this.key(chatId), JSON.stringify(refs));
  }

  /** JSON 安全解析(损坏返回空数组)。 */
  private static parseRefsJson(raw: string): MemoryLoadRef[] {
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      const arr: Object[] = parsed as Object[];
      const result: MemoryLoadRef[] = [];
      for (let i = 0; i < arr.length; i++) {
        const item: Record<string, Object> = arr[i] as Record<string, Object>;
        const memoryId: Object | undefined = item['memoryId'];
        const anchorMessageId: Object | undefined = item['anchorMessageId'];
        const addedAt: Object | undefined = item['addedAt'];
        if (typeof memoryId === 'string' && typeof anchorMessageId === 'string') {
          result.push({
            memoryId: memoryId,
            anchorMessageId: anchorMessageId,
            addedAt: typeof addedAt === 'number' ? addedAt : 0
          });
        }
      }
      return result;
    } catch (_e) {
      return [];
    }
  }
}
