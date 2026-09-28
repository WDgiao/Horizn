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
 * ★ 2026-09-29 自检修正（三处都对应真实缺陷）：
 *
 *   ① 行数上限原先形同虚设
 *      `lineCount` 是实例字段、初值 0，**从不根据已存在的文件初始化**。
 *      于是每次冷启动计数归零，又能再追加满额 —— 文件照样无限增长。
 *      现在在构造函数里按已有文件的行数初始化。
 *
 *   ② 超限时只保留最新一行，恰恰会丢掉最该看的内容
 *      "排查问题时最有价值的日志"往往就是崩溃前那一段，
 *      而原实现一旦超限就把整个文件截成一行 —— 把证据抹掉了。
 *      现在改成保留**尾部 N 行**再追加新行。
 *
 *   ③ 写的是 `bytes.buffer` 而不是实际编码长度
 *      `encodeInto` 返回的是 Uint8Array 视图，其底层 ArrayBuffer 可能更大；
 *      把整个 buffer 交出去会写入多余的字节。同工程的 WatchHistory
 *      专门 slice 过并注释了这一点，这里漏了。
 *      现在统一 `slice(0, bytes.length)`。
 */

/** 超过这个行数就做一次"保留尾部"的压缩 */
const MAX_LINES: number = 2000;
/** 压缩后保留的行数 */
const KEEP_LINES: number = 800;

export class DiagLog {
  private filePath: string;
  /** 当前文件行数的估算值，用于触发压缩 */
  private lineCount: number = 0;

  constructor(context: common.Context) {
    this.filePath = context.filesDir + '/' + FILE_NAME;
    // 按已有文件初始化计数：否则每次冷启动都会重新拥有整份额度，
    // "限制最大条数"就完全失效了
    this.lineCount = this.countLinesFromDisk();
  }

  /** 日志文件绝对路径 */
  getFilePath(): string {
    return this.filePath;
  }

  /** 数一下现有文件有多少行（读不出来就当 0） */
  private countLinesFromDisk(): number {
    try {
      if (!fileIo.accessSync(this.filePath)) {
        return 0;
      }
      const stat = fileIo.statSync(this.filePath);
      if (stat.size <= 0) {
        return 0;
      }
      const file = fileIo.openSync(this.filePath, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(file.fd, buf, { offset: 0, length: stat.size });
        const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
        text = decoder.decodeToString(new Uint8Array(buf, 0, read));
      } finally {
        fileIo.closeSync(file);
      }
      let n: number = 0;
      for (let i = 0; i < text.length; i++) {
        if (text.charCodeAt(i) === 10) {
          n++;
        }
      }
      return n;
    } catch (err) {
      return 0;
    }
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
      if (this.lineCount >= MAX_LINES) {
        // 压缩时**保留尾部**，而不是只留最新一行 ——
        // 崩溃前那一段日志恰恰是最有价值的
        this.compress();
      }
      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(line);
      const file = fileIo.openSync(
        this.filePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND
      );
      try {
        // 只写实际编码的那一段（原先是 bytes.buffer，会多写底层缓冲的垃圾字节）
        fileIo.writeSync(file.fd, bytes.buffer.slice(0, bytes.length));
      } finally {
        fileIo.closeSync(file);
      }
      this.lineCount++;
    } catch (err) {
      // 忽略：诊断日志失败不影响业务
    }
  }

  /**
   * 压缩日志：读取现有内容，只保留尾部 KEEP_LINES 行后整体重写
   *
   * 为什么先读再写而不是直接截断：见文件头 ② 的说明 —— 要保住崩溃前那段。
   */
  private compress(): void {
    try {
      if (!fileIo.accessSync(this.filePath)) {
        this.lineCount = 0;
        return;
      }
      const stat = fileIo.statSync(this.filePath);
      if (stat.size <= 0) {
        this.lineCount = 0;
        return;
      }
      const src = fileIo.openSync(this.filePath, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const buf: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(src.fd, buf, { offset: 0, length: stat.size });
        const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
        text = decoder.decodeToString(new Uint8Array(buf, 0, read));
      } finally {
        fileIo.closeSync(src);
      }

      const lines: string[] = text.split('\n');
      // split 会在末尾留一个空串，去掉以免多算一行
      if (lines.length > 0 && lines[lines.length - 1].length === 0) {
        lines.pop();
      }
      const kept: string[] = lines.length > KEEP_LINES
        ? lines.slice(lines.length - KEEP_LINES)
        : lines;

      const encoder: util.TextEncoder = new util.TextEncoder();
      const bytes: Uint8Array = encoder.encodeInto(kept.join('\n') + '\n');
      const dst = fileIo.openSync(
        this.filePath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
      );
      try {
        fileIo.writeSync(dst.fd, bytes.buffer.slice(0, bytes.length));
      } finally {
        fileIo.closeSync(dst);
      }
      this.lineCount = kept.length;
    } catch (err) {
      // 压缩失败不要卡住后续写入：给个保守值，下一条还会再试
      this.lineCount = 0;
    }
  }
}
