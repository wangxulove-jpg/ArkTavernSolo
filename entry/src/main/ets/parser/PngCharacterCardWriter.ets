/**
 * PngCharacterCardWriter PNG 角色卡写入器
 *
 * 职责:
 * - 生成最小占位 PNG(400x600 单色背景,无外部依赖)
 * - 将 Tavern Card V2 JSON 写入 PNG 的 `chara` tEXt chunk
 * - tEXt chunk 内容为 Base64 编码的 UTF-8 JSON 字符串
 * - 写入后 PNG 可被普通图片查看器正常打开
 * - 可被 ArkTavern PngCharacterCardParser 和 SillyTavern 重新导入
 *
 * 不依赖:
 * - ArkUI / 网络 / 存储 / 数据库
 * - 任何外部 PNG 库
 *
 * PNG chunk 结构:
 *   [4 bytes data length][4 bytes type][N bytes data][4 bytes CRC]
 * CRC 覆盖 type + data。
 *
 * 占位 PNG 结构:
 *   签名 + IHDR + IDAT + IEND
 *   (新增 chara tEXt chunk 放在 IEND 之前)
 *
 * 约束:
 * - 不复制 SillyTavern / MiniTavern 代码
 * - 占位 PNG 由本模块代码生成,不读取任何外部资源
 */

/** PNG 签名:8 字节 */
const PNG_SIGNATURE: number[] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/** 标准 Base64 字符表 */
const BASE64_CHARS: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** 占位 PNG 默认尺寸 */
const PLACEHOLDER_WIDTH: number = 400;
const PLACEHOLDER_HEIGHT: number = 600;

/** 占位 PNG 默认背景色(RGB) - 浅灰偏暖 */
const PLACEHOLDER_BG_R: number = 0xB0;
const PLACEHOLDER_BG_G: number = 0xB0;
const PLACEHOLDER_BG_B: number = 0xB4;

/**
 * PNG 写入结果。
 */
export interface PngWriteResult {
  success: boolean;
  bytes: Uint8Array;
  error: string;
}

/**
 * 生成占位 PNG(纯色背景,400x600)。
 * 不包含任何 tEXt chunk。
 *
 * 内部使用最小化 zlib 流:
 * - IHDR(13 字节数据:width 4 + height 4 + bit depth 1 + color type 1 + compression 1 + filter 1 + interlace 1)
 * - IDAT(单 zlib stream:0x78 0x9C 头 + deflate blocks + adler32)
 * - IEND
 *
 * 实现说明:
 * - 为了零依赖,使用 uncompressed deflate blocks(stored blocks)
 * - IDAT 数据:每行开头加 filter 字节(0),后跟 width*3 字节 RGB
 * - 行数 = height
 */
export function generatePlaceholderPng(
  width: number = PLACEHOLDER_WIDTH,
  height: number = PLACEHOLDER_HEIGHT
): Uint8Array {
  // 1. 签名
  const sigBytes: number[] = PNG_SIGNATURE.slice();

  // 2. IHDR
  const ihdrData: number[] = [];
  pushUint32BE(ihdrData, width);
  pushUint32BE(ihdrData, height);
  ihdrData.push(8);      // bit depth = 8
  ihdrData.push(2);      // color type = 2 (truecolor RGB)
  ihdrData.push(0);      // compression = 0 (deflate)
  ihdrData.push(0);      // filter = 0
  ihdrData.push(0);      // interlace = 0
  const ihdrChunk: number[] = buildChunk('IHDR', ihdrData);

  // 3. IDAT - 原始数据(每行 filter 字节 + RGB 行)
  const rowBytes: number = 1 + width * 3;
  const rawBytes: number[] = [];
  for (let y = 0; y < height; y++) {
    rawBytes.push(0); // filter = none
    for (let x = 0; x < width; x++) {
      rawBytes.push(PLACEHOLDER_BG_R);
      rawBytes.push(PLACEHOLDER_BG_G);
      rawBytes.push(PLACEHOLDER_BG_B);
    }
  }
  const idatData: number[] = buildZlibStream(rawBytes);
  const idatChunk: number[] = buildChunk('IDAT', idatData);

  // 4. IEND
  const iendChunk: number[] = buildChunk('IEND', []);

  // 拼装
  const total: number[] = sigBytes.concat(ihdrChunk).concat(idatChunk).concat(iendChunk);
  return new Uint8Array(total);
}

