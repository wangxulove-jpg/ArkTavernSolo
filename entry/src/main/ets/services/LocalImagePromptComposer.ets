/**
 * LocalImagePromptComposer 本地图片清单提示词构建(纯函数)
 *
 * 产出一段 System Prompt:告诉模型"有哪些本地图片可调用、怎么调用"。
 * 该段由 LocalImageService 写入**受管预设**的 systemPrompt,受管预设固定在
 * 末尾(tail / PostHistory)注入 —— 清单变化不影响它前面的缓存前缀。
 *
 * 稳定性要求:清单必须逐字节可复现 —— 按 nameKey 升序排序,不按插入时间。
 *
 * 不依赖 ArkUI / RDB / Provider。
 */

import { LocalImage } from '../models/LocalImage';

/** 固定规则段(用户不可编辑;若要不同措辞请自建预设) */
const RULE_LINES: string[] = [
  '【本地图片】对方预先导入了一些本地图片/表情包,你可以在回复正文里调用它们来增强表现力。',
  '调用写法:在需要插图的位置原样写出 ![简短描述](arkimg:图片名),「图片名」必须严格取自下面的清单。',
  '约束:只用清单里存在的名字(不要自造、不要改大小写以外的写法);一次回复最多插 1~2 张,不要连续堆图;',
  '不要把这段说明复述给对方,也不要输出任何文件路径。清单里没有合适的图片时,正常用文字表达即可。'
];

/**
 * 构建受管预设的 systemPrompt。
 * 无图片时返回空串(调用方据此删除受管预设)。
 *
 * @param images 该作用域内的图片(不要求已排序,函数内部排序)
 * @param scopeScopeLabel 作用域展示名(如「全局」/ 角色名),仅作标题
 */
export function buildLocalImageSystemPrompt(images: LocalImage[], scopeLabel: string): string {
  if (images.length === 0) {
    return '';
  }
  // 稳定排序:按归一化名字升序(保证库未变时逐字节一致)
  const sorted: LocalImage[] = [...images];
  sorted.sort((a: LocalImage, b: LocalImage): number => {
    if (a.nameKey < b.nameKey) {
      return -1;
    }
    if (a.nameKey > b.nameKey) {
      return 1;
    }
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0);
  });

  const lines: string[] = [];
  lines.push(RULE_LINES[0]);
  lines.push(RULE_LINES[1]);
  lines.push(RULE_LINES[2]);
  lines.push(RULE_LINES[3]);
  lines.push('');
  lines.push(`可用图片(${scopeLabel},共 ${sorted.length} 张):`);
  for (let i = 0; i < sorted.length; i++) {
    lines.push('- ' + sorted[i].name);
  }
  return lines.join('\n');
}

/** 受管预设名 */
export function buildLocalImagePresetName(scopeLabel: string): string {
  return `本地图片清单(${scopeLabel})`;
}

/** 受管预设描述 */
export function buildLocalImagePresetDescription(imageCount: number): string {
  return `由「本地图片库」自动维护(${imageCount} 张),请勿手动编辑;位置固定在末尾。`;
}