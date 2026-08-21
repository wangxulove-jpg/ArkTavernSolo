/**
 * SyncDataExporter WebDAV 同步数据导出服务
 *
 * 职责:
 * - 导出所有 38 张数据库表(SELECT * FROM each, ResultSet → JSON)
 * - 导出 Preferences 键值对(已知 key 列表逐一读取)
 * - 导出文件(头像/背景等,读取沙箱文件 → base64)
 * - 导出加密 API Key(遍历 ProviderConfig,读取密钥,加密后导出)
 * - 组装为 SyncBackupPayload 并序列化为 JSON 字符串
 *
 * 依赖:
 * - DbHelper(getStore → querySql)
 * - AppPreferences(已知 key 列表 → getString/getBoolean)
 * - ProviderKeyStore(readKey)
 * - ProviderConfigStore(list → ProviderConfig[])
 * - CryptoHelper(encrypt → AES-256-GCM)
 * - DatabaseConstants(所有 TABLE_* 常量 + DATABASE_VERSION)
 * - Logger(脱敏日志)
 *
 * 日志规则:
 * - 只记录表名、行数、文件数量、操作类型、成功/失败
 * - 严禁输出 API Key、密钥明文、加密密码、消息正文
 */

import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import util from '@ohos.util';
import { DbHelper } from '../../database/DbHelper';
import { AppPreferences } from '../../storage/AppPreferences';
import { ProviderKeyStore } from '../../storage/ProviderKeyStore';
import { ProviderConfigStore } from '../../storage/ProviderConfigStore';
import { CryptoHelper } from '../../utils/CryptoHelper';
import { Logger } from '../../utils/Logger';
import { ProviderConfig } from '../../models/ProviderConfig';
import {
  DATABASE_VERSION,
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_LOREBOOKS,
  TABLE_LOREBOOK_ENTRIES,
  TABLE_PROMPT_PRESETS,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES,
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
  TABLE_CHAT_MEMORIES,
  TABLE_CHAT_PARTICIPANTS,
  TABLE_WORLDS,
  TABLE_WORLD_LOCATIONS,
  TABLE_WORLD_LOCATION_EDGES,
  TABLE_WORLD_CHARACTER_INSTANCES,
  TABLE_WORLD_EVENTS,
  TABLE_WORLD_SCENES,
  TABLE_WORLD_SCENE_MESSAGES,
  TABLE_WORLD_CHARACTER_MEMORIES,
  TABLE_GROUP_CHARACTER_MEMORIES,
  TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES,
  TABLE_WORLD_PLAYER_PROFILES,
  TABLE_WORLD_CONVERSATION_SESSIONS,
  TABLE_WORLD_LOCATION_MAP_PLACEMENTS,
  TABLE_WORLD_CHARACTER_LOCATION_HISTORY,
  TABLE_WORLD_SESSION_SUMMARIES,
  TABLE_WORLD_CHARACTER_MEMORY_ENTRIES,
  TABLE_WORLD_EVENT_EXTRACTION_RUNS,
  TABLE_WORLD_EVENT_ENTRIES,
  TABLE_WORLD_KNOWN_EVENT_ENTRIES,
  TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES,
  TABLE_WORLD_SESSION_POST_PROCESS_RUNS,
  TABLE_GROUP_CHARACTER_OVERRIDES,
  TABLE_WORLD_MAP_BACKGROUNDS,
  TABLE_PERSONAS
} from '../../database/DatabaseConstants';
import {
  SyncTableData,
  SyncFileEntry,
  SyncBackupPayload
} from './SyncDataImporter';
import { ImageExportEntry } from '../../network/webdav/WebDavModels';

const LOG_TAG: string = 'SyncDataExporter';
const EXPECTED_FORMAT: string = 'arktavern_sync_v1';

/**
 * 所有数据库表名(与 DatabaseConstants TABLE_* 一一对应)。
 * 导出时按此顺序遍历,确保不遗漏任何表。
 */
