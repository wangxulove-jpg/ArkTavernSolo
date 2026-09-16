/**
 * AppServices 应用服务组装根
 *
 * 最小组合根,在应用启动时使用稳定 Context 组装全部底层依赖。
 * 页面与 ViewModel 通过 AppServices.getInstance().modelService 访问业务能力,
 * 不自行 new 全套依赖。
 *
 * 设计原则:
 * - 不实现复杂 DI 框架,仅做静态组装
 * - 不保存 Context 引用(仅用于初始化,初始化后丢弃)
 * - 不持有可变业务状态(仅持有服务实例引用)
 * - 不作为 Service Locator:只暴露 modelService,不提供通用 get(name)
 * - 初始化幂等:重复调用返回同一 Promise
 *
 * 生命周期:
 * - EntryAbility.onCreate 调用 AppServices.initialize(context) 启动初始化
 * - 页面 aboutToAppear 调用 AppServices.whenReady() 等待初始化完成
 * - AppServices.getInstance() 在初始化完成后返回实例
 */

import { common } from '@kit.AbilityKit';
import { AppPreferences } from '../storage/AppPreferences';
import { ThemeManager } from './ThemeManager';
import { ProviderConfigStore } from '../storage/ProviderConfigStore';
import { AssetStoreKeyStore } from '../storage/AssetStoreKeyStore';
import { ProviderKeyStore } from '../storage/ProviderKeyStore';
import { CharacterStore } from '../storage/CharacterStore';
import { CharacterSelectionStore } from '../storage/CharacterSelectionStore';
import { CharacterAssetStore } from '../storage/CharacterAssetStore';
import { LorebookStore } from '../storage/LorebookStore';
import { LorebookSelectionStore } from '../storage/LorebookSelectionStore';
import { CharacterService } from './CharacterService';
import { CharacterMigrationService } from './CharacterMigrationService';
import { LorebookService } from './LorebookService';
import { LorebookPinService } from './LorebookPinService';
import { LorebookMigrationService } from './LorebookMigrationService';
import { MacroReplacer } from './MacroReplacer';
import { PromptBuilder } from './PromptBuilder';
import { TokenCounter } from './TokenCounter';
import { HistoryTrimmer } from './HistoryTrimmer';
import { RecentMessageSelector } from './RecentMessageSelector';
import { DbHelper } from '../database/DbHelper';
import { DatabaseError } from '../models/DatabaseError';
import { ChatRepository } from '../repositories/ChatRepository';
import { MessageRepository } from '../repositories/MessageRepository';
import { MessageSwipeRepository } from '../repositories/MessageSwipeRepository';
import { ChatPersistenceOperations } from '../repositories/ChatPersistenceOperations';
import { CharacterRepository } from '../repositories/CharacterRepository';
import { LorebookRepository } from '../repositories/LorebookRepository';
import { PromptPresetRepository } from '../repositories/PromptPresetRepository';
import { ConversationBranchRepository } from '../repositories/ConversationBranchRepository';
import { PromptPresetSelectionStore } from '../storage/PromptPresetSelectionStore';
import { PromptPresetService } from './PromptPresetService';
import { MessageSwipePersistenceService } from './MessageSwipePersistenceService';
import { ConversationBranchPersistenceService } from './ConversationBranchPersistenceService';
import { ChatMemoryRepository } from '../repositories/ChatMemoryRepository';
import { ChatLorebookPinRepository } from '../repositories/ChatLorebookPinRepository';
import { MemoryPersistenceService } from './MemoryPersistenceService';
import { MemoryService, DEFAULT_CHAPTER_TRIGGER } from './MemoryService';
import { DEFAULT_SUMMARY_POINTS, DEFAULT_MEMORY_TRIGGER } from '../models/ChatMemory';
import { ForkChatService } from './ForkChatService';
import { ContextBudgetService } from './ContextBudgetService';
import { MemoryLoadRefService } from './MemoryLoadRefService';
import { ChatService } from './ChatService';
import { ChatPersistenceService } from './ChatPersistenceService';
import { ChatBackgroundService } from './ChatBackgroundService';
import { ModelService } from './ModelService';
import { DefaultProviderFactory } from './ProviderFactory';
import { HttpClient } from '../network/core/HttpClient';
import { HarmonyHttpClient } from '../network/core/HarmonyHttpClient';
import { MarketCacheStore } from './market/MarketCacheStore';
import { MarketImportedMapStore } from './market/MarketImportedMapStore';
import { MarketService } from './market/MarketService';
import { MarketImportService } from './market/MarketImportService';
import { MarketTranslationService } from './market/MarketTranslationService';
import { PromptPresetListViewModel } from '../viewmodels/PromptPresetListViewModel';
import { PromptPresetEditViewModel } from '../viewmodels/PromptPresetEditViewModel';
import { ChatSessionListViewModel } from '../viewmodels/ChatSessionListViewModel';
import { ChatTextStyleSettings } from '../utils/ChatTextStyleSettings';
import { ChatArchiveService } from './ChatArchiveService';
import { ChatArchiveImportService } from './ChatArchiveImportService';
import { ChatArchiveViewModel } from '../viewmodels/ChatArchiveViewModel';
import { ChatParticipantRepository } from '../repositories/ChatParticipantRepository';
import { PersonaRepository } from '../repositories/PersonaRepository';
import { PersonaSelectionStore } from '../storage/PersonaSelectionStore';
import { PersonaService } from './PersonaService';
import { SyncConfigStore } from '../storage/SyncConfigStore';
import { WebDavSyncService } from './sync/WebDavSyncService';
import { DeepSeekBalanceService } from './DeepSeekBalanceService';
import { WorldGroupService } from './WorldGroupService';
import { WorldGroupRepository } from '../repositories/WorldGroupRepository';

