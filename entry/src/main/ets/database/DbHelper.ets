/**
 * DbHelper
 *
 * 职责:
 * - 初始化 RDB(幂等,允许并发,失败可重试)
 * - 创建 V1 Schema
 * - 执行版本迁移(逐版本,事务包裹)
 * - 提供事务执行入口
 * - 关闭数据库(幂等)
 * - 关闭后允许重新初始化
 *
 * 不负责:
 * - Repository 层 SQL 拼接
 * - 业务模型转换
 * - 缓存
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../utils/Logger';
import {
  DATABASE_NAME,
  DATABASE_VERSION
} from './DatabaseConstants';
import { getSchemaStatements, getCreateTableStatements, getCreateIndexStatements } from './DatabaseSchema';
import {
  buildMigrationPath,
  createV1ToV2Migration,
  createV2ToV3Migration,
  createV3ToV4Migration,
  createV4ToV5Migration,
  createV5ToV6Migration,
  createV6ToV7Migration,
  createV7ToV8Migration,
  createV8ToV9Migration,
  createV9ToV10Migration,
  createV10ToV11Migration,
  createV11ToV12Migration,
  createV12ToV13Migration,
  createV13ToV14Migration,
  createV14ToV15Migration,
  createV15ToV16Migration,
  createV16ToV17Migration,
  createV17ToV18Migration,
  createV18ToV19Migration,
  createV19ToV20Migration,
  createV20ToV21Migration,
  createV21ToV22Migration,
  createV22ToV23Migration,
  createV23ToV24Migration,
  createV24ToV25Migration,
  createV25ToV26Migration,
  createV26ToV27Migration,
  createV27ToV28Migration,
  createV28ToV29Migration,
  createV29ToV30Migration,
  createV30ToV31Migration,
  createV31ToV32Migration,
  createV32ToV33Migration,
  createV33ToV34Migration,
  DatabaseMigration,
  MigrationPath
} from './DatabaseMigration';
import { DatabaseError } from '../models/DatabaseError';

const LOG_TAG: string = 'DbHelper';

/**
 * 事务阶段诊断标识。
 * 用于 runInTransaction 在 begin/commit/rollback 时输出安全日志,
 * 不携带 chatId / messageId / SQL / 正文等敏感信息。
 */
export type TransactionOperation =
  | 'session_create'
  | 'session_create_with_first_message'
  | 'message_append'
  | 'message_pair_append'
  | 'message_replace_after_user'
  | 'session_delete'
  | 'swipe_ensure_state'
  | 'swipe_normalize_candidate'
  | 'swipe_materialize_candidate'
  | 'swipe_update_active'
  | 'branch_fork'
  | 'branch_ensure_root'
  | 'branch_append_message'
  | 'branch_update_swipe_selection'
  | 'chat_fork'
  | 'character_swap_sort_order'
  | 'chat_swap_sort_order'
  | 'v5_migration'
  | 'v5_integrity_repair'
  | 'chat_archive_import'
  | 'group_conversation_create'
  | 'group_conversation_replace_participants'
  | 'group_conversation_update_enabled'
  | 'group_conversation_add_participant'
  | 'group_conversation_remove_participant'
  | 'group_conversation_delete'
  | 'group_message_append_user'
  | 'world_create'
  | 'world_update'
  | 'world_archive'
  | 'world_delete'
  | 'world_location_create'
  | 'world_location_update'
  | 'world_location_archive'
  | 'world_location_delete'
  | 'world_edge_create'
  | 'world_edge_update'
  | 'world_edge_delete'
  | 'world_character_add'
  | 'world_character_remove'
  | 'world_character_activate'
  | 'world_character_move'
  | 'world_character_place'
  | 'world_character_place_at'
  | 'world_character_unplace'
  | 'world_player_profile_update'
  | 'world_scene_start'
  | 'world_scene_end'
  | 'world_scene_message_add'
  | 'world_memory_create'
  | 'world_memory_update'
  | 'world_memory_archive'
  | 'world_memory_delete'
  | 'world_session_start'
  | 'world_session_continue'
  | 'world_session_end'
  | 'world_scene_launch'
  | 'world_user_msg'
  | 'world_char_placeholder'
  | 'world_map_placement_upsert'
  | 'world_map_placement_delete'
  | 'world_map_background_upsert'
  | 'world_map_background_delete'
  | 'world_character_travel'
  | 'world_character_location_history_delete'
  | 'world_session_summary_persist'
  | 'world_character_memory_entry_persist'
  | 'world_event_extraction_persist'
  | 'world_known_event_derive'
  | 'world_known_event_reject'
  | 'world_directional_relationship_persist'
  | 'world_directional_relationship_reject'
  | 'world_post_process_run_begin'
  | 'world_post_process_run_finalize'
  | 'world_post_process_run_mark'
  | 'group_character_memory_create'
  | 'group_character_memory_update'
  | 'group_character_memory_archive'
  | 'group_character_memory_delete'
  | 'group_character_memory_delete_by_group'
  | 'group_auto_summary_replace'
  | 'unknown';

