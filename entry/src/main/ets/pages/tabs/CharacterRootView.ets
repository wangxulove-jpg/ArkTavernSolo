/**
 * CharacterRootView 角色卡 Tab 根视图(UI-3B)
 *
 * 重新设计后的角色卡首页:
 * - 顶部标题栏:标题"角色卡" + 右上角"导入"按钮(导航到 CharacterListPage 用导入流程)
 * - 所有角色以展开式卡片展示
 * - 每张角色卡显示图片、名称、简介
 * - 角色卡支持左滑显示三个操作:新建对话 / 编辑 / 删除
 * - 同一时间只展开一张角色卡(由 List swipeAction 默认行为保证)
 * - 点击角色卡或角色图片 -> 直接进入全屏 CharacterEditPage(UI-3B-2)
 * - 左滑"新建对话" -> 通过 pendingCharacterId 让 ChatPage 用该角色创建新会话
 * - 左滑"编辑" -> 直接进入全屏 CharacterEditPage
 * - 左滑"删除" -> 弹出二次确认(含角色名)
 * - 底部保留现有 HdsTabs 沉浸光感导航栏
 *
 * 复用:
 * - CharacterListViewModel 仅用于加载列表和删除角色
 * - 新建/编辑角色流程已迁移到 CharacterEditPage(不再走底部弹窗)
 */

