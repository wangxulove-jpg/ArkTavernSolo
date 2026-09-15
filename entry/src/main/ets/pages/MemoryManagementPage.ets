/**
 * MemoryManagementPage 对话记忆管理页(v12)
 *
 * v12 升级:
 * - 按 Core/Chapter/Rolling/Legacy 分类展示记忆
 * - 支持查看/编辑/启用/禁用/删除单条 Memory
 * - 显示失效状态和继承标记
 * - 显示覆盖消息范围和创建时间
 *
 * 功能:
 * - 显示当前 Active Branch 的全部 Memory(按类型分组)
 * - 启用/禁用 Memory
 * - 手动编辑摘要文本
 * - 手动删除单条 Memory
 * - 手动触发重新生成摘要(强制,不检查阈值)
 * - 清除当前 Branch 自产记忆(继承祖先的不删)
 *
 * 路由参数:{ chatId: string }
 *
 * 数据流:
 * - MemoryManagementViewModel 通过 MemoryService + ConversationBranchPersistenceService 操作
 * - 不直接访问 Repository / Provider / 数据库
 */

import { router, promptAction } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';
import { MemoryManagementViewModel, MemoryDisplayItem, MemoryTypeGroup } from '../viewmodels/MemoryManagementViewModel';
import { Logger } from '../utils/Logger';
import { ThemePalette } from '../theme/ThemePalette';
import { MEMORY_AUTO_SUMMARY_PREFS_KEY } from '../services/ChatService';

const LOG_TAG: string = 'MemoryMgmtPage';

interface MemoryMgmtRouteParam {
  chatId: string;
}

@Entry
@Component
struct MemoryManagementPage {
  @State viewModel: MemoryManagementViewModel = new MemoryManagementViewModel(
    AppServices.getMemoryService(),
    AppServices.getBranchPersistenceService()
  );
  @State readyHandled: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 是否显示清除确认 */
  @State showClearConfirm: boolean = false;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 自动记忆总结开关(默认关闭,手动触发有利于缓存) */
  @State memoryAutoSummary: boolean = false;

  aboutToAppear(): void {
    this.handleReady();
    this.loadMemoryAutoSummaryPref();
  }

  private async handleReady(): Promise<void> {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;
    try {
      const param = router.getParams() as Record<string, Object>;
      if (param === undefined || param === null) {
        this.viewModel.errorMessage = '缺少 chatId 参数';
        return;
      }
      const chatIdVal: Object | undefined = param['chatId'];
      if (chatIdVal === undefined) {
        this.viewModel.errorMessage = '缺少 chatId 参数';
        return;
      }
      const chatId: string = String(chatIdVal);
      await this.viewModel.initialize(chatId);
    } catch (e) {
      Logger.error(LOG_TAG, 'handleReady failed: ' + String(e));
    }
  }

