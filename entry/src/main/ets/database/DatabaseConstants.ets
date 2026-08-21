/**
 * 数据库常量集中定义
 *
 * 任何 Repository、Schema、Migration 只能从这里读取表名、列名、索引名。
 * 禁止在外部硬编码字符串。
 */

export const DATABASE_NAME: string = 'arktavern_solo.db';
export const DATABASE_VERSION: number = 35;

export const TABLE_CHARACTERS: string = 'characters';
export const TABLE_CHATS: string = 'chats';
export const TABLE_MESSAGES: string = 'messages';

export const INDEX_CHATS_UPDATED_AT: string = 'idx_chats_updated_at';
export const INDEX_CHATS_CHARACTER_ID: string = 'idx_chats_character_id';
export const INDEX_MESSAGES_CHAT_SEQUENCE: string = 'idx_messages_chat_id_sequence';
export const INDEX_MESSAGES_CHAT_CREATED: string = 'idx_messages_chat_id_created_at';

export const COLUMN_ID: string = 'id';
export const COLUMN_NAME: string = 'name';
export const COLUMN_DESCRIPTION: string = 'description';
export const COLUMN_PERSONALITY: string = 'personality';
export const COLUMN_SCENARIO: string = 'scenario';
export const COLUMN_FIRST_MESSAGE: string = 'first_message';
export const COLUMN_SYSTEM_PROMPT: string = 'system_prompt';
export const COLUMN_AVATAR_URI: string = 'avatar_uri';
export const COLUMN_CREATED_AT: string = 'created_at';
export const COLUMN_UPDATED_AT: string = 'updated_at';

// ===== v6: Tavern Card V2 字段(Character 表扩展列) =====
export const COLUMN_MES_EXAMPLE: string = 'mes_example';
export const COLUMN_CREATOR_NOTES: string = 'creator_notes';
export const COLUMN_POST_HISTORY_INSTRUCTIONS: string = 'post_history_instructions';
export const COLUMN_ALTERNATE_GREETINGS_JSON: string = 'alternate_greetings_json';
export const COLUMN_TAGS_JSON: string = 'tags_json';
export const COLUMN_CREATOR: string = 'creator';
export const COLUMN_CHARACTER_VERSION: string = 'character_version';
export const COLUMN_EXTENSIONS_JSON: string = 'extensions_json';
export const COLUMN_CHARACTER_BOOK_ID: string = 'character_book_id';
/** 角色卡 / 会话的自定义排序权重(越小越靠前,v7 引入) */
export const COLUMN_SORT_ORDER: string = 'sort_order';
/** 角色对用户的称呼(v9 引入,仅影响本角色的 {{user}} 替换) */
export const COLUMN_USER_NAME: string = 'user_name';
/** 对话级用户称呼覆盖(v9 引入,优先级高于角色 user_name 与全局设置) */
export const COLUMN_CHAT_USER_NAME_OVERRIDE: string = 'user_name_override';
/** 角色状态配置 JSON(v34 引入,存 ChatStatusState 序列化字符串) */
export const COLUMN_CHAT_STATUS_CONFIG_JSON: string = 'status_config_json';

export const COLUMN_CHARACTER_ID: string = 'character_id';
export const COLUMN_TITLE: string = 'title';
export const COLUMN_LAST_MESSAGE_AT: string = 'last_message_at';
export const COLUMN_IS_ARCHIVED: string = 'is_archived';

export const COLUMN_CHAT_ID: string = 'chat_id';
export const COLUMN_ROLE: string = 'role';
export const COLUMN_CONTENT: string = 'content';
export const COLUMN_STATUS: string = 'status';
export const COLUMN_SEQUENCE_NUMBER: string = 'sequence_number';
export const COLUMN_ERROR_MESSAGE: string = 'error_message';
export const COLUMN_IS_STREAMING: string = 'is_streaming';
export const COLUMN_SOURCE: string = 'source';

export const ROLE_USER: string = 'user';
export const ROLE_ASSISTANT: string = 'assistant';
export const ROLE_SYSTEM: string = 'system';

export const STATUS_PENDING: string = 'pending';
export const STATUS_STREAMING: string = 'streaming';
export const STATUS_COMPLETED: string = 'completed';
export const STATUS_FAILED: string = 'failed';

export const SOURCE_CONVERSATION: string = 'conversation';
export const SOURCE_CHARACTER_PROMPT: string = 'characterPrompt';
export const SOURCE_CHARACTER_FIRST_MESSAGE: string = 'characterFirstMessage';
export const SOURCE_LOREBOOK_BEFORE: string = 'lorebookBefore';
export const SOURCE_LOREBOOK_AFTER: string = 'lorebookAfter';
export const SOURCE_EXTERNAL_SYSTEM: string = 'externalSystem';

// ===== v2: Lorebooks =====
export const TABLE_LOREBOOKS: string = 'lorebooks';
export const COLUMN_LOREBOOK_ID: string = 'id';
export const COLUMN_LOREBOOK_NAME: string = 'name';
export const COLUMN_LOREBOOK_DESCRIPTION: string = 'description';
export const COLUMN_LOREBOOK_ENABLED: string = 'enabled';
export const COLUMN_LOREBOOK_CREATED_AT: string = 'created_at';
export const COLUMN_LOREBOOK_UPDATED_AT: string = 'updated_at';

// ===== v2: Lorebook Entries =====
export const TABLE_LOREBOOK_ENTRIES: string = 'lorebook_entries';
export const COLUMN_ENTRY_ID: string = 'id';
export const COLUMN_ENTRY_LOREBOOK_ID: string = 'lorebook_id';
export const COLUMN_ENTRY_NAME: string = 'name';
export const COLUMN_ENTRY_KEYS_JSON: string = 'keys_json';
export const COLUMN_ENTRY_SECONDARY_KEYS_JSON: string = 'secondary_keys_json';
export const COLUMN_ENTRY_CONTENT: string = 'content';
export const COLUMN_ENTRY_ENABLED: string = 'enabled';
export const COLUMN_ENTRY_CONSTANT: string = 'constant';
export const COLUMN_ENTRY_SELECTIVE: string = 'selective';
export const COLUMN_ENTRY_POSITION: string = 'position';
export const COLUMN_ENTRY_PRIORITY: string = 'priority';
export const COLUMN_ENTRY_CREATED_AT: string = 'created_at';
export const COLUMN_ENTRY_UPDATED_AT: string = 'updated_at';

// ===== v2: Lorebook Indexes =====
export const INDEX_LOREBOOKS_UPDATED_AT: string = 'idx_lorebooks_updated_at';
export const INDEX_LOREBOOKS_ENABLED: string = 'idx_lorebooks_enabled';
export const INDEX_LOREBOOK_ENTRIES_LOREBOOK_ID: string = 'idx_lorebook_entries_lorebook_id';
export const INDEX_LOREBOOK_ENTRIES_LOREBOOK_PRIORITY: string = 'idx_lorebook_entries_lorebook_priority';

// ===== v3: Prompt Presets =====
export const TABLE_PROMPT_PRESETS: string = 'prompt_presets';
export const COLUMN_PRESET_ID: string = 'id';
export const COLUMN_PRESET_NAME: string = 'name';
export const COLUMN_PRESET_DESCRIPTION: string = 'description';
export const COLUMN_PRESET_SYSTEM_PROMPT: string = 'system_prompt';
export const COLUMN_PRESET_TEMPERATURE: string = 'temperature';
export const COLUMN_PRESET_TOP_P: string = 'top_p';
export const COLUMN_PRESET_MAX_OUTPUT_TOKENS: string = 'max_output_tokens';
export const COLUMN_PRESET_CONTEXT_WINDOW: string = 'context_window';
export const COLUMN_PRESET_CREATED_AT: string = 'created_at';
export const COLUMN_PRESET_UPDATED_AT: string = 'updated_at';

