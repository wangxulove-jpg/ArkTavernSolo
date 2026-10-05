/**
 * ChatContextMaintenanceService 上下文维护簇(记忆总结 / 记忆失效 / 世界书激活刷新)(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 成员整块搬出):
 * - 手动记忆总结:triggerManualMemorySummary(强制生成章节并刷新世界书激活)
 * - 自动记忆总结触发:triggerMemorySummaryAsync + handleBackgroundMemoryResult
 * - 记忆失效:invalidateMemoryFromMessagePosition(软失效覆盖位置的记忆)
 * - 世界书激活刷新:refreshLorebookPinAsync / refreshLorebookStickyAsync / refreshLorebookPinNow
 * - 自动总结开关:memoryAutoSummaryEnabled(自带状态)+ set/is + loadMemoryAutoSummaryPref
 * - 变更通知:notifyMemoryChanged(递增 chatMemoryVersion)
 *
 * 依赖与宿主(ArkTS 说明):
 * - 六服务(记忆/会话模式/世界书三件套/偏好)经构造函数注入(只读引用,与 ChatService 同批装配);
 *   会话侧状态(currentChatId / activeBranchId / messages / character / lorebookActivationDefault)
 *   经 ChatContextHost 函数属性回调读取——与搬运前 this.xxx 语义一致;类内同名 getter/方法转发,
 *   使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ChatContextMaintenanceService(仅日志来源标注变化);
 *   3 个原 private 方法因跨类调用改为 public(方法体未动,已记录)。
 */

import { ChatMessage } from '../models/ChatMessage';
import { Character } from '../models/Character';
import { Lorebook, LorebookActivationMode } from '../models/Lorebook';
import { MemoryService, MemorySummaryResult } from './MemoryService';
import { ChatMemoryModeService, ChatMemoryMode } from './ChatMemoryModeService';
import { LorebookService } from './LorebookService';
import { LorebookPinService } from './LorebookPinService';
import { LorebookStickyService } from './LorebookStickyService';
import { AppPreferences } from '../storage/AppPreferences';
import { MEMORY_AUTO_SUMMARY_PREFS_KEY } from './ChatTextContract';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatContextMaintenanceService';

/** 上下文维护依赖(全部为只读引用,null 表示未装配) */
export interface ChatContextDeps {
  /** 记忆服务(章节生成 / 软失效 / 多层回退) */
  memoryService: MemoryService | null;
  /** v50: 会话级记忆模式服务(manual/auto) */
  chatMemoryModeService: ChatMemoryModeService | null;
  /** 世界书服务(角色绑定书读取) */
  lorebookService: LorebookService | null;
  /** v45: 世界书按需钉选服务 */
  lorebookPinService: LorebookPinService | null;
  /** v46: 世界书粘滞服务 */
  lorebookStickyService: LorebookStickyService | null;
  /** 全局偏好(自动总结开关持久化) */
  appPreferences: AppPreferences | null;
}

/**
 * 宿主回调:会话侧状态读取。
 * 读取即最新(与搬运前 this.xxx 语义一致),不含写入。
 */
export interface ChatContextHost {
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 当前活动 Branch ID(空串=未启用分支) */
  getActiveBranchId: () => string;
  /** 当前消息列表(按时间正序;调用方不得修改返回值) */
  getMessages: () => ChatMessage[];
  /** 当前角色卡(可能为 null) */
  getCharacter: () => Character | null;
  /** 世界书全局默认激活方式 */
  getLorebookActivationDefault: () => LorebookActivationMode;
  /**
   * v51: 构建"聊天请求基座"消息(与聊天请求逐字节一致),用于记忆总结的"后缀扩展"。
   * 返回 undefined 表示基座不可用(失败/无会话),调用方回退独立 prompt。
   * 实现方需保证:重建后的消息与下一次聊天请求前缀一致,且不修改共享状态。
   */
  buildSummaryBaseMessages: () => Promise<ChatMessage[] | undefined>;
}

export class ChatContextMaintenanceService {
  private readonly memoryService: MemoryService | null;
  private readonly chatMemoryModeService: ChatMemoryModeService | null;
  private readonly lorebookService: LorebookService | null;
  private readonly lorebookPinService: LorebookPinService | null;
  private readonly lorebookStickyService: LorebookStickyService | null;
  private readonly appPreferences: AppPreferences | null;
  private readonly host: ChatContextHost;

