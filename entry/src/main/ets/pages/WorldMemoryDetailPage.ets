/**
 * WorldMemoryDetailPage 文件夹记忆详情页(v46 树状记忆界面)
 *
 * 通用详情页,按记忆类型展示:
 * - session 会话记忆:摘要全文 + 实体索引清单,底部提供 [核心记忆] [章节记忆] 树状入口
 * - core 核心记忆:摘要全文(世界单例,未传 id 时自动加载最新一条)
 * - chapter 章节记忆:摘要全文 + 人物/地点/时间实体标签
 *
 * 支持编辑摘要(editSummary)与删除(removeWorldMemory)。
 * 从文件夹记忆根页(WorldMemoryPage)或章节列表页(WorldChapterListPage)进入。
 */

import { router } from '@kit.ArkUI';
import { ChatMemory } from '../models/ChatMemory';
import { MemoryService } from '../services/MemoryService';
import { AppServices } from '../services/AppServices';
import {
  parseEntityIndexJson,
  parseChapterEntities,
  EntityIndex,
  ChapterEntities
} from '../services/ChapterMemoryIndexer';
import { ThemePalette } from '../theme/ThemePalette';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldMemoryDetailPage';

type DetailMemoryType = 'core' | 'chapter' | 'session';

@Entry
@Component
struct WorldMemoryDetailPage {
  @State viewModel: WorldMemoryDetailVM = new WorldMemoryDetailVM();
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  @State editing: boolean = false;
  @State editingText: string = '';
  @State confirmDelete: boolean = false;

  aboutToAppear(): void {
    this.loadParams();
  }

