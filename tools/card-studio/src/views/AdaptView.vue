<script setup lang="ts">
/**
 * AI 适配向导(5 步):资产分析 → AI 规划 → AI 生成 → 双预览对比 → 应用导出。
 * 目标:把 SillyTavern 重前端卡改造成适配 ArkTavern App 的
 * extensions.arktavern.frontend + status.fields,尽量复原原版前端观感。
 */
import { computed, onBeforeUnmount, reactive, ref } from 'vue'
import { useRouter } from 'vue-router'
import {
  NButton,
  NCard,
  NCheckbox,
  NCheckboxGroup,
  NEmpty,
  NInput,
  NInputNumber,
  NRadio,
  NRadioGroup,
  NSelect,
  NSpace,
  NStep,
  NSteps,
  NSwitch,
  NTag,
  useMessage
} from 'naive-ui'
import { useCardStore } from '@/stores/cardStore'
import { useSettingsStore } from '@/stores/settingsStore'
import { scanAssets, AssetScanResult } from '@/shared/assets'
import { str, CardData, StatusField, FrontendSpec } from '@/shared/card'
import {
  AdaptPlan,
  buildPlanSystemPrompt,
  buildPlanUserPrompt,
  buildGenerateSystemPrompt,
  buildGenerateUserPrompt,
  extractJson,
  extractHtml
} from '@/prompts/adapt'
import PreviewCompare from '@/components/preview/PreviewCompare.vue'

const router = useRouter()
const cardStore = useCardStore()
const settings = useSettingsStore()
const message = useMessage()

const card = computed((): NonNullable<typeof cardStore.card> => cardStore.card!)
const data = computed((): CardData => card.value.raw.data)

// ===== 步骤状态 =====
const step = ref(1)

// Step 1: 资产分析
const scan = ref<AssetScanResult | null>(null)
const selectedHtmlId = ref<string | null>(null)
const selectedScriptIds = ref<string[]>([])
const userRequirement = ref('')

const selectedAsset = computed(() =>
  scan.value?.htmlAssets.find((a) => a.id === selectedHtmlId.value) ?? null
)

// Step 2: AI 规划
const planning = ref(false)
const planStream = ref('')
const plan = ref<AdaptPlan | null>(null)
const planError = ref('')

// Step 3: AI 生成
const generating = ref(false)
const genStream = ref('')
const adaptedHtml = ref('')
const genError = ref('')
const feedback = ref('')

// Step 5: 应用导出
const cleanup = reactive({ regexScripts: true, tavernHelperScripts: true })
const applied = ref(false)

// ===== 初始化 =====
function initScan(): void {
  scan.value = scanAssets(card.value.raw)
  const firstFull = scan.value.htmlAssets.find((a) => a.isFullPage)
  selectedHtmlId.value = firstFull?.id ?? scan.value.htmlAssets[0]?.id ?? null
}

initScan()
void settings.load()

// ===== AI 调用(流式累积) =====
let abortHandle: { abort: () => void } | null = null

function runAi(
  system: string,
  user: string,
  onDelta: (full: string) => void
): Promise<string> {
  return new Promise((resolve, reject) => {
    let acc = ''
    abortHandle = window.api.aiChat(
      {
        baseUrl: settings.ai.baseUrl,
        apiKey: settings.ai.apiKey,
        model: settings.ai.model,
        temperature: settings.ai.temperature,
        system,
        user
      },
      (ev) => {
        if (ev.type === 'delta' && ev.text) {
          acc += ev.text
          onDelta(acc)
        } else if (ev.type === 'done') {
          abortHandle = null
          resolve(acc)
        } else if (ev.type === 'error') {
          abortHandle = null
          reject(new Error(ev.error ?? '未知错误'))
        }
      }
    )
  })
}

onBeforeUnmount(() => {
  abortHandle?.abort()
})

function ensureAiReady(): boolean {
  if (!settings.ai.configured) {
    message.warning('请先在「设置」页配置 AI 服务(Base URL / API Key / 模型)')
    router.push({ name: 'settings' })
    return false
  }
  return true
}