  // ===== 自带状态(原 ChatService 字段随迁) =====
  /**
   * Prompt Cache 优化:是否启用自动记忆总结。
   * 默认 false(关闭自动总结,保持 Memory 段稳定)。
   * 用户可手动触发记忆总结(手动触发时立即执行一次,然后冻结)。
   */
  private memoryAutoSummaryEnabled: boolean = false;

  constructor(deps: ChatContextDeps, host: ChatContextHost) {
    this.memoryService = deps.memoryService;
    this.chatMemoryModeService = deps.chatMemoryModeService;
    this.lorebookService = deps.lorebookService;
    this.lorebookPinService = deps.lorebookPinService;
    this.lorebookStickyService = deps.lorebookStickyService;
    this.appPreferences = deps.appPreferences;
    this.host = host;
  }

  // ===== 宿主状态读取(同名 getter 转发,保持搬运代码零改写) =====

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private get activeBranchId(): string {
    return this.host.getActiveBranchId();
  }

  private get messages(): ChatMessage[] {
    return this.host.getMessages();
  }

  private get character(): Character | null {
    return this.host.getCharacter();
  }

  private get lorebookActivationDefault(): LorebookActivationMode {
    return this.host.getLorebookActivationDefault();
  }

  // ===== 搬运方法(原 ChatService 成员,逐字搬出) =====

