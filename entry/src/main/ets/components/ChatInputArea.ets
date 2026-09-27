/**
 * 聊天输入区(自 ChatPage.inputArea + sendStopButton 抽取,纯搬运,行为不变)。
 *
 * 设计:组件不持有 VM/服务,依赖全部经 @Prop 值 + @Link + 回调上抛:
 * - 渲染态:inputText / canSend / canStop / showAiActions / isSendButtonOnLeft
 * - 旁白模式:narratorModeActive(@Link 双向,切换按钮直接翻转)
 * - 代写候选:impersonateCandidates / isImpersonateGenerating(候选区渲染在胶囊内部顶部,
 *   与输入栏共用同一模糊底,视觉上连成一块,不再另起一张描边卡片)
 * - 业务动作:全部回调上抛,由页面执行(viewModel 调用、预算校验、发送)
 */
import { ThemePalette } from '../theme/ThemePalette';
import { ImpersonateCandidate } from '../models/ImpersonateCandidate';
import { ImpersonateCandidatesPanel } from './ImpersonateCandidatesPanel';

@Component
export struct ChatInputArea {
  /** 当前主题 */
  @Prop effectiveTheme: string = 'dark';
  /** 输入框文本(来自 viewModel.inputText) */
  @Prop inputText: string = '';
  /** 是否可发送(按钮配色/可用性渲染态) */
  @Prop canSend: boolean = false;
  /** 是否可停止(显示停止按钮) */
  @Prop canStop: boolean = false;
  /** 是否显示 AI 操作行(代写/续写/旁白;页面空闲且 VM 就绪) */
  @Prop showAiActions: boolean = false;
  /** 发送/停止按钮是否在左侧(用户偏好) */
  @Prop isSendButtonOnLeft: boolean = false;
  /** 代写候选列表(非空或生成中时,胶囊顶部展开候选区) */
  @Prop impersonateCandidates: ImpersonateCandidate[] = [];
  /** 代写候选是否生成中 */
  @Prop isImpersonateGenerating: boolean = false;
  /** 旁白模式(双向:切换按钮与发送后复位) */
  @Link narratorModeActive: boolean;

  /** 输入内容变化 */
  onInputChange: (value: string) => void = (_: string) => {};
  /** 代写(页面完成 busy 校验) */
  onImpersonate: () => void = () => {};
  /** 续写(页面完成 busy 校验) */
  onAutoContinue: () => void = () => {};
  /** 选中某条代写候选(页面完成 busy 校验) */
  onSelectImpersonateCandidate: (index: number) => void = (_: number) => {};
  /** 关闭代写候选区 */
  onDismissImpersonateCandidates: () => void = () => {};
  /** 请求发送(提交/回车/发送按钮共用,含预算校验与旁白分支) */
  onSendRequest: () => void = () => {};
  /** 仅发旁白(旁白行 📝 按钮;无预算校验,与原逻辑一致) */
  onSendNarratorOnly: () => void = () => {};
  /** 旁白+回复(旁白行 🎬 按钮;含预算校验) */
  onSendNarrator: () => void = () => {};
  /** 停止生成 */
  onStop: () => void = () => {};
  /** 键盘 Enter 预处理(页面处理 Ctrl 判定/预算/发送,返回是否消费) */
  onKeyPreImeEvent: (event: KeyEvent) => boolean = (_: KeyEvent) => false;

  build() {
    Column() {
      // 代写候选区(与输入胶囊同底,顶部展开;与下方操作行用一条 0.5 分隔线区隔)
      if (this.impersonateCandidates.length > 0 || this.isImpersonateGenerating) {
        ImpersonateCandidatesPanel({
          candidates: this.impersonateCandidates,
          isGenerating: this.isImpersonateGenerating,
          onSelect: (index: number): void => {
            this.onSelectImpersonateCandidate(index);
          },
          onDismiss: (): void => {
            this.onDismissImpersonateCandidates();
          }
        })

        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12, bottom: 2 })
      }

      // AI 操作按钮行(仅空闲时显示)
      if (this.showAiActions) {
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
            this.onImpersonate();
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
            this.onAutoContinue();
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
      if (this.isSendButtonOnLeft) {
        this.sendStopButton()
      }

      TextArea({
        placeholder: this.narratorModeActive ? '输入旁白叙述…' : $r('app.string.chat_input_placeholder'),
        text: this.inputText
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
          this.onInputChange(value);
        })
        .onSubmit((enterKey: EnterKeyType, event?: SubmitEvent) => {
          this.onSendRequest();
          event?.keepEditableState();
        })
        .onKeyPreIme((event: KeyEvent): boolean => {
          return this.onKeyPreImeEvent(event);
        })

      if (!this.isSendButtonOnLeft) {
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

  /**
   * 发送/停止按钮(同一槽位,if 分支切换时按形变过渡交叉淡入)。
   * 停止态刻意用低对比配色:描边圆钮 + 中性色方块,避免高饱和红色在暗色主题里过于跳。
   */
  @Builder
  sendStopButton() {
    if (this.canStop) {
      Stack() {
        Column()
          .width(11)
          .height(11)
          .borderRadius(2.5)
          .backgroundColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      }
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
      .borderRadius(20)
      .height(40)
      .width(40)
      .margin({ left: 2, right: 2 })
      .transition(
        TransitionEffect.OPACITY
          .animation({ duration: 180, curve: Curve.EaseOut })
          .combine(TransitionEffect.scale({ x: 0.85, y: 0.85 }))
      )
      .onClick(() => {
        this.onStop();
      })
    } else if (this.narratorModeActive) {
      Row() {
        Stack() {
          Text('📝')
            .fontSize(14)
        }
        .backgroundColor(this.canSend
          ? ThemePalette.surface2Color(this.effectiveTheme)
          : Color.Transparent)
        .borderRadius(20)
        .height(36)
        .width(36)
        .margin({ left: 1, right: 1 })
        .onClick(() => {
          this.onSendNarratorOnly();
        })
        Stack() {
          Text('🎬')
            .fontSize(14)
        }
        .backgroundColor(this.canSend
          ? ThemePalette.accentColor(this.effectiveTheme)
          : Color.Transparent)
        .borderRadius(20)
        .height(36)
        .width(36)
        .margin({ left: 1, right: 1 })
        .onClick(() => {
          this.onSendNarrator();
        })
      }
    } else {
      Stack() {
        SymbolGlyph($r('sys.symbol.arrow_up'))
          .fontSize(16)
          .fontColor([
            this.canSend
              ? $r('app.color.app_on_accent')
              : ThemePalette.textTertiaryColor(this.effectiveTheme)
          ])
      }
      .backgroundColor(this.canSend
        ? ThemePalette.accentColor(this.effectiveTheme)
        : Color.Transparent)
      .borderRadius(20)
      .height(40)
      .width(40)
      .margin({ left: 2, right: 2 })
      .transition(
        TransitionEffect.OPACITY
          .animation({ duration: 180, curve: Curve.EaseOut })
          .combine(TransitionEffect.scale({ x: 0.85, y: 0.85 }))
      )
      .onClick(() => {
        this.onSendRequest();
      })
    }
  }
}
