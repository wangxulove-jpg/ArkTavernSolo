/**
 * ChatSessionListPanel 会话列表面板
 *
 * T-4.5 Chat Session List MVP 的 UI 组件。
 * 以全屏覆盖层形式展示当前聊天上下文下的会话列表。
 *
 * 设计(组件不持有 VM/服务,依赖全部经 @Prop 值 + 回调上抛):
 * - 数据:@Prop sessions / worldGroups / characterName / sessionError /
 *   isLoadingSessions / canOperateSessions / showDeleteSessionConfirm
 * - 查询:isCurrentSession / getSessionTitle / getSessionSubtitle /
 *   getChapterLabel / getWorldName(由页面转发 viewModel)
 * - 业务动作:全部回调上抛(新建/切换/删除会话、分组增删改移)
 * - 折叠状态持久化:fetchCollapsedWorldIds / onPersistCollapsedWorldIds(页面实现)
 * - 不直接访问 Repository / DbHelper / 网络 / 服务
 * - 不持有 chatId 选择状态(由页面 ViewModel 持有)
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

import { Chat } from '../models/Chat';
import { WorldGroup } from '../models/WorldGroup';
import { ThemePalette } from '../theme/ThemePalette';
import { isWorldCollapsed, toggleCollapsedWorldId } from '../utils/SessionListCollapseState';
import { AppDialog } from './ui/AppDialog';
import { promptAction } from '@kit.ArkUI';

/** 会话列表展示行模型:分组头 或 会话行 */
class SessionListRowModel {
  /** 是否为分组头行 */
  isHeader: boolean = false;
  /** 分组头:worldId */
  worldId: string = '';
  /** 分组头:分组名 */
  worldName: string = '';
  /** 分组头:组内会话数 */
  chatCount: number = 0;
  /** 分组头:是否折叠 */
  isCollapsed: boolean = false;
  /** 会话行:对应会话 */
  chat: Chat | null = null;
}

@Component
export struct ChatSessionListPanel {
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  // ===== 数据(页面传入,对应 viewModel 同名字段) =====
  /** 当前上下文下的会话列表 */
  @Prop sessions: Chat[] = [];
  /** 世界分组(章节文件夹) */
  @Prop worldGroups: WorldGroup[] = [];
  /** 当前角色名(空=普通聊天) */
  @Prop characterName: string = '';
  /** 会话操作错误消息(空=无错误) */
  @Prop sessionError: string = '';
  /** 会话列表加载中 */
  @Prop isLoadingSessions: boolean = false;
  /** 会话是否可操作(生成中/操作中/未就绪时置灰) */
  @Prop canOperateSessions: boolean = false;
  /** 删除确认对话框是否可见(页面 viewModel.showDeleteSessionConfirm) */
  @Prop showDeleteSessionConfirm: boolean = false;

  // ===== 查询(由页面转发 viewModel) =====
  /** 指定会话是否为当前会话(高亮"当前"徽标) */
  isCurrentSession: (chatId: string) => boolean = (_: string) => false;
  /** 会话标题(标题 → "新对话") */
  getSessionTitle: (chat: Chat) => string = (_: Chat) => '';
  /** 会话副标题(最后消息时间) */
  getSessionSubtitle: (chat: Chat) => string = (_: Chat) => '';
  /** 组内章节标签("第N章";未分组返回空) */
  getChapterLabel: (chatId: string) => string = (_: string) => '';
  /** 分组名(未知分组返回兜底文案) */
  getWorldName: (worldId: string) => string = (_: string) => '';

  // ===== 动作(全部由页面执行) =====
  /** 关闭面板(遮罩点击 / 关闭按钮) */
  onClose: () => void = () => {};
  /** 新建对话 */
  onCreateNewSession: () => void = () => {};
  /** 切换会话 */
  onSelectSession: (chatId: string) => void = (_: string) => {};
  /** 请求删除会话(弹出确认) */
  onRequestDeleteSession: (chatId: string) => void = (_: string) => {};
  /** 取消删除 */
  onCancelDeleteSession: () => void = () => {};
  /** 确认删除 */
  onConfirmDeleteSession: () => void = () => {};
  /** 新建分组;返回错误消息(空字符串=成功) */
  onCreateWorldGroup: (name: string) => Promise<string> = (_: string) => Promise.resolve('');
  /** 重命名分组;返回错误消息(空字符串=成功) */
  onRenameWorldGroup: (worldId: string, name: string) => Promise<string> =
    (_: string, _n: string) => Promise.resolve('');
  /** 删除分组(仅解除关联);返回错误消息(空字符串=成功) */
  onDeleteWorldGroup: (worldId: string) => Promise<string> = (_: string) => Promise.resolve('');
  /** 移动会话到分组(空字符串=不分组);返回错误消息(空字符串=成功) */
  onMoveChatToWorld: (chatId: string, worldId: string) => Promise<string> =
    (_: string, _w: string) => Promise.resolve('');
  /** 读取分组折叠状态(页面从 Preferences 读取;失败返回空数组) */
  fetchCollapsedWorldIds: () => Promise<string[]> = () => Promise.resolve([]);
  /** 持久化分组折叠状态(页面写入 Preferences,fire-and-forget) */
  onPersistCollapsedWorldIds: (ids: string[]) => void = (_: string[]) => {};