  private loadParams(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params === undefined || params === null) {
      this.viewModel.errorMessage = '缺少页面参数';
      return;
    }
    const worldId: string = typeof params['worldId'] === 'string' ? params['worldId'] as string : '';
    const memoryId: string = typeof params['memoryId'] === 'string' ? params['memoryId'] as string : '';
    const typeVal: string = typeof params['type'] === 'string' ? params['type'] as string : 'session';
    const type: DetailMemoryType =
      typeVal === 'core' || typeVal === 'chapter' ? typeVal : 'session';
    if (worldId.length === 0) {
      this.viewModel.errorMessage = '缺少 worldId 参数';
      return;
    }
    void this.viewModel.load(worldId, memoryId, type);
  }

  @Builder
  titleBar() {
    Row() {
      Button('<')
        .fontSize(16)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .onClick(() => {
          router.back();
        })
      Text(this.viewModel.typeLabel)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .margin({ left: 8 })
        .layoutWeight(1)
      if (!this.viewModel.isLoading && this.viewModel.memory !== null) {
        Button(this.editing ? '取消' : '编辑')
          .fontSize(13)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(32)
          .margin({ right: 8 })
          .onClick(() => {
            this.toggleEdit();
          })
        Button('删除')
          .fontSize(13)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.app_danger'))
          .height(32)
          .onClick(() => {
            this.confirmDelete = true;
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .margin({ top: this.statusBarHeight + 8, bottom: 8 })
  }

  @Builder
  content() {
    Scroll() {
      Column({ space: 12 }) {
        if (this.viewModel.isLoading) {
          Text('加载中...')
            .fontSize(14)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 40 })
        } else if (this.viewModel.errorMessage.length > 0) {
          Text(this.viewModel.errorMessage)
            .fontSize(13)
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 24 })
        } else if (this.viewModel.memory === null) {
          this.emptyDetail()
        } else {
          this.detailCard()
        }
        Blank().height(32)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  emptyDetail() {
    Column() {
      Text('未找到该记忆')
        .fontSize(15)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ top: 32 })
      if (this.viewModel.type === 'core') {
        Button('新建核心记忆')
          .type(ButtonType.Capsule)
          .height(40)
          .margin({ top: 16 })
          .fontSize(13)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .onClick(() => {
            this.viewModel.openCreateCoreDialog();
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  detailCard() {
    Column() {
      // 标题
      Text(this.viewModel.displayTitle)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')

      Text('更新于 ' + this.viewModel.formatTime(this.viewModel.memory!.updatedAt))
        .fontSize(11)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ top: 4 })

      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 10, bottom: 10 })

      if (this.editing) {
        this.editArea()
      } else {
        // 摘要全文
        Text(this.viewModel.memory!.summary)
          .fontSize(14)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .lineHeight(22)
      }

      // 实体信息
      if (!this.editing && this.viewModel.memory !== null) {
        this.entitySection()
      }

      // 树状入口(session 类型)
      if (!this.editing && this.viewModel.type === 'session' && !this.viewModel.isLoading) {
        this.sessionEntries()
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
  }

  @Builder
  editArea() {
    Column({ space: 8 }) {
      TextArea({ text: this.editingText, placeholder: '编辑摘要内容' })
        .fontSize(14)
        .width('100%')
        .height(240)
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius(10)
        .onChange((value: string) => {
          this.editingText = value;
        })
      Button('保存')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(40)
        .fontSize(14)
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .onClick(() => {
          void this.saveEdit();
        })
    }
    .width('100%')
  }

  @Builder
  entitySection() {
    if (this.viewModel.memory !== null && this.viewModel.memory.summary.length > 0) {
      // session 类型:detail 是实体索引 JSON;chapter 类型:从摘要现解析
      if (this.viewModel.type === 'session') {
        if (this.viewModel.sessionIndex().entries.length > 0) {
          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 12, bottom: 8 })
          Text('实体索引(人物/地点/时间 → 章节)')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 6 })
          Text(this.viewModel.formatEntityIndex(this.viewModel.sessionIndex()))
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .lineHeight(20)
        }
      } else if (this.viewModel.type === 'chapter') {
        if (this.viewModel.chapterPersons().length > 0) {
          Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 12, bottom: 8 })
          Text('人物')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 4 })
          Text(this.viewModel.chapterPersons().join('、'))
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 8 })
        }
        if (this.viewModel.chapterPlaces().length > 0) {
          Text('地点')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 4 })
          Text(this.viewModel.chapterPlaces().join('、'))
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 8 })
        }
        if (this.viewModel.chapterTimes().length > 0) {
          Text('时间')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 4 })
          Text(this.viewModel.chapterTimes().join('、'))
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
        }
      }
    }
  }

  @Builder
  sessionEntries() {
    Column({ space: 10 }) {
      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 12, bottom: 4 })
      Row({ space: 10 }) {
        Button('核心记忆')
          .type(ButtonType.Capsule)
          .height(40)
          .layoutWeight(1)
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
          .onClick(() => {
            this.openCore();
          })
        Button('章节记忆')
          .type(ButtonType.Capsule)
          .height(40)
          .layoutWeight(1)
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
          .onClick(() => {
            this.openChapters();
          })
      }
      .width('100%')

      Text('会话记忆是这段对话的入口摘要;核心记忆为长期稳定事实,章节记忆为逐段详情,均可按需加载')
        .fontSize(11)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
    }
    .width('100%')
  }

  private toggleEdit(): void {
    if (this.viewModel.memory === null) {
      return;
    }
    if (this.editing) {
      this.editing = false;
      this.editingText = '';
    } else {
      this.editingText = this.viewModel.memory.summary;
      this.editing = true;
    }
  }

  private async saveEdit(): Promise<void> {
    if (this.viewModel.memory === null) {
      return;
    }
    const trimmed: string = this.editingText.trim();
    if (trimmed.length === 0) {
      this.viewModel.errorMessage = '摘要不能为空';
      return;
    }
    await this.viewModel.saveSummary(trimmed);
    this.editing = false;
    this.editingText = '';
  }

  private openCore(): void {
    const p: Record<string, Object> = {
      'worldId': this.viewModel.worldId,
      'type': 'core'
    };
    router.pushUrl({ url: 'pages/WorldMemoryDetailPage', params: p });
  }

  private openChapters(): void {
    const p: Record<string, Object> = {
      'worldId': this.viewModel.worldId
    };
    router.pushUrl({ url: 'pages/WorldChapterListPage', params: p });
  }

  build() {
    Column() {
      this.titleBar()
      this.content()

      if (this.confirmDelete) {
        this.deleteConfirmDialog()
      }

      if (this.viewModel.showCreateCoreDialog) {
        this.createCoreDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  deleteConfirmDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text('删除该记忆')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ top: 16, bottom: 12 })
        Text('删除后不可恢复,确定继续?')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ bottom: 16 })
        Row() {
          Button('取消')
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .height(38)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => {
              this.confirmDelete = false;
            })
          Button('删除')
            .fontSize(14)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor($r('app.color.app_on_accent'))
            .height(38)
            .layoutWeight(1)
            .onClick(() => {
              void this.doDelete();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
      }
      .width('86%')
      .borderRadius(14)
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }

  private async doDelete(): Promise<void> {
    this.confirmDelete = false;
    await this.viewModel.remove();
    router.back();
  }

  @Builder
  createCoreDialog() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        Text('新建核心记忆')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 16, bottom: 12 })
        Text('标题')
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextInput({ text: this.viewModel.createTitle })
          .fontSize(14)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(10)
          .margin({ bottom: 10 })
          .onChange((value: string): void => {
            this.viewModel.createTitle = value;
          })
        Text('内容')
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ text: this.viewModel.createContent })
          .fontSize(14)
          .width('100%')
          .height(120)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(10)
          .margin({ bottom: 12 })
          .onChange((value: string): void => {
            this.viewModel.createContent = value;
          })
        Row() {
          Button('取消')
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .height(38)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => {
              this.viewModel.closeCreateCoreDialog();
            })
          Button('保存')
            .fontSize(14)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .height(38)
            .layoutWeight(1)
            .onClick(() => {
              void this.doCreateCore();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
      }
      .width('86%')
      .borderRadius(14)
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }

  private async doCreateCore(): Promise<void> {
    const ok: boolean = await this.viewModel.createCore();
    if (ok) {
      this.viewModel.closeCreateCoreDialog();
    }
  }
}

