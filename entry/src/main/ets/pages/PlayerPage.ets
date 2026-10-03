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
import { SoftPlayerState, SoftAudioTrack, SoftSubtitleTrack } from '../model/SoftPlayerTypes';
import {
  ExternalSubtitle, SubtitleCandidate, current as externalSubtitle,
  findSidecarSubtitles, loadSubtitleFile, pickSubtitleFile, SUBTITLE_EXTENSIONS,
  isExternalActive, setExternalActive, restoreExternalSubtitle
} from '../model/SubtitleLoader';

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
 * 把容器里的语言标签换成中文
 *
 * 为什么值得做这层映射：音轨/字幕轨的语言在容器里是 ISO 639-2 三字母码
 * （chi / eng / jpn），直接显示"音轨 1 · chi"对普通用户没有意义 ——
 * 而这几行代码能让它变成"音轨 1 · 中文"。常见的十几种覆盖了就够。
 */
function translateLanguage(code: string): string {
  const c: string = code.toLowerCase();
  if (c === 'chi' || c === 'zho' || c === 'zh') { return '中文'; }
  if (c === 'eng' || c === 'en') { return '英语'; }
  if (c === 'jpn' || c === 'ja') { return '日语'; }
  if (c === 'kor' || c === 'ko') { return '韩语'; }
  if (c === 'fra' || c === 'fre' || c === 'fr') { return '法语'; }
  if (c === 'deu' || c === 'ger' || c === 'de') { return '德语'; }
  if (c === 'spa' || c === 'es') { return '西班牙语'; }
  if (c === 'rus' || c === 'ru') { return '俄语'; }
  if (c === 'ita' || c === 'it') { return '意大利语'; }
  if (c === 'por' || c === 'pt') { return '葡萄牙语'; }
  if (c === 'tha' || c === 'th') { return '泰语'; }
  if (c === 'vie' || c === 'vi') { return '越南语'; }
  if (c === 'ara' || c === 'ar') { return '阿拉伯语'; }
  if (c === 'hin' || c === 'hi') { return '印地语'; }
  return code;
}

/** 声道数 → 人话（5.1 / 7.1 这类叫法比"6 声道"更符合习惯） */
function channelLabel(ch: number): string {
  if (ch === 1) { return '单声道'; }
  if (ch === 2) { return '立体声'; }
  if (ch === 6) { return '5.1'; }
  if (ch === 8) { return '7.1'; }
  return ch.toString() + ' 声道';
}

/**
 * 视频播放页
 *
 * 布局采用「上中下」三段式，三段都是同一个 Stack 的子节点：
 *   - 顶部信息栏 + 返回按钮：贴顶（Stack 默认 TopStart 对齐）
 *   - 视频渲染层：铺满整屏，由 videoScaleType 保证不拉伸变形
 *   - 底部控制栏：贴底（alignContent: Alignment.Bottom）
 * 顶栏与底栏的显隐由 showControls 统一控制。
 *
 * ★ 控制层显隐（2026-10-03 修）★
 *   原来是"点 XComponent 切换 showControls"，但真机实测**点了没反应**：
 *   XComponent(SURFACE) 的 onClick 在该平台上不派发（surface 由原生渲染，
 *   触摸事件不回到 ArkUI 的点击回调），而铺满全屏的控制层 Column 又会把
 *   落在空白处的触摸吞掉，于是控制栏一旦显示就再也藏不掉。
 *   现在把 click 挂在**控制层 Column 自己**身上：
 *     · 它始终存在（两个 if 只包住顶栏/底栏，Column 本身不受显隐影响），
 *       所以隐藏之后仍然有满屏的点击目标可以把它唤回来；
 *     · ArkUI 里子组件优先响应，所以进度条、按钮、返回键的点击不受影响；
 *     · 播放中若干秒无操作自动隐藏（见 tickControlsAutoHide），
 *       暂停时不隐藏（那时控制栏是必需品）。
 *
 * 横竖屏：通过 window.setPreferredOrientation 切换，
 * 方向变化时 XComponent 的 surface 会重建，因此 onLoad 里做了幂等处理。
 */

/**
 * 播放中控制层的自动隐藏延时（毫秒）
 *
 * 取值理由：太短（<3 秒）用户还没点到按钮就没了；太长（>8 秒）等于没做。
 * 5 秒是主流播放器的量级，也足够"看一眼进度"。
 */