  // ===== v42 世界分组(章节)状态 =====
  /** 已折叠的世界分组 id 列表 */
  @State collapsedWorldIds: string[] = [];
  /** 是否显示新建分组弹窗 */
  @State showCreateGroupDialog: boolean = false;
  /** 新建分组输入 */
  @State newGroupName: string = '';
  /** 重命名分组目标(空时不显示) */
  @State renameGroupTarget: WorldGroup | null = null;
  /** 重命名分组输入 */
  @State renameGroupInput: string = '';
  /** 删除分组确认目标(空时不显示) */
  @State deleteGroupTarget: WorldGroup | null = null;
  /** 移动会话到分组的目标(空时不显示) */
  @State moveTarget: Chat | null = null;
  /** 移动弹窗中选中的分组 id(空字符串=不分组) */
  @State moveSelectedWorldId: string = '';

  aboutToAppear(): void {
    // v49: 恢复上次保存的分组折叠状态(默认全展开)
    this.loadCollapsedWorldIds();
  }

  build() {
    Stack() {
      // 背景遮罩(点击关闭)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.5)')
        .onClick(() => {
          if (!this.showDeleteSessionConfirm) {
            this.onClose();
          }
        })

      // 面板主体
      Column() {
        this.headerBar();
        this.contextBar();
        if (this.sessionError.length > 0) {
          Text(this.sessionError)
            .fontSize(12)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 8 })
        }
        Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).height(1).width('100%')