/**
 * 将 Tavern Card V2 JSON 字符串写入 PNG 字节数据。
 * - 在 IEND 之前插入 chara tEXt chunk
 * - chara chunk 内容 = Base64(UTF-8(json))
 * - 不修改原 PNG 的图片数据
 *
 * @param pngBytes 原始 PNG 字节(必须为合法 PNG,通常为头像或占位图)
 * @param jsonString V2 JSON 字符串
 * @returns 写入结果
 */
export function writeCharaCardToPng(
  pngBytes: Uint8Array,
  jsonString: string
): PngWriteResult {
  if (pngBytes.byteLength < PNG_SIGNATURE.length) {
    return { success: false, bytes: new Uint8Array(0), error: 'PNG 字节数据过短' };
  }
  // 校验 PNG 签名
  for (let i = 0; i < PNG_SIGNATURE.length; i++) {
    if (pngBytes[i] !== PNG_SIGNATURE[i]) {
      return { success: false, bytes: new Uint8Array(0), error: '无效的 PNG 签名' };
    }
  }
  // 查找 IEND chunk 位置(最后 12 字节:4 长度 + 4 'IEND' + 4 CRC)
  // 标准 PNG 最后一段是 IEND,len=0
  // 简单策略:从末尾向前找 'IEND' 字符串
  const iendMarker: number[] = [0x49, 0x45, 0x4E, 0x44]; // 'I','E','N','D'
  let iendPos: number = -1;
  for (let i = pngBytes.byteLength - 8; i >= 8; i--) {
    if (pngBytes[i] === iendMarker[0] &&
      pngBytes[i + 1] === iendMarker[1] &&
      pngBytes[i + 2] === iendMarker[2] &&
      pngBytes[i + 3] === iendMarker[3]) {
      iendPos = i - 4; // IEND chunk 起始位置(length 字段位置)
      break;
    }
  }
  if (iendPos < 0) {
    return { success: false, bytes: new Uint8Array(0), error: '未找到 IEND chunk' };
  }

  // 构建 chara tEXt chunk 数据:keyword 'chara' + 0x00 + Base64(json)
  const base64: string = encodeBase64Utf8(jsonString);
  const keyword: string = 'chara';
  const chunkData: number[] = [];
  // keyword
  for (let i = 0; i < keyword.length; i++) {
    chunkData.push(keyword.charCodeAt(i) & 0xFF);
  }
  // null separator
  chunkData.push(0);
  // base64 text (Latin-1 写入,ASCII 字符无需编码转换)
  for (let i = 0; i < base64.length; i++) {
    chunkData.push(base64.charCodeAt(i) & 0xFF);
  }
  const charaChunk: number[] = buildChunk('tEXt', chunkData);

  // 拼装:pngBytes[0..iendPos) + charaChunk + pngBytes[iendPos..end)
  const resultBytes: number[] = [];
  for (let i = 0; i < iendPos; i++) {
    resultBytes.push(pngBytes[i]);
  }
  for (let i = 0; i < charaChunk.length; i++) {
    resultBytes.push(charaChunk[i]);
  }
  for (let i = iendPos; i < pngBytes.byteLength; i++) {
    resultBytes.push(pngBytes[i]);
  }

  return {
    success: true,
    bytes: new Uint8Array(resultBytes),
    error: ''
  };
}

