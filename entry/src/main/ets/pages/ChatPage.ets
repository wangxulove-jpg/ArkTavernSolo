/**
 * ChatPage 聊天页面(UI-CHAT-01 视觉重构)
 *
 * 设计依据:
 * - docs/ui_reference/generated/pages/chat_page.md
 * - docs/ui_reference/generated/screens/CHAT_PAGE_009.md
 * - docs/ui_reference/generated/glm_context.md 1.9 / 2.x
 *
 * 视觉结构:
 * - TopNavigation:返回 + 汉堡(打开会话列表) + 头像 + 角色名 + 更多(打开 ChatMoreMenuSheet)
 * - MessageArea:Scroll + ForEach,消息气泡由 ChatMessageBubble 渲染
 * - OptionalFloatingControls:回到底部 + 再试一次(条件渲染)
 * - InputArea:TextArea + 发送/停止按钮
 * - ConditionalOverlays:会话列表 / 更多菜单 / 消息操作菜单 / 清空确认
 *
 * 业务约束:
 * - 不显示无功能按钮(全屏 / 加号 / 齿轮未实现不显示)
 * - 不显示字数统计(ChatViewModel 无 4000 字限制,不引入虚假限制)
 * - 再试一次仅在 canRegenerate && !isGenerating && messages.length > 0 时显示
 * - 复用 ChatViewModel 所有接口,不修改业务逻辑
 * - 颜色全部使用 $r('app.color.*') 资源,自动适配深色模式
 */

import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { LorebookEntry } from '../models/Lorebook';
import { AiLorebookChangeSet, AiLorebookAdd, AiLorebookUpdate, AiLorebookDelete } from '../models/LorebookAiTypes';
import { AiLorebookMode } from '../services/ai/AiLorebookService';
import { LorebookPanelBook, LorebookPanelData } from '../viewmodels/ChatViewModel';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatMessageRenderState } from '../models/ChatMessageRenderState';
import { MessageSwipeSummary, MAX_SWIPE_CANDIDATES } from '../models/MessageSwipe';
import { MessageSwipeControls } from '../components/MessageSwipeControls';
import { HistoricalMessageEditDialog } from '../components/HistoricalMessageEditDialog';
import { ChatMessageBubble } from '../components/ChatMessageBubble';
import { ImpersonateCandidatesPanel } from '../components/ImpersonateCandidatesPanel';
import { ChatMessageDataSource } from '../components/ChatMessageDataSource';
import { ChatMessageActionSheet, MessageAction } from '../components/ChatMessageActionSheet';
import { ChatMoreMenuSheet } from '../components/ChatMoreMenuSheet';
import { CharacterImageView } from '../components/CharacterImageView';
import { ColorWheelPicker } from '../components/ColorWheelPicker';
import { promptAction, router, window, mediaquery, display } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { motion } from '@kit.MultimodalAwarenessKit';
import { inputMethod } from '@kit.IMEKit';
import { AppServices } from '../services/AppServices';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import {
  ChatTextColorMode,
  ChatMarkdownColorTheme,
  DEFAULT_BODY_TEXT_COLOR,
  DEFAULT_EMPHASIS_TEXT_COLOR,
  DEFAULT_DIALOGUE_TEXT_COLOR,
  DEFAULT_ACTION_TEXT_COLOR,
  DEFAULT_CODE_TEXT_COLOR,
  DEFAULT_LINK_TEXT_COLOR,
  DEFAULT_QUOTE_TEXT_COLOR,
  DEFAULT_USER_TEXT_COLOR,
  getLightColorTheme,
  getDarkColorTheme,
  isValidHexColor,
  normalizeHexColor
} from '../utils/ChatTextColorTheme';
import { ChatBackgroundConfig } from '../services/ChatBackgroundService';
import { ContextBudgetViewModel } from '../viewmodels/ContextBudgetViewModel';
import { ChatArchiveViewModel } from '../viewmodels/ChatArchiveViewModel';
import { ContextBudgetSnapshotStore } from '../services/ContextBudgetSnapshotStore';
import {
  ContextBudgetStats
} from '../services/ContextBudgetEstimator';
import { ForkChatMode } from '../models/ForkChatOptions';
import { ChatSessionListPanel } from '../components/ChatSessionListPanel';
import { Character, resolveCharacterDisplayName } from '../models/Character';
import { Persona } from '../models/Persona';
import { Logger } from '../utils/Logger';
import { MacroReplacer } from '../services/MacroReplacer';
import { ThemePalette } from '../theme/ThemePalette';
import { TtsService } from '../services/TtsService';
import { EdgeTtsService } from '../services/EdgeTtsService';
import { TtsReadMode } from '../models/TtsReadMode';
import { TtsEngine } from '../models/TtsEngine';

const LOG_TAG: string = 'ChatPage';

/** 显示层宏替换(无状态,单例复用)。仅替换名字类宏,供气泡/开场白展示。 */
const displayMacroReplacer: MacroReplacer = new MacroReplacer();

/** 自定义配色目标字段(语义化:正文/加粗斜体/对白/动作/代码/链接/引用/用户) */
type CustomColorTarget =
  | 'body' | 'emphasis' | 'dialogue' | 'action'
  | 'code' | 'link' | 'quote' | 'user';

@Entry
@Component
struct ChatPage {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @State viewModel: ChatViewModel | null = null;
  /** 业务消息列表(@State 用于触发消息源数据变更,ForEach 不再直接使用) */
  @State messages: ChatMessage[] = [];
  /** 稳定渲染状态列表(@Observed,ForEach 数据源,key 固定为 messageId) */
  @State messageStates: ChatMessageRenderState[] = [];
  /** messageId → RenderState 缓存(确保同一消息长期对应同一实例) */
  private stateMap: Map<string, ChatMessageRenderState> = new Map<string, ChatMessageRenderState>();
  /** 当前角色对象(用于头像) */
  @State character: Character | null = null;
  /** v11 富文本样式设置 */
  @State chatTextStyle: ChatTextStyle | null = null;
  /** 是否显示更多菜单 */
  @State showMoreMenu: boolean = false;
  /** 是否显示消息操作菜单 */
  @State showActionSheet: boolean = false;
  /** 消息操作菜单目标消息 */
  @State actionSheetMsg: ChatMessage | null = null;
  /** 是否显示清空确认 */
  @State showClearConfirm: boolean = false;
  /** 旁白输入模式是否激活 */
  @State narratorModeActive: boolean = false;
  /** TTS 服务实例(离线引擎) */
  private ttsService: TtsService = new TtsService();
  /** TTS 服务实例(Edge 在线引擎) */
  private edgeTtsService: EdgeTtsService = new EdgeTtsService();
  /** 当前 TTS 引擎 */
  @State ttsEngine: TtsEngine = TtsEngine.Offline;
  /** TTS 是否正在朗读 */
  @State ttsIsSpeaking: boolean = false;
  /** v9: 是否显示本对话称呼覆盖编辑对话框 */
  @State showUserNameOverrideDialog: boolean = false;
  /** v9: 对话称呼输入草稿(对话框中使用) */
  @State userNameOverrideDraft: string = '';
  /** v9: 当前生效的用户称呼(供 ChatMoreMenuSheet 展示) */
  @State resolvedUserName: string = '';
  /** v9: 当前对话级覆盖(供 ChatMoreMenuSheet 展示) */
  @State currentUserNameOverride: string = '';
  /** 是否显示 Persona 选择 ActionSheet */
  @State showPersonaPicker: boolean = false;
  /** Persona 列表(供 ActionSheet 选择) */
  @State personaOptions: Persona[] = [];
  /** 当前生效的身份名称(供 ChatMoreMenuSheet 展示) */
  @State resolvedPersonaName: string = '';
  /** v42: 是否显示"新建章节"开场白选择器 */
  @State showChapterGreetingPicker: boolean = false;
  /** v42: 开场白池(选择器预览列表) */
  @State chapterGreetingPool: string[] = [];
  /** v42: 新建章节进行中(防止重复点击) */
  @State chapterCreateBusy: boolean = false;
  /** 是否显示 Fork 模式选择弹窗 */
  @State showForkModePicker: boolean = false;
  /** Fork 操作目标消息 ID */
  private forkTargetMessageId: string = '';
  /** 上下文预算 ViewModel(v8.1) */
  @State budgetViewModel: ContextBudgetViewModel | null = null;
  /** 当前快照统计(由 ChatService 写入) */
  @State budgetStats: ContextBudgetStats | null = null;

  @StorageLink('branchChangeSeq') @Watch('onBranchChangeSeqChanged') branchChangeSeq: number = 0;
  /** 聊天背景配置变更通知(由 ChatBackgroundSettingsPage 通过 AppStorage.setOrCreate 触发) */
  @StorageProp('chatBgConfigVersion') @Watch('onChatBgConfigVersionChanged') chatBgConfigVersion: number = 0;
  /** 上下文预算配置变更通知(由 ContextBudgetPage 通过 AppStorage.setOrCreate 触发) */
  @StorageProp('chatBudgetConfigVersion') @Watch('onBudgetConfigVersionChanged') chatBudgetConfigVersion: number = 0;
  /** 记忆变更通知(由记忆生成/删除后通过 AppStorage.setOrCreate 触发) */
  @StorageProp('chatMemoryVersion') @Watch('onMemoryVersionChanged') chatMemoryVersion: number = 0;
  /** 聊天背景配置(为 null 表示未加载) */
  @State chatBgConfig: ChatBackgroundConfig | null = null;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  private scroller: Scroller = new Scroller();
  /** 懒加载数据源(配合 LazyForEach,仅构建可视区域气泡) */
  private dataSource: ChatMessageDataSource = new ChatMessageDataSource();
  private lastMessageCount: number = 0;
  private editDialogController: CustomDialogController | null = null;
  private editingMessageId: string = '';
  /** 键盘高度变化监听句柄 */
  private keyboardHeightChangeHandler: ((height: number) => void) | null = null;
  /** 主窗口实例(用于注销监听) */
  private mainWindow: window.Window | null = null;
  /** 跳转到 PromptPresetListPage 后返回时刷新当前 preset 名 */
  private pendingRefreshPresetName: boolean = false;
  /** 跳转到 BranchMapPage 后返回时重新加载消息和分支状态 */
  private pendingReloadAfterBranchChange: boolean = false;
  /** 已加载过背景配置的 chatId,避免 onMessagesUpdate 反复加载 */
  private lastLoadedBgChatId: string = '';
  /** 键盘弹起延迟滚动定时器 ID(-1 表示无 pending) */
  private keyboardScrollTimerId: number = -1;

  /** T-CHAT.1: 聊天归档 ViewModel(导出当前聊天/角色全部聊天) */
  @State archiveViewModel: ChatArchiveViewModel | null = null;
  /** T-CHAT.1: 导出进行中提示 */
  @State archiveBusy: boolean = false;

  /** 气泡背景不透明度(0.40~0.90,默认 0.65,仅控制背景 Alpha) */
  @State chatBubbleOpacity: number = 0.65;

  /**
   * 字体配色模式(AUTO / LIGHT / DARK / CUSTOM)。
   * 默认 AUTO:保持 ChatRichText 默认资源颜色。
   * 与 chatBubbleOpacity 完全独立:模式只控制文字颜色,不影响气泡背景透明度。
   * 持久化到 Preferences,跨页面生命周期保持。
   */
  @State chatTextColorMode: string = ChatTextColorMode.AUTO;

  /** 自定义模式下普通正文颜色(#RRGGBB) */
  @State chatBodyTextColor: string = DEFAULT_BODY_TEXT_COLOR;

  /** 自定义模式下加粗/斜体颜色(#RRGGBB) */
  @State chatEmphasisColor: string = DEFAULT_EMPHASIS_TEXT_COLOR;

  /** 自定义模式下对白颜色(#RRGGBB) */
  @State chatDialogueColor: string = DEFAULT_DIALOGUE_TEXT_COLOR;

  /** 自定义模式下动作/旁白颜色(#RRGGBB) */
  @State chatActionColor: string = DEFAULT_ACTION_TEXT_COLOR;

  /** 自定义模式下代码颜色(#RRGGBB) */
  @State chatCodeColor: string = DEFAULT_CODE_TEXT_COLOR;

  /** 自定义模式下链接颜色(#RRGGBB) */
  @State chatLinkColor: string = DEFAULT_LINK_TEXT_COLOR;

  /** 自定义模式下引用块颜色(#RRGGBB) */
  @State chatQuoteColor: string = DEFAULT_QUOTE_TEXT_COLOR;

  /** 自定义模式下用户消息文字颜色(#RRGGBB) */
  @State chatUserTextColor: string = DEFAULT_USER_TEXT_COLOR;

  /** 显示设置面板可见性(轻量卡片,非 Dialog) */
  @State chatAppearancePanelVisible: boolean = false;

  /** 世界书面板可见性 */
  @State statusPanelVisible: boolean = false;

  // ===== Prompt Cache 命中率 =====
  @State cacheHitRatio: number = -1;
  @State cacheCachedTokens: number = 0;
  @State cachePromptTokens: number = 0;

  // ===== DeepSeek 余额 =====
  @State deepSeekBalanceText: string = '';
  @State showDeepSeekBalance: boolean = false;

  // ===== 状态/世界书面板(T-7.x) =====
  /** AI 操作区是否展开 */
  @State aiEntryVisible: boolean = false;
  /** AI 请求进行中 */
  @State aiLoading: boolean = false;
  /** AI 指令输入框内容 */
  @State aiPromptText: string = '';
  /** AI 操作模式:worldbook / extract */
  @State aiMode: string = 'worldbook';
  /** 待确认的世界书变更集(非空时显示预览) */
  @State pendingChangeSet: AiLorebookChangeSet | null = null;
  /** 变更预览中展开中的提案项 key(点击展开/收起关键词与内容) */
  @State expandedAiPreviewKey: string = '';
  /** 世界书条目展开中的 ID(点击展开/收起内容) */
  @State expandedEntryId: string = '';
  /** 世界书面板展示数据(由 viewModel.lorebookPanelData 同步) */
  @State lorebookPanelData: LorebookPanelData | null = null;
  /** 世界书面板刷新版本号(每次同步递增,强制 ForEach 重建,解决条目更新后不刷新) */
  @State lorebookPanelVersion: number = 0;

  /** 色盘选择器当前编辑的目标字段(null 表示关闭) */
  @State colorPickerTarget: CustomColorTarget | null = null;

  /** 当前是否为深色模式(用于动态计算气泡背景 RGB) */
  @State isDarkMode: boolean = false;

  /** 深色模式媒体查询监听器(aboutToDisappear 注销) */
  private darkModeListener: mediaquery.MediaQueryListener | null = null;

  /** 气泡不透明度持久化 Preferences key */
  private static readonly PREF_KEY_BUBBLE_OPACITY: string = 'chat_bubble_opacity';

  /** 字体配色持久化 Preferences key (存储 JSON: mode + 4 个颜色值) */
  private static readonly PREF_KEY_TEXT_COLOR: string = 'chat_text_color';

  /** 键盘高度(vp),0 表示键盘未弹起。OFFSET 模式下用于消息列表底部占位与输入栏间距判断 */
  @State keyboardHeight: number = 0;

  /** 聊天内容显示范围比例持久化 (0.5~1.0, 默认 1.0) */
  private static readonly PREF_KEY_CONTENT_HEIGHT_RATIO: string = 'chat_content_height_ratio';

  /** 发送按钮位置偏好 key: 'left' | 'right' */
  private static readonly PREF_KEY_SEND_BUTTON_POS: string = 'chat_send_button_position';
  /** 智感握姿开关偏好 key */
  private static readonly PREF_KEY_SMART_GRIP: string = 'chat_smart_grip_enabled';

  /** 发送按钮位置: true = 左侧, false = 右侧 */
  @State sendButtonLeft: boolean = false;

  /** 智感握姿开关 */
  @State smartGripEnabled: boolean = false;

  /** 智感握姿:当前握持手是否为左手(用于自动调整按钮位置) */
  @State gripIsLeftHand: boolean = false;

  /** 智感握姿监听回调引用(aboutToDisappear 注销用) */
  private gripCallback: ((status: number) => void) | null = null;

  /**
   * 聊天内容显示范围比例 (0.0~1.0, 默认 1.0)。
   *
   * 1.0 = 占满顶部和底部; 0.0 = 全部擦除, 只显示背景图。
   * 背景图保持占满全屏不动。
   */
  @State chatContentHeightRatio: number = 1.0;

  aboutToAppear(): void {
    const modelService = AppServices.getModelService();
    const characterService = AppServices.getCharacterService();
    const promptPresetService = AppServices.getPromptPresetService();
    const chatService = AppServices.createChatService();
    this.chatTextStyle = AppServices.getInstance().chatTextStyleSettings.get();
    const vm: ChatViewModel = new ChatViewModel(
      chatService, modelService, characterService, promptPresetService
    );
    vm.onMessagesUpdate = (msgs: ChatMessage[]): void => {
      // 同步业务数据 + 同步稳定 RenderState 列表
      this.messages = msgs;
      this.syncRenderStates(msgs);
      this.maybeLoadChatBackground();
      // 流式 delta 期间不刷新预算(避免高频 token 估算拖慢 UI)。
      // 只在非流式状态刷新:用户消息加入 / 回复完成 / 编辑删除 / Swipe / 分支切换 / 页面进入。
      // 其他触发点(onPageShow / onBudgetConfigVersionChanged / onBranchChangeSeqChanged)保持不变。
      const isStreaming: boolean = msgs.length > 0 && msgs[msgs.length - 1].isStreaming === true;
      if (!isStreaming) {
        this.refreshBudgetSnapshot();
      }
    };
    // Prompt Cache 命中率:同步最近一次回复的缓存统计
    vm.onCacheStatsUpdate = (cachedTokens: number, promptTokens: number, hitRatio: number): void => {
      this.cacheCachedTokens = cachedTokens;
      this.cachePromptTokens = promptTokens;
      this.cacheHitRatio = hitRatio;
    };
    this.viewModel = vm;

    // 初始化上下文预算 ViewModel(v8.1)
    // 复用 line 109 的 modelService,避免重复声明
    const budgetService = AppServices.getContextBudgetService();
    const tokenCounter = AppServices.getTokenCounter();
    this.budgetViewModel = new ContextBudgetViewModel(
      budgetService, modelService, tokenCounter
    );

    const pendingChatId: string = AppStorage.get<string>('pendingChatId') ?? '';
    const pendingCharacterId: string = AppStorage.get<string>('pendingCharacterId') ?? '';
    if (pendingChatId.length > 0) {
      AppStorage.set<string>('pendingChatId', '');
      if (pendingCharacterId.length > 0) {
        AppStorage.set<string>('pendingCharacterId', '');
        this.loadCharacterAvatar(pendingCharacterId);
        vm.initialize(pendingCharacterId).then((): Promise<void> => vm.selectSession(pendingChatId))
          .then((): void => { this.refreshUserNameDisplay(); this.refreshPersonaDisplay(); })
          .catch((): void => {});
      } else {
        vm.initialize().then((): Promise<void> => vm.selectSession(pendingChatId))
          .then((): void => { this.refreshUserNameDisplay(); this.refreshPersonaDisplay(); })
          .catch((): void => {});
      }
    } else if (pendingCharacterId.length > 0) {
      AppStorage.set<string>('pendingCharacterId', '');
      this.loadCharacterAvatar(pendingCharacterId);
      // 角色卡"新建对话"入口:forceNew=true 跳过 openLatestSession,直接创建新会话
      vm.initialize(pendingCharacterId, true)
        .then((): void => { this.refreshUserNameDisplay(); this.refreshPersonaDisplay(); })
        .catch((): void => {});
    } else {
      vm.initialize();
      // 从当前角色加载头像
      this.loadCurrentCharacterAvatar();
      this.refreshUserNameDisplay();
      this.refreshPersonaDisplay();
    }
    this.registerKeyboardListener();
    this.registerDarkModeListener();
    this.loadPersistedBubbleOpacity();
    this.loadPersistedTextColor();
    this.loadPersistedContentHeightRatio();
    this.loadPersistedSendButtonPos();
    this.loadPersistedSmartGrip();
    this.registerGripListener();
    this.loadDeepSeekBalance();
    this.loadTtsSettings();
  }

