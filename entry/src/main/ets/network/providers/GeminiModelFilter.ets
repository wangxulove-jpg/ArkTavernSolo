/**
 * GeminiModelFilter Gemini 模型列表过滤(纯函数)
 *
 * Gemini 的 /v1beta/openai/models 接口会返回全部 60+ 模型,其中大量是
 * 聊天应用用不上的类型(embedding / TTS / 图像生成 / 视频 / 音乐 / 实时语音等)。
 * 本模块在 ModelService.fetchAvailableModels 中对 ProviderType.Gemini 的
 * 拉取结果做过滤,只保留可通过 chat/completions 使用的对话模型。
 *
 * 同时去掉原生格式的 "models/" 前缀(接口返回如 "models/gemini-3.6-flash"),
 * 使 ID 与预设列表一致;带前缀与不带前缀在请求时均被服务端接受。
 *
 * 纯逻辑实现,不依赖设备 API,可在本地单元测试运行。
 */

import { ModelListItem } from '../../models/ModelListResult';

/** 原生格式模型 ID 前缀(如 "models/gemini-3.6-flash") */
const MODELS_PREFIX: string = 'models/';

/**
 * 非对话模型标记(小写子串匹配)。
 * 命中任意一项即过滤:
 * - embedding:向量模型
 * - imagen / image / nano-banana:图像生成
 * - tts:语音合成
 * - live / omni / native-audio / transcribe:实时音视频与转写
 * - veo:视频生成
 * - lyria:音乐生成
 * - robotics:机器人模型
 * - computer-use:计算机操作代理
 * - deep-research / antigravity:研究与代理类专用模型
 * - aqa:旧版问答模型
 */
const NON_CHAT_MARKERS: string[] = [
  'embedding',
  'imagen',
  'image',
  'nano-banana',
  'tts',
  'live',
  'omni',
  'native-audio',
  'transcribe',
  'veo',
  'lyria',
  'robotics',
  'computer-use',
  'deep-research',
  'antigravity',
  'aqa'
];

/**
 * 判断模型 ID 是否为 Gemini 对话模型。
 * 匹配前先去掉 "models/" 前缀并转小写。
 *
 * @param id 模型 ID(可能带 models/ 前缀)
 * @returns 是对话模型返回 true
 */
export function isGeminiChatModelId(id: string): boolean {
  let name: string = id.trim().toLowerCase();
  if (name.startsWith(MODELS_PREFIX)) {
    name = name.substring(MODELS_PREFIX.length);
  }
  if (name.length === 0) {
    return false;
  }
  for (let i = 0; i < NON_CHAT_MARKERS.length; i++) {
    if (name.includes(NON_CHAT_MARKERS[i])) {
      return false;
    }
  }
  return true;
}

/**
 * 过滤 Gemini 模型列表,只保留对话模型,并去掉 models/ 前缀。
 * 顺序保持原样(接口本身按字母序返回)。
 *
 * @param models 拉取到的原始模型列表
 * @returns 过滤并规整后的列表
 */
export function filterGeminiChatModels(models: ModelListItem[]): ModelListItem[] {
  const result: ModelListItem[] = [];
  for (let i = 0; i < models.length; i++) {
    const item: ModelListItem = models[i];
    if (!isGeminiChatModelId(item.id)) {
      continue;
    }
    let id: string = item.id.trim();
    if (id.toLowerCase().startsWith(MODELS_PREFIX)) {
      id = id.substring(MODELS_PREFIX.length);
    }
    if (id.length === 0) {
      continue;
    }
    const filtered: ModelListItem = { id: id, ownedBy: item.ownedBy };
    result.push(filtered);
  }
  return result;
}
