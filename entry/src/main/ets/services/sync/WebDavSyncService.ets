import { HttpClient } from '../../network/core/HttpClient';
import { HarmonyHttpClient } from '../../network/core/HarmonyHttpClient';
import { WebDavClient } from '../../network/webdav/WebDavClient';
import { WebDavConfig, SyncManifest, ManifestFileEntry, ImageExportEntry } from '../../network/webdav/WebDavModels';
import { SyncDataExporter } from './SyncDataExporter';
import { SyncDataImporter, SyncImportResult } from './SyncDataImporter';
import { SyncConfigStore } from '../../storage/SyncConfigStore';
import { DbHelper } from '../../database/DbHelper';
import { AppPreferences } from '../../storage/AppPreferences';
import { ProviderKeyStore } from '../../storage/ProviderKeyStore';
import { ProviderConfigStore } from '../../storage/ProviderConfigStore';
import { common } from '@kit.AbilityKit';
import { Logger } from '../../utils/Logger';
import { DATABASE_VERSION } from '../../database/DatabaseConstants';
import { fileIo } from '@kit.CoreFileKit';

const LOG_TAG: string = 'WebDavSyncService';
const MANIFEST_PATH: string = 'manifest.json';
const PREFS_PATH: string = 'prefs.json';
const KEYS_PATH: string = 'keys.json';
const TABLES_DIR: string = 'tables/';
const IMAGES_DIR: string = 'images/';
const FORMAT_V3: string = 'arktavern_sync_v3';

export type SyncDirection = 'upload' | 'download' | 'bidirectional';

export interface SyncProgress {
  stage: string;
  progress: number;
  message: string;
}

export interface SyncResult {
  success: boolean;
  direction: SyncDirection;
  message: string;
}

export interface SyncMeta {
  deviceId: string;
  lastSyncTime: string;
  formatVersion: number;
}

export class WebDavSyncService {
  private readonly dbHelper: DbHelper;
  private readonly appPreferences: AppPreferences;
  private readonly providerKeyStore: ProviderKeyStore;
  private readonly providerConfigStore: ProviderConfigStore;
  private readonly syncConfigStore: SyncConfigStore;
  private readonly context: common.Context;
  private readonly httpClient: HttpClient;
  private syncing: boolean = false;
  private progressCallback: ((progress: SyncProgress) => void) | null = null;

  constructor(
    dbHelper: DbHelper,
    appPreferences: AppPreferences,
    providerKeyStore: ProviderKeyStore,
    providerConfigStore: ProviderConfigStore,
    syncConfigStore: SyncConfigStore,
    context: common.Context
  ) {
    this.dbHelper = dbHelper;
    this.appPreferences = appPreferences;
    this.providerKeyStore = providerKeyStore;
    this.providerConfigStore = providerConfigStore;
    this.syncConfigStore = syncConfigStore;
    this.context = context;
    this.httpClient = new HarmonyHttpClient();
  }

  setProgressCallback(callback: (progress: SyncProgress) => void): void {
    this.progressCallback = callback;
  }

  isSyncing(): boolean {
    return this.syncing;
  }

  async isAutoSyncEnabled(): Promise<boolean> {
    return this.syncConfigStore.isAutoSyncEnabled();
  }

  async testConnection(): Promise<boolean> {
    const client: WebDavClient | null = await this.createClient();
    if (client === null) {
      Logger.error(LOG_TAG, 'testConnection: client is null, not configured');
      return false;
    }
    const config: WebDavConfig = client.getConfig();
    Logger.info(LOG_TAG, 'testConnection: url=' + config.serverUrl + ' user=' + config.username + ' path=' + config.remotePath);
    const result: boolean = await client.checkConnection();
    Logger.info(LOG_TAG, 'testConnection result=' + result.toString());
    return result;
  }

  async upload(): Promise<SyncResult> {
    if (this.syncing) {
      const r: SyncResult = { success: false, direction: 'upload', message: '同步正在进行中' };
      return r;
    }
    this.syncing = true;
    try {
      return await this.uploadInternal();
    } finally {
      this.syncing = false;
    }
  }

