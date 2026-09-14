/**
 * CharacterListPage 角色列表页面
 *
 * 展示角色列表,支持新建/编辑/删除/设为当前角色/导入/导出。
 * 仅通过 CharacterListViewModel 访问业务能力。
 *
 * 要求:
 * - 角色列表(含当前角色标记)
 * - 新建角色
 * - 编辑角色
 * - 删除角色二次确认
 * - 设为当前角色
 * - JSON 导入(含预览)
 * - JSON 导出
 * - 无角色空状态
 * - 本次不做头像上传
 */

import { CharacterListViewModel } from '../viewmodels/CharacterListViewModel';
import { Character } from '../models/Character';
import { sanitizeFileName } from '../parser/CharacterCardJsonWriter';
import { AppServices } from '../services/AppServices';
import { picker } from '@kit.CoreFileKit';
import { promptAction, router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { ThemePalette } from '../theme/ThemePalette';

@Entry
@Component
struct CharacterListPage {
  @State viewModel: CharacterListViewModel | null = null;
  /** 表单字段(使用 @State + $$ 双向绑定,兼容 MCP inputText) */
  @State formName: string = '';
  @State formDescription: string = '';
  @State formPersonality: string = '';
  @State formScenario: string = '';
  @State formFirstMessage: string = '';
  @State formSystemPrompt: string = '';
  /** 搜索关键字(角色卡本地过滤) */
  @State searchQuery: string = '';
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';
  /** 按压中的角色卡 id(按压缩放动效,空串=无) */
  @State pressedCardId: string = '';
  /** 已入场卡片数(列表 stagger 动效) */
  @State appearedCount: number = 1;
  /** 入场 stagger 计时器句柄 */
  private appearTimer: number = -1;

  async aboutToAppear(): Promise<void> {
    const charService = AppServices.getCharacterService();
    const vm: CharacterListViewModel = new CharacterListViewModel(charService);
    this.viewModel = vm;
    await vm.load();
    this.startEntranceAnim();
  }

  aboutToDisappear(): void {
    if (this.appearTimer !== -1) {
      clearInterval(this.appearTimer);
      this.appearTimer = -1;
    }
  }

  /** 列表入场 stagger:每 80ms 逐项显现,直至全部卡片可见 */
  private startEntranceAnim(): void {
    this.appearedCount = 1;
    const total: number = this.filteredCharacters().length;
    if (this.appearTimer !== -1) {
      clearInterval(this.appearTimer);
      this.appearTimer = -1;
    }
    if (total <= 1) {
      this.appearedCount = total;
      return;
    }
    this.appearTimer = setInterval(() => {
      this.appearedCount++;
      if (this.appearedCount >= total) {
        clearInterval(this.appearTimer);
        this.appearTimer = -1;
      }
    }, 80);
  }

  build() {
    Stack() {
      Column() {
        // 顶部标题栏:返回 + 标题 + 导入
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([ThemePalette.textPrimaryColor(this.effectiveTheme)])
            .padding(8)
            .onClick(() => {
              router.back();
            })

          Text($r('app.string.nav_character_list_title'))
            .fontSize($r('app.float.nav_title_font_size'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 8, right: 8 })

          Button($r('app.string.character_import'))
            .fontSize(13)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius(16)
            .height(32)
            .padding({ left: 12, right: 12 })
            .onClick(() => {
              this.openImportPicker();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: this.statusBarHeight + 12, bottom: 4 })
        .alignItems(VerticalAlign.Center)

          // 副标题:角色总数 · 使用中数
          Row() {
            Text((this.viewModel!.characters.length).toString() + ' 位 · ' + this.inUseCount().toString() + ' 位在使用')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 0, bottom: 8 })

          // 搜索框(胶囊)
          Row() {
            TextInput({ placeholder: $r('app.string.character_search_placeholder'), text: $$this.searchQuery })
              .fontSize(14)
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
              .backgroundColor(Color.Transparent)
              .layoutWeight(1)
              .height(36)
              .onChange(() => {
                this.startEntranceAnim();
              })
          }
          .width('100%')
          .height(40)
          .padding({ left: 12, right: 12 })
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(20)
          .margin({ bottom: 8 })

          // 导入错误提示
          if (this.viewModel!.importError.length > 0) {
            Text(this.viewModel!.importError)
              .fontSize(13)
              .fontColor($r('app.color.app_danger'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          }

          // 通用错误提示(含角色被世界引用时的删除保护提示)
          if (this.viewModel!.errorMessage.length > 0) {
            Text(this.viewModel!.errorMessage)
              .fontSize(13)
              .fontColor($r('app.color.app_danger'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          }

          // 角色列表
          Scroll() {
            Column() {
              if (this.filteredCharacters().length === 0) {
                this.characterListEmpty();
              } else {
                ForEach(this.filteredCharacters(), (char: Character, index: number) => {
                  this.characterCard(char, index);
                }, (char: Character) => char.id);
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .height('100%')

        // 新建按钮(FAB)
        Button($r('app.string.character_new'))
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius(24)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .position({ right: 16, bottom: this.navigationBarHeight + 16 })
          .onClick(() => {
            this.viewModel!.showNewDialog();
            this.syncFormFromViewModel();
          })

        // 删除确认对话框
        if (this.viewModel!.deleteTarget !== null) {
          this.deleteConfirmDialog();
        }

        // 编辑对话框
        if (this.viewModel!.showEditDialog) {
          this.editDialogOverlay();
        }

        // 导入预览对话框
        if (this.viewModel!.showImportPreview && this.viewModel!.previewCard !== null) {
          this.importPreviewDialog();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }

  // ===== 空状态 =====

  @Builder
  emptyState() {
    Column() {
      Text($r('app.string.character_no_characters'))
        .fontSize(16)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .margin({ bottom: 8 })

      Text($r('app.string.character_no_characters_desc'))
        .fontSize(13)
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
    }
    .width('100%')
    .height(200)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  characterListEmpty() {
    if (this.searchQuery.trim().length > 0) {
      Column() {
        Text($r('app.string.character_search_no_result'))
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
      }
      .width('100%')
      .height(200)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    } else {
      this.emptyState();
    }
  }

  // ===== 角色卡片 =====

  @Builder
  characterCard(char: Character, index: number) {
    Column() {
      // 顶部:名称 + 状态标记
      Row() {
        // 渐变头像占位(暖色渐变 + 首字母),实图后续可替换
        Column() {
          Text(char.name.charAt(0))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_on_accent'))
            .textAlign(TextAlign.Center)
        }
        .justifyContent(FlexAlign.Center)
        .width(48)
        .height(48)
        .borderRadius(24)
        .linearGradient({
          angle: 135,
          colors: [[ThemePalette.surface2Color(this.effectiveTheme), 0], [ThemePalette.accentColor(this.effectiveTheme), 1]]
        })
        .margin({ right: 12 })

        Column() {
          Text(char.name)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (char.description.length > 0) {
            Text(char.description)
              .fontSize(13)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 4 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 状态标签:使用中=金色实心 / 已停用=金色描边
        if (this.viewModel!.isCurrent(char)) {
          Text($r('app.string.character_status_active'))
            .fontSize(12)
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        } else {
          Text($r('app.string.character_status_inactive'))
            .fontSize(12)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 元信息 chip:上次修改时间
      Row() {
        Text($r('app.string.character_meta_updated'))
          .fontSize($r('app.float.app_font_micro'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        Text(' ' + this.formatMetaDate(char.modificationDate))
          .fontSize($r('app.float.app_font_micro'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
      }
      .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_sm'))
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .margin({ top: 8 })

      // 操作按钮行
      Row() {
        if (!this.viewModel!.isCurrent(char)) {
          Button($r('app.string.character_set_current'))
            .fontSize(12)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .height(32)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              this.viewModel!.setCurrent(char.id);
            })
        }

        Button($r('app.string.character_edit'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .height(32)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.viewModel!.showEditDialogFor(char);
            this.syncFormFromViewModel();
          })

        Button($r('app.string.character_export'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .height(32)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.openExportPicker(char);
          })

        Button($r('app.string.character_delete'))
          .fontSize(12)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.app_danger'))
          .height(32)
          .padding({ left: 8, right: 8 })
          .onClick(() => {
            this.viewModel!.deleteTarget = char;
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 8 })
    }
    .scale({
      x: char.id === this.pressedCardId ? 0.97 : 1,
      y: char.id === this.pressedCardId ? 0.97 : 1
    })
    .opacity(index < this.appearedCount ? 1 : 0)
    .animation({ duration: 200, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedCardId = char.id;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedCardId = '';
      }
    })
    .width('100%')
    .padding({ left: 12, right: 12, top: 12, bottom: 4 })
    .margin({ bottom: 10 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_lg'))
    .shadow(this.cardShadow(char))
    .alignItems(HorizontalAlign.Start)
  }

  /** 卡片阴影:使用中 Tavern 主题换金色辉光,其余用暖色投影 */
  private cardShadow(char: Character): ShadowOptions {
    if (this.viewModel!.isCurrent(char) && this.effectiveTheme === 'tavern') {
      return { radius: 18, color: '#47D4A23B', offsetX: 0, offsetY: 4 };
    }
    return { radius: 18, color: '#99000000', offsetX: 0, offsetY: 6 };
  }

  /** 格式化修改时间为 MM-DD(卡片内省略年份) */
  private formatMetaDate(timestamp: number): string {
    const date: Date = new Date(timestamp);
    const month: number = date.getMonth() + 1;
    const day: number = date.getDate();
    const monthStr: string = month < 10 ? '0' + month.toString() : month.toString();
    const dayStr: string = day < 10 ? '0' + day.toString() : day.toString();
    return monthStr + '-' + dayStr;
  }

  // ===== 编辑对话框(新建/编辑共用) =====

  @Builder
  editDialog() {
    Column() {
      // 标题
      Text(this.viewModel!.editingCharacter === null
        ? $r('app.string.character_form_title_new')
        : $r('app.string.character_form_title_edit'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 16 })

      // 名称
      Column() {
        Text($r('app.string.character_form_name'))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextInput({ placeholder: $r('app.string.character_form_name_placeholder'), text: $$this.formName })
          .fontSize(14)
          .width('100%')
          .height(40)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 描述
      Column() {
        Text($r('app.string.character_form_description'))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_description_placeholder'), text: $$this.formDescription })
          .fontSize(14)
          .maxLines(3)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 性格
      Column() {
        Text($r('app.string.character_form_personality'))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_personality_placeholder'), text: $$this.formPersonality })
          .fontSize(14)
          .maxLines(3)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 场景
      Column() {
        Text($r('app.string.character_form_scenario'))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_scenario_placeholder'), text: $$this.formScenario })
          .fontSize(14)
          .maxLines(3)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 开场白
      Column() {
        Text($r('app.string.character_form_first_message'))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_first_message_placeholder'), text: $$this.formFirstMessage })
          .fontSize(14)
          .maxLines(3)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // System Prompt
      Column() {
        Text($r('app.string.character_form_system_prompt'))
          .fontSize(13)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 4 })
        TextArea({ placeholder: $r('app.string.character_form_system_prompt_placeholder'), text: $$this.formSystemPrompt })
          .fontSize(14)
          .maxLines(4)
          .width('100%')
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }
      .width('100%')
      .margin({ bottom: 12 })
      .alignItems(HorizontalAlign.Start)

      // 错误提示
      if (this.viewModel!.errorMessage.length > 0) {
        Text(this.viewModel!.errorMessage)
          .fontSize(13)
          .fontColor($r('app.color.app_danger'))
          .width('100%')
          .margin({ top: 8, bottom: 8 })
      }

      // 按钮行
      Row() {
        Button($r('app.string.character_form_cancel'))
          .fontSize(14)
          .backgroundColor(Color.Transparent)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .height(40)
          .layoutWeight(1)
          .onClick(() => {
            this.viewModel!.closeEditDialog();
          })

        Button($r('app.string.character_form_save'))
          .fontSize(14)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .fontColor($r('app.color.app_on_accent'))
          .borderRadius(20)
          .height(40)
          .layoutWeight(1)
          .margin({ left: 12 })
          .onClick(() => {
            this.saveFormToViewModel();
            this.viewModel!.saveEdit();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(20)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  /** 已使用(设为当前)角色数 */
  private inUseCount(): number {
    let count: number = 0;
    for (const char of this.viewModel!.characters) {
      if (this.viewModel!.isCurrent(char)) {
        count++;
      }
    }
    return count;
  }

  /** 按搜索关键字本地过滤角色列表(空串返回全量) */
  private filteredCharacters(): Character[] {
    const query: string = this.searchQuery.trim().toLowerCase();
    if (query.length === 0) {
      return this.viewModel!.characters;
    }
    return this.viewModel!.characters.filter((char: Character): boolean => {
      return char.name.toLowerCase().includes(query) ||
        char.description.toLowerCase().includes(query);
    });
  }

  /** 将 @State 表单字段同步到 ViewModel */
  private saveFormToViewModel(): void {
    this.viewModel!.editName = this.formName;
    this.viewModel!.editDescription = this.formDescription;
    this.viewModel!.editPersonality = this.formPersonality;
    this.viewModel!.editScenario = this.formScenario;
    this.viewModel!.editFirstMessage = this.formFirstMessage;
    this.viewModel!.editSystemPrompt = this.formSystemPrompt;
  }

  /** 从 ViewModel 同步表单字段到 @State */
  private syncFormFromViewModel(): void {
    this.formName = this.viewModel!.editName;
    this.formDescription = this.viewModel!.editDescription;
    this.formPersonality = this.viewModel!.editPersonality;
    this.formScenario = this.viewModel!.editScenario;
    this.formFirstMessage = this.viewModel!.editFirstMessage;
    this.formSystemPrompt = this.viewModel!.editSystemPrompt;
  }

  // ===== 删除确认对话框 =====

  @Builder
  deleteConfirmDialog() {
    Column() {
      Column() {
        Text('确认删除')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ bottom: 12 })

        Text('确定删除角色"' + this.viewModel!.deleteTarget!.name + '"吗?此操作不可撤销。')
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .margin({ bottom: 20 })

        Row() {
          Button('取消')
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              this.viewModel!.deleteTarget = null;
            })

          Button('删除')
            .fontSize(14)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor(Color.White)
            .borderRadius(20)
            .layoutWeight(1)
            .height(40)
            .margin({ left: 12 })
            .onClick(() => {
              const id: string = this.viewModel!.deleteTarget!.id;
              this.viewModel!.deleteTarget = null;
              this.viewModel!.deleteCharacter(id);
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(20)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.viewModel!.deleteTarget = null;
    })
  }

  // ===== 编辑对话框(半屏覆盖) =====

  @Builder
  editDialogOverlay() {
    Column() {
      Blank()
        .backgroundColor('rgba(0,0,0,0.3)')
        .onClick(() => {
          this.viewModel!.closeEditDialog();
        })

      this.editDialog();
    }
    .width('100%')
    .height('100%')
  }

  // ===== 导入预览对话框 =====

  @Builder
  importPreviewDialog() {
    Column() {
      Column() {
        Text($r('app.string.character_import_preview'))
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 16 })

        // PNG 头像预览
        if (this.viewModel!.isPngImport && this.viewModel!.previewPngUri.length > 0) {
          Image(this.viewModel!.previewPngUri)
            .width(80)
            .height(80)
            .borderRadius(12)
            .objectFit(ImageFit.Cover)
            .margin({ bottom: 12 })
        }

        this.importPreviewField('名称', this.viewModel!.previewCard!.name, true);
        this.importPreviewField('描述', this.viewModel!.previewCard!.description, false);
        this.importPreviewField('性格', this.viewModel!.previewCard!.personality, false);
        this.importPreviewField('场景', this.viewModel!.previewCard!.scenario, false);
        this.importPreviewField('开场白', this.viewModel!.previewCard!.firstMessage, false);
        this.importPreviewField('System Prompt', this.viewModel!.previewCard!.systemPrompt, false);

        // 来源格式
        Text('来源格式: ' + this.formatSourceLabel(this.viewModel!.previewCard!.sourceFormat))
          .fontSize(12)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 8, bottom: 16 })

        if (this.viewModel!.importError.length > 0) {
          Text(this.viewModel!.importError)
            .fontSize(13)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .margin({ bottom: 12 })
        }

        Row() {
          Button($r('app.string.character_import_cancel'))
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.viewModel!.cancelImport();
            })

          Button($r('app.string.character_import_confirm'))
            .fontSize(14)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .borderRadius(20)
            .height(40)
            .layoutWeight(1)
            .margin({ left: 12 })
            .onClick(() => {
              this.viewModel!.confirmImport();
            })
        }
        .width('100%')
      }
      .width('85%')
      .padding(20)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius(16)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('rgba(0,0,0,0.5)')
    .onClick(() => {
      this.viewModel!.cancelImport();
    })
  }

  @Builder
  importPreviewField(label: string, value: string, isRequired: boolean) {
    if (value.length > 0 || isRequired) {
      Column() {
        Row() {
          Text(label)
            .fontSize(12)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .fontWeight(FontWeight.Medium)
          if (isRequired) {
            Text(' *')
              .fontSize(12)
              .fontColor($r('app.color.app_danger'))
          }
        }
        .width('100%')

        Text(value.length > 0 ? value : '(空)')
          .fontSize(13)
          .fontColor(value.length > 0
            ? ThemePalette.textPrimaryColor(this.effectiveTheme)
            : ThemePalette.textSecondaryColor(this.effectiveTheme))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2, bottom: 8 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  // ===== 文件选择器 =====

  private async openImportPicker(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      await this.viewModel!.startImportFile(uris[0]);
      if (this.viewModel!.importError.length > 0) {
        promptAction.showToast({
          message: this.viewModel!.importError,
          duration: 2000
        });
      }
    } catch (e) {
      // 用户取消选择,静默处理
    }
  }

  private async openExportPicker(char: Character): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [sanitizeFileName(char.name)];
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      await this.viewModel!.exportToFile(char.id, uris[0]);
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
  }

  private formatSourceLabel(sourceFormat: string): string {
    if (sourceFormat === 'arktavern_v1') {
      return 'ArkTavern v1';
    }
    if (sourceFormat === 'chara_card_v2') {
      return 'Character Card V2';
    }
    if (sourceFormat === 'chara_card_v3') {
      return 'Character Card V3';
    }
    return sourceFormat;
  }
}