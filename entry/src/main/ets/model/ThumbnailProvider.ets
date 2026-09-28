import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
// 原生抽帧：系统 AVImageGenerator 解不了的格式（rm/wmv/ogv）走这条路
import { nativeExtractFrame } from 'libsoftplayer.so';

/** 单次抓帧的超时时间（毫秒），超时即放弃并记失败 */
const FETCH_TIMEOUT_MS: number = 2500;
/** 创建生成器的超时时间（毫秒） */
const CREATE_TIMEOUT_MS: number = 2000;

/** 缩略图缓存目录名（位于应用沙箱 cache 目录下） */
const THUMB_DIR_NAME: string = 'thumbs';

/** 缩略图宽度（像素） */
const THUMB_WIDTH: number = 320;
/** 缩略图高度（像素） */
const THUMB_HEIGHT: number = 180;

/**
 * 依次尝试的截帧时间点（微秒）
 * 0.5 秒通常已越过片头黑场；若取不到再往后退，
 * 有些视频的首个关键帧并不在 0 秒处。
 */
const CAPTURE_TIMES_US: number[] = [500000, 1000000, 2000000, 0];

/** 抓帧诊断信息 */
export interface ThumbAttempt {
  /** 尝试的时间点（微秒） */
  timeUs: number;
  /** 查询模式名称 */
  mode: string;
  /** 成功为 true */
  ok: boolean;
  /** 失败时的错误描述 */
  error: string;
}

/** 提取结果统计 */
export interface ThumbStats {
  /** 已尝试提取的路径数 */
  tried: number;
  /** 成功取到帧的数量 */
  success: number;
  /** 最近一次提取的尝试明细 */
  lastAttempts: ThumbAttempt[];
}

/**
 * 视频缩略图提供者
 *
 * 用 AVImageGenerator 取出视频中某一时刻的帧作为「内置封面」，
 * 取出的 PixelMap 可直接交给 Image() 组件显示。
 *
 * ★ 对外方法保证不抛异常：封面是锦上添花，
 *   绝不能让它的失败连带打断调用方的数据加载流程。
 *
 * ★ 抓帧会依次尝试多个时间点与查询模式，
 *   因为部分视频（或部分解码环境）对首帧/关键帧的处理不同，
 *   单一时间点容易取不到；每次失败的具体错误码都会记录下来便于定位。
 */
export class ThumbnailProvider {
  /** 缩略图缓存目录绝对路径 */
  private cacheDir: string;
  /** 应用包名，用于拼 file:// URI */
  private bundleName: string;
  /** 路径 -> 缩略图文件路径 的缓存；值为空串表示该文件提取失败 */
  private cache: Map<string, string> = new Map();
  /** 成功提取的次数 */
  private successCount: number = 0;

  /**
   * @param cacheDir 缩略图落盘目录（通常是 context.cacheDir）
   * @param bundleName 应用包名。Image() 组件不接受绝对沙箱路径，
   *                   必须用 file://<bundleName>/<path> 形式的 URI
   */
  constructor(cacheDir: string, bundleName: string) {
    this.cacheDir = cacheDir + '/' + THUMB_DIR_NAME;
    this.bundleName = bundleName;
    try {
      if (!fileIo.accessSync(this.cacheDir)) {
        fileIo.mkdirSync(this.cacheDir, true);
      }
    } catch (err) {
      console.error('create thumb cache dir failed: ' + JSON.stringify(err));
    }
  }

  /**
   * 把沙箱绝对路径转成 Image() 能识别的 URI
   *
   * Image() 的 src 只接受 $rawfile / 网络地址 / file://<bundleName>/<path>，
   * 直接给 "/data/storage/.../x.jpg" 这种绝对路径是画不出来的
   * —— 这正是封面长期不显示的原因：文件明明存在且有效。
   *
   * @param absPath 沙箱内绝对路径
   */
  private toFileUri(absPath: string): string {
    try {
      return fileUri.getUriFromPath(absPath);
    } catch (err) {
      console.error('getUriFromPath failed: ' + JSON.stringify(err));
      return absPath;
    }
  }

