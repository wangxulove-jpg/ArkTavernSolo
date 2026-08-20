/**
 * ChatBackgroundService 聊天背景服务
 *
 * 提供聊天界面背景图的导入、存储、读取、删除能力。
 *
 * 设计:
 * - 图片以文件形式存储在应用沙箱的 chat_background/ 目录,文件名 = chatId + '.jpg'
 * - 元数据(是否启用、模糊度、暗化程度)通过 AppPreferences 存储
 * - Preferences key 命名:chat_bg_<chatId>_enabled / chat_bg_<chatId>_blur / chat_bg_<chatId>_dim
 * - 不存储图片内容到数据库或 Preferences
 *
 * 业务约束:
 * - blur 范围 0~100,0 = 不模糊,100 = 最大模糊
 * - dim 范围 0~100,0 = 不暗化,100 = 全黑(用于增强浅色背景图下文字可读性)
 * - 删除聊天时由调用方主动调用 deleteBackground(chatId)
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppPreferences } from '../storage/AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'ChatBackgroundService';

/** 模糊度默认值(0~100) */
const DEFAULT_BLUR: number = 30;
/** 暗化程度默认值(0~100) */
const DEFAULT_DIM: number = 30;
/** 模糊度上限 */
const MAX_BLUR: number = 100;
/** 暗化程度上限 */
const MAX_DIM: number = 100;

/** Preferences 名称 */
const PREF_NAME: string = 'chat_background_prefs';
/** 背景图目录名 */
const BG_DIR: string = 'chat_background';

/**
 * 聊天背景配置
 */
export interface ChatBackgroundConfig {
  /** 是否启用背景图 */
  enabled: boolean;
  /** 背景图文件 URI(file://docs/...),未设置时为空字符串 */
  imageUri: string;
  /** 模糊度 0~100 */
  blur: number;
  /** 暗化程度 0~100(0 = 透明,100 = 全黑遮罩) */
  dim: number;
}

/**
 * 思考强度档位枚举值
 * - '':跟随 Provider 默认(不发送 reasoning_effort 字段)
 * - 'none':关闭思考
 * - 'low':低(快速)
 * - 'medium':中(标准)
 * - 'high':高(深度)
 */
export type ReasoningEffort = '' | 'none' | 'low' | 'medium' | 'high';

/**
 * 思考强度配置(per-chat)
 */
export interface ChatReasoningConfig {
  /** 思考强度,空字符串表示跟随 Provider 默认 */
  effort: ReasoningEffort;
}

/** 思考强度默认值(空字符串 = 跟随 Provider 默认) */
const DEFAULT_REASONING_EFFORT: ReasoningEffort = '';

/**
 * 聊天背景服务
 */
export class ChatBackgroundService {
  private readonly preferences: AppPreferences;
  private readonly context: common.Context;
  /** 背景图存储目录的沙箱绝对路径 */
  private readonly bgDirPath: string;

  constructor(context: common.Context, preferences: AppPreferences) {
    this.context = context;
    this.preferences = preferences;
    // filesDir = /data/app/.../files
    this.bgDirPath = context.filesDir + '/' + BG_DIR;
  }

  /**
   * 确保 chat_background 目录存在。
   * 幂等:目录已存在时不报错。
   */
  private async ensureDir(): Promise<void> {
    try {
      const exists: boolean = fs.accessSync(this.bgDirPath);
      if (exists) {
        return;
      }
    } catch (_e) {
      // 路径不存在,继续创建
    }
    await fs.mkdir(this.bgDirPath, true);
  }

  /**
   * 从源 URI 读取图片并复制到应用沙箱。
   * 源 URI 可以是 file://、datashare://、'file:///docs/...' 等形式。
   *
   * @param chatId 聊天 ID(用作文件名)
   * @param sourceUri 源图片 URI(PhotoViewPicker 返回的 uris 数组元素)
   * @returns 复制后的沙箱文件 URI(file://<绝对路径>)
   */
  async importImage(chatId: string, sourceUri: string): Promise<string> {
    if (chatId.length === 0) {
      throw new Error('chatId must not be empty');
    }
    if (sourceUri.length === 0) {
      throw new Error('sourceUri must not be empty');
    }
    await this.ensureDir();
    const targetPath: string = this.bgDirPath + '/' + chatId + '.jpg';
    const targetUri: string = 'file://' + targetPath;

    // 读取源文件
    const sourceFile: fs.File = await fs.open(sourceUri, fs.OpenMode.READ_ONLY);
    try {
      // 写入目标文件(覆盖已存在)
      const targetFile: fs.File = await fs.open(targetPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        // 分块拷贝(单次 4MB)
        const BUFFER_SIZE: number = 4 * 1024 * 1024;
        const tempBuf: ArrayBuffer = new ArrayBuffer(BUFFER_SIZE);
        let offset: number = 0;
        while (true) {
          const readLen: number = await fs.read(sourceFile.fd, tempBuf, { offset: offset });
          if (readLen <= 0) {
            break;
          }
          const writeData: ArrayBuffer = readLen < BUFFER_SIZE
            ? tempBuf.slice(0, readLen) : tempBuf;
          await fs.write(targetFile.fd, writeData);
          offset += readLen;
        }
      } finally {
        await fs.close(targetFile);
      }
    } finally {
      await fs.close(sourceFile);
    }

    return targetUri;
  }

