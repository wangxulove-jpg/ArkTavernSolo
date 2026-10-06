/**
 * 本地图片库(模型 + 清单构建 + 预设作用域)纯函数测试
 *
 * 覆盖:
 * - 图片名归一化/合法性/错误文案
 * - 清单 System Prompt:空集、稳定排序(与输入顺序无关)、逐字节可复现、标题与计数
 * - 预设作用域编解码:往返、非法值兜底、合法性判定
 * - 按作用域过滤预设:全局恒保留 / 角色匹配 / 缺省=全局 / 无角色上下文时不泄漏
 * - 受管图片清单预设 id:全局固定 id、角色 id 前缀、isManaged 判定
 *
 * 说明:为避免依赖设备端 crypto(generateUuid),本文件一律用对象字面量直接构造
 * LocalImage / PromptPreset,不调用 createLocalImage / createPromptPreset。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  LocalImage,
  normalizeImageName,
  isValidImageName,
  describeImageNameProblem
} from '../main/ets/models/LocalImage';
import {
  buildLocalImageSystemPrompt,
  buildLocalImagePresetName,
  buildLocalImagePresetDescription
} from '../main/ets/services/LocalImagePromptComposer';
import {
  PromptPreset,
  PresetScope,
  encodeScope,
  decodeScope,
  isValidScopeValue,
  filterPresetsByScope,
  MANAGED_IMAGE_GLOBAL_PRESET_ID,
  managedImageCharacterPresetId,
  isManagedImagePresetId
} from '../main/ets/models/PromptPreset';

/** 构造图片(不依赖 generateUuid) */
function makeImage(id: string, name: string, characterId: string): LocalImage {
  return {
    id: id,
    name: name,
    nameKey: normalizeImageName(name),
    fileUri: 'file:///data/local_images/' + id + '.png',
    characterId: characterId,
    createdAt: 1,
    updatedAt: 1
  };
}

/** 构造预设(不依赖 generateUuid) */
function makePreset(id: string, name: string): PromptPreset {
  return {
    id: id,
    name: name,
    description: '',
    systemPrompt: 'x',
    createdAt: 1,
    updatedAt: 1
  };
}

