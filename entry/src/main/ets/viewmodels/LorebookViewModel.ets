/**
 * LorebookViewModel 世界书页面状态管理
 *
 * 世界书页面的唯一 ViewModel,管理世界书和条目的 CRUD。
 * 不直接操作 LorebookStore 或 Preferences。
 */

import {
  Lorebook,
  LorebookEntry,
  LorebookPosition,
  LorebookEntryUpdates
} from '../models/Lorebook';
import { LorebookService } from '../services/LorebookService';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LorebookViewModel';

@Observed
export class LorebookViewModel {
  lorebooks: Lorebook[] = [];
  currentLorebookId: string | null = null;
  loading: boolean = false;
  errorMessage: string = '';

  /** 数据变更回调,用于页面将 @State 变量同步到 ViewModel */
  onDataUpdate: (() => void) | null = null;

  /** 展开的世界书 ID(用于显示条目列表) */
  expandedLorebookId: string | null = null;

  /** 世界书编辑对话框 */
  showLorebookDialog: boolean = false;
  editingLorebook: Lorebook | null = null;
  editLorebookName: string = '';
  editLorebookDescription: string = '';

  /** 条目编辑对话框 */
  showEntryDialog: boolean = false;
  editingEntry: LorebookEntry | null = null;
  editingEntryLorebookId: string = '';
  editEntryName: string = '';
  editEntryKeys: string = '';
  editEntrySecondaryKeys: string = '';
  editEntryContent: string = '';
  editEntryEnabled: boolean = true;
  editEntryConstant: boolean = false;
  editEntrySelective: boolean = false;
  editEntryPosition: number = 0; // 0=BeforeCharacter, 1=AfterCharacter
  editEntryPriority: number = 0;

  /** 删除确认 */
  deleteTargetLorebook: Lorebook | null = null;
  deleteTargetEntry: LorebookEntry | null = null;
  deleteTargetEntryLorebookId: string = '';

  private readonly service: LorebookService;