  /**
   * 获取聊天背景配置。
   * 如果未设置过,返回默认值(enabled=false, imageUri='', blur=30, dim=30)。
   */
  async getConfig(chatId: string): Promise<ChatBackgroundConfig> {
    const enabledKey: string = this.buildKey(chatId, 'enabled');
    const blurKey: string = this.buildKey(chatId, 'blur');
    const dimKey: string = this.buildKey(chatId, 'dim');

    const enabled: boolean = await this.preferences.getBoolean(enabledKey, false);
    // AppPreferences 暂未提供 getNumber/putNumber,用字符串存储数字。
    const blurStr: string = await this.preferences.getString(blurKey, DEFAULT_BLUR.toString());
    const dimStr: string = await this.preferences.getString(dimKey, DEFAULT_DIM.toString());
    const blur: number = this.parseIntSafe(blurStr, DEFAULT_BLUR);
    const dim: number = this.parseIntSafe(dimStr, DEFAULT_DIM);

    // 文件是否存在决定 imageUri
    const targetPath: string = this.bgDirPath + '/' + chatId + '.jpg';
    let imageUri: string = '';
    try {
      const exists: boolean = fs.accessSync(targetPath);
      if (exists) {
        imageUri = 'file://' + targetPath;
      }
    } catch (_e) {
      imageUri = '';
    }

    return {
      enabled: enabled,
      imageUri: imageUri,
      blur: blur,
      dim: dim
    };
  }

  /**
   * 设置是否启用背景图。
   */
  async setEnabled(chatId: string, enabled: boolean): Promise<void> {
    const key: string = this.buildKey(chatId, 'enabled');
    await this.preferences.putBoolean(key, enabled);
  }

  /**
   * 设置模糊度(0~100)。
   */
  async setBlur(chatId: string, blur: number): Promise<void> {
    const clamped: number = this.clamp(blur, 0, MAX_BLUR);
    const key: string = this.buildKey(chatId, 'blur');
    // 用字符串存储数字。
    await this.preferences.putString(key, clamped.toString());
  }

  /**
   * 设置暗化程度(0~100)。
   */
  async setDim(chatId: string, dim: number): Promise<void> {
    const clamped: number = this.clamp(dim, 0, MAX_DIM);
    const key: string = this.buildKey(chatId, 'dim');
    await this.preferences.putString(key, clamped.toString());
  }

  /**
   * 删除聊天背景图(同时清理文件和 Preferences)。
   */
  async deleteBackground(chatId: string): Promise<void> {
    // 删除文件
    const targetPath: string = this.bgDirPath + '/' + chatId + '.jpg';
    try {
      const exists: boolean = fs.accessSync(targetPath);
      if (exists) {
        await fs.unlink(targetPath);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteBackground file failed: ' + (e as Error).message);
    }

    // 删除 Preferences
    const enabledKey: string = this.buildKey(chatId, 'enabled');
    const blurKey: string = this.buildKey(chatId, 'blur');
    const dimKey: string = this.buildKey(chatId, 'dim');
    await this.preferences.delete(enabledKey);
    await this.preferences.delete(blurKey);
    await this.preferences.delete(dimKey);
    // 同时删除思考强度(per-chat 设置一并清理)
    const effortKey: string = this.buildReasoningKey(chatId);
    await this.preferences.delete(effortKey);
  }

  // ===== 思考强度(reasoning_effort)=====

  /**
   * 获取聊天的思考强度配置。
   * 未设置过返回默认值(effort='',跟随 Provider 默认)。
   */
  async getReasoningEffort(chatId: string): Promise<ReasoningEffort> {
    const key: string = this.buildReasoningKey(chatId);
    const stored: string = await this.preferences.getString(key, DEFAULT_REASONING_EFFORT);
    // 校验合法性,非法值回退默认
    if (stored === 'none' || stored === 'low' || stored === 'medium' || stored === 'high') {
      return stored as ReasoningEffort;
    }
    return '';
  }

  /**
   * 设置聊天的思考强度。
   * @param chatId 聊天 ID
   * @param effort 档位,空字符串表示跟随 Provider 默认
   */
  async setReasoningEffort(chatId: string, effort: ReasoningEffort): Promise<void> {
    const key: string = this.buildReasoningKey(chatId);
    await this.preferences.putString(key, effort);
  }

  /**
   * 构造 Preferences key:chat_bg_<chatId>_<suffix>
   * chatId 只允许 [a-zA-Z0-9-_](由 Repository 生成),不需要转义。
   */
  private buildKey(chatId: string, suffix: string): string {
    return 'chat_bg_' + chatId + '_' + suffix;
  }

  /**
   * 构造思考强度 Preferences key:chat_reasoning_<chatId>_effort
   */
  private buildReasoningKey(chatId: string): string {
    return 'chat_reasoning_' + chatId + '_effort';
  }

  private clamp(value: number, min: number, max: number): number {
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }

  /**
   * 安全解析整数字符串,失败返回默认值。
   */
  private parseIntSafe(value: string, defValue: number): number {
    if (value.length === 0) {
      return defValue;
    }
    const parsed: number = parseInt(value, 10);
    if (isNaN(parsed)) {
      return defValue;
    }
    return parsed;
  }
}