// ===== v3: Prompt Preset Indexes =====
export const INDEX_PROMPT_PRESETS_UPDATED_AT: string = 'idx_prompt_presets_updated_at';

// ===== v4: Swipe =====
export const TABLE_MESSAGE_SWIPE_GROUPS: string = 'message_swipe_groups';
export const TABLE_MESSAGE_SWIPE_CANDIDATES: string = 'message_swipe_candidates';

export const COLUMN_SWIPE_ASSISTANT_MESSAGE_ID: string = 'assistant_message_id';
export const COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX: string = 'active_candidate_index';
export const COLUMN_SWIPE_CANDIDATE_ID: string = 'id';
export const COLUMN_SWIPE_CANDIDATE_INDEX: string = 'candidate_index';

export const INDEX_SWIPE_GROUPS_CHAT_ID: string = 'idx_swipe_groups_chat_id';
export const INDEX_SWIPE_CANDIDATES_MESSAGE_ID: string = 'idx_swipe_candidates_message_id';
export const INDEX_SWIPE_CANDIDATES_MESSAGE_INDEX: string = 'idx_swipe_candidates_message_index';

// ===== v5: Conversation Branches =====
export const TABLE_CONVERSATION_BRANCHES: string = 'conversation_branches';
export const TABLE_CHAT_BRANCH_STATE: string = 'chat_branch_state';
export const TABLE_CONVERSATION_BRANCH_MESSAGES: string = 'conversation_branch_messages';
export const TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS: string = 'conversation_branch_swipe_selections';

export const COLUMN_BRANCH_ID: string = 'branch_id';
export const COLUMN_PARENT_BRANCH_ID: string = 'parent_branch_id';
export const COLUMN_FORK_MESSAGE_ID: string = 'fork_message_id';
export const COLUMN_IS_ROOT: string = 'is_root';
export const COLUMN_ACTIVE_BRANCH_ID: string = 'active_branch_id';
export const COLUMN_POSITION: string = 'position';
export const COLUMN_CANDIDATE_INDEX: string = 'candidate_index';

export const INDEX_CONVERSATION_BRANCHES_CHAT_ID: string = 'idx_conversation_branches_chat_id';
export const INDEX_CONVERSATION_BRANCHES_PARENT_ID: string = 'idx_conversation_branches_parent_id';
export const INDEX_BRANCH_MESSAGES_MESSAGE_ID: string = 'idx_branch_messages_message_id';
export const INDEX_BRANCH_SWIPE_SELECTIONS_MESSAGE_ID: string = 'idx_branch_swipe_selections_message_id';

// ===== v8: Chat Memory(分支感知长期记忆) =====
export const TABLE_CHAT_MEMORIES: string = 'chat_memories';

export const COLUMN_MEMORY_ID: string = 'id';
export const COLUMN_MEMORY_CHAT_ID: string = 'chat_id';
export const COLUMN_MEMORY_BRANCH_ID: string = 'branch_id';
export const COLUMN_MEMORY_START_MESSAGE_ID: string = 'start_message_id';
export const COLUMN_MEMORY_END_MESSAGE_ID: string = 'end_message_id';
export const COLUMN_MEMORY_START_POSITION: string = 'start_position';
export const COLUMN_MEMORY_END_POSITION: string = 'end_position';
export const COLUMN_MEMORY_SUMMARY: string = 'summary';
export const COLUMN_MEMORY_ENABLED: string = 'enabled';
export const COLUMN_MEMORY_SUMMARY_VERSION: string = 'summary_version';
export const COLUMN_MEMORY_INHERITED_FROM_MEMORY_ID: string = 'inherited_from_memory_id';

// ===== v12: Chat Memory 多层记忆扩展字段 =====
/** 记忆类型:core / chapter / rolling / legacy */
export const COLUMN_MEMORY_TYPE: string = 'memory_type';
/** 记忆标题(章节标题或核心记忆标签) */
export const COLUMN_MEMORY_TITLE: string = 'title';
/** 详细内容(章节摘要的详细描述,比 summary 更丰富) */
export const COLUMN_MEMORY_DETAIL: string = 'detail';
/** 重要度(0-100,用于注入优先级排序) */
export const COLUMN_MEMORY_IMPORTANCE: string = 'importance';
/** 关键词 JSON 数组(用于相关记忆匹配) */
export const COLUMN_MEMORY_KEYWORDS_JSON: string = 'keywords_json';
/** 源内容哈希(用于检测源消息变化) */
export const COLUMN_MEMORY_SOURCE_HASH: string = 'source_hash';
/** 是否已失效(编辑/删除/Swipe 切换后标记,不再注入 Prompt) */
export const COLUMN_MEMORY_INVALIDATED: string = 'invalidated';

export const INDEX_CHAT_MEMORIES_CHAT_ID: string = 'idx_chat_memories_chat_id';
export const INDEX_CHAT_MEMORIES_BRANCH_ID: string = 'idx_chat_memories_branch_id';
export const INDEX_CHAT_MEMORIES_BRANCH_END_POSITION: string = 'idx_chat_memories_branch_end_position';
/** v12: 按 Branch + Type + Invalidated 查询有效记忆 */
export const INDEX_CHAT_MEMORIES_BRANCH_TYPE: string = 'idx_chat_memories_branch_type';

// ===== messages 表扩展字段(原 v10/v11 引入,已内建到 CREATE 语句) =====
export const COLUMN_SENDER_TYPE: string = 'sender_type';
export const COLUMN_SENDER_CHARACTER_ID: string = 'sender_character_id';
export const COLUMN_SCENE_ID: string = 'scene_id';
export const COLUMN_GENERATION_BATCH_ID: string = 'generation_batch_id';
export const COLUMN_VISIBILITY: string = 'visibility';
export const COLUMN_RECIPIENT_CHARACTER_IDS_JSON: string = 'recipient_character_ids_json';
export const COLUMN_PARTICIPANT_IDS_JSON: string = 'participant_ids_json';
export const COLUMN_WITNESS_IDS_JSON: string = 'witness_ids_json';

// ===== v14: G-CONTROL-2A 公开消息回复目标字段(独立于私聊 recipient) =====
/** 公开消息回复目标角色 ID 列表(JSON 数组,空表示全员回复) */
export const COLUMN_REPLY_TARGET_CHARACTER_IDS_JSON: string = 'reply_target_character_ids_json';

// messages 索引扩展
export const INDEX_MESSAGES_CHAT_BATCH: string = 'idx_messages_chat_batch';
export const INDEX_MESSAGES_SENDER_CHARACTER: string = 'idx_messages_sender_character';

// ===== ALTER TABLE 语句(仅迁移时使用) =====
export const ALTER_MESSAGES_ADD_SENDER_TYPE: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_SENDER_TYPE} TEXT NOT NULL DEFAULT 'user'`;
export const ALTER_MESSAGES_ADD_SENDER_CHARACTER_ID: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_SENDER_CHARACTER_ID} TEXT`;
export const ALTER_MESSAGES_ADD_SCENE_ID: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_SCENE_ID} TEXT`;
export const ALTER_MESSAGES_ADD_GENERATION_BATCH_ID: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_GENERATION_BATCH_ID} TEXT`;
export const ALTER_MESSAGES_ADD_VISIBILITY: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_VISIBILITY} TEXT NOT NULL DEFAULT 'public'`;
export const ALTER_MESSAGES_ADD_RECIPIENT_CHARACTER_IDS_JSON: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_RECIPIENT_CHARACTER_IDS_JSON} TEXT`;
export const ALTER_MESSAGES_ADD_PARTICIPANT_IDS_JSON: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_PARTICIPANT_IDS_JSON} TEXT`;
export const ALTER_MESSAGES_ADD_WITNESS_IDS_JSON: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_WITNESS_IDS_JSON} TEXT`;

