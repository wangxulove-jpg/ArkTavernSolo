/**
 * LocalImageTagText 本地图片「标签 = 提示词预设正文」的文本操作(纯函数)
 *
 * 模型(v50,用户定稿):所有图片一个池子,分组一律用**标签**表达;
 * 而**标签就是普通提示词预设** —— 「把这张图分到某个标签」= 在该预设正文里写一行
 * `- 图片名：描述`(描述可空)。因此"图片属于哪些标签"由正文**反推**,不存任何关联表。
 *
 * 约定(本文件是唯一定义处):
 * - 条目行:`- ` 开头,名字与描述之间用全角 `：` 分隔;描述为空时只写名字
 * - 名字以第一个 `：`/`:` 之前的内容为准(去首尾空白)
 * - 同一名字在多行出现时,upsert 只改第一行、remove 删除全部同名行
 *
 * 无副作用:不碰 DB / ArkUI;可直接在 host 侧单测。
 */

/** 条目行前缀 */
const ENTRY_PREFIX: string = '- ';
/** 条目名与描述的分隔符(写入用全角;读取时同时认半角) */
const ENTRY_SEPARATOR: string = '：';
const ENTRY_SEPARATOR_ASCII: string = ':';

/** 构建一条标签条目行(描述为空则只有名字) */
export function buildTagEntryLine(name: string, description: string): string {
  const trimmedName: string = name.trim();
  const trimmedDesc: string = description.trim();
  if (trimmedDesc.length === 0) {
    return ENTRY_PREFIX + trimmedName;
  }
  return ENTRY_PREFIX + trimmedName + ENTRY_SEPARATOR + trimmedDesc;
}

// ===== 标签预设的固定开头 =====

/** 固定开头的标记(幂等判据) */
const TAG_PRESET_HEADER_MARK: string = '【本地图片】';

/**
 * 新建标签(= 提示词预设)时写入的固定开头。
 *
 * 作用:光有图片名清单模型不知道那是"可用的图",必须显式告诉它调用方式。
 * 引用的语法与 parser/ChatTextParser 的 LOCAL_IMAGE_RE(`![alt](arkimg:名字)`)一致。
 *
 * 约束:整段**不得以 `- ` 起头** —— listTagEntryNames / hasTagEntry 只认 `- ` 行,
 * 否则开头会被反查成一张叫该文字的图片(见本文件顶部「约定」)。
 */
export const TAG_PRESET_HEADER: string = TAG_PRESET_HEADER_MARK
  + '需要配图时，在回复中直接输出：![简短描述](arkimg:图片名)\n'
  + '若该名字是视频，请改用：![简短描述](arkvid:视频名)\n'
  + '「图片名」必须与下方清单里的名字完全一致，不要改动或编造名字。\n\n'
  + '可用图片：';

/** 正文是否已带固定开头 */
export function hasTagPresetHeader(text: string): boolean {
  return text.indexOf(TAG_PRESET_HEADER_MARK) >= 0;
}

/**
 * 让正文带上固定开头(幂等:已有则原样返回)。
 * 用于新建标签,以及补齐早期建立(正文为空)的标签。
 */
export function ensureTagPresetHeader(text: string): string {
  if (hasTagPresetHeader(text)) {
    return text;
  }
  const trimmed: string = text.trim();
  return trimmed.length === 0 ? TAG_PRESET_HEADER : TAG_PRESET_HEADER + '\n' + trimmed;
}

/** 该行是否是一条标签条目 */
function isEntryLine(line: string): boolean {
  return line.trim().startsWith(ENTRY_PREFIX);
}

/** 从一条条目行里取名字(非条目行返回空串) */
function entryNameOf(line: string): string {
  const trimmed: string = line.trim();
  if (!trimmed.startsWith(ENTRY_PREFIX)) {
    return '';
  }
  const body: string = trimmed.substring(ENTRY_PREFIX.length);
  let cut: number = body.indexOf(ENTRY_SEPARATOR);
  const asciiCut: number = body.indexOf(ENTRY_SEPARATOR_ASCII);
  if (cut < 0) {
    cut = asciiCut;
  } else if (asciiCut >= 0 && asciiCut < cut) {
    cut = asciiCut;
  }
  return (cut >= 0 ? body.substring(0, cut) : body).trim();
}

/** 名字是否同一条目(去首尾空白后精确比较,与大小写无关的宽松匹配交给调用方) */
function isSameEntryName(lineName: string, name: string): boolean {
  return lineName === name.trim();
}

/**
 * 列出正文里所有标签条目的名字(按出现顺序,去重)。
 * 供"图片 → 标签"反查:正文提到该名字即视为打上该标签。
 */
export function listTagEntryNames(text: string): string[] {
  const names: string[] = [];
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const lineName: string = entryNameOf(lines[i]);
    if (lineName.length === 0) {
      continue;
    }
    if (names.indexOf(lineName) < 0) {
      names.push(lineName);
    }
  }
  return names;
}

/** 正文是否已包含该名字的条目 */
export function hasTagEntry(text: string, name: string): boolean {
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const lineName: string = entryNameOf(lines[i]);
    if (lineName.length > 0 && isSameEntryName(lineName, name)) {
      return true;
    }
  }
  return false;
}

/**
 * 写入/更新一条标签条目:
 * - 已有同名条目 → 替换为首行(保留该行位置)
 * - 没有 → 追加到末尾(必要时补一个换行分隔)
 * 正文为空白时直接返回单行条目。
 */
export function upsertTagEntry(text: string, name: string, description: string): string {
  const line: string = buildTagEntryLine(name, description);
  const lines: string[] = text.split('\n');
  let replaced: boolean = false;
  for (let i = 0; i < lines.length; i++) {
    const lineName: string = entryNameOf(lines[i]);
    if (lineName.length > 0 && isSameEntryName(lineName, name)) {
      if (!replaced) {
        lines[i] = line;
        replaced = true;
      } else {
        lines[i] = ''; // 多余的同名行清空(保持行数稳定之外的确定性:同名只留一行)
      }
    }
  }
  if (!replaced) {
    if (text.length === 0) {
      return line;
    }
    return text + (text.endsWith('\n') ? '' : '\n') + line;
  }
  // 清空可能产生的尾部空行
  while (lines.length > 0 && lines[lines.length - 1].trim().length === 0) {
    lines.pop();
  }
  return lines.join('\n');
}

/**
 * 删除该名字的全部标签条目行(其余内容原样保留)。
 * 删空后返回空串之外的残留空白会被收敛。
 */
export function removeTagEntry(text: string, name: string): string {
  const lines: string[] = text.split('\n');
  const kept: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const lineName: string = entryNameOf(lines[i]);
    if (lineName.length > 0 && isSameEntryName(lineName, name)) {
      continue;
    }
    kept.push(lines[i]);
  }
  // 去掉首尾空白行,避免反复增删后正文堆空行
  while (kept.length > 0 && kept[0].trim().length === 0) {
    kept.shift();
  }
  while (kept.length > 0 && kept[kept.length - 1].trim().length === 0) {
    kept.pop();
  }
  return kept.join('\n');
}

/** 正文是否只由标签条目组成(删空后调用方可据此删除预设——目前不做自动删除) */
export function hasOnlyTagEntries(text: string): boolean {
  const lines: string[] = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].trim().length === 0) {
      continue;
    }
    if (!isEntryLine(lines[i])) {
      return false;
    }
  }
  return true;
}