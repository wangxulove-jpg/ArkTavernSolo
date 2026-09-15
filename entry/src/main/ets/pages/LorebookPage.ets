/**
 * LorebookPage 世界书页面
 *
 * 支持世界书列表、新建/编辑/删除、设为当前、启用/禁用,
 * 以及条目的新建/编辑/删除。
 * 页面只通过 LorebookViewModel 操作,不直接调用 LorebookService。
 *
 * 要求:
 * - 页面只通过 ViewModel 访问业务能力
 * - 不直接调用 LorebookService/LorebookStore
 * - 所有 @Builder 方法不传参数,直接访问 this.viewModel
 * - 深色模式可读
 */

import { LorebookViewModel } from '../viewmodels/LorebookViewModel';
import { LorebookService } from '../services/LorebookService';
import { CharacterService } from '../services/CharacterService';
import { CharacterBookRef } from '../repositories/CharacterRepository';
import { Lorebook, LorebookEntry, LorebookActivationMode } from '../models/Lorebook';
import { AppServices } from '../services/AppServices';
import { router, promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { ThemePalette } from '../theme/ThemePalette';

/**
 * 使用 ThemePalette 统一主题色,支持酒馆棕等主题切换。
 * 页面/卡片/文字/操作色全部通过 ThemePalette.* 访问,
 * 不使用 worldbook_* 独立资源或 sys.color.* 系统色。
 */

@Entry
@Component
struct LorebookPage {
  @State viewModel: LorebookViewModel | null = null;
  @State lorebooks: Lorebook[] = [];
  @State currentLorebookId: string | null = null;
  /** 本地 @State 镜像 ViewModel 的 UI 状态,确保属性变化触发重渲染 */
  @State showLorebookDialog: boolean = false;
  @State showEntryDialog: boolean = false;
  @State expandedLorebookId: string | null = null;
  @State deleteTargetLorebook: Lorebook | null = null;
  @State deleteTargetEntry: LorebookEntry | null = null;
  @State deleteTargetEntryLorebookId: string = '';
  @State vmErrorMessage: string = '';
  /** 世界书 id → 绑定角色引用(镜像 ViewModel,用于展示绑定关系) */
  @State boundCharacterMap: Record<string, CharacterBookRef[]> = {};
  /** 是否正在导入世界书文件 */
  @State importingLorebook: boolean = false;
  /** 导入成功待操作的归书(null 表示关闭导入结果弹窗) */
  @State importedBook: Lorebook | null = null;
  /** 绑定角色选择弹窗是否显示 */
  @State showBindPicker: boolean = false;
  /** 绑定角色弹窗对应的世界书 ID */
  @State bindTargetBookId: string = '';
  /** 可选绑定角色列表 */
  @State bindCharacters: CharacterBookRef[] = [];
  /** 本地 @State 镜像,用于条目编辑对话框表单字段 */
  @State editEntryName: string = '';
  @State editEntryKeys: string = '';
  @State editEntrySecondaryKeys: string = '';
  @State editEntryContent: string = '';
  @State editEntryConstant: boolean = false;
  @State editEntrySelective: boolean = false;
  @State editEntryEnabled: boolean = true;
  @State editEntryPosition: number = 0;
  @State editEntryPriority: number = 0;
  /** 本地 @State 镜像:世界书编辑对话框的激活方式与预算 */
  @State editLorebookActivationMode: number = 0;
  @State editLorebookBudget: string = '';
  /** 本地 @State 镜像:全局默认激活方式与深度 */
  @State globalActivationMode: string = 'OnDemand';
  @State globalInjectionDepth: number = 2;
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部手势条/导航栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    const service: LorebookService = AppServices.getLorebookService();
    const characterService: CharacterService = AppServices.getCharacterService();
    const vm: LorebookViewModel = new LorebookViewModel(
      service, characterService, AppServices.getAppPreferences()
    );
    this.viewModel = vm;
    vm.onDataUpdate = () => {
      this.syncFromViewModel();
    };
    vm.load();
  }

  /** 页面每次回显时重新加载(从"查看源码"编辑器返回后立即刷新为最新内容,无需退出重进) */
  onPageShow(): void {
    if (this.viewModel !== null) {
      this.viewModel.load();
    }
  }

  /** 将 ViewModel 的所有 UI 状态同步到本地 @State,确保属性变化触发重渲染 */
  private syncFromViewModel(): void {
    if (this.viewModel === null) {
      return;
    }
    this.lorebooks = [...this.viewModel.lorebooks];
    this.currentLorebookId = this.viewModel.currentLorebookId;
    this.showLorebookDialog = this.viewModel.showLorebookDialog;
    this.showEntryDialog = this.viewModel.showEntryDialog;
    this.expandedLorebookId = this.viewModel.expandedLorebookId;
    this.deleteTargetLorebook = this.viewModel.deleteTargetLorebook;
    this.deleteTargetEntry = this.viewModel.deleteTargetEntry;
    this.deleteTargetEntryLorebookId = this.viewModel.deleteTargetEntryLorebookId;
    this.vmErrorMessage = this.viewModel.errorMessage;
    this.boundCharacterMap = this.viewModel.boundCharacterMap;
    // 同步条目编辑表单字段
    this.editEntryName = this.viewModel.editEntryName;
    this.editEntryKeys = this.viewModel.editEntryKeys;
    this.editEntrySecondaryKeys = this.viewModel.editEntrySecondaryKeys;
    this.editEntryContent = this.viewModel.editEntryContent;
    this.editEntryConstant = this.viewModel.editEntryConstant;
    this.editEntrySelective = this.viewModel.editEntrySelective;
    this.editEntryEnabled = this.viewModel.editEntryEnabled;
    this.editEntryPosition = this.viewModel.editEntryPosition;
    this.editEntryPriority = this.viewModel.editEntryPriority;
    // 同步世界书编辑对话框的激活方式与预算
    this.editLorebookActivationMode = this.viewModel.editLorebookActivationMode;
    this.editLorebookBudget = this.viewModel.editLorebookBudget;
    // 同步全局默认激活方式与深度
    this.globalActivationMode = this.viewModel.globalActivationMode;
    this.globalInjectionDepth = this.viewModel.globalInjectionDepth;
  }

  /** 选择并导入世界书文件(JSON)。成功后弹出操作弹窗。 */
  private async pickLorebookFile(): Promise<void> {
    if (this.importingLorebook || this.viewModel === null) {
      return;
    }
    let uris: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.json', '.txt', '.png'];
      uris = await documentPicker.select(options);
    } catch (e) {
      promptAction.showToast({ message: '打开文件选择器失败', duration: 2000 });
      return;
    }
    if (uris.length === 0) {
      return;
    }
    this.importingLorebook = true;
    try {
      const book: Lorebook = await this.viewModel.importLorebookFile(uris[0]);
      this.importedBook = book;
      this.syncFromViewModel();
    } catch (e) {
      const msg: string = (e as Error).message ?? '导入失败';
      promptAction.showToast({ message: msg, duration: 2500 });
    } finally {
      this.importingLorebook = false;
    }
  }

  /** 打开绑定角色选择弹窗。 */
  private async openBindPicker(bookId: string): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    this.bindTargetBookId = bookId;
    this.importedBook = null;
    this.bindCharacters = await this.viewModel.listCharactersForBinding();
    this.showBindPicker = true;
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏:返回 + 标题
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
            .padding(8)
            .onClick(() => {
              router.back();
            })

          Text($r('app.string.nav_lorebook_title'))
            .fontSize($r('app.float.nav_title_font_size'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8 })

          Button($r('app.string.lorebook_import'))
            .fontSize(13)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(32)
            .padding({ left: 10, right: 10 })
            .enabled(!this.importingLorebook)
            .onClick(() => {
              void this.pickLorebookFile();
            })
        }
        .width('100%')
        .padding({ top: this.statusBarHeight + 12, left: 12, right: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)

        // 错误提示
        if (this.vmErrorMessage.length > 0) {
          Text(this.vmErrorMessage)
            .fontSize(13)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 4 })
        }

        // 全局默认激活方式设置
        this.globalSettingsPanel()

        // 内容区
        Column() {
          if (this.lorebooks.length === 0) {
            this.emptyState();
          } else {
            // 用 List 而非 Scroll 承载列表:展开世界书后内容变高,List 会对每个 ListItem
            // 重新测量高度并保持可滚动到底部,避免"新建条目"按钮被推出屏幕/点不到。
            List({ space: 8 }) {
              ForEach(this.lorebooks, (lb: Lorebook) => {
                ListItem() {
                  this.lorebookCard(lb);
                }
              }, (lb: Lorebook) => lb.id + '_' + lb.updatedAt)
              // 底部留白:按底部手势条高度动态避让,保留足够保底,避免最后一个条目标签被系统底栏遮挡
              ListItem() {
                Column()
                  .width('100%')
                  .height(Math.max(126, this.navigationBarHeight + 64))
              }
            }
            // 水平缩进放在 List 的 padding,避免子元素 width('100%')+横向 margin 溢出右侧
            .padding({ left: 12, right: 12 })
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
            .width('100%')
            .height('100%')
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')

      // FAB(展开任意世界书时隐藏,避免遮挡卡片底部的"新建条目"按钮)
      if (this.viewModel !== null && this.expandedLorebookId === null) {
        Button($r('app.string.lorebook_new'))
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius(24)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .position({ x: '80%', y: '90%' })
          .onClick(() => {
            this.viewModel!.showNewLorebookDialog();
            this.syncFromViewModel();
          })
      }

      // 世界书编辑对话框
      if (this.showLorebookDialog) {
        this.lorebookDialog();
      }

      // 条目编辑对话框
      if (this.showEntryDialog) {
        this.entryDialog();
      }

      // 删除确认(世界书)
      if (this.deleteTargetLorebook !== null) {
        this.deleteLorebookConfirm();
      }

      // 删除确认(条目)
      if (this.deleteTargetEntry !== null) {
        this.deleteEntryConfirm();
      }

      // 导入结果弹窗
      if (this.importedBook !== null) {
        this.importResultDialog();
      }

      // 绑定角色弹窗
      if (this.showBindPicker) {
        this.bindCharacterDialog();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ===== 空状态 =====

  @Builder
  emptyState() {
    Column() {
      Text($r('app.string.lorebook_no_lorebooks'))
        .fontSize(16)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ bottom: 8 })
      Text($r('app.string.lorebook_no_lorebooks_desc'))
        .fontSize(13)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ===== 全局默认激活方式设置 =====

  @Builder
  globalSettingsPanel() {
    Column() {
      Text('全局默认激活方式')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Button('全量注入')
          .fontSize(12)
          .backgroundColor(this.globalActivationMode === 'FullInject'
            ? ThemePalette.accentColor(this.effectiveTheme)
            : ThemePalette.surface2Color(this.effectiveTheme))
          .fontColor(this.globalActivationMode === 'FullInject'
            ? $r('app.color.app_on_accent')
            : ThemePalette.textPrimaryColor(this.effectiveTheme))
          .borderRadius(16)
          .height(32)
          .layoutWeight(1)
          .margin({ right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              void this.viewModel.setGlobalActivationMode(LorebookActivationMode.FullInject).then(() => {
                this.syncFromViewModel();
              });
            }
          })

        Button('按需激活')
          .fontSize(12)
          .backgroundColor(this.globalActivationMode === 'OnDemand'
            ? ThemePalette.accentColor(this.effectiveTheme)
            : ThemePalette.surface2Color(this.effectiveTheme))
          .fontColor(this.globalActivationMode === 'OnDemand'
            ? $r('app.color.app_on_accent')
            : ThemePalette.textPrimaryColor(this.effectiveTheme))
          .borderRadius(16)
          .height(32)
          .layoutWeight(1)
          .onClick(() => {
            if (this.viewModel !== null) {
              void this.viewModel.setGlobalActivationMode(LorebookActivationMode.OnDemand).then(() => {
                this.syncFromViewModel();
              });
            }
          })
      }
      .width('100%')

      Text(this.globalActivationMode === 'FullInject'
        ? '全量:所有启用条目注入头部,缓存命中最高,上下文占用大'
        : '按需:恒定条目注入头部,关键词命中条目注入对话尾部,最省上下文')
        .fontSize(11)
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ top: 6 })

      // 深度注入位置(仅按需激活时显示)
      if (this.globalActivationMode === 'OnDemand') {
        Row() {
          Text('深度注入位置')
            .fontSize(12)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .layoutWeight(1)
          Button('-')
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(14)
            .width(28)
            .height(28)
            .margin({ right: 8 })
            .enabled(this.globalInjectionDepth > 0)
            .onClick(() => {
              if (this.viewModel !== null && this.globalInjectionDepth > 0) {
                void this.viewModel.setGlobalInjectionDepth(this.globalInjectionDepth - 1).then(() => {
                  this.syncFromViewModel();
                });
              }
            })
          Text(this.globalInjectionDepth.toString())
            .fontSize(14)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .width(24)
            .textAlign(TextAlign.Center)
            .margin({ right: 8 })
          Button('+')
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(14)
            .width(28)
            .height(28)
            .enabled(this.globalInjectionDepth < 8)
            .onClick(() => {
              if (this.viewModel !== null && this.globalInjectionDepth < 8) {
                void this.viewModel.setGlobalInjectionDepth(this.globalInjectionDepth + 1).then(() => {
                  this.syncFromViewModel();
                });
              }
            })
        }
        .width('100%')
        .margin({ top: 8 })

        Text(this.globalInjectionDepth === 0
          ? '0 = 注入到全部消息之后'
          : '命中条目注入到倒数第 ' + this.globalInjectionDepth.toString() + ' 条消息之前')
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
    .borderRadius(10)
    .margin({ bottom: 4 })
  }

  // ===== 世界书卡片 =====

  @Builder
  lorebookCard(lb: Lorebook) {
    Column() {
      // 主卡片
      Row() {
        Column() {
          Row() {
            if (this.currentLorebookId === lb.id) {
              Text($r('app.string.lorebook_current_badge'))
                .fontSize(11)
                .fontColor($r('app.color.app_on_accent'))
                .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
                .borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ right: 6 })
            }
            if (!lb.enabled) {
              Text($r('app.string.lorebook_disabled'))
                .fontSize(11)
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .border({ width: 1, color: ThemePalette.textTertiaryColor(this.effectiveTheme), style: BorderStyle.Solid })
                .borderRadius(8)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ right: 6 })
            }
            // 激活方式徽标(全量/按需/跟随全局)
            Text(this.viewModel !== null
              ? this.viewModel.getActivationModeText(lb.activationMode) : '')
              .fontSize(11)
              .fontColor(lb.activationMode === LorebookActivationMode.FollowGlobal
                ? ThemePalette.textSecondaryColor(this.effectiveTheme)
                : ThemePalette.accentColor(this.effectiveTheme))
              .backgroundColor(lb.activationMode === LorebookActivationMode.FollowGlobal
                ? ThemePalette.surface2Color(this.effectiveTheme)
                : ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ right: 6 })
            Text(lb.name)
              .fontSize(15)
              .fontColor(lb.enabled
                ? ThemePalette.textPrimaryColor(this.effectiveTheme)
                : ThemePalette.textTertiaryColor(this.effectiveTheme))
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')

          if (lb.description.length > 0) {
            Text(lb.description)
              .fontSize(12)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
              .width('100%')
          }

          Row() {
            Text(this.viewModel !== null
              ? this.viewModel.getEntryCountText(lb) : '')
              .fontSize(11)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .margin({ top: 4 })
          }
          .width('100%')

          // 绑定角色行
          this.boundCharactersLine(lb.id)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 展开/折叠按钮
        Image($r('sys.media.ohos_ic_public_arrow_down'))
          .width(16)
          .height(16)
          .fillColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ left: 8 })
          .rotate({
            angle: this.expandedLorebookId === lb.id ? 180 : 0
          })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.toggleExpand(lb.id);
              this.syncFromViewModel();
            }
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 10 })
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.toggleExpand(lb.id);
          this.syncFromViewModel();
        }
      })

      // 操作按钮行
      Row() {
        Button($r('app.string.lorebook_set_current'))
          .fontSize(12)
          .backgroundColor(this.currentLorebookId === lb.id
            ? ThemePalette.surface2Color(this.effectiveTheme)
            : Color.Transparent)
          .fontColor(this.currentLorebookId === lb.id
            ? ThemePalette.accentColor(this.effectiveTheme)
            : ThemePalette.textSecondaryColor(this.effectiveTheme))
          .height(28)
          .padding({ left: 8, right: 8 })
          .borderRadius(6)
          .onClick(() => {
            if (this.viewModel !== null) {
              void this.viewModel.setCurrentLorebook(
                this.currentLorebookId === lb.id ? null : lb.id
              ).then(() => {
                this.syncFromViewModel();
              });
            }
          })

        Button($r('app.string.lorebook_edit'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(28)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showEditLorebookDialog(lb);
              this.syncFromViewModel();
            }
          })

        Button(lb.enabled
          ? $r('app.string.lorebook_disable')
          : $r('app.string.lorebook_enable'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor(lb.enabled
            ? ThemePalette.accentColor(this.effectiveTheme)
            : ThemePalette.accentColor(this.effectiveTheme))
          .height(28)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              void this.viewModel.toggleLorebookEnabled(lb).then(() => {
                this.syncFromViewModel();
              });
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.app_danger'))
          .height(28)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetLorebook = lb;
              this.syncFromViewModel();
            }
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8, bottom: 8 })
      .justifyContent(FlexAlign.SpaceEvenly)

      // 条目列表(展开时显示)
      if (this.expandedLorebookId === lb.id) {
        Divider()
          .color(ThemePalette.dividerColor(this.effectiveTheme))
          .width('100%')
          .height(1)

        // 条目子块统一用内边距缩进,避免 width('100%')+横向 margin 溢出右侧
        Column() {
          if (lb.entries.length === 0) {
            Text($r('app.string.lorebook_no_entries'))
              .fontSize(13)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .padding(16)
              .width('100%')
              .textAlign(TextAlign.Center)
          } else {
            ForEach(lb.entries, (entry: LorebookEntry) => {
              this.entryRow(lb.id, entry);
            }, (entry: LorebookEntry) => entry.id + '_' + entry.updatedAt);
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12 })

        // 绑定角色区(展开时显示)
        this.boundCharactersExpand(lb.id)

        Button($r('app.string.lorebook_new_entry'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(32)
          .width('100%')
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showNewEntryDialog(lb.id);
              this.syncFromViewModel();
            }
          })
      }
    }
    .width('100%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
    .borderRadius(10)
    .margin({ top: 8 })
  }

  // ===== 世界书绑定角色 =====

  /** 卡片标题下方的绑定角色概览行(可换行,避免右侧溢出) */
  @Builder
  boundCharactersLine(bookId: string) {
    Flex({ wrap: FlexWrap.Wrap }) {
      if (this.viewModel !== null && this.viewModel.hasBoundCharacters(bookId)) {
        Text($r('app.string.lorebook_bound_characters_label'))
          .fontSize(11)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .margin({ right: 4 })
        ForEach(this.viewModel.getBoundCharacters(bookId), (ref: CharacterBookRef) => {
          Text(ref.name)
            .fontSize(11)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '70%' })
            .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            .margin({ right: 4, bottom: 2 })
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius(8)
        }, (ref: CharacterBookRef) => ref.id)
      } else {
        Text($r('app.string.lorebook_bound_none'))
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      }
    }
    .width('100%')
    .margin({ top: 4 })
  }

  /** 展开区:列出绑定角色(可逐个解除),并支持"绑定到角色…"新增绑定 */
  @Builder
  boundCharactersExpand(bookId: string) {
    if (this.viewModel !== null) {
      Divider()
        .color(ThemePalette.dividerColor(this.effectiveTheme))
        .width('100%')
        .height(1)
        .margin({ top: 4 })
      Text($r('app.string.lorebook_bound_characters_section'))
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 12, right: 12, top: 10 })

      if (this.viewModel.hasBoundCharacters(bookId)) {
        ForEach(this.viewModel.getBoundCharacters(bookId), (ref: CharacterBookRef) => {
          Row() {
            Text(ref.name)
              .fontSize(13)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Button($r('app.string.lorebook_unbind_character'))
              .fontSize(12)
              .backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.accentColor(this.effectiveTheme))
              .height(28)
              .padding({ left: 8, right: 8 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  void this.viewModel.unbindCharacter(bookId, ref.id).then(() => {
                    this.syncFromViewModel();
                  });
                }
              })
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 6, bottom: 4 })
        }, (ref: CharacterBookRef) => ref.id)
      } else {
        Text($r('app.string.lorebook_bound_none'))
          .fontSize(12)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ left: 12, right: 12, top: 6, bottom: 8 })
      }
    }
  }

  // ===== 条目行 =====

  @Builder
  entryRow(lorebookId: string, entry: LorebookEntry) {
    Column() {
      Row() {
        Column() {
          Row() {
            if (!entry.enabled) {
              Text($r('app.string.lorebook_disabled'))
                .fontSize(10)
                .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
                .border({ width: 1, color: ThemePalette.textTertiaryColor(this.effectiveTheme), style: BorderStyle.Solid })
                .borderRadius(6)
                .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                .margin({ right: 4 })
            }
            Text(entry.name)
              .fontSize(13)
              .fontColor(entry.enabled
                ? ThemePalette.textPrimaryColor(this.effectiveTheme)
                : ThemePalette.textTertiaryColor(this.effectiveTheme))
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')

          Row() {
            if (entry.constant) {
              Text('恒定')
                .fontSize(10)
                .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                .margin({ right: 4 })
            }
            if (entry.selective) {
              Text('Selective')
                .fontSize(10)
                .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                .margin({ right: 4 })
            }
            if (entry.keys.length > 0) {
              Text(entry.keys.join(', '))
                .fontSize(10)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ right: 4 })
            } else {
              // 无 keys 时占位,避免优先级/位置被挤到右侧溢出
              Row().layoutWeight(1)
            }
            if (this.viewModel !== null) {
              Text('P' + entry.priority.toString())
                .fontSize(10)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .margin({ right: 4 })
              Text(this.viewModel.getPositionText(entry.position))
                .fontSize(10)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            }
          }
          .width('100%')
          .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button($r('app.string.lorebook_edit'))
          .fontSize(11)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(24)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.showEditEntryDialog(lorebookId, entry);
              this.syncFromViewModel();
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(11)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.app_danger'))
          .height(24)
          .padding({ left: 6, right: 6 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetEntry = entry;
              this.viewModel.deleteTargetEntryLorebookId = lorebookId;
              this.syncFromViewModel();
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    }
    .width('100%')
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .border({ width: 1, color: ThemePalette.dividerColor(this.effectiveTheme) })
    .margin({ bottom: 6 })
    .borderRadius(8)
  }

  // ===== 世界书编辑对话框 =====

  @Builder
  lorebookDialog() {
    Stack() {
      Column() {
        // 遮罩
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.closeLorebookDialog();
        }
      })

      Scroll() {
      Column() {
        Text(this.viewModel !== null && this.viewModel.editingLorebook !== null
          ? $r('app.string.lorebook_form_title_edit')
          : $r('app.string.lorebook_form_title_new'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 16 })

        Text($r('app.string.lorebook_form_name'))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })

        TextInput({
          placeholder: $r('app.string.lorebook_form_name_placeholder'),
          text: this.viewModel !== null ? this.viewModel.editLorebookName : ''
        })
          .fontSize(14)
          .width('100%')
          .margin({ bottom: 12 })
          .onChange((value: string) => {
            if (this.viewModel !== null) {
              this.viewModel.editLorebookName = value;
            }
          })

        Text($r('app.string.lorebook_form_description'))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })

        TextInput({
          placeholder: $r('app.string.lorebook_form_description_placeholder'),
          text: this.viewModel !== null ? this.viewModel.editLorebookDescription : ''
        })
          .fontSize(14)
          .width('100%')
          .margin({ bottom: 12 })
          .onChange((value: string) => {
            if (this.viewModel !== null) {
              this.viewModel.editLorebookDescription = value;
            }
          })

        // 激活方式(三选一:跟随全局/全量/按需)
        Text('激活方式')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })

        Row() {
          Button('跟随全局')
            .fontSize(12)
            .backgroundColor(this.editLorebookActivationMode === 0
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(this.editLorebookActivationMode === 0
              ? $r('app.color.app_on_accent')
              : ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(16)
            .height(32)
            .layoutWeight(1)
            .margin({ right: 6 })
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel.editLorebookActivationMode = 0;
              }
              this.editLorebookActivationMode = 0;
            })

          Button('全量')
            .fontSize(12)
            .backgroundColor(this.editLorebookActivationMode === 1
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(this.editLorebookActivationMode === 1
              ? $r('app.color.app_on_accent')
              : ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(16)
            .height(32)
            .layoutWeight(1)
            .margin({ right: 6 })
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel.editLorebookActivationMode = 1;
              }
              this.editLorebookActivationMode = 1;
            })

          Button('按需')
            .fontSize(12)
            .backgroundColor(this.editLorebookActivationMode === 2
              ? ThemePalette.accentColor(this.effectiveTheme)
              : ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(this.editLorebookActivationMode === 2
              ? $r('app.color.app_on_accent')
              : ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius(16)
            .height(32)
            .layoutWeight(1)
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel.editLorebookActivationMode = 2;
              }
              this.editLorebookActivationMode = 2;
            })
        }
        .width('100%')
        .margin({ bottom: 4 })

        Text(this.editLorebookActivationMode === 1
          ? '全量:所有启用条目注入头部,缓存命中最高,上下文占用大'
          : (this.editLorebookActivationMode === 2
            ? '按需:恒定条目注入头部,关键词命中条目注入对话尾部,最省上下文'
            : '跟随:使用页面顶部的全局默认激活方式'))
          .fontSize(11)
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 12 })

        // 注入预算(字符)
        Text('注入预算(字符,0 = 默认 12000)')
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })

        TextInput({
          placeholder: '0',
          text: this.editLorebookBudget
        })
          .fontSize(14)
          .type(InputType.Number)
          .width('100%')
          .margin({ bottom: 12 })
          .onChange((value: string) => {
            if (this.viewModel !== null) {
              this.viewModel.editLorebookBudget = value;
            }
            this.editLorebookBudget = value;
          })

        // 查看源码(仅编辑模式)
        if (this.viewModel !== null && this.viewModel.editingLorebook !== null) {
          Button($r('app.string.lorebook_source_open'))
            .fontSize(13)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(36)
            .width('100%')
            .borderRadius(18)
            .margin({ bottom: 16 })
            .onClick(() => {
              this.openSourceEditor(this.getEditingLorebookId());
            })
        }

        // 绑定角色(仅编辑模式)
        if (this.viewModel !== null && this.viewModel.editingLorebook !== null) {
          Divider()
            .color(ThemePalette.dividerColor(this.effectiveTheme))
            .width('100%')
            .height(1)
            .margin({ top: 4, bottom: 12 })

          Text($r('app.string.lorebook_bound_characters_section'))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .width('100%')
            .margin({ bottom: 6 })

          if (this.viewModel.hasBoundCharacters(this.getEditingLorebookId())) {
            ForEach(this.viewModel.getBoundCharacters(this.getEditingLorebookId()),
              (ref: CharacterBookRef) => {
                Row() {
                  Text(ref.name)
                    .fontSize(13)
                    .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Button($r('app.string.lorebook_unbind_character'))
                    .fontSize(12)
                    .backgroundColor(Color.Transparent)
                    .fontColor(ThemePalette.accentColor(this.effectiveTheme))
                    .height(28)
                    .padding({ left: 8, right: 8 })
                    .onClick(() => {
                      if (this.viewModel !== null) {
                        void this.viewModel.unbindCharacter(
                          this.getEditingLorebookId(), ref.id
                        ).then(() => {
                          this.syncFromViewModel();
                        });
                      }
                    })
                }
                .width('100%')
                .padding({ top: 4, bottom: 4 })
              }, (ref: CharacterBookRef) => ref.id)
          } else {
            Text($r('app.string.lorebook_bound_none'))
              .fontSize(13)
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .width('100%')
              .margin({ bottom: 8 })
          }

          Button($r('app.string.lorebook_bind_character_action'))
            .fontSize(13)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(36)
            .width('100%')
            .borderRadius(18)
            .margin({ bottom: 16 })
            .onClick(() => {
              const bookId: string = this.getEditingLorebookId();
              if (this.viewModel !== null) {
                this.viewModel.closeLorebookDialog();
              }
              this.syncFromViewModel();
              if (bookId.length > 0) {
                void this.openBindPicker(bookId);
              }
            })
        }

        Row() {
          Button($r('app.string.lorebook_form_cancel'))
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ right: 8 })
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel.closeLorebookDialog();
                this.syncFromViewModel();
              }
            })

          Button($r('app.string.lorebook_form_save'))
            .fontSize(14)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              if (this.viewModel !== null) {
                void this.viewModel.saveLorebook().then(() => {
                  this.syncFromViewModel();
                });
              }
            })
        }
        .width('100%')
      }
      .width('100%')
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .width('85%')
    .height('70%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
    .padding(20)
    .position({ x: '7.5%', y: '15%' })
    }
    .width('100%')
    .height('100%')
  }

  // ===== 条目编辑对话框 =====

  @Builder
  entryDialog() {
    Stack() {
      Column() {
        // 遮罩
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.closeEntryDialog();
        }
      })

      Scroll() {
      Column() {
        Text(this.viewModel !== null && this.viewModel.editingEntry !== null
          ? $r('app.string.lorebook_entry_form_title_edit')
          : $r('app.string.lorebook_entry_form_title_new'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 12 })

        this.entryFormField(
          $r('app.string.lorebook_entry_name'),
          $r('app.string.lorebook_entry_name_placeholder'),
          this.editEntryName,
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryName = value;
            }
            this.editEntryName = value;
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_keys'),
          $r('app.string.lorebook_entry_keys_placeholder'),
          this.editEntryKeys,
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryKeys = value;
            }
            this.editEntryKeys = value;
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_secondary_keys'),
          $r('app.string.lorebook_entry_secondary_keys_placeholder'),
          this.editEntrySecondaryKeys,
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntrySecondaryKeys = value;
            }
            this.editEntrySecondaryKeys = value;
          }
        )

        this.entryFormField(
          $r('app.string.lorebook_entry_content'),
          $r('app.string.lorebook_entry_content_placeholder'),
          this.editEntryContent,
          (value: string): void => {
            if (this.viewModel !== null) {
              this.viewModel.editEntryContent = value;
            }
            this.editEntryContent = value;
          },
          true
        )

        // 开关行
        Row() {
          Text($r('app.string.lorebook_entry_enabled'))
            .fontSize(13)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.editEntryEnabled })
            .onChange((isOn: boolean) => {
              if (this.viewModel !== null) {
                this.viewModel.editEntryEnabled = isOn;
              }
              this.editEntryEnabled = isOn;
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        Row() {
          Text($r('app.string.lorebook_entry_constant'))
            .fontSize(13)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.editEntryConstant })
            .onChange((isOn: boolean) => {
              if (this.viewModel !== null) {
                this.viewModel.editEntryConstant = isOn;
              }
              this.editEntryConstant = isOn;
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        Row() {
          Text($r('app.string.lorebook_entry_selective'))
            .fontSize(13)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.editEntrySelective })
            .onChange((isOn: boolean) => {
              if (this.viewModel !== null) {
                this.viewModel.editEntrySelective = isOn;
              }
              this.editEntrySelective = isOn;
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        // 优先级
        Row() {
          Text($r('app.string.lorebook_entry_priority'))
            .fontSize(13)
            .width(60)
          TextInput({
            text: this.editEntryPriority.toString()
          })
            .fontSize(14)
            .type(InputType.Number)
            .layoutWeight(1)
            .onChange((value: string) => {
              if (this.viewModel !== null) {
                const parsed: number = parseInt(value);
                this.viewModel.editEntryPriority = isNaN(parsed) ? 0 : parsed;
              }
              const parsed: number = parseInt(value);
              this.editEntryPriority = isNaN(parsed) ? 0 : parsed;
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        // 位置选择
        Row() {
          Text($r('app.string.lorebook_entry_position'))
            .fontSize(13)
            .width(60)
          Row() {
            Button($r('app.string.lorebook_entry_position_before'))
              .fontSize(12)
              .backgroundColor(this.editEntryPosition === 0
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius(16)
              .height(32)
              .padding({ left: 12, right: 12 })
              .margin({ right: 8 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel.editEntryPosition = 0;
                }
                this.editEntryPosition = 0;
              })

            Button($r('app.string.lorebook_entry_position_after'))
              .fontSize(12)
              .backgroundColor(this.editEntryPosition === 1
                ? ThemePalette.accentColor(this.effectiveTheme)
                : ThemePalette.surface2Color(this.effectiveTheme))
              .borderRadius(16)
              .height(32)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                if (this.viewModel !== null) {
                  this.viewModel.editEntryPosition = 1;
                }
                this.editEntryPosition = 1;
              })
          }
          .layoutWeight(1)
        }
        .width('100%')
        .margin({ bottom: 16 })

        Row() {
          Button($r('app.string.lorebook_form_cancel'))
            .fontSize(14)
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ right: 8 })
            .onClick(() => {
              if (this.viewModel !== null) {
                this.viewModel.closeEntryDialog();
                this.syncFromViewModel();
              }
            })

          Button($r('app.string.lorebook_form_save'))
            .fontSize(14)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              if (this.viewModel !== null) {
                void this.viewModel.saveEntry().then(() => {
                  this.syncFromViewModel();
                });
              }
            })
        }
        .width('100%')
      }
      .width('100%')
    }
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
    .width('85%')
    .height('70%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
    .padding(20)
    .position({ x: '7.5%', y: '15%' })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  entryFormField(
    label: ResourceStr,
    placeholder: ResourceStr,
    text: string,
    onChange: (value: string) => void,
    multiLine: boolean = false
  ) {
    Column() {
      Text(label)
        .fontSize(13)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 4 })

      if (multiLine) {
        TextArea({
          placeholder: placeholder,
          text: text
        })
          .fontSize(14)
          .barState(BarState.Auto)
          .constraintSize({ minHeight: 80, maxHeight: 400 })
          .width('100%')
          .margin({ bottom: 12 })
          .onChange(onChange)
      } else {
        TextInput({
          placeholder: placeholder,
          text: text
        })
          .fontSize(14)
          .barState(BarState.Auto)
          .width('100%')
          .margin({ bottom: 12 })
          .onChange(onChange)
      }
    }
    .width('100%')
  }

  // ===== 导入世界书结果弹窗 =====

  @Builder
  importResultDialog() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.importedBook = null;
      })

      Column() {
        Text($r('app.string.lorebook_import_success_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 8 })

        Text(this.importedBook !== null ? this.importedBook.name : '')
          .fontSize(14)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ bottom: 4 })

        Text(this.importedBook !== null
          ? '已导入 ' + String(this.importedBook.entries.length) + ' 个条目'
          : '')
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ bottom: 16 })

        Button($r('app.string.lorebook_set_current'))
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .height(40)
          .width('100%')
          .borderRadius(20)
          .margin({ bottom: 8 })
          .onClick(() => {
            const id: string = this.importedBook !== null ? this.importedBook.id : '';
            this.importedBook = null;
            if (id.length > 0 && this.viewModel !== null) {
              void this.viewModel.setCurrentLorebook(id).then(() => {
                this.syncFromViewModel();
              });
            }
          })

        Button($r('app.string.lorebook_import_bind_character'))
          .fontSize(14)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .height(40)
          .width('100%')
          .borderRadius(20)
          .margin({ bottom: 8 })
          .onClick(() => {
            const id: string = this.importedBook !== null ? this.importedBook.id : '';
            if (id.length > 0) {
              void this.openBindPicker(id);
            }
          })

        Button($r('app.string.dialog_done'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .height(40)
          .width('100%')
          .onClick(() => {
            this.importedBook = null;
          })
      }
      .width('82%')
      .padding(20)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(16)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.4)')
    .onClick(() => {
      this.importedBook = null;
    })
  }

  // ===== 绑定角色弹窗 =====

  @Builder
  bindCharacterDialog() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.showBindPicker = false;
      })

      Column() {
        Row() {
          Text($r('app.string.lorebook_import_bind_character_title'))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
          Text($r('app.string.dialog_close'))
            .fontSize(14)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .onClick(() => {
              this.showBindPicker = false;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 12 })

        if (this.bindCharacters.length === 0) {
          Text($r('app.string.lorebook_import_no_character'))
            .fontSize(13)
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding(20)
        } else {
          Scroll() {
            Column() {
              ForEach(this.bindCharacters, (ref: CharacterBookRef) => {
                Text(ref.name)
                  .fontSize(14)
                  .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .padding({ left: 12, right: 12, top: 12, bottom: 12 })
                  .margin({ bottom: 6 })
                  .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
                  .borderRadius(8)
                  .onClick(() => {
                    this.bindToCharacter(ref.id, ref.name);
                  })
              }, (ref: CharacterBookRef) => ref.id)
            }
            .width('100%')
          }
          .height('70%')
          .scrollBar(BarState.Auto)
          .align(Alignment.Top)
          .width('100%')
        }

        Button($r('app.string.dialog_cancel'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .height(40)
          .width('100%')
          .margin({ top: 12 })
          .onClick(() => {
            this.showBindPicker = false;
          })
      }
      .width('85%')
      .padding(20)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.4)')
  }

  /** 执行世界书 → 角色绑定。 */
  private async bindToCharacter(refId: string, refName: string): Promise<void> {
    this.showBindPicker = false;
    if (this.viewModel === null || this.bindTargetBookId.length === 0) {
      return;
    }
    try {
      await this.viewModel.bindLorebookToCharacter(this.bindTargetBookId, refId);
      this.bindTargetBookId = '';
      promptAction.showToast({ message: '已绑定到 ' + refName, duration: 2000 });
    } catch (e) {
      promptAction.showToast({ message: '绑定失败: ' + String((e as Error).message ?? e), duration: 2500 });
    }
  }

  /** 当前编辑弹窗对应的世界书 ID(无则空串)。 */
  private getEditingLorebookId(): string {
    if (this.viewModel !== null && this.viewModel.editingLorebook !== null) {
      return this.viewModel.editingLorebook.id;
    }
    return '';
  }

  /** 打开源码编辑器;关闭当前编辑弹窗,避免叠加。 */
  private openSourceEditor(bookId: string): void {
    if (bookId.length === 0) {
      return;
    }
    if (this.viewModel !== null) {
      this.viewModel.closeLorebookDialog();
    }
    this.syncFromViewModel();
    router.pushUrl({
      url: 'pages/LorebookSourceEditorPage',
      params: { param: { lorebookId: bookId } }
    });
  }

  // ===== 删除确认(世界书) =====

  @Builder
  deleteLorebookConfirm() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.deleteTargetLorebook = null;
          this.syncFromViewModel();
        }
      })

      Column() {
      Text('删除世界书')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 12 })

      Text(this.deleteTargetLorebook !== null
        ? '确定删除世界书"' + this.deleteTargetLorebook.name + '"吗?所有条目也将一并删除。'
        : '')
        .fontSize(14)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ bottom: 20 })
        .textAlign(TextAlign.Center)

      Row() {
        Button($r('app.string.lorebook_form_cancel'))
          .fontSize(14)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .margin({ right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetLorebook = null;
              this.syncFromViewModel();
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_danger'))
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            if (this.viewModel !== null && this.deleteTargetLorebook !== null) {
              void this.viewModel.deleteLorebook(this.deleteTargetLorebook.id).then(() => {
                this.syncFromViewModel();
              });
            }
          })
      }
      .width('100%')
    }
    .width('80%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
    .padding(20)
    }
    .width('100%')
    .height('100%')
  }

  // ===== 删除确认(条目) =====

  @Builder
  deleteEntryConfirm() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.4)')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        if (this.viewModel !== null) {
          this.viewModel.deleteTargetEntry = null;
          this.syncFromViewModel();
        }
      })

      Column() {
      Text('删除条目')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 12 })

      Text(this.deleteTargetEntry !== null
        ? '确定删除条目"' + this.deleteTargetEntry.name + '"吗?'
        : '')
        .fontSize(14)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ bottom: 20 })
        .textAlign(TextAlign.Center)

      Row() {
        Button($r('app.string.lorebook_form_cancel'))
          .fontSize(14)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .margin({ right: 8 })
          .onClick(() => {
            if (this.viewModel !== null) {
              this.viewModel.deleteTargetEntry = null;
              this.syncFromViewModel();
            }
          })

        Button($r('app.string.lorebook_delete'))
          .fontSize(14)
          .backgroundColor($r('app.color.app_danger'))
          .borderRadius(20)
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            if (this.viewModel !== null && this.deleteTargetEntry !== null) {
              void this.viewModel.deleteEntry(
                this.deleteTargetEntryLorebookId,
                this.deleteTargetEntry.id
              ).then(() => {
                this.syncFromViewModel();
              });
            }
          })
      }
      .width('100%')
    }
    .width('80%')
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
    .padding(20)
    }
    .width('100%')
    .height('100%')
  }
}