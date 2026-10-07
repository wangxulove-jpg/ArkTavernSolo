/**
 * 本地图片库(模型 + 预设作用域)纯函数测试
 *
 * 覆盖:
 * - 图片名归一化/合法性/错误文案;描述归一化与长度校验
 * - 预设作用域编解码:往返、非法值兜底、合法性判定
 * - 按作用域过滤预设:全局恒保留 / 角色匹配 / 缺省=全局 / 无角色上下文时不泄漏
 * - 消息内图片大小设置(ChatTextStyle.imageWidthRatio)归一化
 *
 * 说明:为避免依赖设备端 crypto(generateUuid),本文件一律用对象字面量直接构造
 * LocalImage / PromptPreset,不调用 createLocalImage / createPromptPreset。
 * 「标签 = 预设正文」的文本操作与 v50 迁移校验在 local_image_tag_text.test.ets。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  LocalImage,
  normalizeImageName,
  isValidImageName,
  isValidImageDescription,
  describeImageNameProblem,
  describeImageDescriptionProblem,
  normalizeImageDescription,
  IMAGE_DESCRIPTION_MAX_LENGTH,
  extensionOf,
  mediaTypeFromFileName,
  isSupportedMediaFileName,
  coerceMediaType
} from '../main/ets/models/LocalImage';
import {
  ChatTextStyle,
  DEFAULT_CHAT_TEXT_STYLE,
  IMAGE_WIDTH_RATIO_MIN,
  IMAGE_WIDTH_RATIO_MAX,
  normalizeImageWidthRatio
} from '../main/ets/utils/ChatTextStyleSettings';
import {
  PromptPreset,
  PresetScope,
  encodeScope,
  decodeScope,
  isValidScopeValue,
  filterPresetsByScope,
  isManagedImagePresetId
} from '../main/ets/models/PromptPreset';

/** 构造图片(不依赖 generateUuid) */
function makeImage(id: string, name: string, description: string): LocalImage {
  return {
    id: id,
    name: name,
    nameKey: normalizeImageName(name),
    fileUri: 'file:///data/local_images/' + id + '.png',
    mediaType: 'image',
    description: description,
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

    // ===== 描述 =====

    it('description_normalize_flattens_whitespace', 0, () => {
      expect(normalizeImageDescription('  角色  在雨里\n\n撑着伞  ')).assertEqual('角色 在雨里 撑着伞');
      expect(normalizeImageDescription('')).assertEqual('');
    });

    it('description_length_limit', 0, () => {
      expect(isValidImageDescription('')).assertTrue();
      expect(isValidImageDescription('短的描述')).assertTrue();
      expect(describeImageDescriptionProblem('短的描述').length).assertEqual(0);
      let longDesc: string = '';
      for (let i = 0; i < IMAGE_DESCRIPTION_MAX_LENGTH + 1; i++) {
        longDesc += 'a';
      }
      expect(isValidImageDescription(longDesc)).assertFalse();
      expect(describeImageDescriptionProblem(longDesc).length > 0).assertTrue();
    });

    it('image_fields_are_independent_of_former_scope', 0, () => {
      // v50:图片池模型已无 characterId 字段(编译通过即为该断言)
      const image: LocalImage = makeImage('img-1', '笑', '开心大笑');
      expect(image.description).assertEqual('开心大笑');
      expect(image.nameKey).assertEqual('笑');
    });

    // ===== 作用域(仍用于"预设在哪些会话生效") =====

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

    it('managed_preset_concept_is_retired', 0, () => {
      // v50:标签就是普通预设,不再有"受管图片清单预设"
      expect(isManagedImagePresetId('arkimg-global')).assertFalse();
      expect(isManagedImagePresetId('user-preset-1')).assertFalse();
    });

    // ===== 消息内图片大小设置(ChatTextStyle.imageWidthRatio) =====

    it('image_width_ratio_keeps_valid_value', 0, () => {
      expect(normalizeImageWidthRatio(0.6)).assertEqual(0.6);
      expect(normalizeImageWidthRatio(IMAGE_WIDTH_RATIO_MAX)).assertEqual(1.0);
      expect(normalizeImageWidthRatio(IMAGE_WIDTH_RATIO_MIN)).assertEqual(0.3);
    });

    it('image_width_ratio_clamps_out_of_range', 0, () => {
      expect(normalizeImageWidthRatio(0.0)).assertEqual(IMAGE_WIDTH_RATIO_MIN);
      expect(normalizeImageWidthRatio(-1)).assertEqual(IMAGE_WIDTH_RATIO_MIN);
      expect(normalizeImageWidthRatio(5)).assertEqual(IMAGE_WIDTH_RATIO_MAX);
    });

    it('image_width_ratio_falls_back_on_invalid', 0, () => {
      // 非法值(NaN/非有限)回落默认,保证旧数据与脏数据都不炸
      expect(normalizeImageWidthRatio(Number.NaN)).assertEqual(DEFAULT_CHAT_TEXT_STYLE.imageWidthRatio);
      expect(DEFAULT_CHAT_TEXT_STYLE.imageWidthRatio).assertEqual(1.0);
      // 默认样式是新装用户的比例来源
      const style: ChatTextStyle = DEFAULT_CHAT_TEXT_STYLE;
      expect(style.imageWidthRatio > 0).assertTrue();
    });

    // ===== 媒体类型(v51:图片 / GIF / 视频) =====

    it('extension_extracts_lowercase_and_strips_query', 0, () => {
      expect(extensionOf('file:///a/b/pic.PNG')).assertEqual('.png');
      expect(extensionOf('/a/b/clip.mp4?token=x#f')).assertEqual('.mp4');
      expect(extensionOf('/a/b/noext')).assertEqual('');
    });

    it('media_type_maps_extension_to_kind', 0, () => {
      expect(mediaTypeFromFileName('/a/b/pic.png')).assertEqual('image');
      expect(mediaTypeFromFileName('/a/b/anim.GIF')).assertEqual('gif');
      expect(mediaTypeFromFileName('/a/b/clip.mp4')).assertEqual('video');
      expect(mediaTypeFromFileName('/a/b/clip.MKV')).assertEqual('video');
      // 未识别扩展名回退图片(旧数据安全)
      expect(mediaTypeFromFileName('/a/b/unknown.xyz')).assertEqual('image');
    });

    it('supported_media_whitelist', 0, () => {
      expect(isSupportedMediaFileName('/a/b/pic.jpg')).assertTrue();
      expect(isSupportedMediaFileName('/a/b/anim.gif')).assertTrue();
      expect(isSupportedMediaFileName('/a/b/clip.mp4')).assertTrue();
      expect(isSupportedMediaFileName('/a/b/doc.pdf')).assertFalse();
      expect(isSupportedMediaFileName('/a/b/noext')).assertFalse();
    });

    it('coerce_media_type_defaults_to_image', 0, () => {
      expect(coerceMediaType('gif')).assertEqual('gif');
      expect(coerceMediaType('video')).assertEqual('video');
      expect(coerceMediaType('image')).assertEqual('image');
      expect(coerceMediaType('')).assertEqual('image');
      expect(coerceMediaType('bogus')).assertEqual('image');
    });
  });
}