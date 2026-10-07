/**
 * LocalImageCaptionService 本地图片「AI 自动命名」服务
 *
 * 编排:读沙箱图片 → base64 data URL → 视觉请求(用当前配置的聊天模型) → 解析建议。
 *
 * 只产出**建议**,不落库;写库由调用方在用户确认后调用 LocalImageService
 * (renameImage / updateImageDescription,两者都会同步改写标签预设正文)。
 *
 * 分层:
 * - services 层;ModelService 是唯一 AI 出口
 * - 不 import DbHelper
 * - 不依赖 ArkUI
 *
 * 前提:当前配置的模型需支持图片输入(user 消息 content 块数组)。
 * 若模型不支持,服务端会返回 4xx,这里转成可读提示由 UI 展示。
 */

import { ChatRequest } from '../../models/ChatRequest';
import { ChatResponse } from '../../models/ChatResponse';
import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ProviderConfig } from '../../models/ProviderConfig';
import { LocalImage, sanitizeImageName } from '../../models/LocalImage';
import {
  CaptionParseFailure,
  ImageCaptionSuggestion,
  LOCAL_IMAGE_CAPTION_USER_TEXT,
  buildCaptionInstruction,
  classifyCaptionFailure,
  parseImageCaptionResponse,
  summarizeRawResponse
} from '../../models/LocalImageCaption';
import { LocalImageService } from '../LocalImageService';
import { LocalImageAssetStore } from '../../storage/LocalImageAssetStore';
import { AppPreferences } from '../../storage/AppPreferences';
import { ModelService } from '../ModelService';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'LocalImageCaptionService';

/** 「描述方向」本地偏好键(用户自定义要求,拼在提示词开头) */
const GUIDANCE_KEY: string = 'local_image_caption_guidance_v1';

/** 一次性任务消息 id(不持久化,仅为模型必填字段) */
const SYSTEM_MESSAGE_ID: string = 'caption-sys';
const USER_MESSAGE_ID: string = 'caption-usr';

/**
 * 生成参数。
 *
 * 关键:`reasoningEffort: 'none'` **关掉思考** —— 命名是纯抽取任务,不需要推理;
 * 不关的话思考会吃掉大部分输出配额,导致 JSON 被截断或只剩很短的内容
 * (与聊天页「思考强度」同一套字段,`'none'` = 发送 reasoning_effort=none)。
 * maxTokens 同步放大到 2000:万一某些 Provider 忽略 reasoning_effort,仍留足输出空间。
 */
const CAPTION_TEMPERATURE: number = 0.3;
const CAPTION_TOP_P: number = 0.9;
const CAPTION_MAX_TOKENS: number = 2000;
const CAPTION_REASONING_EFFORT: string = 'none';
/** 失败时在提示里附带的模型原文长度上限 */
const RAW_EXCERPT_MAX_LENGTH: number = 160;

/**
 * 本地图片 AI 命名服务。
 */
export class LocalImageCaptionService {
  private readonly modelService: ModelService;
  private readonly localImageService: LocalImageService;
  private readonly assetStore: LocalImageAssetStore;
  private readonly preferences: AppPreferences;

  constructor(
    modelService: ModelService,
    localImageService: LocalImageService,
    assetStore: LocalImageAssetStore,
    preferences: AppPreferences
  ) {
    this.modelService = modelService;
    this.localImageService = localImageService;
    this.assetStore = assetStore;
    this.preferences = preferences;
  }

  /** 读取用户上次填写的「描述方向」(读失败按空串处理) */
  async loadGuidance(): Promise<string> {
    try {
      return await this.preferences.getString(GUIDANCE_KEY, '');
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadGuidance failed: ' + String(e));
      return '';
    }
  }

  /** 保存「描述方向」(写失败只记日志,不影响命名) */
  async saveGuidance(guidance: string): Promise<void> {
    try {
      await this.preferences.putString(GUIDANCE_KEY, guidance);
    } catch (e) {
      Logger.warn(LOG_TAG, 'saveGuidance failed: ' + String(e));
    }
  }

