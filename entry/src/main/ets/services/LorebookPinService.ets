/**
 * LorebookPinService 按需锁定世界书会话钉选服务(OnDemandPinned)
 *
 * 职责:
 * - 管理会话级世界书条目钉选记录(chat_lorebook_pins 表,每个 chat 一行)
 * - ensurePinnedEntries:请求构建时读取钉选;无记录时按当前全部消息
 *   做首次钉选(新会话即首条消息,老会话补钉)并落库
 * - refreshPinnedEntries:手动记忆总结成功后,按全部对话消息重新匹配刷新
 *
 * 缓存设计:
 * - 钉选按 chatId 持久化,切换会话/重新生成/分支切换都不重算
 * - 仅手动记忆总结成功后刷新 → 与记忆段同时变化,缓存前缀稳定
 *
 * 分层约束:
 * - 可被 ChatService / ViewModel 调用
 * - 不引用页面类,不访问网络
 */

import { Lorebook, LorebookEntry } from '../models/Lorebook';
import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import {
  ChatLorebookPin,
  ChatLorebookPinRepository
} from '../repositories/ChatLorebookPinRepository';
import { LorebookService } from './LorebookService';
import { Logger } from '../utils/Logger';
import { nowMillis } from '../utils/Time';

const LOG_TAG: string = 'LorebookPinService';

export class LorebookPinService {
  private readonly repository: ChatLorebookPinRepository;
  private readonly lorebookService: LorebookService;

  constructor(
    repository: ChatLorebookPinRepository,
    lorebookService: LorebookService
  ) {
    this.repository = repository;
    this.lorebookService = lorebookService;
  }

  /**
   * 获取会话钉选条目(供 PromptBuilder 注入)。
   *
   * - 已有钉选记录:按记录的 entryIds 取 enabled 条目(条目被删/禁用时自动缩水,
   *   内容实时读取,用户编辑条目立即生效)
   * - 无钉选记录:对当前全部消息(新会话即首条消息)做全量关键词匹配,
   *   命中条目落库为钉选(首次钉选)
   * - 钉选记录的 lorebookId 与当前书不一致(角色换了绑定书):视为失效,重新钉选
   *
   * 失败不抛错,返回空数组(等价于无命中,不阻塞请求)。
   */
  async ensurePinnedEntries(
    chatId: string,
    lorebook: Lorebook,
    messages: ChatMessage[]
  ): Promise<LorebookEntry[]> {
    if (chatId.length === 0 || !lorebook.enabled) {
      return [];
    }
    try {
      const existing: ChatLorebookPin | null = await this.repository.getByChatId(chatId);
      if (existing !== null && existing.lorebookId === lorebook.id) {
        return this.lorebookService.getEntriesByIds(lorebook, existing.entryIds);
      }
      const pinned: LorebookEntry[] = this.computePinnedEntries(lorebook, messages);
      await this.repository.upsert({
        chatId: chatId,
        lorebookId: lorebook.id,
        entryIds: pinned.map((e: LorebookEntry): string => e.id),
        createdAt: existing !== null ? existing.createdAt : nowMillis(),
        updatedAt: nowMillis()
      });
      Logger.info(LOG_TAG, 'initial pin chatId.len=' + chatId.length
        + ' book=' + lorebook.id + ' entries=' + pinned.length);
      return pinned;
    } catch (e) {
      Logger.warn(LOG_TAG, 'ensurePinnedEntries failed: ' + String(e));
      return [];
    }
  }

  /**
   * 刷新会话钉选(手动记忆总结成功后调用)。
   * 对全部对话消息做全量关键词匹配,命中即纳入(宁多勿少),替换原钉选。
   * 失败不抛错,保留原钉选。
   */
  async refreshPinnedEntries(
    chatId: string,
    lorebook: Lorebook,
    messages: ChatMessage[]
  ): Promise<void> {
    if (chatId.length === 0 || !lorebook.enabled) {
      return;
    }
    try {
      const pinned: LorebookEntry[] = this.computePinnedEntries(lorebook, messages);
      const existing: ChatLorebookPin | null = await this.repository.getByChatId(chatId);
      await this.repository.upsert({
        chatId: chatId,
        lorebookId: lorebook.id,
        entryIds: pinned.map((e: LorebookEntry): string => e.id),
        createdAt: existing !== null ? existing.createdAt : nowMillis(),
        updatedAt: nowMillis()
      });
      Logger.info(LOG_TAG, 'refresh pin chatId.len=' + chatId.length
        + ' book=' + lorebook.id + ' entries=' + pinned.length);
    } catch (e) {
      Logger.warn(LOG_TAG, 'refreshPinnedEntries failed: ' + String(e));
    }
  }

  /**
   * 全量关键词匹配计算钉选条目(非 constant,命中即纳入,预算截断)。
   */
  private computePinnedEntries(
    lorebook: Lorebook,
    messages: ChatMessage[]
  ): LorebookEntry[] {
    const texts: string[] = [];
    for (let i = 0; i < messages.length; i++) {
      const msg: ChatMessage = messages[i];
      if (msg.role === ChatRole.User || msg.role === ChatRole.Assistant) {
        texts.push(msg.content);
      }
    }
    return this.lorebookService.matchKeywordEntriesAgainstTexts(lorebook, texts);
  }
}