import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'AppServices';

/**
 * 应用服务组装根。
 * 仅暴露 modelService 供上层使用,不提供通用 Service Locator 查询。
 * ChatService 由 ChatPage 按页面生命周期创建,不在应用级保存单例。
 */
export class AppServices {
  private static instance: AppServices | null = null;
  private static readyPromise: Promise<void> | null = null;

  /** ModelService 业务编排服务(唯一对外暴露的服务) */
  readonly modelService: ModelService;
  /** CharacterService 角色服务 */
  readonly characterService: CharacterService;
  /** LorebookService 世界书服务 */
  readonly lorebookService: LorebookService;
  /** v45: LorebookPinService 按需锁定世界书会话钉选服务 */
  readonly lorebookPinService: LorebookPinService;
  /** PromptBuilder 提示词构建器 */
  readonly promptBuilder: PromptBuilder;
  /** TokenCounter 上下文 Token 估算服务(不对页面公开) */
  private readonly tokenCounter: TokenCounter;
  /** HistoryTrimmer 历史裁剪服务(不对页面公开) */
  private readonly historyTrimmer: HistoryTrimmer;
  /** RecentMessageSelector 最近原始消息窗口选择器(v8.3 Phase 2,不对页面公开) */
  private readonly recentMessageSelector: RecentMessageSelector;
  /** DbHelper 数据库底座(不对页面公开) */
  private readonly dbHelper: DbHelper;
  /** ChatRepository 聊天仓储(不对页面公开) */
  private readonly chatRepository: ChatRepository;
  /** MessageRepository 消息仓储(不对页面公开) */
  private readonly messageRepository: MessageRepository;
  /** ChatPersistenceOperations 联合事务操作(不对页面公开) */
  private readonly chatPersistenceOperations: ChatPersistenceOperations;
  /** ChatPersistenceService 聊天持久化协调服务(不对页面公开) */
  private readonly chatPersistenceService: ChatPersistenceService;
  /** MessageSwipeRepository 消息候选仓储(不对页面公开) */
  private readonly messageSwipeRepository: MessageSwipeRepository;
  /** MessageSwipePersistenceService 消息候选持久化服务(不对页面公开) */
  private readonly messageSwipePersistenceService: MessageSwipePersistenceService;
  /** CharacterRepository 角色仓储(不对页面公开) */
  private readonly characterRepository: CharacterRepository;
  /** LorebookRepository 世界书仓储(不对页面公开) */
  private readonly lorebookRepository: LorebookRepository;
  /** CharacterSelectionStore 当前角色选择(不对页面公开) */
  private readonly characterSelectionStore: CharacterSelectionStore;
  /** LorebookSelectionStore 当前世界书选择(不对页面公开) */
  private readonly lorebookSelectionStore: LorebookSelectionStore;
  /** AppPreferences(不对页面公开) */
  private readonly appPreferences: AppPreferences;
  /** ThemeManager 全局主题权威(ARK-UI-THEME-1,不对页面公开) */
  private readonly themeManager: ThemeManager;
  /** CharacterMigrationService(不对页面公开) */
  private readonly characterMigrationService: CharacterMigrationService;
  /** LorebookMigrationService(不对页面公开) */
  private readonly lorebookMigrationService: LorebookMigrationService;
  /** CharacterStore(仅用于迁移,不对页面公开) */
  private readonly characterStore: CharacterStore;
  /** LorebookStore(仅用作迁移源,不对页面公开) */
  private readonly lorebookStore: LorebookStore;
  /** PromptPresetRepository(不对页面公开) */
  private readonly promptPresetRepository: PromptPresetRepository;
  /** PromptPresetSelectionStore(不对页面公开) */
  private readonly promptPresetSelectionStore: PromptPresetSelectionStore;
  /** PromptPresetService(不对页面公开,T-6.1B 接入 Chat 后暴露) */
  private readonly promptPresetService: PromptPresetService;
  /** ConversationBranchRepository 对话分支仓储(不对页面公开,T-6.4A) */
  private readonly conversationBranchRepository: ConversationBranchRepository;
  /** ConversationBranchPersistenceService 对话分支持久化服务(不对页面公开,T-6.4A) */
  private readonly conversationBranchPersistenceService: ConversationBranchPersistenceService;
  /** ChatMemoryRepository 长期记忆仓储(不对页面公开,v8) */
  private readonly chatMemoryRepository: ChatMemoryRepository;
  /** MemoryPersistenceService 长期记忆持久化服务(不对页面公开,v8) */
  private readonly memoryPersistenceService: MemoryPersistenceService;
  /** MemoryService 长期记忆业务服务(增量总结、过期标记,v8) */
  private readonly memoryService: MemoryService;
  /** ForkChatService 从分支创建独立对话服务(不对页面公开,v8) */
  private readonly forkChatService: ForkChatService;
  /** ContextBudgetService per-chat 上下文预算服务(v8.1) */
  private contextBudgetService: ContextBudgetService | null = null;
  /** v46: MemoryLoadRefService 按需加载记忆引用服务。在 initialize 中创建。 */
  private memoryLoadRefService: MemoryLoadRefService | null = null;
  /** ChatBackgroundService 聊天背景图服务(导入图片 + 模糊度 + 暗化)。在 initialize 中创建。 */
  private chatBackgroundService: ChatBackgroundService | null = null;
  /** 市场服务(Chub 公共只读浏览 + 搜索 + 详情 + 下载) */
  readonly marketService: MarketService;
  /** 市场导入服务(需要 context,在 initialize 中创建) */
  private marketImportService: MarketImportService | null = null;
  /** 市场翻译服务(复用 ModelService,在 initialize 中创建) */
  private marketTranslationService: MarketTranslationService | null = null;
  /** 应用 Context,用于 ChatBackgroundService 等需要 filesDir 的服务 */
  private appContext: common.Context | null = null;
  
