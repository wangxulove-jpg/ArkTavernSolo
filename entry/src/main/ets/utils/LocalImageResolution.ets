/**
 * LocalImageResolution 本地图片的渲染解析映射(纯函数)
 *
 * v50 起是**图片池**模型:所有图片一个池子,不做任何范围过滤
 * (AI 能看到哪些图由会话启用了哪些提示词预设决定,与解析无关)。
 * v51 起映射值携带**媒体类型**:渲染层据此决定用 Image(图片/GIF)还是 Video(视频)。
 *
 * 视频额外做一次 URI 形式转换:落库的是 `file:///绝对路径`,
 * 而 ArkUI Video 只认沙箱 URI `file://<bundleName>/<sandboxPath>`,故在此统一转换。
 *
 * 无业务副作用:不碰 DB / ArkUI;可直接在 host 侧单测。
 */

import { fileUri as fileUriKit } from '@kit.CoreFileKit';
import { LocalImage, LocalImageMediaType } from '../models/LocalImage';

/** 一条解析结果:文件 URI + 媒体类型 */
export interface LocalImageResolution {
  readonly uri: string;
  /** 媒体类型:image / gif / video(决定渲染组件) */
  readonly mediaType: LocalImageMediaType;
}

/**
 * 视频 URI 转为 Video 组件可识别的沙箱形式(`file://<bundleName>/<sandboxPath>`)。
 * 仅处理 `file:///绝对路径` 形式;其它形式(理论不出现)原样返回;
 * 非视频类型原样返回。聊天渲染与图片库详情播放共用此转换。
 */
export function toPlayableUri(uri: string, mediaType: LocalImageMediaType): string {
  if (mediaType !== 'video') {
    return uri;
  }
  if (!uri.startsWith('file:///')) {
    return uri;
  }
  const path: string = uri.substring('file://'.length);
  try {
    return fileUriKit.getUriFromPath(path);
  } catch (e) {
    return uri;
  }
}

/** 图片列表 → 归一化名字到解析结果的映射(渲染层按 nameKey 大小写不敏感匹配) */
export function toResolutionMap(images: LocalImage[]): Record<string, LocalImageResolution> {
  const map: Record<string, LocalImageResolution> = {};
  for (let i = 0; i < images.length; i++) {
    const image: LocalImage = images[i];
    map[image.nameKey] = {
      uri: toPlayableUri(image.fileUri, image.mediaType),
      mediaType: image.mediaType
    };
  }
  return map;
}