export default function localImageTest() {
  describe('localImage', () => {
    // ===== 名字 =====

    it('name_normalize_trims_and_lowercases', 0, () => {
      expect(normalizeImageName('  开心 OK  ')).assertEqual('开心 ok');
    });

    it('name_valid_accepts_cjk_alnum_underscore', 0, () => {
      expect(isValidImageName('开心')).assertTrue();
      expect(isValidImageName('happy_1')).assertTrue();
      expect(isValidImageName('A1')).assertTrue();
    });

    it('name_invalid_rejects_empty_space_and_forbidden_chars', 0, () => {
      expect(isValidImageName('')).assertFalse();
      expect(isValidImageName('   ')).assertFalse();
      expect(isValidImageName('bad name')).assertFalse();
      expect(isValidImageName('a(b')).assertFalse();
      expect(isValidImageName('a)b')).assertFalse();
      expect(isValidImageName('a[b')).assertFalse();
      expect(isValidImageName('a<b')).assertFalse();
      expect(isValidImageName('a|b')).assertFalse();
    });

    it('name_invalid_rejects_over_length', 0, () => {
      let longName: string = '';
      for (let i = 0; i < 51; i++) {
        longName += 'a';
      }
      expect(isValidImageName(longName)).assertFalse();
    });

    it('name_problem_message_is_actionable', 0, () => {
      expect(describeImageNameProblem('')).assertEqual('图片名不能为空');
      expect(describeImageNameProblem('bad name')).assertEqual('图片名不能包含空格或换行');
      expect(describeImageNameProblem('开心').length).assertEqual(0);
    });

    // ===== 清单 System Prompt =====

    it('composer_empty_images_returns_empty', 0, () => {
      const empty: LocalImage[] = [];
      expect(buildLocalImageSystemPrompt(empty, '全局')).assertEqual('');
    });

    it('composer_contains_rule_and_sorted_list', 0, () => {
      const images: LocalImage[] = [
        makeImage('img-2', 'Sad', ''),
        makeImage('img-1', 'Angry', ''),
        makeImage('img-3', 'Happy', '')
      ];
      const text: string = buildLocalImageSystemPrompt(images, '全局');
      expect(text.indexOf('arkimg:') >= 0).assertTrue();
      expect(text.indexOf('共 3 张') >= 0).assertTrue();
      // nameKey(小写)升序:angry < happy < sad
      const i1: number = text.indexOf('- Angry');
      const i2: number = text.indexOf('- Happy');
      const i3: number = text.indexOf('- Sad');
      expect(i1 >= 0 && i2 > i1 && i3 > i2).assertTrue();
    });

    it('composer_is_byte_stable_regardless_of_input_order', 0, () => {
      const a: LocalImage[] = [
        makeImage('img-1', '开心', ''),
        makeImage('img-2', '哭', ''),
        makeImage('img-3', '怒', '')
      ];
      const b: LocalImage[] = [
        makeImage('img-3', '怒', ''),
        makeImage('img-1', '开心', ''),
        makeImage('img-2', '哭', '')
      ];
      const t1: string = buildLocalImageSystemPrompt(a, '全局');
      const t2: string = buildLocalImageSystemPrompt(b, '全局');
      // 稳定排序:库没变时清单逐字节一致(缓存前缀不受影响)
      expect(t1).assertEqual(t2);
      expect(buildLocalImageSystemPrompt(a, '全局')).assertEqual(t1);
    });

    it('composer_scope_label_in_list_header', 0, () => {
      const images: LocalImage[] = [makeImage('img-1', '开心', 'char-1')];
      const text: string = buildLocalImageSystemPrompt(images, '林霖');
      expect(text.indexOf('可用图片(林霖') >= 0).assertTrue();
      expect(buildLocalImagePresetName('林霖').indexOf('林霖') >= 0).assertTrue();
    });

    it('composer_description_mentions_auto_maintained', 0, () => {
      expect(buildLocalImagePresetDescription(5).indexOf('自动维护') >= 0).assertTrue();
    });

    // ===== 作用域 =====

    it('scope_roundtrip_global_and_character', 0, () => {
      const globalScope: PresetScope = { kind: 'global', characterId: '' };
      const charScope: PresetScope = { kind: 'character', characterId: 'c1' };
      expect(encodeScope(globalScope)).assertEqual('global');
      expect(encodeScope(charScope)).assertEqual('char:c1');
      expect(decodeScope('global').kind).assertEqual('global');
      const decoded: PresetScope = decodeScope('char:c1');
      expect(decoded.kind).assertEqual('character');
      expect(decoded.characterId).assertEqual('c1');
    });

    it('scope_invalid_values_fall_back_to_global', 0, () => {
      expect(isValidScopeValue('global')).assertTrue();
      expect(isValidScopeValue('char:c1')).assertTrue();
      expect(isValidScopeValue('char:')).assertFalse();
      expect(isValidScopeValue('nope')).assertFalse();
      expect(decodeScope('char:').kind).assertEqual('global');
      expect(decodeScope('nope').kind).assertEqual('global');
    });

    it('filter_keeps_global_and_matching_character', 0, () => {
      const presets: PromptPreset[] = [
        makePreset('p-global', '全局预设'),
        makePreset('p-a', 'A 角色预设'),
        makePreset('p-b', 'B 角色预设')
      ];
      const scopes: Record<string, string> = {};
      scopes['p-a'] = 'char:charA';
      scopes['p-b'] = 'char:charB';
      const kept: PromptPreset[] = filterPresetsByScope(presets, scopes, 'charA');
      expect(kept.length).assertEqual(2);
      expect(kept[0].id).assertEqual('p-global');
      expect(kept[1].id).assertEqual('p-a');
    });

    it('filter_missing_scope_entry_treated_as_global', 0, () => {
      const presets: PromptPreset[] = [makePreset('p-x', '无作用域记录')];
      const scopes: Record<string, string> = {};
      expect(filterPresetsByScope(presets, scopes, 'charA').length).assertEqual(1);
      expect(filterPresetsByScope(presets, scopes, null).length).assertEqual(1);
    });

    it('filter_without_character_context_drops_character_scoped', 0, () => {
      const presets: PromptPreset[] = [
        makePreset('p-global', '全局'),
        makePreset('p-a', 'A 角色')
      ];
      const scopes: Record<string, string> = {};
      scopes['p-a'] = 'char:charA';
      const kept: PromptPreset[] = filterPresetsByScope(presets, scopes, null);
      expect(kept.length).assertEqual(1);
      expect(kept[0].id).assertEqual('p-global');
    });

    it('filter_invalid_scope_value_behaves_as_global', 0, () => {
      const presets: PromptPreset[] = [makePreset('p-bad', '脏数据')];
      const scopes: Record<string, string> = {};
      scopes['p-bad'] = 'garbage';
      // 非法存储值按全局处理(与位置读取的丢弃策略一致)
      expect(filterPresetsByScope(presets, scopes, 'charA').length).assertEqual(1);
    });

    // ===== 受管预设 id =====

    it('managed_ids_are_recognisable', 0, () => {
      expect(MANAGED_IMAGE_GLOBAL_PRESET_ID).assertEqual('arkimg-global');
      expect(isManagedImagePresetId(MANAGED_IMAGE_GLOBAL_PRESET_ID)).assertTrue();
      expect(managedImageCharacterPresetId('c1')).assertEqual('arkimg-char-c1');
      expect(isManagedImagePresetId(managedImageCharacterPresetId('c1'))).assertTrue();
      expect(isManagedImagePresetId('user-preset-1')).assertFalse();
    });
  });
}