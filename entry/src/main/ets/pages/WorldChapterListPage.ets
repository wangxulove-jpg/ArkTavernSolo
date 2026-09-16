/**
 * WorldChapterListPage 文件夹章节记忆列表页(v46 树状记忆界面)
 *
 * 从会话记忆详情页的 [章节记忆] 入口进入,展示文件夹全部有效章节记忆。
 * 支持两种视图:
 * - 时间线:章节按时间顺序排列
 * - 按人物·事件:实体分组(程序化解析,纯展示重排)
 * 点击章节卡片 → WorldMemoryDetailPage 查看详情。
 */

import { router } from '@kit.ArkUI';
import { ChatMemory } from '../models/ChatMemory';
import { MemoryService } from '../services/MemoryService';
import { AppServices } from '../services/AppServices';
import {
  groupChaptersByEntity,
  entityKindLabel,
  EntityChapterGroup
} from '../services/ChapterMemoryIndexer';
import { ThemePalette } from '../theme/ThemePalette';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldChapterListPage';

@Entry
@Component
struct WorldChapterListPage {
  @State worldId: string = '';
  @State chapters: ChatMemory[] = [];
  @State entityGroups: EntityChapterGroup[] = [];
  @State isLoading: boolean = true;
  @State errorMessage: string = '';
  @State entityView: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private readonly memoryService: MemoryService = AppServices.getMemoryService();

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params === undefined || params === null) {
      this.errorMessage = '缺少页面参数';
      this.isLoading = false;
      return;
    }
    const worldId: string = typeof params['worldId'] === 'string' ? params['worldId'] as string : '';
    if (worldId.length === 0) {
      this.errorMessage = '缺少 worldId 参数';
      this.isLoading = false;
      return;
    }
    this.worldId = worldId;
    void this.load();
  }

  private async load(): Promise<void> {
    this.isLoading = true;
    this.errorMessage = '';
    try {
      const all: ChatMemory[] = await this.memoryService.listWorldMemories(this.worldId);
      const chapters: ChatMemory[] = [];
      for (let i = 0; i < all.length; i++) {
        if (all[i].memoryType === 'chapter' && !all[i].invalidated && all[i].enabled) {
          chapters.push(all[i]);
        }
      }
      // 时间正序(createdAt)
      chapters.sort((a: ChatMemory, b: ChatMemory): number => a.createdAt - b.createdAt);
      this.chapters = chapters;
      this.entityGroups = groupChaptersByEntity(chapters);
    } catch (e) {
      this.errorMessage = '加载失败: ' + String(e);
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  private formatTime(ms: number): string {
    const d: Date = new Date(ms);
    const mm: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd: string = d.getDate().toString().padStart(2, '0');
    return mm + '-' + dd;
  }

  private openDetail(memoryId: string): void {
    const p: Record<string, Object> = {
      'worldId': this.worldId,
      'memoryId': memoryId,
      'type': 'chapter'
    };
    router.pushUrl({ url: 'pages/WorldMemoryDetailPage', params: p });
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
      Text('章节记忆')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .margin({ left: 8 })
        .layoutWeight(1)
      if (this.entityGroups.length > 0) {
        Row() {
          Button('时间线')
            .fontSize(12)
            .height(30)
            .padding({ left: 12, right: 12 })
            .backgroundColor(!this.entityView
              ? ThemePalette.accentColor(this.effectiveTheme) : Color.Transparent)
            .fontColor(!this.entityView
              ? $r('app.color.app_on_accent') : ThemePalette.textSecondaryColor(this.effectiveTheme))
            .onClick(() => {
              this.entityView = false;
            })
          Button('按人物·事件')
            .fontSize(12)
            .height(30)
            .padding({ left: 12, right: 12 })
            .margin({ left: 8 })
            .backgroundColor(this.entityView
              ? ThemePalette.accentColor(this.effectiveTheme) : Color.Transparent)
            .fontColor(this.entityView
              ? $r('app.color.app_on_accent') : ThemePalette.textSecondaryColor(this.effectiveTheme))
            .onClick(() => {
              this.entityView = true;
            })
        }
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .margin({ top: this.statusBarHeight + 8, bottom: 8 })
  }

  @Builder
  content() {
    if (this.isLoading) {
      Column() {
        Text('加载中...')
          .fontSize(14)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ top: 40 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    } else if (this.errorMessage.length > 0) {
      Column() {
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor($r('app.color.app_danger'))
          .margin({ top: 24 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    } else if (this.chapters.length === 0) {
      Column({ space: 8 }) {
        Text('暂无章节记忆')
          .fontSize(15)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ top: 32 })
        Text('在对话记忆页手动"生成章节"后,章节会出现在这里')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    } else {
      List({ space: 8 }) {
        if (this.entityView && this.entityGroups.length > 0) {
          ForEach(this.entityGroups, (group: EntityChapterGroup) => {
            ListItem() {
              Column() {
                Row() {
                  Text(entityKindLabel(group.kind) + ' · ' + group.name)
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                  Blank()
                  Text(group.chapters.length.toString() + ' 章')
                    .fontSize(11)
                    .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                }
                .width('100%')
                .padding({ top: 8, bottom: 4 })

                ForEach(group.chapters, (m: ChatMemory) => {
                  this.chapterCard(m)
                }, (m: ChatMemory) => m.id)
              }
              .width('100%')
            }
          }, (group: EntityChapterGroup) => group.kind + '\n' + group.name)
        } else {
          ForEach(this.chapters, (m: ChatMemory) => {
            ListItem() {
              this.chapterCard(m)
            }
          }, (m: ChatMemory) => m.id)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 12, right: 12 })
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  chapterCard(m: ChatMemory) {
    Column() {
      Row() {
        Text(m.title.length > 0 ? m.title : '章节记忆')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.formatTime(m.createdAt))
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ left: 8 })
      }
      .width('100%')

      if (m.summary.length > 0) {
        Text(m.summary)
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .padding(12)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(10)
    .margin({ top: 4, bottom: 4 })
    .onClick(() => {
      this.openDetail(m.id);
    })
  }

  build() {
    Column() {
      this.titleBar()
      this.content()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
