<script setup lang="ts">
/**
 * PreviewCompare:左右分栏对比——左 ST 原版模拟,右 App 模拟。
 */
import StPreview from './StPreview.vue'
import AppPreview from './AppPreview.vue'
import type { StatusField } from '@/shared/card'

defineProps<{
  originalHtml: string
  adaptedHtml: string
  mode?: 'panel' | 'fullscreen'
  title?: string
  sizeWidth?: number | string
  sizeHeight?: number | string
  schema?: StatusField[]
  characterName?: string
  firstMes?: string
  charAvatarUrl?: string
  userAvatarUrl?: string
}>()
</script>

<template>
  <div class="compare">
    <div class="compare-col">
      <div class="compare-head">原版 · SillyTavern 显示</div>
      <StPreview
        :html="originalHtml"
        :char-name="characterName"
        :first-mes="firstMes"
        :char-avatar-url="charAvatarUrl"
        :user-avatar-url="userAvatarUrl"
      />
    </div>
    <div class="compare-col">
      <div class="compare-head">适配后 · ArkTavern App 显示</div>
      <AppPreview
        :html="adaptedHtml"
        :mode="mode"
        :title="title"
        :size-width="sizeWidth"
        :size-height="sizeHeight"
        :schema="schema"
        :character-name="characterName"
      />
    </div>
  </div>
</template>

<style scoped>
.compare {
  display: flex;
  gap: 16px;
  align-items: flex-start;
}

.compare-col {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.compare-head {
  font-size: 13px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.85);
  padding: 6px 10px;
  background: #1d1e24;
  border: 1px solid #2a2a33;
  border-radius: 8px;
}
</style>
