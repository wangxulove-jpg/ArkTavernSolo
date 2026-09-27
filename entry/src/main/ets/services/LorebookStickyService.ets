/**
 * LorebookStickyService 粘滞按需世界书会话命中服务(StickyOnDemand)
 *
 * 职责:
 * - 管理会话级世界书粘滞命中记录(chat_lorebook_sticky 表,每个 chat 一行)
 * - ensureStickyEntries:请求构建时读取命中集合;无记录时按最近消息首钉;
 *   已有记录时,本轮新命中的条目按命中顺序追加到集合尾部(append-only,
 *   已在集合内的条目位置不动、不移除),并为新条目记录锚点
 * - refreshStickyEntries:手动记忆总结成功后,按全部对话消息重新匹配刷新
 *
 * 缓存设计(v47 锚点插入):
 * - 条目全文只插一次,位置 = 首次命中时的锚点消息之后,此后不再移动
 *   → 该块从下一轮起就处在稳定前缀里,被缓存命中
 * - 命中集合会话内只增不减,膨胀由书级注入预算(injectionBudgetChars)控制,
 *   预算满后停止追加新条目
 * - 集合变化仅发生在:新条目首次命中(尾部追加) / 手动总结刷新(重算)
 * - "注意力新鲜"不靠搬动条目,而由 ChatService 在请求尾部追加一行
 *   「当前仍生效的设定」提醒(只列条目名,不含内容)实现
 *
 * 分层约束:
 * - 可被 ChatService / ViewModel 调用
 * - 不引用页面类,不访问网络
 */

import { Lorebook, LorebookEntry } from '../models/Lorebook';
import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import {
  ChatLorebookSticky,
  ChatLorebookStickyRepository
} from '../repositories/ChatLorebookStickyRepository';
import { LorebookService, DEFAULT_MAX_INJECTION_CHARS } from './LorebookService';
import { Logger } from '../utils/Logger';
import { nowMillis } from '../utils/Time';

const LOG_TAG: string = 'LorebookStickyService';

/**
 * 粘滞命中解析结果:条目 + 各自锚点消息 ID(缺省=无锚点,由调用方回退为插到窗口头部)。
 */
export interface StickyResolveResult {
  readonly entries: LorebookEntry[];
  readonly anchors: Record<string, string>;
}

/** 空结果(无命中 / 失败 / 书未启用) */
function emptyStickyResolveResult(): StickyResolveResult {
  return { entries: [], anchors: {} };
}

/** 取消息列表最后一条的 ID 作为锚点;列表为空返回空串(调用方按无锚点处理) */
function lastMessageId(messages: ChatMessage[]): string {
  if (messages.length === 0) {
    return '';
  }
  const last: ChatMessage = messages[messages.length - 1];
  return last.id !== undefined ? last.id : '';
}

export class LorebookStickyService {
  private readonly repository: ChatLorebookStickyRepository;
  private readonly lorebookService: LorebookService;

  constructor(
    repository: ChatLorebookStickyRepository,
    lorebookService: LorebookService
  ) {
    this.repository = repository;
    this.lorebookService = lorebookService;
  }

