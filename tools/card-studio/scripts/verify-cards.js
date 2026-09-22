/**
 * 验证脚本:用与 pngCard.ts 修复后相同的逻辑读取所有角色卡,
 * 验证 chara/ccv3 提取 + base64 解码 + JSON.parse 全链路。
 * 用法: node scripts/verify-cards.js <目录>
 */
const fs = require('fs')
const path = require('path')

async function main() {
  const extract = (await import('png-chunks-extract')).default
  const pngChunkText = require('png-chunk-text')

  /** 与 pngCard.ts extractCardJson 修复后一致的逻辑 */
  function extractCardJson(png) {
    let chunks
    try {
      chunks = extract(png)
    } catch {
      return null
    }
    let chara = null
    for (const chunk of chunks) {
      if (chunk.name === 'tEXt') {
        const decoded = pngChunkText.decode(chunk.data)
        if (decoded.keyword === 'ccv3') {
          return Buffer.from(decoded.text, 'base64').toString('utf8')
        }
        if (decoded.keyword === 'chara') {
          chara = Buffer.from(decoded.text, 'base64').toString('utf8')
        }
      }
    }
    return chara
  }

  const dir = process.argv[2]
  const files = fs
    .readdirSync(dir)
    .filter((f) => f.toLowerCase().endsWith('.png'))
    .sort()

  let pass = 0
  let fail = 0
  for (const f of files) {
    const full = path.join(dir, f)
    try {
      const png = fs.readFileSync(full)
      const jsonText = extractCardJson(png)
      if (!jsonText) {
        console.log(`FAIL ${f} — no chara/ccv3 found`)
        fail++
        continue
      }
      const json = JSON.parse(jsonText)
      const spec = json.spec || json.spec_version || '(v1)'
      const name = json.data?.name ?? json.name ?? '?'
      const extKeys = Object.keys(json.data?.extensions ?? json.extensions ?? {})
      console.log(`PASS ${f} — spec=${spec} name=${name} extensions=[${extKeys.join(',')}]`)
      pass++
    } catch (e) {
      console.log(`FAIL ${f} — ${e.message}`)
      fail++
    }
  }
  console.log(`\n${pass} passed, ${fail} failed, ${files.length} total`)
  process.exit(fail > 0 ? 1 : 0)
}

main().catch((e) => {
  console.error('FATAL:', e)
  process.exit(1)
})