// ===== v14: G-CONTROL-2A 公开消息回复目标字段迁移 =====
export const ALTER_MESSAGES_ADD_REPLY_TARGET_CHARACTER_IDS_JSON: string =
  `ALTER TABLE ${TABLE_MESSAGES} ADD COLUMN ${COLUMN_REPLY_TARGET_CHARACTER_IDS_JSON} TEXT`;

// ===== CREATE INDEX 语句(新安装和迁移都用) =====
export const CREATE_INDEX_MESSAGES_CHAT_BATCH: string =
  `CREATE INDEX IF NOT EXISTS ${INDEX_MESSAGES_CHAT_BATCH} ON ${TABLE_MESSAGES}(${COLUMN_CHAT_ID}, ${COLUMN_GENERATION_BATCH_ID})`;
export const CREATE_INDEX_MESSAGES_SENDER_CHARACTER: string =
  `CREATE INDEX IF NOT EXISTS ${INDEX_MESSAGES_SENDER_CHARACTER} ON ${TABLE_MESSAGES}(${COLUMN_SENDER_CHARACTER_ID})`;

// ===== v13: 多人聊天参与者表(G-DATA-1A) =====
export const TABLE_CHAT_PARTICIPANTS: string = 'chat_participants';
/** chats 表新增字段:对话模式('single' / 'group') */
export const COLUMN_CONVERSATION_MODE: string = 'conversation_mode';
/** chat_participants.speaker_order:发言顺序(从 0 开始,同 Chat 内唯一) */
export const COLUMN_SPEAKER_ORDER: string = 'speaker_order';
/** chat_participants.is_enabled:是否启用(参与 AI 生成轮次) */
export const COLUMN_IS_ENABLED: string = 'is_enabled';

/** ConversationMode 字符串值集中定义 */
export const CONVERSATION_MODE_SINGLE: string = 'single';
export const CONVERSATION_MODE_GROUP: string = 'group';

/** chat_participants(chat_id, speaker_order) 索引 */
export const INDEX_CHAT_PARTICIPANTS_CHAT_ORDER: string = 'idx_chat_participants_chat_order';

export const ALTER_CHATS_ADD_CONVERSATION_MODE: string =
  `ALTER TABLE ${TABLE_CHATS} ADD COLUMN ${COLUMN_CONVERSATION_MODE} TEXT NOT NULL DEFAULT '${CONVERSATION_MODE_SINGLE}'`;

export const CREATE_INDEX_CHAT_PARTICIPANTS_CHAT_ORDER: string =
  `CREATE INDEX IF NOT EXISTS ${INDEX_CHAT_PARTICIPANTS_CHAT_ORDER} ` +
  `ON ${TABLE_CHAT_PARTICIPANTS}(${COLUMN_CHAT_ID}, ${COLUMN_SPEAKER_ORDER})`;

// ===== v15: 世界模式数据域(W-DATA-1A) =====
// 独立数据域,不复用 chats / messages / chat_participants。
// 表名 / 列名 / 索引名集中定义,Repository / Schema / Migration 只读取此处。
export const TABLE_WORLDS: string = 'worlds';
export const TABLE_WORLD_LOCATIONS: string = 'world_locations';
export const TABLE_WORLD_LOCATION_EDGES: string = 'world_location_edges';
export const TABLE_WORLD_CHARACTER_INSTANCES: string = 'world_character_instances';
export const TABLE_WORLD_EVENTS: string = 'world_events';

/** worlds.world_id 列名(同表使用 id 作为主键,world_id 用于其他表外键引用) */
export const COLUMN_WORLD_ID: string = 'world_id';
/** 地点规范化键(用于精确去重) */
export const COLUMN_CANONICAL_KEY: string = 'canonical_key';
/** 边起点地点 ID */
export const COLUMN_FROM_LOCATION_ID: string = 'from_location_id';
/** 边终点地点 ID */
export const COLUMN_TO_LOCATION_ID: string = 'to_location_id';
/** 边方向显示说明 */
export const COLUMN_DIRECTION_LABEL: string = 'direction_label';
/** 边旅行描述 */
export const COLUMN_TRAVEL_DESCRIPTION: string = 'travel_description';
/** 边是否双向可通行 */
export const COLUMN_IS_BIDIRECTIONAL: string = 'is_bidirectional';
/** 角色实例显示名称快照 */
export const COLUMN_DISPLAY_NAME_SNAPSHOT: string = 'display_name_snapshot';
/** 角色实例当前位置 ID(可空) */
export const COLUMN_CURRENT_LOCATION_ID: string = 'current_location_id';
/** 角色实例是否活跃 */
export const COLUMN_IS_ACTIVE: string = 'is_active';
/** 事件类型 */
export const COLUMN_EVENT_TYPE: string = 'event_type';
/** 事件源角色实例 ID(可空) */
export const COLUMN_SOURCE_CHARACTER_INSTANCE_ID: string = 'source_character_instance_id';
/** 事件源地点 ID(可空) */
export const COLUMN_SOURCE_LOCATION_ID: string = 'source_location_id';
/** 事件目标地点 ID(可空) */
export const COLUMN_TARGET_LOCATION_ID: string = 'target_location_id';
/** 事件源场景 ID(可空,为后续场景阶段保留) */
export const COLUMN_SOURCE_SCENE_ID: string = 'source_scene_id';
/** 事件源消息 ID(可空,为后续场景阶段保留) */
export const COLUMN_SOURCE_MESSAGE_ID: string = 'source_message_id';
/** 事件摘要 */
export const COLUMN_SUMMARY: string = 'summary';
/** 事件结构化负载 JSON */
export const COLUMN_PAYLOAD_JSON: string = 'payload_json';
/** 事件发生时间 */
export const COLUMN_OCCURRED_AT: string = 'occurred_at';

// ===== v15: 世界模式索引名 =====
export const INDEX_WORLDS_STATUS: string = 'idx_worlds_status';
export const INDEX_WORLDS_UPDATED_AT: string = 'idx_worlds_updated_at';
export const INDEX_WORLD_LOCATIONS_WORLD_ID: string = 'idx_world_locations_world_id';
export const INDEX_WORLD_LOCATIONS_WORLD_STATUS: string = 'idx_world_locations_world_status';
export const INDEX_WORLD_LOCATION_EDGES_WORLD_ID: string = 'idx_world_location_edges_world_id';
export const INDEX_WORLD_LOCATION_EDGES_FROM: string = 'idx_world_location_edges_from';
export const INDEX_WORLD_LOCATION_EDGES_TO: string = 'idx_world_location_edges_to';
export const INDEX_WORLD_LOCATION_EDGES_ENABLED: string = 'idx_world_location_edges_enabled';
export const INDEX_WORLD_CHARACTER_INSTANCES_WORLD_ID: string = 'idx_world_character_instances_world_id';
export const INDEX_WORLD_CHARACTER_INSTANCES_CHARACTER_ID: string = 'idx_world_character_instances_character_id';
export const INDEX_WORLD_CHARACTER_INSTANCES_LOCATION: string = 'idx_world_character_instances_location';
export const INDEX_WORLD_CHARACTER_INSTANCES_WORLD_ACTIVE: string = 'idx_world_character_instances_world_active';
export const INDEX_WORLD_EVENTS_WORLD_ID: string = 'idx_world_events_world_id';
export const INDEX_WORLD_EVENTS_OCCURRED_AT: string = 'idx_world_events_world_occurred_at';
export const INDEX_WORLD_EVENTS_TYPE: string = 'idx_world_events_type';
export const INDEX_WORLD_EVENTS_SOURCE_CHARACTER: string = 'idx_world_events_source_character';
export const INDEX_WORLD_EVENTS_SOURCE_SCENE: string = 'idx_world_events_source_scene';

// ===== v16: 世界场景与场景消息(W-SCENE-1A) =====
// 独立数据域,不复用 chats / messages / chat_participants。
// 2 张 world_scene* 表 + 相关索引,新安装和 v15→v16 迁移共用同一份 DDL。
export const TABLE_WORLD_SCENES: string = 'world_scenes';
export const TABLE_WORLD_SCENE_MESSAGES: string = 'world_scene_messages';

