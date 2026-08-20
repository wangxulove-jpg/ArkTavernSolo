/**
 * ContextBudgetViewModel 上下文预算管理页面状态(v8.1)
 *
 * 职责:
 * - 加载/保存 per-chat 上下文预算配置
 * - 加载当前模型配置(contextWindow 上限)
 * - 估算当前 Prompt 各分段 Token 占用
 * - 提供恢复默认值
 *
 * 数据流:
 * - 通过 ContextBudgetService 操作 per-chat 配置
 * - 通过 ModelService.getCurrentConfig 获取模型上限
 * - 通过 TokenCounter + ContextBudgetEstimator 估算分段占用
 *   (messages + budget 来自外部传入的 ChatService 快照,避免页面层直接持有 ChatService)
 */

import { ContextBudgetService } from '../services/ContextBudgetService';
import { ModelService } from '../services/ModelService';
import { TokenCounter } from '../services/TokenCounter';
import {
  ContextBudgetEstimator,
  ContextBudgetStats,
  BudgetLevel,
  classifyBudgetLevel
} from '../services/ContextBudgetEstimator';
import {
  ContextBudgetConfig,
  DEFAULT_CUSTOM_CONTEXT_WINDOW,
  DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS,
  MIN_CUSTOM_CONTEXT_WINDOW,
  MAX_CUSTOM_CONTEXT_WINDOW,
  MIN_CUSTOM_RESERVED_OUTPUT_TOKENS,
  MAX_CUSTOM_RESERVED_OUTPUT_TOKENS,
  BUDGET_SAFETY_MARGIN
} from '../models/ContextBudgetConfig';
import { getModelCapability, ModelCapability } from '../models/ModelCapabilities';
import { TokenBudget } from '../models/TokenBudget';
import { ProviderConfig } from '../models/ProviderConfig';
import { ChatMessage } from '../models/ChatMessage';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'BudgetVM';

@Observed
export class ContextBudgetViewModel {
  /** 当前 Chat ID */
  chatId: string = '';
  /** Per-chat 预算配置 */
  config: ContextBudgetConfig = {
    followModel: false,
    customContextWindow: DEFAULT_CUSTOM_CONTEXT_WINDOW,
    customReservedOutputTokens: DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS,
    autoManage: true
  };
  /** 当前模型配置(null 表示无 Provider 配置) */
  currentConfig: ProviderConfig | null = null;
  /** 模型上下文上限(用于 UI 显示与 clamp 输入,来自 ProviderConfig 或 ModelCapability) */
  modelContextWindow: number = DEFAULT_CUSTOM_CONTEXT_WINDOW;
  /** 模型默认预留输出(来自 ProviderConfig.maxTokens) */
  modelReservedOutput: number = DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS;
  /** 模型最大输出能力上限(来自 ModelCapability,用于 clamp reserved 上限) */
  modelReservedOutputLimit: number = MAX_CUSTOM_RESERVED_OUTPUT_TOKENS;
  /** 当前生效的 TokenBudget(最近一次构建的) */
  currentBudget: TokenBudget | undefined = undefined;
  /** 当前生效的请求消息(最近一次构建的) */
  currentRequestMessages: ChatMessage[] | undefined = undefined;
  /** 分段统计(基于 currentRequestMessages + currentBudget) */
  stats: ContextBudgetStats | null = null;
  /** 加载中 */
  isLoading: boolean = true;
  /** 操作进行中 */
  isOperating: boolean = false;
  /** 错误信息 */
  errorMessage: string = '';
  /** 状态消息 */
  statusMessage: string = '';

  private budgetService: ContextBudgetService;
  private modelService: ModelService;
  private tokenCounter: TokenCounter;
  private estimator: ContextBudgetEstimator;
  private disposed: boolean = false;

  constructor(
    budgetService: ContextBudgetService,
    modelService: ModelService,
    tokenCounter: TokenCounter
  ) {
    this.budgetService = budgetService;
    this.modelService = modelService;
    this.tokenCounter = tokenCounter;
    this.estimator = new ContextBudgetEstimator(tokenCounter);
  }

