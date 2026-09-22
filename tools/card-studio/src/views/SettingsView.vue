<script setup lang="ts">
/**
 * 设置页:OpenAI 兼容 API 配置与连接测试。
 */
import { ref, onMounted } from 'vue'
import { NForm, NFormItem, NInput, NSelect, NButton, NSlider, NTag, useMessage } from 'naive-ui'
import { useSettingsStore } from '@/stores/settingsStore'

const store = useSettingsStore()
const message = useMessage()
const testing = ref(false)
const testResult = ref<{ ok: boolean; models?: string[]; error?: string } | null>(null)
const modelOptions = ref<{ label: string; value: string }[]>([])

onMounted((): void => {
  void store.load()
})

const baseUrlOptions = [
  { label: 'DeepSeek (api.deepseek.com/v1)', value: 'https://api.deepseek.com/v1' },
  { label: 'Gemini OpenAI 兼容端点', value: 'https://generativelanguage.googleapis.com/v1beta/openai' },
  { label: 'OpenAI 官方', value: 'https://api.openai.com/v1' },
  { label: '本地/自建网关 (localhost)', value: 'http://127.0.0.1:3000/v1' }
]

async function save(): Promise<void> {
  await store.save()
  message.success('已保存')
}

async function test(): Promise<void> {
  testing.value = true
  testResult.value = null
  try {
    await store.save()
    const result = await store.test()
    testResult.value = result
    if (result.ok) {
      modelOptions.value = (result.models ?? []).map((m: string): { label: string; value: string } => ({
        label: m,
        value: m
      }))
      message.success(`连接成功,发现 ${result.models?.length ?? 0} 个模型`)
    } else {
      message.error(`连接失败: ${result.error ?? '未知错误'}`)
    }
  } finally {
    testing.value = false
  }
}
</script>

<template>
  <div class="settings">
    <n-form label-placement="top" style="max-width: 560px">
      <n-form-item label="Base URL(OpenAI 兼容)">
        <n-select
          v-model:value="store.ai.baseUrl"
          filterable
          tag
          :options="baseUrlOptions"
          placeholder="选择或输入自定义 Base URL"
        />
      </n-form-item>
      <n-form-item label="API Key">
        <n-input v-model:value="store.ai.apiKey" type="password" show-password-on="click" placeholder="sk-..." />
      </n-form-item>
      <n-form-item label="模型">
        <n-select
          v-model:value="store.ai.model"
          filterable
          tag
          :options="modelOptions"
          placeholder="输入模型名,或先测试连接后从列表选择"
        />
      </n-form-item>
      <n-form-item label="温度">
        <n-slider v-model:value="store.ai.temperature" :min="0" :max="2" :step="0.1" />
      </n-form-item>
      <div class="actions">
        <n-button type="primary" @click="save">保存</n-button>
        <n-button :loading="testing" @click="test">测试连接</n-button>
      </div>
      <div v-if="testResult" class="test-result">
        <n-tag v-if="testResult.ok" type="success">连接成功 · {{ testResult.models?.length ?? 0 }} 个模型</n-tag>
        <n-tag v-else type="error">{{ testResult.error }}</n-tag>
      </div>
      <p class="hint">
        仅支持 OpenAI 兼容协议(/v1/chat/completions + /v1/models)。Gemini 请使用其 OpenAI 兼容端点。
        建议适配规划/生成使用长上下文、强代码能力的模型。
      </p>
    </n-form>
  </div>
</template>

<style scoped>
.settings {
  padding: 24px 20px;
}

.actions {
  display: flex;
  gap: 10px;
}

.test-result {
  margin-top: 12px;
}

.hint {
  margin-top: 16px;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.4);
  line-height: 1.7;
}
</style>