  /** ChatTextStyleSettings 聊天文本样式设置(v11 富文本) */
  readonly chatTextStyleSettings: ChatTextStyleSettings;
  /** ChatArchiveService 聊天归档导出服务(T-CHAT.1) */
  private chatArchiveService: ChatArchiveService | null = null;
  /** ChatArchiveImportService 聊天归档导入服务(T-CHAT.1) */
  private chatArchiveImportService: ChatArchiveImportService | null = null;
  /** ChatParticipantRepository 多人聊天参与者仓储(不对页面公开) */
  private readonly chatParticipantRepository: ChatParticipantRepository;
  /** PersonaRepository 用户身份仓储(不对页面公开) */
  private readonly personaRepository: PersonaRepository;
  /** PersonaSelectionStore 用户身份全局默认选择(不对页面公开) */
  private readonly personaSelectionStore: PersonaSelectionStore;
  /** PersonaService 用户身份业务服务 */
  readonly personaService: PersonaService;
  /** SyncConfigStore 云同步配置存储 */
  private readonly syncConfigStore: SyncConfigStore;
  /** WebDavSyncService 云同步服务 */
  private webDavSyncService: WebDavSyncService | null = null;
  /** DeepSeekBalanceService DeepSeek余额查询服务 */
  private deepSeekBalanceService: DeepSeekBalanceService | null = null;
  /** WorldGroupService 世界分组(章节记忆共享)服务(懒加载单例,v42) */
  private worldGroupService: WorldGroupService | null = null;
  /** AssetStoreKeyStore 安全存储(共享实例) */
  private readonly assetKeyStore: AssetStoreKeyStore;
  /** ProviderKeyStore(不对页面公开) */
  private readonly providerKeyStore: ProviderKeyStore;
  /** ProviderConfigStore(不对页面公开) */
  private readonly providerConfigStore: ProviderConfigStore;

