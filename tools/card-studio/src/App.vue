<script setup lang="ts">
import { computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { NConfigProvider, NMessageProvider, NDialogProvider, darkTheme, zhCN, dateZhCN } from 'naive-ui'
import { useCardStore } from '@/stores/cardStore'

const route = useRoute()
const router = useRouter()
const cardStore = useCardStore()

const navs = [
  { key: 'home', label: '首页 · 导入' },
  { key: 'editor', label: '卡片编辑器' },
  { key: 'adapt', label: 'AI 适配' },
  { key: 'settings', label: '设置' }
]

const activeKey = computed((): string => (route.name as string) ?? 'home')
const cardLabel = computed((): string =>
  cardStore.card
    ? `${cardStore.cardName}${cardStore.card.modified ? ' *' : ''}`
    : '未加载角色卡'
)

function go(key: string): void {
  if ((key === 'editor' || key === 'adapt') && !cardStore.card) {
    window.alert('请先在首页导入或新建角色卡')
    return
  }
  router.push({ name: key })
}
</script>

<template>
  <n-config-provider :theme="darkTheme" :locale="zhCN" :date-locale="dateZhCN" style="height: 100%">
    <n-message-provider>
      <n-dialog-provider>
        <div class="app-shell">
          <header class="app-header">
            <div class="brand">🃏 ArkTavern Card Studio</div>
            <nav class="nav">
              <button
                v-for="nav in navs"
                :key="nav.key"
                class="nav-btn"
                :class="{ active: activeKey === nav.key }"
                @click="go(nav.key)"
              >
                {{ nav.label }}
              </button>
            </nav>
            <div class="card-chip" :title="cardLabel">{{ cardLabel }}</div>
          </header>
          <main class="app-main">
            <router-view />
          </main>
        </div>
      </n-dialog-provider>
    </n-message-provider>
  </n-config-provider>
</template>

<style scoped>
.app-shell {
  height: 100%;
  display: flex;
  flex-direction: column;
}

.app-header {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 0 16px;
  height: 48px;
  background: #17171c;
  border-bottom: 1px solid #26262e;
  flex-shrink: 0;
}

.brand {
  font-weight: 600;
  font-size: 14px;
  white-space: nowrap;
}

.nav {
  display: flex;
  gap: 4px;
  flex: 1;
}

.nav-btn {
  background: transparent;
  border: none;
  color: rgba(255, 255, 255, 0.6);
  font-size: 13px;
  padding: 6px 12px;
  border-radius: 8px;
  cursor: pointer;
}

.nav-btn:hover {
  background: rgba(255, 255, 255, 0.06);
  color: rgba(255, 255, 255, 0.9);
}

.nav-btn.active {
  background: rgba(99, 102, 241, 0.22);
  color: #a5b4fc;
}

.card-chip {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.55);
  max-width: 280px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.app-main {
  flex: 1;
  overflow: auto;
}
</style>
