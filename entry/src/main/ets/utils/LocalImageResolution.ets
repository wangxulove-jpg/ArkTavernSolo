/**
 * LocalImageResolution 本地图片的渲染解析映射(纯函数)
 *
 * v50 起是**图片池**模型:所有图片一个池子,不再分「全局 / 角色专属」,
 * 因此"名字 → 文件"的映射就是**全部图片**,不做任何范围过滤
 * (AI 能看到哪些图由会话启用了哪些提示词预设决定,与解析无关)。
 *
 * 无副作用:不碰 DB / ArkUI;可直接在 host 侧单测。
 */

import { LocalImage } from '../models/LocalImage';

/** 图片列表 → 归一化名字到文件 URI 的映射(渲染层按 nameKey 大小写不敏感匹配) */
export function toResolutionMap(images: LocalImage[]): Record<string, string> {
  const map: Record<string, string> = {};
  for (let i = 0; i < images.length; i++) {
    map[images[i].nameKey] = images[i].fileUri;
  }
  return map;
}