// ===== Step 1 → 2 =====
function goToPlan(): void {
  if (!ensureAiReady()) return
  step.value = 2
}

// ===== Step 2: AI 规划 =====
function buildCardSummary(): string {
  const d = data.value
  const book = d.character_book as { entries?: unknown[] } | undefined
  const lines = [
    `名称: ${str(d, 'name')}`,
    `创作者: ${str(d, 'creator')}`,
    `描述(节选): ${clip(str(d, 'description'), 600)}`,
    `性格(节选): ${clip(str(d, 'personality'), 200)}`,
    `场景(节选): ${clip(str(d, 'scenario'), 200)}`,
    `开场白(节选): ${clip(str(d, 'first_mes'), 300)}`,
    book && Array.isArray(book.entries) ? `世界书: ${book.entries.length} 条` : ''
  ]
  return lines.filter(Boolean).join('\n')
}

function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}…` : text
}

function buildScriptSummaries(): string {
  if (!scan.value) return ''
  return scan.value.scripts
    .filter((s) => selectedScriptIds.value.includes(s.id))
    .map((s) => `### ${s.name}\n${clip(s.content, 800)}`)
    .join('\n\n')
}

function buildRegexSummaries(): string {
  if (!scan.value || scan.value.regexes.length === 0) return ''
  const head = scan.value.regexes
    .slice(0, 10)
    .map((r) => `- ${r.name}: ${clip(r.findRegex, 80)}`)
    .join('\n')
  const more =
    scan.value.regexes.length > 10 ? `\n…共 ${scan.value.regexes.length} 条` : ''
  return `${head}${more}`
}

async function startPlanning(): Promise<void> {
  if (!ensureAiReady()) return
  planning.value = true
  planError.value = ''
  planStream.value = ''
  plan.value = null
  try {
    const out = await runAi(
      buildPlanSystemPrompt(),
      buildPlanUserPrompt({
        cardSummary: buildCardSummary(),
        mainHtml: selectedAsset.value?.content ?? '(本卡无前端 HTML 资产,请按用户要求从零设计)',
        scriptSummaries: buildScriptSummaries(),
        regexSummaries: buildRegexSummaries(),
        userRequirement: userRequirement.value
      }),
      (full) => {
        planStream.value = full
      }
    )
    const parsed = extractJson<AdaptPlan>(out)
    if (!parsed || !parsed.frontend || !Array.isArray(parsed.statusFields)) {
      planError.value = 'AI 输出无法解析为规划 JSON,请重试(可在下方查看原始输出)。'
      return
    }
    plan.value = reactive(parsed)
  } catch (e) {
    planError.value = (e as Error).message
  } finally {
    planning.value = false
  }
}

function addPlanField(): void {
  plan.value?.statusFields.push({ name: '', desc: '', type: 'string', locked: false })
}

function removePlanField(index: number): void {
  plan.value?.statusFields.splice(index, 1)
}

function confirmPlan(): void {
  if (!plan.value) return
  const fields = plan.value.statusFields.filter((f) => f.name.trim() !== '')
  if (plan.value.frontend.enabled && fields.length === 0) {
    message.warning('请至少保留一个状态字段(前端界面的数据源)')
    return
  }
  plan.value.statusFields = fields
  step.value = plan.value.frontend.enabled ? 3 : 5
}

// ===== Step 3: AI 生成 =====
async function startGenerate(): Promise<void> {
  if (!plan.value || !ensureAiReady()) return
  generating.value = true
  genError.value = ''
  genStream.value = ''
  try {
    const out = await runAi(
      buildGenerateSystemPrompt(),
      buildGenerateUserPrompt({
        originalHtml: selectedAsset.value?.content ?? '',
        plan: plan.value,
        feedback: feedback.value
      }),
      (full) => {
        genStream.value = full
      }
    )
    const html = extractHtml(out)
    if (!/<html|<body/i.test(html)) {
      genError.value = 'AI 未输出有效 HTML(输出可能被截断)。建议分块生成:先让 AI 输出 CSS 骨架,再补 JS 逻辑。'
      return
    }
    adaptedHtml.value = html
    message.success(`生成完成: ${(html.length / 1024).toFixed(1)} KB`)
  } catch (e) {
    genError.value = (e as Error).message
  } finally {
    generating.value = false
  }
}

