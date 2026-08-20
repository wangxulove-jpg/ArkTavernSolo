/**
 * 数据库迁移框架
 *
 * 职责:
 * - 定义单步迁移接口
 * - 维护已注册的迁移列表
 * - 计算从 currentVersion 到 targetVersion 的迁移路径
 * - 不实现 destructive migration(禁止 DROP TABLE)
 *
 * 限制:
 * - 不支持降级(currentVersion > targetVersion 抛错)
 * - 不支持跳版本(必须逐版本)
 * - 不修改入参 migrations 数组
 */

import { relationalStore } from '@kit.ArkData';
import { V1_TO_V2_STATEMENTS, V2_TO_V3_STATEMENTS, V3_TO_V4_STATEMENTS, V4_TO_V5_DDL_STATEMENTS, V5_TO_V6_STATEMENTS, V6_TO_V7_STATEMENTS, V7_TO_V8_DDL_STATEMENTS, V8_TO_V9_STATEMENTS, V9_TO_V10_DDL_STATEMENTS, V10_TO_V11_DDL_STATEMENTS, V11_TO_V12_DDL_STATEMENTS, V11_TO_V12_DATA_MIGRATION_STATEMENTS, V12_TO_V13_DDL_STATEMENTS, V13_TO_V14_DDL_STATEMENTS, V13_TO_V14_DATA_MIGRATION_STATEMENTS, V14_TO_V15_DDL_STATEMENTS, V15_TO_V16_DDL_STATEMENTS, V16_TO_V17_DDL_STATEMENTS, V17_TO_V18_DDL_STATEMENTS, V18_TO_V19_DDL_STATEMENTS, V19_TO_V20_DDL_STATEMENTS, V20_TO_V21_DDL_STATEMENTS, V21_TO_V22_DDL_STATEMENTS, V22_TO_V23_DDL_STATEMENTS, V23_TO_V24_DDL_STATEMENTS, V24_TO_V25_DDL_STATEMENTS, V25_TO_V26_DDL_STATEMENTS, V26_TO_V27_DDL_STATEMENTS, V27_TO_V28_DDL_STATEMENTS, V28_TO_V29_DDL_STATEMENTS, V29_TO_V30_DDL_STATEMENTS, V30_TO_V31_DDL_STATEMENTS, V31_TO_V32_DDL_STATEMENTS, V32_TO_V33_DDL_STATEMENTS, V33_TO_V34_DDL_STATEMENTS } from './DatabaseSchema';
import {
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
  TABLE_CHARACTERS,
  COLUMN_ID,
  COLUMN_CHAT_ID,
  COLUMN_SEQUENCE_NUMBER,
  COLUMN_CREATED_AT,
  COLUMN_UPDATED_AT,
  COLUMN_LAST_MESSAGE_AT,
  COLUMN_NAME,
  COLUMN_PARENT_BRANCH_ID,
  COLUMN_FORK_MESSAGE_ID,
  COLUMN_IS_ROOT,
  COLUMN_ACTIVE_BRANCH_ID,
  COLUMN_BRANCH_ID,
  COLUMN_POSITION,
  COLUMN_SWIPE_ASSISTANT_MESSAGE_ID,
  COLUMN_CANDIDATE_INDEX,
  COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX,
  COLUMN_SORT_ORDER,
  COLUMN_ROLE,
  COLUMN_SENDER_TYPE
} from './DatabaseConstants';
import { generateUuid } from '../utils/Uuid';
import { nowMillis } from '../utils/Time';

export interface DatabaseMigration {
  readonly fromVersion: number;
  readonly toVersion: number;
  migrate(store: relationalStore.RdbStore): Promise<void>;
}

export interface MigrationPath {
  readonly fromVersion: number;
  readonly toVersion: number;
  readonly steps: DatabaseMigration[];
}

export function buildMigrationPath(
  currentVersion: number,
  targetVersion: number,
  migrations: ReadonlyArray<DatabaseMigration>
): MigrationPath {
  if (currentVersion === targetVersion) {
    return { fromVersion: currentVersion, toVersion: targetVersion, steps: [] };
  }
  if (currentVersion > targetVersion) {
    throw new Error('downgrade not supported');
  }

  const sorted: DatabaseMigration[] = [...migrations].sort(
    (a, b) => a.fromVersion - b.fromVersion
  );

  const steps: DatabaseMigration[] = [];
  let expected: number = currentVersion;
  for (let i = 0; i < sorted.length; i++) {
    const m: DatabaseMigration = sorted[i];
    if (m.fromVersion !== expected) {
      continue;
    }
    if (m.toVersion > targetVersion) {
      continue;
    }
    steps.push(m);
    expected = m.toVersion;
    if (expected === targetVersion) {
      break;
    }
  }

  if (expected !== targetVersion) {
    throw new Error(`no migration path from ${currentVersion} to ${targetVersion}`);
  }

  return { fromVersion: currentVersion, toVersion: targetVersion, steps };
}

export function isMigrationRegistryValid(
  migrations: ReadonlyArray<DatabaseMigration>
): boolean {
  if (migrations.length === 0) {
    return true;
  }
  const seen: Set<string> = new Set();
  for (let i = 0; i < migrations.length; i++) {
    const m: DatabaseMigration = migrations[i];
    if (m.fromVersion >= m.toVersion) {
      return false;
    }
    const key: string = `${m.fromVersion}->${m.toVersion}`;
    if (seen.has(key)) {
      return false;
    }
    seen.add(key);
  }
  return true;
}

