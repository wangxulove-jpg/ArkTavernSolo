import { HttpClient, HttpMethod, HttpRequestOptions, HttpHeaders } from '../network/core/HttpClient';
import { HarmonyHttpClient } from '../network/core/HarmonyHttpClient';
import { ProviderKeyStore } from '../storage/ProviderKeyStore';
import { ProviderConfigStore } from '../storage/ProviderConfigStore';
import { AppPreferences } from '../storage/AppPreferences';
import { ProviderConfig } from '../models/ProviderConfig';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'DeepSeekBalanceService';
const PREFS_KEY_SHOW_BALANCE: string = 'show_deepseek_balance';
const BALANCE_API_URL: string = 'https://api.deepseek.com/user/balance';

export interface DeepSeekBalanceInfo {
  totalBalance: string;
  usedBalance: string;
  currency: string;
}

export class DeepSeekBalanceService {
  private readonly httpClient: HttpClient;
  private readonly providerKeyStore: ProviderKeyStore;
  private readonly providerConfigStore: ProviderConfigStore;
  private readonly appPreferences: AppPreferences;
  private cachedBalance: DeepSeekBalanceInfo | null = null;
  private lastFetchTime: number = 0;
  private static readonly CACHE_TTL: number = 5 * 60 * 1000;

  constructor(
    httpClient: HttpClient,
    providerKeyStore: ProviderKeyStore,
    providerConfigStore: ProviderConfigStore,
    appPreferences: AppPreferences
  ) {
    this.httpClient = httpClient;
    this.providerKeyStore = providerKeyStore;
    this.providerConfigStore = providerConfigStore;
    this.appPreferences = appPreferences;
  }

  async isShowBalance(): Promise<boolean> {
    return this.appPreferences.getBoolean(PREFS_KEY_SHOW_BALANCE, false);
  }

  async setShowBalance(show: boolean): Promise<void> {
    await this.appPreferences.putBoolean(PREFS_KEY_SHOW_BALANCE, show);
    if (!show) {
      this.cachedBalance = null;
      this.lastFetchTime = 0;
    }
  }

  async isDeepSeekProvider(): Promise<boolean> {
    const currentId: string = await this.appPreferences.getString('current_provider_id', '');
    if (currentId.length === 0) {
      return false;
    }
    const configs: ProviderConfig[] = await this.providerConfigStore.list();
    for (let i = 0; i < configs.length; i++) {
      if (configs[i].id === currentId) {
        const lower: string = configs[i].baseUrl.toLowerCase();
        return lower.indexOf('deepseek') >= 0;
      }
    }
    return false;
  }

  async fetchBalance(): Promise<DeepSeekBalanceInfo | null> {
    const now: number = Date.now();
    if (this.cachedBalance !== null && (now - this.lastFetchTime) < DeepSeekBalanceService.CACHE_TTL) {
      return this.cachedBalance;
    }

    try {
      const currentId: string = await this.appPreferences.getString('current_provider_id', '');
      if (currentId.length === 0) {
        return null;
      }
      const apiKey: string | null = await this.providerKeyStore.readKey(currentId);
      if (apiKey === null || apiKey.length === 0) {
        return null;
      }

      const headers: HttpHeaders = new Map();
      headers.set('Authorization', 'Bearer ' + apiKey);
      headers.set('Content-Type', 'application/json');

      const options: HttpRequestOptions = {
        method: HttpMethod.GET,
        url: BALANCE_API_URL,
        headers: headers,
        connectTimeoutMs: 10000,
        readTimeoutMs: 10000
      };

      const response = await this.httpClient.request(options);
      if (response.statusCode !== 200) {
        Logger.warn(LOG_TAG, 'fetchBalance: status=' + response.statusCode.toString());
        return null;
      }

      const info: DeepSeekBalanceInfo | null = DeepSeekBalanceService.parseBalance(response.body);
      if (info !== null) {
        this.cachedBalance = info;
        this.lastFetchTime = now;
      }
      return info;
    } catch (e) {
      Logger.warn(LOG_TAG, 'fetchBalance failed: ' + String(e));
      return null;
    }
  }

  private static parseBalance(body: string): DeepSeekBalanceInfo | null {
    try {
      const obj: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      const balanceInfos: Object | undefined = obj['balance_infos'];
      if (balanceInfos === undefined || balanceInfos === null) {
        return null;
      }
      const infos: Object[] = balanceInfos as Object[];
      if (infos.length === 0) {
        return null;
      }
      const first: Record<string, string> = infos[0] as Record<string, string>;
      const total: string = first['total_balance'] !== undefined ? first['total_balance'] : '0';
      const used: string = first['granted_balance'] !== undefined ? first['granted_balance'] : '0';
      const currency: string = first['currency'] !== undefined ? first['currency'] : 'CNY';
      const result: DeepSeekBalanceInfo = {
        totalBalance: total,
        usedBalance: used,
        currency: currency
      };
      return result;
    } catch (e) {
      Logger.warn(LOG_TAG, 'parseBalance failed');
      return null;
    }
  }

  invalidateCache(): void {
    this.cachedBalance = null;
    this.lastFetchTime = 0;
  }
}
