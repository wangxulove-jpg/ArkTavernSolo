/**
 * SyncDataImporter WebDAV 同步数据导入服务
 *
 * 职责:
 * - 校验 JSON 备份载荷格式与版本兼容性
 * - 以 "latest-wins" 冲突解决策略导入表行(远程 updated_at > 本地则替换)
 * - 导入 Preferences 键值对
 * - 导入文件(从 base64 解码写回沙箱)
 * - 解密并导入 API Key
 *
 * 依赖:
 * - DbHelper(事务 + executeSql)
 * - AppPreferences(键值写入)
 * - ProviderKeyStore(密钥写入)
 * - CryptoHelper(AES-256-GCM 解密)
 * - DatabaseConstants(版本号)
 * - Logger(脱敏日志)
 *
 * 日志规则:
 * - 只记录表名、行数、操作类型、成功/失败、错误码
 * - 严禁输出 API Key、密钥明文、消息正文、完整 SQL
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import util from '@ohos.util';
import { DbHelper } from '../../database/DbHelper';
import { AppPreferences } from '../../storage/AppPreferences';
import { ProviderKeyStore } from '../../storage/ProviderKeyStore';
import { CryptoHelper } from '../../utils/CryptoHelper';
import { DATABASE_VERSION } from '../../database/DatabaseConstants';
import { Logger } from '../../utils/Logger';
import { SyncDataExporter } from './SyncDataExporter';

const LOG_TAG: string = 'SyncDataImporter';
const EXPECTED_FORMAT: string = 'arktavern_sync_v1';
const COLUMN_UPDATED_AT: string = 'updated_at';
const COLUMN_ID: string = 'id';

// ===== 共享类型定义(与 SyncDataExporter 共用) =====

/**
 * 同步备份中单张表的数据。
 * rows 是 JSON 字符串,解析后为 Record<string, Object> 数组(列名→值)。
 */
export interface SyncTableData {
  tableName: string;
  rows: string;
}

/**
 * 同步备份中单个文件条目。
 * content 为 base64 编码的文件内容。
 */
export interface SyncFileEntry {
  relativePath: string;
  content: string;
}

/**
 * 同步备份完整载荷。
 * 加密字段仅在用户提供了加密密码时才有值。
 */
export interface SyncBackupPayload {
  format: string;
  databaseVersion: number;
  exportedAt: number;
  tables: SyncTableData[];
  preferences: string;
  files: SyncFileEntry[];
  encryptedApiKeys: string;
}

// ===== 导入结果类型 =====

/**
 * 备份校验结果。
 */
export interface SyncImportValidation {
  isValid: boolean;
  formatVersion: number;
  databaseVersion: number;
  errorMessage: string;
}

/**
 * 导入操作结果。
 */
export interface SyncImportResult {
  success: boolean;
  tablesImported: number;
  rowsProcessed: number;
  rowsSkipped: number;
  filesRestored: number;
  apiKeysRestored: number;
  errorMessage: string;
}

/**
 * 行内列值映射类型。
 */
type ColumnValueMap = Record<string, string | null>;

interface ColumnInfo {
  name: string;
  type: string;
}

/**
 * 创建校验失败结果。
 */
function createInvalidValidation(
  formatVersion: number,
  dbVersion: number,
  message: string
): SyncImportValidation {
  const result: SyncImportValidation = {
    isValid: false,
    formatVersion: formatVersion,
    databaseVersion: dbVersion,
    errorMessage: message
  };
  return result;
}

/**
 * 创建校验通过结果。
 */
function createValidValidation(
  formatVersion: number,
  dbVersion: number
): SyncImportValidation {
  const result: SyncImportValidation = {
    isValid: true,
    formatVersion: formatVersion,
    databaseVersion: dbVersion,
    errorMessage: ''
  };
  return result;
}

/**
 * 创建成功导入结果。
 */
function createSuccessResult(
  tablesImported: number,
  rowsProcessed: number,
  rowsSkipped: number,
  filesRestored: number,
  apiKeysRestored: number
): SyncImportResult {
  const result: SyncImportResult = {
    success: true,
    tablesImported: tablesImported,
    rowsProcessed: rowsProcessed,
    rowsSkipped: rowsSkipped,
    filesRestored: filesRestored,
    apiKeysRestored: apiKeysRestored,
    errorMessage: ''
  };
  return result;
}

