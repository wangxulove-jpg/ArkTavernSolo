/**
 * 状态/世界书滑动面板(自 ChatPage.statusWorldSheetContent + 世界书/AI 预览族 10 个 @Builder 抽取,纯搬运,行为不变)。
 *
 * 设计:组件不持有 VM/服务,依赖全部经 @Prop 值 + @Link + 回调上抛:
 * - 渲染态:effectiveTheme / aiMode / aiLoading / pendingChangeSet / lorebookPanelData / lorebookPanelVersion
 *   (LorebookPanelBook/Data 仅类型引用自 models/LorebookPanel,不在组件内持有 VM 实例)
 * - 双向:statusPanelVisible(关闭按钮) / aiEntryVisible(AI 入口切换) / aiPromptText(AI 指令输入框)
 * - 组件内 UI 状态:expandedEntryId / expandedAiPreviewKey(仅影响本面板展开态,不跨页面)
 * - 业务动作:全部回调上抛,由页面执行(viewModel 调用、变更应用、激活刷新)
 */
import { ThemePalette } from '../theme/ThemePalette';
import { LorebookEntry } from '../models/Lorebook';
import { AiLorebookChangeSet, AiLorebookAdd, AiLorebookUpdate, AiLorebookDelete } from '../models/LorebookAiTypes';
import { LorebookPanelBook, LorebookPanelData } from '../models/LorebookPanel';

@Component
export struct ChatStatusWorldPanel {
  /** 当前主题 */
  @Prop effectiveTheme: string = 'dark';
  /** 面板可见性(bindSheet 双向绑定;关闭按钮置 false) */
  @Link statusPanelVisible: boolean;
  /** AI 操作区是否展开(双向:入口切换 / 关闭面板时复位) */
  @Link aiEntryVisible: boolean;
  /** AI 指令输入框内容(双向) */
  @Link aiPromptText: string;
  /** AI 操作模式:worldbook / extract(只读;切换经回调) */
  @Prop aiMode: string = 'worldbook';
  /** AI 请求进行中(只读) */
  @Prop aiLoading: boolean = false;
  /** 待确认的世界书变更集(非空时显示预览;只读,清空经回调) */
  @Prop pendingChangeSet: AiLorebookChangeSet | null = null;
  /** 世界书面板展示数据(由页面 viewModel.lorebookPanelData 同步) */
  @Prop lorebookPanelData: LorebookPanelData | null = null;
  /** 世界书面板刷新版本号(ForEach 强制重建) */
  @Prop lorebookPanelVersion: number = 0;

  /** 世界书条目展开中的 ID(点击展开/收起内容) */
  @State expandedEntryId: string = '';
  /** 变更预览中展开中的提案项 key(点击展开/收起关键词与内容) */
  @State expandedAiPreviewKey: string = '';

  /** 清空待确认变更集(取消预览 / 关闭 AI 区 / 关闭面板) */
  onClearPendingChanges: () => void = () => {};
  /** 手动刷新激活内容(按需锁定模式) */
  onRefreshActivated: () => void = () => {};
  /** 切换 AI 操作模式(页面处理待确认清空与 extract 立即执行) */
  onSelectAiMode: (mode: string) => void = () => {};
  /** 执行当前 AI 模式的指令(世界书修改 / 提取) */
  onRunAiAction: () => void = () => {};
  /** 应用待确认的世界书变更集 */
  onApplyPendingChanges: () => void = () => {};
  /** 切换世界书条目启用状态(页面调用 viewModel 并同步面板数据) */
  onToggleEntryEnabled: (lorebookId: string, entryId: string, enabled: boolean) => void =
    (_lorebookId: string, _entryId: string, _enabled: boolean) => {};