  /**
   * 获取会话粘滞命中条目 + 各自锚点(供调用方把条目全文插到锚点之后)。
   *
   * - 无记录:对最近消息(书级 scanDepth)做关键词匹配,命中落库为首钉
   * - 已有记录且 lorebookId 一致:本轮匹配命中的新条目按命中顺序追加到
   *   entryIds 尾部(预算内);已存在的不动、不移除 → append-only
   * - 新纳入条目的锚点 = 传入消息的最后一条 ID;插到它之后属纯尾部追加,
   *   不改动已发出的任何内容,因此该块从下一轮起进入稳定前缀缓存
   * - lorebookId 不一致(角色换了绑定书):视为失效,重新首钉
   *
   * 返回按 entryIds 顺序的 enabled 条目(条目被删/禁用时自动缩水,内容实时读取)。
   * 失败不抛错,返回空结果(等价于无命中,不阻塞请求)。
   */
  async ensureStickyEntries(
    chatId: string,
    lorebook: Lorebook,
    messages: ChatMessage[]
  ): Promise<StickyResolveResult> {
    if (chatId.length === 0 || !lorebook.enabled) {
      return emptyStickyResolveResult();
    }
    // 新纳入条目的锚点 = 当时对话的最后一条消息:插到它之后属纯尾部追加,
    // 不改动任何已发出的内容 → 下一轮起该块进入稳定前缀缓存
    const anchorId: string = lastMessageId(messages);
    try {
      const existing: ChatLorebookSticky | null = await this.repository.getByChatId(chatId);
      if (existing !== null && existing.lorebookId === lorebook.id) {
        const nextIds: string[] = this.appendNewHits(existing.entryIds, lorebook, messages);
        const existingIdSet: Set<string> = new Set(existing.entryIds);
        const anchoredIds: Set<string> = new Set();
        const anchors: Record<string, string> = {};
        const prevKeys: string[] = Object.keys(existing.anchors);
        for (let i = 0; i < prevKeys.length; i++) {
          // 只保留仍在集合内的条目锚点(append-only 路径不会移除,此处为兜底)
          if (existingIdSet.has(prevKeys[i])) {
            anchors[prevKeys[i]] = existing.anchors[prevKeys[i]];
            anchoredIds.add(prevKeys[i]);
          }
        }
        if (anchorId.length > 0) {
          for (let i = 0; i < nextIds.length; i++) {
            if (!anchoredIds.has(nextIds[i])) {
              anchors[nextIds[i]] = anchorId;
              anchoredIds.add(nextIds[i]);
            }
          }
        }
        if (nextIds.length !== existing.entryIds.length) {
          await this.repository.upsert({
            chatId: chatId,
            lorebookId: lorebook.id,
            entryIds: nextIds,
            anchors: anchors,
            createdAt: existing.createdAt,
            updatedAt: nowMillis()
          });
          Logger.info(LOG_TAG, 'sticky append chatId.len=' + chatId.length
            + ' book=' + lorebook.id
            + ' entries=' + nextIds.length + '(+' + (nextIds.length - existing.entryIds.length) + ')');
        }
        return {
          entries: this.lorebookService.getEntriesByIdsOrdered(lorebook, nextIds),
          anchors: anchors
        };
      }
      const matched: LorebookEntry[] = this.lorebookService.matchKeywordEntries(lorebook, messages);
      const entryIds: string[] = matched.map((e: LorebookEntry): string => e.id);
      const anchors: Record<string, string> = {};
      if (anchorId.length > 0) {
        for (let i = 0; i < entryIds.length; i++) {
          anchors[entryIds[i]] = anchorId;
        }
      }
      await this.repository.upsert({
        chatId: chatId,
        lorebookId: lorebook.id,
        entryIds: entryIds,
        anchors: anchors,
        createdAt: existing !== null ? existing.createdAt : nowMillis(),
        updatedAt: nowMillis()
      });
      Logger.info(LOG_TAG, 'initial sticky chatId.len=' + chatId.length
        + ' book=' + lorebook.id + ' entries=' + entryIds.length);
      return {
        entries: this.lorebookService.getEntriesByIdsOrdered(lorebook, entryIds),
        anchors: anchors
      };
    } catch (e) {
      Logger.warn(LOG_TAG, 'ensureStickyEntries failed: ' + String(e));
      return emptyStickyResolveResult();
    }
  }

