<script setup lang="ts">
/** ArkTavern 扩展:status.fields 可视化编辑 + frontend 表单与 HTML 编辑器 + 实时 App 预览 */
import { computed, reactive, watch } from 'vue'
import {
  NButton,
  NFormItem,
  NInput,
  NInputNumber,
  NSelect,
  NSwitch,
  NTag,
  NModal
} from 'naive-ui'
import { useCardStore } from '@/stores/cardStore'
import { getArk, setArk, StatusField, FrontendSpec } from '@/shared/card'
import CodeEditor from '@/components/CodeEditor.vue'
import AppPreview from '@/components/preview/AppPreview.vue'

const store = useCardStore()

// ===== 状态字段 =====
const fields = computed<StatusField[]>((): StatusField[] => getArk(store.card!).status?.fields ?? [])

function syncFields(): void {
  const ark = { ...getArk(store.card!) }
  ark.status = { fields: fields.value }
  setArk(store.card!, ark)
}

function addField(): void {
  fields.value.push({ name: '', desc: '', type: 'string', locked: false })
  syncFields()
}

function removeField(index: number): void {
  fields.value.splice(index, 1)
  syncFields()
}

// ===== 前端界面 =====
const frontendForm = reactive({
  enabled: false,
  isLegacyString: false,
  html: '',
  mode: 'panel' as 'panel' | 'fullscreen',
  title: '',
  sizeWidth: 360 as number | string,
  sizeHeight: '65%'
})

watch(
  () => store.card,
  (): void => {
    loadFrontend()
  },
  { immediate: true }
)

function loadFrontend(): void {
  if (!store.card) return
  const ark = getArk(store.card)
  if (typeof ark.frontend === 'string') {
    frontendForm.enabled = true
    frontendForm.isLegacyString = true
    frontendForm.html = ark.frontend
    frontendForm.mode = 'fullscreen'
    frontendForm.title = ''
  } else if (ark.frontend && typeof ark.frontend === 'object') {
    const fe = ark.frontend as FrontendSpec
    frontendForm.enabled = true
    frontendForm.isLegacyString = false
    frontendForm.html = fe.html ?? ''
    frontendForm.mode = fe.mode === 'fullscreen' ? 'fullscreen' : 'panel'
    frontendForm.title = fe.title ?? ''
    frontendForm.sizeWidth = fe.size?.width ?? 360
    frontendForm.sizeHeight = (fe.size?.height as string) ?? '65%'
  } else {
    frontendForm.enabled = false
    frontendForm.isLegacyString = false
    frontendForm.html = ''
    frontendForm.mode = 'panel'
    frontendForm.title = ''
    frontendForm.sizeWidth = 360
    frontendForm.sizeHeight = '65%'
  }
}

function saveFrontend(): void {
  if (!frontendForm.enabled) return
  const ark = { ...getArk(store.card!) }
  ark.frontend = {
    html: frontendForm.html,
    mode: frontendForm.mode,
    ...(frontendForm.title ? { title: frontendForm.title } : {}),
    ...(frontendForm.mode === 'panel'
      ? { size: { width: frontendForm.sizeWidth, height: frontendForm.sizeHeight } }
      : {})
  }
  setArk(store.card!, ark)
  frontendForm.isLegacyString = false
}

const htmlChars = computed((): number => frontendForm.html.length)
const htmlOverflow = computed((): boolean => frontendForm.html.length > 512 * 1024)
const htmlHeavy = computed((): boolean => frontendForm.html.length > 256 * 1024)

// ===== 预览弹窗 =====
const previewOpen = ref<boolean>(false)
</script>

<script lang="ts">
import { ref } from 'vue'
</script>