  private async uploadInternal(): Promise<SyncResult> {
    try {
      this.reportProgress('preparing', 0, '准备上传...');
      const client: WebDavClient | null = await this.createClient();
      if (client === null) {
        const r: SyncResult = { success: false, direction: 'upload', message: 'WebDAV 未配置' };
        return r;
      }
      const deviceId: string = await this.syncConfigStore.getDeviceId();
      const password: string = await this.syncConfigStore.getAppPassword();
      const remotePath: string = await this.syncConfigStore.getRemotePath();
      const basePath: string = this.normalizePath(remotePath);

      this.reportProgress('ensuring_directory', 3, '创建远程目录...');
      await client.ensureDirectory(remotePath);
      await client.ensureDirectory(basePath + TABLES_DIR);
      await client.ensureDirectory(basePath + IMAGES_DIR);

      const exporter: SyncDataExporter = new SyncDataExporter(
        this.dbHelper, this.appPreferences, this.providerKeyStore,
        this.providerConfigStore, this.context
      );
      const tableNames: string[] = SyncDataExporter.getAllTableNames();

      const localFiles: Record<string, ManifestFileEntry> = {};

      this.reportProgress('exporting', 5, '导出各表数据...');
      const tableJsons: string[] = [];
      for (let i = 0; i < tableNames.length; i++) {
        const tableName: string = tableNames[i];
        try {
          const tableJson: string = await exporter.exportSingleTable(tableName);
          tableJsons.push(tableJson);
          const tableKey: string = TABLES_DIR + tableName + '.json';
          localFiles[tableKey] = WebDavSyncService.computeEntry(tableJson);
        } catch (e) {
          tableJsons.push('');
          Logger.warn(LOG_TAG, 'upload: export table failed table=' + tableName);
        }
      }

      this.reportProgress('exporting', 20, '导出偏好设置...');
      const prefsJson: string = await exporter.exportPrefs();
      localFiles[PREFS_PATH] = WebDavSyncService.computeEntry(prefsJson);

      this.reportProgress('exporting', 25, '导出 API 密钥...');
      const keysJson: string = await exporter.exportApiKeys(password);
      if (keysJson.length > 0) {
        localFiles[KEYS_PATH] = WebDavSyncService.computeEntry(keysJson);
      }

      this.reportProgress('exporting', 30, '收集图片列表...');
      const imageEntries: ImageExportEntry[] = exporter.exportImageList();
      for (let i = 0; i < imageEntries.length; i++) {
        const img: ImageExportEntry = imageEntries[i];
        const size: number = WebDavSyncService.getFileSize(img.localPath);
        const hash: string = WebDavSyncService.computeFileHash(img.localPath);
        const entry: ManifestFileEntry = { hash: hash, size: size };
        localFiles[img.relativePath] = entry;
      }

      this.reportProgress('comparing', 35, '比对远程清单...');
      let remoteManifest: SyncManifest | null = null;
      const manifestRemotePath: string = basePath + MANIFEST_PATH;
      const existingManifest: string | null = await client.downloadFile(manifestRemotePath);
      if (existingManifest !== null) {
        try {
          remoteManifest = JSON.parse(existingManifest) as SyncManifest;
        } catch (e) {
          Logger.warn(LOG_TAG, 'upload: failed to parse remote manifest');
        }
      }

      let uploadCount: number = 0;

      for (let i = 0; i < tableNames.length; i++) {
        const tableName: string = tableNames[i];
        const tableJson: string = tableJsons[i];
        if (tableJson.length === 0) {
          continue;
        }
        const tableKey: string = TABLES_DIR + tableName + '.json';
        if (!WebDavSyncService.fileChanged(tableKey, localFiles, remoteManifest)) {
          continue;
        }
        const progress: number = 35 + Math.floor((i / tableNames.length) * 30);
        this.reportProgress('uploading_tables', progress, '上传表 ' + tableName);
        const ok: boolean = await client.uploadFile(basePath + tableKey, tableJson);
        if (!ok) {
          Logger.warn(LOG_TAG, 'upload: table upload failed table=' + tableName);
        }
        uploadCount++;
      }

      if (WebDavSyncService.fileChanged(PREFS_PATH, localFiles, remoteManifest)) {
        this.reportProgress('uploading', 66, '上传偏好设置...');
        const ok: boolean = await client.uploadFile(basePath + PREFS_PATH, prefsJson);
        if (!ok) {
          const r: SyncResult = { success: false, direction: 'upload', message: '上传偏好设置失败' };
          return r;
        }
        uploadCount++;
      } else {
        Logger.info(LOG_TAG, 'upload: prefs.json unchanged, skipping');
      }

      const keysChanged: boolean = keysJson.length > 0 && WebDavSyncService.fileChanged(KEYS_PATH, localFiles, remoteManifest);
      if (keysChanged) {
        this.reportProgress('uploading', 70, '上传密钥...');
        const ok: boolean = await client.uploadFile(basePath + KEYS_PATH, keysJson);
        if (!ok) {
          const r: SyncResult = { success: false, direction: 'upload', message: '上传密钥文件失败' };
          return r;
        }
        uploadCount++;
      } else if (keysJson.length > 0) {
        Logger.info(LOG_TAG, 'upload: keys.json unchanged, skipping');
      }

      let imagesUploaded: number = 0;
      for (let i = 0; i < imageEntries.length; i++) {
        const img: ImageExportEntry = imageEntries[i];
        if (!WebDavSyncService.fileChanged(img.relativePath, localFiles, remoteManifest)) {
          continue;
        }
        const progress: number = 70 + Math.floor((i / imageEntries.length) * 18);
        this.reportProgress('uploading_images', progress, '上传图片 ' + (i + 1).toString() + '/' + imageEntries.length.toString());
        const imgRemotePath: string = basePath + img.relativePath;
        await client.ensureDirectory(basePath + WebDavSyncService.extractDir(img.relativePath));
        const ok: boolean = await client.uploadBinaryFile(imgRemotePath, img.localPath);
        if (ok) {
          imagesUploaded++;
        } else {
          Logger.warn(LOG_TAG, 'upload: image upload failed path=' + img.relativePath);
        }
        uploadCount++;
      }

      this.reportProgress('uploading_manifest', 90, '上传清单...');
      const newManifest: SyncManifest = {
        format: FORMAT_V3,
        databaseVersion: DATABASE_VERSION,
        exportedAt: Date.now(),
        deviceId: deviceId,
        files: localFiles
      };
      const manifestJson: string = JSON.stringify(newManifest, null, 2);
      await client.uploadFile(manifestRemotePath, manifestJson);

      this.reportProgress('done', 100, '上传完成');
      await this.syncConfigStore.setLastSyncTime(new Date().toISOString());
      await this.syncConfigStore.setLastManifest(manifestJson);
      const msg: string = '上传完成: ' + uploadCount.toString() + ' 个文件 (' +
        imagesUploaded.toString() + ' 张图片)';
      const r: SyncResult = { success: true, direction: 'upload', message: msg };
      return r;
    } catch (e) {
      Logger.error(LOG_TAG, 'upload failed: ' + (e as Error).message);
      const r: SyncResult = { success: false, direction: 'upload', message: '上传失败: ' + (e as Error).message };
      return r;
    }
  }