  /**
   * 私有构造,组装全部依赖。
   * 不保存 Context,仅用于初始化 Preferences。
   */
  private constructor() {
    this.appPreferences = new AppPreferences();
    this.themeManager = ThemeManager.getInstance(this.appPreferences);
    this.chatTextStyleSettings = new ChatTextStyleSettings(this.appPreferences);
    const configStore: ProviderConfigStore = new ProviderConfigStore(this.appPreferences);
    this.providerConfigStore = configStore;
    const assetKeyStore: AssetStoreKeyStore = new AssetStoreKeyStore();
    this.assetKeyStore = assetKeyStore;
    const providerKeyStore: ProviderKeyStore = new ProviderKeyStore(assetKeyStore);
    this.providerKeyStore = providerKeyStore;
    const factory: DefaultProviderFactory = new DefaultProviderFactory(providerKeyStore);
    this.modelService = new ModelService(configStore, providerKeyStore, factory);
    this.characterStore = new CharacterStore();
    const characterAssetStore: CharacterAssetStore = new CharacterAssetStore();
    this.characterSelectionStore = new CharacterSelectionStore();
    this.dbHelper = new DbHelper();
    // CharacterRepository 使用与 Chat 相同的 DbHelper
    this.characterRepository = new CharacterRepository(this.dbHelper);
    // LorebookRepository 必须在 CharacterService 之前创建,以支持角色卡 character_book 自动导入
    this.lorebookRepository = new LorebookRepository(this.dbHelper);
    this.characterService = new CharacterService(
      this.characterRepository,
      this.characterSelectionStore,
      characterAssetStore,
      this.lorebookRepository
    );
    this.lorebookSelectionStore = new LorebookSelectionStore(this.appPreferences);
    this.characterMigrationService = new CharacterMigrationService(
      this.characterStore,
      this.characterRepository,
      this.characterSelectionStore,
      this.appPreferences
    );
    // Lorebook 仅作迁移源,由 AppServices 直接管理
    this.lorebookStore = new LorebookStore();
    // LorebookService 使用 Repository + SelectionStore
    this.lorebookService = new LorebookService(
      this.lorebookRepository,
      this.lorebookSelectionStore
    );
    // v45: 按需锁定世界书会话钉选服务(OnDemandPinned)
    this.lorebookPinService = new LorebookPinService(
      new ChatLorebookPinRepository(this.dbHelper),
      this.lorebookService
    );
    this.lorebookMigrationService = new LorebookMigrationService(
      this.lorebookStore,
      this.lorebookRepository,
      this.lorebookSelectionStore,
      this.appPreferences
    );
    // PromptPreset 领域组装
    this.promptPresetRepository = new PromptPresetRepository(this.dbHelper);
    this.promptPresetSelectionStore = new PromptPresetSelectionStore(this.appPreferences);
    this.promptPresetService = new PromptPresetService(
      this.promptPresetRepository,
      this.promptPresetSelectionStore
    );
    const macroReplacer: MacroReplacer = new MacroReplacer();
    this.promptBuilder = new PromptBuilder(this.lorebookService, macroReplacer);
    this.tokenCounter = new TokenCounter();
    this.historyTrimmer = new HistoryTrimmer(this.tokenCounter);
    // v8.3 Phase 2: 最近原始消息窗口选择器(去重 + 窗口 + 完整轮次)
    this.recentMessageSelector = new RecentMessageSelector(this.tokenCounter);
    // 持久化层组合:全部 Repository 共享同一 DbHelper 实例
    this.chatRepository = new ChatRepository(this.dbHelper);
    this.messageRepository = new MessageRepository(this.dbHelper);
    this.messageSwipeRepository = new MessageSwipeRepository(this.dbHelper);
    // T-6.4A: ConversationBranch 服务(单例,共享同一 DbHelper)
    this.conversationBranchRepository = new ConversationBranchRepository(this.dbHelper);
    this.chatMemoryRepository = new ChatMemoryRepository(this.dbHelper);
    this.memoryPersistenceService = new MemoryPersistenceService(
      this.dbHelper, this.chatMemoryRepository
    );
    this.conversationBranchPersistenceService = new ConversationBranchPersistenceService(
      this.dbHelper,
      this.conversationBranchRepository,
      this.messageRepository,
      this.messageSwipeRepository,
      this.memoryPersistenceService
    );
    this.chatPersistenceOperations = new ChatPersistenceOperations(
      this.dbHelper,
      this.chatRepository,
      this.messageRepository,
      this.messageSwipeRepository,
      this.conversationBranchPersistenceService,
      this.memoryPersistenceService,
      new ChatParticipantRepository(this.dbHelper)
    );
    // v8: MemoryService(依赖 ModelService + MemoryPersistenceService;v42 注入 ChatRepository 解析世界分组)
    this.memoryService = new MemoryService(
      this.memoryPersistenceService,
      this.modelService,
      DEFAULT_SUMMARY_POINTS,
      DEFAULT_MEMORY_TRIGGER,
      DEFAULT_CHAPTER_TRIGGER,
      this.chatRepository
    );
    // v8: ForkChatService(从分支创建独立对话)
    this.forkChatService = new ForkChatService(
      this.dbHelper,
      this.chatRepository,
      this.messageRepository,
      this.messageSwipeRepository,
      this.conversationBranchRepository,
      this.chatMemoryRepository,
      this.memoryPersistenceService
    );
    this.chatPersistenceService = new ChatPersistenceService(
      this.dbHelper,
      this.chatRepository,
      this.messageRepository,
      this.chatPersistenceOperations,
      this.conversationBranchPersistenceService
    );
    this.messageSwipePersistenceService = new MessageSwipePersistenceService(
      this.dbHelper,
      this.messageRepository,
      this.messageSwipeRepository,
      this.conversationBranchPersistenceService
    );
    this.chatParticipantRepository = new ChatParticipantRepository(this.dbHelper);
    // Persona 领域组装
    this.personaRepository = new PersonaRepository(this.dbHelper);
    this.personaSelectionStore = new PersonaSelectionStore(this.appPreferences);
    this.personaService = new PersonaService(this.personaRepository, this.personaSelectionStore);
    this.syncConfigStore = new SyncConfigStore(this.appPreferences);
    const marketHttpClient: HttpClient = new HarmonyHttpClient();
    const marketCacheStore: MarketCacheStore = new MarketCacheStore(this.appPreferences);
    const marketImportedMapStore: MarketImportedMapStore = new MarketImportedMapStore(this.appPreferences);
    this.marketService = new MarketService(marketHttpClient, marketCacheStore, marketImportedMapStore);
    // ChatBackgroundService 在 initialize 中 context 就绪后创建
  }