  /**
   * Prompt Cache:手动触发记忆总结。
   * 无论 memoryAutoSummaryEnabled 是否开启,都强制生成一个详细章节并同步更新核心记忆。
   * 总结完成后 Memory 段内容更新,但后续请求中 Memory 段将保持稳定直到下次手动触发。
   */
  triggerManualMemorySummary(): void {
    if (this.memoryService === null) {
      return;
    }
    if (this.currentChatId === undefined || this.currentChatId.length === 0) {
      return;
    }
    if (this.activeBranchId.length === 0) {
      return;
    }
    const chatId: string = this.currentChatId;
    const branchId: string = this.activeBranchId;
    const branchMessages: ChatMessage[] = this.messages.slice();
    const memoryService: MemoryService = this.memoryService;
    // v51: 先构建聊天请求基座(缓存友好:总结请求前缀与聊天请求逐字节一致)
    this.host.buildSummaryBaseMessages()
      .then((base: ChatMessage[] | undefined): Promise<MemorySummaryResult> => {
        return memoryService.forceGenerateChapterMemory(chatId, branchId, branchMessages, base);
      })
      .then((result: MemorySummaryResult): void => {
        if (!result.success) {
          Logger.warn(LOG_TAG, 'ManualMemorySummary | forced chapter failed'
            + (result.error !== undefined ? ' err=' + result.error : ''));
        } else {
          this.notifyMemoryChanged();
          // v8.4: 窗口锚点由章节边界与保留条数动态派生,总结成功后无需额外持久化
          // v45: 手动总结成功后刷新 OnDemandPinned 会话钉选(记忆段与世界书段一起变化)
          this.refreshLorebookPinAsync(chatId, branchMessages);
          // v46: 手动总结成功后刷新 StickyOnDemand 会话粘滞命中(重算全量对话匹配)
          this.refreshLorebookStickyAsync(chatId, branchMessages);
        }
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'ManualMemorySummary | forced chapter exception: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * v45: 手动记忆总结成功后刷新 OnDemandPinned(按需锁定)会话钉选。
   * 按当前角色绑定世界书 + 全部对话消息重新全量关键词匹配,替换原钉选。
   * 后台执行,失败仅记录日志。
   */
  private refreshLorebookPinAsync(chatId: string, messages: ChatMessage[]): void {
    if (this.lorebookPinService === null || this.lorebookService === null) {
      return;
    }
    if (this.character === null || this.character.characterBookId.length === 0) {
      return;
    }
    const bookId: string = this.character.characterBookId;
    this.lorebookService.getById(bookId)
      .then((book: Lorebook | null): Promise<void> => {
        if (book === null || !book.enabled) {
          return Promise.resolve();
        }
        return this.lorebookPinService!.refreshPinnedEntries(chatId, book, messages);
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'ManualMemorySummary | lorebook pin refresh failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * v46: 手动记忆总结成功后刷新 StickyOnDemand(粘滞按需)会话命中。
   * 按当前角色绑定世界书 + 全部对话消息重新全量关键词匹配,整体替换原集合。
   * 后台执行,失败仅记录日志。
   */
  private refreshLorebookStickyAsync(chatId: string, messages: ChatMessage[]): void {
    if (this.lorebookStickyService === null || this.lorebookService === null) {
      return;
    }
    if (this.character === null || this.character.characterBookId.length === 0) {
      return;
    }
    const bookId: string = this.character.characterBookId;
    this.lorebookService.getById(bookId)
      .then((book: Lorebook | null): Promise<void> => {
        if (book === null || !book.enabled) {
          return Promise.resolve();
        }
        return this.lorebookStickyService!.refreshStickyEntries(chatId, book, messages);
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'ManualMemorySummary | lorebook sticky refresh failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /**
   * v45.1: 手动刷新世界书激活内容(OnDemandPinned 按需锁定模式)。
   * 用户切换开场白/生成新章节后调用:按当前会话全部消息重新关键词匹配,
   * 替换 chat_lorebook_pins 钉选记录并落库(刷新后即锁定)。
   * v46: StickyOnDemand 粘滞模式同样支持,按模式分派刷新。
   * @return true=已刷新; false=无可刷新(会话未初始化/无角色书/书未启用/服务不可用/异常)
   */
  async refreshLorebookPinNow(): Promise<boolean> {
    if (this.currentChatId === undefined || this.currentChatId.length === 0
      || this.lorebookService === null
      || (this.lorebookPinService === null && this.lorebookStickyService === null)) {
      return false;
    }
    if (this.character === null || this.character.characterBookId.length === 0) {
      return false;
    }
    try {
      const book: Lorebook | null = await this.lorebookService.getById(this.character.characterBookId);
      if (book === null || !book.enabled) {
        return false;
      }
      const effectiveMode: LorebookActivationMode =
        book.activationMode !== LorebookActivationMode.FollowGlobal
          ? book.activationMode : this.lorebookActivationDefault;
      const messages: ChatMessage[] = this.messages.slice();
      if (effectiveMode === LorebookActivationMode.StickyOnDemand) {
        if (this.lorebookStickyService === null) {
          return false;
        }
        await this.lorebookStickyService.refreshStickyEntries(this.currentChatId, book, messages);
        Logger.info(LOG_TAG, 'ManuallyRefreshLorebookSticky | refreshed chatId=' + this.currentChatId
          + ' book=' + book.id);
        return true;
      }
      if (this.lorebookPinService === null) {
        return false;
      }
      await this.lorebookPinService.refreshPinnedEntries(this.currentChatId, book, messages);
      Logger.info(LOG_TAG, 'ManuallyRefreshLorebookPin | refreshed chatId=' + this.currentChatId
        + ' book=' + book.id);
      return true;
    } catch (e) {
      Logger.warn(LOG_TAG, 'ManuallyRefreshLorebookPin | failed: ' + String(e));
      return false;
    }
  }

  /**
   * Prompt Cache:设置自动记忆总结开关。
   * @param enabled true=每次 AI 回复后自动触发记忆总结(默认行为,不利于缓存)
   *                false=关闭自动总结,用户需手动触发(推荐,有利于缓存)
   */
  setMemoryAutoSummaryEnabled(enabled: boolean): void {
    this.memoryAutoSummaryEnabled = enabled;
    if (this.appPreferences !== null) {
      this.appPreferences.putString(MEMORY_AUTO_SUMMARY_PREFS_KEY, enabled ? 'true' : 'false')
        .then((): void => {}).catch((_e: Object): void => {});
    }
  }

  isMemoryAutoSummaryEnabled(): boolean {
    return this.memoryAutoSummaryEnabled;
  }

  async loadMemoryAutoSummaryPref(): Promise<void> {
    if (this.appPreferences === null) {
      return;
    }
    try {
      const val: string = await this.appPreferences.getString(MEMORY_AUTO_SUMMARY_PREFS_KEY, 'false');
      this.memoryAutoSummaryEnabled = val === 'true';
    } catch (_e) {
      this.memoryAutoSummaryEnabled = false;
    }
  }

  /**
   * 通知记忆变更,触发 ChatPage 重新计算上下文占用。
   * 记忆生成/更新/删除后调用,递增 chatMemoryVersion 让 ChatPage @Watch 响应。
   */
  private notifyMemoryChanged(): void {
    const v: number = AppStorage.get<number>('chatMemoryVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatMemoryVersion', v + 1);
  }

  /**
   * 异步触发长期记忆增量总结。
   *
   * v50: 会话级记忆模式(优先):
   * - 'auto'(自动章节归档): 达章节阈值时调用 tryAutoChapterMemory
   *   只追加章节,**不回退 rolling 覆盖更新**(保缓存前缀)
   * - 'manual'(手动): 不自动总结
   * - 会话未设置时由 ChatMemoryModeService 回退全局 memoryAutoSummaryEnabled 开关
   *
   * 兼容:chatMemoryModeService 为 null(旧测试构造)时走旧全局开关
   * + tryGenerateMultiLayerMemory(章节优先,回退 rolling)。
   *
   * - 失败不抛出,不阻塞已完成状态
   * - 不调用 await,在后台执行
   * - 仅记录触发阶段,不记录消息内容
   */
  triggerMemorySummaryAsync(): void {
    if (this.memoryService === null) {
      return;
    }
    if (this.currentChatId === undefined || this.currentChatId.length === 0) {
      return;
    }
    if (this.activeBranchId.length === 0) {
      return;
    }
    const chatId: string = this.currentChatId;
    const branchId: string = this.activeBranchId;
    const branchMessages: ChatMessage[] = this.messages.slice();
    const memoryService: MemoryService = this.memoryService;
    if (this.chatMemoryModeService !== null) {
      // v50: 会话级记忆模式——'auto' 自动章节归档(不回退 rolling 覆盖,保缓存)
      const modeService: ChatMemoryModeService = this.chatMemoryModeService;
      modeService.getMemoryMode(chatId)
        .then((mode: ChatMemoryMode): Promise<void> => {
          if (mode !== 'auto') {
            return Promise.resolve();
          }
          // v51: 先构建聊天请求基座(缓存友好:总结请求前缀与聊天请求逐字节一致)
          return this.host.buildSummaryBaseMessages()
            .then((base: ChatMessage[] | undefined): Promise<MemorySummaryResult> => {
              return memoryService.tryAutoChapterMemory(chatId, branchId, branchMessages, base);
            })
            .then((result: MemorySummaryResult): void => {
              this.handleBackgroundMemoryResult(result);
            });
        })
        .catch((e: Object): void => {
          Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=exception: '
            + (e instanceof Error ? e.message : String(e)));
        });
      return;
    }
    // 兼容:无会话模式服务时走旧全局开关 + 多层回退(章节优先,回退 rolling)
    if (!this.memoryAutoSummaryEnabled) {
      return;
    }
    memoryService.tryGenerateMultiLayerMemory(chatId, branchId, branchMessages)
      .then((result): void => {
        this.handleBackgroundMemoryResult(result);
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=exception: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }

  /** 后台记忆总结结果处理:失败仅记日志,成功通知记忆变更。 */
  private handleBackgroundMemoryResult(result: MemorySummaryResult): void {
    if (!result.success) {
      Logger.warn(LOG_TAG, 'MemorySummary | triggered kind=failed'
        + (result.error !== undefined ? ' err=' + result.error : ''));
    } else {
      this.notifyMemoryChanged();
    }
  }

  /**
   * v12: 失效指定消息 position 之后的记忆(软失效)。
   * v12: 失效"覆盖了指定消息位置"的记忆(软失效)。
   * 用于 Swipe 切换、Swipe 候选生成完成、重新生成等场景。
   * - 找到 messageId 在 this.messages 中的索引作为 position
   * - 调用 memoryService.softInvalidateCoveringPosition(branchId, position)
   * - 只失效该消息落在记忆覆盖范围内的记忆,不误伤独立的章节历史快照
   * - 失败不阻塞,只记录 warn
   * - 不记录消息内容
   *
   * @param messageId 触发失效的消息 ID(该消息位置所在的记忆范围会被失效)
   */
  invalidateMemoryFromMessagePosition(messageId: string): void {
    if (this.memoryService === null) {
      return;
    }
    if (this.activeBranchId.length === 0) {
      return;
    }
    // 查找消息 position(在 this.messages 中的索引)
    let position: number = -1;
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].id === messageId) {
        position = i;
        break;
      }
    }
    if (position < 0) {
      return;
    }
    const branchId: string = this.activeBranchId;
    // 不 await:后台执行,失败仅记录日志
    this.memoryService.softInvalidateCoveringPosition(branchId, position)
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'MemoryInvalidate | failed: '
          + (e instanceof Error ? e.message : String(e)));
      });
  }
}