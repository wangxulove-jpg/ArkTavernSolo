import { ModelService } from '../ModelService';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { MarketCacheStore, MarketTranslationCacheEntry } from './MarketCacheStore';
import { MarketCharacter } from '../../models/MarketCharacter';
import { MarketCharacterDetail } from '../../models/MarketCharacterDetail';
import {
  MarketTranslationResult,
  MarketDetailTranslation,
  hashString,
  hashStringArray
} from '../../models/MarketTranslation';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'MarketTranslationService';
const DEBOUNCE_MS: number = 350;
const BATCH_MAX_SIZE: number = 8;

export class MarketTranslationService {
  private readonly modelService: ModelService;
  private readonly cache: MarketCacheStore;
  private operationId: number = 0;
  private debounceTimerId: number = -1;

  constructor(modelService: ModelService, cache: MarketCacheStore) {
    this.modelService = modelService;
    this.cache = cache;
  }

  async isTranslateEnabled(): Promise<boolean> {
    return await this.cache.getTranslateEnabled();
  }

  async setTranslateEnabled(value: boolean): Promise<void> {
    await this.cache.setTranslateEnabled(value);
  }

  async getCachedTranslation(item: MarketCharacter): Promise<MarketTranslationResult | null> {
    const fieldHash: number = computeListFieldHash(item);
    const entry: MarketTranslationCacheEntry | null = await this.cache.getTranslation(
      item.providerId, item.remoteId, item.updatedAt, fieldHash
    );
    if (entry === null) {
      return null;
    }
    return {
      name: entry.translatedName,
      summary: entry.translatedSummary,
      tags: entry.translatedTags.slice(),
      creatorNotes: entry.translatedCreatorNotes
    };
  }

  translateItems(
    items: MarketCharacter[],
    onResult: (remoteId: string, translation: MarketTranslationResult) => void
  ): void {
    this.operationId++;
    const opId: number = this.operationId;

    if (this.debounceTimerId !== -1) {
      clearTimeout(this.debounceTimerId);
      this.debounceTimerId = -1;
    }

    this.debounceTimerId = setTimeout((): void => {
      this.debounceTimerId = -1;
      this.executeBatchTranslation(opId, items, onResult);
    }, DEBOUNCE_MS);
  }

  cancelAll(): void {
    this.operationId++;
    if (this.debounceTimerId !== -1) {
      clearTimeout(this.debounceTimerId);
      this.debounceTimerId = -1;
    }
  }

