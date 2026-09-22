/**
 * ArkTavern Card Studio 主进程:窗口 + IPC(API 见 preload)。
 */
import { app, BrowserWindow, ipcMain } from 'electron'
import { join } from 'path'
import Store from 'electron-store'
import { openCardDialog, readCardFile, saveCardPng, saveCardJson } from './services/cardIO'
import { startChat, abortChat, testConnection, AiChatRequest } from './services/aiClient'

const store = new Store()

function createWindow(): void {
  const win = new BrowserWindow({
    width: 1360,
    height: 900,
    minWidth: 1100,
    minHeight: 700,
    title: 'ArkTavern Card Studio',
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(__dirname, '../preload/preload.js'),
      sandbox: false,
      contextIsolation: true,
      nodeIntegration: false
    }
  })
  if (process.env.ELECTRON_RENDERER_URL) {
    win.loadURL(process.env.ELECTRON_RENDERER_URL)
  } else {
    win.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

app.whenReady().then((): void => {
  // ===== 卡片 IO =====
  ipcMain.handle('card:openDialog', (): Promise<unknown> => openCardDialog())
  ipcMain.handle('card:readFile', (_e, filePath: string): Promise<unknown> => readCardFile(filePath))
  ipcMain.handle(
    'card:savePng',
    (_e, req: { jsonV2: string; jsonV3: string; pngBase64?: string; suggestedName: string }): Promise<unknown> =>
      saveCardPng(req)
  )
  ipcMain.handle(
    'card:saveJson',
    (_e, req: { jsonText: string; suggestedName: string }): Promise<unknown> => saveCardJson(req)
  )

  // ===== 设置(electron-store) =====
  ipcMain.handle('settings:get', (_e, key: string): unknown => store.get(key))
  ipcMain.handle('settings:set', (_e, key: string, value: unknown): void => {
    store.set(key, value)
  })

  // ===== AI =====
  ipcMain.handle(
    'ai:test',
    (_e, config: { baseUrl: string; apiKey: string; model: string; temperature: number }): Promise<unknown> =>
      testConnection(config)
  )
  ipcMain.on('ai:chat:start', (_e, payload: { id: string; req: AiChatRequest }): void => {
    void startChat(payload.id, payload.req)
  })
  ipcMain.on('ai:chat:abort', (_e, id: string): void => {
    abortChat(id)
  })

  createWindow()
  app.on('activate', (): void => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow()
    }
  })
})

app.on('window-all-closed', (): void => {
  if (process.platform !== 'darwin') {
    app.quit()
  }
})
