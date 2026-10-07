/**
 * LocalImage 领域模型
 *
 * 用户导入的图片/表情包/GIF:每张图有一个名字,AI 在回复正文里用
 * `![描述](arkimg:名字)` 引用,App 解析后渲染沙箱内的本地图。
 *
 * 图片池(v50 起):
 * - **所有图片一个池子**,不再分「全局 / 角色专属」(旧 `character_id` 列已停用,不读不写)
 * - 分组一律用**标签**表达,而标签就是普通提示词预设 —— 把图片名写进预设正文即视为打上该标签
 * - 每张图另有一段**描述**(给模型看"这图是什么"),写进标签预设时随名字一起列出
 *
 * 不依赖 ArkUI、RDB、页面或 Provider。
 *
 * 安全要求:
 * - 不包含聊天正文 / Character Prompt / Lorebook 内容
 * - fileUri 只允许沙箱内 file:// 路径(由 LocalImageAssetStore 写入)
 */

import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';
import { DatabaseError } from './DatabaseError';

// ===== 校验常量 =====

/** 图片名长度上限 */
export const IMAGE_NAME_MAX_LENGTH: number = 50;
/** 图片描述长度上限(写进标签预设时与名字一起给模型看,故不宜过长) */
export const IMAGE_DESCRIPTION_MAX_LENGTH: number = 200;
/** 名字 id 前缀 */
const ID_PREFIX: string = 'img-';

/**
 * 名字中禁止出现的字符。
 *
 * 原因:名字会原样出现在 AI 输出的 markdown 图片语法 `![alt](arkimg:名字)` 里,
 * 下列字符会破坏该语法或与 HTML 消毒/占位符机制冲突:
 * - `(` `)` 会提前闭合 markdown 的 URL 段
 * - `[` `]` 会破坏 alt 段与后续解析
 * - `<` `>` 会被 HTML 消毒当成标签
 * - 引号 / 反引号 / 竖线 易与卡内其它标记语法冲突
 */
const FORBIDDEN_NAME_CHARS: string[] = ['[', ']', '(', ')', '<', '>', '"', "'", '`', '|'];

// ===== 模型接口 =====

/**
 * LocalImage 领域模型。
 * 不可变:更新通过 Repository 的 update 方法返回/写入新值。
 */
export interface LocalImage {
  readonly id: string;
  /** 用户起的名字(显示用,保留大小写) */
  readonly name: string;
  /** 归一化名字键(trim + 小写):唯一性约束与大小写不敏感查找用 */
  readonly nameKey: string;
  /** 沙箱内的文件 URI(file://...) */
  readonly fileUri: string;
  /** 给模型看的描述(可空;写进标签预设时与名字一起列出) */
  readonly description: string;
  readonly createdAt: number;
  readonly updatedAt: number;
}

/** 创建 LocalImage 的参数 */
export interface CreateLocalImageOptions {
  readonly id?: string;
  readonly name: string;
  readonly fileUri: string;
  readonly description?: string;
  readonly createdAt?: number;
}

// ===== 名字处理 =====

/**
 * 归一化名字:去首尾空白 + 转小写。
 * 用于唯一性约束与查找(模型输出的名字大小写常与用户输入不一致)。
 */
export function normalizeImageName(name: string): string {
  return name.trim().toLowerCase();
}

/**
 * 名字是否合法。
 * 规则:非空、长度 ≤ IMAGE_NAME_MAX_LENGTH、不含空白、不含 FORBIDDEN_NAME_CHARS。
 */
export function isValidImageName(name: string): boolean {
  const trimmed: string = name.trim();
  if (trimmed.length === 0 || trimmed.length > IMAGE_NAME_MAX_LENGTH) {
    return false;
  }
  for (let i = 0; i < trimmed.length; i++) {
    const ch: string = trimmed.charAt(i);
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      return false;
    }
    if (FORBIDDEN_NAME_CHARS.indexOf(ch) >= 0) {
      return false;
    }
  }
  return true;
}

/** 名字不合法时的原因文案(供 UI 直接展示) */
export function describeImageNameProblem(name: string): string {
  const trimmed: string = name.trim();
  if (trimmed.length === 0) {
    return '图片名不能为空';
  }
  if (trimmed.length > IMAGE_NAME_MAX_LENGTH) {
    return `图片名不能超过 ${IMAGE_NAME_MAX_LENGTH} 个字符`;
  }
  for (let i = 0; i < trimmed.length; i++) {
    const ch: string = trimmed.charAt(i);
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      return '图片名不能包含空格或换行';
    }
    if (FORBIDDEN_NAME_CHARS.indexOf(ch) >= 0) {
      return '图片名不能包含 ' + FORBIDDEN_NAME_CHARS.join(' ');
    }
  }
  return '';
}

