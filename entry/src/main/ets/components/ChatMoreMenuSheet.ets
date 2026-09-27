/**
 * ChatMoreMenuSheet 聊天页顶部更多菜单(底部弹出)
 *
 * 把模型、预设、分支、会话等次要入口收敛到这里,
 * 让顶部栏只保留:返回 + 角色名 + 更多按钮。
 *
 * 布局(v2,2026-09-27):
 * - 按职责分组,每组一个分区小标题 + 一张卡片(卡内用 1px 分隔线);
 * - 行高 52 → 44,标签宽度不再写死(此前固定 56 导致"记忆模式""本对话称呼"折成两行);
 * - 标签统一精简到 ≤6 字,配合 maxLines(1) 保证永不折行;
 * - 危险操作(清空对话)单独成区,不做成普通行的近邻。
 *
 * 复用 ChatViewModel 数据,不在组件内做业务操作。
 */

import { ThemePalette } from '../theme/ThemePalette';

@Component
export struct ChatMoreMenuSheet {
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 是否显示(由 ChatPage 外层 if 挂载驱动) */
  visible: boolean = false;
  /** bindSheet 显示开关(组件挂载后置真,驱动底部滑出动画) */
  @State isShow: boolean = false;
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
  /** 前往聊天背景设置 */
  onGoChatBackground: () => void = () => {};
  /** 前往对话记忆管理 */
  onGoMemory: () => void = () => {};
  /** v50: 打开记忆模式选择(手动总结/自动归档 + 章节注入数) */
  onEditMemoryMode: () => void = () => {};
  /** 前往上下文管理 */
  onGoContextBudget: () => void = () => {};
  /** 前往续写/代写引导设置 */
  onGoAutoWriteGuide: () => void = () => {};
  /** v9: 打开本对话称呼覆盖编辑(回调决定具体 UI 形式) */
  onEditUserNameOverride: () => void = () => {};
  /** 切换用户身份(打开 Persona 选择) */
  onSwitchPersona: () => void = () => {};
  /** v42: 新建章节(世界分组内切换开场白) */
  onNewChapter: () => void = () => {};
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
  /** 当前生效的身份名称(空表示未启用) */
  @Prop resolvedPersonaName: string = '';
  /** T-CHAT.1: 当前对话 ID(用于导出,空表示未就绪) */
  @Prop currentConversationId: string = '';
  /** T-CHAT.1: 当前角色 ID(空表示无角色,隐藏"导出该角色全部聊天") */
  @Prop currentCharacterId: string = '';
  /** v50: 当前会话记忆模式显示文本(手动总结/自动归档) */
  @Prop memoryModeText: string = '手动总结';

  aboutToAppear(): void {
    // 组件挂载(chatPage 外层 if 为真)时触发 bindSheet 向上滑出
    this.isShow = true;
  }

  build() {
    Column()
      .width('100%')
      .height(0)
      .backgroundColor(Color.Transparent)
      .bindSheet(this.isShow, this.sheetContent(), {
        height: SheetSize.FIT_CONTENT,
        dragBar: false,
        showClose: false,
        backgroundColor: ThemePalette.surface1Color(this.effectiveTheme),
        onDisappear: () => {
          this.isShow = false;
          this.onClose();
        }
      })
  }

  @Builder
  sheetContent() {
    Column() {
      Text('对话设置')
        .fontSize($r('app.float.app_font_title'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 4, top: 8, bottom: 2 })

      // ===== 模型与预设 =====
      this.sectionCaption('模型与预设')
      Column() {
        this.valueRow('模型', this.modelName.length > 0 ? this.modelName : '未配置', true, false, (): void => {
          this.onGoModelSettings();
        })
        this.valueRow('预设', this.presetName.length > 0 ? this.presetName : '未启用', true, true, (): void => {
          this.onGoPresetList();
        })
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))

      // ===== 分支 =====
      if (this.branchStatusText.length > 0) {
        this.sectionCaption('分支')
        Column() {
          this.valueRow('分支', this.branchStatusText, !this.busy, false, (): void => {
            if (this.busy) {
              return;
            }
            this.onGoBranchMap();
          })
        }
        .width('100%')
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
      }

      // ===== 对话 =====
      this.sectionCaption('对话')
      Column() {
        this.menuRowInCard('对话设置', this.busy, false, false, (): void => {
          if (this.busy) {
            return;
          }
          this.onGoChatBackground();
          this.onClose();
        })
        this.menuRowInCard('对话记忆', this.busy, false, true, (): void => {
          if (this.busy) {
            return;
          }
          this.onGoMemory();
          this.onClose();
        })
        this.valueRow('记忆模式', this.memoryModeText, !this.busy, true, (): void => {
          if (this.busy) {
            return;
          }
          this.onEditMemoryMode();
        })
        this.menuRowInCard('上下文管理', this.busy, false, true, (): void => {
          if (this.busy) {
            return;
          }
          this.onGoContextBudget();
          this.onClose();
        })
        this.menuRowInCard('续写/代写引导', this.busy, false, true, (): void => {
          if (this.busy) {
            return;
          }
          this.onGoAutoWriteGuide();
          this.onClose();
        })
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))

