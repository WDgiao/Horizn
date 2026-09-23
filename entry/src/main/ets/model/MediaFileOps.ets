import { fileIo } from '@kit.CoreFileKit';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { formatSize, MediaFile } from '../common/MediaFiles';
import { getExtension } from '../common/MediaType';

/** 文件详细信息 */
export interface MediaFileDetail {
  /** 文件名 */
  name: string;
  /** 完整路径 */
  path: string;
  /** 所在目录 */
  folder: string;
  /** 后缀（小写） */
  extension: string;
  /** 文件大小（字节） */
  size: number;
  /** 可读体积，例如 1.4 GB */
  sizeText: string;
  /** 最后修改时间文本 */
  modifiedText: string;
  /** 视频时长文本（取不到时为空串） */
  durationText: string;
  /** 画面尺寸文本，例如 1920×1080（取不到时为空串） */
  resolutionText: string;
  /** MIME 类型（取不到时为空串） */
  mimeText: string;
  /** 是否在可播放白名单内 */
  playable: boolean;
}

/** 媒体元信息（内部使用，字段名与 AVMetadata 对应） */
interface MediaMeta {
  /** 时长文本 */
  durationText: string;
  /** 画面尺寸文本 */
  resolutionText: string;
  /** MIME 类型 */
  mimeText: string;
}

/**
 * 文件操作服务
 *
 * 所有操作都限制在应用沙箱内 —— 这是 HarmonyOS 的能力边界：
 * 应用无权改动沙箱外（如手机公共目录）的文件。
 */
export class MediaFileOps {

  /* ============================================================
     重命名
     ============================================================ */

