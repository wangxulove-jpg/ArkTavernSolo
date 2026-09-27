/**
 * 聊天消息列表(自 ChatPage.messageList 抽取,纯搬运,行为不变)。
 *
 * 设计:组件不持有 VM/服务,依赖全部经 @Prop 值 + 回调上抛:
 * - 数据:dataSource / scroller 由页面持有并传入(保证 RenderState 实例稳定)
 * - 样式与尺寸:effectiveTheme / bubbleOpacity / colorTheme / chatTextStyle / 各高度
 * - 交互:回调上抛,由页面处理(viewModel 调用、弹窗、TTS、滚动)
 */
import { ChatMessageRenderState } from '../models/ChatMessageRenderState';
import { ChatMessage, ChatMessageStatus } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ChatMessageSource } from '../models/ChatMessageSource';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import { ChatMarkdownColorTheme } from '../utils/ChatTextColorTheme';
import { ThemePalette } from '../theme/ThemePalette';
import { ChatMessageBubble } from './ChatMessageBubble';
import { MessageSwipeControls } from './MessageSwipeControls';
import { ChatMessageDataSource } from './ChatMessageDataSource';

@Component
export struct ChatMessageList {
  /** 当前主题(对应页面 effectiveTheme) */
  @Prop effectiveTheme: string = 'dark';
  /** 深色模式(用于重生按钮底色) */
  @Prop isDarkMode: boolean = false;
  /** 气泡不透明度(用于重生按钮底色) */
  @Prop bubbleOpacity: number = 1.0;
  /** Markdown 文字配色主题(null 表示不覆盖) */
  @Prop colorTheme: ChatMarkdownColorTheme | null = null;
  /** 聊天文字样式设置 */
  @Prop chatTextStyle: ChatTextStyle | null = null;
  /** 角色头像 URI */
  @Prop characterAvatarUri: string = '';
  /** 角色名 */
  @Prop characterName: string = '';
  /** 角色 ID(消息 senderCharacterId) */
  @Prop characterId: string = '';
  /** 状态栏高度(顶部 padding 避让) */
  @Prop statusBarHeight: number = 0;
  /** 底部导航条高度(底部占位) */
  @Prop navigationBarHeight: number = 0;
  /** 键盘高度(底部占位) */
  @Prop keyboardHeight: number = 0;
  /** 代写候选面板是否可见(底部占位额外 150) */
  @Prop impersonatePanelActive: boolean = false;
  /** TTS 是否启用(读模式非 Off) */
  @Prop ttsEnabled: boolean = false;
  /** 是否正在生成(Swipe 控件生成态) */
  @Prop isGenerating: boolean = false;
  /** Swipe 控件可渲染(页面 viewModel 就绪) */
  @Prop swipeControlsAvailable: boolean = false;
  /** 新消息入场动画开关(页面首帧门控:首次加载不animate,之后新插入项淡入+上移) */
  @Prop entranceAnimationEnabled: boolean = true;

  /** 消息渲染状态数据源(页面持有) */
  dataSource: ChatMessageDataSource = new ChatMessageDataSource();
  /** 滚动控制器(与页面共用同一实例) */
  scroller: Scroller = new Scroller();

  /** 内容区变化请求自动滚底 */
  onRequestAutoScroll: () => void = () => {};
  /** 用户滚动到底部 */
  onUserScrolledToBottom: () => void = () => {};
  /** 气泡内交互(前端卡)回传 */
  onInteractiveAction: (text: string) => void = (_: string) => {};
  /** 消息长按(打开操作面板) */
  onLongPressMessage: (message: ChatMessage) => void = (_: ChatMessage) => {};
  /** 请求播放 TTS */
  onTtsPlayRequest: (content: string) => void = (_: string) => {};
  /** 指定消息是否可重生成 */
  canRegenerate: (messageId: string) => boolean = (_: string) => false;
  /** 重生成指定消息 */
  onRegenerate: (messageId: string) => void = (_: string) => {};
  /** 取 Swipe 激活候选索引 */
  getSwipeActiveIndex: (messageId: string) => number = (_: string) => 0;
  /** 取 Swipe 候选总数 */
  getCandidateCount: (messageId: string) => number = (_: string) => 0;
  /** Swipe 是否可操作 */
  canOperateSwipe: (messageId: string) => boolean = (_: string) => false;
  /** 切到上一个候选 */
  onSwipePrevious: (messageId: string) => void = (_: string) => {};
  /** 切到下一个候选 */
  onSwipeNext: (messageId: string) => void = (_: string) => {};
  /** 停止生成(Swipe 控件停止按钮) */
  onSwipeStop: () => void = () => {};