/**
 * 创建失败导入结果。
 */
function createFailureResult(message: string): SyncImportResult {
  const result: SyncImportResult = {
    success: false,
    tablesImported: 0,
    rowsProcessed: 0,
    rowsSkipped: 0,
    filesRestored: 0,
    apiKeysRestored: 0,
    errorMessage: message
  };
  return result;
}

/**
 * WebDAV 同步数据导入服务。
 * 构造时注入依赖,调用方负责确保 DbHelper / AppPreferences 已初始化。
 */
export class SyncDataImporter {
  private readonly dbHelper: DbHelper;
  private readonly appPreferences: AppPreferences;
  private readonly providerKeyStore: ProviderKeyStore;
  private readonly context: common.Context;

  constructor(
    dbHelper: DbHelper,
    appPreferences: AppPreferences,
    providerKeyStore: ProviderKeyStore,
    context: common.Context
  ) {
    this.dbHelper = dbHelper;
    this.appPreferences = appPreferences;
    this.providerKeyStore = providerKeyStore;
    this.context = context;
  }

  /**
   * 校验 JSON 备份字符串格式与版本兼容性。
   * 不写入任何数据,仅解析与检查。
   *
   * @param jsonString JSON 备份字符串
   * @returns 校验结果
   */
  async validateBackup(jsonString: string): Promise<SyncImportValidation> {
    let payload: SyncBackupPayload;
    try {
      payload = JSON.parse(jsonString) as SyncBackupPayload;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'validateBackup: JSON parse failed code=' + err.code.toString());
      return createInvalidValidation(0, 0, 'Invalid JSON format');
    }

    if (payload === null || payload === undefined) {
      return createInvalidValidation(0, 0, 'Parsed payload is null');
    }

    // 检查 format 字段
    if (payload.format !== EXPECTED_FORMAT) {
      Logger.error(LOG_TAG, 'validateBackup: unexpected format=' + payload.format);
      return createInvalidValidation(0, payload.databaseVersion, 'Unexpected format: ' + payload.format);
    }

    // 检查数据库版本兼容性(不能导入来自未来版本的数据)
    if (payload.databaseVersion > DATABASE_VERSION) {
      Logger.error(LOG_TAG,
        'validateBackup: incompatible dbVersion=' + payload.databaseVersion.toString() +
        ' current=' + DATABASE_VERSION.toString());
      return createInvalidValidation(1, payload.databaseVersion,
        'Backup database version ' + payload.databaseVersion.toString() +
        ' is newer than local version ' + DATABASE_VERSION.toString());
    }