  async download(): Promise<SyncResult> {
    if (this.syncing) {
      const r: SyncResult = { success: false, direction: 'download', message: '同步正在进行中' };
      return r;
    }
    this.syncing = true;
    try {
      this.reportProgress('preparing', 0, '准备下载...');
      const client: WebDavClient | null = await this.createClient();
      if (client === null) {
        const r: SyncResult = { success: false, direction: 'download', message: 'WebDAV 未配置' };
        return r;
      }
      const remotePath: string = await this.syncConfigStore.getRemotePath();
      const basePath: string = this.normalizePath(remotePath);
      const password: string = await this.syncConfigStore.getAppPassword();

      this.reportProgress('downloading', 5, '下载清单...');
      const manifestRemotePath: string = basePath + MANIFEST_PATH;
      const manifestContent: string | null = await client.downloadFile(manifestRemotePath);
      if (manifestContent === null) {
        const r: SyncResult = { success: false, direction: 'download', message: '远程未找到同步清单' };
        return r;
      }

      let remoteManifest: SyncManifest;
      try {
        remoteManifest = JSON.parse(manifestContent) as SyncManifest;
      } catch (e) {
        Logger.error(LOG_TAG, 'download: manifest parse failed');
        const r: SyncResult = { success: false, direction: 'download', message: '同步清单格式无效' };
        return r;
      }

      if (remoteManifest.databaseVersion > DATABASE_VERSION) {
        const r: SyncResult = {
          success: false,
          direction: 'download',
          message: '远程数据库版本 ' + remoteManifest.databaseVersion.toString() +
            ' 高于本地版本 ' + DATABASE_VERSION.toString()
        };
        return r;
      }

      const importer: SyncDataImporter = new SyncDataImporter(
        this.dbHelper, this.appPreferences, this.providerKeyStore, this.context
      );
      let rowsImported: number = 0;
      let apiKeysRestored: number = 0;
      let imagesDownloaded: number = 0;

      const remoteFiles: Record<string, ManifestFileEntry> = remoteManifest.files;
      const localManifestJson: string = await this.syncConfigStore.getLastManifest();
      let localManifest: SyncManifest | null = null;
      if (localManifestJson.length > 0) {
        try {
          localManifest = JSON.parse(localManifestJson) as SyncManifest;
        } catch (e) {
          Logger.warn(LOG_TAG, 'download: failed to parse local manifest');
        }
      }
      const tableNames: string[] = SyncDataExporter.getAllTableNames();

      for (let i = 0; i < tableNames.length; i++) {
        const tableName: string = tableNames[i];
        const tableKey: string = TABLES_DIR + tableName + '.json';
        const tableEntry: ManifestFileEntry | undefined = remoteFiles[tableKey];
        if (tableEntry === undefined) {
          continue;
        }
        if (localManifest !== null && !WebDavSyncService.fileChanged(tableKey, remoteFiles, localManifest)) {
          continue;
        }
        const progress: number = 10 + Math.floor((i / tableNames.length) * 40);
        this.reportProgress('downloading_tables', progress, '下载表 ' + tableName);
        const tableContent: string | null = await client.downloadFile(basePath + tableKey);
        if (tableContent !== null) {
          try {
            const imported: number = await importer.importSingleTable(tableContent);
            rowsImported += imported;
          } catch (e) {
            Logger.warn(LOG_TAG, 'download: import table failed table=' + tableName);
          }
        }
      }

      this.reportProgress('downloading', 55, '下载偏好设置...');
      const prefsEntry: ManifestFileEntry | undefined = remoteFiles[PREFS_PATH];
      if (prefsEntry !== undefined) {
        if (localManifest === null || WebDavSyncService.fileChanged(PREFS_PATH, remoteFiles, localManifest)) {
          const prefsContent: string | null = await client.downloadFile(basePath + PREFS_PATH);
          if (prefsContent !== null) {
            await importer.importPrefs(prefsContent);
          }
        } else {
          Logger.info(LOG_TAG, 'download: prefs.json unchanged, skipping');
        }
      }

      this.reportProgress('downloading', 60, '下载密钥...');
      const keysEntry: ManifestFileEntry | undefined = remoteFiles[KEYS_PATH];
      if (keysEntry !== undefined && password.length > 0) {
        if (localManifest === null || WebDavSyncService.fileChanged(KEYS_PATH, remoteFiles, localManifest)) {
          const keysContent: string | null = await client.downloadFile(basePath + KEYS_PATH);
          if (keysContent !== null) {
            apiKeysRestored = await importer.importApiKeys(keysContent, password);
          }
        } else {
          Logger.info(LOG_TAG, 'download: keys.json unchanged, skipping');
        }
      }

      const imageKeys: string[] = WebDavSyncService.collectImageKeys(remoteFiles);
      for (let i = 0; i < imageKeys.length; i++) {
        const imgKey: string = imageKeys[i];
        if (localManifest !== null && !WebDavSyncService.fileChanged(imgKey, remoteFiles, localManifest)) {
          continue;
        }
        const progress: number = 60 + Math.floor((i / imageKeys.length) * 35);
        this.reportProgress('downloading_images', progress, '下载图片 ' + (i + 1).toString() + '/' + imageKeys.length.toString());
        const localFilePath: string = this.context.filesDir + '/' + imgKey.substring(IMAGES_DIR.length);
        const imgRemotePath: string = basePath + imgKey;
        const ok: boolean = await client.downloadBinaryFile(imgRemotePath, localFilePath);
        if (ok) {
          imagesDownloaded++;
        } else {
          Logger.warn(LOG_TAG, 'download: image download failed key=' + imgKey);
        }
      }

      this.reportProgress('done', 100, '下载完成');
      await this.syncConfigStore.setLastSyncTime(new Date().toISOString());
      await this.syncConfigStore.setLastManifest(manifestContent);
      const msg: string = '下载完成: ' + rowsImported.toString() + ' 行数据, ' +
        imagesDownloaded.toString() + ' 张图片, ' +
        apiKeysRestored.toString() + ' 个 API 密钥';
      const r: SyncResult = { success: true, direction: 'download', message: msg };
      return r;
    } catch (e) {
      Logger.error(LOG_TAG, 'download failed: ' + (e as Error).message);
      const r: SyncResult = { success: false, direction: 'download', message: '下载失败: ' + (e as Error).message };
      return r;
    } finally {
      this.syncing = false;
    }
  }