      // ===== 身份 =====
      this.sectionCaption('身份')
      Column() {
        this.valueRow(
          '对话称呼',
          this.resolvedUserName.length > 0 ? this.resolvedUserName : 'User',
          !this.busy,
          false,
          (): void => {
            if (this.busy) {
              return;
            }
            this.onEditUserNameOverride();
          }
        )
        this.valueRow(
          '用户身份',
          this.resolvedPersonaName.length > 0 ? this.resolvedPersonaName : '未设置',
          !this.busy,
          true,
          (): void => {
            if (this.busy) {
              return;
            }
            this.onSwitchPersona();
          }
        )
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))

      // ===== 会话(全部门槛行都不可用时整组隐藏) =====
      if (this.characterName.length > 0 || this.canRegenerate
        || this.currentConversationId.length > 0 || this.currentCharacterId.length > 0) {
        this.sectionCaption('会话')
        Column() {
          if (this.characterName.length > 0) {
            this.menuRowInCard('新建章节', this.busy, false, false, (): void => {
              if (this.busy) {
                return;
              }
              this.onNewChapter();
              this.onClose();
            })
          }
          if (this.canRegenerate) {
            this.menuRowInCard('重新生成', this.isGenerating, false,
              this.characterName.length > 0, (): void => {
                if (this.isGenerating) {
                  return;
                }
                this.onRegenerate();
              })
          }
          if (this.currentConversationId.length > 0) {
            this.menuRowInCard('导出当前聊天', this.busy, false,
              this.characterName.length > 0 || this.canRegenerate, (): void => {
                if (this.busy) {
                  return;
                }
                this.onExportCurrentChat();
              })
          }
          if (this.currentCharacterId.length > 0) {
            this.menuRowInCard('导出全部聊天', this.busy, false,
              this.characterName.length > 0 || this.canRegenerate
                || this.currentConversationId.length > 0, (): void => {
                if (this.busy) {
                  return;
                }
                this.onExportCharacterChats();
              })
          }
        }
        .width('100%')
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
      }

      // ===== 危险区 =====
      this.sectionCaption('危险区')
      Column() {
        this.menuRowInCard('清空对话', this.busy, true, false, (): void => {
          this.onClearChat();
        })
      }
      .width('100%')
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_md'))
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 8 })
  }

  /** 分区小标题(与行内文字左对齐:卡片内边距 12 + 分组标题内边距 4) */
  @Builder
  sectionCaption(text: string) {
    Text(text)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      .width('100%')
      .padding({ left: 4, top: 14, bottom: 6 })
  }

  /**
   * 值行:标签自适应宽度(不折行) + 右对齐值 + 箭头。
   * @param showDivider 是否在行顶画分隔线(卡片内非首行传 true)
   */
  @Builder
  valueRow(label: string, value: string, enabled: boolean, showDivider: boolean, onClick: () => void) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12 })
      }
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(value)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(enabled
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textTertiaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .layoutWeight(1)
          .margin({ left: 12 })
        Text('›')
          .fontSize(18)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ left: 4 })
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      if (!enabled) {
        return;
      }
      onClick();
      this.onClose();
    })
  }

  /**
   * 卡片内菜单行(无值列,可危险色)。
   * @param showDivider 是否在行顶画分隔线(卡片内非首行传 true)
   */
  @Builder
  menuRowInCard(label: string, disabled: boolean, isDestructive: boolean,
    showDivider: boolean, onClick: () => void) {
    Column() {
      if (showDivider) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .margin({ left: 12, right: 12 })
      }
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(isDestructive
            ? (disabled ? ThemePalette.textTertiaryColor(this.effectiveTheme) : $r('app.color.app_danger'))
            : (disabled
              ? ThemePalette.textTertiaryColor(this.effectiveTheme)
              : ThemePalette.textPrimaryColor(this.effectiveTheme)))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .onClick(() => {
      if (disabled) {
        return;
      }
      onClick();
    })
  }
}
