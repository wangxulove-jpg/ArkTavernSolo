import { HttpClient, HttpMethod, HttpHeaders, HttpRequestOptions, HttpResponse } from '../core/HttpClient';
import { WebDavResource, WebDavConfig } from './WebDavModels';
import { Logger } from '../../utils/Logger';
import http from '@ohos.net.http';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

const LOG_TAG: string = 'WebDavClient';
const PROPFIND_BODY: string =
  '<?xml version="1.0" encoding="utf-8"?>' +
  '<d:propfind xmlns:d="DAV:">' +
  '<d:prop><d:getlastmodified/><d:getcontentlength/><d:resourcetype/></d:prop>' +
  '</d:propfind>';

export class WebDavClient {
  private readonly httpClient: HttpClient;
  private readonly config: WebDavConfig;

  constructor(httpClient: HttpClient, config: WebDavConfig) {
    this.httpClient = httpClient;
    this.config = config;
  }

  getConfig(): WebDavConfig {
    return this.config;
  }

  async checkConnection(): Promise<boolean> {
    try {
      const url: string = this.buildUrl('/');
      const headers: HttpHeaders = new Map<string, string>();
      headers.set('Depth', '0');
      headers.set('Content-Type', 'application/xml');
      const response: HttpResponse = await this.httpClient.request(this.createOptions(
        HttpMethod.PROPFIND, url, headers, PROPFIND_BODY
      ));
      Logger.info(LOG_TAG, 'checkConnection status=' + response.statusCode.toString());
      return response.statusCode >= 200 && response.statusCode < 400;
    } catch (e) {
      Logger.error(LOG_TAG, 'checkConnection failed: ' + (e as Error).message);
      return false;
    }
  }

  async ensureDirectory(path: string): Promise<void> {
    const parts: string[] = this.splitPath(path);
    let current: string = '';
    for (let i = 0; i < parts.length; i++) {
      current = current + '/' + parts[i];
      const exists: boolean = await this.resourceExists(current);
      if (!exists) {
        try {
          const url: string = this.buildUrl(current);
          await this.httpClient.request(this.createOptions(HttpMethod.MKCOL, url));
        } catch (e) {
          if (!(e as Error).message.includes('405')) {
            Logger.warn(LOG_TAG, 'MKCOL ' + current + ' failed: ' + (e as Error).message);
          }
        }
      }
    }
  }

  async listFiles(path: string): Promise<WebDavResource[]> {
    const url: string = this.buildUrl(path);
    const headers: HttpHeaders = new Map<string, string>();
    headers.set('Depth', '1');
    headers.set('Content-Type', 'application/xml');
    const response: HttpResponse = await this.httpClient.request(
      this.createOptions(HttpMethod.PROPFIND, url, headers, PROPFIND_BODY)
    );
    if (response.statusCode === 207) {
      return this.parseMultiStatus(response.body, path);
    }
    return [];
  }

