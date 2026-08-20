/**
 * ChatMoreMenuSheet 聊天页顶部更多菜单(底部弹出)
 *
 * 把模型、预设、分支、会话等次要入口收敛到这里,
 * 让顶部栏只保留:返回 + 角色名 + 更多按钮。
 *
 * 菜单项:
 * - 模型信息(只读显示)+ 前往模型设置
 * - 预设信息(只读显示)+ 前往预设列表
 * - 分支状态(只读显示)+ 查看分支图
 * - 会话列表
 * - 重新生成(底部 canRegenerate 时)
 * - 清空对话(危险操作,二次确认)
 *
 * 复用 ChatViewModel 数据,不在组件内做业务操作。
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct ChatMoreMenuSheet {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 是否显示 */
  visible: boolean = false;
  /** 当前角色名 */
  characterName: string = '';
  /** 当前模型名 */
  modelName: string = '';
  /** 当前预设名(空表示未启用) */
  presetName: string = '';
  /** 是否有可用模型 */
  hasModel: boolean = false;
  /** 分支状态文本 */
  branchStatusText: string = '';
  /** 是否可重新生成 */
  canRegenerate: boolean = false;
  /** 是否生成中 */
  isGenerating: boolean = false;
  /** 是否忙碌 */
  busy: boolean = false;
  /** 关闭回调 */
  onClose: () => void = () => {};
  /** 前往模型设置 */
  onGoModelSettings: () => void = () => {};
  /** 前往预设列表 */
  onGoPresetList: () => void = () => {};
  /** 查看分支图 */
  onGoBranchMap: () => void = () => {};
  /** 打开会话列表 */
  onOpenSessionList: () => void = () => {};
  /** 前往聊天背景设置 */
  onGoChatBackground: () => void = () => {};
  /** 前往对话记忆管理 */
  onGoMemory: () => void = () => {};
  /** 前往上下文管理 */
  onGoContextBudget: () => void = () => {};
  /** v9: 打开本对话称呼覆盖编辑(回调决定具体 UI 形式) */
  onEditUserNameOverride: () => void = () => {};
  /** 重新生成 */
  onRegenerate: () => void = () => {};
  /** 清空对话 */
  onClearChat: () => void = () => {};
  /** T-CHAT.1: 导出当前聊天 */
  onExportCurrentChat: () => void = () => {};
  /** T-CHAT.1: 导出该角色全部聊天 */
  onExportCharacterChats: () => void = () => {};

  /** v9: 当前对话级用户称呼覆盖(空表示跟随角色或全局) */
  @Prop userNameOverride: string = '';
  /** v9: 当前生效的用户称呼(用于在菜单展示) */
  @Prop resolvedUserName: string = '';
  /** T-CHAT.1: 当前对话 ID(用于导出,空表示未就绪) */
  @Prop currentConversationId: string = '';
  /** T-CHAT.1: 当前角色 ID(空表示无角色,隐藏"导出该角色全部聊天") */
  @Prop currentCharacterId: string = '';

  build() {
    if (this.visible) {
      Stack() {
        Column() {
          Blank().layoutWeight(1)
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
      Text('对话设置')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ top: 12, bottom: 8, left: 16, right: 16 })

      // 模型信息
      this.infoRow('模型', this.modelName.length > 0 ? this.modelName : '未配置', true, (): void => {
        this.onGoModelSettings();
      })

      // 预设
      this.infoRow('预设', this.presetName.length > 0 ? this.presetName : '未启用', true, (): void => {
        this.onGoPresetList();
      })

      // 分支
      if (this.branchStatusText.length > 0) {
        this.infoRow('分支', this.branchStatusText, !this.busy, (): void => {
          if (this.busy) {
            return;
          }
          this.onGoBranchMap();
        })
      }

      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

      // 会话列表
      this.menuRow('会话列表', false, false, (): void => {
        this.onOpenSessionList();
      })

      // 对话设置(背景 + 思考强度)
      this.menuRow('对话设置', this.busy, false, (): void => {
        if (this.busy) {
          return;
        }
        this.onGoChatBackground();
      })

      // 对话记忆(长期记忆摘要管理)
      this.menuRow('对话记忆', this.busy, false, (): void => {
        if (this.busy) {
          return;
        }
        this.onGoMemory();
      })

      // 上下文管理(预算设置 + 占用查看)
      this.menuRow('上下文管理', this.busy, false, (): void => {
        if (this.busy) {
          return;
        }
        this.onGoContextBudget();
      })

      // 本对话称呼(v9:对话级用户称呼覆盖)
      this.infoRow(
        '本对话称呼',
        this.resolvedUserName.length > 0 ? this.resolvedUserName : 'User',
        !this.busy,
        (): void => {
          if (this.busy) {
            return;
          }
          this.onEditUserNameOverride();
        }
      )

      // 重新生成
      if (this.canRegenerate) {
        this.menuRow('重新生成', this.isGenerating, false, (): void => {
          if (this.isGenerating) {
            return;
          }
          this.onRegenerate();
        })
      }

      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

      // T-CHAT.1: 导出当前聊天(对话就绪时显示)
      if (this.currentConversationId.length > 0) {
        this.menuRow('导出当前聊天', this.busy, false, (): void => {
          if (this.busy) {
            return;
          }
          this.onExportCurrentChat();
        })
      }

      // T-CHAT.1: 导出该角色全部聊天(有角色时显示)
      if (this.currentCharacterId.length > 0) {
        this.menuRow('导出该角色全部聊天', this.busy, false, (): void => {
          if (this.busy) {
            return;
          }
          this.onExportCharacterChats();
        })
      }

      // 清空对话
      this.menuRow('清空对话', this.busy, true, (): void => {
        this.onClearChat();
      })
    }
    .width('100%')
  }

  @Builder
  infoRow(label: string, value: string, enabled: boolean, onClick: () => void) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width(56)
      Text(value)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(enabled
          ? ThemePalette.textPrimaryColor(this.effectiveTheme)
          : ThemePalette.textTertiaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('›')
        .fontSize(20)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (!enabled) {
        return;
      }
      onClick();
      this.onClose();
    })
  }

  @Builder
  menuRow(label: string, disabled: boolean, isDestructive: boolean, onClick: () => void) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(isDestructive
          ? (disabled ? ThemePalette.textTertiaryColor(this.effectiveTheme) : $r('app.color.app_danger'))
          : (disabled ? ThemePalette.textTertiaryColor(this.effectiveTheme) : ThemePalette.textPrimaryColor(this.effectiveTheme)))
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (disabled) {
        return;
      }
      onClick();
    })
  }
}
