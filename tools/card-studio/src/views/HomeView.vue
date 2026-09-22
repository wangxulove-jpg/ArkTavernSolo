<script setup lang="ts">
/**
 * 首页:导入角色卡(对话框/拖拽)、最近文件、新建空卡。
 */
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { NButton, NEmpty } from 'naive-ui'
import { useCardStore } from '@/stores/cardStore'

const router = useRouter()
const cardStore = useCardStore()
const dragOver = ref(false)

async function pickFile(): Promise<void> {
  const ok = await cardStore.openFromDialog()
  if (ok) router.push({ name: 'editor' })
}

async function onDrop(e: DragEvent): Promise<void> {
  dragOver.value = false
  const files = e.dataTransfer?.files
  if (!files || files.length === 0) return
  const filePath = window.api.getPathForFile(files[0])
  const ok = await cardStore.openFromPath(filePath)
  if (ok) router.push({ name: 'editor' })
}

function createNew(): void {
  cardStore.newCard()
  router.push({ name: 'editor' })
}

async function openRecent(path: string): Promise<void> {
  const ok = await cardStore.openFromPath(path)
  if (ok) router.push({ name: 'editor' })
}

function goAdapt(): void {
  router.push({ name: 'adapt' })
}
</script>

<template>
  <div class="home">
    <div
      class="drop-zone"
      :class="{ over: dragOver }"
      @dragover.prevent="dragOver = true"
      @dragleave="dragOver = false"
      @drop.prevent="onDrop"
    >
      <div class="drop-icon">🃏</div>
      <div class="drop-title">拖入 SillyTavern 角色卡(PNG / JSON)</div>
      <div class="drop-sub">PC 端保留全部原始数据(酒馆助手脚本 / regex 脚本 / 世界书),供 AI 适配使用</div>
      <div class="drop-actions">
        <n-button type="primary" size="large" :loading="cardStore.loading" @click="pickFile">
          选择角色卡文件
        </n-button>
        <n-button size="large" quaternary @click="createNew">新建空白卡</n-button>
      </div>
    </div>

    <div class="recent">
      <h3>最近打开</h3>
      <n-empty v-if="cardStore.recent.length === 0" description="暂无记录" size="small" />
      <ul v-else class="recent-list">
        <li v-for="item in cardStore.recent" :key="item.filePath">
          <button class="recent-item" @click="openRecent(item.filePath)">
            <span class="recent-name">{{ item.fileName }}</span>
            <span class="recent-path">{{ item.filePath }}</span>
          </button>
        </li>
      </ul>
    </div>

    <div class="workflow">
      <h3>推荐工作流</h3>
      <ol class="workflow-steps">
        <li><b>导入 ST 卡</b> — 支持含酒馆助手前端(楼层 HTML 代码块)的重前端卡</li>
        <li><b>AI 适配</b>(<a class="link" @click="goAdapt">前往</a>) — 分析前端资产 → AI 规划 → 生成适配界面 → 左右预览对比 → 写入 arktavern 扩展</li>
        <li><b>编辑器微调</b> — 状态字段 / 界面 HTML / 世界书 / 全字段编辑</li>
        <li><b>导出 PNG</b> — 手机 App 导入,聊天页出现「界面」入口</li>
      </ol>
    </div>
  </div>
</template>

<style scoped>
.home {
  max-width: 860px;
  margin: 0 auto;
  padding: 28px 20px;
  display: flex;
  flex-direction: column;
  gap: 22px;
}

.drop-zone {
  border: 2px dashed #3a3a46;
  border-radius: 14px;
  padding: 44px 20px;
  text-align: center;
  background: #15151a;
  transition: border-color 0.2s, background 0.2s;
}

.drop-zone.over {
  border-color: #6366f1;
  background: rgba(99, 102, 241, 0.08);
}

.drop-icon {
  font-size: 40px;
}

.drop-title {
  font-size: 16px;
  font-weight: 600;
  margin-top: 10px;
}

.drop-sub {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.45);
  margin-top: 6px;
}

.drop-actions {
  margin-top: 18px;
  display: flex;
  justify-content: center;
  gap: 12px;
}

.recent h3,
.workflow h3 {
  font-size: 14px;
  margin: 0 0 10px;
  color: rgba(255, 255, 255, 0.8);
}

.recent-list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.recent-item {
  width: 100%;
  text-align: left;
  background: #17171c;
  border: 1px solid #26262e;
  border-radius: 8px;
  padding: 10px 12px;
  cursor: pointer;
  color: inherit;
  display: flex;
  justify-content: space-between;
  gap: 12px;
  align-items: center;
}

.recent-item:hover {
  border-color: #6366f1;
}

.recent-name {
  font-size: 13px;
  white-space: nowrap;
}

.recent-path {
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.workflow-steps {
  margin: 0;
  padding-left: 20px;
  font-size: 13px;
  line-height: 2;
  color: rgba(255, 255, 255, 0.65);
}

.link {
  color: #818cf8;
  cursor: pointer;
  text-decoration: underline;
}
</style>
