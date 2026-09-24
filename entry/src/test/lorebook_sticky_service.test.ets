/**
 * LorebookStickyService 单元测试(v46 粘滞按需世界书)
 *
 * 用继承式 Fake Repository 模拟持久层(内存 Map,零平台依赖),
 * 真实 LorebookService(匹配/按序取条目为纯方法,构造不触碰 RDB)。
 * 注意:测试数据用对象字面量构造(不用 createLorebook/createLorebookEntry,
 * 它们内部调 generateUuid 依赖平台 crypto,本地测试环境不可用)。
 *
 * 覆盖:
 * - 无记录时首钉落库并返回命中条目
 * - 新命中追加到集合尾部(append-only 保序),已存在条目位置不动
 * - 预算满后新条目不进集合
 * - 换书(lorebookId 不一致)重置首钉
 * - 条目禁用后返回集合自动缩水
 * - refreshStickyEntries 全量重算整体替换
 * - 失败(repository 抛错)返回空数组不抛出
 */

import { describe, it, expect } from '@ohos/hypium';
import { LorebookStickyService } from '../main/ets/services/LorebookStickyService';
import {
  ChatLorebookStickyRepository,
  ChatLorebookSticky
} from '../main/ets/repositories/ChatLorebookStickyRepository';
import { LorebookService } from '../main/ets/services/LorebookService';
import { LorebookRepository } from '../main/ets/repositories/LorebookRepository';
import { LorebookSelectionStore } from '../main/ets/storage/LorebookSelectionStore';
import { DbHelper } from '../main/ets/database/DbHelper';
import { AppPreferences } from '../main/ets/storage/AppPreferences';
import {
  Lorebook,
  LorebookEntry,
  LorebookActivationMode,
  LorebookPosition
} from '../main/ets/models/Lorebook';
import { ChatMessage, createChatMessage } from '../main/ets/models/ChatMessage';
import { ChatRole } from '../main/ets/models/ChatRole';

/** 内存版 AppPreferences(与 memory_load_ref_service.test 同模式)。 */
class FakeAppPreferences extends AppPreferences {
  private readonly store: Map<string, string> = new Map<string, string>();

  constructor() {
    super('fake_sticky_test_store');
  }

  async getString(key: string, defValue: string): Promise<string> {
    const v: string | undefined = this.store.get(key);
    return v !== undefined ? v : defValue;
  }

  async putString(key: string, value: string): Promise<void> {
    this.store.set(key, value);
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }
}

/** 内存版粘滞 Repository:覆写全部持久化方法,不触碰 RDB。 */
class FakeStickyRepository extends ChatLorebookStickyRepository {
  private readonly store: Map<string, ChatLorebookSticky> = new Map<string, ChatLorebookSticky>();
  /** 模拟故障开关:getByChatId 抛错 */
  public failOnGet: boolean = false;

  constructor() {
    super(new DbHelper());
  }

  async getByChatId(chatId: string): Promise<ChatLorebookSticky | null> {
    if (this.failOnGet) {
      throw new Error('simulated repository failure');
    }
    return this.store.get(chatId) ?? null;
  }

  async upsert(sticky: ChatLorebookSticky): Promise<void> {
    this.store.set(sticky.chatId, sticky);
  }

  async removeByChatId(chatId: string): Promise<void> {
    this.store.delete(chatId);
  }
}

/** 构建测试用 LorebookService(纯方法路径,无需 initialize)。 */
function buildLorebookService(): LorebookService {
  const db: DbHelper = new DbHelper();
  return new LorebookService(
    new LorebookRepository(db),
    new LorebookSelectionStore(new FakeAppPreferences())
  );
}

function makeEntry(id: string, name: string, key: string, content: string,
  enabled: boolean = true): LorebookEntry {
  return {
    id: id,
    name: name,
    keys: [key],
    secondaryKeys: [],
    regex: '',
    content: content,
    enabled: enabled,
    constant: false,
    selective: false,
    position: LorebookPosition.BeforeCharacter,
    priority: 0,
    createdAt: 1000,
    updatedAt: 1000
  };
}

