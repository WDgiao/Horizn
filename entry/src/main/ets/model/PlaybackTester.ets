import { media } from '@kit.MediaKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

/** 单个文件的播放测试结果 */
export interface PlayTestResult {
  /** 文件名 */
  name: string;
  /** 最深到达的状态 */
  reached: string;
  /** 是否进入过 playing */
  played: boolean;
  /** 播放位置是否真实推进 */
  progressed: boolean;
  /** 观测到的 position（毫秒） */
  position: number;
  /** 失败或异常信息 */
  error: string;
  /** 从打开到 prepare 完成的耗时 */
  costMs: number;
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

/** 单个文件最多观察多久（毫秒） */
const WATCH_MS: number = 2500;

/**
 * 播放能力测试器
 *
 * 这是唯一能回答「本机能不能播这个文件」的测试。前置的两轮测试都有误导性：
 *   ① 只做 prepare 不能证明能解码
 *      实测 12/12 全部通过（含 WMV2、RV10），与系统解码器列表矛盾 —— 是假象
 *   ② AVImageGenerator 抽帧失败也不能证明不能播
 *      实测 VP8/VP9/AV1 抽帧同样失败，但这些编码在系统解码器列表里明明存在，
 *      说明抽帧失败反映的是「容器不支持抽帧」，不是「解码器不支持该编码」
 *
 * 只有 AVPlayer 进入 playing 且 currentTime 真实推进，才代表「能播」。
 */
export class PlaybackTester {

  /**
   * 把内置素材解包到沙箱，返回目录
   *
   * 为什么要解包：应用只能读写自己的沙箱，无法访问 /data/local/tmp，
   * 而 hdc 推送进沙箱的文件会被静默丢弃。rawfile 是唯一可靠通道。
   */
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

  /**
   * 把底层状态映射成字符串
   * 直接拿 player.state 做字面量比较会触发 ArkTS 的"无重叠类型"报错，
   * 转成 string 后再比。
   */
  static stateOf(player: media.AVPlayer): string {
    return player.state as string;
  }

  /** 简易 sleep */
  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 等 player 落到指定状态
   *
   * 两个地方必须等，否则会报
   *   5400102 current state is not stopped or initialized
   * ① createAVPlayer() 返回后：状态机是异步就绪的
   * ② 给 fdSrc 赋值后：必须是「先稳到 idle、再迁到 initialized」，
   *    如果停在 idle 就调 prepare，状态机会拒绝
   *    —— 这一点很反直觉：idle 看着"能赋值"，但不是"能 prepare"
   *
   * @param player 播放器
   * @param target 期望状态（'idle' 或 'initialized'）
   * @param trace 状态流转记录（便于诊断）
   * @param budgetMs 最长等待毫秒
   * @returns 最终观测到的状态
   */
  private static async waitState(player: media.AVPlayer, target: string,
    trace: string[], budgetMs: number): Promise<string> {
    const deadline: number = Date.now() + budgetMs;
    let st: string = PlaybackTester.stateOf(player);
    if (trace.length === 0 || trace[trace.length - 1] !== st) {
      trace.push(st);
    }
    while (Date.now() < deadline) {
      st = PlaybackTester.stateOf(player);
      if (trace.length === 0 || trace[trace.length - 1] !== st) {
        trace.push(st);
      }
      if (st === target) {
        return st;
      }
      await PlaybackTester.sleep(20);
    }
    return st;
  }

  /**
   * 播一个文件，观察 WATCH_MS 毫秒
   * @param dir 素材目录
   * @param name 文件名
   */
  static async testOne(dir: string, name: string): Promise<PlayTestResult> {
    const full: string = dir + '/' + name;
    const r: PlayTestResult = {
      name: name, reached: 'idle', played: false, progressed: false,
      position: 0, error: '', costMs: 0
    };
    const t0: number = Date.now();
    let player: media.AVPlayer | undefined = undefined;
    let file: fileIo.File | undefined = undefined;
    const trace: string[] = [];
    try {
      file = fileIo.openSync(full, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(full).size;
      player = await media.createAVPlayer();

      // 事件回调只记录错误；状态推进靠下面主动轮询，避免回调时序不确定
      player.on('error', (err: BusinessError) => {
        r.error = err.code.toString() + ':' + err.message;
      });

      // 必须等状态机就绪，否则接下来赋值 fdSrc / prepare 会报 5400102
      const st0: string = await PlaybackTester.waitState(player, 'idle', trace, 800);
      if (st0 !== 'idle' && st0 !== 'initialized') {
        r.reached = st0;
        r.error = '创建后状态为 ' + st0 + '，无法赋值（流转: ' + trace.join('>') + '）';
        return r;
      }

      // 本地文件只能用 fdSrc，url 只接受 fd:// 或 http(s)
      player.fdSrc = { fd: file.fd, offset: 0, length: size };

      // 赋值只是投递信号，状态迁移是异步的：
      // 必须等它自己走到 initialized，否则紧接着的 prepare 会被状态机拒绝
      // （停 idle 时调 prepare → 5400102）
      const st1: string = await PlaybackTester.waitState(player, 'initialized', trace, 1200);
      if (st1 !== 'initialized') {
        r.reached = st1;
        r.error = 'fdSrc 赋值后未进入 initialized（当前 ' + st1
          + '，流转: ' + trace.join('>') + '）';
        return r;
      }

      await player.prepare();
      r.reached = PlaybackTester.stateOf(player);
      r.costMs = Date.now() - t0;

      await player.play();

      // 轮询观察：状态 + 播放位置
      const deadline: number = Date.now() + WATCH_MS;
      let lastPos: number = -1;
      let moved: number = 0;
      while (Date.now() < deadline) {
        await PlaybackTester.sleep(120);
        const st: string = PlaybackTester.stateOf(player);
        if (st === 'playing' || st === 'completed') {
          r.reached = st;
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
      r.progressed = moved >= 200;
      if (r.error.length === 0 && !r.played) {
        r.error = '未进入 playing（停在 ' + r.reached + '）';
      }
    } catch (err) {
      const e = err as BusinessError;
      if (r.error.length === 0) {
        r.error = e.code.toString() + ':' + e.message
          + '（状态流转: ' + trace.join('>') + '）';
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
   * @param onProgress 每测完一个文件回调一次（只传结果，不传进度计数）
   */
  static async runAll(context: common.UIAbilityContext,
    onProgress: (r: PlayTestResult) => void): Promise<PlayTestResult[]> {
    const dir: string = await PlaybackTester.unpackSamples(context);
    const results: PlayTestResult[] = [];
    for (let i = 0; i < TEST_FILES.length; i++) {
      const r: PlayTestResult = await PlaybackTester.testOne(dir, TEST_FILES[i]);
      results.push(r);
      onProgress(r);
    }
    return results;
  }
}