const ALL_TABLE_NAMES: string[] = [
  TABLE_CHARACTERS,
  TABLE_CHATS,
  TABLE_MESSAGES,
  TABLE_LOREBOOKS,
  TABLE_LOREBOOK_ENTRIES,
  TABLE_PROMPT_PRESETS,
  TABLE_MESSAGE_SWIPE_GROUPS,
  TABLE_MESSAGE_SWIPE_CANDIDATES,
  TABLE_CONVERSATION_BRANCHES,
  TABLE_CHAT_BRANCH_STATE,
  TABLE_CONVERSATION_BRANCH_MESSAGES,
  TABLE_CONVERSATION_BRANCH_SWIPE_SELECTIONS,
  TABLE_CHAT_MEMORIES,
  TABLE_CHAT_PARTICIPANTS,
  TABLE_WORLDS,
  TABLE_WORLD_LOCATIONS,
  TABLE_WORLD_LOCATION_EDGES,
  TABLE_WORLD_CHARACTER_INSTANCES,
  TABLE_WORLD_EVENTS,
  TABLE_WORLD_SCENES,
  TABLE_WORLD_SCENE_MESSAGES,
  TABLE_WORLD_CHARACTER_MEMORIES,
  TABLE_GROUP_CHARACTER_MEMORIES,
  TABLE_GROUP_CHARACTER_RELATIONSHIP_MEMORIES,
  TABLE_WORLD_PLAYER_PROFILES,
  TABLE_WORLD_CONVERSATION_SESSIONS,
  TABLE_WORLD_LOCATION_MAP_PLACEMENTS,
  TABLE_WORLD_CHARACTER_LOCATION_HISTORY,
  TABLE_WORLD_SESSION_SUMMARIES,
  TABLE_WORLD_CHARACTER_MEMORY_ENTRIES,
  TABLE_WORLD_EVENT_EXTRACTION_RUNS,
  TABLE_WORLD_EVENT_ENTRIES,
  TABLE_WORLD_KNOWN_EVENT_ENTRIES,
  TABLE_WORLD_DIRECTIONAL_RELATIONSHIP_ENTRIES,
  TABLE_WORLD_SESSION_POST_PROCESS_RUNS,
  TABLE_GROUP_CHARACTER_OVERRIDES,
  TABLE_WORLD_MAP_BACKGROUNDS,
  TABLE_PERSONAS
];

/**
 * 已知 Preferences 键名列表。
 * 由于 AppPreferences 不暴露 getAll(),使用预定义列表逐一读取。
 * 新增 Preferences key 时需同步更新此列表。
 */
const KNOWN_PREFS_KEYS: string[] = [
  'provider_configs_v1',
  'current_provider_id',
  'chat_bubble_opacity',
  'chat_text_color',
  'chat_content_height_ratio',
  'chat_send_button_position',
  'chat_smart_grip_enabled',
  'status_instruction_enabled',
  'memory_auto_summary_enabled',
  'app_theme_mode',
  'sync_server_url',
  'sync_username',
  'sync_remote_path',
  'sync_auto_enabled',
  'sync_wifi_only',
  'sync_last_sync_time',
  'sync_device_id',
  'sync_last_manifest'
];

/**
 * 需要导出的沙箱子目录列表。
 * 每个目录下的所有文件递归导出为 SyncFileEntry。
 */
const EXPORT_DIRS: string[] = [
  'avatars',
  'backgrounds',
  'world_backgrounds'
];

// ===== 导出结果类型 =====

/**
 * 导出操作结果。
 */
export interface SyncExportResult {
  success: boolean;
  tablesExported: number;
  totalRows: number;
  prefsExported: number;
  filesExported: number;
  apiKeysExported: number;
  errorMessage: string;
}

/**
 * WebDAV 同步数据导出服务。
 * 构造时注入依赖,调用方负责确保 DbHelper / AppPreferences / ProviderConfigStore 已初始化。
 */
export class SyncDataExporter {
  private readonly dbHelper: DbHelper;
  private readonly appPreferences: AppPreferences;
  private readonly providerKeyStore: ProviderKeyStore;
  private readonly providerConfigStore: ProviderConfigStore;
  private readonly context: common.Context;

  constructor(
    dbHelper: DbHelper,
    appPreferences: AppPreferences,
    providerKeyStore: ProviderKeyStore,
    providerConfigStore: ProviderConfigStore,
    context: common.Context
  ) {
    this.dbHelper = dbHelper;
    this.appPreferences = appPreferences;
    this.providerKeyStore = providerKeyStore;
    this.providerConfigStore = providerConfigStore;
    this.context = context;
  }

