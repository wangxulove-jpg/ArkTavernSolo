<script setup lang="ts">
/** 世界书:character_book 元信息 + entries 表格 + 编辑抽屉,带条数/字数预算警告 */
import { computed, ref } from 'vue'
import {
  NButton,
  NEmpty,
  NDrawer,
  NDrawerContent,
  NForm,
  NFormItem,
  NInput,
  NInputNumber,
  NSwitch,
  NSelect,
  NTag
} from 'naive-ui'
import { useCardStore } from '@/stores/cardStore'

interface BookEntry {
  id?: number
  name?: string
  comment?: string
  keys?: string[]
  secondary_keys?: string[]
  content: string
  enabled?: boolean
  constant?: boolean
  insertion_order?: number
  priority?: number
  position?: string | number
  case_sensitive?: boolean
  [key: string]: unknown
}

const store = useCardStore()

const book = computed((): Record<string, unknown> | null => {
  const bookValue = store.card!.raw.data.character_book
  if (bookValue && typeof bookValue === 'object') {
    return bookValue as Record<string, unknown>
  }
  return null
})
const entries = computed((): BookEntry[] => (book.value?.entries as BookEntry[]) ?? [])

const editingIndex = ref(-1)
const drawerOpen = ref(false)

const totalChars = computed((): number =>
  entries.value.reduce((sum: number, e: BookEntry): number => sum + (e.content?.length ?? 0), 0)
)
const overflow = computed((): boolean => entries.value.length > 2000 || totalChars.value > 100000)

function sync(): void {
  store.markModified()
}

function entryTitle(entry: BookEntry): string {
  return entry.name || entry.comment || '(未命名)'
}

function openEntry(index: number): void {
  editingIndex.value = index
  drawerOpen.value = true
}

function addEntry(): void {
  ensureBook()
  entries.value.push({
    name: '',
    keys: [],
    content: '',
    enabled: true,
    constant: false,
    insertion_order: 100,
    position: 'before_char'
  })
  sync()
  openEntry(entries.value.length - 1)
}

function removeEntry(index: number): void {
  entries.value.splice(index, 1)
  sync()
}

function ensureBook(): void {
  if (!book.value) {
    store.card!.raw.data.character_book = {
      name: '',
      description: '',
      scan_depth: 100,
      token_budget: 500,
      recursive_scanning: false,
      extensions: {},
      entries: []
    }
  }
}

const positionOptions = [
  { label: '角色定义前 before_char', value: 'before_char' },
  { label: '角色定义后 after_char', value: 'after_char' },
  { label: '作者注释前 before_authors_notes', value: 'before_authors_notes' },
  { label: '作者注释后 after_authors_notes', value: 'after_authors_notes' },
  { label: '对话历史顶部 at_depth', value: 'at_depth' }
]
</script>

