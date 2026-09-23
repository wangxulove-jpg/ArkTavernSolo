<script setup lang="ts">
/**
 * 卡片编辑器:Tab 式全字段编辑 + 原始 JSON + 导出 PNG/JSON。
 */
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import {
  NTabs,
  NTabPane,
  NButton,
  NTag,
  NSpace,
  useMessage,
  useDialog
} from 'naive-ui'
import { useCardStore } from '@/stores/cardStore'
import BasicInfoTab from '@/components/editor/BasicInfoTab.vue'
import GreetingsTab from '@/components/editor/GreetingsTab.vue'
import PromptsTab from '@/components/editor/PromptsTab.vue'
import WorldbookTab from '@/components/editor/WorldbookTab.vue'
import ArkTavernTab from '@/components/editor/ArkTavernTab.vue'
import CodeEditor from '@/components/CodeEditor.vue'

const router = useRouter()
const store = useCardStore()
const message = useMessage()
const dialog = useDialog()

// ===== 原始 JSON 编辑 =====
const editingJson = ref(false)
const jsonDraft = ref('')

const formattedJson = computed((): string =>
  JSON.stringify(store.card?.raw.data ?? {}, null, 2)
)

function startEditJson(): void {
  dialog.warning({
    title: '进入原始 JSON 编辑模式',
    content:
      '直接编辑 JSON 可能破坏卡片结构(字段名写错、括号缺失等),导出后 App 可能无法导入。建议优先使用各表单 Tab 编辑。确定继续吗?',
    positiveText: '进入编辑',
    negativeText: '取消',
    onPositiveClick: (): void => {
      jsonDraft.value = formattedJson.value
      editingJson.value = true
    }
  })
}

function applyJsonEdit(): void {
  try {
    const parsed = JSON.parse(jsonDraft.value) as Record<string, unknown>
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      message.error('根节点必须是 JSON 对象')
      return
    }
    store.card!.raw.data = parsed
    store.markModified()
    editingJson.value = false
    message.success('已应用 JSON 修改')
  } catch (e) {
    message.error(`JSON 解析失败: ${(e as Error).message}`)
  }
}

function cancelJsonEdit(): void {
  editingJson.value = false
}

// ===== 导出 =====
const exporting = ref(false)

async function exportPng(): Promise<void> {
  exporting.value = true
  try {
    const path = await store.savePng()
    if (path) message.success(`已导出 PNG: ${path}`)
  } finally {
    exporting.value = false
  }
}

async function exportJson(): Promise<void> {
  exporting.value = true
  try {
    const path = await store.saveJson()
    if (path) message.success(`已导出 JSON: ${path}`)
  } finally {
    exporting.value = false
  }
}

function backHome(): void {
  if (store.card?.modified) {
    dialog.warning({
      title: '有未保存的修改',
      content: '当前卡片的修改尚未导出,离开将丢失。确定离开吗?',
      positiveText: '离开',
      negativeText: '留下',
      onPositiveClick: (): void => {
        router.push({ name: 'home' })
      }
    })
    return
  }
  router.push({ name: 'home' })
}
</script>

<template>
  <div class="editor">
    <div class="toolbar">
      <div class="toolbar-left">
        <n-button quaternary size="small" @click="backHome">← 返回</n-button>
        <span class="file-name">{{ store.cardName }}</span>
        <n-tag v-if="store.card?.modified" size="small" type="warning" :bordered="false">
          未保存
        </n-tag>
        <n-tag v-if="store.card?.sourceSpec" size="small" :bordered="false">
          来源: {{ store.card.sourceSpec }}
        </n-tag>
      </div>
      <n-space>
        <n-button :loading="exporting" @click="exportJson">导出 JSON</n-button>
        <n-button type="primary" :loading="exporting" @click="exportPng">导出 PNG(写入手机可导入)</n-button>
      </n-space>
    </div>

    <n-tabs type="line" default-value="basic" animated class="editor-tabs">
      <n-tab-pane name="basic" tab="基本信息">
        <BasicInfoTab />
      </n-tab-pane>
      <n-tab-pane name="greetings" tab="开场白">
        <GreetingsTab />
      </n-tab-pane>
      <n-tab-pane name="prompts" tab="提示词 · 对话示例">
        <PromptsTab />
      </n-tab-pane>
      <n-tab-pane name="worldbook" tab="世界书">
        <WorldbookTab />
      </n-tab-pane>
      <n-tab-pane name="arktavern" tab="ArkTavern 扩展">
        <ArkTavernTab />
      </n-tab-pane>
      <n-tab-pane name="raw" tab="原始 JSON">
        <div class="raw-json">
          <div v-if="!editingJson" class="raw-view">
            <pre class="raw-pre">{{ formattedJson }}</pre>
            <div class="raw-actions">
              <n-button size="small" @click="startEditJson">编辑模式(有风险)</n-button>
            </div>
          </div>
          <div v-else class="raw-edit">
            <CodeEditor v-model="jsonDraft" language="json" height="520px" />
            <div class="raw-actions">
              <n-space>
                <n-button size="small" @click="cancelJsonEdit">取消</n-button>
                <n-button size="small" type="primary" @click="applyJsonEdit">应用修改</n-button>
              </n-space>
            </div>
          </div>
        </div>
      </n-tab-pane>
    </n-tabs>
  </div>
</template>

<style scoped>
.editor {
  height: 100%;
  display: flex;
  flex-direction: column;
  padding: 12px 20px 0;
  box-sizing: border-box;
}

.toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding-bottom: 10px;
  flex-shrink: 0;
}

.toolbar-left {
  display: flex;
  align-items: center;
  gap: 10px;
  min-width: 0;
}

.file-name {
  font-size: 14px;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 320px;
}

.editor-tabs {
  flex: 1;
  min-height: 0;
}

/* naive-ui tabs 根节点为 flex column:nav 固定,pane wrapper 占满剩余空间并滚动 */
.editor-tabs :deep(.n-tabs-pane-wrapper) {
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding-bottom: 24px;
}

.raw-json {
  max-width: 960px;
}

.raw-pre {
  background: #131318;
  border: 1px solid #26262e;
  border-radius: 8px;
  padding: 14px;
  font-size: 12px;
  line-height: 1.6;
  max-height: 560px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-all;
  margin: 0;
}

.raw-actions {
  margin-top: 10px;
  display: flex;
  gap: 8px;
}
</style>
