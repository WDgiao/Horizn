// 原生模块只导出类与函数；枚举/接口来自 ArkTS 侧定义
import { SoftPlayer, SoftPlayerEvent, SoftMediaInfo, SoftAudioTrack, SoftSubtitleTrack } from 'libsoftplayer.so';
import { SoftPlayerState, SoftPlayerEventType } from './SoftPlayerTypes';

/** 事件轮询间隔（毫秒） */
const POLL_INTERVAL_MS: number = 100;

/** 控制器对外暴露的状态快照 */
export interface SoftPlayerSnapshot {
  /** 当前状态 */
  state: SoftPlayerState;
  /** 播放位置（毫秒） */
  positionMs: number;
  /** 总时长（毫秒） */
  durationMs: number;
  /** 画面宽 */
  width: number;
  /** 画面高 */
  height: number;
  /** 视频编码名 */
  videoCodec: string;
  /** 音频编码名 */
  audioCodec: string;
  /** 错误描述，空串表示无错误 */
  error: string;
  /** 可切换的音轨列表 */
  audioTracks: SoftAudioTrack[];
  /** 字幕轨列表 */
  subtitleTracks: SoftSubtitleTrack[];
  /** 当前音轨流下标 */
  currentAudioIndex: number;
  /** 当前字幕轨流下标；-1 表示未启用 */
  currentSubtitleIndex: number;
  /**
   * 首帧是否已经上屏（2026-10-03 新增）
   *
   * 用途：起播流程改成"先出画面，再开始播"（见 PlayerPage 的 beginFirstFrameWait）。
   *   上层不能靠 play() 去催首帧 —— 那正是要避免的（声音先响、画面还是黑的）。
   *   原生侧在渲染第一帧后会发一条 POSITION 事件并把 data2 置 1，
   *   这里转成布尔量给界面用。
   */
  firstFrameRendered: boolean;
  /**
   * 「首帧已上屏」那一帧自己的 pts（毫秒）
   *
   * 为什么要单独带出来：续播时引擎先预渲染了**seek 之前**的一帧（文件开头），
   * 随后 seek 完成又会发一条 POSITION（内容是续播目标）。两条事件落在同一次
   * 轮询里时，快照的 positionMs 会被后者覆盖 —— 只看 positionMs 就没法分辨
   * "报信号的那一帧到底是开头那帧还是续播位置的帧"。
   * 单独记下首帧自己的 pts，续播时就能要求"首帧确实落在目标附近"才开播。
   */
  firstFramePtsMs: number;
}

/**
 * 原生软解播放器控制器
 *
 * 职责边界：
 *   本类只负责"驱动原生播放器 + 把原生事件翻译成状态快照"，
 *   不碰任何 UI。UI 通过构造时传入的回调感知变化。
 *
 * 为什么用轮询而不是原生主动回调：
 *   原生线程直接回调 JS 需要 napi_threadsafe_function + 引用管理，
 *   在对象释放期容易出竞态。改为原生只入队、JS 定时取，
 *   逻辑简单且不会有跨线程生命周期问题（代价是一帧级延迟，可接受）。
 */
export class SoftPlayerController {
  /** 原生播放器实例 */
  private player: SoftPlayer | undefined = undefined;
  /** 轮询定时器 */
  private pollTimer: number = -1;
  /** 是否已释放 */
  private released: boolean = false;
  /** 状态快照 */
  private snapshot: SoftPlayerSnapshot = {
    state: SoftPlayerState.IDLE,
    positionMs: 0,
    durationMs: 0,
    width: 0,
    height: 0,
    videoCodec: '',
    audioCodec: '',
    error: '',
    audioTracks: [],
    subtitleTracks: [],
    currentAudioIndex: -1,
    currentSubtitleIndex: -1,
    firstFrameRendered: false,
    firstFramePtsMs: -1
  };
  /** 状态变化通知（由 UI 传入） */
  private onUpdate: (snap: SoftPlayerSnapshot) => void;