  async syncBidirectional(): Promise<SyncResult> {
    if (this.syncing) {
      const r: SyncResult = { success: false, direction: 'bidirectional', message: '同步正在进行中' };
      return r;
    }
    this.syncing = true;
    try {
      this.reportProgress('preparing', 0, '检查远程状态...');
      const client: WebDavClient | null = await this.createClient();
      if (client === null) {
        const r: SyncResult = { success: false, direction: 'bidirectional', message: 'WebDAV 未配置' };
        return r;
      }
      const remotePath: string = await this.syncConfigStore.getRemotePath();
      const basePath: string = this.normalizePath(remotePath);
      const manifestRemotePath: string = basePath + MANIFEST_PATH;
      const manifestContent: string | null = await client.downloadFile(manifestRemotePath);
      const localDeviceId: string = await this.syncConfigStore.getDeviceId();
      if (manifestContent !== null) {
        try {
          const manifest: SyncManifest = JSON.parse(manifestContent) as SyncManifest;
          if (manifest.deviceId === localDeviceId) {
            const localLastSync: string = await this.syncConfigStore.getLastSyncTime();
            const remoteTime: string = new Date(manifest.exportedAt).toISOString();
            if (localLastSync === remoteTime) {
              this.reportProgress('done', 100, '数据已是最新');
              const r: SyncResult = { success: true, direction: 'bidirectional', message: '数据已是最新' };
              return r;
            }
          }
        } catch (e) {
          Logger.warn(LOG_TAG, 'Failed to parse remote manifest, proceeding with upload');
        }
      }
      this.reportProgress('uploading', 30, '上传本地数据...');
      const uploadResult: SyncResult = await this.uploadInternal();
      return uploadResult;
    } catch (e) {
      Logger.error(LOG_TAG, 'bidirectional sync failed: ' + (e as Error).message);
      const r: SyncResult = { success: false, direction: 'bidirectional', message: '同步失败: ' + (e as Error).message };
      return r;
    } finally {
      this.syncing = false;
    }
  }

