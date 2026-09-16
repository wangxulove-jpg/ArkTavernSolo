/**
 * LogBuffer 诊断日志缓冲
 *
 * 职责:
 * - 内存环形缓冲:收集 Logger 输出的所有日志(脱敏后),限制条数与总字符数
 * - 磁盘镜像:error 级日志触发防抖落盘,应用崩溃/重启后历史日志仍可导出
 * - 导出:拼接为纯文本,供设置页保存到用户选择的位置
 *
 * 设计:
 * - append 为纯内存同步操作,不阻塞调用方
 * - 落盘写全量文本到 filesDir/diagnostics.log,失败静默(不影响主流程)
 * - 不使用 Logger(避免递归),内部异常一律静默吞掉
 * - init 需在 EntryAbility.onCreate 中尽早调用,并加载上次落盘的历史日志
 */

import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';

/** 缓冲最大条数(超出丢弃最旧) */
const MAX_ENTRIES: number = 4000;
/** 缓冲最大总字符数(超出丢弃最旧) */
const MAX_TOTAL_CHARS: number = 2000000;
/** error 触发落盘的防抖间隔(毫秒) */
const FLUSH_DEBOUNCE_MS: number = 2000;
/** 距上次落盘新增条数达到该值时也触发落盘 */
const FLUSH_INTERVAL_ENTRIES: number = 500;
/** 磁盘镜像文件名(位于 filesDir) */
const LOG_FILE_NAME: string = 'diagnostics.log';

export class LogBuffer {
  private static entries: string[] = [];
  private static totalChars: number = 0;
  private static entriesSinceFlush: number = 0;
  private static logFilePath: string = '';
  private static initialized: boolean = false;
  private static flushTimerId: number = -1;
  private static flushInFlight: boolean = false;

  /**
   * 初始化(EntryAbility.onCreate 尽早调用)。
   * 加载上次落盘的历史日志到缓冲,并记录本次启动标记。
   * 重复调用只追加启动标记,不重复加载。
   */
  static init(context: common.UIAbilityContext): void {
    if (LogBuffer.initialized) {
      return;
    }
    LogBuffer.initialized = true;
    try {
      LogBuffer.logFilePath = context.filesDir + '/' + LOG_FILE_NAME;
      LogBuffer.loadFromDisk();
    } catch (_e) {
      // 读取失败:从空缓冲开始,不影响启动
    }
    LogBuffer.appendLine('===== 应用启动 ' + LogBuffer.nowText() + ' =====');
  }

  /**
   * 追加一条日志(由 Logger 调用,内容已脱敏)。
   * @param level 级别缩写(D/I/W/E)
   * @param tag 调用方标签
   * @param message 已格式化的安全消息
   */
  static append(level: string, tag: string, message: string): void {
    LogBuffer.appendLine(LogBuffer.nowText() + ' ' + level + '/' + tag + ': ' + message);
  }

  /**
   * 拼接全部日志为纯文本(导出用)。
   */
  static getLogText(): string {
    return LogBuffer.entries.join('\n');
  }

  /**
   * 当前缓冲条数(供 UI 显示)。
   */
  static getEntryCount(): number {
    return LogBuffer.entries.length;
  }

  /**
   * 清空缓冲并删除磁盘镜像。
   */
  static clear(): void {
    LogBuffer.entries = [];
    LogBuffer.totalChars = 0;
    LogBuffer.entriesSinceFlush = 0;
    if (LogBuffer.logFilePath.length > 0) {
      try {
        fileIo.unlinkSync(LogBuffer.logFilePath);
      } catch (_e) {
        // 文件不存在:忽略
      }
    }
  }

  /**
   * 立即落盘(导出前调用,确保磁盘镜像最新;失败静默)。
   */
  static async flushToDisk(): Promise<void> {
    LogBuffer.writeToDisk();
  }

  private static appendLine(line: string): void {
    LogBuffer.entries.push(line);
    LogBuffer.totalChars += line.length;
    LogBuffer.entriesSinceFlush++;
    // 超限时丢弃最旧
    while (LogBuffer.entries.length > MAX_ENTRIES
      || (LogBuffer.totalChars > MAX_TOTAL_CHARS && LogBuffer.entries.length > 1)) {
      const dropped: string | undefined = LogBuffer.entries.shift();
      if (dropped === undefined) {
        break;
      }
      LogBuffer.totalChars -= dropped.length;
    }
    // error 高频场景防抖落盘;常规日志按条数间隔落盘
    if (LogBuffer.logFilePath.length > 0
      && (line.indexOf(' E/') >= 0 || LogBuffer.entriesSinceFlush >= FLUSH_INTERVAL_ENTRIES)) {
      LogBuffer.scheduleFlush();
    }
  }

  private static scheduleFlush(): void {
    if (LogBuffer.flushTimerId >= 0) {
      return;
    }
    LogBuffer.flushTimerId = setTimeout((): void => {
      LogBuffer.flushTimerId = -1;
      LogBuffer.writeToDisk();
    }, FLUSH_DEBOUNCE_MS);
  }

  private static writeToDisk(): void {
    if (LogBuffer.logFilePath.length === 0 || LogBuffer.flushInFlight) {
      return;
    }
    LogBuffer.flushInFlight = true;
    let file: fileIo.File | null = null;
    try {
      const text: string = LogBuffer.entries.join('\n');
      file = fileIo.openSync(
        LogBuffer.logFilePath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      fileIo.writeSync(file.fd, text);
      LogBuffer.entriesSinceFlush = 0;
    } catch (_e) {
      // 落盘失败:静默,下次再试
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (_e) {
          // 关闭失败:忽略
        }
      }
      LogBuffer.flushInFlight = false;
    }
  }

  private static loadFromDisk(): void {
    try {
      if (!fileIo.accessSync(LogBuffer.logFilePath)) {
        return;
      }
      const text: string = fileIo.readTextSync(LogBuffer.logFilePath);
      if (text.trim().length === 0) {
        return;
      }
      const lines: string[] = text.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const line: string = lines[i];
        if (line.trim().length === 0) {
          continue;
        }
        LogBuffer.entries.push(line);
        LogBuffer.totalChars += line.length;
      }
      // 历史日志超限时保留最新部分
      while (LogBuffer.entries.length > MAX_ENTRIES
        || (LogBuffer.totalChars > MAX_TOTAL_CHARS && LogBuffer.entries.length > 1)) {
        const dropped: string | undefined = LogBuffer.entries.shift();
        if (dropped === undefined) {
          break;
        }
        LogBuffer.totalChars -= dropped.length;
      }
    } catch (_e) {
      // 读取失败:忽略
    }
  }

  private static nowText(): string {
    const d: Date = new Date();
    const pad = (n: number, width: number): string => {
      let s: string = n.toString();
      while (s.length < width) {
        s = '0' + s;
      }
      return s;
    };
    return pad(d.getMonth() + 1, 2) + '-' + pad(d.getDate(), 2)
      + ' ' + pad(d.getHours(), 2) + ':' + pad(d.getMinutes(), 2)
      + ':' + pad(d.getSeconds(), 2) + '.' + pad(d.getMilliseconds(), 3);
  }
}
