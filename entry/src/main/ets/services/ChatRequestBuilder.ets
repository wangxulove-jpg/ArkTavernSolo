/**
 * ChatRequestBuilder 请求构建与注入(自 ChatService 抽离,纯搬运不改行为)
 *
 * 职责(原 ChatService 私有方法整块搬出):
 * - buildRequestMessages:通过 PromptBuilder 组装系统提示 / 世界书 / 记忆 / 历史
 * - autoLoadOnDemandMemories:按需记忆(OnDemand)加载
 * - injectOnDemandMemories:按需记忆按锚点插进对话历史
 * - injectStickyLorebookEntries / appendStickyReminder:粘滞世界书注入与尾部提醒
 *
 * 依赖与宿主(ArkTS 说明):
 * - ChatService 相关成员多为 private,无法用"结构类型直接传 this"的宿主契约,
 *   故:服务依赖经构造函数注入(只读引用,与 ChatService 同批装配);
 *   可变会话状态与宿主私有能力经 ChatRequestHost 回调读取——保持"读取即最新",
 *   与搬运前 this.xxx 的读取时机完全一致;类内以同名的 getter/方法转发,
 *   使搬运代码零改写。
 * - 日志 tag 由 ChatService 改为 ChatRequestBuilder(仅日志来源标注变化)。
 */

import { ChatMessage, createChatMessage, mergeChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatRole } from '../models/ChatRole';
import { Chat } from '../models/Chat';
import { Character } from '../models/Character';
import { Persona } from '../models/Persona';
import { Lorebook, LorebookEntry, LorebookActivationMode } from '../models/Lorebook';
import {
  ContextBudgetConfig,
  DEFAULT_RECENT_WINDOW_TARGET,
  MIN_COMPLETE_TURNS
} from '../models/ContextBudgetConfig';
import { PromptBuilder, PromptBuildContext, PromptBuildResult, MemoryLayersInjection } from './PromptBuilder';
import { MacroContext } from '../models/MacroContext';
import { ContextHistorySelection } from '../models/ContextHistorySelection';
import { ChatMemory } from '../models/ChatMemory';
import { TokenCounter } from './TokenCounter';
import { RecentMessageSelector } from './RecentMessageSelector';
import { LorebookService } from './LorebookService';
import { LorebookPinService } from './LorebookPinService';
import { LorebookStickyService, StickyResolveResult } from './LorebookStickyService';
import { MemoryService } from './MemoryService';
import { MemoryLoadRefService, MemoryLoadRef } from './MemoryLoadRefService';
import { ChatMemoryModeService } from './ChatMemoryModeService';
import { ContextBudgetService } from './ContextBudgetService';
import { EntityIndex, EntityIndexEntry, matchEntityChapterIds, parseEntityIndexJson } from './ChapterMemoryIndexer';
import { buildStickyReminderText, pickHotStickyNames, STICKY_REMINDER_MAX_ITEMS } from './ChatTextContract';
import { ModelService } from './ModelService';
import { PromptPresetService } from './PromptPresetService';
import { ProviderConfig } from '../models/ProviderConfig';
import { PromptPreset, PromptPresetPosition } from '../models/PromptPreset';
import {
  PromptPresetRequestSnapshot,
  EffectiveGenerationSettings,
  resolveEffectiveGenerationSettings,
  createSnapshotWithoutPreset,
  createSnapshotWithPresets
} from './PromptPresetRuntimeResolver';
import { generateUuid } from '../utils/Uuid';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatRequestBuilder';

/** v46: 按需记忆块插入项(insertAfter=-1 表示插到窗口头部) */
interface OnDemandInsert {
  readonly insertAfter: number;
  readonly message: ChatMessage;
}

/** 构建器依赖(全部为只读引用,null 表示未装配) */
export interface ChatRequestBuilderDeps {
  promptBuilder: PromptBuilder | null;
  tokenCounter: TokenCounter | null;
  recentMessageSelector: RecentMessageSelector | null;
  lorebookService: LorebookService | null;
  lorebookPinService: LorebookPinService | null;
  lorebookStickyService: LorebookStickyService | null;
  memoryService: MemoryService | null;
  memoryLoadRefService: MemoryLoadRefService | null;
  chatMemoryModeService: ChatMemoryModeService | null;
  contextBudgetService: ContextBudgetService | null;
  modelService: ModelService;
  promptPresetService: PromptPresetService | null;
}

/**
 * 宿主回调:可变会话状态读取与宿主私有能力。
 * 全部为"读取即最新"语义(与搬运前 this.xxx 一致),不含写入。
 */
export interface ChatRequestHost {
  /** 当前会话(可能为 null) */
  getCurrentChat: () => Chat | null;
  /** 当前会话 id(未初始化时 undefined) */
  getCurrentChatId: () => string | undefined;
  /** 当前角色卡(可能为 null) */
  getCharacter: () => Character | null;
  /** 当前消息列表(按时间正序;调用方不得修改返回值) */
  getMessages: () => ChatMessage[];
  /** 当前分支 id(空串=未启用分支) */
  getActiveBranchId: () => string;
  /** 世界书全局默认激活方式 */
  getLorebookActivationDefault: () => LorebookActivationMode;
  /** 世界书深度注入位置(0-8) */
  getLorebookInjectionDepth: () => number;
  /** 记忆关键词检索开关 */
  getMemoryKeywordRetrievalEnabled: () => boolean;
  /** 解析用户称呼(对话覆盖 > 角色设置 > 全局设置 > User) */
  resolveUserName: () => Promise<string>;
  /** 解析生效 Persona */
  resolveEffectivePersona: () => Promise<Persona | null>;
  /** 状态输出规则文本(稳定前缀;开关关闭时为空串) */
  buildStatusRule: () => string;
  /** 追加"角色状态当前值"段(请求最末;开关关闭时原样返回) */
  appendStatusValuesMessage: (messages: ChatMessage[]) => ChatMessage[];
  /** 前端交互记录提示词段文本(无记录返回空串) */
  buildFrontendInteractionBlock: () => string;
}