  /**
   * 初始化应用服务。
   * 幂等:重复调用返回同一 Promise。
   * 初始化失败时清理实例,允许后续重试。
   *
   * @param context ApplicationContext 或 UIAbility Context(稳定 Context,不保存)
   * @returns 初始化完成的 Promise
   */
  static initialize(context: common.Context): Promise<void> {
    if (AppServices.readyPromise !== null) {
      return AppServices.readyPromise;
    }
    const services: AppServices = new AppServices();
    AppServices.instance = services;
    // 保存 Context(用于 ChatBackgroundService 等需要 filesDir 的服务)
    // EntryAbility.onCreate 始终传入 UIAbilityContext,这里直接保存为 common.Context。
    services.appContext = context;
    AppServices.readyPromise = services.modelService.initialize(context)
      .then((): Promise<void> => services.appPreferences.initialize(context))
      .then((): Promise<void> => services.themeManager.initialize(context))
      .then(async (): Promise<void> => {
        await services.chatTextStyleSettings.load();
      })
      .then((): Promise<void> => services.dbHelper.initialize(context))
      .then((): Promise<void> => services.characterService.initialize(context))
      .then((): Promise<void> => services.characterStore.initialize(context))
      .then(async (): Promise<void> => {
        await services.characterMigrationService.migrateIfNeeded();
      })
      .then((): Promise<void> => services.lorebookStore.initialize(context))
      .then(async (): Promise<void> => {
        await services.lorebookMigrationService.migrateIfNeeded();
      })
      .then((): Promise<void> => services.lorebookService.initialize())
      .then((): Promise<void> => services.promptPresetService.initialize())
      .then((): Promise<void> => services.personaService.initialize())
      .then((): void => {
        // 创建 ChatBackgroundService(需要已初始化的 appPreferences + appContext)
        if (services.appContext !== null) {
          services.chatBackgroundService = new ChatBackgroundService(
            services.appContext, services.appPreferences);
        } else {
          Logger.warn(LOG_TAG, 'appContext is null, chatBackgroundService not created');
        }
        // 创建 ContextBudgetService(只需 appPreferences)
        services.contextBudgetService = new ContextBudgetService(services.appPreferences);
        // v46: 创建 MemoryLoadRefService(按需加载记忆引用,只需 appPreferences)
        services.memoryLoadRefService = new MemoryLoadRefService(services.appPreferences);
        // 创建 MarketImportService(需要 appContext 写入临时 PNG 文件)
        if (services.appContext !== null) {
          services.marketImportService = new MarketImportService(
            services.marketService,
            services.characterService,
            services.marketService.getImportedMapStore(),
            services.appContext
          );
        } else {
          Logger.warn(LOG_TAG, 'appContext is null, marketImportService not created');
        }
        // 创建 MarketTranslationService(使用免费翻译 + MarketCacheStore)
        services.marketTranslationService = new MarketTranslationService(
          services.modelService,
          services.marketService.getCacheStore()
        );
        // 创建 ChatArchiveService(T-CHAT.1 聊天归档导出,只需 Repository)
        services.chatArchiveService = new ChatArchiveService(
          services.chatRepository,
          services.messageRepository,
          services.messageSwipeRepository,
          services.conversationBranchRepository,
          services.characterRepository
        );
        // 创建 ChatArchiveImportService(T-CHAT.1 聊天归档导入,只需 Repository + DbHelper)
        services.chatArchiveImportService = new ChatArchiveImportService(
          services.dbHelper,
          services.chatRepository,
          services.messageRepository,
          services.messageSwipeRepository,
          services.conversationBranchRepository,
          services.characterRepository
        );
        // 创建 WebDavSyncService(云同步,需要 context)
        if (services.appContext !== null) {
          services.webDavSyncService = new WebDavSyncService(
            services.dbHelper,
            services.appPreferences,
            services.providerKeyStore,
            services.providerConfigStore,
            services.syncConfigStore,
            services.appContext
          );
          services.deepSeekBalanceService = new DeepSeekBalanceService(
            new HarmonyHttpClient(),
            services.providerKeyStore,
            services.providerConfigStore,
            services.appPreferences
          );
        }
        Logger.warn(LOG_TAG, 'AppServices initialized');
      })
      .catch((e: Object): void => {
        Logger.error(LOG_TAG, 'initialize failed: ' + (e as Error).message);
        AppServices.instance = null;
        AppServices.readyPromise = null;
        if (e instanceof DatabaseError) {
          throw e;
        }
        throw new Error('AppServices initialize failed: ' + (e as Error).message);
      });
    return AppServices.readyPromise;
  }

