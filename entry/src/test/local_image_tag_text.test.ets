/**
 * 本地图片「标签 = 提示词预设正文」文本操作 + v50 迁移校验
 *
 * 覆盖:
 * - 条目行格式:`- 名字` / `- 名字：描述`
 * - upsert:追加 / 替换(保留位置) / 同名行收敛 / 描述更新
 * - remove:删除条目行且不影响其它内容;不存在时幂等
 * - listTagEntryNames / hasTagEntry:分隔符兼容(全角/半角/无)、非条目行忽略、精确匹配不误判
 * - v50 迁移:版本号、迁移链、schema 前缀逐字节不变且只追加新 DDL
 *
 * 全部为纯函数层用例:不碰 DB / crypto。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  TAG_PRESET_HEADER,
  buildTagEntryLine,
  upsertTagEntry,
  removeTagEntry,
  listTagEntryNames,
  hasTagEntry,
  hasTagPresetHeader,
  ensureTagPresetHeader
} from '../main/ets/utils/LocalImageTagText';
import { getSchemaStatements } from '../main/ets/database/DatabaseSchema';
import {
  MigrationPath,
  buildMigrationPath,
  createV49ToV50Migration,
  createV50ToV51Migration
} from '../main/ets/database/DatabaseMigration';
import { DATABASE_VERSION } from '../main/ets/database/DatabaseConstants';

export default function localImageTagTextTest() {
  describe('localImageTagText', () => {

    // ===== 条目行 =====

    it('entry_line_with_and_without_description', 0, () => {
      expect(buildTagEntryLine('笑', '角色开心大笑')).assertEqual('- 笑：角色开心大笑');
      expect(buildTagEntryLine('笑', '')).assertEqual('- 笑');
      expect(buildTagEntryLine(' 笑 ', '  描述  ')).assertEqual('- 笑：描述');
    });

    // ===== upsert =====

    it('upsert_appends_to_empty_text', 0, () => {
      expect(upsertTagEntry('', '笑', '开心')).assertEqual('- 笑：开心');
    });

    it('upsert_appends_after_existing_content', 0, () => {
      const text: string = '请优先选择下列表情：';
      const next: string = upsertTagEntry(text, '笑', '开心');
      expect(next).assertEqual('请优先选择下列表情：\n- 笑：开心');
    });

    it('upsert_keeps_trailing_newline_single', 0, () => {
      const next: string = upsertTagEntry('- 哭：难过\n', '笑', '开心');
      expect(next).assertEqual('- 哭：难过\n- 笑：开心');
    });

    it('upsert_replaces_existing_entry_and_keeps_position', 0, () => {
      const text: string = '- 哭：难过\n- 笑：旧描述\n- 怒：生气';
      const next: string = upsertTagEntry(text, '笑', '新描述');
      expect(next).assertEqual('- 哭：难过\n- 笑：新描述\n- 怒：生气');
    });

    it('upsert_updates_description_to_empty', 0, () => {
      const next: string = upsertTagEntry('- 笑：旧描述', '笑', '');
      expect(next).assertEqual('- 笑');
    });

    it('upsert_collapses_duplicate_same_name_lines', 0, () => {
      const text: string = '- 笑：一\n- 哭：难过\n- 笑：二';
      const next: string = upsertTagEntry(text, '笑', '三');
      expect(next).assertEqual('- 笑：三\n- 哭：难过');
    });

    it('upsert_ignores_non_entry_lines', 0, () => {
      const text: string = '说明文字\n- 笑：开心';
      const next: string = upsertTagEntry(text, '哭', '难过');
      expect(next).assertEqual('说明文字\n- 笑：开心\n- 哭：难过');
    });

    // ===== remove =====

    it('remove_deletes_entry_and_keeps_others', 0, () => {
      const text: string = '- 笑：开心\n- 哭：难过\n尾注';
      expect(removeTagEntry(text, '哭')).assertEqual('- 笑：开心\n尾注');
    });

    it('remove_is_idempotent_when_absent', 0, () => {
      const text: string = '- 笑：开心';
      expect(removeTagEntry(text, '哭')).assertEqual('- 笑：开心');
    });

    it('remove_trims_blank_edges', 0, () => {
      const text: string = '- 笑：开心\n\n';
      expect(removeTagEntry(text, '笑')).assertEqual('');
    });

    // ===== 反查 =====

    it('list_names_handles_separators_and_skips_plain_lines', 0, () => {
      const text: string = '提示\n- 笑：开心\n- 哭\n- 怒:生气\n普通行';
      const names: string[] = listTagEntryNames(text);
      expect(names.join(',')).assertEqual('笑,哭,怒');
    });

    it('list_names_dedupes', 0, () => {
      const text: string = '- 笑：一\n- 笑：二';
      expect(listTagEntryNames(text).length).assertEqual(1);
    });

    it('has_entry_requires_exact_name_match', 0, () => {
      const text: string = '- 笑脸：开心';
      expect(hasTagEntry(text, '笑脸')).assertTrue();
      expect(hasTagEntry(text, '笑')).assertFalse();
      expect(hasTagEntry(text, '哭')).assertFalse();
    });

    it('roundtrip_upsert_then_remove_leaves_original', 0, () => {
      const original: string = '以下是可用表情：';
      const added: string = upsertTagEntry(original, '笑', '开心');
      expect(removeTagEntry(added, '笑')).assertEqual(original);
    });

    // ===== 固定开头(新建标签时写入,告诉模型如何引用图片) =====

    it('header_lines_are_not_treated_as_image_entries', 0, () => {
      // 开头里的图片语法示例不得被反查成图片条目
      expect(listTagEntryNames(TAG_PRESET_HEADER).length).assertEqual(0);
      expect(hasTagEntry(TAG_PRESET_HEADER, '笑')).assertFalse();
      expect(hasTagPresetHeader(TAG_PRESET_HEADER)).assertTrue();
    });

    it('ensure_header_prepends_once_and_is_idempotent', 0, () => {
      expect(ensureTagPresetHeader('')).assertEqual(TAG_PRESET_HEADER);
      expect(ensureTagPresetHeader('   ')).assertEqual(TAG_PRESET_HEADER);
      const once: string = ensureTagPresetHeader('- 笑：开心');
      expect(once).assertEqual(TAG_PRESET_HEADER + '\n- 笑：开心');
      // 已有开头 → 原样返回(补齐旧标签时不会重复插入)
      expect(ensureTagPresetHeader(once)).assertEqual(once);
    });

    it('header_stays_first_after_upsert', 0, () => {
      const next: string = upsertTagEntry(ensureTagPresetHeader(''), '笑', '开心');
      expect(next.indexOf(TAG_PRESET_HEADER) === 0).assertTrue();
      expect(listTagEntryNames(next).join(',')).assertEqual('笑');
    });

    it('header_survives_removing_last_entry', 0, () => {
      const text: string = upsertTagEntry(ensureTagPresetHeader(''), '笑', '开心');
      expect(removeTagEntry(text, '笑')).assertEqual(TAG_PRESET_HEADER);
    });
  });

  describe('databaseV50Migration', () => {

    it('database_version_is_51_and_v50_chain_has_step', 0, () => {
      expect(DATABASE_VERSION).assertEqual(51);
      const path: MigrationPath = buildMigrationPath(49, 50, [createV49ToV50Migration()]);
      expect(path.steps.length).assertEqual(1);
      expect(path.steps[0].fromVersion).assertEqual(49);
      expect(path.steps[0].toVersion).assertEqual(50);
    });

    it('v50_schema_appends_one_statement_to_v49', 0, () => {
      const v48: string[] = getSchemaStatements(48);
      const v49: string[] = getSchemaStatements(49);
      const v50: string[] = getSchemaStatements(50);
      expect(v48.length > 0).assertTrue();
      // v49(v48 + 5 条分类 DDL)与 v50(v49 + 1 条 ALTER)都只追加,前缀逐字节不变
      expect(v49.length).assertEqual(v48.length + 5);
      expect(v50.length).assertEqual(v49.length + 1);
      for (let i = 0; i < v49.length; i++) {
        expect(v50[i]).assertEqual(v49[i]);
      }
      expect(v50[v49.length].indexOf('description') >= 0).assertTrue();
    });
  });

  describe('databaseV51Migration', () => {

    it('v51_chain_has_step_from_50', 0, () => {
      const path: MigrationPath = buildMigrationPath(50, 51, [createV50ToV51Migration()]);
      expect(path.steps.length).assertEqual(1);
      expect(path.steps[0].fromVersion).assertEqual(50);
      expect(path.steps[0].toVersion).assertEqual(51);
    });

    it('v51_schema_appends_one_statement_to_v50', 0, () => {
      const v50: string[] = getSchemaStatements(50);
      const v51: string[] = getSchemaStatements(51);
      expect(v50.length > 0).assertTrue();
      // v51 只在 v50 之后追加 1 条 ALTER;前缀逐字节不变
      expect(v51.length).assertEqual(v50.length + 1);
      for (let i = 0; i < v50.length; i++) {
        expect(v51[i]).assertEqual(v50[i]);
      }
      expect(v51[v50.length].indexOf('media_type') >= 0).assertTrue();
    });
  });
}