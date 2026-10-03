/**
 * SoftPlayer 原生音视频解码库 —— ArkTS 接口声明
 *
 * ★ 重要：这里只声明【原生模块运行时真正导出】的东西。
 *   枚举、常量等需要在运行时存在的值，一律定义在
 *   model/SoftPlayerTypes.ets —— 因为 .d.ts 编译后会被擦除，
 *   在此声明 enum 会导致运行时 import 失败。
 *
 * 分层：
 *   SoftPlayer（本文件）  NAPI 绑定层，与解码器无关
 *        ↓
 *   IPlayerEngine        引擎抽象接口（C++）
 *        ↓
 *   FfmpegEngine         解码实现（待接入 FFmpeg）
 */

/** 原生线程投递上来的事件 */
export interface SoftPlayerEvent {
  type: number;
  data1: number;
  data2: number;
  text: string;
}

/** 一条可切换的音轨 */
export interface SoftAudioTrack {
  /** 容器里的流下标（传给 switchAudioTrack 用这个，不是"第几条"） */
  index: number;
  codec: string;
  language: string;
  title: string;
  channels: number;
  sampleRate: number;
  bitRate: number;
  isDefault: boolean;
}

/** 一条字幕轨 */
export interface SoftSubtitleTrack {
  index: number;
  codec: string;
  language: string;
  title: string;
  isDefault: boolean;
  /** false 表示位图字幕（PGS/VobSub），本播放器解不了 */
  supported: boolean;
}

/** 媒体信息 */
export interface SoftMediaInfo {
  durationMs: number;
  width: number;
  height: number;
  frameRate: number;
  videoCodec: string;
  audioCodec: string;
  hasVideo: boolean;
  hasAudio: boolean;
  /** 全部可切换音轨 */
  audioTracks: SoftAudioTrack[];
  /** 全部字幕轨（含不支持的图形字幕，靠 supported 区分） */
  subtitleTracks: SoftSubtitleTrack[];
  /** 当前生效的音轨流下标；-1 表示无 */
  currentAudioIndex: number;
  /** 当前生效的字幕轨流下标；-1 表示未启用 */
  currentSubtitleIndex: number;
}

/**
 * 原生播放器
 * 所有控制方法返回 0 表示成功，负数表示失败。
 * 状态变化通过 pollEvents() 取回。
 */
export class SoftPlayer {
  constructor();
  setSurface(surfaceId: string): number;
  /**
   * 解绑渲染 surface
   *
   * ★ 页面销毁时必须先调它、再调 release()。
   * XComponent 被销毁时 ArkUI 会析构 Surface 渲染节点；若原生侧还持有该
   * surface（甚至正在写帧），就会和系统销毁流程撞车而闪退
   * （实测崩溃栈 RSSurfaceNode::~RSSurfaceNode，主线程）。
   */
  detachSurface(): number;
  /**
   * 打开文件并准备解码
   *
   * @param path 文件绝对路径
   * @param startPositionMs 起播位置（毫秒，可选）。
   *        ★ 为什么要有这个参数：续播必须在**开播之前**就把位置交给引擎，
   *        这样引擎"预渲染的第一帧"就是续播位置那一帧。
   *        如果等 READY 之后再 seek，预渲染会先把"文件开头"那帧渲染出去，
   *        上层就没法用它判断"画面已经就绪"，只能靠超时兜底。
   */
  prepare(path: string, startPositionMs?: number): number;
  start(): number;
  pause(): number;
  seekTo(positionMs: number): number;
  release(): void;
  getState(): number;
  getDuration(): number;
  getPosition(): number;
  getMediaInfo(): SoftMediaInfo;

  /**
   * 切换音轨
   *
   * 原生实现是「用新下标重开会话 + seek 回原播放位置」——
   * 所以会有短暂的中断，这是预期行为。
   *
   * @param streamIndex 流下标（取自 getMediaInfo().audioTracks[].index）
   * @returns 0 成功；非 0 失败
   */
  switchAudioTrack(streamIndex: number): number;

  /**
   * 启用 / 关闭内嵌字幕轨
   * @param streamIndex 流下标；-1 关闭字幕
   * @returns 0 成功；非 0 失败
   */
  setSubtitleTrack(streamIndex: number): number;

  /**
   * 取当前该显示的字幕文本
   *
   * 空串表示这一刻没有字幕 —— 直接绑到 Text 组件上就是"不显示"。
   * 这是"查询"而非"事件"：字幕按播放位置对齐，UI 每帧来问最省事。
   */
  getActiveSubtitle(): string;

  /** 文件里是否有多条可切换音轨 */
  canSwitchAudioTrack(): boolean;

  pollEvents(): SoftPlayerEvent[];
}

/** 原生模块探针 */
export const nativeProbe: () => string;
/** 原生库编译信息 */
export const nativeBuildInfo: () => string;
/**
 * 软解引擎探针
 *
 * 验证 FfmpegEngine 的骨架（线程 / 队列 / surface / 生命周期）：
 * 在 FFmpeg 未集成时应返回明确的「未集成」错误且不崩溃、
 * Release 时线程不挂死。接上 FFmpeg 后同一探针即为真正的软解验证。
 *
 * @param surfaceId XComponent 的 surface id（可为空串）
 * @param filePath 要测试的媒体文件绝对路径
 * @returns 多行结果文本
 */
export const nativeSoftDecodeProbe: (surfaceId: string, filePath: string) => string;

/**
 * 抽一帧画面存成 JPEG —— 用于生成视频缩略图
 *
 * 为什么需要它：系统 AVImageGenerator 对 .rm / .wmv / .ogv 完全无能为力
 * （实测报 5400106），导致这些格式在首页和搜索页永远是灰底占位。
 * 而 FFmpeg 本来就能解这些格式。
 *
 * @param srcPath 源视频绝对路径
 * @param dstPath 输出 JPEG 路径
 * @param atMs 取帧位置（毫秒）；实际会跳到该位置之前最近的关键帧
 * @param targetW 期望宽度（等比缩放；<=0 用原始宽度；不会放大）
 * @returns 形如 "0 " 表示成功（首段是错误码，0 为成功）；
 *          失败时首段为负错误码，后面跟可读原因
 */
export const nativeExtractFrame: (srcPath: string, dstPath: string,
                                 atMs: number, targetW: number) => string;

