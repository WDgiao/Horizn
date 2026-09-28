import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { readJsonArraySafe, writeJsonArrayAtomic, AtomicWriteResult } from './JsonStore';

/** 观看记录落盘文件名（存在应用沙箱 files 目录） */
const FILE_NAME: string = 'watch_history.json';
/** 最多保留的记录条数 */
const MAX_RECORDS: number = 50;
/**
 * 判定用：剩余时间超过「时长 × 该比例」才算未播完
 * 即播到最后 5% 视为已看完（播放器很难精确停在最后一帧）
 */
const FINISHED_RATIO: number = 0.95;
/**
 * 已看完的剩余容差（毫秒）
 * 剩余不足这么多就算看完，避免"还剩 0.2 秒"这种无意义的续播
 */
const FINISHED_TAIL_MS: number = 1500;
/**
 * 视为短视频的时长阈值（毫秒）
 * 短视频不看比例，只按剩余时间判定 —— 否则 4 秒的视频会被 1500ms 的容差吞掉
 */
const SHORT_VIDEO_MS: number = 15000;
/**
 * 算作「有实际进度」的最小位置（毫秒）
 * 只看了开头不到 1 秒，不算作有进度，避免刚点开就进「继续观看」
 */
const MIN_POSITION_MS: number = 1000;

/** 单条观看记录 */
export interface WatchRecord {
  /** 视频绝对路径，作为唯一键 */
  path: string;
  /** 视频文件名，用于显示 */
  title: string;
  /** 上次播放位置（毫秒） */
  position: number;
  /** 视频总时长（毫秒） */
  duration: number;
  /** 最后观看时间戳（毫秒），用于排序 */
  updatedAt: number;
}

/**
 * 观看记录仓库
 *
 * 存储方式：应用沙箱 files 目录下的一个 JSON 文件。
 *
 * 为什么不用 Preferences：
 *   Preferences 的 putSync + flush 在部分环境（模拟器 / 特定存储模式）下
 *   存在写入不落盘的情况，排查成本高。
 *   而 fileIo 在本工程中已被播放页（openSync / statSync / closeSync）验证可用，
 *   因此改用最基础的「读文件 -> 改内存 -> 写回文件」，行为完全可预期。
 *
 * 性能考虑：内存里保留一份缓存，读操作直接走缓存，
 * 只有写操作才落盘，避免每次渲染都读磁盘。
 */
export class WatchHistory {
  /** 记录文件绝对路径 */
  private filePath: string;
  /** 内存缓存，undefined 表示尚未加载 */
  private cache: WatchRecord[] | undefined = undefined;

  constructor(context: common.Context) {
    this.filePath = context.filesDir + '/' + FILE_NAME;
  }

  /** 记录文件的绝对路径（便于排查） */
  getFilePath(): string {
    return this.filePath;
  }

  /**
   * 让内存缓存失效，下次读取会重新从磁盘加载
   * 用途：播放页刚写完最终进度时，首页需要立刻看到最新值
   */
  invalidateCache(): void {
    this.cache = undefined;
  }

  /**
   * 读取全部记录（按最后观看时间倒序）
   *
   * 会在返回前剔除「文件已不存在」的记录，见 pruneMissingFiles。
   */
  list(): WatchRecord[] {
    const all: WatchRecord[] = this.pruneMissingFiles(this.load());
    const copy: WatchRecord[] = all.slice(0);
    copy.sort((a: WatchRecord, b: WatchRecord): number => b.updatedAt - a.updatedAt);
    return copy;
  }

  /**
   * 剔除文件已经不存在的记录（惰性清理）
   *
   * ★ 2026-09-29 自检新增。要解决的问题：
   *   观看记录以**绝对路径**为唯一键，而文件操作（重命名 / 移动 / 删除）
   *   只动文件系统、不同步记录 —— 于是重命名或删除之后，旧路径的记录
   *   永远匹配不到新文件，变成"死记录"。
   *   首页「继续观看」是直接把记录渲染成卡片的、**不校验文件是否存在**，
   *   所以用户会看到一张点开必然报错的卡片；而且这条脏记录还占着
   *   MAX_RECORDS 的名额，会把真实记录挤掉。
   *
   * 为什么选"读的时候顺手清"而不是"在文件操作里同步"：
   *   · 需要同步的地方有三处（rename / move / remove），且将来任何新的
   *     文件操作都要记得加 —— 漏一处就有新的死记录，属于容易漂移的设计
   *   · 而"列表里不该出现打不开的条目"是**读取方自己的需求**，
   *     放在读取侧一次性解决，任何来源的脏数据都能被兜住
   *   · 代价是要做若干次 accessSync。记录上限是 MAX_RECORDS(50)，
   *     stat 类调用一次几微秒，实测可忽略
   *
   * @param records 原始记录
   * @returns 文件仍然存在的记录；若有剔除则顺带落盘
   */
  private pruneMissingFiles(records: WatchRecord[]): WatchRecord[] {
    const kept: WatchRecord[] = [];
    let removed: number = 0;
    for (let i = 0; i < records.length; i++) {
      const r: WatchRecord = records[i];
      // 网络流地址不是沙箱路径，不适用"文件是否存在"的判断
      if (r.path.indexOf('://') >= 0) {
        kept.push(r);
        continue;
      }
      let exists: boolean = false;
      try {
        exists = fileIo.accessSync(r.path);
      } catch (err) {
        // 路径异常（非法字符等）一律当不存在
        exists = false;
      }
      if (exists) {
        kept.push(r);
      } else {
        removed++;
      }
    }
    if (removed > 0) {
      console.info('[WatchHistory] 清理了 ' + removed.toString() + ' 条失效记录（文件已不存在）');
      // 落盘一次，避免每次读都要重新判一遍
      this.cache = kept;
      this.persist(kept);
    }
    return kept;
  }

