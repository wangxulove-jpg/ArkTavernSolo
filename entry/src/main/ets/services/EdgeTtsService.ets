import { webSocket } from '@kit.NetworkKit';
import { http } from '@kit.NetworkKit';
import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Logger } from '../utils/Logger';
import { TtsReadMode } from '../models/TtsReadMode';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const LOG_TAG: string = 'EdgeTtsService';

const TRUSTED_CLIENT_TOKEN: string = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const SEC_MS_GEC_VERSION: string = '1-143.0.3650.75';
// Windows file time epoch (1601-01-01 UTC) expressed in ms, so the Sec-MS-GEC
// tick computation can be done exactly with BigInt (the hand-rolled float path
// previously produced an incorrect token).
const WIN_EPOCH_MS: bigint = 11644473600000n;

const EDGE_TTS_VOICES_URL: string =
  'https://speech.platform.bing.com/consumer/speech/synthesize/readaloud/voices/list' +
  '?trustedclienttoken=' + TRUSTED_CLIENT_TOKEN;

interface EdgeVoiceInfo {
  ShortName: string;
  Gender: string;
  Locale: string;
  FriendlyName: string;
}

export class EdgeTtsService {
  private ws: webSocket.WebSocket | null = null;
  private _isSpeaking: boolean = false;
  private _readMode: TtsReadMode = TtsReadMode.Off;
  private _voiceName: string = 'zh-CN-XiaoxiaoNeural';
  private _rate: string = '+0%';
  private _volume: string = '+0%';
  private _pitch: string = '+0Hz';
  private audioChunks: ArrayBuffer[] = [];
  private requestId: string = '';
  private onSpeakCompleteCallback: (() => void) | null = null;
  private onSpeakStartCallback: (() => void) | null = null;
  private synthesisComplete: boolean = false;
  private availableVoices: EdgeVoiceInfo[] = [];
  private voicesLoaded: boolean = false;
  private appContext: common.Context | null = null;
  private avPlayer: media.AVPlayer | null = null;
  private tempFilePath: string = '';
  private tempFile: fileIo.File | null = null;

  get isSpeaking(): boolean {
    return this._isSpeaking;
  }

  get readMode(): TtsReadMode {
    return this._readMode;
  }

  set readMode(value: TtsReadMode) {
    this._readMode = value;
  }

  get voiceName(): string {
    return this._voiceName;
  }

  set voiceName(value: string) {
    this._voiceName = value;
  }

  get speed(): number {
    const num: number = parseInt(this._rate, 10);
    if (isNaN(num)) {
      return 1.0;
    }
    return 1.0 + num / 100.0;
  }

  set speed(value: number) {
    const pct: number = Math.round((value - 1.0) * 100);
    this._rate = (pct >= 0 ? '+' : '') + String(pct) + '%';
  }

  get volume(): number {
    const num: number = parseInt(this._volume, 10);
    if (isNaN(num)) {
      return 1.0;
    }
    return 1.0 + num / 100.0;
  }

  set volume(value: number) {
    const pct: number = Math.round((value - 1.0) * 100);
    this._volume = (pct >= 0 ? '+' : '') + String(pct) + '%';
  }

  get pitch(): number {
    const num: number = parseInt(this._pitch, 10);
    if (isNaN(num)) {
      return 1.0;
    }
    return 1.0 + num / 200.0;
  }

  set pitch(value: number) {
    const hz: number = Math.round((value - 1.0) * 200);
    this._pitch = (hz >= 0 ? '+' : '') + String(hz) + 'Hz';
  }

  get isVoicesLoaded(): boolean {
    return this.voicesLoaded;
  }

  setContext(ctx: common.Context): void {
    this.appContext = ctx;
  }

  getVoices(): EdgeVoiceInfo[] {
    return this.availableVoices;
  }

  getChineseVoices(): EdgeVoiceInfo[] {
    const result: EdgeVoiceInfo[] = [];
    for (let i = 0; i < this.availableVoices.length; i++) {
      if (this.availableVoices[i].Locale.startsWith('zh-')) {
        result.push(this.availableVoices[i]);
      }
    }
    return result;
  }