  /**
   * 导出所有应用数据为 JSON 字符串。
   *
   * @param deviceId 本设备唯一标识(由 SyncConfigStore 生成)
   * @param encryptionPassword 加密密码(用于加密 API Key,空字符串则跳过 API Key 导出)
   * @returns SyncBackupPayload 的 JSON 字符串
   */
  async exportAll(deviceId: string, encryptionPassword: string): Promise<string> {
    Logger.info(LOG_TAG, 'exportAll: starting');

    // 1. 导出数据库表
    const tables: SyncTableData[] = [];
    let totalRows: number = 0;
    for (let i = 0; i < ALL_TABLE_NAMES.length; i++) {
      const tableName: string = ALL_TABLE_NAMES[i];
      try {
        const tableData: SyncTableData = await SyncDataExporter.exportTable(
          this.dbHelper, tableName
        );
        tables.push(tableData);
        // 统计行数(解析 rows JSON 字符串获取长度)
        const rowCount: number = SyncDataExporter.countRowsFromJson(tableData.rows);
        totalRows += rowCount;
        if (rowCount > 0) {
          Logger.info(LOG_TAG,
            'exportAll: table=' + tableName + ' rows=' + rowCount.toString());
        }
      } catch (e) {
        Logger.error(LOG_TAG,
          'exportAll: table export failed table=' + tableName);
      }
    }
    Logger.info(LOG_TAG,
      'exportAll: tables done count=' + tables.length.toString() +
      ' totalRows=' + totalRows.toString());

    // 2. 导出 Preferences
    const preferencesJson: string = await SyncDataExporter.exportPreferences(
      this.appPreferences
    );
    const prefsCount: number = SyncDataExporter.countKeysFromPrefsJson(preferencesJson);
    Logger.info(LOG_TAG,
      'exportAll: preferences done count=' + prefsCount.toString());

    // 3. 导出文件
    const files: SyncFileEntry[] = await SyncDataExporter.exportFiles(
      this.context
    );
    Logger.info(LOG_TAG,
      'exportAll: files done count=' + files.length.toString());

    // 4. 导出加密 API Key
    let encryptedApiKeys: string = '';
    let apiKeysExported: number = 0;
    if (encryptionPassword.length > 0) {
      const keyResult: ApiKeyExportResult = await SyncDataExporter.exportApiKeys(
        this.providerKeyStore, this.providerConfigStore, encryptionPassword
      );
      encryptedApiKeys = keyResult.encryptedJson;
      apiKeysExported = keyResult.keyCount;
      Logger.info(LOG_TAG,
        'exportAll: apiKeys done count=' + apiKeysExported.toString());
    } else {
      Logger.info(LOG_TAG, 'exportAll: apiKeys skipped (no password)');
    }

    // 5. 组装 Payload
    const payload: SyncBackupPayload = {
      format: EXPECTED_FORMAT,
      databaseVersion: DATABASE_VERSION,
      exportedAt: Date.now(),
      tables: tables,
      preferences: preferencesJson,
      files: files,
      encryptedApiKeys: encryptedApiKeys
    };

    const json: string = JSON.stringify(payload, null, 2);
    Logger.info(LOG_TAG, 'exportAll: completed payloadSize=' + json.length.toString());
    return json;
  }

  async exportDb(): Promise<string> {
    const tables: SyncTableData[] = [];
    for (let i = 0; i < ALL_TABLE_NAMES.length; i++) {
      const tableName: string = ALL_TABLE_NAMES[i];
      try {
        const tableData: SyncTableData = await SyncDataExporter.exportTable(
          this.dbHelper, tableName
        );
        tables.push(tableData);
      } catch (e) {
        Logger.error(LOG_TAG, 'exportDb: table export failed table=' + tableName);
      }
    }
    return JSON.stringify(tables, null, 2);
  }

  async exportSingleTable(tableName: string): Promise<string> {
    const tableData: SyncTableData = await SyncDataExporter.exportTable(
      this.dbHelper, tableName
    );
    return JSON.stringify(tableData, null, 2);
  }

  static getAllTableNames(): string[] {
    const result: string[] = [];
    for (let i = 0; i < ALL_TABLE_NAMES.length; i++) {
      result.push(ALL_TABLE_NAMES[i]);
    }
    return result;
  }

  async exportPrefs(): Promise<string> {
    return SyncDataExporter.exportPreferences(this.appPreferences);
  }