export class DbHelper {
  private readonly databaseName: string;
  private readonly migrations: ReadonlyArray<DatabaseMigration>;

  private store: relationalStore.RdbStore | null = null;
  private initializing: Promise<relationalStore.RdbStore> | null = null;
  private closed: boolean = false;
  /**
   * 当前事务深度。用于检测嵌套事务。
   * HarmonyOS RDB 不支持可靠的事务嵌套,生产路径必须保持 depth=0 时才能 begin。
   * - runInTransaction begin 时 +1
   * - commit/rollback 后 -1
   * - 若 begin 时 depth > 0,抛 NestedTransaction 错误
   */
  private transactionDepth: number = 0;

  constructor(
    databaseName: string = DATABASE_NAME,
    migrations: ReadonlyArray<DatabaseMigration> = [createV1ToV2Migration(), createV2ToV3Migration(), createV3ToV4Migration(), createV4ToV5Migration(), createV5ToV6Migration(), createV6ToV7Migration(), createV7ToV8Migration(), createV8ToV9Migration(), createV9ToV10Migration(), createV10ToV11Migration(), createV11ToV12Migration(), createV12ToV13Migration(), createV13ToV14Migration(), createV14ToV15Migration(), createV15ToV16Migration(), createV16ToV17Migration(), createV17ToV18Migration(), createV18ToV19Migration(), createV19ToV20Migration(), createV20ToV21Migration(), createV21ToV22Migration(), createV22ToV23Migration(), createV23ToV24Migration(), createV24ToV25Migration(), createV25ToV26Migration(), createV26ToV27Migration(), createV27ToV28Migration(), createV28ToV29Migration(), createV29ToV30Migration(), createV30ToV31Migration(), createV31ToV32Migration(), createV32ToV33Migration(), createV33ToV34Migration()]
  ) {
    this.databaseName = databaseName;
    this.migrations = migrations;
  }

  /**
   * 当前事务深度(主要用于测试断言)。
   * 生产代码不应依赖此值进行逻辑分支。
   */
  getTransactionDepth(): number {
    return this.transactionDepth;
  }

  /**
   * 是否正处于事务中(用于测试断言嵌套事务防护)。
   */
  isInTransaction(): boolean {
    return this.transactionDepth > 0;
  }

  isInitialized(): boolean {
    return this.store !== null && !this.closed;
  }

  async initialize(context: common.Context): Promise<void> {
    if (this.store !== null && !this.closed) {
      return;
    }
    if (this.initializing !== null) {
      await this.initializing;
      return;
    }
    if (this.closed) {
      this.closed = false;
    }

    const initPromise: Promise<relationalStore.RdbStore> = this.openAndMigrate(context);
    this.initializing = initPromise;

    try {
      const opened: relationalStore.RdbStore = await initPromise;
      this.store = opened;
    } catch (err) {
      this.initializing = null;
      const cause: string = this.extractCauseMessage(err);
      Logger.error(LOG_TAG, `initialize failed cause=${cause}`);
      // W-MEMORY-1A-FIX: 保留原始 DatabaseError 类型信息(如 UnsupportedVersion),
      // 不无脑包装为 openFailed,避免上层无法识别高版本不兼容错误而触发重建兜底。
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.openFailed(cause);
    } finally {
      this.initializing = null;
    }
  }

  getStore(): relationalStore.RdbStore {
    if (this.closed) {
      throw DatabaseError.closed('getStore after close');
    }
    if (this.store === null) {
      throw DatabaseError.notInitialized('getStore before initialize');
    }
    return this.store;
  }

  async getVersion(): Promise<number> {
    const store: relationalStore.RdbStore = this.getStore();
    return await this.readUserVersion(store);
  }

