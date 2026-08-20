/**
 * CharacterAssetStore 角色资源文件管理
 *
 * 负责角色头像等资源文件的持久化。
 * 文件存储在应用私有目录,避免外部 URI 失效。
 *
 * 职责:
 * - 将导入图片(PNG/JPG/JPEG/WebP/BMP/GIF)复制到应用私有目录
 * - 生成安全文件名,保留源文件扩展名
 * - 删除角色时同步删除头像文件
 * - 不保存外部临时 URI 作为长期头像地址
 *
 * 约束:
 * - 不依赖 ArkUI
 * - 不依赖网络/数据库
 * - 使用 @kit.CoreFileKit 进行文件操作
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterAssetStore';
const AVATAR_DIR: string = 'avatars';
const AVATAR_PREFIX: string = 'avatar_';
/** 支持的图片扩展名(小写,含点) */
const SUPPORTED_EXTENSIONS: string[] = ['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'];
/** 默认扩展名(无法识别时使用) */
const DEFAULT_EXTENSION: string = '.png';

export class CharacterAssetStore {
  private baseDir: string = '';
  private initialized: boolean = false;

  /**
   * 初始化,创建头像目录。
   */
  initialize(context: common.Context): void {
    const filesDir: string = context.filesDir;
    this.baseDir = filesDir + '/' + AVATAR_DIR;
    try {
      if (!fileIo.accessSync(this.baseDir)) {
        fileIo.mkdirSync(this.baseDir, true);
      }
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize mkdir failed: ' + String(e));
    }
    this.initialized = true;
  }

  private requireInit(): void {
    if (!this.initialized) {
      throw new Error('CharacterAssetStore not initialized');
    }
  }

  /**
   * 从源 URI 提取小写扩展名(含点)。无法识别时返回 DEFAULT_EXTENSION。
   *
   * 处理场景:
   * - 标准 URI:file:///path/to/avatar.png -> ".png"
   * - 带 query 参数:/path/avatar.jpg?token=xxx -> ".jpg"
   * - 无扩展名或扩展名不在支持列表:/path/avatar -> ".png"
   * - 大写扩展名:avatar.PNG -> ".png"
   */
  private extractExtension(sourceUri: string): string {
    // 剥离 query 参数(?之后)和 fragment(#之后)
    let path: string = sourceUri;
    const queryIdx: number = path.indexOf('?');
    if (queryIdx >= 0) {
      path = path.substring(0, queryIdx);
    }
    const fragIdx: number = path.indexOf('#');
    if (fragIdx >= 0) {
      path = path.substring(0, fragIdx);
    }
    const lastSlash: number = path.lastIndexOf('/');
    const filename: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    const lastDot: number = filename.lastIndexOf('.');
    if (lastDot < 0 || lastDot === filename.length - 1) {
      return DEFAULT_EXTENSION;
    }
    const ext: string = filename.substring(lastDot).toLowerCase();
    if (SUPPORTED_EXTENSIONS.indexOf(ext) < 0) {
      return DEFAULT_EXTENSION;
    }
    return ext;
  }

