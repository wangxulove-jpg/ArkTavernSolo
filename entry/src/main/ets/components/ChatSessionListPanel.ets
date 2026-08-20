/**
 * ChatSessionListPanel 会话列表面板
 *
 * T-4.5 Chat Session List MVP 的 UI 组件。
 * 以全屏覆盖层形式展示当前聊天上下文下的会话列表。
 *
 * 设计:
 * - 通过 @ObjectLink 引用 ChatViewModel(@Observed)
 * - 不直接访问 Repository / DbHelper / 网络
 * - 不持有 chatId 选择状态(由 ViewModel 持有)
 * - 删除前显示确认对话框(同组件内覆盖)
 *
 * 行为:
 * - 点击背景遮罩关闭面板
 * - 点击列表项切换会话
 * - 点击"新建对话"创建新会话
 * - 点击"删除"显示确认对话框
 * - 生成中或操作中按钮置灰
 *
 * UI-CHAT-01 颜色迁移:
 * - 所有字面量颜色迁移到 $r('app.color.*') 资源 Token
 * - 自动适配深色模式
 */

import { ChatViewModel } from '../viewmodels/ChatViewModel';
import { Chat } from '../models/Chat';
import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct ChatSessionListPanel {
  @ObjectLink viewModel: ChatViewModel;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  build() {
    Stack() {
      // 背景遮罩(点击关闭)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .onClick(() => {
          if (!this.viewModel.showDeleteSessionConfirm) {
            this.viewModel.closeSessionList();
          }
        })

      // 面板主体
      Column() {
        this.headerBar();
        this.contextBar();
        if (this.viewModel.sessionError.length > 0) {
          Text(this.viewModel.sessionError)
            .fontSize(12)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
        }
        Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).height(1).width('100%')

        if (this.viewModel.isLoadingSessions) {
          this.loadingState();
        } else if (this.viewModel.sessions.length === 0) {
          this.emptyState();
        } else {
          this.sessionList();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))

      // 删除确认对话框(覆盖在面板之上)
      if (this.viewModel.showDeleteSessionConfirm) {
        this.deleteConfirmDialog();
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  headerBar() {
    Row() {
      Text($r('app.string.tab_sessions'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))

      Blank()

      Button($r('app.string.tab_sessions_new_chat'))
        .fontSize(13)
        .backgroundColor(this.viewModel.canOperateSessions
          ? ThemePalette.accentColor(this.effectiveTheme)
          : ThemePalette.surface2Color(this.effectiveTheme))
        .fontColor(this.viewModel.canOperateSessions
          ? $r('app.color.app_on_accent')
          : ThemePalette.textTertiaryColor(this.effectiveTheme))
        .borderRadius(16)
        .height(36)
        .padding({ left: 12, right: 12 })
        .enabled(this.viewModel.canOperateSessions)
        .onClick(() => {
          this.viewModel.createNewSession();
        })

      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(16)
          .fontColor([ThemePalette.textSecondaryColor(this.effectiveTheme)])
      }
      .width(36)
      .height(36)
      .backgroundColor(Color.Transparent)
      .margin({ left: 4 })
      .onClick(() => {
        this.viewModel.closeSessionList();
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  contextBar() {
    Row() {
      Text('当前上下文:')
        .fontSize(12)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      Text(this.viewModel.characterName.length > 0
        ? this.viewModel.characterName
        : '普通聊天')
        .fontSize(12)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .margin({ left: 4 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  loadingState() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ThemePalette.textSecondaryColor(this.effectiveTheme))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyState() {
    Column() {
      Text('暂无会话')
        .fontSize(14)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ bottom: 16 })

      Button($r('app.string.tab_sessions_new_chat'))
        .fontSize(13)
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius(20)
        .height(36)
        .padding({ left: 20, right: 20 })
        .enabled(this.viewModel.canOperateSessions)
        .onClick(() => {
          this.viewModel.createNewSession();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  sessionList() {
    Scroll() {
      Column() {
        ForEach(this.viewModel.sessions, (chat: Chat, _index: number) => {
          this.sessionItem(chat)
        }, (chat: Chat) => chat.id + '_' + chat.updatedAt + '_' + chat.lastMessageAt)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 12 })
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  sessionItem(chat: Chat) {
    Row() {
      Column() {
        Text(this.viewModel.getSessionTitle(chat))
          .fontSize(15)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.viewModel.getSessionSubtitle(chat))
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 2 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.viewModel.isCurrentSession(chat.id)) {
        Text($r('app.string.chat_branch_current_badge'))
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .margin({ right: 8 })
      }

      Button($r('app.string.character_action_delete'))
        .fontSize(12)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_danger'))
        .height(32)
        .padding({ left: 8, right: 8 })
        .enabled(this.viewModel.canOperateSessions)
        .onClick(() => {
          this.viewModel.requestDeleteSession(chat.id);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius(12)
    .margin({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.viewModel.canOperateSessions) {
        this.viewModel.selectSession(chat.id);
      }
    })
  }

  @Builder
  deleteConfirmDialog() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.4)')
        .onClick(() => {
          this.viewModel.cancelDeleteSession();
        })

      Column() {
        Text('删除该会话及其中的全部消息?')
          .fontSize(15)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ bottom: 8 })
        Text('此操作无法撤销。')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ bottom: 20 })

        Row() {
          Button($r('app.string.chat_edit_message_cancel'))
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(20)
            .height(40)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => {
              this.viewModel.cancelDeleteSession();
            })

          Button($r('app.string.character_action_delete'))
            .fontSize(14)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius(20)
            .height(40)
            .layoutWeight(1)
            .enabled(this.viewModel.canOperateSessions)
            .onClick(() => {
              this.viewModel.confirmDeleteSession();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
