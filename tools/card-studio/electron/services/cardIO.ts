/**
 * 卡片文件 IO:打开对话框/读取文件/保存 PNG/JSON。
 * PNG 解析与写回见 pngCard.ts;业务字段归一化在渲染进程(src/shared/card.ts)完成。
 */
import * as fs from 'fs/promises'
import * as path from 'path'
import { dialog, BrowserWindow } from 'electron'
import { extractCardJson, writeCardJsonToPng } from './pngCard'

export interface CardOpenResult {
  ok: boolean
  error?: string
  fileName?: string
  filePath?: string
  jsonText?: string
  pngBase64?: string
}

export async function openCardDialog(): Promise<CardOpenResult> {
  const win = BrowserWindow.getFocusedWindow()
  const picked = await dialog.showOpenDialog(win!, {
    title: '选择角色卡(PNG / JSON)',
    properties: ['openFile'],
    filters: [{ name: '角色卡', extensions: ['png', 'json'] }]
  })
  if (picked.canceled || picked.filePaths.length === 0) {
    return { ok: false }
  }
  return readCardFile(picked.filePaths[0])
}

export async function readCardFile(filePath: string): Promise<CardOpenResult> {
  const fileName = path.basename(filePath)
  try {
    if (filePath.toLowerCase().endsWith('.json')) {
      const jsonText = await fs.readFile(filePath, 'utf8')
      JSON.parse(jsonText) // 校验
      return { ok: true, fileName, filePath, jsonText }
    }
    const png = await fs.readFile(filePath)
    const jsonText = extractCardJson(png)
    if (!jsonText) {
      return { ok: false, error: 'PNG 中未找到角色卡数据(chara/ccv3),可能不是角色卡图片' }
    }
    JSON.parse(jsonText) // 校验
    return {
      ok: true,
      fileName,
      filePath,
      jsonText,
      pngBase64: png.toString('base64')
    }
  } catch (e) {
    return { ok: false, error: `读取失败: ${(e as Error).message}` }
  }
}

export interface SavePngRequest {
  jsonV2: string
  jsonV3: string
  pngBase64?: string
  suggestedName: string
}

export async function saveCardPng(req: SavePngRequest): Promise<{ ok: boolean; path?: string; error?: string }> {
  const win = BrowserWindow.getFocusedWindow()
  const suggested = req.suggestedName.replace(/[\\/:*?"<>|]/g, '_')
  const picked = await dialog.showSaveDialog(win!, {
    title: '保存角色卡 PNG',
    defaultPath: suggested.endsWith('.png') ? suggested : `${suggested}.png`,
    filters: [{ name: 'PNG 角色卡', extensions: ['png'] }]
  })
  if (picked.canceled || !picked.filePath) {
    return { ok: false }
  }
  try {
    const png = writeCardJsonToPng(req.pngBase64 ?? null, req.jsonV2, req.jsonV3)
    await fs.writeFile(picked.filePath, png)
    return { ok: true, path: picked.filePath }
  } catch (e) {
    return { ok: false, error: `保存失败: ${(e as Error).message}` }
  }
}

export async function saveCardJson(req: {
  jsonText: string
  suggestedName: string
}): Promise<{ ok: boolean; path?: string; error?: string }> {
  const win = BrowserWindow.getFocusedWindow()
  const suggested = req.suggestedName.replace(/[\\/:*?"<>|]/g, '_')
  const picked = await dialog.showSaveDialog(win!, {
    title: '保存角色卡 JSON',
    defaultPath: suggested.endsWith('.json') ? suggested : `${suggested}.json`,
    filters: [{ name: 'JSON 角色卡', extensions: ['json'] }]
  })
  if (picked.canceled || !picked.filePath) {
    return { ok: false }
  }
  try {
    await fs.writeFile(picked.filePath, req.jsonText, 'utf8')
    return { ok: true, path: picked.filePath }
  } catch (e) {
    return { ok: false, error: `保存失败: ${(e as Error).message}` }
  }
}
