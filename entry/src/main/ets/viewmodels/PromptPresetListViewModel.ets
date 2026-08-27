/**
 * PromptPresetListViewModel 预设列表状态管理
 *
 * 页面与 PromptPresetService 之间的唯一桥梁。
 * 不直接依赖 Repository、DbHelper 或 Preferences。
 */

import { PromptPreset } from '../models/PromptPreset';
import { PromptPresetService } from '../services/PromptPresetService';
import { parsePromptPresetImport } from '../parser/PromptPresetImportParser';
import { AppServices } from '../services/AppServices';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetListViewModel';

@Observed
export class PromptPresetListViewModel {
  presets: PromptPreset[] = [];
  selectedPresetIds: string[] = [];
  isLoading: boolean = false;
  isOperating: boolean = false;
  errorMessage: string = '';
  showDeleteConfirm: boolean = false;
  pendingDeleteId: string = '';

  private readonly presetService: PromptPresetService;
  private disposed: boolean = false;

  constructor(presetService: PromptPresetService) {
    this.presetService = presetService;
  }

  async initialize(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    await this.refresh();
  }

  async refresh(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';
    try {
      this.presets = await this.presetService.list();
      this.selectedPresetIds = await this.presetService.getSelectedPresetIds();
    } catch (e) {
      this.errorMessage = '加载预设列表失败';
      Logger.error(LOG_TAG, 'refresh failed: ' + String(e));
    } finally {
      this.isLoading = false;
    }
  }

  async toggle(id: string): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      if (this.isSelected(id)) {
        await this.presetService.removeSelectedPresetId(id);
      } else {
        await this.presetService.addSelectedPresetId(id);
      }
      this.selectedPresetIds = await this.presetService.getSelectedPresetIds();
    } catch (e) {
      this.errorMessage = '切换预设失败';
      Logger.error(LOG_TAG, 'toggle failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  async clearAll(): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      await this.presetService.setSelectedPresetIds([]);
      this.selectedPresetIds = [];
    } catch (e) {
      this.errorMessage = '清除预设失败';
      Logger.error(LOG_TAG, 'clearAll failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  requestDelete(id: string): void {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.pendingDeleteId = id;
    this.showDeleteConfirm = true;
    this.errorMessage = '';
  }

  cancelDelete(): void {
    this.pendingDeleteId = '';
    this.showDeleteConfirm = false;
  }

  async confirmDelete(id: string): Promise<void> {
    if (this.disposed || this.isOperating) {
      return;
    }
    this.isOperating = true;
    try {
      await this.presetService.remove(id);
      this.pendingDeleteId = '';
      // 删除后刷新列表和当前选择
      await this.refresh();
    } catch (e) {
      this.errorMessage = '删除预设失败';
      Logger.error(LOG_TAG, 'confirmDelete failed: ' + String(e));
    } finally {
      this.isOperating = false;
    }
  }

  getPresetSummary(preset: PromptPreset): string {
    const parts: string[] = [];
    if (preset.temperature !== undefined) {
      parts.push('温度 ' + preset.temperature.toString());
    }
    if (preset.topP !== undefined) {
      parts.push('Top P ' + preset.topP.toString());
    }
    if (preset.maxOutputTokens !== undefined) {
      parts.push('输出 ' + preset.maxOutputTokens.toString());
    }
    if (preset.contextWindow !== undefined) {
      parts.push('上下文 ' + preset.contextWindow.toString());
    }
    if (parts.length === 0) {
      return '沿用当前模型参数';
    }
    return parts.join(' · ');
  }

  /**
   * 从文件导入提示词预设(JSON)。
   * 读取文本 → 白名单解析 → 批量入库 → 刷新列表。
   * @returns 成功导入的数量
   */
  async importPresetsFromFile(uri: string): Promise<number> {
    if (this.disposed || this.isOperating) {
      return 0;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
      const text: string = await AppServices.getCharacterService().readFileContent(uri);
      const fallbackName: string = basenameWithoutExtension(uri);
      const items = parsePromptPresetImport(text, fallbackName);
      const inserted: number = await this.presetService.importPresets(items);
      await this.refresh();
      return inserted;
    } catch (e) {
      this.errorMessage = '导入失败: ' + ((e as Error).message ?? String(e));
      Logger.error(LOG_TAG, 'importPresetsFromFile failed: ' + String(e));
      return 0;
    } finally {
      this.isOperating = false;
    }
  }

  isSelected(id: string): boolean {
    return this.selectedPresetIds.indexOf(id) >= 0;
  }

  getSelectedCount(): number {
    return this.selectedPresetIds.length;
  }

  dispose(): void {
    this.disposed = true;
  }
}

/** 从文件 URI 中提取不含扩展名的文件名(用于命名缺失时的兜底)。 */
function basenameWithoutExtension(uri: string): string {
  const idx: number = uri.lastIndexOf('/');
  let name: string = idx >= 0 ? uri.substring(idx + 1) : uri;
  try {
    name = decodeURIComponent(name);
  } catch (e) {
    // 非合法编码则原样使用
  }
  const qIdx: number = name.indexOf('?');
  if (qIdx >= 0) {
    name = name.substring(0, qIdx);
  }
  const dot: number = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}