const CONTROLS_AUTO_HIDE_MS: number = 5000;
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

  // ==================== 音轨与字幕（2026-09-29 新增） ====================
  //
  // 为什么字幕文本用 @State 而轨道列表不用：
  //   字幕文本每次变化都要重绘（就是屏幕上的那行字），必须是响应式的；
  //   而轨道列表只在打开面板时读一次，用普通成员就够，
  //   让它参与渲染只会带来无谓的重绘。

  /** 当前要显示的字幕文本（空串 = 不显示） */
  @State subtitleText: string = '';
  /** 是否显示音轨/字幕选择面板 */
  @State showTrackPanel: boolean = false;
  /** 文件里可切换的音轨（面板打开时从控制器快照刷新） */
  @State audioTracks: SoftAudioTrack[] = [];
  /** 文件里的字幕轨（含不支持的图形字幕） */
  @State subtitleTracks: SoftSubtitleTrack[] = [];
  /** 当前音轨流下标 */
  @State currentAudioIndex: number = -1;
  /** 当前内嵌字幕轨流下标 */
  @State currentSubtitleIndex: number = -1;
  /**
   * 外挂字幕：是否启用
   *
   * 外挂与内嵌是**互斥**的两条路径（同时显示会叠字），
   * 所以用这个标志表示"当前生效的是外挂字幕"。
   */
  @State usingExternalSubtitle: boolean = false;
  /** 外挂字幕显示名（面板上展示） */
  @State externalSubtitleName: string = '';
  /** 同目录发现的外挂字幕候选 */
  @State sidecarCandidates: SubtitleCandidate[] = [];
  /** 轨道/字幕操作的状态提示（例如"切换音轨失败"） */
  @State trackNotice: string = '';

  /** 字幕刷新定时器 */
  private subtitleTimer: number = -1;

  /** 用户是否正在拖动进度条 */
  private dragging: boolean = false;

  /**
   * 控制层最近一次"被唤出/被操作"的时刻（Date.now()，毫秒）
   *
   * 用途：播放中若干秒无操作就把控制层自动隐藏。
   *
   * 为什么不用一次性的 setTimeout（并在每个交互回调里重置）：
   *   那种写法要在 togglePlay / seekTo / toggleTrackPanel / 进度条拖动
   *   等每一处都记得重置定时器，漏一处就会出现"刚点完按钮控制栏自己没了"。
   *   本页本来就有一个 100ms 的字幕轮询（subtitleTimer），把"该不该隐藏"
   *   挂在那个 tick 上判断，天然每 100ms 重新判断一次、随时可重置，
   *   也省掉一个需要在 aboutToDisappear 里清理的定时器。
   */
  private controlsActiveAt: number = 0;
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

  /**
   * 页面是否已进入销毁流程
   *
   * 为什么必须有它：本页多处是异步回调（createAVPlayer().then、restoreExternalSubtitle
   * 的 then、各种 setTimeout），而用户完全可能在回调回来之前就点了返回。
   * 那时 aboutToDisappear 已经跑完 releasePlayer()，但**它什么都不找到** ——
   * this.player 还是 undefined，于是直接返回；随后 then 回调把
   * this.player 赋成一个新建的 AVPlayer，就再也没有人去释放它了。
   * 结果：AVPlayer 与它持有的 fd 泄漏，甚至可能在后台继续解码/出声，
   * 反复进出播放页会持续累积。
   *
   * 所以：进销毁流程先置位，所有异步回调开头都先看这个标志。
   */
  private disposed: boolean = false;
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
    // 外挂字幕：同目录同名/同前缀的自动发现（网络流没有目录，跳过）
    if (!this.isNetworkUrl(this.videoPath)) {
      this.sidecarCandidates = findSidecarSubtitles(this.videoPath);
    }
    // 恢复上次选中的外挂字幕。
    // 为什么需要这一步：外挂字幕的选择是"针对这个视频"的长期意图，
    // 而播放页会被反复创建（返回搜索页再进来就是一次新创建）。
    // 不恢复的话用户每进出一次都要重选一遍，体验很差。
    if (isExternalActive() && externalSubtitle.path.length > 0) {
      restoreExternalSubtitle().then((count: number) => {
        // 恢复是异步读盘，回来时页面可能已经销毁 —— 此时写 @State 会告警，
        // 而且写进去也没人看。先判销毁标志直接放弃。
        if (this.disposed) {
          return;
        }
        if (count > 0) {
          this.usingExternalSubtitle = true;
          this.externalSubtitleName = externalSubtitle.name;
          this.subtitleText = externalSubtitle.textAt(this.positionMs);
          this.writeDiag('已恢复外挂字幕: ' + externalSubtitle.name
            + ' 共 ' + count.toString() + ' 条');
        }
      }).catch((err: object) => {
        // 原先没有 catch：读盘失败会产生 unhandled rejection，
        // 而且失败原因彻底看不到。这里至少把它记进诊断日志。
        this.writeDiag('恢复外挂字幕失败: ' + JSON.stringify(err));
      });
    }
    // 字幕刷新定时器。100ms 与事件轮询同频 —— 字幕的时间精度本来
    // 就在几十毫秒量级，再密也没有意义，反而白耗电。
    // 顺带驱动控制层的自动隐藏（同一个 tick，不额外起定时器）。
    this.subtitleTimer = setInterval(() => {
      this.refreshSubtitle();
      this.tickControlsAutoHide();
    }, 100);
  }

  /**
   * 刷新当前该显示的字幕
   *
   * 两条来源的优先级：**外挂优先于内嵌**。
   *
   * 为什么外挂优先：用户主动去选一个外挂字幕，就是明确表示"我要用这个"，
   * 通常是因为内嵌字幕语言不对或者质量差。这时如果还让内嵌字幕盖在上面，
   * 等于无视用户的明确意图。
   */
  private refreshSubtitle(): void {
    const sc: SoftPlayerController | undefined = this.softCtl;
    const extReady: boolean = this.usingExternalSubtitle && externalSubtitle.loaded;
    if (this.showTrackPanel) {
      // 面板打开时不刷新：面板是模态的，字幕跟着动反而干扰阅读
      return;
    }
    if (extReady) {
      const t: string = externalSubtitle.textAt(this.positionMs);
      if (t !== this.subtitleText) {
        this.subtitleText = t;
      }
      return;
    }
    if (sc === undefined) {
      if (this.subtitleText.length > 0) {
        this.subtitleText = '';
      }
      return;
    }
    const t2: string = sc.getActiveSubtitle();
    if (t2 !== this.subtitleText) {
      this.subtitleText = t2;
    }
  }

  aboutToDisappear(): void {
    // ★ 第一件事：置销毁标志。
    //   本页有多个异步回调（createAVPlayer().then、字幕恢复、看门狗、
    //   各种 setTimeout），它们可能在页面已经销毁之后才回来。
    //   置位之后那些回调会自行放弃并释放自己造出来的资源（尤其是 AVPlayer）。
    //   必须放在最前面 —— 放在后面就等于给了回调一个抢先的窗口。
    this.disposed = true;
    this.writeDiag('aboutToDisappear pos=' + this.positionMs.toString()
      + ' dur=' + this.durationMs.toString());
    // 先停字幕定时器：它每 100ms 会调一次原生 getActiveSubtitle，
    // 而下面马上就要释放原生播放器 —— 不停掉就会在释放后继续调用，
    // 轻则报错刷日志，重则碰到已释放的对象
    if (this.subtitleTimer >= 0) {
      clearInterval(this.subtitleTimer);
      this.subtitleTimer = -1;
    }
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
    // ★ 恢复系统栏与窗口布局 —— 这两项也必须在这里还原。
    //
    //   窗口属性属于 **window 而不是页面**，一旦设置就一直是那个状态。
    //   setupWindow 里设了 setWindowLayoutFullScreen(true) 和
    //   setWindowSystemBarEnable([])，但之前**从来没有还原过**，
    //   于是"只要进过一次播放页，返回首页/搜索页后状态栏与导航条就永久消失"，
    //   影响的是整个 App 而不只是播放页。
    //   （DeveloperModePage 的「跳转压测」会把播放页反复开关 40 次，
    //    每次都在施加这个状态，问题更容易被撞到。）
    this.restoreWindowChrome();
  }

  /**
   * 还原系统栏与窗口布局
   *
   * 与 setupWindow 成对使用。恢复失败不影响退出流程，所以只记日志不抛。
   */
  private restoreWindowChrome(): void {
    const w: window.Window | undefined = this.mainWindow;
    if (w === undefined) {
      // 没拿到过窗口对象（setupWindow 失败或还没回来），
      // 说明也没设置过，不需要还原
      return;
    }
    try {
      // ['status','navigation'] = 状态栏 + 导航条都恢复显示
      w.setWindowSystemBarEnable(['status', 'navigation'])
        .catch((err: BusinessError) => {
          console.error('恢复系统栏失败: ' + JSON.stringify(err));
        });
      w.setWindowLayoutFullScreen(false)
        .catch((err: BusinessError) => {
          console.error('恢复窗口布局失败: ' + JSON.stringify(err));
        });
    } catch (err) {
      console.error('restoreWindowChrome failed: ' + JSON.stringify(err));
    }
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
      // ★ 页面可能已经销毁（用户创建完立刻点了返回）。
      //   此时 aboutToDisappear 的 releasePlayer() 什么也没找到
      //   （this.player 还是 undefined），所以这个刚造出来的播放器
      //   必须由我们自己释放，否则 AVPlayer + fd 一起泄漏。
      if (this.disposed) {
        this.writeDiag('页面已销毁，放弃本次创建的 AVPlayer 并释放');
        p.release().catch((err: BusinessError) => {
          console.error('释放迟到的 AVPlayer 失败: ' + JSON.stringify(err));
        });
        this.closeMediaFile();
        return;
      }
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
      // ★ 创建失败时必须把已经打开的 fd 关掉。
      //   原先这里只置 errorMsg/preparing 就返回，而 fd 只在
      //   releasePlayer/closeMediaFile 路径释放 —— 于是每次
      //   "播放器创建失败"都漏一个 fd，重试同一个坏文件会持续累积。
      this.closeMediaFile();
      if (this.disposed) {
        return;   // 页面已销毁就不再改动 UI 状态
      }
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
      // 与本地文件同理：页面已销毁时这个播放器必须自己释放
      if (this.disposed) {
        this.writeDiag('页面已销毁，放弃本次创建的网络 AVPlayer 并释放');
        p.release().catch((err: BusinessError) => {
          console.error('释放迟到的网络 AVPlayer 失败: ' + JSON.stringify(err));
        });
        return;
      }
      this.player = p;
      this.registerCallbacks(p);
      // url 通道：直接交给系统去请求
      p.url = this.videoPath;
    }).catch((err: BusinessError) => {
      if (this.disposed) {
        return;
      }
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

    // ★ 轨道状态跟着快照同步，不要只在打开面板时才刷新。
    //
    //   踩过的坑：底部那两个按钮的文字（"音轨 1/3"、"字幕 2"）是从
    //   audioTracks / subtitleTracks / currentXxxIndex 算出来的，
    //   而这些 @State 原先只在 toggleTrackPanel() 里赋值。
    //   结果是"进了播放页但没打开过面板"时，按钮永远显示"字幕 -"
    //   —— 因为 subtitleTracks 是空数组，findIndex 返回 -1。
    //   把同步放到快照更新里，按钮文字在任何时刻都是准的。
    //
    //   ★ 2026-09-29 自检修正：原注释写的是"每次都同步"，代码却是
    //     `&& this.audioTracks.length === 0` —— 只填一次。注释与实现不符，
    //     下一个人照着注释改就会引入无谓的重绘。这里把真实意图写清楚：
    //       · **下标**每次都同步（它决定按钮文案，必须实时）；
    //       · **列表**只在"当前为空或长度对不上"时才赋值 ——
    //         数组每次重建会让 @State 认为变了，整个列表跟着重绘，
    //         而这个循环是每 100ms 跑一次的，白白耗电。
    //     长度比对保留了"重新探测后轨道数变了"这条路径的正确性，
    //     代价只是一次 length 读取。
    if (snap.audioTracks.length > 0 && this.audioTracks.length !== snap.audioTracks.length) {
      this.audioTracks = snap.audioTracks;
    }
    if (snap.subtitleTracks.length > 0
        && this.subtitleTracks.length !== snap.subtitleTracks.length) {
      this.subtitleTracks = snap.subtitleTracks;
    }
    if (snap.currentAudioIndex !== this.currentAudioIndex) {
      this.currentAudioIndex = snap.currentAudioIndex;
    }
    // 内嵌字幕轨下标变化时同步；外挂生效时不动它（外挂优先，
    // 此时内嵌下标可能是 -1，界面靠 usingExternalSubtitle 区分）
    if (!this.usingExternalSubtitle
        && snap.currentSubtitleIndex !== this.currentSubtitleIndex) {
      this.currentSubtitleIndex = snap.currentSubtitleIndex;
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
        // ★ 2026-10-03：顺手把轨道列表拉一次。
        //   否则底部按钮要等用户点开面板才显示"音轨 1/2"，
        //   而"这个文件有几条音轨"本来就该在进播放页时就知道。
        //   AVPlayer 路径专用；软解路径的轨道来自快照，不需要这一步。
        if (this.softCtl === undefined) {
          this.refreshAvTracks();
        }
        // 有续播起点则先跳转再播（此时已在 prepared 态，可以 seek）
        //
        // ★ 网络流不做续播 seek：
        //   ① 从网络流页进入时本来就没带起点（没有进度记录）；
        //   ② 更要紧的是实时流（RTSP / 直播 HLS）没有总时长，
        //      对它们 seek 行为未定义，贸然调用可能让播放卡住。
        if (!this.isNetworkUrl(this.videoPath)
          && this.startPositionMs > 0 && this.durationMs > 0) {
          // ★ 2026-09-29：seek 的声明返回 void（不是 Promise，拿不到 .catch），
          //   抛错只能是同步的，所以用 try/catch 兜。
          //   之前完全没有任何处理：跳转失败（超出可跳范围、流不支持）
          //   会直接变成一次未捕获异常，表现为"点了没反应"且日志无痕。
          try {
            p.seek(this.startPositionMs, media.SeekMode.SEEK_CLOSEST);
          } catch (err) {
            const e = err as BusinessError;
            this.writeDiag('续播跳转失败: ' + e.code.toString() + ' ' + e.message);
          }
        }
        // play() 返回 Promise，失败会走 rejected，必须 catch
        p.play().catch((err: BusinessError) => {
          this.writeDiag('自动播放失败: ' + err.code.toString() + ' ' + err.message);
        });
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
   * 字幕层相对自身布局位置的下移量（像素）
   *
   * ★ 2026-09-29：这个函数已经**不再被使用** —— 字幕层已改为
   *   放在与画面同尺寸的 Stack 里、用 alignContent(Alignment.Bottom) 贴底，
   *   不需要任何像素偏移（见 build() 里视频层的说明）。
   *   保留在这里是为了把"为什么那条路走不通"写清楚：
   *
   *   360 是在**参考机型**（铺满容器高 2412px）上靠截图对照试出来的，
   *   而真机布局转储复核后发现字幕实际停在 y=603..765（画面是 y=901..1511）——
   *   那组实测值对应的是更早一版布局，改版之后没人复核，于是"看起来正确"。
   *   等比换算（areaHeight × 360 ÷ 2412）也只是把这个错误按比例放大/缩小。
   *   根子在于 offset 是相对自身布局位置的固定位移，而它所在父容器的
   *   文档流起点随布局而变 —— 任何写死的像素值都会漂。
   */
  private subtitleOffsetY(): number {
    const refHeight: number = 2412;
    const refOffset: number = 360;
    const h: number = this.areaHeight > 0 ? this.areaHeight : refHeight;
    const v: number = Math.round(h * refOffset / refHeight);
    // 兜底：异常尺寸下也别推出可视区，夹在一个实测可用的区间内
    if (v < 120) {
      return 120;
    }
    if (v > 900) {
      return 900;
    }
    return v;
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

  // ==================== 控制层显隐（2026-10-03 新增） ====================

  /**
   * 点画面：显示 / 隐藏控制层
   *
   * 挂在全屏控制层的 onClick 上（不挂在 XComponent 上，原因见文件头注释）。
   */
  private toggleControls(): void {
    if (this.showControls) {
      this.showControls = false;
      return;
    }
    this.showControls = true;
    // 唤出来的那一刻重新计时，避免"刚点出来立刻又被自动隐藏"
    this.noteControlsActivity();
  }

  /** 记一次"用户刚操作/唤出过控制层"，把自动隐藏的倒计时推后 */
  private noteControlsActivity(): void {
    this.controlsActiveAt = Date.now();
  }

  /**
   * 自动隐藏判断，由 100ms 的字幕轮询顺带驱动
   *
   * 为什么不隐藏的三种情况：
   *   · 暂停中 —— 那时控制栏是必需品（要靠它继续播放），藏起来等于没法播；
   *   · 正在拖进度条 —— 拖到一半把控制栏藏掉是最恼人的行为；
   *   · 音轨/字幕面板打开 —— 那是模态面板，底下藏不藏没意义，还会让关闭后一脸懵。
   * 后两种情况顺便把计时基准重置成"现在"，这样操作结束后是完整的 5 秒，
   * 而不是"松手立刻隐藏"。
   */
  private tickControlsAutoHide(): void {
    if (!this.playing) {
      this.controlsActiveAt = Date.now();
      return;
    }
    if (!this.showControls) {
      return;
    }
    if (this.dragging || this.showTrackPanel) {
      this.controlsActiveAt = Date.now();
      return;
    }
    // 首次进入（或刚恢复播放）还没有基准：先打一个，下一轮才开始计时
    if (this.controlsActiveAt <= 0) {
      this.controlsActiveAt = Date.now();
      return;
    }
    if (Date.now() - this.controlsActiveAt >= CONTROLS_AUTO_HIDE_MS) {
      this.showControls = false;
    }
  }

  /** 播放 / 暂停 */
  private togglePlay(): void {
    // 用户刚点过播放/暂停，控制层再留一会儿（不然会出现"刚点完就消失"）
    this.noteControlsActivity();
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
    // 跳转之后控制层再多留一会儿，方便连续调
    this.noteControlsActivity();
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

  // ==================== 音轨 / 字幕操作（2026-09-29 新增） ====================

  /**
   * 打开/关闭音轨字幕面板
   *
   * 打开时从控制器快照刷新一次轨道列表 —— 而不是用 @State 一直同步：
   * 轨道列表在播放期间不会变，只在 Prepare 之后才有值，
   * 需要时读一次最省事（也避免快照每次更新都触发列表重绘）。
   */
  private toggleTrackPanel(): void {
    if (this.showTrackPanel) {
      this.showTrackPanel = false;
      return;
    }
    const sc: SoftPlayerController | undefined = this.softCtl;
    if (sc !== undefined) {
      const snap: SoftPlayerSnapshot = sc.getSnapshot();
      this.audioTracks = snap.audioTracks;
      this.subtitleTracks = snap.subtitleTracks;
      this.currentAudioIndex = snap.currentAudioIndex;
      this.currentSubtitleIndex = snap.currentSubtitleIndex;
    } else if (this.player !== undefined) {
      // ★ 2026-10-03：系统 AVPlayer 那条路也要列音轨。
      //   以前这里只处理软解，于是走 AVPlayer 的文件面板永远显示
      //   「当前文件没有可切换的音轨」—— 而 .mkv 属于 TIER_PLAYABLE，
      //   也就是**必然走 AVPlayer**，于是"双音轨 mkv"这个最典型的场景
      //   反而完全用不了音轨切换（真机反馈就是这个现象）。
      //   这里是异步填充：面板立刻打开，列表拉到之后由 @State 驱动重绘。
      this.refreshAvTracks();
    }
    this.trackNotice = '';
    this.showTrackPanel = true;
    // 打开面板时把控制层的倒计时推后：关掉面板后控制栏还在，用户不用再点一次
    this.noteControlsActivity();
  }

  /** 切换音轨 */
  private chooseAudioTrack(index: number): void {
    const sc: SoftPlayerController | undefined = this.softCtl;
    if (sc === undefined) {
      // 走系统 AVPlayer 的文件：改用 AVPlayer 自己的轨道接口
      if (this.player !== undefined) {
        this.switchAvAudioTrack(index);
        return;
      }
      this.trackNotice = '当前不是软解播放，无法切换音轨';
      return;
    }
    if (index === this.currentAudioIndex) {
      return;
    }
    this.trackNotice = '正在切换音轨…';
    const r: number = sc.switchAudioTrack(index);
    if (r === 0) {
      this.currentAudioIndex = sc.getSnapshot().currentAudioIndex;
      this.trackNotice = '';
      this.writeDiag('切换音轨到 ' + index.toString() + ' 成功');
    } else {
      this.trackNotice = '切换音轨失败（错误码 ' + r.toString() + '）';
      this.writeDiag('切换音轨到 ' + index.toString() + ' 失败: ' + r.toString());
    }
  }

  // ========================================================================
  // 系统 AVPlayer 路径的音轨适配（2026-10-03 新增）
  // ========================================================================
  //
  // 为什么需要这一块：
  //   音轨切换原先只做在软解路径上，而 .mkv 属于 MediaType.TIER_PLAYABLE，
  //   也就是**必然走 AVPlayer** —— 结果"双音轨 mkv"这个最典型的场景反而
  //   完全用不了音轨切换（面板固定显示"当前文件没有可切换的音轨"）。
  //   真机实测反馈的正是这个现象。
  //
  // 做法：AVPlayer 自带一套轨道接口（API 12 起就都有），把它们适配成软解那套
  //   SoftAudioTrack。这样面板 UI、底部按钮文案（"音轨 1/2"）、单选圆点
  //   **一行都不用改**就能用上 —— 它们本来就只认这个数据结构。
  //
  // ★ 两个版本坑，写在这里免得以后踩：
  //   ① 不要用 getSelectedTrack(MediaType)（单数）：它标注 @since 26.0.0，
  //      而本机系统是 6.1.0，调它会直接失败。用 getSelectedTracks()（复数），
  //      API 12 就有 —— 它返回全部选中下标，从中挑出属于音轨的那个即可。
  //   ② 不要靠 on('trackChange') 同步状态：事件在各版本上的可用性不一致，
  //      而"切换完自己重新拉一次"是确定能用的，代码也更好懂。

  /**
   * 拉一次 AVPlayer 的轨道列表并同步到界面状态
   *
   * 全程不抛异常：拉不到轨道只是"看不到列表"，不该影响播放。
   */
  private refreshAvTracks(): void {
    const p: media.AVPlayer | undefined = this.player;
    if (p === undefined) {
      return;
    }
    p.getTrackDescription().then((list: media.MediaDescription[]) => {
      if (this.disposed) {
        return;
      }
      // ★ 同时也打一份到 console（= hilog）。
      //   DiagLog 故意只写沙箱文件（见其文件头说明），而"沙箱文件读不出来"
      //   恰恰是排查轨道问题时最难受的地方。这两行让 hdc 直接能看到原始数据：
      //   轨道条数、每条的 track_type / track_index / codec_mime。
      //   只在 prepared 和打开面板时打，频率极低，不会刷屏。
      console.info('[Track] getTrackDescription -> ' + list.length.toString() + ' 条');
      const dump: string[] = [];
      for (let i = 0; i < list.length; i++) {
        try {
          const d: media.MediaDescription = list[i];
          const rawType: Object = d[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE];
          dump.push('#' + i.toString()
            + ' type=' + this.avStr(rawType) + this.avNum(rawType, -99).toString()
            + ' idx=' + this.avNum(d[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX], -99).toString()
            + ' mime=' + this.avStr(d[media.MediaDescriptionKey.MD_KEY_CODEC_MIME]));
        } catch (err) {
          dump.push('#' + i.toString() + ' <读取失败>');
        }
      }
      if (dump.length > 0) {
        console.info('[Track] 明细: ' + dump.join(' | '));
      }
      this.applyAvTrackDescriptions(list);
      // 再问一次"当前选中的是哪些"。单独一次调用：它失败不该把列表也一起废掉
      p.getSelectedTracks().then((sel: number[]) => {
        if (this.disposed) {
          return;
        }
        console.info('[Track] getSelectedTracks -> [' + sel.join(',') + ']');
        this.applyAvSelectedTracks(sel);
      }).catch((err: BusinessError) => {
        console.warn('[Track] getSelectedTracks 失败: ' + err.code.toString());
        this.writeDiag('getSelectedTracks 失败: ' + err.code.toString());
      });
    }).catch((err: BusinessError) => {
      console.warn('[Track] getTrackDescription 失败: ' + err.code.toString()
        + ' ' + err.message);
      this.writeDiag('getTrackDescription 失败: ' + err.code.toString());
    });
  }

  /**
   * 把 AVPlayer 的 MediaDescription[] 转成面板用的音轨列表
   *
   * 只取 track_type 为音频的那些；视频/字幕轨在这里不处理
   * （字幕走的是应用自己的字幕层，见 refreshSubtitle 的说明）。
   */
  private applyAvTrackDescriptions(list: media.MediaDescription[]): void {
    const out: SoftAudioTrack[] = [];
    for (let i = 0; i < list.length; i++) {
      const d: media.MediaDescription = list[i];
      // MediaDescription 是 [key: string]: Object 的运行时映射，
      // 字段可能整个缺失，取值本身也可能抛（ArkTS 会对下标访问给出
      // "Function may throw exceptions" 警告）。所以整条轨的读取包一层：
      // 拿不到就跳过这一条，绝不能让一条坏数据把播放带崩。
      try {
        const t: Object = d[media.MediaDescriptionKey.MD_KEY_TRACK_TYPE];
        if (t !== media.MediaType.MEDIA_TYPE_AUD) {
          continue;
        }
        const idx: number = this.avNum(d[media.MediaDescriptionKey.MD_KEY_TRACK_INDEX], -1);
        if (idx < 0) {
          continue;
        }
        const mime: string = this.avStr(d[media.MediaDescriptionKey.MD_KEY_CODEC_MIME]);
        // "audio/mp4a-latm" 这种 MIME 前缀对用户没意义，只留斜杠后面的编码名
        const slash: number = mime.indexOf('/');
        out.push({
          index: idx,
          codec: slash >= 0 ? mime.substring(slash + 1) : mime,
          language: this.avStr(d[media.MediaDescriptionKey.MD_KEY_LANGUAGE]),
          title: this.avStr(d[media.MediaDescriptionKey.MD_KEY_TRACK_NAME]),
          channels: this.avNum(d[media.MediaDescriptionKey.MD_KEY_AUD_CHANNEL_COUNT], 0),
          sampleRate: this.avNum(d[media.MediaDescriptionKey.MD_KEY_AUD_SAMPLE_RATE], 0),
          bitRate: this.avNum(d[media.MediaDescriptionKey.MD_KEY_BITRATE], 0),
          // AVPlayer 不提供"容器标记的默认轨"这一信息，一律 false ——
          // 当前生效的是哪条由单选圆点表示，不影响使用
          isDefault: false
        });
      } catch (err) {
        const e = err as BusinessError;
        this.writeDiag('解析第 ' + i.toString() + ' 条轨道描述失败: ' + e.message);
        continue;
      }
    }
    this.audioTracks = out;
    this.currentSubtitleIndex = -1;
    console.info('[Track] 过滤后音轨 ' + out.length.toString() + ' 条');
    this.writeDiag('AVPlayer 音轨 ' + out.length.toString() + ' 条');
  }

  /** 用 AVPlayer 的选中轨下标校准"当前音轨"（选中项里挑出属于音轨的那个） */
  private applyAvSelectedTracks(sel: number[]): void {
    for (let i = 0; i < sel.length; i++) {
      const idx: number = sel[i];
      for (let j = 0; j < this.audioTracks.length; j++) {
        if (this.audioTracks[j].index === idx) {
          this.currentAudioIndex = idx;
          return;
        }
      }
    }
  }

  /** MediaDescription 是个 key:value 映射，取值时按类型兜一下底 */
  private avNum(v: Object, fallback: number): number {
    return typeof v === 'number' ? v as number : fallback;
  }

  /** 同上，取字符串 */
  private avStr(v: Object): string {
    return typeof v === 'string' ? v as string : '';
  }

  /**
   * 切换 AVPlayer 的音轨
   *
   * 顺序：**先选中新的，再放掉旧的**。
   *   音频轨同一时刻只能选中一条，所以必须先 select 新的再 deselect 旧的；
   *   反过来的话中间会出现"一条都没选中"的瞬间，声音会断一下。
   */
  private switchAvAudioTrack(index: number): void {
    const p: media.AVPlayer | undefined = this.player;
    if (p === undefined) {
      this.trackNotice = '播放器未就绪，无法切换音轨';
      return;
    }
    if (index === this.currentAudioIndex) {
      return;
    }
    const old: number = this.currentAudioIndex;
    console.info('[Track] 请求切换音轨: ' + old.toString() + ' -> ' + index.toString());
    this.trackNotice = '正在切换音轨…';
    p.selectTrack(index).then(() => {
      if (this.disposed) {
        return;
      }
      this.currentAudioIndex = index;
      this.trackNotice = '';
      this.writeDiag('AVPlayer 切换音轨到 ' + index.toString() + ' 成功');
      if (old >= 0 && old !== index) {
        // ★ 无条件放掉旧轨 —— 这是**实测验证过的**写法，别再"优化"它。
        //
        //   我一度把它加了个条件（先 getSelectedTracks() 看旧轨是否还挂着，
        //   还挂着才 deselect），理由是系统日志里出现过
        //   「SelectTrack trackId invalid / failed to DeselectTrack」，看着像多余调用。
        //   **结果真机上直接把切换搞坏了**：面板停在原轨不动（音轨1 ● / 音轨2 ○）。
        //   根因是 getSelectedTracks() 在 selectTrack 刚返回时读到的还是旧值
        //   （[0,1]，不含新选的 2），条件判断随之误判，于是多放了一次旧轨，
        //   系统把选择退回了原轨。
        //
        //   代价对比很清楚：
        //     · 无条件 deselect：切换成功且稳定；副作用只是系统侧一行
        //       「failed to DeselectTrack」的噪声日志（库内部的重复 unselect，
        //       系统在 select 时本来就自动 unselect 过一次）。
        //     · 加条件：日志干净了，功能没了。
        //   所以这里保持无条件。真要消噪声，得等系统侧把"选中状态"的可见性
        //   修好（或提供同步接口），不能靠我们这一侧猜。
        p.deselectTrack(old).catch((err: BusinessError) => {
          // 放旧轨失败不影响新轨已经生效，记一笔就够
          this.writeDiag('deselectTrack(' + old.toString() + ') 失败: ' + err.code.toString());
        });
      }
      // 用系统实际状态再校准一次
      this.refreshAvTracks();
    }).catch((err: BusinessError) => {
      this.trackNotice = '切换音轨失败（' + err.code.toString() + '）';
      this.writeDiag('AVPlayer 切换音轨到 ' + index.toString()
        + ' 失败: ' + err.code.toString() + ' ' + err.message);
    });
  }

  /**
   * 选择内嵌字幕轨
   * @param index 流下标；-1 表示关闭内嵌字幕
   */
  private chooseEmbeddedSubtitle(index: number): void {
    const sc: SoftPlayerController | undefined = this.softCtl;
    if (sc === undefined) {
      this.trackNotice = '当前不是软解播放，无法启用内嵌字幕';
      return;
    }
    if (index === this.currentSubtitleIndex && !this.usingExternalSubtitle) {
      return;
    }
    this.trackNotice = index < 0 ? '正在关闭字幕…' : '正在启用内嵌字幕…';
    const r: number = sc.setSubtitleTrack(index);
    if (r === 0) {
      this.currentSubtitleIndex = sc.getSnapshot().currentSubtitleIndex;
      // 选内嵌字幕就自动关掉外挂 —— 两条来源互斥，
      // 否则会出现两行字幕叠在一起
      this.usingExternalSubtitle = false;
      setExternalActive(false);
      externalSubtitle.clear();
      this.externalSubtitleName = '';
      this.subtitleText = '';
      this.trackNotice = '';
      this.writeDiag('内嵌字幕轨设为 ' + index.toString());
    } else {
      this.trackNotice = '启用内嵌字幕失败（错误码 ' + r.toString() + '）';
    }
  }

  /** 用同目录发现的候选外挂字幕 */
  private async useSidecarSubtitle(cand: SubtitleCandidate): Promise<void> {
    this.trackNotice = '正在加载 ' + cand.name + ' …';
    const res = await loadSubtitleFile(cand.path);
    if (res.error.length > 0) {
      this.trackNotice = '加载失败：' + res.error;
      return;
    }
    await this.enableExternalSubtitle(cand.name);
    this.trackNotice = '';
    this.writeDiag('外挂字幕已加载: ' + cand.name + ' 共 '
      + res.count.toString() + ' 条');
  }

  /**
   * 外挂字幕生效后的共同收尾
   *
   * 为什么要关掉内嵌字幕：两者会同时显示，叠字几乎不可读。
   * 用户主动选了外挂，就说明要以它为准。
   */
  private async enableExternalSubtitle(name: string): Promise<void> {
    this.usingExternalSubtitle = true;
    // 模块级状态也要同步：播放页重建时要靠它决定"是否恢复上次的外挂字幕"
    setExternalActive(true);
    this.externalSubtitleName = name;
    // 关掉内嵌字幕（如果开着）。传 -1 只停消费端、不重开会话，
    // 所以不会有播放中断。
    const sc: SoftPlayerController | undefined = this.softCtl;
    if (sc !== undefined && this.currentSubtitleIndex >= 0) {
      sc.setSubtitleTrack(-1);
      this.currentSubtitleIndex = -1;
    }
    this.subtitleText = externalSubtitle.textAt(this.positionMs);
  }

  /** 关闭外挂字幕 */
  private disableExternalSubtitle(): void {
    this.usingExternalSubtitle = false;
    setExternalActive(false);
    externalSubtitle.clear();
    this.externalSubtitleName = '';
    this.subtitleText = '';
    this.writeDiag('外挂字幕已关闭');
  }

  /** 用系统文件选择器挑一个外挂字幕 */
  private async pickExternalSubtitle(): Promise<void> {
    let destDir: string = '';
    try {
      const ctx = this.getUIContext().getHostContext() as commonKit.UIAbilityContext;
      destDir = ctx.filesDir + '/subtitles';
      if (!fileIo.accessSync(destDir)) {
        fileIo.mkdirSync(destDir);
      }
      this.trackNotice = '请选择字幕文件…';
      const res = await pickSubtitleFile(ctx, destDir);
      if (res.error.length > 0) {
        this.trackNotice = res.error;
        return;
      }
      await this.enableExternalSubtitle(externalSubtitle.name);
      this.trackNotice = '';
      this.writeDiag('外挂字幕已导入: ' + externalSubtitle.name + ' 共 '
        + res.count.toString() + ' 条');
    } catch (err) {
      const e = err as BusinessError;
      this.trackNotice = '选择字幕失败：' + (e.message !== undefined ? e.message : '未知错误');
    }
  }

  // ---- 面板上用的文案 ----

  /** 底部"音轨"按钮的文字 */
  private audioTracksLabel(): string {
    if (this.audioTracks.length <= 1) {
      return '音轨';
    }
    const n: number = this.audioTracks.findIndex((t: SoftAudioTrack) =>
      t.index === this.currentAudioIndex);
    return '音轨 ' + (n >= 0 ? (n + 1).toString() : '-') + '/'
      + this.audioTracks.length.toString();
  }

  /** 底部"字幕"按钮的文字 */
  private subtitleLabel(): string {
    if (this.usingExternalSubtitle) {
      return '字幕·外挂';
    }
    if (this.currentSubtitleIndex >= 0) {
      const n: number = this.subtitleTracks.findIndex((t: SoftSubtitleTrack) =>
        t.index === this.currentSubtitleIndex);
      return '字幕 ' + (n >= 0 ? (n + 1).toString() : '-');
    }
    return '字幕';
  }

  /**
   * 一条音轨在面板上显示的文字
   *
   * 音轨的"编号"要用列表序号而不是流下标 —— 流下标是容器内部编号，
   * 可能是 1、3、7 这种跳号，直接显示会让人以为少了几条。
   */
  private audioTrackLabel(t: SoftAudioTrack, i: number): string {
    const parts: string[] = [];
    parts.push('音轨 ' + (i + 1).toString());
    if (t.title.length > 0) {
      parts.push(t.title);
    }
    if (t.language.length > 0) {
      parts.push(translateLanguage(t.language));
    }
    if (t.channels > 0) {
      parts.push(channelLabel(t.channels));
    }
    parts.push(t.codec.toUpperCase());
    if (t.bitRate > 0) {
      parts.push(Math.round(t.bitRate / 1000).toString() + ' kbps');
    }
    if (t.isDefault) {
      parts.push('默认');
    }
    return parts.join(' · ');
  }

  /** 一条字幕轨在面板上显示的文字 */
  private subtitleTrackLabel(t: SoftSubtitleTrack, i: number): string {
    const parts: string[] = [];
    parts.push('字幕 ' + (i + 1).toString());
    if (t.title.length > 0) {
      parts.push(t.title);
    }
    if (t.language.length > 0) {
      parts.push(translateLanguage(t.language));
    }
    parts.push(t.codec.toUpperCase());
    if (t.isDefault) {
      parts.push('默认');
    }
    if (!t.supported) {
      parts.push('图形字幕，暂不支持');
    }
    return parts.join(' · ');
  }

  /**
   * 音轨 / 字幕选择面板
   *
   * 设计取舍：
   *   · 用底部弹出面板而不是新页面 —— 换音轨/换字幕都是"边看边调"的动作，
   *     跳走一页再回来会打断观看，而且新页面还得重新绑定 surface。
   *   · 面板里轨道用 List 而不是 Column：一部片子可能有十几条字幕轨
   *     （多语言 + 评论轨），Column 会把面板撑出屏幕。
   */
  @Builder
  TrackPanel() {
    Column({ space: 0 }) {
      // ---- 标题栏 ----
      Row() {
        Text('音轨与字幕')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
        Text('✕')
          .fontSize(18)
          .fontColor('rgba(255,255,255,0.70)')
          .padding(8)
          .onClick(() => {
            this.showTrackPanel = false;
          })
      }
      .width('100%')
      .padding({ left: 20, right: 12, top: 14, bottom: 10 })

      // ---- 操作提示 ----
      if (this.trackNotice.length > 0) {
        Text(this.trackNotice)
          .fontSize(12)
          .fontColor(Theme.ACCENT)
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 8 })
      }

      List({ space: 0 }) {
        // ============ 音轨 ============
        ListItem() {
          Text('音轨')
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.50)')
            .width('100%')
            .padding({ left: 20, top: 6, bottom: 6 })
        }

        if (this.audioTracks.length === 0) {
          ListItem() {
            Text('当前文件没有可切换的音轨')
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.45)')
              .width('100%')
              .padding({ left: 20, top: 10, bottom: 10 })
          }
        }
        ForEach(this.audioTracks, (t: SoftAudioTrack, i: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text(this.currentAudioIndex === t.index ? '●' : '○')
                .fontSize(14)
                .fontColor(this.currentAudioIndex === t.index
                  ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
              Text(this.audioTrackLabel(t, i))
                .fontSize(13)
                .fontColor(Color.White)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 12, bottom: 12 })
            .onClick(() => {
              this.chooseAudioTrack(t.index);
            })
          }
        }, (t: SoftAudioTrack) => 'a' + t.index.toString())

        // ============ 字幕 ============
        ListItem() {
          Text('字幕')
            .fontSize(12)
            .fontColor('rgba(255,255,255,0.50)')
            .width('100%')
            .padding({ left: 20, top: 14, bottom: 6 })
        }

        // 「关闭字幕」永远在第一项：用户想关字幕时不该还要先找
        ListItem() {
          Row({ space: 10 }) {
            Text((this.currentSubtitleIndex < 0 && !this.usingExternalSubtitle)
              ? '●' : '○')
              .fontSize(14)
              .fontColor((this.currentSubtitleIndex < 0 && !this.usingExternalSubtitle)
                ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
            Text('关闭字幕')
              .fontSize(13)
              .fontColor(Color.White)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 12, bottom: 12 })
          .onClick(() => {
            // 两条来源都要关：只关一个的话另一个会继续显示，
            // 用户点了"关闭字幕"却还有字，会以为功能坏了
            this.chooseEmbeddedSubtitle(-1);
            this.disableExternalSubtitle();
          })
        }

        // 内嵌字幕轨
        ForEach(this.subtitleTracks, (t: SoftSubtitleTrack, i: number) => {
          ListItem() {
            Row({ space: 10 }) {
              Text((this.currentSubtitleIndex === t.index && !this.usingExternalSubtitle)
                ? '●' : '○')
                .fontSize(14)
                .fontColor((this.currentSubtitleIndex === t.index
                  && !this.usingExternalSubtitle)
                  ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
              Text('内嵌 · ' + this.subtitleTrackLabel(t, i))
                .fontSize(13)
                .fontColor(t.supported ? Color.White : 'rgba(255,255,255,0.42)')
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 12, bottom: 12 })
            .onClick(() => {
              if (!t.supported) {
                // 明确告知而不是静默忽略：用户点了没反应最让人困惑
                this.trackNotice = '该轨道是图形字幕（PGS/VobSub），本播放器只支持文本字幕';
                return;
              }
              this.chooseEmbeddedSubtitle(t.index);
            })
          }
        }, (t: SoftSubtitleTrack) => 's' + t.index.toString())

        // 同目录发现的外挂字幕
        ForEach(this.sidecarCandidates, (c: SubtitleCandidate) => {
          ListItem() {
            Row({ space: 10 }) {
              Text((this.usingExternalSubtitle && this.externalSubtitleName === c.name)
                ? '●' : '○')
                .fontSize(14)
                .fontColor((this.usingExternalSubtitle
                  && this.externalSubtitleName === c.name)
                  ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
              Text('外挂 · ' + c.name)
                .fontSize(13)
                .fontColor(Color.White)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: 20, right: 20, top: 12, bottom: 12 })
            .onClick(() => {
              this.useSidecarSubtitle(c);
            })
          }
        }, (c: SubtitleCandidate) => 'x' + c.path)

        // 手动选外挂字幕文件
        ListItem() {
          Text('＋ 从文件选择外挂字幕…')
            .fontSize(13)
            .fontColor(Theme.ACCENT)
            .width('100%')
            .padding({ left: 20, right: 20, top: 14, bottom: 14 })
            .onClick(() => {
              this.pickExternalSubtitle();
            })
        }

        // 关闭外挂字幕（仅在启用时出现）
        if (this.usingExternalSubtitle) {
          ListItem() {
            Text('关闭外挂字幕')
              .fontSize(13)
              .fontColor('rgba(255,255,255,0.70)')
              .width('100%')
              .padding({ left: 20, right: 20, top: 12, bottom: 20 })
              .onClick(() => {
                this.disableExternalSubtitle();
              })
          }
        }
      }
      .width('100%')
      // 高度给上限：轨道多的时候内部滚动，少的时候也不会留一大片空白
      .constraintSize({ maxHeight: 420 })
    }
    .width('100%')
    .backgroundColor('#F21A1A1E')
    .borderRadius({ topLeft: 18, topRight: 18 })
    .padding({ bottom: 12 })
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
      //
      // ★★ 2026-09-29 自检修正：字幕层从"铺满整屏的控制层"里搬到这里 ★★
      //
      //   这个 Stack 的尺寸**就是视频画面矩形**（1084x610，居中），
      //   于是字幕只要 alignContent 到底部，就天然落在"画面下沿"，
      //   不需要任何像素偏移量 —— 这是本次修正的核心。
      //
      //   为什么要推翻之前那套 .offset() 方案：
      //     之前的做法是把字幕放在铺满整屏的控制 Column 里，再用实测出来的
      //     像素值 offset 往下推。真机实测（1084x2412，布局转储）显示：
      //       字幕层不偏移时文本在 y=243..405，offset=360 后落在 y=603..765 ——
      //       而视频画面是 y=901..1511。也就是说字幕**停在画面上方那片黑边里**，
      //       根本没到画面下沿；当视频铺满全屏（没有黑边）时，
      //       这个位置就变成了"压在画面中上部"。
      //       换句话说，那套"360 已实测正确"的结论在本版布局下并不成立
      //       （它记录的是更早一版布局的测量值，布局改过之后没人复核）。
      //
      //   为什么这样就不会再错：
      //     offset 是相对自身布局位置的固定位移，画面高度一变（横屏、换视频比例）
      //     它就不对了；而"字幕的父容器 = 视频矩形"这个关系是结构性的，
      //     与分辨率、DPI、横竖屏、视频比例全部无关。
      if (this.computeVideoWidth() > 0) {
        Stack({ alignContent: Alignment.Bottom }) {
          XComponent({
            type: XComponentType.SURFACE,
            controller: this.surfaceController
          })
            .width(this.computeVideoWidth())
            .height(this.computeVideoHeight())
            .onLoad(() => {
              this.onSurfaceCreated();
            })
            .onClick(() => {
              // ⚠️ 这个回调在真机上**不会被触发**：XComponent(SURFACE) 的
              //    surface 由原生渲染，触摸事件不回到 ArkUI 的点击回调
              //    （实测点了没反应，正是"控制栏藏不掉"的原因）。
              //    真正生效的切换挂在下面控制层 Column 的 onClick 上。
              //    这里保留是为了：万一后续换成 Texture 类型或平台行为变化，
              //    这条路径也仍然是"点画面切换"的语义。
              this.toggleControls();
            })

          // ===== 字幕层（贴画面下沿） =====
          //
          // 历史坑（保留记录，说明为什么不再用那些写法）：
          //   ① Column + Blank().layoutWeight(4) + .height('100%')
          //      → 弹性把整个 100% 高度吃光，后面的控制栏被挤成 0 高度
          //        （布局转储里控制栏那两个子节点高度为 0，看着像状态问题）
          //   ② .position({ y: '100%' }) → 100% 正好等于父高，元素起点落在
          //      父容器之外，节点干脆不出现（不报错也不显示）
          //   ③ 在铺满整屏的父容器里用 .offset() → 只能靠实测像素值硬凑
          //
          //   现在的写法没有任何魔法数字：父容器就是画面矩形，
          //   alignContent(Bottom) 就是"贴底"，余量用 margin 给。
          if (this.subtitleText.length > 0) {
            Text(this.subtitleText)
              .fontSize(18)
              .fontColor(Color.White)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              // 半透明底衬：白色字幕压在亮画面上会看不清，
              // 而描边在 ArkUI 里要配多个 Text 叠放，代价大于收益
              .backgroundColor('rgba(0,0,0,0.45)')
              .borderRadius(6)
              .width('92%')
              // 离画面底边留一点距离，避免紧贴边缘
              .margin({ bottom: 18 })
              // 字幕不吃点击：否则会挡住"点屏幕唤出控制栏"
              .hitTestBehavior(HitTestMode.Transparent)
          }
        }
        .width(this.computeVideoWidth())
        .height(this.computeVideoHeight())
        // position 以父容器左上角为原点，算出居中偏移
        .position({ x: this.computeVideoX(), y: this.computeVideoY() })
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

        // ===== 2.2 字幕层 =====
        //
        // ★ 2026-09-29：字幕层已搬到上面的「视频层 Stack」里（与画面同尺寸、
        //   alignContent(Bottom)），这里不再重复渲染。
        //
        //   为什么必须搬走（而不是继续在这里调 offset）：
        //     本层所在的父容器是"铺满整屏的控制 Column"，它的文档流从屏幕顶部
        //     开始排，所以字幕天然停在画面上方那片黑边里。之前靠实测像素值
        //     offset 往下推，但那组实测值对应的是更早一版布局 ——
        //     真机布局转储核对后发现字幕实际停在 y=603..765，
        //     而画面是 y=901..1511，两者根本没对上。
        //     结构性地把字幕放进画面矩形里，才是唯一不会随布局漂移的做法。
        //   （历史踩坑记录见上面视频层里的注释，保留以免有人再试那几条路。）

        // ===== 2.3 弹性空隙：吃掉全部剩余高度，把底栏推到底部 =====
        Blank()

        // ===== 2.4 底部控制栏（贴底） =====
        //
        // ★★ 2026-10-03：全屏（横屏）改成单行结构，对齐主流播放器的样子 ★★
        //
        //   横屏下屏幕是"宽而矮"，原来那套三行堆叠（进度条行 + 按钮行 +
        //   音轨/字幕行）会把画面下方切掉一大块，而横向明明有大量富余宽度。
        //   现在横屏改为：
        //       第一行：进度条（整行只有滑块，时间挪到第二行去，滑块更长）
        //       第二行：⏪ ⏸ ⏩  12:34 / 1:30:27 ……… 音轨 1/2  字幕  ⛶
        //   也就是「左边一排播放控制 + 时间，右边一排工具项」，与参考图一致。
        //   竖屏保持原来的三行结构不动 —— 竖屏本来就没有横向空间可借。
        if (this.showControls) {
          Column({ space: 10 }) {
            // ---- 2.4.1 进度条行 ----
            if (this.isLandscape) {
              // 横屏：占满整行，不放两侧时间（时间已移到下面的控制行）
              Slider({
                value: this.positionMs,
                min: 0,
                max: this.durationMs > 0 ? this.durationMs : 1,
                style: SliderStyle.OutSet
              })
                .width('100%')
                .height(28)
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
            } else {
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
            }

            // ---- 2.4.2 控制行 ----
            if (this.isLandscape) {
              // 横屏单行：左「播放控制 + 时间」，右「工具项」
              Row() {
                Text('⏪')
                  .fontSize(22)
                  .fontColor(Color.White)
                  .padding({ left: 4, right: 10 })
                  .onClick(() => {
                    this.seekBackward();
                  })

                Text(this.playing ? '⏸' : '▶')
                  .fontSize(30)
                  .fontColor(Color.White)
                  .padding({ left: 4, right: 10 })
                  .onClick(() => {
                    this.togglePlay();
                  })

                Text('⏩')
                  .fontSize(22)
                  .fontColor(Color.White)
                  .padding({ left: 4, right: 14 })
                  .onClick(() => {
                    this.seekForward();
                  })

                // 时间：与参考图一致，写成「当前 / 总长」贴在播放键右侧
                Text(formatTime(this.positionMs) + ' / ' + formatTime(this.durationMs))
                  .fontSize(13)
                  .fontColor('rgba(255,255,255,0.85)')

                // Blank() 吃掉中间的全部宽度，把工具组顶到最右边
                Blank()

                // 工具组：只用真正有实现的能力，不放点了没反应的按钮
                //   （倍速需要软解引擎的变速能力、音量需要音频音量 API、
                //     投屏/画中画需要平台侧集成 —— 这些目前都没有，故不摆）
                Text(this.audioTracksLabel())
                  .fontSize(13)
                  .fontColor(this.audioTracks.length > 1 ? Color.White : 'rgba(255,255,255,0.40)')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .backgroundColor('rgba(255,255,255,0.14)')
                  .margin({ right: 10 })
                  .onClick(() => {
                    this.toggleTrackPanel();
                  })

                Text(this.subtitleLabel())
                  .fontSize(13)
                  .fontColor(Color.White)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .backgroundColor('rgba(255,255,255,0.14)')
                  .margin({ right: 10 })
                  .onClick(() => {
                    this.toggleTrackPanel();
                  })

                // 全屏 / 退出全屏（与参考图同样放在右下角）
                Text(this.isLandscape ? '⛶' : '⤢')
                  .fontSize(20)
                  .fontColor(Color.White)
                  .padding({ left: 10, right: 4 })
                  .onClick(() => {
                    this.toggleOrientation();
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            } else {
              // 竖屏维持原样：按钮居中一行、音轨/字幕居中一行
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

              // ---- 音轨 / 字幕入口 ----
              //
              // 为什么单独占一行而不是塞进上面的按钮行：
              //   播放按钮那一行已经占了 24+34+24 的字号和 32 的间距，
              //   再塞进去会在窄屏（竖屏 360vp）上挤成一团。
              //   而且这两个是"低频但重要"的操作，独立一行更好点中。
              Row({ space: 28 }) {
                Text(this.audioTracksLabel())
                  .fontSize(13)
                  .fontColor(this.audioTracks.length > 1 ? Color.White : 'rgba(255,255,255,0.40)')
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .borderRadius(14)
                  .backgroundColor('rgba(255,255,255,0.14)')
                  .onClick(() => {
                    this.toggleTrackPanel();
                  })

                Text(this.subtitleLabel())
                  .fontSize(13)
                  .fontColor(Color.White)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .borderRadius(14)
                  .backgroundColor('rgba(255,255,255,0.14)')
                  .onClick(() => {
                    this.toggleTrackPanel();
                  })
              }
              .justifyContent(FlexAlign.Center)
              .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          // 横屏控制栏只有两行，上下留白比竖屏收紧，避免压住画面
          .padding(this.isLandscape
            ? { left: 24, right: 24, top: 10, bottom: 12 }
            : { left: 20, right: 20, top: 20, bottom: 28 })
          .linearGradient({
            angle: 0,
            colors: [['rgba(0,0,0,0.80)', 0.0], ['rgba(0,0,0,0.00)', 1.0]]
          })
        }
      }
      .width('100%')
      .height('100%')
      // ★★ 2026-10-03：控制层的显隐切换挂在这里 ★★
      //
      //   为什么挂在这个铺满全屏的 Column 上，而不是 XComponent 上：
      //     ① XComponent(SURFACE) 的 onClick 真机上根本不派发（实测点了没反应）；
      //     ② 这个 Column 铺满整屏且位于视频层之上，空白处的触摸本来就被它
      //        吃掉 —— 不挂处理函数时那些点击就是"点哪都没反应"；
      //     ③ 它始终存在（下面两个 if 只包住顶栏/底栏），所以控制层藏起来之后
      //        仍然有满屏的点击目标把它唤回来 —— 这是能"藏了还能点回来"的关键；
      //     ④ ArkUI 里子组件优先响应点击，所以进度条 / 播放按钮 / 返回键
      //        不会被这个父级 onClick 抢走（实机已验：拖进度条与各按钮均正常）。
      .onClick(() => {
        this.toggleControls();
      })

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

      // ---------- 5. 音轨 / 字幕面板（最上层） ----------
      //
      // 放在最后：Stack 里"后写的在上层"，面板必须盖住控制栏与字幕层。
      if (this.showTrackPanel) {
        Column() {
          // 半透明遮罩：点空白处关闭面板（下方整块绑定 onClick）
          Column()
            .width('100%')
            .layoutWeight(1)
            .onClick(() => {
              this.showTrackPanel = false;
            })

          this.TrackPanel()
        }
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.55)')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // 根 Stack 不使用 expandSafeArea：它会影响 Stack 的布局区域判断，
    // 沉浸式已交给 XComponent，控制栏保持在安全区内。
  }
}
