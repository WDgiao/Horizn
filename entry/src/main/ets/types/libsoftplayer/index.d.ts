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
  prepare(path: string): number;
  start(): number;
  pause(): number;
  seekTo(positionMs: number): number;
  release(): void;
  getState(): number;
  getDuration(): number;
  getPosition(): number;
  getMediaInfo(): SoftMediaInfo;
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