export class ChatRequestBuilder {
  private readonly promptBuilder: PromptBuilder | null;
  private readonly tokenCounter: TokenCounter | null;
  private readonly recentMessageSelector: RecentMessageSelector | null;
  private readonly lorebookService: LorebookService | null;
  private readonly lorebookPinService: LorebookPinService | null;
  private readonly lorebookStickyService: LorebookStickyService | null;
  private readonly memoryService: MemoryService | null;
  private readonly memoryLoadRefService: MemoryLoadRefService | null;
  private readonly chatMemoryModeService: ChatMemoryModeService | null;
  private readonly contextBudgetService: ContextBudgetService | null;
  private readonly modelService: ModelService;
  private readonly promptPresetService: PromptPresetService | null;
  private readonly host: ChatRequestHost;

  constructor(deps: ChatRequestBuilderDeps, host: ChatRequestHost) {
    this.promptBuilder = deps.promptBuilder;
    this.tokenCounter = deps.tokenCounter;
    this.recentMessageSelector = deps.recentMessageSelector;
    this.lorebookService = deps.lorebookService;
    this.lorebookPinService = deps.lorebookPinService;
    this.lorebookStickyService = deps.lorebookStickyService;
    this.memoryService = deps.memoryService;
    this.memoryLoadRefService = deps.memoryLoadRefService;
    this.chatMemoryModeService = deps.chatMemoryModeService;
    this.contextBudgetService = deps.contextBudgetService;
    this.modelService = deps.modelService;
    this.promptPresetService = deps.promptPresetService;
    this.host = host;
  }

  /** 构建请求消息列表(入口;等价原 ChatService.buildRequestMessages) */
  async build(presetSystemPrompt?: string, presetTailSystemPrompt?: string,
    excludeMessageId?: string): Promise<ChatMessage[]> {
    return this.buildRequestMessages(presetSystemPrompt, presetTailSystemPrompt, excludeMessageId);
  }

  // ===== 请求级 Preset 快照(P2-12:自 ChatService 抽离,逐字搬出) =====

