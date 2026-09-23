import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

/** 诊断日志文件名（应用沙箱 files 目录） */
const FILE_NAME: string = 'diag.log';

/**
 * 落盘诊断日志
 *
 * 为什么需要它：
 *   console / hilog 的输出需要连 hdc 才能看到，排查依赖环境。
 *   这里把关键事件直接追加写进沙箱文件，
 *   用 hdc shell cat 或 DevEco 的 Device File Browser 就能读到，
 *   从而用实际数据定位问题，而不是靠推测。
 *
 * 日志只追加不覆盖，并且限制最大条数，避免无限增长。
 */
export class DiagLog {
  private filePath: string;
  /** 已经写过的行数，用于截断保护 */
  private lineCount: number = 0;
  /** 最多保留的行数 */
  private static readonly MAX_LINES: number = 400;

  constructor(context: common.Context) {
    this.filePath = context.filesDir + '/' + FILE_NAME;
  }

  /** 日志文件绝对路径 */
  getFilePath(): string {
    return this.filePath;
  }

  /**
   * 追加一条日志（带时间戳）
   * 内部吞掉所有异常：诊断本身绝不能影响业务
   * @param tag 分类标签
   * @param message 内容
   */
  log(tag: string, message: string): void {
    try {
      const time: Date = new Date();
      const line: string = '[' + time.toISOString() + '] ' + tag + ' | ' + message + '\n';
      // 超过上限就整体重写，避免文件无限增大
      if (this.lineCount >= DiagLog.MAX_LINES) {
        this.rewrite(line);
        return;
      }
      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(line);
      const file = fileIo.openSync(
        this.filePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND
      );
      try {
        fileIo.writeSync(file.fd, bytes.buffer);
      } finally {
        fileIo.closeSync(file);
      }
      this.lineCount++;
    } catch (err) {
      // 忽略
    }
  }

  /** 重写整个文件（仅保留最新一行） */
  private rewrite(line: string): void {
    try {
      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(line);
      const file = fileIo.openSync(
        this.filePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(file.fd, bytes.buffer);
      } finally {
        fileIo.closeSync(file);
      }
      this.lineCount = 1;
    } catch (err) {
      // 忽略
    }
  }
}
