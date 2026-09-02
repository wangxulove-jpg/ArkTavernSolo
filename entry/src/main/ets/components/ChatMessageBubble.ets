import { Logger } from '../utils/Logger';
/**
 * ChatMessageBubble 聊天消息气泡
 *
 * 统一渲染 User / Assistant / System 三种消息:
 * - User:右对齐,accent 背景,on_accent 文字,右下角小圆角
 * - Assistant:左对齐,头像 + surface_1 背景,左下角小圆角
 * - System:居中,tertiary 文字,无气泡背景
 *
 * 设计:
 * - 颜色全部使用 $r('app.color.*') 资源,自动适配深色模式
 * - 长按触发 onLongPress 回调(由 ChatPage 打开消息操作菜单)
 * - 点击 Assistant 头像触发 onAvatarClick(可选)
 * - 分支切换控件由父组件 ChatPage 在气泡外渲染(MessageSwipeControls)
 *
 * 状态管理(单角色聊天稳定渲染):
 * - @ObjectLink renderState: ChatMessageRenderState,@Observed 字段赋值即触发重建
 * - ForEach key 固定为 renderState.messageId,组件实例可被复用
 * - 业务层 ChatMessage 不可变更新后,ChatPage 同步调用 renderState.applyMessage,
 *   本气泡无需重建实例即可看到最新 content/isStreaming/status
 * - 直接读取 renderState.content / renderState.isStreaming / renderState.status / renderState.role
 * - 不使用 TypingState 中间层、不打字机定时器、不缓存 displayedContent
 * - 流式光标根据 renderState.isStreaming && renderState.content.length > 0 显示
 * - "思考中"提示根据 renderState.isStreaming && renderState.content.length === 0 显示
 *
 * 不依赖:
 * - ChatViewModel(只接收展示数据 + 回调)
 * - 网络/数据库/服务
 */

