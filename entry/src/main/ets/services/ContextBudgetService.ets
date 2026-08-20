/**
 * ContextBudgetService 上下文预算服务(v8.1)
 *
 * 提供 per-chat 上下文预算配置的存储与读取。
 *
 * 设计:
 * - 配置通过 AppPreferences 存储(数字以字符串形式持久化)
 * - Preferences key 命名:chat_budget_<chatId>_follow / _ctx / _reserved / _auto
 * - v8.2: 默认 followModel=false,使用 customContextWindow=128K(避免新 Chat 默认用满 1M)
 * - 删除聊天时由调用方主动调用 deleteBudget(chatId)
 *
 * 不依赖:
 * - ProviderConfig(由 ChatService 在 updateRequestPlan 中合并)
 * - 数据库 / RDB
 * - ArkUI / 页面
 */

import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';
import {
  ContextBudgetConfig,
  createDefaultContextBudgetConfig,
  DEFAULT_CUSTOM_CONTEXT_WINDOW,
  DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS,
  MIN_CUSTOM_CONTEXT_WINDOW,
  MAX_CUSTOM_CONTEXT_WINDOW,
  MIN_CUSTOM_RESERVED_OUTPUT_TOKENS,
  MAX_CUSTOM_RESERVED_OUTPUT_TOKENS
} from '../models/ContextBudgetConfig';

const LOG_TAG: string = 'ContextBudgetService';

/**
 * 上下文预算服务。
 *
 * 使用方式:
 * - AppServices 持有单例
 * - ChatService 在 updateRequestPlan 中调用 getBudget(chatId) 读取覆盖
 * - ContextBudgetPage 通过 ViewModel 调用修改
 * - 删除聊天时调用 deleteBudget(chatId) 清理
 */
export class ContextBudgetService {
  private readonly preferences: AppPreferences;

  constructor(preferences: AppPreferences) {
    this.preferences = preferences;
  }

  /**
   * 读取指定 Chat 的预算配置。
   * - 未配置过返回默认值(v8.2: followModel=false + customContextWindow=128K)
   * - 字段单独缺失时使用对应默认
   */
  async getBudget(chatId: string): Promise<ContextBudgetConfig> {
    if (chatId.length === 0) {
      return createDefaultContextBudgetConfig();
    }
    try {
      // v8.2: followModel 默认 false(避免新 Chat 默认用满 1M)
      const followStr: string = await this.preferences.getString(
        this.buildKey(chatId, 'follow'), 'false'
      );
      const followModel: boolean = followStr === 'true';

      // customContextWindow
      const ctxStr: string = await this.preferences.getString(
        this.buildKey(chatId, 'ctx'),
        DEFAULT_CUSTOM_CONTEXT_WINDOW.toString()
      );
      const customContextWindow: number = this.clamp(
        this.parseIntSafe(ctxStr, DEFAULT_CUSTOM_CONTEXT_WINDOW),
        MIN_CUSTOM_CONTEXT_WINDOW,
        MAX_CUSTOM_CONTEXT_WINDOW
      );

      // customReservedOutputTokens
      const reservedStr: string = await this.preferences.getString(
        this.buildKey(chatId, 'reserved'),
        DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS.toString()
      );
      const customReserved: number = this.clamp(
        this.parseIntSafe(reservedStr, DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS),
        MIN_CUSTOM_RESERVED_OUTPUT_TOKENS,
        MAX_CUSTOM_RESERVED_OUTPUT_TOKENS
      );

      // autoManage 默认 true
      const autoStr: string = await this.preferences.getString(
        this.buildKey(chatId, 'auto'), 'true'
      );
      const autoManage: boolean = autoStr === 'true';

      return {
        followModel,
        customContextWindow,
        customReservedOutputTokens: customReserved,
        autoManage
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'getBudget failed: ' + String(e));
      return createDefaultContextBudgetConfig();
    }
  }

  /**
   * 设置是否跟随模型配置。
   */
  async setFollowModel(chatId: string, follow: boolean): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    try {
      await this.preferences.putString(
        this.buildKey(chatId, 'follow'), follow ? 'true' : 'false'
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'setFollowModel failed: ' + String(e));
    }
  }

  /**
   * 设置自定义上下文窗口大小。
   * 自动 clamp 到 [MIN, MAX]。
   */
  async setCustomContextWindow(chatId: string, value: number): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    const clamped: number = this.clamp(
      value,
      MIN_CUSTOM_CONTEXT_WINDOW,
      MAX_CUSTOM_CONTEXT_WINDOW
    );
    try {
      await this.preferences.putString(
        this.buildKey(chatId, 'ctx'), clamped.toString()
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'setCustomContextWindow failed: ' + String(e));
    }
  }

  /**
   * 设置自定义预留输出 Token。
   * 自动 clamp 到 [MIN, MAX]。
   */
  async setCustomReservedOutputTokens(chatId: string, value: number): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    const clamped: number = this.clamp(
      value,
      MIN_CUSTOM_RESERVED_OUTPUT_TOKENS,
      MAX_CUSTOM_RESERVED_OUTPUT_TOKENS
    );
    try {
      await this.preferences.putString(
        this.buildKey(chatId, 'reserved'), clamped.toString()
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'setCustomReservedOutputTokens failed: ' + String(e));
    }
  }

  /**
   * 设置是否自动管理上下文(超限时自动裁剪)。
   */
  async setAutoManage(chatId: string, auto: boolean): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    try {
      await this.preferences.putString(
        this.buildKey(chatId, 'auto'), auto ? 'true' : 'false'
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'setAutoManage failed: ' + String(e));
    }
  }

  /**
   * 恢复默认值(v8.2: followModel=false + customContextWindow=128K + autoManage=true)。
   * 清除 follow / ctx / reserved / auto 全部字段,下次读取时返回默认值。
   */
  async resetToDefault(chatId: string): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    try {
      // v8.2: 默认 followModel=false(避免新 Chat 默认用满 1M)
      await this.preferences.putString(this.buildKey(chatId, 'follow'), 'false');
      await this.preferences.putString(
        this.buildKey(chatId, 'ctx'),
        DEFAULT_CUSTOM_CONTEXT_WINDOW.toString()
      );
      await this.preferences.putString(
        this.buildKey(chatId, 'reserved'),
        DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS.toString()
      );
      await this.preferences.putString(this.buildKey(chatId, 'auto'), 'true');
    } catch (e) {
      Logger.warn(LOG_TAG, 'resetToDefault failed: ' + String(e));
    }
  }

  /**
   * 删除指定 Chat 的全部预算配置(删除聊天时调用)。
   */
  async deleteBudget(chatId: string): Promise<void> {
    if (chatId.length === 0) {
      return;
    }
    try {
      await this.preferences.delete(this.buildKey(chatId, 'follow'));
      await this.preferences.delete(this.buildKey(chatId, 'ctx'));
      await this.preferences.delete(this.buildKey(chatId, 'reserved'));
      await this.preferences.delete(this.buildKey(chatId, 'auto'));
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteBudget failed: ' + String(e));
    }
  }

  /**
   * 构造 Preferences key:chat_budget_<chatId>_<suffix>
   */
  private buildKey(chatId: string, suffix: string): string {
    return 'chat_budget_' + chatId + '_' + suffix;
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

  /**
   * 安全解析整数字符串,失败返回默认值。
   */
  private parseIntSafe(value: string, defValue: number): number {
    if (value.length === 0) {
      return defValue;
    }
    const parsed: number = parseInt(value, 10);
    if (isNaN(parsed)) {
      return defValue;
    }
    return parsed;
  }
}
