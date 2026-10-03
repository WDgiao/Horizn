import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { fileIo } from '@kit.CoreFileKit';
import { window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common as commonKit } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { showToast } from '../common/Toast';
import { formatDuration } from '../common/MediaData';
import { MediaTier, mediaTierOf, isVideoContainer } from '../common/MediaType';
import { WatchHistory } from '../model/WatchHistory';
import { DiagLog } from '../model/DiagLog';
import { SoftPlayerController, SoftPlayerSnapshot } from '../model/SoftPlayerController';
import { SoftPlayerState, SoftAudioTrack, SoftSubtitleTrack } from '../model/SoftPlayerTypes';
import {
  appSettings, AppSettings, SettingsData, SettingsPatch, defaultSettings, DecodePreference,
  SubtitleLanguage, subtitleFontPx, trackMatchesLanguage,
  EqPreset, EQUALIZER_PRESETS, EQ_CUSTOM_NAME, findEqPresetOrUndefined
} from '../model/AppSettings';
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

/**
 * 发起 seek 之后，"忽略旧位置回写"的时长（毫秒）
 *
 * 取值理由：软解通道的 seek 要等解码器重新对齐参考链（关键帧间隔最大
 * 约 4.5 秒），实测一次拖动后 1~2 秒内就能出画面；给 3 秒足够覆盖，
 * 又不会在 seek 真的失败时把界面"骗"太久。
 * 它只影响显示，不影响播放：超时后一切照旧跟随引擎上报的真实位置。
 */
const SEEK_SETTLE_MS: number = 3000;

/**
 * 倍速档位（2026-10-04 新增）
 *
 * 软解通道支持 0.25~4.0 的连续值，这些档位随便给；
 * 系统 AVPlayer 通道只有枚举里的几档（0.75/1.0/1.25/1.75/2.0），
 * 不在这几档上的（0.5/1.5/3.0）会取**最接近的一档**，不会点不动。
 */
const SPEED_OPTIONS: number[] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];

/**
 * 长按临时加速的倍率规则
 *
 * 规则：当前速度 < 2.0 时按住变 2.0，否则变 3.0。
 * 为什么不写成"按住固定 2x"：用户在 2x 上再长按就没反应了（等于功能失效）；
 * 也不写成"按住 = 当前 ×2"：0.5x 按住变 1.0x，等于没加速，同样莫名其妙。
 */
const TEMP_SPEED_LOW: number = 2.0;
const TEMP_SPEED_HIGH: number = 3.0;
/** 按住多久算长按（毫秒）：500ms 与系统长按阈值一致 */
const LONG_PRESS_MS: number = 500;

/**
 * 均衡器预置表已移到 AppSettings.ets（设置模块）：
 * 那里的加载逻辑要用它做"预置名 ↔ 曲线"的一致性校正，
 * 表放在页面里会让依赖方向反过来（设置模块 import 页面）。
 * 这里只保留频点标签，用于手动调节那一排竖滑块下面的刻度。
 */
const EQ_FREQ_LABELS: string[] = ['60', '170', '310', '600', '1k', '3k', '6k', '12k', '14k', '16k'];

/**
 * 「色调」面板的七行参数名，顺序与 colorValue() / setColorValueLocal() 的下标一致
 *
 * 前四项对应参考图里的功能（亮度/对比度/饱和度/色彩度），
 * 后三项是用户要求的"调整视频的 RGB 颜色"（三个通道各自的增益）。
 */
const COLOR_ROW_LABELS: string[] = ['亮度', '对比度', '饱和度', '色彩度', '红色', '绿色', '蓝色'];

/**
 * 色调预设（2026-10-04 新增，放在色调面板最下方）
 *
 * 每一项就是七个参数的成套取值（百分比，含义同滑块）。
 * 设计取向：
 *   · 明亮/柔和/鲜艳  —— 观感类，日常最常用；
 *   · 冷色/暖色       —— 用 R/B 通道增益做色温偏移（比色相旋转更"像白平衡"）；
 *   · 电影/怀旧/黑白  —— 风格类，对应压对比、褪色、除色这些常见调色手法。
 * 选预设后滑块会跟着动（面板里的数值始终等于实际生效值）。
 */
interface ColorPreset {
  name: string;
  bri: number;
  con: number;
  sat: number;
  hue: number;
  r: number;
  g: number;
  b: number;
}

const COLOR_PRESETS: ColorPreset[] = [
  { name: '原色', bri: 0, con: 0, sat: 0, hue: 0, r: 0, g: 0, b: 0 },
  { name: '明亮', bri: 18, con: 12, sat: 8, hue: 0, r: 0, g: 0, b: 0 },
  { name: '柔和', bri: 6, con: -14, sat: -10, hue: 0, r: 4, g: 2, b: 0 },
  { name: '鲜艳', bri: 4, con: 14, sat: 30, hue: 0, r: 0, g: 0, b: 0 },
  { name: '冷色', bri: 4, con: 4, sat: 0, hue: -6, r: -10, g: 0, b: 12 },
  { name: '暖色', bri: 6, con: 4, sat: 6, hue: 6, r: 14, g: 4, b: -12 },
  { name: '电影', bri: -6, con: 20, sat: -6, hue: 8, r: -6, g: 2, b: 8 },
  { name: '怀旧', bri: 8, con: -20, sat: -38, hue: 10, r: 12, g: 6, b: -12 },
  { name: '黑白', bri: 4, con: 16, sat: -100, hue: 0, r: 0, g: 0, b: 0 }
];

/** 带符号的百分比文本：+12% / -3% / 0% */
function formatSignedPercent(v: number): string {
  if (v > 0) {
    return '+' + v.toString() + '%';
  }
  return v.toString() + '%';
}