/**
 * 创建 v1→v2 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 lorebooks 表
 * 2. 创建 lorebook_entries 表
 * 3. 创建新索引
 * 4. 任一失败全部回滚,不影响旧数据
 */
export function createV1ToV2Migration(): DatabaseMigration {
  return new V1ToV2Migration();
}

class V1ToV2Migration implements DatabaseMigration {
  readonly fromVersion: number = 1;
  readonly toVersion: number = 2;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V1_TO_V2_STATEMENTS.length; i++) {
      await store.executeSql(V1_TO_V2_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v2→v3 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 prompt_presets 表
 * 2. 创建相关索引
 * 3. 任一失败全部回滚,不影响旧数据
 */
export function createV2ToV3Migration(): DatabaseMigration {
  return new V2ToV3Migration();
}

class V2ToV3Migration implements DatabaseMigration {
  readonly fromVersion: number = 2;
  readonly toVersion: number = 3;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V2_TO_V3_STATEMENTS.length; i++) {
      await store.executeSql(V2_TO_V3_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v3→v4 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 message_swipe_groups 表
 * 2. 创建 message_swipe_candidates 表
 * 3. 创建 Swipe 索引
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改现有表结构
 * 6. 不为旧消息批量创建 Swipe 数据
 */
export function createV3ToV4Migration(): DatabaseMigration {
  return new V3ToV4Migration();
}

class V3ToV4Migration implements DatabaseMigration {
  readonly fromVersion: number = 3;
  readonly toVersion: number = 4;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V3_TO_V4_STATEMENTS.length; i++) {
      await store.executeSql(V3_TO_V4_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v4→v5 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 conversation_branches / chat_branch_state /
 *    conversation_branch_messages / conversation_branch_swipe_selections 表
 * 2. 创建相关索引
 * 3. 为每个现有 Chat 创建 Root Branch
 * 4. 为每个 Chat 的全部 Message 创建 BranchMessage Link(按 sequence ASC)
 * 5. 为已有 Swipe Group 创建 Root Branch 的 SwipeSelection
 * 6. 创建 chat_branch_state 指向 Root Branch
 * 7. 任一失败全部回滚,不影响旧数据
 * 8. 不修改 Message / Candidate / Group 数据
 */
export function createV4ToV5Migration(): DatabaseMigration {
  return new V4ToV5Migration();
}

class V4ToV5Migration implements DatabaseMigration {
  readonly fromVersion: number = 4;
  readonly toVersion: number = 5;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. 执行 DDL(建表 + 建索引)
    for (let i = 0; i < V4_TO_V5_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V4_TO_V5_DDL_STATEMENTS[i]);
    }

    // 2. 为每个现有 Chat 创建 Root Branch + Message Links + SwipeSelections + BranchState
    const chatIds: string[] = await this.listAllChatIds(store);
    for (let i = 0; i < chatIds.length; i++) {
      await this.createRootBranchForChat(store, chatIds[i]);
    }
  }

  private async listAllChatIds(store: relationalStore.RdbStore): Promise<string[]> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_CHATS);
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const ids: string[] = [];
    try {
      while (rs.goToNextRow()) {
        const col: number = rs.getColumnIndex(COLUMN_ID);
        if (col >= 0) {
          ids.push(rs.getString(col));
        }
      }
    } finally {
      rs.close();
    }
    return ids;
  }

  private async createRootBranchForChat(
    store: relationalStore.RdbStore,
    chatId: string
  ): Promise<void> {
    const now: number = nowMillis();
    const branchId: string = generateUuid();

    // 插入 Root Branch
    const branchBucket: relationalStore.ValuesBucket = {};
    branchBucket[COLUMN_ID] = branchId;
    branchBucket[COLUMN_CHAT_ID] = chatId;
    branchBucket[COLUMN_PARENT_BRANCH_ID] = null;
    branchBucket[COLUMN_FORK_MESSAGE_ID] = null;
    branchBucket[COLUMN_NAME] = '';
    branchBucket[COLUMN_IS_ROOT] = 1;
    branchBucket[COLUMN_CREATED_AT] = now;
    branchBucket[COLUMN_UPDATED_AT] = now;
    branchBucket[COLUMN_LAST_MESSAGE_AT] = now;
    await store.insert(TABLE_CONVERSATION_BRANCHES, branchBucket);

    // 查询该 Chat 的全部 messages,按 sequence ASC, createdAt ASC, id ASC 排序
    const msgPredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGES);
    msgPredicates.equalTo(COLUMN_CHAT_ID, chatId);
    msgPredicates.orderByAsc(COLUMN_SEQUENCE_NUMBER);
    msgPredicates.orderByAsc(COLUMN_CREATED_AT);
    msgPredicates.orderByAsc(COLUMN_ID);
    const msgRs: relationalStore.ResultSet = await store.query(msgPredicates);
    const messageIds: string[] = [];
    try {
      while (msgRs.goToNextRow()) {
        const col: number = msgRs.getColumnIndex(COLUMN_ID);
        if (col >= 0) {
          messageIds.push(msgRs.getString(col));
        }
      }
    } finally {
      msgRs.close();
    }

    // 为每条 Message 创建 BranchMessage Link
    for (let i = 0; i < messageIds.length; i++) {
      const linkBucket: relationalStore.ValuesBucket = {};
      linkBucket[COLUMN_BRANCH_ID] = branchId;
      linkBucket[COLUMN_ID] = messageIds[i];
      linkBucket[COLUMN_POSITION] = i;
      linkBucket[COLUMN_CREATED_AT] = now;
      await store.insert(TABLE_CONVERSATION_BRANCH_MESSAGES, linkBucket);
    }

    // 查询该 Chat 的已有 Swipe Groups,迁移为 Root Branch 的 SwipeSelection
    const swipePredicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(TABLE_MESSAGE_SWIPE_GROUPS);
    swipePredicates.equalTo(COLUMN_CHAT_ID, chatId);
    const swipeRs: relationalStore.ResultSet = await store.query(swipePredicates);
    const swipeEntries: BranchSwipeMigrationEntry[] = [];
    try {
      while (swipeRs.goToNextRow()) {
        const msgIdCol: number = swipeRs.getColumnIndex(COLUMN_SWIPE_ASSISTANT_MESSAGE_ID);
        const activeIdxCol: number = swipeRs.getColumnIndex(COLUMN_SWIPE_ACTIVE_CANDIDATE_INDEX);
        if (msgIdCol >= 0 && activeIdxCol >= 0) {
          swipeEntries.push({
            assistantMessageId: swipeRs.getString(msgIdCol),
            activeCandidateIndex: swipeRs.getLong(activeIdxCol)
          });
        }
      }
    } finally {
      swipeRs.close();
    }

    for (let i = 0; i < swipeEntries.length; i++) {
      const entry: BranchSwipeMigrationEntry = swipeEntries[i];
      const selBucket: relationalStore.ValuesBucket = {};
      selBucket[COLUMN_BRANCH_ID] = branchId;
      selBucket[COLUMN_SWIPE_ASSISTANT_MESSAGE_ID] = entry.assistantMessageId;
      selBucket[COLUMN_CANDIDATE_INDEX] = entry.activeCandidateIndex;
      selBucket[COLUMN_UPDATED_AT] = now;
      await store.insert(TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS, selBucket);
    }

    // 创建 chat_branch_state 指向 Root Branch
    const stateBucket: relationalStore.ValuesBucket = {};
    stateBucket[COLUMN_CHAT_ID] = chatId;
    stateBucket[COLUMN_ACTIVE_BRANCH_ID] = branchId;
    stateBucket[COLUMN_UPDATED_AT] = now;
    await store.insert(TABLE_CHAT_BRANCH_STATE, stateBucket);
  }
}

interface BranchSwipeMigrationEntry {
  readonly assistantMessageId: string;
  readonly activeCandidateIndex: number;
}

/**
 * 创建 v5→v6 数据库迁移。
 *
 * 事务中执行:
 * 1. 为 characters 表添加 Tavern Card V2 扩展字段
 *    (mes_example / creator_notes / post_history_instructions /
 *     alternate_greetings_json / tags_json / creator / character_version /
 *     extensions_json / character_book_id)
 * 2. 旧角色新字段使用 DEFAULT 值('' / '[]' / '{}'),不强制填写
 * 3. 任一失败全部回滚,不影响旧数据
 * 4. 不修改 Message / Branch / Swipe 等其他表
 */
export function createV5ToV6Migration(): DatabaseMigration {
  return new V5ToV6Migration();
}

class V5ToV6Migration implements DatabaseMigration {
  readonly fromVersion: number = 5;
  readonly toVersion: number = 6;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V5_TO_V6_STATEMENTS.length; i++) {
      await store.executeSql(V5_TO_V6_STATEMENTS[i]);
    }
  }
}

