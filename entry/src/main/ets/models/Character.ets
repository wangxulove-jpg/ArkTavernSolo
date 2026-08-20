/**
 * Character 角色模型
 *
 * 兼容 Tavern Card V1 / V2 / V3 规范字段。
 * 不依赖 ArkUI,可用于服务层和持久化层。
 *
 * 约束:
 * - name 必填,最长 100 字符
 * - 各字段最长 5000 字符
 * - extensions 原样保存(导入、编辑、保存、导出后不得丢失)
 * - tags / creator / character_version / creator_notes 只作元数据,不进入 PromptBuilder
 */

/**
 * 角色数据模型。
 */
export interface Character {
  /** 唯一标识(UUID v4) */
  readonly id: string;
  /** 角色名称(必填,最长 100 字符) */
  readonly name: string;
  /** 角色描述 */
  readonly description: string;
  /** 性格描述 */
  readonly personality: string;
  /** 场景/世界观 */
  readonly scenario: string;
  /** 开场白(首次进入聊天时显示,作为 Candidate 0) */
  readonly firstMessage: string;
  /** 系统提示词 */
  readonly systemPrompt: string;
  /** 头像 URI */
  readonly avatarUri: string;
  /** ===== Tavern Card V2 扩展字段 ===== */
  /** 对话示例(进入 PromptBuilder 作为示例消息) */
  readonly mesExample: string;
  /** 创作者备注(元数据,不进入 Prompt) */
  readonly creatorNotes: string;
  /** Post-History Instructions(放在聊天历史之后,生成请求之前) */
  readonly postHistoryInstructions: string;
  /** 备用开场白列表(作为开场白的 Swipe 候选 1..N) */
  readonly alternateGreetings: string[];
  /** 标签列表(元数据,不进入 Prompt) */
  readonly tags: string[];
  /** 创作者名(元数据,不进入 Prompt) */
  readonly creator: string;
  /** 角色卡版本(元数据,不进入 Prompt) */
  readonly characterVersion: string;
  /** 未识别扩展字段(原样保存,导入导出后不得丢失) */
  readonly extensions: Record<string, Object>;
  /** 角色专属世界书 ID(关联 lorebooks.id) */
  readonly characterBookId: string;
  /**
   * 角色对用户的称呼(可选,v9 引入)。
   * 留空时使用全局用户称呼;非空时仅影响本角色的 {{user}} 替换。
   * 不进入角色卡 V2/V3 标准字段,仅存在于 extensions.arktavern.user_name_override。
   */
  readonly userName: string;
  /** 自定义排序权重(越小越靠前,v7 引入) */
  readonly sortOrder: number;
  /** 创建时间戳(毫秒) */
  readonly createdAt: number;
  /** 更新时间戳(毫秒) */
  readonly updatedAt: number;
}

const MAX_NAME_LENGTH: number = 100;
const MAX_FIELD_LENGTH: number = 5000;
const MAX_ALTERNATE_GREETINGS: number = 20;
const MAX_TAGS: number = 30;

/**
 * 创建新角色,自动填充 id 和时间戳。
 */
export function createCharacter(
  id: string,
  name: string,
  description: string = '',
  personality: string = '',
  scenario: string = '',
  firstMessage: string = '',
  systemPrompt: string = '',
  avatarUri: string = '',
  mesExample: string = '',
  creatorNotes: string = '',
  postHistoryInstructions: string = '',
  alternateGreetings: string[] = [],
  tags: string[] = [],
  creator: string = '',
  characterVersion: string = '',
  extensions: Record<string, Object> = {},
  characterBookId: string = '',
  userName: string = '',
  sortOrder: number = 0
): Character {
  const now: number = Date.now();
  return {
    id: id,
    name: name.trim(),
    description: description.trim(),
    personality: personality.trim(),
    scenario: scenario.trim(),
    firstMessage: firstMessage.trim(),
    systemPrompt: systemPrompt.trim(),
    avatarUri: avatarUri.trim(),
    mesExample: mesExample,
    creatorNotes: creatorNotes,
    postHistoryInstructions: postHistoryInstructions,
    alternateGreetings: filterGreetings(alternateGreetings),
    tags: filterTags(tags),
    creator: creator,
    characterVersion: characterVersion,
    extensions: extensions,
    characterBookId: characterBookId.trim(),
    userName: userName.trim(),
    sortOrder: sortOrder,
    createdAt: now,
    updatedAt: now
  };
}

/**
 * 校验角色数据。
 * @returns 错误信息字符串,如果校验通过返回 null
 */
export function validateCharacter(character: Character): string | null {
  if (character.name.trim().length === 0) {
    return '角色名称不能为空';
  }
  if (character.name.length > MAX_NAME_LENGTH) {
    return '角色名称不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (character.description.length > MAX_FIELD_LENGTH) {
    return '角色描述不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.personality.length > MAX_FIELD_LENGTH) {
    return '性格描述不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.scenario.length > MAX_FIELD_LENGTH) {
    return '场景描述不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.firstMessage.length > MAX_FIELD_LENGTH) {
    return '开场白不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.systemPrompt.length > MAX_FIELD_LENGTH) {
    return 'System Prompt 不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.mesExample.length > MAX_FIELD_LENGTH) {
    return '对话示例不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.creatorNotes.length > MAX_FIELD_LENGTH) {
    return '创作者备注不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.postHistoryInstructions.length > MAX_FIELD_LENGTH) {
    return 'Post-History Instructions 不能超过' + MAX_FIELD_LENGTH + '个字符';
  }
  if (character.creator.length > MAX_NAME_LENGTH) {
    return '创作者名称不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (character.characterVersion.length > MAX_NAME_LENGTH) {
    return '角色卡版本不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (character.userName.length > MAX_NAME_LENGTH) {
    return '角色对你的称呼不能超过' + MAX_NAME_LENGTH + '个字符';
  }
  if (character.alternateGreetings.length > MAX_ALTERNATE_GREETINGS) {
    return '备用开场白不能超过' + MAX_ALTERNATE_GREETINGS + '条';
  }
  if (character.tags.length > MAX_TAGS) {
    return '标签不能超过' + MAX_TAGS + '个';
  }
  for (let i = 0; i < character.alternateGreetings.length; i++) {
    if (character.alternateGreetings[i].length > MAX_FIELD_LENGTH) {
      return '备用开场白不能超过' + MAX_FIELD_LENGTH + '个字符';
    }
  }
  for (let i = 0; i < character.tags.length; i++) {
    if (character.tags[i].length > MAX_NAME_LENGTH) {
      return '单个标签不能超过' + MAX_NAME_LENGTH + '个字符';
    }
  }
  return null;
}

