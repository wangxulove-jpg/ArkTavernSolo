/**
 * PngCharacterCardParser PNG 角色卡解析器
 *
 * 解析 PNG 文件中嵌入的角色卡文本元数据。
 * 仅负责:
 * - 校验 PNG 签名
 * - 遍历 chunk
 * - 读取 tEXt chunk 中角色数据
 * - Base64 解码
 * - 返回 JSON 字符串(由 CharacterCardJsonParser 进一步解析)
 *
 * 不重复角色字段映射,不解析 Base64 后的 JSON。
 *
 * 约束:
 * - 不依赖 ArkUI、网络、存储
 * - 纯逻辑解析,可本地单元测试
 */

/** tEXt chunk 解析结果 */
export interface PngTextChunk {
  keyword: string;
  text: string;
}

/** PNG 解析结果 */
export interface PngParseResult {
  /** 是否成功 */
  success: boolean;
  /** 解码后的 JSON 字符串(V2 chara 或 V3 ccv3) */
  jsonString: string;
  /** 来源格式标识 */
  sourceFormat: string;
  /** 错误信息 */
  error: string;
}

/** PNG 签名:8 字节 */
const PNG_SIGNATURE: number[] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/** tEXt chunk 类型 */
const CHUNK_TYPE_TEXT: string = 'tEXt';

/** 最大文件大小:50MB */
const MAX_FILE_SIZE: number = 50 * 1024 * 1024;

/** 最大 tEXt 文本长度:10MB */
const MAX_TEXT_LENGTH: number = 10 * 1024 * 1024;

/** 最大 chunk 数量(防止恶意文件) */
const MAX_CHUNK_COUNT: number = 10000;

/** 最大 chunk 数据长度:100MB */
const MAX_CHUNK_DATA_LENGTH: number = 100 * 1024 * 1024;

/**
 * 从 PNG 文件字节数据解析角色卡。
 * 优先使用 ccv3(V3),其次 chara(V2)。
 *
 * @param bytes PNG 文件字节数组
 * @returns PngParseResult
 */
export function parsePngCharacterCard(bytes: Uint8Array): PngParseResult {
  // 检查文件大小
  if (bytes.byteLength > MAX_FILE_SIZE) {
    return { success: false, jsonString: '', sourceFormat: '', error: '文件过大,不能超过 50MB' };
  }

  if (bytes.byteLength < PNG_SIGNATURE.length) {
    return { success: false, jsonString: '', sourceFormat: '', error: '文件太小,不是有效的 PNG 文件' };
  }

  // 校验 PNG 签名
  for (let i = 0; i < PNG_SIGNATURE.length; i++) {
    if (bytes[i] !== PNG_SIGNATURE[i]) {
      return { success: false, jsonString: '', sourceFormat: '', error: '无效的 PNG 签名,文件不是 PNG 格式' };
    }
  }

  // 解析所有 tEXt chunk
  const chunks: PngTextChunk[] = [];
  try {
    parseChunks(bytes, chunks);
  } catch (e) {
    return { success: false, jsonString: '', sourceFormat: '', error: 'PNG 解析失败: ' + String(e) };
  }

  if (chunks.length === 0) {
    return { success: false, jsonString: '', sourceFormat: '',
      error: 'PNG 中未找到角色卡元数据(chara/ccv3 tEXt chunk)' };
  }

  // 优先 ccv3(V3),其次 chara(V2)
  let selectedChunk: PngTextChunk | null = null;
  for (let i = 0; i < chunks.length; i++) {
    if (chunks[i].keyword === 'ccv3') {
      selectedChunk = chunks[i];
      break;
    }
  }
  if (selectedChunk === null) {
    for (let i = 0; i < chunks.length; i++) {
      if (chunks[i].keyword === 'chara') {
        selectedChunk = chunks[i];
        break;
      }
    }
  }

  if (selectedChunk === null) {
    return { success: false, jsonString: '', sourceFormat: '',
      error: 'PNG 中未找到角色卡元数据(chara/ccv3 tEXt chunk)' };
  }

  // 检查文本长度
  if (selectedChunk.text.length > MAX_TEXT_LENGTH) {
    return { success: false, jsonString: '', sourceFormat: '', error: '角色卡元数据过大,不能超过 10MB' };
  }

  // Base64 解码
  let decoded: string;
  try {
    decoded = decodeBase64(selectedChunk.text);
  } catch (e) {
    return { success: false, jsonString: '', sourceFormat: '', error: 'Base64 解码失败: ' + String(e) };
  }

  if (decoded.length === 0) {
    return { success: false, jsonString: '', sourceFormat: '', error: 'Base64 解码结果为空' };
  }

  const sourceFormat: string = selectedChunk.keyword === 'ccv3' ? 'chara_card_v3' : 'chara_card_v2';

  return {
    success: true,
    jsonString: decoded,
    sourceFormat: sourceFormat,
    error: ''
  };
}

