/**
 * CharacterListViewModel 角色列表页面状态管理
 *
 * 角色列表页面的唯一 ViewModel,管理角色 CRUD 和当前角色选择。
 * 不直接操作 CharacterStore 或 Preferences。
 */

import { Character } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import { ParsedCharacterCard } from '../parser/CharacterCardJsonParser';
import { PngParseResult } from '../parser/PngCharacterCardParser';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterListViewModel';

@Observed
export class CharacterListViewModel {
  characters: Character[] = [];
  currentCharacterId: string | null = null;
  loading: boolean = false;
  /** 错误提示 */
  errorMessage: string = '';
  /** 编辑对话框状态 */
  showEditDialog: boolean = false;
  editingCharacter: Character | null = null;
  /** 编辑表单字段 */
  editName: string = '';
  editDescription: string = '';
  editPersonality: string = '';
  editScenario: string = '';
  editFirstMessage: string = '';
  editSystemPrompt: string = '';
  /** 删除确认 */
  deleteTarget: Character | null = null;
  /** 导入预览 */
  showImportPreview: boolean = false;
  previewCard: ParsedCharacterCard | null = null;
  importJsonBuffer: string = '';
  importing: boolean = false;
  importError: string = '';
  /** PNG 导入特有状态 */
  isPngImport: boolean = false;
  previewPngUri: string = '';
  /** 导出 */
  exporting: boolean = false;
  exportError: string = '';

  private readonly service: CharacterService;