let bookSeq: number = 0;

/** 构建测试书:三个关键词触发条目(阿尔法/贝塔/伽马)。字面量构造,避开 generateUuid。 */
function buildTestBook(budget: number = 1000, enabled: boolean = true): Lorebook {
  bookSeq++;
  return {
    id: 'test-book-' + bookSeq,
    name: '测试书',
    description: 'desc',
    enabled: enabled,
    activationMode: LorebookActivationMode.StickyOnDemand,
    injectionBudgetChars: budget,
    scanDepth: 10,
    entries: [
      makeEntry('e-alpha', '阿尔法', '阿尔法', '阿尔法的内容'),
      makeEntry('e-beta', '贝塔', '贝塔', '贝塔的内容'),
      makeEntry('e-gamma', '伽马', '伽马', '伽马的内容')
    ],
    createdAt: 1000,
    updatedAt: 1000
  };
}

function userMsg(id: string, content: string): ChatMessage {
  return createChatMessage(id, ChatRole.User, content, Date.now());
}

function idsOf(entries: LorebookEntry[]): string {
  return entries.map((e: LorebookEntry): string => e.name).join(',');
}

export default function lorebookStickyServiceTest() {
  describe('LorebookStickyService', () => {
    it('first_pin_persists_matched_entries', 0, async () => {
      const repo: FakeStickyRepository = new FakeStickyRepository();
      const service: LorebookStickyService =
        new LorebookStickyService(repo, buildLorebookService());
      const book: Lorebook = buildTestBook();
      const messages: ChatMessage[] = [userMsg('m1', '我们聊聊阿尔法吧')];

      const entries: LorebookEntry[] = await service.ensureStickyEntries('chat1', book, messages);
      expect(idsOf(entries)).assertEqual('阿尔法');

      // 落库验证:记录的 lorebookId 与条目 ID 一致
      const saved: ChatLorebookSticky | null = await repo.getByChatId('chat1');
      expect(saved !== null).assertTrue();
      expect(saved!.lorebookId).assertEqual(book.id);
      expect(saved!.entryIds.length).assertEqual(1);
    });

    it('new_hits_appended_in_order_existing_unchanged', 0, async () => {
      const repo: FakeStickyRepository = new FakeStickyRepository();
      const service: LorebookStickyService =
        new LorebookStickyService(repo, buildLorebookService());
      const book: Lorebook = buildTestBook();

      // 首轮:命中阿尔法
      await service.ensureStickyEntries('chat1', book, [userMsg('m1', '阿尔法登场')]);
      // 次轮:命中贝塔与伽马,阿尔法未再出现(但已粘滞保留,位置不动)
      const entries: LorebookEntry[] = await service.ensureStickyEntries('chat1', book,
        [userMsg('m2', '贝塔和伽马来了')]);

      // append-only:阿尔法仍在首位,新命中按匹配顺序追加
      expect(idsOf(entries)).assertEqual('阿尔法,贝塔,伽马');
    });

    it('budget_exhausted_excludes_new_entry', 0, async () => {
      const repo: FakeStickyRepository = new FakeStickyRepository();
      const service: LorebookStickyService =
        new LorebookStickyService(repo, buildLorebookService());
      // 预算 15:'阿尔法的内容'(6)+'贝塔的内容'(6)=12 ≤ 15,加'伽马的内容'(6)=18 > 15
      const book: Lorebook = buildTestBook(15);

      await service.ensureStickyEntries('chat1', book, [userMsg('m1', '阿尔法和贝塔')]);
      const entries: LorebookEntry[] = await service.ensureStickyEntries('chat1', book,
        [userMsg('m2', '阿尔法和贝塔和伽马')]);
      expect(idsOf(entries)).assertEqual('阿尔法,贝塔');
    });

    it('book_switch_resets_sticky_set', 0, async () => {
      const repo: FakeStickyRepository = new FakeStickyRepository();
      const service: LorebookStickyService =
        new LorebookStickyService(repo, buildLorebookService());
      const book1: Lorebook = buildTestBook();
      await service.ensureStickyEntries('chat1', book1, [userMsg('m1', '阿尔法登场')]);

      // 换书:lorebookId 不一致 → 重新首钉
      const book2: Lorebook = buildTestBook();
      const entries: LorebookEntry[] = await service.ensureStickyEntries('chat1', book2,
        [userMsg('m2', '贝塔登场')]);
      expect(idsOf(entries)).assertEqual('贝塔');

      const saved: ChatLorebookSticky | null = await repo.getByChatId('chat1');
      expect(saved !== null).assertTrue();
      expect(saved!.lorebookId).assertEqual(book2.id);
    });

    it('disabled_entry_shrinks_from_result', 0, async () => {
      const repo: FakeStickyRepository = new FakeStickyRepository();
      const service: LorebookStickyService =
        new LorebookStickyService(repo, buildLorebookService());
      const book: Lorebook = buildTestBook();
      await service.ensureStickyEntries('chat1', book,
        [userMsg('m1', '阿尔法和贝塔')]);

      // 同 id 的书,阿尔法条目被禁用:返回集合实时缩水(字面量构造,id 与原书一致)
      const bookDisabled: Lorebook = {
        id: book.id,
        name: book.name,
        description: book.description,
        enabled: book.enabled,
        activationMode: book.activationMode,
        injectionBudgetChars: book.injectionBudgetChars,
        scanDepth: book.scanDepth,
        entries: [
          makeEntry('e-alpha', '阿尔法', '阿尔法', '阿尔法的内容', false),
          book.entries[1],
          book.entries[2]
        ],
        createdAt: book.createdAt,
        updatedAt: book.updatedAt
      };
      const entries: LorebookEntry[] = await service.ensureStickyEntries('chat1', bookDisabled,
        [userMsg('m2', '继续聊')]);
      expect(idsOf(entries)).assertEqual('贝塔');
    });

    it('refresh_replaces_set_with_full_match', 0, async () => {
      const repo: FakeStickyRepository = new FakeStickyRepository();
      const service: LorebookStickyService =
        new LorebookStickyService(repo, buildLorebookService());
      const book: Lorebook = buildTestBook();
      await service.ensureStickyEntries('chat1', book, [userMsg('m1', '阿尔法登场')]);

      // 手动总结刷新:全量消息重算(阿尔法的消息已滑出扫描窗口,但全量匹配仍命中)
      await service.refreshStickyEntries('chat1', book,
        [userMsg('m1', '阿尔法登场'), userMsg('m2', '贝塔登场')]);

      const entries: LorebookEntry[] = await service.ensureStickyEntries('chat1', book,
        [userMsg('m3', '继续')]);
      expect(idsOf(entries)).assertEqual('阿尔法,贝塔');
    });

    it('repository_failure_returns_empty_not_throw', 0, async () => {
      const repo: FakeStickyRepository = new FakeStickyRepository();
      repo.failOnGet = true;
      const service: LorebookStickyService =
        new LorebookStickyService(repo, buildLorebookService());
      const book: Lorebook = buildTestBook();

      const entries: LorebookEntry[] =
        await service.ensureStickyEntries('chat1', book, [userMsg('m1', '阿尔法')]);
      expect(entries.length).assertEqual(0);
    });

    it('empty_chatid_or_disabled_book_returns_empty', 0, async () => {
      const repo: FakeStickyRepository = new FakeStickyRepository();
      const service: LorebookStickyService =
        new LorebookStickyService(repo, buildLorebookService());
      const book: Lorebook = buildTestBook(1000, false);

      const entries: LorebookEntry[] =
        await service.ensureStickyEntries('chat1', book, [userMsg('m1', '阿尔法')]);
      expect(entries.length).assertEqual(0);

      const enabledBook: Lorebook = buildTestBook();
      const emptyIdEntries: LorebookEntry[] =
        await service.ensureStickyEntries('', enabledBook, [userMsg('m2', '阿尔法')]);
      expect(emptyIdEntries.length).assertEqual(0);
    });
  });
}