/**
 * v6 → v7 迁移
 *
 * 改动:
 * - characters 表添加 sort_order INTEGER NOT NULL DEFAULT 0
 * - chats 表添加 sort_order INTEGER NOT NULL DEFAULT 0
 * - 回填旧数据:按现有默认排序分配连续 sort_order(0, 1, 2, ...)
 *   - characters: 按 created_at ASC, id ASC
 *   - chats: 按 last_message_at DESC, updated_at DESC, id ASC(保持原 list() 默认顺序)
 *
 * 安全性:
 * - 所有 DDL 用 IF NOT EXISTS / ALTER TABLE ADD COLUMN(重复执行会报错,但事务保证回滚)
 * - 数据回填使用 UPDATE WHERE id = ?,按当前列表顺序逐条更新
 * - 任一失败全部回滚,不影响旧数据
 */
export function createV6ToV7Migration(): DatabaseMigration {
  return new V6ToV7Migration();
}

class V6ToV7Migration implements DatabaseMigration {
  readonly fromVersion: number = 6;
  readonly toVersion: number = 7;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. 执行 DDL(添加 sort_order 字段)
    for (let i = 0; i < V6_TO_V7_STATEMENTS.length; i++) {
      await store.executeSql(V6_TO_V7_STATEMENTS[i]);
    }

    // 2. 回填 characters: 按 created_at ASC, id ASC 分配 sort_order
    await this.backfillSortOrder(store, TABLE_CHARACTERS, true);