  /**
   * 校验新文件名，返回错误文案；合法则返回空串
   * @param newName 用户输入的新名称（不含路径）
   * @param oldName 原名称，用于判断是否未改动
   */
  static validateName(newName: string, oldName: string): string {
    const name: string = newName.trim();
    if (name.length === 0) {
      return '名称不能为空';
    }
    if (name === oldName) {
      return '名称没有变化';
    }
    if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
      return '名称不能包含斜杠';
    }
    if (name === '.' || name === '..') {
      return '该名称不可用';
    }
    if (name.startsWith('.')) {
      return '名称不能以点开头';
    }
    return '';
  }

  /**
   * 重命名文件
   * @param oldPath 原完整路径
   * @param newName 新文件名（可带后缀；不带后缀时沿用原后缀）
   * @returns 新路径；失败返回空串
   */
  static rename(oldPath: string, newName: string): string {
    try {
      const name: string = newName.trim();
      const slash: number = oldPath.lastIndexOf('/');
      const dir: string = slash > 0 ? oldPath.substring(0, slash) : '';
      // 用户没写后缀就沿用原来的，避免把 .mp4 弄丢
      const oldExt: string = getExtension(oldPath);
      const hasExt: boolean = name.lastIndexOf('.') > 0;
      const finalName: string = (hasExt || oldExt.length === 0)
        ? name
        : (name + '.' + oldExt);
      const newPath: string = dir + '/' + finalName;
      if (fileIo.accessSync(newPath)) {
        return '';
      }
      fileIo.renameSync(oldPath, newPath);
      return newPath;
    } catch (err) {
      const e = err as BusinessError;
      console.error('rename failed: ' + JSON.stringify(e));
      return '';
    }
  }

  /* ============================================================
     移动
     ============================================================ */

  /**
   * 移动文件到目标目录
   * @param srcPath 源文件完整路径
   * @param destDir 目标目录完整路径
   * @returns 错误文案；成功返回空串
   */
  static move(srcPath: string, destDir: string): string {
    try {
      const slash: number = srcPath.lastIndexOf('/');
      const fileName: string = slash >= 0 ? srcPath.substring(slash + 1) : srcPath;
      const destPath: string = destDir + '/' + fileName;
      if (destPath === srcPath) {
        return '文件已经在该目录中';
      }
      if (!fileIo.accessSync(destDir)) {
        return '目标目录不存在';
      }
      if (fileIo.accessSync(destPath)) {
        return '目标目录已有同名文件';
      }
      fileIo.moveFileSync(srcPath, destPath);
      return '';
    } catch (err) {
      const e = err as BusinessError;
      console.error('move failed: ' + JSON.stringify(e));
      return '移动失败（' + e.code.toString() + '）';
    }
  }

  /* ============================================================
     卸载（删除文件）
     ============================================================ */

  /**
   * 删除文件
   *
   * 范围说明：只能删除应用有权改动的文件，即沙箱内的文件。
   * 手机公共目录里的原始文件应用无权删除（HarmonyOS 沙箱限制），
   * 因此本功能针对的是「从手机导入」进来的那些副本。
   *
   * @param filePath 文件完整路径
   * @returns 错误文案；成功返回空串
   */
  static remove(filePath: string): string {
    try {
      if (!fileIo.accessSync(filePath)) {
        return '文件不存在（可能已被删除）';
      }
      const stat = fileIo.statSync(filePath);
      if (stat.isDirectory()) {
        return '这是目录，不能作为文件删除';
      }
      fileIo.unlinkSync(filePath);
      return '';
    } catch (err) {
      const e = err as BusinessError;
      console.error('remove failed: ' + JSON.stringify(e));
      return '删除失败（' + e.code.toString() + '）';
    }
  }

  /* ============================================================
     详细信息
     ============================================================ */

  /**
   * 读取文件详细信息（含视频时长与画面尺寸）
   * @param file 媒体文件
   */
  static async detail(file: MediaFile): Promise<MediaFileDetail> {
    const detail: MediaFileDetail = {
      name: file.name,
      path: file.path,
      folder: file.folder,
      extension: file.extension,
      size: file.size,
      sizeText: formatSize(file.size),
      modifiedText: '',
      durationText: '',
      resolutionText: '',
      mimeText: '',
      playable: file.playable
    };

    // ---- 文件系统信息 ----
    try {
      const stat = fileIo.statSync(file.path);
      detail.modifiedText = MediaFileOps.formatDate(new Date(stat.mtime * 1000));
      detail.size = stat.size;
      detail.sizeText = formatSize(stat.size);
    } catch (err) {
      console.error('stat failed: ' + JSON.stringify(err));
    }

    // ---- 媒体信息（时长 / 分辨率），失败不影响其它字段 ----
    try {
      const meta: MediaMeta = await MediaFileOps.readMediaMeta(file.path, file.size);
      detail.durationText = meta.durationText;
      detail.resolutionText = meta.resolutionText;
      detail.mimeText = meta.mimeText;
    } catch (err) {
      console.error('read media meta failed: ' + JSON.stringify(err));
    }
    return detail;
  }

  /**
   * 用 AVMetadataExtractor 读取时长、画面尺寸、MIME
   * 全部字段在 SDK 里都是 string 类型（duration 单位为毫秒的字符串）
   * @param path 视频路径
   * @param fileSize 文件大小，用于填 fdSrc.length
   */
  private static async readMediaMeta(path: string, fileSize: number): Promise<MediaMeta> {
    let extractor: media.AVMetadataExtractor | undefined = undefined;
    let f: fileIo.File | undefined = undefined;
    const out: MediaMeta = { durationText: '', resolutionText: '', mimeText: '' };
    try {
      f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      extractor = await media.createAVMetadataExtractor();
      extractor.fdSrc = { fd: f.fd, offset: 0, length: fileSize };
      const meta: media.AVMetadata = await extractor.fetchMetadata();

      const durationMs: string | undefined = meta.duration;
      if (durationMs !== undefined && durationMs.length > 0) {
        const ms: number = Number.parseInt(durationMs, 10);
        if (!Number.isNaN(ms)) {
          out.durationText = MediaFileOps.formatDuration(ms);
        }
      }
      const w: string | undefined = meta.videoWidth;
      const h: string | undefined = meta.videoHeight;
      if (w !== undefined && h !== undefined && w.length > 0 && h.length > 0) {
        out.resolutionText = w + '×' + h;
      }
      const mime: string | undefined = meta.mimeType;
      if (mime !== undefined) {
        out.mimeText = mime;
      }
    } catch (err) {
      // 取不到就算了，详情页对应字段留空
      console.error('fetchMetadata failed: ' + JSON.stringify(err));
    } finally {
      if (extractor !== undefined) {
        try {
          await extractor.release();
        } catch (e) {
          console.error('release extractor failed');
        }
      }
      if (f !== undefined) {
        try {
          fileIo.closeSync(f);
        } catch (e) {
          console.error('close meta file failed');
        }
      }
    }
    return out;
  }

  /** 毫秒 → mm:ss 或 hh:mm:ss */
  private static formatDuration(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const total: number = Math.floor(ms / 1000);
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const p2 = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    if (h > 0) {
      return p2(h) + ':' + p2(m) + ':' + p2(s);
    }
    return p2(m) + ':' + p2(s);
  }

  /** Date → yyyy-MM-dd HH:mm */
  private static formatDate(d: Date): string {
    const p2 = (n: number): string => n < 10 ? '0' + n.toString() : n.toString();
    return d.getFullYear().toString() + '-' + p2(d.getMonth() + 1) + '-' + p2(d.getDate())
      + ' ' + p2(d.getHours()) + ':' + p2(d.getMinutes());
  }
}