  build() {
    Scroll(this.scroller) {
      Column() {
        LazyForEach(this.dataSource, (state: ChatMessageRenderState, _index: number) => {
          if (state.role !== ChatRole.System || state.senderType === 'narrator') {
            Column() {
              ChatMessageBubble({
                renderState: state,
                characterAvatarUri: this.characterAvatarUri,
                characterName: this.characterName,
                showAvatar: state.source !== ChatMessageSource.CharacterFirstMessage,
                settings: this.chatTextStyle,
                senderCharacterId: this.characterId,
                colorTheme: this.colorTheme,
                bubbleOpacity: this.bubbleOpacity,
                isDarkMode: this.isDarkMode,
                onInteractiveAction: (text: string): void => {
                  this.onInteractiveAction(text);
                },
                onLongPress: (target: ChatMessage): void => {
                  this.onLongPressMessage(target);
                },
                onTtsPlay: state.role === ChatRole.Assistant && this.ttsEnabled
                  ? (): void => {
                    this.onTtsPlayRequest(state.displayContent);
                  }
                  : undefined,
                onRegenerate: state.role === ChatRole.Assistant
                  && this.canRegenerate(state.messageId)
                  ? (): void => {
                    this.onRegenerate(state.messageId);
                  }
                  : undefined,
              })

              // 分支切换控件(仅 Assistant 非首条消息)
              if (state.role === ChatRole.Assistant
                && state.source !== ChatMessageSource.CharacterFirstMessage
                && this.swipeControlsAvailable) {
                MessageSwipeControls({
                  activeCandidateIndex: this.getSwipeActiveIndex(state.messageId),
                  candidateCount: this.getCandidateCount(state.messageId),
                  isGenerating: this.isGenerating,
                  isOperable: this.canOperateSwipe(state.messageId),
                  onPrevious: (): void => {
                    this.onSwipePrevious(state.messageId);
                  },
                  onNext: (): void => {
                    this.onSwipeNext(state.messageId);
                  },
                  onStop: (): void => {
                    this.onSwipeStop();
                  }
                })
              }

              // 失败重试按钮
              if (state.status === ChatMessageStatus.Failed
                && this.canRegenerate(state.messageId)) {
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
                    this.onRegenerate(state.messageId);
                  })
                }
                .width('100%')
                .justifyContent(FlexAlign.Start)
                .margin({ left: 0 })
              }
            }
            .width('100%')
            // 新消息入场:淡入 + 上移 220ms。首帧由页面门控关闭,避免整列表加载时集体闪入;
            // 流式回答只在消息插入时触发一次(delta 更新不重建节点,不会重复播放)。
            .transition(this.entranceAnimationEnabled
              ? TransitionEffect.OPACITY
                .animation({ duration: 220, curve: Curve.FastOutSlowIn })
                .combine(TransitionEffect.translate({ y: 12 }))
              : TransitionEffect.IDENTITY)
          }
        }, (state: ChatMessageRenderState) => state.messageId)
        // 底部空白占位:高度等于悬浮输入栏占用空间(输入栏 56 + bottom padding 12 + navBar 12),
        // 让 scrollEdge(Bottom) 时最后一条消息显示在悬浮输入栏上方,不被遮挡。
        // 键盘弹起时输入栏上移到键盘上方,占位同步增加 keyboardHeight,避免最后一条消息被遮挡。
        // 代写候选面板出现时额外增加高度,避免面板遮挡最后一条消息。
        Blank().height(120 + this.navigationBarHeight + this.keyboardHeight
          + (this.impersonatePanelActive ? 150 : 0))
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: this.statusBarHeight + 12,
        bottom: 0
      })
      .onAreaChange(() => {
        this.onRequestAutoScroll();
      })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .height('100%')
    .onScrollEdge((side: Edge) => {
      if (side === Edge.Bottom) {
        this.onUserScrolledToBottom();
      }
    })
    .onScrollEnd(() => {
      if (this.scroller.isAtEnd()) {
        this.onUserScrolledToBottom();
      }
    })
  }

  /**
   * 重新生成按钮背景色:RGB 保持 surface_2 浅色/深色值,Alpha = bubbleOpacity。
   * light: #F0F1F4, dark: #3A3A3A
   */
  private computeRegenerateButtonColor(): string {
    const rgb: string = this.isDarkMode ? '3A3A3A' : 'F0F1F4';
    const clamped: number = Math.max(0, Math.min(255, Math.round(this.bubbleOpacity * 255)));
    const hex: string = clamped.toString(16).toUpperCase();
    const alphaHex: string = hex.length === 1 ? '0' + hex : hex;
    return '#' + alphaHex + rgb;
  }
}