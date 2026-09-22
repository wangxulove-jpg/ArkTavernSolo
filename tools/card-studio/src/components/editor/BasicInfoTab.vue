<script setup lang="ts">
/** 基本信息:name/nickname/creator/version/tags/description/personality/scenario */
import { computed } from 'vue'
import { NForm, NFormItem, NInput, NDynamicTags } from 'naive-ui'
import { useCardStore } from '@/stores/cardStore'
import { CardData } from '@/shared/card'

const store = useCardStore()
const data = computed((): CardData => store.card!.raw.data)

function sync(): void {
  store.markModified()
}
</script>

<template>
  <n-form label-placement="top" class="tab-form">
    <div class="row2">
      <n-form-item label="名称 name">
        <n-input :value="String(data.name ?? '')" @update:value="data.name = $event; sync()" />
      </n-form-item>
      <n-form-item label="昵称 nickname">
        <n-input :value="String(data.nickname ?? '')" @update:value="data.nickname = $event; sync()" />
      </n-form-item>
    </div>
    <n-form-item label="描述 description">
      <n-input
        type="textarea"
        :autosize="{ minRows: 5, maxRows: 16 }"
        :value="String(data.description ?? '')"
        @update:value="data.description = $event; sync()"
      />
    </n-form-item>
    <n-form-item label="性格 personality">
      <n-input
        type="textarea"
        :autosize="{ minRows: 3, maxRows: 10 }"
        :value="String(data.personality ?? '')"
        @update:value="data.personality = $event; sync()"
      />
    </n-form-item>
    <n-form-item label="场景 scenario">
      <n-input
        type="textarea"
        :autosize="{ minRows: 3, maxRows: 10 }"
        :value="String(data.scenario ?? '')"
        @update:value="data.scenario = $event; sync()"
      />
    </n-form-item>
    <div class="row2">
      <n-form-item label="创作者 creator">
        <n-input :value="String(data.creator ?? '')" @update:value="data.creator = $event; sync()" />
      </n-form-item>
      <n-form-item label="卡版本 character_version">
        <n-input
          :value="String(data.character_version ?? '')"
          @update:value="data.character_version = $event; sync()"
        />
      </n-form-item>
    </div>
    <n-form-item label="标签 tags">
      <n-dynamic-tags :value="(data.tags as string[]) ?? []" @update:value="data.tags = $event; sync()" />
    </n-form-item>
  </n-form>
</template>

<style scoped>
.tab-form {
  max-width: 860px;
}

.row2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0 16px;
}
</style>