  async exportApiKeys(encryptionPassword: string): Promise<string> {
    if (encryptionPassword.length === 0) {
      return '';
    }
    const result: ApiKeyExportResult = await SyncDataExporter.exportApiKeys(
      this.providerKeyStore, this.providerConfigStore, encryptionPassword
    );
    return result.encryptedJson;
  }

  exportImageList(): ImageExportEntry[] {
    const entries: ImageExportEntry[] = [];
    const filesDir: string = this.context.filesDir;
    for (let d: number = 0; d < EXPORT_DIRS.length; d++) {
      const dirName: string = EXPORT_DIRS[d];
      const dirPath: string = filesDir + '/' + dirName;
      try {
        if (!fileIo.accessSync(dirPath)) {
          continue;
        }
        const fileNames: string[] = fileIo.listFileSync(dirPath);
        for (let i: number = 0; i < fileNames.length; i++) {
          const fileName: string = fileNames[i];
          const fullPath: string = dirPath + '/' + fileName;
          try {
            const stat: fileIo.Stat = fileIo.statSync(fullPath);
            if (!stat.isFile()) {
              continue;
            }
            if (stat.size > 50 * 1024 * 1024) {
              continue;
            }
            const entry: ImageExportEntry = {
              relativePath: 'images/' + dirName + '/' + fileName,
              localPath: fullPath
            };
            entries.push(entry);
          } catch (e) {
            Logger.warn(LOG_TAG, 'exportImageList: stat failed path=' + fullPath);
          }
        }
      } catch (e) {
        Logger.warn(LOG_TAG, 'exportImageList: listDir failed dir=' + dirName);
      }
    }
    return entries;
  }

  // ===== 数据库表导出 =====

  /**
   * 导出单张表的全部数据。
   * 使用 SELECT * FROM tableName,将 ResultSet 转换为 JSON 字符串。
   *
   * @param dbHelper 数据库助手
   * @param tableName 表名
   * @returns SyncTableData(tableName + rows JSON 字符串)
   */
  private static async exportTable(
    dbHelper: DbHelper,
    tableName: string
  ): Promise<SyncTableData> {
    const store: relationalStore.RdbStore = dbHelper.getStore();
    const sql: string = 'SELECT * FROM ' + tableName;
    let resultSet: relationalStore.ResultSet | null = null;
    try {
      resultSet = await store.querySql(sql);
      const rowsJson: string = SyncDataExporter.resultSetToJson(resultSet);
      const tableData: SyncTableData = {
        tableName: tableName,
        rows: rowsJson
      };
      return tableData;
    } catch (e) {
      Logger.error(LOG_TAG,
        'exportTable: query failed table=' + tableName);
      const emptyData: SyncTableData = {
        tableName: tableName,
        rows: '[]'
      };
      return emptyData;
    } finally {
      if (resultSet !== null) {
        try {
          resultSet.close();
        } catch (closeErr) {
          Logger.warn(LOG_TAG,
            'exportTable: resultSet close failed table=' + tableName);
        }
      }
    }
  }

  /**
   * 将 ResultSet 转换为 JSON 字符串。
   * 遍历所有列和所有行,将每行转为 列名→值 的映射对象。
   * 值类型处理:
   * - string → 直接使用
   * - number → 转为字符串
   * - null/undefined → 空字符串
   * - ArrayBuffer/Blob → 跳过(不支持导出二进制列)
   *
   * @param resultSet 查询结果集
   * @returns JSON 字符串(Record<string, string> 数组)
   */
  private static resultSetToJson(resultSet: relationalStore.ResultSet): string {
    const columnCount: number = resultSet.columnCount;
    const columnNames: string[] = [];
    for (let i: number = 0; i < columnCount; i++) {
      const name: string = resultSet.getColumnName(i);
      columnNames.push(name);
    }

    const rows: Record<string, string | null>[] = [];
    if (resultSet.goToFirstRow()) {
      do {
        const row: Record<string, string | null> = {};
        for (let i: number = 0; i < columnCount; i++) {
          const colName: string = columnNames[i];
          try {
            const columnIndex: number = resultSet.getColumnIndex(colName);
            if (columnIndex < 0) {
              continue;
            }
            const isNull: boolean = resultSet.isColumnNull(columnIndex);
            if (isNull) {
              row[colName] = null;
            } else {
              row[colName] = resultSet.getString(columnIndex);
            }
          } catch (e) {
            row[colName] = null;
          }
        }
        rows.push(row);
      } while (resultSet.goToNextRow());
    }

    return JSON.stringify(rows, null, 2);
  }

