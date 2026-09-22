/**
 * AI 设置仓库(Base URL / API Key / 模型 / 温度),持久化在主进程 electron-store。
 */
import { defineStore } from 'pinia'
import type { AiConfig } from '@/types/api'

export interface AiSettings extends AiConfig {
  configured: boolean
}

export const DEFAULT_SETTINGS: AiSettings = {
  baseUrl: 'https://api.deepseek.com/v1',
  apiKey: '',
  model: 'deepseek-chat',
  temperature: 0.7,
  configured: false
}

export const useSettingsStore = defineStore('settings', {
  state: (): { ai: AiSettings; loaded: boolean } => ({
    ai: { ...DEFAULT_SETTINGS },
    loaded: false
  }),
  actions: {
    async load(): Promise<void> {
      if (this.loaded) return
      const saved = await window.api.getSetting<AiConfig>('aiConfig')
      if (saved && saved.baseUrl) {
        this.ai = { ...DEFAULT_SETTINGS, ...saved, configured: !!saved.apiKey }
      }
      this.loaded = true
    },
    async save(): Promise<void> {
      await window.api.setSetting('aiConfig', {
        baseUrl: this.ai.baseUrl,
        apiKey: this.ai.apiKey,
        model: this.ai.model,
        temperature: this.ai.temperature
      })
      this.ai.configured = !!this.ai.apiKey
    },
    async test(): Promise<{ ok: boolean; error?: string; models?: string[] }> {
      return window.api.aiTest({
        baseUrl: this.ai.baseUrl,
        apiKey: this.ai.apiKey,
        model: this.ai.model,
        temperature: this.ai.temperature
      })
    }
  }
})