  async uploadFile(remotePath: string, content: string): Promise<boolean> {
    try {
      const url: string = this.buildUrl(remotePath);
      const headers: HttpHeaders = new Map<string, string>();
      headers.set('Content-Type', 'application/octet-stream');
      const response: HttpResponse = await this.httpClient.request(
        this.createOptions(HttpMethod.PUT, url, headers, content)
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      Logger.error(LOG_TAG, 'uploadFile failed: ' + (e as Error).message);
      return false;
    }
  }

  async downloadFile(remotePath: string): Promise<string | null> {
    try {
      const url: string = this.buildUrl(remotePath);
      const response: HttpResponse = await this.httpClient.request(
        this.createOptions(HttpMethod.GET, url)
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.body;
      }
      return null;
    } catch (e) {
      Logger.error(LOG_TAG, 'downloadFile failed: ' + (e as Error).message);
      return null;
    }
  }

  async deleteFile(remotePath: string): Promise<boolean> {
    try {
      const url: string = this.buildUrl(remotePath);
      const response: HttpResponse = await this.httpClient.request(
        this.createOptions(HttpMethod.DELETE, url)
      );
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      Logger.error(LOG_TAG, 'deleteFile failed: ' + (e as Error).message);
      return false;
    }
  }

  async resourceExists(path: string): Promise<boolean> {
    try {
      const url: string = this.buildUrl(path);
      const headers: HttpHeaders = new Map<string, string>();
      headers.set('Depth', '0');
      headers.set('Content-Type', 'application/xml');
      const response: HttpResponse = await this.httpClient.request(
        this.createOptions(HttpMethod.PROPFIND, url, headers, PROPFIND_BODY)
      );
      return response.statusCode === 207;
    } catch (e) {
      return false;
    }
  }

  async uploadBinaryFile(remotePath: string, filePath: string): Promise<boolean> {
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file.fd);
      const url: string = this.buildUrl(remotePath);
      const httpRequest: http.HttpRequest = http.createHttp();
      const base64: util.Base64Helper = new util.Base64Helper();
      const credential: string = this.config.username + ':' + this.config.appPassword;
      const encoded: string = base64.encodeToStringSync(
        new Uint8Array(Array.from(credential).map((c: string) => c.charCodeAt(0)))
      );
      const headerObj: Record<string, string> = {};
      headerObj['Content-Type'] = 'application/octet-stream';
      headerObj['Authorization'] = 'Basic ' + encoded;
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.PUT,
        header: headerObj,
        extraData: buffer,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 60000,
        readTimeout: 120000
      };
      const response: http.HttpResponse = await httpRequest.request(url, options);
      const statusCode: number = response.responseCode;
      httpRequest.destroy();
      Logger.info(LOG_TAG, 'uploadBinaryFile status=' + statusCode.toString() + ' path=' + remotePath);
      return statusCode >= 200 && statusCode < 300;
    } catch (e) {
      Logger.error(LOG_TAG, 'uploadBinaryFile failed: ' + (e as Error).message);
      return false;
    }
  }

  async downloadBinaryFile(remotePath: string, filePath: string): Promise<boolean> {
    try {
      const url: string = this.buildUrl(remotePath);
      const httpRequest: http.HttpRequest = http.createHttp();
      const base64: util.Base64Helper = new util.Base64Helper();
      const credential: string = this.config.username + ':' + this.config.appPassword;
      const encoded: string = base64.encodeToStringSync(
        new Uint8Array(Array.from(credential).map((c: string) => c.charCodeAt(0)))
      );
      const headerObj: Record<string, string> = {};
      headerObj['Authorization'] = 'Basic ' + encoded;
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: headerObj,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 60000,
        readTimeout: 120000
      };
      const response: http.HttpResponse = await httpRequest.request(url, options);
      const statusCode: number = response.responseCode;
      httpRequest.destroy();
      if (statusCode >= 200 && statusCode < 300 && response.result instanceof ArrayBuffer) {
        const lastSlash: number = filePath.lastIndexOf('/');
        if (lastSlash > 0) {
          const parentDir: string = filePath.substring(0, lastSlash);
          if (!fileIo.accessSync(parentDir)) {
            fileIo.mkdirSync(parentDir, true);
          }
        }
        const file: fileIo.File = fileIo.openSync(filePath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC | fileIo.OpenMode.WRITE_ONLY);
        fileIo.writeSync(file.fd, response.result);
        fileIo.closeSync(file);
        Logger.info(LOG_TAG, 'downloadBinaryFile ok path=' + remotePath);
        return true;
      }
      Logger.error(LOG_TAG, 'downloadBinaryFile failed status=' + statusCode.toString());
      return false;
    } catch (e) {
      Logger.error(LOG_TAG, 'downloadBinaryFile failed: ' + (e as Error).message);
      return false;
    }
  }

  private createOptions(
    method: HttpMethod,
    url: string,
    headers?: HttpHeaders,
    body?: string
  ): HttpRequestOptions {
    if (headers !== undefined && body !== undefined) {
      return {
        method: method,
        url: url,
        headers: headers,
        body: body,
        serverAuth: {
          username: this.config.username,
          password: this.config.appPassword
        },
        connectTimeoutMs: 30000,
        readTimeoutMs: 60000
      };
    }
    if (headers !== undefined) {
      return {
        method: method,
        url: url,
        headers: headers,
        serverAuth: {
          username: this.config.username,
          password: this.config.appPassword
        },
        connectTimeoutMs: 30000,
        readTimeoutMs: 60000
      };
    }
    if (body !== undefined) {
      return {
        method: method,
        url: url,
        body: body,
        serverAuth: {
          username: this.config.username,
          password: this.config.appPassword
        },
        connectTimeoutMs: 30000,
        readTimeoutMs: 60000
      };
    }
    return {
      method: method,
      url: url,
      serverAuth: {
        username: this.config.username,
        password: this.config.appPassword
      },
      connectTimeoutMs: 30000,
      readTimeoutMs: 60000
    };
  }

  private buildUrl(path: string): string {
    let base: string = this.config.serverUrl;
    if (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (path.length > 0 && !path.startsWith('/')) {
      return base + '/' + path;
    }
    return base + path;
  }

  private splitPath(path: string): string[] {
    let cleaned: string = path;
    while (cleaned.length > 0 && cleaned.charAt(0) === '/') {
      cleaned = cleaned.substring(1);
    }
    while (cleaned.length > 0 && cleaned.charAt(cleaned.length - 1) === '/') {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (cleaned.length === 0) {
      return [];
    }
    const parts: string[] = [];
    let current: string = '';
    for (let i = 0; i < cleaned.length; i++) {
      const ch: string = cleaned.charAt(i);
      if (ch === '/') {
        if (current.length > 0) {
          parts.push(current);
          current = '';
        }
      } else {
        current = current + ch;
      }
    }
    if (current.length > 0) {
      parts.push(current);
    }
    return parts;
  }

  private parseMultiStatus(xmlBody: string, requestPath: string): WebDavResource[] {
    const results: WebDavResource[] = [];
    const responses: string[] = this.splitByTag(xmlBody, '<d:response>');
    for (let i = 0; i < responses.length; i++) {
      const block: string = responses[i];
      const href: string = this.extractTagContent(block, 'd:href');
      if (href.length === 0) {
        continue;
      }
      const isDir: boolean = block.indexOf('<d:collection/>') >= 0 || block.indexOf('<d:collection />') >= 0;
      const lastMod: string = this.extractTagContent(block, 'd:getlastmodified');
      const contentLen: string = this.extractTagContent(block, 'd:getcontentlength');
      const len: number = contentLen.length > 0 ? this.parseIntSafe(contentLen) : 0;
      const resource: WebDavResource = {
        href: href,
        lastModified: lastMod,
        contentLength: len,
        isDirectory: isDir
      };
      results.push(resource);
    }
    if (results.length > 0) {
      const firstHref: string = results[0].href;
      const filtered: WebDavResource[] = [];
      for (let i = 0; i < results.length; i++) {
        if (results[i].href !== firstHref) {
          filtered.push(results[i]);
        }
      }
      return filtered;
    }
    return results;
  }

  private splitByTag(xml: string, openTag: string): string[] {
    const results: string[] = [];
    const closeTag: string = openTag.replace('<', '</');
    let start: number = 0;
    while (true) {
      const idx: number = xml.indexOf(openTag, start);
      if (idx < 0) {
        break;
      }
      const endIdx: number = xml.indexOf(closeTag, idx);
      if (endIdx < 0) {
        break;
      }
      results.push(xml.substring(idx, endIdx + closeTag.length));
      start = endIdx + closeTag.length;
    }
    return results;
  }

  private extractTagContent(xml: string, tag: string): string {
    const openTag: string = '<' + tag + '>';
    const closeTag: string = '</' + tag + '>';
    const start: number = xml.indexOf(openTag);
    if (start < 0) {
      return '';
    }
    const contentStart: number = start + openTag.length;
    const end: number = xml.indexOf(closeTag, contentStart);
    if (end < 0) {
      return '';
    }
    return xml.substring(contentStart, end).trim();
  }

  private parseIntSafe(s: string): number {
    const n: number = parseInt(s, 10);
    return isNaN(n) ? 0 : n;
  }
}