import { ChatMessage, ChatMessageStatus, MessageSenderType } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { CharacterImageView } from './CharacterImageView';
import { ChatRichText, ChatSenderType } from './ChatRichText';
import { ChatTextStyle } from '../utils/ChatTextStyleSettings';
import { ChatMarkdownColorTheme } from '../utils/ChatTextColorTheme';
import { ChatMessageRenderState } from '../models/ChatMessageRenderState';
import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct ChatMessageBubble {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 稳定渲染状态(@ObjectLink 单向同步,字段赋值触发本组件重建) */
  @ObjectLink renderState: ChatMessageRenderState;
  /** 角色头像 URI(无角色时为空,显示占位) */
  characterAvatarUri: string = '';
  /** 角色名称(用于头像占位首字) */
  characterName: string = '';
  /** 是否显示 Assistant 头像(空会话开场白也用此组件时不显示) */
  showAvatar: boolean = true;
  /** 点击气泡内的分支选项/交互按钮时,把选项文本回调给上层发送给 AI */
  onInteractiveAction?: (text: string) => void;
  /** 长按消息回调 */
  onLongPress?: (msg: ChatMessage) => void;
  /** 点击 Assistant 头像回调(可选) */
  onAvatarClick?: () => void;
  /** TTS 朗读回调(可选) */
  onTtsPlay?: () => void;
  /** 重新生成回调(可选) */
  onRegenerate?: () => void;

  /** 聊天文本样式设置(v11 富文本,@Prop 确保父组件样式变化时同步) */
  @Prop settings: ChatTextStyle | null = null;
  /** 发送者角色 ID(用于角色独立颜色) */
  senderCharacterId: string = '';
  /**
   * 字体颜色主题(null 表示 AUTO 模式,使用默认资源颜色)。
   * 非 null 时覆盖 ChatRichText 的片段颜色查询,
   * 不改变解析行为、节点结构、字体粗细、链接行为或换行逻辑。
   * 与 bubbleOpacity 完全独立:主题只控制文字颜色,bubbleOpacity 只控制气泡背景 Alpha。
   *
   * @Prop 确保父组件 ChatPage 的 colorTheme 变化时同步到本组件,
   * 进而传递给 ChatRichText 触发 @Watch('onThemeChange') 重新解析。
   * 未加装饰器时只在组件首次创建时接收初值,后续切换 AUTO/LIGHT/DARK/CUSTOM
   * 或自定义颜色变化均无法同步,导致聊天界面文字颜色不更新。
   */
  @Prop colorTheme: ChatMarkdownColorTheme | null = null;
  /** 气泡背景不透明度(0.40~0.90,仅控制背景 Alpha,不影响文字/头像/按钮) */
  @Prop bubbleOpacity: number = 1.0;
  /** 当前是否为深色模式(用于动态计算气泡背景 RGB) */
  @Prop isDarkMode: boolean = false;

  /**
   * 将 Alpha(0~1) 转为两位 16 进制字符串(大写)。
   * clamp 到 [0, 255] 后取整。
   */
  private alphaToHex(alpha: number): string {
    const clamped: number = Math.max(0, Math.min(255, Math.round(alpha * 255)));
    const hex: string = clamped.toString(16).toUpperCase();
    return hex.length === 1 ? '0' + hex : hex;
  }

  /**
   * 助手气泡背景色:RGB 保持资源浅色/深色值,Alpha = bubbleOpacity。
   * light: #FFFFFF, dark: #2A2A2A
   */
  private computeAssistantBubbleColor(): string {
    const rgb: string = this.isDarkMode ? '2A2A2A' : 'FFFFFF';
    return '#' + this.alphaToHex(this.bubbleOpacity) + rgb;
  }

  /**
   * 用户气泡背景色:RGB 保持品牌蓝,Alpha = min(bubbleOpacity + 0.08, 0.95)。
   * light: #5B7CFA, dark: #7B9BFF
   */
  private computeUserBubbleColor(): string {
    const rgb: string = this.isDarkMode ? '7B9BFF' : '5B7CFA';
    const alpha: number = Math.min(this.bubbleOpacity + 0.08, 0.95);
    return '#' + this.alphaToHex(alpha) + rgb;
  }

  /**
   * 重新生成按钮背景色:复用助手气泡 RGB,Alpha = bubbleOpacity。
   * 用于失败重试按钮的半透明背景。
   */
  private computeRegenerateButtonColor(): string {
    const rgb: string = this.isDarkMode ? '3A3A3A' : 'F0F1F4';
    return '#' + this.alphaToHex(this.bubbleOpacity) + rgb;
  }

  build() {
    Column() {
      if (this.renderState.senderType === 'narrator') {
        this.narratorBubble()
      } else if (this.renderState.role === ChatRole.System) {
        this.systemBubble()
      } else if (this.renderState.role === ChatRole.User) {
        this.userBubble()
      } else {
        this.assistantBubble()
      }
    }
    .width('100%')
  }

  aboutToUpdate(): void {
    // 关键不变量检查:状态/流式标志互斥校验,异常时记录便于回归
    const s: ChatMessageStatus = this.renderState.status;
    const isStreaming: boolean = this.renderState.isStreaming;
    if ((s === ChatMessageStatus.Failed || s === ChatMessageStatus.Completed || s === ChatMessageStatus.Cancelled)
      && isStreaming) {
      Logger.warn(`[Bubble] inconsistency mid=${this.renderState.messageId.slice(0,8)} status=${String(s)} isStreaming=true`);
    }
  }

  /** 系统消息:居中、tertiary 文字、无气泡背景 */
  @Builder
  systemBubble() {
    Row() {
      Column() {
        ChatRichText({
          content: this.renderState.displayContent,
          senderType: 'system' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: false,
          settings: this.settings,
          colorTheme: this.colorTheme,
          selectable: true,
          onInteractiveAction: this.onInteractiveAction
        })
      }
      .constraintSize({ maxWidth: '80%' })
      .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .margin({ top: 4, bottom: 4 })
  }

  /** User 消息:右对齐,accent 背景(头像在气泡上方) */
  @Builder
  userBubble() {
    Column() {
      // 气泡
      Column() {
        ChatRichText({
          content: this.renderState.displayContent.length > 0 ? this.renderState.displayContent : ' ',
          senderType: 'user' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: false,
          settings: this.settings,
          colorTheme: this.colorTheme,
          selectable: true,
          onInteractiveAction: this.onInteractiveAction
        })
      }
      .constraintSize({ maxWidth: '88%' })
      .backgroundColor(this.computeUserBubbleColor())
      .border({
        width: $r('app.float.chat_bubble_border_width'),
        color: $r('app.color.chat_user_border')
      })
      .borderRadius({
        topLeft: 16, topRight: 16,
        bottomLeft: 16, bottomRight: 6
      })
      .padding({
        left: $r('app.float.chat_bubble_padding_h'),
        right: $r('app.float.chat_bubble_padding_h'),
        top: $r('app.float.chat_bubble_padding_v'),
        bottom: $r('app.float.chat_bubble_padding_v')
      })
      .gesture(
        LongPressGesture()
          .onAction(() => {
            if (this.onLongPress !== undefined) {
              this.onLongPress!(this.renderState.message);
            }
          })
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
    .margin({ top: 8, bottom: 8 })
  }

  /** Assistant 消息:头像在气泡上方 + 左对齐气泡 */
  @Builder
  assistantBubble() {
    Column() {
      // 头像(可选,空会话等场景不显示)
      if (this.showAvatar) {
        CharacterImageView({
          imageUri: this.characterAvatarUri,
          fallbackName: this.characterName,
          imgWidth: 32,
          imgHeight: 32,
          imgBorderRadius: 16,
          displayMode: 'thumbnail',
          objectFit: ImageFit.Cover
        })
          .onClick(() => {
            if (this.onAvatarClick !== undefined) {
              this.onAvatarClick!();
            }
          })
          .margin({ bottom: 6 })
      }

      // 气泡
      Column() {
        // 正文内容(content.length > 0 时显示)
        if (this.renderState.displayContent.length > 0) {
          ChatRichText({
            content: this.renderState.displayContent,
            senderType: 'assistant' as ChatSenderType,
            senderCharacterId: this.senderCharacterId,
            isStreaming: this.renderState.isStreaming,
            settings: this.settings,
            colorTheme: this.colorTheme,
            selectable: true,
            onInteractiveAction: this.onInteractiveAction
          })
        }

        // 流式光标:流式中且已有正文
        if (this.renderState.isStreaming && this.renderState.content.length > 0) {
          Text('▍')
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .margin({ top: 2 })
        }

        // "思考中"提示:流式中但还没收到任何内容(首字延迟阶段)
        if (this.renderState.isStreaming && this.renderState.content.length === 0) {
          Row() {
            Text('思考中')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .fontStyle(FontStyle.Italic)
            Text('...')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .margin({ left: 2 })
          }
          .margin({ top: 2 })
        }

        // 已停止状态(带背景小标签)
        if (this.renderState.status === ChatMessageStatus.Cancelled) {
          Row() {
            Text('■ 已停止')
              .fontSize(11)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.chat_status_stopped_bg'))
          .borderRadius(8)
          .margin({ top: 6 })
        }

        // 失败状态(带背景小标签)
        if (this.renderState.status === ChatMessageStatus.Failed) {
          Row() {
            Text(this.renderState.content.length === 0 ? '⚠ 未收到回复,请重试' : '⚠ 生成失败')
              .fontSize(11)
              .fontColor($r('app.color.app_danger'))
          }
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor($r('app.color.chat_status_failed_bg'))
          .borderRadius(8)
          .margin({ top: 6 })
        }

        // 操作按钮行:已完成或已停止时显示 TTS + 重新生成
        if ((this.renderState.status === ChatMessageStatus.Completed
          || this.renderState.status === ChatMessageStatus.Cancelled)
          && !this.renderState.isStreaming) {
          Row() {
            if (this.onTtsPlay !== undefined) {
              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.speaker_wave_2'))
                  .fontSize(14)
                  .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
              }
              .backgroundColor(Color.Transparent)
              .width(28)
              .height(28)
              .borderRadius(14)
              .padding(0)
              .onClick(() => {
                this.onTtsPlay?.();
              })
            }
            if (this.onRegenerate !== undefined) {
              Button({ type: ButtonType.Normal }) {
                SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                  .fontSize(14)
                  .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
              }
              .backgroundColor(Color.Transparent)
              .width(28)
              .height(28)
              .borderRadius(14)
              .padding(0)
              .margin({ left: 4 })
              .onClick(() => {
                this.onRegenerate?.();
              })
            }
          }
          .margin({ top: 6 })
        }


      }
      .backgroundColor(this.computeAssistantBubbleColor())
      .border({
        width: $r('app.float.chat_bubble_border_width'),
        color: $r('app.color.chat_assistant_border')
      })
      .borderRadius({
        topLeft: 6, topRight: 16,
        bottomLeft: 16, bottomRight: 16
      })
      .padding({
        left: $r('app.float.chat_bubble_padding_h'),
        right: $r('app.float.chat_bubble_padding_h'),
        top: $r('app.float.chat_bubble_padding_v'),
        bottom: $r('app.float.chat_bubble_padding_v')
      })
      .constraintSize({ maxWidth: '94%' })
      .alignItems(HorizontalAlign.Start)
      // 微阴影:让 Assistant 气泡在浅色背景上有浮起感
      .shadow({
        radius: 6,
        color: $r('app.color.chat_assistant_shadow'),
        offsetX: 0,
        offsetY: 2
      })
      .gesture(
        LongPressGesture()
          .onAction(() => {
            if (this.onLongPress !== undefined) {
              this.onLongPress!(this.renderState.message);
            }
          })
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8, bottom: 8 })
  }

  /** 旁白消息:居中、斜体、灰色调、无头像、装饰线 */
  @Builder
  narratorBubble() {
    Column() {
      Row() {
        Row()
          .width(24)
          .height(1)
          .backgroundColor('#80808040')
        Text('NARRATOR')
          .fontSize(9)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .letterSpacing(1.5)
          .margin({ left: 8, right: 8 })
        Row()
          .width(24)
          .height(1)
          .backgroundColor('#80808040')
      }
      .justifyContent(FlexAlign.Center)
      .margin({ bottom: 4 })

      Column() {
        ChatRichText({
          content: this.renderState.displayContent,
          senderType: 'narrator' as ChatSenderType,
          senderCharacterId: '',
          isStreaming: this.renderState.isStreaming,
          settings: this.settings,
          colorTheme: this.colorTheme,
          selectable: true,
          onInteractiveAction: this.onInteractiveAction
        })
      }
      .constraintSize({ maxWidth: '80%' })
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#20808080')
      .borderRadius(8)
      .gesture(
        LongPressGesture()
          .onAction(() => {
            if (this.onLongPress !== undefined) {
              this.onLongPress!(this.renderState.message);
            }
          })
      )
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 6, bottom: 6 })
  }

}
