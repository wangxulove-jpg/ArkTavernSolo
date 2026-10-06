/**
 * PromptPresetListViewModel 预设列表状态管理
 *
 * 页面与 PromptPresetService 之间的唯一桥梁。
 * 不直接依赖 Repository、DbHelper 或 Preferences。
 */

import { PromptPreset, PresetScope, isManagedImagePresetId } from '../models/PromptPreset';
import { Character } from '../models/Character';
import { PromptPresetService } from '../services/PromptPresetService';
import { parsePromptPresetImport, buildPromptPresetExportJson } from '../parser/PromptPresetImportParser';
import { AppServices } from '../services/AppServices';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetListViewModel';

@Observed
export class PromptPresetListViewModel {
  presets: PromptPreset[] = [];
  selectedPresetIds: string[] = [];
  /** v51: 预设 → 注入位置映射(本地偏好;用于列表"末尾"标签) */
  presetPositions: Record<string, string> = {};
  /** v52: 预设 → 作用域展示标签('全局' / 角色名 / '角色已删除';用于列表徽标) */
  presetScopeLabels: Record<string, string> = {};
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
      // v51: 注入位置(本地偏好)
      this.presetPositions = await this.presetService.getPresetPositions();
      // v52: 作用域标签(本地偏好 + 角色名解析)
      this.presetScopeLabels = await this.buildScopeLabels();
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

  /**
   * 将全部预设导出为 JSON 文件。
   * 列表 → 序列化(与导入格式对称) → 写入文件 URI。
   * @returns 成功导出的数量
   */
  async exportPresetsToFile(uri: string): Promise<number> {
    if (this.disposed || this.isOperating) {
      return 0;
    }
    this.isOperating = true;
    this.errorMessage = '';
    try {
        const all: PromptPreset[] = await this.presetService.list();
        // v52: 受管"本地图片清单"由图片库自动维护,导出时排除(导入侧无 id,不会生成受管项)
        const presets: PromptPreset[] = all.filter((p: PromptPreset): boolean => !isManagedImagePresetId(p.id));
        if (presets.length === 0) {
          return 0;
        }
      const json: string = buildPromptPresetExportJson(presets);
      await AppServices.getCharacterService().writeFileContent(uri, json);
      return presets.length;
    } catch (e) {
      this.errorMessage = '导出失败: ' + ((e as Error).message ?? String(e));
      Logger.error(LOG_TAG, 'exportPresetsToFile failed: ' + String(e));
      return 0;
    } finally {
      this.isOperating = false;
    }
  }

  isSelected(id: string): boolean {
    return this.selectedPresetIds.indexOf(id) >= 0;
  }

  /** v51: 该预设是否注入到末尾(对话之后)。 */
  isTail(id: string): boolean {
    return this.presetPositions[id] === 'tail';
  }

  /** v52: 该预设是否为受管"本地图片清单"(由图片库自动维护,列表页禁止编辑/删除)。 */
  isManagedPreset(id: string): boolean {
    return isManagedImagePresetId(id);
  }

  /** v52: 作用域标签(无记录 = 全局)。 */
  getScopeLabel(id: string): string {
    const label: string | undefined = this.presetScopeLabels[id];
    return label !== undefined ? label : '全局';
  }

  /**
   * v52: 构建作用域展示标签(presetId → 文案)。
   * 角色名解析失败 / 角色已删除 → '角色已删除'(列表直接可见,便于用户重新绑定)。
   */
  private async buildScopeLabels(): Promise<Record<string, string>> {
    const labels: Record<string, string> = {};
    let scopes: Record<string, PresetScope> = {};
    try {
      scopes = await this.presetService.getPresetScopes();
    } catch (e) {
      Logger.warn(LOG_TAG, 'buildScopeLabels load scopes failed: ' + String(e));
      return labels;
    }
    const keys: string[] = Object.keys(scopes);
    const nameCache: Record<string, string> = {};
    for (let i = 0; i < keys.length; i++) {
      const id: string = keys[i];
      const scope: PresetScope = scopes[id];
      if (scope.kind !== 'character') {
        labels[id] = '全局';
        continue;
      }
      let name: string | undefined = nameCache[scope.characterId];
      if (name === undefined) {
        name = await this.lookupCharacterName(scope.characterId);
        nameCache[scope.characterId] = name;
      }
      labels[id] = name.length > 0 ? name : '角色已删除';
    }
    return labels;
  }

  /** 角色名查询(失败返回空串,由调用方降级为「角色已删除」) */
  private async lookupCharacterName(characterId: string): Promise<string> {
    try {
      const character: Character | null = await AppServices.getCharacterService().getById(characterId);
      return character !== null ? character.name : '';
    } catch (e) {
      Logger.warn(LOG_TAG, 'lookupCharacterName failed: ' + String(e));
      return '';
    }
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