  /**
   * 判断一条记录是否「还没看完」
   *
   * 判定用两道条件：
   *   1) 剩余时间 > max(时长 × 5%, 5 秒)  → 没播到尾巴
   *   2) 已播位置 >= 1 秒                 → 确实看过一点
   *
   * 第 1 条用「剩余」而非「位置」，是为了让短视频也能正确判定：
   * 一个 4 秒的视频，播到 3.5 秒时剩余 0.5 秒 < 5 秒，应算看完；
   * 而如果按「位置 < 时长 × 0.98」算，4 秒视频播到 2 秒就只剩 2 秒余量，
   * 逻辑上没错，但对用户「我就想继续看刚才那 2 秒」的预期不够宽容。
   *
   * @param record 观看记录
   */
  static isUnfinished(record: WatchRecord): boolean {
    if (record.duration <= 0) {
      return false;
    }
    if (record.position < MIN_POSITION_MS) {
      return false;
    }
    const remain: number = record.duration - record.position;
    if (record.duration < SHORT_VIDEO_MS) {
      // 短视频：剩余超过 1.5 秒就算未播完（4 秒视频播到 2 秒 → 未播完 ✅）
      return remain > FINISHED_TAIL_MS;
    }
    // 长视频：取「比例容差」与「时间容差」中较大的一个
    // 例：31.8 秒的视频 → max(31.8 × 5% = 1.59 秒, 1.5 秒) ≈ 1.59 秒
    const tolerance: number = Math.max(record.duration * (1 - FINISHED_RATIO), FINISHED_TAIL_MS);
    return remain > tolerance;
  }

  /** 读取「继续观看」列表：未播完且有实际进度 */
  listUnfinished(): WatchRecord[] {
    const all: WatchRecord[] = this.list();
    const result: WatchRecord[] = [];
    for (let i = 0; i < all.length; i++) {
      const r: WatchRecord = all[i];
      if (WatchHistory.isUnfinished(r)) {
        result.push(r);
      }
    }
    return result;
  }

  /**
   * 计算某条记录应该从哪里续播（毫秒）
   * 已看完或几乎没有进度时返回 0，表示从头播
   * @param record 观看记录
   */
  static resumePosition(record: WatchRecord): number {
    if (!WatchHistory.isUnfinished(record)) {
      return 0;
    }
    return Math.max(0, Math.floor(record.position));
  }

  /** 取最近一条未播完的记录，用于首页焦点推荐位 */
  latestUnfinished(): WatchRecord | undefined {
    const list: WatchRecord[] = this.listUnfinished();
    return list.length > 0 ? list[0] : undefined;
  }

  /** 按路径查记录 */
  find(path: string): WatchRecord | undefined {
    const all: WatchRecord[] = this.load();
    for (let i = 0; i < all.length; i++) {
      if (all[i].path === path) {
        return all[i];
      }
    }
    return undefined;
  }