<template>
  <div class="worldbook">
    <div class="wb-head">
      <span v-if="overflow" class="wb-warn">
        <n-tag type="warning" size="small">超出 App 预算:{{ entries.length }} 条 / {{ totalChars }} 字符(上限 2000 条,单条 10 万字符)</n-tag>
      </span>
      <n-tag v-else size="small" type="info" :bordered="false">{{ entries.length }} 条 · {{ (totalChars / 1000).toFixed(1) }}K 字符</n-tag>
      <n-button size="small" @click="addEntry">+ 添加条目</n-button>
    </div>

    <n-empty v-if="entries.length === 0" description="此卡没有世界书" size="small" style="margin: 16px 0" />

    <div v-else class="wb-list">
      <div v-for="(entry, index) in entries" :key="index" class="wb-item">
        <div class="wb-item-main" @click="openEntry(index)">
          <span class="wb-item-name">{{ entryTitle(entry) }}</span>
          <span class="wb-item-keys">{{ (entry.keys ?? []).join(', ') }}</span>
        </div>
        <div class="wb-item-side">
          <n-tag v-if="entry.constant" size="tiny" :bordered="false" type="success">常驻</n-tag>
          <n-tag v-if="entry.enabled === false" size="tiny" :bordered="false" type="default">停用</n-tag>
          <span class="wb-item-chars">{{ entry.content?.length ?? 0 }} 字</span>
          <n-button size="tiny" quaternary type="error" @click.stop="removeEntry(index)">删</n-button>
        </div>
      </div>
    </div>

    <n-drawer v-model:show="drawerOpen" :width="620" placement="right">
      <n-drawer-content :title="`编辑条目: ${editingIndex >= 0 ? entryTitle(entries[editingIndex]) : ''}`" closable>
        <template v-if="editingIndex >= 0 && entries[editingIndex]">
          <n-form label-placement="top">
            <n-form-item label="名称">
              <n-input
                :value="entries[editingIndex].name ?? ''"
                @update:value="entries[editingIndex].name = $event; sync()"
              />
            </n-form-item>
            <n-form-item label="关键词 keys(逗号分隔)">
              <n-input
                :value="(entries[editingIndex].keys ?? []).join(',')"
                @update:value="entries[editingIndex].keys = $event.split(/[,，]/).map((s: string) => s.trim()).filter(Boolean); sync()"
              />
            </n-form-item>
            <n-form-item label="次要关键词 secondary_keys(逗号分隔)">
              <n-input
                :value="(entries[editingIndex].secondary_keys ?? []).join(',')"
                @update:value="entries[editingIndex].secondary_keys = $event.split(/[,，]/).map((s: string) => s.trim()).filter(Boolean); sync()"
              />
            </n-form-item>
            <n-form-item label="内容">
              <n-input
                type="textarea"
                :autosize="{ minRows: 6, maxRows: 20 }"
                :value="entries[editingIndex].content ?? ''"
                @update:value="entries[editingIndex].content = $event; sync()"
              />
            </n-form-item>
            <div class="wb-form-row">
              <n-form-item label="常驻 constant">
                <n-switch
                  :value="entries[editingIndex].constant === true"
                  @update:value="entries[editingIndex].constant = $event; sync()"
                />
              </n-form-item>
              <n-form-item label="启用 enabled">
                <n-switch
                  :value="entries[editingIndex].enabled !== false"
                  @update:value="entries[editingIndex].enabled = $event; sync()"
                />
              </n-form-item>
            </div>
            <div class="wb-form-row">
              <n-form-item label="插入顺序">
                <n-input-number
                  :value="entries[editingIndex].insertion_order ?? 100"
                  @update:value="entries[editingIndex].insertion_order = $event ?? 100; sync()"
                />
              </n-form-item>
              <n-form-item label="位置">
                <n-select
                  :value="String(entries[editingIndex].position ?? 'before_char')"
                  :options="positionOptions"
                  @update:value="entries[editingIndex].position = $event; sync()"
                />
              </n-form-item>
            </div>
          </n-form>
        </template>
      </n-drawer-content>
    </n-drawer>
  </div>
</template>

<style scoped>
.worldbook {
  max-width: 860px;
}

.wb-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 10px;
  gap: 12px;
}

.wb-list {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.wb-item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  background: #17171c;
  border: 1px solid #26262e;
  border-radius: 8px;
  padding: 8px 12px;
}

.wb-item-main {
  flex: 1;
  min-width: 0;
  cursor: pointer;
  display: flex;
  gap: 10px;
  align-items: baseline;
}

.wb-item-main:hover .wb-item-name {
  color: #a5b4fc;
}

.wb-item-name {
  font-size: 13px;
  font-weight: 500;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 260px;
}

.wb-item-keys {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.4);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.wb-item-side {
  display: flex;
  align-items: center;
  gap: 6px;
  flex-shrink: 0;
}

.wb-item-chars {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
}

.wb-form-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0 16px;
}
</style>
