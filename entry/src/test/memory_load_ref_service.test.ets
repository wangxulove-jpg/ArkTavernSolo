/**
 * MemoryLoadRefService 单元测试(v46 按需加载记忆引用)
 *
 * 用继承式 FakeAppPreferences 模拟偏好存储(零框架依赖,类型安全),
 * 覆盖:
 * - getRefs 无数据默认空数组 / 读回已存引用
 * - addRef 同 memoryId 去重更新锚点(不新增)
 * - addRef 总量上限拒绝
 * - removeRef / hasRef / clearRefs
 * - 损坏 JSON 兜底返回空数组
 * - 空 chatId 安全短路
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  MemoryLoadRefService,
  MemoryLoadRef,
  MEMORY_LOAD_REF_LIMIT
} from '../main/ets/services/MemoryLoadRefService';
import { AppPreferences } from '../main/ets/storage/AppPreferences';

/** 内存版 AppPreferences(重写 getString/putString/delete,不触碰平台存储)。 */
class FakeAppPreferences extends AppPreferences {
  private readonly store: Map<string, string> = new Map<string, string>();

  constructor() {
    super('fake_test_store');
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

  /** 测试辅助:直接写入原始字符串(模拟损坏数据)。 */
  putRaw(key: string, raw: string): void {
    this.store.set(key, raw);
  }
}

export default function memoryLoadRefServiceTest() {
  describe('MemoryLoadRefService', () => {
    it('get_refs_empty_by_default', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      const refs: MemoryLoadRef[] = await service.getRefs('chat1');
      expect(refs.length).assertEqual(0);
    });

    it('add_ref_then_get_refs_reads_back', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      const ok: boolean = await service.addRef('chat1', 'mem-1', 'msg-10');
      expect(ok).assertTrue();
      const refs: MemoryLoadRef[] = await service.getRefs('chat1');
      expect(refs.length).assertEqual(1);
      expect(refs[0].memoryId).assertEqual('mem-1');
      expect(refs[0].anchorMessageId).assertEqual('msg-10');
      expect(refs[0].addedAt).assertLarger(0);
    });

    it('add_ref_same_memory_updates_anchor_not_duplicated', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      await service.addRef('chat1', 'mem-1', 'msg-10');
      await service.addRef('chat1', 'mem-1', 'msg-20');
      const refs: MemoryLoadRef[] = await service.getRefs('chat1');
      expect(refs.length).assertEqual(1);
      expect(refs[0].anchorMessageId).assertEqual('msg-20');
    });

    it('add_ref_rejects_over_limit', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      let accepted: number = 0;
      for (let i = 0; i < MEMORY_LOAD_REF_LIMIT; i++) {
        const ok: boolean = await service.addRef('chat1', 'mem-' + i, 'msg-' + i);
        if (ok) {
          accepted++;
        }
      }
      expect(accepted).assertEqual(MEMORY_LOAD_REF_LIMIT);
      const rejected: boolean = await service.addRef('chat1', 'mem-over', 'msg-over');
      expect(rejected).assertFalse();
    });

    it('remove_ref_removes_only_target', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      await service.addRef('chat1', 'mem-1', 'msg-1');
      await service.addRef('chat1', 'mem-2', 'msg-2');
      await service.removeRef('chat1', 'mem-1');
      const refs: MemoryLoadRef[] = await service.getRefs('chat1');
      expect(refs.length).assertEqual(1);
      expect(refs[0].memoryId).assertEqual('mem-2');
    });

    it('has_ref_true_after_add_false_after_remove', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      await service.addRef('chat1', 'mem-1', 'msg-1');
      expect(await service.hasRef('chat1', 'mem-1')).assertTrue();
      await service.removeRef('chat1', 'mem-1');
      expect(await service.hasRef('chat1', 'mem-1')).assertFalse();
    });

    it('corrupted_json_returns_empty', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      pref.putRaw('chat_memrefs_chat1', '{broken-json');
      const refs: MemoryLoadRef[] = await service.getRefs('chat1');
      expect(refs.length).assertEqual(0);
    });

    it('empty_chat_id_is_safe_short_circuit', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      expect((await service.getRefs('')).length).assertEqual(0);
      expect(await service.addRef('', 'mem-1', 'msg-1')).assertFalse();
      await service.removeRef('', 'mem-1');
      await service.clearRefs('');
    });

    it('clear_refs_empties_all', 0, async () => {
      const pref: FakeAppPreferences = new FakeAppPreferences();
      const service: MemoryLoadRefService = new MemoryLoadRefService(pref);
      await service.addRef('chat1', 'mem-1', 'msg-1');
      await service.clearRefs('chat1');
      expect((await service.getRefs('chat1')).length).assertEqual(0);
    });
  });
}
