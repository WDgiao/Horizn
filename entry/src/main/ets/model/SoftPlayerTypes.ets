/**
 * 原生播放器的类型定义（ArkTS 侧）
 *
 * 为什么枚举放在这里而不是 .d.ts 里：
 *   .d.ts 是纯类型声明，编译后会被完全擦除。
 *   如果在那里声明 enum，运行时模块并不会导出它，
 *   于是 import 会直接抛
 *   "does not provide an export name ..."
 *   —— 这是只有在真机运行才会暴露的错误。
 *   因此凡是运行时需要真实存在的值（枚举、常量），都用 .ets 定义。
 *
 * 数值必须与 C++ 侧枚举保持一致：
 *   cpp/player/IPlayerEngine.h 里的 PlayerState / PlayerEvent
 */

/** 播放器状态 */
export enum SoftPlayerState {
  /** 已创建，未准备 */
  IDLE = 0,
  /** 正在打开文件、探测流 */
  PREPARING = 1,
  /** 已就绪，可播放 */
  READY = 2,
  PLAYING = 3,
  PAUSED = 4,
  /** 播放结束 */
  COMPLETED = 5,
  ERROR_STATE = 6,
  RELEASED = 7
}

/** 原生事件类型 */
export enum SoftPlayerEventType {
  STATE_CHANGED = 0,
  POSITION = 1,
  DURATION = 2,
  VIDEO_SIZE = 3,
  ERROR = 4,
  PREPARED = 5,
  COMPLETED = 6
}

/** 原生线程投递上来的事件 */
export interface SoftPlayerEvent {
  /** 事件类型 */
  type: number;
  /** 主数据（含义随类型而定） */
  data1: number;
  /** 次数据 */
  data2: number;
  /** 文本载荷（错误描述等） */
  text: string;
}

/** 媒体信息 */
export interface SoftMediaInfo {
  /** 总时长（毫秒） */
  durationMs: number;
  /** 画面宽 */
  width: number;
  /** 画面高 */
  height: number;
  /** 帧率 */
  frameRate: number;
  /** 视频编码名，例如 "rv40" */
  videoCodec: string;
  /** 音频编码名，例如 "cook" */
  audioCodec: string;
  /** 是否含视频流 */
  hasVideo: boolean;
  /** 是否含音频流 */
  hasAudio: boolean;
}