  /**
   * @param onUpdate 状态变化回调，在 JS 线程被调用
   */
  constructor(onUpdate: (snap: SoftPlayerSnapshot) => void) {
    this.onUpdate = onUpdate;
  }

  /**
   * 当前状态快照（**真正的副本**）
   *
   * ★ 2026-09-29 自检修正：原先直接 `return this.snapshot`，
   *   与"副本"的注释不符，而且会带来两个真实问题：
   *     · 调用方拿到的对象会被下一次 applyEvent **就地改写** ——
   *       界面可能读到渲染到一半时被换掉的值；
   *     · ArkUI 的 @State/@Prop 对对象是**按引用比较**的，
   *       引用不变时可能整块跳过刷新，表现为"状态偶尔不更新、偶发跳一帧"，
   *       这类问题极难定位。
   *
   *   现在返回浅拷贝，并对两个数组字段单独 slice ——
   *   数组是引用类型，浅拷贝后仍与原数组共享，必须再切一份。
   */
  getSnapshot(): SoftPlayerSnapshot {
    const s: SoftPlayerSnapshot = this.snapshot;
    return {
      state: s.state,
      positionMs: s.positionMs,
      durationMs: s.durationMs,
      width: s.width,
      height: s.height,
      videoCodec: s.videoCodec,
      audioCodec: s.audioCodec,
      error: s.error,
      audioTracks: s.audioTracks.slice(0),
      subtitleTracks: s.subtitleTracks.slice(0),
      currentAudioIndex: s.currentAudioIndex,
      currentSubtitleIndex: s.currentSubtitleIndex,
      firstFrameRendered: s.firstFrameRendered,
      firstFramePtsMs: s.firstFramePtsMs
    };
  }

  /**
   * 创建原生播放器并设置渲染 surface
   * @param surfaceId XComponent 的 surfaceId
   * @returns 是否成功
   */
  attach(surfaceId: string): boolean {
    if (this.released) {
      return false;
    }
    try {
      if (this.player === undefined) {
        this.player = new SoftPlayer();
        this.startPolling();
      }
      if (surfaceId.length > 0) {
        this.player.setSurface(surfaceId);
      }
      return true;
    } catch (err) {
      this.fail('创建原生播放器失败：' + JSON.stringify(err));
      return false;
    }
  }

