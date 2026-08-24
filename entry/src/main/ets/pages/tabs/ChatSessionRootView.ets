/**
 * ChatSessionRootView 对话记录 Tab 根视图
 *
 * UI-SESSIONS-01 视觉重构(设计依据:sessions_list.md / SESSIONS_LIST_005.md):
 * - 顶栏:居中标题"聊天"(H2 18fp Medium)
 * - 会话卡:[头像] [名称 时间] / [预览单行截断](两行结构)
 * - 标题显示策略:优先 chat.title → 角色名 → "新对话"
 * - 左滑显示重命名按钮
 * - 重命名:原生 TextInputDialog,空名称拒绝
 * - 角色已删除显示"未知角色",不崩溃
 *
 * 复用:
 * - ChatSessionListViewModel(本 Tab 专用,不创建 ChatService 副作用)
 * - CharacterImageView
 * - PressableCard
 * - AppStorage 跨页面刷新信号(chatListVersion)
 *
 * 不修改:
 * - 数据库 Schema / 迁移
 * - ChatService 生成 / Provider / PromptBuilder
 * - 其他 Tab
 */

import { ChatSessionListViewModel, ChatSessionListItem, formatSessionTimestamp, UNKNOWN_CHARACTER_NAME } from '../../viewmodels/ChatSessionListViewModel';
import { AppServices } from '../../services/AppServices';
import { EmptyStateView } from '../../components/EmptyStateView';
import { PressableCard } from '../../components/PressableCard';
import { CharacterImageView } from '../../components/CharacterImageView';
import { promptAction, router } from '@kit.ArkUI';

import { Character, resolveCharacterDisplayName } from '../../models/Character';

import { ChatArchiveViewModel } from '../../viewmodels/ChatArchiveViewModel';
import { ChatArchiveImportConversationResult } from '../../parser/ChatArchiveSchema';
import { Logger } from '../../utils/Logger';
import { ThemePalette } from '../../theme/ThemePalette';

const LOG_TAG_SESSION: string = 'ChatSessionRootView';

/** AppStorage 中待跳转的 chatId(由本视图写入,ChatPage 读取后清除) */
export const PENDING_CHAT_ID_KEY: string = 'pendingChatId';
/** AppStorage 中待应用的 characterId(配合 pendingChatId 切换到指定角色会话) */
export const PENDING_CHARACTER_ID_KEY: string = 'pendingCharacterId';

/** 左滑网格按钮参数(2行×3列紧凑布局) */
interface SwipeIconButtonParams {
  icon: Resource;
  label: Resource | string;
  bgColor: ResourceColor;
  fgColor: ResourceColor;
  disabled: boolean;
  action: () => void;
}

@Component
export struct ChatSessionRootView {
  @State viewModel: ChatSessionListViewModel | null = null;
  @State isInitializing: boolean = true;
  @State initError: string = '';
  /**
   * 组件本地会话列表(@State 直接装饰数组,赋值新数组即触发 ForEach 重渲染)。
   * 说明:@State 装饰 `ViewModel | null` 联合类型时,对 @Observed 实例属性的观察不可靠,
   * 因此显式维护本地 sessions 数组,在每次 reload / renameSession 后同步。
   */
  @State sessions: ChatSessionListItem[] = [];
  /** 重命名弹窗目标 chatId(空时不显示) */
  @State renameTargetId: string = '';
  /** 重命名弹窗输入值 */
  @State renameInput: string = '';
  /** 重命名进行中(防止重复点击) */
  @State isRenaming: boolean = false;
  /** 删除确认弹窗目标项(空时不显示) */
  @State deleteTarget: ChatSessionListItem | null = null;
  /** 删除进行中(防止重复点击) */
  @State isDeleting: boolean = false;

