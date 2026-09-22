/**
 * 声明式状态 Schema 解析测试(arktavern-card-extensions v1)
 *
 * 验证 extractStatusSchema 的容错解析:
 * - 无 extensions.arktavern.status 声明 → 空数组(状态功能禁用)
 * - fields 数组 → 只提取 name 非空的合法子项
 * - desc / type / locked 字段正确解析,缺省有默认值
 */

import { describe, it, expect } from '@ohos/hypium';
import { extractStatusSchema, ChatStatusSchemaEntry } from '../main/ets/models/ChatStatusState';

function field(name: string, desc: string, type: string, locked: boolean): Record<string, Object> {
  const f: Record<string, Object> = {};
  if (name.length > 0) {
    f['name'] = name;
  }
  f['desc'] = desc;
  f['type'] = type;
  f['locked'] = locked;
  return f;
}

/** 构造 { arktavern: { status: { fields: [...] } } } */
function makeExtensions(fields: Record<string, Object>[]): Record<string, Object> {
  const status: Record<string, Object> = {};
  status['fields'] = fields;
  const ark: Record<string, Object> = {};
  ark['status'] = status;
  const ext: Record<string, Object> = {};
  ext['arktavern'] = ark;
  return ext;
}

export default function statusSchemaTest() {
  describe('StatusSchema', () => {
    it('no_arktavern_returns_empty', 0, () => {
      const r: Record<string, Object> = {};
      expect(extractStatusSchema(r).length).assertEqual(0);
    });

    it('arktavern_without_status_returns_empty', 0, () => {
      const ark: Record<string, Object> = { 'user_name_override': '哥' };
      const ext: Record<string, Object> = {};
      ext['arktavern'] = ark;
      expect(extractStatusSchema(ext).length).assertEqual(0);
    });

    it('status_not_object_returns_empty', 0, () => {
      const ark: Record<string, Object> = {};
      ark['status'] = 'not-an-object';
      const ext: Record<string, Object> = {};
      ext['arktavern'] = ark;
      expect(extractStatusSchema(ext).length).assertEqual(0);
    });

    it('status_fields_not_array_returns_empty', 0, () => {
      const ark: Record<string, Object> = {};
      const status: Record<string, Object> = {};
      status['fields'] = 'not-array';
      ark['status'] = status;
      const ext: Record<string, Object> = {};
      ext['arktavern'] = ark;
      expect(extractStatusSchema(ext).length).assertEqual(0);
    });

    it('extracts_valid_fields_and_skips_invalid', 0, () => {
      const fields: Record<string, Object>[] = [
        field('金币', '当前金币', 'number', false),
        field('', '空名字应跳过', '', false)
      ];
      const schema: ChatStatusSchemaEntry[] = extractStatusSchema(makeExtensions(fields));
      expect(schema.length).assertEqual(1);
      expect(schema[0].name).assertEqual('金币');
      expect(schema[0].desc).assertEqual('当前金币');
      expect(schema[0].type).assertEqual('number');
      expect(schema[0].locked).assertEqual(false);
    });

    it('omit_optional_fields_use_defaults', 0, () => {
      const onlyName: Record<string, Object> = {};
      onlyName['name'] = '炼金石联动';
      const schema: ChatStatusSchemaEntry[] = extractStatusSchema(makeExtensions([onlyName]));
      expect(schema.length).assertEqual(1);
      expect(schema[0].desc).assertEqual('');
      expect(schema[0].type).assertEqual('');
      expect(schema[0].locked).assertEqual(false);
    });
  });
}