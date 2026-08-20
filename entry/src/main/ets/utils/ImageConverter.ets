/**
 * ImageConverter 图片格式转换工具
 *
 * 职责:
 * - 读取任意支持格式(PNG/JPG/JPEG/WebP/BMP/GIF)的图片文件
 * - 通过 HarmonyOS Image Kit 解码为 PixelMap
 * - 重新编码为 PNG 格式返回字节数组
 *
 * 不依赖:
 * - ArkUI / 业务层 / 数据库 / 存储
 *
 * 用途:
 * - 导入头像时统一转为 PNG 存储,避免导出角色卡时格式不兼容
 * - 导出 PNG 角色卡时,旧的非 PNG 头像兜底转换
 *
 * 失败策略:
 * - 解码失败:抛错(调用方决定是否 fallback 到占位图)
 * - 编码失败:抛错
 * - 资源释放在 finally 中保证
 */

import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from './Logger';

const LOG_TAG: string = 'ImageConverter';

/** PNG 签名:8 字节 */
const PNG_SIGNATURE: number[] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/** PNG 编码质量(0-100,PNG 是无损格式,质量参数对 PNG 不影响,但 API 要求传值) */
const PNG_PACK_QUALITY: number = 100;

/**
 * 校验字节数组是否以 PNG 签名开头。
 */
export function isPngBytes(bytes: Uint8Array): boolean {
  if (bytes.byteLength < PNG_SIGNATURE.length) {
    return false;
  }
  for (let i = 0; i < PNG_SIGNATURE.length; i++) {
    if (bytes[i] !== PNG_SIGNATURE[i]) {
      return false;
    }
  }
  return true;
}

/**
 * 将任意支持格式的图片文件转换为 PNG 字节数组。
 *
 * 流程:
 * 1. 通过 fileIo 打开源文件获取 fd
 * 2. image.createImageSource(fd) 创建 ImageSource
 * 3. imageSource.createPixelMap() 解码为 PixelMap
 * 4. image.createImagePacker() 创建 ImagePacker
 * 5. imagePacker.packing(pixelMap, { format: 'image/png', quality: 100 }) 返回 ArrayBuffer
 * 6. 释放资源
 *
 * @param sourceUri 源图片 URI(file:// 或 fd 路径)
 * @returns PNG 字节数组
 * @throws 解码/编码失败时抛错
 */
export async function convertUriToPngBytes(sourceUri: string): Promise<Uint8Array> {
  let srcFile: fileIo.File | null = null;
  let imageSource: image.ImageSource | null = null;
  let pixelMap: image.PixelMap | null = null;
  let imagePacker: image.ImagePacker | null = null;

  try {
    srcFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
    imageSource = image.createImageSource(srcFile.fd);
    if (imageSource === null) {
      throw new Error('createImageSource 返回 null');
    }
    pixelMap = await imageSource.createPixelMap();
    if (pixelMap === null) {
      throw new Error('createPixelMap 返回 null');
    }
    imagePacker = image.createImagePacker();
    if (imagePacker === null) {
      throw new Error('createImagePacker 返回 null');
    }
    const packOptions: image.PackingOption = {
      format: 'image/png',
      quality: PNG_PACK_QUALITY
    };
    const buffer: ArrayBuffer = await imagePacker.packing(pixelMap, packOptions);
    return new Uint8Array(buffer);
  } catch (e) {
    Logger.error(LOG_TAG, 'convertUriToPngBytes failed: ' + String(e));
    throw new Error('图片转换为 PNG 失败: ' + String(e));
  } finally {
    // 严格按相反顺序释放资源
    if (imagePacker !== null) {
      try {
        imagePacker.release();
      } catch (e) {
        Logger.warn(LOG_TAG, 'imagePacker.release ignored: ' + String(e));
      }
    }
    if (pixelMap !== null) {
      try {
        pixelMap.release();
      } catch (e) {
        Logger.warn(LOG_TAG, 'pixelMap.release ignored: ' + String(e));
      }
    }
    if (imageSource !== null) {
      try {
        imageSource.release();
      } catch (e) {
        Logger.warn(LOG_TAG, 'imageSource.release ignored: ' + String(e));
      }
    }
    if (srcFile !== null) {
      try {
        fileIo.closeSync(srcFile);
      } catch (e) {
        Logger.warn(LOG_TAG, 'srcFile.closeSync ignored: ' + String(e));
      }
    }
  }
}