  async autoSync(): Promise<SyncResult | null> {
    const configured: boolean = await this.syncConfigStore.isConfigured();
    if (!configured) {
      return null;
    }
    const autoEnabled: boolean = await this.syncConfigStore.isAutoSyncEnabled();
    if (!autoEnabled) {
      return null;
    }
    Logger.info(LOG_TAG, 'Auto-sync triggered');
    return this.syncBidirectional();
  }

  private async createClient(): Promise<WebDavClient | null> {
    const serverUrl: string = await this.syncConfigStore.getServerUrl();
    const username: string = await this.syncConfigStore.getUsername();
    const appPassword: string = await this.syncConfigStore.getAppPassword();
    const remotePath: string = await this.syncConfigStore.getRemotePath();
    if (username.length === 0 || appPassword.length === 0 || serverUrl.length === 0) {
      return null;
    }
    const config: WebDavConfig = {
      serverUrl: serverUrl,
      username: username,
      appPassword: appPassword,
      remotePath: remotePath
    };
    return new WebDavClient(this.httpClient, config);
  }

  private reportProgress(stage: string, progress: number, message: string): void {
    if (this.progressCallback !== null) {
      const p: SyncProgress = { stage: stage, progress: progress, message: message };
      this.progressCallback(p);
    }
  }

