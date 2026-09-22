/**
 * OpenAI 兼容 API 客户端(主进程请求,无 CORS 限制)。
 * 覆盖 OpenAI / DeepSeek / Gemini(OpenAI 兼容端点) / 各类网关。
 * SSE 流式输出,经 webContents.send 推给渲染进程。
 */
import { webContents } from 'electron'

export interface AiConfig {
  baseUrl: string
  apiKey: string
  model: string
  temperature: number
}

export interface AiChatRequest extends AiConfig {
  system: string
  user: string
  maxTokens?: number
}

export interface AiStreamEvent {
  id: string
  type: 'delta' | 'done' | 'error'
  text?: string
  error?: string
}

const activeControllers = new Map<string, AbortController>()

export function abortChat(id: string): void {
  const ctrl = activeControllers.get(id)
  if (ctrl) {
    ctrl.abort()
    activeControllers.delete(id)
  }
}

function normalizeBaseUrl(baseUrl: string): string {
  let url = baseUrl.trim().replace(/\/+$/, '')
  if (!/\/chat\/completions$/.test(url) && !/\/v\d+(beta)?$/.test(url)) {
    // 未带版本号时默认补 /v1
    url = `${url}/v1`
  }
  return url
}

export async function startChat(id: string, req: AiChatRequest): Promise<void> {
  const send = (ev: AiStreamEvent): void => {
    for (const wc of webContents.getAllWebContents()) {
      if (!wc.isDestroyed()) {
        wc.send('ai:event', ev)
      }
    }
  }
  const ctrl = new AbortController()
  activeControllers.set(id, ctrl)
  let url = normalizeBaseUrl(req.baseUrl) + '/chat/completions'
  try {
    const res = await fetch(url, {
      method: 'POST',
      signal: ctrl.signal,
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${req.apiKey}`
      },
      body: JSON.stringify({
        model: req.model,
        temperature: req.temperature,
        stream: true,
        max_tokens: req.maxTokens ?? 32768,
        messages: [
          { role: 'system', content: req.system },
          { role: 'user', content: req.user }
        ]
      })
    })
    if (!res.ok) {
      const errText = await res.text().catch(() => '')
      throw new Error(`HTTP ${res.status}: ${errText.slice(0, 500) || res.statusText}`)
    }
    if (!res.body) {
      throw new Error('服务未返回内容流')
    }
    const reader = res.body.getReader()
    const decoder = new TextDecoder('utf8')
    let buffer = ''
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const lines = buffer.split('\n')
      buffer = lines.pop() ?? ''
      for (const line of lines) {
        const trimmed = line.trim()
        if (!trimmed.startsWith('data:')) continue
        const payload = trimmed.slice(5).trim()
        if (payload === '[DONE]') continue
        try {
          const obj = JSON.parse(payload)
          const delta = obj?.choices?.[0]?.delta?.content
          if (typeof delta === 'string' && delta.length > 0) {
            send({ id, type: 'delta', text: delta })
          }
        } catch {
          // 忽略无法解析的行(部分网关会发送注释心跳)
        }
      }
    }
    send({ id, type: 'done' })
  } catch (e) {
    const err = e as Error
    if (err.name === 'AbortError') {
      send({ id, type: 'error', error: '已停止' })
    } else {
      send({
        id,
        type: 'error',
        error: `${err.message}(请检查 Base URL / API Key / 模型名,或稍后重试、更换模型)`
      })
    }
  } finally {
    activeControllers.delete(id)
  }
}

export async function testConnection(
  config: AiConfig
): Promise<{ ok: boolean; error?: string; models?: string[] }> {
  try {
    const url = normalizeBaseUrl(config.baseUrl) + '/models'
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${config.apiKey}` }
    })
    if (!res.ok) {
      const errText = await res.text().catch(() => '')
      return { ok: false, error: `HTTP ${res.status}: ${errText.slice(0, 300) || res.statusText}` }
    }
    const obj = (await res.json()) as { data?: Array<{ id: string }> }
    const models: string[] = Array.isArray(obj.data)
      ? obj.data.map((m: { id: string }): string => m.id).filter(Boolean)
      : []
    return { ok: true, models }
  } catch (e) {
    return { ok: false, error: (e as Error).message }
  }
}
