/** png-chunks 系列库无官方类型,按 ST 同款用法声明 */
declare module 'png-chunks-extract' {
  interface PngChunk {
    name: string
    data: Buffer
  }
  const extract: (buffer: Buffer) => PngChunk[]
  export default extract
}

declare module 'png-chunk-text' {
  export function encode(keyword: string, text: string): Buffer
  export function decode(data: Buffer): { keyword: string; text: string }
}

declare module 'png-chunks-encode' {
  interface PngChunk {
    name: string
    data: Buffer
  }
  const encode: (chunks: PngChunk[]) => Buffer
  export default encode
}

declare module 'jquery/dist/jquery.min.js?raw' {
  const source: string
  export default source
}
