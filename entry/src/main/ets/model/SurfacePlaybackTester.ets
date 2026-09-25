import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

/** 单个文件的播放测试结果 */
export interface SurfaceTestResult {
  /** 文件名 */
  name: string;
  /** 解封装识别到的视频 mime */
  mime: string;
  /** 解码出的画面宽 */
  width: number;
  /** 解码出的画面高 */
  height: number;
  /** 是否进入过 playing */
  played: boolean;
  /** 播放位置是否推进（毫秒） */
  position: number;
  /** 失败原因 */
  error: string;
}

/** 内置素材清单 */
const TEST_FILES: string[] = [
  '01_h264_aac.mp4',
  '02_hevc_aac.mp4',
  '03_mpeg4_aac.mp4',
  '04_vp8_vorbis.webm',
  '05_vp9_opus.webm',
  '06_av1_opus.mkv',
  '07_mpeg2_mp2.mpg',
  '08_theora_vorbis.ogv',
  '09_wmv2_wmav2.wmv',
  '10_h263_amr.3gp',
  '11_h264_mkv.mkv',
  '12_rv10.rm'
];

/** 沙箱内解包目录 */
const UNPACK_DIR: string = 'codec-test';

/**
 * 补充测试素材在沙箱里的目录名
 *
 * 与 codec-test 分开：那边是"每个格式一个"的格式覆盖样本，
 * 这边是针对具体薄弱点的（长视频压 seek、无音轨验时钟回退）。
 */
const TESTSET_DIR: string = '测试素材';

/** 单个文件观察时长（毫秒） */
const WATCH_MS: number = 2500;

/**
 * 带 surface 的播放能力测试
 *
 * 为什么必须带 surface：
 *   不带 surface 时，AVPlayer 会把视频轨整个关掉（日志里的
 *   isVideoTrackDisabled_: 1、videoDecoder is null、video size 0x0），
 *   位置照样推进 —— 但推进的是「音频时钟」。
 *   上一轮测出的 12/12 全部可播就是这么来的，等于什么都没测到。
 *
 * 带 surface 后才有意义：
 *   视频解码器真被创建 → videoWidth/videoHeight 变成真实分辨率
 *   解不出来 → 尺寸停在 0x0，或直接报错
 *
 * 所以判据是：**画面尺寸非 0** + 进入 playing + 位置推进。
 */
export class SurfacePlaybackTester {