  /**
   * 等待初始化完成。
   * 页面在 aboutToAppear 中调用此方法,确保 modelService 可用。
   *
   * @returns 初始化完成的 Promise
   * @throws Error 当未调用 initialize 时
   */
  static whenReady(): Promise<void> {
    if (AppServices.readyPromise === null) {
      return Promise.reject(new Error('AppServices not initialized, call initialize(context) first'));
    }
    return AppServices.readyPromise;
  }

  /**
   * 获取已初始化的 AppServices 实例。
   * 必须在 whenReady() 完成后调用。
   *
   * @returns AppServices 实例
   * @throws Error 当未初始化时
   */
  static getInstance(): AppServices {
    if (AppServices.instance === null) {
      throw new Error('AppServices not initialized');
    }
    return AppServices.instance;
  }

  /**
   * 判断是否已开始初始化(不代表已完成)。
   * @returns 已调用 initialize 返回 true
   */
  static isStarted(): boolean {
    return AppServices.instance !== null;
  }

  /**
   * 获取 ModelService 实例。
   */
  static getModelService(): ModelService {
    return AppServices.getInstance().modelService;
  }

  /**
   * 获取 CharacterService 实例。
   */
  static getCharacterService(): CharacterService {
    return AppServices.getInstance().characterService;
  }

  /**
   * 获取 LorebookService 实例。
   */
  static getLorebookService(): LorebookService {
    return AppServices.getInstance().lorebookService;
  }

  /**
   * 获取 LorebookPinService 实例(v45 按需锁定世界书会话钉选)。
   */
  static getLorebookPinService(): LorebookPinService {
    return AppServices.getInstance().lorebookPinService;
  }

  /**
   * 获取 PromptPresetService 实例(T-6.1B 接入 Chat 后使用)。
   */
  static getPromptPresetService(): PromptPresetService {
    return AppServices.getInstance().promptPresetService;
  }

  /**
   * 获取 ConversationBranchPersistenceService 实例(T-6.4B-1.1)。
   * 用于 BranchMapPage 加载 Branch 列表和切换 Active Branch,无需创建完整 ChatService。
   */
  static getBranchPersistenceService(): ConversationBranchPersistenceService {
    return AppServices.getInstance().conversationBranchPersistenceService;
  }

  /**
   * 获取 MemoryService 实例(v8 长期记忆业务服务)。
   * 用于 MemoryManagementPage 等页面查询/编辑/清除当前 Branch Memory。
   */
  static getMemoryService(): MemoryService {
    return AppServices.getInstance().memoryService;
  }

