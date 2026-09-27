/**
 * LorebookPanelVM 世界书面板逻辑
 *
 * P3-1② 自 ChatViewModel 逐字抽离:面板数据加载 / AI 世界书提议与套用 / 条目启停。
 * 服务取用沿用 AppServices 静态(与抽离前一致,零改写);
 * 可变状态(disposed / character / messages / lorebookPanelData)经宿主契约 LorebookPanelHost 回调读写。
 */

import { Logger } from '../utils/Logger';
import { AppServices } from '../services/AppServices';
import { LorebookService } from '../services/LorebookService';
import { Character } from '../models/Character';
import { ChatMessage } from '../models/ChatMessage';
import { Lorebook, LorebookEntry, LorebookPosition, LorebookEntryUpdates } from '../models/Lorebook';
import { AiLorebookService, AiLorebookMode, AiLorebookInput } from '../services/ai/AiLorebookService';
import {
  AiLorebookChangeSet,
  AiLorebookAdd,
  AiLorebookUpdate,
  AiLorebookDelete
} from '../models/LorebookAiTypes';
import { LorebookPanelBook, LorebookPanelData } from '../models/LorebookPanel';

const LOG_TAG: string = 'LorebookPanelVM';

/**
 * 宿主契约:读取 ChatViewModel 的可变状态并回写面板数据(函数属性写法)。
 */
export interface LorebookPanelHost {
  isDisposed: () => boolean;
  getCharacter: () => Character | null;
  getRecentMessages: () => ChatMessage[];
  setPanelData: (data: LorebookPanelData | null) => void;
}

export class LorebookPanelVM {
  private host: LorebookPanelHost;
  private aiLorebookService: AiLorebookService | null = null;

  constructor(host: LorebookPanelHost) {
    this.host = host;
  }

  async loadLorebookPanelData(): Promise<void> {
    if (this.host.isDisposed()) {
      return;
    }
    try {
      const lorebookService: LorebookService = AppServices.getLorebookService();
      let characterBook: Lorebook | null = null;
      const character: Character | null = this.host.getCharacter();
      if (character !== null && character.characterBookId.length > 0) {
        characterBook = await lorebookService.getById(character.characterBookId);
      }
      const books: LorebookPanelBook[] = [];
      if (characterBook !== null) {
        books.push(this.buildPanelBook(characterBook, true));
      }
      this.host.setPanelData(books.length > 0 ? { books: books } : null);
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadLorebookPanelData failed: ' + String(e));
      this.host.setPanelData(null);
    }
  }

  private buildPanelBook(book: Lorebook, isCharacterBook: boolean): LorebookPanelBook {
    const sorted: LorebookEntry[] = book.entries.slice();
    sorted.sort((a: LorebookEntry, b: LorebookEntry): number => {
      if (a.priority !== b.priority) {
        return b.priority - a.priority;
      }
      return a.name.localeCompare(b.name);
    });
    return {
      lorebookId: book.id,
      name: book.name,
      isCharacterBook: isCharacterBook,
      entries: sorted
    };
  }

  async aiProposeWorldbookChanges(
    mode: AiLorebookMode,
    instruction: string
  ): Promise<AiLorebookChangeSet | null> {
    if (this.host.isDisposed()) {
      return null;
    }
    try {
      const lorebookService: LorebookService = AppServices.getLorebookService();
      let characterBook: Lorebook | null = null;
      const character: Character | null = this.host.getCharacter();
      if (character !== null && character.characterBookId.length > 0) {
        characterBook = await lorebookService.getById(character.characterBookId);
      }
      const input: AiLorebookInput = {
        globalBook: null,
        characterBook: characterBook,
        recentMessages: this.host.getRecentMessages(),
        instruction: instruction,
        mode: mode
      };
      return await this.getAiLorebookService().proposeChanges(input);
    } catch (e) {
      Logger.warn(LOG_TAG, 'aiProposeWorldbookChanges failed: ' + String(e));
      return null;
    }
  }

  async applyLorebookChangeSet(changes: AiLorebookChangeSet): Promise<boolean> {
    if (this.host.isDisposed()) {
      return false;
    }
    let anyFailed: boolean = false;
    const lorebookService: LorebookService = AppServices.getLorebookService();
    try {
      for (let i = 0; i < changes.adds.length; i++) {
        const a: AiLorebookAdd = changes.adds[i];
        try {
          await lorebookService.addEntry(
            a.lorebookId,
            a.name,
            a.keys,
            [],
            a.content,
            true,
            a.constant,
            false,
            a.position === 'AfterCharacter'
              ? LorebookPosition.AfterCharacter : LorebookPosition.BeforeCharacter,
            a.priority
          );
        } catch (e) {
          anyFailed = true;
          Logger.warn(LOG_TAG, 'apply add failed: ' + String(e));
        }
      }
      for (let i = 0; i < changes.updates.length; i++) {
        const u: AiLorebookUpdate = changes.updates[i];
        try {
          const updates: LorebookEntryUpdates = {};
          if (u.name !== undefined) {
            updates.name = u.name;
          }
          if (u.keys !== undefined) {
            updates.keys = u.keys;
          }
          if (u.content !== undefined) {
            updates.content = u.content;
          }
          if (u.position !== undefined) {
            updates.position = u.position === 'AfterCharacter'
              ? LorebookPosition.AfterCharacter : LorebookPosition.BeforeCharacter;
          }
          if (u.priority !== undefined) {
            updates.priority = u.priority;
          }
          await lorebookService.updateEntry(u.lorebookId, u.entryId, updates);
        } catch (e) {
          anyFailed = true;
          Logger.warn(LOG_TAG, 'apply update failed: ' + String(e));
        }
      }
      for (let i = 0; i < changes.deletes.length; i++) {
        const d: AiLorebookDelete = changes.deletes[i];
        try {
          await lorebookService.removeEntry(d.lorebookId, d.entryId);
        } catch (e) {
          anyFailed = true;
          Logger.warn(LOG_TAG, 'apply delete failed: ' + String(e));
        }
      }
      if (!anyFailed) {
        await this.loadLorebookPanelData();
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'applyLorebookChangeSet failed: ' + String(e));
      anyFailed = true;
    }
    return !anyFailed;
  }

  async toggleLorebookEntryEnabled(
    lorebookId: string,
    entryId: string,
    enabled: boolean
  ): Promise<void> {
    if (this.host.isDisposed()) {
      return;
    }
    try {
      const lorebookService: LorebookService = AppServices.getLorebookService();
      const updates: LorebookEntryUpdates = { enabled: enabled };
      await lorebookService.updateEntry(lorebookId, entryId, updates);
      await this.loadLorebookPanelData();
    } catch (e) {
      Logger.warn(LOG_TAG, 'toggleLorebookEntryEnabled failed: ' + String(e));
    }
  }

  private getAiLorebookService(): AiLorebookService {
    if (this.aiLorebookService === null) {
      this.aiLorebookService = new AiLorebookService(
        AppServices.getModelService(),
        AppServices.getLorebookService()
      );
    }
    return this.aiLorebookService;
  }
}
