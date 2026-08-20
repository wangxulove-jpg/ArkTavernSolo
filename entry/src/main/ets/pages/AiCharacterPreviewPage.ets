/**
 * AiCharacterPreviewPage AI 制作角色卡预览编辑页
 *
 * 接收 AiCharacterMakerPage 通过 AppStorage 传递的 ParsedCharacterCard,
 * 提供预览、编辑、保存、单字段重新生成、导出能力。
 *
 * 流程:
 * 生成完成 → 加载 AppStorage 中的卡片 → 显示可编辑表单 → 保存/重生/导出
 *
 * 职责:
 * 1. 加载 PENDING_AI_CARD_KEY 中的卡片数据
 * 2. 显示全部字段(可编辑)
 * 3. 单字段重新生成(显示进度,完成后更新字段)
 * 4. 保存为本地角色(复用 CharacterService.importFromParsed)
 * 5. 导出 JSON / PNG(复用 CharacterService 的导出能力)
 * 6. 放弃:返回上一页,清理 AppStorage 槽位
 *
 * 不直接:
 * - 调用 network/(通过 ViewModel)
 * - 操作 RDB(通过 CharacterService)
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { AppServices } from '../services/AppServices';
import { AppPreferences } from '../storage/AppPreferences';
import { CharacterService } from '../services/CharacterService';
import { ModelService } from '../services/ModelService';
import {
  AiCharacterGenerationService
} from '../services/ai/AiCharacterGenerationService';
import {
  AiCharacterPreviewViewModel,
  FieldRegenState,
  FieldRegenResult
} from '../viewmodels/AiCharacterPreviewViewModel';
import { Logger } from '../utils/Logger';
import { ThemePalette } from '../theme/ThemePalette';

const LOG_TAG: string = 'AiCharPreviewPage';

@Entry
@Component
struct AiCharacterPreviewPage {
  @State viewModel: AiCharacterPreviewViewModel | null = null;
  @State isInitializing: boolean = true;
  /** 是否展开原始 JSON */
  @State showRawJson: boolean = false;
  /** 是否显示"重新生成整张卡"覆盖确认对话框 */
  @State showRegenerateConfirm: boolean = false;
  /** 是否显示"同名角色已存在"确认对话框 */
  @State showDuplicateNameConfirm: boolean = false;
  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏/手势条避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;
  /** 当前有效主题 */
  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  async aboutToAppear(): Promise<void> {
    try {
      await AppServices.whenReady();
      const appServices: AppServices = AppServices.getInstance();
      const characterService: CharacterService = appServices.characterService;
      const modelService: ModelService = appServices.modelService;
      const ctx: common.Context = getContext(this) as common.Context;
      const prefs: AppPreferences = new AppPreferences();
      await prefs.initialize(ctx);
      const generationService: AiCharacterGenerationService = new AiCharacterGenerationService(modelService);
      const vm: AiCharacterPreviewViewModel = new AiCharacterPreviewViewModel(
        characterService, generationService, prefs
      );
      vm.setOnFieldRegenComplete((result: FieldRegenResult) => this.onFieldRegenComplete(result));
      this.viewModel = vm;
      const ok: boolean = vm.loadPendingCard();
      if (!ok) {
        promptAction.showToast({ message: vm.errorMessage, duration: 2000 });
      }
      this.isInitializing = false;
    } catch (e) {
      this.isInitializing = false;
      const msg: string = e instanceof Error ? e.message : '初始化失败';
      promptAction.showToast({ message: msg, duration: 2000 });
    }
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel!.dispose();
    }
  }

  /** 返回上一页 */
  private handleBack(): void {
    router.back();
  }

  /** 字段重新生成完成回调 */
  private onFieldRegenComplete(result: FieldRegenResult): void {
    if (result.value === null) {
      promptAction.showToast({
        message: result.error.length > 0 ? result.error : '字段重新生成失败',
        duration: 2000
      });
    } else {
      promptAction.showToast({
        message: '字段已更新',
        duration: 1000
      });
    }
  }

  /** 保存角色:先检查同名,再决定是否弹出确认 */
  private async onSaveClick(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    // 重复点击保护:保存进行中或对话框已显示时不再触发
    if (this.viewModel!.isSaving) {
      return;
    }
    if (this.showDuplicateNameConfirm) {
      return;
    }
    // 名称非空校验
    if (this.viewModel!.name.trim().length === 0) {
      promptAction.showToast({ message: '请输入角色名称', duration: 2000 });
      return;
    }
    // 同名检查
    const dup: boolean = await this.viewModel!.hasDuplicateName();
    if (dup) {
      this.showDuplicateNameConfirm = true;
      return;
    }
    this.performSave();
  }

  /** 实际执行保存 */
  private async performSave(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    const ok: boolean = await this.viewModel!.save();
    if (ok) {
      promptAction.showToast({ message: '角色已保存', duration: 1500 });
      // 返回到角色卡首页
      router.back({ url: 'pages/CharacterListPage' });
    } else {
      promptAction.showToast({
        message: this.viewModel!.errorMessage.length > 0 ? this.viewModel!.errorMessage : '保存失败',
        duration: 2000
      });
    }
  }

  /** 同名确认对话框:仍然保存 */
  private confirmDuplicateNameSave(): void {
    this.showDuplicateNameConfirm = false;
    this.performSave();
  }

  /** 同名确认对话框:取消 */
  private cancelDuplicateNameSave(): void {
    this.showDuplicateNameConfirm = false;
  }

  /** 放弃 */
  private onDiscardClick(): void {
    // 清理 AppStorage 槽位
    if (this.viewModel !== null) {
      AppStorage.setOrCreate('pendingAiCard', null);
      AppStorage.setOrCreate('pendingAiInput', null);
    }
    router.back();
  }

  /** 重新生成整张卡:先弹覆盖确认,确认后回退到 Maker 页面 */
  private onRegenerateFullClick(): void {
    this.showRegenerateConfirm = true;
  }

  /** 确认重新生成:清理草案并回退 */
  private confirmRegenerateFull(): void {
    this.showRegenerateConfirm = false;
    // 清理 pendingAiCard,但保留 pendingAiInput(Maker 页面会自动加载草稿)
    if (this.viewModel !== null) {
      AppStorage.setOrCreate('pendingAiCard', null);
    }
    router.back({ url: 'pages/AiCharacterMakerPage' });
  }

  /** 取消重新生成 */
  private cancelRegenerateFull(): void {
    this.showRegenerateConfirm = false;
  }

  /** 重新生成单字段 */
  private onRegenerateFieldClick(fieldPath: string): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.regenerateField(fieldPath);
  }

  /** 取消字段重新生成 */
  private onCancelFieldRegenClick(): void {
    if (this.viewModel === null) {
      return;
    }
    this.viewModel!.cancelFieldRegen();
  }

  /** 导出 JSON */
  private async onExportJsonClick(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.savedCharacterId.length === 0) {
      promptAction.showToast({ message: '请先保存角色后再导出', duration: 2000 });
      return;
    }
    let jsonString: string = '';
    try {
      jsonString = await this.viewModel!.exportToJson();
    } catch (e) {
      promptAction.showToast({
        message: e instanceof Error ? e.message : '导出 JSON 失败',
        duration: 2000
      });
      return;
    }
    // 调用系统文件保存器
    let uri: string = '';
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSaveOptions();
      const safeName: string = this.makeSafeFileName(this.viewModel!.name);
      options.newFileNames = [safeName + '.json'];
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      uri = uris[0];
    } catch (e) {
      promptAction.showToast({ message: '文件选择失败', duration: 2000 });
      return;
    }
    try {
      await this.writeJsonToFile(uri, jsonString);
      promptAction.showToast({ message: '已导出 JSON', duration: 1500 });
    } catch (e) {
      promptAction.showToast({ message: '写入文件失败', duration: 2000 });
    }
  }

  /** 导出 PNG */
  private async onExportPngClick(): Promise<void> {
    if (this.viewModel === null) {
      return;
    }
    if (this.viewModel!.savedCharacterId.length === 0) {
      promptAction.showToast({ message: '请先保存角色后再导出', duration: 2000 });
      return;
    }
    // 调用系统文件保存器
    let uri: string = '';
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSaveOptions();
      const safeName: string = this.makeSafeFileName(this.viewModel!.name);
      options.newFileNames = [safeName + '.png'];
      const uris: string[] = await documentPicker.save(options);
      if (uris.length === 0) {
        return;
      }
      uri = uris[0];
    } catch (e) {
      promptAction.showToast({ message: '文件选择失败', duration: 2000 });
      return;
    }
    try {
      await this.viewModel!.exportToPng(uri);
      promptAction.showToast({ message: '已导出 PNG', duration: 1500 });
    } catch (e) {
      promptAction.showToast({
        message: e instanceof Error ? e.message : '导出 PNG 失败',
        duration: 2000
      });
    }
  }

  /** 写入 JSON 文本到文件(UTF-8) */
  private async writeJsonToFile(uri: string, jsonString: string): Promise<void> {
    const file: fileIo.File = fileIo.openSync(uri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
    try {
      fileIo.writeSync(file.fd, jsonString);
    } finally {
      fileIo.closeSync(file);
    }
  }

  /** 生成文件名安全的字符串 */
  private makeSafeFileName(name: string): string {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return 'character';
    }
    // 替换文件系统不允许的字符
    return trimmed.replace(/[\\/:*?"<>|]/g, '_').slice(0, 64);
  }

  build() {
    Stack() {
      Column() {
        this.topBar()
        if (this.isInitializing) {
          this.loadingView()
        } else if (this.viewModel !== null && this.viewModel!.loaded) {
          this.previewContent()
        } else {
          this.errorView()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(ThemePalette.pageBgColor(this.effectiveTheme))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 字段重新生成遮罩
      if (this.viewModel !== null
        && this.viewModel!.fieldRegenState === FieldRegenState.Regenerating) {
        this.fieldRegenOverlay()
      }

      // 重新生成整张卡覆盖确认
      if (this.showRegenerateConfirm) {
        this.regenerateConfirmDialog()
      }

      // 同名角色确认
      if (this.showDuplicateNameConfirm) {
        this.duplicateNameConfirmDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ===== 顶部栏 =====

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

      Text('AI 角色卡预览')
        .fontSize($r('app.float.app_font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Button('保存')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(Color.Transparent)
        .fontColor(ThemePalette.accentColor(this.effectiveTheme))
        .height(40)
        .padding({ left: 12, right: 12 })
        .enabled(this.viewModel !== null && !this.viewModel!.isSaving)
        .onClick(() => {
          this.onSaveClick();
        })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: this.statusBarHeight + 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
  }

  // ===== 主内容 =====

  @Builder
  previewContent() {
    Scroll() {
      Column() {
        // ===== 基本信息区 =====
        this.sectionTitle('基本信息')
        this.editableField('名称', 'data.name',
          this.viewModel!.name, (v: string) => { this.viewModel!.name = v; }, false)

        Row() {
          Column() {
            Text('作者')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            TextInput({ text: this.viewModel!.creator })
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .width('100%')
              .padding({ left: 12, right: 12 })
              .margin({ top: 4 })
              .onChange((v: string) => { this.viewModel!.creator = v; })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ right: 8 })

          Column() {
            Text('版本')
              .fontSize($r('app.float.app_font_caption'))
              .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            TextInput({ text: this.viewModel!.characterVersion })
              .fontSize($r('app.float.app_font_body'))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_sm'))
              .height(40)
              .width('100%')
              .padding({ left: 12, right: 12 })
              .margin({ top: 4 })
              .onChange((v: string) => { this.viewModel!.characterVersion = v; })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_20'),
          right: $r('app.float.app_spacing_20'),
          top: 8,
          bottom: 8
        })

        this.editableTextArea('描述', 'data.description',
          this.viewModel!.description, (v: string) => { this.viewModel!.description = v; })

        this.editableTextArea('性格', 'data.personality',
          this.viewModel!.personality, (v: string) => { this.viewModel!.personality = v; })

        this.editableTextArea('场景', 'data.scenario',
          this.viewModel!.scenario, (v: string) => { this.viewModel!.scenario = v; })

        this.editableTextArea('开场白 (first_mes)', 'data.first_mes',
          this.viewModel!.firstMessage, (v: string) => { this.viewModel!.firstMessage = v; })

        this.editableTextArea('备用开场白 (alternate_greetings, 一行一条)',
          'data.alternate_greetings',
          this.viewModel!.alternateGreetings.join('\n'),
          (v: string) => {
            this.viewModel!.alternateGreetings = v.split('\n').filter((s: string) => s.length > 0);
          })

        this.editableTextArea('对话示例 (mes_example)', 'data.mes_example',
          this.viewModel!.mesExample, (v: string) => { this.viewModel!.mesExample = v; })

        this.editableTextArea('创作者备注 (creator_notes)', 'data.creator_notes',
          this.viewModel!.creatorNotes, (v: string) => { this.viewModel!.creatorNotes = v; })

        this.editableTextArea('System Prompt', 'data.system_prompt',
          this.viewModel!.systemPrompt, (v: string) => { this.viewModel!.systemPrompt = v; })

        this.editableTextArea('Post-History Instructions', 'data.post_history_instructions',
          this.viewModel!.postHistoryInstructions,
          (v: string) => { this.viewModel!.postHistoryInstructions = v; })

        this.editableField('标签 (逗号分隔)', 'data.tags',
          this.viewModel!.tags.join(', '),
          (v: string) => {
            this.viewModel!.tags = v.split(',').map((s: string) => s.trim()).filter((s: string) => s.length > 0);
          }, false)

        // ===== 角色世界书 =====
        this.sectionTitle('角色世界书 (character_book)')
        Text('JSON 格式,留空表示无世界书')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_20'),
            right: $r('app.float.app_spacing_20'),
            bottom: 4
          })
        TextArea({ text: this.viewModel!.characterBookJson, placeholder: '{\n  "entries": []\n}' })
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(160)
          .width('100%')
          .padding(12)
          .constraintSize({ maxHeight: 320 })
          .onChange((v: string) => { this.viewModel!.characterBookJson = v; })

        // ===== Extensions =====
        this.sectionTitle('Extensions')
        Text('JSON 格式,保存时与 character_book 一同保留')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_20'),
            right: $r('app.float.app_spacing_20'),
            bottom: 4
          })
        TextArea({ text: this.viewModel!.extensionsJson, placeholder: '{}' })
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(120)
          .width('100%')
          .padding(12)
          .constraintSize({ maxHeight: 240 })
          .onChange((v: string) => { this.viewModel!.extensionsJson = v; })

        // ===== 原始 JSON =====
        Row() {
          Text('原始 JSON')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .layoutWeight(1)
          Text(this.showRawJson ? '收起' : '展开')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .onClick(() => {
              this.showRawJson = !this.showRawJson;
            })
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_20'),
          right: $r('app.float.app_spacing_20'),
          top: 16,
          bottom: 8
        })
        if (this.showRawJson) {
          Text(this.viewModel!.rawResponse.length > 0 ? this.viewModel!.rawResponse : '(无)')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_sm'))
            .width('100%')
            .padding(12)
            .margin({
              left: $r('app.float.app_spacing_20'),
              right: $r('app.float.app_spacing_20'),
              bottom: 12
            })
            .maxLines(20)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .copyOption(CopyOptions.LocalDevice)
        }

        // ===== 错误提示 =====
        if (this.viewModel!.errorMessage.length > 0) {
          Text(this.viewModel!.errorMessage)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({
              left: $r('app.float.app_spacing_20'),
              right: $r('app.float.app_spacing_20'),
              top: 8,
              bottom: 8
            })
        }

        // ===== 操作按钮 =====
        Column() {
          // 重新生成整张卡
          Button('重新生成整张卡')
            .fontSize($r('app.float.app_font_body'))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
            .borderRadius($r('app.float.app_radius_md'))
            .height(44)
            .width('100%')
            .onClick(() => {
              this.onRegenerateFullClick();
            })

          // 导出
          Row() {
            Button('导出 JSON')
              .fontSize($r('app.float.app_font_body'))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_md'))
              .height(44)
              .layoutWeight(1)
              .onClick(() => {
                this.onExportJsonClick();
              })

            Button('导出 PNG')
              .fontSize($r('app.float.app_font_body'))
              .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
              .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
              .borderRadius($r('app.float.app_radius_md'))
              .height(44)
              .layoutWeight(1)
              .margin({ left: 8 })
              .onClick(() => {
                this.onExportPngClick();
              })
          }
          .width('100%')
          .margin({ top: 8 })

          // 放弃
          Button('放弃')
            .fontSize($r('app.float.app_font_body'))
            .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
            .fontColor($r('app.color.app_danger'))
            .borderRadius($r('app.float.app_radius_md'))
            .height(44)
            .width('100%')
            .margin({ top: 8 })
            .onClick(() => {
              this.onDiscardClick();
            })
        }
        .width('100%')
        .padding({
          left: $r('app.float.app_spacing_20'),
          right: $r('app.float.app_spacing_20'),
          top: 16,
          bottom: this.navigationBarHeight + 24
        })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }

  // ===== 通用 Builder =====

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize($r('app.float.app_font_subtitle'))
      .fontWeight(FontWeight.Medium)
      .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_20'),
        right: $r('app.float.app_spacing_20'),
        top: 16,
        bottom: 8
      })
  }

  /**
   * 可编辑的单行字段(带"重新生成"按钮)。
   * @param label 字段标签
   * @param fieldPath 字段路径(用于单字段重新生成)
   * @param value 当前值
   * @param onChange 值变化回调
   * @param multiline 是否支持多行(此处为 false,使用 TextInput)
   */
  @Builder
  editableField(label: string, fieldPath: string, value: string,
    onChange: (v: string) => void, _multiline: boolean) {
    Column() {
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text('重新生成')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .onClick(() => {
            this.onRegenerateFieldClick(fieldPath);
          })
      }
      .width('100%')

      TextInput({ text: value })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .width('100%')
        .padding({ left: 12, right: 12 })
        .margin({ top: 4 })
        .onChange((v: string) => onChange(v))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      top: 8,
      bottom: 8
    })
  }

  /**
   * 可编辑的多行字段(带"重新生成"按钮)。
   */
  @Builder
  editableTextArea(label: string, fieldPath: string, value: string,
    onChange: (v: string) => void) {
    Column() {
      Row() {
        Text(label)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Text('重新生成')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.accentColor(this.effectiveTheme))
          .onClick(() => {
            this.onRegenerateFieldClick(fieldPath);
          })
      }
      .width('100%')

      TextArea({ text: value })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(80)
        .width('100%')
        .padding(12)
        .margin({ top: 4 })
        .constraintSize({ maxHeight: 240 })
        .onChange((v: string) => onChange(v))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: $r('app.float.app_spacing_20'),
      right: $r('app.float.app_spacing_20'),
      top: 8,
      bottom: 8
    })
  }

  // ===== 字段重新生成遮罩 =====

  @Builder
  fieldRegenOverlay() {
    Stack() {
      Column() {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(ThemePalette.accentColor(this.effectiveTheme))
        Text('正在重新生成字段...')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .margin({ top: 12 })
        if (this.viewModel!.regeneratingField.length > 0) {
          Text(this.viewModel!.regeneratingField)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .margin({ top: 4 })
        }
        Button('取消')
          .fontSize($r('app.float.app_font_body'))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_md'))
          .height(40)
          .width('60%')
          .margin({ top: 16 })
          .onClick(() => {
            this.onCancelFieldRegenClick();
          })
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('80%')
      .padding(24)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_lg'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }

  // ===== 重新生成整张卡确认对话框 =====

  @Builder
  regenerateConfirmDialog() {
    Stack() {
      Column() {
        Text('重新生成会替换当前草案')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 12 })

        Text('当前已编辑的角色草案将被丢弃,返回输入页重新生成。是否继续?')
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 20 })

        Row() {
          Button('取消')
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.cancelRegenerateFull();
            })

          Button('继续')
            .fontSize(14)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .height(40)
            .layoutWeight(1)
            .margin({ left: 12 })
            .onClick(() => {
              this.confirmRegenerateFull();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(24)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_lg'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }

  // ===== 同名角色确认对话框 =====

  @Builder
  duplicateNameConfirmDialog() {
    Stack() {
      Column() {
        Text('已存在同名角色')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 12 })

        Text('已存在同名角色,继续保存将创建独立的新角色,不会覆盖原有角色。是否继续保存?')
          .fontSize(14)
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%')
          .margin({ bottom: 20 })

        Row() {
          Button('取消')
            .fontSize(14)
            .backgroundColor(Color.Transparent)
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
            .height(40)
            .layoutWeight(1)
            .onClick(() => {
              this.cancelDuplicateNameSave();
            })

          Button('仍然保存')
            .fontSize(14)
            .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
            .fontColor($r('app.color.app_on_accent'))
            .height(40)
            .layoutWeight(1)
            .margin({ left: 12 })
            .onClick(() => {
              this.confirmDuplicateNameSave();
            })
        }
        .width('100%')
      }
      .width('80%')
      .padding(24)
      .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
      .borderRadius($r('app.float.app_radius_lg'))
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(0,0,0,0.5)')
  }

  // ===== 加载/错误视图 =====

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
      Text(this.viewModel !== null && this.viewModel!.errorMessage.length > 0
        ? this.viewModel!.errorMessage : '加载失败')
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .textAlign(TextAlign.Center)
        .margin({ top: 80 })
      Button('返回')
        .fontSize($r('app.float.app_font_body'))
        .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
        .fontColor($r('app.color.app_on_accent'))
        .borderRadius($r('app.float.app_radius_md'))
        .height(44)
        .width('50%')
        .margin({ top: 16 })
        .onClick(() => {
          this.handleBack();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }
}
