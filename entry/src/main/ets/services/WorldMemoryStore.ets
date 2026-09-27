/**
 * WorldMemoryStore 世界级手工记忆与关键词召回(P3-2② 自 MemoryService 逐字抽离)
 *
 * 覆盖 v44:文件夹级手工记忆 CRUD + 关键词召回(parse/match/isAsciiOnly)。
 * 依赖 MemoryPersistenceService 构造期注入(字段与 MemoryService 同名 → 搬运体逐字一致)。
 * 无网络、无副作用;不持有可变状态,故无需宿主回调。
 *
 * 注:`listWorldSessions`(会话记忆列表去重)依赖加载簇的 dedupe 逻辑,保留在 MemoryService。
 */

import {
  ChatMemory,
  createChatMemory,
  withMemoryMetadata,
  MemoryType
} from '../models/ChatMemory';
import { MemoryPersistenceService } from './MemoryPersistenceService';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

export class WorldMemoryStore {
  private readonly memoryPersistence: MemoryPersistenceService;

  constructor(memoryPersistence: MemoryPersistenceService) {
    this.memoryPersistence = memoryPersistence;
  }

  /**
   * 新增文件夹级手工记忆(不绑定具体会话/分支,worldId 非空即参与世界池注入)。
   */
  async addWorldMemory(
    worldId: string,
    title: string,
    content: string,
    memoryType: MemoryType,
    keywords: string[],
    importance: number
  ): Promise<ChatMemory> {
    const now: number = nowMillis();
    const base: ChatMemory = createChatMemory(
      generateUuid(), '', '', '', '', 0, 0, content, now, undefined, worldId
    );
    const typed: ChatMemory = withMemoryMetadata(base, {
      memoryType: memoryType,
      title: title,
      detail: content,
      importance: importance,
      keywordsJson: JSON.stringify(keywords),
      sourceHash: ''
    }, now);
    await this.memoryPersistence.insert(typed);
    return typed;
  }

  /** 更新手工记忆(标题/内容/关键词/重要度由管理页编辑后回写)。 */
  async updateWorldMemory(memory: ChatMemory): Promise<void> {
    await this.memoryPersistence.update(memory);
  }

  /** 删除手工记忆(物理删除)。 */
  async removeWorldMemory(memoryId: string): Promise<void> {
    await this.memoryPersistence.removeById(memoryId);
  }

  /** 列出文件夹全部有效记忆(供记忆管理页)。 */
  async listWorldMemories(worldId: string): Promise<ChatMemory[]> {
    return await this.memoryPersistence.listValidByWorld(worldId);
  }

  /**
   * 关键词召回:从文件夹章节池中,按当前对话文本命中关键词提取历史章节,
   * 排除恒定注入列表,按重要度降序取预算内最多 maxCount 条。
   * 供可选的"记忆检索段"注入(开关关闭时调用方不调用本方法)。
   */
  async retrieveKeywordMemories(
    worldId: string,
    texts: string[],
    excludeIds: string[],
    maxCount: number
  ): Promise<ChatMemory[]> {
    if (maxCount <= 0) {
      return [];
    }
    const all: ChatMemory[] = await this.memoryPersistence.listValidByWorldAndType(worldId, 'chapter');
    const exclude: Set<string> = new Set(excludeIds);
    const hits: ChatMemory[] = [];
    for (let i = 0; i < all.length; i++) {
      const m: ChatMemory = all[i];
      if (exclude.has(m.id)) {
        continue;
      }
      const keywords: string[] = this.parseMemoryKeywords(m.keywordsJson);
      if (keywords.length === 0) {
        continue;
      }
      if (this.matchMemoryKeywords(keywords, texts)) {
        hits.push(m);
      }
    }
    hits.sort((a: ChatMemory, b: ChatMemory): number => {
      if (b.importance !== a.importance) {
        return b.importance - a.importance;
      }
      return b.updatedAt - a.updatedAt;
    });
    return hits.slice(0, maxCount);
  }

  /** keywordsJson 安全解析(损坏返回空数组)。 */
  private parseMemoryKeywords(json: string): string[] {
    if (json.length === 0) {
      return [];
    }
    try {
      const parsed: Object = JSON.parse(json) as Object;
      if (!Array.isArray(parsed)) {
        return [];
      }
      const result: string[] = [];
      const arr: Object[] = parsed as Object[];
      for (let i = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string' && (arr[i] as string).trim().length > 0) {
          result.push((arr[i] as string).trim());
        }
      }
      return result;
    } catch (e) {
      return [];
    }
  }

  /** 任一关键词命中任一文本(ASCII 忽略大小写,非 ASCII 精确包含)。 */
  private matchMemoryKeywords(keywords: string[], texts: string[]): boolean {
    for (let i = 0; i < keywords.length; i++) {
      const key: string = keywords[i];
      for (let j = 0; j < texts.length; j++) {
        const text: string = texts[j];
        let hit: boolean;
        if (this.isAsciiOnly(key)) {
          hit = text.toLowerCase().includes(key.toLowerCase());
        } else {
          hit = text.includes(key);
        }
        if (hit) {
          return true;
        }
      }
    }
    return false;
  }

  private isAsciiOnly(str: string): boolean {
    for (let i = 0; i < str.length; i++) {
      if (str.charCodeAt(i) > 127) {
        return false;
      }
    }
    return true;
  }
}