  /**
   * 为一张图片生成命名建议(不落库)。
   *
   * @param imageId 图片 id
   * @param guidance 用户自定义「描述方向」,拼在提示词开头(可为空)
   * @returns 建议:名字已按本项目规则消毒(消毒后为空则退回原名),描述已归一化截断
   * @throws Error 未配置模型 / 图片不可读或过大 / 请求失败 / 返回无法解析
   */
  async suggestCaption(imageId: string, guidance: string): Promise<ImageCaptionSuggestion> {
    const image: LocalImage | null = await this.localImageService.getImage(imageId);
    if (image === null) {
      throw new Error('图片不存在或已被删除');
    }

    const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
    if (config === null) {
      throw new Error('尚未配置模型,请先在「模型设置」中添加服务商');
    }
    const modelName: string = config.modelName.trim();
    if (modelName.length === 0) {
      throw new Error('当前配置未填写模型名,请在「模型设置」中填写');
    }

    // 读图:超过体积上限会在此抛出可读错误
    const dataUrl: string = await this.assetStore.readImageAsDataUrl(image.fileUri);

    // 图片挂在最后一条 user 消息上(DeepSeek/OpenAI 兼容端点的硬要求)
    const messages: ChatMessage[] = [
      createChatMessage(SYSTEM_MESSAGE_ID, ChatRole.System, buildCaptionInstruction(guidance), Date.now()),
      createChatMessage(USER_MESSAGE_ID, ChatRole.User, LOCAL_IMAGE_CAPTION_USER_TEXT, Date.now())
    ];
    const request: ChatRequest = {
      model: modelName,
      messages: messages,
      temperature: CAPTION_TEMPERATURE,
      topP: CAPTION_TOP_P,
      maxTokens: CAPTION_MAX_TOKENS,
      stream: false,
      responseFormatJson: true,
      reasoningEffort: CAPTION_REASONING_EFFORT,
      imageDataUrls: [dataUrl]
    };

    let response: ChatResponse;
    try {
      response = await this.modelService.sendChat(request);
    } catch (e) {
      Logger.warn(LOG_TAG, 'suggestCaption request failed: ' + String(e));
      throw toReadableCaptionError(e);
    }

    const finishReason: string = response.finishReason !== undefined ? response.finishReason : '';
    if (response.content.trim().length === 0) {
      Logger.warn(LOG_TAG, 'suggestCaption empty content, finish=' + finishReason);
      throw new Error('模型没有返回任何内容(常见于被安全策略拦截,或思考内容占满了输出配额);'
        + '请重试,或更换不做内容过滤的模型');
    }

    const suggestion: ImageCaptionSuggestion | null = parseImageCaptionResponse(response.content);
    if (suggestion === null) {
      const failure: CaptionParseFailure = classifyCaptionFailure(response.content, finishReason);
      Logger.warn(LOG_TAG, 'suggestCaption parse failed: kind=' + failure +
        ' finish=' + finishReason +
        ' content.len=' + response.content.length.toString());
      throw new Error(buildParseFailureMessage(failure, response.content));
    }

    const safeName: string = sanitizeImageName(suggestion.name, image.name);
    return {
      name: safeName.length > 0 ? safeName : image.name,
      description: suggestion.description
    };
  }
}

/**
 * 按失败类型给出可操作的提示,并附带模型原文摘要(便于用户/开发一眼定性)。
 */
function buildParseFailureMessage(failure: CaptionParseFailure, raw: string): string {
  const excerpt: string = summarizeRawResponse(raw, RAW_EXCERPT_MAX_LENGTH);
  if (failure === 'truncated') {
    return 'AI 输出被长度上限截断,JSON 不完整 —— 请重试。\n原文:' + excerpt;
  }
  if (failure === 'refusal') {
    return '模型没有按要求返回 JSON(常见原因是拒答或安全策略拦截)。\n'
      + '可换用不做内容过滤的模型;若只是措辞触发,可把描述要求改得更中性。\n原文:' + excerpt;
  }
  return 'AI 返回的 JSON 无法解析(格式不符或字段缺失)。\n原文:' + excerpt;
}

/**
 * 把请求失败转成可读错误。
 * 命中图片相关报错时补一句可操作提示(最常见原因:当前模型不支持视觉输入)。
 */
function toReadableCaptionError(e: Object): Error {
  let raw: string = String(e);
  const maybe: Error = e as Error;
  if (maybe.message !== undefined && maybe.message !== null && maybe.message.length > 0) {
    raw = maybe.message;
  }
  if (raw.length === 0) {
    return new Error('AI 命名失败,请重试');
  }
  if (raw.toLowerCase().indexOf('image') >= 0) {
    return new Error(raw +
      '(若提示模型不支持图片,请在「模型设置」中改用支持视觉的模型,如 deepseek-flash)');
  }
  return new Error(raw);
}