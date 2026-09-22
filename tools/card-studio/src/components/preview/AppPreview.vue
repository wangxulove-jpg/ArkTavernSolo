<script setup lang="ts">
/**
 * AppPreview:模拟角色卡前端在 ArkTavern App 中的显示。
 * 行为对齐 CardFrontendWeb.ets:注入 arktavern Bridge mock,
 * 打开即推 schema_update/status_update/message_update 快照;
 * 支持模拟含 <|status|> 状态块的 AI 回复驱动界面刷新。
 */
import { ref, computed, watch } from 'vue'
import { NButton, NInput, NTag } from 'naive-ui'
import type { StatusField } from '@/shared/card'
import { buildArkMockScript, injectScript } from './mockScripts'

const props = withDefaults(
  defineProps<{
    html: string
    mode?: 'panel' | 'fullscreen'
    title?: string
    sizeWidth?: number | string
    sizeHeight?: number | string
    schema?: StatusField[]
    characterName?: string
  }>(),
  { mode: 'panel', title: '界面', schema: () => [], characterName: '角色' }
)

interface MockEntry {
  role: 'user' | 'assistant'
  text: string
}

const iframeRef = ref<HTMLIFrameElement | null>(null)
const mockChat = ref<MockEntry[]>([
  { role: 'assistant', text: '(聊天页模拟:对话在 ChatPage 进行,此面板仅为界面入口)' }
])
const replyInput = ref(
  '我整理好了行囊。\n<|status|>\n{"金币": "520", "地点": "东海坊市", "好感度": "12"}\n</|status|>'
)
const statusRows = ref<{ name: string; value: string; locked: boolean }[]>([])
const previewKey = ref(0)

const srcdoc = computed((): string => {
  if (!props.html) return '<html><body style="color:#888;font-family:sans-serif">无前端 HTML</body></html>'
  const mock = buildArkMockScript({
    schema: props.schema,
    character: { name: props.characterName }
  })
  return injectScript(props.html, mock)
})

watch(
  () => [props.html, props.schema],
  (): void => {
    previewKey.value++
  }
)

function onIframeLoad(): void {
  const win = iframeRef.value?.contentWindow
  if (!win) return
  const mock = (win as unknown as { __arkMock?: { pushSnapshot: () => void; getState: () => { name: string; value: string; locked: boolean }[] } }).__arkMock
  ;(win as unknown as { __arkHost?: { onSend: (t: string) => void; onClose: () => void } }).__arkHost = {
    onSend: (text: string): void => {
      mockChat.value.push({ role: 'user', text })
      // 模拟触发模型:短暂生成态后用户手动推送回复
    },
    onClose: (): void => {
      // 预览中仅记录
    }
  }
  if (mock) {
    mock.pushSnapshot()
    statusRows.value = mock.getState().map((e) => ({ name: e.name, value: e.value, locked: e.locked }))
  }
}

function pushReply(): void {
  const win = iframeRef.value?.contentWindow
  const mock = (win as unknown as { __arkMock?: { simulateReply: (t: string) => void; getState: () => { name: string; value: string; locked: boolean }[] } }).__arkMock
  if (!mock || !replyInput.value.trim()) return
  mockChat.value.push({ role: 'assistant', text: stripStatusBlock(replyInput.value) })
  mock.simulateReply(replyInput.value)
  statusRows.value = mock.getState().map((e) => ({ name: e.name, value: e.value, locked: e.locked }))
}

function stripStatusBlock(text: string): string {
  return text.replace(/<\|status\|>[\s\S]*?(?:<\|\/status\|>|$)/g, '').trim()
}

const panelWidth = computed((): string => {
  const w = props.sizeWidth
  if (typeof w === 'number') return `${w}px`
  return typeof w === 'string' && w ? w : '340px'
})
const panelHeight = computed((): string => {
  const h = props.sizeHeight
  if (typeof h === 'number') return `${h}px`
  return typeof h === 'string' && h ? h : '65%'
})
</script>

<template>
  <div class="app-preview">
    <div class="phone-frame preview-frame">
      <!-- 模拟聊天背景 -->
      <div class="mock-chat-bg">
        <div
          v-for="(entry, i) in mockChat"
          :key="i"
          class="mock-bubble"
          :class="entry.role"
        >
          {{ entry.text.slice(0, 120) }}
        </div>
      </div>

      <!-- panel 模式:浮层面板 -->
      <div v-if="mode === 'panel'" class="front-panel" :style="{ width: panelWidth, height: panelHeight }">
        <div class="panel-titlebar">
          <span class="panel-title">{{ title }}</span>
          <span class="panel-collapse">─</span>
        </div>
        <iframe
          :key="previewKey"
          ref="iframeRef"
          class="panel-iframe"
          :srcdoc="srcdoc"
          sandbox="allow-scripts allow-same-origin"
          @load="onIframeLoad"
        />
      </div>

      <!-- fullscreen 模式:整屏 -->
      <iframe
        v-else
        :key="previewKey"
        ref="iframeRef"
        class="full-iframe"
        :srcdoc="srcdoc"
        sandbox="allow-scripts allow-same-origin"
        @load="onIframeLoad"
      />
    </div>

    <!-- 交互自测控制台 -->
    <div class="console">
      <div class="console-row">
        <span class="console-label">状态字段</span>
        <div class="status-chips">
          <n-tag v-for="row in statusRows" :key="row.name" size="small" :bordered="false">
            {{ row.name }}: {{ row.value || '—' }}{{ row.locked ? ' 🔒' : '' }}
          </n-tag>
          <n-tag v-if="statusRows.length === 0" size="small" :bordered="false" type="warning">
            未声明状态字段
          </n-tag>
        </div>
      </div>
      <n-input
        v-model:value="replyInput"
        type="textarea"
        :rows="4"
        placeholder="模拟一条含 <|status|> 状态块的 AI 回复,推送后右侧界面应实时刷新"
      />
      <div class="console-actions">
        <n-button size="small" type="primary" @click="pushReply">推送回复(触发 status_update)</n-button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.app-preview {
  display: flex;
  flex-direction: column;
  gap: 10px;
  min-width: 0;
}

.preview-frame {
  width: 375px;
  height: 620px;
  flex-shrink: 0;
}

.front-panel {
  position: absolute;
  top: 14px;
  right: 10px;
  display: flex;
  flex-direction: column;
  border-radius: 12px;
  overflow: hidden;
  border: 1px solid #3a3a46;
  background: #17171c;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);
}

.panel-titlebar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 6px 10px;
  background: #22222a;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.85);
  flex-shrink: 0;
}

.panel-collapse {
  color: rgba(255, 255, 255, 0.5);
  cursor: default;
}

.panel-iframe,
.full-iframe {
  border: none;
  width: 100%;
  background: #fff;
}

.panel-iframe {
  flex: 1;
}

.full-iframe {
  height: 100%;
}

.console {
  width: 375px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  background: #17171c;
  border: 1px solid #26262e;
  border-radius: 10px;
  padding: 10px;
}

.console-row {
  display: flex;
  align-items: flex-start;
  gap: 8px;
}

.console-label {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.5);
  white-space: nowrap;
  padding-top: 2px;
}

.status-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
}

.console-actions {
  display: flex;
  gap: 8px;
}
</style>
