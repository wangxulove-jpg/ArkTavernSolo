/**
 * 提示词预设导出格式测试
 *
 * 验证 buildPromptPresetExportJson:
 * - 导出 JSON 可被 parsePromptPresetImport 读回,字段一致(round-trip)
 * - undefined 可选数字字段不写入 JSON
 * - 不导出 id/createdAt/updatedAt(导入时重新生成)
 * - 空列表导出为空数组
 */

import { describe, it, expect } from '@ohos/hypium';
import { buildPromptPresetExportJson, parsePromptPresetImport } from '../main/ets/parser/PromptPresetImportParser';
import { PromptPreset } from '../main/ets/models/PromptPreset';

/** 全字段预设(name/description/systemPrompt + 4 个数字参数)。直接构造字面量,不走 createPromptPreset(host 侧无 crypto API)。 */
function makeFullPreset(): PromptPreset {
  return {
    id: 'preset-full',
    name: '完整预设',
    description: '带全部采样参数',
    systemPrompt: 'You are a helpful assistant.',
    temperature: 0.7,
    topP: 0.9,
    maxOutputTokens: 2048,
    contextWindow: 16384,
    createdAt: 100,
    updatedAt: 100
  };
}

/** 最小预设(仅必填字段,数字参数全部缺省) */
function makeMinimalPreset(): PromptPreset {
  return {
    id: 'preset-min',
    name: '最小预设',
    description: '',
    systemPrompt: '仅系统提示词',
    createdAt: 100,
    updatedAt: 100
  };
}

export default function presetExportTest() {
  describe('PresetExport', () => {
    it('round_trip_fields_preserved', 0, () => {
      const presets: PromptPreset[] = [makeFullPreset(), makeMinimalPreset()];
      const json: string = buildPromptPresetExportJson(presets);
      const parsed = parsePromptPresetImport(json, '');

      expect(parsed.length).assertEqual(2);

      // 第一条:全部字段一致
      expect(parsed[0].name).assertEqual('完整预设');
      expect(parsed[0].description).assertEqual('带全部采样参数');
      expect(parsed[0].systemPrompt).assertEqual('You are a helpful assistant.');
      expect(parsed[0].temperature).assertEqual(0.7);
      expect(parsed[0].topP).assertEqual(0.9);
      expect(parsed[0].maxOutputTokens).assertEqual(2048);
      expect(parsed[0].contextWindow).assertEqual(16384);

      // 第二条:必填字段一致,数字参数缺省为 undefined
      expect(parsed[1].name).assertEqual('最小预设');
      expect(parsed[1].description).assertEqual('');
      expect(parsed[1].systemPrompt).assertEqual('仅系统提示词');
      expect(parsed[1].temperature).assertUndefined();
      expect(parsed[1].contextWindow).assertUndefined();
    });

    it('optional_fields_omitted_when_undefined', 0, () => {
      const json: string = buildPromptPresetExportJson([makeMinimalPreset()]);
      expect(json.includes('temperature')).assertFalse();
      expect(json.includes('topP')).assertFalse();
      expect(json.includes('maxOutputTokens')).assertFalse();
      expect(json.includes('contextWindow')).assertFalse();
    });

    it('id_and_timestamps_not_exported', 0, () => {
      const json: string = buildPromptPresetExportJson([makeFullPreset()]);
      expect(json.includes('"id"')).assertFalse();
      expect(json.includes('createdAt')).assertFalse();
      expect(json.includes('updatedAt')).assertFalse();
    });

    it('empty_list_exports_empty_array', 0, () => {
      const json: string = buildPromptPresetExportJson([]);
      expect(json).assertEqual('[]');
    });
  });
}
