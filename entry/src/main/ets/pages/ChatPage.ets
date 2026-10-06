/**
 * ChatPage 聊天页面(UI-CHAT-01 视觉重构)
 *
 * 设计依据:
 * - docs/ui_reference/generated/pages/chat_page.md
 * - docs/ui_reference/generated/screens/CHAT_PAGE_009.md
 * - docs/ui_reference/generated/glm_context.md 1.9 / 2.x
 *
 * 视觉结构:
 * - TopNavigation:返回 + 预算指示 / TTS / 显示设置 / 世界书 + 更多(打开 ChatMoreMenuSheet)
 * - MessageArea:Scroll + ForEach,消息气泡由 ChatMessageBubble 渲染
 * - OptionalFloatingControls:回到底部 + 再试一次(条件渲染)
 * - InputArea:TextArea + 发送/停止按钮
 * - ConditionalOverlays:更多菜单 / 消息操作菜单 / 清空确认 / 章节开场白选择
 *   (会话切换统一走首页"对话记录"Tab,页面内不再提供会话列表面板)
 *
 * 业务约束:
 * - 不显示无功能按钮(全屏 / 加号 / 齿轮未实现不显示)
 * - 不显示字数统计(ChatViewModel 无 4000 字限制,不引入虚假限制)
 * - 再试一次仅在 canRegenerate && !isGenerating && messages.length > 0 时显示
 * - 复用 ChatViewModel 所有接口,不修改业务逻辑
 * - 颜色全部使用 $r('app.color.*') 资源,自动适配深色模式
 */