/** world_scenes.location_id 列名 */
export const COLUMN_LOCATION_ID: string = 'location_id';
/** world_scenes.started_at 列名 */
export const COLUMN_STARTED_AT: string = 'started_at';
/** world_scenes.ended_at 列名 */
export const COLUMN_ENDED_AT: string = 'ended_at';

/** world_scene_messages.scene_id 列名(复用 messages 表同名列常量 COLUMN_SCENE_ID) */
/** world_scene_messages.sender_type 列名 */
export const COLUMN_SENDER_TYPE_WS: string = 'sender_type';
/** world_scene_messages.sender_character_instance_id 列名 */
export const COLUMN_SENDER_CHARACTER_INSTANCE_ID: string = 'sender_character_instance_id';
/** world_scene_messages.generation_batch_id 列名(与 messages 表字段语义一致,独立列) */
export const COLUMN_GENERATION_BATCH_ID_WS: string = 'generation_batch_id';
/** world_scene_messages.visibility 列名(与 messages 表字段语义一致,独立列) */
export const COLUMN_VISIBILITY_WS: string = 'visibility';
/** world_scene_messages.recipient_character_instance_ids_json 列名 */
export const COLUMN_RECIPIENT_CHARACTER_INSTANCE_IDS_JSON: string = 'recipient_character_instance_ids_json';
/** world_scene_messages.participant_character_instance_ids_json 列名 */
export const COLUMN_PARTICIPANT_CHARACTER_INSTANCE_IDS_JSON: string = 'participant_character_instance_ids_json';
/** world_scene_messages.witness_character_instance_ids_json 列名 */
export const COLUMN_WITNESS_CHARACTER_INSTANCE_IDS_JSON: string = 'witness_character_instance_ids_json';
/** world_scene_messages.reply_target_character_instance_ids_json 列名 */
export const COLUMN_REPLY_TARGET_CHARACTER_INSTANCE_IDS_JSON: string = 'reply_target_character_instance_ids_json';

// ===== v16: 世界场景索引名 =====
export const INDEX_WORLD_SCENES_WORLD_ID: string = 'idx_world_scenes_world_id';
export const INDEX_WORLD_SCENES_LOCATION_ID: string = 'idx_world_scenes_location_id';
export const INDEX_WORLD_SCENES_WORLD_STATUS: string = 'idx_world_scenes_world_status';
export const INDEX_WORLD_SCENES_WORLD_LOCATION: string = 'idx_world_scenes_world_location';
export const INDEX_WORLD_SCENES_WORLD_LOCATION_STATUS: string = 'idx_world_scenes_world_location_status';
export const INDEX_WORLD_SCENES_STARTED_AT: string = 'idx_world_scenes_started_at';

export const INDEX_WORLD_SCENE_MESSAGES_WORLD_ID: string = 'idx_world_scene_messages_world_id';
export const INDEX_WORLD_SCENE_MESSAGES_SCENE_ID: string = 'idx_world_scene_messages_scene_id';
export const INDEX_WORLD_SCENE_MESSAGES_SCENE_SEQUENCE: string = 'idx_world_scene_messages_scene_sequence';
export const INDEX_WORLD_SCENE_MESSAGES_SCENE_STATUS: string = 'idx_world_scene_messages_scene_status';
export const INDEX_WORLD_SCENE_MESSAGES_SENDER_INSTANCE: string = 'idx_world_scene_messages_sender_instance';
export const INDEX_WORLD_SCENE_MESSAGES_BATCH: string = 'idx_world_scene_messages_batch';
export const INDEX_WORLD_SCENE_MESSAGES_VISIBILITY: string = 'idx_world_scene_messages_visibility';
export const INDEX_WORLD_SCENE_MESSAGES_CREATED_AT: string = 'idx_world_scene_messages_created_at';

// ===== v17: 世界角色实例独立长期记忆(W-MEMORY-1A) =====
// 独立数据域,不复用 chat_memories。
// 记忆所有权属于 WorldCharacterInstance,不属于 Character 模板、WorldLocation、WorldScene。
// 表名 / 列名 / 索引名集中定义,Repository / Schema / Migration 只读取此处。
export const TABLE_WORLD_CHARACTER_MEMORIES: string = 'world_character_memories';

/** world_character_memories.character_instance_id 列名 */
export const COLUMN_CHARACTER_INSTANCE_ID: string = 'character_instance_id';
/** world_character_memories.memory_type 列名 */
export const COLUMN_MEMORY_TYPE_WCM: string = 'memory_type';
/** world_character_memories.origin_type 列名 */
export const COLUMN_ORIGIN_TYPE: string = 'origin_type';
/** world_character_memories.importance 列名(独立于 chat_memories.importance) */
export const COLUMN_IMPORTANCE_WCM: string = 'importance';

// ===== v17: 世界角色记忆索引名 =====
export const INDEX_WORLD_CHARACTER_MEMORIES_WORLD_ID: string = 'idx_world_character_memories_world_id';
export const INDEX_WORLD_CHARACTER_MEMORIES_INSTANCE: string = 'idx_world_character_memories_instance';
export const INDEX_WORLD_CHARACTER_MEMORIES_INSTANCE_STATUS: string = 'idx_world_character_memories_instance_status';
export const INDEX_WORLD_CHARACTER_MEMORIES_INSTANCE_STATUS_UPDATED: string = 'idx_world_character_memories_instance_status_updated';
export const INDEX_WORLD_CHARACTER_MEMORIES_TYPE: string = 'idx_world_character_memories_type';
export const INDEX_WORLD_CHARACTER_MEMORIES_ORIGIN: string = 'idx_world_character_memories_origin';
export const INDEX_WORLD_CHARACTER_MEMORIES_SOURCE_SCENE: string = 'idx_world_character_memories_source_scene';
export const INDEX_WORLD_CHARACTER_MEMORIES_SOURCE_MESSAGE: string = 'idx_world_character_memories_source_message';
export const INDEX_WORLD_CHARACTER_MEMORIES_SOURCE_LOCATION: string = 'idx_world_character_memories_source_location';
export const INDEX_WORLD_CHARACTER_MEMORIES_OCCURRED_AT: string = 'idx_world_character_memories_occurred_at';
export const INDEX_WORLD_CHARACTER_MEMORIES_IMPORTANCE: string = 'idx_world_character_memories_importance';

// ===== v18: 多人聊天每角色独立记忆(G-MEMORY-1A) =====
// 独立数据域,不复用 chat_memories / world_character_memories。
// 记忆所有权属于 (group_conversation_id, character_id):
// - group_conversation_id 对应 chats.id(ConversationMode=Group)
// - character_id 对应 characters.id(角色卡)
// - 同一角色在不同群聊中的记忆完全隔离
// - 角色被移出群聊时记忆保留,重新加入时恢复
// - 删除整个群聊时同事务级联清理
// - 删除角色卡时记忆保留(角色缺失时 UI 安全降级显示)
// 表名 / 列名 / 索引名集中定义,Repository / Schema / Migration 只读取此处。
export const TABLE_GROUP_CHARACTER_MEMORIES: string = 'group_character_memories';

