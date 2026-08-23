import { webSocket } from '@kit.NetworkKit';
import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Logger } from '../utils/Logger';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const LOG_TAG: string = 'EdgeTtsTest';
const EDGE_TRUSTED_TOKEN: string = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const EDGE_SEC_MS_GEC_VERSION: string = '1-143.0.3650.75';

@Entry
@Component
struct EdgeTtsTestPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @State logText: string = '';
  @State isRunning: boolean = false;

  private addLog(msg: string): void {
    const now: Date = new Date();
    const ts: string = String(now.getHours()).padStart(2, '0') + ':' +
      String(now.getMinutes()).padStart(2, '0') + ':' +
      String(now.getSeconds()).padStart(2, '0') + '.' +
      String(now.getMilliseconds()).padStart(3, '0');
    this.logText += '[' + ts + '] ' + msg + '\n';
    Logger.info(LOG_TAG, msg);
  }

  private async testHttpVoices(): Promise<void> {
    this.addLog('=== TEST 1: HTTP voices list ===');
    try {
      const req: http.HttpRequest = http.createHttp();
      const resp: http.HttpResponse = await req.request(
        'https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list?trustedclienttoken=6A5AA1D4EAFF4E9FB37E23D68491D6F4',
        {
          method: http.RequestMethod.GET,
          header: {
            'Accept': 'application/json',
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
          }
        }
      );
      this.addLog('HTTP status: ' + String(resp.responseCode));
      this.addLog('Response length: ' + String((resp.result as string).length));
      req.destroy();
    } catch (e) {
      this.addLog('HTTP voices FAILED: ' + (e instanceof Error ? e.message : String(e)));
    }
  }

  private async testWsMinimal(): Promise<string> {
    return new Promise((resolve: (msg: string) => void) => {
      this.addLog('=== TEST 2: WebSocket minimal (no custom headers, fresh GEC) ===');
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      let result: string = 'pending';
      let settled: boolean = false;

      const done = (msg: string): void => {
        if (!settled) {
          settled = true;
          result = msg;
          try { ws.close(); } catch (_e) {}
          try { ws.off('open'); } catch (_e) {}
          try { ws.off('error'); } catch (_e) {}
          try { ws.off('close'); } catch (_e) {}
          try { ws.off('headerReceive'); } catch (_e) {}
          resolve(result);
        }
      };

      ws.on('headerReceive', (data: Record<string, string | string[] | undefined>): void => {
        this.addLog('[minimal] headerReceive: ' + JSON.stringify(data));
      });

      ws.on('open', (_err: BusinessError, _value: Object): void => {
        this.addLog('[minimal] OPEN success');
        done('open_success');
      });

      ws.on('error', (err: BusinessError): void => {
        this.addLog('[minimal] ERROR code=' + String(err.code) + ' msg=' + String(err.message));
        done('error_' + String(err.code));
      });

      ws.on('close', (_err: BusinessError, value: webSocket.CloseResult): void => {
        this.addLog('[minimal] CLOSE code=' + String(value.code) + ' reason=' + String(value.reason));
        done('close_' + String(value.code));
      });

      this.generateSecMsGec().then((gec: string): void => {
        const url: string = this.buildEdgeWssUrl(gec);
        ws.connect(url).then((v: boolean) => {
          this.addLog('[minimal] connect() returned: ' + String(v));
        }).catch((e: BusinessError) => {
          this.addLog('[minimal] connect() rejected: ' + String(e.code));
          done('connect_rejected');
        });
      }).catch((e: Error): void => {
        this.addLog('[minimal] GEC gen failed: ' + e.message);
        done('gec_failed');
      });

      setTimeout(() => {
        this.addLog('[minimal] TIMEOUT 5s');
        done('timeout');
      }, 5000);
    });
  }

  private async testWsCustomHeaders(): Promise<string> {
    return new Promise((resolve: (msg: string) => void) => {
      this.addLog('=== TEST 3: WebSocket with CORRECT edge-tts headers (positive control) ===');
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      let result: string = 'pending';
      let settled: boolean = false;

      const done = (msg: string): void => {
        if (!settled) {
          settled = true;
          result = msg;
          try { ws.close(); } catch (_e) {}
          try { ws.off('open'); } catch (_e) {}
          try { ws.off('error'); } catch (_e) {}
          try { ws.off('close'); } catch (_e) {}
          try { ws.off('headerReceive'); } catch (_e) {}
          resolve(result);
        }
      };

      ws.on('headerReceive', (data: Record<string, string | string[] | undefined>): void => {
        this.addLog('[headers] headerReceive: ' + JSON.stringify(data));
      });

      ws.on('open', (_err: BusinessError, _value: Object): void => {
        this.addLog('[headers] OPEN success');
        done('open_success');
      });

      ws.on('error', (err: BusinessError): void => {
        this.addLog('[headers] ERROR code=' + String(err.code) + ' msg=' + String(err.message));
        done('error_' + String(err.code));
      });

      ws.on('close', (_err: BusinessError, value: webSocket.CloseResult): void => {
        this.addLog('[headers] CLOSE code=' + String(value.code) + ' reason=' + String(value.reason));
        done('close_' + String(value.code));
      });

      this.generateSecMsGec().then((gec: string): void => {
        const url: string = this.buildEdgeWssUrl(gec);
        // No Sec-WebSocket-Protocol here: Edge Read Aloud has no subprotocol.
        ws.connect(url, {
          header: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
            'Accept-Encoding': 'gzip, deflate, br, zstd',
            'Accept-Language': 'en-US,en;q=0.9',
            'Pragma': 'no-cache',
            'Cache-Control': 'no-cache',
            'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
            'Cookie': 'muid=' + this.generateMuid() + ';'
          }
        }).then((v: boolean) => {
          this.addLog('[headers] connect() returned: ' + String(v));
        }).catch((e: BusinessError) => {
          this.addLog('[headers] connect() rejected: ' + String(e.code));
          done('connect_rejected');
        });
      }).catch((e: Error): void => {
        this.addLog('[headers] GEC gen failed: ' + e.message);
        done('gec_failed');
      });

      setTimeout(() => {
        this.addLog('[headers] TIMEOUT 5s');
        done('timeout');
      }, 5000);
    });
  }

  private testWsEchoServer(): Promise<string> {
    return new Promise((resolve: (msg: string) => void) => {
      this.addLog('=== TEST 4: WebSocket to public echo server ===');
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      let result: string = 'pending';
      let settled: boolean = false;

      const done = (msg: string): void => {
        if (!settled) {
          settled = true;
          result = msg;
          try { ws.close(); } catch (_e) {}
          try { ws.off('open'); } catch (_e) {}
          try { ws.off('error'); } catch (_e) {}
          try { ws.off('close'); } catch (_e) {}
          resolve(result);
        }
      };

      ws.on('open', (_err: BusinessError, _value: Object): void => {
        this.addLog('[echo] OPEN success - WebSocket works on this device');
        done('open_success');
      });

      ws.on('error', (err: BusinessError): void => {
        this.addLog('[echo] ERROR code=' + String(err.code) + ' msg=' + String(err.message));
        done('error_' + String(err.code));
      });

      ws.on('close', (_err: BusinessError, value: webSocket.CloseResult): void => {
        this.addLog('[echo] CLOSE code=' + String(value.code));
        done('close_' + String(value.code));
      });

      ws.connect('wss://echo.websocket.org').then((v: boolean) => {
        this.addLog('[echo] connect() returned: ' + String(v));
      }).catch((e: BusinessError) => {
        this.addLog('[echo] connect() rejected: ' + String(e.code));
        done('connect_rejected');
      });

      setTimeout(() => {
        this.addLog('[echo] TIMEOUT 5s');
        done('timeout');
      }, 5000);
    });
  }

  private testWsTtsHk(): Promise<string> {
    return new Promise((resolve: (msg: string) => void) => {
      this.addLog('=== TEST 5: WebSocket to speech.platform.bing.com (HK region) ===');
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      let result: string = 'pending';
      let settled: boolean = false;

      const done = (msg: string): void => {
        if (!settled) {
          settled = true;
          result = msg;
          try { ws.close(); } catch (_e) {}
          try { ws.off('open'); } catch (_e) {}
          try { ws.off('error'); } catch (_e) {}
          try { ws.off('close'); } catch (_e) {}
          try { ws.off('headerReceive'); } catch (_e) {}
          resolve(result);
        }
      };

      ws.on('headerReceive', (data: Record<string, string | string[] | undefined>): void => {
        this.addLog('[hk] headerReceive: ' + JSON.stringify(data));
      });

      ws.on('open', (_err: BusinessError, _value: Object): void => {
        this.addLog('[hk] OPEN success');
        done('open_success');
      });

      ws.on('error', (err: BusinessError): void => {
        this.addLog('[hk] ERROR code=' + String(err.code) + ' msg=' + String(err.message));
        done('error_' + String(err.code));
      });

      ws.on('close', (_err: BusinessError, value: webSocket.CloseResult): void => {
        this.addLog('[hk] CLOSE code=' + String(value.code) + ' reason=' + String(value.reason));
        done('close_' + String(value.code));
      });

      this.generateSecMsGec().then((gec: string): void => {
        const url: string = this.buildEdgeWssUrl(gec);
        ws.connect(url, {
          header: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
            'Accept-Encoding': 'gzip, deflate, br, zstd',
            'Accept-Language': 'en-US,en;q=0.9',
            'Pragma': 'no-cache',
            'Cache-Control': 'no-cache',
            'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
            'Cookie': 'muid=' + this.generateMuid() + ';'
          }
        }).then((v: boolean) => {
          this.addLog('[hk] connect() returned: ' + String(v));
        }).catch((e: BusinessError) => {
          this.addLog('[hk] connect() rejected: ' + String(e.code));
          done('connect_rejected');
        });
      }).catch((e: Error): void => {
        this.addLog('[hk] GEC gen failed: ' + e.message);
        done('gec_failed');
      });

      setTimeout(() => {
        this.addLog('[hk] TIMEOUT 8s');
        done('timeout');
      }, 8000);
    });
  }

  private generateUuid(): string {
    const chars: string = '0123456789abcdef';
    const segments: number[] = [8, 4, 4, 4, 12];
    let uuid: string = '';
    for (let s = 0; s < segments.length; s++) {
      if (s > 0) {
        uuid += '-';
      }
      for (let i = 0; i < segments[s]; i++) {
        uuid += chars[Math.floor(Math.random() * 16)];
      }
    }
    return uuid;
  }

  private buildEdgeWssUrl(gec: string): string {
    return 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1' +
      '?TrustedClientToken=' + EDGE_TRUSTED_TOKEN +
      '&Sec-MS-GEC=' + gec +
      '&Sec-MS-GEC-Version=' + EDGE_SEC_MS_GEC_VERSION +
      '&ConnectionId=' + this.generateUuid().replace(new RegExp('-', 'g'), '');
  }

  private generateMuid(): string {
    const chars: string = '0123456789ABCDEF';
    let s: string = '';
    for (let i = 0; i < 32; i++) {
      s += chars[Math.floor(Math.random() * 16)];
    }
    return s;
  }

  private async generateSecMsGec(): Promise<string> {
    const nowMs: bigint = BigInt(Date.now());
    let b: bigint = nowMs + 11644473600000n;
    b -= b % 300000n;
    const winTicks: bigint = b * 10000n;
    const strToHash: string = winTicks.toString() + EDGE_TRUSTED_TOKEN;
    const bytes: Uint8Array = new Uint8Array(strToHash.length);
    for (let i = 0; i < strToHash.length; i++) {
      bytes[i] = strToHash.charCodeAt(i) & 0xFF;
    }
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const out: cryptoFramework.DataBlob = await md.digest();
    const hexChars: string = '0123456789abcdef';
    let hex: string = '';
    for (let i = 0; i < out.data.length; i++) {
      hex += hexChars[(out.data[i] >> 4) & 0x0f];
      hex += hexChars[out.data[i] & 0x0f];
    }
    return hex.toUpperCase();
  }

  private async runAllTests(): Promise<void> {
    if (this.isRunning) {
      return;
    }
    this.isRunning = true;
    this.logText = '';

    await this.testHttpVoices();
    const r2: string = await this.testWsMinimal();
    this.addLog('TEST 2 result: ' + r2);
    const r3: string = await this.testWsCustomHeaders();
    this.addLog('TEST 3 result: ' + r3);
    const r4: string = await this.testWsEchoServer();
    this.addLog('TEST 4 result: ' + r4);
    const r5: string = await this.testWsTtsHk();
    this.addLog('TEST 5 result: ' + r5);

    this.addLog('=== ALL TESTS COMPLETE ===');
    this.isRunning = false;
  }

  build() {
    Column() {
      Row() {
        Text('Edge TTS WebSocket 诊断')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
        Button('运行')
          .height(32)
          .fontSize(14)
          .enabled(!this.isRunning)
          .onClick(() => { this.runAllTests(); })
      }
      .width('100%')
      .padding(16)
      .margin({ top: this.statusBarHeight })

      Scroll() {
        Text(this.logText)
          .fontSize(12)
          .fontColor(Color.White)
          .fontFamily('monospace')
          .width('100%')
          .padding(16)
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1a1a2e')
  }
}
