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

import { ChatMemory, withMemoryMetadata, withUpdatedSummary, withTitle } from '../models/ChatMemory';
import { Chat } from '../models/Chat';
import { MemoryService } from '../services/MemoryService';
import { AppServices } from '../services/AppServices';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'WorldMemoryViewModel';

const TYPE_CHAPTER: number = 0;
const TYPE_CORE: number = 1;

/** v49: 文件夹会话记忆排序模式 */
export type WorldSessionSortMode = 'created' | 'folder' | 'recent';

@Observed
export class WorldMemoryViewModel {
  worldId: string = '';
  core: ChatMemory | null = null;
  chapters: ChatMemory[] = [];
  /** v46: 会话记忆列表(树状第一层,按 chatId 去重取最新,顺序由 sessionSortMode 决定) */
  sessions: ChatMemory[] = [];
  /** v49: 会话记忆排序模式(默认按会话创建时间) */
  sessionSortMode: WorldSessionSortMode = 'created';
  loading: boolean = false;
  errorMessage: string = '';

  /** v49: chatId → Chat(供按创建时间/文件夹顺序排序) */
  private chatMap: Map<string, Chat> = new Map<string, Chat>();

  /** 编辑对话框状态 */
  showEditDialog: boolean = false;
  editingMemory: ChatMemory | null = null;
  editType: number = TYPE_CHAPTER;
  editTitle: string = '';
  editContent: string = '';
  editKeywords: string = '';
  editImportance: string = '50';

  /** v47: 会话记忆编辑对话框状态(标题 + 摘要,仅更新 title/summary,保留 detail 实体索引) */
  showSessionEdit: boolean = false;
  sessionEditMemory: ChatMemory | null = null;
  sessionEditTitle: string = '';
  sessionEditContent: string = '';
  sessionEditSaving: boolean = false;

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
      // v46: 会话记忆列表(树状根层);v49: 按会话记录排序(创建时间/文件夹顺序/最近修改)
      this.sessions = await this.memoryService.listWorldSessions(worldId);
      await this.loadChatMap(this.sessions);
      this.sortSessions();
    } catch (e) {
      this.errorMessage = '加载记忆失败: ' + String(e);
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.loading = false;
    }
  }

  /** v49: 构建 chatId → Chat 映射(供按会话创建时间/文件夹顺序排序)。 */
  private async loadChatMap(sessions: ChatMemory[]): Promise<void> {
    this.chatMap = new Map<string, Chat>();
    try {
      const repo = AppServices.getChatRepository();
      for (let i = 0; i < sessions.length; i++) {
        const chat: Chat | null = await repo.getById(sessions[i].chatId);
        if (chat !== null) {
          this.chatMap.set(sessions[i].chatId, chat);
        }
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadChatMap failed: ' + String(e));
    }
  }

  /** v49: 设置会话记忆排序模式并重排(无需重新加载)。 */
  setSessionSortMode(mode: WorldSessionSortMode): void {
    this.sessionSortMode = mode;
    this.sortSessions();
  }

  /** v49: 按当前排序模式重排会话记忆(新引用触发 ForEach 重渲染)。 */
  private sortSessions(): void {
    const mode: WorldSessionSortMode = this.sessionSortMode;
    const sorted: ChatMemory[] = this.sessions.slice();
    sorted.sort((a: ChatMemory, b: ChatMemory): number => {
      if (mode === 'recent') {
        // 最近修改:会话记忆 updatedAt 倒序
        return b.updatedAt - a.updatedAt;
      }
      const ca: Chat | undefined = this.chatMap.get(a.chatId);
      const cb: Chat | undefined = this.chatMap.get(b.chatId);
      if (mode === 'folder') {
        // 文件夹顺序:与文件夹内会话记录保存顺序一致(sortOrder 升序,平局按创建时间)
        const sa: number = ca !== undefined ? ca.sortOrder : 0;
        const sb: number = cb !== undefined ? cb.sortOrder : 0;
        if (sa !== sb) {
          return sa - sb;
        }
      }
      // 默认:会话创建时间升序(查不到会话时回退记忆创建时间)
      const ta: number = ca !== undefined ? ca.createdAt : a.createdAt;
      const tb: number = cb !== undefined ? cb.createdAt : b.createdAt;
      return ta - tb;
    });
    this.sessions = sorted;
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

  /**
   * 打开会话记忆编辑对话框。
   * 预填标题与摘要(只编辑 title/summary,detail 实体索引不展示、不修改)。
   */
  openSessionEdit(memory: ChatMemory): void {
    this.sessionEditMemory = memory;
    this.sessionEditTitle = memory.title;
    this.sessionEditContent = memory.summary;
    this.sessionEditSaving = false;
    this.showSessionEdit = true;
  }

  /** 关闭会话记忆编辑对话框。 */
  closeSessionEdit(): void {
    this.showSessionEdit = false;
    this.sessionEditMemory = null;
    this.sessionEditTitle = '';
    this.sessionEditContent = '';
    this.sessionEditSaving = false;
  }

  /**
   * 保存会话记忆编辑。
   * 仅更新 title 与 summary(注入用 summary 字段),保留 detail(实体索引 JSON)与
   * memoryType 等其余字段;worldId 不变,仍参与世界池注入。
   *
   * @returns 是否保存成功
   */
  async saveSessionEdit(): Promise<boolean> {
    if (this.sessionEditMemory === null || this.sessionEditSaving) {
      return false;
    }
    const title: string = this.sessionEditTitle.trim();
    const content: string = this.sessionEditContent.trim();
    if (title.length === 0 || content.length === 0) {
      this.errorMessage = '标题与内容不能为空';
      return false;
    }
    this.errorMessage = '';
    this.sessionEditSaving = true;
    try {
      const now: number = Date.now();
      const updated: ChatMemory = withMemoryMetadata(
        withUpdatedSummary(this.sessionEditMemory, content, now),
        { title: title },
        now
      );
      await this.memoryService.updateWorldMemory(updated);
      this.closeSessionEdit();
      await this.load(this.worldId);
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'saveSessionEdit failed: ' + String(e));
      return false;
    } finally {
      this.sessionEditSaving = false;
    }
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