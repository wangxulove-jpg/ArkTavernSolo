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
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    const charService = AppServices.getCharacterService();
    const vm: CharacterListViewModel = new CharacterListViewModel(charService);
    this.viewModel = vm;
    await vm.load();
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
            .fontColor(Color.White)
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

          // 导入错误提示
          if (this.viewModel!.importError.length > 0) {
            Text(this.viewModel!.importError)
              .fontSize(13)
              .fontColor('#E74C3C')
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          }

          // 通用错误提示(含角色被世界引用时的删除保护提示)
          if (this.viewModel!.errorMessage.length > 0) {
            Text(this.viewModel!.errorMessage)
              .fontSize(13)
              .fontColor('#E74C3C')
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          }

          // 角色列表
          Scroll() {
            Column() {
              if (this.viewModel!.characters.length === 0) {
                this.emptyState();
              } else {
                ForEach(this.viewModel!.characters, (char: Character) => {
                  this.characterCard(char);
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
          .fontColor(Color.White)
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

  // ===== 角色卡片 =====

  @Builder
  characterCard(char: Character) {
    Column() {
      // 顶部:名称 + 当前标记
      Row() {
        // 文字头像(取名称首字)
        Text(char.name.charAt(0))
          .fontSize(18)
          .fontColor(Color.White)
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius(20)
          .width(40)
          .height(40)
          .textAlign(TextAlign.Center)
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

        if (this.viewModel!.isCurrent(char)) {
          Text($r('app.string.character_current_badge'))
            .fontSize(12)
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme) })
            .borderRadius(8)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

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
          .fontColor('#E74C3C')
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
    .width('100%')
    .padding(12)
    .margin({ bottom: 8 })
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
    .borderRadius(12)
    .alignItems(HorizontalAlign.Start)
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
          .fontColor('#E74C3C')
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
          .fontColor(Color.White)
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
            .backgroundColor('#E74C3C')
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
            .fontColor('#E74C3C')
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
            .fontColor(Color.White)
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
              .fontColor('#E74C3C')
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