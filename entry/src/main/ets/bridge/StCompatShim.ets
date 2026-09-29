/**
 * StCompatShim ST 兼容层加载器
 *
 * 职责:把 rawfile/st_compat/ 下的 jQuery 与酒馆助手 API shim(st_shim.js)
 * 读成字符串(进程内缓存一次),由 CardFrontendWeb 在 loadData 前注入到卡片 HTML 的 <head>,
 * 使从 SillyTavern 原文导入的前端页面(依赖 TavernHelper/jQuery/酒馆事件)可直接运行,
 * 数据接自 window.arktavern Bridge(契约 v3)。
 *
 * 分层:bridge 层(与 CardFrontendBridge 同层);只读资源,无副作用;
 * shim 能力边界与已映射 API 清单见 rawfile/st_compat/st_shim.js 头注释与
 * docs/frontend-card-contract.md「ST 兼容层」一节。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'StCompatShim';

/** 兼容层脚本缓存(内容固定,读一次;读失败缓存空串,后续注入自然跳过) */
let cachedScripts: string | null = null;

/**
 * 读取 ST 兼容层脚本(jquery.min.js + st_shim.js,拼接为一段)。
 * 返回空串表示资源缺失(原生 ArkTavern 卡不受影响,注入为 no-op)。
 */
export function loadStCompatScripts(context: common.Context): string {
  if (cachedScripts !== null) {
    return cachedScripts;
  }
  try {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    const jquery: string = decoder.decodeToString(
      context.resourceManager.getRawFileContentSync('st_compat/jquery.min.js')
    );
    const shim: string = decoder.decodeToString(
      context.resourceManager.getRawFileContentSync('st_compat/st_shim.js')
    );
    cachedScripts = jquery + '\n;\n' + shim;
    Logger.info(LOG_TAG, 'ST compat scripts loaded: ' + (cachedScripts.length / 1024).toFixed(1) + 'KB');
  } catch (e) {
    cachedScripts = '';
    Logger.warn(LOG_TAG, 'ST compat scripts unavailable: ' + (e as Error).message);
  }
  return cachedScripts;
}
