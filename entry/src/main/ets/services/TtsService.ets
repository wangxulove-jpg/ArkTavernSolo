import { textToSpeech } from '@kit.CoreSpeechKit';
import { Logger } from '../utils/Logger';
import { TtsReadMode } from '../models/TtsReadMode';

const LOG_TAG: string = 'TtsService';

const TTS_MAX_CHARS: number = 10000;

export class TtsService {
  private engine: textToSpeech.TextToSpeechEngine | null = null;
  private speakRequestId: number = 0;
  private _isSpeaking: boolean = false;
  private _readMode: TtsReadMode = TtsReadMode.Off;
  private _speed: number = 1.0;
  private _volume: number = 1.0;
  private _pitch: number = 1.0;
  private _voicePerson: number = 13;
  private _autoPlay: boolean = false;
  private _language: string = 'zh-CN';
  private onSpeakCompleteCallback: (() => void) | null = null;
  private onSpeakStartCallback: (() => void) | null = null;

  get isSpeaking(): boolean {
    return this._isSpeaking;
  }

  get readMode(): TtsReadMode {
    return this._readMode;
  }

  set readMode(value: TtsReadMode) {
    this._readMode = value;
  }

  get speed(): number {
    return this._speed;
  }

  set speed(value: number) {
    this._speed = Math.max(0.5, Math.min(2.0, value));
  }

  get volume(): number {
    return this._volume;
  }

  set volume(value: number) {
    this._volume = Math.max(0, Math.min(2.0, value));
  }

  get pitch(): number {
    return this._pitch;
  }

  set pitch(value: number) {
    this._pitch = Math.max(0.5, Math.min(2.0, value));
  }

  get voicePerson(): number {
    return this._voicePerson;
  }

  set voicePerson(value: number) {
    this._voicePerson = value;
    if (this.engine !== null) {
      this.shutdown();
    }
  }

  get autoPlay(): boolean {
    return this._autoPlay;
  }

  set autoPlay(value: boolean) {
    this._autoPlay = value;
  }

  get language(): string {
    return this._language;
  }

  set language(value: string) {
    this._language = value;
    if (this.engine !== null) {
      this.shutdown();
    }
  }

  private async ensureEngine(): Promise<boolean> {
    if (this.engine !== null) {
      return true;
    }
    try {
      const extraParam: Record<string, Object> = {
        'style': 'interaction-broadcast',
        'locate': 'CN',
        'name': 'ArkTavernTTS'
      };
      const initParams: textToSpeech.CreateEngineParams = {
        language: this._language,
        person: this._voicePerson,
        online: 1,
        extraParams: extraParam
      };
      this.engine = await textToSpeech.createEngine(initParams);
      const listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, _response: textToSpeech.StartResponse): void => {
          Logger.info(LOG_TAG, 'TTS onStart: ' + requestId);
          this._isSpeaking = true;
          if (this.onSpeakStartCallback !== null) {
            this.onSpeakStartCallback!();
          }
        },
        onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
          Logger.info(LOG_TAG, 'TTS onComplete: ' + requestId + ' type=' + String(response.type));
          if (response.type === 1) {
            this._isSpeaking = false;
            if (this.onSpeakCompleteCallback !== null) {
              this.onSpeakCompleteCallback!();
            }
          }
        },
        onStop: (requestId: string, _response: textToSpeech.StopResponse): void => {
          Logger.info(LOG_TAG, 'TTS onStop: ' + requestId);
          this._isSpeaking = false;
        },
        onData: (requestId: string, _audio: ArrayBuffer, _response: textToSpeech.SynthesisResponse): void => {
        },
        onError: (requestId: string, errorCode: number, errorMessage: string): void => {
          Logger.error(LOG_TAG, 'TTS onError: ' + requestId + ' code=' + String(errorCode) + ' msg=' + errorMessage);
          this._isSpeaking = false;
          if (this.onSpeakCompleteCallback !== null) {
            this.onSpeakCompleteCallback!();
          }
        }
      };
      this.engine.setListener(listener);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'createEngine failed: ' + (e instanceof Error ? e.message : String(e)));
      this.engine = null;
      return false;
    }
  }

  async speak(text: string, onComplete?: () => void, onStart?: () => void): Promise<void> {
    if (this._readMode === TtsReadMode.Off) {
      return;
    }
    const processedText: string = this.processText(text);
    if (processedText.length === 0) {
      return;
    }
    const engineReady: boolean = await this.ensureEngine();
    if (!engineReady) {
      Logger.error(LOG_TAG, 'speak: engine not available');
      return;
    }
    if (this._isSpeaking) {
      this.stop();
    }
    this.onSpeakCompleteCallback = onComplete ?? null;
    this.onSpeakStartCallback = onStart ?? null;
    this.speakRequestId++;
    const extraParam: Record<string, Object> = {
      'speed': this._speed,
      'volume': this._volume,
      'pitch': this._pitch,
      'languageContext': this._language,
      'audioType': 'pcm',
      'playType': 1,
      'queueMode': 1
    };
    const speakParams: textToSpeech.SpeakParams = {
      requestId: 'tts-' + String(this.speakRequestId),
      extraParams: extraParam
    };
    try {
      this.engine!.speak(processedText, speakParams);
    } catch (e) {
      Logger.error(LOG_TAG, 'speak failed: ' + (e instanceof Error ? e.message : String(e)));
      this._isSpeaking = false;
    }
  }

  stop(): void {
    if (this.engine !== null && this._isSpeaking) {
      try {
        this.engine.stop();
      } catch (e) {
        Logger.error(LOG_TAG, 'stop failed: ' + (e instanceof Error ? e.message : String(e)));
      }
      this._isSpeaking = false;
    }
  }

  shutdown(): void {
    this.stop();
    if (this.engine !== null) {
      try {
        this.engine.shutdown();
      } catch (e) {
        Logger.error(LOG_TAG, 'shutdown failed: ' + (e instanceof Error ? e.message : String(e)));
      }
      this.engine = null;
    }
  }

  private processText(text: string): string {
    let result: string = text;
    if (this._readMode === TtsReadMode.QuotesOnly) {
      result = this.extractQuotedText(text);
    }
    result = result.trim();
    if (result.length > TTS_MAX_CHARS) {
      result = result.slice(0, TTS_MAX_CHARS);
    }
    return result;
  }

  private extractQuotedText(text: string): string {
    const parts: string[] = [];
    const doubleQuoteRegex: RegExp = /"([^"]*)"/g;
    let match: RegExpExecArray | null = doubleQuoteRegex.exec(text);
    while (match !== null) {
      if (match[1].trim().length > 0) {
        parts.push(match[1].trim());
      }
      match = doubleQuoteRegex.exec(text);
    }
    const cornerBracketRegex: RegExp = /「([^」]*)」/g;
    match = cornerBracketRegex.exec(text);
    while (match !== null) {
      if (match[1].trim().length > 0) {
        parts.push(match[1].trim());
      }
      match = cornerBracketRegex.exec(text);
    }
    return parts.join('。');
  }
}
