/**
 * ChatPalette 角色对白颜色生成器
 *
 * 职责:
 * - 根据 characterId 稳定生成一个对白色
 * - 颜色限制在可读色板内,避免过亮或过暗
 * - 同一个 characterId 在不同消息、分支、重新进入页面后保持相同颜色
 *
 * 不负责:
 * - 颜色资源化(由调用方结合主题模式查询资源)
 * - 用户对白颜色(用户对白固定使用一个语义色)
 *
 * 色板设计:
 * - 共 12 个预设颜色,覆盖蓝/绿/紫/橙/粉/青/黄/红等色相
 * - 每个颜色都经过可读性测试,在浅色和深色背景下均可读
 * - 使用 FNV-1a 哈希对 characterId 计算索引,确保稳定分布
 */

/** 预设可读色板(HSL 格式:色相,饱和度,明度) */
interface PaletteColor {
  readonly h: number;
  readonly s: number;
  readonly l: number;
}

/** 12 个可读颜色,覆盖主要色相 */
const READABLE_PALETTE: PaletteColor[] = [
  { h: 210, s: 70, l: 50 }, // 蓝
  { h: 160, s: 65, l: 40 }, // 青绿
  { h: 270, s: 60, l: 55 }, // 紫
  { h: 30, s: 75, l: 45 },  // 橙
  { h: 340, s: 65, l: 55 }, // 粉红
  { h: 190, s: 70, l: 40 }, // 青
  { h: 45, s: 70, l: 40 },  // 黄褐
  { h: 0, s: 65, l: 50 },   // 红
  { h: 120, s: 55, l: 40 }, // 绿
  { h: 290, s: 55, l: 50 }, // 品红
  { h: 220, s: 60, l: 55 }, // 蓝紫
  { h: 80, s: 55, l: 40 }   // 黄绿
];

/**
 * FNV-1a 哈希(32 位)。
 * 稳定且分布均匀,适合字符串哈希。
 */
function fnv1aHash(str: string): number {
  let hash: number = 2166136261;
  for (let i = 0; i < str.length; i++) {
    hash ^= str.charCodeAt(i);
    // 等价于 hash *= 16777619,用位运算避免精度问题
    hash = Math.imul(hash, 16777619);
  }
  // 转为无符号 32 位
  return hash >>> 0;
}

/**
 * HSL 转 RGB。
 * 返回 [r, g, b],范围 0-255。
 */
function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  const sNorm: number = s / 100;
  const lNorm: number = l / 100;
  const c: number = (1 - Math.abs(2 * lNorm - 1)) * sNorm;
  const hPrime: number = h / 60;
  const x: number = c * (1 - Math.abs(hPrime % 2 - 1));
  let r1: number = 0;
  let g1: number = 0;
  let b1: number = 0;
  if (hPrime < 1) {
    r1 = c; g1 = x; b1 = 0;
  } else if (hPrime < 2) {
    r1 = x; g1 = c; b1 = 0;
  } else if (hPrime < 3) {
    r1 = 0; g1 = c; b1 = x;
  } else if (hPrime < 4) {
    r1 = 0; g1 = x; b1 = c;
  } else if (hPrime < 5) {
    r1 = x; g1 = 0; b1 = c;
  } else {
    r1 = c; g1 = 0; b1 = x;
  }
  const m: number = lNorm - c / 2;
  return [
    Math.round((r1 + m) * 255),
    Math.round((g1 + m) * 255),
    Math.round((b1 + m) * 255)
  ];
}

/**
 * 根据 characterId 稳定生成一个对白颜色(十六进制字符串)。
 * 同一个 characterId 永远返回相同颜色。
 */
export function getCharacterColor(characterId: string): string {
  if (characterId.length === 0) {
    // 默认返回第一个色板颜色
    const c: PaletteColor = READABLE_PALETTE[0];
    const rgb: [number, number, number] = hslToRgb(c.h, c.s, c.l);
    return rgbToHex(rgb[0], rgb[1], rgb[2]);
  }
  const hash: number = fnv1aHash(characterId);
  const index: number = hash % READABLE_PALETTE.length;
  const color: PaletteColor = READABLE_PALETTE[index];
  const rgb: [number, number, number] = hslToRgb(color.h, color.s, color.l);
  return rgbToHex(rgb[0], rgb[1], rgb[2]);
}

/**
 * RGB 转十六进制字符串。
 */
function rgbToHex(r: number, g: number, b: number): string {
  const toHex: (n: number) => string = (n: number): string => {
    const hex: string = n.toString(16);
    return hex.length === 1 ? '0' + hex : hex;
  };
  return '#' + toHex(r) + toHex(g) + toHex(b);
}