  /**
   * 在事务中执行 action。
   *
   * 事务所有权规则:
   * - 最外层 PersistenceService 是唯一事务所有者
   * - Repository 和 WithStore 方法不得调用此方法
   * - 若检测到嵌套事务(depth > 0),抛 NestedTransaction 错误
   *
   * 诊断规则:
   * - 在 begin/commit/rollback 时输出安全日志(仅 operation 标识)
   * - 不记录 chatId / messageId / SQL / 正文 / BusinessError 原始 message
   *
   * @param action 事务内执行的操作(接收同一 store)
   * @param operation 安全操作标识(用于日志,默认 'unknown')
   */
  async runInTransaction(
    action: (store: relationalStore.RdbStore) => Promise<void>,
    operation: TransactionOperation = 'unknown'
  ): Promise<void> {
    const store: relationalStore.RdbStore = this.getStore();
    if (this.transactionDepth > 0) {
      // 嵌套事务防护:HarmonyOS RDB 不支持可靠嵌套,直接拒绝
      Logger.error(LOG_TAG, `nested transaction rejected operation=${operation}`);
      throw DatabaseError.transactionFailed(
        `nested transaction not allowed operation=${operation}`
      );
    }
    this.transactionDepth = 1;
    try {
      store.beginTransaction();
      await action(store);
      store.commit();
    } catch (err) {
      const cause: string = this.extractCauseMessage(err);
      Logger.error(LOG_TAG, `transaction rollback operation=${operation} cause=${cause}`);
      try {
        store.rollBack();
      } catch (rollbackErr) {
        const rollbackCause: string = this.extractCauseMessage(rollbackErr);
        Logger.error(LOG_TAG, `rollback failed operation=${operation} cause=${rollbackCause}`);
        throw DatabaseError.transactionFailed(
          `rollback failed operation=${operation}`
        );
      }
      // 保留原始 DatabaseError 类型信息,不无脑包装为 transactionFailed
      if (err instanceof DatabaseError) {
        throw err;
      }
      throw DatabaseError.transactionFailed(`operation=${operation}`);
    } finally {
      this.transactionDepth = 0;
    }
  }

  async close(): Promise<void> {
    if (this.store === null && this.initializing === null) {
      return;
    }
    if (this.initializing !== null) {
      try {
        await this.initializing;
      } catch (err) {
        Logger.warn(LOG_TAG, 'close: pending init failed, ignoring');
      }
    }
    if (this.store !== null) {
      try {
        await this.store.close();
      } catch (err) {
        const cause: string = this.extractCauseMessage(err);
        Logger.warn(LOG_TAG, `close store failed cause=${cause}`);
      }
    }
    this.store = null;
    this.initializing = null;
    this.closed = true;
  }