    // 3. 回填 chats: 按 last_message_at DESC, updated_at DESC, id ASC 分配 sort_order
    await this.backfillSortOrder(store, TABLE_CHATS, false);
  }

  /**
   * 按现有默认顺序回填 sort_order(0, 1, 2, ...)
   *
   * @param store RDB Store
   * @param tableName 表名
   * @param ascending true=按 created_at ASC(characters),false=按 last_message_at DESC(chats)
   */
  private async backfillSortOrder(
    store: relationalStore.RdbStore,
    tableName: string,
    ascending: boolean
  ): Promise<void> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(tableName);
    if (ascending) {
      predicates.orderByAsc(COLUMN_CREATED_AT);
    } else {
      predicates.orderByDesc(COLUMN_LAST_MESSAGE_AT);
      predicates.orderByDesc(COLUMN_UPDATED_AT);
    }
    predicates.orderByAsc(COLUMN_ID);
    const rs: relationalStore.ResultSet = await store.query(predicates);
    const ids: string[] = [];
    try {
      while (rs.goToNextRow()) {
        const col: number = rs.getColumnIndex(COLUMN_ID);
        if (col >= 0) {
          ids.push(rs.getString(col));
        }
      }
    } finally {
      rs.close();
    }

    // 逐条 UPDATE sort_order
    for (let i = 0; i < ids.length; i++) {
      const updatePredicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(tableName);
      updatePredicates.equalTo(COLUMN_ID, ids[i]);
      const bucket: relationalStore.ValuesBucket = {};
      bucket[COLUMN_SORT_ORDER] = i;
      await store.update(bucket, updatePredicates);
    }
  }
}

/**
 * 创建 v7→v8 数据库迁移。
 *
 * 事务中执行:
 * 1. 创建 chat_memories 表(分支感知长期记忆)
 * 2. 创建相关索引(chat_id / branch_id / branch_id+end_position)
 * 3. 不为旧 Chat 创建 Memory 记录(按需触发总结时才创建)
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改现有 Branch / Message / Swipe 数据
 *
 * 设计:
 * - Memory 表通过 (chat_id, branch_id) 关联现有 Branch
 * - 不强制每个 Chat 都有 Memory,旧 Chat 视为新无 Memory,后续按需总结
 * - 共享祖先记忆通过 inherited_from_memory_id 字段标记,删除 Branch 时不级联删除共享祖先记忆
 */
export function createV7ToV8Migration(): DatabaseMigration {
  return new V7ToV8Migration();
}

class V7ToV8Migration implements DatabaseMigration {
  readonly fromVersion: number = 7;
  readonly toVersion: number = 8;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不创建任何 Memory 数据
    // 旧 Chat 视为"无 Memory",后续按需触发总结
    for (let i = 0; i < V7_TO_V8_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V7_TO_V8_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v8→v9 数据库迁移。
 *
 * 事务中执行:
 * 1. characters 表添加 user_name TEXT NOT NULL DEFAULT ''(角色对用户的称呼)
 * 2. chats 表添加 user_name_override TEXT NOT NULL DEFAULT ''(对话级覆盖)
 * 3. 旧角色 / 旧对话新字段使用空字符串(表示"未设置",运行时回退到全局用户称呼)
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改 Message / Branch / Swipe / Memory 数据
 *
 * 设计:
 * - 留空时由 ChatService.resolveUserName 按优先级回退:
 *   对话覆盖 > 角色设置 > 全局设置 > 'User'
 * - 不直接读取 V2 spec 的 data.user_name,避免覆盖用户已有角色卡数据
 */
export function createV8ToV9Migration(): DatabaseMigration {
  return new V8ToV9Migration();
}

class V8ToV9Migration implements DatabaseMigration {
  readonly fromVersion: number = 8;
  readonly toVersion: number = 9;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V8_TO_V9_STATEMENTS.length; i++) {
      await store.executeSql(V8_TO_V9_STATEMENTS[i]);
    }
  }
}

/**
 * 创建 v9→v10 数据库迁移。
 *
 * 事务中执行:
 * 1. messages 表扩展 sender_type / sender_character_id / scene_id / generation_batch_id
 * 2. 创建相关索引(messages_chat_batch / messages_sender_character)
 * 3. 旧消息 sender_type 默认 'user' (User 消息) 或根据 role 推断
 *    - role='user' → sender_type='user'
 *    - role='assistant' → sender_type='character' (单角色兼容)
 *    - role='system' → sender_type='narrator'
 * 4. 任一失败全部回滚,不影响旧数据
 * 5. 不修改现有 Character / Chat / Branch / Swipe / Memory 数据
 *
 * 设计:
 * - messages.sender_type 默认 'user' 保证旧 User 消息兼容
 * - 旧 Assistant 消息在迁移时回填 sender_type='character' 以保持一致性
 */
export function createV9ToV10Migration(): DatabaseMigration {
  return new V9ToV10Migration();
}

