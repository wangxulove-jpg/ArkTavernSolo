/**
 * UUID v4 工具模块
 *
 * 使用 HarmonyOS cryptoFramework 生成安全随机数,
 * 并按 RFC 4122 v4 规范设置 version 和 variant 位。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';

const HEX_CHARS: string = '0123456789abcdef';
const UUID_V4_PATTERN: RegExp = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * 将字节数组转换为十六进制字符串。
 * @param bytes 字节数组
 * @returns 小写十六进制字符串
 */
function bytesToHex(bytes: Uint8Array): string {
  let result: string = '';
  for (let i = 0; i < bytes.length; i++) {
    const b: number = bytes[i];
    result += HEX_CHARS[(b >> 4) & 0x0f];
    result += HEX_CHARS[b & 0x0f];
  }
  return result;
}

/**
 * 从 16 字节随机数生成 UUID v4 格式字符串。
 * 正确设置 version(第 7 字节高 4 位为 0100)和 variant(第 9 字节高 2 位为 10)位。
 *
 * @param randomBytes 至少 16 字节的随机数
 * @returns UUID v4 格式字符串
 * @throws Error 当随机字节不足 16 字节时
 */
export function formatUuidV4(randomBytes: Uint8Array): string {
  if (randomBytes.length < 16) {
    throw new Error('randomBytes must be at least 16 bytes');
  }

  // 复制前 16 字节到可变数组
  const bytes: number[] = [];
  for (let i = 0; i < 16; i++) {
    bytes.push(randomBytes[i]);
  }

  // version: 第 7 字节(index 6)高 4 位设为 0100
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  // variant: 第 9 字节(index 8)高 2 位设为 10
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  const hex: string = bytesToHex(new Uint8Array(bytes));
  // 格式: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  return hex.substring(0, 8) + '-' +
    hex.substring(8, 12) + '-' +
    hex.substring(12, 16) + '-' +
    hex.substring(16, 20) + '-' +
    hex.substring(20, 32);
}

/**
 * 生成 UUID v4 字符串。
 * 使用 HarmonyOS cryptoFramework 的安全随机数生成器。
 *
 * @returns UUID v4 格式字符串
 */
export function generateUuid(): string {
  const random: cryptoFramework.Random = cryptoFramework.createRandom();
  const dataBlob: cryptoFramework.DataBlob = random.generateRandomSync(16);
  return formatUuidV4(dataBlob.data);
}

/**
 * 校验字符串是否符合 UUID v4 格式。
 * 同时检查 version 位(必须为 4)和 variant 位(必须为 8/9/a/b)。
 *
 * @param value 待校验字符串
 * @returns 符合格式返回 true,否则返回 false
 */
export function isUuidV4(value: string): boolean {
  return UUID_V4_PATTERN.test(value);
}
