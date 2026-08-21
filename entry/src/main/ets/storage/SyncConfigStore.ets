import { AppPreferences } from './AppPreferences';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'SyncConfigStore';
const KEY_SERVER_URL: string = 'sync_server_url';
const KEY_USERNAME: string = 'sync_username';
const KEY_APP_PASSWORD: string = 'sync_app_password';
const KEY_REMOTE_PATH: string = 'sync_remote_path';
const KEY_AUTO_ENABLED: string = 'sync_auto_enabled';
const KEY_WIFI_ONLY: string = 'sync_wifi_only';
const KEY_LAST_SYNC_TIME: string = 'sync_last_sync_time';
const KEY_DEVICE_ID: string = 'sync_device_id';
const KEY_LAST_MANIFEST: string = 'sync_last_manifest';

export class SyncConfigStore {
  private readonly prefs: AppPreferences;
  private initialized: boolean = false;

  constructor(prefs: AppPreferences) {
    this.prefs = prefs;
  }

  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
  }

  async getServerUrl(): Promise<string> {
    return this.prefs.getString(KEY_SERVER_URL, 'https://dav.jianguoyun.com/dav/');
  }

  async setServerUrl(url: string): Promise<void> {
    await this.prefs.putString(KEY_SERVER_URL, url);
  }

  async getUsername(): Promise<string> {
    return this.prefs.getString(KEY_USERNAME, '');
  }

  async setUsername(username: string): Promise<void> {
    await this.prefs.putString(KEY_USERNAME, username);
  }

  async getAppPassword(): Promise<string> {
    return this.prefs.getString(KEY_APP_PASSWORD, '');
  }

  async setAppPassword(password: string): Promise<void> {
    await this.prefs.putString(KEY_APP_PASSWORD, password);
  }

  async getRemotePath(): Promise<string> {
    return this.prefs.getString(KEY_REMOTE_PATH, '/ArkTavernSolo/');
  }

  async setRemotePath(path: string): Promise<void> {
    await this.prefs.putString(KEY_REMOTE_PATH, path);
  }

  async isAutoSyncEnabled(): Promise<boolean> {
    return this.prefs.getBoolean(KEY_AUTO_ENABLED, false);
  }

  async setAutoSyncEnabled(enabled: boolean): Promise<void> {
    await this.prefs.putBoolean(KEY_AUTO_ENABLED, enabled);
  }

  async isWifiOnly(): Promise<boolean> {
    return this.prefs.getBoolean(KEY_WIFI_ONLY, true);
  }

  async setWifiOnly(wifiOnly: boolean): Promise<void> {
    await this.prefs.putBoolean(KEY_WIFI_ONLY, wifiOnly);
  }

  async getLastSyncTime(): Promise<string> {
    return this.prefs.getString(KEY_LAST_SYNC_TIME, '');
  }

  async setLastSyncTime(time: string): Promise<void> {
    await this.prefs.putString(KEY_LAST_SYNC_TIME, time);
  }

  async getDeviceId(): Promise<string> {
    let deviceId: string = await this.prefs.getString(KEY_DEVICE_ID, '');
    if (deviceId.length === 0) {
      deviceId = 'dev_' + Date.now().toString(36) + '_' + Math.random().toString(36).substring(2, 10);
      await this.prefs.putString(KEY_DEVICE_ID, deviceId);
    }
    return deviceId;
  }

  async isConfigured(): Promise<boolean> {
    const username: string = await this.getUsername();
    const password: string = await this.getAppPassword();
    const serverUrl: string = await this.getServerUrl();
    return username.length > 0 && password.length > 0 && serverUrl.length > 0;
  }

  async getLastManifest(): Promise<string> {
    return this.prefs.getString(KEY_LAST_MANIFEST, '');
  }

  async setLastManifest(manifestJson: string): Promise<void> {
    await this.prefs.putString(KEY_LAST_MANIFEST, manifestJson);
  }
}