const htmlTooLarge = computed((): boolean => adaptedHtml.value.length > 512 * 1024)

// ===== Step 4 → 5 =====
const originalHtmlForPreview = computed((): string =>
  selectedAsset.value?.content ??
  '<html><body style="font-family:sans-serif;color:#888;padding:16px">本卡无原版前端 HTML(AI 按需求自由生成)</body></html>'
)

const frontendSpecForPreview = computed((): FrontendSpec => ({
  html: adaptedHtml.value,
  mode: plan.value?.frontend.mode ?? 'panel',
  title: plan.value?.frontend.title ?? '界面',
  size: {
    width: plan.value?.frontend.sizeWidth,
    height: plan.value?.frontend.sizeHeight
  }
}))

// ===== Step 5: 应用与导出 =====
function applyToCard(): void {
  if (!plan.value) return
  const p = plan.value
  const frontend: FrontendSpec | null = p.frontend.enabled
    ? {
        html: adaptedHtml.value,
        mode: p.frontend.mode,
        title: p.frontend.title,
        size: { width: p.frontend.sizeWidth, height: p.frontend.sizeHeight }
      }
    : null
  cardStore.applyAdaptation(p.statusFields, frontend, {
    regexScripts: cleanup.regexScripts,
    tavernHelperScripts: cleanup.tavernHelperScripts
  })
  applied.value = true
  message.success('已写入角色卡,记得导出保存')
}

async function exportPng(): Promise<void> {
  const path = await cardStore.savePng()
  if (path) message.success(`已导出 PNG: ${path}`)
}

async function exportJson(): Promise<void> {
  const path = await cardStore.saveJson()
  if (path) message.success(`已导出 JSON: ${path}`)
}
</script>