  async translateDetail(detail: MarketCharacterDetail): Promise<MarketDetailTranslation | null> {
    try {
      const base: MarketCharacter = detail.base;
      const listHash: number = computeListFieldHash(base);
      const cached: MarketTranslationCacheEntry | null = await this.cache.getTranslation(
        base.providerId, base.remoteId, base.updatedAt, listHash
      );

      let name: string;
      let summary: string;
      let tags: string[];
      let creatorNotes: string;
      let description: string;
      let personality: string;
      let scenario: string;
      let firstMessagePreview: string;

      if (cached !== null && cached.translatedDescription.length > 0) {
        name = cached.translatedName;
        summary = cached.translatedSummary;
        tags = cached.translatedTags.slice();
        creatorNotes = cached.translatedCreatorNotes;
        description = cached.translatedDescription;
        personality = cached.translatedPersonality;
        scenario = cached.translatedScenario;
        firstMessagePreview = cached.translatedFirstMessagePreview;
        return {
          name: name,
          summary: summary,
          tags: tags,
          creatorNotes: creatorNotes,
          description: description,
          personality: personality,
          scenario: scenario,
          firstMessagePreview: firstMessagePreview
        };
      }

      if (cached !== null) {
        name = cached.translatedName;
        summary = cached.translatedSummary;
        tags = cached.translatedTags.slice();
        creatorNotes = cached.translatedCreatorNotes;
      } else {
        const listResult: MarketTranslationResult | null = await this.translateSingleList(base);
        if (listResult !== null) {
          name = listResult.name;
          summary = listResult.summary;
          tags = listResult.tags;
          creatorNotes = listResult.creatorNotes;
        } else {
          name = base.name;
          summary = base.summary;
          tags = base.tags.slice();
          creatorNotes = detail.creatorNotes;
        }
      }

      description = detail.description;
      personality = detail.personality;
      scenario = detail.scenario;
      firstMessagePreview = detail.firstMessagePreview;

      const detailTexts: string[] = [];
      if (detail.description.trim().length > 0) {
        detailTexts.push('Description: ' + detail.description);
      }
      if (detail.personality.trim().length > 0) {
        detailTexts.push('Personality: ' + detail.personality);
      }
      if (detail.scenario.trim().length > 0) {
        detailTexts.push('Scenario: ' + detail.scenario);
      }
      if (detail.firstMessagePreview.trim().length > 0) {
        detailTexts.push('First Message: ' + detail.firstMessagePreview);
      }

      if (detailTexts.length > 0) {
        const translatedDetail: string = await this.translateText(detailTexts.join('\n\n'), 'en', 'zh-CN');
        if (translatedDetail.trim().length > 0) {
          const sections: string[] = translatedDetail.split(/\n{2,}/);
          let sectionIdx: number = 0;
          if (detail.description.trim().length > 0 && sectionIdx < sections.length) {
            const s: string = sections[sectionIdx];
            if (s.trim().length > 0) {
              description = stripPrefix(s);
            }
            sectionIdx++;
          }
          if (detail.personality.trim().length > 0 && sectionIdx < sections.length) {
            const s: string = sections[sectionIdx];
            if (s.trim().length > 0) {
              personality = stripPrefix(s);
            }
            sectionIdx++;
          }
          if (detail.scenario.trim().length > 0 && sectionIdx < sections.length) {
            const s: string = sections[sectionIdx];
            if (s.trim().length > 0) {
              scenario = stripPrefix(s);
            }
            sectionIdx++;
          }
          if (detail.firstMessagePreview.trim().length > 0 && sectionIdx < sections.length) {
            const s: string = sections[sectionIdx];
            if (s.trim().length > 0) {
              firstMessagePreview = stripPrefix(s);
            }
            sectionIdx++;
          }
        }
      }

      const entry: MarketTranslationCacheEntry = {
        providerId: base.providerId,
        remoteId: base.remoteId,
        remoteUpdatedAt: base.updatedAt,
        fieldHash: listHash,
        translatedName: name,
        translatedSummary: summary,
        translatedTags: tags.slice(),
        translatedCreatorNotes: creatorNotes,
        translatedDescription: description,
        translatedPersonality: personality,
        translatedScenario: scenario,
        translatedFirstMessagePreview: firstMessagePreview,
        translatedAt: Date.now()
      };
      await this.cache.putTranslation(entry);

      return {
        name: name,
        summary: summary,
        tags: tags,
        creatorNotes: creatorNotes,
        description: description,
        personality: personality,
        scenario: scenario,
        firstMessagePreview: firstMessagePreview
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'translateDetail failed: ' + String(e));
      return null;
    }
  }

  async translateQueryToEnglish(chineseQuery: string): Promise<string> {
    if (chineseQuery.trim().length === 0) {
      return chineseQuery;
    }
    try {
      const result: string = await this.translateText(chineseQuery, 'zh-CN', 'en');
      return result.trim().length > 0 ? result : chineseQuery;
    } catch (e) {
      Logger.warn(LOG_TAG, 'translateQueryToEnglish failed: ' + String(e));
      return chineseQuery;
    }
  }

  async clearTranslationCache(): Promise<void> {
    await this.cache.clearTranslationCache();
  }

  private async translateText(text: string, fromLang: string, toLang: string): Promise<string> {
    if (text.trim().length === 0) {
      return text;
    }
    const prompt: string = buildTranslationPrompt(text, fromLang, toLang);
    const userMsg: ChatMessage = createChatMessage(
      'translate-' + Date.now().toString(),
      ChatRole.User,
      prompt,
      Date.now()
    );
    const request: ChatRequest = {
      model: '',
      messages: [userMsg],
      temperature: 0.1,
      topP: 0.9,
      maxTokens: 4096,
      stream: false
    };
    const response = await this.modelService.sendChat(request);
    if (response.content.trim().length > 0) {
      return response.content.trim();
    }
    return '';
  }