  /**
   * 复制头像文件到应用私有目录。
   *
   * 文件名格式:avatar_<characterId>_<timestamp>.<ext>
   * - ext 保留源文件扩展名(png/jpg/jpeg/webp/bmp/gif),不在支持列表时默认 .png
   * - 每次保存生成新文件名,避免覆盖旧文件导致 ArkUI Image 缓存失效问题
   * - 旧文件由调用方通过 deleteAvatarByUri 显式删除
   * - deleteAvatar(characterId) 仍可扫描删除该角色的所有历史头像(任意扩展名)
   *
   * @param sourceUri 源文件 URI
   * @param characterId 角色 ID
   * @returns 新的头像文件 URI(带时间戳,保留源扩展名)
   */
  async saveAvatar(sourceUri: string, characterId: string): Promise<string> {
    this.requireInit();
    const timestamp: number = Date.now();
    const ext: string = this.extractExtension(sourceUri);
    const destPath: string = this.baseDir + '/' + AVATAR_PREFIX + characterId + '_' + timestamp + ext;
    try {
      const srcFile: fileIo.File = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
      const stat: fileIo.Stat = fileIo.statSync(srcFile.fd);
      if (stat.size > 50 * 1024 * 1024) {
        fileIo.closeSync(srcFile);
        throw new Error('头像文件过大,不能超过 50MB');
      }
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(srcFile.fd, buffer);
      fileIo.closeSync(srcFile);

      const destFile: fileIo.File = fileIo.openSync(destPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      fileIo.writeSync(destFile.fd, buffer);
      fileIo.closeSync(destFile);

      return 'file://' + destPath;
    } catch (e) {
      Logger.error(LOG_TAG, 'saveAvatar failed: ' + String(e));
      throw new Error('保存头像失败: ' + String(e));
    }
  }

  /**
   * 将 PNG 字节数组直接写入应用私有目录作为头像。
   *
   * 用途:
   * - 配合 ImageConverter 实现导入时统一转 PNG 存储
   * - 文件名格式同 saveAvatar,但扩展名固定为 .png
   * - 旧文件由调用方通过 deleteAvatarByUri 显式删除
   *
   * @param pngBytes PNG 字节数组(必须为合法 PNG)
   * @param characterId 角色 ID
   * @returns 新的头像文件 URI(带时间戳,扩展名 .png)
   */
  async savePngAvatarFromBytes(pngBytes: Uint8Array, characterId: string): Promise<string> {
    this.requireInit();
    const timestamp: number = Date.now();
    const destPath: string = this.baseDir + '/' + AVATAR_PREFIX + characterId + '_' + timestamp + '.png';
    try {
      if (pngBytes.byteLength > 50 * 1024 * 1024) {
        throw new Error('头像文件过大,不能超过 50MB');
      }
      const destFile: fileIo.File = fileIo.openSync(destPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      fileIo.writeSync(destFile.fd, pngBytes.buffer as ArrayBuffer);
      fileIo.closeSync(destFile);

      return 'file://' + destPath;
    } catch (e) {
      Logger.error(LOG_TAG, 'savePngAvatarFromBytes failed: ' + String(e));
      throw new Error('保存 PNG 头像失败: ' + String(e));
    }
  }

  /**
   * 按精确 URI 删除头像文件。
   * 用于在 updateAvatar 流程中清理被替换的旧头像文件。
   * 文件不存在时静默成功。
   *
   * @param avatarUri 完整的 file:// URI
   */
  async deleteAvatarByUri(avatarUri: string): Promise<void> {
    this.requireInit();
    if (avatarUri.length === 0) {
      return;
    }
    let path: string = avatarUri;
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    }
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteAvatarByUri ignored: ' + String(e));
    }
  }

  /**
   * 删除角色所有头像文件(包括带时间戳的历史版本,任意扩展名)。
   * 文件不存在时静默成功。
   * 用于删除角色时清理全部头像文件。
   *
   * @param characterId 角色 ID
   */
  async deleteAvatar(characterId: string): Promise<void> {
    this.requireInit();
    try {
      const filenames: string[] = fileIo.listFileSync(this.baseDir);
      const prefix: string = AVATAR_PREFIX + characterId;
      for (let i = 0; i < filenames.length; i++) {
        const name: string = filenames[i];
        if (!name.startsWith(prefix)) {
          continue;
        }
        // 校验扩展名是否在支持列表(避免误删 .tmp / 系统文件)
        const lowerName: string = name.toLowerCase();
        let matched: boolean = false;
        for (let j = 0; j < SUPPORTED_EXTENSIONS.length; j++) {
          if (lowerName.endsWith(SUPPORTED_EXTENSIONS[j])) {
            matched = true;
            break;
          }
        }
        if (!matched) {
          continue;
        }
        const fullPath: string = this.baseDir + '/' + name;
        try {
          if (fileIo.accessSync(fullPath)) {
            fileIo.unlinkSync(fullPath);
          }
        } catch (e) {
          Logger.warn(LOG_TAG, 'deleteAvatar skip ' + name + ': ' + String(e));
        }
      }
    } catch (e) {
      // 目录不存在或读取失败,静默处理
      Logger.warn(LOG_TAG, 'deleteAvatar listSync ignored: ' + String(e));
    }
  }
}