/**
 * 将角色数据导出为 PNG 字节。
 * 如果 avatarBytes 非空,使用头像作为 PNG 视觉内容;
 * 否则使用生成的占位 PNG。
 *
 * @param avatarBytes 头像 PNG 字节(可为 null)
 * @param jsonString V2 JSON 字符串
 * @returns 写入结果
 */
export function exportCharacterToPng(
  avatarBytes: Uint8Array | null,
  jsonString: string
): PngWriteResult {
  const pngBytes: Uint8Array = avatarBytes !== null ? avatarBytes : generatePlaceholderPng();
  return writeCharaCardToPng(pngBytes, jsonString);
}

// ===== 内部工具 =====

/**
 * 构建 PNG chunk:length + type + data + CRC
 */
function buildChunk(type: string, data: number[]): number[] {
  const result: number[] = [];
  // length (4 bytes BE)
  pushUint32BE(result, data.length);
  // type (4 bytes ASCII)
  for (let i = 0; i < type.length; i++) {
    result.push(type.charCodeAt(i) & 0xFF);
  }
  // data
  for (let i = 0; i < data.length; i++) {
    result.push(data[i] & 0xFF);
  }
  // CRC over type + data
  const crcInput: number[] = [];
  for (let i = 0; i < type.length; i++) {
    crcInput.push(type.charCodeAt(i) & 0xFF);
  }
  for (let i = 0; i < data.length; i++) {
    crcInput.push(data[i] & 0xFF);
  }
  const crc: number = crc32(crcInput);
  pushUint32BE(result, crc);
  return result;
}

/**
 * 构建 zlib stream(78 9C 头 + stored deflate blocks + adler32)
 *
 * 使用 uncompressed deflate(stored)块:
 * - 块头 5 字节:BFINAL(1 bit) + BTYPE=00(2 bits) + 0(2 bits) + LEN(2 bytes LE) + NLEN(2 bytes LE)
 * - 数据原样写入
 * - 末尾 4 字节 adler32(原始数据)
 *
 * 单块最大 65535 字节,数据更长则分多块。
 */
function buildZlibStream(data: number[]): number[] {
  const result: number[] = [];
  // zlib header
  result.push(0x78); // CMF: CM=8 (deflate), CINFO=7 (32K window)
  result.push(0x9C); // FLG: FCHECK so that (CMF*256 + FLG) % 31 == 0
  // 0x78*256 + 0x9C = 30876, 30876 % 31 = 0

  // 分块写入 stored blocks
  let offset: number = 0;
  const total: number = data.length;
  while (offset < total) {
    const remaining: number = total - offset;
    const blockLen: number = remaining > 65535 ? 65535 : remaining;
    const isLast: boolean = (offset + blockLen) >= total;
    // BFINAL = isLast ? 1 : 0, BTYPE = 00
    result.push(isLast ? 0x01 : 0x00);
    // LEN (2 bytes LE)
    result.push(blockLen & 0xFF);
    result.push((blockLen >> 8) & 0xFF);
    // NLEN = ~LEN (2 bytes LE)
    const nlen: number = (~blockLen) & 0xFFFF;
    result.push(nlen & 0xFF);
    result.push((nlen >> 8) & 0xFF);
    // data
    for (let i = 0; i < blockLen; i++) {
      result.push(data[offset + i] & 0xFF);
    }
    offset += blockLen;
  }

  // adler32 (4 bytes BE)
  const adler: number = adler32(data);
  pushUint32BE(result, adler);

  return result;
}

/** 大端写入 32 位无符号整数 */
function pushUint32BE(arr: number[], value: number): void {
  arr.push((value >>> 24) & 0xFF);
  arr.push((value >>> 16) & 0xFF);
  arr.push((value >>> 8) & 0xFF);
  arr.push(value & 0xFF);
}

/**
 * CRC32 计算(PNG 使用的多项式 0xEDB88320)。
 * 输入是字节数组。
 */
