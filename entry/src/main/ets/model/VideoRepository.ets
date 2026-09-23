import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { MediaFile, buildMediaFile } from '../common/MediaFiles';
import { isPlayableMedia } from '../common/MediaType';

/** 单次扫描允许的最大文件数，避免大容量存储导致卡顿 */
const MAX_FILES: number = 3000;
/** 递归深度上限，防止异常目录结构导致栈过深 */
const MAX_DEPTH: number = 10;

/** 目录探测状态 */
export type RootStatus = 'ok' | 'denied' | 'missing';

/** 单个候选目录的探测结果 */
export interface RootProbe {
  /** 候选目录路径 */
  path: string;
  /** ok=可读并已扫描；denied=存在但无权限；missing=不存在 */
  status: RootStatus;
  /** 该目录下直接命中的媒体文件数 */
  count: number;
}

/** 扫描结果 */
export interface ScanResult {
  /** 命中的媒体文件 */
  files: MediaFile[];
  /** 全部候选目录的探测结果，用于界面诊断 */
  probes: RootProbe[];
}

/**
 * 媒体文件仓库
 *
 * 设计要点：不同设备/模拟器的可访问媒体目录差异很大
 * （有的用 /storage/Users/currentUser/Download，有的只有 /sdcard），
 * 因此这里不写死单一路径，而是「列一批候选 -> 运行时逐个探测 -> 只扫可读的」。
 * 探测结果会返回给界面展示，便于排查「为什么没搜到文件」。
 */
export class VideoRepository {
  /** 应用沙箱上下文 */
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  /**
   * 明确可读的根目录
   * 这些是「不需要探测父目录、直接当扫描根」的位置
   */
  getDirectRoots(): string[] {
    const roots: string[] = [];
    // ---- 应用沙箱：无需任何权限，永远可读 ----
    roots.push(this.context.filesDir);
    roots.push(this.context.cacheDir);
    // ---- 开发调试常用投放位置 ----
    roots.push('/data/local/tmp');
    return roots;
  }

  /**
   * 需要先展开、再决定是否扫描的父目录
   *
   * 为什么不直接当扫描根：
   *   这些路径在真机上可能不存在（实测 HarmonyOS 6.1.1 上
   *   /storage/Users/currentUser/ 就不存在），而公共目录的确切形态
   *   随系统版本与机型变化。先探测父目录，可读就把子目录逐个纳入，
   *   这样不依赖写死的具体路径名。
   */
  getParentCandidates(): string[] {
    return [
      // 鸿蒙标准用户目录（模拟器上存在）
      '/storage/Users/currentUser',
      // 部分版本的实际媒体落盘路径
      '/storage/media/100/local/files',
      '/storage/media',
      // 真机上观察到的挂载点（权限受限，但值得探测）
      '/mnt/hmdfs',
      '/mnt/user',
      '/mnt/share',
      '/storage/cloud',
      // 兼容类 Android 布局
      '/storage/emulated/0',
      '/mnt/sdcard',
      '/sdcard'
    ];
  }

  /**
   * 组装候选根目录（保留旧接口，供内部逻辑复用）
   * 顺序即展示顺序：沙箱在最前，因为沙箱永远可读
   */
  getCandidateRoots(): string[] {
    const roots: string[] = this.getDirectRoots();
    const parents: string[] = this.getParentCandidates();
    for (let i = 0; i < parents.length; i++) {
      roots.push(parents[i]);
    }
    return roots;
  }

  /**
   * 探测一个目录是否可读
   * @param dir 目录路径
   * @returns 状态；ok 还会带回直接命中的媒体文件数
   */
  probeRoot(dir: string): RootProbe {
    const probe: RootProbe = { path: dir, status: 'missing', count: 0 };
    try {
      const entries: string[] = fileIo.listFileSync(dir);
      probe.status = 'ok';
      for (let i = 0; i < entries.length; i++) {
        if (isPlayableMedia(entries[i])) {
          probe.count++;
        }
      }
    } catch (err) {
      // 读不到就再确认一次路径是否存在：
      // 存在 -> 无权限(denied)；不存在 -> missing
      // 注意 accessSync 自身也会抛异常，必须单独包一层 try
      let exists: boolean = false;
      try {
        exists = fileIo.accessSync(dir);
      } catch (probeErr) {
        exists = false;
      }
      probe.status = exists ? 'denied' : 'missing';
    }
    return probe;
  }