  /**
   * 由视频路径推出缩略图文件路径
   * 用路径的哈希命名，避免文件名里的空格/中文/特殊字符引发问题
   * @param src 视频绝对路径
   */
  private thumbPathOf(src: string): string {
    let hash: number = 0;
    for (let i = 0; i < src.length; i++) {
      hash = (hash * 31 + src.charCodeAt(i)) % 2147483647;
    }
    return this.cacheDir + '/' + hash.toString() + '.jpg';
  }
  /** 最近一次提取的尝试明细 */
  private lastAttempts: ThumbAttempt[] = [];
  /**
   * 正在提取中的路径集合
   * 首页可能并发触发多次加载（aboutToAppear 与 onPageShow 会先后调用），
   * 若没有这个标记，同一路径会被解码两遍 —— 日志里曾出现每个视频都提取 2 次。
   */
  private inFlight: Set<string> = new Set();

  /**
   * 把 PixelMap 转成与解码器无关的独立位图
   *
   * 做法：读出像素 -> 编码为 JPEG -> 重新解码。
   * 为什么不用 copy()：PixelMap 没有提供同步深拷贝接口，
   * 而 JPEG 往返既得到独立内存，又顺带把格式统一成标准位图。
   *
   * @param raw 原始 PixelMap
   * @param tag 日志用的路径标识
   * @param ownRaw 是否由本函数负责释放 raw（默认 true）
   *
   * ★ 2026-09-29 自检修正：原先**从不释放 raw**。
   *   raw 来自 AVImageGenerator.fetchFrameByTime，是一块原生位图
   *   （1080p 约 8MB，而且请求的 {width,height} 只是期望值、不保证缩放）。
   *   本类对 generator / packer / ImageSource 都严格 release 了，唯独漏了
   *   占内存最大的 PixelMap —— 每次成功抓帧都漏一块，首页批量刷新时线性叠加，
   *   靠 GC 回收原生 buffer 并不可靠，典型表现是刷几次首页后被系统杀掉。
   *   传 ownRaw=false 可以让调用方自己管（当前调用方都是让它自己管）。
   */
  private async toStablePixelMap(raw: image.PixelMap, tag: string,
                                 ownRaw: boolean = true): Promise<image.PixelMap | undefined> {
    let packer: image.ImagePacker | undefined = undefined;
    let source: image.ImageSource | undefined = undefined;
    try {
      // ---- 诊断：确认拿到的原始图是有效数据 ----
      const info: image.ImageInfo = await raw.getImageInfo();
      const bytes: number = raw.getPixelBytesNumber();
      this.lastFrameInfo = 'size=' + info.size.width.toString() + 'x' + info.size.height.toString()
        + ' fmt=' + info.pixelFormat.toString()
        + ' bytes=' + bytes.toString();
      if (info.size.width <= 0 || info.size.height <= 0 || bytes <= 0) {
        this.lastFrameInfo = this.lastFrameInfo + ' INVALID';
        return undefined;
      }

      // ---- 编码为 JPEG ----
      packer = image.createImagePacker();
      const jpeg: ArrayBuffer = await packer.packing(raw, { format: 'image/jpeg', quality: 85 });

      // ---- 重新解码为独立位图 ----
      source = image.createImageSource(jpeg);
      const stable: image.PixelMap = await source.createPixelMap();
      const info2: image.ImageInfo = await stable.getImageInfo();
      this.lastFrameInfo = this.lastFrameInfo
        + ' -> out=' + info2.size.width.toString() + 'x' + info2.size.height.toString()
        + ' outBytes=' + stable.getPixelBytesNumber().toString();
      return stable;
    } catch (err) {
      const e = err as BusinessError;
      this.lastFrameInfo = (this.lastFrameInfo.length > 0 ? this.lastFrameInfo + ' | ' : '')
        + 'roundtrip err=' + e.code + ':' + e.message;
      return undefined;
    } finally {
      // 释放原始位图（占内存最大的一块）。
      // 放在 finally 里：packing 之后 raw 就已经没用了，
      // 无论成功、失败还是提前 return，都必须把它还回去。
      if (ownRaw) {
        try {
          await raw.release();
        } catch (e) {
          console.error('release raw pixelmap failed');
        }
      }
      if (source !== undefined) {
        try {
          await source.release();
        } catch (e) {
          console.error('release image source failed');
        }
      }
      if (packer !== undefined) {
        try {
          await packer.release();
        } catch (e) {
          console.error('release image packer failed');
        }
      }
    }
  }