<template>
  <div class="adapt">
    <n-steps :current="step" size="small" class="adapt-steps">
      <n-step title="资产分析" />
      <n-step title="AI 规划" />
      <n-step title="AI 生成" />
      <n-step title="双预览对比" />
      <n-step title="应用导出" />
    </n-steps>

    <!-- Step 1: 资产分析 -->
    <div v-if="step === 1" class="step-body">
      <n-card title="① 前端资产(选择主界面 HTML)" size="small">
        <template #header-extra>
          <n-tag v-if="scan && scan.htmlAssets.length === 0" size="small" type="warning" :bordered="false">
            未发现 HTML 代码块 · 将自由生成
          </n-tag>
        </template>
        <n-empty
          v-if="scan && scan.htmlAssets.length === 0"
          description="开场白/备用开场白/世界书中未发现围栏代码块 HTML,可继续让 AI 按你的要求从零设计界面"
          size="small"
        />
        <n-radio-group v-else v-model:value="selectedHtmlId" class="asset-list">
          <div v-for="asset in scan?.htmlAssets" :key="asset.id" class="asset-item">
            <n-radio :value="asset.id">
              <span class="asset-name">{{ asset.source }}</span>
              <n-tag size="tiny" :bordered="false" :type="asset.isFullPage ? 'success' : 'default'">
                {{ asset.isFullPage ? '完整页面' : 'HTML 片段' }}
              </n-tag>
              <n-tag size="tiny" :bordered="false">{{ (asset.chars / 1024).toFixed(1) }} KB</n-tag>
            </n-radio>
            <pre class="asset-preview">{{ asset.content.slice(0, 160) }}…</pre>
          </div>
        </n-radio-group>
      </n-card>

      <n-card title="② 酒馆助手角色脚本(选作 AI 参考,展示交互意图)" size="small">
        <n-empty
          v-if="scan && scan.scripts.length === 0"
          description="本卡无 TavernHelper_scripts"
          size="small"
        />
        <n-checkbox-group v-else v-model:value="selectedScriptIds">
          <n-space vertical>
            <n-checkbox v-for="s in scan?.scripts" :key="s.id" :value="s.id">
              {{ s.name }}
              <n-tag size="tiny" :bordered="false">{{ (s.content.length / 1024).toFixed(1) }} KB</n-tag>
            </n-checkbox>
          </n-space>
        </n-checkbox-group>
      </n-card>

      <n-card title="③ regex 美化脚本(自动附摘要供 AI 参考)" size="small">
        <span v-if="scan && scan.regexes.length === 0" class="muted">本卡无 regex_scripts</span>
        <span v-else class="muted">共 {{ scan?.regexes.length }} 条,摘要将随规划请求发送</span>
      </n-card>

      <n-card title="④ 适配要求(可选,指导 AI 规划)" size="small">
        <n-input
          v-model:value="userRequirement"
          type="textarea"
          :autosize="{ minRows: 3, maxRows: 8 }"
          placeholder="例如:保留原来的深色血条与背包格子;状态栏放界面顶部;不要改成列表样式…(留空则以复原原版为目标)"
        />
      </n-card>

      <div class="step-actions">
        <n-button type="primary" size="large" @click="goToPlan">下一步 · AI 规划</n-button>
      </div>
    </div>

    <!-- Step 2: AI 规划 -->
    <div v-else-if="step === 2" class="step-body">
      <n-card size="small" title="AI 生成适配规划">
        <n-space>
          <n-button type="primary" :loading="planning" @click="startPlanning">
            {{ plan ? '重新规划' : '开始规划' }}
          </n-button>
          <n-button v-if="plan" type="success" size="large" @click="confirmPlan">
            确认规划,进入{{ plan.frontend.enabled ? '生成' : '应用' }}
          </n-button>
        </n-space>
        <pre v-if="planStream && !plan" class="stream-pre">{{ planStream }}</pre>
        <div v-if="planError" class="error-text">{{ planError }}</div>
        <pre v-if="planError && planStream" class="stream-pre">{{ planStream }}</pre>
      </n-card>

      <template v-if="plan">
        <n-card title="前端界面配置" size="small">
          <div class="form-grid">
            <div class="form-item">
              <span class="form-label">启用前端界面</span>
              <n-switch v-model:value="plan.frontend.enabled" />
            </div>
            <div class="form-item">
              <span class="form-label">模式 mode</span>
              <n-select
                v-model:value="plan.frontend.mode"
                :options="[
                  { label: 'panel(聊天页浮层)', value: 'panel' },
                  { label: 'fullscreen(全屏页)', value: 'fullscreen' }
                ]"
                style="width: 200px"
              />
            </div>
            <div class="form-item">
              <span class="form-label">标题 title</span>
              <n-input v-model:value="plan.frontend.title" style="width: 240px" />
            </div>
            <div class="form-item">
              <span class="form-label">宽 width(px)</span>
              <n-input-number v-model:value="plan.frontend.sizeWidth" :min="280" :max="500" />
            </div>
            <div class="form-item">
              <span class="form-label">高 height</span>
              <n-input v-model:value="plan.frontend.sizeHeight" style="width: 120px" placeholder="65%" />
            </div>
          </div>
        </n-card>

        <n-card title="角色状态字段(status.fields,界面数据源)" size="small">
          <div class="field-table">
            <div class="field-row field-head">
              <span>字段名</span><span>含义 desc</span><span>类型</span><span>锁定</span><span></span>
            </div>
            <div v-for="(f, i) in plan.statusFields" :key="i" class="field-row">
              <n-input v-model:value="f.name" size="small" placeholder="字段名" />
              <n-input v-model:value="f.desc" size="small" placeholder="取值含义" />
              <n-select
                v-model:value="f.type"
                size="small"
                style="width: 110px"
                :options="[
                  { label: 'number', value: 'number' },
                  { label: 'string', value: 'string' }
                ]"
              />
              <n-switch v-model:value="f.locked" size="small" />
              <n-button size="tiny" quaternary type="error" @click="removePlanField(i)">删</n-button>
            </div>
          </div>
          <n-button size="small" dashed block @click="addPlanField">+ 添加字段</n-button>
        </n-card>

        <n-card v-if="plan.apiMappings.length" title="API 映射(只读参考)" size="small">
          <div v-for="(m, i) in plan.apiMappings" :key="i" class="mapping-row">
            <code>{{ m.original }}</code>
            <span class="mapping-arrow">→</span>
            <code>{{ m.replacement }}</code>
            <span v-if="m.note" class="muted">({{ m.note }})</span>
          </div>
        </n-card>

        <n-card v-if="plan.risks.length" title="风险与降级提示" size="small">
          <ul class="plain-list">
            <li v-for="(r, i) in plan.risks" :key="i">{{ r }}</li>
          </ul>
        </n-card>

        <n-card v-if="plan.updateMechanism" title="更新机制说明" size="small">
          <p class="mechanism">{{ plan.updateMechanism }}</p>
        </n-card>
      </template>
    </div>

    <!-- Step 3: AI 生成 -->
    <div v-else-if="step === 3" class="step-body">
      <n-card size="small" title="AI 改造前端 HTML">
        <n-space>
          <n-button type="primary" :loading="generating" @click="startGenerate">
            {{ adaptedHtml ? '重新生成' : '开始生成' }}
          </n-button>
          <n-button v-if="adaptedHtml && !generating" @click="step = 4">下一步 · 预览对比</n-button>
        </n-space>
        <div v-if="generating" class="gen-progress">
          已生成 {{ (genStream.length / 1024).toFixed(1) }} KB…
          <pre class="stream-pre">{{ genStream.slice(-800) }}</pre>
        </div>
        <div v-if="genError" class="error-text">{{ genError }}</div>
        <div v-if="adaptedHtml && !generating" class="gen-done">
          <n-tag :type="htmlTooLarge ? 'error' : 'success'" :bordered="false">
            {{ (adaptedHtml.length / 1024).toFixed(1) }} KB{{ htmlTooLarge ? ' · 超出 App 512KB 上限,请精简' : '' }}
          </n-tag>
        </div>
      </n-card>

      <n-card title="修改意见(附在下一次重新生成时)" size="small">
        <n-input
          v-model:value="feedback"
          type="textarea"
          :autosize="{ minRows: 2, maxRows: 5 }"
          placeholder="例如:血条改成红色渐变;按钮太小说到 48px;去掉顶部的返回按钮…"
        />
      </n-card>

      <n-button quaternary @click="step = 2">← 返回规划</n-button>
    </div>

    <!-- Step 4: 双预览对比 -->
    <div v-else-if="step === 4" class="step-body">
      <PreviewCompare
        :original-html="originalHtmlForPreview"
        :adapted-html="adaptedHtml"
        :mode="frontendSpecForPreview.mode"
        :title="frontendSpecForPreview.title"
        :size-width="frontendSpecForPreview.size?.width"
        :size-height="frontendSpecForPreview.size?.height"
        :schema="plan?.statusFields ?? []"
        :character-name="str(data, 'name')"
        :first-mes="str(data, 'first_mes')"
      />
      <div class="step-actions">
        <n-button quaternary @click="step = 3">← 不满意,返回修改重生成</n-button>
        <n-button type="primary" size="large" @click="step = 5">满意 · 应用并导出</n-button>
      </div>
    </div>

    <!-- Step 5: 应用与导出 -->
    <div v-else class="step-body">
      <n-card title="写入角色卡" size="small">
        <div class="apply-summary">
          <p>
            将写入 <code>extensions.arktavern</code>:
            <b>{{ plan?.statusFields.length ?? 0 }}</b> 个状态字段
            <template v-if="plan?.frontend.enabled">
              + 前端界面({{ plan.frontend.mode }} 模式,
              {{ (adaptedHtml.length / 1024).toFixed(1) }} KB)
            </template>
          </p>
        </div>
        <div class="form-item">
          <n-checkbox v-model:checked="cleanup.regexScripts">
            移除 regex_scripts(默认:App 导入会丢弃,且防止超出 RDB 2MB 限制)
          </n-checkbox>
        </div>
        <div class="form-item">
          <n-checkbox v-model:checked="cleanup.tavernHelperScripts">
            移除 TavernHelper_scripts(默认:App 不支持酒馆助手脚本)
          </n-checkbox>
        </div>
        <n-space>
          <n-button type="primary" :disabled="applied" @click="applyToCard">
            {{ applied ? '已写入 ✓' : '写入角色卡' }}
          </n-button>
        </n-space>
      </n-card>

      <n-card title="导出并导入手机 App" size="small">
        <ol class="plain-list">
          <li>点击「导出 PNG」,保存为角色卡图片</li>
          <li>把 PNG 传到手机,在 ArkTavern App 中导入该角色卡</li>
          <li>进入聊天页:出现「界面」入口(panel 浮层)与「状态」入口</li>
          <li>与角色对话,AI 回复末尾的状态块会自动驱动前端界面刷新</li>
        </ol>
        <n-space>
          <n-button type="primary" :disabled="!applied" @click="exportPng">导出 PNG</n-button>
          <n-button :disabled="!applied" @click="exportJson">导出 JSON</n-button>
          <n-button @click="router.push({ name: 'editor' })">去编辑器检查</n-button>
        </n-space>
      </n-card>
    </div>
  </div>
