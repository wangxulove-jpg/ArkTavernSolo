/**
 * preload:contextBridge 暴露安全 API(window.api)。
 * 类型契约与 src/types/api.d.ts 保持一致。
 */
import { contextBridge, ipcRenderer, webUtils } from 'electron'

interface AiStreamEvent {
  id: string
  type: 'delta' | 'done' | 'error'
  text?: string
  error?: string
}

interface AiChatRequest {
  baseUrl: string
  apiKey: string
  model: string
  temperature: number
  system: string
  user: string
  maxTokens?: number
}

const api = {
  openCardDialog: (): Promise<unknown> => ipcRenderer.invoke('card:openDialog'),
  readCardFile: (filePath: string): Promise<unknown> => ipcRenderer.invoke('card:readFile', filePath),
  saveCardPng: (req: {
    jsonV2: string
    jsonV3: string
    pngBase64?: string
    suggestedName: string
  }): Promise<{ ok: boolean; path?: string; error?: string }> =>
    ipcRenderer.invoke('card:savePng', req),
  saveCardJson: (req: {
    jsonText: string
    suggestedName: string
  }): Promise<{ ok: boolean; path?: string; error?: string }> =>
    ipcRenderer.invoke('card:saveJson', req),
  getPathForFile: (file: File): string => webUtils.getPathForFile(file),
  getSetting: <T>(key: string): Promise<T | undefined> => ipcRenderer.invoke('settings:get', key),
  setSetting: (key: string, value: unknown): Promise<void> =>
    ipcRenderer.invoke('settings:set', key, value),
  aiTest: (config: {
    baseUrl: string
    apiKey: string
    model: string
    temperature: number
  }): Promise<{ ok: boolean; error?: string; models?: string[] }> =>
    ipcRenderer.invoke('ai:test', config),
  aiChat: (
    req: AiChatRequest,
    onEvent: (ev: AiStreamEvent) => void
  ): { abort: () => void } => {
    const id = `chat-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`
    const listener = (_e: Electron.IpcRendererEvent, ev: AiStreamEvent): void => {
      if (ev.id !== id) return
      onEvent(ev)
      if (ev.type === 'done' || ev.type === 'error') {
        ipcRenderer.removeListener('ai:event', listener)
      }
    }
    ipcRenderer.on('ai:event', listener)
    ipcRenderer.send('ai:chat:start', { id, req })
    return {
      abort: (): void => {
        ipcRenderer.send('ai:chat:abort', id)
        ipcRenderer.removeListener('ai:event', listener)
      }
    }
  }
}

contextBridge.exposeInMainWorld('api', api)
