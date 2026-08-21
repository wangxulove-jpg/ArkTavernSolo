import { WebDavSyncService, SyncResult, SyncProgress, SyncDirection } from '../services/sync/WebDavSyncService';
import { SyncConfigStore } from '../storage/SyncConfigStore';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'SyncViewModel';

export type ConnectionStatus = 'untested' | 'connected' | 'failed' | 'testing';

export class SyncViewModel {
  private readonly syncService: WebDavSyncService;
  private readonly configStore: SyncConfigStore;
  serverUrl: string = 'https://dav.jianguoyun.com/dav/';
  username: string = '';
  appPassword: string = '';
  remotePath: string = '/ArkTavernSolo/';
  autoSyncEnabled: boolean = false;
  wifiOnly: boolean = true;
  lastSyncTime: string = '';
  connectionStatus: ConnectionStatus = 'untested';
  isSyncing: boolean = false;
  syncProgress: number = 0;
  syncMessage: string = '';
  syncResult: SyncResult | null = null;

  constructor(syncService: WebDavSyncService, configStore: SyncConfigStore) {
    this.syncService = syncService;
    this.configStore = configStore;
    this.syncService.setProgressCallback((progress: SyncProgress) => {
      this.syncProgress = progress.progress;
      this.syncMessage = progress.message;
    });
  }

  async loadConfig(): Promise<void> {
    try {
      this.serverUrl = await this.configStore.getServerUrl();
      this.username = await this.configStore.getUsername();
      this.appPassword = await this.configStore.getAppPassword();
      this.remotePath = await this.configStore.getRemotePath();
      this.autoSyncEnabled = await this.configStore.isAutoSyncEnabled();
      this.wifiOnly = await this.configStore.isWifiOnly();
      this.lastSyncTime = await this.configStore.getLastSyncTime();
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadConfig failed: ' + (e as Error).message);
    }
  }

  async saveConfig(): Promise<boolean> {
    try {
      await this.configStore.setServerUrl(this.serverUrl);
      await this.configStore.setUsername(this.username);
      await this.configStore.setAppPassword(this.appPassword);
      await this.configStore.setRemotePath(this.remotePath);
      await this.configStore.setAutoSyncEnabled(this.autoSyncEnabled);
      await this.configStore.setWifiOnly(this.wifiOnly);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'saveConfig failed: ' + (e as Error).message);
      return false;
    }
  }

  isConfigured(): boolean {
    return this.username.length > 0 && this.appPassword.length > 0 && this.serverUrl.length > 0;
  }

  async testConnection(): Promise<boolean> {
    await this.saveConfig();
    this.connectionStatus = 'testing';
    const success: boolean = await this.syncService.testConnection();
    this.connectionStatus = success ? 'connected' : 'failed';
    return success;
  }

  async syncNow(): Promise<SyncResult> {
    if (!this.isConfigured()) {
      const result: SyncResult = {
        success: false,
        direction: 'bidirectional' as SyncDirection,
        message: '请先配置坚果云 WebDAV 设置'
      };
      this.syncResult = result;
      return result;
    }
    await this.saveConfig();
    this.isSyncing = true;
    this.syncProgress = 0;
    this.syncMessage = '开始同步...';
    this.syncResult = null;
    try {
      const result: SyncResult = await this.syncService.syncBidirectional();
      this.syncResult = result;
      if (result.success) {
        this.lastSyncTime = await this.configStore.getLastSyncTime();
      }
      return result;
    } catch (e) {
      const result: SyncResult = {
        success: false,
        direction: 'bidirectional' as SyncDirection,
        message: '同步失败: ' + (e as Error).message
      };
      this.syncResult = result;
      return result;
    } finally {
      this.isSyncing = false;
    }
  }

  async uploadOnly(): Promise<SyncResult> {
    if (!this.isConfigured()) {
      const result: SyncResult = {
        success: false,
        direction: 'upload' as SyncDirection,
        message: '请先配置坚果云 WebDAV 设置'
      };
      this.syncResult = result;
      return result;
    }
    await this.saveConfig();
    this.isSyncing = true;
    this.syncProgress = 0;
    this.syncMessage = '开始上传...';
    this.syncResult = null;
    try {
      const result: SyncResult = await this.syncService.upload();
      this.syncResult = result;
      if (result.success) {
        this.lastSyncTime = await this.configStore.getLastSyncTime();
      }
      return result;
    } catch (e) {
      const result: SyncResult = {
        success: false,
        direction: 'upload' as SyncDirection,
        message: '上传失败: ' + (e as Error).message
      };
      this.syncResult = result;
      return result;
    } finally {
      this.isSyncing = false;
    }
  }

  async downloadOnly(): Promise<SyncResult> {
    if (!this.isConfigured()) {
      const result: SyncResult = {
        success: false,
        direction: 'download' as SyncDirection,
        message: '请先配置坚果云 WebDAV 设置'
      };
      this.syncResult = result;
      return result;
    }
    await this.saveConfig();
    this.isSyncing = true;
    this.syncProgress = 0;
    this.syncMessage = '开始下载...';
    this.syncResult = null;
    try {
      const result: SyncResult = await this.syncService.download();
      this.syncResult = result;
      if (result.success) {
        this.lastSyncTime = await this.configStore.getLastSyncTime();
      }
      return result;
    } catch (e) {
      const result: SyncResult = {
        success: false,
        direction: 'download' as SyncDirection,
        message: '下载失败: ' + (e as Error).message
      };
      this.syncResult = result;
      return result;
    } finally {
      this.isSyncing = false;
    }
  }
}
