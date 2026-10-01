/**
 * 代写方向扩展解析与写入测试（arktavern-card-extensions）
 *
 * 验证 extractImpresDirection 的容错解析：
 * - 无 extensions.arktavern.impres.direction 声明 → 空串（代写回退现状）
 * - 类型非法 / 空串（含纯空白）→ 空串
 * - 合法字符串 → 去首尾空白后的原值
 *
 * 验证 applyImpresDirection 的不可变写入：
 * - 写入 / 覆盖（trim）/ 清空（移除 impres，必要时整键移除）
 * - 其余顶层键与 arktavern / impres 下的其他键原样保留，不改原对象
 */

import { describe, it, expect } from '@ohos/hypium';
import { applyImpresDirection, extractImpresDirection } from '../main/ets/models/CardImpres';

/** 构造 { arktavern: { impres: { direction } } } */
function makeExtensions(direction: Object): Record<string, Object> {
  const impres: Record<string, Object> = {};
  impres['direction'] = direction;
  const ark: Record<string, Object> = {};
  ark['impres'] = impres;
  const ext: Record<string, Object> = {};
  ext['arktavern'] = ark;
  return ext;
}

/** 取 arktavern 子对象(测试辅助;不存在/非对象返回空对象) */
function arkOf(ext: Record<string, Object>): Record<string, Object> {
  const ark: Object | undefined = ext['arktavern'];
  return ark !== undefined && ark instanceof Object ? ark as Record<string, Object> : {};
}

/** 取 impres 子对象(测试辅助) */
function impresOf(ext: Record<string, Object>): Record<string, Object> {
  const impres: Object | undefined = arkOf(ext)['impres'];
  return impres !== undefined && impres instanceof Object ? impres as Record<string, Object> : {};
}

export default function cardImpresTest() {
  describe('CardImpres', () => {
    it('no_arktavern_returns_empty', 0, () => {
      const r: Record<string, Object> = {};
      expect(extractImpresDirection(r)).assertEqual('');
    });

    it('arktavern_not_object_returns_empty', 0, () => {
      const ext: Record<string, Object> = {};
      ext['arktavern'] = 'not-an-object';
      expect(extractImpresDirection(ext)).assertEqual('');
    });

    it('no_impres_returns_empty', 0, () => {
      const ark: Record<string, Object> = {};
      ark['bridge_version'] = 1;
      const ext: Record<string, Object> = {};
      ext['arktavern'] = ark;
      expect(extractImpresDirection(ext)).assertEqual('');
    });

    it('impres_not_object_returns_empty', 0, () => {
      const ark: Record<string, Object> = {};
      ark['impres'] = 'not-an-object';
      const ext: Record<string, Object> = {};
      ext['arktavern'] = ark;
      expect(extractImpresDirection(ext)).assertEqual('');
    });

    it('direction_not_string_returns_empty', 0, () => {
      expect(extractImpresDirection(makeExtensions(123))).assertEqual('');
      expect(extractImpresDirection(makeExtensions(true))).assertEqual('');
    });

    it('blank_direction_returns_empty', 0, () => {
      expect(extractImpresDirection(makeExtensions(''))).assertEqual('');
      expect(extractImpresDirection(makeExtensions('  \n\t '))).assertEqual('');
    });

    it('valid_direction_returns_trimmed_value', 0, () => {
      expect(extractImpresDirection(makeExtensions('  故事背景与发展方向  ')))
        .assertEqual('故事背景与发展方向');
    });

    it('unknown_subfields_tolerated', 0, () => {
      const impres: Record<string, Object> = {};
      impres['direction'] = '方向文本';
      impres['future_field'] = 'x';
      const ark: Record<string, Object> = {};
      ark['impres'] = impres;
      ark['unknown'] = 42;
      const ext: Record<string, Object> = {};
      ext['arktavern'] = ark;
      expect(extractImpresDirection(ext)).assertEqual('方向文本');
    });

    it('apply_writes_direction_into_empty_extensions', 0, () => {
      const result: Record<string, Object> = applyImpresDirection({}, '新的方向');
      expect(extractImpresDirection(result)).assertEqual('新的方向');
    });

    it('apply_preserves_other_keys', 0, () => {
      const fields: Record<string, Object>[] = [];
      const status: Record<string, Object> = {};
      status['fields'] = fields;
      const ark: Record<string, Object> = {};
      ark['bridge_version'] = 2;
      ark['status'] = status;
      const ext: Record<string, Object> = {};
      ext['arktavern'] = ark;
      ext['regex_scripts'] = 'keep-me';
      const result: Record<string, Object> = applyImpresDirection(ext, '方向A');
      expect(extractImpresDirection(result)).assertEqual('方向A');
      expect(arkOf(result)['bridge_version']).assertEqual(2);
      expect(arkOf(result)['status'] === status).assertEqual(true);
      expect(result['regex_scripts']).assertEqual('keep-me');
    });

    it('apply_overwrites_existing_direction_and_trims', 0, () => {
      const result: Record<string, Object> = applyImpresDirection(makeExtensions('旧方向'), '  新方向  ');
      expect(extractImpresDirection(result)).assertEqual('新方向');
    });

    it('apply_empty_direction_removes_only_direction', 0, () => {
      const impres: Record<string, Object> = {};
      impres['direction'] = '要清掉的方向';
      impres['future'] = 'keep';
      const ark: Record<string, Object> = {};
      ark['impres'] = impres;
      ark['bridge_version'] = 1;
      const ext: Record<string, Object> = {};
      ext['arktavern'] = ark;
      const result: Record<string, Object> = applyImpresDirection(ext, '   ');
      expect(extractImpresDirection(result)).assertEqual('');
      expect(arkOf(result)['bridge_version']).assertEqual(1);
      expect(impresOf(result)['future']).assertEqual('keep');
    });

    it('apply_empty_direction_drops_impres_key_when_alone', 0, () => {
      const result: Record<string, Object> = applyImpresDirection(makeExtensions('方向'), '');
      const impres: Object | undefined = arkOf(result)['impres'];
      expect(impres === undefined).assertEqual(true);
    });

    it('apply_does_not_mutate_source', 0, () => {
      const ext: Record<string, Object> = makeExtensions('原方向');
      const result: Record<string, Object> = applyImpresDirection(ext, '新方向');
      expect(extractImpresDirection(ext)).assertEqual('原方向');
      expect(extractImpresDirection(result)).assertEqual('新方向');
    });

    it('apply_rebuilds_when_arktavern_not_object', 0, () => {
      const ext: Record<string, Object> = {};
      ext['arktavern'] = 'not-an-object';
      const result: Record<string, Object> = applyImpresDirection(ext, '方向B');
      expect(extractImpresDirection(result)).assertEqual('方向B');
    });
  });
}