  /**
   * 把 rawfile/testset/ 下的补充测试素材解包到沙箱
   *
   * 为什么单独一组（不复用上面的 unpackSamples）：
   *   codec/ 那 12 个是"格式覆盖"用的固定样本（每个格式一个）；
   *   testset/ 这几个是"针对具体薄弱点"的（长视频压 seek、无音轨验时钟回退），
   *   性质不同、数量会变，所以分开管理。
   *
   * 为什么必须写进沙箱才能用：
   *   媒体库扫描的是沙箱目录，而 rawfile 是打包在 HAP 里的只读资源，
   *   不落盘就不会出现在搜索页。而 hdc 无法写入应用沙箱（实测 cp 报
   *   Permission denied，模拟器与真机都一样），所以只能由应用自己解包。
   */
  static async unpackTestset(context: common.UIAbilityContext): Promise<string[]> {
    const dir: string = context.filesDir + '/' + TESTSET_DIR;
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    // 列目录而不是写死文件名：以后往 rawfile/testset/ 里加素材时不用改代码
    const names: string[] = await context.resourceManager.getRawFileList('testset');
    const done: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const target: string = dir + '/' + name;
      let need: boolean = true;
      try {
        if (fileIo.accessSync(target) && fileIo.statSync(target).size > 0) {
          need = false;
        }
      } catch (err) {
        need = true;
      }
      if (!need) {
        done.push(name + '（已存在）');
        continue;
      }
      try {
        const bytes: Uint8Array = await context.resourceManager.getRawFileContent('testset/' + name);
        const file = fileIo.openSync(target,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(file.fd, bytes.buffer.slice(0, bytes.length));
        } finally {
          fileIo.closeSync(file);
        }
        done.push(name + '  ' + (bytes.length / 1024).toFixed(0) + ' KB');
      } catch (err) {
        done.push(name + ' 失败: ' + JSON.stringify(err));
      }
    }
    return done;
  }

  /** 解包素材到沙箱（复用上一轮的逻辑，目录已存在则跳过） */
  static async unpackSamples(context: common.UIAbilityContext): Promise<string> {
    const dir: string = context.filesDir + '/' + UNPACK_DIR;
    if (!fileIo.accessSync(dir)) {
      fileIo.mkdirSync(dir, true);
    }
    for (let i = 0; i < TEST_FILES.length; i++) {
      const name: string = TEST_FILES[i];
      const target: string = dir + '/' + name;
      let need: boolean = true;
      try {
        if (fileIo.accessSync(target) && fileIo.statSync(target).size > 0) {
          need = false;
        }
      } catch (err) {
        need = true;
      }
      if (!need) {
        continue;
      }
      const bytes: Uint8Array = await context.resourceManager.getRawFileContent('codec/' + name);
      const file = fileIo.openSync(target,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, bytes.buffer.slice(0, bytes.length));
      } finally {
        fileIo.closeSync(file);
      }
    }
    return dir;
  }

  /** 读状态（避免 ArkTS 字面量收窄） */
  private static stateOf(player: media.AVPlayer): string {
    return player.state as string;
  }

  /** 简易 sleep */
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 等状态 */
  private static async waitState(player: media.AVPlayer, target: string, budgetMs: number): Promise<string> {
    const deadline: number = Date.now() + budgetMs;
    let st: string = SurfacePlaybackTester.stateOf(player);
    while (Date.now() < deadline) {
      st = SurfacePlaybackTester.stateOf(player);
      if (st === target) {
        return st;
      }
      await SurfacePlaybackTester.sleep(20);
    }
    return st;
  }

  /**
   * 带 surface 测一个文件
   * @param dir 素材目录
   * @param name 文件名
   * @param surfaceId XComponent 提供的 surface id
   */
  static async testOne(dir: string, name: string, surfaceId: string): Promise<SurfaceTestResult> {
    const full: string = dir + '/' + name;
    const r: SurfaceTestResult = {
      name: name, mime: '', width: 0, height: 0, played: false, position: 0, error: ''
    };
    let player: media.AVPlayer | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(full, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(full).size;
      player = await media.createAVPlayer();

      player.on('error', (err: BusinessError) => {
        r.error = err.code.toString() + ':' + err.message;
      });

      // 画面尺寸只能从事件拿（AVPlayer 没有 videoWidth/videoHeight 属性）
      // 关键：视频轨被跳过时这个回调给出 0x0，正常解码时给出真实分辨率
      player.on('videoSizeChange', (width: number, height: number) => {
        if (width > 0) {
          r.width = width;
        }
        if (height > 0) {
          r.height = height;
        }
      });

      const st0: string = await SurfacePlaybackTester.waitState(player, 'idle', 800);
      if (st0 !== 'idle') {
        r.error = '创建后状态 ' + st0;
        return r;
      }

      // 顺序很讲究，两步都不能颠倒（实测报错驱动）：
      //   ① 先给 fdSrc → 状态机迁到 initialized
      //   ② 再给 surfaceId（此属性只在 initialized 态可写）
      //   ③ 最后 prepare
      // 先给 surfaceId 会报 5400102 "SurfaceID can only be set in the initialized state"
      player.fdSrc = { fd: file.fd, offset: 0, length: size };
      const st1: string = await SurfacePlaybackTester.waitState(player, 'initialized', 1200);
      if (st1 !== 'initialized') {
        r.error = 'fdSrc 后状态 ' + st1;
        return r;
      }

      player.surfaceId = surfaceId;

      await player.prepare();
      await player.play();

      const deadline: number = Date.now() + WATCH_MS;
      let lastPos: number = -1;
      let moved: number = 0;
      while (Date.now() < deadline) {
        await SurfacePlaybackTester.sleep(150);
        const st: string = SurfacePlaybackTester.stateOf(player);
        if (st === 'playing' || st === 'completed') {
          r.played = true;
        }
        let pos: number = -1;
        try {
          pos = player.currentTime;
        } catch (err) {
          pos = -1;
        }
        if (pos >= 0) {
          r.position = pos;
          if (lastPos >= 0 && pos > lastPos) {
            moved += (pos - lastPos);
          }
          lastPos = pos;
        }
      }
      if (r.error.length === 0 && !r.played) {
        r.error = '未进入 playing';
      }
      if (r.error.length === 0 && r.width === 0) {
        r.error = '位置推进了但画面尺寸为 0（视频轨被跳过）';
      }
    } catch (err) {
      const e = err as BusinessError;
      if (r.error.length === 0) {
        r.error = e.code.toString() + ':' + e.message;
      }
    } finally {
      if (player !== undefined) {
        try {
          await player.release();
        } catch (e) {
          console.error('release failed');
        }
      }
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (e) {
          console.error('close failed');
        }
      }
    }
    return r;
  }

  /**
   * 跑完整测试
   * @param onProgress 每测完一个文件回调一次。
   *        只传结果本身 —— 进度计数让调用方自己累加即可，
   *        多传 done/total 只会让调用方收到用不到的参数（IDE 也会提示未使用）。
   */
  static async runAll(context: common.UIAbilityContext, surfaceId: string,
    onProgress: (r: SurfaceTestResult) => void): Promise<SurfaceTestResult[]> {
    const dir: string = await SurfacePlaybackTester.unpackSamples(context);
    const results: SurfaceTestResult[] = [];
    for (let i = 0; i < TEST_FILES.length; i++) {
      const r: SurfaceTestResult = await SurfacePlaybackTester.testOne(dir, TEST_FILES[i], surfaceId);
      results.push(r);
      onProgress(r);
    }
    return results;
  }

  /**
   * 把测试素材另拷一份到 filesDir 根目录
   *
   * 用途：媒体库（VideoRepository）扫描的是 filesDir，而测试素材原本放在
   * filesDir/codec-test/ 子目录里 —— 也能扫到，但混在诊断目录里不直观。
   * 这个函数把它们以「可读名字」放到根目录，方便在搜索页里点开验证播放。
   *
   * 为什么要这么绕：应用只能写自己的沙箱，hdc shell 无权写入
   * （实测 cp 报 Permission denied），所以只能让应用自己来拷。
   *
   * @param context 上下文
   * @returns 拷贝成功的文件名列表
   */
  static async publishSamples(context: common.UIAbilityContext): Promise<string[]> {
    // 挑几个「系统解不了、必须软解」的代表性格式，改成语义化文件名
    const plan: string[][] = [
      ['12_rv10.rm', 'RV10_RealVideo.rm'],
      ['09_wmv2_wmav2.wmv', 'WMV2_软解测试.wmv'],
      ['08_theora_vorbis.ogv', 'Theora_软解测试.ogv'],
      ['06_av1_opus.mkv', 'AV1_软解测试.mkv'],
      ['04_vp8_vorbis.webm', 'VP8_软解测试.webm']
    ];
    const dir: string = await SurfacePlaybackTester.unpackSamples(context);
    const done: string[] = [];
    for (let i = 0; i < plan.length; i++) {
      const src: string = dir + '/' + plan[i][0];
      const dst: string = context.filesDir + '/' + plan[i][1];
      try {
        if (fileIo.accessSync(dst)) {
          done.push(plan[i][1] + '（已存在）');
          continue;
        }
        fileIo.copyFileSync(src, dst);
        done.push(plan[i][1]);
      } catch (err) {
        done.push(plan[i][1] + ' 失败:' + JSON.stringify(err));
      }
    }
    return done;
  }

  /**
   * 确保测试素材已解包，返回可播放的 rm 文件绝对路径
   *
   * 给"跳转压力测试"用：它需要知道该打开哪个文件。
   */
  static async ensureSamplePath(context: common.UIAbilityContext): Promise<string> {
    const dir: string = await SurfacePlaybackTester.unpackSamples(context);
    return dir + '/12_rv10.rm';
  }
}