  /**
   * 打开媒体文件
   * @param path 沙箱内绝对路径
   * @param startPositionMs 起播位置（毫秒，可选）。续播必须在这里给：
   *        引擎会在"打开之后、预渲染第一帧之前"跳到位，于是首帧就是续播位置那一帧；
   *        若等 READY 之后再 seek，首帧会是文件开头，上层就没法用它判断画面是否就绪。
   * @returns 是否成功发起（真正就绪要等 PREPARED 事件）
   */
  prepare(path: string, startPositionMs: number = 0): boolean {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return false;
    }
    try {
      this.snapshot.error = '';
      const r: number = p.prepare(path, startPositionMs > 0 ? Math.floor(startPositionMs) : 0);
      if (r !== 0) {
        this.fail('prepare 返回错误码 ' + r.toString());
        return false;
      }
      return true;
    } catch (err) {
      this.fail('prepare 异常：' + JSON.stringify(err));
      return false;
    }
  }

  /** 开始播放 */
  play(): void {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return;
    }
    try {
      p.start();
    } catch (err) {
      this.fail('start 异常：' + JSON.stringify(err));
    }
  }

  /** 暂停 */
  pause(): void {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return;
    }
    try {
      p.pause();
    } catch (err) {
      this.fail('pause 异常：' + JSON.stringify(err));
    }
  }

  /** 跳转 */
  seekTo(positionMs: number): void {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return;
    }
    try {
      p.seekTo(Math.max(0, Math.floor(positionMs)));
    } catch (err) {
      this.fail('seekTo 异常：' + JSON.stringify(err));
    }
  }

  /**
   * 解绑渲染 surface（页面销毁前必须调用，且要在 release 之前）
   *
   * 为什么不能只靠 release：
   *   XComponent 被销毁时，ArkUI 会析构对应的 Surface 渲染节点。
   *   如果那时原生侧还持有这个 surface 的 native window、甚至解码线程
   *   还在往上写帧，就会与系统销毁流程撞车 ——
   *   实测崩溃栈是 RSSurfaceNode::~RSSurfaceNode -> RSNode::ClearAllModifiers
   *   （系统渲染库、主线程），表现为"极快开合时闪退"。
   *
   *   解绑之后 RenderFrame 会因为拿不到 native window 而直接跳过，
   *   解码线程仍可继续跑（不崩溃），只是不上屏。
   */
  detachSurface(): void {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return;
    }
    try {
      p.detachSurface();
    } catch (err) {
      console.error('detachSurface failed: ' + JSON.stringify(err));
    }
  }

  /** 释放全部资源（幂等） */
  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    this.stopPolling();
    const p: SoftPlayer | undefined = this.player;
    this.player = undefined;
    if (p !== undefined) {
      try {
        p.release();
      } catch (err) {
        console.error('native release failed: ' + JSON.stringify(err));
      }
    }
  }

  /* ============================================================
     内部：事件轮询与状态同步
     ============================================================ */

  /** 启动事件轮询 */
  private startPolling(): void {
    if (this.pollTimer !== -1) {
      return;
    }
    this.pollTimer = setInterval(() => {
      this.drainEvents();
    }, POLL_INTERVAL_MS);
  }

  /** 停止轮询 */
  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 取走并处理累积的事件 */
  private drainEvents(): void {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return;
    }
    let events: SoftPlayerEvent[] = [];
    try {
      events = p.pollEvents();
    } catch (err) {
      this.fail('pollEvents 异常：' + JSON.stringify(err));
      return;
    }
    if (events === undefined || events.length === 0) {
      return;
    }
    let changed: boolean = false;
    for (let i = 0; i < events.length; i++) {
      if (this.applyEvent(events[i])) {
        changed = true;
      }
    }
    if (changed) {
      this.notify();
    }
  }

  /**
   * 处理单个事件
   * @returns 是否引起状态变化（决定要不要通知 UI）
   */
  private applyEvent(ev: SoftPlayerEvent): boolean {
    if (ev.type === SoftPlayerEventType.STATE_CHANGED) {
      // 原生传回的是数字，这里显式转成枚举
      this.snapshot.state = ev.data1 as SoftPlayerState;
      return true;
    }
    if (ev.type === SoftPlayerEventType.POSITION) {
      this.snapshot.positionMs = ev.data1;
      // data2 == 1 表示"这是首帧上屏时上报的那一条"（见引擎里的预渲染说明）
      if (ev.data2 === 1) {
        this.snapshot.firstFrameRendered = true;
        this.snapshot.firstFramePtsMs = ev.data1;
      }
      return true;
    }
    if (ev.type === SoftPlayerEventType.DURATION) {
      this.snapshot.durationMs = ev.data1;
      return true;
    }
    if (ev.type === SoftPlayerEventType.VIDEO_SIZE) {
      this.snapshot.width = ev.data1;
      this.snapshot.height = ev.data2;
      return true;
    }
    if (ev.type === SoftPlayerEventType.PREPARED) {
      // 就绪后把媒体信息补全（编码名等来自 getMediaInfo）
      this.syncMediaInfo();
      return true;
    }
    if (ev.type === SoftPlayerEventType.ERROR) {
      this.snapshot.error = ev.text;
      this.snapshot.state = SoftPlayerState.ERROR_STATE;
      return true;
    }
    if (ev.type === SoftPlayerEventType.COMPLETED) {
      this.snapshot.state = SoftPlayerState.COMPLETED;
      return true;
    }
    return false;
  }

  /** 从原生侧同步媒体信息到快照 */
  private syncMediaInfo(): void {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined) {
      return;
    }
    try {
      const info: SoftMediaInfo = p.getMediaInfo();
      this.snapshot.durationMs = info.durationMs;
      this.snapshot.width = info.width;
      this.snapshot.height = info.height;
      this.snapshot.videoCodec = info.videoCodec;
      this.snapshot.audioCodec = info.audioCodec;
      // 轨道列表要做空值兜底：原生侧理论上一定返回数组，
      // 但 crossing napi 边界时类型不匹配只会得到 undefined，
      // 直接 .length 就会抛异常把整个 PREPARED 处理打断。
      this.snapshot.audioTracks = info.audioTracks !== undefined ? info.audioTracks : [];
      this.snapshot.subtitleTracks =
        info.subtitleTracks !== undefined ? info.subtitleTracks : [];
      this.snapshot.currentAudioIndex =
        info.currentAudioIndex !== undefined ? info.currentAudioIndex : -1;
      this.snapshot.currentSubtitleIndex =
        info.currentSubtitleIndex !== undefined ? info.currentSubtitleIndex : -1;
      console.info('[SoftPlayer] 轨道: 音轨 ' + this.snapshot.audioTracks.length.toString()
        + ' 条(当前 ' + this.snapshot.currentAudioIndex.toString() + '), 字幕轨 '
        + this.snapshot.subtitleTracks.length.toString() + ' 条(当前 '
        + this.snapshot.currentSubtitleIndex.toString() + ')');
    } catch (err) {
      console.error('getMediaInfo failed: ' + JSON.stringify(err));
    }
  }

  /**
   * 切换音轨
   *
   * 原生侧的实现是"重开会话 + seek 回原位"，会有短暂的画面/声音中断，
   * 这是预期行为（界面可以据此给个提示）。
   *
   * @return 0 成功；非 0 失败
   */
  switchAudioTrack(index: number): number {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return -1;
    }
    try {
      const r: number = p.switchAudioTrack(index);
      if (r === 0) {
        // 重开之后媒体信息要重新取一次（当前音轨下标变了，
        // 而且时长、尺寸这些也可能因新音轨而略有不同）
        this.syncMediaInfo();
        this.notify();
      } else {
        this.snapshot.error = '切换音轨失败（' + r.toString() + '）';
        this.notify();
      }
      return r;
    } catch (err) {
      console.error('switchAudioTrack failed: ' + JSON.stringify(err));
      return -1;
    }
  }

  /**
   * 启用 / 关闭内嵌字幕轨
   * @param index 字幕流下标；-1 表示关闭字幕
   */
  setSubtitleTrack(index: number): number {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return -1;
    }
    try {
      const r: number = p.setSubtitleTrack(index);
      this.syncMediaInfo();
      this.notify();
      return r;
    } catch (err) {
      console.error('setSubtitleTrack failed: ' + JSON.stringify(err));
      return -1;
    }
  }

  /**
   * 取当前该显示的字幕文本（内嵌字幕用）
   *
   * 每次都向原生查询，而不是靠事件推送 —— 理由见 C++ 侧 SubtitleCue 的说明：
   * 字幕是时间对齐的，让 UI 按当前播放位置来问，天然同步。
   *
   * @return 字幕文本；空串表示这一刻没有字幕
   */
  getActiveSubtitle(): string {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return '';
    }
    try {
      const s: string = p.getActiveSubtitle();
      return s !== undefined && s !== null ? s : '';
    } catch (err) {
      return '';
    }
  }

  /** 文件里是否有多条可切换音轨 */
  canSwitchAudioTrack(): boolean {
    return this.snapshot.audioTracks.length > 1;
  }

  /** 音频编码名（界面诊断用） */
  getAudioCodec(): string {
    return this.snapshot.audioCodec;
  }

  /** 记录错误并通知 */
  private fail(msg: string): void {
    this.snapshot.error = msg;
    this.snapshot.state = SoftPlayerState.ERROR_STATE;
    console.error('[SoftPlayer] ' + msg);
    this.notify();
  }

  /** 通知 UI */
  private notify(): void {
    // 传副本而不是内部对象：理由同 getSnapshot 的说明 ——
    // 内部对象会被后续事件就地改写，直接交出去等于让界面持有一个会变的引用
    this.onUpdate(this.getSnapshot());
  }
}