  /**
   * 获取 MemoryPersistenceService 实例(v8 长期记忆持久化服务)。
   * 仅供 ChatService / ConversationBranchPersistenceService 等内部服务使用。
   */
  static getMemoryPersistenceService(): MemoryPersistenceService {
    return AppServices.getInstance().memoryPersistenceService;
  }

  /**
   * 获取 ForkChatService 实例(v8 从分支创建独立对话)。
   * 用于 ChatMessageActionSheet / BranchMapPage 等触发"从此处创建独立对话"。
   */
  static getForkChatService(): ForkChatService {
    return AppServices.getInstance().forkChatService;
  }

  /**
   * 获取 ContextBudgetService 实例(v8.1 per-chat 上下文预算服务)。
   * @throws Error 当未初始化或服务创建失败时
   */
  static getContextBudgetService(): ContextBudgetService {
    const service: ContextBudgetService | null = AppServices.getInstance().contextBudgetService;
    if (service === null) {
      throw new Error('ContextBudgetService not initialized');
    }
    return service;
  }

  /**
   * 获取 MemoryLoadRefService 实例(v46 按需加载记忆引用)。
   * 初始化未完成时返回 null。
   */
  static getMemoryLoadRefService(): MemoryLoadRefService | null {
    return AppServices.getInstance().memoryLoadRefService;
  }

  /**
   * 获取 TokenCounter 实例(v8.1 上下文占用估算)。
   * 用于 ContextBudgetViewModel 在页面侧重新估算分段 Token。
   */
  static getTokenCounter(): TokenCounter {
    return AppServices.getInstance().tokenCounter;
  }

  /**
   * 获取 ChatPersistenceService 实例。
   * 用于"对话记录"Tab 等不需要完整 ChatService 的场景(只查询会话列表 / 重命名)。
   */
  static getChatPersistenceService(): ChatPersistenceService {
    return AppServices.getInstance().chatPersistenceService;
  }

  /**
   * 获取 ChatBackgroundService 实例。
   * 用于聊天界面背景图导入、读取、删除。
   * 如果初始化时 appContext 不可用,返回 null。
   */
  static getChatBackgroundService(): ChatBackgroundService | null {
    return AppServices.getInstance().chatBackgroundService;
  }

  /**
   * 获取 MarketService 实例。
   * 用于市场 Tab 浏览、搜索、详情查看、PNG/JSON 下载。
   */
  static getMarketService(): MarketService {
    return AppServices.getInstance().marketService;
  }

  /**
   * 获取 MarketImportService 实例。
   * 用于市场角色卡导入(校验重复 + 下载 + 调用现有 CharacterService 导入流程)。
   * 如果初始化时 appContext 不可用,返回 null。
   */
  static getMarketImportService(): MarketImportService | null {
    return AppServices.getInstance().marketImportService;
  }

  /**
   * 获取 MarketTranslationService 实例。
   * 用于市场角色卡预览字段的中文翻译(复用 ModelService)。
   * 初始化完成后始终可用(无外部依赖)。
   */
  static getMarketTranslationService(): MarketTranslationService | null {
    return AppServices.getInstance().marketTranslationService;
  }

  /**
   * 获取 AppPreferences 实例(v9 引入)。
   * 用于 AppSettingsPage 等页面读写全局用户称呼等通用 KV 配置。
   */
  static getAppPreferences(): AppPreferences {
    return AppServices.getInstance().appPreferences;
  }

  /**
   * 获取全局主题权威实例(ARK-UI-THEME-1)。
   * 页面不保存独立 theme state,统一通过 ThemeManager 读取/设置。
   */
  static getThemeManager(): ThemeManager {
    return AppServices.getInstance().themeManager;
  }

  /**
   * 创建 ChatSessionListViewModel 实例。
   * 用于"对话记录"Tab 展示全部会话 + 角色信息 + 最后消息摘要 + 重命名。
   */
  static createChatSessionListViewModel(): ChatSessionListViewModel {
    const services: AppServices = AppServices.getInstance();
    return new ChatSessionListViewModel(
      services.chatPersistenceService,
      services.characterService
    );
  }