  private normalizePath(path: string): string {
    if (path.length === 0) {
      return '/';
    }
    if (path.charAt(path.length - 1) !== '/') {
      return path + '/';
    }
    return path;
  }

  private static computeEntry(content: string): ManifestFileEntry {
    const hash: string = WebDavSyncService.computeContentHash(content);
    const entry: ManifestFileEntry = { hash: hash, size: content.length };
    return entry;
  }

  private static computeContentHash(content: string): string {
    if (content.length === 0) {
      return 'e_0';
    }
    const len: number = content.length;
    const headLen: number = Math.min(64, len);
    const tailLen: number = Math.min(64, len);
    const head: string = content.substring(0, headLen);
    const tail: string = content.substring(len - tailLen);
    let h: number = 5381;
    for (let i = 0; i < len; i++) {
      const code: number = content.charCodeAt(i);
      h = ((h << 5) + h + code) & 0x7FFFFFFF;
    }
    return h.toString(36) + '_' + len.toString(36) + '_' + head.substring(0, 8) + '_' + tail.substring(tail.length - 8);
  }

  private static computeFileHash(filePath: string): string {
    try {
      if (!fileIo.accessSync(filePath)) {
        return 'missing';
      }
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      if (!stat.isFile()) {
        return 'not_file';
      }
      return stat.size.toString(36) + '_' + Math.floor(stat.mtime / 1000).toString(36);
    } catch (e) {
      return 'error';
    }
  }

  private static getFileSize(filePath: string): number {
    try {
      if (!fileIo.accessSync(filePath)) {
        return 0;
      }
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      if (!stat.isFile()) {
        return 0;
      }
      return stat.size;
    } catch (e) {
      return 0;
    }
  }

  private static fileChanged(
    key: string,
    localFiles: Record<string, ManifestFileEntry>,
    remoteManifest: SyncManifest | null
  ): boolean {
    const localEntry: ManifestFileEntry | undefined = localFiles[key];
    if (localEntry === undefined) {
      return false;
    }
    if (remoteManifest === null) {
      return true;
    }
    const remoteEntry: ManifestFileEntry | undefined = remoteManifest.files[key];
    if (remoteEntry === undefined) {
      return true;
    }
    if (localEntry.hash !== remoteEntry.hash) {
      return true;
    }
    return false;
  }

  private static extractDir(relativePath: string): string {
    const lastSlash: number = relativePath.lastIndexOf('/');
    if (lastSlash > 0) {
      return relativePath.substring(0, lastSlash);
    }
    return '';
  }

  private static collectImageKeys(files: Record<string, ManifestFileEntry>): string[] {
    const keys: string[] = Object.keys(files);
    const imageKeys: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      if (key.startsWith(IMAGES_DIR)) {
        imageKeys.push(key);
      }
    }
    return imageKeys;
  }
}