class V9ToV10Migration implements DatabaseMigration {
  readonly fromVersion: number = 9;
  readonly toVersion: number = 10;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. 执行 DDL(添加新字段 + 创建新表 + 创建索引)
    for (let i = 0; i < V9_TO_V10_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V9_TO_V10_DDL_STATEMENTS[i]);
    }

    // 2. 回填旧消息的 sender_type:
    //    role='assistant' → sender_type='character'(单角色兼容)
    //    role='system' → sender_type='narrator'
    //    role='user' 已经是默认 'user',无需更新
    await store.executeSql(
      `UPDATE ${TABLE_MESSAGES} SET ${COLUMN_SENDER_TYPE} = 'character' ` +
      `WHERE ${COLUMN_ROLE} = 'assistant' AND ${COLUMN_SENDER_TYPE} = 'user'`
    );
    await store.executeSql(
      `UPDATE ${TABLE_MESSAGES} SET ${COLUMN_SENDER_TYPE} = 'narrator' ` +
      `WHERE ${COLUMN_ROLE} = 'system' AND ${COLUMN_SENDER_TYPE} = 'user'`
    );
  }
}

/**
 * v10→v11 迁移:
 * - 给 messages 表添加 visibility / recipient_character_ids_json / participant_ids_json / witness_ids_json 字段
 * - 旧消息默认 visibility='public'(由 ALTER 默认值保证)
 * - 不需要回填 recipient/participant/witness(旧消息无这些信息)
 */
export function createV10ToV11Migration(): DatabaseMigration {
  return new V10ToV11Migration();
}

class V10ToV11Migration implements DatabaseMigration {
  readonly fromVersion: number = 10;
  readonly toVersion: number = 11;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V10_TO_V11_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V10_TO_V11_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v11→v12 迁移:
 * - 给 chat_memories 表添加多层记忆字段
 *   (memory_type / title / detail / importance / keywords_json / source_hash / invalidated)
 * - 创建新索引 idx_chat_memories_branch_type(branch_id, memory_type, invalidated)
 * - 旧 Memory 记录默认 memory_type='rolling',随后通过 DATA_MIGRATION 改为 'legacy'
 * - 不修改现有 Memory 的 summary / enabled / range 等字段
 * - 不创建新的 Memory 记录
 */
export function createV11ToV12Migration(): DatabaseMigration {
  return new V11ToV12Migration();
}

class V11ToV12Migration implements DatabaseMigration {
  readonly fromVersion: number = 11;
  readonly toVersion: number = 12;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. DDL: ALTER TABLE + CREATE INDEX
    for (let i = 0; i < V11_TO_V12_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V11_TO_V12_DDL_STATEMENTS[i]);
    }
    // 2. 数据迁移:将旧 Memory 标记为 'legacy' 类型
    //    新安装时表为空,UPDATE 不影响任何行
    for (let i = 0; i < V11_TO_V12_DATA_MIGRATION_STATEMENTS.length; i++) {
      await store.executeSql(V11_TO_V12_DATA_MIGRATION_STATEMENTS[i]);
    }
  }
}

/**
 * v12→v13 迁移(G-DATA-1A 多人聊天数据底座):
 * - ALTER chats 表添加 conversation_mode TEXT NOT NULL DEFAULT 'single'
 *   (旧 Chat 统一视为 Single,不从 character_id 反推模式)
 * - 创建 chat_participants 表(多人聊天参与者关系)
 * - 创建 idx_chat_participants_chat_order 索引
 *
 * 安全性:
 * - 所有 DDL 用 IF NOT EXISTS / ALTER TABLE ADD COLUMN
 * - 不重建 chats / messages / characters 等现有表
 * - 不删除任何现有数据
 * - 不为旧 Chat 创建 participant 行(旧 Chat 全部为 Single,无参与者)
 * - 任一失败由 DbHelper 事务回滚,保持 v12
 */
export function createV12ToV13Migration(): DatabaseMigration {
  return new V12ToV13Migration();
}

class V12ToV13Migration implements DatabaseMigration {
  readonly fromVersion: number = 12;
  readonly toVersion: number = 13;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V12_TO_V13_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V12_TO_V13_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v13→v14 迁移(G-CONTROL-2A 公开消息回复目标字段):
 * 1. DDL:ALTER messages 表添加 reply_target_character_ids_json TEXT 字段
 * 2. 数据迁移:将 G-CONTROL-1 误写入 recipient_character_ids_json 的
 *    公开用户消息回复目标复制到 reply_target_character_ids_json,
 *    然后清空 recipient_character_ids_json(恢复私聊语义)
 *
 * 安全性:
 * - 所有 DDL 用 ALTER TABLE ADD COLUMN
 * - 不重建 messages 表
 * - 不删除任何现有数据
 * - 数据迁移用条件 UPDATE,只影响 user+public+recipient 非空的行
 * - 私聊消息(visibility='private')的 recipient 不动
 * - 任一失败由 DbHelper 事务回滚,保持 v13
 */
export function createV13ToV14Migration(): DatabaseMigration {
  return new V13ToV14Migration();
}

class V13ToV14Migration implements DatabaseMigration {
  readonly fromVersion: number = 13;
  readonly toVersion: number = 14;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 1. DDL:ALTER TABLE 添加新字段
    for (let i = 0; i < V13_TO_V14_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V13_TO_V14_DDL_STATEMENTS[i]);
    }
    // 2. 数据迁移:G-CONTROL-1 旧单角色目标数据迁移
    for (let i = 0; i < V13_TO_V14_DATA_MIGRATION_STATEMENTS.length; i++) {
      await store.executeSql(V13_TO_V14_DATA_MIGRATION_STATEMENTS[i]);
    }
  }
}

