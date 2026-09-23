import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 导入结果 */
export interface ImportResult {
  /** 成功导入的文件数 */
  imported: number;
  /** 跳过的文件数（用户取消或失败） */
  skipped: number;
  /** 导入到的目录 */
  targetDir: string;
  /** 失败原因摘要（成功时为空串） */
  error: string;
}

/**
 * 视频文件导入器
 *
 * 为什么需要它：
 *   HarmonyOS 的应用沙箱不允许任意扫描手机目录，公共目录权限在真机上也常常拿不到。
 *   系统文件选择器是官方唯一可靠的"访问手机任意位置文件"途径 ——
 *   用户主动选择即授予访问权，无需声明任何敏感权限。
 *
 * 为什么选择"复制进沙箱"而不是"直接播 URI"：
 *   复制之后文件变成沙箱内普通文件，扫描、封面提取、播放、进度记录
 *   这些已有功能全部可以直接复用，改动最小、行为最可预期。
 *   代价是占用存储空间与复制耗时。
 */
export class MediaImporter {
  /** 沙箱内接收导入文件的目录名 */
  private static readonly IMPORT_DIR: string = '导入的视频';
  /** 目标目录绝对路径 */
  private targetDir: string;
  /** 应用上下文，构造 picker 需要 */
  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
    this.targetDir = context.filesDir + '/' + MediaImporter.IMPORT_DIR;
    this.ensureTargetDir();
  }

  /** 导入目录绝对路径 */
  getTargetDir(): string {
    return this.targetDir;
  }

  /** 确保导入目录存在 */
  private ensureTargetDir(): void {
    try {
      if (!fileIo.accessSync(this.targetDir)) {
        fileIo.mkdirSync(this.targetDir, true);
      }
    } catch (err) {
      console.error('create import dir failed: ' + JSON.stringify(err));
    }
  }

  /**
   * 弹出系统文件选择器并导入所选视频
   * @returns 导入结果
   */
  async pickAndImport(): Promise<ImportResult> {
    const result: ImportResult = {
      imported: 0,
      skipped: 0,
      targetDir: this.targetDir,
      error: ''
    };
    this.ensureTargetDir();

    // ---- 第一步：调起系统文件选择器 ----
    let uris: string[] = [];
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSelectOptions();
      // 只让用户选视频：与 MediaType.ets 里的容器白名单保持一致
      options.maxSelectNumber = 20;
      options.fileSuffixFilters = [
        '.mp4', '.m4v', '.mkv', '.avi', '.flv', '.webm', '.ts', '.m2ts', '.tp',
        '.mpeg', '.mpg', '.vob', '.wmv', '.asf', '.rm', '.rmvb', '.ogv', '.ogm',
        '.3gp', '.3g2', '.mxf', '.mov'
      ];
      uris = await documentPicker.select(options);
    } catch (err) {
      const e = err as BusinessError;
      // 用户主动取消也会走到这里，不当作错误
      result.error = '选择器未返回文件（' + e.code.toString() + '）';
      console.error('documentPicker.select failed: ' + JSON.stringify(e));
      return result;
    }

    if (uris === undefined || uris === null || uris.length === 0) {
      result.error = '未选择任何文件';
      return result;
    }

    // ---- 第二步：逐个复制进沙箱 ----
    for (let i = 0; i < uris.length; i++) {
      const ok: boolean = await this.copyOne(uris[i]);
      if (ok) {
        result.imported++;
      } else {
        result.skipped++;
      }
    }
    return result;
  }

  /**
   * 复制单个 URI 指向的文件到沙箱
   * @param uri 选择器返回的文档 URI
   * @returns 是否成功
   */
  private async copyOne(uri: string): Promise<boolean> {
    let srcFile: fileIo.File | undefined = undefined;
    let destFile: fileIo.File | undefined = undefined;
    try {
      // 文档 URI 不能直接当路径用，但可以用 openSync 打开拿到 fd
      srcFile = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const fileName: string = this.buildFileName(uri);
      const destPath: string = this.targetDir + '/' + fileName;

      // 已存在同名文件时加序号，避免覆盖用户已导入的内容
      const finalPath: string = this.uniquePath(destPath);

      destFile = fileIo.openSync(finalPath,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      // copyFile 支持 fd 作为源与目标，大文件也不会一次性读进内存
      await fileIo.copyFile(srcFile.fd, destFile.fd);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      console.error('copy import failed: ' + JSON.stringify(e));
      return false;
    } finally {
      if (srcFile !== undefined) {
        try {
          fileIo.closeSync(srcFile);
        } catch (e) {
          console.error('close src failed');
        }
      }
      if (destFile !== undefined) {
        try {
          fileIo.closeSync(destFile);
        } catch (e) {
          console.error('close dest failed');
        }
      }
    }
  }

  /**
   * 从 URI 里提取文件名
   * 文档 URI 形如 file://docs/storage/Users/currentUser/Download/xxx.mp4
   * @param uri 文档 URI
   */
  private buildFileName(uri: string): string {
    let name: string = uri;
    const slash: number = name.lastIndexOf('/');
    if (slash >= 0) {
      name = name.substring(slash + 1);
    }
    // URI 可能带查询串，去掉
    const query: number = name.indexOf('?');
    if (query >= 0) {
      name = name.substring(0, query);
    }
    // 解码百分号转义（中文文件名常见）
    try {
      name = decodeURIComponent(name);
    } catch (err) {
      // 解码失败就用原串
    }
    if (name.length === 0) {
      name = 'imported_' + Date.now().toString() + '.mp4';
    }
    return name;
  }

  /**
   * 若目标路径已存在，追加序号
   * @param destPath 期望路径
   */
  private uniquePath(destPath: string): string {
    try {
      if (!fileIo.accessSync(destPath)) {
        return destPath;
      }
    } catch (err) {
      return destPath;
    }
    const dot: number = destPath.lastIndexOf('.');
    const base: string = dot > 0 ? destPath.substring(0, dot) : destPath;
    const ext: string = dot > 0 ? destPath.substring(dot) : '';
    for (let i = 2; i <= 99; i++) {
      const candidate: string = base + ' (' + i.toString() + ')' + ext;
      try {
        if (!fileIo.accessSync(candidate)) {
          return candidate;
        }
      } catch (err) {
        return candidate;
      }
    }
    return destPath;
  }
}
