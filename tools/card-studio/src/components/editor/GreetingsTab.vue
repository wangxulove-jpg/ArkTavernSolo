<script setup lang="ts">
/** 开场白:first_mes + alternate_greetings 列表(每条是完整元素,可含多段落) */
import { computed } from 'vue'
import { NInput, NButton, NEmpty } from 'naive-ui'
import { useCardStore } from '@/stores/cardStore'
import { CardData } from '@/shared/card'

const store = useCardStore()
const data = computed((): CardData => store.card!.raw.data)
const greetings = computed<string[]>((): string[] => (data.value.alternate_greetings as string[]) ?? [])

function sync(): void {
  store.markModified()
}

function updateGreeting(index: number, value: string): void {
  greetings.value[index] = value
  sync()
}

function addGreeting(): void {
  greetings.value.push('')
  sync()
}

function removeGreeting(index: number): void {
  greetings.value.splice(index, 1)
  sync()
}

function moveGreeting(index: number, delta: number): void {
  const target = index + delta
  if (target < 0 || target >= greetings.value.length) return
  const item = greetings.value[index]
  greetings.value[index] = greetings.value[target]
  greetings.value[target] = item
  sync()
}
</script>

<template>
  <div class="greetings">
    <div class="block">
      <div class="block-title">主开场白 first_mes</div>
      <n-input
        type="textarea"
        :autosize="{ minRows: 5, maxRows: 20 }"
        :value="String(data.first_mes ?? '')"
        @update:value="data.first_mes = $event; sync()"
      />
      <div class="block-meta">{{ String(data.first_mes ?? '').length }} 字符</div>
    </div>

    <div class="block">
      <div class="block-title">
        备用开场白 alternate_greetings({{ greetings.length }} 条,上限 60)
      </div>
      <n-empty v-if="greetings.length === 0" description="暂无备用开场白" size="small" style="margin: 8px 0" />
      <div v-for="(greeting, index) in greetings" :key="index" class="greeting-item">
        <div class="greeting-head">
          <span class="greeting-index">#{{ index + 1 }}</span>
          <span class="greeting-chars">{{ greeting.length }} 字符</span>
          <span class="greeting-actions">
            <n-button size="tiny" quaternary :disabled="index === 0" @click="moveGreeting(index, -1)">↑</n-button>
            <n-button size="tiny" quaternary :disabled="index === greetings.length - 1" @click="moveGreeting(index, 1)">↓</n-button>
            <n-button size="tiny" quaternary type="error" @click="removeGreeting(index)">删除</n-button>
          </span>
        </div>
        <n-input
          type="textarea"
          :autosize="{ minRows: 3, maxRows: 14 }"
          :value="greeting"
          @update:value="updateGreeting(index, $event)"
        />
      </div>
      <n-button size="small" dashed block @click="addGreeting">+ 添加备用开场白</n-button>
    </div>
  </div>
</template>

<style scoped>
.greetings {
  max-width: 860px;
  display: flex;
  flex-direction: column;
  gap: 18px;
}

.block-title {
  font-size: 13px;
  font-weight: 600;
  margin-bottom: 8px;
  color: rgba(255, 255, 255, 0.85);
}

.block-meta {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
  margin-top: 4px;
}

.greeting-item {
  margin-bottom: 10px;
}

.greeting-head {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 4px;
}

.greeting-index {
  font-size: 12px;
  color: #818cf8;
  font-weight: 600;
}

.greeting-chars {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
  flex: 1;
}
</style>