/** group_character_memories.group_conversation_id 列名(对应 chats.id) */
export const COLUMN_GROUP_CONVERSATION_ID: string = 'group_conversation_id';
/** group_character_memories.title 列名(记忆标题,独立于 chat_memories.title) */
export const COLUMN_MEMORY_TITLE_GCM: string = 'title';
/** group_character_memories.importance 列名(独立于 chat_memories / world_character_memories) */
export const COLUMN_IMPORTANCE_GCM: string = 'importance';
/** group_character_memories.source_round_id 列名(交互记忆预留) */
export const COLUMN_SOURCE_ROUND_ID: string = 'source_round_id';
/** group_character_memories.source_sender_character_id 列名(交互记忆预留) */
export const COLUMN_SOURCE_SENDER_CHARACTER_ID: string = 'source_sender_character_id';
/** group_character_memories.source_type 列名(交互记忆预留) */
export const COLUMN_SOURCE_TYPE: string = 'source_type';
// COLUMN_CONTENT / COLUMN_ORIGIN_TYPE / COLUMN_STATUS / COLUMN_SOURCE_MESSAGE_ID /
// COLUMN_SOURCE_HASH / COLUMN_MEMORY_KEYWORDS_JSON / COLUMN_CHARACTER_ID / COLUMN_ID /
// COLUMN_CREATED_AT / COLUMN_UPDATED_AT 均已在文件前部定义,这里复用同名常量

// ===== v18: 多人聊天角色记忆索引名 =====
export const INDEX_GROUP_CHARACTER_MEMORIES_GROUP: string = 'idx_group_character_memories_group';
export const INDEX_GROUP_CHARACTER_MEMORIES_CHARACTER: string = 'idx_group_character_memories_character';
export const INDEX_GROUP_CHARACTER_MEMORIES_GROUP_CHARACTER: string = 'idx_group_character_memories_group_character';
export const INDEX_GROUP_CHARACTER_MEMORIES_GROUP_CHARACTER_STATUS: string = 'idx_group_character_memories_group_character_status';
export const INDEX_GROUP_CHARACTER_MEMORIES_ORIGIN: string = 'idx_group_character_memories_origin';
export const INDEX_GROUP_CHARACTER_MEMORIES_SOURCE_MESSAGE: string = 'idx_group_character_memories_source_message';
export const INDEX_GROUP_CHARACTER_MEMORIES_SOURCE_ROUND: string = 'idx_group_character_memories_source_round';
export const INDEX_GROUP_CHARACTER_MEMORIES_SOURCE_HASH: string = 'idx_group_character_memories_source_hash';
export const INDEX_GROUP_CHARACTER_MEMORIES_UPDATED_AT: string = 'idx_group_character_memories_updated_at';

// ===== v19: 多人角色定向关系记忆(G-MEMORY-AUTO-1B) =====
// 独立数据域,不复用 group_character_memories / chat_memories / world_character_memories。
// 关系所有权属于 (group_conversation_id, owner_character_id, target_type, target_id):
// - 关系有方向:A→B 与 B→A 完全隔离,各自一条记录
// - 第一版每个方向对象只保留一条当前关系摘要(UNIQUE 约束)
// - 再次批准新总结时 UPDATE 现有记录,保留新 sourceMessageIds/sourceHash/updatedAt
// - 成员移除后关系记录保留(重新加入时恢复展示)
// - 删除整个群聊时同事务级联清理
// 表名 / 列名 / 索引名集中定义,Repository / Schema / Migration 只读取此处。
export const TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES: string = 'group_character_relationship_memories';

/** group_character_relationship_memories.owner_character_id 列名(发起方角色 ID) */
export const COLUMN_OWNER_CHARACTER_ID: string = 'owner_character_id';
/** group_character_relationship_memories.target_type 列名('user' / 'character') */
export const COLUMN_TARGET_TYPE: string = 'target_type';
/** group_character_relationship_memories.target_id 列名(用户固定 'user' 或 characters.id) */
export const COLUMN_TARGET_ID: string = 'target_id';
/** group_character_relationship_memories.experience_summary 列名(共同经历) */
export const COLUMN_EXPERIENCE_SUMMARY: string = 'experience_summary';
/** group_character_relationship_memories.attitude_summary 列名(owner 对对方的态度) */
export const COLUMN_ATTITUDE_SUMMARY: string = 'attitude_summary';
/** group_character_relationship_memories.relationship_summary 列名(当前关系概括) */
export const COLUMN_RELATIONSHIP_SUMMARY: string = 'relationship_summary';
/** group_character_relationship_memories.importance 列名(独立列,1-5 默认 3) */
export const COLUMN_IMPORTANCE_GCRM: string = 'importance';
/** group_character_relationship_memories.keywords_json 列名 */
export const COLUMN_KEYWORDS_JSON: string = 'keywords_json';
/** group_character_relationship_memories.source_message_ids_json 列名(JSON 数组) */
export const COLUMN_SOURCE_MESSAGE_IDS_JSON: string = 'source_message_ids_json';
/** group_character_relationship_memories.source_hash 列名(稳定哈希,防重复) */
export const COLUMN_SOURCE_HASH_GCRM: string = 'source_hash';
/** group_character_relationship_memories.source_type 列名('relationship_summary_v1') */
export const COLUMN_SOURCE_TYPE_GCRM: string = 'source_type';

// ===== v19: 多人角色关系记忆索引名 =====
export const INDEX_GROUP_CHARACTER_RELATIONSHIP_MEMORIES_GROUP: string = 'idx_group_character_relationship_memories_group';
export const INDEX_GROUP_CHARACTER_RELATIONSHIP_MEMORIES_OWNER: string = 'idx_group_character_relationship_memories_owner';
export const INDEX_GROUP_CHARACTER_RELATIONSHIP_MEMORIES_OWNER_TARGET: string = 'idx_group_character_relationship_memories_owner_target';
export const INDEX_GROUP_CHARACTER_RELATIONSHIP_MEMORIES_OWNER_STATUS: string = 'idx_group_character_relationship_memories_owner_status';
export const INDEX_GROUP_CHARACTER_RELATIONSHIP_MEMORIES_TARGET: string = 'idx_group_character_relationship_memories_target';
export const INDEX_GROUP_CHARACTER_RELATIONSHIP_MEMORIES_SOURCE_HASH: string = 'idx_group_character_relationship_memories_source_hash';
export const INDEX_GROUP_CHARACTER_RELATIONSHIP_MEMORIES_UPDATED_AT: string = 'idx_group_character_relationship_memories_updated_at';

// ===== v20: 世界模式玩家档案与会话(W1A-WORLD-CORE-STORE) =====
// 独立数据域,不复用 world_scenes / world_scene_messages。
// 2 张新表: world_player_profiles / world_conversation_sessions。
// 表名 / 列名 / 索引名集中定义,Repository / Schema / Migration 只读取此处。
export const TABLE_WORLD_PLAYER_PROFILES: string = 'world_player_profiles';
export const TABLE_WORLD_CONVERSATION_SESSIONS: string = 'world_conversation_sessions';

/** world_player_profiles.display_name 列名 */
export const COLUMN_DISPLAY_NAME: string = 'display_name';
/** world_conversation_sessions.participant_snapshot_json 列名 */
export const COLUMN_PARTICIPANT_SNAPSHOT_JSON: string = 'participant_snapshot_json';
/** world_conversation_sessions.player_display_name_snapshot 列名 */
export const COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT: string = 'player_display_name_snapshot';

// ===== v20: 世界模式玩家档案与会话索引名 =====
export const INDEX_WORLD_PLAYER_PROFILES_WORLD_ID: string = 'idx_world_player_profiles_world_id';
export const INDEX_WORLD_CONVERSATION_SESSIONS_SCENE_ID: string = 'idx_world_conversation_sessions_scene_id';
export const INDEX_WORLD_CONVERSATION_SESSIONS_SCENE_SEQUENCE: string = 'idx_world_conversation_sessions_scene_sequence';
export const INDEX_WORLD_CONVERSATION_SESSIONS_WORLD_ID: string = 'idx_world_conversation_sessions_world_id';

// ===== v21: 世界场景/消息 Session 存储适配(W1B1-WORLD-SESSION-STORAGE-ADAPTER) =====
// world_scenes 新增 title; world_scene_messages 新增 session_id / location_id。

