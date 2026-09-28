import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common as commonKit } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { formatDuration } from '../common/MediaData';
import { MediaTier, mediaTierOf, isVideoContainer } from '../common/MediaType';
import { WatchHistory } from '../model/WatchHistory';
import { DiagLog } from '../model/DiagLog';
import { SoftPlayerController, SoftPlayerSnapshot } from '../model/SoftPlayerController';
import { SoftPlayerState } from '../model/SoftPlayerTypes';

/** 播放器路由参数 */
export interface PlayerParams {
  /** 视频绝对路径 */
  path: string;
  /** 显示用标题 */
  title: string;
  /** 续播起点（毫秒），由首页「继续观看」传入；0 表示从头播 */
  startMs?: number;
}

/**
 * 把毫秒格式化成 mm:ss 或 hh:mm:ss
 * 直接复用首页的公共实现（MediaData.formatDuration），
 * 保证播放页与首页对同一个时长显示一致，避免两处格式化规则打架。
 */
function formatTime(ms: number): string {
  return formatDuration(ms);
}

/**
 * 视频播放页
 *
 * 布局采用「上中下」三段式，三段都是同一个 Stack 的子节点：
 *   - 顶部信息栏 + 返回按钮：贴顶（Stack 默认 TopStart 对齐）
 *   - 视频渲染层：铺满整屏，由 videoScaleType 保证不拉伸变形
 *   - 底部控制栏：贴底（alignContent: Alignment.Bottom）
 * 三者显隐由 showControls 统一控制。
 *
 * 横竖屏：通过 window.setPreferredOrientation 切换，
 * 方向变化时 XComponent 的 surface 会重建，因此 onLoad 里做了幂等处理。
 */
@Entry
@Component
struct PlayerPage {
  /** 视频路径 */
  @State videoPath: string = '';
  /** 显示标题 */
  @State title: string = '';
  /** 当前播放位置（毫秒） */
  @State positionMs: number = 0;
  /** 总时长（毫秒） */
  @State durationMs: number = 0;
  /** 是否正在播放 */
  @State playing: boolean = false;
  /** 是否显示控制层 */
  @State showControls: boolean = true;
  /** 是否正在准备 */
  @State preparing: boolean = true;
  /** 错误信息，非空时显示错误层 */
  @State errorMsg: string = '';
  /** 是否横屏，用于切换按钮图标 */
  @State isLandscape: boolean = false;
  /**
   * 视频宽高比（宽 ÷ 高），由 AVPlayer 的 videoSizeChange 回调提供
   * 初值 16:9 只是占位；拿到真实尺寸后会更新，进而驱动画面尺寸重算
   */
  @State videoAspect: number = 16 / 9;
  /**
   * 可用显示区域的像素尺寸，由铺满容器 onAreaChange 测得
   * 横竖屏切换会改变该区域，从而触发画面尺寸重算
   */
  @State areaWidth: number = 0;
  @State areaHeight: number = 0;

  /** 用户是否正在拖动进度条 */
  private dragging: boolean = false;
  /** XComponent 控制器 */
  private surfaceController: XComponentController = new XComponentController();
  /** AVPlayer 实例 */
  private player: media.AVPlayer | undefined = undefined;
  /**
   * 已打开的媒体文件句柄
   * AVPlayer 播放本地文件必须走 fd 通道，且整个播放期间 fd 要保持打开，
   * 只有 release() 之后才能 close，因此这里持有它。
   */
  private mediaFile: fileIo.File | undefined = undefined;
  /** 媒体文件字节数，作为 fdSrc.length 传入 */
  private mediaFileSize: number = 0;
  /** 渲染 surface id */
  private surfaceId: string = '';
  /** surface 是否已就绪 */
  private surfaceReady: boolean = false;
  /** AVPlayer 当前状态字符串 */
  private avState: string = 'idle';
  /** prepare 是否已发起，避免重复调用 */
  private prepared: boolean = false;
  /** 主窗口，用于横竖屏切换 */
  private mainWindow: window.Window | undefined = undefined;
  /** 观看记录仓库，用于持久化播放进度 */
  private history: WatchHistory | undefined = undefined;
  /** 诊断日志 */
  private diag: DiagLog | undefined = undefined;
  /** 本次续播的起点（毫秒） */
  private startPositionMs: number = 0;
  /** 上次落盘的时间戳，用于限制写盘频率 */
  private lastSavedAt: number = 0;
  /** timeUpdate 回调计数，用于抽样写诊断日志 */
  private tickCount: number = 0;
  /**
   * AVPlayer 是否报告过视频尺寸（videoSizeChange 回调）
   *
   * 用途：识别「容器能解开、但内部编码解不了」这种情况。
   * 实测这类失败**不报错误码**，AVPlayer 照样进入 playing 且音频正常，
   * 只是画面始终黑着 —— 因此不能靠 error 回调发现，只能靠"迟迟没有尺寸"判定。
   */
  private videoSizeReported: boolean = false;
  /** 「播放中却一直没有画面」的看门狗定时器 id */
  private videoWatchdogId: number = -1;