    Logger.info(LOG_TAG,
      'validateBackup: valid format=arktavern_sync_v1 dbVersion=' +
      payload.databaseVersion.toString());
    return createValidValidation(1, payload.databaseVersion);
  }

  /**
   * 完整导入 JSON 备份,采用 "latest-wins" 冲突解决策略。
   * 各子流程的错误被捕获并记录,不中断整体导入。
   *
   * @param jsonString JSON 备份字符串
   * @param encryptionPassword 加密密码(用于解密 API Key)
   * @returns 导入结果
   */
  async importAll(
    jsonString: string,
    encryptionPassword: string
  ): Promise<SyncImportResult> {
    // 1. 解析载荷
    let payload: SyncBackupPayload;
    try {
      payload = JSON.parse(jsonString) as SyncBackupPayload;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      Logger.error(LOG_TAG, 'importAll: JSON parse failed code=' + err.code.toString());
      return createFailureResult('Invalid JSON format');
    }

    if (payload === null || payload === undefined) {
      return createFailureResult('Parsed payload is null');
    }

    // 2. 基本校验
    if (payload.format !== EXPECTED_FORMAT) {
      return createFailureResult('Unexpected format: ' + payload.format);
    }
    if (payload.databaseVersion > DATABASE_VERSION) {
      return createFailureResult(
        'Backup database version ' + payload.databaseVersion.toString() +
        ' is newer than local version ' + DATABASE_VERSION.toString());
    }

    // 3. 导入表数据
    let tablesImported: number = 0;
    let rowsProcessed: number = 0;
    let rowsSkipped: number = 0;
    if (payload.tables !== null && payload.tables !== undefined) {
      for (let i = 0; i < payload.tables.length; i++) {
        const tableData: SyncTableData = payload.tables[i];
        const tableResult: TableImportResult = await SyncDataImporter.importTable(
          this.dbHelper, tableData
        );
        if (tableResult.anyRowImported) {
          tablesImported++;
        }
        rowsProcessed += tableResult.rowsProcessed;
        rowsSkipped += tableResult.rowsSkipped;
      }
    }

    // 4. 导入 Preferences
    await SyncDataImporter.importPreferences(this.appPreferences, payload.preferences);

    // 5. 导入文件
    let filesRestored: number = 0;
    if (payload.files !== null && payload.files !== undefined) {
      filesRestored = await SyncDataImporter.importFiles(
        this.context, payload.files
      );
    }

    // 6. 导入 API Key
    let apiKeysRestored: number = 0;
    if (payload.encryptedApiKeys !== null && payload.encryptedApiKeys !== undefined &&
        payload.encryptedApiKeys.length > 0 && encryptionPassword.length > 0) {
      apiKeysRestored = await SyncDataImporter.importApiKeys(
        this.providerKeyStore, payload.encryptedApiKeys, encryptionPassword
      );
    }

    Logger.info(LOG_TAG,
      'importAll: completed tables=' + tablesImported.toString() +
      ' rows=' + rowsProcessed.toString() +
      ' skipped=' + rowsSkipped.toString() +
      ' files=' + filesRestored.toString() +
      ' keys=' + apiKeysRestored.toString());

    return createSuccessResult(
      tablesImported, rowsProcessed, rowsSkipped, filesRestored, apiKeysRestored
    );
  }

  async importDb(dbJson: string): Promise<number> {
    let tables: SyncTableData[];
    try {
      tables = JSON.parse(dbJson) as SyncTableData[];
    } catch (e) {
      Logger.error(LOG_TAG, 'importDb: JSON parse failed');
      return 0;
    }
    if (tables === null || tables === undefined || tables.length === 0) {
      return 0;
    }
    let rowsImported: number = 0;
    for (let i = 0; i < tables.length; i++) {
      const tableData: SyncTableData = tables[i];
      const tableResult: TableImportResult = await SyncDataImporter.importTable(
        this.dbHelper, tableData
      );
      rowsImported += tableResult.rowsProcessed;
    }
    return rowsImported;
  }

  async importSingleTable(tableJson: string): Promise<number> {
    let tableData: SyncTableData;
    try {
      tableData = JSON.parse(tableJson) as SyncTableData;
    } catch (e) {
      Logger.error(LOG_TAG, 'importSingleTable: JSON parse failed');
      return 0;
    }
    if (tableData === null || tableData === undefined) {
      return 0;
    }
    const tableResult: TableImportResult = await SyncDataImporter.importTable(
      this.dbHelper, tableData
    );
    return tableResult.rowsProcessed;
  }

  async importPrefs(prefsJson: string): Promise<void> {
    await SyncDataImporter.importPreferences(this.appPreferences, prefsJson);
  }

  async importApiKeys(encryptedJson: string, encryptionPassword: string): Promise<number> {
    if (encryptedJson === null || encryptedJson === undefined || encryptedJson.length === 0) {
      return 0;
    }
    if (encryptionPassword.length === 0) {
      return 0;
    }
    return SyncDataImporter.importApiKeys(this.providerKeyStore, encryptedJson, encryptionPassword);
  }

  // ===== 表数据导入 =====

  /**
   * 导入单张表的数据,在事务中执行。
   * latest-wins 冲突解决:
   * - 远程 updated_at > 本地 → INSERT OR REPLACE
   * - 远程 updated_at <= 本地 → 跳过(INSERT OR IGNORE)
   * - 无 updated_at 列 → INSERT OR REPLACE
   */
  private static async importTable(
    dbHelper: DbHelper,
    tableData: SyncTableData
  ): Promise<TableImportResult> {
    const result: TableImportResult = {
      rowsProcessed: 0,
      rowsSkipped: 0,
      anyRowImported: false
    };

    let rows: ColumnValueMap[];
    try {
      rows = JSON.parse(tableData.rows) as ColumnValueMap[];
    } catch (e) {
      Logger.error(LOG_TAG,
        'importTable: rows parse failed table=' + tableData.tableName);
      return result;
    }

    if (rows === null || rows === undefined || rows.length === 0) {
      return result;
    }

    const tableName: string = tableData.tableName;
    if (!SyncDataImporter.isValidTableName(tableName)) {
      Logger.error(LOG_TAG, 'importTable: invalid table name=' + tableName);
      return result;
    }
    let rowsProcessed: number = 0;
    let rowsSkipped: number = 0;
    let anyRowImported: boolean = false;

    const store: relationalStore.RdbStore = dbHelper.getStore();
    const columnInfos: ColumnInfo[] = await SyncDataImporter.getTableColumns(store, tableName);
    if (columnInfos.length === 0) {
      Logger.error(LOG_TAG, 'importTable: no columns found table=' + tableName);
      return result;
    }

    try {
      await dbHelper.runInTransaction(
        async (txStore: relationalStore.RdbStore): Promise<void> => {
          for (let i = 0; i < rows.length; i++) {
            const rawRow: ColumnValueMap = rows[i];
            const row: ColumnValueMap = SyncDataImporter.filterColumns(rawRow, columnInfos);
            if (SyncDataImporter.isRowEmpty(row)) {
              rowsSkipped++;
              continue;
            }
            const rowId: string | undefined = SyncDataImporter.getRowId(row);

            if (rowId === undefined || rowId === null || rowId.length === 0) {
              try {
                const sql: string = SyncDataImporter.buildInsertOrReplaceSql(tableName, row, columnInfos);
                await txStore.executeSql(sql);
                rowsProcessed++;
                anyRowImported = true;
              } catch (e) {
                Logger.error(LOG_TAG,
                  'importTable: insert failed table=' + tableName);
                rowsSkipped++;
              }
              continue;
            }

            const localUpdatedAt: string | null = await SyncDataImporter.getLocalUpdatedAt(
              txStore, tableName, rowId
            );
            const remoteUpdatedAt: string | null = SyncDataImporter.getRemoteUpdatedAt(row);

            if (localUpdatedAt === null) {
              try {
                const sql: string = SyncDataImporter.buildInsertOrReplaceSql(tableName, row, columnInfos);
                await txStore.executeSql(sql);
                rowsProcessed++;
                anyRowImported = true;
              } catch (e) {
                Logger.error(LOG_TAG,
                  'importTable: insert new row failed table=' + tableName);
                rowsSkipped++;
              }
            } else if (remoteUpdatedAt !== null && remoteUpdatedAt.length > 0) {
              if (SyncDataImporter.compareTimestamps(remoteUpdatedAt, localUpdatedAt) > 0) {
                try {
                  const sql: string = SyncDataImporter.buildInsertOrReplaceSql(tableName, row, columnInfos);
                  await txStore.executeSql(sql);
                  rowsProcessed++;
                  anyRowImported = true;
                } catch (e) {
                  Logger.error(LOG_TAG,
                    'importTable: replace row failed table=' + tableName);
                  rowsSkipped++;
                }
              } else {
                rowsSkipped++;
              }
            } else {
              try {
                const sql: string = SyncDataImporter.buildInsertOrReplaceSql(tableName, row, columnInfos);
                await txStore.executeSql(sql);
                rowsProcessed++;
                anyRowImported = true;
              } catch (e) {
                Logger.error(LOG_TAG,
                  'importTable: replace row (no updated_at) failed table=' + tableName);
                rowsSkipped++;
              }
            }
          }
        },
        'chat_archive_import'
      );
    } catch (e) {
      Logger.error(LOG_TAG,
        'importTable: transaction failed table=' + tableData.tableName);
    }

    result.rowsProcessed = rowsProcessed;
    result.rowsSkipped = rowsSkipped;
    result.anyRowImported = anyRowImported;
    return result;
  }

  private static async getTableColumns(
    store: relationalStore.RdbStore,
    tableName: string
  ): Promise<ColumnInfo[]> {
    const columns: ColumnInfo[] = [];
    try {
      const sql: string = 'PRAGMA table_info(' + tableName + ')';
      const resultSet: relationalStore.ResultSet = await store.querySql(sql);
      if (resultSet.goToFirstRow()) {
        const nameIndex: number = resultSet.getColumnIndex('name');
        const typeIndex: number = resultSet.getColumnIndex('type');
        if (nameIndex >= 0 && typeIndex >= 0) {
          do {
            const colName: string = resultSet.getString(nameIndex);
            const colType: string = resultSet.getString(typeIndex);
            const info: ColumnInfo = { name: colName, type: colType };
            columns.push(info);
          } while (resultSet.goToNextRow());
        }
      }
      resultSet.close();
    } catch (e) {
      Logger.error(LOG_TAG, 'getTableColumns: failed table=' + tableName);
    }
    return columns;
  }

  private static filterColumns(
    row: ColumnValueMap,
    columnInfos: ColumnInfo[]
  ): ColumnValueMap {
    const filtered: ColumnValueMap = {};
    for (let i = 0; i < columnInfos.length; i++) {
      const col: string = columnInfos[i].name;
      const value: string | null | undefined = row[col];
      if (value !== undefined) {
        filtered[col] = value;
      }
    }
    return filtered;
  }

  private static isRowEmpty(row: ColumnValueMap): boolean {
    const keys: string[] = Object.keys(row);
    return keys.length === 0;
  }

  /**
   * 获取行的 id 值。
   */
  private static getRowId(row: ColumnValueMap): string | undefined {
    const value: string | null | undefined = row[COLUMN_ID];
    if (value === null || value === undefined) {
      return undefined;
    }
    return value;
  }

  /**
   * 获取行的 updated_at 值(远程)。
   */
  private static getRemoteUpdatedAt(row: ColumnValueMap): string | null {
    const value: string | null | undefined = row[COLUMN_UPDATED_AT];
    if (value === undefined || value === null) {
      return null;
    }
    return value;
  }

  /**
   * 查询本地行的 updated_at 值。
   * 不存在则返回 null。
   */
  private static async getLocalUpdatedAt(
    store: relationalStore.RdbStore,
    tableName: string,
    rowId: string
  ): Promise<string | null> {
    const escaped: string = SyncDataImporter.escapeSqlValue(rowId);
    const sql: string = 'SELECT ' + COLUMN_UPDATED_AT + ' FROM ' + tableName +
      ' WHERE ' + COLUMN_ID + ' = ' + escaped;
    try {
      const resultSet: relationalStore.ResultSet = await store.querySql(sql);
      let result: string | null = null;
      if (resultSet.goToFirstRow()) {
        const columnIndex: number = resultSet.getColumnIndex(COLUMN_UPDATED_AT);
        if (columnIndex >= 0) {
          const value: relationalStore.ValueType = resultSet.getString(columnIndex);
          if (typeof value === 'string') {
            result = value;
          }
        }
      }
      resultSet.close();
      return result;
    } catch (e) {
      Logger.error(LOG_TAG,
        'getLocalUpdatedAt: query failed table=' + tableName);
      return null;
    }
  }

  /**
   * 构建 INSERT OR REPLACE SQL。
   * 对于有 id 列的行,SQLite 按 PRIMARY KEY 决定替换。
   */
  private static buildInsertOrReplaceSql(
    tableName: string,
    row: ColumnValueMap,
    columnInfos: ColumnInfo[]
  ): string {
    const keys: string[] = SyncDataImporter.getRecordKeys(row);
    const columns: string = keys.map((key: string): string => {
      return '"' + key + '"';
    }).join(', ');
    const values: string = keys.map((key: string): string => {
      const value: string | null | undefined = row[key];
      const colType: string = SyncDataImporter.getColumnType(key, columnInfos);
      return SyncDataImporter.formatSqlValue(value, colType);
    }).join(', ');
    return 'INSERT OR REPLACE INTO ' + tableName + ' (' + columns + ') VALUES (' + values + ')';
  }

  private static getColumnType(colName: string, columnInfos: ColumnInfo[]): string {
    for (let i = 0; i < columnInfos.length; i++) {
      if (columnInfos[i].name === colName) {
        return columnInfos[i].type;
      }
    }
    return 'TEXT';
  }

  private static formatSqlValue(value: string | null | undefined, colType: string): string {
    if (value === undefined || value === null) {
      return 'NULL';
    }
    const upperType: string = colType.toUpperCase();
    if (upperType === 'INTEGER' || upperType === 'INT' || upperType === 'BIGINT') {
      if (value.length === 0) {
        return 'NULL';
      }
      const num: number = Number(value);
      if (!isNaN(num) && Number.isFinite(num)) {
        return Math.trunc(num).toString();
      }
      return '0';
    }
    if (upperType === 'REAL' || upperType === 'FLOAT' || upperType === 'DOUBLE' || upperType === 'NUMERIC') {
      if (value.length === 0) {
        return 'NULL';
      }
      const num: number = Number(value);
      if (!isNaN(num) && Number.isFinite(num)) {
        return num.toString();
      }
      return '0';
    }
    if (upperType === 'BLOB') {
      if (value.length === 0) {
        return 'NULL';
      }
      return 'NULL';
    }
    return SyncDataImporter.escapeSqlValue(value);
  }



  /**
   * 转义 SQL 值。
   * null/undefined → 'NULL'
   * 字符串 → 加引号并转义内部单引号
   */
  private static escapeSqlValue(value: string | null | undefined): string {
    if (value === undefined || value === null) {
      return 'NULL';
    }
    const escaped: string = value.replace(new RegExp("'", 'g'), "''");
    return '\'' + escaped + '\'';
  }

  /**
   * 获取 Record 的所有键。
   * 与项目中其他模块保持一致,使用 Object.keys。
   */
  private static getRecordKeys(record: Record<string, string | null>): string[] {
    return Object.keys(record);
  }

  private static compareTimestamps(a: string, b: string): number {
    const numA: number = Number(a);
    const numB: number = Number(b);
    if (!isNaN(numA) && !isNaN(numB)) {
      if (numA > numB) {
        return 1;
      }
      if (numA < numB) {
        return -1;
      }
      return 0;
    }
    if (a > b) {
      return 1;
    }
    if (a < b) {
      return -1;
    }
    return 0;
  }

  private static isValidTableName(tableName: string): boolean {
    const validNames: string[] = SyncDataExporter.getAllTableNames();
    for (let i = 0; i < validNames.length; i++) {
      if (validNames[i] === tableName) {
        return true;
      }
    }
    return false;
  }

  // ===== Preferences 导入 =====

  /**
   * 导入 Preferences 键值对。
   * 解析 JSON 字符串为 key→value 映射,逐项写入。
   * 所有值作为字符串存储(AppPreferences 内部统一为字符串)。
   */
  private static async importPreferences(
    appPreferences: AppPreferences,
    preferencesJson: string
  ): Promise<void> {
    if (preferencesJson === null || preferencesJson === undefined ||
        preferencesJson.length === 0) {
      return;
    }

    let prefsMap: Record<string, string>;
    try {
      prefsMap = JSON.parse(preferencesJson) as Record<string, string>;
    } catch (e) {
      Logger.error(LOG_TAG, 'importPreferences: JSON parse failed');
      return;
    }

    if (prefsMap === null || prefsMap === undefined) {
      return;
    }

    const BOOLEAN_KEYS: string[] = [
      'sync_auto_enabled',
      'sync_wifi_only',
      'status_instruction_enabled',
      'memory_auto_summary_enabled',
      'chat_smart_grip_enabled',
      'show_deepseek_balance'
    ];
    const NUMBER_KEYS: string[] = [
      'tts_mode',
      'tts_speed',
      'tts_volume',
      'tts_pitch',
      'tts_voice_person'
    ];
    const EXCLUDED_KEYS: string[] = [
      'sync_auto_enabled',
      'sync_wifi_only'
    ];
    const keys: string[] = SyncDataImporter.getRecordKeys(prefsMap);
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const value: string | undefined = prefsMap[key];
      if (value === undefined || value === null) {
        continue;
      }
      let isExcluded: boolean = false;
      for (let j: number = 0; j < EXCLUDED_KEYS.length; j++) {
        if (EXCLUDED_KEYS[j] === key) {
          isExcluded = true;
          break;
        }
      }
      if (isExcluded) {
        continue;
      }
      try {
        let isBoolKey: boolean = false;
        for (let j: number = 0; j < BOOLEAN_KEYS.length; j++) {
          if (BOOLEAN_KEYS[j] === key) {
            isBoolKey = true;
            break;
          }
        }
        if (isBoolKey) {
          await appPreferences.putBoolean(key, value === 'true');
        } else {
          await appPreferences.putString(key, value);
        }
      } catch (e) {
        Logger.error(LOG_TAG, 'importPreferences: put failed key=' + key);
      }
    }
  }

  // ===== 文件导入 =====

  /**
   * 导入文件条目。
   * 将 base64 内容解码后写入沙箱 filesDir + relativePath。
   * 自动创建父目录。
   *
   * @returns 成功恢复的文件数
   */
  private static async importFiles(
    context: common.Context,
    files: SyncFileEntry[]
  ): Promise<number> {
    let restored: number = 0;
    const base64: util.Base64Helper = new util.Base64Helper();
    const filesDir: string = context.filesDir;

    for (let i = 0; i < files.length; i++) {
      const entry: SyncFileEntry = files[i];
      try {
        const fullPath: string = filesDir + '/' + entry.relativePath;
        // 确保父目录存在
        const lastSlash: number = fullPath.lastIndexOf('/');
        if (lastSlash > 0) {
          const parentDir: string = fullPath.substring(0, lastSlash);
          if (!fileIo.accessSync(parentDir)) {
            fileIo.mkdirSync(parentDir, true);
          }
        }
        // 解码 base64
        const decoded: Uint8Array = base64.decodeSync(entry.content, util.Type.BASIC);
        // 写入文件
        const file: fileIo.File = fileIo.openSync(fullPath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
        fileIo.writeSync(file.fd, decoded.buffer as ArrayBuffer);
        fileIo.closeSync(file);
        restored++;
      } catch (e) {
        Logger.error(LOG_TAG,
          'importFiles: failed path=' + entry.relativePath);
      }
    }

    return restored;
  }

  // ===== API Key 导入 =====

  /**
   * 解密并导入 API Key。
   * 解密 encryptedApiKeys,解析为 providerId→apiKey 映射,逐项保存。
   *
   * @returns 成功恢复的密钥数
   */
  private static async importApiKeys(
    providerKeyStore: ProviderKeyStore,
    encryptedApiKeys: string,
    encryptionPassword: string
  ): Promise<number> {
    let decrypted: string;
    try {
      decrypted = await CryptoHelper.decrypt(encryptedApiKeys, encryptionPassword);
    } catch (e) {
      Logger.error(LOG_TAG, 'importApiKeys: decrypt failed');
      return 0;
    }

    let keysMap: Record<string, string>;
    try {
      keysMap = JSON.parse(decrypted) as Record<string, string>;
    } catch (e) {
      Logger.error(LOG_TAG, 'importApiKeys: JSON parse failed after decrypt');
      return 0;
    }

    if (keysMap === null || keysMap === undefined) {
      return 0;
    }

    let restored: number = 0;
    const keys: string[] = SyncDataImporter.getRecordKeys(keysMap);
    for (let i = 0; i < keys.length; i++) {
      const providerId: string = keys[i];
      const apiKey: string | undefined = keysMap[providerId];
      if (apiKey === undefined || apiKey === null || apiKey.length === 0) {
        continue;
      }
      try {
        await providerKeyStore.saveKey(providerId, apiKey);
        restored++;
      } catch (e) {
        Logger.error(LOG_TAG, 'importApiKeys: saveKey failed providerId=' + providerId);
      }
    }

    return restored;
  }
}

// ===== 内部辅助类型 =====

/**
 * 单表导入结果(内部使用)。
 */
interface TableImportResult {
  rowsProcessed: number;
  rowsSkipped: number;
  anyRowImported: boolean;
}

// ===== BusinessError 声明(与 DbHelper 保持一致) =====

interface BusinessError {
  code: number;
  message: string;
}
