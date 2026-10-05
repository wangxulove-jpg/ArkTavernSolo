/**
 * ChatMemoryModeService 会话级记忆模式服务(v50)
 *
 * 提供 per-chat 记忆模式的存储与读取:
 * - mode: 'manual'(手动章节总结,现状默认) / 'auto'(自动章节归档)
 * - chapterInjectCount: 注入最近章节数(1-20,默认 4)
 *
 * 设计(照 ContextBudgetService 的 Preferences 模式):
 * - 配置通过 AppPreferences 存储(字符串形式持久化)
 * - Preferences key 命名:chat_memory_<chatId>_mode / _chapters
 * - 会话未显式设置 mode 时回退全局 memory_auto_summary_enabled 开关
 *   (开 → 'auto',关 → 'manual',兼容旧版全局自动总结行为)
 * - 删除聊天时由调用方主动调用 deleteMemoryMode(chatId)
 *
 * 缓存设计:
 * - 'auto' 模式走 MemoryService.tryAutoChapterMemory(只追加章节,
 *   不回退 rolling 覆盖),章节追加仅一次性重建缓存前缀,之后稳定
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatMemoryModeService';

/**
 * 全局自动总结开关 Preferences key(与 ChatService.MEMORY_AUTO_SUMMARY_PREFS_KEY
 * 同值;本地定义以避免与 ChatService 的循环 import)。
 */
const GLOBAL_AUTO_SUMMARY_PREFS_KEY: string = 'memory_auto_summary_enabled';

/** 会话记忆模式 */
export type ChatMemoryMode = 'manual' | 'auto';

/** 注入最近章节数下限 */
export const MIN_CHAPTER_INJECT_COUNT: number = 1;
/** 注入最近章节数上限 */
export const MAX_CHAPTER_INJECT_COUNT: number = 20;
/** 注入最近章节数默认值(与 MemoryService.DEFAULT_CHAPTER_TRIGGER 一致) */
export const DEFAULT_CHAPTER_INJECT_COUNT: number = 4;

export class ChatMemoryModeService {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 读取指定 Chat 的记忆模式。
   * - 未显式设置时回退全局 memory_auto_summary_enabled 开关(兼容旧版)
   * - 空 chatId 返回 'manual'
   */
  async getMemoryMode(chatId: string): Promise<ChatMemoryMode> {
    if (chatId.length === 0) {
      return 'manual';
    }
    try {
      const val: string = await this.preferences.getString(
        this.buildKey(chatId, 'mode'), ''
      );
      if (val === 'manual' || val === 'auto') {
        return val;
      }
      // 未设置:回退全局开关
      const globalVal: string = await this.preferences.getString(
        GLOBAL_AUTO_SUMMARY_PREFS_KEY, 'false'
      );
      return globalVal === 'true' ? 'auto' : 'manual';
    } catch (e) {
      Logger.warn(LOG_TAG, 'getMemoryMode failed: ' + String(e));
      return 'manual';
    }
  }

  /**
   * 设置指定 Chat 的记忆模式并持久化。
   */
  async setMemoryMode(chatId: string, mode: ChatMemoryMode): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    try {
      await this.preferences.putString(this.buildKey(chatId, 'mode'), mode);
    } catch (e) {
      Logger.warn(LOG_TAG, 'setMemoryMode failed: ' + String(e));
    }
  }

  /**
   * 读取指定 Chat 的"注入最近章节数"(1-20,默认 4)。
   */
  async getChapterInjectCount(chatId: string): Promise<number> {
    if (chatId.length === 0) {
      return DEFAULT_CHAPTER_INJECT_COUNT;
    }
    try {
      const val: string = await this.preferences.getString(
        this.buildKey(chatId, 'chapters'), ''
      );
      if (val.length === 0) {
        return DEFAULT_CHAPTER_INJECT_COUNT;
      }
      const parsed: number = parseInt(val, 10);
      if (isNaN(parsed)) {
        return DEFAULT_CHAPTER_INJECT_COUNT;
      }
      return this.clamp(parsed, MIN_CHAPTER_INJECT_COUNT, MAX_CHAPTER_INJECT_COUNT);
    } catch (e) {
      Logger.warn(LOG_TAG, 'getChapterInjectCount failed: ' + String(e));
      return DEFAULT_CHAPTER_INJECT_COUNT;
    }
  }

  /**
   * 设置指定 Chat 的"注入最近章节数"(自动 clamp 到 [1, 20])。
   */
  async setChapterInjectCount(chatId: string, value: number): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    const clamped: number = this.clamp(
      value, MIN_CHAPTER_INJECT_COUNT, MAX_CHAPTER_INJECT_COUNT
    );
    try {
      await this.preferences.putString(
        this.buildKey(chatId, 'chapters'), clamped.toString()
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'setChapterInjectCount failed: ' + String(e));
    }
  }

  /**
   * v51: 读取会话记忆"激活边界"(已归档并被激活注入的最大消息 position)。
   *
   * 语义(延迟激活核心):
   * - 返回 undefined 表示"未初始化"(首次运行新逻辑):调用方按当前实际章节边界初始化
   * - 返回 -1 表示"已初始化且尚无已激活章节"（全文窗口,等价于未总结）
   * - 返回 N>=0 表示 endPosition <= N 的章节已激活注入,窗口锚点也以此为界
   *
   * 未激活章节仍写库但不进 prompt、不移动锚点 → 聊天请求前缀保持稳定,缓存命中。
   */
  async getActiveBoundary(chatId: string): Promise<number | undefined> {
    if (chatId.length === 0) {
      return -1;
    }
    try {
      const val: string = await this.preferences.getString(
        this.buildKey(chatId, 'aboundary'), ''
      );
      if (val.length === 0) {
        return undefined;
      }
      const parsed: number = parseInt(val, 10);
      if (isNaN(parsed)) {
        return undefined;
      }
      return parsed;
    } catch (e) {
      Logger.warn(LOG_TAG, 'getActiveBoundary failed: ' + String(e));
      return undefined;
    }
  }

  /**
   * v51: 设置会话记忆"激活边界"并持久化(激活流程调用)。
   */
  async setActiveBoundary(chatId: string, value: number): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    try {
      await this.preferences.putString(this.buildKey(chatId, 'aboundary'), value.toString());
    } catch (e) {
      Logger.warn(LOG_TAG, 'setActiveBoundary failed: ' + String(e));
    }
  }

  /**
   * 删除指定 Chat 的全部记忆模式配置(删除聊天时调用)。
   */
  async deleteMemoryMode(chatId: string): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    try {
      await this.preferences.delete(this.buildKey(chatId, 'mode'));
      await this.preferences.delete(this.buildKey(chatId, 'chapters'));
      await this.preferences.delete(this.buildKey(chatId, 'aboundary'));
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteMemoryMode failed: ' + String(e));
    }
  }

  /**
   * 构造 Preferences key:chat_memory_<chatId>_<suffix>
   */
  private buildKey(chatId: string, suffix: string): string {
    return 'chat_memory_' + chatId + '_' + suffix;
  }

  private clamp(value: number, min: number, max: number): number {
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}