  /**
   * 在 currentUser 下自动发现真实存在的子目录
   * 不同系统版本目录名可能不同，靠枚举补齐，避免漏扫
   */
  discoverSubDirs(parent: string): string[] {
    const found: string[] = [];
    try {
      const entries: string[] = fileIo.listFileSync(parent);
      for (let i = 0; i < entries.length; i++) {
        const full: string = parent + '/' + entries[i];
        try {
          if (fileIo.statSync(full).isDirectory()) {
            found.push(full);
          }
        } catch (err) {
          // 单个条目读不到就跳过
          continue;
        }
      }
    } catch (err) {
      // 父目录本身不可读
    }
    return found;
  }

  /**
   * 只扫描指定的一个目录（用于首页「打开文件夹」）
   * @param dir 目录绝对路径
   */
  scanSingleDir(dir: string): ScanResult {
    const probes: RootProbe[] = [];
    const readable: string[] = [];
    const probe: RootProbe = this.probeRoot(dir);
    probes.push(probe);
    if (probe.status === 'ok') {
      readable.push(dir);
    }
    const files: MediaFile[] = [];
    for (let i = 0; i < readable.length; i++) {
      this.walk(readable[i], 0, files);
    }
    files.sort((a: MediaFile, b: MediaFile): number => a.name.localeCompare(b.name));
    return { files: files, probes: probes };
  }

  /**
   * 执行扫描
   * 先探测候选目录，再对可读目录做递归遍历
   */
  scan(): ScanResult {
    const probes: RootProbe[] = [];
    const readable: string[] = [];
    // 已加入扫描根的路径集合，用于去重
    const accepted: string[] = [];

    const accept = (dir: string): void => {
      for (let i = 0; i < accepted.length; i++) {
        if (accepted[i] === dir) {
          return;
        }
      }
      accepted.push(dir);
      readable.push(dir);
    };

    // ---- 第一轮：沙箱等「必定可读」的目录直接作为扫描根 ----
    const directs: string[] = this.getDirectRoots();
    for (let i = 0; i < directs.length; i++) {
      const probe: RootProbe = this.probeRoot(directs[i]);
      probes.push(probe);
      if (probe.status === 'ok') {
        accept(directs[i]);
      }
    }

    // ---- 第二轮：逐个探测父目录，可读就展开它的子目录 ----
    const parents: string[] = this.getParentCandidates();
    for (let i = 0; i < parents.length; i++) {
      const parent: string = parents[i];
      const parentProbe: RootProbe = this.probeRoot(parent);
      probes.push(parentProbe);
      if (parentProbe.status !== 'ok') {
        // 不存在或无权限：记录状态即可，界面会显示出来
        continue;
      }
      // 父目录本身也作为扫描根（媒体可能直接放在这里）
      accept(parent);
      // 再展开一层子目录，把真实存在的公共目录纳进来
      const children: string[] = this.discoverSubDirs(parent);
      for (let j = 0; j < children.length; j++) {
        const child: string = children[j];
        const childProbe: RootProbe = this.probeRoot(child);
        probes.push(childProbe);
        if (childProbe.status === 'ok') {
          accept(child);
        }
      }
    }

    // ---- 第三轮：对可读目录递归收集媒体文件 ----
    const files: MediaFile[] = [];
    for (let i = 0; i < readable.length; i++) {
      this.walk(readable[i], 0, files);
    }

    // 按文件名排序，保证列表顺序稳定
    files.sort((a: MediaFile, b: MediaFile): number => a.name.localeCompare(b.name));
    return { files: files, probes: probes };
  }

  /**
   * 递归遍历一个目录
   * @param dir 目录绝对路径
   * @param depth 当前递归深度
   * @param out 命中文件累加器
   */
  private walk(dir: string, depth: number, out: MediaFile[]): void {
    if (depth > MAX_DEPTH || out.length >= MAX_FILES) {
      return;
    }
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dir);
    } catch (err) {
      // 子目录权限不足：跳过，不影响其它目录
      return;
    }

    for (let i = 0; i < entries.length; i++) {
      const name: string = entries[i];
      const full: string = dir + '/' + name;
      let isDir: boolean = false;
      let size: number = 0;
      try {
        const info = fileIo.statSync(full);
        isDir = info.isDirectory();
        size = info.size;
      } catch (err) {
        // 单个条目读不到就跳过，不中断整个扫描
        continue;
      }
      if (isDir) {
        this.walk(full, depth + 1, out);
      } else if (isPlayableMedia(name)) {
        out.push(buildMediaFile(full, size));
        if (out.length >= MAX_FILES) {
          return;
        }
      }
    }
  }
}