  /**
   * 刷新会话粘滞命中(手动记忆总结成功后 / 长按世界书按钮手动刷新时调用)。
   * 对全部对话消息做全量关键词匹配,命中即纳入(宁多勿少),整体替换原集合。
   * 失败不抛错,保留原集合。
   */
  async refreshStickyEntries(
    chatId: string,
    lorebook: Lorebook,
    messages: ChatMessage[]
  ): Promise<void> {
    if (chatId.length === 0 || !lorebook.enabled) {
      return;
    }
    try {
      const texts: string[] = [];
      for (let i = 0; i < messages.length; i++) {
        const msg: ChatMessage = messages[i];
        if (msg.role === ChatRole.User || msg.role === ChatRole.Assistant) {
          texts.push(msg.content);
        }
      }
      const matched: LorebookEntry[] =
        this.lorebookService.matchKeywordEntriesAgainstTexts(lorebook, texts);
      const existing: ChatLorebookSticky | null = await this.repository.getByChatId(chatId);
      const nextIds: string[] = matched.map((e: LorebookEntry): string => e.id);
      const nextIdSet: Set<string> = new Set(nextIds);
      const anchoredIds: Set<string> = new Set();
      const anchors: Record<string, string> = {};
      if (existing !== null) {
        const prevKeys: string[] = Object.keys(existing.anchors);
        for (let i = 0; i < prevKeys.length; i++) {
          // 仍命中的条目保留原锚点(位置不动,避免无谓的前缀作废);被移出集合的丢弃锚点
          if (nextIdSet.has(prevKeys[i])) {
            anchors[prevKeys[i]] = existing.anchors[prevKeys[i]];
            anchoredIds.add(prevKeys[i]);
          }
        }
      }
      const anchorId: string = lastMessageId(messages);
      if (anchorId.length > 0) {
        for (let i = 0; i < nextIds.length; i++) {
          if (!anchoredIds.has(nextIds[i])) {
            anchors[nextIds[i]] = anchorId;
            anchoredIds.add(nextIds[i]);
          }
        }
      }
      await this.repository.upsert({
        chatId: chatId,
        lorebookId: lorebook.id,
        entryIds: nextIds,
        anchors: anchors,
        createdAt: existing !== null ? existing.createdAt : nowMillis(),
        updatedAt: nowMillis()
      });
      Logger.info(LOG_TAG, 'refresh sticky chatId.len=' + chatId.length
        + ' book=' + lorebook.id + ' entries=' + matched.length);
    } catch (e) {
      Logger.warn(LOG_TAG, 'refreshStickyEntries failed: ' + String(e));
    }
  }

  /**
   * 把本轮新命中的条目追加到已有集合尾部(append-only)。
   * 预算检查:已注入条目内容字符和 + 新条目 ≤ 书级预算(0 用默认 12000)。
   * 已在集合内的条目无论是否仍命中都保留(只增不减)。
   */
  private appendNewHits(
    existingIds: string[],
    lorebook: Lorebook,
    messages: ChatMessage[]
  ): string[] {
    const matched: LorebookEntry[] = this.lorebookService.matchKeywordEntries(lorebook, messages);
    const existingSet: Set<string> = new Set(existingIds);
    // 已注入部分的实际字符量(以书内当前内容实时计算)
    const alreadyInjected: LorebookEntry[] =
      this.lorebookService.getEntriesByIdsOrdered(lorebook, existingIds);
    let totalChars: number = 0;
    for (let i = 0; i < alreadyInjected.length; i++) {
      totalChars += alreadyInjected[i].content.length;
    }
    const budget: number = lorebook.injectionBudgetChars > 0
      ? lorebook.injectionBudgetChars : DEFAULT_MAX_INJECTION_CHARS;
    const nextIds: string[] = [...existingIds];
    for (let i = 0; i < matched.length; i++) {
      const entry: LorebookEntry = matched[i];
      if (existingSet.has(entry.id)) {
        continue;
      }
      if (totalChars + entry.content.length > budget) {
        Logger.info(LOG_TAG, 'sticky budget exhausted, skip entry=' + entry.id
          + ' totalChars=' + totalChars + ' budget=' + budget);
        continue;
      }
      nextIds.push(entry.id);
      existingSet.add(entry.id);
      totalChars += entry.content.length;
    }
    return nextIds;
  }
}