/**
 * v14→v15 迁移(W-DATA-1A 世界模式数据域):
 * 1. 创建 5 张 world_* 表(worlds / world_locations / world_location_edges /
 *    world_character_instances / world_events)
 * 2. 创建相关索引(status / updated_at / world_id / from_location_id /
 *    to_location_id / is_enabled / character_id / current_location_id /
 *    world_id+is_active / world_id+occurred_at / event_type /
 *    source_character_instance_id / source_scene_id)
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表(characters / chats / messages / chat_participants 等)
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 14
 * - 失败不写入 V15
 *
 * 本阶段不实现:
 * - WorldStateService
 * - 世界 UI / 地点节点图 / 角色移动 / 世界场景 / 世界消息 / 世界 Prompt
 * - 关系 / 记忆 / AI 候选地点 / AI 世界 Builder
 */
export function createV14ToV15Migration(): DatabaseMigration {
  return new V14ToV15Migration();
}

class V14ToV15Migration implements DatabaseMigration {
  readonly fromVersion: number = 14;
  readonly toVersion: number = 15;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不修改任何现有表,不迁移任何现有数据
    for (let i = 0; i < V14_TO_V15_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V14_TO_V15_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v15→v16 迁移(W-SCENE-1A 世界场景与场景消息):
 * 1. 创建 2 张 world_scene* 表(world_scenes / world_scene_messages)
 * 2. 创建相关索引(world_id / location_id / world_id+status / world_id+location_id /
 *    world_id+location_id+status / started_at / scene_id / scene_id+sequence_number /
 *    scene_id+status / sender_character_instance_id / generation_batch_id /
 *    visibility / created_at)
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表(characters / chats / messages / chat_participants / world_* 等)
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 15
 * - 失败不写入 V16
 *
 * 本阶段不实现:
 * - WorldSceneService
 * - 场景 UI / 场景消息 UI / 手动发送消息 / 模型对话
 * - WorldRuntimeService / WorldRuntimeRegistry / WorldPromptAssembler
 * - 角色发言顺序 / 流式模型调用 / 停止、重试
 * - Prompt 可见性过滤 / 世界记忆 / 方向性关系 / 地点知识
 * - AI 候选地点 / AI 世界 Builder
 */
export function createV15ToV16Migration(): DatabaseMigration {
  return new V15ToV16Migration();
}

class V15ToV16Migration implements DatabaseMigration {
  readonly fromVersion: number = 15;
  readonly toVersion: number = 16;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不修改任何现有表,不迁移任何现有数据
    for (let i = 0; i < V15_TO_V16_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V15_TO_V16_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v16→v17 迁移(W-MEMORY-1A 世界角色实例独立长期记忆):
 * 1. 创建 1 张 world_character_memories 表
 * 2. 创建相关索引(world_id / character_instance_id / instance+status /
 *    instance+status+updated_at / memory_type / origin_type /
 *    source_scene_id / source_message_id / source_location_id /
 *    occurred_at / importance)
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表(characters / chats / messages / chat_participants /
 *   chat_memories / branches / world_* 等)
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 16
 * - 失败不写入 V17
 *
 * 本阶段不实现:
 * - AI 自动提取记忆 / 模型总结 / 场景结束自动生成记忆
 * - 每条消息自动写记忆 / Prompt 注入 / 记忆检索排序
 * - 向量数据库 / Embedding / 关系系统 / 地点知识 / 共享记忆
 */
export function createV16ToV17Migration(): DatabaseMigration {
  return new V16ToV17Migration();
}

class V16ToV17Migration implements DatabaseMigration {
  readonly fromVersion: number = 16;
  readonly toVersion: number = 17;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不修改任何现有表,不迁移任何现有数据
    for (let i = 0; i < V16_TO_V17_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V16_TO_V17_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v17→v18 迁移(G-MEMORY-1A 多人聊天每角色独立手动记忆):
 * 1. 创建 1 张 group_character_memories 表
 * 2. 创建相关索引(group_conversation_id / character_id /
 *    group+character / group+character+status / origin_type /
 *    source_message_id / source_round_id / source_hash / updated_at)
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表(characters / chats / messages / chat_participants /
 *   chat_memories / conversation_branches / world_* 等)
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 17
 * - 失败不写入 V18
 *
 * 本阶段不实现:
 * - AI 自动提取记忆 / 模型总结 / 轮次结束自动生成记忆
 * - 把记忆注入 GroupPromptAssembler
 * - 交互记忆来源有效性管理 / 自动失效
 * - 复杂唯一索引实现交互记忆去重(留给 G-MEMORY-1B)
 */
export function createV17ToV18Migration(): DatabaseMigration {
  return new V17ToV18Migration();
}

class V17ToV18Migration implements DatabaseMigration {
  readonly fromVersion: number = 17;
  readonly toVersion: number = 18;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不修改任何现有表,不迁移任何现有数据
    for (let i = 0; i < V17_TO_V18_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V17_TO_V18_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v18→v19 迁移(G-MEMORY-AUTO-1B 多人角色定向关系记忆):
 * 1. 创建 1 张 group_character_relationship_memories 表
 * 2. 创建相关索引(group / owner / owner_target / owner_status / target /
 *    source_hash / updated_at)
 * 3. 表上 UNIQUE(group_conversation_id, owner_character_id, target_type, target_id)
 *    保证每个方向对象只保留一条当前关系摘要
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表(characters / chats / messages / chat_participants /
 *   chat_memories / conversation_branches / world_* / group_character_memories 等)
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 18
 * - 失败不写入 V19
 *
 * 本阶段不实现:
 * - 自动总结触发 / 后台队列 / Prompt 注入
 * - 关系版本历史 / 复杂关系数值系统 / 好感度 / 阵营 / 关系图谱
 * - 删除消息后自动失效 / 重新生成后自动失效
 */
export function createV18ToV19Migration(): DatabaseMigration {
  return new V18ToV19Migration();
}

class V18ToV19Migration implements DatabaseMigration {
  readonly fromVersion: number = 18;
  readonly toVersion: number = 19;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不修改任何现有表,不迁移任何现有数据
    for (let i = 0; i < V18_TO_V19_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V18_TO_V19_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v19→v20 迁移(W1A-WORLD-CORE-STORE 世界模式玩家档案与会话):
 * 1. 创建 2 张新表(world_player_profiles / world_conversation_sessions)
 * 2. 创建相关索引(world_id / scene_id / scene_id+sequence_number / world_id)
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表(characters / chats / messages / chat_participants /
 *   chat_memories / conversation_branches / world_* / group_character_* 等)
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 19
 * - 失败不写入 V20
 *
 * 约束说明:
 * - world_player_profiles: UNIQUE(world_id) 保证每个世界只有一个玩家档案
 * - world_conversation_sessions: UNIQUE(scene_id, sequence_number) 保证场景内会话序号唯一
 */
export function createV19ToV20Migration(): DatabaseMigration {
  return new V19ToV20Migration();
}

class V19ToV20Migration implements DatabaseMigration {
  readonly fromVersion: number = 19;
  readonly toVersion: number = 20;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    // 仅执行 DDL(建表 + 建索引),不修改任何现有表,不迁移任何现有数据
    for (let i = 0; i < V19_TO_V20_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V19_TO_V20_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v20→v21 迁移(W1B1-WORLD-SESSION-STORAGE-ADAPTER):
 * 1. ALTER world_scenes 添加 title TEXT NOT NULL DEFAULT ''
 * 2. ALTER world_scene_messages 添加 session_id TEXT / location_id TEXT
 * 3. 创建 3 个新索引(session_id / session_id+sequence_number / location_id)
 *
 * 安全性:
 * - ALTER TABLE ADD COLUMN 不重建表,不删除任何数据
 * - 旧行 title 默认 '', session_id / location_id 默认 NULL
 * - 不回填任何旧数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 20
 */
export function createV20ToV21Migration(): DatabaseMigration {
  return new V20ToV21Migration();
}

class V20ToV21Migration implements DatabaseMigration {
  readonly fromVersion: number = 20;
  readonly toVersion: number = 21;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V20_TO_V21_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V20_TO_V21_DDL_STATEMENTS[i]);
    }
  }
}

export function createV21ToV22Migration(): DatabaseMigration {
  return new V21ToV22Migration();
}

class V21ToV22Migration implements DatabaseMigration {
  readonly fromVersion: number = 21;
  readonly toVersion: number = 22;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V21_TO_V22_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V21_TO_V22_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v22→v23 迁移(W2A1-WORLD-PLAYER-CHARACTER-DOMAIN 世界角色实例领域增强):
 * 1. ALTER world_character_instances 添加 current_goal TEXT NOT NULL DEFAULT ''
 * 2. ALTER world_character_instances 添加 map_icon_style TEXT
 * 3. ALTER world_player_profiles 添加 persona TEXT NOT NULL DEFAULT ''
 * 4. ALTER world_player_profiles 添加 public_identity TEXT NOT NULL DEFAULT ''
 * 5. ALTER world_player_profiles 添加 private_identity TEXT NOT NULL DEFAULT ''
 * 6. ALTER world_player_profiles 添加 current_location_id TEXT
 *
 * 安全性:
 * - ALTER TABLE ADD COLUMN 不重建表,不删除任何数据
 * - 旧行新字段均有 DEFAULT 值,不影响现有数据
 * - 不回填任何旧数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 22
 */
export function createV22ToV23Migration(): DatabaseMigration {
  return new V22ToV23Migration();
}

class V22ToV23Migration implements DatabaseMigration {
  readonly fromVersion: number = 22;
  readonly toVersion: number = 23;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V22_TO_V23_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V22_TO_V23_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v23→v24 迁移(W4A-WORLD-MOVEMENT-CORE-LOCATION-HISTORY 世界角色地点历史):
 * 1. 创建 world_character_location_history 表
 * 2. 创建相关索引(world_id / character_instance_id / instance+created_at / transition_kind / created_at)
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 23
 */
export function createV23ToV24Migration(): DatabaseMigration {
  return new V23ToV24Migration();
}

class V23ToV24Migration implements DatabaseMigration {
  readonly fromVersion: number = 23;
  readonly toVersion: number = 24;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V23_TO_V24_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V23_TO_V24_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v24→v25 迁移(W5A1-WORLD-SESSION-SUMMARY-STORE 世界会话摘要存储):
 * 1. 创建 world_session_summaries 表
 * 2. 创建相关索引(world_id / scene_id / session_id / session_id+version / created_at)
 * 3. UNIQUE(session_id, version) 约束保证版本号唯一
 *
 * 安全性:
 * - 所有 DDL 用 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
 * - 不修改任何现有表
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 24
 */
export function createV24ToV25Migration(): DatabaseMigration {
  return new V24ToV25Migration();
}

class V24ToV25Migration implements DatabaseMigration {
  readonly fromVersion: number = 24;
  readonly toVersion: number = 25;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V24_TO_V25_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V24_TO_V25_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v25→v26 迁移(W5A2-PROVENANCE 世界会话摘要来源追溯):
 * 1. ALTER TABLE world_session_summaries ADD COLUMN provider_id TEXT
 * 2. ALTER TABLE world_session_summaries ADD COLUMN model_id TEXT
 *
 * 安全性:
 * - 仅 ADD COLUMN,不修改现有列定义
 * - 不迁移任何现有数据(V25 历史行保持 NULL)
 * - 新列为 nullable,不影响现有查询
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 25
 */
export function createV25ToV26Migration(): DatabaseMigration {
  return new V25ToV26Migration();
}

class V25ToV26Migration implements DatabaseMigration {
  readonly fromVersion: number = 25;
  readonly toVersion: number = 26;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V25_TO_V26_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V25_TO_V26_DDL_STATEMENTS[i]);
    }
  }
}

export function createV26ToV27Migration(): DatabaseMigration {
  return new V26ToV27Migration();
}

class V26ToV27Migration implements DatabaseMigration {
  readonly fromVersion: number = 26;
  readonly toVersion: number = 27;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V26_TO_V27_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V26_TO_V27_DDL_STATEMENTS[i]);
    }
  }
}

export function createV27ToV28Migration(): DatabaseMigration {
  return new V27ToV28Migration();
}

class V27ToV28Migration implements DatabaseMigration {
  readonly fromVersion: number = 27;
  readonly toVersion: number = 28;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V27_TO_V28_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V27_TO_V28_DDL_STATEMENTS[i]);
    }
  }
}

export function createV28ToV29Migration(): DatabaseMigration {
  return new V28ToV29Migration();
}

class V28ToV29Migration implements DatabaseMigration {
  readonly fromVersion: number = 28;
  readonly toVersion: number = 29;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V28_TO_V29_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V28_TO_V29_DDL_STATEMENTS[i]);
    }
  }
}

export function createV29ToV30Migration(): DatabaseMigration {
  return new V29ToV30Migration();
}

class V29ToV30Migration implements DatabaseMigration {
  readonly fromVersion: number = 29;
  readonly toVersion: number = 30;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V29_TO_V30_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V29_TO_V30_DDL_STATEMENTS[i]);
    }
  }
}