  // ===== Preferences 导出 =====

  /**
   * 导出所有已知 Preferences 键值对。
   * 遍历 KNOWN_PREFS_KEYS 列表,逐一检查是否存在并读取。
   * 所有值统一转为字符串(布尔值转 'true'/'false')。
   *
   * @param appPreferences Preferences 封装
   * @returns JSON 字符串(Record<string, string>)
   */
  private static async exportPreferences(
    appPreferences: AppPreferences
  ): Promise<string> {
    const prefsMap: Record<string, string> = {};

    for (let i: number = 0; i < KNOWN_PREFS_KEYS.length; i++) {
      const key: string = KNOWN_PREFS_KEYS[i];
      try {
        const exists: boolean = await appPreferences.has(key);
        if (!exists) {
          continue;
        }
        // 优先尝试读取为字符串
        const strValue: string = await appPreferences.getString(key, '');
        if (strValue.length > 0) {
          prefsMap[key] = strValue;
          continue;
        }
        // 字符串为空时尝试读取布尔值(区分 "未设置" 和 "值为空字符串" 和 "false")
        // 只有当 key 存在但字符串读取返回空时才尝试布尔
        // getString 对不存在的 key 也会返回默认值,但上面 has() 已过滤
        // 所以如果 exists=true 且 getString 返回空,可能是布尔值
        try {
          const boolValue: boolean = await appPreferences.getBoolean(key, false);
          prefsMap[key] = boolValue ? 'true' : 'false';
        } catch (boolErr) {
          // 布尔读取也失败,记录空字符串
          prefsMap[key] = '';
        }
      } catch (e) {
        Logger.warn(LOG_TAG,
          'exportPreferences: read failed key=' + key);
      }
    }

    return JSON.stringify(prefsMap, null, 2);
  }

  // ===== 文件导出 =====

  /**
   * 导出沙箱目录中的文件。
   * 遍历 EXPORT_DIRS 中的子目录,读取所有文件并转为 base64。
   *
   * @param context 应用 Context
   * @returns SyncFileEntry 列表
   */
  private static async exportFiles(
    context: common.Context
  ): Promise<SyncFileEntry[]> {
    const files: SyncFileEntry[] = [];
    const filesDir: string = context.filesDir;
    const base64: util.Base64Helper = new util.Base64Helper();

    for (let d: number = 0; d < EXPORT_DIRS.length; d++) {
      const dirName: string = EXPORT_DIRS[d];
      const dirPath: string = filesDir + '/' + dirName;
      let fileNames: string[] = [];
      try {
        if (!fileIo.accessSync(dirPath)) {
          continue;
        }
        fileNames = fileIo.listFileSync(dirPath);
      } catch (e) {
        Logger.warn(LOG_TAG,
          'exportFiles: listDir failed dir=' + dirName);
        continue;
      }

      for (let i: number = 0; i < fileNames.length; i++) {
        const fileName: string = fileNames[i];
        const fullPath: string = dirPath + '/' + fileName;
        const relativePath: string = dirName + '/' + fileName;
        try {
          // 读取文件为 ArrayBuffer
          const stat: fileIo.Stat = fileIo.statSync(fullPath);
          if (!stat.isFile()) {
            continue;
          }
          // 限制单文件大小(50MB)
          if (stat.size > 50 * 1024 * 1024) {
            Logger.warn(LOG_TAG,
              'exportFiles: file too large path=' + relativePath +
              ' size=' + stat.size.toString());
            continue;
          }
          const file: fileIo.File = fileIo.openSync(fullPath, fileIo.OpenMode.READ_ONLY);
          const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
          fileIo.readSync(file.fd, buffer);
          fileIo.closeSync(file.fd);
          // 转为 base64
          const uint8Arr: Uint8Array = new Uint8Array(buffer);
          const encoded: string = base64.encodeToStringSync(uint8Arr, util.Type.BASIC);
          const entry: SyncFileEntry = {
            relativePath: relativePath,
            content: encoded
          };
          files.push(entry);
        } catch (e) {
          Logger.warn(LOG_TAG,
            'exportFiles: read failed path=' + relativePath);
        }
      }
    }

    return files;
  }