  /**
   * 创建新的 ChatService 实例。
   * 每次 ChatPage 进入时调用,保证生命周期独立。
   * 内部完成 ModelService、LorebookService、PromptBuilder、TokenCounter、HistoryTrimmer、
   * ChatPersistenceService 的依赖注入。
   *
   * 持久化服务为应用级共享实例(自身无页面状态),所有 ChatService 共用。
   * DbHelper 必须在 initialize() 完成后才允许 ChatService 加载会话,
   * 调用方需通过 AppServices.whenReady() 等待初始化完成后再创建 ChatService。
   *
   * @returns 新创建的 ChatService 实例
   */
  static createChatService(): ChatService {
    const services: AppServices = AppServices.getInstance();
    return new ChatService(
      services.modelService,
      services.lorebookService,
      services.promptBuilder,
      services.tokenCounter,
      services.historyTrimmer,
      services.chatPersistenceService,
      services.promptPresetService,
      services.messageSwipePersistenceService,
      services.conversationBranchPersistenceService,
      services.chatBackgroundService,
      services.memoryService,
      services.contextBudgetService,
      services.appPreferences,
      services.recentMessageSelector,
      services.lorebookPinService
    );
  }

  /**
   * 创建 PromptPresetListViewModel 实例。
   */
  static createPromptPresetListViewModel(): PromptPresetListViewModel {
    const services: AppServices = AppServices.getInstance();
    return new PromptPresetListViewModel(services.promptPresetService);
  }

  /**
   * 创建 PromptPresetEditViewModel 实例。
   * @param presetId 编辑已有 Preset 时传入 ID,新建时传入 undefined
   */
  static createPromptPresetEditViewModel(presetId?: string): PromptPresetEditViewModel {
    const services: AppServices = AppServices.getInstance();
    return new PromptPresetEditViewModel(services.promptPresetService);
  }

  /**
   * 获取 ChatArchiveService 实例(T-CHAT.1 聊天归档导出)。
   * 用于导出单个对话或角色全部对话。
   */
  static getChatArchiveService(): ChatArchiveService {
    const service: ChatArchiveService | null = AppServices.getInstance().chatArchiveService;
    if (service === null) {
      throw new Error('ChatArchiveService not initialized');
    }
    return service;
  }

  /**
   * 获取 ChatArchiveImportService 实例(T-CHAT.1 聊天归档导入)。
   * 用于从 .arktchat.json 文件导入对话。
   */
  static getChatArchiveImportService(): ChatArchiveImportService {
    const service: ChatArchiveImportService | null = AppServices.getInstance().chatArchiveImportService;
    if (service === null) {
      throw new Error('ChatArchiveImportService not initialized');
    }
    return service;
  }

  /**
   * 创建 ChatArchiveViewModel 实例(T-CHAT.1 聊天归档导入导出)。
   * 用于 ChatPage / ChatSessionRootView 触发导出与导入。
   * 每次调用返回新实例,内部封装文件选择器与 Service 调用。
   */
  static createChatArchiveViewModel(): ChatArchiveViewModel {
    const archiveService: ChatArchiveService = AppServices.getChatArchiveService();
    const importService: ChatArchiveImportService = AppServices.getChatArchiveImportService();
    return new ChatArchiveViewModel(archiveService, importService);
  }

  static getChatRepository(): ChatRepository {
    return AppServices.getInstance().chatRepository;
  }

  static getMessageRepository(): MessageRepository {
    return AppServices.getInstance().messageRepository;
  }

  /**
   * 获取 PersonaService 实例。
   * 用于 PersonaViewModel 等需要直接访问用户身份服务的场景。
   */
  static getPersonaService(): PersonaService {
    return AppServices.getInstance().personaService;
  }

  static getSyncConfigStore(): SyncConfigStore {
    return AppServices.getInstance().syncConfigStore;
  }

  static getWebDavSyncService(): WebDavSyncService {
    const service: WebDavSyncService | null = AppServices.getInstance().webDavSyncService;
    if (service === null) {
      throw new Error('WebDavSyncService not initialized');
    }
    return service;
  }

  static getDeepSeekBalanceService(): DeepSeekBalanceService {
    const service: DeepSeekBalanceService | null = AppServices.getInstance().deepSeekBalanceService;
    if (service === null) {
      throw new Error('DeepSeekBalanceService not initialized');
    }
    return service;
  }

  /**
   * 获取 WorldGroupService 实例(v42 世界分组章节记忆共享)。
   * 懒加载单例,首次调用时组装 WorldGroupRepository + ChatRepository。
   */
  static getWorldGroupService(): WorldGroupService {
    const services: AppServices = AppServices.getInstance();
    if (services.worldGroupService === null) {
      services.worldGroupService = new WorldGroupService(
        new WorldGroupRepository(services.dbHelper),
        services.chatRepository
      );
    }
    return services.worldGroupService;
  }
}