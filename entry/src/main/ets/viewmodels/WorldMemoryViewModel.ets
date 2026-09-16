/**
 * WorldMemoryViewModel 文件夹(世界分组)记忆管理页状态管理。
 *
 * 职责:
 * - 展示文件夹级记忆(core 核心 + chapter 章节时间线,按最后更新倒序)
 * - 新建/编辑/删除手工记忆(文件夹级,不绑定具体会话,worldId 共享注入)
 * - 手工记忆的关键词写入 keywordsJson,供"记忆关键词召回层"使用
 *
 * 不维护网络/模型调用;章节自动生成仍由 MemoryService 现有机制负责。
 */

import { ChatMemory, withMemoryMetadata } from '../models/ChatMemory';
import { MemoryService } from '../services/MemoryService';
import { AppServices } from '../services/AppServices';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldMemoryViewModel';

const TYPE_CHAPTER: number = 0;
const TYPE_CORE: number = 1;

@Observed
export class WorldMemoryViewModel {
  worldId: string = '';
  core: ChatMemory | null = null;
  chapters: ChatMemory[] = [];
  /** v46: 会话记忆列表(树状第一层,按 chatId 去重取最新,createdAt 正序) */
  sessions: ChatMemory[] = [];
  loading: boolean = false;
  errorMessage: string = '';

  /** 编辑对话框状态 */
  showEditDialog: boolean = false;
  editingMemory: ChatMemory | null = null;
  editType: number = TYPE_CHAPTER;
  editTitle: string = '';
  editContent: string = '';
  editKeywords: string = '';
  editImportance: string = '50';

  private readonly memoryService: MemoryService;

  constructor() {
    this.memoryService = AppServices.getMemoryService();
  }

  async load(worldId: string): Promise<void> {
    this.worldId = worldId;
    this.loading = true;
    this.errorMessage = '';
    try {
      const all: ChatMemory[] = await this.memoryService.listWorldMemories(worldId);
      let core: ChatMemory | null = null;
      const chapters: ChatMemory[] = [];
      for (let i = 0; i < all.length; i++) {
        const m: ChatMemory = all[i];
        if (m.memoryType === 'core') {
          // 世界 core 是单例,展示最新一条
          if (core === null || m.updatedAt > core.updatedAt) {
            core = m;
          }
        } else {
          chapters.push(m);
        }
      }
      // 章节按最后更新倒序(对应"按结束时间顺序")
      chapters.sort((a: ChatMemory, b: ChatMemory): number => b.updatedAt - a.updatedAt);
      this.core = core;
      this.chapters = chapters;
      // v46: 会话记忆列表(树状根层)
      this.sessions = await this.memoryService.listWorldSessions(worldId);
    } catch (e) {
      this.errorMessage = '加载记忆失败: ' + String(e);
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.loading = false;
    }
  }

  openNewDialog(type: number): void {
    this.editingMemory = null;
    this.editType = type;
    this.editTitle = '';
    this.editContent = '';
    this.editKeywords = '';
    this.editImportance = '50';
    this.showEditDialog = true;
  }

  openEditDialog(memory: ChatMemory): void {
    this.editingMemory = memory;
    this.editTitle = memory.title;
    this.editContent = memory.summary;
    this.editKeywords = this.keywordsJsonToText(memory.keywordsJson);
    this.editImportance = String(memory.importance);
    this.showEditDialog = true;
  }

  closeDialog(): void {
    this.showEditDialog = false;
    this.editingMemory = null;
  }

  async save(): Promise<boolean> {
    this.errorMessage = '';
    const title: string = this.editTitle.trim();
    const content: string = this.editContent.trim();
    if (title.length === 0 || content.length === 0) {
      this.errorMessage = '标题与内容不能为空';
      return false;
    }
    const importance: number = this.parseImportance(this.editImportance);
    const keywords: string[] = this.parseKeywordsText(this.editKeywords);
    try {
      if (this.editingMemory === null) {
        await this.memoryService.addWorldMemory(
          this.worldId,
          title,
          content,
          this.editType === TYPE_CORE ? 'core' : 'chapter',
          keywords,
          importance
        );
      } else {
        const now: number = Date.now();
        const updated: ChatMemory = withMemoryMetadata(this.editingMemory, {
          memoryType: this.editingMemory.memoryType,
          title: title,
          detail: content,
          importance: importance,
          keywordsJson: JSON.stringify(keywords),
          sourceHash: ''
        }, now);
        await this.memoryService.updateWorldMemory(updated);
      }
      this.closeDialog();
      await this.load(this.worldId);
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'save failed: ' + String(e));
      return false;
    }
  }

  async remove(memory: ChatMemory): Promise<void> {
    this.errorMessage = '';
    try {
      await this.memoryService.removeWorldMemory(memory.id);
      await this.load(this.worldId);
    } catch (e) {
      this.errorMessage = '删除失败: ' + String(e);
      Logger.error(LOG_TAG, 'remove failed: ' + String(e));
    }
  }

  private parseKeywordsText(text: string): string[] {
    const result: string[] = [];
    const parts: string[] = text.split(/[,，]/);
    for (let i = 0; i < parts.length; i++) {
      const k: string = parts[i].trim();
      if (k.length > 0 && result.indexOf(k) < 0) {
        result.push(k);
      }
    }
    return result;
  }

  private keywordsJsonToText(json: string): string {
    if (json.length === 0) {
      return '';
    }
    try {
      const parsed: Object = JSON.parse(json) as Object;
      if (!Array.isArray(parsed)) {
        return '';
      }
      return (parsed as Object[]).join(', ');
    } catch (e) {
      return '';
    }
  }

  private parseImportance(input: string): number {
    const parsed: number = parseInt(input);
    if (isNaN(parsed)) {
      return 0;
    }
    const clamped: number = Math.max(0, Math.min(100, parsed));
    return clamped;
  }
}