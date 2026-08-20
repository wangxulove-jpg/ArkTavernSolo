/**
 * AliasBuilder alias 构建与校验纯逻辑模块
 *
 * 本模块为纯 ArkTS 逻辑,不依赖任何设备 API,可在本地单元测试运行。
 * 提供:
 * - alias 构建:从 providerId 生成稳定 alias
 * - alias 校验:检查格式、长度、非法字符
 * - secret 字节长度校验
 * - UTF-8 字节长度计算(纯逻辑实现,不依赖 util.TextEncoder)
 *
 * alias 格式:arktavern.provider.<providerId>.api-key
 * alias 仅包含非敏感信息:providerId 是配置 ID(UUID),不含 API Key。
 *
 * 安全要求:
 * - alias 不包含 API Key
 * - alias 不包含 Base URL
 * - alias 不包含用户输入的密钥片段
 * - 只允许 [a-zA-Z0-9.\-_]
 * - 限制 alias 长度
 */

/** alias 前缀(应用级固定) */
const ALIAS_PREFIX: string = 'arktavern_solo.provider.';
/** alias 后缀(用途标识) */
const ALIAS_SUFFIX: string = '.api-key';
/** providerId 允许的最大长度(UUID 36 字符,留余量) */
const MAX_PROVIDER_ID_LENGTH: number = 64;
/** alias 允许的最大长度(Asset Store 实际支持更大,这里保守限制) */
const MAX_ALIAS_LENGTH: number = 128;
/** secret 允许的最大字节数(保守限制,API Key 远小于此) */
const MAX_SECRET_BYTES: number = 2048;

/** alias 允许字符正则:[a-zA-Z0-9.\-_] */
const ALIAS_CHAR_PATTERN: RegExp = /^[a-zA-Z0-9.\-_]+$/;

/**
 * 判断字符是否为 ASCII 字母。
 * @param c 字符码点
 * @returns 是 ASCII 字母返回 true
 */
function isAsciiAlpha(c: number): boolean {
  return (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
}

/**
 * 判断字符是否为 ASCII 数字。
 * @param c 字符码点
 * @returns 是 ASCII 数字返回 true
 */
function isAsciiDigit(c: number): boolean {
  return c >= 0x30 && c <= 0x39;
}

/**
 * 判断字符是否为允许的安全字符(. - _)
 * @param c 字符码点
 * @returns 是允许的分隔符返回 true
 */
function isAllowedSeparator(c: number): boolean {
  return c === 0x2E || c === 0x2D || c === 0x5F; // . - _
}

/**
 * 校验 providerId 是否符合安全字符集。
 * 不允许:斜杠、换行、控制字符、空格、路径字符。
 *
 * @param providerId 待校验的 providerId
 * @returns 合法返回 true,否则 false
 */
export function isValidProviderId(providerId: string): boolean {
  if (providerId.length === 0) {
    return false;
  }
  if (providerId.length > MAX_PROVIDER_ID_LENGTH) {
    return false;
  }
  for (let i = 0; i < providerId.length; i++) {
    const code: number = providerId.charCodeAt(i);
    if (!isAsciiAlpha(code) && !isAsciiDigit(code) && !isAllowedSeparator(code)) {
      return false;
    }
  }
  return true;
}

/**
 * 从 providerId 构建 alias。
 * alias 格式:arktavern.provider.<providerId>.api-key
 *
 * @param providerId Provider 配置 ID(必须为安全字符)
 * @returns 构建结果,success=false 时 error 描述校验失败原因
 */
export function buildAlias(providerId: string): AliasBuildResult {
  if (providerId.length === 0) {
    return { success: false, alias: '', error: 'providerId is empty' };
  }
  if (providerId.length > MAX_PROVIDER_ID_LENGTH) {
    return { success: false, alias: '', error: 'providerId too long' };
  }
  if (!isValidProviderId(providerId)) {
    return { success: false, alias: '', error: 'providerId contains invalid characters' };
  }
  const alias: string = ALIAS_PREFIX + providerId + ALIAS_SUFFIX;
  if (alias.length > MAX_ALIAS_LENGTH) {
    return { success: false, alias: '', error: 'alias exceeds maximum length' };
  }
  return { success: true, alias: alias, error: '' };
}

/**
 * 校验已构建的 alias 是否合法。
 * 用于在调用平台 API 前做最终防御性校验。
 *
 * @param alias 待校验的 alias
 * @returns 合法返回 true,否则 false
 */
export function isValidAlias(alias: string): boolean {
  if (alias.length === 0) {
    return false;
  }
  if (alias.length > MAX_ALIAS_LENGTH) {
    return false;
  }
  if (!ALIAS_CHAR_PATTERN.test(alias)) {
    return false;
  }
  if (!alias.startsWith(ALIAS_PREFIX)) {
    return false;
  }
  if (!alias.endsWith(ALIAS_SUFFIX)) {
    return false;
  }
  return true;
}

/**
 * 计算 UTF-8 编码后的字节数。
 * 纯逻辑实现,不依赖 util.TextEncoder,可在本地单元测试运行。
 *
 * 规则:
 * - U+0000 ~ U+007F: 1 字节
 * - U+0080 ~ U+07FF: 2 字节
 * - U+0800 ~ U+FFFF(非代理对): 3 字节
 * - U+10000 ~ U+10FFFF(代理对): 4 字节
 *
 * @param s 待计算字符串
 * @returns UTF-8 字节数
 */
export function utf8ByteLength(s: string): number {
  let bytes: number = 0;
  let i: number = 0;
  while (i < s.length) {
    const code: number = s.charCodeAt(i);
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < s.length) {
      // 高代理项,需要配对低代理项
      const low: number = s.charCodeAt(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        // 有效的代理对,对应 4 字节 UTF-8
        bytes += 4;
        i += 2;
        continue;
      }
      // 无效的代理对,按 1 个字符(3 字节)处理
      bytes += 3;
      i += 1;
      continue;
    }
    if (code <= 0x007F) {
      bytes += 1;
    } else if (code <= 0x07FF) {
      bytes += 2;
    } else {
      bytes += 3;
    }
    i += 1;
  }
  return bytes;
}

/**
 * 校验 secret 是否合法(非空且不超过最大字节数)。
 *
 * @param secret 待校验的 secret
 * @returns 合法返回 true,否则 false
 */
export function isValidSecret(secret: string): boolean {
  if (secret.length === 0) {
    return false;
  }
  if (utf8ByteLength(secret) > MAX_SECRET_BYTES) {
    return false;
  }
  return true;
}

/**
 * 获取 secret 最大允许字节数。
 * @returns 最大字节数
 */
export function getMaxSecretBytes(): number {
  return MAX_SECRET_BYTES;
}

/**
 * 获取 alias 最大允许长度。
 * @returns 最大长度
 */
export function getMaxAliasLength(): number {
  return MAX_ALIAS_LENGTH;
}

/**
 * alias 构建结果。
 */
export interface AliasBuildResult {
  /** 是否构建成功 */
  readonly success: boolean;
  /** 构建出的 alias(success=true 时有效) */
  readonly alias: string;
  /** 失败原因(success=false 时有效) */
  readonly error: string;
}