/**
 * 更新角色时可选字段。
 */
export interface CharacterUpdates {
  name?: string;
  description?: string;
  personality?: string;
  scenario?: string;
  firstMessage?: string;
  systemPrompt?: string;
  avatarUri?: string;
  mesExample?: string;
  creatorNotes?: string;
  postHistoryInstructions?: string;
  alternateGreetings?: string[];
  tags?: string[];
  creator?: string;
  characterVersion?: string;
  extensions?: Record<string, Object>;
  characterBookId?: string;
  userName?: string;
  sortOrder?: number;
}

/**
 * 不可变更新角色字段。
 * 返回新 Character 对象,不修改原对象。
 */
export function updateCharacter(
  character: Character,
  updates: CharacterUpdates
): Character {
  const merged: Character = {
    id: character.id,
    name: updates.name !== undefined ? updates.name.trim() : character.name,
    description: updates.description !== undefined ? updates.description.trim() : character.description,
    personality: updates.personality !== undefined ? updates.personality.trim() : character.personality,
    scenario: updates.scenario !== undefined ? updates.scenario.trim() : character.scenario,
    firstMessage: updates.firstMessage !== undefined ? updates.firstMessage.trim() : character.firstMessage,
    systemPrompt: updates.systemPrompt !== undefined ? updates.systemPrompt.trim() : character.systemPrompt,
    avatarUri: updates.avatarUri !== undefined ? updates.avatarUri.trim() : character.avatarUri,
    mesExample: updates.mesExample !== undefined ? updates.mesExample : character.mesExample,
    creatorNotes: updates.creatorNotes !== undefined ? updates.creatorNotes : character.creatorNotes,
    postHistoryInstructions: updates.postHistoryInstructions !== undefined
      ? updates.postHistoryInstructions : character.postHistoryInstructions,
    alternateGreetings: updates.alternateGreetings !== undefined
      ? filterGreetings(updates.alternateGreetings) : character.alternateGreetings,
    tags: updates.tags !== undefined ? filterTags(updates.tags) : character.tags,
    creator: updates.creator !== undefined ? updates.creator : character.creator,
    characterVersion: updates.characterVersion !== undefined
      ? updates.characterVersion : character.characterVersion,
    extensions: updates.extensions !== undefined ? updates.extensions : character.extensions,
    characterBookId: updates.characterBookId !== undefined
      ? updates.characterBookId.trim() : character.characterBookId,
    userName: updates.userName !== undefined ? updates.userName.trim() : character.userName,
    sortOrder: updates.sortOrder !== undefined ? updates.sortOrder : character.sortOrder,
    createdAt: character.createdAt,
    updatedAt: Date.now()
  };
  return merged;
}

/**
 * 构建默认角色 System 内容(无自定义 systemPrompt 时的组合)。
 * 此内容可被 {{original}} 宏引用。
 */
export function buildDefaultCharacterSystemContent(character: Character): string {
  const parts: string[] = [];
  if (character.name.trim().length > 0) {
    parts.push('你是' + character.name);
  }
  if (character.description.trim().length > 0) {
    parts.push(character.description);
  }
  if (character.personality.trim().length > 0) {
    parts.push('性格: ' + character.personality);
  }
  if (character.scenario.trim().length > 0) {
    parts.push('场景: ' + character.scenario);
  }
  return parts.join('\n');
}

/**
 * 构建角色聊天上下文的 System 消息内容。
 *
 * 行为:
 * - systemPrompt 为空时,返回默认组合(name/description/personality/scenario)
 * - systemPrompt 非空时,原样返回(由 PromptBuilder 负责 {{original}} 替换)
 */
export function buildCharacterSystemContent(character: Character): string {
  if (character.systemPrompt.trim().length > 0) {
    return character.systemPrompt;
  }
  return buildDefaultCharacterSystemContent(character);
}

/**
 * 过滤备用开场白:去重 + trim 空项。
 */
function filterGreetings(greetings: string[]): string[] {
  const result: string[] = [];
  const seen: Set<string> = new Set();
  for (let i = 0; i < greetings.length; i++) {
    const trimmed: string = greetings[i].trim();
    if (trimmed.length === 0) {
      continue;
    }
    if (seen.has(trimmed)) {
      continue;
    }
    seen.add(trimmed);
    result.push(trimmed);
  }
  return result;
}

/**
 * 过滤标签:trim 空项 + 去重(大小写不敏感)。
 */
function filterTags(tags: string[]): string[] {
  const result: string[] = [];
  const seen: Set<string> = new Set();
  for (let i = 0; i < tags.length; i++) {
    const trimmed: string = tags[i].trim();
    if (trimmed.length === 0) {
      continue;
    }
    const lower: string = trimmed.toLowerCase();
    if (seen.has(lower)) {
      continue;
    }
    seen.add(lower);
    result.push(trimmed);
  }
  return result;
}