</template>

<style scoped>
.adapt {
  max-width: 1100px;
  margin: 0 auto;
  padding: 16px 20px 32px;
  display: flex;
  flex-direction: column;
  gap: 16px;
}

.adapt-steps {
  flex-shrink: 0;
}

.step-body {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.asset-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  width: 100%;
}

.asset-item {
  border: 1px solid #26262e;
  border-radius: 8px;
  padding: 8px 10px;
}

.asset-name {
  margin-right: 8px;
  font-weight: 600;
}

.asset-preview {
  margin: 6px 0 0 24px;
  font-size: 11px;
  color: rgba(255, 255, 255, 0.35);
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 56px;
  overflow: hidden;
}

.stream-pre {
  margin-top: 10px;
  background: #131318;
  border: 1px solid #26262e;
  border-radius: 8px;
  padding: 10px;
  font-size: 11px;
  line-height: 1.5;
  max-height: 260px;
  overflow: auto;
  white-space: pre-wrap;
  word-break: break-all;
}

.error-text {
  margin-top: 8px;
  color: #f87171;
  font-size: 13px;
}

.gen-progress {
  margin-top: 10px;
  font-size: 12px;
  color: rgba(255, 255, 255, 0.6);
}

.gen-done {
  margin-top: 10px;
}

.form-grid {
  display: flex;
  flex-wrap: wrap;
  gap: 12px 24px;
}