/** world_scenes.title 列名(场景标题,已存在于 characters/chats,此处复用常量值) */
export const COLUMN_SCENE_TITLE: string = 'title';
/** world_scene_messages.session_id 列名 */
export const COLUMN_SESSION_ID: string = 'session_id';
/** world_scene_messages.location_id 列名(复用 world_scenes.location_id 常量值) */
export const COLUMN_LOCATION_ID_WS: string = 'location_id';

// ===== v21: 新增索引名 =====
export const INDEX_WORLD_SCENE_MESSAGES_SESSION_ID: string = 'idx_world_scene_messages_session_id';
export const INDEX_WORLD_SCENE_MESSAGES_SESSION_SEQUENCE: string = 'idx_world_scene_messages_session_sequence';
export const INDEX_WORLD_SCENE_MESSAGES_LOCATION_ID: string = 'idx_world_scene_messages_location_id';

// ===== v22: 世界地点地图放置(W1C-WORLD-MAP-CONTRACT) =====
// 独立数据域,不复用 world_locations / world_scenes / world_scene_messages。
// 1 张新表: world_location_map_placements。
// 表名 / 列名 / 索引名集中定义,Repository / Schema / Migration 只读取此处。
export const TABLE_WORLD_LOCATION_MAP_PLACEMENTS: string = 'world_location_map_placements';

/** world_location_map_placements.position_x 列名 */
export const COLUMN_POSITION_X: string = 'position_x';
/** world_location_map_placements.position_y 列名 */
export const COLUMN_POSITION_Y: string = 'position_y';
/** world_location_map_placements.position_z 列名 */
export const COLUMN_POSITION_Z: string = 'position_z';
/** world_location_map_placements.rotation_x 列名 */
export const COLUMN_ROTATION_X: string = 'rotation_x';
/** world_location_map_placements.rotation_y 列名 */
export const COLUMN_ROTATION_Y: string = 'rotation_y';
/** world_location_map_placements.rotation_z 列名 */
export const COLUMN_ROTATION_Z: string = 'rotation_z';
/** world_location_map_placements.scale 列名 */
export const COLUMN_PLACEMENT_SCALE: string = 'scale';

// ===== v23: 世界角色实例领域增强(W2A1-WORLD-PLAYER-CHARACTER-DOMAIN) =====
// world_character_instances 新增 current_goal / map_icon_style 列。
// world_player_profiles 新增 persona / public_identity / private_identity / current_location_id 列。

/** world_character_instances.current_goal 列名(角色在该世界中的当前目标) */
export const COLUMN_CURRENT_GOAL: string = 'current_goal';
/** world_character_instances.map_icon_style 列名(地图图标样式,预留) */
export const COLUMN_MAP_ICON_STYLE: string = 'map_icon_style';
/** world_player_profiles.persona 列名(玩家人设) */
export const COLUMN_PERSONA: string = 'persona';
/** world_player_profiles.public_identity 列名(公开身份) */
export const COLUMN_PUBLIC_IDENTITY: string = 'public_identity';
/** world_player_profiles.private_identity 列名(私密身份) */
export const COLUMN_PRIVATE_IDENTITY: string = 'private_identity';

// ===== v24: 世界角色地点历史(W4A-WORLD-MOVEMENT-CORE-LOCATION-HISTORY) =====
// 独立数据域,不可变地点变更历史。
// 1 张新表: world_character_location_history。
// 表名 / 列名 / 索引名集中定义,Repository / Schema / Migration 只读取此处。
export const TABLE_WORLD_CHARACTER_LOCATION_HISTORY: string = 'world_character_location_history';

/** world_character_location_history.transition_kind 列名(transition 类型) */
export const COLUMN_TRANSITION_KIND: string = 'transition_kind';
/** world_character_location_history.initiator_type 列名(发起者类型) */
export const COLUMN_INITIATOR_TYPE: string = 'initiator_type';
/** world_character_location_history.edge_id 列名(旅行经过的边 ID,可空) */
export const COLUMN_EDGE_ID: string = 'edge_id';

// ===== v24: 世界角色地点历史索引名 =====
export const INDEX_WORLD_CHARACTER_LOCATION_HISTORY_WORLD_ID: string = 'idx_world_character_location_history_world_id';
export const INDEX_WORLD_CHARACTER_LOCATION_HISTORY_INSTANCE: string = 'idx_world_character_location_history_instance';
export const INDEX_WORLD_CHARACTER_LOCATION_HISTORY_INSTANCE_CREATED: string = 'idx_world_character_location_history_instance_created';
export const INDEX_WORLD_CHARACTER_LOCATION_HISTORY_TRANSITION: string = 'idx_world_character_location_history_transition';
export const INDEX_WORLD_CHARACTER_LOCATION_HISTORY_OCCURRED_AT: string = 'idx_world_character_location_history_occurred_at';

// ===== v25: 世界会话摘要存储(W5A1-WORLD-SESSION-SUMMARY-STORE) =====
// 独立数据域,不可变会话摘要。
// 1 张新表: world_session_summaries + 相关索引,
// 表名 / 列名 / 索引名集中定义,Repository / Schema / Migration 只读取此处。
export const TABLE_WORLD_SESSION_SUMMARIES: string = 'world_session_summaries';

/** world_session_summaries.session_id 列名 */
export const COLUMN_SESSION_ID_WSS: string = 'session_id';
/** world_session_summaries.version 列名(session-scoped, starting at 1) */
export const COLUMN_VERSION: string = 'version';
/** world_session_summaries.visibility_scope 列名 */
export const COLUMN_VISIBILITY_SCOPE: string = 'visibility_scope';
/** world_session_summaries.source_message_ids_json 列名(full provenance) */
export const COLUMN_SOURCE_MESSAGE_IDS_JSON_WSS: string = 'source_message_ids_json';
/** world_session_summaries.source_message_count 列名(auto-derived from sourceMessageIds.length) */
export const COLUMN_SOURCE_MESSAGE_COUNT: string = 'source_message_count';
/** world_session_summaries.participant_snapshot_json 列名 */
export const COLUMN_PARTICIPANT_SNAPSHOT_JSON_WSS: string = 'participant_snapshot_json';
/** world_session_summaries.player_display_name_snapshot 列名 */
export const COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WSS: string = 'player_display_name_snapshot';
/** world_session_summaries.location_id 列名 */
export const COLUMN_LOCATION_ID_WSS: string = 'location_id';
/** world_session_summaries.prompt_version 列名 */
export const COLUMN_PROMPT_VERSION: string = 'prompt_version';

// ===== v25: 世界会话摘要索引名 =====
export const INDEX_WORLD_SESSION_SUMMARIES_WORLD_ID: string = 'idx_world_session_summaries_world_id';
export const INDEX_WORLD_SESSION_SUMMARIES_SCENE_ID: string = 'idx_world_session_summaries_scene_id';
export const INDEX_WORLD_SESSION_SUMMARIES_SESSION_ID: string = 'idx_world_session_summaries_session_id';
export const INDEX_WORLD_SESSION_SUMMARIES_SESSION_VERSION: string = 'idx_world_session_summaries_session_version';
export const INDEX_WORLD_SESSION_SUMMARIES_CREATED_AT: string = 'idx_world_session_summaries_created_at';

// ===== v26: 世界会话摘要来源追溯(W5A2-PROVENANCE) =====
/** world_session_summaries.provider_id 列名(生成时使用的 ProviderConfig.id) */
export const COLUMN_PROVIDER_ID_WSS: string = 'provider_id';
/** world_session_summaries.model_id 列名(生成时使用的 ProviderConfig.modelName) */
export const COLUMN_MODEL_ID_WSS: string = 'model_id';

// ===== v27: 世界角色私有主观记忆存储(W5B1-WORLD-CHARACTER-MEMORY-STORE) =====
export const TABLE_WORLD_CHARACTER_MEMORY_ENTRIES: string = 'world_character_memory_entries';