  private async translateSingleList(item: MarketCharacter): Promise<MarketTranslationResult | null> {
    try {
      const tName: string = await this.translateText(item.name, 'en', 'zh-CN');
      if (tName.trim().length === 0) {
        return null;
      }
      const result: MarketTranslationResult = {
        name: tName,
        summary: item.summary,
        tags: item.tags.slice(),
        creatorNotes: ''
      };
      const entry: MarketTranslationCacheEntry = {
        providerId: item.providerId,
        remoteId: item.remoteId,
        remoteUpdatedAt: item.updatedAt,
        fieldHash: computeListFieldHash(item),
        translatedName: tName,
        translatedSummary: item.summary,
        translatedTags: item.tags.slice(),
        translatedCreatorNotes: '',
        translatedDescription: '',
        translatedPersonality: '',
        translatedScenario: '',
        translatedFirstMessagePreview: '',
        translatedAt: Date.now()
      };
      await this.cache.putTranslation(entry);
      return result;
    } catch (e) {
      Logger.warn(LOG_TAG, 'translateSingleList failed: ' + String(e));
      return null;
    }
  }

  private async executeBatchTranslation(
    opId: number,
    items: MarketCharacter[],
    onResult: (remoteId: string, translation: MarketTranslationResult) => void
  ): Promise<void> {
    if (opId !== this.operationId) {
      return;
    }

    const pending: MarketCharacter[] = [];
    for (let i: number = 0; i < items.length; i++) {
      if (opId !== this.operationId) {
        return;
      }
      const item: MarketCharacter = items[i];
      const hash: number = computeListFieldHash(item);
      const cached: MarketTranslationCacheEntry | null = await this.cache.getTranslation(
        item.providerId, item.remoteId, item.updatedAt, hash
      );
      if (cached === null) {
        pending.push(item);
      }
    }

    if (pending.length === 0) {
      return;
    }

    for (let i: number = 0; i < pending.length; i += BATCH_MAX_SIZE) {
      if (opId !== this.operationId) {
        return;
      }
      const end: number = Math.min(i + BATCH_MAX_SIZE, pending.length);
      const batch: MarketCharacter[] = pending.slice(i, end);
      await this.translateBatch(opId, batch, onResult);
    }
  }

  private async translateBatch(
    opId: number,
    batch: MarketCharacter[],
    onResult: (remoteId: string, translation: MarketTranslationResult) => void
  ): Promise<void> {
    for (let i: number = 0; i < batch.length; i++) {
      if (opId !== this.operationId) {
        return;
      }
      const item: MarketCharacter = batch[i];
      const result: MarketTranslationResult | null = await this.translateSingleList(item);
      if (opId !== this.operationId) {
        return;
      }
      if (result !== null) {
        onResult(item.remoteId, result);
      }
    }
  }
}

function buildTranslationPrompt(text: string, fromLang: string, toLang: string): string {
  const fromName: string = fromLang === 'en' ? 'English' : fromLang === 'zh-CN' ? 'Chinese' : fromLang;
  const toName: string = toLang === 'zh-CN' ? 'Chinese' : toLang === 'en' ? 'English' : toLang;
  return 'Translate the following text from ' + fromName + ' to ' + toName + '. ' +
    'Only output the translation, no explanations, no notes, no original text. ' +
    'Preserve the line structure (each line corresponds to the same line in the original). ' +
    'If a line starts with a label like "Name:", "Summary:", "Tags:", "Description:", keep the label and translate the content after it.\n\n' +
    text;
}

function stripPrefix(line: string): string {
  const prefixes: string[] = ['Name:', 'Summary:', 'Tags:', 'Description:', 'Personality:', 'Scenario:', 'First Message:',
    '名称:', '摘要:', '标签:', '描述:', '性格:', '场景:', '第一条消息:',
    'name:', 'summary:', 'tags:', 'description:', 'personality:', 'scenario:', 'first message:'];
  const trimmed: string = line.trim();
  for (let i: number = 0; i < prefixes.length; i++) {
    if (trimmed.startsWith(prefixes[i])) {
      return trimmed.substring(prefixes[i].length).trim();
    }
  }
  return trimmed;
}

function computeListFieldHash(item: MarketCharacter): number {
  const nameHash: number = hashString(item.name);
  const summaryHash: number = hashString(item.summary);
  const tagsHash: number = hashStringArray(item.tags);
  return (nameHash ^ (summaryHash * 31) ^ (tagsHash * 67)) >>> 0;
}