  // ===== T-CHAT.1: 聊天归档导入导出 =====
  /** T-CHAT.1: 聊天归档 ViewModel(导入流程) */
  @State archiveViewModel: ChatArchiveViewModel | null = null;
  /** T-CHAT.1: 是否显示导入预览弹窗 */
  @State showImportPreview: boolean = false;
  /** T-CHAT.1: 是否显示导入结果弹窗 */
  @State showImportResult: boolean = false;
  /** T-CHAT.1: 导入/导出进行中(防止重复点击) */
  @State archiveBusy: boolean = false;
  /** T-CHAT.1: 导出长按菜单目标项(空时不显示) */
  @State exportTarget: ChatSessionListItem | null = null;
  /**
   * 跨页面列表刷新信号。
   * 由 ChatPage 在会话变化(发消息/新建会话/删除)后递增,触发本组件 reload。
   * 说明:本组件作为 HdsTabs 的 TabContent 嵌入,onPageShow 不会被调用。
   */
  @StorageProp('chatListVersion') @Watch('onListVersionChange') chatListVersion: number = 0;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const vm: ChatSessionListViewModel = AppServices.createChatSessionListViewModel();
      this.viewModel = vm;
      await vm.reload();
      this.sessions = vm.sessions;
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      this.initError = (e as Error).message ?? '';
    }
  }

  /** chatListVersion 变化时刷新列表(从 ChatPage 返回后立即重新加载最新摘要/时间) */
  private onListVersionChange(): void {
    if (this.isInitializing) {
      return;
    }
    if (this.viewModel === null || !AppServices.isStarted()) {
      return;
    }
    this.viewModel!.reload()
      .then((): void => {
        this.sessions = this.viewModel!.sessions;
      })
      .catch((): void => {});
  }

  /** 同步 viewModel.sessions 到本地 @State sessions(触发 ForEach 重渲染) */
  private syncSessions(): void {
    if (this.viewModel !== null) {
      this.sessions = this.viewModel!.sessions;
    }
  }

  /** 点击会话项:写入 pendingChatId 和 pendingCharacterId(如有),push 到 ChatPage */
  private openSession(item: ChatSessionListItem): void {
    AppStorage.setOrCreate<string>(PENDING_CHAT_ID_KEY, item.chat.id);
    // 若会话有关联角色,同时写入 characterId,让 ChatPage 在 initialize 时加载正确角色上下文
    const charId: string | undefined = item.chat.characterId;
    if (charId !== undefined && charId.length > 0) {
      AppStorage.setOrCreate<string>(PENDING_CHARACTER_ID_KEY, charId);
    } else {
      AppStorage.set<string>(PENDING_CHARACTER_ID_KEY, '');
    }
    router.pushUrl({ url: 'pages/ChatPage' });
  }

  /** 打开重命名弹窗 */
  private openRenameDialog(item: ChatSessionListItem): void {
    if (this.isRenaming) {
      return;
    }
    this.renameTargetId = item.chat.id;
    // 回填当前标题(空标题回填为"新对话"以便编辑)
    this.renameInput = item.chat.title.length > 0 ? item.chat.title : '新对话';
  }

  /** 取消重命名 */
  private cancelRename(): void {
    if (this.isRenaming) {
      return;
    }
    this.renameTargetId = '';
    this.renameInput = '';
  }

  /** 确认重命名:校验非空,调 viewModel.renameSession */
  private async confirmRename(): Promise<void> {
    if (this.isRenaming || this.renameTargetId.length === 0) {
      return;
    }
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      promptAction.showToast({ message: '会话名称不能为空', duration: 2000 });
      return;
    }
    if (this.viewModel === null) {
      return;
    }
    this.isRenaming = true;
    try {
      await this.viewModel.renameSession(this.renameTargetId, trimmed);
      this.renameTargetId = '';
      this.renameInput = '';
      // 显式同步到本地 @State sessions,触发 ForEach 重渲染
      this.syncSessions();
      // 通知其他可能监听的页面(避免 ChatPage 复用旧 title)
      this.bumpListVersion();
    } catch (e) {
      promptAction.showToast({
        message: (e as Error).message ?? '重命名失败',
        duration: 2000
      });
    } finally {
      this.isRenaming = false;
    }
  }

  /** 打开删除确认弹窗 */
  private promptDelete(item: ChatSessionListItem): void {
    if (this.isDeleting) {
      return;
    }
    this.deleteTarget = item;
  }

  /** 取消删除 */
  private cancelDelete(): void {
    if (this.isDeleting) {
      return;
    }
    this.deleteTarget = null;
  }

  /** 确认删除:调 viewModel.deleteSession */
  private async confirmDelete(): Promise<void> {
    if (this.isDeleting || this.deleteTarget === null) {
      this.deleteTarget = null;
      return;
    }
    if (this.viewModel === null) {
      this.deleteTarget = null;
      return;
    }
    const chatId: string = this.deleteTarget.chat.id;
    this.isDeleting = true;
    try {
      await this.viewModel.deleteSession(chatId);
      // 显式同步本地 sessions
      this.syncSessions();
      // 通知其他页面(如 ChatPage)刷新
      this.bumpListVersion();
    } catch (e) {
      promptAction.showToast({
        message: (e as Error).message ?? '删除失败',
        duration: 2000
      });
    } finally {
      this.deleteTarget = null;
      this.isDeleting = false;
    }
  }

  /** 递增 chatListVersion,通知其他页面(如已存在的 ChatPage)刷新会话列表 */
  private bumpListVersion(): void {
    const v: number = AppStorage.get<number>('chatListVersion') ?? 0;
    AppStorage.setOrCreate<number>('chatListVersion', v + 1);
  }

  /** 上移会话卡片(异步,完成后同步本地 sessions 并通知刷新) */
  private async handleMoveUp(chatId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.moveUp(chatId);
    this.syncSessions();
    this.bumpListVersion();
  }

  /** 下移会话卡片(异步,完成后同步本地 sessions 并通知刷新) */
  private async handleMoveDown(chatId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    await this.viewModel!.moveDown(chatId);
    this.syncSessions();
    this.bumpListVersion();
  }

  build() {
    Stack() {
      Column() {
        // 顶栏:标题"对话记录" + T-CHAT.1 导入入口
        this.headerBar()

        // 错误提示
        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_20'),
              right: $r('app.float.app_spacing_20'),
              bottom: $r('app.float.app_spacing_4')
            })
        }

        // 主内容区
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.initError.length > 0) {
          this.errorView()
        } else {
          this.sessionListArea()
        }
      }
      .width('100%')
      .height('100%')
      // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // 重命名弹窗
      if (this.renameTargetId.length > 0) {
        this.renameDialog()
      }

      // 删除确认弹窗
      if (this.deleteTarget !== null) {
        this.deleteConfirmDialog()
      }

      // T-CHAT.1: 长按导出选择弹窗
      if (this.exportTarget !== null) {
        this.exportChatDialog()
      }

      // T-CHAT.1: 导入预览弹窗
      if (this.showImportPreview) {
        this.importPreviewDialog()
      }

      // T-CHAT.1: 导入结果弹窗
      if (this.showImportResult) {
        this.importResultDialog()
      }
    }
    .width('100%')
    .height('100%')
    // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  /** 顶部标题栏:对话记录 + 紧凑导入按钮 */
  @Builder
  headerBar() {
    Row() {
      Text($r('app.string.tab_sessions'))
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Bold)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // T-CHAT.1: 导入聊天按钮(顶栏右侧,紧凑)
      Button($r('app.string.character_import'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(28)
        .padding({ left: 10, right: 10 })
        .enabled(!this.archiveBusy)
        .onClick(() => {
          this.startImportFlow();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      // 顶部 padding = 状态栏高度 + 间距 4(与对话设置等二级页 titleBar 保持一致)
      top: this.statusBarHeight + 4,
      bottom: $r('app.float.app_spacing_8')
    })
    // 顶栏背景色与二级页 titleBar 一致:surface1 色块延伸覆盖状态栏区域,
    // 与内容区(pageBg)形成分层
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .alignItems(VerticalAlign.Center)
  }

  /** 会话列表区:直接展示全部单人会话(左滑操作) */
  @Builder
  sessionListArea() {
    if (this.sessions.length === 0) {
      this.sessionsEmptyState()
    } else {
      List() {
        ForEach(this.sessions, (item: ChatSessionListItem, index: number) => {
          ListItem() {
            this.sessionCard(item)
          }
          .width('100%')
          .margin({ bottom: 6 })
          .swipeAction({
            end: {
              builder: (): void => {
                this.swipeActionButtons(item, index)
              }
            }
          })
        }, (item: ChatSessionListItem) => item.chat.id + '|' + item.chat.title)

        ListItem() {
          Column().width('100%').height(160)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
      .padding({
        left: $r('app.float.app_spacing_8'),
        right: $r('app.float.app_spacing_8'),
        top: 0,
        bottom: 0
      })
    }
  }

  /** 无会话记录的空状态(开始新对话 + 导入聊天记录) */
  @Builder
  sessionsEmptyState() {
    Column() {
      // 简单装饰形状(不引入新图片资产)
      Stack() {
        SymbolGlyph($r('sys.symbol.bell'))
          .fontSize(32)
          .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
      }
      .width(72)
      .height(72)
      .borderRadius(36)
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .alignContent(Alignment.Center)
      .margin({ bottom: 16 })

      Text($r('app.string.tab_sessions_empty'))
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .width('100%')

      Text($r('app.string.tab_sessions_empty_desc'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 8 })
        .padding({ left: $r('app.float.app_spacing_24'), right: $r('app.float.app_spacing_24') })

      // 主按钮:开始单聊(使用当前角色进入 ChatPage)
      Button($r('app.string.sessions_empty_start_chat'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_on_accent'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_20') })
        .onClick(() => {
          AppStorage.set<string>(PENDING_CHAT_ID_KEY, '');
          AppStorage.set<string>(PENDING_CHARACTER_ID_KEY, '');
          router.pushUrl({ url: 'pages/ChatPage' });
        })

      // 次按钮:导入聊天记录
      Button($r('app.string.sessions_empty_import'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .padding({ left: 24, right: 24 })
        .margin({ top: $r('app.float.app_spacing_8') })
        .enabled(!this.archiveBusy)
        .onClick(() => {
          this.startImportFlow();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: $r('app.float.app_spacing_24'), bottom: 160 })
  }


  /** 左滑操作区:2行×3列紧凑网格(上移/重命名/导出 | 下移/删除) */
  @Builder
  swipeActionButtons(item: ChatSessionListItem, index: number) {
    Row() {
      Column() {
        // 第一行:上移 / 重命名 / 导出
        Row() {
          this.swipeGridCell({
            icon: $r('sys.symbol.arrow_up'),
            label: '上移',
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: index === 0,
            action: (): void => { this.handleMoveUp(item.chat.id); }
          })
          this.swipeGridCell({
            icon: $r('sys.symbol.square_and_pencil'),
            label: $r('app.string.session_action_rename'),
            bgColor: ThemePalette.accentColor(this.effectiveTheme),
            fgColor: $r('app.color.app_on_accent'),
            disabled: false,
            action: (): void => { this.openRenameDialog(item); }
          })
          this.swipeGridCell({
            icon: $r('sys.symbol.share'),
            label: $r('app.string.session_action_export'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: false,
            action: (): void => { this.exportTarget = item; }
          })
        }
        .layoutWeight(1)
        .width('100%')

        // 第二行:下移 / 删除
        Row() {
          this.swipeGridCell({
            icon: $r('sys.symbol.arrow_down'),
            label: '下移',
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: index === this.sessions.length - 1,
            action: (): void => { this.handleMoveDown(item.chat.id); }
          })
          this.swipeGridCell({
            icon: $r('sys.symbol.trash'),
            label: $r('app.string.session_action_delete'),
            bgColor: $r('app.color.app_danger'),
            fgColor: $r('app.color.app_on_accent'),
            disabled: false,
            action: (): void => { this.promptDelete(item); }
          })
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width(204)
      .height('100%')
      .padding(2)
    }
    .height('100%')
  }

  /** 左滑紧凑网格单元格(图标在上,文字在下,圆角矩形) */
  @Builder
  swipeGridCell(params: SwipeIconButtonParams) {
    Button() {
      Column() {
        SymbolGlyph(params.icon)
          .fontSize(18)
          .fontColor([params.fgColor])
        Text(params.label)
          .fontSize(10)
          .fontColor(params.fgColor)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .type(ButtonType.Normal)
    .backgroundColor(params.bgColor)
    .borderRadius(10)
    .height('100%')
    .layoutWeight(1)
    .margin({ left: 2, right: 2, top: 2, bottom: 2 })
    .padding(0)
    .enabled(!params.disabled)
    .opacity(params.disabled ? 0.35 : 1.0)
    .onClick(() => {
      params.action();
    })
  }

  /** 单个会话卡片(紧凑布局:头像 52 + 两行文本 + 时间/Chevron) */
  @Builder
  sessionCard(item: ChatSessionListItem) {
    Column() {
      PressableCard({
        onPress: () => {
          this.openSession(item);
        },
        surfaceColor: ThemePalette.surface1Color(this.effectiveTheme)
      }) {
        Row() {
          CharacterImageView({
            imageUri: item.character !== null ? item.character.avatarUri : '',
            fallbackName: this.getCharacterFallbackName(item),
            imgWidth: 52,
            imgHeight: 52,
            imgBorderRadius: 26,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })

          Column() {
            Text(this.getSessionTitle(item))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)

            if (item.lastMessagePreview.length > 0) {
              Text(item.lastMessagePreview)
                .fontSize(13)
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 3 })
                .width('100%')
                .textAlign(TextAlign.Start)
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })

          Column() {
            Text(formatSessionTimestamp(item.displayTimestamp))
              .fontSize(11)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14)
              .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
              .margin({ top: 6 })
          }
          .alignItems(HorizontalAlign.End)
          .margin({ left: 8 })
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_12'),
          right: $r('app.float.app_spacing_12'),
          top: 10,
          bottom: 10
        })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .borderRadius($r('app.float.app_radius_md'))
    .border({ width: 0.5, color: ThemePalette.dividerColor(this.effectiveTheme) })
  }

  /**
   * 获取会话标题(规范:名称=角色名;支持重命名优先)。
   * 优先级:chat.title → 角色名 → "未知角色"(已删除) → "新对话"
   */
  private getSessionTitle(item: ChatSessionListItem): string {
    if (item.chat.title.length > 0) {
      return item.chat.title;
    }
    if (item.isCharacterDeleted) {
      return UNKNOWN_CHARACTER_NAME;
    }
    if (item.character !== null && item.character.name.length > 0) {
      return item.character.name;
    }
    return '新对话';
  }

  /** 获取头像占位首字(已删除显示"?",有角色用角色名首字,无角色用"助") */
  private getCharacterFallbackName(item: ChatSessionListItem): string {
    if (item.isCharacterDeleted) {
      return '?';
    }
    if (item.character !== null && item.character.name.length > 0) {
      return item.character.name.charAt(0);
    }
    return '助';
  }

  /** 底部"开始新对话"按钮已移除(规范未要求;新建对话入口统一由角色卡 Tab 提供) */

  /** 重命名弹窗(原生 Stack 遮罩 + 输入框) */
  @Builder
  renameDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.session_rename_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          TextInput({ placeholder: $r('app.string.session_rename_placeholder'), text: this.renameInput })
            .fontSize(15)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(44)
            .padding({ left: 12, right: 12 })
            .onChange((value: string) => {
              this.renameInput = value;
            })

          Row() {
            Button($r('app.string.session_rename_cancel'))
              .fontSize(15)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .enabled(!this.isRenaming)
              .onClick(() => {
                this.cancelRename();
              })
            Button($r('app.string.session_rename_confirm'))
              .fontSize(15)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .enabled(!this.isRenaming)
              .onClick(() => {
                this.confirmRename();
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

  /** 删除确认弹窗 */
  @Builder
  deleteConfirmDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.session_delete_confirm_title'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          Text($r('app.string.session_delete_confirm_message'))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ bottom: 20 })

          Row() {
            Button($r('app.string.session_delete_confirm_cancel'))
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1)
              .height(40)
              .enabled(!this.isDeleting)
              .onClick(() => {
                this.cancelDelete();
              })

            Button($r('app.string.session_delete_confirm_ok'))
              .fontSize(14)
              .backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White)
              .borderRadius($r('app.float.app_radius_sm'))
              .layoutWeight(1)
              .height(40)
              .margin({ left: 12 })
              .enabled(!this.isDeleting)
              .onClick(() => {
                this.confirmDelete();
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

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(ThemePalette.accentColor(this.effectiveTheme))
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  errorView() {
    Column() {
      EmptyStateView({
        title: $r('app.string.tab_sessions_load_failed'),
        description: this.initError
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  // ===== T-CHAT.1: 聊天归档导入导出方法 =====

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
   * T-CHAT.1: 启动导入流程。
   * 1. 打开文件选择器
   * 2. 读取并校验文件
   * 3. 生成预览
   * 4. 显示预览弹窗
   *
   * 用户取消不显示错误。
   */
  private async startImportFlow(): Promise<void> {
    if (this.archiveBusy) {
      return;
    }
    // 当前角色 ID(用于匹配判断,无角色传空)
    const currentCharId: string = '';
    this.archiveBusy = true;
    try {
      const vm: ChatArchiveViewModel = this.ensureArchiveViewModel();
      const ok: boolean = await vm.startImportFlow(currentCharId);
      if (!ok) {
        // 用户取消或出错
        if (vm.errorMessage.length > 0) {
          promptAction.showToast({ message: vm.errorMessage, duration: 2500 });
        }
        vm.resetState();
        return;
      }
      // 预览就绪,显示预览弹窗
      this.showImportPreview = true;
    } catch (e) {
      Logger.error(LOG_TAG_SESSION, 'startImportFlow failed: ' + (e as Error).message);
      promptAction.showToast({
        message: (e as Error).message ?? '导入失败',
        duration: 2500
      });
    } finally {
      this.archiveBusy = false;
    }
  }

  /**
   * T-CHAT.1: 确认导入。
   * 将预览数据写入数据库,显示结果弹窗。
   */
  private async confirmImportAction(): Promise<void> {
    if (this.archiveBusy) {
      return;
    }
    const vm: ChatArchiveViewModel | null = this.archiveViewModel;
    if (vm === null || vm.previewPayload === null) {
      promptAction.showToast({ message: '没有可导入的预览数据', duration: 1500 });
      return;
    }
    this.archiveBusy = true;
    try {
      const ok: boolean = await vm.confirmImport();
      // 关闭预览弹窗
      this.showImportPreview = false;
      if (ok) {
        // 显示结果弹窗
        this.showImportResult = true;
      } else {
        promptAction.showToast({ message: vm.errorMessage, duration: 2500 });
      }
    } catch (e) {
      this.showImportPreview = false;
      promptAction.showToast({
        message: (e as Error).message ?? '导入失败',
        duration: 2500
      });
    } finally {
      this.archiveBusy = false;
    }
  }

  /**
   * T-CHAT.1: 取消导入预览。
   */
  private cancelImportPreview(): void {
    if (this.archiveBusy) {
      return;
    }
    this.showImportPreview = false;
    if (this.archiveViewModel !== null) {
      this.archiveViewModel!.cancelImport();
    }
  }

  /**
   * T-CHAT.1: 关闭导入结果弹窗,刷新会话列表。
   */
  private closeImportResult(): void {
    this.showImportResult = false;
    if (this.archiveViewModel !== null) {
      this.archiveViewModel!.resetState();
    }
    // 刷新会话列表
    if (this.viewModel !== null) {
      this.viewModel!.reload()
        .then((): void => {
          this.sessions = this.viewModel!.sessions;
        })
        .catch((): void => {});
    }
  }

  /**
   * T-CHAT.1: 查看导入的聊天(跳转到第一个导入的对话)。
   */
  private viewImportedChats(): void {
    const vm: ChatArchiveViewModel | null = this.archiveViewModel;
    if (vm === null || vm.importResult === null) {
      return;
    }
    const ids: string[] = vm.importResult.importedConversationIds;
    if (ids.length === 0) {
      this.closeImportResult();
      return;
    }
    const firstId: string = ids[0];
    this.showImportResult = false;
    vm.resetState();
    // 跳转到第一个导入的对话
    AppStorage.setOrCreate<string>(PENDING_CHAT_ID_KEY, firstId);
    AppStorage.set<string>(PENDING_CHARACTER_ID_KEY, '');
    router.pushUrl({ url: 'pages/ChatPage' });
  }

  /**
   * T-CHAT.1: 关闭长按导出弹窗。
   */
  private closeExportDialog(): void {
    this.exportTarget = null;
  }

  /**
   * T-CHAT.1: 长按导出 - 导出当前选中的单个对话。
   */
  private async exportSelectedChat(): Promise<void> {
    const target: ChatSessionListItem | null = this.exportTarget;
    if (target === null) {
      return;
    }
    if (this.archiveBusy) {
      return;
    }
    this.archiveBusy = true;
    this.exportTarget = null;
    try {
      const vm: ChatArchiveViewModel = this.ensureArchiveViewModel();
      const charName: string = resolveCharacterDisplayName(target.character);
      const title: string = target.chat.title.length > 0 ? target.chat.title : charName;
      const ok: boolean = await vm.exportCurrentConversation({
        conversationId: target.chat.id,
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
   * T-CHAT.1: 长按导出 - 导出该对话所属角色的全部聊天。
   */
  private async exportSelectedCharacterChats(): Promise<void> {
    const target: ChatSessionListItem | null = this.exportTarget;
    if (target === null) {
      return;
    }
    if (target.character === null || target.character!.id.length === 0) {
      promptAction.showToast({ message: '该对话无关联角色,无法导出全部聊天', duration: 1500 });
      return;
    }
    if (this.archiveBusy) {
      return;
    }
    this.archiveBusy = true;
    this.exportTarget = null;
    try {
      const vm: ChatArchiveViewModel = this.ensureArchiveViewModel();
      const ok: boolean = await vm.exportCharacterConversations({
        characterId: target.character!.id,
        characterName: target.character!.name
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
   * 格式化时间戳为 YYYY-MM-DD HH:mm。
   */
  private formatArchiveTime(ts: number): string {
    if (ts <= 0) {
      return '未知';
    }
    const d: Date = new Date(ts);
    const year: number = d.getFullYear();
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    const hour: string = d.getHours().toString().padStart(2, '0');
    const minute: string = d.getMinutes().toString().padStart(2, '0');
    return year + '-' + month + '-' + day + ' ' + hour + ':' + minute;
  }

  // ===== T-CHAT.1: Builder =====

  /**
   * T-CHAT.1: 长按导出选择弹窗。
   */
  @Builder
  exportChatDialog() {
    Stack() {
      Column() {
        Column() {
          Text('导出聊天')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 16 })

          if (this.exportTarget !== null) {
            Text(this.exportTarget!.chat.title.length > 0
              ? this.exportTarget!.chat.title
              : (this.exportTarget!.character !== null ? this.exportTarget!.character!.name : '新对话'))
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ bottom: 16 })
          }

          // 导出当前对话
          Button('导出当前对话')
            .fontSize(15)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .enabled(!this.archiveBusy)
            .onClick(() => {
              this.exportSelectedChat();
            })

          // 导出该角色全部对话(有关联角色时显示)
          if (this.exportTarget !== null
            && this.exportTarget!.character !== null
            && this.exportTarget!.character!.id.length > 0) {
            Button('导出该角色全部对话')
              .fontSize(15)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .width('100%')
              .height(44)
              .margin({ top: 12 })
              .enabled(!this.archiveBusy)
              .onClick(() => {
                this.exportSelectedCharacterChats();
              })
          }

          // 取消
          Button('取消')
            .fontSize(15)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .height(44)
            .margin({ top: 12 })
            .enabled(!this.archiveBusy)
            .onClick(() => {
              this.closeExportDialog();
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
    .onClick(() => {
      if (!this.archiveBusy) {
        this.closeExportDialog();
      }
    })
  }

  /**
   * T-CHAT.1: 导入预览弹窗。
   * 显示归档文件信息、统计、角色匹配,用户选择角色并确认导入。
   */
  @Builder
  importPreviewDialog() {
    Stack() {
      Column() {
        Column() {
          Text('导入聊天预览')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })

          // 预览内容(archiveViewModel 已就绪)
          if (this.archiveViewModel !== null
            && this.archiveViewModel!.previewPayload !== null) {
            this.importPreviewContent()
          } else {
            Text('正在读取文件...')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ bottom: 16 })
          }
        }
        .width('88%')
        .constraintSize({ maxHeight: '80%' })
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

  /**
   * T-CHAT.1: 导入预览内容(统计 + 角色选择 + 重复提示 + 操作按钮)。
   */
  @Builder
  importPreviewContent() {
    Scroll() {
      Column() {
        // 文件信息
        this.previewRow('文件名', this.archiveViewModel!.previewPayload!.stats.fileName);
        this.previewRow('格式版本', 'v' + String(this.archiveViewModel!.previewPayload!.stats.version));
        this.previewRow('文件大小', this.formatFileSize(this.archiveViewModel!.previewPayload!.stats.fileSize));
        this.previewRow('导出时间', this.formatArchiveTime(this.archiveViewModel!.previewPayload!.stats.exportedAt));
        this.previewRow('来源角色', this.archiveViewModel!.previewPayload!.stats.sourceCharacterName.length > 0
          ? this.archiveViewModel!.previewPayload!.stats.sourceCharacterName
          : '无');

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

        // 统计信息
        this.previewRow('对话数量', String(this.archiveViewModel!.previewPayload!.stats.conversationCount));
        this.previewRow('消息总数', String(this.archiveViewModel!.previewPayload!.stats.messageCount));
        this.previewRow('分支数量', String(this.archiveViewModel!.previewPayload!.stats.branchCount));
        this.previewRow('候选总数', String(this.archiveViewModel!.previewPayload!.stats.candidateCount));
        this.previewRow('最早消息', this.formatArchiveTime(this.archiveViewModel!.previewPayload!.stats.earliestMessageAt));
        this.previewRow('最晚消息', this.formatArchiveTime(this.archiveViewModel!.previewPayload!.stats.latestMessageAt));
        this.previewRow('包含 system', this.archiveViewModel!.previewPayload!.stats.hasSystemMessage ? '是' : '否');
        this.previewRow('包含分支', this.archiveViewModel!.previewPayload!.stats.hasBranches ? '是' : '否');
        if (this.archiveViewModel!.previewPayload!.stats.hasUnknownFields) {
          this.previewRow('未知字段', '是(将忽略)');
        }

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

        // 重复提示
        if (this.hasDuplicateWarning()) {
          Text('该聊天可能已经导入。仍可导入为新对话。')
            .fontSize(13)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .margin({ bottom: 8 })
        }

        // 角色选择
        Text('选择目标角色:')
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 8 })

        // 匹配角色优先显示
        if (this.archiveViewModel!.matchedCharacters.length > 0) {
          ForEach(this.archiveViewModel!.matchedCharacters, (c: Character) => {
            this.characterOptionRow(c, '匹配')
          }, (c: Character) => 'matched_' + c.id)
        }

        // 全部角色(手动选择,排除已匹配的)
        if (this.getUnmatchedCharacters().length > 0) {
          ForEach(this.getUnmatchedCharacters(), (c: Character) => {
            this.characterOptionRow(c, '')
          }, (c: Character) => 'all_' + c.id)
        }

        if (this.archiveViewModel!.allCharacters.length === 0) {
          Text('未找到现有角色,将以无角色方式导入。')
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 8 })
        }

        // 无角色选项
        Row() {
          Radio({ value: 'none', group: 'importChar' })
            .checked(this.archiveViewModel!.selectedCharacterId.length === 0)
            .onChange((checked: boolean) => {
              if (checked && this.archiveViewModel !== null) {
                this.archiveViewModel!.selectedCharacterId = '';
              }
            })
          Text('不绑定角色')
            .fontSize(14)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ left: 8 })
        }
        .width('100%')
        .height(44)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          if (this.archiveViewModel !== null) {
            this.archiveViewModel!.selectedCharacterId = '';
          }
        })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 12, bottom: 12 })

        // 操作按钮
        Row() {
          Button('取消')
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .layoutWeight(1)
            .height(40)
            .enabled(!this.archiveBusy)
            .onClick(() => {
              this.cancelImportPreview();
            })
          Button('导入为新对话')
            .fontSize(15)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius($r('app.float.app_radius_sm'))
            .layoutWeight(1)
            .height(40)
            .margin({ left: 12 })
            .enabled(!this.archiveBusy)
            .onClick(() => {
              this.confirmImportAction();
            })
        }
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  /**
   * T-CHAT.1: 预览信息行(label + value)。
   */
  @Builder
  previewRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width(96)
      Text(value)
        .fontSize(13)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(28)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * T-CHAT.1: 角色选择行(单选)。
   */
  @Builder
  characterOptionRow(c: Character, tag: string) {
    Row() {
      Radio({ value: c.id, group: 'importChar' })
        .checked(this.archiveViewModel !== null
          && this.archiveViewModel!.selectedCharacterId === c.id)
        .onChange((checked: boolean) => {
          if (checked && this.archiveViewModel !== null) {
            this.archiveViewModel!.selectedCharacterId = c.id;
          }
        })
      Text(c.name)
        .fontSize(14)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .margin({ left: 8 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (tag.length > 0) {
        Text(tag)
          .fontSize(11)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.archiveViewModel !== null) {
        this.archiveViewModel!.selectedCharacterId = c.id;
      }
    })
  }

  /**
   * T-CHAT.1: 导入结果弹窗。
   */
  @Builder
  importResultDialog() {
    Stack() {
      Column() {
        Column() {
          if (this.archiveViewModel !== null && this.archiveViewModel!.importResult !== null) {
            Text('导入完成')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .margin({ bottom: 12 })

            // 总览
            Text('已导入 ' + String(this.archiveViewModel!.importResult!.successCount) + ' 个对话,共 '
              + String(this.archiveViewModel!.importResult!.totalMessageCount) + ' 条消息。')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ bottom: 12 })

            // 失败详情
            if (this.archiveViewModel!.importResult!.failedCount > 0) {
              Text('失败: ' + String(this.archiveViewModel!.importResult!.failedCount) + ' 个对话')
                .fontSize(13)
                .fontColor($r('app.color.app_danger'))
                .width('100%')
                .margin({ bottom: 8 })

              // 展开失败原因
              ForEach(this.archiveViewModel!.importResult!.conversationResults, (r: ChatArchiveImportConversationResult, index: number) => {
                if (!r.success) {
                  Row() {
                    Text(r.sourceTitle.length > 0 ? r.sourceTitle : '(无标题)')
                      .fontSize(12)
                      .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(r.errorMessage)
                      .fontSize(12)
                      .fontColor($r('app.color.app_danger'))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(2)
                  }
                  .width('100%')
                  .margin({ bottom: 4 })
                }
              }, (r: ChatArchiveImportConversationResult, index: number) => 'fail_' + String(index))
            }

            Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 12, bottom: 12 })

            // 操作按钮
            Row() {
              Button('关闭')
                .fontSize(15)
                .backgroundColor(Color.Transparent)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .layoutWeight(1)
                .height(40)
                .onClick(() => {
                  this.closeImportResult();
                })
              if (this.archiveViewModel!.importResult!.importedConversationIds.length > 0) {
                Button('查看导入的聊天')
                  .fontSize(15)
                  .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
                  .fontColor($r('app.color.app_on_accent'))
                  .borderRadius($r('app.float.app_radius_sm'))
                  .layoutWeight(1)
                  .height(40)
                  .margin({ left: 12 })
                  .onClick(() => {
                    this.viewImportedChats();
                  })
              }
            }
            .width('100%')
          } else {
            Text('无导入结果')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ bottom: 16 })
            Button('关闭')
              .fontSize(15)
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .width('100%')
              .height(40)
              .onClick(() => {
                this.closeImportResult();
              })
          }
        }
        .width('85%')
        .constraintSize({ maxHeight: '80%' })
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

  /**
   * T-CHAT.1: 检查预览中是否存在可能重复的对话。
   */
  private hasDuplicateWarning(): boolean {
    if (this.archiveViewModel === null || this.archiveViewModel!.previewPayload === null) {
      return false;
    }
    const dups = this.archiveViewModel!.previewPayload!.duplicates;
    for (let i: number = 0; i < dups.length; i++) {
      if (dups[i].possiblyDuplicate) {
        return true;
      }
    }
    return false;
  }

  /**
   * T-CHAT.1: 获取未匹配的全部角色列表(排除已匹配角色)。
   */
  private getUnmatchedCharacters(): Character[] {
    if (this.archiveViewModel === null) {
      return [];
    }
    const result: Character[] = [];
    const all: Character[] = this.archiveViewModel!.allCharacters;
    const matched: Character[] = this.archiveViewModel!.matchedCharacters;
    for (let i: number = 0; i < all.length; i++) {
      const c: Character = all[i];
      let isMatched: boolean = false;
      for (let j: number = 0; j < matched.length; j++) {
        if (matched[j].id === c.id) {
          isMatched = true;
          break;
        }
      }
      if (!isMatched) {
        result.push(c);
      }
    }
    return result;
  }

  /**
   * T-CHAT.1: 格式化文件大小。
   */
  private formatFileSize(size: number): string {
    if (size < 1024) {
      return String(size) + ' B';
    }
    if (size < 1024 * 1024) {
      return (size / 1024).toFixed(1) + ' KB';
    }
    return (size / (1024 * 1024)).toFixed(2) + ' MB';
  }
}
