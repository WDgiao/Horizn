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
    // ★ 2026-09-29 自检修正：同一棵目录树可能被多个扫描根覆盖
    //   （例如根目录和它的子目录同时进入候选列表），
    //   这里用 visited 保证每个目录只被遍历一次，避免同一文件重复出现。
    const visited: Set<string> = new Set<string>();
    for (let i = 0; i < readable.length; i++) {
      this.walk(readable[i], 0, files, visited);
    }
    files.sort((a: MediaFile, b: MediaFile): number => a.name.localeCompare(b.name));
    return { files: files, probes: probes };
  }

  /**
   * 只扫描指定的一个目录（**协作式**版本，每层目录之间让出主线程）
   *
   * ★ 2026-09-29 自检新增。为什么需要它：
   *
   *   同步版 scanSingleDir / scan 用的是 listFileSync + statSync，
   *   整个递归遍历期间**一直占着 UI 线程**。文件搜索页在 aboutToAppear
   *   里直接调用它，于是：
   *     · 目录大一点（几百上千个文件）界面就整块卡住，连"正在扫描…"
   *       这段文字都刷不出来；
   *     · 极端情况下超过系统的无响应阈值就变成 ANR 弹窗。
   *   下面的实现与同步版**逻辑完全一致**（同样的候选目录、同样的 visited
   *   去重、同样的深度与数量上限），只是每处理完一层目录就 await 一次
   *   宏任务，把主线程还给渲染与输入。
   *
   *   为什么不用 taskpool：扫描需要 common.Context 才能拿到沙箱目录，
   *   而 Context 不能跨线程传递（不可序列化）。为它单独开一套
   *   "把 filesDir/cacheDir 传进去"的并发实现，改动面和验证成本都大得多，
   *   而协作式让出已经能消除卡死现象。
   *
   * @param dir 目录绝对路径
   * @param shouldStop 可选取消检查：返回 true 立即中止（页面已销毁时用）
   */
  async scanSingleDirCooperative(dir: string,
                                 shouldStop?: () => boolean): Promise<ScanResult> {
    const probes: RootProbe[] = [];
    const readable: string[] = [];
    const probe: RootProbe = this.probeRoot(dir);
    probes.push(probe);
    if (probe.status === 'ok') {
      readable.push(dir);
    }
    const files: MediaFile[] = [];
    const visited: Set<string> = new Set<string>();
    for (let i = 0; i < readable.length; i++) {
      await this.walkCooperative(readable[i], 0, files, visited, shouldStop);
    }
    files.sort((a: MediaFile, b: MediaFile): number => a.name.localeCompare(b.name));
    return { files: files, probes: probes };
  }

  /**
   * 协作式全量扫描：与 scan() 逻辑一致，但在目录之间让出主线程
   *
   * @param shouldStop 可选取消检查：返回 true 立即中止
   */
  async scanCooperative(shouldStop?: () => boolean): Promise<ScanResult> {
    const probes: RootProbe[] = [];
    const readable: string[] = [];
    const accepted: string[] = [];

    // 与 scan() 相同的包含关系去重，理由见 acceptRoot 的注释
    const accept = (dir: string): void => {
      VideoRepository.acceptRoot(dir, accepted, readable);
    };

    const directs: string[] = this.getDirectRoots();
    for (let i = 0; i < directs.length; i++) {
      if (this.stopped(shouldStop)) {
        return { files: [], probes: probes };
      }
      const probe: RootProbe = this.probeRoot(directs[i]);
      probes.push(probe);
      if (probe.status === 'ok') {
        accept(directs[i]);
      }
    }

    const parents: string[] = this.getParentCandidates();
    for (let i = 0; i < parents.length; i++) {
      if (this.stopped(shouldStop)) {
        return { files: [], probes: probes };
      }
      const parent: string = parents[i];
      const parentProbe: RootProbe = this.probeRoot(parent);
      probes.push(parentProbe);
      if (parentProbe.status !== 'ok') {
        continue;
      }
      accept(parent);
      const children: string[] = this.discoverSubDirs(parent);
      for (let j = 0; j < children.length; j++) {
        const child: string = children[j];
        const childProbe: RootProbe = this.probeRoot(child);
        probes.push(childProbe);
        if (childProbe.status === 'ok') {
          accept(child);
        }
      }
      await VideoRepository.yieldToUi();
    }

    const files: MediaFile[] = [];
    const visited: Set<string> = new Set<string>();
    for (let i = 0; i < readable.length; i++) {
      if (this.stopped(shouldStop)) {
        break;
      }
      await this.walkCooperative(readable[i], 0, files, visited, shouldStop);
    }

    files.sort((a: MediaFile, b: MediaFile): number => a.name.localeCompare(b.name));
    return { files: files, probes: probes };
  }

  /** 是否已被取消 */
  private stopped(shouldStop?: () => boolean): boolean {
    return shouldStop !== undefined && shouldStop();
  }

  /**
   * 把一个目录纳入扫描根，并处理它与已有根的包含关系
   *
   * ★ 2026-09-29 自检新增。为什么必须处理包含关系：
   *
   *   getParentCandidates() 里同时列了 '/storage/media' 和
   *   '/storage/media/100/local/files'，而 '/mnt/user' 与沙箱目录
   *   也可能互为父子。原先只比较「完全相等的路径」，
   *   于是父目录和它的子目录都被当作独立扫描根：
   *     · 同一个文件被 walk 两次 -> 列表里出现重复条目；
   *     · MAX_FILES=3000 的配额被重复项白白吃掉，真实文件反而被截断。
   *
   *   规则：
   *     · 已经等于某个已接受根，或被它覆盖（是其子目录）-> 忽略；
   *     · 反过来是某个已接受根的父目录 -> 把那些更窄的根移除，
   *       因为父目录一走，子目录必然被重复遍历。
   *
   * @param dir 待接受的目录
   * @param accepted 已接受的根（会被就地修改）
   * @param readable 实际要遍历的根（会被就地修改）
   */
  private static acceptRoot(dir: string, accepted: string[], readable: string[]): void {
    for (let i = 0; i < accepted.length; i++) {
      const exist: string = accepted[i];
      if (exist === dir) {
        return;
      }
      // dir 是已接受根的子目录 -> 已被覆盖
      if (dir.startsWith(exist + '/')) {
        return;
      }
    }
    // dir 是已接受根的父目录 -> 反过来吞掉那些更窄的根
    for (let i = accepted.length - 1; i >= 0; i--) {
      if (accepted[i].startsWith(dir + '/')) {
        const dup: string = accepted[i];
        accepted.splice(i, 1);
        for (let j = readable.length - 1; j >= 0; j--) {
          if (readable[j] === dup) {
            readable.splice(j, 1);
          }
        }
      }
    }
    accepted.push(dir);
    readable.push(dir);
  }

  /**
   * 让出主线程一次
   *
   * 用 setTimeout(0) 而不是 Promise.resolve()：后者只是微任务，
   * 仍然排在同一个宏任务里执行完，渲染与输入事件根本没有机会插进来。
   */
  private static async yieldToUi(): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, 0);
    });
  }

  /**
   * 协作式递归遍历
   *
   * 与同步版 walk 的差异只有两点：
   *   ① 每进入一层子目录前 await 一次，把主线程让出去；
   *   ② 每次让出前后都检查取消标志，页面销毁后立刻收手。
   * 收集规则（深度上限、数量上限、visited 去重、可播放格式判定）完全一致。
   */
  private async walkCooperative(dir: string, depth: number, out: MediaFile[],
                                visited: Set<string>,
                                shouldStop?: () => boolean): Promise<void> {
    if (depth > MAX_DEPTH || out.length >= MAX_FILES) {
      return;
    }
    if (visited.has(dir)) {
      return;
    }
    if (this.stopped(shouldStop)) {
      return;
    }
    visited.add(dir);
    let entries: string[] = [];
    try {
      entries = fileIo.listFileSync(dir);
    } catch (err) {
      return;
    }

    for (let i = 0; i < entries.length; i++) {
      if (out.length >= MAX_FILES) {
        return;
      }
      const name: string = entries[i];
      const full: string = dir + '/' + name;
      let isDir: boolean = false;
      let size: number = 0;
      try {
        const info = fileIo.statSync(full);
        isDir = info.isDirectory();
        size = info.size;
      } catch (err) {
        continue;
      }
      if (isDir) {
        await this.walkCooperative(full, depth + 1, out, visited, shouldStop);
        // 每下降一层就让一次，避免"目录树很深"时连续占用主线程
        await VideoRepository.yieldToUi();
        if (this.stopped(shouldStop)) {
          return;
        }
      } else if (isPlayableMedia(name)) {
        out.push(buildMediaFile(full, size));
      }
    }
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

    // ★ 2026-09-29 自检修正：候选根之间存在包含关系，会重复扫描
    //   规则与理由集中在 acceptRoot 里，与协作式扫描共用同一份实现，
    //   避免两处各写一遍而慢慢走样。
    const accept = (dir: string): void => {
      VideoRepository.acceptRoot(dir, accepted, readable);
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
    // ★ 2026-09-29：与 scanSingleDir 同理，visited 兜底去重
    //   accept() 已尽量剔除互为父子的根，但候选根里仍可能存在
    //   「兄弟目录下的同一子树」（例如符号链接/挂载点指向同一处），
    //   visited 保证任何目录只被真实遍历一次。
    const visited: Set<string> = new Set<string>();
    for (let i = 0; i < readable.length; i++) {
      this.walk(readable[i], 0, files, visited);
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
   * @param visited 已遍历过的目录集合，保证同一目录不会被重复遍历
   */
  private walk(dir: string, depth: number, out: MediaFile[], visited: Set<string>): void {
    if (depth > MAX_DEPTH || out.length >= MAX_FILES) {
      return;
    }
    if (visited.has(dir)) {
      return;
    }
    visited.add(dir);
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
        this.walk(full, depth + 1, out, visited);
      } else if (isPlayableMedia(name)) {
        out.push(buildMediaFile(full, size));
        if (out.length >= MAX_FILES) {
          return;
        }
      }
    }
  }
}