export function createV30ToV31Migration(): DatabaseMigration {
  return new V30ToV31Migration();
}

class V30ToV31Migration implements DatabaseMigration {
  readonly fromVersion: number = 30;
  readonly toVersion: number = 31;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V30_TO_V31_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V30_TO_V31_DDL_STATEMENTS[i]);
    }
  }
}

export function createV31ToV32Migration(): DatabaseMigration {
  return new V31ToV32Migration();
}

class V31ToV32Migration implements DatabaseMigration {
  readonly fromVersion: number = 31;
  readonly toVersion: number = 32;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V31_TO_V32_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V31_TO_V32_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v32→v33 迁移(W2A3-WORLD-MAP-BACKGROUND 世界地图背景图):
 * 1. 创建 world_map_backgrounds 表
 *
 * 安全性:
 * - 仅 CREATE TABLE IF NOT EXISTS,不修改任何现有表
 * - 一个世界最多一张背景图(UNIQUE world_id)
 * - 不迁移任何现有数据
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 32
 */
export function createV32ToV33Migration(): DatabaseMigration {
  return new V32ToV33Migration();
}

class V32ToV33Migration implements DatabaseMigration {
  readonly fromVersion: number = 32;
  readonly toVersion: number = 33;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V32_TO_V33_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V32_TO_V33_DDL_STATEMENTS[i]);
    }
  }
}

/**
 * v33→v34 迁移(CHAT-STATUS-1A 聊天角色状态配置):
 * 1. ALTER chats 表添加 status_config_json TEXT NOT NULL DEFAULT ''
 *
 * 安全性:
 * - 仅 ALTER TABLE ADD COLUMN,不重建表、不删除任何数据
 * - 旧行默认空字符串(表示无状态配置)
 * - 新安装时列已存在于 CREATE_CHATS_TABLE,不会重复执行
 * - 任一语句失败由 DbHelper 事务回滚,数据库版本保持 33
 */
export function createV33ToV34Migration(): DatabaseMigration {
  return new V33ToV34Migration();
}

class V33ToV34Migration implements DatabaseMigration {
  readonly fromVersion: number = 33;
  readonly toVersion: number = 34;

  async migrate(store: relationalStore.RdbStore): Promise<void> {
    for (let i = 0; i < V33_TO_V34_DDL_STATEMENTS.length; i++) {
      await store.executeSql(V33_TO_V34_DDL_STATEMENTS[i]);
    }
  }
}
