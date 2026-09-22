/**
 * 卡片数据模型:V1/V2/V3/ArkTavern 导出格式归一化为统一工作模型,
 * 编辑直接改 raw.data(保留未知字段,导出无损)。
 */

export type SourceSpec = 'v1' | 'v2' | 'v3' | 'arktavern'

export interface CardData {
  [key: string]: unknown
}

export interface CharaCard {
  spec?: string
  spec_version?: string
  data: CardData
  [key: string]: unknown
}

export interface StudioCard {
  /** 工作模型:始终为 {spec, spec_version, data} 包裹(编辑 data 内字段) */
  raw: CharaCard
  sourceSpec: SourceSpec
  fileName: string
  filePath?: string
  /** 原始 PNG(base64),导出 PNG 时作为底图保留原图 */
  pngBase64?: string
  modified: boolean
}

export interface StatusField {
  name: string
  desc?: string
  type?: string
  locked?: boolean
}

export interface FrontendSpec {
  html: string
  mode?: 'panel' | 'fullscreen'
  title?: string
  size?: { width?: number | string; height?: number | string }
}

/** ArkTavern 扩展命名空间(data.extensions.arktavern) */
export interface ArkExtension {
  status?: { fields?: StatusField[]; min?: number; max?: number }
  frontend?: string | FrontendSpec
  bridge_version?: number
  [key: string]: unknown
}

// ===== 归一化 =====

const V1_TO_DATA_KEYS: Record<string, string> = {
  name: 'name',
  description: 'description',
  personality: 'personality',
  scenario: 'scenario',
  first_mes: 'first_mes',
  mes_example: 'mes_example'
}

const ARK_FIELD_MAP: Record<string, string> = {
  // ArkTavern App 自研导出格式(camelCase → V3 snake_case)
  firstMessage: 'first_mes',
  systemPrompt: 'system_prompt',
  mesExample: 'mes_example',
  creatorNotes: 'creator_notes',
  postHistoryInstructions: 'post_history_instructions',
  alternateGreetings: 'alternate_greetings',
  characterVersion: 'character_version',
  characterBook: 'character_book'
}

export function normalizeCard(jsonText: string, fileName: string): StudioCard {
  const json = JSON.parse(jsonText) as Record<string, unknown>
  let sourceSpec: SourceSpec = 'v3'
  let data: CardData

  if (json.spec === 'chara_card_v3') {
    sourceSpec = 'v3'
    data = (json.data as CardData) ?? {}
  } else if (json.spec === 'chara_card_v2') {
    sourceSpec = 'v2'
    data = (json.data as CardData) ?? {}
  } else if (
    json.schemaVersion === 1 &&
    json.character &&
    typeof json.character === 'object'
  ) {
    // ArkTavern App 自研导出 {schemaVersion: 1, character: {...}}
    sourceSpec = 'arktavern'
    const character = json.character as Record<string, unknown>
    data = {}
    for (const [key, value] of Object.entries(character)) {
      const mapped = ARK_FIELD_MAP[key]
      if (mapped) {
        data[mapped] = value
      } else if (key !== 'avatarUri' && key !== 'characterBookId' && key !== 'sourceFormat') {
        data[key] = value
      }
    }
  } else {
    // V1:字段平铺在根
    sourceSpec = 'v1'
    data = {}
    for (const [key, value] of Object.entries(json)) {
      const mapped = V1_TO_DATA_KEYS[key]
      if (mapped) {
        data[mapped] = value
      } else if (key !== 'char_greeting' && key !== 'char_persona') {
        data[key] = value
      }
    }
    if (json.char_greeting) data.first_mes = json.char_greeting
    if (json.char_persona) data.personality = json.personality
    if (typeof data.extensions !== 'object' || data.extensions === null) {
      data.extensions = {}
    }
  }

  if (typeof data.extensions !== 'object' || data.extensions === null) {
    data.extensions = {}
  }
  if (!Array.isArray(data.alternate_greetings)) {
    data.alternate_greetings = []
  }
  if (!Array.isArray(data.tags)) {
    data.tags = []
  }
  // 世界书 entries 兼容 object map 形式,统一为数组
  const book = data.character_book as { entries?: unknown } | undefined
  if (book && book.entries && !Array.isArray(book.entries) && typeof book.entries === 'object') {
    book.entries = Object.values(book.entries as Record<string, unknown>)
  }

  return {
    raw: { spec: 'chara_card_v3', spec_version: '3.0', data },
    sourceSpec,
    fileName,
    modified: false
  }
}

export function createEmptyCard(): StudioCard {
  const data: CardData = {
    name: '新角色',
    description: '',
    personality: '',
    scenario: '',
    first_mes: '',
    mes_example: '',
    creator_notes: '',
    system_prompt: '',
    post_history_instructions: '',
    alternate_greetings: [],
    tags: [],
    creator: '',
    character_version: '1.0',
    extensions: {},
    assets: []
  }
  return {
    raw: { spec: 'chara_card_v3', spec_version: '3.0', data },
    sourceSpec: 'v3',
    fileName: '新角色.json',
    modified: false
  }
}

// ===== 序列化导出 =====

export function toV3Json(card: StudioCard): string {
  return JSON.stringify(
    { spec: 'chara_card_v3', spec_version: '3.0', data: card.raw.data },
    null,
    2
  )
}

export function toV2Json(card: StudioCard): string {
  return JSON.stringify(
    { spec: 'chara_card_v2', spec_version: '2.0', data: card.raw.data },
    null,
    2
  )
}

// ===== arktavern 扩展存取 =====

export function getArk(card: StudioCard): ArkExtension {
  const ext = card.raw.data.extensions as Record<string, unknown>
  const ark = ext?.arktavern
  if (ark && typeof ark === 'object' && !Array.isArray(ark)) {
    return ark as ArkExtension
  }
  return {}
}

export function setArk(card: StudioCard, ark: ArkExtension): void {
  const ext = card.raw.data.extensions as Record<string, unknown>
  ext.arktavern = ark
  card.modified = true
}

export function getStatusFields(card: StudioCard): StatusField[] {
  return getArk(card).status?.fields ?? []
}

export function getFrontendSpec(card: StudioCard): FrontendSpec | null {
  const frontend = getArk(card).frontend
  if (!frontend) return null
  if (typeof frontend === 'string') {
    return { html: frontend, mode: 'fullscreen' }
  }
  return frontend
}

/** 字段便捷读取 */
export function str(data: CardData, key: string): string {
  const v = data[key]
  return typeof v === 'string' ? v : ''
}

export function setStr(data: CardData, key: string, value: string): void {
  data[key] = value
}
