<script setup lang="ts">
/**
 * StPreview:模拟原版前端在 SillyTavern(酒馆助手渲染器)中的显示。
 * 楼层样式 + TavernHelper API mock(jQuery/变量/楼层/头像 CSS)。
 */
import { ref, computed, watch } from 'vue'
import { buildStMockScript, injectScript } from './mockScripts'

const props = withDefaults(
  defineProps<{
    html: string
    charName?: string
    firstMes?: string
    userName?: string
    charAvatarUrl?: string
    userAvatarUrl?: string
  }>(),
  { charName: '角色', firstMes: '', userName: 'User', charAvatarUrl: '', userAvatarUrl: '' }
)

const previewKey = ref(0)

const srcdoc = computed((): string => {
  if (!props.html) return '<html><body style="color:#888;font-family:sans-serif">未选择 HTML 资产</body></html>'
  return injectScript(
    props.html,
    buildStMockScript({
      charName: props.charName,
      firstMes: props.firstMes,
      userName: props.userName,
      charAvatarUrl: props.charAvatarUrl,
      userAvatarUrl: props.userAvatarUrl
    })
  )
})

watch(
  () => props.html,
  (): void => {
    previewKey.value++
  }
)
</script>

<template>
  <div class="st-preview">
    <div class="st-floor">
      <div class="floor-header">
        <div class="avatar" :style="charAvatarUrl ? { backgroundImage: `url(${charAvatarUrl})` } : {}">
          <span v-if="!charAvatarUrl">{{ charName.slice(0, 1) }}</span>
        </div>
        <div class="floor-meta">
          <span class="floor-name">{{ charName }}</span>
          <span class="floor-time">SillyTavern 楼层 · 酒馆助手渲染</span>
        </div>
      </div>
      <iframe
        :key="previewKey"
        class="st-iframe"
        :srcdoc="srcdoc"
        sandbox="allow-scripts allow-same-origin"
      />
    </div>
    <p class="st-note">注:此为本地模拟(注入 TavernHelper mock API),与真实酒馆环境可能有细微差异。</p>
  </div>
</template>

<style scoped>
.st-preview {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
}

.st-floor {
  border: 1px solid #2c2c35;
  border-radius: 10px;
  background: #191a1f;
  overflow: hidden;
  width: 100%;
}

.floor-header {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 12px;
  background: #202126;
}

.avatar {
  width: 34px;
  height: 34px;
  border-radius: 50%;
  background: #3a3a46;
  background-size: cover;
  background-position: center;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  color: rgba(255, 255, 255, 0.8);
  flex-shrink: 0;
}

.floor-meta {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.floor-name {
  font-size: 13px;
  font-weight: 600;
  color: rgba(255, 255, 255, 0.9);
}

.floor-time {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.4);
}

.st-iframe {
  border: none;
  width: 100%;
  height: 560px;
  background: #fff;
  display: block;
}

.st-note {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.4);
  margin: 0;
}
</style>
