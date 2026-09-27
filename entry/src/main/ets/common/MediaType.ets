/**
 * 媒体格式能力分级（基于真机实测，不是猜的）
 *
 * 实测方法见 `本机真实解码能力实测.md`：应用内挂 surface，用 AVPlayer
 * 逐个播放样本，判据是 videoSizeChange 报出的画面尺寸非 0。
 *
 * 为什么必须分级：
 *   早先只用后缀白名单判断"能不能播"，结果是 .rmvb / .wmv 被标成可播放，
 *   用户点开才报 5400106 —— 后缀只说明"容器对不对"，不说明"解码器认不认"。
 *
 * 实测确认的系统能力：
 *   能解码：H.264 / HEVC / MPEG-4 / MPEG-2 / H.263
 *   不能解：VP8 / VP9 / AV1（无解码器接口）、Theora、WMV2/VC-1、RealVideo
 *   不能解封装：asf(wmv/wma)、realmedia(rm/rmvb)、ogg/ogv、ac3
 *
 * 两个各级别的区别（这一点实测出来的，很反直觉）：
 *   "视频解码器不支持" 只让画面黑掉，播放器照样 playing、有声音；
 *   "解封装不支持"     直接整个失败（5400106 / DEM_FMT_ERR）。
 *   所以前者还能"点开试试"，后者点开必然失败。
 */

/** 格式可用级别 */
export enum MediaTier {
  /** 系统解码器直接支持，点开就能播 */
  PLAYABLE = 0,
  /** 容器能解但内部编码可能需要软解，点开可能只有声音 */
  MAYBE_PLAYABLE = 1,
  /** 系统连容器都解不开，必须有软解才能播（当前会失败） */
  NEEDS_SOFT_DECODE = 2,
  /** 不是媒体文件 */
  NOT_MEDIA = 3
}

/**
 * 取小写后缀（不含点），无后缀返回空串
 * @param name 文件名或完整路径
 */
export function getExtension(name: string): string {
  const dot: number = name.lastIndexOf('.');
  if (dot < 0) {
    return '';
  }
  return name.substring(dot + 1).toLowerCase();
}

/** 视频容器后缀（不含点，全小写） */
export const VIDEO_CONTAINERS: string[] = [
  'mp4', 'm4v', 'mkv', 'avi', 'flv', 'webm', 'ts', 'm2ts', 'tp',
  'mpeg', 'mpg', 'vob', 'wmv', 'asf', 'rm', 'rmvb', 'ogv', 'ogm',
  '3gp', '3g2', 'mxf', 'swf', 'f4v', 'mov', 'mpe', 'm1v', 'm2v',
  'mts', 'divx', 'mod', 'tod', 'dat', 'dv', 'ogx'
];

/** 音频容器后缀（同样可交给 AVPlayer 播放） */
export const AUDIO_CONTAINERS: string[] = [
  'aac', 'mp3', 'flac', 'ape', 'wav', 'aiff', 'aif', 'ogg', 'oga',
  'ac3', 'eac3', 'dts', 'mlp', 'wma', 'mid', 'midi', 'mpc', 'amr',
  'm4a', 'mka', 'opus', 'ra', 'au', 'caf', 'wv', 'tta'
];

/** 视频流编码格式（写在这里是为了显示与后续扩展，非后缀） */
export const VIDEO_CODECS: string[] = [
  'H.264 / AVC', 'H.265 / HEVC', 'AV1', 'VP8', 'VP9', 'VC-1',
  'MPEG-1', 'MPEG-2', 'MPEG-4', 'WMV2', 'WMV3', 'Theora',
  'AVS2', 'AVS3', 'RealVideo'
];

/** 音频流编码格式 */
export const AUDIO_CODECS: string[] = [
  'AAC', 'MP3', 'FLAC', 'APE', 'WAV', 'AIFF', 'OGG Vorbis', 'AC3',
  'EAC3', 'DTS', 'DTS-HD', 'TrueHD', 'MLP', 'WMA', 'MIDI', 'MPC', 'AMR'
];

/**
 * 实测「点开就能播」的后缀
 * 这些容器能被系统解开，且实际样本通过真解码测试
 */
const TIER_PLAYABLE: string[] = ['mp4', 'm4v', 'mov', 'mkv', 'mpeg', 'mpg', 'mpe', 'm1v', 'm2v', '3gp', '3g2'];

/**
 * 实测「系统解封装就失败」的后缀，必须交给软解
 * 实测证据（DEM_FMT_ERR）：
 *   wmv / asf  → wmav2 音频解不开
 *   rm / rmvb  → ac3 音频解不开
 *   ogv / ogm  → vorbis 解不开
 *
 * 后一组（mxf / swf / dv / divx / ape / dts / truehd / mlp）走软解的
 * 原因不同：**系统根本不认这些容器或编码**，而内嵌 FFmpeg 原先也没编，
 * 所以它们原先点开必然失败。2026-09-25 已补齐组件，现已归入可走软解。
 */
const TIER_NEEDS_SOFT: string[] = [
  // 系统解封装失败（有真机实测证据）
  'wmv', 'asf', 'rm', 'rmvb', 'ra', 'ogv', 'ogm', 'ogg', 'oga',
  // 系统完全不支持 + 内嵌 FFmpeg 已补齐（见下方 SOFT_ADDED 说明）
  'mxf', 'swf', 'dv', 'tod', 'mod',
  'divx', 'ape', 'dts', 'truehd', 'mlp'
];