/** 按名字找预置；找不到时返回"默认"（设置文件被手改过也不能让面板空掉） */
function findEqPreset(name: string): EqPreset {
  for (let i = 0; i < EQUALIZER_PRESETS.length; i++) {
    if (EQUALIZER_PRESETS[i].name === name) {
      return EQUALIZER_PRESETS[i];
    }
  }
  return EQUALIZER_PRESETS[0];
}

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

  /**
   * 是否显示"加载/缓冲"指示（2026-10-03 新增）
   *
   * 两种用途：
   *   ① 起播阶段：文件已就绪但**首帧还没上屏** —— 这时不该开始播（见 awaitFirstFrame）；
   *   ② 播放途中：一小段时间没有任何位置更新（解码跟不上/临时缺数据）——
   *      给用户一个"在加载"的反馈，而不是看着画面发呆以为卡死了。
   */
  @State buffering: boolean = false;
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
   * 上一次看到的软解状态机状态（-1 = 还没看到过）
   *
   * ★ 2026-10-04 新增，修的是一个"把 1 秒节流废掉"的缺陷 ★
   *
   *   onSoftUpdate 是**每 100ms** 调一次的快照回调，而 PLAYING 分支里原来写着
   *     this.lastSavedAt = Date.now();
   *     this.persistProgress(...);
   *   于是每次快照都把节流时间戳刷新一遍，下面那段
   *     "now - lastSavedAt > 1000 才落盘" 永远不成立，
   *   实际变成**每 100ms 写一次观看记录**（真机 diag.log 实锤：
   *   "persist OK pos=… total=20" 连成一片，一秒十条）。
   *   代价是 UI 线程每秒做 10 次 JSON 序列化 + 文件写入 ——
   *   拖动进度条时会明显发涩、丢帧。
   *   现在只在"状态**变化**到 PLAYING"的那一刻落一次盘，周期性落盘仍交给
   *   下面的 1 秒节流。
   */
  private lastSoftState: number = -1;

  /**
   * 刚发起的 seek：时刻（Date.now()）与目标位置（毫秒）
   *
   * ★ 2026-10-04 新增，专治用户反馈的「拖动后弹回去继续播放」★
   *
   *   时间轴是这样的：用户松手 → 上层把位置设成目标值 → 引擎开始 seek。
   *   而 seek 真正生效前，引擎仍会按 100ms 的节奏上报**旧位置**的进度，
   *   上层的"位置回写"就会把滑块又拉回旧位置 —— 视觉上就是"弹回去"，
   *   用户以为没生效，其实 seek 正在执行。
   *
   *   所以发起 seek 之后的一小段时间里，凡是与目标差得较远的快照位置
   *   一律忽略（滑块停在用户放下的地方），等引擎真的跳到目标附近再交还控制权。
   *   这是纯 UI 侧的兜底：它不假设引擎多久能完成，只保证"用户看到的
   *   位置不会在他刚拖完之后自己弹回去"。
   */
  private seekIssuedAt: number = 0;
  private seekIssuedTo: number = -1;

  /* ==================== 色调 / 均衡器状态（2026-10-04 新增） ==================== */

  /** 是否显示「色调」面板 */
  @State showColorPanel: boolean = false;
  /** 是否显示「均衡器」面板 */
  @State showEqPanel: boolean = false;

  // 色调七项（百分比 -100~100）。做成 @State 是为了让滑块/数值实时刷新。
  @State colBrightness: number = 0;
  @State colContrast: number = 0;
  @State colSaturation: number = 0;
  @State colHue: number = 0;
  @State colRGain: number = 0;
  @State colGGain: number = 0;
  @State colBGain: number = 0;

  /** 均衡器总开关与当前预置名 */
  @State eqEnabled: boolean = false;
  @State eqPresetName: string = '默认';

  /**
   * 均衡器 10 段手动增益（dB）
   *
   * ★ 必须整体替换数组才会触发重绘 ★
   *   ArkUI 的 @State 对数组是"引用比较"：`this.eqBands[i] = v` 改了内容但引用没变，
   *   界面不会刷新（滑块拖了不走、柱状图不动）。所以 setEqBand 里一律
   *   slice() 出一份新数组再赋值 —— 这是 ArkUI 状态管理的经典坑。
   */
  @State eqBands: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

  /* ==================== 倍速（2026-10-04 新增） ==================== */

  /** 当前播放速度（1.0 = 原速）。不落盘：每次开播回到原速，这也是主流播放器的默认 */
  @State speed: number = 1.0;
  /** 是否处于"长按临时加速"中（决定要不要显示角标） */
  @State tempSpeedActive: boolean = false;
  /** 是否显示「倍速」抽屉 */
  @State showSpeedPanel: boolean = false;
  /** 长按计时器（-1 = 没有在计时）。必须在 aboutToDisappear 里清掉 */
  private longPressTimer: number = -1;
  /**
   * 抑制下一次"点画面显隐控制层"
   *
   * 长按结束时手指抬起同样会触发控制层的 onClick，用户会看到"按一下就加速、
   * 松手后控制栏莫名其妙冒出来"。用这个标志吃掉那一次。
   */
  private suppressControlsToggle: boolean = false;

  /* ==================== 音量与手势（2026-10-04 新增） ==================== */

  /** 应用内音量（0.0~1.0）。落盘，下次开播自动恢复 */
  @State volume: number = 1.0;
  /** 手势提示文本（'' = 不显示） */
  @State gestureHint: string = '';
  /** 手势进度条比例 0~1（-1 = 不显示） */
  @State gestureBar: number = -1;

  /** 手势起点（像素）与按下时刻 */
  private touchDownX: number = 0;
  private touchDownY: number = 0;
  private touchDownAt: number = 0;
  /** 上一次抬手时刻（双击判定用） */
  private lastTapAt: number = 0;
  /**
   * 当前手势模式：0=还没定 1=横向（拖进度） 2=纵向（左半屏亮度 / 右半屏音量）
   *
   * 为什么"先定模式再动作"：手指落下时无法预知用户要横着还是竖着划，
   * 若两边同时响应，想调音量的人会把进度也拖乱。所以第一次移动超过阈值时
   * 按"哪个方向位移更大"定死一种模式，本次手势内不再切换。
   */
  private gestureMode: number = 0;
  /** 手势起始播放位置（横向拖动时的基准） */
  private gestureBaseMs: number = 0;
  /** 手势起始参数值（亮度或音量的基准） */
  private gestureBaseValue: number = 0;
  /** 纵向手势落在右半屏 = 音量，左半屏 = 亮度 */
  private gestureOnRightHalf: boolean = false;
  /** 手势提示的自动收起计时器（-1 = 没有在计时） */
  private gestureTimer: number = -1;

  /* ==================== 倍速：应用与交互 ==================== */
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

  /**
   * 应用设置（播放 / 字幕）
   *
   * 为什么每次用都重新 get() 而不是缓存一份字段：
   *   本页可能被"压"在路由栈里（用户从这里返回首页 → 进设置改一项 → 回来），
   *   那时页面不会重建、@State 也不会刷新，缓存下来的旧值就会一直生效。
   *   get() 读的是内存缓存，没有磁盘开销，所以每次按需要读最新的最省心。
   */
  private settings: AppSettings | undefined = undefined;

  /**
   * 是否已经按设置自动选过字幕轨
   *
   * 一个文件只自动选一次：快照是每 100ms 来的，不加这个闸门就会
   * 反复把用户手动关掉的字幕又打开（那是最典型的"设置项打架"）。
   */
  private subtitleAutoApplied: boolean = false;

  /**
   * 是否在等"首帧上屏"才开播（2026-10-03 新增）
   *
   * 为什么要有这一步（用户反馈："点开东西还没渲染完就在放了"）：
   *   原来软解一到 READY 就立刻 play()，音频与主时钟先跑起来，
   *   而首帧还在解码/转换（有时还要等 surface 就绪）——
   *   结果先响声音、画面还是黑的。
   *   现在改成：READY 后**不立刻播**，等引擎把首帧渲染上屏
   *   （快照里的 firstFrameRendered，由原生 POSITION 事件的 data2 带上来）再 play()。
   *   引擎侧为此做了"预渲染"：未播放状态下也允许上屏一帧，否则会互等。
   */
  private awaitFirstFrame: boolean = false;

  /**
   * 等首帧的兜底超时（毫秒）
   *
   * 为什么必须有：纯音频文件、解码异常、surface 一直不就绪等情况永远不会
   * 出现"首帧"。没有兜底就会**永远停在加载界面**——那比先响声音更糟。
   * 超时后照常开播，让既有的错误处理去决定要不要报错。
   *
   * ★ 为什么是 20 秒（先后写过 3 秒、8 秒，都被真机打回）：
   *   起播首帧的耗时取决于"seek + 从存储读那一帧"，实测同一台机器、
   *   同一个 842MB 的 rmvb、同一个续播位置附近：快的时候 255ms，
   *   慢的时候 18 秒（内存吃紧时页缓存被换出，要重新读盘）。
   *   兜底超时短于它，就会在首帧之前开播 —— 正是要修掉的现象。实测日志：
   *     · 3 秒版：发起等待后 3 秒内没有任何首帧信号 → 兜底先开播；
   *     · 8 秒版：16:15:07.854 丢弃残留帧 → 16:15:15.903 超时开播（音频先响）
   *               → 16:15:25.593 首帧才上屏（画面晚了 10 秒）。
   *   而等待期间画面本来就是黑的、用户看到的是"正在缓冲…" ——
   *   转圈等 seek 完成是播放器的常规行为，比"先响声音、画面还黑着"好。
   *   纯音频文件不会等：beginFirstFrameWait 里有"没有视频轨就直接开播"的分支。
   */
  private static readonly FIRST_FRAME_TIMEOUT_MS: number = 20000;
  private firstFrameTimer: number = -1;

  /** 最近一次"位置发生变化"的时刻（毫秒），用于判定播放途中是否卡住 */
  private lastPositionAtMs: number = 0;
  /** 最近一次位置值（用于判断"变了没有"） */
  private lastPositionValue: number = -1;

  /**
   * 收到首帧后要不要调用软解的 play()
   *
   * 软解：READY 时不立刻播，等首帧上屏后再 play（本标志为 true）。
   * 系统 AVPlayer：prepared 时就得 play 才会出画，所以为 false。
   */
  private pendingSoftPlay: boolean = false;

  /** 本场是否已经处理过 READY（READY 分支每 100ms 都会跑，必须闸住，见那里说明） */
  private readyHandled: boolean = false;

  /**
   * 是否已经试过「软解失败 → 回退系统播放器」
   *
   * 只在"优先内置软解"这条我们自己选的通道上才允许回退，
   * 且只回退一次，避免两个通道互相踢皮球。
   */
  private softToSystemTried: boolean = false;
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
      // 应用设置（播放/字幕）也用同一个上下文创建；单例，别的页面改过就立刻可见
      this.settings = appSettings(appCtx);
      // ★ 2026-10-04：把上次的色调 / 均衡器状态读进 @State ——
      //   面板打开时显示的就是"当前实际生效"的值，不会出现
      //   "界面显示 0%、实际画面偏蓝"这种对不上的情况。
      const st: SettingsData = this.settings.get();
      this.colBrightness = st.colorBrightness;
      this.colContrast = st.colorContrast;
      this.colSaturation = st.colorSaturation;
      this.colHue = st.colorHue;
      this.colRGain = st.colorRGain;
      this.colGGain = st.colorGGain;
      this.colBGain = st.colorBGain;
      this.eqEnabled = st.eqEnabled;
      this.eqPresetName = st.eqPreset;
      // 手调的 10 段曲线也要读回来：它是真正生效的曲线，
      // 少了这一句就会出现"界面显示默认、耳朵听到超重低音"的不一致
      this.eqBands = st.eqBands.slice();
      // 音量（0~100 → 0.0~1.0）：手势调过之后重启要能恢复
      this.volume = st.volumePercent / 100;
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
          return;
        }
        // 没有"上次选中的外挂字幕"可恢复时，才轮到设置里的自动加载。
        // 顺序不能反：用户手动选过的字幕优先级高于自动策略。
        this.autoLoadSidecarSubtitle();
      }).catch((err: object) => {
        // 原先没有 catch：读盘失败会产生 unhandled rejection，
        // 而且失败原因彻底看不到。这里至少把它记进诊断日志。
        this.writeDiag('恢复外挂字幕失败: ' + JSON.stringify(err));
      });
    } else {
      // 本来就没有可恢复的外挂字幕，直接看设置要不要自动加载
      this.autoLoadSidecarSubtitle();
    }
    // 字幕刷新定时器。100ms 与事件轮询同频 —— 字幕的时间精度本来
    // 就在几十毫秒量级，再密也没有意义，反而白耗电。
    // 顺带驱动控制层的自动隐藏（同一个 tick，不额外起定时器）。
    this.subtitleTimer = setInterval(() => {
      this.refreshSubtitle();
      this.tickControlsAutoHide();
      // 播放途中的卡顿判定（缺数据/解码跟不上 → 显示加载指示）
      this.tickBuffering();
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
    const embeddedReady: boolean = sc !== undefined && this.currentSubtitleIndex >= 0;
    if (this.showTrackPanel) {
      // 面板打开时不刷新：面板是模态的，字幕跟着动反而干扰阅读
      return;
    }
    // ★ 2026-10-03：来源优先级改为按设置决定（原来是把"外挂优先"写死的）。
    //   为什么默认仍然是外挂优先：用户主动去选一个外挂字幕，就是明确表示
    //   "我要用这个"；但有些用户就是想要内嵌的（外挂可能是机翻），
    //   所以给一个开关。两边都有内容时按设置选一个，绝不同时显示两行。
    const preferExt: boolean = this.cfg().preferExternalSubtitle;
    const useExt: boolean = extReady && (preferExt || !embeddedReady);
    if (useExt) {
      const t: string = externalSubtitle.textAt(this.positionMs);
      if (t !== this.subtitleText) {
        this.subtitleText = t;
      }
      return;
    }
    if (embeddedReady) {
      const t2: string = sc!.getActiveSubtitle();
      if (t2 !== this.subtitleText) {
        this.subtitleText = t2;
      }
      return;
    }
    if (extReady) {
      // 内嵌不可用而外挂可用（例如内嵌是位图字幕）—— 仍然显示外挂
      const t3: string = externalSubtitle.textAt(this.positionMs);
      if (t3 !== this.subtitleText) {
        this.subtitleText = t3;
      }
      return;
    }
    if (this.subtitleText.length > 0) {
      this.subtitleText = '';
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
    // 长按/手势的两个 setTimeout 同理：销毁后回调里会去碰已释放的播放器
    if (this.longPressTimer !== -1) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
    if (this.gestureTimer !== -1) {
      clearTimeout(this.gestureTimer);
      this.gestureTimer = -1;
    }
    // 等首帧的兜底定时器也要撤掉：页面没了它还可能触发，
    // 那时会去调用已经释放的软解控制器
    this.awaitFirstFrame = false;
    this.clearFirstFrameTimer();
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
        // ★ 2026-10-03：设置里的「允许跟随设备旋转」在这里生效。
        //   允许 → AUTO_ROTATION_UNSPECIFIED（跟随传感器）
        //   不允许 → PORTRAIT（固定竖屏，仍可用右上角按钮手动全屏）
        const allowRotate: boolean = this.cfg().allowAutoRotate;
        win.setPreferredOrientation(allowRotate
          ? window.Orientation.AUTO_ROTATION_UNSPECIFIED
          : window.Orientation.PORTRAIT);
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

  /** 当前设置（未初始化时用默认值，保证任何路径下都有确定行为） */
  private cfg(): SettingsData {
    const s: AppSettings | undefined = this.settings;
    return s !== undefined ? s.get() : defaultSettings();
  }

  // ==================== 起播等待首帧 + 缓冲指示（2026-10-03 新增） ====================

  /**
   * 开始等首帧：显示加载指示，等引擎报"首帧已上屏"后才真正开播
   *
   * @param startSoftPlay 收到首帧后要不要调用软解的 play()
   *        （系统 AVPlayer 那条路不需要——它在 prepared 时就得 play 才会出画）
   */
  /**
   * 开始等首帧：显示加载指示，等引擎报"首帧已上屏"后才真正开播
   *
   * @param startSoftPlay 收到首帧后要不要调用软解的 play()
   *        （系统 AVPlayer 那条路不需要——它在 prepared 时就得 play 才会出画）
   * @param videoWidth 视频宽（软解快照里的画面宽度）。<= 0 表示这个文件
   *        根本没有视频轨（纯音频），那就**不该等首帧** —— 等不到，白等 8 秒。
   */
  private beginFirstFrameWait(startSoftPlay: boolean, videoWidth: number): void {
    this.clearFirstFrameTimer();

    if (startSoftPlay && videoWidth <= 0) {
      this.writeDiag('该文件没有视频轨，不等待首帧，直接开播');
      this.softCtl?.play();
      return;
    }
    this.awaitFirstFrame = true;
    this.buffering = true;
    this.pendingSoftPlay = startSoftPlay;
    this.writeDiag('等首帧：startSoftPlay=' + startSoftPlay.toString()
      + ' startMs=' + this.startPositionMs.toString());
    this.firstFrameTimer = setTimeout(() => {
      this.firstFrameTimer = -1;
      if (this.disposed || !this.awaitFirstFrame) {
        return;
      }
      // 兜底：等不到首帧也必须开播（否则永远停在加载界面）
      this.writeDiag('等首帧超时 ' + PlayerPage.FIRST_FRAME_TIMEOUT_MS.toString()
        + 'ms，照常开播');
      this.awaitFirstFrame = false;
      this.buffering = false;
      if (this.pendingSoftPlay) {
        this.softCtl?.play();
      }
    }, PlayerPage.FIRST_FRAME_TIMEOUT_MS);
  }

  /** 撤掉等首帧的兜底定时器 */
  private clearFirstFrameTimer(): void {
    if (this.firstFrameTimer >= 0) {
      clearTimeout(this.firstFrameTimer);
      this.firstFrameTimer = -1;
    }
  }

  /**
   * 位置更新统一入口（软解与系统 AVPlayer 两条路都走这里）
   *
   * 职责：
   *   ① 记录"位置在动"，用于判定播放途中是否卡住；
   *   ② 若在等首帧，且位置已经到达目标（续播 seek 时不能停在旧位置的画面上），
   *      就结束等待、开始播放。
   *
   * @param posMs 当前位置
   * @param firstFrameSignal 原生是否明确报了"首帧已上屏"
   */
  private notePosition(posMs: number, firstFrameSignal: boolean, firstFramePtsMs: number): void {
    if (posMs !== this.lastPositionValue) {
      this.lastPositionValue = posMs;
      this.lastPositionAtMs = Date.now();
      // 位置一动，就不再是"缓冲中"
      if (this.buffering && !this.awaitFirstFrame) {
        this.buffering = false;
      }
    }
    if (!this.awaitFirstFrame) {
      return;
    }

    // 续播时：引擎的预渲染发生在 seek 之前，报上来的很可能是"文件开头"那一帧。
    // 判定要用**首帧自己的 pts**（firstFramePtsMs），不能用快照的 positionMs ——
    // seek 完成后引擎还会发一条 POSITION（内容是续播目标），
    // 两条事件落在同一次轮询里时 positionMs 会被那条覆盖，
    // 于是"开头那一帧"会被误判成"已到续播位置"，用户先看到开头闪一下。
    if (this.startPositionMs > 0 && firstFramePtsMs < this.startPositionMs - 1000) {
      return;
    }
    // ★★ 只认原生明确的"首帧已上屏"信号（POSITION 事件 data2 == 1）★★
    //
    //   ⚠️ 不能拿"位置是个有效值"当依据 —— 这是一个实测踩到的真 bug：
    //     · seek 完成时引擎也会发一条 POSITION（内容就是续播目标位置）；
    //     · 那条的 data2 = 0（不是首帧信号），而当时我的判断写成
    //       `!firstFrameSignal && posMs < 0` —— posMs 明明是正的目标位置，
    //       于是这条被当成了"首帧就绪"，play() 提前发出：
    //         [Buf] beginFirstFrameWait videoWidth=1024 startMs=3233277
    //         [Buf] notePosition pos=3233277 signal=false   ← 这就是 seek 那条
    //         音频线程已启动                                ← 比"已上屏 1 帧"早 155ms
    //     结果就是声音仍然抢在画面之前 —— 正是要修掉的现象。
    //   现在只认 data2 带来的信号，位置值仅用于"续播是否已到位"的附加判断。
    if (!firstFrameSignal) {
      return;
    }
    this.writeDiag('首帧已上屏 pos=' + posMs.toString()
      + ' firstFrameSignal=' + firstFrameSignal.toString() + ' → 开始播放');
    this.awaitFirstFrame = false;
    this.buffering = false;
    this.clearFirstFrameTimer();
    if (this.pendingSoftPlay) {
      this.softCtl?.play();
    }
  }

  /**
   * 播放途中的卡顿判定（由 100ms 轮询驱动）
   *
   * ★ 判定写成**对称**的：位置超过 900ms 没动 → 显示；位置又动了 → 撤掉。
   *   为什么不能只在 notePosition 里去撤：那条路只在快照有变化时才会跑到，
   *   实测出现过"引擎明明在出帧、进度条也在走，加载指示却一直挂着"的情况
   *   （暂停/继续之后触发）。tick 是每 100ms 无条件跑的，用它兜住最稳。
   */
  private tickBuffering(): void {
    if (this.disposed || this.awaitFirstFrame) {
      return;
    }
    if (!this.playing || this.dragging || this.errorMsg.length > 0) {
      if (this.buffering) {
        this.buffering = false;
      }
      return;
    }
    if (this.lastPositionAtMs <= 0) {
      return;
    }
    const idleMs: number = Date.now() - this.lastPositionAtMs;
    if (idleMs > 900) {
      this.buffering = true;
    } else if (this.buffering) {
      this.buffering = false;
    }
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

    // ★ 2026-10-03：设置里的「解码方式」在这里生效。
    //   PREFER_SOFT = 连系统本来能播的格式（mp4/mkv…）也先走内置软解 ——
    //   好处是字幕/音轨的控制完全统一（系统那条通道的自字幕我们管不了），
    //   代价是更耗电。失败时会自动回退系统（见 onSoftUpdate 的软解失败分支）。
    const preferSoft: boolean = this.cfg().decodePreference === DecodePreference.PREFER_SOFT;
    // ★ 通道决策日志：这台播放器有"系统硬解"和"内置软解"两条通道，
    //   出问题时第一个要回答的就是"这次走了哪条、为什么"。
    //   把设置原值和"设置存储是否就绪"一起打出来 —— 少任何一项都得靠猜。
    console.info('[Route] tier=' + tier.toString()
      + ' preferSoft=' + preferSoft.toString()
      + ' decodeCfg=' + this.cfg().decodePreference.toString()
      + ' settingsReady=' + (this.settings !== undefined).toString()
      + ' path=' + this.videoPath);
    if (tier === MediaTier.NEEDS_SOFT_DECODE) {
      this.writeDiag('后缀属于系统不支持的容器，直接走软解');
      this.startSoftPlayer();
      return;
    }
    if (preferSoft) {
      this.writeDiag('设置：优先内置软解 → 本文件也先走软解');
      this.startSoftPlayer();
      return;
    }

    this.createSystemPlayer();
  }

  /**
   * 走系统播放器（AVPlayer）通道
   *
   * 为什么从 createPlayer 里拆出来：
   *   「优先内置软解」失败时需要回退到这条通道，而那时不能重跑 createPlayer
   *   —— 它会再次按设置判断、又切回软解，变成两个通道互相踢皮球。
   */
  private createSystemPlayer(): void {
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
      // ★ 2026-10-03：设置里关掉自动回退时，看门狗只提示、不切通道。
      //   为什么不直接强制回退：那样这个开关就没有意义了。
      //   为什么也不报错页：音频还在正常播，报错页会把"能听"也一起停掉，
      //   用户只是看不到画面而已 —— 提示一句、让用户自己去设置里打开回退更合适。
      if (!this.cfg().autoFallbackSoft) {
        this.writeDiag('自动回退软解已在设置中关闭，保持系统通道');
        showToast('画面可能无法显示：系统解码不支持该编码，且已在设置里关闭自动回退软解');
        return;
      }
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
   * 「优先内置软解」失败时回退到系统播放器
   *
   * 为什么必须有这一步：
   *   「优先软解」是用户在设置里选的策略，不是"这个文件只能软解"的结论。
   *   如果软解对它无能为力（罕见编码、软解构建里没带的格式），
   *   一个设置项就把本来能播的文件变成播不了 —— 那不能接受。
   *   所以软解失败时给系统播放器一次机会。
   *
   * 只在两种情况下回退：
   *   · 确实是"优先软解"策略把我们带到这条通道的
   *   · 且该容器系统本来就可能支持（TIER_PLAYABLE）；RMVB/WMV 这类
   *     系统必然不支持，回退只会白白多等一次失败
   */
  private shouldFallbackToSystem(): boolean {
    if (this.softToSystemTried || this.isNetworkUrl(this.videoPath)) {
      return false;
    }
    if (this.cfg().decodePreference !== DecodePreference.PREFER_SOFT) {
      return false;
    }
    // PLAYABLE / MAYBE_PLAYABLE 都值得让系统试一次；
    // NEEDS_SOFT_DECODE（RMVB/WMV 这类）系统必然不支持，回退只会白等一次失败
    const tier: MediaTier = mediaTierOf(this.videoPath);
    return tier === MediaTier.PLAYABLE || tier === MediaTier.MAYBE_PLAYABLE;
  }

  /** 释放软解、改走系统播放器（只做一次） */
  private fallbackToSystem(reason: string): void {
    if (this.softToSystemTried) {
      return;
    }
    this.softToSystemTried = true;
    this.writeDiag('回退到系统播放器，原因：' + reason);
    const c: SoftPlayerController | undefined = this.softCtl;
    this.softCtl = undefined;
    this.usingSoft = false;
    if (c !== undefined) {
      c.release();
    }
    this.errorMsg = '';
    this.preparing = true;
    this.prepared = false;
    this.avState = 'idle';
    this.usingExternalSubtitle = false;
    this.currentSubtitleIndex = -1;
    this.createSystemPlayer();
  }

  /**
   * 按设置自动加载同目录外挂字幕
   *
   * 只在"用户没有手动选过字幕"的路径上调用（见 aboutToAppear），
   * 且只在设置打开时才动作。同名文件优先 —— 同名的几乎一定就是它。
   */
  private autoLoadSidecarSubtitle(): void {
    if (!this.cfg().autoLoadSidecar) {
      return;
    }
    const list: SubtitleCandidate[] = this.sidecarCandidates;
    if (list.length === 0) {
      return;
    }
    let pick: SubtitleCandidate = list[0];
    for (let i = 0; i < list.length; i++) {
      if (list[i].sameName) {
        pick = list[i];
        break;
      }
    }
    this.writeDiag('设置：自动加载同目录外挂字幕 ' + pick.name);
    this.useSidecarSubtitle(pick).catch((err: object) => {
      this.writeDiag('自动加载外挂字幕失败: ' + JSON.stringify(err));
    });
  }

  /**
   * 按设置挑一条内嵌字幕轨（一个文件只做一次）
   *
   * 三种策略：
   *   跟随文件默认 —— 优先容器标记的默认轨，没有就取第一条可解码的
   *   中文优先 / 英文优先 —— 只挑语言匹配的；一条都不匹配时**不启用**
   *     （宁可不显示，也不要给用户一条语言不对的字幕）
   *   不自动启用 —— 完全不碰
   *
   * @param tracks 文件里的字幕轨
   * @param current 引擎当前生效的轨下标（>=0 说明引擎自己选了，我们不抢）
   */
  private applySubtitlePreference(tracks: SoftSubtitleTrack[], current: number): void {
    if (this.subtitleAutoApplied || tracks.length === 0) {
      return;   // 还没有轨道信息时等下一次快照，不消耗这一次机会
    }
    this.subtitleAutoApplied = true;
    const cfg: SettingsData = this.cfg();
    if (cfg.subtitleLanguage === SubtitleLanguage.OFF) {
      this.writeDiag('设置：不自动启用字幕');
      return;
    }
    if (current >= 0 || this.usingExternalSubtitle) {
      // 引擎已经选了一条，或外挂字幕已经在用 —— 都不该再叠一条上去
      return;
    }
    let pick: number = -1;
    if (cfg.subtitleLanguage === SubtitleLanguage.AUTO) {
      for (let i = 0; i < tracks.length; i++) {
        if (tracks[i].isDefault && tracks[i].supported) {
          pick = tracks[i].index;
          break;
        }
      }
      if (pick < 0) {
        for (let i = 0; i < tracks.length; i++) {
          if (tracks[i].supported) {
            pick = tracks[i].index;
            break;
          }
        }
      }
    } else {
      for (let i = 0; i < tracks.length; i++) {
        const t: SoftSubtitleTrack = tracks[i];
        if (t.supported && trackMatchesLanguage(t.language, t.title, cfg.subtitleLanguage)) {
          pick = t.index;
          break;
        }
      }
    }
    if (pick < 0) {
      this.writeDiag('设置：没找到匹配的内嵌字幕轨，保持关闭');
      return;
    }
    this.chooseEmbeddedSubtitle(pick);
    this.writeDiag('设置：自动启用内嵌字幕 index=' + pick.toString());
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
    // ★ 2026-10-03：续播起点**在这里**交给引擎（而不是等 READY 后再 seek）。
    //   引擎会"打开 → 跳到起点 → 预渲染第一帧"，于是上层拿到的首帧
    //   就是续播位置那一帧；否则首帧是文件开头，只能靠超时兜底才敢开播。
    if (!ctl.prepare(this.videoPath, this.startPositionMs)) {
      // prepare 的同步失败已经在 onSoftUpdate 里通过 error 快照报出来了
      this.preparing = false;
    }
  }

  /** 软解状态更新（在 JS 线程被调用） */
  private onSoftUpdate(snap: SoftPlayerSnapshot): void {
    if (snap.error.length > 0) {
      // ★ 2026-10-03：软解失败时，如果是"优先软解"策略把它带到这条通道的，
      //   给系统播放器一次机会（否则一个设置项就能让能播的文件播不了）。
      if (this.shouldFallbackToSystem()) {
        this.fallbackToSystem('软解失败：' + snap.error);
        return;
      }
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
    // 播放位置（拖动时不要被回写覆盖；刚 seek 完的旧位置也不要）
    if (!this.dragging && !this.isStalePositionAfterSeek(snap.positionMs)) {
      this.positionMs = snap.positionMs;
    }
    // ★ 2026-10-03：位置更新统一走 notePosition —— 它负责
    //   ①判定"播放途中是否卡住"（卡住就显示加载指示）
    //   ②起播时等到首帧上屏/位置到位后才真正开播
    this.notePosition(snap.positionMs, snap.firstFrameRendered, snap.firstFramePtsMs);

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
      // ★★ 2026-10-03：READY 分支**每 100ms 都会跑一次**，里面的动作必须闸住 ★★
      //
      //   这是一个实测抓到的真 bug：原来这里无脑做两件事 ——
      //     · `seekTo(startPositionMs)`（续播）
      //     · 起播（现在改成"等首帧"）
      //   状态从 READY 走到 PLAYING 期间会经过很多次快照，于是**seek 被反复下发**：
      //     日志实测每 100ms 一条「解复用线程已 seek 到 3273325 ms 并清空队列」，
      //     解码器被一次次拉回目标点，首帧永远来不及解出来，
      //     最终只能靠上层的兜底超时开播 —— 而那时声音又抢在了画面之前。
      //   以前 READY 只停留几十毫秒，这个重复恰好没被看见；等首帧把 READY
      //   拉长到几秒之后它就成了主要矛盾。
      //   现在整场只处理一次（换文件会重建页面，标志随之重置）。
      if (this.readyHandled) {
        return;
      }
      this.readyHandled = true;
      // 按字幕设置挑内嵌字幕轨（内部还有一次自己的闸门，双保险）
      this.applySubtitlePreference(snap.subtitleTracks, snap.currentSubtitleIndex);
      // ★ 2026-10-04：软解通道就绪时把色调 / 均衡器推给引擎 ★
      //   放在这里而不是 Prepare 之前：引擎要等会话建立后这些设置才有意义；
      //   而 READY 恰好只跑一次（上面的 readyHandled 闸门），推一次就够。
      //   这样"上次调过的画面/声音"在新文件里自动延续，用户不必每次重调。
      this.applyColorAdjust();
      this.applyAudioEq();
      // 音量也在这一刻下发：软解通道的音频流是 Prepare 时才建的，
      // 早于此时调用只会写进引擎的记忆值（也能生效，但这里补一次更直白）
      this.applyVolume(this.volume);
      this.writeDiag('色调/均衡已应用：' + this.colBrightness.toString() + '/'
        + this.colContrast.toString() + '/' + this.colSaturation.toString() + '/'
        + this.colHue.toString() + '/' + this.colRGain.toString() + '/'
        + this.colGGain.toString() + '/' + this.colBGain.toString()
        + ' eq=' + this.eqEnabled.toString() + '(' + this.eqPresetName + ')');
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
      // ★ 续播 seek 已经在 startSoftPlayer 里通过 prepare(path, startMs) 交给引擎了
      //   （引擎在预渲染之前完成跳转），这里刻意**不再补一次 seek** ——
      //   补的话会把刚预渲染好的位置再次打乱。
      this.writeDiag('soft READY: 续播位置由引擎在 Prepare 阶段处理 startMs='
        + this.startPositionMs.toString());
      // ★ 2026-10-03：不在这里直接 play() —— 先等首帧上屏再播（见 beginFirstFrameWait）。
      //   引擎已做"预渲染"：未播放状态也允许上屏一帧，所以不会互等。
      this.beginFirstFrameWait(true, snap.width);
    } else if (st === SoftPlayerState.PLAYING) {
      this.playing = true;
      this.preparing = false;
      this.errorMsg = '';
      // ★ 只在"刚进入 PLAYING"那一刻落一次盘（见 lastSoftState 的说明）：
      //   这个分支每 100ms 都会跑到，无脑落盘会把 1 秒节流刷没。
      if (this.durationMs > 0 && st !== this.lastSoftState) {
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

    // ★ 记下本帧看到的状态，供"是否刚进入 PLAYING"判断（见 lastSoftState）
    this.lastSoftState = st;

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
        // ★ 2026-10-03：系统 AVPlayer 这条通道**不能**像软解那样"等首帧再播"
        //   —— 它必须先 play() 才会解码出画。所以这里照旧立即 play()，
        //   但把加载指示挂起来：等第一条 timeUpdate（首位位置更新）到达才撤掉，
        //   那之前用户看到的是"正在缓冲"，而不是黑屏。
        //   同样带兜底超时：万一位置一直不来，也必须撤掉指示，不能一直挡着。
        //   第二个参数传 1（当作"有视频轨"）：系统通道不靠它判断，只是为了接口统一。
        this.beginFirstFrameWait(false, 1);
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
      // 拖动中不回写；刚发起 seek、引擎还在旧位置上时也不回写（否则滑块会弹回去）
      if (!this.dragging && !this.isStalePositionAfterSeek(time)) {
        this.positionMs = time;
      }
      // ★ 2026-10-03：系统通道也走统一的位置入口 —— 它的"首帧已上屏"信号
      //   就是第一条 timeUpdate（AVPlayer 没有首帧回调，这是最接近的等价物）。
      // 系统通道没有"首帧 pts"这个概念，直接用它自己的位置（timeUpdate 的 time）
      this.notePosition(time, true, time);
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
      //   2026-10-03：回退开关受设置控制（默认开）。
      if (this.isUnsupportedFormat(err.code) && !this.usingSoft && !this.softFallbackTried
          && this.cfg().autoFallbackSoft) {
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
    // ★ 2026-10-03：设置里的「记住播放进度」在这里生效。
    //   关掉之后不再写观看历史 —— 首页的「继续观看」也就不会再出现新记录。
    if (!this.cfg().rememberProgress) {
      return;
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
    // 长按加速结束时手指抬起也会走到这里：吃掉这一次，
    // 否则用户"按一下加速、松手后控制栏自己冒出来"
    if (this.suppressControlsToggle) {
      this.suppressControlsToggle = false;
      return;
    }
    if (this.showControls) {
      this.showControls = false;
      return;
    }
    this.showControls = true;
    // 唤出来的那一刻重新计时，避免"刚点出来立刻又被自动隐藏"
    this.noteControlsActivity();
  }

  /**
   * 画面长按/抬手：长按临时加速，松手还原
   *
   * 为什么挂在控制层这个铺满全屏的 Column 上：
   *   XComponent(SURFACE) 的触摸事件不回 ArkUI（文件头注释里记过实测结论），
   *   而控制层始终铺满全屏且位于视频层之上，是唯一可靠的手势落点。
   *
   * 与 onClick 的配合：长按抬手同样会触发 onClick，所以结束时置
   * suppressControlsToggle，由 toggleControls 吃掉那一次（见那里的说明）。
   */
  /**
   * 安全取触点坐标
   *
   * ★ 踩过的坑：抬手（TouchType.Up）时 event.touches 可能是**空数组** ——
   *   它表示"当前还按在屏幕上的手指"，抬手那一刻当然没有了，
   *   真正离开的那个点在 changedTouches 里。直接写 touches[0].x 会在抬手时
   *   抛异常（被 ArkUI 吞掉，表现为"滑动生效了但松手那一下什么都没有"：
   *   音量确实变了、却没落盘，进度也没跳）。所以两个都试，优先 changedTouches。
   */
  private touchX(event: TouchEvent): number {
    if (event.changedTouches.length > 0) {
      return event.changedTouches[0].x;
    }
    if (event.touches.length > 0) {
      return event.touches[0].x;
    }
    return this.touchDownX;
  }

  private touchY(event: TouchEvent): number {
    if (event.changedTouches.length > 0) {
      return event.changedTouches[0].y;
    }
    if (event.touches.length > 0) {
      return event.touches[0].y;
    }
    return this.touchDownY;
  }

  private onVideoTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      // 抽屉开着时不接管：那时用户是在操作面板
      if (this.anyPanelOpen()) {
        return;
      }
      this.touchDownX = this.touchX(event);
      this.touchDownY = this.touchY(event);
      this.touchDownAt = Date.now();
      this.gestureMode = 0;
      // ★ 双击 = 播放/暂停 ★
      //   判定放在 Down 上而不是 Up：双击的第二次按下就该立刻响应，
      //   等抬手才响应会有"点了没反应"的迟滞感。300ms 是通行阈值。
      if (this.touchDownAt - this.lastTapAt < 300) {
        this.lastTapAt = 0;   // 吃掉，避免三击被当成两次双击
        this.togglePlay();
        return;
      }
      this.lastTapAt = this.touchDownAt;
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
      }
      this.longPressTimer = setTimeout(() => {
        this.longPressTimer = -1;
        this.enterTempSpeed();
      }, LONG_PRESS_MS);
    } else if (event.type === TouchType.Move) {
      if (this.anyPanelOpen()) {
        return;
      }
      // ★ 手指一动就取消长按计时 ★
      //   原来只在"方向判定成功"之后才取消，而判定要等位移超过 18px ——
      //   真机上首次 Move 可能已经在 500ms 之后才到（也就是长按计时器先到期），
      //   于是"边拖边被当成长按"：抬手时走进还原倍速的分支，手势当场作废。
      //   移动永远不可能是长按，所以任何 Move 都该取消，不必等判定。
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
      }
      this.handleGestureMove(this.touchX(event) - this.touchDownX,
        this.touchY(event) - this.touchDownY);
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
      }
      // ★ 长按还原与手势结束是**两件独立的事**，不能写成 else if ★
      //   原来写成互斥分支，结果"拖动过程中长按先触发"时手势结束被整段跳过，
      //   表现就是"滑了半天松手什么都不发生"（音量变了不落盘、进度压根不跳）。
      if (this.tempSpeedActive) {
        this.exitTempSpeed();
        this.suppressControlsToggle = true;
      }
      if (this.gestureMode !== 0) {
        this.suppressControlsToggle = true;
        this.handleGestureEnd(this.touchX(event) - this.touchDownX,
          this.touchY(event) - this.touchDownY);
      }
    }
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
    // 拖动进度条、或任意抽屉开着时都不自动隐藏控制层
    if (this.dragging || this.anyPanelOpen()) {
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
    // 记下"刚发起 seek"，让位置回写在这段时间里不要弹回旧位置
    // （说明见 seekIssuedAt / isStalePositionAfterSeek）
    this.seekIssuedAt = Date.now();
    this.seekIssuedTo = ms;
    // ★ 诊断留痕（2026-10-04）：用户反馈"拖进度条没反应"时，必须能区分
    //   ①上层根本没把 seek 发出去（手势没到 / durationMs 还是 0）
    //   ②发出去了但引擎没执行（这边日志有、引擎那边没动）
    //   每个 seek 只打一条，不会刷屏（拖动也只会在松手时走这里一次）。
    this.writeDiag('seek 请求 ms=' + ms.toString() + ' 通道='
      + (this.usingSoft ? 'soft' : 'avplayer') + ' dur=' + this.durationMs.toString());
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

  /* ==================== 音量：应用与落盘 ==================== */

  /** 把音量推给当前通道（软解走系统音频渲染器，系统通道走 player.volume） */
  private applyVolume(v: number): void {
    const clamped: number = v < 0 ? 0 : (v > 1 ? 1 : v);
    this.volume = clamped;
    if (this.usingSoft) {
      this.softCtl?.setVolume(clamped);
      return;
    }
    const p = this.player;
    if (p !== undefined) {
      try {
        // AVPlayer 没有 volume 属性，用 setVolume(单参数，0.0~1.0) 设置
        p.setVolume(clamped);
      } catch (err) {
        this.trackNotice = '音量设置失败';
      }
    }
  }

  /** 音量写进设置文件（松手时调用，拖动过程不落盘） */
  private persistVolume(): void {
    const s: AppSettings | undefined = this.settings;
    if (s === undefined) {
      return;
    }
    s.update({ volumePercent: Math.round(this.volume * 100) } as SettingsPatch);
  }

  /* ==================== 手势 ==================== */

  /** 手势提示的统一展示（自动在 900ms 后收起） */
  private showGestureHint(hint: string, bar: number): void {
    this.gestureHint = hint;
    this.gestureBar = bar;
    if (this.gestureTimer !== -1) {
      clearTimeout(this.gestureTimer);
    }
    this.gestureTimer = setTimeout(() => {
      this.gestureTimer = -1;
      this.gestureHint = '';
      this.gestureBar = -1;
    }, 900);
  }

  /**
   * 处理画面上的滑动手势
   *
   * @param dx 相对按下点的横向位移（px，右为正）
   * @param dy 相对按下点的纵向位移（px，下为正）
   *
   * 设计取舍（移动端播放器的通用做法）：
   *   · 横滑 = 拖进度：**不边拖边 seek**，只在提示上显示目标时间，松手才跳 ——
   *     每动一下就 seek 会让解码器反复重启（软解代价尤其高）；
   *   · 竖滑 = 调参数：实时生效（调音量/亮度就是要边调边听/看），
   *     滑动手感才跟手；松手才落盘。
   */
  private handleGestureMove(dx: number, dy: number): void {
    // 位移超过阈值才决定模式（避免手指微抖就误判方向）
    if (this.gestureMode === 0) {
      if (Math.abs(dx) < 18 && Math.abs(dy) < 18) {
        return;
      }
      // 长按计时器要取消：手指已经在滑了，不该再触发"长按加速"
      if (this.longPressTimer !== -1) {
        clearTimeout(this.longPressTimer);
        this.longPressTimer = -1;
      }
      if (Math.abs(dx) > Math.abs(dy)) {
        this.gestureMode = 1;
        this.gestureBaseMs = this.positionMs;
      } else {
        this.gestureMode = 2;
        this.gestureOnRightHalf = this.touchDownX > this.areaWidth / 2;
        this.gestureBaseValue = this.gestureOnRightHalf ? this.volume : this.colBrightness / 100.0;
      }
    }

    if (this.gestureMode === 1) {
      // 横向：整屏宽度对应 ±6 分钟（手机上最长也就拖这么远，再长不跟手）
      const spanMs: number = 6 * 60 * 1000;
      const deltaMs: number = Math.round(dx / this.areaWidth * spanMs);
      const target: number = this.clampToDuration(this.gestureBaseMs + deltaMs);
      const sign: string = deltaMs >= 0 ? '+' : '−';
      this.showGestureHint(formatTime(target) + '  ' + sign + formatTime(Math.abs(deltaMs)),
        this.durationMs > 0 ? target / this.durationMs : 0);
      return;
    }

    // 纵向：整屏高度对应 100% 的变化量（从下往上滑 = 变大）
    const delta: number = -dy / this.areaHeight;
    const v: number = this.clamp01(this.gestureBaseValue + delta);
    if (this.gestureOnRightHalf) {
      this.applyVolume(v);
      this.showGestureHint('音量 ' + Math.round(v * 100).toString() + '%', v);
    } else {
      // 左半屏调"亮度"：用色调里的亮度参数实现（播放器拿不到系统亮度，
      // 而色调亮度是逐像素运算，效果等价且不需要任何权限）
      const pct: number = Math.round(v * 100);
      this.colBrightness = pct < -100 ? -100 : (pct > 100 ? 100 : pct);
      this.applyColorAdjust();
      this.showGestureHint('亮度 ' + formatSignedPercent(this.colBrightness), v);
    }
  }

  /** 手势结束：横滑在这里才真正 seek；竖滑落盘 */
  private handleGestureEnd(dx: number, dy: number): void {
    if (this.gestureMode === 1) {
      const spanMs: number = 6 * 60 * 1000;
      const target: number = this.clampToDuration(
        this.gestureBaseMs + Math.round(dx / this.areaWidth * spanMs));
      this.seekTo(target);
    } else if (this.gestureMode === 2) {
      if (this.gestureOnRightHalf) {
        this.persistVolume();
      } else {
        this.persistColorSettings();
      }
    }
    this.gestureMode = 0;
  }

  private clamp01(v: number): number {
    return v < 0 ? 0 : (v > 1 ? 1 : v);
  }

  private clampToDuration(ms: number): number {
    if (ms < 0) {
      return 0;
    }
    if (this.durationMs > 0 && ms > this.durationMs) {
      return this.durationMs;
    }
    return ms;
  }


  /** 倍速文本：1.0 → "1.0x"，1.25 → "1.25x" */
  private speedLabel(v: number): string {
    return v.toString() + 'x';
  }

  /**
   * 把速度推给当前通道
   *
   * 软解：直接给倍率，引擎按比例重采样音频（画面跟着音频时钟走）。
   * 系统 AVPlayer：只有枚举里的几档，取最接近的一档。
   */
  private applySpeed(v: number): void {
    this.speed = v;
    if (this.usingSoft) {
      this.softCtl?.setSpeed(v);
      return;
    }
    const p = this.player;
    if (p !== undefined) {
      try {
        p.setSpeed(this.avSpeedOf(v));
      } catch (err) {
        this.trackNotice = '系统解码通道不支持该倍速';
      }
    }
  }

  /** 取系统通道最接近的倍速档（枚举只有 0.75/1.0/1.25/1.75/2.0 这几档） */
  private avSpeedOf(v: number): media.PlaybackSpeed {
    if (v <= 0.85) {
      return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    }
    if (v <= 1.12) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    }
    if (v <= 1.37) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    }
    if (v <= 1.87) {
      return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    }
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  }

  /** 选择档位（面板里点一下） */
  private chooseSpeed(v: number): void {
    this.applySpeed(v);
    this.writeDiag('倍速=' + this.speedLabel(v) + ' 通道=' + (this.usingSoft ? 'soft' : 'avplayer'));
  }

  /** 长按开始：临时加速（不写 @State.speed，松手要还原） */
  private enterTempSpeed(): void {
    const target: number = (this.speed < TEMP_SPEED_LOW) ? TEMP_SPEED_LOW : TEMP_SPEED_HIGH;
    if (this.usingSoft) {
      this.softCtl?.setSpeed(target);
    } else if (this.player !== undefined) {
      try {
        this.player.setSpeed(this.avSpeedOf(target));
      } catch (err) {
        return;
      }
    }
    this.tempSpeedActive = true;
  }

  /** 长按结束：还原到用户选定的速度 */
  private exitTempSpeed(): void {
    if (!this.tempSpeedActive) {
      return;
    }
    this.tempSpeedActive = false;
    if (this.usingSoft) {
      this.softCtl?.setSpeed(this.speed);
    } else if (this.player !== undefined) {
      try {
        this.player.setSpeed(this.avSpeedOf(this.speed));
      } catch (err) {
        // 还原失败不用打扰用户：下一次点档位会重新设置
      }
    }
  }


  /* ==================== 色调 / 均衡器：状态与应用 ==================== */

  /** 取第 i 项色调参数（0 亮度 1 对比度 2 饱和度 3 色彩度 4 红 5 绿 6 蓝） */
  private colorValue(i: number): number {
    if (i === 0) { return this.colBrightness; }
    if (i === 1) { return this.colContrast; }
    if (i === 2) { return this.colSaturation; }
    if (i === 3) { return this.colHue; }
    if (i === 4) { return this.colRGain; }
    if (i === 5) { return this.colGGain; }
    return this.colBGain;
  }

  /** 写入第 i 项色调参数（只改内存，不落盘） */
  private setColorValueLocal(i: number, v: number): void {
    const c: number = v < -100 ? -100 : (v > 100 ? 100 : v);
    if (i === 0) { this.colBrightness = c; }
    else if (i === 1) { this.colContrast = c; }
    else if (i === 2) { this.colSaturation = c; }
    else if (i === 3) { this.colHue = c; }
    else if (i === 4) { this.colRGain = c; }
    else if (i === 5) { this.colGGain = c; }
    else { this.colBGain = c; }
  }

  /** 是否有任何一项色调不为 0（按钮亮暗与"重置"是否可用都看它） */
  private colorAdjusted(): boolean {
    return this.colBrightness !== 0 || this.colContrast !== 0 || this.colSaturation !== 0
      || this.colHue !== 0 || this.colRGain !== 0 || this.colGGain !== 0 || this.colBGain !== 0;
  }

  /**
   * 把当前七项色调推给引擎（软解通道）
   *
   * 只有软解通道能改画面：AVPlayer 的画面由系统渲染，播放器拿不到像素，
   * 所以那条路上这里会静默无效 —— 打开面板时会给出明确提示（见 toggleColorPanel）。
   */
  private applyColorAdjust(): void {
    this.softCtl?.setColorAdjust(this.colBrightness, this.colContrast, this.colSaturation,
      this.colHue, this.colRGain, this.colGGain, this.colBGain);
  }

  /** 拖动中的实时应用（不落盘）+ 松手时落盘 */
  private onColorChanged(i: number, v: number, persist: boolean): void {
    this.setColorValueLocal(i, Math.round(v));
    this.applyColorAdjust();
    if (persist) {
      this.persistColorSettings();
      this.writeDiag('色调 ms=' + this.colBrightness.toString() + '/' + this.colContrast.toString()
        + '/' + this.colSaturation.toString() + '/' + this.colHue.toString()
        + '/' + this.colRGain.toString() + '/' + this.colGGain.toString()
        + '/' + this.colBGain.toString());
    }
  }

  /** 七项色调写进设置文件（下次打开自动生效） */
  private persistColorSettings(): void {
    const s: AppSettings | undefined = this.settings;
    if (s === undefined) {
      return;
    }
    s.update({
      colorBrightness: this.colBrightness,
      colorContrast: this.colContrast,
      colorSaturation: this.colSaturation,
      colorHue: this.colHue,
      colorRGain: this.colRGain,
      colorGGain: this.colGGain,
      colorBGain: this.colBGain
    } as SettingsPatch);
  }

  /** 七项全部归零 */
  private resetColorAdjust(): void {
    this.colBrightness = 0;
    this.colContrast = 0;
    this.colSaturation = 0;
    this.colHue = 0;
    this.colRGain = 0;
    this.colGGain = 0;
    this.colBGain = 0;
    this.applyColorAdjust();
    this.persistColorSettings();
    this.writeDiag('色调已重置');
  }

  /** 当前生效的 10 段增益（就是手调数组；预置选中时它已被写成预置的曲线） */
  private eqGains(): number[] {
    return this.eqBands;
  }

  /**
   * 手动调某一频段
   *
   * 一旦手调，预置名立刻变成"自定义" —— 因为这条曲线已经不等于任何预置了，
   * 名字还挂着"超重低音"会让用户以为选错了。
   * 落盘只在松手时做（拖动过程每帧写文件会把 UI 线程写满）。
   */
  private setEqBand(i: number, db: number, persist: boolean): void {
    // ★ 必须换一份新数组：@State 对数组是引用比较，原地改不会触发重绘
    const next: number[] = this.eqBands.slice();
    next[i] = Math.round(db);
    this.eqBands = next;
    this.eqPresetName = EQ_CUSTOM_NAME;
    // 手调等于"我要用它"，顺手把开关打开
    this.eqEnabled = true;
    this.applyAudioEq();
    if (persist) {
      const s: AppSettings | undefined = this.settings;
      if (s !== undefined) {
        s.update({
          eqEnabled: this.eqEnabled,
          eqPreset: this.eqPresetName,
          eqBands: this.eqBands
        } as SettingsPatch);
      }
      this.writeDiag('均衡器手调 第' + i.toString() + '段=' + db.toString() + 'dB 曲线='
        + this.eqBands.join(','));
    }
  }

  /**
   * 应用一个色调预设（面板最下方那一排）
   *
   * 直接写七项 @State，滑块会跟着动 —— 用户能立刻看到"这个预设到底改了什么"。
   */
  private chooseColorPreset(p: ColorPreset): void {
    this.colBrightness = p.bri;
    this.colContrast = p.con;
    this.colSaturation = p.sat;
    this.colHue = p.hue;
    this.colRGain = p.r;
    this.colGGain = p.g;
    this.colBGain = p.b;
    this.applyColorAdjust();
    this.persistColorSettings();
    this.writeDiag('色调预设=' + p.name);
  }

  /** 当前是否正好等于某个预设（用于把那一项高亮） */
  private colorPresetActive(p: ColorPreset): boolean {
    return this.colBrightness === p.bri && this.colContrast === p.con
      && this.colSaturation === p.sat && this.colHue === p.hue
      && this.colRGain === p.r && this.colGGain === p.g && this.colBGain === p.b;
  }

  /** 把均衡器状态推给引擎 */
  private applyAudioEq(): void {
    // ★ 必须手工拷成**普通数组**再传 ★
    //
    //   2026-10-04 真机抓到的坑：eqBands 是 @State 数组，ArkTS 会给它套一层
    //   观察者代理；把代理直接传到 NAPI 时 napi_is_array 返回 false，
    //   原生侧于是按"全 0"处理 —— 界面显示 eq=true、曲线也对，
    //   但引擎日志是「0 段非平坦 | 曲线=0,0,...,0」，声音完全没变。
    //   （之前选预置能生效，是因为那条路径传的是 gains.slice() 出来的普通数组。）
    //   这里逐项 push 出一个干净的 number[]，不依赖 slice 对代理的行为。
    const plain: number[] = [];
    for (let i = 0; i < 10; i++) {
      plain.push(i < this.eqBands.length ? this.eqBands[i] : 0);
    }
    this.softCtl?.setAudioEq(this.eqEnabled, plain);
  }

  /** 选择预置：立即生效并落盘 */
  private chooseEqPreset(name: string): void {
    const p: EqPreset | undefined = findEqPresetOrUndefined(name);
    if (p === undefined) {
      return;
    }
    this.eqPresetName = name;
    // 预置名 → 曲线：之后手调是以这条曲线为起点继续改
    this.eqBands = p.gains.slice();
    // 选预置天然意味着"我要用它"，顺手把总开关打开 ——
    // 否则用户点了预置却听不出变化，会以为功能坏了
    this.eqEnabled = true;
    this.applyAudioEq();
    const s: AppSettings | undefined = this.settings;
    if (s !== undefined) {
      s.update({
        eqEnabled: this.eqEnabled,
        eqPreset: this.eqPresetName,
        eqBands: this.eqBands
      } as SettingsPatch);
    }
    this.writeDiag('均衡器预置=' + name + ' 开启=' + this.eqEnabled.toString());
  }

  /** 开关均衡器 */
  private setEqEnabled(on: boolean): void {
    this.eqEnabled = on;
    this.applyAudioEq();
    const s: AppSettings | undefined = this.settings;
    if (s !== undefined) {
      s.update({ eqEnabled: on } as SettingsPatch);
    }
    this.writeDiag('均衡器开关=' + on.toString() + ' 预置=' + this.eqPresetName);
  }

  /**
   * 打开「色调」面板
   *
   * 走系统解码的文件会明确告知"调色只在软解生效"：这类提示必须有 ——
   * 用户拖了半天滑块画面没变化，最需要知道的就是"为什么"。
   */
  private toggleColorPanel(): void {
    if (this.showColorPanel) {
      this.closePanels();
      return;
    }
    if (!this.usingSoft) {
      this.trackNotice = '当前用系统解码播放，色调调整只在软解通道生效';
    } else {
      this.trackNotice = '';
    }
    this.openPanel(1);
    this.noteControlsActivity();
  }

  /** 打开「均衡器」面板（同样只对软解有效） */
  private toggleEqPanel(): void {
    if (this.showEqPanel) {
      this.closePanels();
      return;
    }
    if (!this.usingSoft) {
      this.trackNotice = '当前用系统解码播放，均衡器只在软解通道生效';
    } else {
      this.trackNotice = '';
    }
    this.openPanel(2);
    this.noteControlsActivity();
  }

  /**
   * 这次快照位置是不是"seek 还没生效时的旧值"
   * 判据（两个条件同时成立才算旧值）：
   *   ① 距上次发起 seek 还在 SEEK_SETTLE_MS 之内；
   *   ② 快照位置与 seek 目标相差超过 3 秒 —— 引擎真的跳过去之后，
   *      位置会在目标附近（关键帧最多落在目标前一个 GOP），不会再差 3 秒。
   * 超时后自动放行，不依赖引擎回报任何"seek 完成"事件，
   * 所以即使 seek 失败，界面也只是多停 3 秒就会继续跟随真实进度。
   */
  private isStalePositionAfterSeek(pos: number): boolean {
    if (this.seekIssuedTo < 0) {
      return false;
    }
    if (Date.now() - this.seekIssuedAt > SEEK_SETTLE_MS) {
      this.seekIssuedTo = -1;   // 窗口结束，恢复正常的进度回写
      return false;
    }
    return Math.abs(pos - this.seekIssuedTo) > 3000;
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
      this.setTrackPanel(false);
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
    this.setTrackPanel(true);
    // 打开面板时把控制层的倒计时推后：关掉面板后控制栏还在，用户不用再点一次
    this.noteControlsActivity();
  }

  /**
   * 打开 / 关闭音轨字幕面板（带弹出动画）
   *
   * ★ 2026-10-04：面板改成"全屏时从屏幕右侧滑出"之后，显隐**必须走这里** ——
   *   ArkUI 的 .transition() 只在显式动画（animateTo）里才会播放；
   *   直接改 @State 是瞬间出现/消失，用户看到的是"啪一下蹦出来"，
   *   完全没有"从右侧弹出"的感觉。
   */
  private setTrackPanel(open: boolean): void {
    if (!open) {
      this.closePanels();
      return;
    }
    if (this.showTrackPanel) {
      return;
    }
    this.openPanel(0);
  }

  /**
   * 打开某一个右侧抽屉（0=音轨字幕 1=色调 2=均衡器），互斥
   *
   * 三个面板共用同一套"全屏从右侧滑出 / 竖屏从底部滑上"的容器
   * （见 build() 里那段 if/else），所以切换时必须**互相排除**，
   * 否则会出现两层遮罩叠在一起、点一下只关掉一层的怪现象。
   */
  /**
   * 打开某一个右侧抽屉（0=音轨字幕 1=色调 2=均衡器 3=倍速），互斥
   *
   * 四个面板共用同一套"全屏从右侧滑出 / 竖屏从底部滑上"的容器
   * （见 build() 里那段 if/else），所以切换时必须**互相排除**，
   * 否则会出现两层遮罩叠在一起、点一下只关掉一层的怪现象。
   */
  private openPanel(which: number): void {
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, () => {
      this.showTrackPanel = (which === 0);
      this.showColorPanel = (which === 1);
      this.showEqPanel = (which === 2);
      this.showSpeedPanel = (which === 3);
    });
  }

  /** 关闭所有抽屉（点遮罩、点 ✕、再点一次按钮都走这里） */
  private closePanels(): void {
    if (!this.anyPanelOpen()) {
      return;
    }
    this.getUIContext().animateTo({ duration: 220, curve: Curve.Friction }, () => {
      this.showTrackPanel = false;
      this.showColorPanel = false;
      this.showEqPanel = false;
      this.showSpeedPanel = false;
    });
  }

  /** 是否有任意抽屉开着（控制层自动隐藏要避开它） */
  private anyPanelOpen(): boolean {
    return this.showTrackPanel || this.showColorPanel || this.showEqPanel
      || this.showSpeedPanel;
  }

  /** 打开/关闭「倍速」抽屉 */
  private toggleSpeedPanel(): void {
    if (this.showSpeedPanel) {
      this.closePanels();
      return;
    }
    this.trackNotice = '';
    this.openPanel(3);
    this.noteControlsActivity();
  }

  /**
   * 面板内字号：全屏（横屏）时抽屉只占 1/3 屏宽，字号要跟着收一点
   *
   * 规则：按 0.85 缩放，但**下限 11vp** —— 实测 11vp 在 2832x1280 的横屏上
   * 仍能看清并准确点中（列表项整行可点，不依赖精确命中），而再小就会出现
   * "看不清是哪条轨道"的问题。竖屏（底部半屏面板）宽度充足，字号不动。
   */
  private panelFont(base: number): number {
    if (!this.isLandscape) {
      return base;
    }
    return Math.max(11, Math.round(base * 0.85));
  }

  /** 面板内边距：全屏时同步收紧（20→14、12→8），给窄抽屉腾出可用宽度 */
  private panelPad(base: number): number {
    return this.isLandscape ? Math.max(6, Math.round(base * 0.7)) : base;
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
          .fontSize(this.panelFont(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
        Text('✕')
          .fontSize(this.panelFont(18))
          .fontColor('rgba(255,255,255,0.70)')
          .padding(8)
          .onClick(() => {
            this.setTrackPanel(false);
          })
      }
      .width('100%')
      .padding({
        left: this.panelPad(20), right: this.panelPad(12),
        top: this.panelPad(14), bottom: this.panelPad(10)
      })

      // ---- 操作提示 ----
      if (this.trackNotice.length > 0) {
        Text(this.trackNotice)
          .fontSize(this.panelFont(12))
          .fontColor(Theme.ACCENT)
          .width('100%')
          .padding({ left: this.panelPad(20), right: this.panelPad(20), bottom: this.panelPad(8) })
      }

      List({ space: 0 }) {
        // ============ 音轨 ============
        ListItem() {
          Text('音轨')
            .fontSize(this.panelFont(12))
            .fontColor('rgba(255,255,255,0.50)')
            .width('100%')
            .padding({ left: this.panelPad(20), top: this.panelPad(6), bottom: this.panelPad(6) })
        }

        if (this.audioTracks.length === 0) {
          ListItem() {
            Text('当前文件没有可切换的音轨')
              .fontSize(this.panelFont(13))
              .fontColor('rgba(255,255,255,0.45)')
              .width('100%')
              .padding({ left: this.panelPad(20), top: this.panelPad(10), bottom: this.panelPad(10) })
          }
        }
        ForEach(this.audioTracks, (t: SoftAudioTrack, i: number) => {
          ListItem() {
            Row({ space: this.panelPad(10) }) {
              Text(this.currentAudioIndex === t.index ? '●' : '○')
                .fontSize(this.panelFont(14))
                .fontColor(this.currentAudioIndex === t.index
                  ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
              Text(this.audioTrackLabel(t, i))
                .fontSize(this.panelFont(13))
                .fontColor(Color.White)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({
              left: this.panelPad(20), right: this.panelPad(20),
              top: this.panelPad(12), bottom: this.panelPad(12)
            })
            .onClick(() => {
              this.chooseAudioTrack(t.index);
            })
          }
        }, (t: SoftAudioTrack) => 'a' + t.index.toString())

        // ============ 字幕 ============
        ListItem() {
          Text('字幕')
            .fontSize(this.panelFont(12))
            .fontColor('rgba(255,255,255,0.50)')
            .width('100%')
            .padding({ left: this.panelPad(20), top: this.panelPad(14), bottom: this.panelPad(6) })
        }

        // 「关闭字幕」永远在第一项：用户想关字幕时不该还要先找
        ListItem() {
          Row({ space: this.panelPad(10) }) {
            Text((this.currentSubtitleIndex < 0 && !this.usingExternalSubtitle)
              ? '●' : '○')
              .fontSize(this.panelFont(14))
              .fontColor((this.currentSubtitleIndex < 0 && !this.usingExternalSubtitle)
                ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
            Text('关闭字幕')
              .fontSize(this.panelFont(13))
              .fontColor(Color.White)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({
            left: this.panelPad(20), right: this.panelPad(20),
            top: this.panelPad(12), bottom: this.panelPad(12)
          })
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
            Row({ space: this.panelPad(10) }) {
              Text((this.currentSubtitleIndex === t.index && !this.usingExternalSubtitle)
                ? '●' : '○')
                .fontSize(this.panelFont(14))
                .fontColor((this.currentSubtitleIndex === t.index
                  && !this.usingExternalSubtitle)
                  ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
              Text('内嵌 · ' + this.subtitleTrackLabel(t, i))
                .fontSize(this.panelFont(13))
                .fontColor(t.supported ? Color.White : 'rgba(255,255,255,0.42)')
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({
              left: this.panelPad(20), right: this.panelPad(20),
              top: this.panelPad(12), bottom: this.panelPad(12)
            })
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
            Row({ space: this.panelPad(10) }) {
              Text((this.usingExternalSubtitle && this.externalSubtitleName === c.name)
                ? '●' : '○')
                .fontSize(this.panelFont(14))
                .fontColor((this.usingExternalSubtitle
                  && this.externalSubtitleName === c.name)
                  ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
              Text('外挂 · ' + c.name)
                .fontSize(this.panelFont(13))
                .fontColor(Color.White)
                .layoutWeight(1)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({
              left: this.panelPad(20), right: this.panelPad(20),
              top: this.panelPad(12), bottom: this.panelPad(12)
            })
            .onClick(() => {
              this.useSidecarSubtitle(c);
            })
          }
        }, (c: SubtitleCandidate) => 'x' + c.path)

        // 手动选外挂字幕文件
        ListItem() {
          Text('＋ 从文件选择外挂字幕…')
            .fontSize(this.panelFont(13))
            .fontColor(Theme.ACCENT)
            .width('100%')
            .padding({
              left: this.panelPad(20), right: this.panelPad(20),
              top: this.panelPad(14), bottom: this.panelPad(14)
            })
            .onClick(() => {
              this.pickExternalSubtitle();
            })
        }

        // 关闭外挂字幕（仅在启用时出现）
        if (this.usingExternalSubtitle) {
          ListItem() {
            Text('关闭外挂字幕')
              .fontSize(this.panelFont(13))
              .fontColor('rgba(255,255,255,0.70)')
              .width('100%')
              .padding({
                left: this.panelPad(20), right: this.panelPad(20),
                top: this.panelPad(12), bottom: this.panelPad(20)
              })
              .onClick(() => {
                this.disableExternalSubtitle();
              })
          }
        }
      }
      // ★ 全屏（右侧抽屉）：用 layoutWeight(1) 撑满抽屉剩余高度，内部滚动。
      //   竖屏（底部面板）：layoutWeight(0)（默认）按内容高度，上限 420 ——
      //   轨道少时不留大片空白，多时内部滚动。
      //   注意不能在竖屏也用 layoutWeight(1)：竖屏面板是"包裹内容"的高度，
      //   加权子节点在无固定高度父容器里会被压成 0，列表就整块消失了。
      .width('100%')
      .layoutWeight(this.isLandscape ? 1 : 0)
      .constraintSize({ maxHeight: this.isLandscape ? '100%' : 420 })
    }
    // ★ 全屏：贴右侧、占 33% 屏宽、满高，左侧两角圆角（右角是屏幕边缘，不用圆）
    //   竖屏：原来的底部半屏面板（整宽 + 上方两角圆角）
    .width(this.isLandscape ? '33%' : '100%')
    // 全屏：满高抽屉；竖屏：'auto' 即按内容高度（不能写 undefined，
    // ArkTS 的 Length 不接受 undefined，会直接编译失败）
    .height(this.isLandscape ? '100%' : 'auto')
    .backgroundColor('#F21A1A1E')
    .borderRadius(this.isLandscape
      ? { topLeft: 18, bottomLeft: 18 }
      : { topLeft: 18, topRight: 18 })
    .padding({ bottom: this.panelPad(12) })
    // 弹出方向：全屏从右侧滑入（位移量 = 抽屉宽度 + 余量），竖屏从底部滑入
    .transition(TransitionEffect.translate({
      x: this.isLandscape ? (this.areaWidth / 3 + 24) : 0,
      y: this.isLandscape ? 0 : 520
    }).animation({ duration: 220, curve: Curve.Friction }))
  }

  /**
   * 抽屉外壳（三个面板共用）
   *
   * 为什么抽出来：色调 / 均衡器 / 音轨字幕三个面板的**外壳完全相同**
   * （宽度、圆角、背景、滑入方向），只有内容不同。ArkUI 的 @Builder
   * 不能把"另一个 @Builder"当参数传，所以这里用三个独立的 if 分支
   * 各自套同一套属性 —— 属性值全部来自 panelWidth() 等小函数，
   * 三处保持一致（改尺寸只改那几个函数）。
   */
  private panelWidth(): string {
    return this.isLandscape ? '33%' : '100%';
  }

  private panelHeight(): string {
    return this.isLandscape ? '100%' : 'auto';
  }

  /** 「色调」面板：七项滑块 + 重置 */
  @Builder
  ColorPanel() {
    Column({ space: 0 }) {
      Row() {
        Text('色调')
          .fontSize(this.panelFont(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
        Text('重置')
          .fontSize(this.panelFont(13))
          .fontColor(this.colorAdjusted() ? Theme.ACCENT : 'rgba(255,255,255,0.35)')
          .padding(8)
          .onClick(() => {
            this.resetColorAdjust();
          })
        Text('✕')
          .fontSize(this.panelFont(18))
          .fontColor('rgba(255,255,255,0.70)')
          .padding(8)
          .onClick(() => {
            this.closePanels();
          })
      }
      .width('100%')
      .padding({
        left: this.panelPad(20), right: this.panelPad(12),
        top: this.panelPad(14), bottom: this.panelPad(6)
      })

      if (this.trackNotice.length > 0) {
        Text(this.trackNotice)
          .fontSize(this.panelFont(12))
          .fontColor(Theme.ACCENT)
          .width('100%')
          .padding({ left: this.panelPad(20), right: this.panelPad(20), bottom: this.panelPad(8) })
      }

      // 七项：亮度 / 对比度 / 饱和度 / 色彩度 / 红 / 绿 / 蓝
      //
      // 为什么用"滑块 + 百分比"而不是参考图里的「-1% / +1%」两行：
      //   功能完全一样（步长就是 1%），但滑块可以一次拖到位 ——
      //   参考图那套要连点几十次才能看出变化，在手机全屏下不好用。
      //   数值实时显示成 ±N%，等价于参考图里的百分比读数。
      List({ space: 0 }) {
        ForEach(COLOR_ROW_LABELS, (label: string, i: number) => {
          ListItem() {
            Column({ space: 0 }) {
              Row() {
                Text(label)
                  .fontSize(this.panelFont(13))
                  .fontColor(Color.White)
                  .layoutWeight(1)
                Text(formatSignedPercent(this.colorValue(i)))
                  .fontSize(this.panelFont(12))
                  .fontColor(this.colorValue(i) === 0 ? 'rgba(255,255,255,0.45)' : Theme.ACCENT)
              }
              .width('100%')

              Slider({
                value: this.colorValue(i),
                min: -100,
                max: 100,
                step: 1,
                style: SliderStyle.OutSet
              })
                .width('100%')
                .height(this.isLandscape ? 24 : 30)
                .blockColor(Color.White)
                .trackColor('rgba(255,255,255,0.25)')
                .selectedColor(Theme.ACCENT)
                .onChange((v: number, mode: SliderChangeMode) => {
                  // 拖动中实时生效（不落盘），松手/点击才写设置文件 ——
                  // 与进度条同一套约定：拖动过程每帧都落盘会把 UI 线程写满
                  const settled: boolean = (mode === SliderChangeMode.End
                    || mode === SliderChangeMode.Click);
                  this.onColorChanged(i, v, settled);
                })
            }
            .width('100%')
            .padding({
              left: this.panelPad(20), right: this.panelPad(20),
              top: this.panelPad(8), bottom: this.panelPad(8)
            })
          }
        }, (label: string) => 'c' + label)
      }
      .width('100%')
      .layoutWeight(this.isLandscape ? 1 : 0)
      .constraintSize({ maxHeight: this.isLandscape ? '100%' : 460 })

      // ---- 预设（用户要求放在最下方）----
      //
      // 用 Flex 换行而不是横向滚动条：抽屉只有 1/3 屏宽，
      // 换行排两行就能放下 9 个，而且所有预设一眼可见、点一下就到位，
      // 比"要滑才看得到后面几个"更省事。
      Text('预设')
        .fontSize(this.panelFont(12))
        .fontColor('rgba(255,255,255,0.50)')
        .width('100%')
        .padding({
          left: this.panelPad(20), top: this.panelPad(10), bottom: this.panelPad(6)
        })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(COLOR_PRESETS, (p: ColorPreset) => {
          Text(p.name)
            .fontSize(this.panelFont(12))
            .fontColor(this.colorPresetActive(p) ? Theme.ACCENT : Color.White)
            .padding({
              left: this.panelPad(12), right: this.panelPad(12),
              top: this.panelPad(6), bottom: this.panelPad(6)
            })
            .borderRadius(12)
            .backgroundColor(this.colorPresetActive(p)
              ? 'rgba(0,125,255,0.28)' : 'rgba(255,255,255,0.14)')
            .margin({
              right: this.panelPad(8), bottom: this.panelPad(8)
            })
            .onClick(() => {
              this.chooseColorPreset(p);
            })
        }, (p: ColorPreset) => 'cp' + p.name)
      }
      .width('100%')
      .padding({ left: this.panelPad(20), right: this.panelPad(12) })

      Text('提示：色调只作用于软解通道的画面')
        .fontSize(this.panelFont(11))
        .fontColor('rgba(255,255,255,0.40)')
        .width('100%')
        .padding({
          left: this.panelPad(20), right: this.panelPad(20),
          top: this.panelPad(2), bottom: this.panelPad(8)
        })
    }
    .width(this.panelWidth())
    .height(this.panelHeight())
    .backgroundColor('#F21A1A1E')
    .borderRadius(this.isLandscape
      ? { topLeft: 18, bottomLeft: 18 }
      : { topLeft: 18, topRight: 18 })
    .padding({ bottom: this.panelPad(12) })
    .transition(TransitionEffect.translate({
      x: this.isLandscape ? (this.areaWidth / 3 + 24) : 0,
      y: this.isLandscape ? 0 : 520
    }).animation({ duration: 220, curve: Curve.Friction }))
  }

  /** 「均衡器」面板：开关 + 预置列表 + 频段可视化 */
  @Builder
  EqPanel() {
    Column({ space: 0 }) {
      Row() {
        Text('均衡器')
          .fontSize(this.panelFont(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
        Text('✕')
          .fontSize(this.panelFont(18))
          .fontColor('rgba(255,255,255,0.70)')
          .padding(8)
          .onClick(() => {
            this.closePanels();
          })
      }
      .width('100%')
      .padding({
        left: this.panelPad(20), right: this.panelPad(12),
        top: this.panelPad(14), bottom: this.panelPad(6)
      })

      if (this.trackNotice.length > 0) {
        Text(this.trackNotice)
          .fontSize(this.panelFont(12))
          .fontColor(Theme.ACCENT)
          .width('100%')
          .padding({ left: this.panelPad(20), right: this.panelPad(20), bottom: this.panelPad(8) })
      }

      // ---- 总开关 ----
      Row() {
        Text('开启均衡器')
          .fontSize(this.panelFont(13))
          .fontColor(Color.White)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.eqEnabled })
          .selectedColor(Theme.ACCENT)
          .onChange((on: boolean) => {
            this.setEqEnabled(on);
          })
      }
      .width('100%')
      .padding({
        left: this.panelPad(20), right: this.panelPad(20),
        top: this.panelPad(4), bottom: this.panelPad(8)
      })

      // ---- 手动调节：10 段竖向滑块（2026-10-04 新增）----
      //
      // 为什么用竖向滑块而不是横向列表：
      //   均衡器的本质就是"一条曲线"，10 根柱子并排摆出来，
      //   当前曲线一眼可见、哪一段在动也一目了然 —— 和器材上的图形均衡器一致。
      //   横向 10 行滑块在 1/3 屏宽的抽屉里放不下，也没有曲线的形状感。
      Text('手动调节')
        .fontSize(this.panelFont(12))
        .fontColor('rgba(255,255,255,0.50)')
        .width('100%')
        .padding({
          left: this.panelPad(20), top: this.panelPad(10), bottom: this.panelPad(6)
        })

      Row() {
        ForEach(EQ_FREQ_LABELS, (f: string, i: number) => {
          Column({ space: this.panelPad(4) }) {
            Slider({
              value: this.eqBands[i],
              min: -12,
              max: 12,
              step: 1,
              style: SliderStyle.OutSet,
              direction: Axis.Vertical
            })
              .width(this.isLandscape ? 22 : 30)
              .height(this.isLandscape ? 92 : 120)
              .blockColor(Color.White)
              .trackColor('rgba(255,255,255,0.25)')
              .selectedColor(Theme.ACCENT)
              .onChange((v: number, mode: SliderChangeMode) => {
                // 拖动中实时生效（不落盘），松手才写设置文件
                const settled: boolean = (mode === SliderChangeMode.End
                  || mode === SliderChangeMode.Click);
                this.setEqBand(i, v, settled);
              })

            Text(f)
              .fontSize(this.panelFont(10))
              .fontColor('rgba(255,255,255,0.55)')
          }
          .layoutWeight(1)
        }, (f: string) => 'band' + f)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: this.panelPad(12), right: this.panelPad(12) })

      Text('当前：' + this.eqPresetName + '（拖动任一频段即变为自定义）')
        .fontSize(this.panelFont(11))
        .fontColor('rgba(255,255,255,0.55)')
        .width('100%')
        .padding({
          left: this.panelPad(20), right: this.panelPad(20), top: this.panelPad(6)
        })

      // ---- 预置列表 ----
      List({ space: 0 }) {
        ListItem() {
          Text('预置')
            .fontSize(this.panelFont(12))
            .fontColor('rgba(255,255,255,0.50)')
            .width('100%')
            .padding({
              left: this.panelPad(20), top: this.panelPad(10), bottom: this.panelPad(6)
            })
        }

        ForEach(EQUALIZER_PRESETS, (p: EqPreset) => {
          ListItem() {
            Row({ space: this.panelPad(10) }) {
              Text(this.eqPresetName === p.name ? '●' : '○')
                .fontSize(this.panelFont(14))
                .fontColor(this.eqPresetName === p.name
                  ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
              Text(p.name)
                .fontSize(this.panelFont(13))
                .fontColor(Color.White)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({
              left: this.panelPad(20), right: this.panelPad(20),
              top: this.panelPad(10), bottom: this.panelPad(10)
            })
            .onClick(() => {
              this.chooseEqPreset(p.name);
            })
          }
        }, (p: EqPreset) => 'eqp' + p.name)
      }
      .width('100%')
      .layoutWeight(this.isLandscape ? 1 : 0)
      .constraintSize({ maxHeight: this.isLandscape ? '100%' : 460 })

      Text('提示：均衡器只作用于软解通道的声音')
        .fontSize(this.panelFont(11))
        .fontColor('rgba(255,255,255,0.40)')
        .width('100%')
        .padding({
          left: this.panelPad(20), right: this.panelPad(20),
          top: this.panelPad(6), bottom: this.panelPad(8)
        })
    }
    .width(this.panelWidth())
    .height(this.panelHeight())
    .backgroundColor('#F21A1A1E')
    .borderRadius(this.isLandscape
      ? { topLeft: 18, bottomLeft: 18 }
      : { topLeft: 18, topRight: 18 })
    .padding({ bottom: this.panelPad(12) })
    .transition(TransitionEffect.translate({
      x: this.isLandscape ? (this.areaWidth / 3 + 24) : 0,
      y: this.isLandscape ? 0 : 520
    }).animation({ duration: 220, curve: Curve.Friction }))
  }

  /** 「倍速」面板：档位列表 + 长按加速说明 */
  @Builder
  SpeedPanel() {
    Column({ space: 0 }) {
      Row() {
        Text('倍速')
          .fontSize(this.panelFont(16))
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
        Text('✕')
          .fontSize(this.panelFont(18))
          .fontColor('rgba(255,255,255,0.70)')
          .padding(8)
          .onClick(() => {
            this.closePanels();
          })
      }
      .width('100%')
      .padding({
        left: this.panelPad(20), right: this.panelPad(12),
        top: this.panelPad(14), bottom: this.panelPad(6)
      })

      List({ space: 0 }) {
        ForEach(SPEED_OPTIONS, (v: number) => {
          ListItem() {
            Row({ space: this.panelPad(10) }) {
              Text(this.speed === v ? '●' : '○')
                .fontSize(this.panelFont(14))
                .fontColor(this.speed === v ? Theme.ACCENT : 'rgba(255,255,255,0.40)')
              Text(this.speedLabel(v) + (v === 1.0 ? '（原速）' : ''))
                .fontSize(this.panelFont(13))
                .fontColor(Color.White)
                .layoutWeight(1)
            }
            .width('100%')
            .padding({
              left: this.panelPad(20), right: this.panelPad(20),
              top: this.panelPad(12), bottom: this.panelPad(12)
            })
            .onClick(() => {
              this.chooseSpeed(v);
            })
          }
        }, (v: number) => 'sp' + v.toString())
      }
      .width('100%')
      .layoutWeight(this.isLandscape ? 1 : 0)
      .constraintSize({ maxHeight: this.isLandscape ? '100%' : 420 })

      Text('提示：长按画面可临时加速（松开还原）；'
        + (this.usingSoft ? '当前为软解通道' : '当前为系统解码通道，档位会取最接近的一档'))
        .fontSize(this.panelFont(11))
        .fontColor('rgba(255,255,255,0.40)')
        .width('100%')
        .padding({
          left: this.panelPad(20), right: this.panelPad(20),
          top: this.panelPad(6), bottom: this.panelPad(8)
        })
    }
    .width(this.panelWidth())
    .height(this.panelHeight())
    .backgroundColor('#F21A1A1E')
    .borderRadius(this.isLandscape
      ? { topLeft: 18, bottomLeft: 18 }
      : { topLeft: 18, topRight: 18 })
    .padding({ bottom: this.panelPad(12) })
    .transition(TransitionEffect.translate({
      x: this.isLandscape ? (this.areaWidth / 3 + 24) : 0,
      y: this.isLandscape ? 0 : 520
    }).animation({ duration: 220, curve: Curve.Friction }))
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
              // ★ 2026-10-03：字号与底衬来自「字幕设置」（默认 18px、底衬开）
              .fontSize(subtitleFontPx(this.cfg().subtitleFontSize))
              .fontColor(Color.White)
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              // 半透明底衬：白色字幕压在亮画面上会看不清，
              // 而描边在 ArkUI 里要配多个 Text 叠放，代价大于收益。
              // 关掉后字幕直接压在画面上（有些用户就是不喜欢那条黑底）。
              .backgroundColor(this.cfg().subtitleBackground
                ? 'rgba(0,0,0,0.45)' : 'rgba(0,0,0,0.0)')
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

      // ---------- 1.5 加载/缓冲指示（2026-10-03 新增） ----------
      //
      //   ⚠️ 位置很重要：**在视频层之上、控制层之下**。
      //     · 在视频层之上：才能盖住"还没画出来的黑屏"和预渲染的那一帧；
      //     · 在控制层之下：底部的进度条/按钮依然可点，用户能照常操作；
      //     · hitTestBehavior(Transparent)：不吃点击，"点画面显隐控制层"照旧生效。
      //   什么时候出现：① 已就绪但首帧还没上屏（起播等待）；
      //                ② 播放途中 900ms 没有任何位置更新（缺数据/解码跟不上）。
      if (this.buffering) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(46)
            .height(46)
            .color(Theme.ACCENT)
          Text('正在缓冲…')
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.85)')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        // 半透明底：既不彻底遮住画面（用户能看到"有画面了"），又能压住噪声
        .backgroundColor('rgba(0,0,0,0.35)')
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // ---------- 1.6 长按临时加速角标（2026-10-04 新增） ----------
      //
      //   "加速中"必须看得见：否则用户松手前后画面速度不同、又没有任何提示，
      //   只会以为播放器在抽风。角标放左上角（与顶栏返回键错开），
      //   同样不吃点击（Transparent），不影响"点画面显隐控制层"和长按判定。
      if (this.tempSpeedActive) {
        Text(this.speedLabel(this.speed < TEMP_SPEED_LOW ? TEMP_SPEED_LOW : TEMP_SPEED_HIGH))
          .fontSize(14)
          .fontColor(Color.White)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor('rgba(0,125,255,0.75)')
          .position({ x: 84, y: 96 })
          .hitTestBehavior(HitTestMode.Transparent)
      }

      // ---------- 1.7 手势提示（2026-10-04 新增） ----------
      //
      //   横滑显示目标时间与进度、竖滑显示音量/亮度百分比 —— 手势是"盲操作"，
      //   没有反馈用户不知道滑到哪了。整块 Transparent，不干扰手势本身。
      if (this.gestureHint.length > 0) {
        Column({ space: 8 }) {
          Text(this.gestureHint)
            .fontSize(15)
            .fontColor(Color.White)
          if (this.gestureBar >= 0) {
            Row() {
              Row()
                .width(Math.round(this.clamp01(this.gestureBar) * 160))
                .height(5)
                .backgroundColor(Theme.ACCENT)
                .borderRadius(3)
            }
            .width(160)
            .height(5)
            .backgroundColor('rgba(255,255,255,0.30)')
            .borderRadius(3)
            .justifyContent(FlexAlign.Start)
          }
        }
        .padding({ left: 18, right: 18, top: 12, bottom: 12 })
        .backgroundColor('rgba(0,0,0,0.62)')
        .borderRadius(12)
        .position({
          x: this.areaWidth / 2 - 100,
          y: this.areaHeight / 2 - 40
        })
        .width(200)
        .alignItems(HorizontalAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
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

                // ★ 2026-10-04 新增：倍速 / 色调 / 均衡器（用户要求放在全屏右下角）★
                //   没做调整时按钮是暗的（和音轨按钮同一套语义：暗 = 当前无效果），
                //   调过之后亮起，用户一眼能看出"画面/声音被我改过"。
                Text(this.speedLabel(this.speed))
                  .fontSize(13)
                  .fontColor(this.speed !== 1.0 ? Theme.ACCENT : Color.White)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .backgroundColor(this.speed !== 1.0
                    ? 'rgba(0,125,255,0.28)' : 'rgba(255,255,255,0.14)')
                  .margin({ right: 10 })
                  .onClick(() => {
                    this.toggleSpeedPanel();
                  })

                Text('色调')
                  .fontSize(13)
                  .fontColor(this.colorAdjusted() ? Theme.ACCENT : Color.White)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .backgroundColor(this.colorAdjusted()
                    ? 'rgba(0,125,255,0.28)' : 'rgba(255,255,255,0.14)')
                  .margin({ right: 10 })
                  .onClick(() => {
                    this.toggleColorPanel();
                  })

                Text('均衡器')
                  .fontSize(13)
                  .fontColor(this.eqEnabled ? Theme.ACCENT : Color.White)
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(14)
                  .backgroundColor(this.eqEnabled
                    ? 'rgba(0,125,255,0.28)' : 'rgba(255,255,255,0.14)')
                  .margin({ right: 10 })
                  .onClick(() => {
                    this.toggleEqPanel();
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

                // ★ 2026-10-04：倍速在竖屏也给入口 —— 它是基础播放控制，
                //   不该"只有全屏才能用"（竖屏第二行本来就有空位）
                Text(this.speedLabel(this.speed))
                  .fontSize(13)
                  .fontColor(this.speed !== 1.0 ? Theme.ACCENT : Color.White)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .borderRadius(14)
                  .backgroundColor(this.speed !== 1.0
                    ? 'rgba(0,125,255,0.28)' : 'rgba(255,255,255,0.14)')
                  .onClick(() => {
                    this.toggleSpeedPanel();
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
      // ★ 2026-10-04：长按画面 = 临时加速 ★
      //   理由见 onVideoTouch 的注释：这是全屏唯一可靠的触摸落点。
      .onTouch((event: TouchEvent) => {
        this.onVideoTouch(event);
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
      //
      // ★ 2026-10-04 改版（用户要求）：**全屏时从屏幕右侧弹出，只占 1/3 屏宽** ★
      //   全屏下画面是"宽而矮"，底部半屏面板会直接把画面中间切掉一大块，
      //   而且横向明明有富余宽度可用 —— 改成右侧抽屉正好利用这个形状：
      //     · 抽屉占 33% 屏宽、满高，画面左 2/3 完全不受遮挡；
      //     · 竖屏宽度紧张，仍然保持原来的底部半屏面板（体验更好）。
      //   遮罩只做透明度动画、面板自己做位移动画：两者都挂在同一次
      //   animateTo 里（见 setTrackPanel），所以看起来就是"遮罩渐暗 +
      //   面板从右侧滑入"。若把位移加在整层遮罩上，会看到一块黑边一起滑进来。
      if (this.anyPanelOpen()) {
        if (this.isLandscape) {
          Row() {
            // 左侧 2/3 是遮罩：点一下关闭面板（右侧抽屉留给面板本身）
            Column()
              .layoutWeight(1)
              .height('100%')
              .onClick(() => {
                this.closePanels();
              })

            if (this.showTrackPanel) {
              this.TrackPanel()
            } else if (this.showColorPanel) {
              this.ColorPanel()
            } else if (this.showEqPanel) {
              this.EqPanel()
            } else {
              this.SpeedPanel()
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.45)')
          .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
        } else {
          Column() {
            // 半透明遮罩：点空白处关闭面板（下方整块绑定 onClick）
            Column()
              .width('100%')
              .layoutWeight(1)
              .onClick(() => {
                this.closePanels();
              })

            if (this.showTrackPanel) {
              this.TrackPanel()
            } else if (this.showColorPanel) {
              this.ColorPanel()
            } else if (this.showEqPanel) {
              this.EqPanel()
            } else {
              this.SpeedPanel()
            }
          }
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.55)')
          .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // 根 Stack 不使用 expandSafeArea：它会影响 Stack 的布局区域判断，
    // 沉浸式已交给 XComponent，控制栏保持在安全区内。
  }
}