  /**
   * 初始化:加载配置 + 模型信息 + 估算。
   */
  async initialize(chatId: string): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.chatId = chatId;
    this.isLoading = true;
    this.errorMessage = '';
    try {
      // 并行加载:per-chat 配置 + 模型配置(ArkTS 不支持解构声明,顺序 await)
      const budget = await this.budgetService.getBudget(chatId);
      const currentConfig = await this.modelService.getCurrentConfig();

      this.config = budget;
      this.currentConfig = currentConfig;
      if (currentConfig !== null) {
        // v8.2: 优先用 ModelCapability 提供的模型上下文上限(DeepSeek-V4-Flash = 1M)
        // 若模型在能力表内且 ProviderConfig 未显式配置 contextWindow,使用能力表值
        const capability: ModelCapability | null = getModelCapability(currentConfig.modelName);
        if (capability !== null) {
          this.modelContextWindow = currentConfig.contextWindow !== undefined
            ? currentConfig.contextWindow
            : capability.contextWindow;
          this.modelReservedOutputLimit = capability.maxOutputTokensLimit;
          // modelReservedOutput 仍取 ProviderConfig.maxTokens(用户在 ModelConfigEditPage 配置的值)
          this.modelReservedOutput = currentConfig.maxTokens !== undefined
            ? currentConfig.maxTokens : DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS;
        } else {
          // 未知模型:ProviderConfig 未配置时用默认 32K
          this.modelContextWindow = currentConfig.contextWindow !== undefined
            ? currentConfig.contextWindow : DEFAULT_CUSTOM_CONTEXT_WINDOW;
          this.modelReservedOutputLimit = MAX_CUSTOM_RESERVED_OUTPUT_TOKENS;
          this.modelReservedOutput = currentConfig.maxTokens !== undefined
            ? currentConfig.maxTokens : DEFAULT_CUSTOM_RESERVED_OUTPUT_TOKENS;
        }
      }

      // 估算
      this.refreshStats();
    } catch (e) {
      this.errorMessage = '加载失败';
      Logger.error(LOG_TAG, 'initialize failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * 刷新分段统计(不重新加载配置)。
   * 由外部(ChatPage)在 prompt 重建后调用 refreshFromSnapshot。
   */
  refreshStats(): void {
    if (this.currentRequestMessages === undefined) {
      this.stats = null;
      return;
    }
    try {
      this.stats = this.estimator.estimate(
        this.currentRequestMessages, this.currentBudget
      );
    } catch (e) {
      Logger.warn(LOG_TAG, 'refreshStats failed: ' + String(e));
      this.stats = null;
    }
  }

  /**
   * 从外部 ChatService 快照更新预算与请求消息,并刷新统计。
   * 由 ChatPage 在 aboutToAppear / 消息变更 / 分支切换时调用。
   */
  async refreshFromSnapshot(
    budget: TokenBudget | undefined,
    requestMessages: ChatMessage[] | undefined
  ): Promise<void> {
    this.currentBudget = budget;
    this.currentRequestMessages = requestMessages;
    this.refreshStats();
  }

  /**
   * 切换 followModel。
   */
  async setFollowModel(follow: boolean): Promise<void> {
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.budgetService.setFollowModel(this.chatId, follow);
      this.config = {
        followModel: follow,
        customContextWindow: this.config.customContextWindow,
        customReservedOutputTokens: this.config.customReservedOutputTokens,
        autoManage: this.config.autoManage
      };
      this.statusMessage = follow ? '已切换为跟随模型' : '已切换为自定义';
      this.notifyConfigChanged();
    } catch (e) {
      this.errorMessage = '保存失败';
      Logger.error(LOG_TAG, 'setFollowModel failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 设置自定义上下文窗口大小。
   * 不超过模型上限(this.modelContextWindow)。
   */
  async setCustomContextWindow(value: number): Promise<void> {
    if (this.isOperating) {
      return;
    }
    const clamped: number = this.clampContextWindow(value);
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.budgetService.setCustomContextWindow(this.chatId, clamped);
      this.config = {
        followModel: this.config.followModel,
        customContextWindow: clamped,
        customReservedOutputTokens: this.config.customReservedOutputTokens,
        autoManage: this.config.autoManage
      };
      this.statusMessage = '已保存上下文窗口';
      this.notifyConfigChanged();
    } catch (e) {
      this.errorMessage = '保存失败';
      Logger.error(LOG_TAG, 'setCustomContextWindow failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 设置自定义预留输出 Token。
   */
  async setCustomReservedOutputTokens(value: number): Promise<void> {
    if (this.isOperating) {
      return;
    }
    const clamped: number = this.clampReserved(value);
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.budgetService.setCustomReservedOutputTokens(this.chatId, clamped);
      this.config = {
        followModel: this.config.followModel,
        customContextWindow: this.config.customContextWindow,
        customReservedOutputTokens: clamped,
        autoManage: this.config.autoManage
      };
      this.statusMessage = '已保存预留输出 Token';
      this.notifyConfigChanged();
    } catch (e) {
      this.errorMessage = '保存失败';
      Logger.error(LOG_TAG, 'setCustomReservedOutputTokens failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 切换 autoManage。
   */
  async setAutoManage(auto: boolean): Promise<void> {
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.budgetService.setAutoManage(this.chatId, auto);
      this.config = {
        followModel: this.config.followModel,
        customContextWindow: this.config.customContextWindow,
        customReservedOutputTokens: this.config.customReservedOutputTokens,
        autoManage: auto
      };
      this.statusMessage = auto ? '已启用自动管理' : '已关闭自动管理';
      this.notifyConfigChanged();
    } catch (e) {
      this.errorMessage = '保存失败';
      Logger.error(LOG_TAG, 'setAutoManage failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 恢复默认值。
   */
  async resetToDefault(): Promise<void> {
    if (this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.budgetService.resetToDefault(this.chatId);
      const fresh = await this.budgetService.getBudget(this.chatId);
      this.config = fresh;
      this.statusMessage = '已恢复默认值';
      this.notifyConfigChanged();
    } catch (e) {
      this.errorMessage = '恢复失败';
      Logger.error(LOG_TAG, 'resetToDefault failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  /**
   * 计算当前状态级别(供 UI 颜色)。
   */
  get currentLevel(): BudgetLevel {
    if (this.stats === null) {
      return BudgetLevel.Normal;
    }
    return classifyBudgetLevel(this.stats.usageRatio);
  }

  /**
   * 获取当前生效的 contextWindow(根据 followModel)。
   */
  get effectiveContextWindow(): number {
    return this.config.followModel
      ? this.modelContextWindow
      : this.config.customContextWindow;
  }

  /**
   * 获取当前生效的 reservedOutputTokens。
   */
  get effectiveReserved(): number {
    return this.config.followModel
      ? this.modelReservedOutput
      : this.config.customReservedOutputTokens;
  }

  /**
   * 获取输入可用预算。
   * v8.2: 扣除安全余量(用于 Token 估算误差和 Provider 包装)
   *   输入可用预算 = effectiveContextWindow - effectiveReserved - BUDGET_SAFETY_MARGIN
   */
  get effectiveAvailable(): number {
    const ctx: number = this.effectiveContextWindow;
    const rsv: number = this.effectiveReserved;
    const available: number = ctx - rsv - BUDGET_SAFETY_MARGIN;
    return available > 0 ? available : 0;
  }

  /**
   * v8.2: 自定义预留输出 Slider 的上限。
   * = min(modelReservedOutputLimit, effectiveContextWindow - BUDGET_SAFETY_MARGIN)
   * 用于 UI 显示与 Slider max 参数。
   */
  getCustomReservedSliderMax(): number {
    const hardMax: number = Math.min(
      MAX_CUSTOM_RESERVED_OUTPUT_TOKENS,
      this.modelReservedOutputLimit
    );
    const ctxBound: number = this.effectiveContextWindow - BUDGET_SAFETY_MARGIN;
    const finalMax: number = Math.min(hardMax, ctxBound);
    return finalMax > MIN_CUSTOM_RESERVED_OUTPUT_TOKENS
      ? finalMax
      : MIN_CUSTOM_RESERVED_OUTPUT_TOKENS;
  }

  clearStatusMessage(): void {
    this.statusMessage = '';
  }

  clearErrorMessage(): void {
    this.errorMessage = '';
  }

  dispose(): void {
    this.disposed = true;
  }

  // ===== 内部工具 =====

  /**
   * clamp 自定义上下文窗口:
   * - 下限 MIN_CUSTOM_CONTEXT_WINDOW(4K)
   * - 上限 modelContextWindow(模型实际上限,如 DeepSeek-V4-Flash = 1M)
   *   (MAX_CUSTOM_CONTEXT_WINDOW=1M 与 modelContextWindow 取较小值)
   * v8.2: 不再 clamp 到固定 32K
   */
  private clampContextWindow(value: number): number {
    const min: number = MIN_CUSTOM_CONTEXT_WINDOW;
    const max: number = Math.min(MAX_CUSTOM_CONTEXT_WINDOW, this.modelContextWindow);
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }

  /**
   * clamp 自定义预留输出:
   * - 下限 MIN_CUSTOM_RESERVED_OUTPUT_TOKENS(256)
   * - 上限 modelReservedOutputLimit(模型最大输出能力,如 DeepSeek-V4-Flash = 384K)
   *   且不得超过 effectiveContextWindow(避免 reserved > context 导致输入预算为 0)
   */
  private clampReserved(value: number): number {
    if (value < MIN_CUSTOM_RESERVED_OUTPUT_TOKENS) {
      return MIN_CUSTOM_RESERVED_OUTPUT_TOKENS;
    }
    const hardMax: number = Math.min(
      MAX_CUSTOM_RESERVED_OUTPUT_TOKENS,
      this.modelReservedOutputLimit
    );
    // 最大输出不得超过当前上下文(否则输入预算为 0)
    const ctxBound: number = this.effectiveContextWindow - BUDGET_SAFETY_MARGIN;
    const finalMax: number = Math.min(hardMax, ctxBound);
    if (value > finalMax) {
      return finalMax;
    }
    return value;
  }

  /**
   * 通知其他页面(ChatPage)预算配置已变更,触发重算。
   */
  private notifyConfigChanged(): void {
    const v: number = AppStorage.get<number>('chatBudgetConfigVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatBudgetConfigVersion', v + 1);
  }
}