  build() {
    Stack() {
      Column() {
        this.titleBar();

        if (this.viewModel.errorMessage.length > 0) {
          this.errorBanner();
        }

        if (this.viewModel.statusMessage.length > 0) {
          this.statusBanner();
        }

        Scroll() {
          Column() {
            if (this.viewModel.isLoading) {
              Text('加载中...')
                .fontSize(14)
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .margin({ top: 40, bottom: 40 })
            } else if (this.viewModel.memoryGroups.length === 0) {
              this.emptyState()
            } else {
              this.memoryListContent()
            }

            Blank().height(this.navigationBarHeight + 32)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')

      if (this.showClearConfirm) {
        this.clearConfirmDialog()
      }

      if (this.viewModel.showDeleteConfirm) {
        this.deleteConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  titleBar() {
    Row() {
      Button($r('app.string.branch_map_back'))
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .onClick(() => {
          router.back();
        })

      Blank()

      Text('对话记忆')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))

      Blank()

      // 占位保持标题居中
      Text('')
        .fontSize(14)
        .width(56)
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: this.statusBarHeight + 4, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  errorBanner() {
    Row() {
      Text(this.viewModel.errorMessage)
        .fontSize(13)
        .fontColor($r('app.color.app_danger'))
        .layoutWeight(1)
      Button('×')
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .onClick(() => {
          this.viewModel.clearErrorMessage();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
  }

  @Builder
  statusBanner() {
    Row() {
      Text(this.viewModel.statusMessage)
        .fontSize(13)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .layoutWeight(1)
      Button('×')
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .onClick(() => {
          this.viewModel.clearStatusMessage();
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
  }

  @Builder
  emptyState() {
    Column() {
      Text('当前分支暂无记忆')
        .fontSize(16)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ top: 32, bottom: 8 })

      Text('对话内容达到一定量后,可手动点击下方"生成章节"生成详细章节记忆,并同步更新核心记忆。')
        .fontSize(13)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .margin({ left: 24, right: 24 })

      // 统计信息
      this.statsCard()

      // 手动生成按钮
      Button('生成章节')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(44)
        .margin({ top: 24 })
        .enabled(!this.viewModel.isOperating && this.viewModel.totalMessageCount > 0)
        .onClick(() => {
          this.viewModel.regenerateSummary();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  memoryListContent() {
    Column() {
      // 统计信息
      this.statsCard()

      // 按类型分组展示
      ForEach(this.viewModel.memoryGroups, (group: MemoryTypeGroup) => {
        this.memoryTypeGroupSection(group)
      }, (group: MemoryTypeGroup) => group.memoryType)

      // 操作按钮
      this.actionButtons()
    }
    .width('100%')
  }

  @Builder
  memoryTypeGroupSection(group: MemoryTypeGroup) {
    Column() {
      // 分组标题
      Row() {
        Text(group.typeLabel)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Blank()
        Text(group.items.length.toString() + ' 条')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({ top: 12, bottom: 8 })

      // 该类型的 Memory 列表
      ForEach(group.items, (item: MemoryDisplayItem) => {
        this.memoryItemCard(item)
      }, (item: MemoryDisplayItem) => item.memory.id)
    }
    .width('100%')
  }

  @Builder
  memoryItemCard(item: MemoryDisplayItem) {
    Column() {
      // 卡片头部:标题 + 状态标签
      Row() {
        Text(item.displayTitle)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)

        // v42: 世界共享记忆 chip(区分世界共享与分支私有)
        if (item.worldName.length > 0) {
          Text(item.worldName + ' · 世界共享')
            .fontSize(11)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 8 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Text('分支私有')
            .fontSize(11)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius(4)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ left: 8 })
        }

        // 失效标签
        if (item.isInvalidated) {
          Text('已失效')
            .fontSize(11)
            .fontColor($r('app.color.app_danger'))
            .margin({ left: 8 })
        }

        // 继承标签
        if (item.isInherited) {
          Text('继承')
            .fontSize(11)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ left: 8 })
        }

        // 禁用标签
        if (!item.isEnabled && !item.isInvalidated) {
          Text('已禁用')
            .fontSize(11)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ left: 8 })
        }
      }
      .width('100%')

      // 摘要预览
      Text(item.summaryPreview)
        .fontSize(13)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ top: 6 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 展开详情
      if (this.viewModel.expandedMemoryId === item.memory.id) {
        this.memoryItemDetail(item)
      }

      // 底部信息:范围 + 时间
      Row() {
        Text('范围: ' + item.coverageText)
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        Blank()
        Text(item.createdTimeText)
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      }
      .width('100%')
      .margin({ top: 8 })

      // 操作按钮
      if (this.viewModel.expandedMemoryId === item.memory.id && !item.isInvalidated) {
        Row() {
          Button(item.isEnabled ? '禁用' : '启用')
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .layoutWeight(1)
            .enabled(!this.viewModel.isOperating)
            .onClick(() => {
              this.viewModel.toggleEnabled(item.memory.id);
            })

          Divider().vertical(true).height(20).color(ThemePalette.dividerColor(this.effectiveTheme))

          Button('编辑')
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .layoutWeight(1)
            .enabled(!this.viewModel.isOperating)
            .onClick(() => {
              this.viewModel.enterEditMode(item.memory.id);
            })

          Divider().vertical(true).height(20).color(ThemePalette.dividerColor(this.effectiveTheme))

          Button('删除')
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_danger'))
            .layoutWeight(1)
            .enabled(!this.viewModel.isOperating)
            .onClick(() => {
              this.viewModel.requestDelete(item.memory.id);
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(8)
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .margin({ top: 8 })
    .onClick(() => {
      this.viewModel.toggleExpand(item.memory.id);
    })
  }

  @Builder
  memoryItemDetail(item: MemoryDisplayItem) {
    Column() {
      // 完整摘要
      if (this.viewModel.isEditing && this.viewModel.editingMemoryId === item.memory.id) {
        this.summaryEditArea(item)
      } else {
        Text(item.memory.summary)
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 8 })
          .lineHeight(20)
      }

      // 详细内容(仅当与 summary 内容不同时显示,避免完整章节重复展示)
      if (item.memory.detail.length > 0 && item.memory.detail !== item.memory.summary) {
        Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 8, bottom: 8 })

        Text('详细内容')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ bottom: 4 })
        Text(item.memory.detail)
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .lineHeight(20)
      }
    }
    .width('100%')
    .margin({ top: 8 })
    .onClick(() => {
      // 阻止冒泡到卡片点击
    })
  }

  @Builder
  summaryEditArea(item: MemoryDisplayItem) {
    Column() {
      Row() {
        Text('编辑摘要')
          .fontSize(13)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        Blank()
        Text('取消')
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .margin({ right: 16 })
          .onClick(() => {
            this.viewModel.cancelEdit();
          })
        Text('保存')
          .fontSize(12)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .onClick(() => {
            this.viewModel.saveEditedSummary();
          })
      }
      .width('100%')

      TextArea({ text: this.viewModel.editingSummary, placeholder: '编辑摘要内容' })
        .fontSize(13)
        .width('100%')
        .height(160)
        .margin({ top: 8 })
        .onChange((value: string) => {
          this.viewModel.editingSummary = value;
        })
    }
    .width('100%')
    .margin({ top: 8 })
  }

  @Builder
  statsCard() {
    Column() {
      Row() {
        Text('消息总数')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Blank()
        Text(this.viewModel.totalMessageCount.toString())
          .fontSize(13)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({ top: 8, bottom: 4 })

      Row() {
        Text('已总结消息数')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Blank()
        Text(this.viewModel.summarizedMessageCount.toString())
          .fontSize(13)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('未总结消息数')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Blank()
        Text(this.viewModel.unsummarizedMessageCount.toString())
          .fontSize(13)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('未总结字符数')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Blank()
        Text(this.viewModel.unsummarizedChars.toString())
          .fontSize(13)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Text('记忆总字符数')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        Blank()
        Text(this.viewModel.summaryChars.toString())
          .fontSize(13)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .padding({ top: 4, bottom: 8 })

      Divider().color(ThemePalette.dividerColor(this.effectiveTheme)).margin({ top: 6, bottom: 6 })

      Row() {
        Column() {
          Text('自动总结')
            .fontSize(13)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          Text(this.memoryAutoSummary ? '每次回复后自动生成' : '手动触发,有利于缓存')
            .fontSize(11)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.memoryAutoSummary })
          .onChange((isOn: boolean) => {
            this.memoryAutoSummary = isOn;
            this.persistMemoryAutoSummary(isOn);
          })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
    .borderRadius(8)
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .margin({ top: 8 })
  }

  @Builder
  actionButtons() {
    Column() {
      // 重新生成
      Button('重新生成章节')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(44)
        .margin({ top: 16 })
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .enabled(!this.viewModel.isOperating && this.viewModel.totalMessageCount > 0)
        .onClick(() => {
          this.viewModel.regenerateSummary();
        })

      // 清除当前分支记忆
      Button('清除当前分支记忆')
        .type(ButtonType.Capsule)
        .width('100%')
        .height(44)
        .margin({ top: 12 })
        .backgroundColor(Color.Transparent)
        .fontColor($r('app.color.app_danger'))
        .enabled(!this.viewModel.isOperating)
        .border({ width: 1, color: $r('app.color.app_danger') })
        .onClick(() => {
          this.showClearConfirm = true;
        })
    }
    .width('100%')
  }

  @Builder
  clearConfirmDialog() {
    Stack() {
      Column() {
        Text('清除当前分支记忆')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ top: 16, bottom: 8 })

        Text('此操作将删除当前分支自产的记忆摘要(继承自祖先的不删)。原始消息不会被修改。')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .lineHeight(20)
          .margin({ left: 16, right: 16, bottom: 16 })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

        Row() {
          Button('取消')
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .layoutWeight(1)
            .height(48)
            .onClick(() => {
              this.showClearConfirm = false;
            })

          Divider().vertical(true).height(24).color(ThemePalette.dividerColor(this.effectiveTheme))

          Button('清除')
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_danger'))
            .layoutWeight(1)
            .height(48)
            .onClick(() => {
              this.showClearConfirm = false;
              this.executeClear();
            })
        }
        .width('100%')
      }
      .width('80%')
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.showClearConfirm = false;
    })
  }

  @Builder
  deleteConfirmDialog() {
    Stack() {
      Column() {
        Text('删除记忆')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ top: 16, bottom: 8 })

        Text('确定要删除这条记忆吗?删除后不可恢复,但原始消息不会被修改。')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .lineHeight(20)
          .margin({ left: 16, right: 16, bottom: 16 })

        Divider().color(ThemePalette.dividerColor(this.effectiveTheme))

        Row() {
          Button('取消')
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .layoutWeight(1)
            .height(48)
            .onClick(() => {
              this.viewModel.cancelDelete();
            })

          Divider().vertical(true).height(24).color(ThemePalette.dividerColor(this.effectiveTheme))

          Button('删除')
            .fontSize(15)
            .backgroundColor(Color.Transparent)
            .fontColor($r('app.color.app_danger'))
            .layoutWeight(1)
            .height(48)
            .onClick(() => {
              this.viewModel.confirmDelete();
            })
        }
        .width('100%')
      }
      .width('80%')
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.viewModel.cancelDelete();
    })
  }

  private async executeClear(): Promise<void> {
    await this.viewModel.clearOwnedMemory();
    if (this.viewModel.errorMessage.length === 0) {
      promptAction.showToast({ message: '已清除当前分支记忆', duration: 1500 });
    }
  }

  private async loadMemoryAutoSummaryPref(): Promise<void> {
    try {
      const prefs = AppServices.getAppPreferences();
      const val: string = await prefs.getString(MEMORY_AUTO_SUMMARY_PREFS_KEY, 'false');
      this.memoryAutoSummary = val === 'true';
    } catch (_e) {
      this.memoryAutoSummary = false;
    }
  }

  private persistMemoryAutoSummary(enabled: boolean): void {
    const prefs = AppServices.getAppPreferences();
    prefs.putString(MEMORY_AUTO_SUMMARY_PREFS_KEY, enabled ? 'true' : 'false')
      .catch((_e: Object): void => {});
  }
}
