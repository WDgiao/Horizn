import { getExtension, getFileName, isPlayableMedia, mediaTierOf, MediaTier } from './MediaType';

/** 扫描到的媒体文件 */
export interface MediaFile {
  /** 完整绝对路径，交给 AVPlayer 的 url 使用 */
  path: string;
  /** 文件名（含后缀） */
  name: string;
  /** 小写后缀，用于显示与分组 */
  extension: string;
  /** 文件大小（字节） */
  size: number;
  /** 所属目录，用于搜索结果显示来源 */
  folder: string;
  /** 后缀是否在白名单内，决定能否进播放器 */
  playable: boolean;
  /** 格式级别（实测得出，决定界面提示与是否提示"需要软解"） */
  tier: MediaTier;
}

/** 字节数转可读体积，例如 1.4 GB */
export function formatSize(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return bytes.toString() + ' B';
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return kb.toFixed(0) + ' KB';
  }
  const mb: number = kb / 1024;
  if (mb < 1024) {
    return mb.toFixed(1) + ' MB';
  }
  const gb: number = mb / 1024;
  return gb.toFixed(2) + ' GB';
}

/** 由绝对路径构造 MediaFile */
export function buildMediaFile(fullPath: string, size: number): MediaFile {
  const name: string = getFileName(fullPath);
  const slash: number = fullPath.lastIndexOf('/');
  const folder: string = slash > 0 ? fullPath.substring(0, slash) : fullPath;
  const item: MediaFile = {
    path: fullPath,
    name: name,
    extension: getExtension(name),
    size: size,
    folder: folder,
    playable: isPlayableMedia(name),
    tier: mediaTierOf(name)
  };
  return item;
}