  /**
   * 把 PixelMap 写成 JPEG 文件
   * @param map 位图
   * @param targetPath 目标文件路径
   * @returns 是否成功
   */
  private async savePixelMapToFile(map: image.PixelMap, targetPath: string): Promise<boolean> {
    let packer: image.ImagePacker | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(targetPath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      packer = image.createImagePacker();
      await packer.packToFile(map, file.fd, { format: 'image/jpeg', quality: 85 });
      return true;
    } catch (err) {
      const e = err as BusinessError;
      this.lastFrameInfo = (this.lastFrameInfo.length > 0 ? this.lastFrameInfo + ' | ' : '')
        + 'packToFile err=' + e.code + ':' + e.message;
      return false;
    } finally {
      if (packer !== undefined) {
        try {
          await packer.release();
        } catch (e) {
          console.error('release packer failed');
        }
      }
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          console.error('close thumb file failed');
        }
      }
    }
  }

  /** 最近一次抓帧的详细信息，供界面诊断 */
  private lastFrameInfo: string = '';

  /** 取最近一次抓帧详情 */
  getLastFrameInfo(): string {
    return this.lastFrameInfo;
  }

  /**
   * 给 Promise 套一层超时
   * 原生媒体调用不保证一定返回，没有超时保护会把调用方永久挂住
   * （下拉刷新动画一直转不消失就是这么来的）
   *
   * @param task 被包装的异步任务
   * @param timeoutMs 超时毫秒数
   */
  private withTimeout<T>(task: Promise<T>, timeoutMs: number): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (reason: Object) => void) => {
      let settled: boolean = false;
      const timer = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        const e: BusinessError = {
          code: -1,
          name: 'TimeoutError',
          message: 'thumbnail operation timed out after ' + timeoutMs.toString() + 'ms'
        };
        reject(e);
      }, timeoutMs);
      task.then((value: T) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        resolve(value);
      }).catch((err: Object) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimeout(timer);
        reject(err);
      });
    });
  }

  /**
   * 同步取缓存的缩略图文件路径（已提取过才有值）
   * 返回空串表示无缓存
   * @param key 视频绝对路径
   */
  peek(key: string): string {
    try {
      const v: string | undefined = this.cache.get(key);
      return v === undefined ? '' : v;
    } catch (err) {
      return '';
    }
  }

  /** 该路径是否已经尝试提取过（无论成功或失败） */
  hasTried(key: string): boolean {
    try {
      return this.cache.has(key);
    } catch (err) {
      return false;
    }
  }

  /**
   * 缓存内容快照，用于诊断
   * 直接回答"缓存里到底有没有这个键"
   * @param keys 需要检查的视频路径
   */
  cacheSnapshot(keys: string[]): string {
    let hit: number = 0;
    let miss: number = 0;
    for (let i = 0; i < keys.length; i++) {
      const v: string | undefined = this.cache.get(keys[i]);
      if (v === undefined || v.length === 0) {
        miss++;
      } else {
        hit++;
      }
    }
    return 'cacheSize=' + this.cache.size.toString()
      + ' hit=' + hit.toString() + ' miss=' + miss.toString()
      + ' dir=' + this.cacheDir;
  }

  /** 提取统计，用于诊断 */
  stats(): ThumbStats {
    return {
      tried: this.cache.size,
      success: this.successCount,
      lastAttempts: this.lastAttempts
    };
  }

  /**
   * 用 FFmpeg 抽一帧存成 JPEG（系统抽帧失败时的回退路径）
   *
   * 与系统那条路的区别：这里直接产出 JPEG 文件，不需要经过 PixelMap。
   * 原系统路径之所以要"PixelMap → 编码 JPEG → 再解码回来"，
   * 是因为 AVImageGenerator 解出的 PixelMap 可能依赖解码器资源，
   * 一旦 release 生成器位图就可能失效。而 FFmpeg 在原生侧解码，
   * 编成 JPEG 直接落盘，天然不依赖任何外部资源。
   *
   * @param src 源视频绝对路径
   * @returns 成功返回 file:// URI，失败返回空串
   */
  private async extractByFfmpeg(src: string): Promise<string> {
    try {
      const target: string = this.thumbPathOf(src);
      // 取第 1 秒的画面：太靠前常常是黑场或片头，太靠后则可能超出短片时长。
      // 原生侧实际会跳到该位置之前最近的关键帧，所以拿到的画面可能略早，
      // 缩略图场景完全可以接受。
      const atMs: number = 1000;
      const code: string = nativeExtractFrame(src, target, atMs, THUMB_WIDTH);
      // nativeExtractFrame 返回 "错误码 原因"，错误码 0 表示成功
      const codeNum: number = parseInt(code.split(' ')[0], 10);
      if (codeNum !== 0) {
        console.warn('[Thumb] FFmpeg 抽帧失败: ' + code);
        return '';
      }
      // 确认文件真的写出来了 —— 抽帧报成功但文件为空的情况也要挡住，
      // 否则界面会拿到一个指向空文件的 URI，表现为"加载失败"而不是"灰底兜底"
      if (!fileIo.accessSync(target)) {
        console.warn('[Thumb] FFmpeg 报告成功但文件不存在: ' + target);
        return '';
      }
      if (fileIo.statSync(target).size <= 0) {
        console.warn('[Thumb] FFmpeg 生成的 JPEG 为空文件');
        return '';
      }
      return this.toFileUri(target);
    } catch (err) {
      const e = err as BusinessError;
      console.warn('[Thumb] FFmpeg 抽帧异常: ' + e.code + ':' + e.message);
      return '';
    }
  }

  /**
   * 提取视频内置帧作为封面
   * @param src 视频绝对路径
   * @returns 成功返回 PixelMap，失败返回 undefined（调用方走渐变兜底）
   */
  async generate(src: string): Promise<string> {
    const attempts: ThumbAttempt[] = [];
    try {
      if (this.cache.has(src)) {
        // 缓存里存的已经是 URI
        const cached: string | undefined = this.cache.get(src);
        return cached === undefined ? '' : cached;
      }
      // 已有另一次调用在解码同一路径：本次直接放弃，
      // 等那次完成后首页会通过后续刷新拿到结果
      if (this.inFlight.has(src)) {
        return '';
      }
      this.inFlight.add(src);

      // ---- 第一步：打开文件拿 fd ----
      let file: fileIo.File | undefined = undefined;
      let fileSize: number = 0;
      try {
        file = fileIo.openSync(src, fileIo.OpenMode.READ_ONLY);
        fileSize = fileIo.statSync(src).size;
      } catch (err) {
        const e = err as BusinessError;
        attempts.push({ timeUs: -1, mode: 'open', ok: false, error: e.code + ':' + e.message });
        this.lastAttempts = attempts;
        this.cache.set(src, '');
        this.inFlight.delete(src);
        return '';
      }

      // ---- 第二步：创建生成器 ----
      let generator: media.AVImageGenerator | undefined = undefined;
      try {
        generator = await this.withTimeout(media.createAVImageGenerator(), CREATE_TIMEOUT_MS);
        generator.fdSrc = { fd: file.fd, offset: 0, length: fileSize };
      } catch (err) {
        const e = err as BusinessError;
        attempts.push({ timeUs: -1, mode: 'create', ok: false, error: e.code + ':' + e.message });
        this.lastAttempts = attempts;
      }

      // ---- 第三步：多策略抓帧 ----
      let result: image.PixelMap | undefined = undefined;
      if (generator !== undefined) {
        const modes: media.AVImageQueryOptions[] = [
          media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC,
          media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST
        ];
        for (let i = 0; i < CAPTURE_TIMES_US.length && result === undefined; i++) {
          for (let m = 0; m < modes.length && result === undefined; m++) {
            const timeUs: number = CAPTURE_TIMES_US[i];
            const mode: media.AVImageQueryOptions = modes[m];
            try {
              const raw: image.PixelMap = await this.withTimeout(
                generator.fetchFrameByTime(timeUs, mode, { width: THUMB_WIDTH, height: THUMB_HEIGHT }),
                FETCH_TIMEOUT_MS);
              // ★ 立即把它转成独立的软件位图。
              //   AVImageGenerator 解码出的 PixelMap 可能依赖解码器资源，
              //   一旦 release() 生成器，位图底层数据可能失效（界面就画不出来）。
              //   编码成 JPEG 再解码回来，就等于拿到一份完全独立的位图。
              result = await this.toStablePixelMap(raw, src);
              attempts.push({
                timeUs: timeUs,
                mode: m === 0 ? 'SYNC' : 'CLOSEST',
                ok: result !== undefined,
                error: result === undefined ? 'roundtrip-failed' : ''
              });
            } catch (err) {
              const e = err as BusinessError;
              attempts.push({
                timeUs: timeUs,
                mode: m === 0 ? 'SYNC' : 'CLOSEST',
                ok: false,
                error: e.code + ':' + e.message
              });
            }
          }
        }
      }

      // ---- 第四步：把结果写成 JPEG 文件，只把路径交给界面 ----
      let filePath: string = '';
      if (result !== undefined) {
        const target: string = this.thumbPathOf(src);
        const saved: boolean = await this.savePixelMapToFile(result, target);
        if (saved) {
          // 对外返回 URI：组件直接把它交给 Image() 即可
          filePath = this.toFileUri(target);
          this.lastFrameInfo = this.lastFrameInfo + ' saved=' + filePath;
        } else {
          this.lastFrameInfo = this.lastFrameInfo + ' save-failed';
        }
        // ★ 存盘之后这块位图就没用了，必须释放。
        //   界面拿到的是文件 URI（Image() 自己去读文件），不再引用这个 PixelMap。
        //   原先这里没有 release，每次成功生成缩略图都漏一块原生位图。
        try {
          await result.release();
        } catch (err) {
          this.lastFrameInfo = this.lastFrameInfo + ' release-failed';
        }
      }

      // ---- 第五步：先释放生成器再关文件（顺序不能反） ----
      if (generator !== undefined) {
        try {
          await generator.release();
        } catch (err) {
          const e = err as BusinessError;
          attempts.push({ timeUs: -1, mode: 'release', ok: false, error: e.code + ':' + e.message });
        }
      }
      try {
        fileIo.closeSync(file);
      } catch (err) {
        attempts.push({ timeUs: -1, mode: 'close', ok: false, error: 'close failed' });
      }

      // ---- 第六步：系统抽帧失败时，用 FFmpeg 回退 ----
      //
      // 为什么需要回退：
      //   实测系统 AVImageGenerator 对 .rm / .wmv / .ogv 完全无能为力
      //   （日志里一直是 "THUMB FAIL ... 12_rv10.rm :: SYNC@500000 err=5400106"）。
      //   结果这些格式在首页和搜索页永远是灰底占位 —— 用户一眼就能看出缺陷。
      //   而 FFmpeg 本来就能解这些格式（这正是内置软解的意义），抽一帧是顺手的事。
      //
      // 为什么必须放在 release/close 之后：
      //   FFmpeg 抽帧要重新打开同一个文件。如果此时系统的生成器还没释放、
      //   文件句柄还开着，就是两个解码器同时持有同一个文件 ——
      //   既浪费内存，也可能因句柄争用而失败。先彻底退出再进来，最干净。
      if (filePath.length === 0) {
        const ffPath: string = await this.extractByFfmpeg(src);
        if (ffPath.length > 0) {
          filePath = ffPath;
          attempts.push({ timeUs: -1, mode: 'ffmpeg', ok: true, error: '' });
        } else {
          attempts.push({ timeUs: -1, mode: 'ffmpeg', ok: false, error: 'ffmpeg-extract-failed' });
        }
      }

      this.lastAttempts = attempts;
      if (filePath.length === 0) {
        this.cache.set(src, '');
        this.inFlight.delete(src);
        return '';
      }
      this.cache.set(src, filePath);
      this.successCount++;
      this.inFlight.delete(src);
      return filePath;
    } catch (err) {
      // 兜底：任何未预料的异常都转成 undefined，绝不向上抛
      const e = err as BusinessError;
      attempts.push({ timeUs: -1, mode: 'unexpected', ok: false, error: e.code + ':' + e.message });
      this.lastAttempts = attempts;
      try {
        this.cache.set(src, '');
      } catch (inner) {
        console.error('cache set failed');
      }
      this.inFlight.delete(src);
      return '';
    }
  }
}