import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { ChatMemoryMode } from '../services/ChatMemoryModeService';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatStatusState, ChatStatusEntry } from '../models/ChatStatusState';
import { AiLorebookChangeSet } from '../models/LorebookAiTypes';
import { AiLorebookMode } from '../services/ai/AiLorebookService';
import { LorebookPanelData } from '../models/LorebookPanel';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatMessageRenderState } from '../models/ChatMessageRenderState';
import { MessageSwipeSummary, MAX_SWIPE_CANDIDATES } from '../models/MessageSwipe';
import { HistoricalMessageEditDialog } from '../components/HistoricalMessageEditDialog';
import { ChatMessageDataSource } from '../components/ChatMessageDataSource';
import { ChatMessageActionSheet, MessageAction } from '../components/ChatMessageActionSheet';
import { ChatMoreMenuSheet } from '../components/ChatMoreMenuSheet';
import { CharacterImageView } from '../components/CharacterImageView';
import { ColorWheelPicker } from '../components/ColorWheelPicker';
import { ChatForkPicker } from '../components/ChatForkPicker';
import { ChatMessageList } from '../components/ChatMessageList';
import { ChatInputArea } from '../components/ChatInputArea';
import { ChatAppearancePanel, CustomColorTarget, ColorPickerRequest } from '../components/ChatAppearancePanel';
import { ChatStatusWorldPanel } from '../components/ChatStatusWorldPanel';
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
  ChatSymbolColorRule,
  createSymbolRule,
  DEFAULT_SYMBOL_TEXT_COLOR,
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
import { Character, resolveCharacterDisplayName } from '../models/Character';
import { extractFrontendSpec, FrontendSpec } from '../bridge/CardFrontendBridge';
import { detectStFrontendHtml, StFrontendFallback } from '../bridge/StFrontendFallback';
import { CardFrontendWeb } from '../components/CardFrontendWeb';
import { ACTIVE_CHAT_VM_KEY, FRONTEND_OPEN_PANEL_SEQ } from './FrontendCardPage';
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
  /** 是否显示删除消息确认 */
  @State showDeleteMessageConfirm: boolean = false;
  /** 待删除的消息 ID */
  @State pendingDeleteMessageId: string = '';
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
  /** v50: 是否显示记忆模式选择对话框 */
  @State showMemoryModeDialog: boolean = false;
  /** v50: 记忆模式草稿(true=自动归档,false=手动总结) */
  @State memoryModeIsAuto: boolean = false;
  /** v50: 注入最近章节数草稿(1-20) */
  @State memoryModeChapterCount: number = 4;
  /** v50: 当前会话记忆模式显示文本(供 ChatMoreMenuSheet 展示) */
  @State memoryModeText: string = '手动总结';
  /** v51: 当前会话待激活章节数(已生成未激活,供记忆模式面板展示) */
  @State memoryPendingChapters: number = 0;
  /** v51: 记忆总结/激活进行中(由 ChatContextMaintenanceService 写入 AppStorage) */
  @StorageProp('memorySummaryRunning') memorySummaryRunning: boolean = false;
  /** v51: 记忆总结最近结果(''|'success'|'failed');@Watch 弹 Toast 后复位以便连续触发 */
  @StorageProp('memorySummaryLastResult') @Watch('onMemorySummaryResultChanged') memorySummaryLastResult: string = '';
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
  /** 上滑面板显示开关:挂载后由 onAppear 置真,驱动 bindSheet 的上滑动画 */
  @State memoryModeSheetShow: boolean = false;
  @State userNameSheetShow: boolean = false;
  @State personaSheetShow: boolean = false;
  @State chapterSheetShow: boolean = false;
  /** 用户身份面板当前分段:0=用户身份,1=性格总结 */
  @State personaSheetTab: number = 0;
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

  /**
   * 自定义符号配色规则(如 【】「」)。
   * 与配色模式无关,所有模式下都生效;持久化到 Preferences。
   */
  @State chatSymbolRules: ChatSymbolColorRule[] = [];
  /**
   * 本地图片库解析映射(归一化名字 → 沙箱 file:// URI)。
   * AI 回复正文里的 ![描述](arkimg:名字) 由此解析成实际文件;由页面加载后透传给消息组件
   * (组件不得直接访问服务/数据库)。
   */
  @State localImages: Record<string, string> = {};

  /** 显示设置面板可见性(轻量卡片,非 Dialog) */
  @State chatAppearancePanelVisible: boolean = false;

  /** 世界书面板可见性 */
  @State statusPanelVisible: boolean = false;

  // ===== 角色状态侧边栏(CHAT-STATUS-1B) =====
  /** 角色状态条目(由 viewModel.onStatusUpdate 实时同步,AI 依据角色卡生成、流式输出即刷新) */
  @State statusEntries: ChatStatusEntry[] = [];
  /** 右侧状态面板是否展开(折叠时仅显示右侧小标签) */
  @State statusPanelExpanded: boolean = false;
  /** 状态面板:AI 生成字段进行中 */
  @State statusGenBusy: boolean = false;

  // ===== 前端页面入口(角色卡扩展 extensions.arktavern.frontend) =====
  /** 当前会话角色卡是否带可渲染的前端页面 */
  @State hasFrontend: boolean = false;
  /** 前端页面 mode(fullscreen=跳独立全屏页;panel=聊天页内浮层面板) */
  @State frontendMode: string = 'fullscreen';
  /** 前端面板是否可见(仅 mode=panel 使用) */
  @State frontendPanelVisible: boolean = false;
  /** 前端面板要渲染的 HTML(打开面板时快照) */
  @State frontendPanelHtml: string = '';
  /** 前端面板标题(缺省用角色名) */
  @State frontendPanelTitle: string = '';
  /** 前端面板建议高度(vp 或百分比,缺省 '50%') */
  @State frontendPanelHeight: string = '50%';
  /** 前端面板是否固定:固定后点击面板以外区域不会自动收起 */
  @State frontendPanelPinned: boolean = false;
  /** 前端面板当前宽度(vp,打开时默认铺满全宽;长按角柄拖动可实时调整) */
  @State frontendPanelCurWidth: number = 360;
  /** 前端面板当前高度(vp,打开时由建议值初始化,长按角柄拖动可实时调整) */
  @State frontendPanelCurHeight: number = 0;
  /** 前端面板纵向位移(vp,拖标题栏上下移动;收起后保留,换卡/离开页面重置) */
  @State frontendPanelOffsetY: number = 0;
  /**
   * 前端面板是否已挂载(ArkWeb 保活):
   * 首次点击「界面」后保持挂载,收起只做位移隐藏,不销毁节点 → 再展开不再白屏重载。
   * 仅在离开本页或切换到别的角色卡时重置(见 resetFrontendPanel)。
   */
  @State frontendPanelMounted: boolean = false;
  /** 面板挂载时的角色卡 id(换卡时用于重置挂载) */
  private frontendMountedCardId: string = '';
  /**
   * 本页实例是否已自动打开过界面页(frontend.autoOpen,纯前端卡"整卡即应用"):
   * 每次进入会话只触发一次;从界面页返回原生聊天不再重复弹出。
   */
  private frontendAutoOpened: boolean = false;
  /** 已持久化的面板宽度(vp,0=无记录) */
  private persistedPanelW: number = 0;
  /** 已持久化的面板高度(vp,0=无记录) */
  private persistedPanelH: number = 0;
  /** 本次展开是否被用户拖动调整过(只有调整过才落盘,避免把卡声明尺寸冻结成用户值) */
  private frontendPanelResized: boolean = false;
  /** 角落拖动起始宽度(vp) */
  private frontendResizeStartW: number = 360;
  /** 角落拖动起始高度(vp) */
  private frontendResizeStartH: number = 0;
  /** 标题栏纵向拖动起始位移(vp) */
  private frontendDragStartY: number = 0;
  /** 窗口宽度缓存(vp,首次布局时取) */
  private cachedScreenW: number = -1;
  /** 窗口高度缓存(vp,首次布局时取) */
  private cachedScreenH: number = -1;

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
  /** 世界书面板展示数据(由 viewModel.lorebookPanelData 同步) */
  @State lorebookPanelData: LorebookPanelData | null = null;
  /** 世界书面板刷新版本号(每次同步递增,强制 ForEach 重建,解决条目更新后不刷新) */
  @State lorebookPanelVersion: number = 0;

  /** 色盘选择器请求(target + 打开时当前色;null 表示关闭。由 ChatAppearancePanel 上抛) */
  @State colorPickerRequest: ColorPickerRequest | null = null;

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

  /** 前端界面面板尺寸持久化 key 前缀(按角色卡:id 后缀,值 "宽x高" vp) */
  private static readonly PREF_KEY_FRONTEND_PANEL_SIZE: string = 'fe_panel_size_';

  /** 前端面板四角缩放热区边长(vp):放大触控目标,避免贴在圆角处难以命中 */
  private static readonly FRONTEND_CORNER_HIT: number = 44;

  /** 折叠态右缘入口标签的细线尺寸(vp):只留一条线,尽量不遮挡画面 */
  private static readonly RAIL_TAB_LINE_W: number = 3;
  private static readonly RAIL_TAB_LINE_H: number = 40;
  /** 「全屏」入口细线高度(比「界面」细线短,视觉区分两种打开方式) */
  private static readonly RAIL_TAB_LINE_H_SM: number = 28;

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

  /**
   * 新消息入场动画门控。
   *
   * 进入页面时消息是一次性批量插入的,若一开始就开着过渡,整个列表会集体闪入;
   * 因此首批(加载)不animate,从第二批起(必然是用户动作触发的新消息)才打开,
   * 之后只有"新插入的那条"播放入场。
   */
  @State messageEntranceEnabled: boolean = false;
  /** 首批(加载)批次是否已消费(纯标记,无需触发重渲染) */
  private messageEntranceInitialBatchDone: boolean = false;

  /**
   * 消息列表是否已"定位到最新消息"。
   *
   * 懒加载列表的高度是逐帧长出来的,直接渲染会先看到最早的消息、随后才跳到最新。
   * 因此进入会话 / 切换会话时先显示加载动画,让列表在不可见状态下完成追底定位,
   * 落定后再一次性显示最新消息(见 autoScrollToBottom / beginListPositioning)。
   */
  @State chatListPositioned: boolean = false;
  /** 追底锁:定位期间持续把视图钉到底部,直到真正到底或超时 */
  private bottomLockActive: boolean = false;
  /** 追底重试计数(安全上限,防止极端情况下不收敛) */
  private bottomLockRetries: number = 0;
  /** 定位兜底定时器(超时后强制显示,避免列表永久隐藏) */
  private positionFallbackTimer: number = -1;

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
      // 首条消息 id 变化 = 整列表被替换(进入会话 / 切换会话 / 新建章节),需要重新定位到底部
      const prevFirstId: string = this.messages.length > 0 ? this.messages[0].id : '';
      // 同步业务数据 + 同步稳定 RenderState 列表
      this.messages = msgs;
      this.syncRenderStates(msgs);
      this.maybeLoadChatBackground();
      this.updateListPositioning(msgs, prevFirstId);
      // 入场动画门控:首批(加载)不animate,之后的批次才开(见字段注释)
      if (msgs.length > 0) {
        if (!this.messageEntranceInitialBatchDone) {
          this.messageEntranceInitialBatchDone = true;
        } else if (!this.messageEntranceEnabled) {
          this.messageEntranceEnabled = true;
        }
      }
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
    // 角色状态胶囊栏:AI 流式输出状态块时实时同步(初始/切会话/字段增删改均会触发)
    vm.onStatusUpdate = (state: ChatStatusState): void => {
      this.statusEntries = state.entries.slice();
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
          .then((): void => {
            this.refreshUserNameDisplay();
            this.refreshPersonaDisplay();
            this.refreshHasFrontend();
            this.refreshLocalImages();
          })
          .catch((): void => {});
      } else {
        vm.initialize().then((): Promise<void> => vm.selectSession(pendingChatId))
          .then((): void => {
            this.refreshUserNameDisplay();
            this.refreshPersonaDisplay();
            this.refreshHasFrontend();
            this.refreshLocalImages();
          })
          .catch((): void => {});
      }
    } else if (pendingCharacterId.length > 0) {
      AppStorage.set<string>('pendingCharacterId', '');
      this.loadCharacterAvatar(pendingCharacterId);
      // 角色卡"新建对话"入口:forceNew=true 跳过 openLatestSession,直接创建新会话
      vm.initialize(pendingCharacterId, true)
        .then((): void => {
          this.refreshUserNameDisplay();
          this.refreshPersonaDisplay();
          this.refreshHasFrontend();
          this.refreshLocalImages();
        })
        .catch((): void => {});
    } else {
      // 打开最近会话:等待会话加载完成后刷新前端页面入口状态
      vm.initialize().then((): void => {
        this.refreshHasFrontend();
        this.refreshLocalImages();
      }).catch((): void => {});
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
   *     "quote": "#RRGGBB", "user": "#RRGGBB",
   *     "symbols": [ { "open": "【", "close": "】", "color": "#RRGGBB" } ] }
   *
   * 读取失败或未初始化时静默使用默认值。
   * 非法字段回退为对应默认值,确保渲染安全。
   * symbols 为可选字段(旧版本数据缺失时回退为空列表)。
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
          this.chatSymbolRules = this.readSymbolRules(obj);
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
   * 从持久化 JSON 对象读取自定义符号规则列表。
   * 缺失/非法(非数组、单字符不满足、颜色非法)的条目一律跳过,保证渲染安全。
   */
  private readSymbolRules(obj: Record<string, Object>): ChatSymbolColorRule[] {
    const raw: Object | undefined = obj['symbols'];
    if (raw === undefined || !Array.isArray(raw)) {
      return [];
    }
    const items: Object[] = raw as Object[];
    const result: ChatSymbolColorRule[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: Record<string, Object> = items[i] as Record<string, Object>;
      const open: Object | undefined = item['open'];
      const close: Object | undefined = item['close'];
      const color: string = this.readColorField(item, 'color', '');
      if (typeof open === 'string' && typeof close === 'string'
        && open.length === 1 && close.length === 1 && color.length > 0) {
        result.push(createSymbolRule(open, close, color));
      }
    }
    return result;
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
      const symbolItems: Record<string, string>[] = [];
      for (let i = 0; i < this.chatSymbolRules.length; i++) {
        const rule: ChatSymbolColorRule = this.chatSymbolRules[i];
        const item: Record<string, string> = {
          'open': rule.open,
          'close': rule.close,
          'color': rule.color
        };
        symbolItems.push(item);
      }
      const obj: Record<string, Object> = {
        'mode': this.chatTextColorMode,
        'body': this.chatBodyTextColor,
        'emphasis': this.chatEmphasisColor,
        'dialogue': this.chatDialogueColor,
        'action': this.chatActionColor,
        'code': this.chatCodeColor,
        'link': this.chatLinkColor,
        'quote': this.chatQuoteColor,
        'user': this.chatUserTextColor,
        'symbols': symbolItems
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
    this.clearPositionFallback();
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
    // 关闭角色状态侧边栏并清空条目
    this.statusPanelExpanded = false;
    this.statusEntries = [];
    // 释放前端界面面板(卸下保活的 ArkWeb)
    this.resetFrontendPanel();
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
    // FrontendCardPage「浮窗」按钮的切换请求:返回聊天页并展开前端面板
    const openPanelSeq: number = AppStorage.get<number>(FRONTEND_OPEN_PANEL_SEQ) ?? 0;
    if (openPanelSeq > 0 && this.hasFrontend) {
      AppStorage.set<number>(FRONTEND_OPEN_PANEL_SEQ, 0);
      this.openFrontendCard('panel');
    }
    this.refreshBudgetSnapshot();
    this.loadTtsSettings();
    // 从图片库页返回后同步最新映射
    this.refreshLocalImages();
  }

  /**
   * 加载本地图片库解析映射(归一化名字 → 沙箱 file:// URI)。
   *
   * 架构口径:组件(components/)不得访问服务/数据库,故解析在页面层完成,
   * 结果经 @Prop 逐层透传到 ChatRichText。
   * 失败不阻塞聊天(仅记日志),未命中名字的图片按「未找到图片」降级展示。
   */
  private refreshLocalImages(): void {
    const rawId: string = this.character !== null ? this.character!.id : '';
    const characterId: string | null = rawId.length > 0 ? rawId : null;
    AppServices.whenReady()
      .then((): Promise<Record<string, string>> => {
        return AppServices.getLocalImageService().buildResolutionMap(characterId);
      })
      .then((map: Record<string, string>): void => {
        this.localImages = map;
      })
      .catch((e: Error): void => {
        Logger.warn(LOG_TAG, 'refreshLocalImages failed: ' + e.message);
      });
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
              ChatMessageList({
                effectiveTheme: this.effectiveTheme,
                isDarkMode: this.isDarkMode,
                bubbleOpacity: this.chatBubbleOpacity,
                colorTheme: this.getCurrentColorTheme(),
                symbolRules: this.chatSymbolRules,
                localImages: this.localImages,
                chatTextStyle: this.chatTextStyle,
                characterAvatarUri: this.character !== null ? this.character!.avatarUri : '',
                characterName: this.viewModel !== null ? this.viewModel!.characterName : '',
                characterId: this.character !== null ? this.character!.id : '',
                statusBarHeight: this.statusBarHeight,
                navigationBarHeight: this.navigationBarHeight,
                keyboardHeight: this.keyboardHeight,
                impersonatePanelActive: this.viewModel !== null
                  && (this.viewModel!.impersonateCandidates.length > 0
                    || this.viewModel!.isImpersonateGenerating),
                ttsEnabled: this.ttsService.readMode !== TtsReadMode.Off,
                isGenerating: this.viewModel !== null && this.viewModel!.isGenerating,
                swipeControlsAvailable: this.viewModel !== null,
                entranceAnimationEnabled: this.messageEntranceEnabled,
                dataSource: this.dataSource,
                scroller: this.scroller,
                onRequestAutoScroll: (): void => {
                  this.autoScrollToBottom();
                },
                onUserScrolledToBottom: (): void => {
                  if (this.viewModel !== null) {
                    this.viewModel!.userScrolledUp = false;
                  }
                },
                onInteractiveAction: (text: string): void => {
                  this.handleInteractiveAction(text);
                },
                onLongPressMessage: (message: ChatMessage): void => {
                  this.actionSheetMsg = message;
                  this.showActionSheet = true;
                },
                onTtsPlayRequest: (content: string): void => {
                  this.handleTtsPlay(content);
                },
                canRegenerate: (messageId: string): boolean => {
                  return this.viewModel !== null
                    && this.viewModel!.canRegenerateAssistantMessage(messageId);
                },
                onRegenerate: (messageId: string): void => {
                  this.regenerateAssistantMessage(messageId);
                },
                getSwipeActiveIndex: (messageId: string): number => {
                  return this.getSwipeActiveIndex(messageId);
                },
                getCandidateCount: (messageId: string): number => {
                  return this.getCandidateCount(messageId);
                },
                canOperateSwipe: (messageId: string): boolean => {
                  return this.viewModel !== null && this.viewModel!.canOperateSwipe(messageId);
                },
                onSwipePrevious: (messageId: string): void => {
                  if (this.viewModel !== null) {
                    this.viewModel!.swipePrevious(messageId);
                  }
                },
                onSwipeNext: (messageId: string): void => {
                  if (this.viewModel !== null) {
                    this.viewModel!.swipeNext(messageId);
                  }
                },
                onSwipeStop: (): void => {
                  if (this.viewModel !== null) {
                    this.viewModel!.stop();
                  }
                }
              })
                // 定位到底部之前先不显示列表(仍需挂载并完成布局,才能量出真实高度),
                // 由下方加载动画占位;落定后一次性显示最新消息,避免看到"从最开始翻到最新"
                .opacity(this.chatListPositioned ? 1 : 0)

              if (!this.chatListPositioned) {
                this.loadingView()
              }
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

          ChatInputArea({
            effectiveTheme: this.effectiveTheme,
            inputText: this.viewModel !== null ? this.viewModel!.inputText : '',
            canSend: this.canSend(),
            canStop: this.viewModel !== null && this.viewModel!.canStop,
            showAiActions: this.viewModel !== null
              && !this.viewModel!.busy && !this.viewModel!.isGenerating,
            isSendButtonOnLeft: this.isSendButtonOnLeft(),
            impersonateCandidates: this.viewModel !== null
              ? this.viewModel!.impersonateCandidates
              : [],
            isImpersonateGenerating: this.viewModel !== null
              && this.viewModel!.isImpersonateGenerating,
            narratorModeActive: this.narratorModeActive,
            onInputChange: (value: string): void => {
              if (this.viewModel !== null) {
                this.viewModel!.updateInput(value);
              }
            },
            onImpersonate: (): void => {
              if (this.viewModel !== null && !this.viewModel!.busy) {
                this.viewModel!.impersonate();
              }
            },
            onAutoContinue: (): void => {
              if (this.viewModel !== null && !this.viewModel!.busy) {
                this.viewModel!.autoContinue();
              }
            },
            onSelectImpersonateCandidate: (index: number): void => {
              if (this.viewModel !== null) {
                this.viewModel!.selectImpersonateCandidate(index);
              }
            },
            onDismissImpersonateCandidates: (): void => {
              if (this.viewModel !== null) {
                this.viewModel!.dismissImpersonateCandidates();
              }
            },
            onSendRequest: (): void => {
              this.handleInputSend();
            },
            onSendNarratorOnly: (): void => {
              if (this.canSend() && this.viewModel !== null) {
                this.viewModel!.sendNarratorOnly();
                this.narratorModeActive = false;
              }
            },
            onSendNarrator: (): void => {
              if (this.isBudgetExceeded()) {
                this.notifyBudgetBlocked();
                return;
              }
              if (this.canSend() && this.viewModel !== null) {
                this.viewModel!.sendNarrator();
                this.narratorModeActive = false;
              }
            },
            onStop: (): void => {
              if (this.viewModel !== null) {
                this.viewModel!.stop();
              }
            },
            onKeyPreImeEvent: (event: KeyEvent): boolean => {
              return this.handleInputKeyPreIme(event);
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        // OFFSET 模式下输入栏未加 expandSafeArea(KEYBOARD),被系统上抬到键盘上方;
        // bottom 仅控制 inputArea 与 Column 底部的间距:
        // 键盘弹起时 12(系统已上抬,只需小间距);未弹起时 navigationBarHeight + 12(避让手势条)
        .padding({ left: 12, right: 12, bottom: this.keyboardHeight > 0 ? 40 : this.navigationBarHeight + 40 })
        .hitTestBehavior(HitTestMode.Transparent)

        // ===== 右上角入口标签列(状态 / 界面,流式堆叠;对应面板展开时该标签移出) =====
        this.rightRail()

        // ===== 角色状态浮层面板(展开态;点面板以外收起) =====
        if (this.statusPanelExpanded) {
          this.statusPanelLayer()
        }

        // ===== 前端界面浮层面板(mode=panel,聊天页内展开,对话仍可继续) =====
        // 挂载后不随收起卸载(ArkWeb 保活,再展开无白屏重载);隐藏由面板自身位移+透明实现
        if (this.frontendPanelMounted && this.viewModel !== null) {
          this.frontendPanel()
        }

        // ===== 弹窗层(覆盖在最上层) =====

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
            onEditMemoryMode: (): void => {
              this.openMemoryModeDialog();
            },
            memoryModeText: this.memoryModeText,
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
            canEditAssistant: !this.viewModel!.busy,
            canGenerateFromUser: this.viewModel!.canGenerateFromUserMessage(this.actionSheetMsg!.id),
            canRegenerate: this.viewModel!.canRegenerateAssistantMessage(this.actionSheetMsg!.id),
            canContinue: this.viewModel!.canContinueFromAssistant(this.actionSheetMsg!.id),
            candidateCount: this.getCandidateCount(this.actionSheetMsg!.id),
            canForkChat: !this.viewModel!.busy && this.viewModel!.isSessionReady,
            canDelete: this.viewModel!.canDeleteMessage(this.actionSheetMsg!.id),
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

        // 删除消息确认弹窗
        if (this.showDeleteMessageConfirm) {
          this.deleteMessageConfirmDialog()
        }

        // v9: 本对话称呼(上滑面板)
        if (this.showUserNameOverrideDialog) {
          Column()
            .width('100%')
            .height(0)
            .backgroundColor(Color.Transparent)
            .bindSheet(this.userNameSheetShow, this.userNameSheetContent(), {
              height: SheetSize.FIT_CONTENT,
              dragBar: false,
              showClose: false,
              backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
              onDisappear: (): void => {
                this.userNameSheetShow = false;
                this.showUserNameOverrideDialog = false;
              }
            })
            .onAppear(() => {
              this.userNameSheetShow = true;
            })
        }

        // v50: 记忆模式选择(上滑面板)
        if (this.showMemoryModeDialog) {
          Column()
            .width('100%')
            .height(0)
            .backgroundColor(Color.Transparent)
            .bindSheet(this.memoryModeSheetShow, this.memoryModeSheetContent(), {
              height: SheetSize.FIT_CONTENT,
              dragBar: false,
              showClose: false,
              backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
              onDisappear: (): void => {
                this.memoryModeSheetShow = false;
                this.showMemoryModeDialog = false;
              }
            })
            .onAppear(() => {
              this.memoryModeSheetShow = true;
            })
        }

        // Persona 选择(上滑面板)
        if (this.showPersonaPicker) {
          Column()
            .width('100%')
            .height(0)
            .backgroundColor(Color.Transparent)
            .bindSheet(this.personaSheetShow, this.personaSheetContent(), {
              height: SheetSize.FIT_CONTENT,
              dragBar: false,
              showClose: false,
              backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
              onDisappear: (): void => {
                this.personaSheetShow = false;
                this.showPersonaPicker = false;
              }
            })
            .onAppear(() => {
              this.personaSheetShow = true;
            })
        }

        // v42: 新建章节开场白选择(上滑面板)
        if (this.showChapterGreetingPicker) {
          Column()
            .width('100%')
            .height(0)
            .backgroundColor(Color.Transparent)
            .bindSheet(this.chapterSheetShow, this.chapterSheetContent(), {
              height: SheetSize.FIT_CONTENT,
              dragBar: false,
              showClose: false,
              backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
              onDisappear: (): void => {
                this.chapterSheetShow = false;
                this.showChapterGreetingPicker = false;
                this.chapterGreetingPool = [];
              }
            })
            .onAppear(() => {
              this.chapterSheetShow = true;
            })
        }

        // Fork 模式选择弹窗
        if (this.showForkModePicker) {
          ChatForkPicker({
            effectiveTheme: this.effectiveTheme,
            onPick: (fullHistory: boolean): void => {
              this.showForkModePicker = false;
              void this.executeForkChat(this.forkTargetMessageId, fullHistory);
            },
            onCancel: (): void => {
              this.showForkModePicker = false;
            }
          })
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
          this.refreshMemoryModeDisplay();
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

  // ===== 前端页面入口(角色卡扩展 extensions.arktavern.frontend) =====

  /** 刷新"是否带前端页面"标识,并缓存其 mode/HTML/尺寸(会话角色加载完成后调用) */
  private refreshHasFrontend(): void {
    // 角色卡可能已变化:先释放旧面板(OFF 挂载),避免拿着上一张卡的 HTML 保活
    this.resetFrontendPanel();
    if (this.viewModel === null) {
      this.hasFrontend = false;
      return;
    }
    const character: Character | null = this.viewModel!.currentCharacter;
    if (character === null) {
      this.hasFrontend = false;
      return;
    }
    const spec: FrontendSpec = extractFrontendSpec(character.extensions);
    let html: string = spec.html;
    let mode: string = spec.mode;
    if (html.trim().length === 0) {
      // 原版 ST 卡散落前端回退检测(开场白/备用开场白/美化正则里的界面 HTML):
      // 无 arktavern.frontend 声明但有 ST 前端资产时,运行时兜底接入(不写卡数据),默认 panel 展示
      const fallback: StFrontendFallback | null = detectStFrontendHtml(character);
      if (fallback !== null) {
        html = fallback.html;
        mode = 'panel';
      }
    }
    this.hasFrontend = html.trim().length > 0;
    this.frontendMode = mode;
    this.frontendPanelHeight = spec.sizeHeight.length > 0 ? spec.sizeHeight : '50%';
    this.frontendPanelTitle = spec.title;
    // 读取该卡上次调整过的面板尺寸(异步,取到后作为下次展开的初始值)
    this.loadPersistedPanelSize(character.id);
    // 纯前端卡(autoOpen + fullscreen):进入会话自动打开界面页,整卡即应用;
    // 每次会话进入只触发一次,从界面页返回后停在原生聊天。
    if (spec.autoOpen && spec.mode === 'fullscreen' && this.hasFrontend && !this.frontendAutoOpened) {
      this.frontendAutoOpened = true;
      this.openFrontendCard();
    }
  }

  /**
   * 解析前端页面 HTML:优先 arktavern.frontend 声明,无声明时回退检测
   * ST 卡散落前端(开场白/备用开场白/美化正则,见 bridge/StFrontendFallback.ets)。
   */
  private resolveFrontendHtml(character: Character): string {
    const spec: FrontendSpec = extractFrontendSpec(character.extensions);
    if (spec.html.trim().length > 0) {
      return spec.html;
    }
    const fallback: StFrontendFallback | null = detectStFrontendHtml(character);
    return fallback !== null ? fallback.html : '';
  }

  /** 释放前端面板(收起并卸下 ArkWeb 挂载),用于换卡/离开会话 */
  private resetFrontendPanel(): void {
    this.frontendPanelVisible = false;
    this.frontendPanelMounted = false;
    this.frontendPanelHtml = '';
    this.frontendMountedCardId = '';
    this.frontendPanelPinned = false;
    this.frontendPanelResized = false;
    this.frontendPanelOffsetY = 0;
    this.persistedPanelW = 0;
    this.persistedPanelH = 0;
  }

  /**
   * 打开前端页面:
   * - mode=panel → 在聊天页内展开浮层面板(对话仍可继续)
   * - mode=fullscreen → 推入独立全屏页 FrontendCardPage
   * @param modeOverride 显示方式覆盖('panel'/'fullscreen');缺省用角色卡声明的 frontendMode。
   *   悬浮导航「全屏」细线与面板「全屏」按钮传 'fullscreen',全屏页「浮窗」按钮经
   *   AppStorage 标志回来后传 'panel'——显示方式由用户在 App 内切换,不受卡声明限制。
   */
  private openFrontendCard(modeOverride?: string): void {
    if (this.viewModel === null) {
      return;
    }
    const mode: string = modeOverride !== undefined ? modeOverride : this.frontendMode;
    if (mode === 'panel') {
      const character: Character | null = this.viewModel!.currentCharacter;
      if (character === null) {
        return;
      }
      if (this.frontendPanelMounted && this.frontendMountedCardId !== character.id) {
        // 换了角色卡:卸旧再挂新
        this.resetFrontendPanel();
      }
      if (!this.frontendPanelMounted) {
        this.frontendPanelHtml = this.resolveFrontendHtml(character);
        this.frontendMountedCardId = character.id;
        this.frontendPanelMounted = true;
      }
      // 尺寸初始化:宽度默认铺满全宽(仅当用户上次长按角柄调整过才沿用其值)
      this.frontendPanelCurWidth = this.persistedPanelW > 0
        ? this.clampPanelWidth(this.persistedPanelW)
        : this.screenWidthVp();
      this.frontendPanelCurHeight = this.clampPanelHeight(
        this.persistedPanelH > 0 ? this.persistedPanelH : this.resolvePanelHeightVp());
      this.frontendPanelPinned = false;
      animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
        this.frontendPanelVisible = true;
      });
      return;
    }
    AppStorage.setOrCreate<ChatViewModel>(ACTIVE_CHAT_VM_KEY, this.viewModel!);
    router.pushUrl({ url: 'pages/FrontendCardPage' });
  }

  /**
   * 关闭前端浮层面板(收起,回到聊天视图)。
   * 保活:只做位移隐藏,不卸载 ArkWeb、不清 HTML,再展开即刻可见。
   */
  private closeFrontendPanel(): void {
    if (this.frontendPanelResized) {
      this.persistPanelSize();
    }
    this.frontendPanelPinned = false;
    animateTo({ duration: 180, curve: Curve.EaseIn }, (): void => {
      this.frontendPanelVisible = false;
    });
  }

  /** 面板隐藏时的横向位移(vp):足以把面板整体移出右边界(不改变布局尺寸) */
  private panelHideOffset(): number {
    // 面板默认铺满且只做纵向移动,横向位移固定为"整体宽度 + 余量"即可完全移出屏幕
    return this.frontendPanelCurWidth + 120;
  }

  /** 读取该角色卡上次调整过的面板尺寸(vp);无记录/解析失败则保持 0 */
  private loadPersistedPanelSize(cardId: string): void {
    if (cardId.length === 0) {
      return;
    }
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.getString(ChatPage.PREF_KEY_FRONTEND_PANEL_SIZE + cardId, '')
        .then((value: string): void => {
          const m: RegExpMatchArray | null = value.match(/^(\d{1,4})x(\d{1,4})$/);
          if (m === null) {
            return;
          }
          const w: number = Number(m[1]);
          const h: number = Number(m[2]);
          if (w > 0 && h > 0) {
            this.persistedPanelW = w;
            this.persistedPanelH = h;
          }
        })
        .catch((_e: Object): void => {
          // 读取失败静默使用卡声明值
        });
    } catch (_e) {
      // AppServices 未初始化时静默
    }
  }

  /** 持久化当前面板尺寸(按角色卡);写入失败静默忽略 */
  private persistPanelSize(): void {
    if (!this.frontendPanelMounted || this.frontendMountedCardId.length === 0) {
      return;
    }
    if (this.frontendPanelCurWidth <= 0 || this.frontendPanelCurHeight <= 0) {
      return;
    }
    const value: string =
      Math.round(this.frontendPanelCurWidth).toString() + 'x' + Math.round(this.frontendPanelCurHeight).toString();
    this.persistedPanelW = Math.round(this.frontendPanelCurWidth);
    this.persistedPanelH = Math.round(this.frontendPanelCurHeight);
    try {
      const prefs = AppServices.getAppPreferences();
      if (!prefs.isInitialized()) {
        return;
      }
      prefs.putString(ChatPage.PREF_KEY_FRONTEND_PANEL_SIZE + this.frontendMountedCardId, value)
        .catch((_e: Object): void => {
          // 写入失败不影响交互
        });
    } catch (_e) {
      // AppServices 未初始化时静默
    }
  }

  /** 解析面板高度为 vp:百分比按窗口高度折算;数字原样;非法/空回退 50% */
  private resolvePanelHeightVp(): number {
    const h: string = this.frontendPanelHeight;
    const fallback: number = Math.round(this.screenHeightVp() * 0.5);
    if (h.length === 0) {
      return fallback;
    }
    if (h.indexOf('%') >= 0) {
      const pct: number = Number(h.replace('%', ''));
      if (Number.isNaN(pct)) {
        return fallback;
      }
      return Math.max(180, Math.round(this.screenHeightVp() * (pct / 100)));
    }
    const n: number = Number(h);
    return Number.isNaN(n) ? fallback : Math.max(180, n);
  }

  /** 缓存并返回窗口宽度(vp,失败回退 480) */
  private screenWidthVp(): number {
    if (this.cachedScreenW > 0) {
      return this.cachedScreenW;
    }
    this.cacheScreenSize();
    return this.cachedScreenW > 0 ? this.cachedScreenW : 480;
  }

  /** 缓存并返回窗口高度(vp,失败回退 800) */
  private screenHeightVp(): number {
    if (this.cachedScreenH > 0) {
      return this.cachedScreenH;
    }
    this.cacheScreenSize();
    return this.cachedScreenH > 0 ? this.cachedScreenH : 800;
  }

  /** 取窗口尺寸(px)换算 vp 并缓存 */
  private cacheScreenSize(): void {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.cachedScreenW = Math.round(px2vp(d.width));
      this.cachedScreenH = Math.round(px2vp(d.height));
    } catch (e) {
      this.cachedScreenW = 480;
      this.cachedScreenH = 800;
    }
  }

  /** 面板宽度限幅:最小 240vp,最大不超过窗口宽度(默认铺满全宽) */
  private clampPanelWidth(w: number): number {
    const max: number = this.screenWidthVp();
    return Math.min(Math.max(w, 240), max);
  }

  /** 面板高度限幅:最小 180vp,最大不超出窗口底部留白 */
  private clampPanelHeight(h: number): number {
    const nav: number = (AppStorage.get<number>('navigationBarHeight') ?? 0) as number;
    const max: number = this.screenHeightVp() - this.statusBarHeight - 54 - nav - 24;
    return Math.min(Math.max(h, 180), max);
  }

  /** 拖动位移限幅:不高于展开默认位置,底部不越过手势条 */
  private clampPanelOffsetY(y: number): number {
    const nav: number = (AppStorage.get<number>('navigationBarHeight') ?? 0) as number;
    const maxTop: number = this.screenHeightVp() - nav - 8;
    const max: number = maxTop - this.statusBarHeight - 54 - this.frontendPanelCurHeight;
    return Math.min(Math.max(y, 0), Math.max(0, max));
  }

  /** 角柄横向位置:0/1=贴左缘,2/3=贴右缘 */
  private resizeHotspotX(corner: number): number {
    const right: boolean = corner === 1 || corner === 3;
    return right
      ? Math.max(0, this.frontendPanelCurWidth - ChatPage.FRONTEND_CORNER_HIT)
      : 0;
  }

  /** 角柄纵向位置:0/1=贴上缘,2/3=贴下缘 */
  private resizeHotspotY(corner: number): number {
    const bottom: boolean = corner === 2 || corner === 3;
    return bottom
      ? Math.max(0, this.frontendPanelCurHeight - ChatPage.FRONTEND_CORNER_HIT)
      : 0;
  }

  /** 角标括号朝向:0=左上 1=右上 2=左下 3=右下(基准形为左上 L) */
  private resizeBracketAngle(corner: number): number {
    if (corner === 1) {
      return 90;
    }
    if (corner === 2) {
      return 270;
    }
    return corner === 3 ? 180 : 0;
  }

  /**
   * 折叠态:「界面」入口(贴屏右缘的一条细线,中性色;由 rightRail 统一排布与定位)。
   * 视觉仅 3vp 宽,避免遮挡画面;点击热区经 responseRegion 扩到约 31x56vp,保证好点。
   */
  @Builder
  frontendFloatingTab() {
    Column()
      .width(ChatPage.RAIL_TAB_LINE_W)
      .height(ChatPage.RAIL_TAB_LINE_H)
      .borderRadius({ topLeft: 2, topRight: 0, bottomLeft: 2, bottomRight: 0 })
      .backgroundColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      .shadow({ radius: 4, color: 'rgba(0,0,0,0.18)' })
      // 细线本体只有 3vp 宽,把点击热区向左扩到约 31x56vp(不改变视觉),避免难点
      .responseRegion({ x: -27, y: -8, width: 31, height: 56 })
      .transition(
        TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: 40 }))
          .animation({ duration: 200, curve: Curve.EaseOut })
      )
      .onClick(() => {
        this.openFrontendCard();
      })
  }

  /** 前端界面浮层面板(仅 mode=panel):右上展开 ArkWeb,对话仍可在下方继续 */
  @Builder
  frontendPanel() {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 透明捕获层:点面板以外任意位置即收起(固定后不收起);收起态不存在,不拦截点击
      if (this.frontendPanelVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            if (!this.frontendPanelPinned) {
              this.closeFrontendPanel();
            }
          })
      }

      // 面板:标题栏 + ArkWeb 内容(默认左右铺满、四角长按后缩放,标题栏可上下拖动移动)
      // 保活:收起只做位移+透明(布局尺寸不变,ArkWeb 节点不重建),再展开即刻显示,无白屏
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          Row() {
            Text(this.frontendPanelTitle.length > 0
              ? this.frontendPanelTitle
              : (this.character !== null && this.character!.name.length > 0 ? this.character!.name : '界面'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            // 全屏切换:收起面板并以 fullscreen 模式打开同一份前端页面(悬浮导航窗切换的另一入口)
            Text('全屏')
              .fontSize(12)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .height(26)
              .padding({ left: 10, right: 10 })
              .borderRadius(13)
              .textAlign(TextAlign.Center)
              .margin({ right: 6 })
              .onClick(() => {
                this.closeFrontendPanel();
                this.openFrontendCard('fullscreen');
              })

            // 固定开关:与「✕」同规格的热区,不固定时也保留底色,避免按钮时有时无
            Text(this.frontendPanelPinned ? '已固定' : '固定')
              .fontSize(12)
              .fontWeight(this.frontendPanelPinned ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.frontendPanelPinned
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .height(26)
              .padding({ left: 10, right: 10 })
              .borderRadius(13)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.frontendPanelPinned = !this.frontendPanelPinned;
              })

            Text('✕')
              .fontSize(12)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .width(26)
              .height(26)
              .borderRadius(13)
              .textAlign(TextAlign.Center)
              .margin({ left: 6 })
              .onClick(() => {
                this.closeFrontendPanel();
              })
          }
          .width('100%')
          .height(44)
          // 左右留出角柄热区宽度,避免标题栏按钮被角落热区遮挡
          .padding({ left: ChatPage.FRONTEND_CORNER_HIT, right: ChatPage.FRONTEND_CORNER_HIT })
          // 拖动标题栏上下移动面板(左右铺满,仅纵向;下移受限幅保护,不会跑出屏幕)
          .gesture(
            PanGesture({ direction: PanDirection.Vertical })
              .onActionStart(() => {
                this.frontendDragStartY = this.frontendPanelOffsetY;
              })
              .onActionUpdate((event: GestureEvent | undefined) => {
                if (event === undefined) {
                  return;
                }
                this.frontendPanelOffsetY =
                  this.clampPanelOffsetY(this.frontendDragStartY + event.offsetY);
              })
          )

          // 标题栏与网页内容之间的分隔,避免标题和页面黏在一起
          Divider()
            .color(ThemePalette.dividerColor(this.effectiveTheme))

          CardFrontendWeb({
            host: this.viewModel,
            html: this.frontendPanelHtml,
            active: this.frontendPanelVisible,
            onClose: (): void => {
              this.closeFrontendPanel();
            }
          })
            .width('100%')
            .layoutWeight(1)
        }
        .width('100%')
        .height('100%')

        // 四个角缩放热区(44vp):平时不响应,长按后拖动可自由改宽高
        this.frontendResizeHotspot(0)
        this.frontendResizeHotspot(1)
        this.frontendResizeHotspot(2)
        this.frontendResizeHotspot(3)
      }
      .width(this.frontendPanelCurWidth)
      .height(this.frontendPanelCurHeight)
      .margin({ top: this.statusBarHeight + 54 })
      .borderRadius({ topLeft: 18, topRight: 0, bottomLeft: 18, bottomRight: 0 })
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .clip(true)
      .shadow({ radius: 10, color: 'rgba(0,0,0,0.18)' })
      .translate({
        x: this.frontendPanelVisible ? 0 : this.panelHideOffset(),
        y: this.frontendPanelOffsetY
      })
      .opacity(this.frontendPanelVisible ? 1 : 0)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(this.frontendPanelVisible ? HitTestMode.Transparent : HitTestMode.None)
  }

  /**
   * 角部缩放热区(corner:0=左上 1=右上 2=左下 3=右下)。
   * 面板默认左右铺满、仅允许上下移动,缩放能力收进长按:长按约 350ms 后不松手拖动即可自由改宽高。
   * 四角行为一致(锚定右缘:向左拖加宽,向下拖加高);热区放大到 44vp,避免角落难以命中。
   */
  @Builder
  frontendResizeHotspot(corner: number) {
    Column() {
      // 角标视觉提示:L 形括号(朝向对应角)
      Stack({ alignContent: Alignment.TopStart }) {
        Text('')
          .width(8)
          .height(1.5)
          .position({ x: 0, y: 0 })
          .backgroundColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .opacity(0.55)
        Text('')
          .width(1.5)
          .height(8)
          .position({ x: 0, y: 0 })
          .backgroundColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .opacity(0.55)
      }
      .width(12)
      .height(12)
      .rotate({ angle: this.resizeBracketAngle(corner) })
    }
    .width(ChatPage.FRONTEND_CORNER_HIT)
    .height(ChatPage.FRONTEND_CORNER_HIT)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .position({ x: this.resizeHotspotX(corner), y: this.resizeHotspotY(corner) })
    .hitTestBehavior(HitTestMode.Block)
    // 必须"长按激活 → 继续按住拖动":避免面板铺满后误触角落就改变尺寸
    .gesture(
      GestureGroup(GestureMode.Sequence,
        LongPressGesture({ repeat: false, duration: 350 }),
        PanGesture({ direction: PanDirection.All })
          .onActionStart(() => {
            this.frontendResizeStartW = this.frontendPanelCurWidth;
            this.frontendResizeStartH = this.frontendPanelCurHeight;
          })
          .onActionUpdate((event: GestureEvent | undefined) => {
            if (event === undefined) {
              return;
            }
            // 面板锚定右上角:向右拖(offsetX>0)收窄宽度,向左拖加宽;向下拖加高,向上拖变矮
            this.frontendPanelCurWidth =
              this.clampPanelWidth(this.frontendResizeStartW - event.offsetX);
            this.frontendPanelCurHeight =
              this.clampPanelHeight(this.frontendResizeStartH + event.offsetY);
          })
          .onActionEnd(() => {
            // 拖动结束落盘(按角色卡记忆,下次展开/重启后沿用)
            this.frontendPanelResized = true;
            this.persistPanelSize();
          })
      )
    )
  }

  // ===== 角色状态侧边栏(CHAT-STATUS-1B) =====

  /**
   * 右上角入口标签列:「状态」「界面」按顺序流式堆叠(谁有谁排上)。
   * 位置由整个 Column 一次给定,不再为第二个标签手算偏移;
   * 对应面板展开时该标签移出(带过渡,与面板滑入同时发生)。
   */
  @Builder
  rightRail() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column({ space: 8 }) {
        if (this.statusEntries.length > 0 && !this.statusPanelExpanded) {
          this.statusFloatingTab()
        }
        if (this.hasFrontend && !this.frontendPanelVisible) {
          this.frontendFloatingTab()
        }
        // 「全屏」入口:仅 panel 卡显示(卡声明 fullscreen 时「界面」细线本就全屏打开)
        if (this.hasFrontend && this.frontendMode === 'panel' && !this.frontendPanelVisible) {
          this.frontendFullscreenTab()
        }
      }
      .margin({ top: this.statusBarHeight + 54 })
      .alignItems(HorizontalAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    // 外层透明:空白处点击穿透到下层(消息列表/顶栏/输入区),仅标签自身可点
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 折叠态:「全屏界面」入口(panel 卡专用,贴屏右缘的短细线;由 rightRail 统一排布)。
   * 点按以 fullscreen 模式打开同一份前端页面——显示方式由用户在 App 内选择,
   * 不再受角色卡声明的 mode 限制。
   */
  @Builder
  frontendFullscreenTab() {
    Column()
      .width(ChatPage.RAIL_TAB_LINE_W)
      .height(ChatPage.RAIL_TAB_LINE_H_SM)
      .borderRadius({ topLeft: 2, topRight: 0, bottomLeft: 2, bottomRight: 0 })
      .backgroundColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      .shadow({ radius: 4, color: 'rgba(0,0,0,0.18)' })
      .responseRegion({ x: -27, y: -8, width: 31, height: 44 })
      .transition(
        TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: 40 }))
          .animation({ duration: 200, curve: Curve.EaseOut })
      )
      .onClick(() => {
        this.openFrontendCard('fullscreen');
      })
  }

  /** 展开态:角色状态面板 + 点面板以外任意位置收起 */
  @Builder
  statusPanelLayer() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.toggleStatusPanel(false);
        })

      Column() {
        this.statusFloatingPanel()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(HorizontalAlign.End)
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 折叠态:右上角「状态」入口(贴屏右缘的一条细线,强调色;由 rightRail 统一排布与定位) */
  @Builder
  statusFloatingTab() {
    Column()
      .width(ChatPage.RAIL_TAB_LINE_W)
      .height(ChatPage.RAIL_TAB_LINE_H)
      .borderRadius({ topLeft: 2, topRight: 0, bottomLeft: 2, bottomRight: 0 })
      .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
      .shadow({ radius: 4, color: 'rgba(0,0,0,0.18)' })
      // 细线本体只有 3vp 宽,把点击热区向左扩到约 31x56vp(不改变视觉),避免难点
      .responseRegion({ x: -27, y: -8, width: 31, height: 56 })
      .transition(
        TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: 40 }))
          .animation({ duration: 200, curve: Curve.EaseOut })
      )
      .onClick(() => {
        this.toggleStatusPanel(true);
      })
  }

  /** 展开态:右上角状态面板(只读列表 + 锁定 + AI 重新生成,字段由 AI 依据角色卡自动生成) */
  @Builder
  statusFloatingPanel() {
    Column() {
      // 标题行
      Row() {
        Text('角色状态')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Blank()

        // AI 依据角色卡重新生成字段(无底色纯文字,与字段列表保持同一视觉语言)
        Row() {
          if (this.statusGenBusy) {
            Text('生成中…')
              .fontSize(11)
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          } else {
            Text('✦ 重新生成')
              .fontSize(11)
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          }
        }
        .height(26)
        .padding({ left: 4, right: 4 })
        .onClick(() => {
          this.requestStatusGeneration();
        })
        .margin({ right: 6 })

        // 收起
        Text('››')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width(26)
          .height(26)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.toggleStatusPanel(false);
          })
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 字段列表
      if (this.statusEntries.length === 0) {
        Text('暂无状态字段,点击“重新生成”让 AI 依据角色卡生成')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 24 })
      } else {
        List() {
          ForEach(this.statusEntries,
            (entry: ChatStatusEntry, index: number) => {
              ListItem() {
                this.statusEntryRow(entry)
              }
            },
            (entry: ChatStatusEntry, index: number) => entry.name + '_' + index.toString()
          )
        }
        .divider({
          strokeWidth: 1,
          color: ThemePalette.dividerColor(this.effectiveTheme),
          startMargin: 0,
          endMargin: 0
        })
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width(320)
    .height(380)
    .margin({ top: this.statusBarHeight + 54 })
    .padding({ left: 12, right: 12, top: 12, bottom: 12 })
    .borderRadius({ topLeft: 18, topRight: 0, bottomLeft: 18, bottomRight: 0 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .shadow({ radius: 10, color: 'rgba(0,0,0,0.18)' })
    .transition(
      TransitionEffect.opacity(0).combine(TransitionEffect.translate({ x: 80 }))
        .animation({ duration: 220, curve: Curve.EaseOut })
    )
  }

  /** 单个状态字段行:emoji + 字段名(次要小字,固定列宽) + 值(主色中黑);不用方框,靠行距与分隔线分组 */
  @Builder
  statusEntryRow(entry: ChatStatusEntry) {
    Row() {
      Text(this.statusEmoji(entry.name))
        .fontSize(13)
        .width(18)
        .textAlign(TextAlign.Center)
      Text(entry.name)
        .fontSize(12)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(76)
        .margin({ left: 6 })
      Text(this.statusEntryValueText(entry))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .lineHeight(19)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 8 })
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 2, right: 2, top: 9, bottom: 9 })
  }

  // ===== CHAT-STATUS-1A / T-7.x: 状态/世界书滑动面板 =====

  /**
   * 状态/世界书面板(供 bindSheet 使用)。
   * 渲染与交互全部在 ChatStatusWorldPanel 内(纯搬运);状态与业务动作仍由本页持有:
   * - 双向:@Link(面板可见性 / AI 入口 / AI 指令输入)
   * - 业务动作:回调上抛本页方法(manualRefreshLorebookActivated / runAiAction / applyPendingChanges /
   *   viewModel.toggleLorebookEntryEnabled)
   */
  @Builder
  statusWorldSheetContent() {
    ChatStatusWorldPanel({
      effectiveTheme: this.effectiveTheme,
      statusPanelVisible: this.statusPanelVisible,
      aiEntryVisible: this.aiEntryVisible,
      aiPromptText: this.aiPromptText,
      aiMode: this.aiMode,
      aiLoading: this.aiLoading,
      pendingChangeSet: this.pendingChangeSet,
      lorebookPanelData: this.lorebookPanelData,
      lorebookPanelVersion: this.lorebookPanelVersion,
      onClearPendingChanges: (): void => {
        this.pendingChangeSet = null;
      },
      onRefreshActivated: (): void => {
        this.manualRefreshLorebookActivated();
      },
      onSelectAiMode: (mode: string): void => {
        this.aiMode = mode;
        this.pendingChangeSet = null;
        if (mode === 'extract') {
          this.runAiExtract();
        }
      },
      onRunAiAction: (): void => {
        this.runAiAction();
      },
      onApplyPendingChanges: (): void => {
        this.applyPendingChanges();
      },
      onToggleEntryEnabled: (lorebookId: string, entryId: string, enabled: boolean): void => {
        if (this.viewModel !== null) {
          this.viewModel!.toggleLorebookEntryEnabled(lorebookId, entryId, enabled).then((): void => {
            this.syncLorebookPanelData();
          }).catch((): void => {
          });
        }
      }
    })
  }

  // ===== 角色状态管理面板逻辑(CHAT-STATUS-1B) =====

  /** 管理面板行的值文案;无值时显示占位符(字段名已单独成列) */
  private statusEntryValueText(entry: ChatStatusEntry): string {
    const v: string = entry.value.trim();
    return v.length === 0 ? '—' : v;
  }

  /** 字段名 → emoji(关键词匹配,兜底 ✨) */
  private statusEmoji(name: string): string {
    const n: string = name.trim();
    if (n.length === 0) {
      return '✨';
    }
    if (n.includes('衣') || n.includes('服')) {
      return '🧥';
    }
    if (n.includes('地点') || n.includes('位置') || n.includes('场所')) {
      return '📍';
    }
    if (n.includes('金币') || n.includes('金钱') || n.includes('钱')) {
      return '🪙';
    }
    if (n.includes('武器')) {
      return '⚔';
    }
    if (n.includes('心情') || n.includes('情绪') || n.includes('心境')) {
      return '🎭';
    }
    if (n.includes('体力') || n.includes('能量') || n.includes('法力') || n.includes('魔力')) {
      return '⚡';
    }
    if (n.includes('生命') || n.includes('健康') || n.includes('血量')) {
      return '❤';
    }
    if (n.includes('时间') || n.includes('时辰')) {
      return '🕐';
    }
    if (n.includes('道具') || n.includes('物品') || n.includes('背包')) {
      return '🎒';
    }
    return '✨';
  }

  /** 展开/收起状态面板(带动画:透明度 + 从右侧滑入/滑出) */
  private toggleStatusPanel(expand: boolean): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, (): void => {
      this.statusPanelExpanded = expand;
    });
  }

  /** AI 一键生成状态字段(非阻塞;完成后同步刷新列表) */
  private requestStatusGeneration(): void {
    if (this.viewModel === null || this.statusGenBusy) {
      return;
    }
    this.statusGenBusy = true;
    this.viewModel!.generateStatusFields().then((_ok: boolean): void => {
      this.statusGenBusy = false;
    }).catch(() => {
      this.statusGenBusy = false;
    });
  }

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

  /**
   * 显示设置面板(供 bindSheet 使用)。
   * 渲染与交互全部在 ChatAppearancePanel 内(纯搬运);状态与持久化仍由本页持有:
   * - 双向:@Link(面板可见性 / 两个滑块 / 色盘请求)
   * - 业务动作:回调上抛本页方法(persistBubbleOpacity / applyFontSize / setChatTextColorMode / ...)
   */
  @Builder
  appearanceSheetContent() {
    ChatAppearancePanel({
      effectiveTheme: this.effectiveTheme,
      chatAppearancePanelVisible: this.chatAppearancePanelVisible,
      chatBubbleOpacity: this.chatBubbleOpacity,
      chatContentHeightRatio: this.chatContentHeightRatio,
      colorPickerRequest: this.colorPickerRequest,
      chatTextStyle: this.chatTextStyle,
      chatTextColorMode: this.chatTextColorMode,
      isDarkMode: this.isDarkMode,
      bodyTextColor: this.chatBodyTextColor,
      emphasisTextColor: this.chatEmphasisColor,
      dialogueTextColor: this.chatDialogueColor,
      actionTextColor: this.chatActionColor,
      codeTextColor: this.chatCodeColor,
      linkTextColor: this.chatLinkColor,
      quoteTextColor: this.chatQuoteColor,
      userTextColor: this.chatUserTextColor,
      symbolRules: this.chatSymbolRules,
      clampBubbleOpacity: (value: number): number => this.normalizeChatBubbleOpacity(value),
      onPersistBubbleOpacity: (value: number): void => {
        this.persistBubbleOpacity(value);
      },
      onPersistContentHeightRatio: (ratio: number): void => {
        this.persistContentHeightRatio(ratio);
      },
      onApplyFontSize: (fontSize: number): void => {
        this.applyFontSize(fontSize);
      },
      onApplyImageWidthRatio: (ratio: number): void => {
        this.applyImageWidthRatio(ratio);
      },
      onApplyFontFamily: (family: string): void => {
        this.applyFontFamily(family);
      },
      onSelectTextColorMode: (mode: string): void => {
        this.setChatTextColorMode(mode);
      },
      onSetCustomColor: (target: CustomColorTarget, ruleId: string, color: string): void => {
        if (ruleId.length > 0) {
          this.setSymbolRuleColor(ruleId, color);
        } else {
          this.setCustomColor(target, color);
        }
      },
      onSetCustomColorLive: (target: CustomColorTarget, ruleId: string, color: string): void => {
        if (ruleId.length > 0) {
          this.setSymbolRuleColorLive(ruleId, color);
        } else {
          this.setCustomColorLive(target, color);
        }
      },
      onAddSymbolRule: (open: string, close: string): void => {
        this.addSymbolRule(open, close);
      },
      onRemoveSymbolRule: (ruleId: string): void => {
        this.removeSymbolRule(ruleId);
      },
      onResetTextColor: (): void => {
        this.resetChatTextColor();
      },
      onResetAllAppearance: (): void => {
        this.resetAllAppearance();
      }
    })
  }

  /**
   * 色盘选择器覆盖层(全屏遮罩 + 居中卡片)。
   *
   * - 遮罩与卡片为兄弟节点,避免卡片内拖动/点击冒泡到遮罩导致误关闭
   * - ColorWheelPicker 实时回调 setCustomColor,拖动即预览、关闭即生效
   */
  @Builder
  colorPickerOverlay() {
    if (this.colorPickerRequest !== null) {
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
            color: this.colorPickerRequest.color,
            onChange: (c: string): void => {
              const request: ColorPickerRequest | null = this.colorPickerRequest;
              if (request === null) {
                return;
              }
              // 符号规则(drag 实时预览)与语义色分流
              if (request.ruleId.length > 0) {
                this.setSymbolRuleColorLive(request.ruleId, c);
              } else {
                this.setCustomColorLive(request.target, c);
              }
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
    // 加载期间阻断触摸:定位阶段消息列表已挂载但不可见,避免误触到列表
    .hitTestBehavior(HitTestMode.Block)
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

  /**
   * 输入区发送/提交统一入口(自 inputArea 抽取,行为不变):
   * 预算超限提示;可发送时按旁白模式分支发送。
   */
  private handleInputSend(): void {
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
  }

  /**
   * 输入框 Enter 预处理(自 inputArea 抽取,行为不变):
   * Ctrl+Enter 放行(换行);否则预算校验/发送,消费事件返回 true。
   */
  private handleInputKeyPreIme(event: KeyEvent): boolean {
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

  /** 删除消息确认对话框 */
  @Builder
  deleteMessageConfirmDialog() {
    Stack() {
      Column() {
        Column() {
          Text('删除消息')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })

          Text('确定删除这条消息吗?删除后不可恢复。')
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
                this.showDeleteMessageConfirm = false;
                this.pendingDeleteMessageId = '';
              })
            Button('删除')
              .fontSize(15)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .layoutWeight(1)
              .margin({ left: 12 })
              .onClick(() => {
                void this.executeDeleteMessage();
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
      this.showDeleteMessageConfirm = false;
      this.pendingDeleteMessageId = '';
    })
  }

  /** 执行删除消息 */
  private async executeDeleteMessage(): Promise<void> {
    const messageId: string = this.pendingDeleteMessageId;
    this.showDeleteMessageConfirm = false;
    this.pendingDeleteMessageId = '';
    if (messageId.length === 0 || this.viewModel === null) {
      return;
    }
    await this.viewModel!.deleteMessage(messageId);
    if (this.viewModel!.errorMessage.length > 0) {
      promptAction.showToast({ message: this.viewModel!.errorMessage, duration: 1500 });
    }
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
    this.userNameSheetShow = false;
    this.showUserNameOverrideDialog = true;
  }

  // ===== v50: 记忆模式选择对话框 =====

  /**
   * v51: 记忆总结结果 Toast(由 AppStorage 驱动;弹完复位以便连续触发)。
   */
  onMemorySummaryResultChanged(): void {
    const result: string = this.memorySummaryLastResult;
    if (result === 'success') {
      promptAction.showToast({ message: '记忆总结完成', duration: 1500 });
    } else if (result === 'failed') {
      promptAction.showToast({ message: '记忆总结失败,请重试', duration: 2000 });
    } else {
      return;
    }
    // 复位,保证下一次相同结果仍能触发 @Watch
    AppStorage.setOrCreate<string>('memorySummaryLastResult', '');
  }

  /** v51: 刷新待激活章节数(面板打开 / 记忆变更后调用)。 */
  private async refreshPendingChapterCount(): Promise<void> {
    if (this.viewModel === null) {
      this.memoryPendingChapters = 0;
      return;
    }
    try {
      this.memoryPendingChapters = await this.viewModel!.getPendingChapterCount();
    } catch (_e) {
      this.memoryPendingChapters = 0;
    }
  }

  /** v51: 生成章节摘要(仅生成,不改动当前对话与缓存)。 */
  private generateMemorySummary(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.triggerManualMemorySummary();
  }

  /** v51: 立即归档(生成未归档章节 + 推进激活边界 + 更新核心记忆,一次前缀冷重建)。 */
  private activateMemoryNow(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.activateMemoryNow();
  }

  /**
   * 打开记忆模式选择对话框:读取当前会话的记忆模式与章节注入数到草稿。
   */
  private async openMemoryModeDialog(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      const mode: ChatMemoryMode = await this.viewModel!.getMemoryMode();
      this.memoryModeIsAuto = mode === 'auto';
      this.memoryModeChapterCount = await this.viewModel!.getChapterInjectCount();
      this.memoryPendingChapters = await this.viewModel!.getPendingChapterCount();
    } catch (_e) {
      // 读取失败用默认值打开
      this.memoryModeIsAuto = false;
      this.memoryModeChapterCount = 4;
      this.memoryPendingChapters = 0;
    }
    this.memoryModeSheetShow = false;
    this.showMemoryModeDialog = true;
  }

  /**
   * 保存记忆模式与章节注入数(仅当前会话)。
   */
  private async saveMemoryMode(): Promise<void> {
    if (this.viewModel === null) {
      this.memoryModeSheetShow = false;
      return;
    }
    try {
      await this.viewModel!.setMemoryMode(this.memoryModeIsAuto ? 'auto' : 'manual');
      await this.viewModel!.setChapterInjectCount(this.memoryModeChapterCount);
      await this.refreshMemoryModeDisplay();
      promptAction.showToast({
        message: this.memoryModeIsAuto ? '已切换为自动归档' : '已切换为手动总结', duration: 1500
      });
    } catch (_e) {
      promptAction.showToast({ message: '保存失败,请重试', duration: 2000 });
    }
    this.memoryModeSheetShow = false;
  }

  /**
   * 刷新菜单中的记忆模式显示文本。
   */
  private async refreshMemoryModeDisplay(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    try {
      const mode: ChatMemoryMode = await this.viewModel!.getMemoryMode();
      this.memoryModeText = mode === 'auto' ? '自动归档' : '手动总结';
    } catch (_e) {
      this.memoryModeText = '手动总结';
    }
  }

  /** 记忆模式面板内容(上滑 Sheet):模式选择 + 章节注入数 */
  @Builder
  memoryModeSheetContent() {
    Column() {
      Text('记忆模式')
        .fontSize($r('app.float.app_font_title'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 8, bottom: 2 })

      this.sheetSectionCaption('模式')
      Column() {
        this.memoryModeRow('手动总结', '完全手动:用下方"生成章节摘要"生成,自行决定何时归档',
          true, false)
        this.memoryModeRow('自动归档', '未归档满 50 条或 2 万字符时自动生成;待归档累积 4 章后整体归档',
          false, true)
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))

      this.sheetSectionCaption('章节注入')
      Column() {
        Row() {
          Text('注入最近章节数')
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .layoutWeight(1)
          Text(String(this.memoryModeChapterCount))
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10 })

        Slider({ value: this.memoryModeChapterCount, min: 1, max: 20, step: 1 })
          .width('100%')
          .height(28)
          .padding({ left: 12, right: 12 })
          .onChange((value: number) => {
            this.memoryModeChapterCount = Math.round(value);
          })

        Text('每章约 2000-3000 字,章节数越多上下文占用越大(默认 4)')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ left: 12, right: 12, bottom: 10 })
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))

      this.sheetSectionCaption('记忆操作')
      Column() {
        this.memoryActionRow('生成章节摘要', '只生成并保存,不改动当前对话与缓存',
          this.memoryPendingChapters > 0 ? ('待归档 ' + this.memoryPendingChapters) : '生成',
          false, false, (): void => {
            this.generateMemorySummary();
          })
        this.memoryActionRow('立即归档', '补生成未归档章节并使其生效(本章结束后仅此一次缓存重建)',
          '立即归档', this.memoryPendingChapters <= 0, true, (): void => {
            this.activateMemoryNow();
          })
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))

      Button('保存')
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .width('100%')
        .margin({ top: 16 })
        .onClick(() => {
          void this.saveMemoryMode();
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 8 })
  }

  /**
   * v51: 记忆模式选择行(勾选标记在 Builder 体内直接读 @State,修复 @Builder 按值传参不刷新)。
   * @param isManual true=本行为"手动总结",false=本行为"自动归档"
   */
  @Builder
  memoryModeRow(label: string, desc: string, isManual: boolean, showDivider: boolean) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12 })
      }
      Row() {
        Column() {
          Text(label)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
          if (desc.length > 0) {
            Text(desc)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ top: 2 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (isManual === !this.memoryModeIsAuto) {
          Text('✓')
            .fontSize(16)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      this.memoryModeIsAuto = !isManual;
    })
  }

  /**
   * v51: 记忆操作行(生成章节摘要 / 立即归档)。
   * 进行中显示进度环;disabled 时动作胶囊置灰且不响应点击。
   */
  @Builder
  memoryActionRow(label: string, desc: string, actionText: string, disabled: boolean, showDivider: boolean,
    onClick: () => void) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12 })
      }
      Row() {
        Column() {
          Text(label)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
          if (desc.length > 0) {
            Text(desc)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ top: 2 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.memorySummaryRunning) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(ThemePalette.accentColor(this.effectiveTheme))
        } else {
          Text(actionText)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(disabled
              ? ThemePalette.textTertiaryColor(this.effectiveTheme)
              : ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      if (disabled || this.memorySummaryRunning) {
        return;
      }
      onClick();
    })
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
   * 打开 Persona 选择面板(上滑)。
   * 加载所有 Persona 并展示选择列表。
   */
  private async openPersonaPicker(): Promise<void> {
    try {
      const service = AppServices.getPersonaService();
      this.personaOptions = await service.list();
      // 获取当前生效的身份名称
      await this.refreshPersonaDisplay();
      this.personaSheetTab = 0;
      this.personaSheetShow = false;
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
      this.personaSheetShow = false;
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
    this.personaSheetShow = false;
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
    this.chapterSheetShow = false;
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
        this.chapterSheetShow = false;
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

  /** 新建章节面板内容(上滑 Sheet):开场白列表 + 创建按钮 */
  @Builder
  chapterSheetContent() {
    Column() {
      Text('新建章节')
        .fontSize($r('app.float.app_font_title'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 8, bottom: 2 })

      Text('新章节将加入同一世界分组,原对话保留可切回')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4 })

      this.sheetSectionCaption('选择开场白')
      Column() {
        ForEach(this.chapterGreetingPool, (greeting: string, index: number) => {
          Column() {
            if (index > 0) {
              Divider()
                .color(ThemePalette.dividerColor(this.effectiveTheme))
                .margin({ left: 12, right: 12 })
            }
            Column() {
              Text('开场白 ' + (index + 1).toString())
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                .width('100%')
              Text(this.greetingPreview(greeting))
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .width('100%')
                .margin({ top: 2 })
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .alignItems(HorizontalAlign.Start)
            .onClick(() => {
              this.selectChapterGreeting(index);
            })
          }
          .width('100%')
        }, (greeting: string, index: number) => 'greeting_' + index.toString())
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))

      Button(this.chapterCreateBusy ? '正在创建章节...' : '创建章节')
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .height(44)
        .margin({ top: 16 })
        .enabled(!this.chapterCreateBusy)
        .onClick(() => {
          if (!this.chapterCreateBusy && this.chapterGreetingPool.length > 0) {
            this.selectChapterGreeting(0);
          }
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 8 })
  }

  /**
   * 上滑面板分区小标题(与行内文字左对齐:面板内边距 12 + 标题内边距 4)
   */
  @Builder
  sheetSectionCaption(text: string) {
    Text(text)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      .width('100%')
      .padding({ left: 4, top: 14, bottom: 6 })
  }

  /**
   * 上滑面板选择行:名称 + 说明(可空) + 选中标记。
   * @param showDivider 是否在行顶画分隔线(卡片内非首行传 true)
   */
  @Builder
  sheetChoiceRow(label: string, desc: string, selected: boolean, showDivider: boolean, onClick: () => void) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12 })
      }
      Row() {
        Column() {
          Text(label)
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
          if (desc.length > 0) {
            Text(desc)
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ top: 2 })
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (selected) {
          Text('✓')
            .fontSize(16)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      onClick();
    })
  }

  /**
   * 上滑面板动作行:名称 + 右侧动作胶囊(忙碌时替换为进度环)。
   * @param dangerous 是否危险色标签
   * @param showDivider 是否在行顶画分隔线
   */
  @Builder
  sheetActionRow(label: string, actionText: string, busy: boolean, dangerous: boolean, showDivider: boolean,
    onClick: () => void) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12 })
      }
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(dangerous
            ? $r('app.color.app_danger')
            : ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (busy) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(ThemePalette.accentColor(this.effectiveTheme))
        } else {
          Text(actionText)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(dangerous
              ? $r('app.color.app_danger')
              : ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        }
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      if (busy) {
        return;
      }
      onClick();
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

  /** 本对话称呼面板内容(上滑 Sheet):输入覆盖值 + 保存 */
  @Builder
  userNameSheetContent() {
    Column() {
      Text($r('app.string.chat_user_name_override_menu_title'))
        .fontSize($r('app.float.app_font_title'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 8, bottom: 2 })

      Text($r('app.string.chat_user_name_override_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 4, bottom: 6 })

      TextInput({
        placeholder: $r('app.string.chat_user_name_override_placeholder'),
        text: this.userNameOverrideDraft
      })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .padding({ left: 12, right: 12 })
        .width('100%')
        .onChange((value: string) => {
          this.userNameOverrideDraft = value;
        })

      Button($r('app.string.character_edit_save'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(44)
        .width('100%')
        .margin({ top: 16 })
        .onClick(() => {
          this.saveUserNameOverride().catch(() => {});
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 8 })
  }

  /** 用户身份面板内容(上滑 Sheet):分段切换「用户身份 / 性格总结」 */
  @Builder
  personaSheetContent() {
    Column() {
      Text('切换用户身份')
        .fontSize($r('app.float.app_font_title'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 8, bottom: 2 })

      Row() {
        this.personaTabItem(0, '用户身份')
        this.personaTabItem(1, '性格总结')
      }
      .width('100%')
      .padding(2)
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_sm'))
      .margin({ top: 10, bottom: 4 })

      if (this.personaSheetTab === 0) {
        this.personaListSection()
      } else {
        this.personaSummarySection()
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 8 })
  }

  /** 身份面板分段项 */
  @Builder
  personaTabItem(tab: number, label: string) {
    Text(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontWeight(this.personaSheetTab === tab ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.personaSheetTab === tab
        ? ThemePalette.textPrimaryColor(this.effectiveTheme)
        : ThemePalette.textSecondaryColor(this.effectiveTheme))
      .textAlign(TextAlign.Center)
      .backgroundColor(this.personaSheetTab === tab
        ? ThemePalette.surface1Color(this.effectiveTheme)
        : Color.Transparent)
      .borderRadius($r('app.float.app_radius_sm'))
      .height(32)
      .layoutWeight(1)
      .onClick(() => {
        this.personaSheetTab = tab;
      })
  }

  /** 身份分段:一张卡承载「跟随默认 + 全部身份」 */
  @Builder
  personaListSection() {
    Column() {
      this.sheetChoiceRow('跟随默认', '使用角色或全局默认身份',
        this.viewModel !== null && this.viewModel!.getCurrentChatPersonaId().length === 0,
        false, (): void => {
          this.selectPersonaForChat('');
        })

      ForEach(this.personaOptions, (persona: Persona) => {
        this.sheetChoiceRow(persona.name, persona.description,
          this.viewModel !== null && this.viewModel!.getCurrentChatPersonaId() === persona.id,
          true, (): void => {
            this.selectPersonaForChat(persona.id);
          })
      }, (persona: Persona) => persona.id)

      if (this.personaOptions.length === 0) {
        Text('暂无身份,请先在「设置 → 用户身份」中创建')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      }
    }
    .width('100%')
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
  }

  /** 性格总结分段:摘要卡 + 操作卡 */
  @Builder
  personaSummarySection() {
    Column({ space: 8 }) {
      Column() {
        if (this.viewModel !== null && this.viewModel!.userPersonaSummary.length > 0) {
          Text(this.viewModel!.userPersonaSummary)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .padding(12)
            .maxLines(10)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Text('尚未生成。可用下方按钮从角色卡提取,或从对话总结。')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .padding(12)
        }
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))

      Column() {
        this.sheetActionRow('从角色卡提取', '生成',
          this.viewModel !== null && this.viewModel!.isExtractingUserPersona, false, false, (): void => {
            if (this.viewModel !== null) {
              this.viewModel!.extractUserFromCharacter();
            }
          })
        this.sheetActionRow('从对话总结', '生成',
          this.viewModel !== null && this.viewModel!.isSummarizingUserPersona, false, true, (): void => {
            if (this.viewModel !== null) {
              this.viewModel!.summarizeUserPersona();
            }
          })
        if (this.viewModel !== null && this.viewModel!.userPersonaSummary.length > 0) {
          this.sheetActionRow('清除性格总结', '清除', false, true, true, (): void => {
            if (this.viewModel !== null) {
              this.viewModel!.clearUserPersonaSummary();
            }
          })
        }
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
    }
    .width('100%')
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

  /**
   * 整列表被替换时(进入会话 / 切换会话)重新定位到底部。
   * 仅两种情况需要定位:①页面首次加载(列表还没显示过)②首条消息 id 变化且原有内容非空。
   * 空会话里发出第一条消息不触发定位,避免闪一下加载动画。
   */
  private updateListPositioning(msgs: ChatMessage[], prevFirstId: string): void {
    if (msgs.length === 0) {
      this.finishListPositioning();
      return;
    }
    const replaced: boolean = prevFirstId.length > 0
      ? msgs[0].id !== prevFirstId
      : !this.chatListPositioned;
    if (replaced) {
      this.beginListPositioning();
    }
  }

  /**
   * 开始"追底定位":隐藏消息列表(显示加载动画),把视图钉在最新消息处。
   * 懒加载内容高度逐帧增长,单次滚动会落在顶部,故需持续追底直到真正到底。
   */
  private beginListPositioning(): void {
    this.chatListPositioned = false;
    this.bottomLockActive = true;
    this.bottomLockRetries = 0;
    this.lastMessageCount = this.messages.length;
    this.schedulePositionFallback();
    this.scroller.scrollEdge(Edge.Bottom);
  }

  /** 结束定位:显示消息列表并撤掉兜底定时器 */
  private finishListPositioning(): void {
    this.bottomLockActive = false;
    this.clearPositionFallback();
    this.chatListPositioned = true;
  }

  /** 定位兜底:极端情况下布局不再变化且未判定到底时,超时强制显示,避免列表永久隐藏 */
  private schedulePositionFallback(): void {
    this.clearPositionFallback();
    this.positionFallbackTimer = setTimeout((): void => {
      this.positionFallbackTimer = -1;
      if (!this.bottomLockActive) {
        return;
      }
      this.scroller.scrollEdge(Edge.Bottom);
      this.finishListPositioning();
    }, 800);
  }

  private clearPositionFallback(): void {
    if (this.positionFallbackTimer >= 0) {
      clearTimeout(this.positionFallbackTimer);
      this.positionFallbackTimer = -1;
    }
  }

  /**
   * 内容区变化时的滚动处理。
   * - 追底锁生效中(刚进入 / 切换会话):持续追底,直到真正到底、超时或用户上滑;
   * - 否则只在新消息插入时滚到底(既有行为)。
   */
  private autoScrollToBottom(): void {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel.userScrolledUp) {
      if (this.bottomLockActive) {
        // 用户主动上滑:放弃追底,直接显示列表
        this.finishListPositioning();
      }
      return;
    }
    const newCount: number = this.messages.length;
    if (this.bottomLockActive) {
      this.bottomLockRetries++;
      this.lastMessageCount = newCount;
      this.scroller.scrollEdge(Edge.Bottom);
      if (this.scroller.isAtEnd() || this.bottomLockRetries > 40) {
        this.finishListPositioning();
      }
      return;
    }
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
    // v51: 记忆变更(生成/激活)后刷新待激活章节数
    void this.refreshPendingChapterCount();
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
        } else if (msg.role === ChatRole.Assistant) {
          this.openEditAssistantDialog(msg.id, msg.content);
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
      case 'delete':
        this.pendingDeleteMessageId = msg.id;
        this.showDeleteMessageConfirm = true;
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

  /** v52: 应用消息内图片大小(宽度占气泡比例,实时更新 ChatTextStyle) */
  private applyImageWidthRatio(ratio: number): void {
    const settings = AppServices.getInstance().chatTextStyleSettings;
    settings.update({ imageWidthRatio: ratio })
      .then((): void => {
        this.chatTextStyle = settings.get();
      })
      .catch((e: Object): void => {
        Logger.warn(LOG_TAG, 'applyImageWidthRatio failed: ' + (e as Error).message);
      });
  }

  /** 应用正文字体族设置(实时更新 ChatTextStyle) */
  private applyFontFamily(family: string): void {
    const settings = AppServices.getInstance().chatTextStyleSettings;
    settings.update({ fontFamily: family })
      .then((): void => {
        this.chatTextStyle = settings.get();
      })
      .catch((e: Object): void => {
        Logger.warn('ChatPage', 'applyFontFamily failed: ' + (e as Error).message);
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

  // ===== 自定义符号配色规则(所有配色模式下都生效) =====

  /**
   * 新增符号规则。
   * 默认颜色由页面决定(DEFAULT_SYMBOL_TEXT_COLOR),去重由面板校验。
   * 不可变更新(整体替换数组)以触发 @State/@Prop 刷新与消息重解析。
   */
  private addSymbolRule(open: string, close: string): void {
    const next: ChatSymbolColorRule[] = [];
    for (let i = 0; i < this.chatSymbolRules.length; i++) {
      next.push(this.chatSymbolRules[i]);
    }
    next.push(createSymbolRule(open, close, DEFAULT_SYMBOL_TEXT_COLOR));
    this.chatSymbolRules = next;
    this.persistTextColor();
  }

  /** 删除符号规则(整体替换数组触发刷新)。 */
  private removeSymbolRule(ruleId: string): void {
    const next: ChatSymbolColorRule[] = [];
    for (let i = 0; i < this.chatSymbolRules.length; i++) {
      const rule: ChatSymbolColorRule = this.chatSymbolRules[i];
      if (rule.id !== ruleId) {
        next.push(rule);
      }
    }
    this.chatSymbolRules = next;
    this.persistTextColor();
  }

  /** 设置符号规则颜色(含持久化)。 */
  private setSymbolRuleColor(ruleId: string, color: string): void {
    if (this.applySymbolRuleColor(ruleId, color)) {
      this.persistTextColor();
    }
  }

  /** 仅更新符号规则颜色,不持久化(色盘拖动实时预览)。 */
  private setSymbolRuleColorLive(ruleId: string, color: string): void {
    this.applySymbolRuleColor(ruleId, color);
  }

  /**
   * 应用符号规则颜色(校验 + 归一化 + 不可变替换)。
   * 返回是否发生变更(未命中规则或颜色非法时为 false)。
   */
  private applySymbolRuleColor(ruleId: string, color: string): boolean {
    const normalized: string | null = normalizeHexColor(color);
    if (normalized === null) {
      return false;
    }
    const next: ChatSymbolColorRule[] = [];
    let changed: boolean = false;
    for (let i = 0; i < this.chatSymbolRules.length; i++) {
      const rule: ChatSymbolColorRule = this.chatSymbolRules[i];
      if (rule.id === ruleId) {
        next.push(createSymbolRule(rule.open, rule.close, normalized));
        changed = true;
      } else {
        next.push(rule);
      }
    }
    if (changed) {
      this.chatSymbolRules = next;
    }
    return changed;
  }

  /** 关闭色盘选择器,并持久化当前配色。 */
  private closeColorPicker(): void {
    if (this.colorPickerRequest !== null) {
      this.colorPickerRequest = null;
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
    // 自定义符号规则一并清空(恢复默认 = 回到无规则状态)
    this.chatSymbolRules = [];
    this.persistTextColor();
  }

  /**
   * 全部恢复默认(气泡不透明度 + 字体配色)。
   */
  private resetAllAppearance(): void {
    this.resetChatBubbleOpacity();
    this.resetChatTextColor();
  }

  /**
   * 播放/停止消息 TTS(自 messageList 抽取,行为不变)。
   * 正在播放时停止;否则按当前引擎(Edge 在线 / 本地)朗读指定内容。
   */
  private handleTtsPlay(content: string): void {
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
        this.edgeTtsService.speak(content, onComplete, onStart, onError);
      } else {
        this.ttsService.speak(content, onComplete, onStart);
      }
      this.ttsIsSpeaking = true;
    }
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
      customStyle: true
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
      customStyle: true
    });
    this.editDialogController.open();
  }

  private confirmEditNarratorMessage(messageId: string, editedContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.editNarratorMessage(messageId, editedContent);
  }

  /** 打开角色回复编辑对话框(仅改文本,不重新生成) */
  private openEditAssistantDialog(messageId: string, originalContent: string): void {
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
          this.confirmEditAssistantMessage(messageId, editedContent);
        },
        onCancel: (): void => {}
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.editDialogController.open();
  }

  private confirmEditAssistantMessage(messageId: string, editedContent: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.editAssistantMessage(messageId, editedContent);
  }
}