  /**
   * 原生软解控制器
   *
   * 什么时候用它（两条路，都会走到）：
   *   ① 预先分流：文件后缀属于实测「系统解不开」的那类（rm/rmvb/wmv/asf/ogv…），
   *      直接交给软解，不去碰 AVPlayer —— 免得先报一次 5400106 让用户看到闪错
   *   ② 兜底回退：文件后缀看着正常，但 AVPlayer 仍报「不支持格式」
   *      （同一后缀内部编码可能不同，例如 .avi 里装 VC-1），此时自动换软解重试
   *
   * 为什么要有 ②：后缀只能说明容器，说明不了内部编码。
   * 实测 .avi / .mkv 这类容器系统能解，但里面的 VC-1 / Theora 解不了，
   * 光靠后缀预判会漏掉这些情况。
   */
  private softCtl: SoftPlayerController | undefined = undefined;
  /** 当前是否走的软解通道（决定 togglePlay / seekTo 该调谁） */
  private usingSoft: boolean = false;
  /** 是否已经尝试过回退到软解，避免回退后再次失败时无限重试 */
  private softFallbackTried: boolean = false;

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as PlayerParams;
    if (params !== undefined && params !== null) {
      if (params.path !== undefined) {
        this.videoPath = params.path;
      }
      if (params.title !== undefined) {
        this.title = params.title;
      }
    }
    if (this.title.length === 0) {
      this.title = '视频播放';
    }
    // 续播起点：来自路由参数
    if (params !== undefined && params !== null && params.startMs !== undefined) {
      this.startPositionMs = params.startMs;
    }
    // 初始化观看记录仓库与诊断日志
    try {
      const appCtx = this.getUIContext().getHostContext() as commonKit.UIAbilityContext;
      this.diag = new DiagLog(appCtx);
      this.history = new WatchHistory(appCtx);
      this.diag.log('Player', 'aboutToAppear path=' + this.videoPath
        + ' startMs=' + this.startPositionMs.toString());
    } catch (err) {
      console.error('init history failed: ' + JSON.stringify(err));
      this.history = undefined;
    }
    this.setupWindow();
    this.createPlayer();
  }

  aboutToDisappear(): void {
    this.writeDiag('aboutToDisappear pos=' + this.positionMs.toString()
      + ' dur=' + this.durationMs.toString());
    // ★ 第一步：先解绑 surface，再往下走。
    //
    //   顺序在这里是决定性的。XComponent 随页面销毁时，ArkUI 会析构它的
    //   Surface 渲染节点；若此时原生侧还持有该 surface（解码线程甚至正在写帧），
    //   就会和系统销毁流程撞车。实测崩溃栈正是：
    //     RSSurfaceNode::~RSSurfaceNode -> RSNode::ClearAllModifiers（系统渲染库、主线程）
    //   触发条件就是"频率极高地在播放页与搜索页之间来回切"。
    //
    //   所以必须抢在系统销毁 surface 之前把窗口还回去，
    //   后面的 releasePlayer() 才不会再碰它。
    const sc: SoftPlayerController | undefined = this.softCtl;
    if (sc !== undefined) {
      sc.detachSurface();
    }
    // 页面要销毁了，先撤掉看门狗 —— 否则它可能在页面已消失后触发回退，
    // 去操作一个已经释放的播放器
    this.clearVideoWatchdog();
    // 退出前补记一次进度，保证「继续观看」拿到的是最新位置
    // 网络流不写 —— 观看历史是「沙箱内路径 + 进度」的语义，URL 不属于它
    if (this.durationMs > 0 && !this.isNetworkUrl(this.videoPath)) {
      this.persistProgress(this.positionMs, this.durationMs);
    }
    this.releasePlayer();
    // 退出播放页时恢复默认方向，避免影响其它页面
    this.applyOrientation(window.Orientation.AUTO_ROTATION_UNSPECIFIED);
  }

  /**
   * 进入沉浸式全屏并缓存窗口对象
   * 播放视频时隐藏状态栏和导航条是最符合预期的做法
   */
  private setupWindow(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window) => {
        this.mainWindow = win;
        win.setWindowLayoutFullScreen(true);
        win.setWindowSystemBarEnable([]);
        // 进入播放页时允许随传感器自动旋转
        win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_UNSPECIFIED);
      }).catch((err: BusinessError) => {
        console.error('setupWindow failed: ' + JSON.stringify(err));
      });
    } catch (err) {
      console.error('setupWindow failed');
    }
  }

  /**
   * 切换横竖屏
   * 横屏用 LANDSCAPE、竖屏用 PORTRAIT，都是强制方向，
   * 这样画面比例不会被系统自动旋转打断。
   */
  private toggleOrientation(): void {
    this.isLandscape = !this.isLandscape;
    this.applyOrientation(this.isLandscape
      ? window.Orientation.LANDSCAPE
      : window.Orientation.PORTRAIT);
  }

  /** 应用指定屏幕方向 */
  private applyOrientation(orientation: window.Orientation): void {
    const win: window.Window | undefined = this.mainWindow;
    if (win === undefined) {
      return;
    }
    win.setPreferredOrientation(orientation).catch((err: BusinessError) => {
      console.error('setPreferredOrientation failed: ' + JSON.stringify(err));
    });
  }

  /**
   * 判断这个地址是不是网络流
   *
   * 为什么必须单独判定：
   *   AVPlayer 的 url 只接受 fd:// 或 http(s):// 形式，
   *   而 fdSrc 只接受本地文件描述符 —— 两条通道互斥，走错就必然失败。
   *
   * @param path 播放地址
   */
  private isNetworkUrl(path: string): boolean {
    const lower: string = path.trim().toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://')
      || lower.startsWith('rtsp://') || lower.startsWith('rtmp://')
      || lower.startsWith('rtmps://');
  }

  /** 创建 AVPlayer 并注册回调 */
  private createPlayer(): void {
    // ---- 第零步：网络流单独一条通道 ----
    //   必须在 mediaTierOf 之前判断：那是按【文件后缀】分级的，
    //   对 http://... 这种地址没有意义（后缀会变成一串查询串）。
    if (this.isNetworkUrl(this.videoPath)) {
      this.writeDiag('网络流地址，走 AVPlayer 的 url 通道：' + this.videoPath);
      this.createNetworkPlayer();
      return;
    }

    // ---- 第零点五步：先看后缀要不要直接走软解 ----
    // 实测「系统解不开」的后缀直接交给软解，不让用户先看到一次格式不支持的错误
    const tier: MediaTier = mediaTierOf(this.videoPath);
    this.writeDiag('tier=' + tier.toString() + ' for ' + this.videoPath);
    if (tier === MediaTier.NEEDS_SOFT_DECODE) {
      this.writeDiag('后缀属于系统不支持的容器，直接走软解');
      this.startSoftPlayer();
      return;
    }

    // ---- 第一步：打开文件拿到 fd ----
    // AVPlayer 的 url 只接受 fd:// 或 http(s):// 形式，绝对路径会直接报
    // 「401 Invalid Parameter: not fd:// or network address」，
    // 因此本地文件必须走 fdSrc（文件描述符）通道。
    try {
      this.mediaFile = fileIo.openSync(this.videoPath, fileIo.OpenMode.READ_ONLY);
      this.mediaFileSize = fileIo.statSync(this.videoPath).size;
    } catch (err) {
      this.mediaFile = undefined;
      this.preparing = false;
      this.errorMsg = '无法读取视频文件：' + this.videoPath +
        '\n请确认文件存在且应用有权访问该目录。';
      return;
    }

    // ---- 第二步：创建播放器并绑定 fd ----
    media.createAVPlayer().then((p: media.AVPlayer) => {
      this.player = p;
      this.registerCallbacks(p);
      // 注意：audioInterruptMode 只能在 prepared/playing/paused/completed 态设置，
      // 此处仍是 idle 态，若在这里赋值会抛 5400102「unsupport audio interrupt operation」。
      // 因此改到 stateChange 的 prepared 分支里设置（见 registerCallbacks）。
      const opened: fileIo.File | undefined = this.mediaFile;
      if (opened === undefined) {
        this.errorMsg = '文件句柄已失效，请返回重试。';
        this.preparing = false;
        return;
      }
      // 设置 fdSrc 后进入 initialized 态；offset/length 描述的是整个文件
      p.fdSrc = { fd: opened.fd, offset: 0, length: this.mediaFileSize };
    }).catch((err: BusinessError) => {
      this.errorMsg = '播放器创建失败：' + err.message;
      this.preparing = false;
    });
  }

  /**
   * 创建网络流播放器（走 AVPlayer 的 url 通道）
   *
   * 与本地文件的关键区别：
   *   本地：fdSrc = { fd, offset, length } —— 需要先打开文件拿到描述符
   *   网络：url = 'http(s)://...'       —— 由系统自己去请求
   *   两者互斥，设置错了会直接报「401 Invalid Parameter:
   *   not fd:// or network address」。
   *
   * 为什么不做 URL 预检（先 HEAD 一下看是不是媒体）：
   *   预检会给每个地址凭空加上一次网络往返，而且很多 CDN 不支持 HEAD；
   *   真正的判定交给 AVPlayer 的错误回调，它给的信息比预检更准。
   *   代价是用户会等一次失败 —— 所以错误文案要把「可能的原因」说清楚，
   *   尤其是「贴的是网页而不是视频地址」这个最常见的情况。
   */
  private createNetworkPlayer(): void {
    this.preparing = true;
    this.errorMsg = '';
    media.createAVPlayer().then((p: media.AVPlayer) => {
      this.player = p;
      this.registerCallbacks(p);
      // url 通道：直接交给系统去请求
      p.url = this.videoPath;
    }).catch((err: BusinessError) => {
      this.errorMsg = '网络播放器创建失败：' + err.message;
      this.preparing = false;
    });
  }

  /* ============================================================
     原生软解通道
     ============================================================ */

  /**
   * 判断这个错误码是否代表「系统不支持该格式」
   *
   * 5400106 = Unsupported Format：解封装或解码器不支持，正是软解能救的情况。
   *
   * ★ 2026-09-26 放宽：原先只认 5400106，会漏掉一类情况。
   *   实测 .mkv / .mp4 / .avi 这类「容器系统能解、内部编码解不了」的文件，
   *   系统**未必**报 5400106 —— 有时只报一个笼统的解码错误码，有时干脆
   *   不报错（AVPlayer 照常 playing、音频正常，只是画面黑着）。
   *   后者由下面的看门狗兜住；前者在这里把同属"解码能力不足"的错误码一并纳入。
   *
   *   仍不回退的情况：文件不存在/无权限/磁盘错误这一类，软解同样救不了，
   *   盲目回退只会把一个清晰的错误掩盖成一次更慢的失败。
   */
  private isUnsupportedFormat(code: number): boolean {
    // 5400106 Unsupported Format
    if (code === 5400106) {
      return true;
    }
    // 5400102 Operation not allowed：实测在「解码器不支持」时也会以这个码报出
    // （状态机被推进到非法状态）。软解不依赖 AVPlayer 状态机，能绕开。
    if (code === 5400102) {
      return true;
    }
    // 5400103 stream 相关：解封装/解码流建立失败
    if (code === 5400103) {
      return true;
    }
    return false;
  }

  /**
   * 取消「一直没有画面」的看门狗
   * 幂等：可重复调用
   */
  private clearVideoWatchdog(): void {
    if (this.videoWatchdogId >= 0) {
      clearTimeout(this.videoWatchdogId);
      this.videoWatchdogId = -1;
    }
  }

  /**
   * 启动「播放中却一直没有画面」的看门狗
   *
   * 为什么需要它：上面说过，有一类失败 AVPlayer 不报错 ——
   * 容器解开、音频正常、状态机走到 playing，但视频解码器解不出画面，
   * 于是 videoSizeChange 永远不触发，界面一直黑着。
   * 这种情况按错误码是抓不到的，只能靠"给了足够时间仍无画面"来判定。
   *
   * 判定条件（三个都满足才回退，避免误判）：
   *   ① 后缀是视频容器（音频文件本来就没有画面，不能当失败）
   *   ② 没走软解、也没回退过
   *   ③ duration > 0（说明文件真的解开了，不是打不开）
   *   ④ 仍处于 playing（若已暂停/播完，用户可能只是没让它播）
   *
   * 延迟取值：3.5 秒。太短会误判慢启动的大文件，太长让用户白等。
   * 实测普通样本 1 秒内就会报尺寸，3.5 秒足够宽裕。
   */
  private startVideoWatchdog(): void {
    this.clearVideoWatchdog();
    if (!isVideoContainer(this.videoPath)) {
      return;
    }
    if (this.usingSoft || this.softFallbackTried) {
      return;
    }
    this.videoWatchdogId = setTimeout(() => {
      this.videoWatchdogId = -1;
      if (this.videoSizeReported || this.usingSoft || this.softFallbackTried) {
        return;
      }
      if (this.durationMs <= 0 || this.avState !== 'playing') {
        return;
      }
      this.writeDiag('看门狗触发：playing 但 ' + this.videoPath
        + ' 始终无画面尺寸 dur=' + this.durationMs.toString()
        + ' aspect 仍为占位值 → 判定为容器能开、编码解不了，回退软解');
      this.fallbackToSoft('播放中始终无画面（疑似视频编码不支持）');
    }, 3500);
  }

  /**
   * 切到软解通道重试
   * 会先把 AVPlayer 彻底释放，避免两个播放器同时持有 surface 互相抢画面
   */
  private fallbackToSoft(reason: string): void {
    if (this.softFallbackTried || this.usingSoft) {
      return;
    }
    this.softFallbackTried = true;
    // 回退后由软解接管，看门狗不再需要（也防止它二次触发）
    this.clearVideoWatchdog();
    this.writeDiag('回退到软解，原因：' + reason);
    // 释放 AVPlayer 与其 fd：软解自己按路径打开文件，不需要 fd
    const p: media.AVPlayer | undefined = this.player;
    this.player = undefined;
    if (p !== undefined) {
      p.release().catch((err: BusinessError) => {
        console.error('release for fallback failed: ' + JSON.stringify(err));
      });
    }
    this.closeMediaFile();
    // 清掉上一次的错误，让软解有机会重新开始
    this.errorMsg = '';
    this.preparing = true;
    this.prepared = false;
    this.startSoftPlayer();
  }

  /**
   * 启动软解通道
   * 软解直接按文件路径打开（FFmpeg 自己处理解封装），不走 fd
   */
  private startSoftPlayer(): void {
    this.usingSoft = true;
    this.preparing = true;
    this.errorMsg = '';

    const ctl: SoftPlayerController = new SoftPlayerController((snap: SoftPlayerSnapshot) => {
      this.onSoftUpdate(snap);
    });
    this.softCtl = ctl;

    // surface 可能还没就绪（XComponent 的 onLoad 是异步的），
    // 那就先不带 surface 创建，等 onSurfaceCreated 里再补挂
    const attached: boolean = ctl.attach(this.surfaceReady ? this.surfaceId : '');
    if (!attached) {
      this.preparing = false;
      this.errorMsg = '软解播放器创建失败';
      return;
    }
    if (!ctl.prepare(this.videoPath)) {
      // prepare 的同步失败已经在 onSoftUpdate 里通过 error 快照报出来了
      this.preparing = false;
    }
  }

  /** 软解状态更新（在 JS 线程被调用） */
  private onSoftUpdate(snap: SoftPlayerSnapshot): void {
    if (snap.error.length > 0) {
      this.preparing = false;
      this.errorMsg = '软解失败：' + snap.error;
      return;
    }
    // 诊断：确认软解报上来的时长到底是数字还是别的类型
    if (this.tickCount === 0) {
      this.tickCount = 1;
      this.writeDiag('soft snap: dur=' + snap.durationMs.toString()
        + ' typeof=' + (typeof snap.durationMs)
        + ' formatted=' + formatTime(snap.durationMs)
        + ' state=' + snap.state.toString()
        + ' wh=' + snap.width.toString() + 'x' + snap.height.toString());
    }
    // 时长与画面尺寸
    if (snap.durationMs > 0 && this.durationMs !== snap.durationMs) {
      this.durationMs = snap.durationMs;
    }
    if (snap.width > 0 && snap.height > 0) {
      const aspect: number = snap.width / snap.height;
      if (aspect !== this.videoAspect) {
        this.videoAspect = aspect;
      }
    }
    // 播放位置（拖动时不要被回写覆盖）
    if (!this.dragging) {
      this.positionMs = snap.positionMs;
    }

    const st: SoftPlayerState = snap.state;
    if (st === SoftPlayerState.READY) {
      this.preparing = false;
      this.errorMsg = '';
      // 就绪即播：续播起点用 seekTo 处理（软解在 READY 态接受 seek）
      //
      // 诊断：这里必须记下"决定要不要 seek"的三个输入。
      // 「rm 文件无法续播」这个缺陷有几种可能：startMs 没传进来、
      // 进 READY 时 durationMs 还是 0（于是被 if 拦掉）、或者 seek 发了但没生效。
      // 只有把这三个值记下来才能区分，否则只能靠猜。
      this.writeDiag('soft READY: startMs=' + this.startPositionMs.toString()
        + ' snapDur=' + snap.durationMs.toString()
        + ' thisDur=' + this.durationMs.toString()
        + ' 将seek=' + ((this.startPositionMs > 0 && snap.durationMs > 0) ? '是' : '否'));
      if (this.startPositionMs > 0 && snap.durationMs > 0) {
        this.softCtl?.seekTo(this.startPositionMs);
        this.writeDiag('soft 已发起 seekTo(' + this.startPositionMs.toString() + ')');
      }
      this.softCtl?.play();
    } else if (st === SoftPlayerState.PLAYING) {
      this.playing = true;
      this.preparing = false;
      this.errorMsg = '';
      if (this.durationMs > 0) {
        this.lastSavedAt = Date.now();
        this.persistProgress(this.positionMs, this.durationMs);
      }
    } else if (st === SoftPlayerState.PAUSED) {
      this.playing = false;
      this.errorMsg = '';
    } else if (st === SoftPlayerState.COMPLETED) {
      this.playing = false;
      this.positionMs = this.durationMs;
      this.persistProgress(this.durationMs, this.durationMs);
    } else if (st === SoftPlayerState.ERROR_STATE) {
      this.preparing = false;
    }

    // 软解进度同样要按 1 秒间隔落盘（与 AVPlayer 通道保持一致）
    const now: number = Date.now();
    if (this.playing && now - this.lastSavedAt > 1000 && this.durationMs > 0) {
      this.lastSavedAt = now;
      this.persistProgress(this.positionMs, this.durationMs);
    }
  }


  /** 注册状态机、进度、错误回调 */
  private registerCallbacks(p: media.AVPlayer): void {
    p.on('stateChange', (state: string, reason: number) => {
      this.avState = state;
      if (state === 'initialized') {
        this.tryPrepare(p);
      } else if (state === 'prepared') {
        this.writeDiag('state=prepared dur=' + p.duration.toString());
        // audioInterruptMode 只能在 prepared / playing / paused / completed 态设置。
        // 放在这里才能生效（且必须在首次 play() 之前），避免 5400102。
        p.audioInterruptMode = audio.InterruptMode.SHARE_MODE;
        // ★ videoScaleType 同样只能在 prepared / playing / paused / completed 态设置！
        //   之前写在 prepared 之前（initialized 态），设置被忽略，导致画面被拉伸填满。
        p.videoScaleType = media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
        this.durationMs = p.duration;
        this.writeDiag('duration set to ' + this.durationMs.toString()
          + ' (p.duration=' + p.duration.toString() + ')');
        this.preparing = false;
        // 已经真正准备好，清掉此前累积的错误信息
        this.errorMsg = '';
        // 有续播起点则先跳转再播（此时已在 prepared 态，可以 seek）
        //
        // ★ 网络流不做续播 seek：
        //   ① 从网络流页进入时本来就没带起点（没有进度记录）；
        //   ② 更要紧的是实时流（RTSP / 直播 HLS）没有总时长，
        //      对它们 seek 行为未定义，贸然调用可能让播放卡住。
        if (!this.isNetworkUrl(this.videoPath)
          && this.startPositionMs > 0 && this.durationMs > 0) {
          p.seek(this.startPositionMs, media.SeekMode.SEEK_CLOSEST);
        }
        p.play();
      } else if (state === 'playing') {
        this.playing = true;
        this.preparing = false;
        this.errorMsg = '';
        // 一进入播放就落盘一次：保证该视频的 updatedAt 立刻变成"最新"，
        // 首页据此把它认定为"最近观看"，不会串到别的视频上。
        // 网络流不写观看历史 —— 那份记录是「沙箱内绝对路径 + 进度」的语义，
        // URL 混进去会让首页的续播逻辑拿到它无意义的数据（见 NetworkStreamStore 的说明）。
        if (this.durationMs > 0 && !this.isNetworkUrl(this.videoPath)) {
          this.lastSavedAt = Date.now();
          this.persistProgress(this.positionMs, this.durationMs);
        }
        // ★ 启动「播放中却一直没有画面」的看门狗。
        //   有一类失败不报错误码（容器能开、音频正常、就是没画面），
        //   只能这样兜住，见 startVideoWatchdog 的说明。
        //
        //   ★ 网络流不启看门狗：它的兜底动作是「回退到内置软解」，
        //     而内置 FFmpeg 是 --disable-network 构建的，根本打不开 URL ——
        //     回退必然失败，只会把一个清晰的网络错误变成一次更慢的失败。
        this.startVideoWatchdog();
      } else if (state === 'paused') {
        this.playing = false;
        this.errorMsg = '';
      } else if (state === 'completed') {
        this.playing = false;
        this.positionMs = this.durationMs;
        // 播完：记成完整进度，首页据此判定「已看完」而不再列入继续观看
        this.persistProgress(this.durationMs, this.durationMs);
      } else if (state === 'error') {
        this.preparing = false;
      }
    });

    // 播放进度，用于刷新进度条与时间文本
    p.on('timeUpdate', (time: number) => {
      if (!this.dragging) {
        this.positionMs = time;
      }
      // 进度诊断：每 10 次回调记一次，用于核对滑块数值与总长是否匹配
      this.tickCount++;
      if (this.tickCount % 10 === 0) {
        this.writeDiag('tick pos=' + time.toString()
          + ' dur=' + this.durationMs.toString()
          + ' ratio=' + (this.durationMs > 0 ? (time / this.durationMs).toFixed(3) : 'n/a')
          + ' sliderMax=' + (this.durationMs > 0 ? this.durationMs : 1).toString());
      }
      // 落盘间隔：1 秒。
      // 之前是 3 秒，导致用户"看 2 秒就退出"时最新位置还没写盘，
      // 首页读到的仍是上一次的记录，表现为"时间对不上"。
      // 记录文件很小，1 秒一次的开销可以接受。
      const now: number = Date.now();
      if (now - this.lastSavedAt > 1000 && this.durationMs > 0) {
        this.lastSavedAt = now;
        this.persistProgress(time, this.durationMs);
      }
    });

    // 视频真实尺寸：拿到后更新宽高比，驱动画面尺寸重算
    p.on('videoSizeChange', (width: number, height: number) => {
      if (width > 0 && height > 0) {
        this.videoAspect = width / height;
        // 报告过尺寸 = 视频解码器确实在工作，看门狗可以撤了
        if (!this.videoSizeReported) {
          this.videoSizeReported = true;
          this.writeDiag('videoSizeChange ' + width.toString() + 'x'
            + height.toString() + ' → 视频解码正常，撤销看门狗');
        }
        this.clearVideoWatchdog();
      }
    });

    p.on('error', (err: BusinessError) => {
      this.writeDiag('AVPlayer error code=' + err.code.toString() + ' msg=' + err.message);
      // ★ 网络流不回退软解：内置 FFmpeg 是 --disable-network 构建的，
      //   打不开 URL —— 回退必然失败，只会把清晰的网络错误变成更慢的失败。
      if (this.isNetworkUrl(this.videoPath)) {
        this.preparing = false;
        this.errorMsg = this.networkErrorText(err);
        return;
      }
      // ★ 系统不支持这个格式时，自动换软解再试一次。
      //   只对「格式不支持」这一类回退：其它错误（权限、文件损坏）软解也救不了，
      //   盲目回退只会把真实错误掩盖成一个更慢的失败。
      if (this.isUnsupportedFormat(err.code) && !this.usingSoft && !this.softFallbackTried) {
        this.fallbackToSoft('AVPlayer ' + err.code.toString());
        return;
      }
      this.preparing = false;
      this.errorMsg = '播放失败（' + err.code.toString() + '）：' + err.message;
    });
  }

  /**
   * 网络流失败时的用户可读文案
   *
   * ★ 为什么要专门写这一段，而不是直接抛系统错误码：
   *   实测最常见的情况是「用户贴的是网页地址而不是视频地址」
   *   （例如 https://www.bilibili.com/video/BVxxxx）。
   *   那种地址返回的是一整页 HTML，播放器只会报一个笼统的解封装错误，
   *   用户完全不知道自己错在哪 —— 会反复重试同一个地址。
   *   所以这里必须把「网页 ≠ 视频地址」这件事直接说出来。
   *
   * 其余原因（鉴权 / 防盗链 / 时效签名 / 网络）也一并列出，
   * 因为播放器给不出区分它们的信息。
   *
   * @param err 系统错误
   */
  private networkErrorText(err: BusinessError): string {
    const u: string = this.videoPath.toLowerCase();
    const looksLikePage: boolean = u.indexOf('.html') >= 0
      || u.indexOf('/video/') >= 0
      || u.indexOf('/watch') >= 0
      || u.indexOf('bilibili.com') >= 0
      || u.indexOf('youtube.com') >= 0
      || u.indexOf('youku.com') >= 0
      || u.indexOf('iqiyi.com') >= 0
      || u.indexOf('douyin.com') >= 0;
    let head: string = '网络播放失败（' + err.code.toString() + '）';
    if (looksLikePage) {
      head = '这个地址看起来是一个【网页】，不是视频地址';
    }
    return head
      + '\n\n常见原因：'
      + '\n· 贴的是网页地址 —— 视频网站页面上是播放器界面，'
      + '真正的视频流地址需要从页面/接口里解析出来，不能直接用'
      + '\n· 需要登录或鉴权（会员内容、私有链接）'
      + '\n· 防盗链限制（要求特定 Referer / User-Agent）'
      + '\n· 链接有时效签名，已过期'
      + '\n· 网络不通或服务器拒绝'
      + '\n\n建议：换一个【直接指向媒体文件】的地址试试，'
      + '例如以 .mp4 / .m3u8 / .flv 结尾的链接。'
      + '\n\n地址：' + this.videoPath
      + '\n系统信息：' + err.message;
  }

  /**
   * 计算画面应显示的宽度（像素）
   * 算法：contain —— 按视频宽高比在可用区域内等比缩放，取较小者，保证完整显示
   * 这样竖屏看横片会上下留黑边、横屏看竖片会左右留黑边，且永不裁切画面
   */
  private computeVideoWidth(): number {
    if (this.areaWidth <= 0 || this.areaHeight <= 0 || this.videoAspect <= 0) {
      return 0;
    }
    const fitByWidth: number = this.areaWidth;
    const fitByHeight: number = this.areaHeight * this.videoAspect;
    return Math.min(fitByWidth, fitByHeight);
  }

  /** 画面应显示的高度（像素） */
  private computeVideoHeight(): number {
    const w: number = this.computeVideoWidth();
    if (w <= 0) {
      return 0;
    }
    return w / this.videoAspect;
  }

  /** 画面水平居中所需的左侧偏移 */
  private computeVideoX(): number {
    return (this.areaWidth - this.computeVideoWidth()) / 2;
  }

  /** 画面垂直居中所需的顶部偏移 */
  private computeVideoY(): number {
    return (this.areaHeight - this.computeVideoHeight()) / 2;
  }

  /**
   * 把当前进度写入观看记录
   *
   * ★ 网络流不写 —— 这个判断放在这里（函数的单一咽喉点），
   *   不要散在调用点。
   *
   *   为什么：本函数有 6 个调用点（timeUpdate 每秒一次、prepared 的
   *   seek 之后、playing 首次、completed、aboutToDisappear、看门狗），
   *   逐个加 if 一定会漏 —— 实测就漏了 4 处，日志里网络流照样
   *   出现了 "persist OK"。
   *
   *   为什么不该写：观看历史的键是「沙箱内绝对路径」，首页的
   *   「继续观看」是从媒体库里按路径匹配的 —— URL 记录永远不会被
   *   匹配到，只会白占条目；而且它的 duration 非 0 时还会被
   *   listUnfinished 判成「未播完」，混进首页焦点位。
   *
   * @param position 播放位置（毫秒）
   * @param duration 总时长（毫秒）
   */
  private persistProgress(position: number, duration: number): void {
    if (this.isNetworkUrl(this.videoPath)) {
      return;   // 静默跳过，不必写诊断日志刷屏
    }
    if (this.history === undefined) {
      this.writeDiag('persist SKIPPED: history undefined, pos=' + position.toString());
      return;
    }
    if (duration <= 0) {
      this.writeDiag('persist SKIPPED: duration<=0, pos=' + position.toString());
      return;
    }
    this.history.save(this.videoPath, this.title, position, duration);
    this.writeDiag('persist OK pos=' + position.toString() + ' dur=' + duration.toString()
      + ' total=' + this.history.list().length.toString());
  }

  /** 写诊断日志（diag 未初始化时静默忽略） */
  private writeDiag(message: string): void {
    const d: DiagLog | undefined = this.diag;
    if (d !== undefined) {
      d.log('Player', message);
    }
  }

  /** surface 是否可用 */
  private hasSurfaceId(): boolean {
    return this.surfaceReady && this.surfaceId.length > 0;
  }

  /**
   * surface 就绪与 initialized 态都满足时才真正 prepare
   * 横竖屏切换会导致 surface 重建，此时只需重新绑定 surfaceId，不能重新 prepare。
   */
  private tryPrepare(p: media.AVPlayer): void {
    if (!this.hasSurfaceId()) {
      return;
    }
    p.surfaceId = this.surfaceId;
    if (this.prepared) {
      // 已播放过：只是 surface 换了，重新绑定即可
      return;
    }
    if (this.avState !== 'initialized') {
      return;
    }
    this.prepared = true;
    p.prepare().catch((err: BusinessError) => {
      this.preparing = false;
      this.errorMsg = '准备失败（' + err.code.toString() + '）：' + err.message;
    });
  }

  /** XComponent surface 创建完成（横竖屏切换后会再次触发） */
  private onSurfaceCreated(): void {
    const id: string = this.surfaceController.getXComponentSurfaceId();
    if (id.length === 0) {
      return;
    }
    this.surfaceId = id;
    this.surfaceReady = true;
    // 软解通道：横竖屏切换会换 surface id，必须重新绑定，
    // 否则换屏之后画面就再也不更新了（解码还在跑，但画到了旧 surface 上）
    if (this.usingSoft) {
      this.softCtl?.attach(id);
      return;
    }
    if (this.player !== undefined) {
      this.tryPrepare(this.player);
    }
  }

  /**
   * 释放播放器（两条通道都要释放）
   *
   * fd 的生命周期必须晚于播放器：SDK 明确要求「调用方负责关闭 fd」，
   * 但关闭时机必须在 release() 完成之后 —— 提前关闭会让播放中途断流。
   * 因此这里先 release，再在 then/catch 里关闭文件。
   */
  private releasePlayer(): void {
    // 软解通道：直接释放，不涉及 fd（FFmpeg 自己按路径打开文件）
    const sc: SoftPlayerController | undefined = this.softCtl;
    this.softCtl = undefined;
    if (sc !== undefined) {
      sc.release();
    }

    const p: media.AVPlayer | undefined = this.player;
    this.player = undefined;
    if (p === undefined) {
      this.closeMediaFile();
      return;
    }
    p.release().then(() => {
      this.closeMediaFile();
    }).catch((err: BusinessError) => {
      console.error('release failed: ' + JSON.stringify(err));
      this.closeMediaFile();
    });
  }

  /** 关闭文件句柄（幂等，可重复调用） */
  private closeMediaFile(): void {
    const opened: fileIo.File | undefined = this.mediaFile;
    this.mediaFile = undefined;
    if (opened === undefined) {
      return;
    }
    try {
      fileIo.closeSync(opened);
    } catch (err) {
      console.error('closeSync failed: ' + JSON.stringify(err));
    }
  }

  /** 播放 / 暂停 */
  private togglePlay(): void {
    // 软解通道：状态由快照维护，直接按快照反转
    if (this.usingSoft) {
      const c: SoftPlayerController | undefined = this.softCtl;
      if (c === undefined) {
        return;
      }
      if (this.playing) {
        c.pause();
      } else {
        c.play();
      }
      return;
    }
    if (this.player === undefined) {
      return;
    }
    const p: media.AVPlayer = this.player;
    if (this.playing) {
      p.pause().catch((err: BusinessError) => {
        console.error('pause failed: ' + JSON.stringify(err));
      });
    } else {
      p.play().catch((err: BusinessError) => {
        console.error('play failed: ' + JSON.stringify(err));
      });
    }
  }

  /** 后退 10 秒 */
  private seekBackward(): void {
    this.seekTo(Math.max(0, this.positionMs - 10000));
  }

  /** 前进 10 秒 */
  private seekForward(): void {
    this.seekTo(Math.min(this.durationMs, this.positionMs + 10000));
  }

  /** 跳转到指定毫秒位置 */
  private seekTo(ms: number): void {
    if (this.durationMs <= 0) {
      return;
    }
    if (this.usingSoft) {
      this.softCtl?.seekTo(ms);
      this.positionMs = ms;
      return;
    }
    if (this.player !== undefined) {
      this.player.seek(ms, media.SeekMode.SEEK_CLOSEST);
      this.positionMs = ms;
    }
  }

  /** 返回上一页 */
  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  build() {
    // ===================== 布局要点（踩过三次坑后的最终做法） =====================
    //
    // 1) 层叠顺序：Stack 中子节点「先写的在底层、后写的在上层」，
    //    所以视频层必须最先写，所有控件写在它后面，否则会被 surface 盖住。
    //
    // 2) 【关键教训】不要用 .align() 给 Stack 的子节点做绝对定位。
    //    .align() 在 Stack 中与 alignContent 同义，含义是「设置整个容器的对齐方式」，
    //    而不是「只设置这一个子节点」。想用它把顶栏送上去、底栏送下去，
    //    结果语义含糊、表现不确定：出现过「两栏都居中」，也出现过「两栏都在顶部」。
    //
    // 3) 【本版做法】控制层用一个铺满屏幕的 Column，内部结构固定为：
    //        顶栏 ── Blank() ── 底栏
    //    Blank() 是 ArkUI 的弹性占位组件，会吃掉 Column 里所有剩余空间，
    //    从而把顶栏顶到最上、底栏顶到最下。这是纯布局流控制，结果完全确定，
    //    不依赖任何对齐语义，横竖屏切换时也不会互相挤动。
    //
    // 4) 视频画面尺寸由代码显式计算（contain 算法）并用 .position() 居中，
    //    不使用 .aspectRatio()，也不依赖 Stack 的对齐语义。
    //
    // 5) 根 Stack 不使用 expandSafeArea：它会影响 Stack 的布局区域判断。
    //    沉浸式只交给 XComponent（视频画面），控制栏留在安全区内，
    //    因此返回按钮不会顶进状态栏/刘海。
    Stack({ alignContent: Alignment.TopStart }) {
      // ---------- 0. 测量层：铺满屏幕，仅用于测出可用区域尺寸 ----------
      // 必须是 Stack 的第一个子节点，这样它决定整个 Stack 的尺寸。
      // onAreaChange 在横竖屏切换后会再次触发，测量值随之更新。
      Column()
        .width('100%')
        .height('100%')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const w: number = Number(newArea.width);
          const h: number = Number(newArea.height);
          if (w > 0 && h > 0 && (w !== this.areaWidth || h !== this.areaHeight)) {
            this.areaWidth = w;
            this.areaHeight = h;
          }
        })

      // ---------- 1. 视频渲染层（按视频比例显式定尺寸 + 精确居中） ----------
      // 为什么不用 .aspectRatio()：
      //   它只负责「按比例约束尺寸」，不负责居中，且与百分比宽高组合时
      //   在不同屏幕比例下表现不确定（实测出现不居中、横屏画面超出屏幕）。
      // 改为自己算「装得下」的尺寸，再用 .position() 精确居中，结果完全确定。
      if (this.computeVideoWidth() > 0) {
        XComponent({
          type: XComponentType.SURFACE,
          controller: this.surfaceController
        })
          .width(this.computeVideoWidth())
          .height(this.computeVideoHeight())
          // position 以父容器左上角为原点，算出居中偏移
          .position({ x: this.computeVideoX(), y: this.computeVideoY() })
          .onLoad(() => {
            this.onSurfaceCreated();
          })
          .onClick(() => {
            this.showControls = !this.showControls;
          })
      }

      // ---------- 2. 控制层：顶栏 ⟶ Blank 撑开 ⟶ 底栏 ----------
      Column() {
        // ===== 2.1 顶部信息栏（贴顶） =====
        if (this.showControls) {
          Row() {
            Text('‹')
              .fontSize(30)
              .fontColor(Color.White)
              .padding({ left: 12, right: 12 })
              .onClick(() => {
                this.goBack();
              })

            Column({ space: 2 }) {
              Text(this.title)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)

              Text(this.videoPath)
                .fontSize(11)
                .fontColor('rgba(255,255,255,0.55)')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .textAlign(TextAlign.Start)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            // 横竖屏切换
            Text(this.isLandscape ? '⛶' : '⤢')
              .fontSize(22)
              .fontColor(Color.White)
              .padding({ left: 12, right: 16 })
              .onClick(() => {
                this.toggleOrientation();
              })
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 20, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .linearGradient({
            angle: 180,
            colors: [['rgba(0,0,0,0.75)', 0.0], ['rgba(0,0,0,0.00)', 1.0]]
          })
        }

        // ===== 2.2 弹性空隙：吃掉全部剩余高度，把底栏推到底部 =====
        Blank()

        // ===== 2.3 底部控制栏（贴底） =====
        if (this.showControls) {
          Column({ space: 10 }) {
            // ---- 进度条行 ----
            Row({ space: 12 }) {
              Text(formatTime(this.positionMs))
                .fontSize(12)
                .fontColor(Color.White)
                .width(56)
                .textAlign(TextAlign.Center)

              // 注意：不要设置 step。
              // 之前写 step: 100 会把 4 秒的视频量化成约 40 个离散档位，
              // 滑块位置被"吸附"到整百毫秒，看起来与实际进度对不上。
              // 不设 step 即为连续取值，滑块位置与 positionMs 严格成比例。
              Slider({
                value: this.positionMs,
                min: 0,
                max: this.durationMs > 0 ? this.durationMs : 1,
                style: SliderStyle.OutSet
              })
                .layoutWeight(1)
                .width('100%')
                .height(32)
                .blockColor(Color.White)
                .trackColor('rgba(255,255,255,0.30)')
                .selectedColor(Theme.ACCENT)
                .onChange((value: number, mode: SliderChangeMode) => {
                  if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                    this.dragging = true;
                    this.positionMs = value;
                  } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    this.dragging = false;
                    this.seekTo(value);
                  }
                })

              Text(formatTime(this.durationMs))
                .fontSize(12)
                .fontColor('rgba(255,255,255,0.70)')
                .width(56)
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)

            // ---- 按钮行 ----
            Row({ space: 32 }) {
              Text('⏪')
                .fontSize(24)
                .onClick(() => {
                  this.seekBackward();
                })

              Text(this.playing ? '⏸' : '▶')
                .fontSize(34)
                .onClick(() => {
                  this.togglePlay();
                })

              Text('⏩')
                .fontSize(24)
                .onClick(() => {
                  this.seekForward();
                })
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ left: 20, right: 20, top: 20, bottom: 28 })
          .linearGradient({
            angle: 0,
            colors: [['rgba(0,0,0,0.80)', 0.0], ['rgba(0,0,0,0.00)', 1.0]]
          })
        }
      }
      .width('100%')
      .height('100%')

      // ---------- 3. 准备中遮罩（铺满并居中） ----------
      if (this.preparing && this.errorMsg.length === 0) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(Theme.ACCENT)
          Text('正在准备播放…')
            .fontSize(14)
            .fontColor('rgba(255,255,255,0.80)')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ---------- 4. 错误层（铺满并居中） ----------
      if (this.errorMsg.length > 0) {
        Column({ space: 16 }) {
          Text('⚠️')
            .fontSize(40)
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor('rgba(255,255,255,0.85)')
            .textAlign(TextAlign.Center)
            .padding({ left: 32, right: 32 })
          Button('返回')
            .fontSize(15)
            .backgroundColor(Theme.ACCENT)
            .onClick(() => {
              this.goBack();
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('rgba(0,0,0,0.85)')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // 根 Stack 不使用 expandSafeArea：它会影响 Stack 的布局区域判断，
    // 沉浸式已交给 XComponent，控制栏保持在安全区内。
  }
}
