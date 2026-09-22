<script setup lang="ts">
/** 提示词:system_prompt / post_history_instructions / creator_notes / mes_example */
import { computed } from 'vue'
import { NForm, NFormItem, NInput } from 'naive-ui'
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
    <n-form-item label="System Prompt(帮助模型稳定扮演角色)">
      <n-input
        type="textarea"
        :autosize="{ minRows: 4, maxRows: 16 }"
        :value="String(data.system_prompt ?? '')"
        @update:value="data.system_prompt = $event; sync()"
      />
    </n-form-item>
    <n-form-item label="Post-History Instructions(置于历史之后,常用于收尾约束)">
      <n-input
        type="textarea"
        :autosize="{ minRows: 3, maxRows: 12 }"
        :value="String(data.post_history_instructions ?? '')"
        @update:value="data.post_history_instructions = $event; sync()"
      />
    </n-form-item>
    <n-form-item label="对话示例 mes_example(用 <START> 分隔)">
      <n-input
        type="textarea"
        :autosize="{ minRows: 4, maxRows: 16 }"
        :value="String(data.mes_example ?? '')"
        @update:value="data.mes_example = $event; sync()"
      />
    </n-form-item>
    <n-form-item label="创作者备注 creator_notes">
      <n-input
        type="textarea"
        :autosize="{ minRows: 2, maxRows: 8 }"
        :value="String(data.creator_notes ?? '')"
        @update:value="data.creator_notes = $event; sync()"
      />
    </n-form-item>
  </n-form>
</template>

<style scoped>
.tab-form {
  max-width: 860px;
}
</style>
