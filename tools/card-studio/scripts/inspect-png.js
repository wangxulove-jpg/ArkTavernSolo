/**
 * 诊断脚本:列出 PNG 卡内所有文本类 chunk(tEXt/zTXt/iTXt)的 keyword 与数据头部。
 * 用法: node scripts/inspect-png.js <png路径>
 */
const fs = require('fs')
const path = require('path')
const zlib = require('zlib')

async function main() {
  const extract = (await import('png-chunks-extract')).default
  const pngChunkText = require('png-chunk-text')

  const file = process.argv[2]
  const buf = fs.readFileSync(file)
  console.log('file:', path.basename(file), 'size:', buf.length)
  const sigOk = buf.readUInt32BE(0) === 0x89504e47
  console.log('png signature:', sigOk ? 'OK' : 'INVALID')

  let chunks
  try {
    chunks = extract(buf)
  } catch (e) {
    console.log('extract FAILED:', e.message)
    return
  }
  const counts = {}
  for (const c of chunks) counts[c.name] = (counts[c.name] || 0) + 1
  console.log('chunk types:', JSON.stringify(counts))

  for (const c of chunks) {
    if (c.name === 'tEXt') {
      try {
        const d = pngChunkText.decode(c.data)
        console.log(
          `tEXt keyword=${JSON.stringify(d.keyword)} textLen=${d.text.length} head=${JSON.stringify(d.text.slice(0, 48))}`
        )
      } catch (e) {
        console.log('tEXt decode fail:', e.message)
      }
    } else if (c.name === 'zTXt') {
      try {
        const pos = c.data.indexOf(0)
        const keyword = c.data.toString('latin1', 0, pos)
        const text = zlib.inflateSync(c.data.subarray(pos + 2)).toString('utf8')
        console.log(
          `zTXt keyword=${JSON.stringify(keyword)} textLen=${text.length} head=${JSON.stringify(text.slice(0, 48))}`
        )
      } catch (e) {
        console.log('zTXt decode fail:', e.message)
      }
    } else if (c.name === 'iTXt') {
      try {
        const pos = c.data.indexOf(0)
        const keyword = c.data.toString('latin1', 0, pos)
        const compFlag = c.data[pos + 1]
        let p = pos + 3
        p = c.data.indexOf(0, p) + 1
        p = c.data.indexOf(0, p) + 1
        const raw = c.data.subarray(p)
        const text =
          compFlag === 1 ? zlib.inflateSync(raw).toString('utf8') : raw.toString('utf8')
        console.log(
          `iTXt keyword=${JSON.stringify(keyword)} comp=${compFlag} textLen=${text.length} head=${JSON.stringify(text.slice(0, 48))}`
        )
      } catch (e) {
        console.log('iTXt decode fail:', e.message)
      }
    }
  }
}

main().catch((e) => {
  console.error('FATAL:', e)
  process.exit(1)
})
