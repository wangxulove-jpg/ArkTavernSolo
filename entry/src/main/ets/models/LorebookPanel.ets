import { LorebookEntry } from './Lorebook';

/**
 * 世界书面板单本书展示数据。
 */
export interface LorebookPanelBook {
  readonly lorebookId: string;
  readonly name: string;
  readonly isCharacterBook: boolean;
  readonly entries: LorebookEntry[];
}

/**
 * 世界书面板展示数据(角色专属书在前,全局书在后)。
 */
export interface LorebookPanelData {
  readonly books: LorebookPanelBook[];
}