function crc32(bytes: number[]): number {
  let crc: number = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) {
    crc = crc ^ (bytes[i] & 0xFF);
    for (let j = 0; j < 8; j++) {
      if ((crc & 1) !== 0) {
        crc = (crc >>> 1) ^ 0xEDB88320;
      } else {
        crc = crc >>> 1;
      }
    }
  }
  return (crc ^ 0xFFFFFFFF) >>> 0;
}

/**
 * Adler-32 校验和(zlib 末尾使用)。
 */
function adler32(bytes: number[]): number {
  let a: number = 1;
  let b: number = 0;
  const MOD: number = 65521;
  for (let i = 0; i < bytes.length; i++) {
    a = (a + (bytes[i] & 0xFF)) % MOD;
    b = (b + a) % MOD;
  }
  return ((b << 16) | a) >>> 0;
}

/**
 * 将 UTF-8 字符串编码为 Base64。
 * 先按 UTF-8 转字节,再按 3 字节一组映射为 4 个 Base64 字符。
 *
 * 纯逻辑实现,不依赖 util.Base64Helper(便于本地单元测试)。
 */
function encodeBase64Utf8(input: string): string {
  // 1. UTF-8 编码
  const utf8Bytes: number[] = [];
  for (let i = 0; i < input.length; i++) {
    const cp: number = input.charCodeAt(i);
    if (cp < 0x80) {
      utf8Bytes.push(cp);
    } else if (cp < 0x800) {
      utf8Bytes.push(0xC0 | (cp >> 6));
      utf8Bytes.push(0x80 | (cp & 0x3F));
    } else if (cp < 0xD800 || cp >= 0xE000) {
      utf8Bytes.push(0xE0 | (cp >> 12));
      utf8Bytes.push(0x80 | ((cp >> 6) & 0x3F));
      utf8Bytes.push(0x80 | (cp & 0x3F));
    } else {
      // surrogate pair
      i++;
      const cp2: number = 0x10000 + ((cp & 0x3FF) << 10) + (input.charCodeAt(i) & 0x3FF);
      utf8Bytes.push(0xF0 | (cp2 >> 18));
      utf8Bytes.push(0x80 | ((cp2 >> 12) & 0x3F));
      utf8Bytes.push(0x80 | ((cp2 >> 6) & 0x3F));
      utf8Bytes.push(0x80 | (cp2 & 0x3F));
    }
  }

  // 2. Base64 编码
  let result: string = '';
  const len: number = utf8Bytes.length;
  let i: number = 0;
  while (i + 3 <= len) {
    const b0: number = utf8Bytes[i] & 0xFF;
    const b1: number = utf8Bytes[i + 1] & 0xFF;
    const b2: number = utf8Bytes[i + 2] & 0xFF;
    const triple: number = (b0 << 16) | (b1 << 8) | b2;
    result += BASE64_CHARS.charAt((triple >> 18) & 0x3F);
    result += BASE64_CHARS.charAt((triple >> 12) & 0x3F);
    result += BASE64_CHARS.charAt((triple >> 6) & 0x3F);
    result += BASE64_CHARS.charAt(triple & 0x3F);
    i += 3;
  }
  const remaining: number = len - i;
  if (remaining === 1) {
    const b0: number = utf8Bytes[i] & 0xFF;
    result += BASE64_CHARS.charAt((b0 >> 2) & 0x3F);
    result += BASE64_CHARS.charAt((b0 << 4) & 0x3F);
    result += '==';
  } else if (remaining === 2) {
    const b0: number = utf8Bytes[i] & 0xFF;
    const b1: number = utf8Bytes[i + 1] & 0xFF;
    result += BASE64_CHARS.charAt((b0 >> 2) & 0x3F);
    result += BASE64_CHARS.charAt(((b0 << 4) | (b1 >> 4)) & 0x3F);
    result += BASE64_CHARS.charAt((b1 << 2) & 0x3F);
    result += '=';
  }
  return result;
}