  /**
   * 写入/更新一条记录（同时落盘）
   * @param path 视频绝对路径
   * @param title 显示名
   * @param position 当前播放位置（毫秒）
   * @param duration 总时长（毫秒）
   */
  save(path: string, title: string, position: number, duration: number): void {
    if (path.length === 0) {
      return;
    }
    // ★ 2026-09-29 自检加固：原先只有 `duration <= 0` 一道闸，挡不住 NaN。
    //
    //   `NaN <= 0` 的结果是 **false**，所以 NaN 时长能顺利通过检查；
    //   而 positionMs/durationMs 是直接来自原生事件的（畸形容器会报异常值）。
    //   一旦写入，`JSON.stringify(NaN)` 会变成 `null`；下次读回来
    //   `typeof null !== 'number'`（load 里会过滤掉）或 `null <= 0` 为 true，
    //   这条记录就被当成"已看完" —— 用户的续播点**永久**丢失。
    //
    //   另外 position 也要夹到 [0, duration]：
    //   seek 越界或时钟回退时可能报出 position > duration，
    //   首页按 position/duration 画进度条就会画出界（>1）。
    if (!Number.isFinite(duration) || duration <= 0) {
      return;
    }
    if (!Number.isFinite(position)) {
      return;
    }
    const safePosition: number = Math.min(Math.max(position, 0), duration);

    const all: WatchRecord[] = this.load();
    const record: WatchRecord = {
      path: path,
      title: title,
      position: safePosition,
      duration: duration,
      updatedAt: Date.now()
    };
    // 同路径只保留最新一条
    const next: WatchRecord[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].path !== path) {
        next.push(all[i]);
      }
    }
    next.push(record);
    next.sort((a: WatchRecord, b: WatchRecord): number => b.updatedAt - a.updatedAt);
    const trimmed: WatchRecord[] = next.slice(0, MAX_RECORDS);
    this.cache = trimmed;
    const result: string = this.persist(trimmed);
    if (result.indexOf('ok ') !== 0) {
      console.error('persist not clean: ' + result);
    }
    this.lastPersistResult = result + ' (in-memory=' + trimmed.length.toString() + ')';
  }

  /** 最近一次写盘的结果描述，供界面诊断展示 */
  lastPersistResult: string = '(尚未写入)';

  /** 取最近一次写盘结果 */
  getLastPersistResult(): string {
    return this.lastPersistResult;
  }

  /** 删除一条记录 */
  remove(path: string): void {
    const all: WatchRecord[] = this.load();
    const next: WatchRecord[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].path !== path) {
        next.push(all[i]);
      }
    }
    this.cache = next;
    this.persist(next);
  }

  /** 清空全部记录 */
  clear(): void {
    this.cache = [];
    this.persist([]);
  }

  /** 取内存缓存；首次访问时从磁盘加载 */
  private load(): WatchRecord[] {
    const cached: WatchRecord[] | undefined = this.cache;
    if (cached !== undefined) {
      return cached;
    }
    // 交给公共模块：它会做类型校验，并在文件损坏时**先留档再当空**，
    // 避免"读取失败 → 当成没有记录 → 下次保存把可抢救的内容永久覆盖"。
    const raw: Object[] = readJsonArraySafe(this.filePath);
    const result: WatchRecord[] = [];
    for (let i = 0; i < raw.length; i++) {
      const r = raw[i] as WatchRecord;
      // 逐条校验必备字段类型：旧 schema 或手改过的文件里可能缺字段，
      // 缺了的话后面按字段运算会得到 NaN 甚至抛错
      if (typeof r.path !== 'string' || r.path.length === 0) {
        continue;
      }
      if (typeof r.position !== 'number' || !Number.isFinite(r.position)) {
        continue;
      }
      if (typeof r.duration !== 'number' || !Number.isFinite(r.duration)) {
        continue;
      }
      result.push(r);
    }
    this.cache = result;
    return result;
  }

  /**
   * 序列化并写回磁盘（原子写）
   * @param records 要写入的记录
   * @returns 写盘结果描述（用于诊断），成功时形如 "ok 164/164"
   */
  private persist(records: WatchRecord[]): string {
    // 改用原子写：先写 .tmp 再 rename 替换。
    // 原先"先 TRUNC 再写"的做法一旦崩在中间，整个文件就没了 ——
    // 而这是**用户的全部断点续播记录**，不能赌运气。
    const r: AtomicWriteResult = writeJsonArrayAtomic(this.filePath, records);
    if (!r.ok) {
      console.error('persist history failed: ' + r.error);
      return 'error ' + r.error;
    }
    return 'ok ' + r.written.toString() + '/' + r.expected.toString();
  }

  /**
   * 绕过内存缓存，直接从磁盘重新读一遍并返回记录条数与内容长度
   * 专门用于诊断"内存里有、磁盘上没有"这类问题
   * @returns 形如 "disk=2 bytes=312" 的描述
   */
  readFromDiskInfo(): string {
    try {
      if (!fileIo.accessSync(this.filePath)) {
        return 'disk=NO_FILE';
      }
      const stat = fileIo.statSync(this.filePath);
      if (stat.size <= 0) {
        return 'disk=EMPTY';
      }
      const file = fileIo.openSync(this.filePath, fileIo.OpenMode.READ_ONLY);
      let text: string = '';
      try {
        const buffer = new ArrayBuffer(stat.size);
        const readLen: number = fileIo.readSync(file.fd, buffer);
        const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
        text = decoder.decodeToString(new Uint8Array(buffer, 0, readLen));
      } finally {
        fileIo.closeSync(file);
      }
      const parsed: WatchRecord[] = JSON.parse(text) as WatchRecord[];
      const n: number = parsed === null || parsed === undefined ? -1 : parsed.length;
      return 'disk=' + n.toString() + ' bytes=' + stat.size.toString();
    } catch (err) {
      return 'disk=PARSE_FAIL ' + JSON.stringify(err);
    }
  }
}