.form-item {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 4px 0;
}

.form-label {
  font-size: 13px;
  color: rgba(255, 255, 255, 0.7);
  white-space: nowrap;
}

.field-table {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 10px;
}

.field-row {
  display: grid;
  grid-template-columns: 160px 1fr 120px 60px 44px;
  gap: 8px;
  align-items: center;
}

.field-head {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.45);
}

.mapping-row {
  font-size: 13px;
  padding: 2px 0;
}

.mapping-row code {
  background: #131318;
  padding: 1px 6px;
  border-radius: 4px;
  font-size: 12px;
}

.mapping-arrow {
  color: #818cf8;
  margin: 0 6px;
}

.plain-list {
  margin: 0;
  padding-left: 20px;
  font-size: 13px;
  line-height: 1.9;
  color: rgba(255, 255, 255, 0.75);
}

.mechism,
.mechanism {
  margin: 0;
  font-size: 13px;
  color: rgba(255, 255, 255, 0.75);
  line-height: 1.7;
}

.muted {
  font-size: 12px;
  color: rgba(255, 255, 255, 0.45);
}

.apply-summary p {
  margin: 0 0 10px;
  font-size: 14px;
}

.apply-summary code {
  background: #131318;
  padding: 1px 6px;
  border-radius: 4px;
}

.step-actions {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
}
</style>
