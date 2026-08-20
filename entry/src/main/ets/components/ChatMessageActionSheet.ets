/**
 * ChatMessageActionSheet 消息操作菜单(底部)
 *
 * 长按消息后弹出,根据消息类型显示不同操作:
 * - User:复制 / 编辑 / 从此处生成新回复
 * - Assistant:复制 / 重新生成 / 从此处继续 / 切换分支(候选)
 *
 * 复用 ChatViewModel 的 canXxx 能力判定(由 ChatPage 传入),不在组件内做业务判定。
 * 点击操作后通过 onAction 回调返回 action 字符串,由 ChatPage 执行实际逻辑。
 *
 * 不依赖:
 * - ChatViewModel(由父组件传入数据 + 回调)
 * - 网络/数据库
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { ThemePalette } from '../theme/ThemePalette';

/** 操作类型 */
export type MessageAction =
  | 'copy'
  | 'edit'
  | 'generate_from_user'
  | 'regenerate_assistant'
  | 'continue_from_here'
  | 'switch_branch'
  | 'fork_chat';

/** 操作项 */
interface ActionItem {
  readonly action: MessageAction;
  readonly label: string;
  readonly enabled: boolean;
  readonly isDestructive: boolean;
}

@Component
export struct ChatMessageActionSheet {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 是否显示 */
  visible: boolean = false;
  /** 目标消息 */
  msg: ChatMessage | null = null;
  /** 是否可编辑(User) */
  canEdit: boolean = false;
  /** 是否可从此处生成新回复(User) */
  canGenerateFromUser: boolean = false;
  /** 是否可重新生成(Assistant) */
  canRegenerate: boolean = false;
  /** 是否可从此处继续(Assistant) */
  canContinue: boolean = false;
  /** 候选数(>1 时显示切换分支) */
  candidateCount: number = 1;
  /** 是否可从此处创建独立对话 */
  canForkChat: boolean = false;
  /** 关闭回调 */
  onClose: () => void = () => {};
  /** 操作点击回调 */
  onAction: (action: MessageAction) => void = (_: MessageAction) => {};

  build() {
    if (this.visible && this.msg !== null) {
      Stack() {
        // 遮罩层
        Column() {
          Blank().layoutWeight(1)
          // 操作面板
          Column() {
            this.sheetContent()
          }
          .width('100%')
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius({
            topLeft: 16, topRight: 16,
            bottomLeft: 0, bottomRight: 0
          })
          .padding({ top: 8, bottom: 24 })
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.5)')
      .onClick(() => {
        this.onClose();
      })
      .transition(TransitionEffect.OPACITY)
    }
  }

  @Builder
  sheetContent() {
    Column() {
      // 标题
      Text(this.getTitle())
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ bottom: 8, top: 8 })

      // 操作列表
      ForEach(this.buildActions(), (item: ActionItem) => {
        this.actionRow(item)
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
  }

  @Builder
  actionRow(item: ActionItem) {
    Row() {
      Text(item.label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(item.isDestructive
          ? $r('app.color.app_danger')
          : (item.enabled
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textTertiaryColor(this.effectiveTheme)))
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (!item.enabled) {
        return;
      }
      this.onAction(item.action);
      this.onClose();
    })
  }

  /** 构建操作列表 */
  private buildActions(): ActionItem[] {
    if (this.msg === null) {
      return [];
    }
    const items: ActionItem[] = [];
    if (this.msg.role === ChatRole.User) {
      items.push({ action: 'copy', label: '复制', enabled: true, isDestructive: false });
      if (this.canEdit) {
        items.push({ action: 'edit', label: '编辑', enabled: true, isDestructive: false });
      }
      if (this.canGenerateFromUser) {
        items.push({ action: 'generate_from_user', label: '从此处生成新回复', enabled: true, isDestructive: false });
      }
      if (this.canForkChat) {
        items.push({ action: 'fork_chat', label: '从此处创建独立对话', enabled: true, isDestructive: false });
      }
    } else if (this.msg.role === ChatRole.Assistant) {
      items.push({ action: 'copy', label: '复制', enabled: true, isDestructive: false });
      if (this.candidateCount > 1) {
        items.push({ action: 'switch_branch', label: '切换候选', enabled: true, isDestructive: false });
      }
      if (this.canContinue) {
        items.push({ action: 'continue_from_here', label: '从此处继续', enabled: true, isDestructive: false });
      }
      if (this.canRegenerate) {
        items.push({ action: 'regenerate_assistant', label: '重新生成', enabled: true, isDestructive: false });
      }
      if (this.canForkChat) {
        items.push({ action: 'fork_chat', label: '从此处创建独立对话', enabled: true, isDestructive: false });
      }
    }
    return items;
  }

  /** 菜单标题 */
  private getTitle(): string {
    if (this.msg === null) {
      return '';
    }
    if (this.msg.role === ChatRole.User) {
      return '用户消息';
    }
    return '角色回复';
  }
}
