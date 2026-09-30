/**
 * 代写方向扩展解析测试（arktavern-card-extensions）
 *
 * 验证 extractImpresDirection 的容错解析：
 * - 无 extensions.arktavern.impres.direction 声明 → 空串（代写回退现状）
 * - 类型非法 / 空串（含纯空白）→ 空串
 * - 合法字符串 → 去首尾空白后的原值
 */

import { describe, it, expect } from '@ohos/hypium';
import { extractImpresDirection } from '../main/ets/models/CardImpres';

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
  });
}