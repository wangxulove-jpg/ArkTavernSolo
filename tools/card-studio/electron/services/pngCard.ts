/**
 * PNG 角色卡 chunk 读写(与 SillyTavern / ArkTavern App 同款 tEXt 方案)。
 *
 * - 读:提取 tEXt / iTXt chunk 中 keyword 为 ccv3(优先) 或 chara 的 base64 JSON
 * - 写:移除旧 chara/ccv3 chunk,追加新 tEXt chara(V2 兼容) 与 ccv3(V3) 双写
 * - 无原图时生成纯色占位 PNG(zlib 自构造,零依赖)
 */
import extract from 'png-chunks-extract'
import encode from 'png-chunks-encode'
import * as pngChunkText from 'png-chunk-text'
import * as zlib from 'zlib'

export interface PngChunk {
  name: string
  data: Buffer
}

/** 从 PNG buffer 提取角色卡 JSON 文本;找不到返回 null */
export function extractCardJson(png: Buffer): string | null {
  let chunks: PngChunk[]
  try {
    chunks = extract(png) as PngChunk[]
  } catch {
    return null
  }
  let chara: string | null = null
  for (const chunk of chunks) {
    if (chunk.name === 'tEXt') {
      const decoded = pngChunkText.decode(chunk.data)
      if (decoded.keyword === 'ccv3') {
        return decodeBase64Json(decoded.text)
      }
      if (decoded.keyword === 'chara') {
        chara = decodeBase64Json(decoded.text)
      }
    } else if (chunk.name === 'iTXt') {
      const decoded = decodeITxt(chunk.data)
      if (decoded && decoded.keyword === 'ccv3') {
        return decoded.text
      }
      if (decoded && decoded.keyword === 'chara' && chara === null) {
        chara = decoded.text
      }
    }
  }
  return chara
}

function decodeBase64Json(text: string): string | null {
  try {
    return Buffer.from(text, 'base64').toString('utf8')
  } catch {
    return null
  }
}

/** 解码 iTXt chunk: keyword\0compFlag\0compMethod\0lang\0translated\0text */
function decodeITxt(data: Buffer): { keyword: string; text: string } | null {
  try {
    let pos = data.indexOf(0)
    if (pos < 0) return null
    const keyword = data.toString('latin1', 0, pos)
    pos++
    const compFlag = data[pos]
    pos++ // compFlag
    pos++ // compMethod
    pos = data.indexOf(0, pos) + 1 // languageTag
    if (pos <= 0) return null
    pos = data.indexOf(0, pos) + 1 // translatedKeyword
    if (pos <= 0) return null
    const raw = data.subarray(pos)
    const text =
      compFlag === 1 ? zlib.inflateSync(raw).toString('utf8') : raw.toString('utf8')
    return { keyword, text }
  } catch {
    return null
  }
}

/** 把 V2/V3 JSON 写入 PNG(保留原 chunk;移除旧 chara/ccv3 后双写) */
export function writeCardJsonToPng(
  pngBase64: string | null,
  jsonV2: string,
  jsonV3: string
): Buffer {
  let chunks: PngChunk[]
  if (pngBase64) {
    const original = Buffer.from(pngBase64, 'base64')
    try {
      chunks = (extract(original) as PngChunk[]).filter((c) => !isCardTextChunk(c))
    } catch {
      chunks = placeholderChunks(512, 768)
    }
  } else {
    chunks = placeholderChunks(512, 768)
  }
  chunks.push(toTextChunk('chara', jsonV2))
  chunks.push(toTextChunk('ccv3', jsonV3))
  return encode(chunks) as unknown as Buffer
}

function isCardTextChunk(chunk: PngChunk): boolean {
  if (chunk.name === 'tEXt') {
    const decoded = pngChunkText.decode(chunk.data)
    return decoded.keyword === 'chara' || decoded.keyword === 'ccv3'
  }
  if (chunk.name === 'iTXt') {
    const decoded = decodeITxt(chunk.data)
    return !!decoded && (decoded.keyword === 'chara' || decoded.keyword === 'ccv3')
  }
  return false
}

function toTextChunk(keyword: string, json: string): PngChunk {
  const text = Buffer.from(json, 'utf8').toString('base64')
  return { name: 'tEXt', data: pngChunkText.encode(keyword, text) }
}

// ===== 纯色占位 PNG(无原图时使用) =====

/** png-chunks-encode 自行处理签名/长度/CRC,这里只构造 {name, data} 裸 chunk */
function placeholderChunks(width: number, height: number): PngChunk[] {
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 2 // color type: truecolor RGB
  const raw = Buffer.alloc((width * 3 + 1) * height)
  let pos = 0
  for (let y = 0; y < height; y++) {
    raw[pos++] = 0 // filter none
    for (let x = 0; x < width; x++) {
      // 深蓝紫渐变底色
      const t = y / height
      raw[pos++] = Math.round(24 + t * 12)
      raw[pos++] = Math.round(26 + t * 10)
      raw[pos++] = Math.round(34 + t * 22)
    }
  }
  const idat = zlib.deflateSync(raw, { level: 6 })
  return [
    { name: 'IHDR', data: ihdr },
    { name: 'IDAT', data: idat },
    { name: 'IEND', data: Buffer.alloc(0) }
  ]
}