  constructor(service: CharacterService) {
    this.service = service;
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      this.characters = await this.service.listSummaries();
      this.currentCharacterId = await this.service.getCurrentCharacterId();
    } catch (e) {
      this.errorMessage = '加载角色列表失败';
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.loading = false;
    }
  }

  /** 打开新建对话框 */
  showNewDialog(): void {
    this.editingCharacter = null;
    this.editName = '';
    this.editDescription = '';
    this.editPersonality = '';
    this.editScenario = '';
    this.editFirstMessage = '';
    this.editSystemPrompt = '';
    this.showEditDialog = true;
  }

  /** 打开编辑对话框 */
  showEditDialogFor(character: Character): void {
    this.editingCharacter = character;
    this.editName = character.name;
    this.editDescription = character.description;
    this.editPersonality = character.personality;
    this.editScenario = character.scenario;
    this.editFirstMessage = character.firstMessage;
    this.editSystemPrompt = character.systemPrompt;
    this.showEditDialog = true;
  }

  /** 关闭编辑对话框 */
  closeEditDialog(): void {
    this.showEditDialog = false;
    this.editingCharacter = null;
  }

  /** 保存(新建或编辑) */
  async saveEdit(): Promise<boolean> {
    this.errorMessage = '';
    if (this.editName.trim().length === 0) {
      this.errorMessage = '角色名称不能为空';
      return false;
    }
    try {
      if (this.editingCharacter === null) {
        // 新建
        await this.service.create(
          this.editName, this.editDescription, this.editPersonality,
          this.editScenario, this.editFirstMessage, this.editSystemPrompt
        );
      } else {
        // 编辑
        await this.service.update(this.editingCharacter.id, {
          name: this.editName,
          description: this.editDescription,
          personality: this.editPersonality,
          scenario: this.editScenario,
          firstMessage: this.editFirstMessage,
          systemPrompt: this.editSystemPrompt
        });
      }
      this.showEditDialog = false;
      this.editingCharacter = null;
      await this.load();
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'saveEdit failed: ' + String(e));
      return false;
    }
  }

  /** 删除角色 */
  async deleteCharacter(id: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.remove(id);
      await this.load();
    } catch (e) {
      this.errorMessage = '删除失败: ' + String(e);
      Logger.error(LOG_TAG, 'deleteCharacter failed: ' + String(e));
    }
  }

  /** 设为当前角色 */
  async setCurrent(id: string | null): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.setCurrentCharacterId(id);
      this.currentCharacterId = await this.service.getCurrentCharacterId();
    } catch (e) {
      this.errorMessage = '设置失败: ' + String(e);
      Logger.error(LOG_TAG, 'setCurrent failed: ' + String(e));
    }
  }

  /** 上移角色卡片 */
  async moveUp(id: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.moveCharacterUp(id);
      await this.load();
    } catch (e) {
      this.errorMessage = '上移失败: ' + String(e);
      Logger.error(LOG_TAG, 'moveUp failed: ' + String(e));
    }
  }

  /** 下移角色卡片 */
  async moveDown(id: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.moveCharacterDown(id);
      await this.load();
    } catch (e) {
      this.errorMessage = '下移失败: ' + String(e);
      Logger.error(LOG_TAG, 'moveDown failed: ' + String(e));
    }
  }

  /** 是否为当前角色 */
  isCurrent(character: Character): boolean {
    return this.currentCharacterId === character.id;
  }

  // ===== 导入导出 =====

  /**
   * 从文件 URI 读取并解析角色卡,显示预览。
   * 自动检测 PNG 或 JSON 格式。
   *
   * @param uri 文件 URI
   */
  async startImportFile(uri: string): Promise<void> {
    // 检测文件类型
    const lowerUri: string = uri.toLowerCase();
    if (lowerUri.endsWith('.png')) {
      await this.startPngImport(uri);
      return;
    }
    await this.startJsonImport(uri);
  }

  /**
   * JSON 导入流程。
   */
  private async startJsonImport(uri: string): Promise<void> {
    this.importing = true;
    this.importError = '';
    this.previewCard = null;
    this.importJsonBuffer = '';
    this.showImportPreview = false;
    this.isPngImport = false;
    this.previewPngUri = '';
    try {
      const jsonString: string = await this.service.readFileContent(uri);
      const result = this.service.parseCharacterJson(jsonString);
      if (!result.success || result.card === null) {
        this.importError = result.error !== null ? result.error : '导入失败';
        return;
      }
      this.previewCard = result.card;
      this.importJsonBuffer = jsonString;
      this.showImportPreview = true;
    } catch (e) {
      this.importError = '导入失败: ' + String(e);
      Logger.error(LOG_TAG, 'startJsonImport failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  /**
   * PNG 导入流程。
   * 解析 PNG → 复用 CharacterCardJsonParser 解析 JSON → 显示预览。
   */
  private async startPngImport(uri: string): Promise<void> {
    this.importing = true;
    this.importError = '';
    this.previewCard = null;
    this.importJsonBuffer = '';
    this.showImportPreview = false;
    this.isPngImport = false;
    this.previewPngUri = '';
    try {
      const pngImport = await this.service.importPngFromFile(uri);
      const pngResult: PngParseResult = pngImport.result;

      if (!pngResult.success) {
        this.importError = pngResult.error;
        return;
      }

      // 复用 CharacterCardJsonParser 解析 JSON
      const jsonResult = this.service.parseCharacterJson(pngResult.jsonString);
      if (!jsonResult.success || jsonResult.card === null) {
        this.importError = jsonResult.error !== null ? jsonResult.error : '导入失败';
        return;
      }

      this.previewCard = jsonResult.card;
      // 设置来源格式为 PNG 中的格式(chara_card_v2/chara_card_v3)
      this.previewCard = {
        name: jsonResult.card.name,
        description: jsonResult.card.description,
        personality: jsonResult.card.personality,
        scenario: jsonResult.card.scenario,
        firstMessage: jsonResult.card.firstMessage,
        systemPrompt: jsonResult.card.systemPrompt,
        avatarUri: jsonResult.card.avatarUri,
        mesExample: jsonResult.card.mesExample,
        creatorNotes: jsonResult.card.creatorNotes,
        postHistoryInstructions: jsonResult.card.postHistoryInstructions,
        alternateGreetings: jsonResult.card.alternateGreetings,
        tags: jsonResult.card.tags,
        creator: jsonResult.card.creator,
        characterVersion: jsonResult.card.characterVersion,
        extensions: jsonResult.card.extensions,
        characterBook: jsonResult.card.characterBook,
        sourceFormat: pngResult.sourceFormat,
        userName: jsonResult.card.userName,
        nickname: jsonResult.card.nickname,
        groupOnlyGreetings: jsonResult.card.groupOnlyGreetings,
        creatorNotesMultilingual: jsonResult.card.creatorNotesMultilingual,
        source: jsonResult.card.source,
        assets: jsonResult.card.assets,
        creationDate: jsonResult.card.creationDate,
        modificationDate: jsonResult.card.modificationDate
      };
      this.previewPngUri = uri;
      this.isPngImport = true;
      this.showImportPreview = true;
    } catch (e) {
      this.importError = 'PNG 导入失败: ' + String(e);
      Logger.error(LOG_TAG, 'startPngImport failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  /**
   * 确认导入:保存预览中的角色卡。
   * PNG 导入时保存头像并创建角色,JSON 导入时直接创建角色。
   * 导入成功后刷新列表,但不自动设为当前角色。
   */
  async confirmImport(): Promise<void> {
    if (this.previewCard === null) {
      return;
    }
    this.importing = true;
    this.importError = '';
    try {
      if (this.isPngImport && this.previewPngUri.length > 0) {
        // PNG 导入:保存头像 + 角色
        await this.service.confirmPngImport(this.previewCard, this.previewPngUri);
      } else {
        // JSON 导入
        await this.service.importFromParsed(this.previewCard);
      }
      this.showImportPreview = false;
      this.previewCard = null;
      this.importJsonBuffer = '';
      this.isPngImport = false;
      this.previewPngUri = '';
      await this.load();
    } catch (e) {
      this.importError = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'confirmImport failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  /**
   * 取消导入预览。
   */
  cancelImport(): void {
    this.showImportPreview = false;
    this.previewCard = null;
    this.importJsonBuffer = '';
    this.importError = '';
    this.isPngImport = false;
    // 不删除原始 PNG 文件(只取消导入,不产生残留)
    this.previewPngUri = '';
  }

  /**
   * 导出角色到文件 URI。
   *
   * @param id 角色 ID
   * @param uri 文件 URI
   */
  async exportToFile(id: string, uri: string): Promise<void> {
    this.exporting = true;
    this.exportError = '';
    try {
      await this.service.exportToFile(id, uri);
    } catch (e) {
      this.exportError = '导出失败: ' + String(e);
      Logger.error(LOG_TAG, 'exportToFile failed: ' + String(e));
      throw new Error(String(e));
    } finally {
      this.exporting = false;
    }
  }
}