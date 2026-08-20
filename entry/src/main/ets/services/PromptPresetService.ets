/**
 * PromptPresetService 业务服务
 *
 * 职责:
 * - PromptPreset 的 CRUD 业务编排
 * - 已选 Preset 集合管理(多选)
 * - 删除 Preset 时自动从已选集合移除
 * - 不存在的已选 Preset 自动剔除
 *
 * 不负责:
 * - ChatService / PromptBuilder / Provider 请求参数接入(T-6.1B)
 * - 管理 UI
 * - 导入导出
 * - 自动创建默认 Preset
 * - 从现有模型设置迁移 Preset
 *
 * 安全:
 * - 错误不泄露 systemPrompt 或完整 Preset ID
 * - 日志不输出 Preset name / description / systemPrompt
 */

import { PromptPresetRepository } from '../repositories/PromptPresetRepository';
import { PromptPresetSelectionStore } from '../storage/PromptPresetSelectionStore';
import {
  PromptPreset,
  CreatePromptPresetOptions,
  PromptPresetUpdates,
  createPromptPreset,
  updatePromptPreset,
  validatePromptPreset
} from '../models/PromptPreset';
import { DatabaseError } from '../models/DatabaseError';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'PromptPresetService';

export class PromptPresetService {
  private readonly repository: PromptPresetRepository;
  private readonly selectionStore: PromptPresetSelectionStore;

  constructor(
    repository: PromptPresetRepository,
    selectionStore: PromptPresetSelectionStore
  ) {
    this.repository = repository;
    this.selectionStore = selectionStore;
  }

  async initialize(): Promise<void> {
    await this.selectionStore.initialize();
  }

  async list(): Promise<PromptPreset[]> {
    return await this.repository.list();
  }

  async getById(id: string): Promise<PromptPreset | null> {
    return await this.repository.getById(id);
  }

  async create(options: CreatePromptPresetOptions): Promise<PromptPreset> {
    const preset: PromptPreset = createPromptPreset(options);
    await this.repository.insert(preset);
    return preset;
  }

  async update(id: string, updates: PromptPresetUpdates): Promise<PromptPreset> {
    const existing: PromptPreset | null = await this.repository.getById(id);
    if (existing === null) {
      throw DatabaseError.notFound('preset.update');
    }
    const updated: PromptPreset = updatePromptPreset(existing, updates);
    await this.repository.update(updated);
    return updated;
  }

  async remove(id: string): Promise<void> {
    // 幂等:先检查是否存在
    const exists: boolean = await this.repository.exists(id);
    if (!exists) {
      return;
    }
    await this.repository.remove(id);

    // 从已选集合中移除被删除的 Preset
    await this.removeSelectedPresetId(id);
  }

  async getSelectedPresetIds(): Promise<string[]> {
    return await this.selectionStore.getSelectedPresetIds();
  }

  async getSelectedPresets(): Promise<PromptPreset[]> {
    const ids: string[] = await this.selectionStore.getSelectedPresetIds();
    const result: PromptPreset[] = [];
    const validIds: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      const preset: PromptPreset | null = await this.repository.getById(id);
      if (preset !== null) {
        result.push(preset);
        validIds.push(id);
      }
    }
    // 清理失效的已选 ID(不存在则剔除)
    if (validIds.length !== ids.length) {
      await this.selectionStore.setSelectedPresetIds(validIds);
      Logger.warn(LOG_TAG, 'selection cleaned (some preset not found)');
    }
    return result;
  }

  async setSelectedPresetIds(ids: string[]): Promise<void> {
    const validIds: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const exists: boolean = await this.repository.exists(ids[i]);
      if (exists) {
        validIds.push(ids[i]);
      }
    }
    await this.selectionStore.setSelectedPresetIds(validIds);
  }

  async addSelectedPresetId(id: string): Promise<void> {
    const exists: boolean = await this.repository.exists(id);
    if (!exists) {
      throw DatabaseError.notFound('preset.addSelected');
    }
    const ids: string[] = await this.selectionStore.getSelectedPresetIds();
    let already: boolean = false;
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] === id) {
        already = true;
        break;
      }
    }
    if (!already) {
      ids.push(id);
      await this.selectionStore.setSelectedPresetIds(ids);
    }
  }

  async removeSelectedPresetId(id: string): Promise<void> {
    const ids: string[] = await this.selectionStore.getSelectedPresetIds();
    const next: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] !== id) {
        next.push(ids[i]);
      }
    }
    await this.selectionStore.setSelectedPresetIds(next);
  }
}