export const COLUMN_OWNER_CHARACTER_INSTANCE_ID_WCME: string = 'owner_character_instance_id';
export const COLUMN_MEMORY_KIND_WCME: string = 'memory_kind';
export const COLUMN_SOURCE_SCENE_ID_WCME: string = 'source_scene_id';
export const COLUMN_SOURCE_SESSION_ID_WCME: string = 'source_session_id';
export const COLUMN_SOURCE_LOCATION_ID_WCME: string = 'source_location_id';
export const COLUMN_MEMORY_TEXT_WCME: string = 'memory_text';
export const COLUMN_SOURCE_MESSAGE_IDS_JSON_WCME: string = 'source_message_ids_json';
export const COLUMN_SOURCE_MESSAGE_COUNT_WCME: string = 'source_message_count';
export const COLUMN_SOURCE_PARTICIPANT_INSTANCE_IDS_JSON_WCME: string = 'source_participant_instance_ids_json';
export const COLUMN_SOURCE_WITNESS_INSTANCE_IDS_JSON_WCME: string = 'source_witness_instance_ids_json';
export const COLUMN_OWNER_DISPLAY_NAME_SNAPSHOT_WCME: string = 'owner_display_name_snapshot';
export const COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WCME: string = 'player_display_name_snapshot';
export const COLUMN_CONFIDENCE_WCME: string = 'confidence';
export const COLUMN_STATUS_WCME: string = 'status';
export const COLUMN_PROMPT_VERSION_WCME: string = 'prompt_version';
export const COLUMN_PROVIDER_ID_WCME: string = 'provider_id';
export const COLUMN_MODEL_ID_WCME: string = 'model_id';
export const COLUMN_SUPERSEDES_MEMORY_ID_WCME: string = 'supersedes_memory_id';
export const COLUMN_STATUS_UPDATED_AT_WCME: string = 'status_updated_at';

// ===== v27: 世界角色私有主观记忆索引名 =====
export const INDEX_WORLD_CHARACTER_MEMORY_ENTRIES_OWNER_CREATED: string = 'idx_wcme_owner_created';
export const INDEX_WORLD_CHARACTER_MEMORY_ENTRIES_OWNER_STATUS_CREATED: string = 'idx_wcme_owner_status_created';
export const INDEX_WORLD_CHARACTER_MEMORY_ENTRIES_OWNER_SESSION_KIND_VERSION: string = 'idx_wcme_owner_session_kind_version';

// ===== v28: 世界事件提取存储(W6A1-WORLD-EVENT-STORE-EXTRACTION-SOURCE) =====
export const TABLE_WORLD_EVENT_EXTRACTION_RUNS: string = 'world_event_extraction_runs';
export const TABLE_WORLD_EVENT_ENTRIES: string = 'world_event_entries';

export const COLUMN_SOURCE_SCENE_ID_WEER: string = 'source_scene_id';
export const COLUMN_SOURCE_SESSION_ID_WEER: string = 'source_session_id';
export const COLUMN_SOURCE_LOCATION_ID_WEER: string = 'source_location_id';
export const COLUMN_VERSION_WEER: string = 'version';
export const COLUMN_SOURCE_SUMMARY_ID_WEER: string = 'source_summary_id';
export const COLUMN_SOURCE_SUMMARY_VERSION_WEER: string = 'source_summary_version';
export const COLUMN_SOURCE_MESSAGE_IDS_JSON_WEER: string = 'source_message_ids_json';
export const COLUMN_SOURCE_MESSAGE_COUNT_WEER: string = 'source_message_count';
export const COLUMN_PARTICIPANT_INSTANCE_IDS_JSON_WEER: string = 'participant_instance_ids_json';
export const COLUMN_PLAYER_DISPLAY_NAME_SNAPSHOT_WEER: string = 'player_display_name_snapshot';
export const COLUMN_STATUS_WEER: string = 'status';
export const COLUMN_PROMPT_VERSION_WEER: string = 'prompt_version';
export const COLUMN_PROVIDER_ID_WEER: string = 'provider_id';
export const COLUMN_MODEL_ID_WEER: string = 'model_id';
export const COLUMN_STATUS_UPDATED_AT_WEER: string = 'status_updated_at';

export const COLUMN_EXTRACTION_RUN_ID: string = 'extraction_run_id';
export const COLUMN_EVENT_ORDINAL: string = 'event_ordinal';
export const COLUMN_EVENT_KIND: string = 'event_kind';
export const COLUMN_EVENT_TEXT: string = 'event_text';
export const COLUMN_ACTOR_INSTANCE_IDS_JSON: string = 'actor_instance_ids_json';
export const COLUMN_PLAYER_INVOLVED: string = 'player_involved';
export const COLUMN_EVIDENCE_MESSAGE_IDS_JSON: string = 'evidence_message_ids_json';
export const COLUMN_WITNESS_INSTANCE_IDS_JSON: string = 'witness_instance_ids_json';
export const COLUMN_CONFIDENCE: string = 'confidence';
export const COLUMN_STATUS_WEE: string = 'status';
export const COLUMN_STATUS_UPDATED_AT_WEE: string = 'status_updated_at';

// ===== v30: 世界角色方向性关系存储(W6C1-WORLD-DIRECTIONAL-RELATIONSHIP-STORE) =====
export const TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES: string = 'world_directional_relationship_entries';

export const COLUMN_OWNER_CHARACTER_INSTANCE_ID_WDRE: string = 'owner_character_instance_id';
export const COLUMN_TARGET_CHARACTER_INSTANCE_ID_WDRE: string = 'target_character_instance_id';
export const COLUMN_VERSION_WDRE: string = 'version';
export const COLUMN_RELATIONSHIP_TEXT: string = 'relationship_text';
export const COLUMN_SOURCE_SCENE_ID_WDRE: string = 'source_scene_id';
export const COLUMN_SOURCE_SESSION_ID_WDRE: string = 'source_session_id';
export const COLUMN_SOURCE_LOCATION_ID_WDRE: string = 'source_location_id';
export const COLUMN_EVIDENCE_MESSAGE_IDS_JSON_WDRE: string = 'evidence_message_ids_json';
export const COLUMN_OWNER_DISPLAY_NAME_SNAPSHOT_WDRE: string = 'owner_display_name_snapshot';
export const COLUMN_TARGET_DISPLAY_NAME_SNAPSHOT_WDRE: string = 'target_display_name_snapshot';
export const COLUMN_SUPERSEDES_RELATIONSHIP_ID: string = 'supersedes_relationship_id';
export const COLUMN_PROVIDER_ID_WDRE: string = 'provider_id';
export const COLUMN_MODEL_ID_WDRE: string = 'model_id';
export const COLUMN_STATUS_WDRE: string = 'status';
export const COLUMN_STATUS_UPDATED_AT_WDRE: string = 'status_updated_at';

// ===== v30: 世界角色方向性关系索引名 =====
export const INDEX_WORLD_DIR_REL_OWNER_STATUS_CREATED: string = 'idx_wdre_owner_status_created';
export const INDEX_WORLD_DIR_REL_OWNER_TARGET_STATUS: string = 'idx_wdre_owner_target_status';
export const INDEX_WORLD_DIR_REL_TARGET_STATUS: string = 'idx_wdre_target_status';

// ===== v29: 世界已知事件存储(W6B1-WORLD-KNOWN-EVENT-STORE) =====
export const TABLE_WORLD_KNOWN_EVENT_ENTRIES: string = 'world_known_event_entries';

export const COLUMN_OWNER_CHARACTER_INSTANCE_ID_WKEE: string = 'owner_character_instance_id';
export const COLUMN_EVENT_ID_WKEE: string = 'event_id';
export const COLUMN_EXTRACTION_RUN_ID_WKEE: string = 'extraction_run_id';
export const COLUMN_KNOWLEDGE_SOURCE_KIND: string = 'knowledge_source_kind';
export const COLUMN_SOURCE_SESSION_ID_WKEE: string = 'source_session_id';
export const COLUMN_KNOWLEDGE_SOURCE_MESSAGE_IDS_JSON: string = 'knowledge_source_message_ids_json';
export const COLUMN_STATUS_WKEE: string = 'status';
export const COLUMN_STATUS_UPDATED_AT_WKEE: string = 'status_updated_at';