<template>
  <div class="ark-tab">
    <!-- 状态字段 -->
    <section class="section">
      <div class="section-head">
        <h3>角色状态 status.fields</h3>
        <n-button size="small" @click="addField">+ 添加字段</n-button>
      </div>
      <p class="section-desc">
        声明后 App 聊天时自动注入状态输出规则,模型每轮回复末尾输出状态块更新这些字段;无需在 system_prompt 中另写规则。
      </p>
      <div v-if="fields.length === 0" class="empty-tip">未声明状态字段(状态功能整体禁用)</div>
      <div v-for="(field, index) in fields" :key="index" class="field-row">
        <n-input
          size="small"
          placeholder="字段名"
          :value="field.name"
          @update:value="field.name = $event; syncFields()"
          style="width: 140px"
        />
        <n-input
          size="small"
          placeholder="含义/取值说明"
          :value="field.desc ?? ''"
          @update:value="field.desc = $event; syncFields()"
          style="flex: 1"
        />
        <n-select
          size="small"
          :value="field.type ?? 'string'"
          :options="[
            { label: 'string', value: 'string' },
            { label: 'number', value: 'number' }
          ]"
          @update:value="field.type = $event; syncFields()"
          style="width: 110px"
        />
        <div class="locked-cell">
          <span class="locked-label">locked</span>
          <n-switch
            size="small"
            :value="field.locked === true"
            @update:value="field.locked = $event; syncFields()"
          />
        </div>
        <n-button size="small" quaternary type="error" @click="removeField(index)">删</n-button>
      </div>
    </section>

    <!-- 前端界面 -->
    <section class="section">
      <div class="section-head">
        <h3>前端界面 frontend</h3>
        <div class="head-actions">
          <n-tag v-if="frontendForm.isLegacyString" size="small" type="warning" :bordered="false">旧字符串格式(保存后转为对象格式)</n-tag>
          <n-switch v-model:value="frontendForm.enabled" @update:value="saveFrontend()">
            <template #checked>启用</template>
            <template #unchecked>停用</template>
          </n-switch>
        </div>
      </div>
      <p class="section-desc">
        HTML 需 CSS/JS 全内联、无外部资源;经 window.arktavern Bridge 与 App 交互(契约见 docs/frontend-card-contract.md)。
      </p>
      <template v-if="frontendForm.enabled">
        <div class="fe-form">
          <n-form-item label="模式 mode">
            <n-select
              :value="frontendForm.mode"
              :options="[
                { label: 'panel(聊天页浮层面板)', value: 'panel' },
                { label: 'fullscreen(独立全屏页)', value: 'fullscreen' }
              ]"
              @update:value="frontendForm.mode = $event; saveFrontend()"
            />
          </n-form-item>
          <n-form-item label="标题 title">
            <n-input :value="frontendForm.title" @update:value="frontendForm.title = $event; saveFrontend()" />
          </n-form-item>
          <template v-if="frontendForm.mode === 'panel'">
            <n-form-item label="面板宽度 width(px)">
              <n-input-number
                :value="Number(frontendForm.sizeWidth) || 360"
                @update:value="frontendForm.sizeWidth = $event ?? 360; saveFrontend()"
              />
            </n-form-item>
            <n-form-item label="面板高度 height">
              <n-input
                :value="String(frontendForm.sizeHeight)"
                placeholder="65% 或 480"
                @update:value="frontendForm.sizeHeight = $event; saveFrontend()"
              />
            </n-form-item>
          </template>
        </div>
        <div class="html-meta">
          <n-tag size="small" :bordered="false" :type="htmlOverflow ? 'error' : htmlHeavy ? 'warning' : 'success'">
            {{ htmlChars }} 字符{{ htmlOverflow ? ' · 超 512KB 上限,导入后不会启用' : htmlHeavy ? ' · 超建议值 256KB' : '' }}
          </n-tag>
          <n-button size="small" @click="previewOpen = true">App 预览</n-button>
        </div>
        <CodeEditor
          :model-value="frontendForm.html"
          language="html"
          height="420px"
          @update:model-value="frontendForm.html = $event; saveFrontend()"
        />
      </template>
    </section>

    <n-modal v-model:show="previewOpen" :width="860" preset="card" title="App 内显示预览(手机模拟)">
      <div style="display: flex; justify-content: center">
        <AppPreview
          :html="frontendForm.html"
          :mode="frontendForm.mode"
          :title="frontendForm.title || '界面'"
          :size-width="frontendForm.sizeWidth"
          :size-height="frontendForm.sizeHeight"
          :schema="fields"
          :character-name="String(store.card?.raw.data.name ?? '')"
        />
      </div>
    </n-modal>
  </div>
</template>

<style scoped>
.ark-tab {
  max-width: 980px;
  display: flex;
  flex-direction: column;
  gap: 26px;
}

.section-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.section-head h3 {
  font-size: 14px;
  margin: 0;
}

.section-desc {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.45);
  margin: 6px 0 12px;
  line-height: 1.6;
}

.empty-tip {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.4);
  padding: 10px 0;
}

.field-row {
  display: flex;
  gap: 8px;
  align-items: center;
  margin-bottom: 8px;
}

.locked-cell {
  display: flex;
  align-items: center;
  gap: 6px;
}

.locked-label {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.4);
}

.head-actions {
  display: flex;
  align-items: center;
  gap: 10px;
}

.fe-form {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(220px, 1fr));
  gap: 0 16px;
  margin-bottom: 10px;
}

.html-meta {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}
</style>