  constructor(service: LorebookService) {
    this.service = service;
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      this.lorebooks = await this.service.list();
      this.currentLorebookId = await this.service.getCurrentLorebookId();
      this.notifyDataUpdate();
    } catch (e) {
      this.errorMessage = '加载世界书列表失败';
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.loading = false;
    }
  }

  private notifyDataUpdate(): void {
    if (this.onDataUpdate !== null) {
      this.onDataUpdate();
    }
  }

  isCurrent(lorebook: Lorebook): boolean {
    return this.currentLorebookId === lorebook.id;
  }

  /** 切换展开/折叠 */
  toggleExpand(lorebookId: string): void {
    if (this.expandedLorebookId === lorebookId) {
      this.expandedLorebookId = null;
    } else {
      this.expandedLorebookId = lorebookId;
    }
  }

  // ===== 世界书编辑 =====

  showNewLorebookDialog(): void {
    this.editingLorebook = null;
    this.editLorebookName = '';
    this.editLorebookDescription = '';
    this.showLorebookDialog = true;
  }

  showEditLorebookDialog(lorebook: Lorebook): void {
    this.editingLorebook = lorebook;
    this.editLorebookName = lorebook.name;
    this.editLorebookDescription = lorebook.description;
    this.showLorebookDialog = true;
  }

  closeLorebookDialog(): void {
    this.showLorebookDialog = false;
    this.editingLorebook = null;
  }

  async saveLorebook(): Promise<boolean> {
    this.errorMessage = '';
    if (this.editLorebookName.trim().length === 0) {
      this.errorMessage = '世界书名称不能为空';
      return false;
    }
    try {
      if (this.editingLorebook === null) {
        await this.service.create(this.editLorebookName, this.editLorebookDescription);
      } else {
        await this.service.update(this.editingLorebook.id, {
          name: this.editLorebookName,
          description: this.editLorebookDescription
        });
      }
      this.showLorebookDialog = false;
      this.editingLorebook = null;
      await this.load();
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'saveLorebook failed: ' + String(e));
      return false;
    }
  }

  async setCurrentLorebook(id: string | null): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.setCurrentLorebookId(id);
      this.currentLorebookId = await this.service.getCurrentLorebookId();
      this.notifyDataUpdate();
    } catch (e) {
      this.errorMessage = '设置失败: ' + String(e);
      Logger.error(LOG_TAG, 'setCurrentLorebook failed: ' + String(e));
    }
  }

  async deleteLorebook(id: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.remove(id);
      this.deleteTargetLorebook = null;
      if (this.expandedLorebookId === id) {
        this.expandedLorebookId = null;
      }
      await this.load();
    } catch (e) {
      this.errorMessage = '删除失败: ' + String(e);
      Logger.error(LOG_TAG, 'deleteLorebook failed: ' + String(e));
    }
  }

  async toggleLorebookEnabled(lorebook: Lorebook): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.update(lorebook.id, { enabled: !lorebook.enabled });
      await this.load();
    } catch (e) {
      this.errorMessage = '操作失败: ' + String(e);
      Logger.error(LOG_TAG, 'toggleLorebookEnabled failed: ' + String(e));
    }
  }

  // ===== 条目编辑 =====

  showNewEntryDialog(lorebookId: string): void {
    this.editingEntry = null;
    this.editingEntryLorebookId = lorebookId;
    this.editEntryName = '';
    this.editEntryKeys = '';
    this.editEntrySecondaryKeys = '';
    this.editEntryContent = '';
    this.editEntryEnabled = true;
    this.editEntryConstant = false;
    this.editEntrySelective = false;
    this.editEntryPosition = 0;
    this.editEntryPriority = 0;
    this.showEntryDialog = true;
  }

  showEditEntryDialog(lorebookId: string, entry: LorebookEntry): void {
    this.editingEntry = entry;
    this.editingEntryLorebookId = lorebookId;
    this.editEntryName = entry.name;
    this.editEntryKeys = entry.keys.join(', ');
    this.editEntrySecondaryKeys = entry.secondaryKeys.join(', ');
    this.editEntryContent = entry.content;
    this.editEntryEnabled = entry.enabled;
    this.editEntryConstant = entry.constant;
    this.editEntrySelective = entry.selective;
    this.editEntryPosition = entry.position === LorebookPosition.AfterCharacter ? 1 : 0;
    this.editEntryPriority = entry.priority;
    this.showEntryDialog = true;
  }

  closeEntryDialog(): void {
    this.showEntryDialog = false;
    this.editingEntry = null;
  }

  async saveEntry(): Promise<boolean> {
    this.errorMessage = '';
    if (this.editEntryName.trim().length === 0) {
      this.errorMessage = '条目名称不能为空';
      return false;
    }
    if (this.editEntryContent.trim().length === 0) {
      this.errorMessage = '条目内容不能为空';
      return false;
    }
    const keys: string[] = this.parseKeysString(this.editEntryKeys);
    const secondaryKeys: string[] = this.parseKeysString(this.editEntrySecondaryKeys);
    if (!this.editEntryConstant && keys.length === 0) {
      this.errorMessage = '非恒定条目至少需要一个关键词';
      return false;
    }
    const position: LorebookPosition = this.editEntryPosition === 1
      ? LorebookPosition.AfterCharacter : LorebookPosition.BeforeCharacter;

    try {
      if (this.editingEntry === null) {
        await this.service.addEntry(
          this.editingEntryLorebookId,
          this.editEntryName, keys, secondaryKeys, this.editEntryContent,
          this.editEntryEnabled, this.editEntryConstant, this.editEntrySelective,
          position, this.editEntryPriority
        );
      } else {
        const updates: LorebookEntryUpdates = {
          name: this.editEntryName,
          keys: keys,
          secondaryKeys: secondaryKeys,
          content: this.editEntryContent,
          enabled: this.editEntryEnabled,
          constant: this.editEntryConstant,
          selective: this.editEntrySelective,
          position: position,
          priority: this.editEntryPriority
        };
        await this.service.updateEntry(this.editingEntryLorebookId, this.editingEntry.id, updates);
      }
      this.showEntryDialog = false;
      this.editingEntry = null;
      await this.load();
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'saveEntry failed: ' + String(e));
      return false;
    }
  }

  async deleteEntry(lorebookId: string, entryId: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.removeEntry(lorebookId, entryId);
      this.deleteTargetEntry = null;
      this.deleteTargetEntryLorebookId = '';
      await this.load();
    } catch (e) {
      this.errorMessage = '删除失败: ' + String(e);
      Logger.error(LOG_TAG, 'deleteEntry failed: ' + String(e));
    }
  }

  // ===== 工具方法 =====

  /**
   * 解析关键词字符串(逗号或换行分隔)。
   */
  private parseKeysString(input: string): string[] {
    const result: string[] = [];
    // 先按换行分割,再按逗号分割
    const lines: string[] = input.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const parts: string[] = lines[i].split(',');
      for (let j = 0; j < parts.length; j++) {
        const trimmed: string = parts[j].trim();
        if (trimmed.length > 0) {
          result.push(trimmed);
        }
      }
    }
    return result;
  }

  /**
   * 获取 Position 显示文本。
   */
  getPositionText(position: string): string {
    if (position === LorebookPosition.AfterCharacter) {
      return '角色后';
    }
    return '角色前';
  }

  /**
   * 获取条目数量文本。
   */
  getEntryCountText(lorebook: Lorebook): string {
    const count: number = lorebook.entries.length;
    if (count === 0) {
      return '无条目';
    }
    return count.toString() + ' 个条目';
  }
}