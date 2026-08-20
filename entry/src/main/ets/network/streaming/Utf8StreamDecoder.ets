/**
 * Utf8StreamDecoder 增量 UTF-8 解码器
 *
 * 将分块到达的 UTF-8 字节流增量解码为字符串。
 * 正确处理多字节字符跨 chunk 边界的情况(中文、Emoji 等)。
 *
 * 纯逻辑实现,不依赖 @ohos.util.TextDecoder 或任何设备 API。
 * 可在本地单元测试中运行。
 *
 * UTF-8 编码规则:
 * - 1 字节:0xxxxxxx(0x00-0x7F)
 * - 2 字节:110xxxxx 10xxxxxx(0x80-0x7FF)
 * - 3 字节:1110xxxx 10xxxxxx 10xxxxxx(0x800-0xFFFF,中文在此范围)
 * - 4 字节:11110xxx 10xxxxxx 10xxxxxx 10xxxxxx(0x10000-0x10FFFF,Emoji 在此范围)
 *
 * 后续字节:10xxxxxx(0x80-0xBF)
 */

/** 替换字符,用于非法字节序列。 */
const REPLACEMENT_CHAR: string = '\uFFFD';
/** UTF-8 最大字节长度。 */
const MAX_BYTE_LENGTH: number = 4;

/**
 * 增量 UTF-8 解码器。
 * 保留未完成的尾部字节,在下次 feed 时合并处理。
 */
export class Utf8StreamDecoder {
  /** 未完成的尾部字节缓冲(等待下一 chunk 补全)。 */
  private pending: number[] = [];
  /** 是否已遇到非法字节(用于 flush 时判断)。 */
  private hasError: boolean = false;

  /**
   * 喂入一个字节块,返回已成功解码的字符串。
   * 未完成的尾部字节保留在内部缓冲,等待下次 feed。
   *
   * @param bytes 字节块(每个元素 0-255)
   * @returns 已解码的字符串(可能为空字符串)
   */
  feed(bytes: Uint8Array): string {
    let result: string = '';
    let i: number = 0;
    const len: number = bytes.length;

    while (i < len) {
      // 合并 pending 与当前字节
      const byteVal: number = bytes[i];
      i++;

      if (this.pending.length === 0) {
        // 新字符起始字节
        const seqLen: number = byteSequenceLength(byteVal);
        if (seqLen < 0) {
          // 非法起始字节
          result += REPLACEMENT_CHAR;
          this.hasError = true;
          continue;
        }
        if (seqLen === 1) {
          // 单字节 ASCII
          result += String.fromCharCode(byteVal);
          continue;
        }
        // 多字节序列起始
        this.pending.push(byteVal);
        continue;
      }

      // pending 非空:当前字节应为后续字节(10xxxxxx)
      if ((byteVal & 0xC0) !== 0x80) {
        // 非法后续字节,丢弃 pending,用替换字符占位
        result += REPLACEMENT_CHAR;
        this.pending = [];
        this.hasError = true;
        // 当前字节作为新起始字节重新处理
        i--;
        continue;
      }

      this.pending.push(byteVal);
      const seqLen: number = byteSequenceLength(this.pending[0]);
      if (this.pending.length === seqLen) {
        // 序列完整,尝试解码
        const decoded: string | null = decodeSequence(this.pending);
        if (decoded === null) {
          result += REPLACEMENT_CHAR;
          this.hasError = true;
        } else {
          result += decoded;
        }
        this.pending = [];
      }
    }

    return result;
  }

  /**
   * 通知流结束,flush 剩余字节。
   * 如果存在未完成的序列,用替换字符代替。
   *
   * @returns 剩余解码的字符串
   */
  flush(): string {
    if (this.pending.length === 0) {
      const err: boolean = this.hasError;
      this.hasError = false;
      return '';
    }
    // 有未完成序列,用替换字符
    const result: string = REPLACEMENT_CHAR;
    this.pending = [];
    this.hasError = false;
    return result;
  }

  /**
   * 重置解码器状态,可复用。
   */
  reset(): void {
    this.pending = [];
    this.hasError = false;
  }

  /**
   * 获取当前 pending 字节数(用于诊断)。
   * @returns pending 字节个数
   */
  getPendingLength(): number {
    return this.pending.length;
  }
}

/**
 * 根据 UTF-8 起始字节判断序列长度。
 * @param byteVal 起始字节(0-255)
 * @returns 序列长度(1-4),非法返回 -1
 */
function byteSequenceLength(byteVal: number): number {
  if ((byteVal & 0x80) === 0) {
    return 1; // 0xxxxxxx
  }
  if ((byteVal & 0xE0) === 0xC0) {
    return 2; // 110xxxxx
  }
  if ((byteVal & 0xF0) === 0xE0) {
    return 3; // 1110xxxx
  }
  if ((byteVal & 0xF8) === 0xF0) {
    return 4; // 11110xxx
  }
  return -1; // 非法起始字节(10xxxxxx 或 11111xxx)
}

/**
 * 解码一个完整的 UTF-8 字节序列。
 * @param seq 完整序列(长度 2-4)
 * @returns 解码后的字符,非法序列返回 null
 */
function decodeSequence(seq: number[]): string | null {
  const len: number = seq.length;
  if (len < 2 || len > MAX_BYTE_LENGTH) {
    return null;
  }

  let codePoint: number;
  if (len === 2) {
    codePoint = ((seq[0] & 0x1F) << 6) | (seq[1] & 0x3F);
    // 2 字节序列的最小值是 0x80,小于此为过长编码
    if (codePoint < 0x80) {
      return null;
    }
  } else if (len === 3) {
    codePoint = ((seq[0] & 0x0F) << 12) | ((seq[1] & 0x3F) << 6) | (seq[2] & 0x3F);
    // 3 字节序列的最小值是 0x800,小于此为过长编码
    if (codePoint < 0x800) {
      return null;
    }
    // 代理对范围非法(U+D800 ~ U+DFFF)
    if (codePoint >= 0xD800 && codePoint <= 0xDFFF) {
      return null;
    }
  } else {
    // len === 4
    codePoint = ((seq[0] & 0x07) << 18) | ((seq[1] & 0x3F) << 12) | ((seq[2] & 0x3F) << 6) | (seq[3] & 0x3F);
    // 4 字节序列的最小值是 0x10000,最大 0x10FFFF
    if (codePoint < 0x10000 || codePoint > 0x10FFFF) {
      return null;
    }
  }

  // 转为 JS 字符串(注意 BMP 外字符需用代理对)
  return codePointToString(codePoint);
}

/**
 * 将码点转为字符串(处理 BMP 外字符的代理对)。
 * @param codePoint Unicode 码点
 * @returns 字符串
 */
function codePointToString(codePoint: number): string {
  if (codePoint <= 0xFFFF) {
    return String.fromCharCode(codePoint);
  }
  // BMP 外字符:用代理对
  const adjusted: number = codePoint - 0x10000;
  const highSurrogate: number = 0xD800 + (adjusted >> 10);
  const lowSurrogate: number = 0xDC00 + (adjusted & 0x3FF);
  return String.fromCharCode(highSurrogate) + String.fromCharCode(lowSurrogate);
}