  build() {
    Column() {
      // 顶部栏:标题 + AI 入口 + 关闭
      this.worldbookHeader()

      // AI 操作区(置于顶部,键盘弹出时不会被遮挡)
      this.aiActionArea()

      // 世界书内容(单页,无 Swiper)
      this.worldbookPageContent()

      // 世界书变更预览(确认/取消)
      this.aiPreviewArea()
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
  }

  @Builder
  worldbookHeader() {
    Row() {
      Text('世界书')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      Blank()

      // AI 入口(低调透明)
      Row() {
        Text('✦')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        Text('AI')
          .fontSize(11)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ left: 4 })
      }
      .height(28)
      .padding({ left: 10, right: 10 })
      .borderRadius(14)
      .backgroundColor(this.aiEntryVisible ? 'rgba(255,255,255,0.14)' : 'rgba(255,255,255,0.07)')
      .opacity(this.aiEntryVisible ? 0.9 : 0.6)
      .onClick(() => {
        this.aiEntryVisible = !this.aiEntryVisible;
        if (!this.aiEntryVisible) {
          this.onClearPendingChanges();
        }
      })
      .key('chat.world.ai')

      // 手动刷新激活内容(按需锁定模式):切换开场白/章节后重新匹配并锁定
      Row() {
        Text('↻')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        Text('刷新激活')
          .fontSize(11)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ left: 4 })
      }
      .height(28)
      .padding({ left: 10, right: 10 })
      .borderRadius(14)
      .backgroundColor('rgba(255,255,255,0.07)')
      .onClick(() => {
        this.onRefreshActivated();
      })
      .key('chat.world.refresh')

      Text('✕')
        .fontSize(13)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .opacity(0.7)
        .margin({ left: 12 })
        .onClick(() => {
          this.statusPanelVisible = false;
          this.aiEntryVisible = false;
          this.onClearPendingChanges();
        })
        .key('chat.world.close')
    }
    .width('100%')
    .margin({ bottom: 6 })
  }

  @Builder
  worldbookPageContent() {
    Scroll() {
      Column() {
        if (this.lorebookPanelData === null) {
          Text('暂无世界书，点击上方 AI 可从近期对话提取设定')
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .padding({ top: 12, bottom: 12 })
        } else {
          ForEach(this.lorebookPanelData!.books, (book: LorebookPanelBook) => {
            this.worldBookGroupRow(book)
          }, (book: LorebookPanelBook) =>
            book.lorebookId + '|' + String(this.lorebookPanelVersion))
        }
      }
      .width('100%')
      .padding({ bottom: 8 })
    }
    .width('100%')
      // layoutWeight 占满顶部栏/AI 区之后的剩余高度:条目只在面板内滚动,
      // 不会把内容顶出圆角背景框以外。
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  worldBookGroupRow(book: LorebookPanelBook) {
    Column() {
      Text((book.isCharacterBook ? '角色专属 · ' : '全局 · ') + (book.name.length > 0 ? book.name : '世界书'))
        .fontSize(12)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ top: 6, bottom: 4 })
      if (book.entries.length === 0) {
        Text('(无条目)')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ top: 2, bottom: 2 })
      } else {
        ForEach(book.entries, (entry: LorebookEntry) => {
          this.worldBookEntryRow(book, entry)
        }, (entry: LorebookEntry) =>
          entry.id + '|' + String(this.lorebookPanelVersion))
      }
    }
    .width('100%')
  }

  @Builder
  worldBookEntryRow(book: LorebookPanelBook, entry: LorebookEntry) {
    Column() {
      Row() {
        Text(entry.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(entry.constant ? '恒定' : '')
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .opacity(0.7)
          .margin({ right: 8 })
        Text(entry.enabled ? '启用' : '停用')
          .fontSize(10)
          .fontColor(entry.enabled
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textTertiaryColor(this.effectiveTheme))
          .opacity(entry.enabled ? 0.9 : 0.5)
          .onClick(() => {
            this.onToggleEntryEnabled(book.lorebookId, entry.id, !entry.enabled);
          })
          .key('chat.world.entry.' + entry.id + '.toggle')
      }
      .width('100%')

      if (entry.keys.length > 0) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(entry.keys, (key: string) => {
            Text(key)
              .fontSize(10)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .backgroundColor('rgba(255,255,255,0.06)')
              .borderRadius(8)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .margin({ right: 6, top: 4 })
          }, (key: string) => key)
        }
        .width('100%')
      }

      Text(entry.content)
        .fontSize(12)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .maxLines(this.expandedEntryId === entry.id ? 100 : 3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .onClick(() => {
          this.expandedEntryId = this.expandedEntryId === entry.id ? '' : entry.id;
        })
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 6, bottom: 6 })
    .borderRadius(10)
    .backgroundColor('rgba(255,255,255,0.04)')
    .margin({ top: 4 })
  }

  @Builder
  aiActionArea() {
    if (this.aiEntryVisible) {
      Column() {
        Row() {
          this.aiModeChip('修改世界书', 'worldbook')
          this.aiModeChip('提取角色/地点', 'extract')
        }
        .width('100%')
        .margin({ top: 6 })

        Row() {
          TextInput({
            placeholder: this.aiMode === 'worldbook'
              ? '如：新增角色 张三，酒馆老板'
              : '自动提取近期对话中的新角色/地点',
            text: this.aiPromptText
          })
            .layoutWeight(1)
            .height(32)
            .fontSize(12)
            .onChange((value: string) => {
              this.aiPromptText = value;
            })
          Text(this.aiLoading ? '处理中…' : '执行')
            .fontSize(12)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .opacity(this.aiLoading ? 0.4 : 1)
            .margin({ left: 12 })
            .onClick(() => {
              this.onRunAiAction();
            })
            .key('chat.world.ai.run')
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
    }
  }

  @Builder
  aiModeChip(label: string, mode: string) {
    Text(label)
      .fontSize(11)
      .fontColor(this.aiMode === mode
        ? ThemePalette.accentColor(this.effectiveTheme)
        : ThemePalette.textSecondaryColor(this.effectiveTheme))
      .backgroundColor(this.aiMode === mode ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.04)')
      .borderRadius(12)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .margin({ right: 8 })
      .onClick(() => {
        this.onSelectAiMode(mode);
      })
      .key('chat.world.mode.' + mode)
  }

  @Builder
  aiPreviewArea() {
    if (this.pendingChangeSet !== null) {
      Column() {
        Text('变更预览')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })

        if (this.pendingChangeSet!.adds.length === 0
          && this.pendingChangeSet!.updates.length === 0
          && this.pendingChangeSet!.deletes.length === 0) {
          Text('未识别到需要变更的内容')
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
        } else {
          Scroll() {
            Column() {
              ForEach(this.pendingChangeSet!.adds, (a: AiLorebookAdd, index: number) => {
                this.aiPreviewAddRow(a, index)
              }, (a: AiLorebookAdd, index: number) => 'add-' + a.lorebookId + '-' + a.name + '-' + String(index))
              ForEach(this.pendingChangeSet!.updates, (u: AiLorebookUpdate, index: number) => {
                this.aiPreviewUpdateRow(u, index)
              }, (u: AiLorebookUpdate, index: number) => 'upd-' + u.lorebookId + '-' + u.entryId + '-' + String(index))
              ForEach(this.pendingChangeSet!.deletes, (d: AiLorebookDelete, index: number) => {
                Row() {
                  Text('删除')
                    .fontSize(10)
                    .fontColor($r('app.color.app_danger'))
                  Text(d.entryId)
                    .fontSize(11)
                    .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                    .layoutWeight(1)
                    .margin({ left: 6 })
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .width('100%')
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor('rgba(255,255,255,0.04)')
                .borderRadius(8)
                .margin({ top: 4 })
              }, (d: AiLorebookDelete, index: number) => 'del-' + d.lorebookId + '-' + d.entryId + '-' + String(index))
            }
            .width('100%')
          }
          .width('100%')
          .constraintSize({ maxHeight: 140 })
          .scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring)
        }

        Row() {
          Text('应用')
            .fontSize(12)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .onClick(() => {
              this.onApplyPendingChanges();
            })
            .key('chat.world.apply')
          Blank()
          Text('取消')
            .fontSize(12)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .onClick(() => {
              this.onClearPendingChanges();
            })
            .key('chat.world.cancel')
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .padding({ top: 8, bottom: 4 })
      .border({ width: 0.5, color: ThemePalette.surface2Color(this.effectiveTheme) })
      .borderRadius(10)
      .margin({ top: 8 })
    }
  }

  /** 变更预览:新增条目行(点击展开关键词与内容,便于确认前审阅)。 */
  @Builder
  aiPreviewAddRow(a: AiLorebookAdd, index: number) {
    Column() {
      Row() {
        Text('新增')
          .fontSize(10)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        Text(a.name)
          .fontSize(11)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.expandedAiPreviewKey === 'add-' + String(index) ? '收起' : '展开')
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .opacity(0.8)
      }
      .width('100%')

      if (this.expandedAiPreviewKey === 'add-' + String(index)) {
        // 关键词
        if (a.keys.length > 0) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
            ForEach(a.keys, (k: string) => {
              Text(k)
                .fontSize(10)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .backgroundColor('rgba(255,255,255,0.06)')
                .borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ right: 5, top: 4 })
            }, (k: string) => k)
          }
          .width('100%')
        }
        // 内容
        Text(a.content)
          .fontSize(11)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .backgroundColor('rgba(255,255,255,0.04)')
    .borderRadius(8)
    .margin({ top: 4 })
    .onClick(() => {
      const k: string = 'add-' + String(index);
      this.expandedAiPreviewKey = this.expandedAiPreviewKey === k ? '' : k;
    })
  }

  /** 变更预览:修改条目行(点击展开被修改的字段与内容)。 */
  @Builder
  aiPreviewUpdateRow(u: AiLorebookUpdate, index: number) {
    Column() {
      Row() {
        Text('修改')
          .fontSize(10)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Text(u.name !== undefined ? u.name : u.entryId)
          .fontSize(11)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.expandedAiPreviewKey === 'upd-' + String(index) ? '收起' : '展开')
          .fontSize(10)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .opacity(0.8)
      }
      .width('100%')

      if (this.expandedAiPreviewKey === 'upd-' + String(index)) {
        if (u.name !== undefined) {
          Text('名称：' + u.name)
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 4 })
        }
        if (u.content !== undefined && u.content.length > 0) {
          Text(u.content)
            .fontSize(11)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 4 })
        } else if (u.name === undefined) {
          Text('（未提供具体字段，请直接应用）')
            .fontSize(11)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ top: 4 })
        }
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 5, bottom: 5 })
    .backgroundColor('rgba(255,255,255,0.04)')
    .borderRadius(8)
    .margin({ top: 4 })
    .onClick(() => {
      const k: string = 'upd-' + String(index);
      this.expandedAiPreviewKey = this.expandedAiPreviewKey === k ? '' : k;
    })
  }
}