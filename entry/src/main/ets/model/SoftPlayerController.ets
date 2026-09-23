// 原生模块只导出类与函数；枚举/接口来自 ArkTS 侧定义
import { SoftPlayer, SoftPlayerEvent, SoftMediaInfo } from 'libsoftplayer.so';
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
  /** 错误描述，空串表示无错误 */
  error: string;
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
    error: ''
  };
  /** 状态变化通知（由 UI 传入） */
  private onUpdate: (snap: SoftPlayerSnapshot) => void;

  /**
   * @param onUpdate 状态变化回调，在 JS 线程被调用
   */
  constructor(onUpdate: (snap: SoftPlayerSnapshot) => void) {
    this.onUpdate = onUpdate;
  }

  /** 当前状态快照（副本） */
  getSnapshot(): SoftPlayerSnapshot {
    return this.snapshot;
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
   * @returns 是否成功发起（真正就绪要等 PREPARED 事件）
   */
  prepare(path: string): boolean {
    const p: SoftPlayer | undefined = this.player;
    if (p === undefined || this.released) {
      return false;
    }
    try {
      this.snapshot.error = '';
      const r: number = p.prepare(path);
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
    } catch (err) {
      console.error('getMediaInfo failed: ' + JSON.stringify(err));
    }
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
    this.onUpdate(this.snapshot);
  }
}