  /**
   * 从 Preferences 读取持久化的气泡不透明度。
   * 读取失败或未初始化时静默使用默认值 0.65。
   */
  private loadPersistedBubbleOpacity(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.getString(ChatPage.PREF_KEY_BUBBLE_OPACITY, '0.65')
        .then((value: string): void => {
          const parsed: number = parseFloat(value);
          if (Number.isFinite(parsed)) {
            this.chatBubbleOpacity = this.normalizeChatBubbleOpacity(parsed);
          }
        })
        .catch((_e: Object): void => {
          // 读取失败静默使用默认值
        });
    } catch (_e) {
      // AppServices 未初始化时静默使用默认值
    }
  }

  /**
   * 将气泡不透明度持久化到 Preferences。
   * 写入失败静默忽略(不影响 UI 交互)。
   */
  private persistBubbleOpacity(value: number): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.putString(ChatPage.PREF_KEY_BUBBLE_OPACITY, value.toString())
        .catch((_e: Object): void => {
          // 写入失败静默忽略
        });
    } catch (_e) {
      // AppServices 未初始化时静默忽略
    }
  }

  /**
   * 加载持久化的聊天内容显示范围比例。
   * 范围 0.0~1.0, 默认 1.0。
   */
  private loadPersistedContentHeightRatio(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.getString(ChatPage.PREF_KEY_CONTENT_HEIGHT_RATIO, '1.0')
        .then((value: string): void => {
          const ratio: number = parseFloat(value);
          if (!isNaN(ratio) && ratio >= 0.0 && ratio <= 1.0) {
            this.chatContentHeightRatio = ratio;
          }
        })
        .catch((_e: Object): void => {
          // 读取失败静默使用默认值
        });
    } catch (_e) {
      // AppServices 未初始化时静默使用默认值
    }
  }

  /**
   * 持久化聊天内容显示范围比例。
   */
  private persistContentHeightRatio(ratio: number): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.putString(ChatPage.PREF_KEY_CONTENT_HEIGHT_RATIO, String(ratio))
        .catch((_e: Object): void => {
          // 写入失败静默忽略
        });
    } catch (_e) {
      // AppServices 未初始化时静默忽略
    }
  }

  private loadPersistedSendButtonPos(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.getString(ChatPage.PREF_KEY_SEND_BUTTON_POS, 'right')
        .then((value: string): void => {
          this.sendButtonLeft = value === 'left';
        })
        .catch((_e: Object): void => {});
    } catch (_e) {}
  }

  private persistSendButtonPos(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.putString(ChatPage.PREF_KEY_SEND_BUTTON_POS, this.sendButtonLeft ? 'left' : 'right')
        .catch((_e: Object): void => {});
    } catch (_e) {}
  }

  private loadPersistedSmartGrip(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.getBoolean(ChatPage.PREF_KEY_SMART_GRIP, false)
        .then((value: boolean): void => {
          this.smartGripEnabled = value;
        })
        .catch((_e: Object): void => {});
    } catch (_e) {}
  }

  private loadTtsSettings(): void {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      this.edgeTtsService.setContext(ctx);

      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.getString('tts_engine', '0')
        .then((value: string): void => {
          const engine: number = parseInt(value, 10);
          this.ttsEngine = isNaN(engine) ? TtsEngine.Offline : (engine === TtsEngine.Edge ? TtsEngine.Edge : TtsEngine.Offline);
        })
        .catch((_e: Object): void => {});
      prefs.getString('tts_mode', '0')
        .then((value: string): void => {
          const mode: number = parseInt(value, 10);
          const readMode: TtsReadMode = isNaN(mode) ? TtsReadMode.Off : (mode as TtsReadMode);
          this.ttsService.readMode = readMode;
          this.edgeTtsService.readMode = readMode;
        })
        .catch((_e: Object): void => {});
      prefs.getString('tts_speed', '1.0')
        .then((value: string): void => {
          const speed: number = parseFloat(value);
          if (!isNaN(speed)) {
            this.ttsService.speed = speed;
            this.edgeTtsService.speed = speed;
          }
        })
        .catch((_e: Object): void => {});
      prefs.getString('tts_volume', '1.0')
        .then((value: string): void => {
          const volume: number = parseFloat(value);
          if (!isNaN(volume)) {
            this.ttsService.volume = volume;
            this.edgeTtsService.volume = volume;
          }
        })
        .catch((_e: Object): void => {});
      prefs.getString('tts_pitch', '1.0')
        .then((value: string): void => {
          const pitch: number = parseFloat(value);
          if (!isNaN(pitch)) {
            this.ttsService.pitch = pitch;
            this.edgeTtsService.pitch = pitch;
          }
        })
        .catch((_e: Object): void => {});
      prefs.getString('tts_voice_person', '13')
        .then((value: string): void => {
          const person: number = parseInt(value, 10);
          if (!isNaN(person)) {
            this.ttsService.voicePerson = person;
            if (person === 8) {
              this.ttsService.language = 'en-US';
            } else {
              this.ttsService.language = 'zh-CN';
            }
          }
        })
        .catch((_e: Object): void => {});
      prefs.getString('tts_edge_voice', 'zh-CN-XiaoxiaoNeural')
        .then((value: string): void => {
          if (value.length > 0) {
            this.edgeTtsService.voiceName = value;
          }
        })
        .catch((_e: Object): void => {});
    } catch (_e) {}
  }

  private persistSmartGrip(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.putBoolean(ChatPage.PREF_KEY_SMART_GRIP, this.smartGripEnabled)
        .catch((_e: Object): void => {});
    } catch (_e) {}
  }

  private registerGripListener(): void {
    if (this.gripCallback !== null) {
      return;
    }
    this.gripCallback = (status: number): void => {
      if (!this.smartGripEnabled) {
        return;
      }
      // HoldingHandStatus: 0=NOT_HELD, 1=LEFT_HAND, 2=RIGHT_HAND, 3=BOTH_HANDS
      this.gripIsLeftHand = status === 1;
    };
    try {
      motion.on('holdingHandChanged', this.gripCallback);
    } catch (_e) {
      // 设备不支持智感握姿,静默忽略
    }
  }

  private unregisterGripListener(): void {
    if (this.gripCallback === null) {
      return;
    }
    try {
      motion.off('holdingHandChanged', this.gripCallback);
    } catch (_e) {
      // 忽略注销失败
    }
    this.gripCallback = null;
  }

  private loadDeepSeekBalance(): void {
    try {
      const service = AppServices.getDeepSeekBalanceService();
      service.isShowBalance().then((show: boolean): void => {
        this.showDeepSeekBalance = show;
        if (show) {
          service.isDeepSeekProvider().then((isDs: boolean): void => {
            if (isDs) {
              service.fetchBalance().then((info): void => {
                if (info !== null) {
                  this.deepSeekBalanceText = info.totalBalance + ' ' + info.currency;
                }
              }).catch((): void => {
              });
            }
          }).catch((): void => {
          });
        }
      }).catch((): void => {
      });
    } catch (_e) {
    }
  }

  private isSendButtonOnLeft(): boolean {
    if (this.smartGripEnabled) {
      return this.gripIsLeftHand;
    }
    return this.sendButtonLeft;
  }

  /**
   * 从 Preferences 读取持久化的字体配色。
   *
   * 存储 JSON 格式:
   *   { "mode": "AUTO|LIGHT|DARK|CUSTOM",
   *     "body": "#RRGGBB", "emphasis": "#RRGGBB", "dialogue": "#RRGGBB",
   *     "action": "#RRGGBB", "code": "#RRGGBB", "link": "#RRGGBB",
   *     "quote": "#RRGGBB", "user": "#RRGGBB" }
   *
   * 读取失败或未初始化时静默使用默认值。
   * 非法字段回退为对应默认值,确保渲染安全。
   */
  private loadPersistedTextColor(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.getString(ChatPage.PREF_KEY_TEXT_COLOR, '')
        .then((value: string): void => {
          if (value.length === 0) {
            return;
          }
          const obj: Record<string, Object> = JSON.parse(value) as Record<string, Object>;
          const mode: Object | undefined = obj['mode'];
          if (typeof mode === 'string') {
            this.chatTextColorMode = mode;
          }
          this.chatBodyTextColor = this.readColorField(obj, 'body', DEFAULT_BODY_TEXT_COLOR);
          this.chatEmphasisColor = this.readColorField(obj, 'emphasis', DEFAULT_EMPHASIS_TEXT_COLOR);
          this.chatDialogueColor = this.readColorField(obj, 'dialogue', DEFAULT_DIALOGUE_TEXT_COLOR);
          this.chatActionColor = this.readColorField(obj, 'action', DEFAULT_ACTION_TEXT_COLOR);
          this.chatCodeColor = this.readColorField(obj, 'code', DEFAULT_CODE_TEXT_COLOR);
          this.chatLinkColor = this.readColorField(obj, 'link', DEFAULT_LINK_TEXT_COLOR);
          this.chatQuoteColor = this.readColorField(obj, 'quote', DEFAULT_QUOTE_TEXT_COLOR);
          this.chatUserTextColor = this.readColorField(obj, 'user', DEFAULT_USER_TEXT_COLOR);
        })
        .catch((_e: Object): void => {
          // 读取失败静默使用默认值
        });
    } catch (_e) {
      // AppServices 未初始化时静默使用默认值
    }
  }

  /** 从持久化 JSON 对象读取单个颜色字段,非法时回退默认值。 */
  private readColorField(obj: Record<string, Object>, key: string, fallback: string): string {
    const value: Object | undefined = obj[key];
    if (typeof value === 'string' && isValidHexColor(value)) {
      return value.toUpperCase();
    }
    return fallback;
  }

  /**
   * 将当前字体配色持久化到 Preferences。
   *
   * 包含模式 + 8 个语义化颜色值,即使从 CUSTOM 切回 AUTO 也写入当前状态,
   * 确保下次进入页面时恢复用户最后的配置。
   * 写入失败静默忽略(不影响 UI 交互)。
   */
  private persistTextColor(): void {
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      const obj: Record<string, string> = {
        'mode': this.chatTextColorMode,
        'body': this.chatBodyTextColor,
        'emphasis': this.chatEmphasisColor,
        'dialogue': this.chatDialogueColor,
        'action': this.chatActionColor,
        'code': this.chatCodeColor,
        'link': this.chatLinkColor,
        'quote': this.chatQuoteColor,
        'user': this.chatUserTextColor
      };
      prefs.putString(ChatPage.PREF_KEY_TEXT_COLOR, JSON.stringify(obj))
        .catch((_e: Object): void => {
          // 写入失败静默忽略
        });
    } catch (_e) {
      // AppServices 未初始化时静默忽略
    }
  }

  /**
   * 注册深色模式监听器,实时更新 isDarkMode 状态。
   * 用于动态计算气泡背景 RGB(light/dark 资源值不同)。
   */
  private registerDarkModeListener(): void {
    try {
      const listener = mediaquery.matchMediaSync('(dark-mode: true)');
      this.isDarkMode = listener.matches;
      listener.on('change', (result: mediaquery.MediaQueryResult): void => {
        this.isDarkMode = result.matches;
      });
      this.darkModeListener = listener;
    } catch (_e) {
      // mediaquery 不可用时默认浅色模式
      this.isDarkMode = false;
    }
  }

  aboutToDisappear(): void {
    this.unregisterKeyboardListener();
    this.unregisterGripListener();
    // 注销深色模式监听器
    if (this.darkModeListener !== null) {
      try {
        this.darkModeListener.off('change');
      } catch (_e) {
        // 忽略注销失败
      }
      this.darkModeListener = null;
    }
    // 关闭显示设置面板
    this.chatAppearancePanelVisible = false;
    // 关闭世界书面板
    this.statusPanelVisible = false;
    // 关闭 TTS 引擎
    this.ttsService.shutdown();
    this.edgeTtsService.shutdown();
    this.cacheHitRatio = -1;
    this.cacheCachedTokens = 0;
    this.cachePromptTokens = 0;
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
      this.viewModel = null;
    }
    this.messages = [];
    this.messageStates = [];
    this.stateMap.clear();
    this.dataSource.clear();
    const v: number = AppStorage.get<number>('chatListVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatListVersion', v + 1);
  }

  onPageShow(): void {
    // 处理从二级页面返回后的回调(替代原 pushPathByName 的 onPop 回调)
    if (this.pendingRefreshPresetName) {
      this.pendingRefreshPresetName = false;
      if (this.viewModel !== null && !this.viewModel!.isDisposed) {
        this.viewModel!.refreshCurrentPresetName();
      }
    }
    if (this.pendingReloadAfterBranchChange) {
      this.pendingReloadAfterBranchChange = false;
      if (this.viewModel !== null && !this.viewModel!.isDisposed) {
        this.viewModel!.reloadAfterBranchChange().catch((): void => {});
      }
    }
    // 从二级页面返回时刷新上下文占用统计
    // 失效缓存确保使用最新配置(如 recentWindowTarget)重建
    if (this.viewModel !== null && !this.viewModel!.isDisposed) {
      this.viewModel!.invalidateEstimateCache();
    }
    this.refreshBudgetSnapshot();
    this.loadTtsSettings();
  }

  onBackPress(): boolean {
    if (this.showActionSheet) {
      this.showActionSheet = false;
      this.actionSheetMsg = null;
      return true;
    }
    if (this.showMoreMenu) {
      this.showMoreMenu = false;
      return true;
    }
    if (this.showClearConfirm) {
      this.showClearConfirm = false;
      return true;
    }
    if (this.viewModel !== null) {
      if (this.viewModel!.showDeleteSessionConfirm) {
        this.viewModel!.cancelDeleteSession();
        return true;
      }
      if (this.viewModel!.showSessionList) {
        this.viewModel!.closeSessionList();
        return true;
      }
    }
    return false;
  }

  build() {
    Stack() {
        // ===== 背景层(最底层,位于消息列表之下)=====
        // 仅在配置已加载、启用、且图片存在时渲染。否则透出根 Stack 的 page_background。
        if (this.chatBgConfig !== null
          && this.chatBgConfig!.enabled
          && this.chatBgConfig!.imageUri.length > 0) {
          // 背景图(应用模糊度,模糊后图像边缘有透明像素,由 page_background 兜底)
          // expandSafeArea(KEYBOARD):OFFSET 模式下键盘弹出时背景层不上抬,保持全屏固定不动
          Image(this.chatBgConfig!.imageUri)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .blur(this.chatBgConfig!.blur)
            .hitTestBehavior(HitTestMode.Transparent)
            .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])

          // 暗化遮罩(增强浅色背景图下的文字可读性)
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('rgba(0,0,0,' + (this.chatBgConfig!.dim / 100).toString() + ')')
            .hitTestBehavior(HitTestMode.Transparent)
            .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])
        }

        // ===== 底层:消息列表 + 浮动按钮 =====
        // Stack 整体离屏合成, 让顶部擦除遮罩能通过 DST_IN 擦除消息
        // - 消息列表正常渲染 (默认 SRC_OVER)
        // - 顶部遮罩用 DST_IN + alpha 渐变: alpha=0 擦除消息, alpha=1 显示消息
        //   → 消息从顶部淡出, 背景图和模型透出 (遮罩本身透明)
        Column() {
          // 消息列表 + 浮动按钮
          Stack({ alignContent: Alignment.BottomEnd }) {
            if (this.isInitialLoading()) {
              this.loadingView()
            } else if (this.hasInitError()) {
              this.initErrorView()
            } else if (this.messages.length === 0) {
              this.emptyStateView()
            } else {
              this.messageList()
            }

            // 顶部擦除遮罩: 用 DST_IN alpha 渐变擦除消息顶部, 背景图和模型透出
            // - 100% = 占满顶部和底部 (无遮罩)
            // - 调小占比 = 顶部消息被擦除, 在交界处渐变消失
            // - 背景图保持占满全屏不动 (遮罩只是擦除消息, 不绘制实体色)
            // position 强制顶部对齐, 避免 Stack alignContent=BottomEnd 把遮罩拉到底部
            if (this.chatContentHeightRatio < 1.0) {
              Column()
                .width('100%')
                .height(`${(1 - this.chatContentHeightRatio) * 100}%`)
                .linearGradient({
                  angle: 180,
                  colors: [
                    ['#00000000', 0.0],
                    ['#00000000', 0.5],
                    ['#FF000000', 0.9],
                    ['#FF000000', 1.0]
                  ]
                })
        .hitTestBehavior(HitTestMode.None)
                .blendMode(BlendMode.DST_IN)
                .position({ x: 0, y: 0 })
            }

            // 回到底部浮动按钮
            if (this.viewModel !== null
              && this.viewModel!.userScrolledUp
              && this.messages.length > 0) {
              Button({ type: ButtonType.Circle, stateEffect: false }) {
                SymbolGlyph($r('sys.symbol.chevron_down'))
                  .fontSize(20)
                  .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
              }
              .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
              .borderRadius(22)
              .width(44)
              .height(44)
              .margin({ bottom: 12, right: 12 })
              .shadow({ radius: 8, color: 'rgba(0,0,0,0.15)' })
              .onClick(() => {
                this.scroller.scrollEdge(Edge.Bottom);
                this.viewModel!.userScrolledUp = false;
              })
            }
          }
          .layoutWeight(1)
          .width('100%')
          // Stack 离屏合成, 让顶部遮罩的 blendMode(DST_IN) 能擦除消息列表
          // OFFSCREEN: Stack 内子组件先合成到离屏 buffer, 再与下层混合
          .blendMode(BlendMode.SRC_OVER, BlendApplyType.OFFSCREEN)
          // padding 0:消息列表占满全屏,顶栏/输入栏作为浮层叠加(顶栏透明、输入栏底部带不透明背景)。
          // 最新消息通过 autoScrollToBottom 滚动到输入栏上方可视区域。
          .padding({ top: 0, bottom: 0 })
          .onClick(() => {
            // 点击消息列表空白区域收起软键盘
            try {
              inputMethod.getController().stopInputSession();
            } catch (_e) {
              // 输入法未显示或已隐藏,忽略
            }
          })
        }
        .width('100%')
        .height('100%')
        .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])

        // ===== 顶部渐变层(增强状态栏图标和顶部文字可读性) =====
        // 不响应触摸:hitTestBehavior(Transparent)
        // 不改变背景图片透明度:仅本层自身带渐变背景
        // 仅覆盖状态栏和顶部过渡区域(高度 = 状态栏高度 + 渐变过渡区 112vp)
        Column() {
          Column()
            .width('100%')
            .height(this.statusBarHeight + 112)
            .linearGradient({
              angle: 180,
              colors: [
                [$r('app.color.chat_top_gradient_start'), 0.0],
                [$r('app.color.chat_top_gradient_mid'), 0.5],
                [$r('app.color.chat_top_gradient_end'), 1.0]
              ]
            })
            .hitTestBehavior(HitTestMode.Transparent)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
        .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])

        // ===== 浮层:顶栏(顶部对齐,半透明背景) =====
        // 注意:Stack 默认 alignContent=Center,若 Column 只设 width 不设 height,
        // 会被居中显示(顶栏/输入栏"集中在中间"的根因)。
        // 解法:Column 占满 height + justifyContent(Start/End) 让内容在顶部/底部对齐,
        // 同时 hitTestBehavior=Transparent 让空白区域点击穿透到下层消息列表。
        Column() {
          this.topBar()

          // 错误提示条
          if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
            Text(this.viewModel!.errorMessage)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_danger'))
              .width('100%')
              .padding({
                left: $r('app.float.app_spacing_16'),
                right: $r('app.float.app_spacing_16'),
                top: $r('app.float.app_spacing_4'),
                bottom: $r('app.float.app_spacing_4')
              })
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          }

          // 状态条(生成中/已停止 - 轻量提示)
          if (this.viewModel !== null && this.viewModel!.statusMessage.length > 0) {
            Text(this.viewModel!.statusMessage)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 2, bottom: 2 })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Start)
        // 顶栏 Column 透明:让下层消息列表完全可见,顶栏背景由 topBar Row 自己带
        // hitTestBehavior=Transparent 让顶栏下方空白区域点击穿透到消息列表
        .hitTestBehavior(HitTestMode.Transparent)
        .expandSafeArea([SafeAreaType.KEYBOARD], [SafeAreaEdge.BOTTOM])

        // ===== 浮层:输入栏(底部对齐,悬浮胶囊式) =====
        // 外层 Column 透明,只负责把 inputArea 推到底部对齐位置;
        // 输入栏本身由 inputArea 的 backgroundBlurStyle 提供视觉容器,不承载不透明背景。
        // margin bottom 12vp + navigationBarHeight:避开系统手势条;
        // margin left/right 12vp:与页面其他内容对齐。
        Column() {
          if (this.viewModel !== null
            && (this.viewModel!.impersonateCandidates.length > 0
              || this.viewModel!.isImpersonateGenerating)) {
            ImpersonateCandidatesPanel({
              candidates: this.viewModel!.impersonateCandidates,
              isGenerating: this.viewModel!.isImpersonateGenerating,
              onSelect: (index: number): void => {
                if (this.viewModel !== null) {
                  this.viewModel!.selectImpersonateCandidate(index);
                }
              },
              onDismiss: (): void => {
                if (this.viewModel !== null) {
                  this.viewModel!.dismissImpersonateCandidates();
                }
              }
            })
          }

          // 开场白选择箭头(新会话首条消息时显示,点击切换开场白;开始聊天后自动消失)。
          // 放在输入栏胶囊上方独立浮层,避免被胶囊背景遮挡。
          if (this.showGreetingSwitcher()) {
            Row() {
              this.greetingSwitcherButton()
            }
            .width('100%')
            .justifyContent(FlexAlign.End)
            .padding({ right: 4, bottom: 6 })
            // 空白区域点击穿透到消息列表(收起软键盘),箭头自身仍可点击
            .hitTestBehavior(HitTestMode.Transparent)
          }

          this.inputArea()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        // OFFSET 模式下输入栏未加 expandSafeArea(KEYBOARD),被系统上抬到键盘上方;
        // bottom 仅控制 inputArea 与 Column 底部的间距:
        // 键盘弹起时 12(系统已上抬,只需小间距);未弹起时 navigationBarHeight + 12(避让手势条)
        .padding({ left: 12, right: 12, bottom: this.keyboardHeight > 0 ? 40 : this.navigationBarHeight + 40 })
        .hitTestBehavior(HitTestMode.Transparent)

        // ===== 弹窗层(覆盖在最上层) =====
        // 会话列表面板(覆盖层)
        if (this.viewModel !== null && this.viewModel!.showSessionList) {
          ChatSessionListPanel({ viewModel: this.viewModel! })
        }

        // 更多菜单
        if (this.showMoreMenu && this.viewModel !== null) {
          ChatMoreMenuSheet({
            visible: true,
            characterName: this.viewModel!.characterName,
            modelName: this.viewModel!.currentModelName,
            presetName: this.viewModel!.currentPresetName,
            hasModel: this.viewModel!.hasCurrentModel,
            branchStatusText: this.viewModel!.getBranchStatusText(),
            canRegenerate: this.viewModel!.canRegenerate,
            isGenerating: this.viewModel!.isGenerating,
            busy: this.viewModel!.busy,
            userNameOverride: this.currentUserNameOverride,
            resolvedUserName: this.resolvedUserName,
            resolvedPersonaName: this.resolvedPersonaName,
            onClose: (): void => {
              this.showMoreMenu = false;
              // 关闭菜单时刷新一次当前生效称呼(可能在其他地方被修改)
              this.refreshUserNameDisplay();
            },
            onGoModelSettings: (): void => { this.goToModelSettings(); },
            onGoPresetList: (): void => { this.goToPresetList(); },
            onGoBranchMap: (): void => { this.navigateToBranchMap(); },
            onGoChatBackground: (): void => { this.navigateToChatBackgroundSettings(); },
            onGoMemory: (): void => { this.navigateToMemoryManagement(); },
            onGoContextBudget: (): void => { this.navigateToContextBudget(); },
            onGoAutoWriteGuide: (): void => { this.navigateToAutoWriteGuide(); },
            onEditUserNameOverride: (): void => {
              this.openUserNameOverrideDialog();
            },
            onSwitchPersona: (): void => {
              this.openPersonaPicker();
            },
            onNewChapter: (): void => {
              this.openChapterGreetingPicker();
            },
            onRegenerate: (): void => { this.viewModel!.regenerate(); },
            onClearChat: (): void => {
              this.showClearConfirm = true;
            }
          })
        }

        // 消息操作菜单
        if (this.showActionSheet && this.actionSheetMsg !== null && this.viewModel !== null) {
          ChatMessageActionSheet({
            visible: true,
            msg: this.actionSheetMsg,
            canEdit: this.viewModel!.canEditUserMessage(this.actionSheetMsg!.id),
            canGenerateFromUser: this.viewModel!.canGenerateFromUserMessage(this.actionSheetMsg!.id),
            canRegenerate: this.viewModel!.canRegenerateAssistantMessage(this.actionSheetMsg!.id),
            canContinue: this.viewModel!.canContinueFromAssistant(this.actionSheetMsg!.id),
            candidateCount: this.getCandidateCount(this.actionSheetMsg!.id),
            canForkChat: !this.viewModel!.busy && this.viewModel!.isSessionReady,
            onClose: (): void => {
              this.showActionSheet = false;
              this.actionSheetMsg = null;
            },
            onAction: (action: MessageAction): void => {
              this.handleMessageAction(action);
            }
          })
        }

        // 清空确认弹窗
        if (this.showClearConfirm) {
          this.clearConfirmDialog()
        }

        // v9: 本对话称呼覆盖编辑弹窗
        if (this.showUserNameOverrideDialog) {
          this.userNameOverrideDialog()
        }

        // Persona 选择弹窗
        if (this.showPersonaPicker) {
          this.personaPickerSheet()
        }

        // v42: 新建章节开场白选择弹窗
        if (this.showChapterGreetingPicker) {
          this.chapterGreetingPickerDialog()
        }

        // Fork 模式选择弹窗
        if (this.showForkModePicker) {
          this.forkModePickerDialog()
        }

        // 色盘选择器覆盖层(自定义 Markdown 文字颜色)
        this.colorPickerOverlay()
      }
      .width('100%')
      .height('100%')
      // PanoVR2 模式:不透明背景填满到状态栏区域
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== 顶部栏 =====

  @Builder
  topBar() {
    Column() {
      Row() {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
        }
        .width(40)
        .height(40)
        .onClick(() => {
          this.handleBack();
        })

        this.topBarBudgetIndicator()

        Stack() {
          SymbolGlyph($r('sys.symbol.speaker'))
            .fontSize(18)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
        }
        .width(36)
        .height(36)
        .borderRadius($r('app.float.app_radius_sm'))
        .onClick(() => {
          this.navigateToTtsSettings();
        })

        Blank()

        Stack() {
          SymbolGlyph($r('sys.symbol.textformat'))
            .fontSize(20)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
        }
        .width(40)
        .height(40)
        .margin({ right: 4 })
        .borderRadius($r('app.float.app_radius_sm'))
        .backgroundColor(this.chatAppearancePanelVisible
          ? ThemePalette.surface2Color(this.effectiveTheme) : Color.Transparent)
        .onClick(() => {
          this.chatAppearancePanelVisible = !this.chatAppearancePanelVisible;
        })
        .bindSheet($$this.chatAppearancePanelVisible, this.appearanceSheetContent(), {
          height: '76%',
          dragBar: false,
          showClose: false,
          backgroundColor: ThemePalette.surface1Color(this.effectiveTheme)
        })

        Stack() {
          SymbolGlyph($r('sys.symbol.book'))
            .fontSize(20)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
        }
        .width(40)
        .height(40)
        .margin({ right: 4 })
        .borderRadius($r('app.float.app_radius_sm'))
        .backgroundColor(this.statusPanelVisible
          ? ThemePalette.surface2Color(this.effectiveTheme) : Color.Transparent)
        .onClick(() => {
          this.statusPanelVisible = !this.statusPanelVisible;
          if (this.statusPanelVisible && this.viewModel !== null) {
            this.viewModel!.loadLorebookPanelData().then((): void => {
              this.syncLorebookPanelData();
            }).catch((): void => {
            });
          }
        })
        .gesture(
          LongPressGesture()
            .onAction(() => {
              // 长按世界书按钮:手动刷新激活内容(按需锁定模式)
              this.manualRefreshLorebookActivated();
            })
        )
        .key('chat.worldbook.toggle')
        .bindSheet($$this.statusPanelVisible, this.statusWorldSheetContent(), {
          height: '70%',
          dragBar: false,
          showClose: false,
          backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
          onWillDisappear: () => {
            // 保持不变,由 $$ 双向绑定自动回写 statusPanelVisible = false
          }
        })

        Stack() {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(22)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
        }
        .width(40)
        .height(40)
        .onClick(() => {
          this.refreshUserNameDisplay();
          this.refreshPersonaDisplay();
          this.showMoreMenu = true;
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        if (this.cacheHitRatio >= 0) {
          Text(this.getCacheHitText())
            .fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor('rgba(128,128,128,0.15)')
        }

        if (this.showDeepSeekBalance && this.deepSeekBalanceText.length > 0) {
          Text(this.deepSeekBalanceText)
            .fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor('rgba(128,128,128,0.15)')
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .padding({ left: 48, right: 4 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: this.statusBarHeight + 4, bottom: 4 })
  }

  // ===== CHAT-STATUS-1A / T-7.x: 状态/世界书滑动面板 =====

  @Builder
  statusWorldSheetContent() {
    Column() {
      // 顶部栏:标题 + AI 入口 + 关闭
      this.worldbookHeader()

      // AI 操作区(置于顶部,键盘弹出时不会被遮挡)
      this.aiActionArea()

      // 世界书内容(单页,无 Swiper)
      this.worldbookPageContent()

      // 世界书变更预览(确认/取消)
      this.aiPreviewArea()
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
  }

  @Builder
  worldbookHeader() {
    Row() {
      Text('世界书')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      Blank()

      // AI 入口(低调透明)
      Row() {
        Text('✦')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        Text('AI')
          .fontSize(11)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ left: 4 })
      }
      .height(28)
      .padding({ left: 10, right: 10 })
      .borderRadius(14)
      .backgroundColor(this.aiEntryVisible ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.07)')
      .opacity(this.aiEntryVisible ? 0.9 : 0.6)
      .onClick(() => {
        this.aiEntryVisible = !this.aiEntryVisible;
        if (!this.aiEntryVisible) {
          this.pendingChangeSet = null;
        }
      })
      .key('chat.world.ai')

      // 手动刷新激活内容(按需锁定模式):切换开场白/章节后重新匹配并锁定
      Row() {
        Text('↻')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        Text('刷新激活')
          .fontSize(11)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ left: 4 })
      }
      .height(28)
      .padding({ left: 10, right: 10 })
      .borderRadius(14)
      .backgroundColor('rgba(255,255,255,0.07)')
      .onClick(() => {
        this.manualRefreshLorebookActivated();
      })
      .key('chat.world.refresh')

      Text('✕')
        .fontSize(13)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .opacity(0.7)
        .margin({ left: 12 })
        .onClick(() => {
          this.statusPanelVisible = false;
          this.aiEntryVisible = false;
          this.pendingChangeSet = null;
        })
        .key('chat.world.close')
    }
    .width('100%')
    .margin({ bottom: 6 })
  }

  @Builder
  worldbookPageContent() {
    Scroll() {
      Column() {
        if (this.lorebookPanelData === null) {
          Text('暂无世界书，点击上方 AI 可从近期对话提取设定')
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .padding({ top: 12, bottom: 12 })
        } else {
          ForEach(this.lorebookPanelData!.books, (book: LorebookPanelBook) => {
            this.worldBookGroupRow(book)
          }, (book: LorebookPanelBook) =>
            book.lorebookId + '|' + String(this.lorebookPanelVersion))
        }
      }
      .width('100%')
      .padding({ bottom: 8 })
    }
    .width('100%')
      // layoutWeight 占满顶部栏/AI 区之后的剩余高度:条目只在面板内滚动,
      // 不会把内容顶出圆角背景框以外。
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  worldBookGroupRow(book: LorebookPanelBook) {
    Column() {
      Text((book.isCharacterBook ? '角色专属 · ' : '全局 · ') + (book.name.length > 0 ? book.name : '世界书'))
        .fontSize(12)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ top: 6, bottom: 4 })
      if (book.entries.length === 0) {
        Text('(无条目)')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ top: 2, bottom: 2 })
      } else {
        ForEach(book.entries, (entry: LorebookEntry) => {
          this.worldBookEntryRow(book, entry)
        }, (entry: LorebookEntry) =>
          entry.id + '|' + String(this.lorebookPanelVersion))
      }
    }
    .width('100%')
  }

  @Builder
  worldBookEntryRow(book: LorebookPanelBook, entry: LorebookEntry) {
    Column() {
      Row() {
        Text(entry.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(entry.constant ? '恒定' : '')
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .opacity(0.7)
          .margin({ right: 8 })
        Text(entry.enabled ? '启用' : '停用')
          .fontSize(10)
          .fontColor(entry.enabled
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textTertiaryColor(this.effectiveTheme))
          .opacity(entry.enabled ? 0.9 : 0.5)
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel!.toggleLorebookEntryEnabled(
                book.lorebookId, entry.id, !entry.enabled
              ).then((): void => {
                this.syncLorebookPanelData();
              }).catch((): void => {
              });
            }
          })
          .key('chat.world.entry.' + entry.id + '.toggle')
      }
      .width('100%')

      if (entry.keys.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(entry.keys, (key: string) => {
            Text(key)
              .fontSize(10)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor('rgba(255,255,255,0.06)')
              .borderRadius(8)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .margin({ right: 6, top: 4 })
          }, (key: string) => key)
        }
        .width('100%')
      }

      Text(entry.content)
        .fontSize(12)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .maxLines(this.expandedEntryId === entry.id ? 100 : 3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick(() => {
          this.expandedEntryId = this.expandedEntryId === entry.id ? '' : entry.id;
        })
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor('rgba(255,255,255,0.04)')
    .margin({ top: 4 })
  }

  @Builder
  aiActionArea() {
    if (this.aiEntryVisible) {
      Column() {
        Row() {
          this.aiModeChip('修改世界书', 'worldbook')
          this.aiModeChip('提取角色/地点', 'extract')
        }
        .width('100%')
        .margin({ top: 6 })

        Row() {
          TextInput({
            placeholder: this.aiMode === 'worldbook'
              ? '如：新增角色 张三，酒馆老板'
              : '自动提取近期对话中的新角色/地点',
            text: this.aiPromptText
          })
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .onChange((value: string) => {
              this.aiPromptText = value;
            })
          Text(this.aiLoading ? '处理中…' : '执行')
            .fontSize(12)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .opacity(this.aiLoading ? 0.4 : 1)
            .margin({ left: 12 })
            .onClick(() => {
              this.runAiAction();
            })
            .key('chat.world.ai.run')
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
    }
  }

  @Builder
  aiModeChip(label: string, mode: string) {
    Text(label)
      .fontSize(11)
      .fontColor(this.aiMode === mode
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(this.aiMode === mode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.04)')
      .borderRadius(12)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .margin({ right: 8 })
      .onClick(() => {
        this.aiMode = mode;
        this.pendingChangeSet = null;
        if (mode === 'extract') {
          this.runAiExtract();
        }
      })
      .key('chat.world.mode.' + mode)
  }

  @Builder
  aiPreviewArea() {
    if (this.pendingChangeSet !== null) {
      Column() {
        Text('变更预览')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })

        if (this.pendingChangeSet!.adds.length === 0
          && this.pendingChangeSet!.updates.length === 0
          && this.pendingChangeSet!.deletes.length === 0) {
          Text('未识别到需要变更的内容')
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
        } else {
          Scroll() {
            Column() {
              ForEach(this.pendingChangeSet!.adds, (a: AiLorebookAdd, index: number) => {
                this.aiPreviewAddRow(a, index)
              }, (a: AiLorebookAdd, index: number) => 'add-' + a.lorebookId + '-' + a.name + '-' + String(index))
              ForEach(this.pendingChangeSet!.updates, (u: AiLorebookUpdate, index: number) => {
                this.aiPreviewUpdateRow(u, index)
              }, (u: AiLorebookUpdate, index: number) => 'upd-' + u.lorebookId + '-' + u.entryId + '-' + String(index))
              ForEach(this.pendingChangeSet!.deletes, (d: AiLorebookDelete, index: number) => {
                Row() {
                  Text('删除')
                    .fontSize(10)
                    .fontColor($r('app.color.app_danger'))
                  Text(d.entryId)
                    .fontSize(11)
                    .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                    .layoutWeight(1)
                    .margin({ left: 6 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor('rgba(255,255,255,0.04)')
                .borderRadius(8)
                .margin({ top: 4 })
              }, (d: AiLorebookDelete, index: number) => 'del-' + d.lorebookId + '-' + d.entryId + '-' + String(index))
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 140 })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }

        Row() {
          Text('应用')
            .fontSize(12)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .onClick(() => {
              this.applyPendingChanges();
            })
            .key('chat.world.apply')
          Blank()
          Text('取消')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .onClick(() => {
              this.pendingChangeSet = null;
            })
            .key('chat.world.cancel')
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ top: 8, bottom: 4 })
      .border({ width: 0.5, color: ThemePalette.surface2Color(this.effectiveTheme) })
      .borderRadius(10)
      .margin({ top: 8 })
    }
  }

  /** 变更预览:新增条目行(点击展开关键词与内容,便于确认前审阅)。 */
  @Builder
  aiPreviewAddRow(a: AiLorebookAdd, index: number) {
    Column() {
      Row() {
        Text('新增')
          .fontSize(10)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        Text(a.name)
          .fontSize(11)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.expandedAiPreviewKey === 'add-' + String(index) ? '收起' : '展开')
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .opacity(0.8)
      }
      .width('100%')

      if (this.expandedAiPreviewKey === 'add-' + String(index)) {
        // 关键词
        if (a.keys.length > 0) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
            ForEach(a.keys, (k: string) => {
              Text(k)
                .fontSize(10)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .backgroundColor('rgba(255,255,255,0.06)')
                .borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ right: 5, top: 4 })
            }, (k: string) => k)
          }
          .width('100%')
        }
        // 内容
        Text(a.content)
          .fontSize(11)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .backgroundColor('rgba(255,255,255,0.04)')
    .borderRadius(8)
    .margin({ top: 4 })
    .onClick(() => {
      const k: string = 'add-' + String(index);
      this.expandedAiPreviewKey = this.expandedAiPreviewKey === k ? '' : k;
    })
  }

  /** 变更预览:修改条目行(点击展开被修改的字段与内容)。 */
  @Builder
  aiPreviewUpdateRow(u: AiLorebookUpdate, index: number) {
    Column() {
      Row() {
        Text('修改')
          .fontSize(10)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Text(u.name !== undefined ? u.name : u.entryId)
          .fontSize(11)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.expandedAiPreviewKey === 'upd-' + String(index) ? '收起' : '展开')
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .opacity(0.8)
      }
      .width('100%')

      if (this.expandedAiPreviewKey === 'upd-' + String(index)) {
        if (u.name !== undefined) {
          Text('名称：' + u.name)
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 4 })
        }
        if (u.content !== undefined && u.content.length > 0) {
          Text(u.content)
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 4 })
        } else if (u.name === undefined) {
          Text('（未提供具体字段，请直接应用）')
            .fontSize(11)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 4 })
        }
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .backgroundColor('rgba(255,255,255,0.04)')
    .borderRadius(8)
    .margin({ top: 4 })
    .onClick(() => {
      const k: string = 'upd-' + String(index);
      this.expandedAiPreviewKey = this.expandedAiPreviewKey === k ? '' : k;
    })
  }

  // ===== T-7.x: 世界书面板逻辑 =====

  /** 同步世界书面板数据(由 viewModel.lorebookPanelData 镜像到本地 @State)。
   * 每次同步递增版本号,强制 ForEach 按新 key 重建条目(修复 AI 应用变更后面板不刷新)。 */
  private syncLorebookPanelData(): void {
    if (this.viewModel !== null) {
      this.lorebookPanelData = this.viewModel!.lorebookPanelData;
    }
    this.lorebookPanelVersion = this.lorebookPanelVersion + 1;
  }

  /** 执行当前 AI 模式的指令(世界书修改 / 提取)。 */
  private runAiAction(): void {
    if (this.viewModel === null || this.aiLoading) {
      return;
    }
    if (this.aiMode === 'worldbook') {
      const prompt: string = this.aiPromptText.trim();
      if (prompt.length === 0) {
        promptAction.showToast({ message: '请输入修改指令', duration: 1500 });
        return;
      }
      this.aiLoading = true;
      this.viewModel!.aiProposeWorldbookChanges(AiLorebookMode.Modify, prompt).then(
        (changes: AiLorebookChangeSet | null): void => {
          this.aiLoading = false;
          if (changes !== null) {
            this.aiPromptText = '';
            this.pendingChangeSet = changes;
          } else {
            promptAction.showToast({ message: '生成失败，请重试', duration: 2000 });
          }
        }).catch((): void => {
        this.aiLoading = false;
        promptAction.showToast({ message: '生成失败，请重试', duration: 2000 });
      });
    } else {
      this.runAiExtract();
    }
  }

  /** 从近期对话提取新角色/地点到世界书(生成变更提案,待确认)。 */
  private runAiExtract(): void {
    if (this.viewModel === null || this.aiLoading) {
      return;
    }
    this.aiLoading = true;
    this.viewModel!.aiProposeWorldbookChanges(AiLorebookMode.Extract, '').then(
      (changes: AiLorebookChangeSet | null): void => {
        this.aiLoading = false;
        if (changes !== null) {
          this.pendingChangeSet = changes;
        } else {
          promptAction.showToast({ message: '生成失败，请重试', duration: 2000 });
        }
      }).catch((): void => {
      this.aiLoading = false;
      promptAction.showToast({ message: '生成失败，请重试', duration: 2000 });
    });
  }

  /** 应用待确认的世界书变更集。 */
  private applyPendingChanges(): void {
    if (this.viewModel === null || this.pendingChangeSet === null || this.aiLoading) {
      return;
    }
    this.aiLoading = true;
    this.viewModel!.applyLorebookChangeSet(this.pendingChangeSet).then((ok: boolean): void => {
      this.aiLoading = false;
      this.pendingChangeSet = null;
      this.syncLorebookPanelData();
      promptAction.showToast({ message: ok ? '世界书已更新' : '部分操作失败，请检查', duration: 2000 });
    }).catch((): void => {
      this.aiLoading = false;
      this.pendingChangeSet = null;
      promptAction.showToast({ message: '应用失败', duration: 2000 });
    });
  }

  /**
   * 手动刷新世界书激活内容(OnDemandPinned 按需锁定模式)。
   * 用户切换开场白(不同章节)后调用:按当前会话全部消息重新关键词匹配并落库锁定。
   */
  private manualRefreshLorebookActivated(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.refreshLorebookPinNow().then((ok: boolean): void => {
      promptAction.showToast({
        message: ok ? '世界书激活内容已刷新并锁定' : '无可刷新内容(未启用/无角色世界书)',
        duration: 2000
      });
    }).catch((): void => {
      promptAction.showToast({ message: '刷新失败，请重试', duration: 2000 });
    });
  }

  // ===== 显示设置面板(气泡不透明度 + 字体配色) =====

  @Builder
  appearanceSheetContent() {
    Scroll() {
      Column() {
        // 标题行
            Row() {
              Text('显示设置')
                .fontSize($r('app.float.app_font_body'))
                .fontWeight(FontWeight.Medium)
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              Blank()
              // 关闭按钮
              Stack() {
                SymbolGlyph($r('sys.symbol.xmark'))
                  .fontSize(14)
                  .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
              }
              .width(28)
              .height(28)
              .borderRadius(14)
              .onClick(() => {
                this.chatAppearancePanelVisible = false;
              })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 12 })

            // ===== 气泡不透明度 =====
            Row() {
              Text('气泡不透明度')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              Blank()
              Text(`${Math.round(this.chatBubbleOpacity * 100)}%`)
                .fontSize($r('app.float.app_font_caption'))
                .fontWeight(FontWeight.Medium)
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 8 })

            Slider({
              value: Math.round(this.chatBubbleOpacity * 100),
              min: 0,
              max: 100,
              step: 10,
              style: SliderStyle.OutSet
            })
              .blockColor(ThemePalette.accentColor(this.effectiveTheme))
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
              .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
              .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
              .width('100%')
              .onChange((value: number, mode: SliderChangeMode) => {
                const opacity: number = this.normalizeChatBubbleOpacity(value / 100);
                this.chatBubbleOpacity = opacity;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.persistBubbleOpacity(opacity);
                }
              })

            Row() {
              Text('0%')
                .fontSize(11)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              Blank()
              Text('100%')
                .fontSize(11)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            }
            .width('100%')
            .margin({ top: 4 })

            Divider()
              .color(ThemePalette.dividerColor(this.effectiveTheme))
              .margin({ top: 16, bottom: 12 })

            // ===== 聊天显示范围 (顶部压缩, 消息渐变淡出) =====
            Row() {
              Text('聊天显示范围')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              Blank()
              Text(`${Math.round(this.chatContentHeightRatio * 100)}%`)
                .fontSize($r('app.float.app_font_caption'))
                .fontWeight(FontWeight.Medium)
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 8 })

            Slider({
              value: Math.round(this.chatContentHeightRatio * 100),
              min: 0,
              max: 100,
              step: 5,
              style: SliderStyle.OutSet
            })
              .blockColor(ThemePalette.accentColor(this.effectiveTheme))
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
              .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
              .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
              .width('100%')
              .onChange((value: number, mode: SliderChangeMode) => {
                const ratio: number = value / 100;
                this.chatContentHeightRatio = ratio;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.persistContentHeightRatio(ratio);
                }
              })

            Row() {
              Text('50%')
                .fontSize(11)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              Blank()
              Text('100%')
                .fontSize(11)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            }
            .width('100%')
            .margin({ top: 4 })

            Divider()
              .color(ThemePalette.dividerColor(this.effectiveTheme))
              .margin({ top: 16, bottom: 12 })

            // ===== 字体大小 =====
            Row() {
              Text('字体大小')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              Blank()
              Text(this.chatTextStyle !== null ? this.chatTextStyle!.fontSize.toString() + 'fp' : '16fp')
                .fontSize($r('app.float.app_font_caption'))
                .fontWeight(FontWeight.Medium)
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 8 })

            Slider({
              value: this.chatTextStyle !== null ? this.chatTextStyle!.fontSize : 16,
              min: 12,
              max: 24,
              step: 1,
              style: SliderStyle.OutSet
            })
              .blockColor(ThemePalette.accentColor(this.effectiveTheme))
            .sliderInteractionMode(SliderInteraction.SLIDE_ONLY)
              .trackColor(ThemePalette.surface2Color(this.effectiveTheme))
              .selectedColor(ThemePalette.accentColor(this.effectiveTheme))
              .width('100%')
              .onChange((value: number, mode: SliderChangeMode) => {
                const fontSize: number = Math.round(value);
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.applyFontSize(fontSize);
                }
              })

            Row() {
              Text('12fp')
                .fontSize(11)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              Blank()
              Text('24fp')
                .fontSize(11)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            }
            .width('100%')
            .margin({ top: 4 })

            Divider()
              .color(ThemePalette.dividerColor(this.effectiveTheme))
              .margin({ top: 16, bottom: 12 })

            // ===== 文字配色模式 =====
            Row() {
              Text('文字配色')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              Blank()
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ bottom: 8 })

            // 模式按钮:自动 / 浅色 / 深色 / 自定义
            Row({ space: 6 }) {
              ForEach([
                ChatTextColorMode.AUTO,
                ChatTextColorMode.LIGHT,
                ChatTextColorMode.DARK,
                ChatTextColorMode.CUSTOM
              ], (mode: string) => {
                Button(this.getModeLabel(mode))
                  .fontSize($r('app.float.app_font_caption'))
                  .fontColor(this.chatTextColorMode === mode
                    ? $r('app.color.app_on_accent')
                    : ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .backgroundColor(this.chatTextColorMode === mode
                    ? ThemePalette.accentColor(this.effectiveTheme)
                    : ThemePalette.surface2Color(this.effectiveTheme))
                  .borderRadius(14)
                  .height(28)
                  .padding({ left: 10, right: 10 })
                  .onClick(() => {
                    this.setChatTextColorMode(mode);
                  })
              }, (mode: string) => mode)
            }
            .width('100%')

            // 对比度辅助提示
            Text('气泡较透明时建议使用浅色文字,气泡较不透明时可使用深色文字')
              .fontSize(10)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ top: 8 })

            // 快捷按钮:适合深色背景 / 适合浅色背景
            Row({ space: 8 }) {
              Button('适合深色背景')
                .fontSize(11)
                .fontColor(this.chatTextColorMode === ChatTextColorMode.LIGHT
                  ? $r('app.color.app_on_accent')
                  : ThemePalette.accentColor(this.effectiveTheme))
                .backgroundColor(this.chatTextColorMode === ChatTextColorMode.LIGHT
                  ? ThemePalette.accentColor(this.effectiveTheme)
                  : Color.Transparent)
                .border({
                  width: 1,
                  color: ThemePalette.accentColor(this.effectiveTheme)
                })
                .borderRadius(12)
                .height(24)
                .padding({ left: 8, right: 8 })
                .onClick(() => {
                  this.setChatTextColorMode(ChatTextColorMode.LIGHT);
                })
              Button('适合浅色背景')
                .fontSize(11)
                .fontColor(this.chatTextColorMode === ChatTextColorMode.DARK
                  ? $r('app.color.app_on_accent')
                  : ThemePalette.accentColor(this.effectiveTheme))
                .backgroundColor(this.chatTextColorMode === ChatTextColorMode.DARK
                  ? ThemePalette.accentColor(this.effectiveTheme)
                  : Color.Transparent)
                .border({
                  width: 1,
                  color: ThemePalette.accentColor(this.effectiveTheme)
                })
                .borderRadius(12)
                .height(24)
                .padding({ left: 8, right: 8 })
                .onClick(() => {
                  this.setChatTextColorMode(ChatTextColorMode.DARK);
                })
            }
            .width('100%')
            .margin({ top: 8 })

            // ===== 自定义配色(仅在 CUSTOM 模式下显示)=====
            if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
              Divider()
                .color(ThemePalette.dividerColor(this.effectiveTheme))
                .margin({ top: 12, bottom: 12 })

              Text('自定义配色')
                .fontSize($r('app.float.app_font_caption'))
                .fontWeight(FontWeight.Medium)
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .width('100%')
                .margin({ bottom: 8 })

              // 普通正文
              this.colorSwatchRow('普通正文', 'body')

              // 加粗/斜体
              this.colorSwatchRow('**加粗** / *斜体*', 'emphasis')

              // 对白 “”
              this.colorSwatchRow('“对白”', 'dialogue')

              // 动作/旁白 ()
              this.colorSwatchRow('(动作)', 'action')

              // 行内代码
              this.colorSwatchRow('`代码`', 'code')

              // 链接
              this.colorSwatchRow('[链接](url)', 'link')

              // 引用
              this.colorSwatchRow('> 引用', 'quote')

              // 用户消息文字
              this.colorSwatchRow('用户消息', 'user')
            }

            Divider()
              .color(ThemePalette.dividerColor(this.effectiveTheme))
              .margin({ top: 12, bottom: 12 })

            // ===== 预览区域 =====
            Text('预览')
              .fontSize($r('app.float.app_font_caption'))
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ bottom: 6 })

            this.fontColorPreviewArea()

            // ===== 恢复默认按钮 =====
            Row({ space: 8 }) {
              Button('恢复默认')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                .backgroundColor(Color.Transparent)
                .borderRadius(8)
                .height(32)
                .padding({ left: 12, right: 12 })
                .enabled(!this.isChatTextColorDefault())
                .onClick(() => {
                  this.resetChatTextColor();
                })
              Button('全部恢复默认')
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .backgroundColor(Color.Transparent)
                .borderRadius(8)
                .height(32)
                .padding({ left: 12, right: 12 })
                .enabled(this.chatBubbleOpacity !== 0.65 || !this.isChatTextColorDefault())
                .onClick(() => {
                  this.resetAllAppearance();
                })
            }
            .width('100%')
            .margin({ top: 12 })
          }
          .width('100%')
          .padding(16)
        }
        .scrollBar(BarState.Auto)
        .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        .width('100%')
      }

  /**
   * 色盘选择器覆盖层(全屏遮罩 + 居中卡片)。
   *
   * - 遮罩与卡片为兄弟节点,避免卡片内拖动/点击冒泡到遮罩导致误关闭
   * - ColorWheelPicker 实时回调 setCustomColor,拖动即预览、关闭即生效
   */
  @Builder
  colorPickerOverlay() {
    if (this.colorPickerTarget !== null) {
      Stack() {
        // 遮罩层(点击关闭)
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.5)')
          .onClick(() => {
            this.closeColorPicker();
          })

        // 卡片
        Column() {
          Row() {
            Text('选择颜色')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            Blank()
            Stack() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(14)
                .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
            }
            .width(28)
            .height(28)
            .borderRadius(14)
            .onClick(() => {
              this.closeColorPicker();
            })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 14 })

          ColorWheelPicker({
            color: this.getCustomColorByTarget(this.colorPickerTarget!),
            onChange: (c: string): void => {
              this.setCustomColorLive(this.colorPickerTarget!, c);
            }
          })

          Button('完成')
            .type(ButtonType.Normal)
            .fontSize(15)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius(12)
            .height(40)
            .width('100%')
            .margin({ top: 16 })
            .onClick(() => {
              this.closeColorPicker();
            })
        }
        .width('84%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius(20)
        .shadow({ radius: 20, color: 'rgba(0,0,0,0.3)', offsetX: 0, offsetY: 8 })
      }
      .width('100%')
      .height('100%')
    }
  }

  /**
   * 根据 target 获取当前自定义颜色(响应式访问 @State)。
   *
   * 此方法在 @Builder colorSwatchRow 内部调用,
   * 方法体内访问的 @State 变量(chatBodyTextColor 等)会被 ArkUI 依赖收集,
   * 任一变化时触发 Builder 重新执行,确保色块选中标记和预览圆点立即更新。
   *
   * 不能通过 @Builder 参数传递 currentColor:参数在调用时求值后被固定,
   * 不响应式追踪 @State 变化,会导致点击预设色块后选中标记不刷新。
   */
  private getCustomColorByTarget(target: CustomColorTarget): string {
    if (target === 'body') {
      return this.chatBodyTextColor;
    }
    if (target === 'emphasis') {
      return this.chatEmphasisColor;
    }
    if (target === 'dialogue') {
      return this.chatDialogueColor;
    }
    if (target === 'action') {
      return this.chatActionColor;
    }
    if (target === 'code') {
      return this.chatCodeColor;
    }
    if (target === 'link') {
      return this.chatLinkColor;
    }
    if (target === 'quote') {
      return this.chatQuoteColor;
    }
    return this.chatUserTextColor;
  }

  /**
   * 颜色色块行:标签 + 预设色块 + Hex 输入。
   * 仅在 CUSTOM 模式下渲染。
   * 色块点击即应用,Hex 输入失焦时校验并提交(非法值不提交)。
   *
   * 注意:当前颜色通过 this.getCustomColorByTarget(target) 在 Builder 体内响应式获取,
   * 不通过参数传入,确保 @State 变化时选中标记和预览圆点立即更新。
   */
  @Builder
  colorSwatchRow(label: string, target: CustomColorTarget) {
    Column() {
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Blank()
        // 当前颜色预览圆点(响应式:访问 @State)
        Stack()
          .width(16)
          .height(16)
          .borderRadius(8)
          .backgroundColor(this.getCustomColorByTarget(target))
          .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 6 })

      // 预设色块
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.presetSwatches, (swatch: string) => {
          Stack() {
            if (this.getCustomColorByTarget(target).toUpperCase() === swatch.toUpperCase()) {
              // 选中标记:勾选(按亮度自动选择深/浅勾色)
              Text('✓')
                .fontSize(12)
                .fontColor(this.isLightColor(swatch) ? '#171717' : '#FFFFFF')
                .fontWeight(FontWeight.Bold)
            }
          }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor(swatch)
          .border({
            width: this.getCustomColorByTarget(target).toUpperCase() === swatch.toUpperCase() ? 2 : 1,
            color: this.getCustomColorByTarget(target).toUpperCase() === swatch.toUpperCase()
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.dividerColor(this.effectiveTheme)
          })
          .margin({ right: 8, bottom: 6 })
          .onClick(() => {
            this.setCustomColor(target, swatch);
          })
        }, (swatch: string, index: number) => swatch + index.toString())
      }
      .width('100%')

      // 色盘选择(打开 HSV 色盘,无需手动输入 RGB / Hex 数字)
      Button('色盘选择')
        .type(ButtonType.Normal)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
        .borderRadius(8)
        .height(30)
        .width('100%')
        .onClick(() => {
          this.colorPickerTarget = target;
        })
    }
    .width('100%')
    .margin({ bottom: 10 })
  }

  /**
   * 字体配色预览区域(固定演示文本,不发送消息,不调用网络)。
   * 颜色根据当前模式实时计算,立即更新。
   */
  @Builder
  fontColorPreviewArea() {
    Column({ space: 6 }) {
      // 普通正文
      Row() {
        Text('普通正文示例文字')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('body'))
      }
      .width('100%')

      // 加粗/斜体
      Row() {
        Text('**加粗** *斜体*')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('emphasis'))
      }
      .width('100%')

      // 对白
      Row() {
        Text('“这是对白内容”')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('dialogue'))
      }
      .width('100%')

      // 动作/旁白
      Row() {
        Text('(这是动作/旁白)')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('action'))
      }
      .width('100%')

      // 行内代码
      Row() {
        Text('`代码内容`')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('code'))
      }
      .width('100%')

      // 链接
      Row() {
        Text('链接文字')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('link'))
      }
      .width('100%')

      // 引用
      Row() {
        Text('> 引用内容')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('quote'))
      }
      .width('100%')

      // 用户消息预览(右对齐,带气泡背景)
      Row() {
        Text('用户消息')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(this.getPreviewColor('user'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(this.computeUserBubbleColor())
          .borderRadius(10)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(this.computeAssistantBubbleColor())
    .borderRadius(10)
  }

  /**
   * 计算预览区域助手气泡背景色(基于当前气泡不透明度)。
   * 字体配色与气泡不透明度相互独立:此处仅用于预览背景渲染,
   * 不影响字体颜色,也不受字体模式影响。
   * 浅色模式下基底为白色,深色模式下基底为深灰,叠加 chatBubbleOpacity。
   */
  private computeAssistantBubbleColor(): string {
    const alpha: number = this.chatBubbleOpacity;
    if (this.isDarkMode) {
      // 深色模式:深灰底 0x2A2A2A,叠加 Alpha
      const r: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      const g: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      const b: number = Math.round(0x2A * alpha + 0x00 * (1 - alpha));
      return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
    }
    // 浅色模式:白底 0xFFFFFF,叠加 Alpha 向透明过渡(与 0x000000 混合)
    const r: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    const g: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    const b: number = Math.round(0xFF * alpha + 0xFF * (1 - alpha));
    return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
  }

  /**
   * 计算预览区域用户气泡背景色(品牌蓝 + 当前不透明度)。
   * 用户气泡背景与字体颜色独立,保持品牌色基调。
   */
  private computeUserBubbleColor(): string {
    const alpha: number = this.chatBubbleOpacity;
    // 品牌蓝 0x5B7CFA,叠加 Alpha
    const r: number = Math.round(0x5B * alpha + 0x00 * (1 - alpha));
    const g: number = Math.round(0x7C * alpha + 0x00 * (1 - alpha));
    const b: number = Math.round(0xFA * alpha + 0x00 * (1 - alpha));
    return `#${this.toHex2(r)}${this.toHex2(g)}${this.toHex2(b)}`;
  }

  /** 将 0~255 整数转为 2 位大写 Hex */
  private toHex2(value: number): string {
    const clamped: number = Math.max(0, Math.min(255, Math.round(value)));
    const hex: string = clamped.toString(16).toUpperCase();
    return hex.length === 1 ? '0' + hex : hex;
  }

  /**
   * 获取预览区域指定语义类型的颜色。
   * - CUSTOM / LIGHT / DARK:使用 getCurrentColorTheme 对应的主题字段
   * - AUTO:使用默认深色主题作为预览基准
   */
  private getPreviewColor(target: CustomColorTarget): string {
    const theme: ChatMarkdownColorTheme | null = this.getCurrentColorTheme();
    if (theme !== null) {
      return this.themeField(theme, target);
    }
    return this.themeField(getDarkColorTheme(), target);
  }

  /** 按 target 读取主题对象中对应的语义颜色字段。 */
  private themeField(theme: ChatMarkdownColorTheme, target: CustomColorTarget): string {
    switch (target) {
      case 'body':
        return theme.bodyColor;
      case 'emphasis':
        return theme.emphasisColor;
      case 'dialogue':
        return theme.dialogueColor;
      case 'action':
        return theme.actionColor;
      case 'code':
        return theme.codeColor;
      case 'link':
        return theme.linkColor;
      case 'quote':
        return theme.quoteColor;
      default:
        return theme.userColor;
    }
  }

  // ===== 消息列表 =====

  /**
   * 开场白选择箭头(输入栏右上角)。
   * 仅新会话首条开场白消息时显示,点击切换到下一条开场白(超出后回绕)。
   * 用户发送首条消息后自动消失。
   */
  @Builder
  greetingSwitcherButton() {
    Row() {
      Text(this.getGreetingCounterLabel())
        .fontSize(12)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
        .margin({ left: 2 })
    }
    .padding({ left: 12, right: 10, top: 7, bottom: 7 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(16)
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.15)' })
    .onClick(() => {
      this.switchNextGreeting();
    })
  }

  @Builder
  messageList() {
    Scroll(this.scroller) {
      Column() {
        LazyForEach(this.dataSource, (state: ChatMessageRenderState, _index: number) => {
          if (state.role !== ChatRole.System || state.senderType === 'narrator') {
            Column() {
              ChatMessageBubble({
                renderState: state,
                characterAvatarUri: this.character !== null ? this.character!.avatarUri : '',
                characterName: this.viewModel !== null ? this.viewModel!.characterName : '',
                showAvatar: state.source !== ChatMessageSource.CharacterFirstMessage,
                settings: this.chatTextStyle,
                senderCharacterId: this.character !== null ? this.character!.id : '',
                colorTheme: this.getCurrentColorTheme(),
                bubbleOpacity: this.chatBubbleOpacity,
                isDarkMode: this.isDarkMode,
                onInteractiveAction: (text: string): void => {
                  this.handleInteractiveAction(text);
                },
                onLongPress: (target: ChatMessage): void => {
                  this.actionSheetMsg = target;
                  this.showActionSheet = true;
                },
                onTtsPlay: state.role === ChatRole.Assistant
                  && this.ttsService.readMode !== TtsReadMode.Off
                  ? (): void => {
                    if (this.ttsIsSpeaking) {
                      if (this.ttsEngine === TtsEngine.Edge) {
                        this.edgeTtsService.stop();
                      } else {
                        this.ttsService.stop();
                      }
                      this.ttsIsSpeaking = false;
                    } else {
                      const onComplete = (): void => { this.ttsIsSpeaking = false; };
                      const onStart = (): void => { this.ttsIsSpeaking = true; };
                      if (this.ttsEngine === TtsEngine.Edge) {
                        const onError = (msg: string): void => {
                          this.ttsIsSpeaking = false;
                          promptAction.showToast({ message: msg, duration: 2500 });
                        };
                        this.edgeTtsService.speak(state.displayContent, onComplete, onStart, onError);
                      } else {
                        this.ttsService.speak(state.displayContent, onComplete, onStart);
                      }
                      this.ttsIsSpeaking = true;
                    }
                  }
                  : undefined,
                onRegenerate: state.role === ChatRole.Assistant
                  && this.viewModel !== null
                  && this.viewModel!.canRegenerateAssistantMessage(state.messageId)
                  ? (): void => {
                    this.regenerateAssistantMessage(state.messageId);
                  }
                  : undefined,
              })

              // 分支切换控件(仅 Assistant 非首条消息)
              if (state.role === ChatRole.Assistant
                && state.source !== ChatMessageSource.CharacterFirstMessage
                && this.viewModel !== null) {
                MessageSwipeControls({
                  activeCandidateIndex: this.getSwipeActiveIndex(state.messageId),
                  candidateCount: this.getCandidateCount(state.messageId),
                  isGenerating: this.viewModel!.isGenerating,
                  isOperable: this.viewModel!.canOperateSwipe(state.messageId),
                  onPrevious: (): void => {
                    this.viewModel!.swipePrevious(state.messageId);
                  },
                  onNext: (): void => {
                    this.viewModel!.swipeNext(state.messageId);
                  },
                  onStop: (): void => {
                    this.viewModel!.stop();
                  }
                })
              }

              // 失败重试按钮
              if (state.status === ChatMessageStatus.Failed
                && this.viewModel !== null
                && this.viewModel!.canRegenerateAssistantMessage(state.messageId)) {
                Row() {
                  Button({ type: ButtonType.Normal, stateEffect: false }) {
                    Row() {
                      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                        .fontSize(14)
                        .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
                      Text($r('app.string.chat_regenerate'))
                        .fontSize($r('app.float.app_font_caption'))
                        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                        .margin({ left: 4 })
                    }
                  }
                  .backgroundColor(this.computeRegenerateButtonColor())
                  .borderRadius(14)
                  .height(28)
                  .padding({ left: 12, right: 12 })
                  .margin({ top: 4, bottom: 4 })
                  .onClick(() => {
                    this.regenerateAssistantMessage(state.messageId);
                  })
                }
                .width('100%')
                .justifyContent(FlexAlign.Start)
                .margin({ left: 0 })
              }
            }
            .width('100%')
          }
        }, (state: ChatMessageRenderState) => state.messageId)
        // 底部空白占位:高度等于悬浮输入栏占用空间(输入栏 56 + bottom padding 12 + navBar 12),
        // 让 scrollEdge(Bottom) 时最后一条消息显示在悬浮输入栏上方,不被遮挡。
        // 键盘弹起时输入栏上移到键盘上方,占位同步增加 keyboardHeight,避免最后一条消息被遮挡。
        // 代写候选面板出现时额外增加高度,避免面板遮挡最后一条消息。
        Blank().height(120 + this.navigationBarHeight + this.keyboardHeight
          + (this.viewModel !== null
            && (this.viewModel!.impersonateCandidates.length > 0
              || this.viewModel!.isImpersonateGenerating) ? 150 : 0))
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: this.statusBarHeight + 12,
        bottom: 0
      })
      .onAreaChange(() => {
        this.autoScrollToBottom();
      })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .height('100%')
    .onScrollEdge((side: Edge) => {
      if (side === Edge.Bottom && this.viewModel !== null) {
        this.viewModel!.userScrolledUp = false;
      }
    })
    .onScrollEnd(() => {
      if (this.viewModel !== null && this.scroller.isAtEnd()) {
        this.viewModel!.userScrolledUp = false;
      }
    })
  }

  /**
   * 同步最新消息到稳定 RenderState 列表。
   *
   * 关键约束:
   * - 同一 messageId 始终复用已有 RenderState 实例,保证 ForEach 稳定复用 Bubble
   * - 已有实例就地调用 applyMessage,@Observed 字段赋值触发 @ObjectLink 响应式重建
   * - 新消息才创建新 RenderState
   * - 已不存在于最新消息中的旧状态从缓存中移除
   * - 始终按最新消息顺序生成新 messageStates 数组(不原地修改)
   */
  private syncRenderStates(messages: ChatMessage[]): void {
    const nextStates: ChatMessageRenderState[] = [];
    const newIds: Set<string> = new Set<string>();
    let reusedCount: number = 0;
    let newCount: number = 0;
    for (let i: number = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      newIds.add(msg.id);
      let state: ChatMessageRenderState | undefined = this.stateMap.get(msg.id);
      if (state === undefined) {
        state = new ChatMessageRenderState(msg);
        this.stateMap.set(msg.id, state);
        newCount++;
      } else {
        state.applyMessage(msg);
        reusedCount++;
      }
      // 显示层宏替换:把 {{user}}/{{char}} 替换为当前生效称呼与角色名。
      // 仅影响展示文本(气泡渲染),不修改 message.content 原文(复制/编辑仍用原文)。
      state.setDisplayContent(this.resolveDisplayContent(msg.content));
      nextStates.push(state);
    }
    // 清理已不在最新消息列表中的旧状态
    const oldIds: string[] = Array.from(this.stateMap.keys());
    let removedCount: number = 0;
    for (let i: number = 0; i < oldIds.length; i++) {
      if (!newIds.has(oldIds[i])) {
        this.stateMap.delete(oldIds[i]);
        removedCount++;
      }
    }
    this.messageStates = nextStates;
    // 同步懒加载数据源,触发 LazyForEach 按 key 复用已有气泡组件
    this.dataSource.setStates(nextStates);
  }

  /**
   * 显示层宏替换:把 {{user}}/{{char}}/{{character}} 替换为当前生效称呼与角色名。
   * 其余宏在展示层保持原样。无角色或称呼为空时保持原文。
   * @param content 原始消息正文
   * @returns 带当前称呼/角色名的展示文本
   */
  private resolveDisplayContent(content: string): string {
    if (content.length === 0) {
      return '';
    }
    const charName: string = resolveCharacterDisplayName(this.character);
    return displayMacroReplacer.replaceDisplayNames(content, charName, this.resolvedUserName);
  }

  // ===== 空会话状态 =====

  @Builder
  emptyStateView() {
    Column() {
      if (this.viewModel !== null && !this.viewModel!.hasCurrentModel) {
        Text($r('app.string.chat_no_model'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ bottom: $r('app.float.app_spacing_16') })

        Button($r('app.string.chat_go_settings'))
          .fontSize($r('app.float.app_font_body'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(40)
          .padding({ left: 20, right: 20 })
          .onClick(() => {
            this.goToModelSettings();
          })
      } else if (this.character !== null) {
        // 显示角色头像 + 名称 + 开场白
        CharacterImageView({
          imageUri: this.character!.avatarUri,
          fallbackName: this.character!.name,
          imgWidth: 80,
          imgHeight: 80,
          imgBorderRadius: 40,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })
        Text(this.character!.name)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ top: $r('app.float.app_spacing_12') })

        if (this.character!.firstMessage.length > 0) {
          Text(this.resolveDisplayContent(this.character!.firstMessage))
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)
            .margin({ top: $r('app.float.app_spacing_12'), left: 32, right: 32 })
            .padding({
              left: $r('app.float.app_spacing_16'),
              right: $r('app.float.app_spacing_16'),
              top: $r('app.float.app_spacing_12'),
              bottom: $r('app.float.app_spacing_12')
            })
            .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_md'))
        }

        Text($r('app.string.nav_chat_empty'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ top: $r('app.float.app_spacing_24') })
      } else {
        Text($r('app.string.nav_chat_empty'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24, top: 32, bottom: 32 })
  }

  // ===== 加载/错误视图 =====

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(ThemePalette.accentColor(this.effectiveTheme))
      Text('加载会话中…')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  initErrorView() {
    Column() {
      Text('会话初始化失败')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontColor($r('app.color.app_danger'))
        .margin({ bottom: 8 })
      Text(this.viewModel !== null ? this.viewModel!.initError : '')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 底部输入区 =====

  /**
   * v8.1: 紧凑上下文占用指示器
   * - 显示在输入栏上方(贴近输入栏,不遮挡消息)
   * - 格式:"12.4K / 32K · 39%"
   * - 颜色按占用级别变化(Normal/Warning/High/Exceeded)
   * - 点击打开 ContextBudgetPage
   * - 无统计数据时隐藏
   */
  @Builder
  topBarBudgetIndicator() {
    if (this.budgetViewModel !== null && this.budgetViewModel!.effectiveAvailable > 0) {
      Row() {
        Text(this.getBudgetIndicatorText())
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .maxLines(1)
      }
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .borderRadius(8)
      .backgroundColor('rgba(128,128,128,0.15)')
      .onClick(() => {
        this.navigateToContextBudget();
      })
    }
  }

  @Builder
  budgetIndicator() {
  }

  @Builder
  inputArea() {
    Column() {
      // AI 操作按钮行(仅空闲时显示)
      if (this.viewModel !== null && !this.viewModel!.busy && !this.viewModel!.isGenerating) {
        Row() {
          Button({ type: ButtonType.Normal }) {
            Text('🎭代写')
              .fontSize(11)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          }
          .height(28)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(14)
          .padding({ left: 10, right: 10 })
          .margin({ right: 6 })
          .onClick(() => {
            if (this.viewModel !== null && !this.viewModel!.busy) {
              this.viewModel!.impersonate();
            }
          })

          Button({ type: ButtonType.Normal }) {
            Text('⚡续写')
              .fontSize(11)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          }
          .height(28)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(14)
          .padding({ left: 10, right: 10 })
          .margin({ right: 6 })
          .onClick(() => {
            if (this.viewModel !== null && !this.viewModel!.busy) {
              this.viewModel!.autoContinue();
            }
          })

          Button({ type: ButtonType.Normal }) {
            Text(this.narratorModeActive ? '📖旁白✓' : '📖旁白')
              .fontSize(11)
              .fontColor(this.narratorModeActive
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.textPrimaryColor(this.effectiveTheme))
          }
          .height(28)
          .backgroundColor(this.narratorModeActive
            ? '#205B7CFA'
            : ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(14)
          .padding({ left: 10, right: 10 })
          .margin({ right: 6 })
          .onClick(() => {
            this.narratorModeActive = !this.narratorModeActive;
          })

        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ left: 4, right: 4, bottom: 4 })
      }

      // 旁白模式标签
      if (this.narratorModeActive) {
        Row() {
          Text('[旁白模式]')
            .fontSize(10)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontWeight(FontWeight.Bold)
          Text(' Enter=仅旁白')
            .fontSize(10)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }
        .padding({ left: 12, bottom: 2 })
      }

      Row() {
      if (this.isSendButtonOnLeft()) {
        this.sendStopButton()
      }

      TextArea({
        placeholder: this.narratorModeActive ? '输入旁白叙述…' : $r('app.string.chat_input_placeholder'),
        text: this.viewModel !== null ? this.viewModel!.inputText : ''
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .borderRadius($r('app.float.app_radius_md'))
        .border({ width: 0 })
        .maxLines(10)
        .barState(BarState.Auto)
        .constraintSize({ minHeight: 40, maxHeight: 280 })
        .layoutWeight(1)
        .padding({ left: 14, right: 8, top: 8, bottom: 8 })
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string) => {
          if (this.viewModel !== null) {
            this.viewModel!.updateInput(value);
          }
        })
        .onSubmit((enterKey: EnterKeyType, event?: SubmitEvent) => {
          if (this.isBudgetExceeded()) {
            this.notifyBudgetBlocked();
          } else if (this.canSend() && this.viewModel !== null) {
            if (this.narratorModeActive) {
              this.viewModel!.sendNarratorOnly();
              this.narratorModeActive = false;
            } else {
              this.viewModel!.send();
            }
          }
          event?.keepEditableState();
        })
        .onKeyPreIme((event: KeyEvent): boolean => {
          if (event.type === KeyType.Down
            && (event.keyCode === KeyCode.KEYCODE_ENTER
              || event.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER)) {
            let hasCtrl: boolean = false;
            try {
              hasCtrl = event.getModifierKeyState?.(['Ctrl']) ?? false;
            } catch (_e) {
              hasCtrl = false;
            }
            if (hasCtrl) {
              return false;
            }
            if (this.isBudgetExceeded()) {
              this.notifyBudgetBlocked();
              return true;
            }
            if (this.canSend() && this.viewModel !== null) {
              if (this.narratorModeActive) {
                this.viewModel!.sendNarratorOnly();
                this.narratorModeActive = false;
              } else {
                this.viewModel!.send();
              }
              return true;
            }
          }
          return false;
        })

      if (!this.isSendButtonOnLeft()) {
        this.sendStopButton()
      }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .borderRadius(24)
    .border({ width: 0.5, color: ThemePalette.surface2Color(this.effectiveTheme) })
    .backgroundBlurStyle(BlurStyle.Regular, {
      policy: BlurStyleActivePolicy.ALWAYS_ACTIVE
    })
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
  }

  @Builder
  sendStopButton() {
    if (this.viewModel !== null && this.viewModel!.canStop) {
      Stack() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor([$r('app.color.app_on_accent')])
      }
      .backgroundColor($r('app.color.app_danger'))
      .borderRadius(20)
      .height(40)
      .width(40)
      .margin({ left: 2, right: 2 })
      .onClick(() => {
        this.viewModel!.stop();
      })
    } else if (this.narratorModeActive) {
      Row() {
        Stack() {
          Text('📝')
            .fontSize(14)
        }
        .backgroundColor(this.canSend()
          ? ThemePalette.surface2Color(this.effectiveTheme)
          : Color.Transparent)
        .borderRadius(20)
        .height(36)
        .width(36)
        .margin({ left: 1, right: 1 })
        .onClick(() => {
          if (this.canSend() && this.viewModel !== null) {
            this.viewModel!.sendNarratorOnly();
            this.narratorModeActive = false;
          }
        })
        Stack() {
          Text('🎬')
            .fontSize(14)
        }
        .backgroundColor(this.canSend()
          ? ThemePalette.accentColor(this.effectiveTheme)
          : Color.Transparent)
        .borderRadius(20)
        .height(36)
        .width(36)
        .margin({ left: 1, right: 1 })
        .onClick(() => {
          if (this.isBudgetExceeded()) {
            this.notifyBudgetBlocked();
            return;
          }
          if (this.canSend() && this.viewModel !== null) {
            this.viewModel!.sendNarrator();
            this.narratorModeActive = false;
          }
        })
      }
    } else {
      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(16)
          .fontColor([
            this.canSend()
              ? $r('app.color.app_on_accent')
              : ThemePalette.textTertiaryColor(this.effectiveTheme)
          ])
      }
      .backgroundColor(this.canSend()
        ? ThemePalette.accentColor(this.effectiveTheme)
        : Color.Transparent)
      .borderRadius(20)
      .height(40)
      .width(40)
      .margin({ left: 2, right: 2 })
      .onClick(() => {
        if (this.isBudgetExceeded()) {
          this.notifyBudgetBlocked();
          return;
        }
        if (this.canSend() && this.viewModel !== null) {
          if (this.narratorModeActive) {
            this.viewModel!.sendNarratorOnly();
            this.narratorModeActive = false;
          } else {
            this.viewModel!.send();
          }
        }
      })
    }
  }

  // ===== 清空确认弹窗 =====

  @Builder
  clearConfirmDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.chat_clear'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })

          Text('将删除当前会话的所有消息,此操作不可撤销。')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)
            .margin({ bottom: 16 })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.showClearConfirm = false;
              })
            Button($r('app.string.chat_clear'))
              .fontSize(15)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel!.clear();
                }
                this.showClearConfirm = false;
              })
          }
          .width('100%')
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showClearConfirm = false;
    })
  }

  // ===== v9: 本对话称呼覆盖对话框 =====

  /**
   * 打开本对话称呼覆盖编辑对话框。
   * - 加载当前覆盖值到草稿
   * - 同步刷新一次 resolvedUserName
   */
  private openUserNameOverrideDialog(): void {
    if (this.viewModel === null) {
      return;
    }
    this.userNameOverrideDraft = this.viewModel!.getCurrentChatUserNameOverride();
    this.showUserNameOverrideDialog = true;
  }

  /**
   * 保存对话级用户称呼覆盖。
   * - 草稿 trim 后为空:清空覆盖(回退到角色或全局)
   * - 草稿非空:写入覆盖(仅影响当前会话)
   */
  private async saveUserNameOverride(): Promise<void> {
    if (this.viewModel === null) {
      this.showUserNameOverrideDialog = false;
      return;
    }
    try {
      const trimmed: string = this.userNameOverrideDraft.trim();
      await this.viewModel!.updateUserNameOverride(trimmed.length > 0 ? trimmed : null);
      await this.refreshUserNameDisplay();
    } catch (e) {
      // 失败时只关闭对话框,不阻塞后续操作
    }
    this.showUserNameOverrideDialog = false;
  }

  /**
   * 刷新当前生效用户称呼 + 对话覆盖的显示状态。
   * 在打开菜单、关闭菜单、保存覆盖后调用。
   */
  private async refreshUserNameDisplay(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      this.resolvedUserName = await this.viewModel!.getResolvedUserName();
      this.currentUserNameOverride = this.viewModel!.getCurrentChatUserNameOverride();
    } catch (e) {
      // 读取失败时保留空值,不影响主流程
    }
    // 称呼变化后重新计算气泡展示文本({{user}} 用最新称呼),不改变原始 content
    if (this.messages.length > 0) {
      this.syncRenderStates(this.messages);
    }
  }

  /**
   * 打开 Persona 选择 ActionSheet。
   * 加载所有 Persona 并展示选择列表。
   */
  private async openPersonaPicker(): Promise<void> {
    try {
      const service = AppServices.getPersonaService();
      this.personaOptions = await service.list();
      // 获取当前生效的身份名称
      await this.refreshPersonaDisplay();
      this.showPersonaPicker = true;
    } catch (e) {
      Logger.error(LOG_TAG, 'openPersonaPicker failed: ' + String(e));
    }
  }

  /**
   * 选择 Persona 锁定到当前聊天。
   * personaId 为空字符串时清除锁定。
   */
  private async selectPersonaForChat(personaId: string): Promise<void> {
    if (this.viewModel === null) {
      this.showPersonaPicker = false;
      return;
    }
    try {
      await this.viewModel!.updateChatPersonaId(personaId.length > 0 ? personaId : null);
      await this.refreshPersonaDisplay();
      // 身份变化后重新计算气泡展示文本
      if (this.messages.length > 0) {
        this.syncRenderStates(this.messages);
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'selectPersonaForChat failed: ' + String(e));
    }
    this.showPersonaPicker = false;
  }

  /**
   * 刷新当前生效身份名称。
   */
  private async refreshPersonaDisplay(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      const service = AppServices.getPersonaService();
      const chatPersonaId: string = this.viewModel!.getCurrentChatPersonaId();
      const characterDefaultPersonaId: string = this.viewModel!.getCharacterDefaultPersonaId();
      const persona: Persona | null = await service.resolveEffectivePersona(
        chatPersonaId,
        characterDefaultPersonaId
      );
      this.resolvedPersonaName = persona !== null ? persona.name : '';
    } catch (e) {
      this.resolvedPersonaName = '';
    }
  }

  // ===== v42 新建章节(切换开场白) =====

  /**
   * 打开"新建章节"开场白选择器。
   * 从 viewModel 取开场白池;池为空时提示并关闭。
   */
  private openChapterGreetingPicker(): void {
    if (this.viewModel === null) {
      return;
    }
    const pool: string[] = this.viewModel!.getGreetingPool();
    if (pool.length === 0) {
      promptAction.showToast({ message: '该角色没有可用的开场白', duration: 1500 });
      return;
    }
    this.chapterGreetingPool = pool;
    this.showChapterGreetingPicker = true;
  }

  /**
   * 选中开场白 → 调 viewModel.createChapter(index)。
   * 成功后刷新会话列表并提示;原会话保留,可切回。
   */
  private async selectChapterGreeting(index: number): Promise<void> {
    if (this.viewModel === null || this.chapterCreateBusy) {
      return;
    }
    this.chapterCreateBusy = true;
    try {
      const newChatId: string = await this.viewModel!.createChapter(index);
      if (newChatId.length > 0) {
        this.showChapterGreetingPicker = false;
        this.chapterGreetingPool = [];
        this.refreshUserNameDisplay();
        promptAction.showToast({ message: '已创建新章节,原对话可切回', duration: 2000 });
      } else {
        const msg: string = this.viewModel!.sessionError.length > 0
          ? this.viewModel!.sessionError : '新建章节失败';
        promptAction.showToast({ message: msg, duration: 2000 });
      }
    } catch (e) {
      promptAction.showToast({ message: '新建章节失败', duration: 2000 });
      Logger.error(LOG_TAG, 'selectChapterGreeting failed: ' + String(e));
    } finally {
      this.chapterCreateBusy = false;
    }
  }

  /** 关闭"新建章节"开场白选择器 */
  private closeChapterGreetingPicker(): void {
    if (this.chapterCreateBusy) {
      return;
    }
    this.showChapterGreetingPicker = false;
    this.chapterGreetingPool = [];
  }

  /** 开场白选择弹窗:列表显示每项前 100 字预览 */
  @Builder
  chapterGreetingPickerDialog() {
    Stack() {
      Column() {
        Column() {
          Row() {
            Text('新建章节 · 选择开场白')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            Blank()
            Button('取消')
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .height(36)
              .enabled(!this.chapterCreateBusy)
              .onClick(() => {
                this.closeChapterGreetingPicker();
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 4 })

          Text('新章节将加入同一世界分组,原对话保留可切回')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 8 })

          Scroll() {
            Column() {
              ForEach(this.chapterGreetingPool, (greeting: string, index: number) => {
                Column() {
                  Text('开场白 ' + (index + 1).toString())
                    .fontSize(12)
                    .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                    .width('100%')
                  Text(this.greetingPreview(greeting))
                    .fontSize(13)
                    .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                    .width('100%')
                    .margin({ top: 2 })
                    .maxLines(4)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding(12)
                .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                .borderRadius(8)
                .margin({ bottom: 8 })
                .alignItems(HorizontalAlign.Start)
                .onClick(() => {
                  this.selectChapterGreeting(index);
                })
              }, (greeting: string, index: number) => 'greeting_' + index.toString())
            }
            .width('100%')
          }
          .height(300)
          .scrollBar(BarState.Auto)

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 4, bottom: 4 })

          Button(this.chapterCreateBusy ? '正在创建章节...' : '创建章节')
            .fontSize(15)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .enabled(!this.chapterCreateBusy)
            .onClick(() => {
              if (!this.chapterCreateBusy && this.chapterGreetingPool.length > 0) {
                this.selectChapterGreeting(0);
              }
            })
        }
        .width('88%')
        .padding(16)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.closeChapterGreetingPicker();
    })
  }

  /** 开场白预览文本:前 100 字,超长省略 */
  private greetingPreview(greeting: string): string {
    const trimmed: string = greeting.trim();
    if (trimmed.length <= 100) {
      return trimmed;
    }
    return trimmed.substring(0, 100) + '…';
  }

  @Builder
  userNameOverrideDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.chat_user_name_override_menu_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })

          Text($r('app.string.chat_user_name_override_hint'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)
            .margin({ bottom: 16 })

          TextInput({
            placeholder: $r('app.string.chat_user_name_override_placeholder'),
            text: this.userNameOverrideDraft
          })
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_md'))
            .height(48)
            .padding({ left: 16, right: 16 })
            .width('100%')
            .onChange((value: string) => {
              this.userNameOverrideDraft = value;
            })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.showUserNameOverrideDialog = false;
              })
            Button($r('app.string.character_edit_save'))
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                this.saveUserNameOverride();
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('80%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showUserNameOverrideDialog = false;
    })
  }

  @Builder
  personaPickerSheet() {
    Stack() {
      Column() {
        Column() {
          Text('切换用户身份')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          Scroll() {
            Column() {
              // "清除锁定"选项
              Row() {
                Column() {
                  Text('跟随默认')
                    .fontSize(15)
                    .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  Text('使用角色或全局默认身份')
                    .fontSize(12)
                    .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                if (this.viewModel !== null && this.viewModel!.getCurrentChatPersonaId().length === 0) {
                  Text('✓')
                    .fontSize(16)
                    .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                }
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.selectPersonaForChat('');
              })

              Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

              // Persona 列表
              ForEach(this.personaOptions, (persona: Persona) => {
                Row() {
                  Column() {
                    Text(persona.name)
                      .fontSize(15)
                      .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                    if (persona.description.length > 0) {
                      Text(persona.description)
                        .fontSize(12)
                        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                        .maxLines(3)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 2 })
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  if (this.viewModel !== null && this.viewModel!.getCurrentChatPersonaId() === persona.id) {
                    Text('✓')
                      .fontSize(16)
                      .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                  }
                }
                .width('100%')
                .padding({ top: 10, bottom: 10 })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.selectPersonaForChat(persona.id);
                })
              }, (persona: Persona) => persona.id)

              if (this.personaOptions.length === 0) {
                Text('暂无身份，请先在设置中创建')
                  .fontSize(13)
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .margin({ top: 12 })
              }
            }
            .width('100%')
          }
          .height(280)
          .scrollBar(BarState.Auto)

          Divider()
            .color(ThemePalette.dividerColor(this.effectiveTheme))
            .margin({ top: 8, bottom: 8 })

          Column() {
            Text('用户性格总结')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .margin({ bottom: 6 })

            if (this.viewModel !== null && this.viewModel!.userPersonaSummary.length > 0) {
              Text(this.viewModel!.userPersonaSummary)
                .fontSize(13)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .maxLines(8)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ bottom: 8 })
            } else {
              Text('尚未生成。点击下方按钮从角色卡提取或从对话总结。')
                .fontSize(13)
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .margin({ bottom: 8 })
            }

            Row() {
              Button('从角色卡提取')
                .fontSize(13)
                .height(34)
                .padding({ left: 12, right: 12 })
                .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .enabled(this.viewModel !== null && !this.viewModel!.isExtractingUserPersona)
                .onClick(() => {
                  if (this.viewModel !== null) {
                    this.viewModel!.extractUserFromCharacter();
                  }
                })
              Button('从对话总结')
                .fontSize(13)
                .height(34)
                .padding({ left: 12, right: 12 })
                .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .margin({ left: 8 })
                .enabled(this.viewModel !== null && !this.viewModel!.isSummarizingUserPersona)
                .onClick(() => {
                  if (this.viewModel !== null) {
                    this.viewModel!.summarizeUserPersona();
                  }
                })

              Blank()

              if (this.viewModel !== null && this.viewModel!.userPersonaSummary.length > 0) {
                Button() {
                  SymbolGlyph($r('sys.symbol.trash'))
                    .fontSize(18)
                    .fontColor([$r('app.color.app_danger')])
                }
                .type(ButtonType.Circle)
                .width(34)
                .height(34)
                .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                .margin({ left: 8 })
                .onClick(() => {
                  if (this.viewModel !== null) {
                    this.viewModel!.clearUserPersonaSummary();
                  }
                })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            if (this.viewModel !== null &&
              (this.viewModel!.isExtractingUserPersona || this.viewModel!.isSummarizingUserPersona)) {
              LoadingProgress()
                .width(20)
                .height(20)
                .color(ThemePalette.accentColor(this.effectiveTheme))
                .margin({ top: 8 })
            }
          }
          .width('100%')

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .height(40)
              .layoutWeight(1)
              .onClick(() => {
                this.showPersonaPicker = false;
              })
          }
          .width('100%')
          .margin({ top: 8 })
        }
        .width('85%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showPersonaPicker = false;
    })
  }

  // ===== 辅助方法 =====

  private canSend(): boolean {
    // v8.1: 上下文超预算时禁止发送(必须先处理超限)
    if (this.isBudgetExceeded()) {
      return false;
    }
    return this.viewModel !== null && this.viewModel!.canSend;
  }

  /**
   * 处理气泡内交互动作(点击分支选项)。
   * 把选项文字作为当前输入并走既有发送流程发给 AI。
   */
  private handleInteractiveAction(text: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.isBudgetExceeded()) {
      this.notifyBudgetBlocked();
      return;
    }
    const vm: ChatViewModel = this.viewModel!;
    if (vm.isGenerating) {
      return;
    }
    // 先写入输入,再走既有发送流程(send() 内部会自行校验 canSend)
    vm.inputText = text;
    vm.send();
    try {
      inputMethod.getController().stopInputSession();
    } catch (_e) {
      // 输入法未显示或已隐藏,忽略
    }
  }

  /**
   * v8.1: 当前上下文是否超出输入预算。
   * 基于 budgetViewModel.stats 与 effectiveAvailable 计算。
   */
  private isBudgetExceeded(): boolean {
    if (this.budgetViewModel === null || this.budgetStats === null) {
      return false;
    }
    const available: number = this.budgetViewModel!.effectiveAvailable;
    if (available <= 0) {
      return true;
    }
    return this.budgetStats!.totalInputTokens > available;
  }

  /**
   * v8.1: 当前占用比例(0~1+,无 stats 时返回 0)。
   */
  private getBudgetUsageRatio(): number {
    if (this.budgetViewModel === null) {
      return 0;
    }
    if (this.budgetStats === null) {
      return 0;
    }
    const available: number = this.budgetViewModel!.effectiveAvailable;
    if (available <= 0) {
      return this.budgetStats!.totalInputTokens > 0 ? 1 : 0;
    }
    return this.budgetStats!.totalInputTokens / available;
  }

  /**
   * v8.1: 紧凑指示器文本,如 "12.4K / 32K · 39%"。
   */
  private getBudgetIndicatorText(): string {
    if (this.budgetViewModel === null) {
      return '';
    }
    const used: number = this.budgetStats !== null ? this.budgetStats!.totalInputTokens : 0;
    const available: number = this.budgetViewModel!.effectiveAvailable;
    const ratio: number = this.getBudgetUsageRatio();
    const percent: number = Math.round(ratio * 100);
    return this.formatTokenCompact(used) + ' / ' + this.formatTokenCompact(available)
      + ' · ' + percent.toString() + '%';
  }

  /**
   * v8.2: 紧凑 Token 数值格式化。
   * - >= 1000000 显示为 M(保留 1 位小数,如 1M / 1.5M)
   * - >= 1000 显示为 K(保留 1 位小数,如 12.4K / 128K)
   * - 否则原样显示
   */
  private formatTokenCompact(value: number): string {
    if (value >= 1000000) {
      const m: number = value / 1000000;
      const s: string = m.toFixed(1);
      if (s.endsWith('.0')) {
        return s.substring(0, s.length - 2) + 'M';
      }
      return s + 'M';
    }
    if (value >= 1000) {
      const k: number = value / 1000;
      const s: string = k.toFixed(1);
      // 去除 .0 后缀
      if (s.endsWith('.0')) {
        return s.substring(0, s.length - 2) + 'K';
      }
      return s + 'K';
    }
    return value.toString();
  }

  /**
   * v8.1: 指示器颜色(按占用级别)。
   * - Normal(<70%):text_tertiary
   * - Warning(70~90%):app_accent
   * - High(>=90%):app_danger
   * - Exceeded(>100%):app_danger
   */
  private getBudgetIndicatorColor(): ResourceColor {
    return ThemePalette.textTertiaryColor(this.effectiveTheme);
  }

  private getCacheHitText(): string {
    if (this.cacheHitRatio < 0) {
      return '';
    }
    const percent: number = Math.round(this.cacheHitRatio * 100);
    return 'Cache ' + percent.toString() + '%';
  }

  private getCacheHitColor(): ResourceColor {
    return ThemePalette.textTertiaryColor(this.effectiveTheme);
  }

  /**
   * v8.1: 发送被预算阻止时,提示用户处理超限。
   */
  private notifyBudgetBlocked(): void {
    promptAction.showToast({
      message: '上下文已超出输入预算,请打开"上下文管理"减少历史或调整配置',
      duration: 2000
    });
  }

  private isInitialLoading(): boolean {
    return this.viewModel !== null && this.viewModel!.isInitializing;
  }

  private hasInitError(): boolean {
    return this.viewModel !== null && this.viewModel!.initError.length > 0;
  }

  /**
   * 是否显示"再试一次"悬浮按钮:
   * - ViewModel 就绪
   * - 可重新生成(canRegenerate)
   * - 当前未生成中(!isGenerating)
   * - 当前未忙碌(!busy)
   * - 消息列表非空
   */
  private showRetryFloating(): boolean {
    return this.viewModel !== null
      && this.viewModel!.canRegenerate
      && !this.viewModel!.isGenerating
      && !this.viewModel!.busy
      && this.messages.length > 0;
  }

  private getSwipeActiveIndex(messageId: string): number {
    if (this.viewModel === null) {
      return 0;
    }
    const s: MessageSwipeSummary | undefined = this.viewModel!.getSwipeSummary(messageId);
    return s !== undefined ? s.activeCandidateIndex : 0;
  }

  private getCandidateCount(messageId: string): number {
    if (this.viewModel === null) {
      return 1;
    }
    const s: MessageSwipeSummary | undefined = this.viewModel!.getSwipeSummary(messageId);
    return s !== undefined ? s.candidateCount : 1;
  }

  /**
   * 新会话首条开场白消息 ID(开始聊天前)。
   * 判定:消息列表只有一条消息且为 CharacterFirstMessage(尚无用户消息)。
   * 返回空串表示非"新会话开场白"状态。
   */
  private getOpeningFirstMessageId(): string {
    if (this.viewModel === null || this.messages.length !== 1) {
      return '';
    }
    const first: ChatMessage = this.messages[0];
    if (first.source !== ChatMessageSource.CharacterFirstMessage) {
      return '';
    }
    return first.id;
  }

  /**
   * 是否显示开场白选择箭头:
   * - 处于新会话首条开场白状态(尚未开始聊天)
   * - 非初始化中、无错误
   * - 开场白候选多于 1 条
   */
  private showGreetingSwitcher(): boolean {
    if (this.viewModel === null || this.isInitialLoading() || this.hasInitError()) {
      return false;
    }
    const firstId: string = this.getOpeningFirstMessageId();
    if (firstId.length === 0) {
      return false;
    }
    return this.getCandidateCount(firstId) > 1;
  }

  /** 开场白计数器文案,如 "1/3"。 */
  private getGreetingCounterLabel(): string {
    const firstId: string = this.getOpeningFirstMessageId();
    if (firstId.length === 0) {
      return '';
    }
    const total: number = this.getCandidateCount(firstId);
    const active: number = this.getSwipeActiveIndex(firstId);
    return String(active + 1) + '/' + String(total);
  }

  /**
   * 切换到下一条开场白(超出后回绕到第一条)。
   */
  private switchNextGreeting(): void {
    if (this.viewModel === null) {
      return;
    }
    const firstId: string = this.getOpeningFirstMessageId();
    if (firstId.length === 0) {
      return;
    }
    const count: number = this.getCandidateCount(firstId);
    if (count <= 1) {
      return;
    }
    const active: number = this.getSwipeActiveIndex(firstId);
    if (active < count - 1) {
      this.viewModel!.swipeNext(firstId);
    } else {
      this.viewModel!.activateCandidate(firstId, 0);
    }
  }

  private autoScrollToBottom(): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel.userScrolledUp) {
      return;
    }
    const newCount: number = this.messages.length;
    if (newCount > this.lastMessageCount) {
      this.lastMessageCount = newCount;
      this.scroller.scrollEdge(Edge.Bottom);
    }
  }

  /**
   * 注册键盘高度变化监听。
   *
   * EntryAbility 设为 OFFSET 上抬模式:键盘弹出时系统上抬未加 expandSafeArea(KEYBOARD) 的组件。
   * 本页面背景/Avatar/顶栏/消息列表均加了 expandSafeArea(KEYBOARD) 固定不动,
   * 仅输入栏被系统上抬到键盘上方。
   * keyboardHeight 用于消息列表底部 Blank 占位与输入栏间距判断。
   * 键盘弹起时主动滚动到底部,避免最后一条消息被输入栏遮挡。
   */
  private registerKeyboardListener(): void {
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      window.getLastWindow(ctx)
        .then((win: window.Window): void => {
          this.mainWindow = win;
          this.keyboardHeightChangeHandler = (height: number): void => {
            // px → vp 换算(键盘高度回调单位为 px,输入栏 padding 单位为 vp)
            const densityPixels: number = display.getDefaultDisplaySync().densityPixels;
            const density: number = densityPixels > 0 ? densityPixels : 3.0;
            this.keyboardHeight = height > 0 ? height / density : 0;
            if (height > 0 && this.viewModel !== null && !this.viewModel!.userScrolledUp) {
              // 键盘弹起,延迟一帧确保布局已更新,再滚动到底部
              setTimeout((): void => {
                try {
                  this.scroller.scrollEdge(Edge.Bottom);
                } catch (_e) {
                  // 忽略滚动异常
                }
              }, 80);
            }
          };
          win.on('keyboardHeightChange', this.keyboardHeightChangeHandler);
        })
        .catch((e: Error): void => {
          Logger.warn(LOG_TAG, 'getLastWindow failed: ' + e.message);
        });
    } catch (e) {
      Logger.warn(LOG_TAG, 'registerKeyboardListener failed: ' + (e as Error).message);
    }
  }

  private unregisterKeyboardListener(): void {
    if (this.mainWindow !== null && this.keyboardHeightChangeHandler !== null) {
      try {
        this.mainWindow.off('keyboardHeightChange', this.keyboardHeightChangeHandler);
      } catch (_e) {
        // 忽略注销异常
      }
      this.mainWindow = null;
      this.keyboardHeightChangeHandler = null;
      this.keyboardHeight = 0;
    }
  }

  /** 加载角色头像(指定 characterId) */
  private loadCharacterAvatar(characterId: string): void {
    const characterService = AppServices.getCharacterService();
    characterService.getById(characterId)
      .then((c: Character | null): void => {
        this.character = c;
      })
      .catch((e: Error): void => {
        Logger.warn(LOG_TAG, 'loadCharacterAvatar failed: ' + e.message);
      });
  }

  /** 加载当前角色头像(无 characterId 时) */
  private loadCurrentCharacterAvatar(): void {
    const characterService = AppServices.getCharacterService();
    characterService.getCurrentCharacter()
      .then((c: Character | null): void => {
        this.character = c;
      })
      .catch((e: Error): void => {
        Logger.warn(LOG_TAG, 'loadCurrentCharacterAvatar failed: ' + e.message);
      });
  }

  private handleBack(): void {
    router.back();
  }

  private goToModelSettings(): void {
    router.pushUrl({ url: 'pages/ModelSettingsPage' });
  }

  private goToPresetList(): void {
    this.pendingRefreshPresetName = true;
    router.pushUrl({ url: 'pages/PromptPresetListPage' });
  }

  private navigateToBranchMap(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    this.pendingReloadAfterBranchChange = true;
    router.pushUrl({
      url: 'pages/BranchMapPage',
      params: { chatId: chatId }
    });
  }

  private navigateToChatBackgroundSettings(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    router.pushUrl({
      url: 'pages/ChatBackgroundSettingsPage',
      params: { chatId: chatId }
    });
  }

  private navigateToMemoryManagement(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    router.pushUrl({
      url: 'pages/MemoryManagementPage',
      params: { chatId: chatId }
    });
  }

  private navigateToTtsSettings(): void {
    router.pushUrl({ url: 'pages/TtsSettingsPage' });
  }

  /**
   * v8.1: 刷新上下文占用统计。
   * 由 onMessagesUpdate / onBranchChangeSeqChanged / onBudgetConfigVersionChanged / onPageShow 调用。
   * 读取 chatService.getLastBuiltRequestMessages + getLastTokenBudget,
   * 通过 budgetViewModel 估算分段统计,并写入 SnapshotStore 供 ContextBudgetPage 读取。
   */
  private refreshBudgetSnapshot(): void {
    if (this.viewModel === null || this.budgetViewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    if (this.budgetViewModel!.chatId !== chatId) {
      this.budgetViewModel!.initialize(chatId!).then((): void => {
        // 初始化完成后,先从 SnapshotStore 读取已有快照立即刷新 UI
        // 避免 budgetStats 长时间为 null 导致顶栏指示器消失
        const existingSnap = ContextBudgetSnapshotStore.getInstance().getSnapshot(chatId!);
        if (existingSnap !== null) {
          this.budgetViewModel!.refreshFromSnapshot(
            existingSnap.budget, existingSnap.requestMessages
          ).then((): void => {
            this.budgetStats = this.budgetViewModel!.stats;
          }).catch((): void => {
          });
        }
        // 然后异步构建新快照(精确更新)
        this.doRefreshBudgetSnapshot(chatId!);
      }).catch((): void => {
      });
      return;
    }
    this.doRefreshBudgetSnapshot(chatId);
  }

  private doRefreshBudgetSnapshot(chatId: string): void {
    let requestMessages = this.viewModel!.getLastBuiltRequestMessages();
    if (requestMessages === undefined) {
      this.viewModel!.buildEstimateMessages().then((): void => {
        requestMessages = this.viewModel!.getLastBuiltRequestMessages();
        const budget = this.viewModel!.getLastTokenBudget();
        const store = ContextBudgetSnapshotStore.getInstance();
        store.setSnapshot({
          chatId: chatId,
          budget: budget,
          requestMessages: requestMessages
        });
        this.notifyBudgetSnapshotUpdated();
        this.budgetViewModel!.refreshFromSnapshot(budget, requestMessages).then((): void => {
          this.budgetStats = this.budgetViewModel!.stats;
        }).catch((e: Error): void => {
          Logger.warn(LOG_TAG, 'refreshFromSnapshot failed in async doRefresh: ' + e.message);
        });
      }).catch((e: Error): void => {
        Logger.warn(LOG_TAG, 'buildEstimateMessages failed in doRefresh: ' + e.message);
      });
      return;
    }
    const budget = this.viewModel!.getLastTokenBudget();
    const store = ContextBudgetSnapshotStore.getInstance();
    store.setSnapshot({
      chatId: chatId,
      budget: budget,
      requestMessages: requestMessages
    });
    this.notifyBudgetSnapshotUpdated();
    this.budgetViewModel!.refreshFromSnapshot(budget, requestMessages).then((): void => {
      this.budgetStats = this.budgetViewModel!.stats;
    }).catch((e: Error): void => {
      Logger.warn(LOG_TAG, 'refreshBudgetSnapshot failed in sync doRefresh: ' + e.message);
    });
  }

  /**
   * v8.1: 上下文预算配置变更(由 ContextBudgetPage 触发)。
   * 重新加载 budget 配置后,基于已有 messages 重算占用统计。
   */
  onBudgetConfigVersionChanged(): void {
    if (this.budgetViewModel === null || this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    // 失效估算缓存(配置变更后需重新构建请求消息,如 recentWindowTarget 调整)
    this.viewModel!.invalidateEstimateCache();
    // 重新加载配置 + 重算 stats
    this.budgetViewModel!.initialize(chatId).then((): void => {
      this.refreshBudgetSnapshot();
    }).catch((e: Error): void => {
      Logger.warn(LOG_TAG, 'onBudgetConfigVersionChanged reload failed: ' + e.message);
    });
  }

  /**
   * 记忆变更后刷新上下文占用。
   * 记忆生成/删除会改变 Prompt 的记忆摘要段与 RecentMessageSelector 的去重范围,
   * 需失效估算缓存并重算。
   */
  onMemoryVersionChanged(): void {
    if (this.budgetViewModel === null || this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    this.viewModel!.invalidateEstimateCache();
    this.refreshBudgetSnapshot();
  }

  /**
   * 通知快照已更新,供 ContextBudgetPage 从 Store 重载最新统计数据。
   */
  private notifyBudgetSnapshotUpdated(): void {
    const v: number = AppStorage.get<number>('chatBudgetSnapshotVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatBudgetSnapshotVersion', v + 1);
  }

  /**
   * v8.1: 导航到上下文管理页。
   */
  private navigateToContextBudget(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    // 离开前刷新一次快照,确保 ContextBudgetPage 读到最新数据
    this.refreshBudgetSnapshot();
    router.pushUrl({
      url: 'pages/ContextBudgetPage',
      params: { chatId: chatId }
    });
  }

  /**
   * 前往续写/代写引导设置页。
   * 进入设置页,关闭更多菜单。
   */
  private navigateToAutoWriteGuide(): void {
    this.showMoreMenu = false;
    router.pushUrl({ url: 'pages/ContinueGuideSettingsPage' });
  }

  // ===== T-CHAT.1: 聊天归档导出 =====

  /**
   * T-CHAT.1: 导出当前聊天。
   * 从 ChatViewModel 获取当前 chatId 与角色信息,调用 ChatArchiveViewModel 执行导出。
   */
  private async exportCurrentChat(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.archiveBusy) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    this.archiveBusy = true;
    try {
      const vm: ChatArchiveViewModel = this.ensureArchiveViewModel();
      const title: string = this.viewModel!.characterName.length > 0
        ? this.viewModel!.characterName
        : '对话';
      const charName: string = resolveCharacterDisplayName(this.character);
      const ok: boolean = await vm.exportCurrentConversation({
        conversationId: chatId,
        conversationTitle: title,
        characterName: charName
      });
      if (ok && vm.lastExportStats !== null) {
        promptAction.showToast({
          message: '聊天导出成功: ' + String(vm.lastExportStats!.conversationCount)
            + ' 个对话, ' + String(vm.lastExportStats!.messageCount) + ' 条消息',
          duration: 2500
        });
      } else if (!ok && vm.errorMessage.length > 0) {
        promptAction.showToast({ message: vm.errorMessage, duration: 2500 });
      }
      vm.resetState();
    } finally {
      this.archiveBusy = false;
    }
  }

  /**
   * T-CHAT.1: 导出该角色全部聊天。
   */
  private async exportCharacterChats(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.archiveBusy) {
      return;
    }
    if (this.character === null || this.character!.id.length === 0) {
      promptAction.showToast({ message: '当前无角色,无法导出', duration: 1500 });
      return;
    }
    this.archiveBusy = true;
    try {
      const vm: ChatArchiveViewModel = this.ensureArchiveViewModel();
      const ok: boolean = await vm.exportCharacterConversations({
        characterId: this.character!.id,
        characterName: this.character!.name
      });
      if (ok && vm.lastExportStats !== null) {
        promptAction.showToast({
          message: '导出成功: ' + String(vm.lastExportStats!.conversationCount)
            + ' 个对话, ' + String(vm.lastExportStats!.messageCount) + ' 条消息',
          duration: 2500
        });
      } else if (!ok && vm.errorMessage.length > 0) {
        promptAction.showToast({ message: vm.errorMessage, duration: 2500 });
      }
      vm.resetState();
    } finally {
      this.archiveBusy = false;
    }
  }

  /**
   * 懒创建 ChatArchiveViewModel。
   */
  private ensureArchiveViewModel(): ChatArchiveViewModel {
    if (this.archiveViewModel === null) {
      this.archiveViewModel = AppServices.createChatArchiveViewModel();
    }
    return this.archiveViewModel!;
  }

  /**
   * 从指定消息创建独立对话。
   * 弹出自定义选择弹窗,让用户选择完整历史或仅记忆模式。
   */
  private forkChatFromMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    const branchId: string = this.viewModel!.activeBranchId;
    if (branchId.length === 0) {
      promptAction.showToast({ message: '当前无活动分支', duration: 1500 });
      return;
    }
    this.forkTargetMessageId = messageId;
    this.showForkModePicker = true;
  }

  @Builder
  forkModePickerDialog() {
    Stack() {
      Column() {
        Text('从此处创建独立对话')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ top: 20, bottom: 8 })

        Text('选择新会话的初始内容范围,新会话与原会话后续完全独立。')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .lineHeight(20)
          .margin({ left: 16, right: 16, bottom: 12 })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

        // 携带完整历史
        Column() {
          Text('携带完整历史')
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ top: 12, bottom: 4 })
          Text('复制从根到当前消息的全部历史与记忆')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 8, bottom: 12 })
        .onClick(() => {
          this.showForkModePicker = false;
          void this.executeForkChat(this.forkTargetMessageId, true);
        })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

        // 只携带记忆
        Column() {
          Text('只携带记忆')
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ top: 12, bottom: 4 })
          Text('不复制旧消息,仅继承记忆摘要 + 最近 2 条消息')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding({ top: 8, bottom: 12 })
        .onClick(() => {
          this.showForkModePicker = false;
          void this.executeForkChat(this.forkTargetMessageId, false);
        })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

        // 取消
        Text('取消')
          .fontSize(15)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 14 })
          .onClick(() => {
            this.showForkModePicker = false;
          })
      }
      .width('80%')
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showForkModePicker = false;
    })
  }

  private async executeForkChat(
    forkMessageId: string,
    fullHistory: boolean
  ): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const sourceChatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (sourceChatId === undefined || sourceChatId.length === 0) {
      promptAction.showToast({ message: '会话未就绪', duration: 1500 });
      return;
    }
    const sourceBranchId: string = this.viewModel!.activeBranchId;
    if (sourceBranchId.length === 0) {
      promptAction.showToast({ message: '当前无活动分支', duration: 1500 });
      return;
    }
    promptAction.showToast({ message: '正在创建独立对话...', duration: 1500 });
    try {
      const forkService = AppServices.getForkChatService();
      const result = fullHistory
        ? await forkService.forkChatWithFullHistory({
            mode: ForkChatMode.FullHistory,
            sourceChatId: sourceChatId,
            sourceBranchId: sourceBranchId,
            forkMessageId: forkMessageId
          })
        : await forkService.forkChatWithMemoryOnly({
            mode: ForkChatMode.MemoryOnly,
            sourceChatId: sourceChatId,
            sourceBranchId: sourceBranchId,
            keepRecentMessages: 2
          });
      const msg: string = '已创建新对话(复制 '
        + result.copiedMessageCount.toString() + ' 条消息, '
        + result.copiedMemoryCount.toString() + ' 条记忆)';
      promptAction.showToast({ message: msg, duration: 2000 });
    } catch (e) {
      Logger.error(LOG_TAG, 'executeForkChat failed: ' + String(e));
      promptAction.showToast({
        message: '创建失败: ' + (e instanceof Error ? e.message : String(e)),
        duration: 2500
      });
    }
  }

  /**
   * 会话首次就绪或切换时加载背景配置。
   * 通过 lastLoadedBgChatId 缓存避免 onMessagesUpdate 反复加载。
   */
  private maybeLoadChatBackground(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    if (chatId === this.lastLoadedBgChatId) {
      return;
    }
    this.lastLoadedBgChatId = chatId;
    this.loadChatBackground();
  }

  private loadChatBackground(): void {
    if (this.viewModel === null) {
      return;
    }
    const chatId: string | undefined = this.viewModel!.getCurrentChatId();
    if (chatId === undefined || chatId.length === 0) {
      return;
    }
    const service = AppServices.getChatBackgroundService();
    if (service === null) {
      return;
    }
    service.getConfig(chatId)
      .then((cfg: ChatBackgroundConfig): void => {
        this.chatBgConfig = cfg;
      })
      .catch((e: Error): void => {
        Logger.warn(LOG_TAG, 'loadChatBackground failed: ' + e.message);
      });
  }

  /**
   * ChatBackgroundSettingsPage 保存配置后通过 AppStorage.setOrCreate 触发。
   */
  onChatBgConfigVersionChanged(): void {
    this.loadChatBackground();
  }

  private copyMessage(msg: ChatMessage): void {
    if (msg.content.length === 0 || msg.isStreaming === true) {
      return;
    }
    try {
      const pasteData: pasteboard.PasteData = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_PLAIN, msg.content
      );
      const systemPasteboard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      systemPasteboard.setData(pasteData, (err: Error) => {
        if (err) {
          return;
        }
        promptAction.showToast({ message: $r('app.string.chat_copy_success'), duration: 1500 });
      });
    } catch (_e) {
      // 复制失败,静默处理
    }
  }

  /** 处理消息操作菜单点击 */
  private handleMessageAction(action: MessageAction): void {
    if (this.actionSheetMsg === null || this.viewModel === null) {
      return;
    }
    const msg: ChatMessage = this.actionSheetMsg!;
    switch (action) {
      case 'copy':
        this.copyMessage(msg);
        break;
      case 'edit':
        if (msg.senderType === 'narrator') {
          this.openEditNarratorDialog(msg.id, msg.content);
        } else {
          this.openEditUserDialog(msg.id, msg.content);
        }
        break;
      case 'generate_from_user':
        this.generateFromUserMessage(msg.id);
        break;
      case 'regenerate_assistant':
        this.regenerateAssistantMessage(msg.id);
        break;
      case 'continue_from_here':
        this.continueFromAssistant(msg.id);
        break;
      case 'switch_branch':
        // 简化:直接 swipeNext,不弹二级菜单
        this.viewModel!.swipeNext(msg.id);
        break;
      case 'fork_chat':
        this.forkChatFromMessage(msg.id);
        break;
      case 'add_to_memory':
        this.addToMemory(msg.id);
        break;
      default:
        break;
    }
    this.actionSheetMsg = null;
  }

  private continueFromAssistant(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    this.viewModel!.continueFromAssistant(messageId);
  }

  private addToMemory(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.markMessageIncludeInMemory(messageId, true);
  }

  private generateFromUserMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    this.viewModel!.generateFromUserMessage(messageId);
  }

  private regenerateAssistantMessage(messageId: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    this.viewModel!.regenerateAssistantMessage(messageId);
  }

  /**
   * 将气泡不透明度 clamp 到 [0.0, 1.0]。
   * 非有限值(NaN/Infinity)恢复为默认 0.65。
   * Slider 范围为 0~100%,允许完全透明到完全不透明。
   */
  private normalizeChatBubbleOpacity(value: number): number {
    if (!Number.isFinite(value)) {
      return 0.65;
    }
    if (value < 0.0) {
      return 0.0;
    }
    if (value > 1.0) {
      return 1.0;
    }
    return value;
  }

  /** 恢复默认气泡不透明度 */
  private resetChatBubbleOpacity(): void {
    this.chatBubbleOpacity = 0.65;
    this.persistBubbleOpacity(this.chatBubbleOpacity);
  }

  /** 应用字体大小设置(实时更新 ChatTextStyle) */
  private applyFontSize(fontSize: number): void {
    const settings = AppServices.getInstance().chatTextStyleSettings;
    settings.update({ fontSize: fontSize }).then((): void => {
      this.chatTextStyle = settings.get();
    });
  }

  // ===== 字体配色主题 =====

  /**
   * 根据当前 chatTextColorMode 计算传入 ChatRichText 的颜色主题。
   * - AUTO:返回 null(使用默认资源颜色)
   * - LIGHT:返回预设浅色主题
   * - DARK:返回预设深色主题
   * - CUSTOM:使用用户选择的 8 个语义化颜色值构造主题
   *
   * 返回 null 时,ChatRichText 保持原有解析与颜色行为,不做任何覆盖。
   */
  private getCurrentColorTheme(): ChatMarkdownColorTheme | null {
    if (this.chatTextColorMode === ChatTextColorMode.LIGHT) {
      return getLightColorTheme();
    }
    if (this.chatTextColorMode === ChatTextColorMode.DARK) {
      return getDarkColorTheme();
    }
    if (this.chatTextColorMode === ChatTextColorMode.CUSTOM) {
      const theme: ChatMarkdownColorTheme = {
        bodyColor: this.chatBodyTextColor,
        emphasisColor: this.chatEmphasisColor,
        dialogueColor: this.chatDialogueColor,
        actionColor: this.chatActionColor,
        codeColor: this.chatCodeColor,
        linkColor: this.chatLinkColor,
        quoteColor: this.chatQuoteColor,
        userColor: this.chatUserTextColor
      };
      return theme;
    }
    // AUTO 或未知模式
    return null;
  }

  /**
   * 切换字体配色模式。
   * 不修改 chatBubbleOpacity,保持两者完全独立。
   * 持久化到 Preferences,跨页面生命周期保持。
   */
  private setChatTextColorMode(mode: string): void {
    this.chatTextColorMode = mode;
    this.persistTextColor();
  }

  /**
   * 设置自定义颜色项。
   * 仅在 CUSTOM 模式下生效,非法值不提交。
   * 自动转为大写,禁止 Alpha 与 CSS 函数。
   * 持久化到 Preferences,跨页面生命周期保持。
   */
  private setCustomColor(target: CustomColorTarget, color: string): void {
    this.applyCustomColor(target, color);
    this.persistTextColor();
  }

  /**
   * 仅更新内存中的自定义颜色,不持久化。
   * 用于色盘拖动时的实时预览,避免高频写 Preferences 导致卡顿。
   * 关闭色盘时再统一持久化。
   */
  private setCustomColorLive(target: CustomColorTarget, color: string): void {
    this.applyCustomColor(target, color);
  }

  /** 应用自定义颜色值(校验 + 归一化 + 写入对应 @State)。 */
  private applyCustomColor(target: CustomColorTarget, color: string): void {
    const normalized: string | null = normalizeHexColor(color);
    if (normalized === null) {
      return;
    }
    if (target === 'body') {
      this.chatBodyTextColor = normalized;
    } else if (target === 'emphasis') {
      this.chatEmphasisColor = normalized;
    } else if (target === 'dialogue') {
      this.chatDialogueColor = normalized;
    } else if (target === 'action') {
      this.chatActionColor = normalized;
    } else if (target === 'code') {
      this.chatCodeColor = normalized;
    } else if (target === 'link') {
      this.chatLinkColor = normalized;
    } else if (target === 'quote') {
      this.chatQuoteColor = normalized;
    } else if (target === 'user') {
      this.chatUserTextColor = normalized;
    }
  }

  /** 关闭色盘选择器,并持久化当前配色。 */
  private closeColorPicker(): void {
    if (this.colorPickerTarget !== null) {
      this.colorPickerTarget = null;
      this.persistTextColor();
    }
  }

  /**
   * 恢复默认字体配色。
   * 模式恢复 AUTO,4 个颜色值恢复默认。
   * 不修改 chatBubbleOpacity。
   * 持久化恢复后的默认状态,确保下次进入页面也是默认值。
   */
  private resetChatTextColor(): void {
    this.chatTextColorMode = ChatTextColorMode.AUTO;
    this.chatBodyTextColor = DEFAULT_BODY_TEXT_COLOR;
    this.chatEmphasisColor = DEFAULT_EMPHASIS_TEXT_COLOR;
    this.chatDialogueColor = DEFAULT_DIALOGUE_TEXT_COLOR;
    this.chatActionColor = DEFAULT_ACTION_TEXT_COLOR;
    this.chatCodeColor = DEFAULT_CODE_TEXT_COLOR;
    this.chatLinkColor = DEFAULT_LINK_TEXT_COLOR;
    this.chatQuoteColor = DEFAULT_QUOTE_TEXT_COLOR;
    this.chatUserTextColor = DEFAULT_USER_TEXT_COLOR;
    this.persistTextColor();
  }

  /**
   * 全部恢复默认(气泡不透明度 + 字体配色)。
   */
  private resetAllAppearance(): void {
    this.resetChatBubbleOpacity();
    this.resetChatTextColor();
  }

  /** 判断字体配色是否处于默认状态(用于"恢复默认"按钮 enabled 状态) */
  private isChatTextColorDefault(): boolean {
    return this.chatTextColorMode === ChatTextColorMode.AUTO
      && this.chatBodyTextColor === DEFAULT_BODY_TEXT_COLOR
      && this.chatEmphasisColor === DEFAULT_EMPHASIS_TEXT_COLOR
      && this.chatDialogueColor === DEFAULT_DIALOGUE_TEXT_COLOR
      && this.chatActionColor === DEFAULT_ACTION_TEXT_COLOR
      && this.chatCodeColor === DEFAULT_CODE_TEXT_COLOR
      && this.chatLinkColor === DEFAULT_LINK_TEXT_COLOR
      && this.chatQuoteColor === DEFAULT_QUOTE_TEXT_COLOR
      && this.chatUserTextColor === DEFAULT_USER_TEXT_COLOR;
  }

  /** 获取模式按钮显示文本 */
  private getModeLabel(mode: string): string {
    if (mode === ChatTextColorMode.AUTO) {
      return '自动';
    }
    if (mode === ChatTextColorMode.LIGHT) {
      return '浅色';
    }
    if (mode === ChatTextColorMode.DARK) {
      return '深色';
    }
    return '自定义';
  }

  /**
   * 预设色块列表(中性色 + 常用和谐色,取自 Tailwind 色板)。
   * 覆盖黑白灰 + 蓝/青/青绿/绿/黄绿/琥珀/橙/红/粉/紫,便于对白/动作/代码等语义类型快速取色。
   */
  private readonly presetSwatches: string[] = [
    '#FFFFFF', '#E5E7EB', '#9CA3AF', '#4B5563', '#1F2937', '#111827',
    '#3B82F6', '#60A5FA', '#06B6D4', '#14B8A6', '#10B981', '#34D399',
    '#84CC16', '#F59E0B', '#F97316', '#EF4444', '#EC4899', '#8B5CF6', '#A78BFA'
  ];

  /**
   * 判断色块是否为浅色(用于自动选择勾选标记的深/浅颜色)。
   * 基于相对亮度(0.299R + 0.587G + 0.114B),阈值 150。
   */
  private isLightColor(hex: string): boolean {
    let h: string = hex;
    if (h.length > 0 && h.charAt(0) === '#') {
      h = h.substring(1);
    }
    if (h.length !== 6) {
      return false;
    }
    const r: number = parseInt(h.substring(0, 2), 16);
    const g: number = parseInt(h.substring(2, 4), 16);
    const b: number = parseInt(h.substring(4, 6), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return false;
    }
    const luminance: number = 0.299 * r + 0.587 * g + 0.114 * b;
    return luminance > 150;
  }

  /**
   * 重新生成按钮背景色:RGB 保持 surface_2 浅色/深色值,Alpha = chatBubbleOpacity。
   * light: #F0F1F4, dark: #3A3A3A
   */
  private computeRegenerateButtonColor(): string {
    const rgb: string = this.isDarkMode ? '3A3A3A' : 'F0F1F4';
    const clamped: number = Math.max(0, Math.min(255, Math.round(this.chatBubbleOpacity * 255)));
    const hex: string = clamped.toString(16).toUpperCase();
    const alphaHex: string = hex.length === 1 ? '0' + hex : hex;
    return '#' + alphaHex + rgb;
  }

  private openEditUserDialog(messageId: string, originalContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.busy) {
      promptAction.showToast({ message: $r('app.string.chat_branch_create_busy'), duration: 1500 });
      return;
    }
    this.editingMessageId = messageId;
    this.editDialogController = new CustomDialogController({
      builder: HistoricalMessageEditDialog({
        originalContent: originalContent,
        isSubmitting: false,
        onConfirm: (editedContent: string): void => {
          this.confirmEditUserMessage(messageId, editedContent);
        },
        onCancel: (): void => {}
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: false
    });
    this.editDialogController.open();
  }

  private confirmEditUserMessage(messageId: string, editedContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.editUserMessageAndGenerate(messageId, editedContent);
  }

  /**
   * BranchMapPage 切换 Active Branch 后触发。
   */
  onBranchChangeSeqChanged(): void {
    if (this.viewModel === null || this.viewModel!.isDisposed) {
      return;
    }
    if (!this.viewModel!.isSessionReady) {
      return;
    }
    this.viewModel!.reloadAfterBranchChange();
    // 分支切换后,上下文占用需重新统计
    this.refreshBudgetSnapshot();
  }

  private openEditNarratorDialog(messageId: string, originalContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.editingMessageId = messageId;
    this.editDialogController = new CustomDialogController({
      builder: HistoricalMessageEditDialog({
        originalContent: originalContent,
        isSubmitting: false,
        onConfirm: (editedContent: string): void => {
          this.confirmEditNarratorMessage(messageId, editedContent);
        },
        onCancel: (): void => {}
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: false
    });
    this.editDialogController.open();
  }

  private confirmEditNarratorMessage(messageId: string, editedContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.editNarratorMessage(messageId, editedContent);
  }
}
