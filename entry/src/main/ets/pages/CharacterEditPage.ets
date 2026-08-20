/**
 * CharacterEditPage 全屏角色编辑页(UI-3B-2)
 *
 * 顶部:返回 + 分段切换(角色/对话) + 保存
 * 角色分段:图片 → 名称 → 描述 → 性格 → 标签 → 创作者 → 角色卡版本 → 创作者备注
 * 对话分段:场景 → 开场白 → 备用开场白 → 对话示例 → System Prompt → Post-History Instructions → 角色专属世界书
 *
 * 字段策略:
 * - tags / creator / character_version / creator_notes 只作元数据,不进入 PromptBuilder
 * - alternate_greetings 作为开场白的额外 Swipe 候选(可增删、可排序)
 * - mes_example 进入 PromptBuilder 作为对话示例
 * - system_prompt 空时使用默认组合,非空时支持 {{original}}
 * - post_history_instructions 放在聊天历史之后
 * - character_book 复用 Lorebook 编辑能力(只读展示关联 ID)
 *
 * 路由参数:{ characterId: string } 编辑模式;undefined 新建模式。
 */

import { CharacterEditViewModel, CharacterEditFormState, emptyFormState, copyFormState, parseCharacterEditRouteParam } from '../viewmodels/CharacterEditViewModel';
import { AppServices } from '../services/AppServices';
import { CharacterImageView } from '../components/CharacterImageView';
import { promptAction, router } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { ThemePalette } from '../theme/ThemePalette';

const TAB_CHARACTER: number = 0;
const TAB_CONVERSATION: number = 1;

@Entry
@Component
struct CharacterEditPage {
  @State formState: CharacterEditFormState = emptyFormState();
  @State isLoading: boolean = true;
  @State isSaving: boolean = false;
  @State errorMessage: string = '';
  @State activeTab: number = TAB_CHARACTER;
  @State showDiscardDialog: boolean = false;
  /** 标签输入框当前内容(独立于 formState,只在添加时回写到 formState) */
  @State tagInputDraft: string = '';
  /** 备用开场白编辑态:正在编辑的索引(空表示未进入编辑) */
  @State editingGreetingIndex: number = -1;
  /** 备用开场白编辑态:正在编辑的内容草稿 */
  @State editingGreetingDraft: string = '';
  /** 顶部状态栏避让高度(由 EntryAbility 写入 AppStorage) */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  private viewModel: CharacterEditViewModel = new CharacterEditViewModel(
    AppServices.getCharacterService()
  );
  private readyHandled: boolean = false;

  aboutToDisappear(): void {
    this.viewModel.dispose();
  }

  aboutToAppear(): void {
    this.handleReady();
  }

  onBackPress(): boolean {
    if (this.showDiscardDialog) {
      this.showDiscardDialog = false;
      return true;
    }
    if (this.isDirty()) {
      this.showDiscardDialog = true;
      return true;
    }
    return false;
  }