import { CharacterListViewModel } from '../../viewmodels/CharacterListViewModel';
import { CharacterExportViewModel, CharacterExportFormat, CharacterExportResult } from '../../viewmodels/CharacterExportViewModel';
import { Character } from '../../models/Character';
import { AppServices } from '../../services/AppServices';
import { EmptyStateView } from '../../components/EmptyStateView';
import { PressableCard } from '../../components/PressableCard';
import { CharacterImageView } from '../../components/CharacterImageView';
import { router, promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { fileIo } from '@kit.CoreFileKit';
import { ThemePalette } from '../../theme/ThemePalette';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'CharacterRootView';

/** v50: 角色卡 Tab 布局模式持久化 key(list=列表,grid=宫格) */
const CHARACTER_LAYOUT_MODE_KEY: string = 'character_tab_layout_mode';

/** v50: 布局方式选项(后续扩展新的排列方式时在此追加) */
class LayoutOptionItem {
  mode: string = '';
  label: string = '';
}

const LAYOUT_OPTIONS: LayoutOptionItem[] = [
  { mode: 'list', label: '列表' },
  { mode: 'grid', label: '宫格' }
];

/** v50: 宫格卡片位置(x/y 为 Grid 内容坐标, w/h 为宽高) */
interface CharCardPos {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 角色编辑页路由参数,携带 characterId */
interface CharacterEditNavParam {
  characterId: string;
}

/** 左滑矩阵单元格参数 */
interface SwipeGridCellParams {
  icon: Resource;
  label: Resource;
  bgColor: ResourceColor;
  fgColor: ResourceColor;
  disabled: boolean;
  action: () => void;
}

@Component
export struct CharacterRootView {
  @State viewModel: CharacterListViewModel | null = null;
  /**
   * 组件本地角色列表(@State 直接装饰数组,赋值新数组即触发 ForEach 重渲染)。
   * 说明:@State 装饰 `ViewModel | null` 联合类型时,对 @Observed 实例属性的观察不可靠,
   * 因此显式维护本地 characters 数组,在每次 load 后同步(与 ChatSessionRootView 一致)。
   */
  @State characters: Character[] = [];
  /**
   * 列表刷新计数:每次 reload 后递增并拼进 ForEach key,
   * 强制 ForEach 用新 key 重建所有列表项,避免组件复用导致图片/文本不刷新。
   */
  @State refreshKey: number = 0;
  @State isInitializing: boolean = true;
  @State initError: string = '';
  /** 删除二次确认的目标角色(null 时确认弹窗不显示) */
  @State deleteTarget: Character | null = null;
  /** 导出格式选择弹窗的目标角色(null 时不显示弹窗) */
  @State exportTarget: Character | null = null;
  /** 导出进行中(禁用按钮防止重复点击) */
  @State isExporting: boolean = false;
  /** 当前展开左滑菜单的角色 ID(null 表示全部收起) */
  @State expandedCharId: string | null = null;
  /** 搜索关键词(本地过滤,不修改 domain 数据) */
  @State searchText: string = '';
  /** v50: 布局模式:list=列表,grid=宫格(N×2) */
  @State layoutMode: string = 'list';
  /** v50: 是否显示布局方式选择弹层 */
  @State showLayoutMenu: boolean = false;
  // ===== v50: 宫格拖拽重排状态 =====
  /** 正在拖拽的角色 id(空=未拖拽) */
  @State dragCharId: string = '';
  /** 拖拽悬停目标角色 id(空=无目标,用于高亮) */
  @State dragCharTargetId: string = '';
  /** 拖拽悬停目标下标(-1=无目标,用于实时让位动画) */
  @State dragCharTargetIndex: number = -1;
  /** 是否正在拖拽 */
  @State isCharDragging: boolean = false;
  /** 拖拽预览跟随手指的垂直偏移 */
  @State charDragOffsetY: number = 0;
  /** 拖拽预览跟随手指的水平偏移 */
  @State charDragOffsetX: number = 0;
  /** 拖拽起点:手指窗口 Y */
  @State charDragFingerStartGlobalY: number = 0;
  /** 拖拽起点:手指窗口 X */
  @State charDragFingerStartGlobalX: number = 0;
  /** 页面宽度(vp,根 Stack onAreaChange 实测,用于预览宽度/越界钳制) */
  @State charGridPageWidth: number = 0;
  /** v50: 当前打开操作菜单的角色 id(空=关闭) */
  @State charActionMenuId: string = '';
  /** 拖拽中的角色卡位置缓存:charId → 位置(Grid 内容坐标) */
  private charPosMap: Map<string, CharCardPos> = new Map<string, CharCardPos>();
  /** v50: 长按触发拖拽后抑制本次点击打开编辑页(下次触摸 Down 复位) */
  @State charDragSuppressOpen: boolean = false;
  /** v50: 拖拽预览角色(整卡预览) */
  @State charDragPreviewItem: Character | null = null;
  /** List 滚动控制器,用于点击操作后收起 swipeAction */
  private listScroller: ListScroller = new ListScroller();
  /**
   * 跨页面列表刷新信号。
   * 由 CharacterEditPage / CharacterListPage 在角色数据变化后递增,
   * 触发本组件 onListVersionChange 回调重新 load。
   *
   * 说明:本组件作为 HdsTabs 的 TabContent 嵌入,非 @Entry 也非 NavDestination,
   * 因此 onPageShow 不会被调用;改用 AppStorage 计数器 + @Watch 监听二级页面变化。
   */
  @StorageProp('characterListVersion') @Watch('onListVersionChange') characterListVersion: number = 0;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      await this.loadLayoutModePref();
      const charService = AppServices.getCharacterService();
      const vm: CharacterListViewModel = new CharacterListViewModel(charService);
      this.viewModel = vm;
      await vm.load();
      this.characters = vm.characters;
      this.refreshKey++;
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      this.initError = (e as Error).message ?? '';
    }
  }

  /** characterListVersion 变化时刷新列表(从编辑页/导入页返回后自动刷新) */
  private onListVersionChange(): void {
    Logger.info(LOG_TAG, 'onListVersionChange fired, version=' + this.characterListVersion.toString());
    if (this.isInitializing) {
      return;
    }
    if (this.viewModel === null || !AppServices.isStarted()) {
      return;
    }
    this.viewModel!.load()
      .then((): void => {
        this.characters = this.viewModel!.characters;
        this.refreshKey++;
        Logger.info(LOG_TAG, 'onListVersionChange reload done, count=' + this.characters.length.toString()
          + ' refreshKey=' + this.refreshKey.toString());
      })
      .catch((): void => {});
  }

  /** 同步 viewModel.characters 到本地 @State characters(触发 ForEach 重渲染) */
  private syncCharacters(): void {
    if (this.viewModel !== null) {
      this.characters = this.viewModel!.characters;
      this.refreshKey++;
    }
  }

  /** v50: 加载上次保存的布局模式(默认列表)。 */
  private async loadLayoutModePref(): Promise<void> {
    try {
      const prefs = AppServices.getAppPreferences();
      const mode: string = await prefs.getString(CHARACTER_LAYOUT_MODE_KEY, 'list');
      this.layoutMode = mode === 'grid' ? 'grid' : 'list';
    } catch (_e) {
      this.layoutMode = 'list';
    }
  }

  /** v50: 切换布局模式并持久化。 */
  private setLayoutMode(mode: string): void {
    this.layoutMode = mode;
    const prefs = AppServices.getAppPreferences();
    prefs.putString(CHARACTER_LAYOUT_MODE_KEY, mode).catch((_e: Object): void => {});
  }

  /** 本地搜索过滤(匹配 name/description/personality/tags,大小写不敏感) */
  private filteredCharacters(): Character[] {
    const keyword: string = this.searchText.trim().toLowerCase();
    if (keyword.length === 0) {
      return this.characters;
    }
    const result: Character[] = [];
    const all: Character[] = this.characters;
    for (let i = 0; i < all.length; i++) {
      const c: Character = all[i];
      if (c.name.toLowerCase().indexOf(keyword) >= 0
        || c.description.toLowerCase().indexOf(keyword) >= 0
        || c.personality.toLowerCase().indexOf(keyword) >= 0
        || c.scenario.toLowerCase().indexOf(keyword) >= 0) {
        result.push(c);
        continue;
      }
      // 标签匹配
      const tags: string[] = c.tags;
      let tagMatch: boolean = false;
      for (let t = 0; t < tags.length; t++) {
        if (tags[t].toLowerCase().indexOf(keyword) >= 0) {
          tagMatch = true;
          break;
        }
      }
      if (tagMatch) {
        result.push(c);
      }
    }
    return result;
  }

  /** 格式化角色更新时间(YYYY-MM-DD) */
  private formatCharacterDate(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const d: Date = new Date(ts);
    const year: number = d.getFullYear();
    const month: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    return year + '-' + month + '-' + day;
  }

  // ===== 跳转 / 操作 =====

  /** 点击角色卡:直接进入全屏 CharacterEditPage 编辑该角色 */
  private openCharacterDetail(characterId: string): void {
    const navParam: CharacterEditNavParam = { characterId: characterId };
    router.pushUrl({
      url: 'pages/CharacterEditPage',
      params: { param: navParam }
    });
  }

  /** 左滑"新建对话":用该角色创建新会话并跳转 ChatPage(不修改全局当前角色) */
  private startNewChatWithCharacter(characterId: string): void {
    AppStorage.setOrCreate<string>('pendingCharacterId', characterId);
    // 清除 pendingChatId 防止冲突(优先级:pendingChatId > pendingCharacterId)
    AppStorage.setOrCreate<string>('pendingChatId', '');
    router.pushUrl({ url: 'pages/ChatPage' });
  }

  /** 左滑"编辑":与点击角色卡相同,直接进入全屏编辑页 */
  private editCharacter(characterId: string): void {
    this.openCharacterDetail(characterId);
  }

  /** 左滑"删除":弹出二次确认 */
  private promptDelete(char: Character): void {
    this.deleteTarget = char;
  }

  /** 确认删除:复用 CharacterListViewModel.deleteCharacter */
  private async confirmDelete(): Promise<void> {
    if (this.viewModel === null || this.deleteTarget === null) {
      this.deleteTarget = null;
      return;
    }
    const id: string = this.deleteTarget.id;
    this.deleteTarget = null;
    await this.viewModel!.deleteCharacter(id);
    this.syncCharacters();
    // 删除失败时明确提示(deleteCharacter 内部捕获异常,这里读取 errorMessage 展示)
    if (this.viewModel!.errorMessage.length > 0) {
      promptAction.showToast({
        message: this.viewModel!.errorMessage,
        duration: 2500
      });
    }
  }

  /** 取消删除 */
  private cancelDelete(): void {
    this.deleteTarget = null;
  }

  /** 删除确认主问题(显示角色名,副说明"此操作不可撤销"由弹窗正文单独展示) */
  private formatDeleteMessage(name: string): string {
    return '确定删除角色"' + name + '"吗?';
  }

  // ===== 导出 =====

  /** 左滑"导出":弹出格式选择 */
  private promptExport(char: Character): void {
    if (this.isExporting) {
      return;
    }
    this.exportTarget = char;
  }

  /** 取消导出选择 */
  private cancelExport(): void {
    if (this.isExporting) {
      return;
    }
    this.exportTarget = null;
  }

  /** 选择 PNG 导出 */
  private async chooseExportPng(): Promise<void> {
    if (this.exportTarget === null || this.isExporting) {
      return;
    }
    const char: Character = this.exportTarget;
    this.exportTarget = null;
    await this.runExport(char, CharacterExportFormat.V2Png);
  }

  /** 选择 JSON 导出 */
  private async chooseExportJson(): Promise<void> {
    if (this.exportTarget === null || this.isExporting) {
      return;
    }
    const char: Character = this.exportTarget;
    this.exportTarget = null;
    await this.runExport(char, CharacterExportFormat.V2Json);
  }

  /**
   * 执行导出:调用 ViewModel 生成数据 + 系统文件保存器选择位置 + 写入文件。
   * 用户取消 picker 时不报错。
   */
  private async runExport(char: Character, format: CharacterExportFormat): Promise<void> {
    if (this.isExporting) {
      return;
    }
    this.isExporting = true;
    try {
      const exportVm: CharacterExportViewModel = new CharacterExportViewModel(
        AppServices.getCharacterService()
      );
      const result: CharacterExportResult =
        format === CharacterExportFormat.V2Png
          ? await exportVm.exportToPng(char.id, char.name)
          : await exportVm.exportToJson(char.id, char.name);
      if (!result.success) {
        promptAction.showToast({
          message: $r('app.string.character_export_failed'),
          duration: 2000
        });
        return;
      }
      // 调用系统文件保存器
      let uri: string = '';
      try {
        const documentPicker = new picker.DocumentViewPicker();
        const options = new picker.DocumentSaveOptions();
        options.newFileNames = [result.defaultFileName];
        const uris: string[] = await documentPicker.save(options);
        if (uris.length === 0) {
          // 用户取消,不报错
          return;
        }
        uri = uris[0];
      } catch (e) {
        promptAction.showToast({
          message: $r('app.string.character_export_failed'),
          duration: 2000
        });
        return;
      }
      // 写入文件
      try {
        if (format === CharacterExportFormat.V2Json) {
          await this.writeJsonToFile(uri, result.jsonString);
        } else {
          await this.writePngBytesToFile(uri, result.pngBytes);
        }
        promptAction.showToast({
          message: $r('app.string.character_export_success'),
          duration: 1500
        });
      } catch (e) {
        promptAction.showToast({
          message: $r('app.string.character_export_failed'),
          duration: 2000
        });
      }
    } finally {
      this.isExporting = false;
    }
  }

  /** 写入 JSON 文本到文件(复用 CharacterService.writeFileContent 的 UTF-8 编码能力) */
  private async writeJsonToFile(uri: string, jsonString: string): Promise<void> {
    await AppServices.getCharacterService().writeFileContent(uri, jsonString);
  }

  /** 写入 PNG 字节到文件 */
  private async writePngBytesToFile(uri: string, bytes: Uint8Array): Promise<void> {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, bytes.buffer as ArrayBuffer);
    } finally {
      fileIo.closeSync(file);
    }
  }

  build() {
    Stack() {
      Column() {
        // ===== 顶部栏:标题 + 右侧紧凑搜索 + 导入 =====
        Row() {
          Text($r('app.string.tab_characters'))
            .fontSize($r('app.float.app_font_title'))
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          // 紧凑搜索框(角色卡标题右侧,本地过滤不修改数据库)
          Row() {
            TextInput({
              placeholder: $r('app.string.character_search_placeholder'),
              text: this.searchText
            })
              .fontSize(13)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .backgroundColor(Color.Transparent)
              .height(32)
              .padding({ left: 4, right: 4 })
              .layoutWeight(1)
              .onChange((value: string) => {
                this.searchText = value;
              })
          }
          .height(36)
          .padding({ left: 12, right: 12 })
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(18)
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)
          .margin({ left: 12, right: 12 })

          // v50: 布局方式选择按钮(点击弹出选项,便于后续扩展更多排列方式)
          Button() {
            Row() {
              SymbolGlyph($r('sys.symbol.square_grid_2x2'))
                .fontSize(14)
                .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
              Text(this.layoutMode === 'grid' ? '宫格' : '列表')
                .fontSize(12)
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .margin({ left: 4 })
            }
            .alignItems(VerticalAlign.Center)
          }
          .type(ButtonType.Normal)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(16)
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.showLayoutMenu = true;
          })

          // 导入按钮(新建角色 / 文件导入二选一)
          Button($r('app.string.character_import'))
            .fontSize($r('app.float.app_font_body'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent)
            .height(36)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/AddCharacterPage' });
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: this.statusBarHeight + 8, bottom: 8 })
        .alignItems(VerticalAlign.Center)

        // ===== 错误提示 =====
        if (this.viewModel !== null && this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_20'),
              right: $r('app.float.app_spacing_20'),
              top: $r('app.float.app_spacing_4'),
              bottom: $r('app.float.app_spacing_4')
            })
        }

        // ===== 主内容区 =====
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.initError.length > 0) {
          this.errorView()
        } else if (this.viewModel === null || this.characters.length === 0) {
          this.emptyStateView()
        } else if (this.layoutMode === 'grid') {
          this.characterGrid()
        } else {
          this.characterList()
        }
      }
      .width('100%')
      .height('100%')
      // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      // ===== 删除二次确认弹窗(浮层)=====
      this.deleteConfirmDialog()

      // ===== 导出格式选择弹窗(浮层)=====
      this.exportFormatDialog()

      // v50: 布局方式选择弹层(浮层)
      this.layoutMenuDialog()

      // v50: 角色操作菜单弹层(浮层)
      this.charActionMenuDialog()

      // v50: 宫格拖拽浮动预览(浮层)
      if (this.isCharDragging) {
        this.characterDragPreview()
      }
    }
    .width('100%')
    .height('100%')
    // 背景层分离:不设 backgroundColor,让 Index 根背景透出。
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    // v50: 记录页面实际宽度(vp),供宫格拖拽预览 1:1 尺寸与横向钳制
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      if (typeof newValue.width === 'number') {
        this.charGridPageWidth = newValue.width as number;
      }
    })
  }

  // ===== 角色列表(支持左滑) =====

  /** v50: 布局方式选择弹层(点击按钮弹出,选项驱动,便于扩展)。 */
  @Builder
  layoutMenuDialog() {
    if (this.showLayoutMenu) {
      Stack() {
        Column() {
          Text('排列方式')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ bottom: 12 })

          ForEach(LAYOUT_OPTIONS, (opt: LayoutOptionItem) => {
            Row() {
              Text(opt.label)
                .fontSize(15)
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .layoutWeight(1)
              if (this.layoutMode === opt.mode) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(15)
                  .fontColor([ThemePalette.accentColor(this.effectiveTheme)])
              }
            }
            .width('100%')
            .height(44)
            .padding({ left: 4, right: 4 })
            .alignItems(VerticalAlign.Center)
            .borderRadius(8)
            .backgroundColor(this.layoutMode === opt.mode
              ? ThemePalette.surface2Color(this.effectiveTheme)
              : Color.Transparent)
            .onClick(() => {
              this.setLayoutMode(opt.mode);
              this.showLayoutMenu = false;
            })
          }, (opt: LayoutOptionItem) => opt.mode)
        }
        .width('70%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.5)')
      .onClick(() => {
        this.showLayoutMenu = false;
      })
    }
  }

  /** v50: 角色操作菜单弹层(新建对话/编辑/导出/删除),点击 ⋯ 按钮弹出。 */
  @Builder
  charActionMenuDialog() {
    if (this.charActionMenuId.length > 0 && this.findCharById(this.charActionMenuId) !== null) {
      Stack() {
        Column() {
          Text(this.findCharById(this.charActionMenuId)!.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ bottom: 12 })

          this.actionMenuItem($r('app.string.character_action_new_chat'), () => {
            const id: string = this.charActionMenuId;
            this.charActionMenuId = '';
            this.startNewChatWithCharacter(id);
          })
          this.actionMenuItem($r('app.string.character_action_edit'), () => {
            const id: string = this.charActionMenuId;
            this.charActionMenuId = '';
            this.editCharacter(id);
          })
          this.actionMenuItem($r('app.string.character_action_export'), () => {
            const id: string = this.charActionMenuId;
            this.charActionMenuId = '';
            this.promptExport(this.findCharById(id)!);
          })
          this.actionMenuItem($r('app.string.character_action_delete'), () => {
            const id: string = this.charActionMenuId;
            this.charActionMenuId = '';
            this.promptDelete(this.findCharById(id)!);
          })
        }
        .width('70%')
        .padding(20)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_lg'))
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.5)')
      .onClick(() => {
        this.charActionMenuId = '';
      })
    }
  }

  /** v50: 操作菜单项行。 */
  @Builder
  actionMenuItem(label: ResourceStr, onSelect: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
    }
    .width('100%')
    .height(44)
    .padding({ left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
    .borderRadius(8)
    .onClick(() => {
      onSelect();
    })
  }

  // ===== v50: 角色宫格(2 列) =====

  /** 角色宫格:N×2 排列,长按卡片拖动重排。 */
  @Builder
  characterGrid() {
    Grid() {
      ForEach(this.filteredCharacters(), (char: Character) => {
        GridItem() {
          this.characterGridCard(char)
        }
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          const px: number = typeof newValue.position.x === 'number'
            ? (newValue.position.x as number) : 0;
          const py: number = typeof newValue.position.y === 'number'
            ? (newValue.position.y as number) : 0;
          const pw: number = typeof newValue.width === 'number'
            ? (newValue.width as number) : 0;
          const ph: number = typeof newValue.height === 'number'
            ? (newValue.height as number) : 0;
          // 'g_' 前缀与列表模式位置缓存隔离
          this.charPosMap.set('g_' + char.id, { x: px, y: py, w: pw, h: ph });
        })
      }, (char: Character) => char.id + '_' + this.refreshKey.toString())

      // 末尾留白:让最后一行卡片能完全滚出悬浮 TabBar 上方,确保底部卡片的
      // ⋯ 操作按钮始终可点(与列表模式末尾 spacer 同一思路)。
      GridItem() {
        Column().width('100%').height(120)
      }
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap($r('app.float.app_spacing_8'))
    .rowsGap($r('app.float.app_spacing_8'))
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: 4,
      // v50: 底部留出悬浮 TabBar 高度:Grid 的 padding 会缩小内容视口,
      // 内容区在 TabBar 上方结束,最后一行卡片不会再被 TabBar 遮挡
      bottom: 96
    })
  }

  /** 宫格卡片内容(真实卡片与拖拽预览共用,保证预览与真实卡片大小一致)。 */
  @Builder
  characterGridCardBody(char: Character) {
    Column() {
      // 图片区:撑满剩余空间,保证所有卡片图片高度一致
      Column() {
        CharacterImageView({
          imageUri: char.avatarUri,
          fallbackName: char.name,
          imgWidth: '100%',
          imgHeight: '100%',
          imgBorderRadius: 10,
          displayMode: 'portrait',
          objectFit: ImageFit.Cover
        })
      }
      .width('100%')
      .layoutWeight(1)
      .clip(true)
      .borderRadius(10)

      Row() {
        Text(char.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Start)

        // 操作菜单入口(点击弹出:新建对话/编辑/导出/删除)
        Button() {
          Text('⋯')
            .fontSize(16)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        }
        .type(ButtonType.Circle)
        .width(26)
        .height(26)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .onClick(() => {
          // v50: 用弹层菜单替代 bindMenu,避免长按手势与卡片拖拽冲突
          this.charActionMenuId = char.id;
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

      Text(this.getCharacterSummary(char))
        .fontSize(11)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(10)
  }

  /** 宫格角色卡:统一高度,长按拖动重排,拖拽时其它卡片实时让位。 */
  @Builder
  characterGridCard(char: Character) {
    Column() {
      PressableCard({
        onPress: () => {
          // v50: 长按触发拖拽后抑制本次点击,避免松手误进编辑页
          if (!this.charDragSuppressOpen) {
            this.openCharacterDetail(char.id);
          }
        },
        surfaceColor: ThemePalette.surface1Color(this.effectiveTheme)
      }) {
        this.characterGridCardBody(char)
      }
    }
    // 统一高度,略微加长,使布局和谐
    .height(240)
    .width('100%')
    .borderRadius(12)
    .border({
      width: this.isCharDragging && this.dragCharTargetId === char.id ? 2 : 0,
      color: ThemePalette.accentColor(this.effectiveTheme)
    })
    .opacity(this.isCharDragging && this.dragCharId === char.id ? 0.4 : 1.0)
    // v50: 拖拽时源卡与目标之间的卡片实时让位(translate 视觉移动)
    .translate({
      x: this.charGridShiftX(char.id),
      y: this.charGridShiftY(char.id)
    })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.charDragSuppressOpen = false;
      } else if (event.type === TouchType.Up && this.isCharDragging) {
        this.endCharDrag();
      } else if (event.type === TouchType.Cancel && this.isCharDragging) {
        this.cancelCharDrag();
      }
    })
    .gesture(
      GestureGroup(GestureMode.Sequence,
        LongPressGesture({ repeat: false })
          .onAction((event: GestureEvent) => {
            this.beginCharDrag(char.id, event);
          }),
        PanGesture({ direction: PanDirection.All })
          .onActionUpdate((event: GestureEvent) => {
            this.charDragOffsetY = event.offsetY;
            this.charDragOffsetX = event.offsetX;
            // v50: 让位动画跟随手指实时更新
            this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
              this.recomputeCharDragTarget();
            });
          })
          .onActionEnd(() => {
            this.endCharDrag();
          })
          .onActionCancel(() => {
            this.cancelCharDrag();
          })
      )
    )
  }

  // ===== v50: 宫格拖拽重排 =====

  /** 开始拖拽:记录被拖角色与手指窗口坐标。 */
  private beginCharDrag(charId: string, event: GestureEvent): void {
    this.dragCharId = charId;
    this.dragCharTargetId = '';
    this.charDragOffsetY = 0;
    this.charDragOffsetX = 0;
    this.charDragSuppressOpen = true;
    this.charDragPreviewItem = this.findCharById(charId);
    this.isCharDragging = true;
    const finger = event.fingerList.length > 0 ? event.fingerList[0] : null;
    this.charDragFingerStartGlobalY = finger !== null && finger !== undefined
      ? finger.globalY : 0;
    this.charDragFingerStartGlobalX = finger !== null && finger !== undefined
      ? finger.globalX : 0;
  }

  /** 宫格模式:实时计算悬停目标(距离手指最近的其它卡片,含横向)。 */
  private recomputeCharDragTarget(): void {
    if (this.dragCharId.length === 0) {
      return;
    }
    const srcPos: CharCardPos | undefined = this.charPosMap.get('g_' + this.dragCharId);
    if (srcPos === undefined) {
      return;
    }
    const fingerX: number = srcPos.x + this.charDragOffsetX;
    const fingerY: number = srcPos.y + this.charDragOffsetY;
    let targetId: string = '';
    let targetIndex: number = -1;
    let bestDist: number = Number.MAX_SAFE_INTEGER;
    this.charPosMap.forEach((pos: CharCardPos, key: string): void => {
      if (!key.startsWith('g_')) {
        return;
      }
      const charId: string = key.substring(2);
      if (charId === this.dragCharId) {
        return;
      }
      const dx: number = fingerX - (pos.x + pos.w / 2);
      const dy: number = fingerY - (pos.y + pos.h / 2);
      const dist: number = dx * dx + dy * dy;
      if (dist < bestDist) {
        bestDist = dist;
        targetId = charId;
        targetIndex = this.charIndex(charId);
      }
    });
    this.dragCharTargetId = targetId;
    this.dragCharTargetIndex = targetIndex;
  }

  /** 列表模式:实时计算悬停目标(距离手指最近的其它行,仅纵向)。 */
  private recomputeCharListTarget(): void {
    if (this.dragCharId.length === 0) {
      return;
    }
    const srcPos: CharCardPos | undefined = this.charPosMap.get('l_' + this.dragCharId);
    if (srcPos === undefined) {
      return;
    }
    const fingerY: number = srcPos.y + this.charDragOffsetY;
    let targetId: string = '';
    let targetIndex: number = -1;
    let bestDist: number = Number.MAX_SAFE_INTEGER;
    this.charPosMap.forEach((pos: CharCardPos, key: string): void => {
      if (!key.startsWith('l_')) {
        return;
      }
      const charId: string = key.substring(2);
      if (charId === this.dragCharId) {
        return;
      }
      const center: number = pos.y + pos.h / 2;
      const dist: number = Math.abs(fingerY - center);
      if (dist < bestDist) {
        bestDist = dist;
        targetId = charId;
        targetIndex = this.charIndex(charId);
      }
    });
    this.dragCharTargetId = targetId;
    this.dragCharTargetIndex = targetIndex;
  }

  /** 结束拖拽:把源卡片移动到目标下标;未移动视为误触。 */
  private endCharDrag(): void {
    if (this.dragCharId.length === 0) {
      this.cancelCharDrag();
      return;
    }
    if (Math.abs(this.charDragOffsetY) < 2 && Math.abs(this.charDragOffsetX) < 2) {
      this.cancelCharDrag();
      return;
    }
    const sourceId: string = this.dragCharId;
    const targetIndex: number = this.dragCharTargetIndex;
    const sourceIndex: number = this.charIndex(sourceId);
    this.cancelCharDrag();
    if (targetIndex < 0 || targetIndex === sourceIndex || this.viewModel === null) {
      return;
    }
    void this.viewModel!.moveCharacterTo(sourceId, targetIndex).then((): void => {
      this.syncCharacters();
    });
  }

  /** 取消/清理拖拽状态。 */
  private cancelCharDrag(): void {
    this.isCharDragging = false;
    this.dragCharId = '';
    this.dragCharTargetId = '';
    this.dragCharTargetIndex = -1;
    this.charDragOffsetY = 0;
    this.charDragOffsetX = 0;
    this.charDragPreviewItem = null;
  }

  /** 按 id 查找角色(拖拽预览用)。 */
  private findCharById(id: string): Character | null {
    for (let i = 0; i < this.characters.length; i++) {
      if (this.characters[i].id === id) {
        return this.characters[i];
      }
    }
    return null;
  }

  /** v50: 角色 id → 在完整列表中的下标(-1=未找到)。 */
  private charIndex(id: string): number {
    for (let i = 0; i < this.characters.length; i++) {
      if (this.characters[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  /** v50: 宫格卡片宽度(与 Grid 两列布局一致,基于实测页面宽度)。 */
  private charGridCardWidth(): number {
    const pageWidth: number = this.charGridPageWidth > 0 ? this.charGridPageWidth : 360;
    return (pageWidth - 40) / 2;
  }

  /** v50: 拖拽预览宽度:宫格=被拖卡片实测宽度;列表=列表行宽度。保证与真实项 1:1。 */
  private charDragPreviewWidth(): number {
    if (this.layoutMode === 'grid') {
      if (this.dragCharId.length > 0) {
        const pos: CharCardPos | undefined = this.charPosMap.get('g_' + this.dragCharId);
        if (pos !== undefined && pos.w > 0) {
          return pos.w;
        }
      }
      return this.charGridCardWidth();
    }
    return this.charDragListWidth();
  }

  /** v50: 列表模式行宽度 = 页面宽度 - 列表左右 padding。 */
  private charDragListWidth(): number {
    const pageWidth: number = this.charGridPageWidth > 0 ? this.charGridPageWidth : 360;
    return pageWidth - 32;
  }

  /** v50: 拖拽预览高度:宫格=240;列表=被拖行实测高度。 */
  private charDragPreviewHeight(): number {
    if (this.layoutMode === 'grid') {
      return 240;
    }
    if (this.dragCharId.length > 0) {
      const pos: CharCardPos | undefined = this.charPosMap.get('l_' + this.dragCharId);
      if (pos !== undefined && pos.h > 0) {
        return pos.h;
      }
    }
    return 110;
  }

  /** v50: 列表模式拖拽让位:行间垂直位移(0=不动)。 */
  private charListShiftY(id: string): number {
    if (!this.isCharDragging || this.dragCharId.length === 0 || this.dragCharTargetIndex < 0) {
      return 0;
    }
    const src: number = this.charIndex(this.dragCharId);
    const cur: number = this.charIndex(id);
    const tgt: number = this.dragCharTargetIndex;
    if (src < 0 || cur < 0 || cur === src) {
      return 0;
    }
    const srcPos: CharCardPos | undefined = this.charPosMap.get('l_' + this.dragCharId);
    const rowStride: number = (srcPos !== undefined && srcPos.h > 0 ? srcPos.h : 100) + 8;
    if (tgt > src) {
      if (cur > src && cur <= tgt) {
        return -rowStride;
      }
    } else if (tgt < src) {
      if (cur >= tgt && cur < src) {
        return rowStride;
      }
    }
    return 0;
  }

  /** v50: 拖拽时该卡片应让位的水平位移(0=不动)。 */
  private charGridShiftX(id: string): number {
    if (!this.isCharDragging || this.dragCharId.length === 0 || this.dragCharTargetIndex < 0) {
      return 0;
    }
    const src: number = this.charIndex(this.dragCharId);
    const cur: number = this.charIndex(id);
    const tgt: number = this.dragCharTargetIndex;
    if (src < 0 || cur < 0 || cur === src) {
      return 0;
    }
    const slot: number = this.charGridCardWidth() + 8;
    if (tgt > src) {
      // 向下拖: (src, tgt] 上移一格
      if (cur > src && cur <= tgt) {
        return cur % 2 === 1 ? -slot : slot;
      }
    } else if (tgt < src) {
      // 向上拖: [tgt, src) 下移一格
      if (cur >= tgt && cur < src) {
        return cur % 2 === 0 ? slot : -slot;
      }
    }
    return 0;
  }

  /** v50: 拖拽时该卡片应让位的垂直位移(0=不动)。 */
  private charGridShiftY(id: string): number {
    if (!this.isCharDragging || this.dragCharId.length === 0 || this.dragCharTargetIndex < 0) {
      return 0;
    }
    const src: number = this.charIndex(this.dragCharId);
    const cur: number = this.charIndex(id);
    const tgt: number = this.dragCharTargetIndex;
    if (src < 0 || cur < 0 || cur === src) {
      return 0;
    }
    const rowStride: number = 240 + 8;
    if (tgt > src) {
      // 向下拖: 偶数列(cur 上移一格会跨到上一行)
      if (cur > src && cur <= tgt && cur % 2 === 0) {
        return -rowStride;
      }
    } else if (tgt < src) {
      // 向上拖: 奇数列(cur 下移一格会跨到下一行)
      if (cur >= tgt && cur < src && cur % 2 === 1) {
        return rowStride;
      }
    }
    return 0;
  }

  /** 浮动拖拽预览(与真实卡片/行同尺寸,跟随手指移动)。 */
  @Builder
  characterDragPreview() {
    if (this.charDragPreviewItem !== null) {
      if (this.layoutMode === 'grid') {
        // 宫格:整卡预览
        Column() {
          this.characterGridCardBody(this.charDragPreviewItem!)
        }
        .width(this.charDragPreviewWidth())
        .height(240)
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius(12)
        .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
        .opacity(0.96)
        .shadow({ radius: 16, color: '#55000000', offsetX: 0, offsetY: 8 })
        .position({
          x: this.resolveCharDragPreviewX(),
          // 根 Stack 顶部即窗口顶部(expandSafeArea TOP),直接用窗口坐标
          y: this.charDragFingerStartGlobalY + this.charDragOffsetY - 120
        })
      } else {
        // 列表:整行预览(与列表行 1:1)
        Column() {
          this.characterCard(this.charDragPreviewItem!)
        }
        .width(this.charDragPreviewWidth())
        .height(this.charDragPreviewHeight())
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius(12)
        .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
        .opacity(0.96)
        .shadow({ radius: 12, color: '#55000000', offsetX: 0, offsetY: 6 })
        .position({
          x: 16,
          y: this.charDragFingerStartGlobalY + this.charDragOffsetY - this.charDragPreviewHeight() / 2
        })
      }
    }
  }

  /** v50: 预览横向位置:跟随手指水平移动,并钳制在屏幕内。 */
  private resolveCharDragPreviewX(): number {
    const previewW: number = this.charDragPreviewWidth();
    const minX: number = 8;
    const maxX: number = this.charGridPageWidth > 0
      ? this.charGridPageWidth - previewW - 8 : 320 - previewW;
    const desired: number = this.charDragFingerStartGlobalX + this.charDragOffsetX - previewW / 2;
    if (desired < minX) {
      return minX;
    }
    if (desired > maxX) {
      return maxX;
    }
    return desired;
  }

  @Builder
  characterList() {
    List({ scroller: this.listScroller }) {
      if (this.filteredCharacters().length === 0) {
        // 搜索无结果
        ListItem() {
          Column() {
            EmptyStateView({
              title: $r('app.string.character_search_no_result'),
              description: ''
            })
          }
          .width('100%')
          .padding({ top: $r('app.float.app_spacing_48'), bottom: 160 })
        }
      } else {
        ForEach(this.filteredCharacters(), (char: Character, index: number) => {
          ListItem() {
            this.characterCard(char)
          }
          .margin({ bottom: $r('app.float.app_spacing_8') })
          // v50: 列表拖拽重排:记录行位置(与宫格缓存用 'l_' 前缀隔离)
          .onAreaChange((_oldValue: Area, newValue: Area) => {
            const py: number = typeof newValue.position.y === 'number'
              ? (newValue.position.y as number) : 0;
            const ph: number = typeof newValue.height === 'number'
              ? (newValue.height as number) : 0;
            this.charPosMap.set('l_' + char.id, { x: 0, y: py, w: 0, h: ph });
          })
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.charDragSuppressOpen = false;
            } else if (event.type === TouchType.Up && this.isCharDragging) {
              this.endCharDrag();
            } else if (event.type === TouchType.Cancel && this.isCharDragging) {
              this.cancelCharDrag();
            }
          })
          .gesture(
            GestureGroup(GestureMode.Sequence,
              LongPressGesture({ repeat: false })
                .onAction((event: GestureEvent) => {
                  this.beginCharDrag(char.id, event);
                }),
              PanGesture({ direction: PanDirection.Vertical })
                .onActionUpdate((event: GestureEvent) => {
                  this.charDragOffsetY = event.offsetY;
                  // v50: 让位动画跟随手指实时更新
                  this.getUIContext().animateTo({ duration: 150, curve: Curve.EaseOut }, () => {
                    this.recomputeCharListTarget();
                  });
                })
                .onActionEnd(() => {
                  this.endCharDrag();
                })
                .onActionCancel(() => {
                  this.cancelCharDrag();
                })
            )
          )
          // v50: 拖拽时源行与目标之间的行实时让位;源行半透明
          .translate({ y: this.charListShiftY(char.id) })
          .opacity(this.isCharDragging && this.dragCharId === char.id ? 0.4 : 1.0)
          .swipeAction({
            end: {
              builder: (): void => {
                this.swipeActionGrid(char, index)
              },
              onStateChange: (state: SwipeActionState): void => {
                if (state === SwipeActionState.EXPANDED) {
                  this.expandedCharId = char.id;
                } else if (state === SwipeActionState.COLLAPSED && this.expandedCharId === char.id) {
                  this.expandedCharId = null;
                }
              }
            }
          })
        }, (char: Character) => char.id + '_' + this.refreshKey.toString())

        // 末尾空白 ListItem:让内容总高度始终超出视口,确保即使内容少也能上下滚动(spring 回弹)。
        ListItem() {
          Column().width('100%').height(160)
        }
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // padding 0:padding 直接在 List 上会缩小视口,padding 区域不显示内容。
    // 左右 padding 通过每个 ListItem 内部布局控制。
    .padding({
      left: $r('app.float.app_spacing_16'),
      right: $r('app.float.app_spacing_16'),
      top: 0,
      bottom: 0
    })
  }

  // ===== 左滑操作区(2 行 × 3 列矩阵,位于当前角色卡右侧) =====

  /**
   * 左滑矩阵操作区。
   * 第一行:上移 / 新建对话 / 编辑
   * 第二行:下移 / 导出 / 删除
   *
   * @param char 当前角色
   * @param index 当前角色在列表中的位置(用于禁用上移/下移)
   */
  @Builder
  swipeActionGrid(char: Character, index: number) {
    Row() {
      Column() {
        // 第一行:上移 / 新建对话 / 编辑
        Row() {
          this.gridCell({
            icon: $r('sys.symbol.arrow_up'),
            label: $r('app.string.card_action_move_up'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: index === 0,
            action: (): void => {
              this.viewModel!.moveUp(char.id).then((): void => {
                this.syncCharacters();
              }).catch((): void => {});
            }
          })
          this.gridCell({
            icon: $r('sys.symbol.plus'),
            label: $r('app.string.character_action_new_chat'),
            bgColor: ThemePalette.accentColor(this.effectiveTheme),
            fgColor: $r('app.color.app_on_accent'),
            disabled: false,
            action: (): void => { this.startNewChatWithCharacter(char.id); }
          })
          this.gridCell({
            icon: $r('sys.symbol.square_and_pencil'),
            label: $r('app.string.character_action_edit'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: false,
            action: (): void => { this.editCharacter(char.id); }
          })
        }
        .layoutWeight(1)
        .width('100%')

        // 第二行:下移 / 导出 / 删除
        Row() {
          this.gridCell({
            icon: $r('sys.symbol.arrow_down'),
            label: $r('app.string.card_action_move_down'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: index === this.characters.length - 1,
            action: (): void => {
              this.viewModel!.moveDown(char.id).then((): void => {
                this.syncCharacters();
              }).catch((): void => {});
            }
          })
          this.gridCell({
            icon: $r('sys.symbol.share'),
            label: $r('app.string.character_action_export'),
            bgColor: ThemePalette.surface2Color(this.effectiveTheme),
            fgColor: ThemePalette.textPrimaryColor(this.effectiveTheme),
            disabled: false,
            action: (): void => { this.promptExport(char); }
          })
          this.gridCell({
            icon: $r('sys.symbol.trash'),
            label: $r('app.string.character_action_delete'),
            bgColor: $r('app.color.app_danger'),
            fgColor: $r('app.color.app_on_accent'),
            disabled: false,
            action: (): void => { this.promptDelete(char); }
          })
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width(220)
      .height('100%')
      .padding(2)
    }
    .height('100%')
  }

  /**
   * 单个矩阵单元格(图标在上、文字在下,圆角矩形,非胶囊)。
   * 点击后自动收起 swipeAction。
   */
  @Builder
  gridCell(params: SwipeGridCellParams) {
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
      this.listScroller.closeAllSwipeActions();
    })
  }

  // ===== 紧凑角色卡 =====

  @Builder
  characterCard(char: Character) {
    PressableCard({
      onPress: () => {
        // 点击角色卡 -> 跳转到该角色详情(编辑弹窗)
        this.openCharacterDetail(char.id);
      },
      surfaceColor: ThemePalette.surface1Color(this.effectiveTheme)
    }) {
      Row() {
        // 左侧角色头像(76x76 圆角矩形)
        CharacterImageView({
          imageUri: char.avatarUri,
          fallbackName: char.name,
          imgWidth: 76,
          imgHeight: 76,
          imgBorderRadius: 12,
          displayMode: 'portrait',
          objectFit: ImageFit.Cover
        })

        // 右侧主体(三层结构)
        Column() {
          // 第一层:角色名 + Chevron
          Row() {
            Text(char.name)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .textAlign(TextAlign.Start)

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14)
              .fontColor([ThemePalette.textTertiaryColor(this.effectiveTheme)])
              .margin({ left: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 第二层:角色摘要(description → personality → scenario,最多 2 行)
          Text(this.getCharacterSummary(char))
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
            .width('100%')
            .textAlign(TextAlign.Start)

          // 第三层:Metadata(标签 / 创作者 / 更新时间,最多 3 项)
          if (this.hasCharacterMetadata(char)) {
            Row() {
              if (char.tags.length > 0) {
                Text(char.tags[0])
                  .fontSize(11)
                  .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                  .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                  .borderRadius(4)
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }

              if (char.creator.length > 0) {
                Text(char.creator)
                  .fontSize(11)
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ left: char.tags.length > 0 ? 8 : 0 })
              }

              if (char.updatedAt > 0) {
                Text(this.formatCharacterDate(char.updatedAt))
                  .fontSize(11)
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .maxLines(1)
                  .margin({ left: 8 })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: 6 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .padding({ left: $r('app.float.app_spacing_12') })
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

  /** 角色摘要:description → personality → scenario(优先非空字段) */
  private getCharacterSummary(char: Character): string {
    if (char.description.trim().length > 0) {
      return char.description;
    }
    if (char.personality.trim().length > 0) {
      return char.personality;
    }
    if (char.scenario.trim().length > 0) {
      return char.scenario;
    }
    return '';
  }

  /** 是否有关键元数据(标签/创作者/更新时间任一) */
  private hasCharacterMetadata(char: Character): boolean {
    return char.tags.length > 0 || char.creator.trim().length > 0 || char.updatedAt > 0;
  }

  // ===== 空状态 =====

  @Builder
  emptyStateView() {
    Scroll() {
      Column() {
        EmptyStateView({
          title: $r('app.string.character_home_empty_title'),
          description: $r('app.string.character_home_empty_desc')
        })

        // 统一入口:进入"添加角色"页面(新建角色 / 文件导入二选一)
        Button($r('app.string.character_import'))
          .fontSize($r('app.float.app_font_body'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius($r('app.float.app_radius_md'))
          .height(48)
          .width('60%')
          .margin({ top: $r('app.float.app_spacing_24') })
          .onClick(() => {
            router.pushUrl({ url: 'pages/AddCharacterPage' });
          })
      }
      .width('100%')
      .padding({
        top: $r('app.float.app_spacing_48'),
        bottom: 100,
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20')
      })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
  }

  // ===== 加载 / 错误视图 =====

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
        title: $r('app.string.tab_characters_load_failed'),
        description: this.initError
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 删除二次确认弹窗 =====

  @Builder
  deleteConfirmDialog() {
    // 用外层 if 控制挂载/销毁。
    // 卡片形式与 ChatSessionRootView 删除会话弹窗保持一致:
    // surface1 背景 / radius_lg / 80% 宽度 / 透明取消 + danger 实底删除。
    if (this.deleteTarget !== null) {
      Stack() {
        Column() {
          Column() {
            Text(this.formatDeleteMessage(this.deleteTarget!.name))
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .margin({ bottom: 12 })

            Text('此操作不可撤销。')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ bottom: 20 })

            Row() {
              Button($r('app.string.character_delete_confirm_cancel'))
                .fontSize(14)
                .backgroundColor(Color.Transparent)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .layoutWeight(1)
                .height(40)
                .onClick(() => {
                  this.cancelDelete();
                })

              Button($r('app.string.character_delete_confirm_ok'))
                .fontSize(14)
                .backgroundColor($r('app.color.app_danger'))
                .fontColor(Color.White)
                .borderRadius($r('app.float.app_radius_sm'))
                .layoutWeight(1)
                .height(40)
                .margin({ left: 12 })
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
      .onClick(() => {
        // 点击外部取消
        this.cancelDelete();
      })
    }
  }

  // ===== 导出格式选择弹窗 =====

  @Builder
  exportFormatDialog() {
    // 外层 if 控制挂载/销毁。卡片形式与删除会话/角色弹窗保持一致。
    if (this.exportTarget !== null) {
      Stack() {
        Column() {
          Column() {
            Text($r('app.string.character_export_choose_format'))
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .margin({ bottom: 12 })

            Text('选择导出为 PNG 图片或 JSON 文件。')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ bottom: 20 })

            Button($r('app.string.character_export_png'))
              .fontSize(14)
              .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
              .fontColor($r('app.color.app_on_accent'))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .width('100%')
              .margin({ bottom: 8 })
              .onClick(() => {
                this.chooseExportPng();
              })

            Button($r('app.string.character_export_json'))
              .fontSize(14)
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .width('100%')
              .margin({ bottom: 8 })
              .onClick(() => {
                this.chooseExportJson();
              })

            Button($r('app.string.character_export_cancel'))
              .fontSize(14)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .height(40)
              .width('100%')
              .onClick(() => {
                this.cancelExport();
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
        // 点击外部取消
        this.cancelExport();
      })
    }
  }
}