        if (this.isLoadingSessions) {
          this.loadingState();
        } else if (this.sessions.length === 0) {
          this.emptyState();
        } else {
          this.sessionList();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))

      // 删除确认对话框(覆盖在面板之上)
      this.deleteConfirmDialog()

      // v42: 新建分组弹窗
      if (this.showCreateGroupDialog) {
        this.createGroupDialog()
      }

      // v42: 分组管理(重命名/删除)弹窗
      if (this.renameGroupTarget !== null) {
        this.renameGroupDialog()
      }

      // v42: 删除分组确认弹窗
      if (this.deleteGroupTarget !== null) {
        this.deleteGroupDialog()
      }

      // v42: 移动会话到分组弹窗
      if (this.moveTarget !== null) {
        this.moveChatDialog()
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
        .backgroundColor(this.canOperateSessions
          ? ThemePalette.accentColor(this.effectiveTheme)
          : ThemePalette.surface2Color(this.effectiveTheme))
        .fontColor(this.canOperateSessions
          ? $r('app.color.app_on_accent')
          : ThemePalette.textTertiaryColor(this.effectiveTheme))
        .borderRadius(16)
        .height(36)
        .padding({ left: 12, right: 12 })
        .enabled(this.canOperateSessions)
        .onClick(() => {
          this.onCreateNewSession();
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
        this.onClose();
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
      Text(this.characterName.length > 0
        ? this.characterName
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
        .enabled(this.canOperateSessions)
        .onClick(() => {
          this.onCreateNewSession();
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
        // 分组管理入口
        Row() {
          Text('世界分组')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          Blank()
          Button('新建分组')
            .fontSize(12)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(14)
            .height(28)
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              this.newGroupName = '';
              this.showCreateGroupDialog = true;
            })
        }
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 6 })

        ForEach(this.buildRows(), (row: SessionListRowModel) => {
          if (row.isHeader) {
            this.groupHeaderRow(row)
          } else {
            this.sessionItem(row.chat!)
          }
        }, (row: SessionListRowModel) => {
          return row.isHeader
            ? 'h_' + row.worldId + '|' + row.isCollapsed.toString()
            : 's_' + row.chat!.id + '_' + row.chat!.updatedAt + '_' + row.chat!.lastMessageAt
        })
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

  /**
   * 构建分组展示行:世界分组头 + 组内会话 + 未分组会话平铺。
   */
  private buildRows(): SessionListRowModel[] {
    const rows: SessionListRowModel[] = [];
    const grouped: Map<string, Chat[]> = new Map<string, Chat[]>();
    const flat: Chat[] = [];
    const sessions: Chat[] = this.sessions;
    for (let i = 0; i < sessions.length; i++) {
      const chat: Chat = sessions[i];
      if (chat.worldId.length > 0) {
        let list: Chat[] | undefined = grouped.get(chat.worldId);
        if (list === undefined) {
          list = [];
          grouped.set(chat.worldId, list);
        }
        list.push(chat);
      } else {
        flat.push(chat);
      }
    }
    // 分组顺序:优先按已加载分组的 createdAt 升序,未知分组排最后
    const knownOrder: string[] = [];
    const unknownWorldIds: string[] = [];
    const vmGroups: WorldGroup[] = this.worldGroups;
    const vmGroupsSorted: WorldGroup[] = vmGroups.slice();
    vmGroupsSorted.sort((a: WorldGroup, b: WorldGroup): number => a.createdAt - b.createdAt);
    for (let i = 0; i < vmGroupsSorted.length; i++) {
      knownOrder.push(vmGroupsSorted[i].id);
    }
    grouped.forEach((_list: Chat[], worldId: string): void => {
      if (knownOrder.indexOf(worldId) < 0) {
        unknownWorldIds.push(worldId);
      }
    });
    unknownWorldIds.sort();
    const orderedWorldIds: string[] = knownOrder.concat(unknownWorldIds);

    for (let w = 0; w < orderedWorldIds.length; w++) {
      const worldId: string = orderedWorldIds[w];
      const list: Chat[] | undefined = grouped.get(worldId);
      if (list === undefined || list.length === 0) {
        continue;
      }
      const header: SessionListRowModel = new SessionListRowModel();
      header.isHeader = true;
      header.worldId = worldId;
      header.worldName = this.getWorldName(worldId);
      header.chatCount = list.length;
      header.isCollapsed = isWorldCollapsed(this.collapsedWorldIds, worldId);
      rows.push(header);
      if (!header.isCollapsed) {
        const sorted: Chat[] = list.slice();
        sorted.sort((a: Chat, b: Chat): number => a.createdAt - b.createdAt);
        for (let i = 0; i < sorted.length; i++) {
          const row: SessionListRowModel = new SessionListRowModel();
          row.isHeader = false;
          row.chat = sorted[i];
          rows.push(row);
        }
      }
    }
    for (let i = 0; i < flat.length; i++) {
      const row: SessionListRowModel = new SessionListRowModel();
      row.isHeader = false;
      row.chat = flat[i];
      rows.push(row);
    }
    return rows;
  }

  /** 折叠/展开分组(切换后持久化) */
  private toggleWorldCollapsed(worldId: string): void {
    const next: string[] = toggleCollapsedWorldId(this.collapsedWorldIds, worldId);
    this.collapsedWorldIds = next;
    this.persistCollapsedWorldIds(next);
  }

  /** v49: 加载上次保存的分组折叠状态(无记录时全展开;读取实现由页面提供) */
  private async loadCollapsedWorldIds(): Promise<void> {
    try {
      this.collapsedWorldIds = await this.fetchCollapsedWorldIds();
    } catch (_e) {
      this.collapsedWorldIds = [];
    }
  }

  /** v49: 持久化分组折叠状态(fire-and-forget;写入实现由页面提供) */
  private persistCollapsedWorldIds(ids: string[]): void {
    this.onPersistCollapsedWorldIds(ids);
  }

  /** 分组头行:分组名 + 章节数 + 折叠箭头 + 管理按钮 */
  @Builder
  groupHeaderRow(row: SessionListRowModel) {
    Row() {
      Text(row.worldName)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text(row.chatCount.toString() + ' 个章节')
        .fontSize(11)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ left: 8 })

      Text(row.isCollapsed ? '▸' : '▾')
        .fontSize(14)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .margin({ left: 8 })

      Button('管理')
        .fontSize(11)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .height(28)
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          this.openGroupManageDialog(row.worldId);
        })
    }
    .width('100%')
    .padding({ left: 12, right: 8, top: 10, bottom: 10 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius(10)
    .margin({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.toggleWorldCollapsed(row.worldId);
    })
  }

  /** 打开分组管理弹窗(重命名/删除) */
  private openGroupManageDialog(worldId: string): void {
    const groups: WorldGroup[] = this.worldGroups;
    for (let i = 0; i < groups.length; i++) {
      if (groups[i].id === worldId) {
        this.renameGroupTarget = groups[i];
        this.renameGroupInput = groups[i].name;
        return;
      }
    }
  }

  @Builder
  sessionItem(chat: Chat) {
    Row() {
      Column() {
        Row() {
          if (chat.worldId.length > 0) {
            Text(this.getChapterLabel(chat.id))
              .fontSize(10)
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
              .borderRadius(4)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .margin({ right: 6 })
          }
          Text(this.getSessionTitle(chat))
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.getSessionSubtitle(chat))
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 2 })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.isCurrentSession(chat.id)) {
        Text($r('app.string.chat_branch_current_badge'))
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .margin({ right: 8 })
      }

      Button('分组')
        .fontSize(12)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .height(32)
        .padding({ left: 8, right: 8 })
        .enabled(this.canOperateSessions)
        .onClick(() => {
          this.openMoveChatDialog(chat);
        })

      Button($r('app.string.character_action_delete'))
        .fontSize(12)
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_danger'))
        .height(32)
        .padding({ left: 8, right: 8 })
        .enabled(this.canOperateSessions)
        .onClick(() => {
          this.onRequestDeleteSession(chat.id);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius(12)
    .margin({ top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.canOperateSessions) {
        this.onSelectSession(chat.id);
      }
    })
  }

  @Builder
  deleteConfirmDialog() {
    AppDialog({
      visible: this.showDeleteSessionConfirm,
      title: '',
      layout: 'center',
      actions: [
        {
          label: $r('app.string.chat_edit_message_cancel'),
          style: 'secondary',
          enabled: true,
          onTap: () => {
            this.onCancelDeleteSession();
          }
        },
        {
          label: $r('app.string.character_action_delete'),
          style: 'danger',
          enabled: this.canOperateSessions,
          onTap: () => {
            this.onConfirmDeleteSession();
          }
        }
      ],
      onClose: () => {
        this.onCancelDeleteSession();
      }
    }) {
      Column() {
        Text('删除该会话及其中的全部消息?')
          .fontSize(15)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ bottom: 8 })
        Text('此操作无法撤销。')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ bottom: 20 })
      }
      .width('100%')
    }
  }

  // ===== v42 世界分组管理 =====

  /** 确认新建分组 */
  private async confirmCreateGroup(): Promise<void> {
    const name: string = this.newGroupName.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '分组名称不能为空', duration: 2000 });
      return;
    }
    this.showCreateGroupDialog = false;
    const error: string = await this.onCreateWorldGroup(name);
    if (error.length === 0) {
      promptAction.showToast({ message: '已创建分组', duration: 1500 });
    } else {
      promptAction.showToast({ message: error, duration: 2000 });
    }
  }

  /** 确认重命名分组 */
  private async confirmRenameGroup(): Promise<void> {
    const target: WorldGroup | null = this.renameGroupTarget;
    if (target === null) {
      return;
    }
    const name: string = this.renameGroupInput.trim();
    if (name.length === 0) {
      promptAction.showToast({ message: '分组名称不能为空', duration: 2000 });
      return;
    }
    this.renameGroupTarget = null;
    const error: string = await this.onRenameWorldGroup(target.id, name);
    if (error.length === 0) {
      promptAction.showToast({ message: '已重命名分组', duration: 1500 });
    } else {
      promptAction.showToast({ message: error, duration: 2000 });
    }
  }

  /** 确认删除分组(仅解除关联,不删会话) */
  private async confirmDeleteGroup(): Promise<void> {
    const target: WorldGroup | null = this.deleteGroupTarget;
    if (target === null) {
      return;
    }
    this.deleteGroupTarget = null;
    const error: string = await this.onDeleteWorldGroup(target.id);
    if (error.length === 0) {
      promptAction.showToast({ message: '已删除分组,会话未受影响', duration: 1500 });
    } else {
      promptAction.showToast({ message: error, duration: 2000 });
    }
  }

  /** 打开移动会话到分组弹窗 */
  private openMoveChatDialog(chat: Chat): void {
    this.moveTarget = chat;
    this.moveSelectedWorldId = chat.worldId;
  }

  /** 确认移动会话到分组(空字符串=不分组) */
  private async confirmMoveChat(): Promise<void> {
    const target: Chat | null = this.moveTarget;
    if (target === null) {
      return;
    }
    this.moveTarget = null;
    const worldId: string = this.moveSelectedWorldId;
    const error: string = await this.onMoveChatToWorld(target.id, worldId);
    if (error.length === 0) {
      promptAction.showToast({ message: '已移动会话', duration: 1500 });
    } else {
      promptAction.showToast({ message: error, duration: 2000 });
    }
  }

  /** 新建分组弹窗 */
  @Builder
  createGroupDialog() {
    Stack() {
      Column() {
        Column() {
          Text('新建世界分组')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          TextInput({ placeholder: '分组名称', text: this.newGroupName })
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.newGroupName = value;
            })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.showCreateGroupDialog = false;
              })
            Button('创建')
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmCreateGroup();
              })
          }
          .width('100%')
          .margin({ top: 20 })
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
  }

  /** 分组管理弹窗(重命名 + 删除) */
  @Builder
  renameGroupDialog() {
    Stack() {
      Column() {
        Column() {
          Text('分组管理')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          TextInput({ placeholder: '分组名称', text: this.renameGroupInput })
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.renameGroupInput = value;
            })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.renameGroupTarget = null;
              })
            Button('重命名')
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmRenameGroup();
              })
          }
          .width('100%')
          .margin({ top: 12 })

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 12, bottom: 4 })

          Button('删除分组(仅解除关联,不删会话)')
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .height(44)
            .onClick(() => {
              const target: WorldGroup | null = this.renameGroupTarget;
              if (target !== null) {
                this.renameGroupTarget = null;
                this.deleteGroupTarget = target;
              }
            })
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
  }

  /** 删除分组确认弹窗 */
  @Builder
  deleteGroupDialog() {
    Stack() {
      Column() {
        Column() {
          Text('删除分组')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          Text('删除分组仅解除会话与该分组的关联,不会删除任何会话。确定删除"'
            + (this.deleteGroupTarget !== null ? this.deleteGroupTarget!.name : '')
            + '"吗?')
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .lineHeight(20)
            .margin({ bottom: 20 })

          Row() {
            Button('取消')
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.deleteGroupTarget = null;
              })

            Button('删除')
              .fontSize(14)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White)
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmDeleteGroup();
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
  }

  /** 移动会话到分组弹窗(含"不分组") */
  @Builder
  moveChatDialog() {
    Stack() {
      Column() {
        Column() {
          Text('移动到分组')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 8 })

          Text(this.moveTarget !== null ? this.getSessionTitle(this.moveTarget!) : '')
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ bottom: 12 })

          Scroll() {
            Column() {
              // "不分组"选项
              Row() {
                Radio({ value: 'none', group: 'moveWorldPanel' })
                  .checked(this.moveSelectedWorldId.length === 0)
                  .onChange((checked: boolean) => {
                    if (checked) {
                      this.moveSelectedWorldId = '';
                    }
                  })
                Text('不分组')
                  .fontSize(14)
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .margin({ left: 8 })
              }
              .width('100%')
              .height(44)
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.moveSelectedWorldId = '';
              })

              Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

              // 分组列表
              ForEach(this.worldGroups, (g: WorldGroup) => {
                Row() {
                  Radio({ value: g.id, group: 'moveWorldPanel' })
                    .checked(this.moveSelectedWorldId === g.id)
                    .onChange((checked: boolean) => {
                      if (checked) {
                        this.moveSelectedWorldId = g.id;
                      }
                    })
                  Text(g.name)
                    .fontSize(14)
                    .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                    .margin({ left: 8 })
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .height(44)
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.moveSelectedWorldId = g.id;
                })
              }, (g: WorldGroup) => g.id)

              if (this.worldGroups.length === 0) {
                Text('暂无分组,请先点击"新建分组"创建')
                  .fontSize(13)
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .margin({ top: 8 })
              }
            }
            .width('100%')
          }
          .height(220)
          .scrollBar(BarState.Auto)

          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

          Row() {
            Button('取消')
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .onClick(() => {
                this.moveTarget = null;
              })
            Button('移动')
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .onClick(() => {
                this.confirmMoveChat();
              })
          }
          .width('100%')
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
  }
}
