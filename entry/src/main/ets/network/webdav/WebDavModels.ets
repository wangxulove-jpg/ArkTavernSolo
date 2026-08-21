export interface WebDavResource {
  href: string;
  lastModified: string;
  contentLength: number;
  isDirectory: boolean;
}

export interface WebDavConfig {
  serverUrl: string;
  username: string;
  appPassword: string;
  remotePath: string;
}

export class WebDavConfigDefaults {
  static readonly DEFAULT_SERVER_URL: string = 'https://dav.jianguoyun.com/dav/';
  static readonly DEFAULT_REMOTE_PATH: string = '/ArkTavernSolo/';
}

export interface ManifestFileEntry {
  hash: string;
  size: number;
}

export interface SyncManifest {
  format: string;
  databaseVersion: number;
  exportedAt: number;
  deviceId: string;
  files: Record<string, ManifestFileEntry>;
}

export interface ImageExportEntry {
  relativePath: string;
  localPath: string;
}
