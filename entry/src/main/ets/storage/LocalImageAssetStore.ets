/**
 * LocalImageAssetStore 本地图片文件管理
 *
 * 负责用户导入的图片/表情包/GIF 文件的持久化。
 * 文件存储在应用私有目录,避免外部 URI 失效。
 *
 * 职责:
 * - 将导入图片(PNG/JPG/JPEG/WebP/BMP/GIF)逐字节复制到应用私有目录
 * - 生成安全文件名,保留源文件扩展名(含 GIF 动画原样保留)
 * - 删除图片时同步删除文件
 *
 * 为何不能复用 CharacterAssetStore:它的目录名/文件名前缀/角色语义均硬编码为
 * 头像场景(avatars 目录、avatar_ 前缀、按 characterId 归档),泛化它会超出本次
 * 改动的外科范围。
 *
 * 约束:
 * - 不依赖 ArkUI
 * - 不依赖网络/数据库
 * - 使用 @kit.CoreFileKit 进行文件操作
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'LocalImageAssetStore';
const IMAGE_DIR: string = 'local_images';
const IMAGE_PREFIX: string = 'img_';
/** 支持的图片扩展名(小写,含点) */
const SUPPORTED_EXTENSIONS: string[] = ['.png', '.jpg', '.jpeg', '.webp', '.bmp', '.gif'];
/** 默认扩展名(无法识别时使用) */
const DEFAULT_EXTENSION: string = '.png';
/** 单文件大小上限 50MB */
const MAX_FILE_SIZE: number = 50 * 1024 * 1024;
/**
 * 送 AI 视觉任务时的单图体积上限 4MB。
 * 与 MAX_FILE_SIZE 分开:base64 会让体积膨胀约 1.37 倍,
 * 50MB 上限对进请求体(且是移动网络上传)明显过大。
 */
const VISION_IMAGE_MAX_BYTES: number = 4 * 1024 * 1024;

/** 扩展名 → MIME(不在表内按 image/png) */
function mimeTypeForExtension(ext: string): string {
  if (ext === '.jpg' || ext === '.jpeg') {
    return 'image/jpeg';
  }
  if (ext === '.webp') {
    return 'image/webp';
  }
  if (ext === '.gif') {
    return 'image/gif';
  }
  if (ext === '.bmp') {
    return 'image/bmp';
  }
  return 'image/png';
}

export class LocalImageAssetStore {
  private baseDir: string = '';
  private initialized: boolean = false;

  /**
   * 初始化,创建本地图片目录。
   */
  initialize(context: common.Context): void {
    const filesDir: string = context.filesDir;
    this.baseDir = filesDir + '/' + IMAGE_DIR;
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
      throw new Error('LocalImageAssetStore not initialized');
    }
  }

  /**
   * 从源 URI 提取小写扩展名(含点)。无法识别时返回 DEFAULT_EXTENSION。
   *
   * 处理场景:
   * - 标准 URI:file:///path/to/pic.png -> ".png"
   * - 带 query 参数:/path/pic.jpg?token=xxx -> ".jpg"
   * - 无扩展名或扩展名不在支持列表:/path/pic -> ".png"
   * - 大写扩展名:pic.PNG -> ".png"
   */
  private extractExtension(sourceUri: string): string {
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
   * 逐字节读取源文件。
   * 不使用图片转码,避免 GIF 动画被转成静态 PNG 丢失动画。
   *
   * @param sourceUri 源文件 URI
   * @param maxBytes 允许的最大字节数
   * @returns 源文件字节
   * @throws Error 文件超过 maxBytes
   */
  private readSourceBytes(sourceUri: string, maxBytes: number): ArrayBuffer {
    const srcFile: fileIo.File = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = fileIo.statSync(srcFile.fd);
      if (stat.size > maxBytes) {
        throw new Error('图片文件过大,超过上限 ' + maxBytes.toString() + ' 字节');
      }
      const bytes: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(srcFile.fd, bytes);
      return bytes;
    } finally {
      fileIo.closeSync(srcFile);
    }
  }

  /**
   * 读沙箱图片并编码为 base64 data URL(供"AI 视觉任务"作为图片输入)。
   *
   * 与 saveImage 不同,这里用**独立的小体积上限**(VISION_IMAGE_MAX_BYTES):
   * base64 会让体积膨胀约 1.37 倍,过大的原图会让请求体极度臃肿。
   *
   * @param fileUri 沙箱内 file:// URI
   * @returns `data:<mime>;base64,<数据>`
   * @throws Error 文件不可读或超过上限
   */
  async readImageAsDataUrl(fileUri: string): Promise<string> {
    this.requireInit();
    const ext: string = this.extractExtension(fileUri);
    let bytes: ArrayBuffer;
    try {
      bytes = this.readSourceBytes(fileUri, VISION_IMAGE_MAX_BYTES);
    } catch (e) {
      Logger.warn(LOG_TAG, 'readImageAsDataUrl failed: ' + String(e));
      if (String(e).indexOf('图片文件过大') >= 0) {
        throw new Error('图片过大,无法用于 AI 识别(上限 4MB)');
      }
      throw new Error('读取图片失败');
    }
    const helper: util.Base64Helper = new util.Base64Helper();
    const encoded: string = helper.encodeToStringSync(new Uint8Array(bytes));
    return 'data:' + mimeTypeForExtension(ext) + ';base64,' + encoded;
  }

  /**
   * 复制图片文件到应用私有目录。
   *
   * 文件名格式:img_<imageId>_<timestamp><ext>
   * - ext 保留源文件扩展名(png/jpg/jpeg/webp/bmp/gif),不在支持列表时默认 .png
   * - 每次保存生成新文件名,避免覆盖旧文件导致 ArkUI Image 缓存失效问题
   * - 旧文件由调用方通过 deleteByUri 显式删除
   *
   * @param sourceUri 源文件 URI
   * @param imageId 图片 ID(形如 img-<uuid>)
   * @returns 新的图片文件 URI
   */
  async saveImage(sourceUri: string, imageId: string): Promise<string> {
    this.requireInit();
    const timestamp: number = Date.now();
    const ext: string = this.extractExtension(sourceUri);
    const destPath: string = this.baseDir + '/' + IMAGE_PREFIX + imageId + '_' + timestamp + ext;
    try {
      const bytes: ArrayBuffer = this.readSourceBytes(sourceUri, MAX_FILE_SIZE);
      const destFile: fileIo.File =
        fileIo.openSync(destPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE);
      try {
        fileIo.writeSync(destFile.fd, bytes);
      } finally {
        fileIo.closeSync(destFile);
      }
      return 'file://' + destPath;
    } catch (e) {
      Logger.error(LOG_TAG, 'saveImage failed: ' + String(e));
      if (String(e).indexOf('图片文件过大') >= 0) {
        throw new Error('图片文件过大,不能超过 50MB');
      }
      throw new Error('保存图片失败: ' + String(e));
    }
  }

  /**
   * 按精确 URI 删除图片文件。
   * 文件不存在时静默成功。
   *
   * @param fileUri 完整的 file:// URI
   */
  async deleteByUri(fileUri: string): Promise<void> {
    this.requireInit();
    if (fileUri.length === 0) {
      return;
    }
    let path: string = fileUri;
    if (path.startsWith('file://')) {
      path = path.substring('file://'.length);
    }
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteByUri ignored: ' + String(e));
    }
  }
}