/**
 * 遍历 PNG chunk,提取所有 tEXt chunk。
 */
function parseChunks(bytes: Uint8Array, result: PngTextChunk[]): void {
  let offset: number = PNG_SIGNATURE.length;
  let chunkCount: number = 0;

  while (offset + 12 <= bytes.byteLength) {
    chunkCount++;
    if (chunkCount > MAX_CHUNK_COUNT) {
      throw new Error('chunk 数量超过限制(' + String(MAX_CHUNK_COUNT) + ')');
    }

    // 读取 chunk 长度(4 字节 big-endian)
    const dataLength: number = readUint32BE(bytes, offset);
    offset += 4;

    if (dataLength > MAX_CHUNK_DATA_LENGTH) {
      throw new Error('chunk 数据长度异常: ' + String(dataLength));
    }

    // 读取 chunk 类型(4 字节 ASCII)
    const type: string = readAsciiString(bytes, offset, 4);
    offset += 4;

    // 检查数据是否足够
    if (offset + dataLength > bytes.byteLength) {
      throw new Error('chunk 数据越界: type=' + type + ' len=' + String(dataLength));
    }

    // 读取 chunk 数据
    if (type === CHUNK_TYPE_TEXT && dataLength > 0) {
      const data: Uint8Array = new Uint8Array(bytes.buffer, offset, dataLength);
      const textChunk: PngTextChunk | null = parseTextChunk(data);
      if (textChunk !== null) {
        result.push(textChunk);
      }
    }

    offset += dataLength;

    // 跳过 CRC(4 字节)
    offset += 4;
  }
}

/**
 * 解析 tEXt chunk 数据:keyword\0text
 */
function parseTextChunk(data: Uint8Array): PngTextChunk | null {
  // 查找 null 分隔符
  let nullPos: number = -1;
  for (let i = 0; i < data.length; i++) {
    if (data[i] === 0x00) {
      nullPos = i;
      break;
    }
  }
  if (nullPos < 0) {
    return null;
  }

  const keywordBytes: Uint8Array = new Uint8Array(data.buffer, data.byteOffset, nullPos);
  const keyword: string = bytesToUtf8(keywordBytes);

  // 只提取角色卡相关 keyword
  if (keyword !== 'chara' && keyword !== 'ccv3') {
    return null;
  }

  const textStart: number = nullPos + 1;
  const textBytes: Uint8Array = new Uint8Array(data.buffer, data.byteOffset + textStart, data.length - textStart);
  const text: string = latin1ToUtf8(textBytes);

  return { keyword: keyword, text: text };
}

/**
 * 读取 4 字节 big-endian 无符号整数。
 */
function readUint32BE(bytes: Uint8Array, offset: number): number {
  return ((bytes[offset] & 0xFF) << 24) |
    ((bytes[offset + 1] & 0xFF) << 16) |
    ((bytes[offset + 2] & 0xFF) << 8) |
    (bytes[offset + 3] & 0xFF);
}

/**
 * 读取 ASCII 字符串。
 */
function readAsciiString(bytes: Uint8Array, offset: number, length: number): string {
  let result: string = '';
  for (let i = 0; i < length; i++) {
    result += String.fromCharCode(bytes[offset + i] & 0xFF);
  }
  return result;
}

/**
 * 将字节数组转 UTF-8 字符串。
 * 纯逻辑实现,不依赖 util.TextDecoder。
 */