  async fetchVoices(): Promise<boolean> {
    if (this.voicesLoaded) {
      return true;
    }
    try {
      const httpRequest: http.HttpRequest = http.createHttp();
      const response: http.HttpResponse = await httpRequest.request(EDGE_TTS_VOICES_URL, {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/json',
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0'
        }
      });
      const body: string = response.result as string;
      const parsed: Object[] = JSON.parse(body) as Object[];
      this.availableVoices = [];
      for (let i = 0; i < parsed.length; i++) {
        const item: Record<string, string> = parsed[i] as Record<string, string>;
        const info: EdgeVoiceInfo = {
          ShortName: item['ShortName'] ?? '',
          Gender: item['Gender'] ?? '',
          Locale: item['Locale'] ?? '',
          FriendlyName: item['FriendlyName'] ?? ''
        };
        if (info.ShortName.length > 0) {
          this.availableVoices.push(info);
        }
      }
      this.voicesLoaded = true;
      httpRequest.destroy();
      Logger.info(LOG_TAG, 'fetchVoices: loaded ' + String(this.availableVoices.length) + ' voices');
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'fetchVoices failed: ' + (e instanceof Error ? e.message : String(e)));
      return false;
    }
  }

  private generateRequestId(): string {
    const hex: string[] = [];
    const chars: string = '0123456789abcdef';
    for (let i = 0; i < 32; i++) {
      const idx: number = Math.floor(Math.random() * 16);
      hex.push(chars[idx]);
    }
    return hex.join('');
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
    // Exact, BigInt-based computation (mirrors Python edge-tts DRM.generate_sec_ms_gec).
    const nowMs: bigint = BigInt(Date.now());
    let b: bigint = nowMs + WIN_EPOCH_MS;
    b -= b % 300000n;          // align to the 5-minute (300s) window
    const winTicks: bigint = b * 10000n; // seconds * 1e7 = 100-ns ticks
    const strToHash: string = winTicks.toString() + TRUSTED_CLIENT_TOKEN;

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

  private async buildWssUrl(): Promise<string> {
    const secMsGec: string = await this.generateSecMsGec();
    const connectionId: string = this.generateRequestId();
    return 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1' +
      '?TrustedClientToken=' + TRUSTED_CLIENT_TOKEN +
      '&Sec-MS-GEC=' + secMsGec +
      '&Sec-MS-GEC-Version=' + SEC_MS_GEC_VERSION +
      '&ConnectionId=' + connectionId;
  }

  async speak(text: string, onComplete?: () => void, onStart?: () => void): Promise<void> {
    if (this._readMode === TtsReadMode.Off) {
      return;
    }
    const processedText: string = this.processText(text);
    if (processedText.length === 0) {
      return;
    }
    if (this._isSpeaking) {
      this.stop();
    }

    this.onSpeakCompleteCallback = onComplete ?? null;
    this.onSpeakStartCallback = onStart ?? null;
    this.audioChunks = [];
    this.synthesisComplete = false;
    this.requestId = this.generateRequestId();
    this._isSpeaking = true;

    try {
      const wssUrl: string = await this.buildWssUrl();
      Logger.info(LOG_TAG, 'Connecting to: ' + wssUrl.substring(0, 100) + '...');

      this.ws = webSocket.createWebSocket();
      this.ws.on('open', (_err: BusinessError, _value: Object) => {
        this.onWsOpen(processedText);
      });
      this.ws.on('message', (_err: BusinessError, value: string | ArrayBuffer) => {
        this.onWsMessage(value);
      });
      this.ws.on('close', (_err: BusinessError, _value: webSocket.CloseResult) => {
        this.onWsClose();
      });
      this.ws.on('error', (err: BusinessError) => {
        // A code of 200 means the server answered the WebSocket upgrade with a
        // plain HTTP 200 instead of 101 Switching Protocols (it treated our
        // request as a normal HTTP request).  The other common failure is 403,
        // which means the Sec-MS-GEC token was rejected (clock skew / bad token)
        // and is a DIFFERENT problem from this 200.
        Logger.error(LOG_TAG, 'WebSocket error: code=' + String(err.code) + ' msg=' + String(err.message));
        if (err.code === 200) {
          Logger.error(LOG_TAG, 'Handshake got HTTP 200 (not 101): server treated request as plain HTTP. ' +
            'Check that the request carries a correct Origin + muid Cookie and NO Sec-WebSocket-Protocol.');
        } else if (err.code === 403) {
          Logger.error(LOG_TAG, 'Handshake got HTTP 403: Sec-MS-GEC was rejected. Check device clock (must be within 5 min of server) and the GEC algorithm.');
        }
        this._isSpeaking = false;
        if (this.onSpeakCompleteCallback !== null) {
          this.onSpeakCompleteCallback!();
        }
      });
      this.ws.on('headerReceive', (data: webSocket.ResponseHeaders) => {
        Logger.info(LOG_TAG, 'WS headerReceive: ' + JSON.stringify(data));
      });

      // Byte-for-byte reproduce the request that the working Python edge-tts
      // client sends.  Two things here were different from the valid handshake:
      //   1. `protocol: 'binary'` added a spurious `Sec-WebSocket-Protocol:
      //      binary` header.  Edge Read Aloud has NO subprotocol, so requesting
      //      one can make some Edge/CDN endpoints reject the upgrade back with a
      //      plain HTTP 200 instead of 101 Switching Protocols.
      //   2. The `Cookie: muid=<random>;` header (plus the standard Edge
      //      browser headers below) was missing.  The current service requires
      //      the muid cookie; without it some edges return 200.
      const connectOptions: webSocket.WebSocketRequestOptions = {
        header: {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0',
          'Accept-Encoding': 'gzip, deflate, br, zstd',
          'Accept-Language': 'en-US,en;q=0.9',
          'Pragma': 'no-cache',
          'Cache-Control': 'no-cache',
          'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
          'Cookie': 'muid=' + this.generateMuid() + ';'
        },
        // The working Python edge-tts client connects directly (no system
        // proxy).  The system proxy is enabled for webSocket by default, and a
        // proxy that does not forward WebSocket upgrades can turn the 101 into
        // a plain HTTP 200.  Force a direct connection to match the reference.
        proxy: 'no-proxy'
      };

      await this.ws.connect(wssUrl, connectOptions);
    } catch (e) {
      Logger.error(LOG_TAG, 'speak connect failed: ' + (e instanceof Error ? e.message : String(e)));
      this._isSpeaking = false;
      if (this.onSpeakCompleteCallback !== null) {
        this.onSpeakCompleteCallback!();
      }
    }
  }

  private onWsOpen(text: string): void {
    Logger.info(LOG_TAG, 'WebSocket connected');

    const configMsg: string =
      'X-Timestamp:' + this.getDateString() + '\r\n' +
      'Content-Type:application/json; charset=utf-8\r\n' +
      'Path:speech.config\r\n\r\n' +
      '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}';

    this.ws!.send(configMsg).catch((e: BusinessError) => {
      Logger.error(LOG_TAG, 'send config failed: ' + String(e.code));
    });

    const ssml: string =
      '<speak version=\'1.0\' xmlns=\'http://www.w3.org/2001/10/synthesis\' xml:lang=\'zh-CN\'>' +
      '<voice name=\'' + this._voiceName + '\'>' +
      '<prosody pitch=\'' + this._pitch + '\' rate=\'' + this._rate + '\' volume=\'' + this._volume + '\'>' +
      this.escapeXml(text) +
      '</prosody></voice></speak>';

    const ssmlMsg: string =
      'X-RequestId:' + this.requestId + '\r\n' +
      'Content-Type:application/ssml+xml\r\n' +
      'X-Timestamp:' + this.getDateString() + 'Z\r\n' +
      'Path:ssml\r\n\r\n' +
      ssml;

    this.ws!.send(ssmlMsg).catch((e: BusinessError) => {
      Logger.error(LOG_TAG, 'send ssml failed: ' + String(e.code));
    });
  }

  private onWsMessage(value: string | ArrayBuffer): void {
    if (typeof value === 'string') {
      const path: string = this.extractPath(value);
      if (path === 'turn.start') {
        Logger.info(LOG_TAG, 'TTS synthesis started');
        if (this.onSpeakStartCallback !== null) {
          this.onSpeakStartCallback!();
        }
      } else if (path === 'turn.end') {
        this.synthesisComplete = true;
        Logger.info(LOG_TAG, 'TTS synthesis complete, chunks=' + String(this.audioChunks.length));
        this.closeAndPlay();
      }
    } else {
      const data: ArrayBuffer = value as ArrayBuffer;
      const headerEnd: number = this.findAudioHeaderEnd(data);
      if (headerEnd >= 0 && headerEnd < data.byteLength) {
        const audioData: ArrayBuffer = data.slice(headerEnd);
        this.audioChunks.push(audioData);
      }
    }
  }

  private closeAndPlay(): void {
    if (this.ws !== null) {
      try {
        this.ws.close();
      } catch (_e) {}
      this.ws = null;
    }
    this.playAudioChunks();
  }

  private onWsClose(): void {
    Logger.info(LOG_TAG, 'WebSocket closed');
    this.ws = null;
    if (!this.synthesisComplete && this._isSpeaking) {
      this._isSpeaking = false;
      if (this.onSpeakCompleteCallback !== null) {
        this.onSpeakCompleteCallback!();
      }
    }
  }

  private findAudioHeaderEnd(data: ArrayBuffer): number {
    const view: Uint8Array = new Uint8Array(data);
    if (view.length < 2) {
      return -1;
    }
    const headerLength: number = (view[0] << 8) | view[1];
    const audioStart: number = 2 + headerLength;
    if (audioStart >= data.byteLength) {
      return -1;
    }
    return audioStart;
  }

  private extractPath(header: string): string {
    if (header.includes('Path:turn.start')) {
      return 'turn.start';
    }
    if (header.includes('Path:turn.end')) {
      return 'turn.end';
    }
    if (header.includes('Path:response')) {
      return 'response';
    }
    return '';
  }

  private async playAudioChunks(): Promise<void> {
    if (this.audioChunks.length === 0) {
      Logger.error(LOG_TAG, 'playAudioChunks: no audio data received');
      this._isSpeaking = false;
      if (this.onSpeakCompleteCallback !== null) {
        this.onSpeakCompleteCallback!();
      }
      return;
    }
    if (this.appContext === null) {
      Logger.error(LOG_TAG, 'no app context, cannot play');
      this._isSpeaking = false;
      if (this.onSpeakCompleteCallback !== null) {
        this.onSpeakCompleteCallback!();
      }
      return;
    }

    let totalLength: number = 0;
    for (let i = 0; i < this.audioChunks.length; i++) {
      totalLength += this.audioChunks[i].byteLength;
    }
    const merged: ArrayBuffer = new ArrayBuffer(totalLength);
    const mergedView: Uint8Array = new Uint8Array(merged);
    let offset: number = 0;
    for (let i = 0; i < this.audioChunks.length; i++) {
      const chunk: Uint8Array = new Uint8Array(this.audioChunks[i]);
      mergedView.set(chunk, offset);
      offset += chunk.byteLength;
    }

    Logger.info(LOG_TAG, 'playAudioChunks: total=' + String(totalLength) + ' bytes');

    try {
      const tempDir: string = this.appContext.tempDir;
      this.tempFilePath = tempDir + '/edge_tts_' + this.requestId + '.mp3';
      const wFile: fileIo.File = fileIo.openSync(this.tempFilePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.writeSync(wFile.fd, merged);
      fileIo.closeSync(wFile);

      // AVPlayer.url does NOT accept file:// paths (that's the 401 we saw).
      // It only accepts a fd:// URI or a network address.  Reopen the file for
      // reading so the fd is positioned at offset 0, then hand the fd to the
      // player and keep it open until playback is done.
      const rFile: fileIo.File = fileIo.openSync(this.tempFilePath, fileIo.OpenMode.READ_ONLY);
      this.tempFile = rFile;
      const playFd: number = rFile.fd;

      this.avPlayer = await media.createAVPlayer();
      this.avPlayer.on('stateChange', (state: string) => {
        Logger.info(LOG_TAG, 'AVPlayer state: ' + state);
        if (state === 'initialized') {
          // AVPlayer requires an explicit prepare() once the source is loaded
          // (the stateChange event has reached 'initialized'); without it the
          // player never moves to 'prepared' and play() is never called.
          if (this.avPlayer !== null) {
            this.avPlayer.prepare().catch((e: BusinessError) => {
              Logger.error(LOG_TAG, 'AVPlayer prepare failed: ' + String(e.code) + ' ' + e.message);
            });
          }
        } else if (state === 'prepared') {
          this.avPlayer!.play();
        } else if (state === 'completed' || state === 'stopped') {
          this._isSpeaking = false;
          this.releasePlayer();
          this.closeTempFile();
          this.cleanupTempFile();
          if (this.onSpeakCompleteCallback !== null) {
            this.onSpeakCompleteCallback!();
          }
        } else if (state === 'error') {
          this._isSpeaking = false;
          this.releasePlayer();
          this.closeTempFile();
          this.cleanupTempFile();
          if (this.onSpeakCompleteCallback !== null) {
            this.onSpeakCompleteCallback!();
          }
        }
      });
      this.avPlayer.on('error', (err: BusinessError) => {
        Logger.error(LOG_TAG, 'AVPlayer error: ' + String(err.code) + ' ' + err.message);
      });
      this.avPlayer.url = 'fd://' + String(playFd);
    } catch (e) {
      Logger.error(LOG_TAG, 'playAudioChunks failed: ' + (e instanceof Error ? e.message : String(e)));
      this._isSpeaking = false;
      this.closeTempFile();
      this.cleanupTempFile();
      if (this.onSpeakCompleteCallback !== null) {
        this.onSpeakCompleteCallback!();
      }
    }
  }

  private closeTempFile(): void {
    if (this.tempFile !== null) {
      try {
        fileIo.closeSync(this.tempFile);
      } catch (_e) {}
      this.tempFile = null;
    }
  }

  private releasePlayer(): void {
    if (this.avPlayer !== null) {
      try {
        this.avPlayer.release();
      } catch (_e) {}
      this.avPlayer = null;
    }
  }

  private cleanupTempFile(): void {
    if (this.tempFilePath.length > 0) {
      try {
        fileIo.unlinkSync(this.tempFilePath);
      } catch (_e) {}
      this.tempFilePath = '';
    }
  }

  stop(): void {
    if (this.avPlayer !== null) {
      try {
        this.avPlayer.stop();
        this.avPlayer.release();
      } catch (_e) {}
      this.avPlayer = null;
    }
    this.closeTempFile();
    if (this.ws !== null) {
      try {
        this.ws.close();
      } catch (_e) {}
      this.ws = null;
    }
    this._isSpeaking = false;
    this.audioChunks = [];
    this.cleanupTempFile();
  }

  shutdown(): void {
    this.stop();
  }

  private processText(text: string): string {
    let result: string = text;
    if (this._readMode === TtsReadMode.QuotesOnly) {
      const quoted: string = this.extractQuotedText(text);
      if (quoted.length > 0) {
        result = quoted;
      } else {
        return '';
      }
    }
    result = result.trim();
    if (result.length > 10000) {
      result = result.slice(0, 10000);
    }
    return result;
  }

  private extractQuotedText(text: string): string {
    const parts: string[] = [];
    const quoteRegex: RegExp = new RegExp('["\u201C\u201E\u300C\u300E]([^"\u201D\u201F\u300D\u300F\\n]+)["\u201D\u201F\u300D\u300F]', 'g');
    let match: RegExpExecArray | null = quoteRegex.exec(text);
    while (match !== null) {
      if (match[1].trim().length > 0) {
        parts.push(match[1].trim());
      }
      match = quoteRegex.exec(text);
    }
    return parts.join('\u3002');
  }

  private escapeXml(text: string): string {
    let result: string = text;
    result = result.replace(new RegExp('&', 'g'), '&amp;');
    result = result.replace(new RegExp('<', 'g'), '&lt;');
    result = result.replace(new RegExp('>', 'g'), '&gt;');
    result = result.replace(new RegExp('"', 'g'), '&quot;');
    result = result.replace(new RegExp("'", 'g'), '&apos;');
    return result;
  }

  private getDateString(): string {
    const now: Date = new Date();
    const days: string[] = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    const months: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return days[now.getDay()] + ' ' +
      months[now.getMonth()] + ' ' +
      String(now.getDate()) + ' ' +
      String(now.getFullYear()) + ' ' +
      String(now.getHours()).padStart(2, '0') + ':' +
      String(now.getMinutes()).padStart(2, '0') + ':' +
      String(now.getSeconds()).padStart(2, '0') +
      ' GMT+0000 (Coordinated Universal Time)';
  }
}
