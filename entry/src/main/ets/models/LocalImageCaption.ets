/**
 * LocalImageCaption 本地图片「AI 自动命名」的契约与纯函数
 *
 * 场景:本地图片库导入的图片只有名字(常来自文件名)、描述为空,
 * 而聊天时模型只能看到「名字 + 描述」两段纯文本(图片本体不发出去,模型按名字点图),
 * 描述是模型判断"该用哪张图"的唯一依据。故提供一个视觉任务:
 * 把图片发给当前配置的聊天模型(需支持视觉),让它返回名字 + 描述,由用户确认后落库。
 *
 * 本文件只放**无副作用**的部分(可在 host 侧单测):
 * - 送给模型的指令文本
 * - 解析模型返回的 JSON(容忍代码围栏与前后噪声)
 *
 * 不碰 DB / 网络 / ArkUI;名字的合法性规则仍由 models/LocalImage.ets 单点拥有。
 */

import {
  IMAGE_DESCRIPTION_MAX_LENGTH,
  normalizeImageDescription
} from './LocalImage';

/** AI 给出的命名建议(尚未消毒/校验) */
export interface ImageCaptionSuggestion {
  readonly name: string;
  readonly description: string;
}

/**
 * 任务指令(作为 system 消息)。
 *
 * 注意:文本中必须出现 "JSON" 字样 —— 开启 response_format=json_object 时
 * 部分 OpenAI 兼容端点会强制校验这一点,否则直接报错。
 * 提示词刻意压短:本任务每次都要带一张图,token 主要花在图片上。
 */
export const LOCAL_IMAGE_CAPTION_INSTRUCTION: string =
  '你在整理聊天用的表情/配图库。请观察这张图片,只输出一个 JSON 对象:\n'
  + '{"name":"图片名","description":"一句话描述"}\n'
  + '要求:\n'
  + '- name:2~6 个字,直接点出情绪/动作/物件(如「开心」「生气」「比耶」),不含空格与标点\n'
  + '- description:说明画面内容与适合使用的场景,不超过 40 字\n'
  + '- 不要输出 JSON 以外的任何内容';

/** 与图片同一条 user 消息里的文本 */
export const LOCAL_IMAGE_CAPTION_USER_TEXT: string = '请为这张图片给出名字与描述。';

/** 用户自定义「描述方向」的长度上限 */
export const CAPTION_GUIDANCE_MAX_LENGTH: number = 300;

/**
 * 组装最终发给模型的任务指令。
 *
 * 用户填的「描述方向」**放在最前**(它优先级最高、用于覆盖/补充下面的固定要求),
 * 空行之后接固定基础指令;方向为空时就是基础指令本身。
 *
 * @param guidance 用户在界面上填写的描述方向(可为空)
 */
export function buildCaptionInstruction(guidance: string): string {
  const trimmed: string = guidance.trim();
  if (trimmed.length === 0) {
    return LOCAL_IMAGE_CAPTION_INSTRUCTION;
  }
  const capped: string = trimmed.length > CAPTION_GUIDANCE_MAX_LENGTH
    ? trimmed.substring(0, CAPTION_GUIDANCE_MAX_LENGTH)
    : trimmed;
  return capped + '\n\n' + LOCAL_IMAGE_CAPTION_INSTRUCTION;
}

/**
 * 解析模型返回的文本。
 *
 * 容忍三种常见形态:
 * - ```json ... ``` 代码围栏
 * - JSON 前后夹带说明文字(取第一个 `{` 到最后一个 `}`)
 * - 非法 JSON / 非对象 / 字段全空 → 返回 null(调用方保留原名字)
 *
 * @param raw 模型返回的原始文本
 * @returns 解析出的建议;无法解析返回 null
 */
export function parseImageCaptionResponse(raw: string): ImageCaptionSuggestion | null {
  const jsonText: string = extractJsonObjectText(raw);
  if (jsonText.length === 0) {
    return null;
  }
  let root: Object;
  try {
    root = JSON.parse(jsonText) as Object;
  } catch (e) {
    return null;
  }
  if (typeof root !== 'object' || root === null || Array.isArray(root)) {
    return null;
  }
  const record: Record<string, Object> = root as Record<string, Object>;
  // 键名容错:模型可能用中文键或别名
  const name: string = readFirstString(record, ['name', '名称', '图片名', 'title']);
  const rawDescription: string = normalizeImageDescription(
    readFirstString(record, ['description', '描述', 'desc', '简介'])
  );
  const description: string = rawDescription.length > IMAGE_DESCRIPTION_MAX_LENGTH
    ? rawDescription.substring(0, IMAGE_DESCRIPTION_MAX_LENGTH)
    : rawDescription;
  if (name.length === 0 && description.length === 0) {
    return null;
  }
  return { name: name, description: description };
}

/** 解析失败的归类(决定给用户哪种可操作提示) */
export type CaptionParseFailure = 'refusal' | 'truncated' | 'malformed';

/**
 * 归类解析失败原因。
 * - truncated:输出达到长度上限(JSON 必然不完整)—— 优先判定,因为提示最可操作
 * - refusal:原文里根本没有 `{`(多半是模型用自然语言拒答或未按要求输出)
 * - malformed:有花括号但 JSON 不完整 / 字段不可用
 *
 * @param raw 模型返回的原始文本
 * @param finishReason 响应的结束原因(可能为空串)
 */
export function classifyCaptionFailure(raw: string, finishReason: string): CaptionParseFailure {
  if (finishReason === 'length') {
    return 'truncated';
  }
  if (raw.indexOf('{') < 0) {
    return 'refusal';
  }
  return 'malformed';
}

/** 连续空白压平(ArkTS 禁正则字面量,故用 new RegExp) */
const WHITESPACE_PATTERN: RegExp = new RegExp('\\s+', 'g');

/**
 * 把模型原文压成单行摘要(供 UI 展示失败原因用)。
 * 空白压平 + 截断,避免把整段回复塞进面板。
 */
export function summarizeRawResponse(raw: string, maxLen: number): string {
  const flat: string = raw.replace(WHITESPACE_PATTERN, ' ').trim();
  if (flat.length <= maxLen) {
    return flat;
  }
  return flat.substring(0, maxLen) + '…';
}

/** 取出 JSON 对象文本:剥代码围栏 → 取首 `{` 到末 `}` */
function extractJsonObjectText(raw: string): string {
  let text: string = raw.trim();
  if (text.startsWith('```')) {
    const firstNewline: number = text.indexOf('\n');
    if (firstNewline >= 0) {
      text = text.substring(firstNewline + 1);
    }
    const fenceEnd: number = text.lastIndexOf('```');
    if (fenceEnd >= 0) {
      text = text.substring(0, fenceEnd);
    }
    text = text.trim();
  }
  const start: number = text.indexOf('{');
  const end: number = text.lastIndexOf('}');
  if (start < 0 || end <= start) {
    return '';
  }
  return text.substring(start, end + 1);
}

/** 安全读字符串字段(非字符串返回空串) */
function readString(raw: Record<string, Object>, key: string): string {
  const v: Object | undefined = raw[key];
  if (typeof v === 'string') {
    return (v as string).trim();
  }
  return '';
}

/** 按候选键顺序取第一个非空字符串(键名容错) */
function readFirstString(raw: Record<string, Object>, keys: string[]): string {
  for (let i = 0; i < keys.length; i++) {
    const value: string = readString(raw, keys[i]);
    if (value.length > 0) {
      return value;
    }
  }
  return '';
}