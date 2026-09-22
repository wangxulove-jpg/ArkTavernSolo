/**
 * 卡片仓库:当前工作卡、导入/导出、最近文件。
 */
import { defineStore } from 'pinia'
import {
  StudioCard,
  normalizeCard,
  createEmptyCard,
  toV3Json,
  toV2Json,
  getArk,
  setArk,
  ArkExtension,
  StatusField,
  FrontendSpec
} from '@/shared/card'
import type { CardOpenResult } from '@/types/api'

const RECENT_KEY = 'card-studio:recent'

interface RecentEntry {
  fileName: string
  filePath: string
}

export const useCardStore = defineStore('card', {
  state: (): { card: StudioCard | null; recent: RecentEntry[]; loading: boolean } => ({
    card: null,
    recent: loadRecent(),
    loading: false
  }),
  getters: {
    cardName(state): string {
      const name = state.card?.raw.data.name
      return typeof name === 'string' && name ? name : '(未命名)'
    }
  },
  actions: {
    async openFromDialog(): Promise<boolean> {
      this.loading = true
      try {
        const result = (await window.api.openCardDialog()) as CardOpenResult
        return this.applyOpenResult(result)
      } finally {
        this.loading = false
      }
    },
    async openFromPath(filePath: string): Promise<boolean> {
      this.loading = true
      try {
        const result = (await window.api.readCardFile(filePath)) as CardOpenResult
        return this.applyOpenResult(result)
      } finally {
        this.loading = false
      }
    },
    applyOpenResult(result: CardOpenResult): boolean {
      if (!result.ok || !result.jsonText) {
        if (result.error) {
          window.alert(result.error)
        }
        return false
      }
      try {
        this.card = normalizeCard(result.jsonText, result.fileName ?? 'card')
        this.card.filePath = result.filePath
        this.card.pngBase64 = result.pngBase64
      } catch (e) {
        window.alert(`解析失败: ${(e as Error).message}`)
        return false
      }
      if (result.filePath) {
        this.addRecent(result.fileName ?? 'card', result.filePath)
      }
      return true
    },
    newCard(): void {
      this.card = createEmptyCard()
    },
    markModified(): void {
      if (this.card) {
        this.card.modified = true
      }
    },
    addRecent(fileName: string, filePath: string): void {
      this.recent = [
        { fileName, filePath },
        ...this.recent.filter((r: RecentEntry): boolean => r.filePath !== filePath)
      ].slice(0, 10)
      saveRecent(this.recent)
    },
    /** 适配结果写入卡:status + frontend(frontend 为 null 时仅写状态) + 可选清理 ST 脚本 */
    applyAdaptation(
      statusFields: StatusField[],
      frontend: FrontendSpec | null,
      cleanup: { regexScripts: boolean; tavernHelperScripts: boolean }
    ): void {
      if (!this.card) return
      const ark: ArkExtension = { ...getArk(this.card) }
      ark.status = { fields: statusFields }
      if (frontend) {
        ark.frontend = frontend
      }
      setArk(this.card, ark)
      const ext = this.card.raw.data.extensions as Record<string, unknown>
      if (cleanup.regexScripts) delete ext.regex_scripts
      if (cleanup.tavernHelperScripts) delete ext.TavernHelper_scripts
      this.card.modified = true
    },
    async savePng(): Promise<string> {
      if (!this.card) return ''
      const result = await window.api.saveCardPng({
        jsonV2: toV2Json(this.card),
        jsonV3: toV3Json(this.card),
        pngBase64: this.card.pngBase64,
        suggestedName: this.cardName
      })
      if (result.ok) {
        this.card.modified = false
        return result.path ?? ''
      }
      if (result.error) window.alert(result.error)
      return ''
    },
    async saveJson(): Promise<string> {
      if (!this.card) return ''
      const result = await window.api.saveCardJson({
        jsonText: toV3Json(this.card),
        suggestedName: this.cardName
      })
      if (result.ok) {
        this.card.modified = false
        return result.path ?? ''
      }
      if (result.error) window.alert(result.error)
      return ''
    }
  }
})

function loadRecent(): RecentEntry[] {
  try {
    const raw = localStorage.getItem(RECENT_KEY)
    const parsed = raw ? (JSON.parse(raw) as RecentEntry[]) : []
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

function saveRecent(recent: RecentEntry[]): void {
  localStorage.setItem(RECENT_KEY, JSON.stringify(recent))
}