/**
 * 把一段任意文本消毒成本项目合法的图片名(供 AI 命名结果落库前使用)。
 *
 * 规则与 isValidImageName 一致:
 * - 去掉所有空白字符与 FORBIDDEN_NAME_CHARS
 * - 截断到 IMAGE_NAME_MAX_LENGTH
 * - 结果为空时退回 fallback(通常传原名字);fallback 也非法则返回空串
 *
 * @param raw 待消毒的文本(如模型输出)
 * @param fallback 消毒后为空时的兜底名字
 */
export function sanitizeImageName(raw: string, fallback: string): string {
  const kept: string[] = [];
  for (let i = 0; i < raw.length; i++) {
    const ch: string = raw.charAt(i);
    if (ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r') {
      continue;
    }
    if (FORBIDDEN_NAME_CHARS.indexOf(ch) >= 0) {
      continue;
    }
    kept.push(ch);
  }
  const compact: string = kept.join('');
  const capped: string = compact.length > IMAGE_NAME_MAX_LENGTH
    ? compact.substring(0, IMAGE_NAME_MAX_LENGTH)
    : compact;
  if (capped.length > 0) {
    return capped;
  }
  return isValidImageName(fallback) ? fallback.trim() : '';
}

// ===== 描述处理 =====

/** 描述内的连续空白(含换行)压成单个空格(ArkTS 禁正则字面量,故用 new RegExp) */
const DESCRIPTION_WHITESPACE_PATTERN: RegExp = new RegExp('\\s+', 'g');

/** 归一化描述:去首尾空白 + 压平换行(描述会被写进预设正文的单行条目) */
export function normalizeImageDescription(description: string): string {
  return description.trim().replace(DESCRIPTION_WHITESPACE_PATTERN, ' ');
}

/** 描述是否合法:长度 ≤ IMAGE_DESCRIPTION_MAX_LENGTH(可空) */
export function isValidImageDescription(description: string): boolean {
  return normalizeImageDescription(description).length <= IMAGE_DESCRIPTION_MAX_LENGTH;
}

/** 描述不合法时的原因文案(供 UI 直接展示) */
export function describeImageDescriptionProblem(description: string): string {
  if (!isValidImageDescription(description)) {
    return `图片描述不能超过 ${IMAGE_DESCRIPTION_MAX_LENGTH} 个字符`;
  }
  return '';
}

// ===== 工厂与校验 =====

/**
 * 创建 LocalImage 实例。
 * @throws DatabaseError.InvalidData 名字/描述/URI 非法
 */
export function createLocalImage(options: CreateLocalImageOptions): LocalImage {
  const id: string = options.id !== undefined && options.id.length > 0
    ? options.id
    : ID_PREFIX + generateUuid();
  const now: number = options.createdAt !== undefined ? options.createdAt : nowMillis();
  const image: LocalImage = {
    id: id,
    name: options.name.trim(),
    nameKey: normalizeImageName(options.name),
    fileUri: options.fileUri,
    description: options.description !== undefined ? normalizeImageDescription(options.description) : '',
    createdAt: now,
    updatedAt: now
  };
  validateLocalImage(image);
  return image;
}

/**
 * 校验 LocalImage 字段合法性。
 * 非法数据抛 DatabaseError.InvalidData,不返回半合法对象。
 */
export function validateLocalImage(image: LocalImage): void {
  if (image.id.length === 0) {
    throw DatabaseError.invalidData('local image id empty');
  }
  if (!isValidImageName(image.name)) {
    throw DatabaseError.invalidData('local image name invalid');
  }
  if (image.nameKey !== normalizeImageName(image.name)) {
    throw DatabaseError.invalidData('local image nameKey mismatch');
  }
  if (image.fileUri.length === 0) {
    throw DatabaseError.invalidData('local image fileUri empty');
  }
  if (!isValidImageDescription(image.description)) {
    throw DatabaseError.invalidData('local image description too long');
  }
  if (!Number.isFinite(image.createdAt) || !Number.isInteger(image.createdAt) || image.createdAt < 0) {
    throw DatabaseError.invalidData('local image createdAt invalid');
  }
  if (!Number.isFinite(image.updatedAt) || !Number.isInteger(image.updatedAt) || image.updatedAt < 0) {
    throw DatabaseError.invalidData('local image updatedAt invalid');
  }
  if (image.updatedAt < image.createdAt) {
    throw DatabaseError.invalidData('local image updatedAt < createdAt');
  }
}

/** 生成新的图片 id(供 Store 预先命名文件用) */
export function newLocalImageId(): string {
  return ID_PREFIX + generateUuid();
}