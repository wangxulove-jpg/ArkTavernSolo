/**
 * Gemini 模型列表过滤测试
 *
 * 验证 filterGeminiChatModels / isGeminiChatModelId:
 * - 非 chat 模型被过滤（tts/image/embedding/live/transcribe/lyria/veo/robotics）
 * - chat 模型保留，models/ 前缀被剥离
 * - models/ 前缀模型解析正确，ownedBy 持续传递
 * - 空列表和空 ID 不崩溃
 */

import { describe, it, expect } from '@ohos/hypium';
import { filterGeminiChatModels, isGeminiChatModelId } from '../main/ets/network/providers/GeminiModelFilter';
import { ModelListItem } from '../main/ets/models/ModelListResult';

function item(id: string): ModelListItem {
  return { id: id, ownedBy: 'google' };
}

export default function geminiModelFilterTest() {
  describe('GeminiModelFilter', () => {
    it('filters_non_chat_models', 0, () => {
      expect(isGeminiChatModelId('gemini-2.5-flash-preview-tts')).assertFalse();
      expect(isGeminiChatModelId('gemini-3.1-flash-image')).assertFalse();
      expect(isGeminiChatModelId('gemini-embedding-001')).assertFalse();
      expect(isGeminiChatModelId('gemini-3.8-live')).assertFalse();
      expect(isGeminiChatModelId('gemini-3.5-transcribe')).assertFalse();
      expect(isGeminiChatModelId('lyria-3.5')).assertFalse();
      expect(isGeminiChatModelId('veo-3.1-generate-preview')).assertFalse();
      expect(isGeminiChatModelId('gemini-robotics-er-2-preview')).assertFalse();
      expect(isGeminiChatModelId('gemini-2.5-computer-use-preview-10-2025')).assertFalse();
      expect(isGeminiChatModelId('deep-research-pro-preview-12-2025')).assertFalse();
      expect(isGeminiChatModelId('nano-banana-pro-preview')).assertFalse();
      expect(isGeminiChatModelId('models/gemini-2.5-flash-image')).assertFalse();
      expect(isGeminiChatModelId('')).assertFalse();
    });

    it('keeps_chat_models', 0, () => {
      expect(isGeminiChatModelId('gemini-3.6-flash')).assertTrue();
      expect(isGeminiChatModelId('gemini-3.8-flash')).assertTrue();
      expect(isGeminiChatModelId('gemini-3.1-pro-preview')).assertTrue();
      expect(isGeminiChatModelId('gemini-3.1-pro-preview-customtools')).assertTrue();
      expect(isGeminiChatModelId('gemini-3.1-flash-lite')).assertTrue();
      expect(isGeminiChatModelId('gemini-flash-latest')).assertTrue();
      expect(isGeminiChatModelId('gemini-pro-latest')).assertTrue();
      expect(isGeminiChatModelId('gemma-4-31b-it')).assertTrue();
      expect(isGeminiChatModelId('models/gemini-3.6-flash')).assertTrue();
    });

    it('filter_list_and_strip_prefix', 0, () => {
      const input: ModelListItem[] = [
        item('models/antigravity-preview-latest'),
        item('models/gemini-2.5-flash'),
        item('models/gemini-2.5-flash-preview-tts'),
        item('models/gemini-3.1-flash-image'),
        item('models/gemini-3.1-pro-preview'),
        item('models/gemini-3.5-transcribe'),
        item('models/gemini-3.6-flash'),
        item('models/gemini-embedding-001'),
        item('models/gemma-4-31b-it')
      ];
      const result: ModelListItem[] = filterGeminiChatModels(input);
      expect(result.length).assertEqual(4);
      expect(result[0].id).assertEqual('gemini-2.5-flash');
      expect(result[1].id).assertEqual('gemini-3.1-pro-preview');
      expect(result[2].id).assertEqual('gemini-3.6-flash');
      expect(result[3].id).assertEqual('gemma-4-31b-it');
      expect(result[0].ownedBy).assertEqual('google');
    });

    it('empty_input_returns_empty', 0, () => {
      expect(filterGeminiChatModels([]).length).assertEqual(0);
    });
  });
}