// ===== v29: 世界已知事件索引名 =====
export const INDEX_WORLD_KNOWN_EVENT_ENTRIES_OWNER_CREATED: string = 'idx_wkee_owner_created';
export const INDEX_WORLD_KNOWN_EVENT_ENTRIES_OWNER_STATUS_CREATED: string = 'idx_wkee_owner_status_created';
export const INDEX_WORLD_KNOWN_EVENT_ENTRIES_OWNER_SESSION_SOURCE_KIND: string = 'idx_wkee_owner_session_source_kind';

// ===== v31: 世界会话后处理运行存储(W7A-WORLD-SESSION-POST-PROCESS-RUN-STORE) =====
export const TABLE_WORLD_SESSION_POST_PROCESS_RUNS: string = 'world_session_post_process_runs';

export const COLUMN_SESSION_ID_WPPR: string = 'session_id';
export const COLUMN_PIPELINE_VERSION_WPPR: string = 'pipeline_version';
export const COLUMN_STATE_JSON_WPPR: string = 'state_json';
export const COLUMN_ATTEMPT_COUNT_WPPR: string = 'attempt_count';
export const COLUMN_REVISION_WPPR: string = 'revision';
export const COLUMN_COMPLETED_AT_WPPR: string = 'completed_at';

// ===== v31: 世界会话后处理运行索引名 =====
export const INDEX_WORLD_SESSION_POST_PROCESS_RUNS_WORLD_ID: string = 'idx_wppr_world_id';
export const INDEX_WORLD_SESSION_POST_PROCESS_RUNS_SESSION_ID: string = 'idx_wppr_session_id';
export const INDEX_WORLD_SESSION_POST_PROCESS_RUNS_WORLD_STATUS: string = 'idx_wppr_world_status';

// ===== v28: 世界事件提取索引名 =====
export const INDEX_WORLD_EVENT_EXTRACTION_RUNS_WORLD_SESSION_VERSION: string = 'idx_weer_world_session_version';
export const INDEX_WORLD_EVENT_EXTRACTION_RUNS_WORLD_SCENE_CREATED: string = 'idx_weer_world_scene_created';
export const INDEX_WORLD_EVENT_EXTRACTION_RUNS_WORLD_STATUS_CREATED: string = 'idx_weer_world_status_created';
export const INDEX_WORLD_EVENT_ENTRIES_WORLD_SESSION_ORDINAL: string = 'idx_wee_world_session_ordinal';
export const INDEX_WORLD_EVENT_ENTRIES_WORLD_RUN_STATUS: string = 'idx_wee_world_run_status';

// ===== v32: 多人聊天角色覆写(G-OVERRIDE-1A) =====
export const TABLE_GROUP_CHARACTER_OVERRIDES: string = 'group_character_overrides';

export const COLUMN_OVERRIDE_NAME: string = 'override_name';
export const COLUMN_OVERRIDE_DESCRIPTION: string = 'override_description';
export const COLUMN_OVERRIDE_PERSONALITY: string = 'override_personality';
export const COLUMN_OVERRIDE_SCENARIO: string = 'override_scenario';
export const COLUMN_OVERRIDE_SYSTEM_PROMPT: string = 'override_system_prompt';
export const COLUMN_OVERRIDE_MES_EXAMPLE: string = 'override_mes_example';
export const COLUMN_OVERRIDE_POST_HISTORY_INSTRUCTIONS: string = 'override_post_history_instructions';
export const COLUMN_OVERRIDE_FIRST_MESSAGE: string = 'override_first_message';

export const INDEX_GROUP_CHARACTER_OVERRIDES_GROUP_CHARACTER: string = 'idx_group_char_overrides_group_char';

export const CREATE_INDEX_GROUP_CHARACTER_OVERRIDES_GROUP_CHARACTER: string =
  `CREATE UNIQUE INDEX IF NOT EXISTS ${INDEX_GROUP_CHARACTER_OVERRIDES_GROUP_CHARACTER} ` +
  `ON ${TABLE_GROUP_CHARACTER_OVERRIDES}(${COLUMN_GROUP_CONVERSATION_ID}, ${COLUMN_CHARACTER_ID})`;

// ===== v33: 世界地图背景图(W2A3-WORLD-MAP-BACKGROUND) =====
export const TABLE_WORLD_MAP_BACKGROUNDS: string = 'world_map_backgrounds';

/** world_map_backgrounds.world_id 列名(UNIQUE,一个世界一张背景图) */
export const COLUMN_WORLD_ID_WMB: string = 'world_id';
/** world_map_backgrounds.image_uri 列名(沙箱文件 URI,file://...) */
export const COLUMN_IMAGE_URI_WMB: string = 'image_uri';
/** world_map_backgrounds.image_width 列名(图片原始宽度,像素) */
export const COLUMN_IMAGE_WIDTH_WMB: string = 'image_width';
/** world_map_backgrounds.image_height 列名(图片原始高度,像素) */
export const COLUMN_IMAGE_HEIGHT_WMB: string = 'image_height';
/** world_map_backgrounds.rotation 列名(图片旋转弧度,围绕图片中心) */
export const COLUMN_ROTATION_WMB: string = 'rotation';
/** world_map_backgrounds.fit_scale 列名(图片像素→世界单位缩放因子) */
export const COLUMN_FIT_SCALE_WMB: string = 'fit_scale';

// ===== v35: Persona 用户身份(Phase 2A) =====
export const TABLE_PERSONAS: string = 'personas';
/** personas.id 列名(PK, 'ps-' + UUID) */
export const COLUMN_PERSONA_ID: string = 'id';
/** personas.name 列名(必填,替换 {{user}}) */
export const COLUMN_PERSONA_NAME: string = 'name';
/** personas.description 列名(用户自我描述) */
export const COLUMN_PERSONA_DESCRIPTION: string = 'description';
/** personas.avatar_uri 列名(头像 URI) */
export const COLUMN_PERSONA_AVATAR_URI: string = 'avatar_uri';
/** personas.position 列名(PersonaPosition 枚举值) */
export const COLUMN_PERSONA_POSITION: string = 'position';
/** personas.depth 列名(AtDepth 时插入深度,默认 4) */
export const COLUMN_PERSONA_DEPTH: string = 'depth';
/** personas.created_at 列名 */
export const COLUMN_PERSONA_CREATED_AT: string = 'created_at';
/** personas.updated_at 列名 */
export const COLUMN_PERSONA_UPDATED_AT: string = 'updated_at';

/** personas 表索引: updated_at */
export const INDEX_PERSONAS_UPDATED_AT: string = 'idx_personas_updated_at';

/** chats 表新增列: chat_persona_id(聊天锁定的 Persona ID) */
export const COLUMN_CHAT_PERSONA_ID: string = 'chat_persona_id';
/** characters 表新增列: character_default_persona_id(角色默认 Persona ID) */
export const COLUMN_CHARACTER_DEFAULT_PERSONA_ID: string = 'character_default_persona_id';

/** v35 迁移: ALTER chats 添加 chat_persona_id 列 */
export const ALTER_CHATS_ADD_PERSONA_ID: string =
  `ALTER TABLE ${TABLE_CHATS} ADD COLUMN ${COLUMN_CHAT_PERSONA_ID} TEXT NOT NULL DEFAULT ''`;
/** v35 迁移: ALTER characters 添加 character_default_persona_id 列 */
export const ALTER_CHARACTERS_ADD_DEFAULT_PERSONA_ID: string =
  `ALTER TABLE ${TABLE_CHARACTERS} ADD COLUMN ${COLUMN_CHARACTER_DEFAULT_PERSONA_ID} TEXT NOT NULL DEFAULT ''`;
