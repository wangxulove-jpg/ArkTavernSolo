/** window.api 类型契约(与 electron/preload.ts 实现保持一致) */

export interface CardOpenResult {
  ok: boolean
  error?: string
  fileName?: string
  filePath?: string
  jsonText?: string
  pngBase64?: string
}

export interface AiConfig {
  baseUrl: string
  apiKey: string
  model: string
  temperature: number
}

export interface AiStreamEvent {
  id: string
  type: 'delta' | 'done' | 'error'
  text?: string
  error?: string
}

export interface AiChatRequest extends AiConfig {
  system: string
  user: string
  maxTokens?: number
}

export interface Api {
  openCardDialog(): Promise<CardOpenResult>
  readCardFile(filePath: string): Promise<CardOpenResult>
  saveCardPng(req: {
    jsonV2: string
    jsonV3: string
    pngBase64?: string
    suggestedName: string
  }): Promise<{ ok: boolean; path?: string; error?: string }>
  saveCardJson(req: {
    jsonText: string
    suggestedName: string
  }): Promise<{ ok: boolean; path?: string; error?: string }>
  getPathForFile(file: File): string
  getSetting<T>(key: string): Promise<T | undefined>
  setSetting(key: string, value: unknown): Promise<void>
  aiTest(config: AiConfig): Promise<{ ok: boolean; error?: string; models?: string[] }>
  aiChat(req: AiChatRequest, onEvent: (ev: AiStreamEvent) => void): { abort: () => void }
}

declare global {
  interface Window {
    api: Api
  }
}

export {}