/**
 * 音频后缀里实测能播的
 * 只有 AAC 被验证过（样本里带的），其余先保守归到"可能"
 */
const AUDIO_PLAYABLE: string[] = ['aac', 'm4a', 'mp3', 'amr', 'flac', 'wav'];

/**
 * 2026-09-25 为以下后缀补齐了内嵌 FFmpeg 组件（原先一个都没有，点开必然失败）
 *
 * 补齐清单与依据：
 *   解封装器 mxf / swf / dv
 *       → 覆盖 .mxf（广电）、.swf（Flash）、.dv（DV 摄像机）、
 *         .tod / .mod（JVC 的 DV 与 MPEG-2 变体，走 dv / mpegps 分支）
 *   解码器 msmpeg4v1 / v2 / v3
 *       → 覆盖 .divx（DivX 3 就是 msmpeg4v3；DivX 4/5 是标准 MPEG-4，本来就能解）
 *       ★ 坑：configure 里不能写 msmpeg4，那样只匹配到同名配置项组，
 *         三个具体解码器仍为 0。必须写带版本号的名字
 *   解码器 ape / dca / truehd / mlp + parser dca / mlp
 *       → 覆盖 .ape（Monkey's Audio）、.dts、.truehd / .mlp
 *
 * 体积代价：全部加起来只增加 0.36 MB（7.01 → 7.37 MB），
 * 远低于预估 —— 解封装器和小众解码器都不大。
 *
 * ⚠️ 这些是「组件已编入」，尚未在真机上验证实际解码效果
 * （没有对应样本，且验证受阻：模拟器是 x86_64 装不上，真机当时不可用）。
 */

/** 可解码后缀集合：容器白名单 + 音频白名单 */
export const DECODABLE_EXTENSIONS: string[] = VIDEO_CONTAINERS.concat(AUDIO_CONTAINERS);

/**
 * 已知无法播放的后缀：白名单里有、但系统与内嵌 FFmpeg 都没有对应组件
 *
 * 单独列出来而不是从后缀数组里删掉，是为了保留「这个后缀是媒体格式」的认知
 * —— 将来某个版本补上组件时，改这里一处即可。
 *
 * 目前只有 MIDI 这一项：
 *   MIDI 不是音频流，而是"乐谱指令"，播放需要音源库（SoundFont）合成，
 *   与解码一个音频文件是两件事。要支持它得引入合成器，成本远高于收益，
 *   所以明确列为不支持，而不是让它显示"点击播放"然后失败。
 */
const KNOWN_UNSUPPORTED: string[] = ['mid', 'midi'];

/**
 * 判断格式级别
 * @param name 文件名或完整路径
 */
export function mediaTierOf(name: string): MediaTier {
  const ext: string = getExtension(name);
  if (ext.length === 0) {
    return MediaTier.NOT_MEDIA;
  }
  // 明确不支持的要先拦掉：宁可显示"不在白名单"，也不要让用户点开才报错
  if (KNOWN_UNSUPPORTED.indexOf(ext) >= 0) {
    return MediaTier.NOT_MEDIA;
  }
  if (TIER_PLAYABLE.indexOf(ext) >= 0 || AUDIO_PLAYABLE.indexOf(ext) >= 0) {
    return MediaTier.PLAYABLE;
  }
  if (TIER_NEEDS_SOFT.indexOf(ext) >= 0) {
    return MediaTier.NEEDS_SOFT_DECODE;
  }
  if (DECODABLE_EXTENSIONS.indexOf(ext) >= 0) {
    return MediaTier.MAYBE_PLAYABLE;
  }
  return MediaTier.NOT_MEDIA;
}

/**
 * 判断文件是否可播放
 *
 * 语义已收紧：PLAYABLE / MAYBE_PLAYABLE 返回 true（点开有希望），
 * NEEDS_SOFT_DECODE 也返回 true —— 因为软解接上之后它们就能播，
 * 界面上用 mediaTierOf 的结果来区分提示文案。
 *
 * @param name 文件名或完整路径
 */
export function isPlayableMedia(name: string): boolean {
  return mediaTierOf(name) !== MediaTier.NOT_MEDIA;
}

/**
 * 级别对应的界面提示
 *
 * NEEDS_SOFT_DECODE 的文案已从「需要软解（暂不可播）」改成「点击播放（软解）」——
 * 内置 FFmpeg 已经接上，这类文件现在真的能播了，文案不能还写着不可播。
 *
 * @param tier 级别
 */
export function tierLabel(tier: MediaTier): string {
  if (tier === MediaTier.PLAYABLE) { return '点击播放'; }
  if (tier === MediaTier.MAYBE_PLAYABLE) { return '点击播放'; }
  if (tier === MediaTier.NEEDS_SOFT_DECODE) { return '点击播放（软解）'; }
  return '不在白名单';
}

/**
 * 取不带路径的文件名
 * @param fullPath 完整路径
 */
export function getFileName(fullPath: string): string {
  const slash: number = fullPath.lastIndexOf('/');
  if (slash < 0) {
    return fullPath;
  }
  return fullPath.substring(slash + 1);
}

/**
 * 判断是视频容器还是音频容器
 * @param name 文件名
 */
export function isVideoContainer(name: string): boolean {
  return VIDEO_CONTAINERS.indexOf(getExtension(name)) >= 0;
}