  // ===== API Key 导出 =====

  /**
   * 导出所有 Provider 的 API Key。
   * 遍历所有 ProviderConfig,逐一读取密钥,组装为 JSON 后加密。
   *
   * @param providerKeyStore 密钥存储
   * @param providerConfigStore 配置存储
   * @param encryptionPassword 加密密码
   * @returns 加密后的 JSON 字符串 + 导出的密钥数
   */
  private static async exportApiKeys(
    providerKeyStore: ProviderKeyStore,
    providerConfigStore: ProviderConfigStore,
    encryptionPassword: string
  ): Promise<ApiKeyExportResult> {
    const emptyResult: ApiKeyExportResult = {
      encryptedJson: '',
      keyCount: 0
    };

    let configs: ProviderConfig[];
    try {
      configs = await providerConfigStore.list();
    } catch (e) {
      Logger.error(LOG_TAG, 'exportApiKeys: list configs failed');
      return emptyResult;
    }

    if (configs === null || configs === undefined || configs.length === 0) {
      Logger.info(LOG_TAG, 'exportApiKeys: no configs found');
      return emptyResult;
    }

    const keysMap: Record<string, string> = {};
    let keyCount: number = 0;

    for (let i: number = 0; i < configs.length; i++) {
      const config: ProviderConfig = configs[i];
      const providerId: string = config.id;
      try {
        const apiKey: string | null = await providerKeyStore.readKey(providerId);
        if (apiKey !== null && apiKey.length > 0) {
          keysMap[providerId] = apiKey;
          keyCount++;
        }
      } catch (e) {
        Logger.warn(LOG_TAG,
          'exportApiKeys: readKey failed providerId=' + providerId);
      }
    }

    if (keyCount === 0) {
      Logger.info(LOG_TAG, 'exportApiKeys: no keys to export');
      return emptyResult;
    }

    const plainJson: string = JSON.stringify(keysMap);
    try {
      const encrypted: string = await CryptoHelper.encrypt(plainJson, encryptionPassword);
      const result: ApiKeyExportResult = {
        encryptedJson: encrypted,
        keyCount: keyCount
      };
      return result;
    } catch (e) {
      Logger.error(LOG_TAG, 'exportApiKeys: encrypt failed');
      return emptyResult;
    }
  }

  // ===== 辅助方法 =====

  /**
   * 从 rows JSON 字符串中估算行数。
   * 通过计算顶层数组元素数量来确定。
   * 简单实现:空数组返回 0,否则用 JSON.parse 获取长度。
   *
   * @param rowsJson rows 字段的 JSON 字符串
   * @returns 行数
   */
  private static countRowsFromJson(rowsJson: string): number {
    if (rowsJson === null || rowsJson === undefined || rowsJson.length === 0) {
      return 0;
    }
    if (rowsJson === '[]') {
      return 0;
    }
    try {
      const arr: Object[] = JSON.parse(rowsJson) as Object[];
      return arr.length;
    } catch (e) {
      return 0;
    }
  }

  /**
   * 从 Preferences JSON 字符串中估算键数。
   *
   * @param prefsJson preferences 字段的 JSON 字符串
   * @returns 键数
   */
  private static countKeysFromPrefsJson(prefsJson: string): number {
    if (prefsJson === null || prefsJson === undefined || prefsJson.length === 0) {
      return 0;
    }
    if (prefsJson === '{}') {
      return 0;
    }
    try {
      const obj: Record<string, string> = JSON.parse(prefsJson) as Record<string, string>;
      // ArkTS 禁止 Object.keys,使用 JSON.stringify 后计算键数
      // 简单方式:重新解析获取键列表
      // 由于 Record<string, string> 允许 indexed access,通过遍历已知键计数
      let count: number = 0;
      for (let i: number = 0; i < KNOWN_PREFS_KEYS.length; i++) {
        const key: string = KNOWN_PREFS_KEYS[i];
        const value: string | undefined = obj[key];
        if (value !== undefined && value !== null) {
          count++;
        }
      }
      return count;
    } catch (e) {
      return 0;
    }
  }
}

// ===== 内部辅助类型 =====

/**
 * API Key 导出结果(内部使用)。
 */
interface ApiKeyExportResult {
  encryptedJson: string;
  keyCount: number;
}


