import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

/** 一个文件夹 */
export interface MediaFolder {
  /** 文件夹名 */
  name: string;
  /** 绝对路径 */
  path: string;
  /** 直接子文件数 */
  fileCount: number;
}

/**
 * 文件夹仓库
 *
 * 所有自建文件夹都放在应用沙箱的 files 目录下：
 *   - 沙箱无需任何权限，读写最稳；
 *   - 搜索页的扫描根目录已包含 filesDir，所以新建的文件夹能立刻被搜索到。
 */
export class FolderRepository {
  /** 应用沙箱上下文 */
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  /** 自建文件夹的根目录 */
  getRootDir(): string {
    return this.context.filesDir;
  }

  /**
   * 列出根目录下的全部子文件夹
   */
  listFolders(): MediaFolder[] {
    const root: string = this.getRootDir();
    const result: MediaFolder[] = [];
    let names: string[] = [];
    try {
      if (!fileIo.accessSync(root)) {
        return result;
      }
      names = fileIo.listFileSync(root);
    } catch (err) {
      console.error('list folders failed: ' + JSON.stringify(err));
      return result;
    }

    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      const full: string = root + '/' + name;
      try {
        if (!fileIo.statSync(full).isDirectory()) {
          continue;
        }
      } catch (err) {
        continue;
      }
      result.push({
        name: name,
        path: full,
        fileCount: this.countFiles(full)
      });
    }
    result.sort((a: MediaFolder, b: MediaFolder): number => a.name.localeCompare(b.name));
    return result;
  }

  /**
   * 新建文件夹
   * @param name 文件夹名
   * @returns 失败时返回错误原因，成功返回空串
   */
  createFolder(name: string): string {
    const trimmed: string = name.trim();
    if (trimmed.length === 0) {
      return '文件夹名不能为空';
    }
    // 路径分隔符与非法字符校验，避免创建出异常目录
    if (trimmed.indexOf('/') >= 0 || trimmed.indexOf('\\') >= 0) {
      return '文件夹名不能包含斜杠';
    }
    if (trimmed === '.' || trimmed === '..') {
      return '文件夹名不合法';
    }
    const full: string = this.getRootDir() + '/' + trimmed;
    try {
      if (fileIo.accessSync(full)) {
        return '同名文件夹已存在';
      }
      fileIo.mkdirSync(full, false);
      return '';
    } catch (err) {
      console.error('mkdir failed: ' + JSON.stringify(err));
      return '创建失败，请换一个名称';
    }
  }

  /**
   * 用自动编号的名字新建文件夹
   * 依次尝试「新建文件夹」「新建文件夹 (2)」「新建文件夹 (3)」…
   * 这样做的好处是不需要用户输入，也就不存在非法字符、重名等问题
   * @returns 新建成功返回文件夹名，失败返回空串
   */
  createAutoNamedFolder(): string {
    for (let i = 1; i <= 99; i++) {
      const name: string = i === 1 ? '新建文件夹' : ('新建文件夹 (' + i.toString() + ')');
      const full: string = this.getRootDir() + '/' + name;
      try {
        if (fileIo.accessSync(full)) {
          continue;
        }
        fileIo.mkdirSync(full, false);
        return name;
      } catch (err) {
        console.error('createAutoNamedFolder failed: ' + JSON.stringify(err));
        return '';
      }
    }
    return '';
  }

  /**
   * 删除文件夹（仅允许删除空文件夹，避免误删视频）
   * @param folderPath 绝对路径
   * @returns 失败原因，成功返回空串
   */
  removeFolder(folderPath: string): string {
    try {
      if (this.countFiles(folderPath) > 0) {
        return '文件夹内还有文件，请先清空';
      }
      fileIo.rmdirSync(folderPath);
      return '';
    } catch (err) {
      console.error('rmdir failed: ' + JSON.stringify(err));
      return '删除失败';
    }
  }

  /** 统计目录下的文件个数（不含子目录，递归一层即可满足展示需要） */
  private countFiles(dir: string): number {
    let count: number = 0;
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        try {
          if (!fileIo.statSync(dir + '/' + names[i]).isDirectory()) {
            count++;
          }
        } catch (err) {
          continue;
        }
      }
    } catch (err) {
      return 0;
    }
    return count;
  }
}
