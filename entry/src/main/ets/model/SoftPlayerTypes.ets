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
  /** 文件里的全部可切换音轨 */
  audioTracks: SoftAudioTrack[];
  /** 文件里的全部字幕轨 */
  subtitleTracks: SoftSubtitleTrack[];
  /** 当前生效的音轨流下标；-1 表示无 */
  currentAudioIndex: number;
  /** 当前生效的字幕轨流下标；-1 表示未启用 */
  currentSubtitleIndex: number;
}

/**
 * 一条可切换的音轨
 *
 * 注意：index 是**容器里的流下标**，不是"第几条音轨"。
 * 流下标可能不连续（0 是视频、1 是音频、2 是字幕、3 又是音频），
 * 所以界面显示"音轨 1/2/3"时要自己编号，传给原生时必须用 index。
 */
export interface SoftAudioTrack {
  index: number;
  /** 编码名，例如 "aac" / "ac3" / "dca" */
  codec: string;
  /** 语言标签，例如 "chi" / "eng"（可能是空串） */
  language: string;
  /** 轨道标题（可能是空串） */
  title: string;
  /** 声道数，0 表示未知 */
  channels: number;
  /** 采样率，0 表示未知 */
  sampleRate: number;
  /** 码率（bps），0 表示未知 */
  bitRate: number;
  /** 是否为容器标记的默认轨 */
  isDefault: boolean;
}

/** 一条字幕轨 */
export interface SoftSubtitleTrack {
  index: number;
  /** 编码名，例如 "subrip" / "ass" / "mov_text" / "hdmv_pgs_subtitle" */
  codec: string;
  language: string;
  title: string;
  isDefault: boolean;
  /**
   * 是否可解码成文本
   *
   * 位图字幕（PGS / VobSub）为 false —— 界面要把它们显示成"不支持"，
   * 而不是让用户点了之后毫无反应。
   */
  supported: boolean;
}