function bytesToUtf8(bytes: Uint8Array): string {
  let result: string = '';
  let i: number = 0;
  while (i < bytes.length) {
    const b0: number = bytes[i] & 0xFF;
    if (b0 < 0x80) {
      result += String.fromCharCode(b0);
      i += 1;
    } else if (b0 < 0xE0) {
      const b1: number = bytes[i + 1] & 0xFF;
      const cp: number = ((b0 & 0x1F) << 6) | (b1 & 0x3F);
      result += String.fromCharCode(cp);
      i += 2;
    } else if (b0 < 0xF0) {
      const b1: number = bytes[i + 1] & 0xFF;
      const b2: number = bytes[i + 2] & 0xFF;
      const cp: number = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
      result += String.fromCharCode(cp);
      i += 3;
    } else {
      const b1: number = bytes[i + 1] & 0xFF;
      const b2: number = bytes[i + 2] & 0xFF;
      const b3: number = bytes[i + 3] & 0xFF;
      const cp: number = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
      result += String.fromCharCode(cp);
      i += 4;
    }
  }
  return result;
}

/**
 * 将 Latin-1 字节数组转为 UTF-8 字符串。
 * tEXt chunk 文本数据使用 Latin-1 编码。
 */
function latin1ToUtf8(bytes: Uint8Array): string {
  let result: string = '';
  for (let i = 0; i < bytes.length; i++) {
    result += String.fromCharCode(bytes[i] & 0xFF);
  }
  return result;
}

/**
 * Base64 解码(纯逻辑实现)。
 * 支持标准 Base64 和 URL-safe Base64。
 */
function decodeBase64(input: string): string {
  // 移除空白字符
  let s: string = '';
  for (let i = 0; i < input.length; i++) {
    const ch: string = input.charAt(i);
    if (ch !== ' ' && ch !== '\n' && ch !== '\r' && ch !== '\t') {
      s += ch;
    }
  }

  if (s.length === 0) {
    return '';
  }

  const base64Chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const urlSafeChars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

  // 检测并选择解码表
  let useUrlSafe: boolean = false;
  if (s.includes('-') || s.includes('_')) {
    useUrlSafe = true;
  }

  const charTable: string = useUrlSafe ? urlSafeChars : base64Chars;

  // 构建反向查找表
  const lookup: number[] = new Array<number>(256);
  for (let i = 0; i < 256; i++) {
    lookup[i] = -1;
  }
  for (let i = 0; i < charTable.length; i++) {
    lookup[charTable.charCodeAt(i)] = i;
  }

  // 计算填充
  let padding: number = 0;
  if (s.length > 0 && s.charAt(s.length - 1) === '=') {
    padding++;
    if (s.length > 1 && s.charAt(s.length - 2) === '=') {
      padding++;
    }
  }

  const validLen: number = s.length - padding;
  const outputLen: number = Math.floor(validLen / 4) * 3;

  // 收集解码后的字节
  const bytes: number[] = new Array<number>(outputLen);
  let pos: number = 0;

  for (let i = 0; i < validLen; i += 4) {
    const remaining: number = validLen - i;
    const quadLen: number = remaining < 4 ? remaining : 4;

    const b0: number = lookup[s.charCodeAt(i)];
    const b1: number = quadLen > 1 ? lookup[s.charCodeAt(i + 1)] : 0;
    const b2: number = quadLen > 2 ? lookup[s.charCodeAt(i + 2)] : 0;
    const b3: number = quadLen > 3 ? lookup[s.charCodeAt(i + 3)] : 0;

    if (b0 < 0 || b1 < 0 || (quadLen > 2 && b2 < 0) || (quadLen > 3 && b3 < 0)) {
      throw new Error('Base64 包含非法字符');
    }

    const triple: number = (b0 << 18) | (b1 << 12) | (b2 << 6) | b3;

    bytes[pos] = (triple >> 16) & 0xFF;
    pos++;
    if (quadLen > 2) {
      bytes[pos] = (triple >> 8) & 0xFF;
      pos++;
    }
    if (quadLen > 3) {
      bytes[pos] = triple & 0xFF;
      pos++;
    }
  }

  // 使用 UTF-8 解码字节数组
  const byteArray: Uint8Array = new Uint8Array(bytes.slice(0, pos));
  return bytesToUtf8(byteArray);
}