  private async openAndMigrate(context: common.Context): Promise<relationalStore.RdbStore> {
    const config: relationalStore.StoreConfig = {
      name: this.databaseName,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore =
      await relationalStore.getRdbStore(context, config);
    const currentVersion: number = await this.readUserVersion(store);
    if (currentVersion > DATABASE_VERSION) {
      // W-MEMORY-1A-FIX: 未知高版本无损拒绝保护。
      // 高版本数据库可能由未来版本应用创建,直接删除会清空用户数据。
      // 必须明确拒绝打开/迁移,且:
      // - 不调用 deleteRdbStore
      // - 不删除数据库文件
      // - 不执行 DROP TABLE / CREATE TABLE
      // - 不执行迁移
      // - 不修改 PRAGMA user_version
      // 仅关闭本次打开的 store 句柄(关闭句柄不删除文件),抛出 UnsupportedVersion 错误。
      Logger.error(LOG_TAG,
        `Database version unsupported: currentVersion=${currentVersion} supportedVersion=${DATABASE_VERSION}`);
      try {
        store.close();
      } catch (closeErr) {
        // 关闭句柄失败不影响拒绝语义,记录后继续抛出 UnsupportedVersion
        Logger.warn(LOG_TAG,
          `close store before unsupported version rejection failed cause=${this.extractCauseMessage(closeErr)}`);
      }
      throw DatabaseError.unsupportedVersion(
        `currentVersion=${currentVersion} supportedVersion=${DATABASE_VERSION}`
      );
    }
    if (currentVersion === 0) {
      await this.createFreshSchema(store);
      await this.writeUserVersion(store, DATABASE_VERSION);
      return store;
    }
    if (currentVersion < DATABASE_VERSION) {
      await this.runMigrations(store, currentVersion, DATABASE_VERSION);
      return store;
    }
    await this.ensureSchemaExists(store);
    return store;
  }

  private async createFreshSchema(store: relationalStore.RdbStore): Promise<void> {
    const statements: string[] = getSchemaStatements(DATABASE_VERSION);
    try {
      for (let i = 0; i < statements.length; i++) {
        await store.executeSql(statements[i]);
      }
    } catch (err) {
      throw DatabaseError.schemaFailed(this.extractCauseMessage(err));
    }
  }

  private async ensureSchemaExists(store: relationalStore.RdbStore): Promise<void> {
    // T-4.2E-Closeout: 只执行幂等的 CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS,
    // 不执行 ALTER TABLE(getSchemaStatements 包含 ALTER,列已存在时会报 code=14800021)
    const tables: string[] = getCreateTableStatements();
    const indexes: string[] = getCreateIndexStatements();
    const statements: string[] = [...tables, ...indexes];
    try {
      for (let i = 0; i < statements.length; i++) {
        await store.executeSql(statements[i]);
      }
    } catch (err) {
      throw DatabaseError.schemaFailed(this.extractCauseMessage(err));
    }
  }

  private async runMigrations(
    store: relationalStore.RdbStore,
    fromVersion: number,
    toVersion: number
  ): Promise<void> {
    if (fromVersion === toVersion) {
      return;
    }
    const path: MigrationPath =
      buildMigrationPath(fromVersion, toVersion, this.migrations);
    for (let i = 0; i < path.steps.length; i++) {
      const step: DatabaseMigration = path.steps[i];
      try {
        store.beginTransaction();
        await step.migrate(store);
        store.commit();
      } catch (err) {
        try {
          store.rollBack();
        } catch (rollbackErr) {
          Logger.error(
            LOG_TAG,
            `migration rollback failed cause=${this.extractCauseMessage(rollbackErr)}`
          );
        }
        throw DatabaseError.migrationFailed(
          `step ${step.fromVersion}->${step.toVersion}: ${this.extractCauseMessage(err)}`
        );
      }
    }
    await this.writeUserVersion(store, toVersion);
  }

  private async readUserVersion(store: relationalStore.RdbStore): Promise<number> {
    try {
      const result: relationalStore.ResultSet = await store.querySql('PRAGMA user_version');
      let version: number = 0;
      if (result.goToFirstRow()) {
        const columnIndex: number = result.getColumnIndex('user_version');
        if (columnIndex >= 0) {
          version = result.getLong(columnIndex);
        }
      }
      result.close();
      return version;
    } catch (err) {
      throw DatabaseError.queryFailed(this.extractCauseMessage(err));
    }
  }

  private async writeUserVersion(
    store: relationalStore.RdbStore,
    version: number
  ): Promise<void> {
    try {
      await store.executeSql(`PRAGMA user_version = ${version}`);
    } catch (err) {
      throw DatabaseError.schemaFailed(this.extractCauseMessage(err));
    }
  }

  private extractCauseMessage(err: Error | BusinessError | Object): string {
    if (err === null || err === undefined) {
      return '';
    }
    if (typeof err === 'object') {
      const obj: Object = err as Object;
      const code: Object | undefined = Reflect.has(obj, 'code')
        ? (obj as Record<string, Object>).code
        : undefined;
      const msg: Object | undefined = Reflect.has(obj, 'message')
        ? (obj as Record<string, Object>).message
        : undefined;
      // DatabaseError 携带的底层 causeMessage(脱敏后的原始错误)
      const causeMsg: Object | undefined = Reflect.has(obj, 'causeMessage')
        ? (obj as Record<string, Object>).causeMessage
        : undefined;
      if (typeof code === 'number' && typeof msg === 'string') {
        const causeStr: string = typeof causeMsg === 'string' && causeMsg.length > 0
          ? ` cause=${causeMsg}`
          : '';
        return `code=${code} message=${msg}${causeStr}`;
      }
      if (typeof msg === 'string') {
        const causeStr: string = typeof causeMsg === 'string' && causeMsg.length > 0
          ? ` cause=${causeMsg}`
          : '';
        return msg.length > 0 ? `${msg}${causeStr}` : (causeStr.length > 0 ? causeStr : msg);
      }
    }
    return 'unknown error';
  }
}

interface BusinessError {
  code: number;
  message: string;
}
