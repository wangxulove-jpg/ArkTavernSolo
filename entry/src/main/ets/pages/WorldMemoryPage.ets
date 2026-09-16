/**
 * WorldMemoryPage 文件夹记忆管理页(v46 树状记忆界面·根页)
 *
 * 树状结构第一层:会话记忆列表(每个会话一条入口级摘要)。
 * - 点击会话记忆 → WorldMemoryDetailPage 查看详情,并从详情进入核心记忆 / 章节记忆
 * - 保留"新建记忆"手工记忆能力(章节 / 核心,文件夹级)
 */

import { router } from '@kit.ArkUI';
import { ChatMemory } from '../models/ChatMemory';
import { WorldMemoryViewModel } from '../viewmodels/WorldMemoryViewModel';
import { ThemePalette } from '../theme/ThemePalette';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldMemoryPage';

@Entry
@Component
struct WorldMemoryPage {
  @State viewModel: WorldMemoryViewModel | null = null;
  @State worldName: string = '';
  @State vmErrorMessage: string = '';
  @State editDialogDummy: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    const worldId: string = params !== undefined && params !== null && typeof params['worldId'] === 'string'
      ? params['worldId'] as string : '';
    const name: string = params !== undefined && params !== null && typeof params['name'] === 'string'
      ? params['name'] as string : '';
    if (worldId.length === 0) {
      Logger.warn(LOG_TAG, 'no worldId param');
      return;
    }
    this.worldName = name;
    const vm: WorldMemoryViewModel = new WorldMemoryViewModel();
    this.viewModel = vm;
    void vm.load(worldId).then((): void => {
      this.syncFromViewModel();
    });
  }

  private syncFromViewModel(): void {
    const vm: WorldMemoryViewModel | null = this.viewModel;
    if (vm === null) {
      return;
    }
    this.vmErrorMessage = vm.errorMessage;
    this.editDialogDummy = this.editDialogDummy + 1;
  }

  private openSessionDetail(memoryId: string): void {
    const vm: WorldMemoryViewModel | null = this.viewModel;
    if (vm === null) {
      return;
    }
    const p: Record<string, Object> = {
      'worldId': vm.worldId,
      'memoryId': memoryId,
      'type': 'session'
    };
    router.pushUrl({ url: 'pages/WorldMemoryDetailPage', params: p });
  }

  private formatTime(ms: number): string {
    const d: Date = new Date(ms);
    const mm: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd: string = d.getDate().toString().padStart(2, '0');
    const hh: string = d.getHours().toString().padStart(2, '0');
    const mi: string = d.getMinutes().toString().padStart(2, '0');
    return mm + '-' + dd + ' ' + hh + ':' + mi;
  }

  @Builder
  sessionCard(memory: ChatMemory) {
    Column() {
      Row() {
        Text(memory.title.length > 0 ? memory.title : '会话记忆')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('会话记忆')
          .fontSize(10)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
      .width('100%')

      if (memory.summary.length > 0) {
        Text(memory.summary)
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
      }

      Row() {
        Text('更新于 ' + this.formatTime(memory.updatedAt))
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        Blank()
        Text('查看详情 ›')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .padding(12)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(10)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.openSessionDetail(memory.id);
    })
  }

  @Builder
  editDialog() {
    if (this.viewModel !== null && this.viewModel.showEditDialog) {
      Column() {
        Text(this.viewModel.editingMemory === null ? '新建记忆' : '编辑记忆')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 12 })

        Row() {
          Button('章节记忆')
            .fontSize(12)
            .backgroundColor(this.viewModel.editType === 0
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(this.viewModel.editType === 0
              ? $r('app.color.app_on_accent')
              : ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(16)
            .height(32)
            .layoutWeight(1)
            .margin({ right: 8 })
            .onClick(() => {
              this.viewModel!.editType = 0;
            })
          Button('核心记忆')
            .fontSize(12)
            .backgroundColor(this.viewModel.editType === 1
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(this.viewModel.editType === 1
              ? $r('app.color.app_on_accent')
              : ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(16)
            .height(32)
            .layoutWeight(1)
            .onClick(() => {
              this.viewModel!.editType = 1;
            })
        }
        .width('100%')
        .margin({ bottom: 10 })

        this.labeledInput('标题')
        TextInput({ text: this.viewModel.editTitle })
          .fontSize(14)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(10)
          .margin({ bottom: 10 })
          .onChange((value: string): void => {
            this.viewModel!.editTitle = value;
          })

        Text('内容')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ text: this.viewModel.editContent })
          .fontSize(14)
          .width('100%')
          .height(120)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(10)
          .margin({ bottom: 10 })
          .onChange((value: string): void => {
            this.viewModel!.editContent = value;
          })

        this.labeledInput('关键词(逗号分隔,用于按需召回)')
        TextInput({ text: this.viewModel.editKeywords })
          .fontSize(14)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(10)
          .margin({ bottom: 10 })
          .onChange((value: string): void => {
            this.viewModel!.editKeywords = value;
          })

        this.labeledInput('重要度(0-100)')
        TextInput({ text: this.viewModel.editImportance })
          .fontSize(14)
          .type(InputType.Number)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(10)
          .margin({ bottom: 4 })
          .onChange((value: string): void => {
            this.viewModel!.editImportance = value;
          })

        Text('高重要度优先注入;关键词命中的旧章节可在对话中按需召回')
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 12 })

        Button('保存')
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .height(40)
          .width('100%')
          .borderRadius(20)
          .onClick(() => {
            void this.saveMemory();
          })

        Button('取消')
          .fontSize(14)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .height(40)
          .width('100%')
          .borderRadius(20)
          .margin({ top: 8 })
          .onClick(() => {
            this.viewModel!.closeDialog();
            this.syncFromViewModel();
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
      .borderRadius(16)
    }
  }

  @Builder
  labeledInput(label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      .width('100%')
      .margin({ bottom: 4 })
  }

  private openNewMemory(): void {
    if (this.viewModel !== null) {
      this.viewModel.openNewDialog(0);
      this.syncFromViewModel();
    }
  }

  private saveMemory(): void {
    if (this.viewModel === null) {
      return;
    }
    void this.viewModel.save().then((ok: boolean): void => {
      this.syncFromViewModel();
    });
  }

  build() {
    Column() {
      Row() {
        Button('<')
          .fontSize(16)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .onClick(() => {
            router.back();
          })
        Text(this.worldName.length > 0 ? this.worldName : '文件夹记忆')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ left: 8 })
          .layoutWeight(1)
        Button('＋ 新建记忆')
          .fontSize(13)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .height(32)
          .borderRadius(16)
          .onClick(() => {
            this.openNewMemory();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12 })
      .margin({ top: this.statusBarHeight + 8, bottom: 8 })

      Text('此文件夹内所有会话共享以下记忆 · 点击会话记忆查看详情与核心/章节记忆')
        .fontSize(12)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({ bottom: 4 })

      if (this.vmErrorMessage.length > 0) {
        Text(this.vmErrorMessage)
          .fontSize(12)
          .fontColor($r('app.color.app_danger'))
          .padding({ left: 16, right: 16 })
          .width('100%')
          .margin({ bottom: 4 })
      }

      if (this.viewModel !== null && this.viewModel.loading) {
        Column() {
          Text('加载中...')
            .fontSize(14)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 40 })
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
      } else {
        List({ space: 4 }) {
          if (this.viewModel !== null && this.viewModel.sessions.length > 0) {
            ListItem() {
              Column() {
                Row() {
                  Text('会话记忆')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                  Blank()
                  Text(this.viewModel.sessions.length.toString() + ' 段对话')
                    .fontSize(11)
                    .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                }
                .width('100%')
                .padding({ top: 12, bottom: 6 })
              }
            }
            ForEach(this.viewModel.sessions,
              (m: ChatMemory) => {
                ListItem() {
                  this.sessionCard(m)
                }
              }, (m: ChatMemory) => m.id + '_' + this.editDialogDummy)
          }

          if (this.viewModel === null || this.viewModel.sessions.length === 0) {
            ListItem() {
              Column({ space: 6 }) {
                Text('暂无会话记忆')
                  .fontSize(15)
                  .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                  .margin({ top: 32 })
                Text('完成一段对话后,在对话记忆页先生成章节,再点"生成会话记忆",'
                  + '即可在此看到该段对话的入口摘要')
                  .fontSize(12)
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .textAlign(TextAlign.Center)
                  .lineHeight(18)
                Text('或点击右上角"新建记忆"手动记录文件夹级记忆')
                  .fontSize(12)
                  .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                  .margin({ top: 4 })
              }
              .width('100%')
              .padding(24)
            }
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 12, right: 12 })
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }

      // 编辑对话框
      if (this.viewModel !== null && this.viewModel.showEditDialog) {
        this.editDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
