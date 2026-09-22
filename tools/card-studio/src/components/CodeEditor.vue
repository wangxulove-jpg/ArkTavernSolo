<script setup lang="ts">
/**
 * CodeMirror 6 封装:v-model 双向绑定,支持 html/json 高亮。
 */
import { onMounted, onBeforeUnmount, watch, shallowRef, ref } from 'vue'
import { basicSetup, EditorView } from 'codemirror'
import { EditorState, Compartment } from '@codemirror/state'
import { html } from '@codemirror/lang-html'
import { json } from '@codemirror/lang-json'
import { oneDark } from '@codemirror/theme-one-dark'

const props = withDefaults(
  defineProps<{
    modelValue: string
    language?: 'html' | 'json'
    height?: string
  }>(),
  { language: 'html', height: '320px' }
)

const emit = defineEmits<{ (e: 'update:modelValue', value: string): void }>()

const hostRef = ref<HTMLDivElement | null>(null)
const viewRef = shallowRef<EditorView | null>(null)
const languageComp = new Compartment()

onMounted((): void => {
  if (!hostRef.value) return
  const view = new EditorView({
    parent: hostRef.value,
    state: EditorState.create({
      doc: props.modelValue,
      extensions: [
        basicSetup,
        oneDark,
        languageComp.of(props.language === 'json' ? json() : html()),
        EditorView.updateListener.of((update): void => {
          if (update.docChanged) {
            lastEmitted = update.state.doc.toString()
            emit('update:modelValue', lastEmitted)
          }
        })
      ]
    })
  })
  viewRef.value = view
})

onBeforeUnmount((): void => {
  viewRef.value?.destroy()
})

// 外部值变化(非本编辑器输入)时同步
let lastEmitted: string | null = null
watch(
  () => props.modelValue,
  (value: string): void => {
    const view = viewRef.value
    if (!view || value === lastEmitted) return
    const current = view.state.doc.toString()
    if (value !== current) {
      view.dispatch({
        changes: { from: 0, to: current.length, insert: value }
      })
    }
  }
)

watch(
  () => props.language,
  (lang: 'html' | 'json'): void => {
    viewRef.value?.dispatch({
      effects: languageComp.reconfigure(lang === 'json' ? json() : html())
    })
  }
)
</script>

<template>
  <div ref="hostRef" class="code-editor" :style="{ height }"></div>
</template>

<style scoped>
.code-editor {
  overflow: hidden;
  border: 1px solid #2a2a33;
  border-radius: 8px;
  background: #282c34;
}

.code-editor :deep(.cm-editor) {
  height: 100%;
}

.code-editor :deep(.cm-scroller) {
  overflow: auto;
}
</style>