  /**
   * 创建请求级 Preset 快照。
   *
   * 每次 sendMessage/regenerate 开始时调用一次。
   * 读取当前 Preset,与模型配置合并为 EffectiveGenerationSettings。
   *
   * 读取失败规则:
   * - 当前 ID 不存在:清空选择,返回 null(使用模型配置)
   * - Repository 读取异常:抛出错误,阻止请求
   * - Preset 数据损坏:抛出错误,阻止请求
   *
   * @returns 请求快照
   * @throws Error 无法读取当前预设或数据损坏
   */
  async createPresetRequestSnapshot(): Promise<PromptPresetRequestSnapshot> {
    // 1. 获取模型配置作为基准
    let baseTemperature: number | undefined = undefined;
    let baseTopP: number | undefined = undefined;
    let baseMaxOutputTokens: number | undefined = undefined;
    let baseContextWindow: number | undefined = undefined;
    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config !== null) {
        baseTemperature = config.temperature;
        baseTopP = config.topP;
        baseMaxOutputTokens = config.maxTokens;
        baseContextWindow = config.contextWindow;
      }
    } catch (e) {
      // 配置获取失败:使用空 base,后续由 DEFAULT_OPTIONS 兜底
      Logger.warn(LOG_TAG, 'createPresetRequestSnapshot getCurrentConfig failed: '
        + (e instanceof Error ? e.message : String(e)));
    }
    const base: EffectiveGenerationSettings = {
      temperature: baseTemperature,
      topP: baseTopP,
      maxOutputTokens: baseMaxOutputTokens,
      contextWindow: baseContextWindow
    };

    // 2. 获取当前 Preset
    if (this.promptPresetService === null) {
      return createSnapshotWithoutPreset(
        resolveEffectiveGenerationSettings(base)
      );
    }

    let presets: PromptPreset[] = [];
    try {
      presets = await this.promptPresetService.getSelectedPresets();
    } catch (e) {
      // Repository 读取失败:阻止请求
      throw new Error('无法读取当前提示词预设，请重试');
    }

    // Phase 4D-9: 预设加载诊断日志
    // 用于验证用户在设置 tab 选择的预设是否真正被加载到请求中
    Logger.info(LOG_TAG, 'createPresetRequestSnapshot: selected preset count='
      + presets.length.toString());

    if (presets.length === 0) {
      return createSnapshotWithoutPreset(
        resolveEffectiveGenerationSettings(base)
      );
    }

    // 3. 合并参数
    let settings: EffectiveGenerationSettings;
    try {
      settings = resolveEffectiveGenerationSettings(base, presets);
    } catch (e) {
      // 数据损坏:阻止请求
      throw new Error('无法读取当前提示词预设，请重试');
    }

    // v51: 读取预设注入位置(本地偏好;失败不阻塞请求,全部按 head 处理)
    let positions: Record<string, PromptPresetPosition> = {};
    try {
      positions = await this.promptPresetService.getPresetPositions();
    } catch (e) {
      Logger.warn(LOG_TAG, 'createPresetRequestSnapshot getPresetPositions failed: '
        + (e instanceof Error ? e.message : String(e)));
    }

    return createSnapshotWithPresets(presets, settings, positions);
  }


  // ===== 宿主状态读取(同名 getter 转发,保持搬运代码零改写) =====

  private get currentChat(): Chat | null {
    return this.host.getCurrentChat();
  }

  private get currentChatId(): string | undefined {
    return this.host.getCurrentChatId();
  }

  private get character(): Character | null {
    return this.host.getCharacter();
  }

  private get messages(): ChatMessage[] {
    return this.host.getMessages();
  }

  private get activeBranchId(): string {
    return this.host.getActiveBranchId();
  }

  private get lorebookActivationDefault(): LorebookActivationMode {
    return this.host.getLorebookActivationDefault();
  }

  private get lorebookInjectionDepth(): number {
    return this.host.getLorebookInjectionDepth();
  }

  private get memoryKeywordRetrievalEnabled(): boolean {
    return this.host.getMemoryKeywordRetrievalEnabled();
  }

  // ===== 宿主能力(同名方法转发) =====

  private resolveUserName(): Promise<string> {
    return this.host.resolveUserName();
  }

  private resolveEffectivePersona(): Promise<Persona | null> {
    return this.host.resolveEffectivePersona();
  }

  private buildStatusRule(): string {
    return this.host.buildStatusRule();
  }

  private appendStatusValuesMessage(messages: ChatMessage[]): ChatMessage[] {
    return this.host.appendStatusValuesMessage(messages);
  }

  private buildFrontendInteractionBlock(): string {
    return this.host.buildFrontendInteractionBlock();
  }

  // ===== 搬运方法(原 ChatService 私有方法,逐字搬出) =====
  /**
   * 构建请求消息列表(通过 PromptBuilder 统一构建)。
   *
   * 角色、世界书和聊天历史由 PromptBuilder 按固定顺序组装。
   * 世界书内容不会写入 this.messages。
   * 无 PromptBuilder 或无角色时,返回原始消息列表(跳过 System 消息)。
   *
   * V2 字段支持:
   * - character.mesExample:作为 DialogueExamples 段(由 PromptBuilder 处理)
   * - character.postHistoryInstructions:作为 PostHistory 段(由 PromptBuilder 处理)
   * - character.systemPrompt + {{original}}:由 PromptBuilder 处理
   * - character.characterBookId:加载关联 Lorebook 作为 characterBook 参与匹配
   *
   * @param presetSystemPrompt Preset 附加 System Prompt(可选,已宏替换)
   * @param presetTailSystemPrompt v51: 位置为 tail 的 Preset 附加 System Prompt(注入对话之后)
   */
  private async buildRequestMessages(
    presetSystemPrompt?: string,
    presetTailSystemPrompt?: string,
    excludeMessageId?: string
  ): Promise<ChatMessage[]> {
    // Phase 4D-9: 诊断日志,确认 presetSystemPrompt 是否传入 PromptBuilder
    Logger.info(LOG_TAG, 'buildRequestMessages: presetSystemPrompt=' +
      (presetSystemPrompt !== undefined
        ? `len=${presetSystemPrompt.length}`
        : 'undefined'));

    // 确定用于构建 Prompt 的消息列表
    let sourceMessages: ChatMessage[];
    if (excludeMessageId !== undefined && excludeMessageId.length > 0) {
      // 排除目标 Assistant(候选生成时使用)
      sourceMessages = [];
      for (let i = 0; i < this.messages.length; i++) {
        if (this.messages[i].id !== excludeMessageId) {
          sourceMessages.push(this.messages[i]);
        }
      }
    } else {
      sourceMessages = this.messages;
    }

    if (this.promptBuilder === null) {
      // 无 PromptBuilder:跳过 System 消息,保留 User/Assistant
      const filtered: ChatMessage[] = [];
      for (let i = 0; i < sourceMessages.length; i++) {
        if (sourceMessages[i].role !== ChatRole.System) {
          filtered.push(sourceMessages[i]);
        }
      }
      return filtered;
    }

    // 世界书只加载角色绑定的那本,不加载全局当前世界书(每本书只服务绑定它的角色)
    let characterBook: Lorebook | undefined = undefined;
    if (this.character !== null
      && this.character.characterBookId.length > 0
      && this.lorebookService !== null) {
      try {
        const book: Lorebook | null = await this.lorebookService.getById(
          this.character.characterBookId
        );
        if (book !== null) {
          characterBook = book;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load character_book failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // 可观测性:记录本次请求实际加载到的角色绑定世界书,用于排查"世界书是否参与注入"
    Logger.info(LOG_TAG,
      'buildRequestMessages worldbook: characterBook=' + (characterBook !== undefined
        ? ('id=' + characterBook.id + ' name=' + characterBook.name + ' enabled=' + String(characterBook.enabled)
          + ' entries=' + String(characterBook.entries.length))
        : 'none')
      + ' characterBookId=' + (this.character !== null ? this.character.characterBookId : ''));

    // v45: OnDemandPinned(按需锁定)会话钉选加载
    // - 已有钉选记录 → 直接按记录取条目(切换会话/重新生成都不重算,缓存前缀稳定)
    // - 无钉选记录 → 按当前全部消息(新会话即首条消息)首次钉选并落库
    let pinnedLorebookEntries: LorebookEntry[] | undefined = undefined;
    if (characterBook !== undefined
      && this.lorebookPinService !== null
      && this.currentChatId !== undefined
      && this.currentChatId.length > 0) {
      const effectiveMode: LorebookActivationMode =
        characterBook.activationMode !== LorebookActivationMode.FollowGlobal
          ? characterBook.activationMode : this.lorebookActivationDefault;
      if (effectiveMode === LorebookActivationMode.OnDemandPinned) {
        try {
          pinnedLorebookEntries = await this.lorebookPinService.ensurePinnedEntries(
            this.currentChatId, characterBook, sourceMessages
          );
          Logger.info(LOG_TAG, 'buildRequestMessages lorebookPin: entries='
            + String(pinnedLorebookEntries.length));
        } catch (e) {
          Logger.warn(LOG_TAG, 'lorebook pin ensure failed: '
            + (e instanceof Error ? e.message : String(e)));
          pinnedLorebookEntries = [];
        }
      }
    }

    // v47: StickyOnDemand(粘滞按需)会话命中加载。
    // 条目全文不再统一挂在对话之后,而是按锚点插进对话历史(见 injectStickyLorebookEntries):
    // 插一次即固定、新对话续在其后 → 从下一轮起就处在稳定前缀里,被缓存命中。
    let stickyResolve: StickyResolveResult = { entries: [], anchors: {} };
    if (characterBook !== undefined
      && this.lorebookStickyService !== null
      && this.currentChatId !== undefined
      && this.currentChatId.length > 0) {
      const effectiveStickyMode: LorebookActivationMode =
        characterBook.activationMode !== LorebookActivationMode.FollowGlobal
          ? characterBook.activationMode : this.lorebookActivationDefault;
      if (effectiveStickyMode === LorebookActivationMode.StickyOnDemand) {
        try {
          stickyResolve = await this.lorebookStickyService.ensureStickyEntries(
            this.currentChatId, characterBook, sourceMessages
          );
          Logger.info(LOG_TAG, 'buildRequestMessages lorebookSticky: entries='
            + String(stickyResolve.entries.length));
        } catch (e) {
          Logger.warn(LOG_TAG, 'lorebook sticky ensure failed: '
            + (e instanceof Error ? e.message : String(e)));
        }
      }
    }

    // 通过 PromptBuilder.buildMacroContext 构建宏替换上下文
    // (包含 description / personality / scenario / mesExample / lastMessage / originalContent)
    // 用户称呼优先级:对话覆盖 > 角色设置 > 全局设置 > 'User'
    const resolvedUserName: string = await this.resolveUserName();
    const macroContext: MacroContext = this.promptBuilder.buildMacroContext(
      this.character,
      resolvedUserName,
      sourceMessages
    );

    // 长期记忆注入(v12 多层优先,回退单段)
    // v12: 优先使用 getMultiLayerInjectionContext 获取 Core/Chapter/Rolling/Legacy 分层记忆
    // 失败或无记忆时回退到空,不影响主流程
    // v8.3 Phase 2: 同时取得 memoryEndPosition 用于 RecentMessageSelector 去重
    let memoryLayers: MemoryLayersInjection | undefined = undefined;
    let memoryEndPosition: number = -1;
    // v51: 记忆"激活边界"(延迟激活)。>=0 时只注入 endPosition <= activeBoundary 的章节,
    // 窗口锚点也停在激活边界 → 新生成的章节不改变 prompt 前缀,聊天缓存保持命中。
    // -1 表示未启用(无会话模式服务)或未初始化,回退现状(用实际章节边界)。
    let activeBoundary: number = -1;
    if (this.memoryService !== null && this.activeBranchId.length > 0) {
      try {
        // v42: 传入当前 chat 的 worldId,世界分组内 core/chapter 跨会话共享
        // v46: 同时传入 chatId——世界内存在会话记忆时,章节只注入本会话最近 N 章,
        // 跨会话细节改由会话记忆(入口级)+ 按需加载提供
        // v50: 会话级"注入最近章节数"覆盖(默认 4,范围 1-20)
        const currentChatId: string =
          this.currentChatId !== undefined ? this.currentChatId : '';
        let chapterInjectCount: number = 0;
        if (this.chatMemoryModeService !== null && currentChatId.length > 0) {
          chapterInjectCount =
            await this.chatMemoryModeService.getChapterInjectCount(currentChatId);
          // v51: 读取激活边界;未初始化时按当前实际章节边界初始化
          // (存量会话保持现状;新会话无章节则为 -1,后续章节生成即"待激活")
          const stored: number | undefined =
            await this.chatMemoryModeService.getActiveBoundary(currentChatId);
          if (stored === undefined) {
            const initBoundary: number = await this.memoryService.getChapterBoundaryPosition(
              this.activeBranchId, currentChatId
            );
            activeBoundary = initBoundary >= 0 ? initBoundary : -1;
            this.chatMemoryModeService.setActiveBoundary(currentChatId, activeBoundary)
              .then((): void => {}).catch((_e: Object): void => {});
          } else {
            activeBoundary = stored;
          }
        }
        const multi = await this.memoryService.getMultiLayerInjectionContext(
          this.activeBranchId,
          this.currentChat !== null ? this.currentChat.worldId : '',
          currentChatId,
          chapterInjectCount,
          activeBoundary
        );
        if (multi.enabled) {
          // v12: 使用分层注入
          memoryLayers = {
            core: multi.core,
            session: multi.session,
            chapter: multi.chapter,
            rolling: multi.rolling,
            legacy: multi.legacy
          };
          memoryEndPosition = multi.endPosition;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'load multi-layer memory failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // v8.4: 窗口锚点改为"动态派生",由记忆归档边界与保留条数实时计算。
    // - anchor = 边界(boundary) - recentWindowTarget
    //   => 窗口起点 = anchor + 1 = 边界往前 recentWindowTarget 条原文
    // - v51: 边界取"激活边界"(延迟激活):未激活章节不注入,其原文仍留在窗口内,信息不丢失;
    //   未启用延迟激活时回退"实际章节边界"(现状)
    // - 实际章节边界更小时 clamp(章节被删除/重新生成时自愈,防止锚点越过实际内容)
    // - 修改「记忆总结后保留条数」立即生效(无需重新总结)
    // - 无章节或消息不足时 anchor<0 => 全部原文
    // - 仅当记忆实际可用(memoryLayers 已加载)时才应用;防止记忆被清除/禁用后截断前缀
    let recentWindowTarget: number = DEFAULT_RECENT_WINDOW_TARGET;
    if (this.contextBudgetService !== null && this.currentChatId !== undefined
      && this.currentChatId.length > 0) {
      try {
        const budgetConfig: ContextBudgetConfig =
          await this.contextBudgetService.getBudget(this.currentChatId);
        if (budgetConfig.recentWindowTarget > 0) {
          recentWindowTarget = budgetConfig.recentWindowTarget;
        }
      } catch (_e) {
        // 读取失败用默认值
      }
    }
    if (memoryLayers !== undefined && this.memoryService !== null
      && this.activeBranchId.length > 0) {
      try {
        const actualBoundary: number =
          await this.memoryService.getChapterBoundaryPosition(
            this.activeBranchId,
            this.currentChatId !== undefined ? this.currentChatId : ''
          );
        let effectiveBoundary: number = activeBoundary;
        if (effectiveBoundary < 0) {
          // 未启用延迟激活:回退实际章节边界(现状行为)
          effectiveBoundary = actualBoundary;
        } else if (actualBoundary >= 0 && effectiveBoundary > actualBoundary) {
          effectiveBoundary = actualBoundary;
        }
        const derivedAnchor: number = effectiveBoundary - recentWindowTarget;
        memoryEndPosition = derivedAnchor >= 0 ? derivedAnchor : -1;
        Logger.info(LOG_TAG, 'buildRequestMessages | window anchor derived'
          + ' activeBoundary=' + activeBoundary
          + ' actualBoundary=' + actualBoundary
          + ' recentWindowTarget=' + recentWindowTarget
          + ' anchor=' + memoryEndPosition);
      } catch (e) {
        Logger.warn(LOG_TAG, 'load chapter boundary failed: ' + String(e));
      }
    }

    // 使用 RecentMessageSelector 选择最近原始消息窗口(缓存优先,append-only)
    // - 窗口以最后一次记忆总结结束位置为锚(memoryEndPosition),新消息只追加、不滑动
    // - 与长期记忆范围去重:已被记忆覆盖且不在最近窗口的消息不注入原文
    // - 刚总结完、窗口为空时兜底保留最近 MIN_COMPLETE_TURNS(2)完整轮次
    // - availableTokens 传一个宽松上限,让 RecentMessageSelector 主要做去重 + 窗口
    //   精确 Token 裁剪由后续 HistoryTrimmer 完成
    // - 为 null 时回退到旧行为(传全部 sourceMessages)
    let conversationMessages: ChatMessage[] = sourceMessages;
    if (this.recentMessageSelector !== null && this.tokenCounter !== null) {
      try {
        // recentWindowTarget 已在上方解析,直接复用(窗口锚点派生也使用同一值)
        const selection: ContextHistorySelection = this.recentMessageSelector.select(
          sourceMessages,
          {
            targetCount: recentWindowTarget,
            minCompleteTurns: MIN_COMPLETE_TURNS,
            availableTokens: Number.MAX_SAFE_INTEGER,
            memoryEndPosition: memoryEndPosition
          }
        );
        conversationMessages = selection.recentMessages;
        if (selection.selectedCount === 0 && sourceMessages.length > 0) {
          // 选择器异常返回空:回退到 sourceMessages,避免空请求
          Logger.warn(LOG_TAG, 'RecentMessageSelector returned empty, fallback to sourceMessages');
          conversationMessages = sourceMessages;
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'RecentMessageSelector failed, fallback to sourceMessages: '
          + (e instanceof Error ? e.message : String(e)));
        conversationMessages = sourceMessages;
      }
    }

    // 解析有效 Persona
    const effectivePersona: Persona | null = await this.resolveEffectivePersona();

    // v46: 按需加载记忆(自动实体匹配 + 锚点插入)。
    // 替换 v44 关键词前置注入:命中记忆不再放到对话历史之前,而是记录引用(持久化),
    // 在历史末尾锚点之后插入,后续对话续在其后,保持前缀缓存命中。
    // 开关沿用 memoryKeywordRetrievalEnabled(仅世界分组生效)。
    if (this.memoryKeywordRetrievalEnabled
      && this.memoryService !== null
      && this.currentChat !== null
      && this.currentChat.worldId.length > 0
      && this.currentChatId !== undefined
      && this.currentChatId.length > 0
      && this.memoryLoadRefService !== null
      && conversationMessages.length > 0) {
      try {
        await this.autoLoadOnDemandMemories(conversationMessages, memoryLayers);
      } catch (e) {
        Logger.warn(LOG_TAG, 'auto on-demand memory load failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // v46: 注入已加载的按需记忆块(锚点消息之后插入;锚点不在窗口时插到窗口头部)
    if (this.memoryService !== null
      && this.currentChatId !== undefined
      && this.currentChatId.length > 0
      && this.memoryLoadRefService !== null) {
      try {
        conversationMessages = await this.injectOnDemandMemories(conversationMessages);
      } catch (e) {
        Logger.warn(LOG_TAG, 'inject on-demand memories failed: '
          + (e instanceof Error ? e.message : String(e)));
      }
    }

    // v47: 注入粘滞世界书条目全文(按锚点插到首次命中时的位置;锚点不在窗口时插到窗口头部)。
    // 与按需记忆共用同一套锚点机制:插一次即固定,新对话续在其后 → 进稳定前缀缓存。
    conversationMessages = this.injectStickyLorebookEntries(conversationMessages, stickyResolve);

    const context: PromptBuildContext = {
      character: this.character !== null ? this.character : undefined,
      characterBook: characterBook,
      messages: conversationMessages,
      macroContext: macroContext,
      presetSystemPrompt: presetSystemPrompt,
      // v51: 末尾预设(位置=tail),注入到聊天历史之后,用于约束输出
      presetTailSystemPrompt: presetTailSystemPrompt,
      // v12: 优先使用分层注入;memoryLayers 为 undefined 时 PromptBuilder 回退到 memorySummary(此处不传)
      memoryLayers: memoryLayers,
      // 角色绑定书的激活方式兜底(书级 FollowGlobal 遗留数据时用全局默认) + 深度注入位置
      characterBookActivationMode: this.lorebookActivationDefault,
      lorebookDepth: this.lorebookInjectionDepth,
      // v45: OnDemandPinned 会话钉选条目(记忆之后、对话之前注入)
      pinnedLorebookEntries: pinnedLorebookEntries,
      // 粘滞条目已按锚点插进 conversationMessages(见上),此处不再作为固定尾部段注入
      // v50: 前端卡交互记录(无记录时为空串→不产生段)
      frontendInteractionLog: this.buildFrontendInteractionBlock(),
      // 角色状态输出规则(稳定段:格式 + 字段清单,不含当前值;注入对话示例之后)
      statusRuleText: this.buildStatusRule(),
      // Persona 注入
      persona: effectivePersona !== null ? effectivePersona : undefined
      // enablePostHistoryInstructions 默认为 true
      // 后续可由 Preset 配置控制
    };

    const result: PromptBuildResult = this.promptBuilder.build(context);

    // ===== 尾部易变区(变化越频繁排得越靠后,保证其前面的内容全部命中前缀缓存) =====
    // 粘滞生效提醒(仅条目名,随"话题是否还热"变化) → 角色状态当前值(每轮都可能变)
    let finalMessages: ChatMessage[] = this.appendStickyReminder(
      result.messages, characterBook, stickyResolve, sourceMessages
    );
    finalMessages = this.appendStatusValuesMessage(finalMessages);
    return finalMessages;
  }

  /**
   * v46: 自动实体匹配 → 追加按需加载引用。
   *
   * 数据源:世界池会话记忆 detail 中的实体索引(人名/地点/时间)
   * + 章节记忆 keywordsJson 关键词(补充)。
   * 匹配最近 20 条消息文本;排除已常驻注入与已引用的记忆;
   * 单次构建最多新增 3 条(总量上限由 MemoryLoadRefService 控制)。
   * 锚点 = 当前历史末尾消息 ID。
   */
  private async autoLoadOnDemandMemories(
    conversationMessages: ChatMessage[],
    memoryLayers: MemoryLayersInjection | undefined
  ): Promise<void> {
    const chatId: string | undefined = this.currentChatId;
    if (chatId === undefined || chatId.length === 0
      || this.memoryService === null || this.memoryLoadRefService === null
      || this.currentChat === null || this.currentChat.worldId.length === 0) {
      return;
    }
    const worldId: string = this.currentChat.worldId;

    // 匹配文本:最近 20 条消息
    const texts: string[] = [];
    const endIdx: number = conversationMessages.length;
    for (let i = Math.max(0, endIdx - 20); i < endIdx; i++) {
      texts.push(conversationMessages[i].content);
    }

    // 排除:已常驻注入的章节 + 已引用的记忆
    const excludeIds: Set<string> = new Set<string>();
    if (memoryLayers !== undefined) {
      for (let i = 0; i < memoryLayers.chapter.length; i++) {
        excludeIds.add(memoryLayers.chapter[i].id);
      }
      for (let i = 0; i < memoryLayers.session.length; i++) {
        excludeIds.add(memoryLayers.session[i].id);
      }
    }
    const refs: MemoryLoadRef[] = await this.memoryLoadRefService.getRefs(chatId);
    for (let i = 0; i < refs.length; i++) {
      excludeIds.add(refs[i].memoryId);
    }

    // 1) 会话记忆实体索引匹配
    const worldMemories: ChatMemory[] = await this.memoryService.listWorldMemories(worldId);
    const mergedEntries: EntityIndexEntry[] = [];
    for (let i = 0; i < worldMemories.length; i++) {
      const m: ChatMemory = worldMemories[i];
      if (m.memoryType === 'session' && !excludeIds.has(m.id)) {
        const index: EntityIndex = parseEntityIndexJson(m.detail);
        for (let j = 0; j < index.entries.length; j++) {
          mergedEntries.push(index.entries[j]);
        }
      }
    }
    const mergedIndex: EntityIndex = { entries: mergedEntries };
    const matchedIds: string[] = matchEntityChapterIds(mergedIndex, texts);

    // 2) 章节关键词补充(排除实体命中与恒定注入)
    const kwExclude: string[] = Array.from(excludeIds);
    for (let i = 0; i < matchedIds.length; i++) {
      kwExclude.push(matchedIds[i]);
    }
    const keywordHits: ChatMemory[] = await this.memoryService.retrieveKeywordMemories(
      worldId, texts, kwExclude, 3
    );

    // 合并候选(实体命中优先),单次最多 3 条
    const candidates: string[] = [];
    for (let i = 0; i < matchedIds.length && candidates.length < 3; i++) {
      if (!excludeIds.has(matchedIds[i])) {
        candidates.push(matchedIds[i]);
        excludeIds.add(matchedIds[i]);
      }
    }
    for (let i = 0; i < keywordHits.length && candidates.length < 3; i++) {
      if (!excludeIds.has(keywordHits[i].id)) {
        candidates.push(keywordHits[i].id);
        excludeIds.add(keywordHits[i].id);
      }
    }
    if (candidates.length === 0) {
      return;
    }

    // 锚点 = 当前历史末尾消息
    const anchorMessageId: string = conversationMessages[conversationMessages.length - 1].id;
    let added: number = 0;
    for (let i = 0; i < candidates.length; i++) {
      const ok: boolean = await this.memoryLoadRefService.addRef(chatId, candidates[i], anchorMessageId);
      if (ok) {
        added++;
      }
    }
    if (added > 0) {
      Logger.info(LOG_TAG, 'on-demand memory auto-loaded=' + added
        + ' matched=' + matchedIds.length + ' keyword=' + keywordHits.length);
    }
  }

  /**
   * v46: 注入按需加载的记忆块。
   * - 锚点消息在窗口内 → 紧随其后插入(后续对话续在其后,前缀缓存保持)
   * - 锚点消息不在窗口(被裁剪/删除) → 插到窗口第一条消息之前
   * - 记忆失效/禁用/已删 → 跳过并清理引用
   */
  private async injectOnDemandMemories(messages: ChatMessage[]): Promise<ChatMessage[]> {
    const chatId: string | undefined = this.currentChatId;
    if (chatId === undefined || chatId.length === 0
      || this.memoryService === null || this.memoryLoadRefService === null) {
      return messages;
    }
    const refs: MemoryLoadRef[] = await this.memoryLoadRefService.getRefs(chatId);
    if (refs.length === 0) {
      return messages;
    }
    // 按添加时间正序(同锚点保持加入顺序)
    const sortedRefs: MemoryLoadRef[] = refs.slice().sort(
      (a: MemoryLoadRef, b: MemoryLoadRef): number => a.addedAt - b.addedAt
    );

    const result: ChatMessage[] = messages.slice();
    const headBlocks: ChatMessage[] = [];
    const anchoredInserts: OnDemandInsert[] = [];

    for (let i = 0; i < sortedRefs.length; i++) {
      const ref: MemoryLoadRef = sortedRefs[i];
      const memory: ChatMemory | null = await this.memoryService.getById(ref.memoryId);
      if (memory === null || memory.invalidated || !memory.enabled) {
        // 失效引用清理(静默,不阻塞构建)
        await this.memoryLoadRefService.removeRef(chatId, ref.memoryId);
        continue;
      }
      const title: string = memory.title.length > 0 ? memory.title : '历史记忆';
      const block: ChatMessage = {
        id: 'memref-' + memory.id,
        role: ChatRole.System,
        content: '【回忆 · ' + title + '】\n' + memory.summary,
        createdAt: memory.createdAt,
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.MemoryChapter
      };
      let anchorIdx: number = -1;
      for (let j = 0; j < result.length; j++) {
        if (result[j].id === ref.anchorMessageId) {
          anchorIdx = j;
          break;
        }
      }
      if (anchorIdx >= 0) {
        anchoredInserts.push({ insertAfter: anchorIdx, message: block });
      } else {
        headBlocks.push(block);
      }
    }

    return this.applyAnchoredInserts(result, anchoredInserts, headBlocks, 'on-demand memory injected');
  }

  /**
   * v47: 把粘滞世界书条目全文按锚点插进对话历史(与 injectOnDemandMemories 同一套机制)。
   *
   * - 锚点消息在当前窗口内 → 插到它之后。位置此后固定不再移动,新消息只在其后追加,
   *   因此该块从下一轮起就落在稳定前缀里被缓存命中。
   * - 锚点缺失 / 已滑出窗口(如手动记忆总结截断后)→ 回退插到窗口头部。
   * - 每条目只插一份(集合本身按 entryId 去重),不会重复加载同一内容。
   * 空集合直接返回原数组(无粘滞命中时不产生任何段)。
   */
  private injectStickyLorebookEntries(
    messages: ChatMessage[], resolve: StickyResolveResult
  ): ChatMessage[] {
    if (resolve.entries.length === 0) {
      return messages;
    }
    const result: ChatMessage[] = messages.slice();
    const headBlocks: ChatMessage[] = [];
    const anchoredInserts: OnDemandInsert[] = [];
    const anchorKeys: Set<string> = new Set(Object.keys(resolve.anchors));
    const now: number = Date.now();

    for (let i = 0; i < resolve.entries.length; i++) {
      const entry: LorebookEntry = resolve.entries[i];
      const block: ChatMessage = {
        id: 'sticky-' + entry.id,
        role: ChatRole.System,
        content: entry.content,
        createdAt: now,
        status: ChatMessageStatus.Completed,
        source: ChatMessageSource.LorebookSticky,
        sourceName: '粘滞命中·' + entry.name
      };
      const anchorId: string = anchorKeys.has(entry.id) ? resolve.anchors[entry.id] : '';
      let anchorIdx: number = -1;
      if (anchorId.length > 0) {
        for (let j = 0; j < result.length; j++) {
          if (result[j].id === anchorId) {
            anchorIdx = j;
            break;
          }
        }
      }
      if (anchorIdx >= 0) {
        anchoredInserts.push({ insertAfter: anchorIdx, message: block });
      } else {
        headBlocks.push(block);
      }
    }

    return this.applyAnchoredInserts(result, anchoredInserts, headBlocks, 'sticky lorebook injected');
  }

  /**
   * 锚点插入公共尾部:头部块逆序 unshift + 锚点块按 insertAfter 降序逆序 splice。
   * injectOnDemandMemories / injectStickyLorebookEntries 共用(同一套锚点插入机制)。
   * @param result 已复制的消息数组(调用方已 slice,索引均基于原窗口计算)。
   * @param logTag 注入日志前缀(区分来源:on-demand / sticky)。
   */
  private applyAnchoredInserts(
    result: ChatMessage[],
    anchoredInserts: OnDemandInsert[],
    headBlocks: ChatMessage[],
    logTag: string
  ): ChatMessage[] {
    if (anchoredInserts.length === 0 && headBlocks.length === 0) {
      return result;
    }
    // 头部块:逆序 unshift,最终按添加顺序排在窗口最前
    for (let i = headBlocks.length - 1; i >= 0; i--) {
      result.unshift(headBlocks[i]);
    }
    // 锚点块:按 insertAfter 降序排序后逆序 splice,同锚点时保持先加入的在前
    anchoredInserts.sort((a: OnDemandInsert, b: OnDemandInsert): number =>
      b.insertAfter - a.insertAfter
    );
    for (let i = anchoredInserts.length - 1; i >= 0; i--) {
      const insert: OnDemandInsert = anchoredInserts[i];
      result.splice(insert.insertAfter + 1, 0, insert.message);
    }
    Logger.info(LOG_TAG, logTag + ' anchored=' + anchoredInserts.length
      + ' head=' + headBlocks.length);
    return result;
  }

  /**
   * v47: 在请求尾部追加一行「当前仍生效的设定」提醒。
   *
   * 条目全文已按锚点固定在对话历史里(不搬动,否则会作废其后的前缀缓存),
   * 随着对话推进注意力会衰减;本段只列**条目名、不带内容**,把注意力拉回这些设定。
   * 只列"已加载 且 本轮最近消息里仍然关键词命中"的条目(话题还热);
   * 都不热(或该书非 StickyOnDemand)时返回原数组,不产生该段。
   */
  private appendStickyReminder(
    messages: ChatMessage[],
    book: Lorebook | undefined,
    loaded: StickyResolveResult,
    recentMessages: ChatMessage[]
  ): ChatMessage[] {
    if (book === undefined || this.lorebookService === null || loaded.entries.length === 0) {
      return messages;
    }
    let matched: LorebookEntry[] = [];
    try {
      matched = this.lorebookService.matchKeywordEntries(book, recentMessages);
    } catch (e) {
      Logger.warn(LOG_TAG, 'sticky reminder match failed: ' + String(e));
      return messages;
    }
    if (matched.length === 0) {
      return messages;
    }
    // 按首次命中顺序(entryIds 顺序)列出,内容只含条目名
    const names: string[] = pickHotStickyNames(
      loaded.entries, matched, STICKY_REMINDER_MAX_ITEMS
    );
    const text: string = buildStickyReminderText(names);
    if (text.length === 0) {
      return messages;
    }
    const reminder: ChatMessage = mergeChatMessage(
      createChatMessage(generateUuid(), ChatRole.System, text, Date.now()),
      {
        source: ChatMessageSource.StickyReminder,
        sourceName: '粘滞生效提醒'
      }
    );
    const result: ChatMessage[] = messages.slice();
    result.push(reminder);
    return result;
  }
}