  build() {
    Column() {
        this.topBar()

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_16'),
              right: $r('app.float.app_spacing_16'),
              top: $r('app.float.app_spacing_4'),
              bottom: $r('app.float.app_spacing_4')
            })
        }

        if (this.isLoading) {
          this.loadingView()
        } else {
          this.contentArea()
        }

        if (this.showDiscardDialog) {
          this.discardDialog()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private handleReady(): void {
    if (this.readyHandled) {
      return;
    }
    this.readyHandled = true;

    try {
      const params = router.getParams() as Record<string, Object>;
      const param = params?.['param'];
      this.handleDestinationReady(param);
    } catch (e) {
      this.errorMessage = '页面参数错误';
      this.isLoading = false;
    }
  }

  private async handleDestinationReady(param: Object | undefined): Promise<void> {
    const parsed = parseCharacterEditRouteParam(param);

    if (parsed.error !== undefined) {
      this.errorMessage = parsed.error;
      this.isLoading = false;
      return;
    }

    try {
      await this.viewModel.initialize(parsed.characterId);
      this.formState = this.viewModel.getFormState();
      this.isLoading = false;
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '加载失败';
      this.isLoading = false;
    }
  }

  // ===== 顶部固定栏 =====
  @Builder
  topBar() {
    Row() {
      Button($r('app.string.character_edit_back'))
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .height(40)
        .padding({ left: 8, right: 8 })
        .onClick(() => {
          this.handleBack();
        })

      Blank()
      this.segmentedControl()
      Blank()

      Button($r('app.string.character_edit_save'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(FontWeight.Medium)
        .backgroundColor(this.canSave() ? ThemePalette.accentColor(this.effectiveTheme) : ThemePalette.surface2Color(this.effectiveTheme))
        .fontColor(this.canSave() ? $r('app.color.app_on_accent') : ThemePalette.textTertiaryColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(36)
        .padding({ left: 16, right: 16 })
        .enabled(this.canSave())
        .onClick(() => {
          this.handleSave();
        })
    }
    .width('100%')
    .padding({ left: 8, right: 12, top: this.statusBarHeight + 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }

  @Builder
  segmentedControl() {
    Row() {
      Text($r('app.string.character_edit_tab_character'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(this.activeTab === TAB_CHARACTER ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === TAB_CHARACTER ? $r('app.color.app_on_accent') : ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(this.activeTab === TAB_CHARACTER ? ThemePalette.accentColor(this.effectiveTheme) : Color.Transparent)
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32).padding({ left: 16, right: 16 }).textAlign(TextAlign.Center)
        .onClick(() => { this.activeTab = TAB_CHARACTER; })
      Text($r('app.string.character_edit_tab_conversation'))
        .fontSize($r('app.float.app_font_body'))
        .fontWeight(this.activeTab === TAB_CONVERSATION ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.activeTab === TAB_CONVERSATION ? $r('app.color.app_on_accent') : ThemePalette.textSecondaryColor(this.effectiveTheme))
        .backgroundColor(this.activeTab === TAB_CONVERSATION ? ThemePalette.accentColor(this.effectiveTheme) : Color.Transparent)
        .borderRadius($r('app.float.app_radius_sm'))
        .height(32).padding({ left: 16, right: 16 }).margin({ left: 4 }).textAlign(TextAlign.Center)
        .onClick(() => { this.activeTab = TAB_CONVERSATION; })
    }
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .padding({ left: 4, right: 4, top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  // ===== 主内容区 =====
  @Builder
  contentArea() {
    if (this.activeTab === TAB_CHARACTER) {
      this.characterTab()
    } else {
      this.conversationTab()
    }
  }

  // ===== "角色"分段 =====
  // 顺序:图片 → 名称 → 描述 → 性格 → 标签 → 创作者 → 角色卡版本 → 创作者备注
  @Builder
  characterTab() {
    Scroll() {
      Column() {
        this.imageSection()

        this.textFieldRow(
          $r('app.string.character_edit_field_name'),
          $r('app.string.character_edit_field_name_placeholder'),
          true,
          this.formState.nameInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.nameInput = value;
            this.formState = updated;
          }
        )

        this.textFieldRow(
          $r('app.string.character_edit_field_user_name'),
          $r('app.string.character_edit_field_user_name_placeholder'),
          false,
          this.formState.userNameInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.userNameInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_description'),
          $r('app.string.character_edit_field_description_placeholder'),
          $r('app.string.character_edit_field_description_hint'),
          this.formState.descriptionInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.descriptionInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_personality'),
          $r('app.string.character_edit_field_personality_placeholder'),
          undefined,
          this.formState.personalityInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.personalityInput = value;
            this.formState = updated;
          }
        )

        this.tagsSection()

        this.textFieldRow(
          $r('app.string.character_edit_field_creator'),
          $r('app.string.character_edit_field_creator_placeholder'),
          false,
          this.formState.creatorInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.creatorInput = value;
            this.formState = updated;
          }
        )

        this.textFieldRow(
          $r('app.string.character_edit_field_character_version'),
          $r('app.string.character_edit_field_character_version_placeholder'),
          false,
          this.formState.characterVersionInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.characterVersionInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_creator_notes'),
          $r('app.string.character_edit_field_creator_notes_placeholder'),
          undefined,
          this.formState.creatorNotesInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.creatorNotesInput = value;
            this.formState = updated;
          }
        )
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20'),
        top: $r('app.float.app_spacing_16'),
        bottom: 100
      })
    }
    .layoutWeight(1)
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .width('100%')
  }

  /** 角色图片区域 */
  @Builder
  imageSection() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.formState.avatarUriInput.length > 0) {
        CharacterImageView({
          imageUri: this.formState.avatarUriInput,
          fallbackName: this.formState.nameInput,
          imgWidth: 160,
          imgHeight: 220,
          imgBorderRadius: $r('app.float.app_radius_lg'),
          displayMode: 'portrait',
          objectFit: ImageFit.Cover
        })
      } else {
        Column() {
          Text($r('app.string.character_edit_image_placeholder'))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .textAlign(TextAlign.Center)
        }
        .width(160)
        .height(220)
        .borderRadius($r('app.float.app_radius_lg'))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      Button() {
        Text('✎')
          .fontSize(18)
          .fontColor($r('app.color.app_on_accent'))
      }
      .width(36)
      .height(36)
      .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
      .borderRadius(18)
      .margin({ right: 8, bottom: 8 })
      .enabled(!this.isSaving && !this.isLoading && this.viewModel.isEditing)
      .onClick(() => {
        this.openAvatarPicker();
      })
    }
    .width(160)
    .height(220)
    .margin({ top: 8, bottom: 24 })
    .alignSelf(ItemAlign.Center)
  }

  /** 标签编辑区域:输入 + 添加按钮 + 标签列表(可删除) */
  @Builder
  tagsSection() {
    Column() {
      Row() {
        Text($r('app.string.character_edit_field_tags'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      Row() {
        TextInput({ placeholder: $r('app.string.character_edit_field_tags_placeholder'), text: this.tagInputDraft })
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.tagInputDraft = value;
          })

        Button($r('app.string.character_edit_tag_add'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .margin({ left: 8 })
          .padding({ left: 12, right: 12 })
          .enabled(this.tagInputDraft.trim().length > 0)
          .onClick(() => {
            this.addTagFromDraft();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.character_edit_field_tags_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ top: 6 })
        .textAlign(TextAlign.Start)

      if (this.formState.tagsInput.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.formState.tagsInput, (tag: string, index: number) => {
            Row() {
              Text(tag)
                .fontSize($r('app.float.app_font_caption'))
                .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ right: 6 })

              Text('×')
                .fontSize(16)
                .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
                .onClick(() => {
                  this.removeTagAtIndex(index);
                })
            }
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .margin({ right: 8, top: 6 })
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .alignItems(VerticalAlign.Center)
          }, (tag: string, index: number) => tag + '|' + String(index))
        }
        .width('100%')
        .margin({ top: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 24 })
  }

  /** 备用开场白编辑区域:可增删、可排序的列表 */
  @Builder
  alternateGreetingsSection() {
    Column() {
      Row() {
        Text($r('app.string.character_edit_alternate_greetings'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      Text($r('app.string.character_edit_alternate_greetings_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ bottom: 8 })
        .textAlign(TextAlign.Start)

      if (this.formState.alternateGreetingsInput.length === 0) {
        Text($r('app.string.character_edit_alternate_greetings_empty'))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .textAlign(TextAlign.Center)
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_md'))
      } else {
        ForEach(this.formState.alternateGreetingsInput, (greeting: string, index: number) => {
          this.greetingItemCard(greeting, index)
        }, (greeting: string, index: number) => String(index) + '|' + greeting.length.toString())
      }

      Button($r('app.string.character_edit_alternate_greetings_add'))
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .backgroundColor(Color.Transparent)
        .borderWidth(1)
        .borderColor(ThemePalette.accentColor(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(40)
        .width('100%')
        .margin({ top: 8 })
        .onClick(() => {
          this.startAddGreeting();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 24 })
  }

  /** 单条备用开场白卡片:内容预览 + 排序按钮 + 编辑/删除按钮 */
  @Builder
  greetingItemCard(greeting: string, index: number) {
    Column() {
      // 内容预览或编辑框
      if (this.editingGreetingIndex === index) {
        TextArea({ placeholder: $r('app.string.character_edit_alternate_greetings_placeholder'), text: this.editingGreetingDraft })
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(100)
          .barState(BarState.Auto)
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .onChange((value: string) => {
            this.editingGreetingDraft = value;
          })

        Row() {
          Button('取消')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .layoutWeight(1)
            .onClick(() => {
              this.cancelEditGreeting();
            })

          Button('保存')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_on_accent'))
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .layoutWeight(1)
            .margin({ left: 8 })
            .enabled(this.editingGreetingDraft.trim().length > 0)
            .onClick(() => {
              this.confirmEditGreeting(index);
            })
        }
        .width('100%')
        .margin({ top: 8 })
      } else {
        Text(greeting)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .onClick(() => {
            this.startEditGreeting(index);
          })
      }

      // 操作按钮行(只在非编辑态显示)
      if (this.editingGreetingIndex !== index) {
        Row() {
          Text('#' + String(index + 1))
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
            .layoutWeight(1)

          Button() {
            Text('↑')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          }
          .width(32)
          .height(32)
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.app_radius_sm'))
          .enabled(index > 0)
          .onClick(() => {
            this.moveGreeting(index, index - 1);
          })

          Button() {
            Text('↓')
              .fontSize(14)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          }
          .width(32)
          .height(32)
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.app_radius_sm'))
          .margin({ left: 4 })
          .enabled(index < this.formState.alternateGreetingsInput.length - 1)
          .onClick(() => {
            this.moveGreeting(index, index + 1);
          })

          Button('编辑')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .margin({ left: 4 })
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.startEditGreeting(index);
            })

          Button('删除')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .height(32)
            .margin({ left: 4 })
            .padding({ left: 10, right: 10 })
            .onClick(() => {
              this.removeGreeting(index);
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 8 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
    .borderRadius($r('app.float.app_radius_md'))
    .margin({ top: 8 })
  }

  /** 角色专属世界书区域:只读展示关联 ID */
  @Builder
  characterBookSection() {
    Column() {
      Row() {
        Text($r('app.string.character_edit_character_book'))
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      if (this.formState.characterBookIdInput.length > 0) {
        Text(this.formState.characterBookIdInput)
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_md'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else {
        Text($r('app.string.character_edit_character_book_empty'))
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({ left: 12, right: 12, top: 12, bottom: 12 })
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_md'))
          .textAlign(TextAlign.Center)
      }

      Text($r('app.string.character_edit_character_book_hint'))
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .margin({ top: 6 })
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 24 })
  }

  // ===== "对话"分段 =====
  // 顺序:场景 → 开场白 → 备用开场白 → 对话示例 → System Prompt → Post-History Instructions → 角色专属世界书
  @Builder
  conversationTab() {
    Scroll() {
      Column() {
        this.multilineField(
          $r('app.string.character_edit_field_scenario'),
          $r('app.string.character_edit_field_scenario_placeholder'),
          $r('app.string.character_edit_field_scenario_hint'),
          this.formState.scenarioInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.scenarioInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_first_message'),
          $r('app.string.character_edit_field_first_message_placeholder'),
          $r('app.string.character_edit_field_first_message_hint'),
          this.formState.firstMessageInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.firstMessageInput = value;
            this.formState = updated;
          }
        )

        this.alternateGreetingsSection()

        this.multilineField(
          $r('app.string.character_edit_field_mes_example'),
          $r('app.string.character_edit_field_mes_example_placeholder'),
          $r('app.string.character_edit_field_mes_example_hint'),
          this.formState.mesExampleInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.mesExampleInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_system_prompt'),
          $r('app.string.character_edit_field_system_prompt_placeholder'),
          $r('app.string.character_edit_field_system_prompt_hint'),
          this.formState.systemPromptInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.systemPromptInput = value;
            this.formState = updated;
          }
        )

        this.multilineField(
          $r('app.string.character_edit_field_post_history'),
          $r('app.string.character_edit_field_post_history_placeholder'),
          $r('app.string.character_edit_field_post_history_hint'),
          this.formState.postHistoryInstructionsInput,
          (value: string) => {
            const updated = copyFormState(this.formState);
            updated.postHistoryInstructionsInput = value;
            this.formState = updated;
          }
        )

        this.characterBookSection()
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20'),
        top: $r('app.float.app_spacing_16'),
        bottom: 100
      })
    }
    .layoutWeight(1)
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .width('100%')
  }

  // ===== 字段组件 =====
  /** 单行文本字段 */
  @Builder
  textFieldRow(
    labelResource: Resource,
    placeholderResource: Resource,
    required: boolean,
    value: string,
    onChange: (value: string) => void
  ) {
    Column() {
      Row() {
        Text(labelResource)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        if (required) {
          Text($r('app.string.character_edit_field_required_hint'))
            .fontSize($r('app.float.app_font_subtitle'))
            .fontColor($r('app.color.app_danger'))
            .margin({ left: 4 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      TextInput({ placeholder: placeholderResource, text: value })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(48)
        .padding({ left: 16, right: 16 })
        .onChange(onChange)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 24 })
  }

  /** 多行文本字段 */
  @Builder
  multilineField(
    labelResource: Resource,
    placeholderResource: Resource,
    hintResource: Resource | undefined,
    value: string,
    onChange: (value: string) => void
  ) {
    Column() {
      Row() {
        Text(labelResource)
          .fontSize($r('app.float.app_font_subtitle'))
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      TextArea({ placeholder: placeholderResource, text: value })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_md'))
        .height(120)
        .barState(BarState.Auto)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .onChange(onChange)

      if (hintResource !== undefined) {
        Text(hintResource)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ top: 6 })
          .textAlign(TextAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 24 })
  }

  // ===== 加载视图 =====
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

  // ===== 放弃修改确认弹窗 =====
  @Builder
  discardDialog() {
    Stack() {
      Column() {
        Column() {
          Text($r('app.string.character_edit_unsaved_title'))
            .fontSize(17).fontWeight(FontWeight.Medium).fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .margin({ bottom: 12 })
          Text($r('app.string.character_edit_unsaved_message'))
            .fontSize(14).fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ bottom: 20 })
          Row() {
            Button($r('app.string.character_edit_unsaved_stay'))
              .fontSize(14).backgroundColor(Color.Transparent)
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
              .layoutWeight(1).height(40)
              .onClick(() => { this.showDiscardDialog = false; })
            Button($r('app.string.character_edit_unsaved_discard'))
              .fontSize(14).backgroundColor($r('app.color.app_danger'))
              .fontColor(Color.White).borderRadius(20)
              .layoutWeight(1).height(40).margin({ left: 12 })
              .onClick(() => { this.showDiscardDialog = false; this.popBack(); })
          }.width('100%')
        }
        .width('80%').padding(20).backgroundColor(ThemePalette.surface1Color(this.effectiveTheme)).borderRadius(16)
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    }
    .width('100%').height('100%').backgroundColor('rgba(0,0,0,0.5)')
  }

  // ===== 标签操作 =====
  private addTagFromDraft(): void {
    const trimmed: string = this.tagInputDraft.trim();
    if (trimmed.length === 0) {
      return;
    }
    // 检查重复(大小写不敏感)
    const lower: string = trimmed.toLowerCase();
    for (let i = 0; i < this.formState.tagsInput.length; i++) {
      if (this.formState.tagsInput[i].toLowerCase() === lower) {
        this.tagInputDraft = '';
        return;
      }
    }
    const updated = copyFormState(this.formState);
    updated.tagsInput = updated.tagsInput.concat([trimmed]);
    this.formState = updated;
    this.tagInputDraft = '';
  }

  private removeTagAtIndex(index: number): void {
    if (index < 0 || index >= this.formState.tagsInput.length) {
      return;
    }
    const updated = copyFormState(this.formState);
    const next: string[] = [];
    for (let i = 0; i < updated.tagsInput.length; i++) {
      if (i !== index) {
        next.push(updated.tagsInput[i]);
      }
    }
    updated.tagsInput = next;
    this.formState = updated;
  }

  // ===== 备用开场白操作 =====
  private startAddGreeting(): void {
    // 用 -1 表示"新建"模式,进入编辑态
    this.editingGreetingIndex = -1;
    this.editingGreetingDraft = '';
  }

  private startEditGreeting(index: number): void {
    if (index < 0 || index >= this.formState.alternateGreetingsInput.length) {
      return;
    }
    this.editingGreetingIndex = index;
    this.editingGreetingDraft = this.formState.alternateGreetingsInput[index];
  }

  private cancelEditGreeting(): void {
    this.editingGreetingIndex = -1;
    this.editingGreetingDraft = '';
  }

  private confirmEditGreeting(index: number): void {
    const trimmed: string = this.editingGreetingDraft.trim();
    if (trimmed.length === 0) {
      return;
    }
    const updated = copyFormState(this.formState);
    if (index === -1) {
      // 新增
      updated.alternateGreetingsInput = updated.alternateGreetingsInput.concat([trimmed]);
    } else {
      // 编辑现有
      const next: string[] = [];
      for (let i = 0; i < updated.alternateGreetingsInput.length; i++) {
        if (i === index) {
          next.push(trimmed);
        } else {
          next.push(updated.alternateGreetingsInput[i]);
        }
      }
      updated.alternateGreetingsInput = next;
    }
    this.formState = updated;
    this.editingGreetingIndex = -1;
    this.editingGreetingDraft = '';
  }

  private removeGreeting(index: number): void {
    if (index < 0 || index >= this.formState.alternateGreetingsInput.length) {
      return;
    }
    const updated = copyFormState(this.formState);
    const next: string[] = [];
    for (let i = 0; i < updated.alternateGreetingsInput.length; i++) {
      if (i !== index) {
        next.push(updated.alternateGreetingsInput[i]);
      }
    }
    updated.alternateGreetingsInput = next;
    this.formState = updated;
    if (this.editingGreetingIndex === index) {
      this.editingGreetingIndex = -1;
      this.editingGreetingDraft = '';
    }
  }

  private moveGreeting(from: number, to: number): void {
    if (from === to) {
      return;
    }
    if (from < 0 || from >= this.formState.alternateGreetingsInput.length) {
      return;
    }
    if (to < 0 || to >= this.formState.alternateGreetingsInput.length) {
      return;
    }
    const updated = copyFormState(this.formState);
    const next: string[] = updated.alternateGreetingsInput.slice();
    const tmp: string = next[from];
    next[from] = next[to];
    next[to] = tmp;
    updated.alternateGreetingsInput = next;
    this.formState = updated;
  }

  // ===== 业务逻辑 =====
  private isDirty(): boolean {
    if (this.isLoading || this.isSaving) {
      return false;
    }
    return this.viewModel.isDirty(this.formState);
  }

  private canSave(): boolean {
    if (this.isSaving || this.isLoading) {
      return false;
    }
    return this.formState.nameInput.trim().length > 0;
  }

  /**
   * 打开系统文件选择器选择头像图片。
   * - 支持 PNG / JPG / JPEG / WebP / BMP / GIF,单选
   * - 取消返回空数组,不修改任何内容
   * - 选中后调 viewModel.changeAvatar 即时落库(CharacterAssetStore 保留源扩展名)
   * - 失败时旧头像仍可用,显示 errorMessage
   * - 新建模式下按钮已禁用,这里再防御性校验
   */
  private async openAvatarPicker(): Promise<void> {
    if (!this.viewModel.isEditing) {
      promptAction.showToast({
        message: $r('app.string.character_edit_image_edit_hint'),
        duration: 2000
      });
      return;
    }
    if (this.isSaving || this.isLoading) {
      return;
    }
    let uris: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'];
      uris = await documentPicker.select(options);
    } catch (e) {
      // picker 调用本身失败(权限/系统错误),不修改任何内容
      this.errorMessage = '打开文件选择器失败: ' + (e as Error).message;
      return;
    }
    // 用户取消选择,不修改任何内容
    if (uris.length === 0) {
      return;
    }
    this.isSaving = true;
    try {
      await this.viewModel.changeAvatar(uris[0]);
      // 刷新表单头像 URI(originalCharacter 已更新,getFormState 返回新 avatarUri)
      this.formState = this.viewModel.getFormState();
      this.errorMessage = '';
      // 通知首页刷新(CharacterRootView 作为 TabContent 不会触发 onPageShow)
      this.bumpListVersion();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '头像更新失败';
    } finally {
      this.isSaving = false;
    }
  }

  /** 递增 characterListVersion,通知首页 CharacterRootView 重新 load() */
  private bumpListVersion(): void {
    const v: number = AppStorage.get<number>('characterListVersion') ?? 0;
    AppStorage.setOrCreate<number>('characterListVersion', v + 1);
  }

  private handleBack(): void {
    if (this.isDirty()) {
      this.showDiscardDialog = true;
      return;
    }
    this.popBack();
  }

  private async handleSave(): Promise<void> {
    if (!this.canSave() || this.isSaving) {
      return;
    }
    // 如果正在编辑备用开场白,先取消(草稿不保存)
    if (this.editingGreetingIndex !== -1) {
      this.cancelEditGreeting();
    }
    this.isSaving = true;
    try {
      await this.viewModel.save(this.formState);
      this.bumpListVersion();
      this.popBack();
    } catch (e) {
      this.errorMessage = (e as Error).message ?? '保存失败';
    } finally {
      this.isSaving = false;
    }
  }

  private popBack(): void {
    router.back();
  }
}