/**
 * 详情页状态管理(页面内私有 VM,不依赖 @Observed 也能驱动 @State 刷新)。
 */
class WorldMemoryDetailVM {
  worldId: string = '';
  memory: ChatMemory | null = null;
  type: DetailMemoryType = 'session';
  typeLabel: string = '会话记忆';
  isLoading: boolean = true;
  errorMessage: string = '';
  showCreateCoreDialog: boolean = false;
  createTitle: string = '';
  createContent: string = '';

  private readonly memoryService: MemoryService;

  constructor() {
    this.memoryService = AppServices.getMemoryService();
  }

  get displayTitle(): string {
    if (this.memory === null) {
      return '';
    }
    return this.memory.title.length > 0 ? this.memory.title : this.typeLabel;
  }

  async load(worldId: string, memoryId: string, type: DetailMemoryType): Promise<void> {
    this.worldId = worldId;
    this.type = type;
    this.typeLabel = type === 'core' ? '核心记忆' : (type === 'chapter' ? '章节记忆' : '会话记忆');
    this.isLoading = true;
    this.errorMessage = '';
    try {
      if (memoryId.length > 0) {
        this.memory = await this.memoryService.getById(memoryId);
        // 记忆被删除/失效时置空,展示空态
      } else if (type === 'core') {
        // 世界核心记忆单例:加载最新一条
        const all: ChatMemory[] = await this.memoryService.listWorldMemories(worldId);
        let core: ChatMemory | null = null;
        for (let i = 0; i < all.length; i++) {
          if (all[i].memoryType === 'core'
            && (core === null || all[i].updatedAt > core.updatedAt)) {
            core = all[i];
          }
        }
        this.memory = core;
      } else {
        this.memory = null;
      }
      // 已失效记忆视为未找到
      if (this.memory !== null && this.memory.invalidated) {
        this.memory = null;
      }
    } catch (e) {
      this.errorMessage = '加载失败: ' + String(e);
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  async saveSummary(text: string): Promise<void> {
    if (this.memory === null) {
      return;
    }
    try {
      await this.memoryService.editSummary(this.memory.id, text);
      const refreshed: ChatMemory | null = await this.memoryService.getById(this.memory.id);
      if (refreshed !== null) {
        this.memory = refreshed;
      }
      this.errorMessage = '';
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'saveSummary failed: ' + String(e));
    }
  }

  async remove(): Promise<void> {
    if (this.memory === null) {
      return;
    }
    try {
      await this.memoryService.removeWorldMemory(this.memory.id);
    } catch (e) {
      this.errorMessage = '删除失败: ' + String(e);
      Logger.error(LOG_TAG, 'remove failed: ' + String(e));
    }
  }

  openCreateCoreDialog(): void {
    this.createTitle = '';
    this.createContent = '';
    this.showCreateCoreDialog = true;
  }

  closeCreateCoreDialog(): void {
    this.showCreateCoreDialog = false;
  }

  async createCore(): Promise<boolean> {
    const title: string = this.createTitle.trim();
    const content: string = this.createContent.trim();
    if (title.length === 0 || content.length === 0) {
      this.errorMessage = '标题与内容不能为空';
      return false;
    }
    try {
      const created: ChatMemory = await this.memoryService.addWorldMemory(
        this.worldId, title, content, 'core', [], 80
      );
      this.memory = created;
      this.errorMessage = '';
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'createCore failed: ' + String(e));
      return false;
    }
  }

  formatTime(ms: number): string {
    const d: Date = new Date(ms);
    const mm: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd: string = d.getDate().toString().padStart(2, '0');
    const hh: string = d.getHours().toString().padStart(2, '0');
    const mi: string = d.getMinutes().toString().padStart(2, '0');
    return mm + '-' + dd + ' ' + hh + ':' + mi;
  }

  formatEntityIndex(index: EntityIndex): string {
    if (index.entries.length === 0) {
      return '(暂无可解析的实体索引)';
    }
    const parts: string[] = [];
    for (let i = 0; i < index.entries.length; i++) {
      parts.push(index.entries[i].name + '(' + index.entries[i].chapterIds.length.toString() + '章)');
    }
    return parts.join(' · ');
  }

  /** 解析会话记忆 detail 中的实体索引(损坏返回空索引)。 */
  sessionIndex(): EntityIndex {
    if (this.memory === null) {
      return parseEntityIndexJson('');
    }
    return parseEntityIndexJson(this.memory.detail);
  }

  /** 章节摘要中的人物(空返回空数组)。 */
  chapterPersons(): string[] {
    if (this.memory === null) {
      return [];
    }
    return parseChapterEntities(this.memory.summary).persons;
  }

  /** 章节摘要中的地点。 */
  chapterPlaces(): string[] {
    if (this.memory === null) {
      return [];
    }
    return parseChapterEntities(this.memory.summary).places;
  }

  /** 章节摘要中的时间。 */
  chapterTimes(): string[] {
    if (this.memory === null) {
      return [];
    }
    return parseChapterEntities(this.memory.summary).times;
  }
}
