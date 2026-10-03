import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import {
  HERO_EMPTY, NAV_ITEMS, HeroItem, VideoItem, FolderItem, NavItem, formatDuration
} from '../common/MediaData';
import { HeroBanner } from '../view/HeroBanner';
import { MediaCard } from '../view/MediaCard';
import { FolderCard } from '../view/FolderCard';
import { FloatingNav } from '../view/FloatingNav';
import { ToastView, TOAST_BOTTOM_OFFSET } from '../view/ToastView';
import { showToast, initToast } from '../common/Toast';
import { WatchHistory, WatchRecord } from '../model/WatchHistory';
import { FolderRepository, MediaFolder } from '../model/FolderRepository';
import { ThumbnailProvider, ThumbStats } from '../model/ThumbnailProvider';
import { DiagLog } from '../model/DiagLog';

/**
 * 刷新动画的最短展示时长（毫秒）
 * 数据加载只要几毫秒，若立即收起动画，用户会感觉"什么都没发生"。
 * 保留一段可见的动画时间，刷新才有反馈感。
 */
const MIN_REFRESH_VISIBLE_MS: number = 600;

/**
 * 媒体库首页
 *
 * 三块内容现在都由真实数据驱动：
 *   - 焦点推荐位：最近一条「未播完」的观看记录，点击直接续播
 *   - 最近播放：全部观看记录，按时间倒序
 *   - 我的文件夹：沙箱 files 目录下的真实文件夹 + 一个「新建文件夹」入口
 *
 * 数据刷新时机：aboutToAppear（首次进入）+ onPageShow（从播放页返回），
 * 因此播放进度变化后回到首页能立刻看到更新的进度线。
 */
@Entry
@Component
struct Index {
  /** 焦点推荐位数据 */
  @State hero: HeroItem = HERO_EMPTY;
  /** 最近播放列表 */
  @State videos: VideoItem[] = [];
  /** 我的文件夹列表 */
  @State folders: FolderItem[] = [];
  /** 底部导航数据 */
  @State navItems: NavItem[] = NAV_ITEMS;
  /** 当前选中的底部导航下标 */
  @State activeNavIndex: number = 0;
  /** Toast 文本，空串表示隐藏 */
  @State toastText: string = '';
  /** 是否正在下拉刷新（只允许通过 setRefreshing 修改，便于诊断） */
  @State refreshing: boolean = false;
  /** 后台是否还在补封面（刷新已结束但封面未全部就绪） */
  @State thumbsPending: boolean = false;
  /**
   * 本次刷新的同步任务是否已完成
   * 用于和 RefreshStatus 状态回调配合：
   * 只有当「任务完成」且「组件已进入 Refresh 态」两个条件都满足，才收起动画。
   * 直接置 false 会抢在组件进入 Refresh 态之前，导致动画卡住。
   */
  private refreshWorkDone: boolean = false;
  /** 组件是否已进入 RefreshStatus.Refresh 态 */
  private refreshStateActive: boolean = false;
  /** 本次刷新动画点亮的时间戳，用于计算最短展示时长 */
  private refreshShownAt: number = 0;
  /** 收尾定时器（等待最短展示时长用） */
  private refreshFinishTimer: number = -1;
  /** 下拉刷新的最小回调间隔，避免连续触发时重复加载 */
  private lastRefreshAt: number = 0;
  /** Toast 自动隐藏定时器 */
  private toastTimer: number = -1;
  /** 观看记录仓库 */
  private history: WatchHistory | undefined = undefined;
  /** 文件夹仓库 */
  private folderRepo: FolderRepository | undefined = undefined;
  /** 视频内置封面提供者（需要 cacheDir，故在 aboutToAppear 里构造） */
  private thumbs: ThumbnailProvider | undefined = undefined;
  /** 诊断日志：把关键事件写进沙箱文件，便于用实际数据定位问题 */
  private diag: DiagLog | undefined = undefined;

  // ==================== 后台封面任务的调度状态（2026-09-29 自检新增） ====================
  //
  // 背景：一次进入首页会**触发两次**封面任务 ——
  //   aboutToAppear→refreshData→loadWatchData→attachThumbnails，
  //   紧接着 onPageShow 又走一遍同样的链（ArkUI 首次进入时两者接连发生）；
  //   下拉刷新那次更直接：loadWatchData 里一次 + onPullRefresh 里显式再一次。
  //   两次任务同时遍历同一批记录，ThumbnailProvider 的 inFlight 去重会把
  //   后一次直接判成"提取失败"，日志里刷出一片假的 THUMB FAIL，
  //   真正失败的原因反而被淹没；两次都结束还会各自重建一次列表。
  //   所以这里做**单飞 + 合并**：正在跑就只记一个"跑完再来一轮"的标记。
  /**
   * 页面当前是否不活跃（被别的页面盖住，或已经销毁）
   *
   * 为什么不叫 disposed：ArkUI 里 `aboutToDisappear` 在"页面被 push 覆盖"
   * 和"页面真的被销毁"两种情况下都可能触发，而**重新回到前台时
   * 只会走 onPageShow、不会重走 aboutToAppear**。
   * 如果把它当成"已销毁"一次性标志，返回首页后封面任务就再也不会启动了。
   * 所以它的真实语义是"现在别在后台干活"，并在 onPageShow 里复位。
   */
  private pageSuspended: boolean = false;
  /** 封面任务是否正在执行 */
  private thumbJobRunning: boolean = false;
  /** 执行期间又被请求过一次：跑完再来一轮，确保覆盖最新记录 */
  private thumbRerunRequested: boolean = false;
  /** 任务代号；递增即让在跑的任务自行退出（用于取消） */
  private thumbJobSeq: number = 0;

  aboutToAppear(): void {
    // 把 UIContext 交给公共提示模块，使其可在任意页面调用系统 Toast/对话框。
    initToast(this.getUIContext());
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.diag = new DiagLog(ctx);
      this.history = new WatchHistory(ctx);
      this.folderRepo = new FolderRepository(ctx);
      // 缩略图缓存放 cache 目录：系统可回收，也不占用户可见空间
      // 需要 bundleName 来拼 file:// URI（Image() 不接受绝对路径）
      const bundle: string = ctx.abilityInfo.bundleName;
      this.thumbs = new ThumbnailProvider(ctx.cacheDir, bundle);
      this.writeDiag('Index aboutToAppear historyFile=' + this.history.getFilePath());
    } catch (err) {
      console.error('init repositories failed: ' + JSON.stringify(err));
    }
    this.refreshData();
  }

  /** 从播放页返回时重新加载，保证进度与记录是最新的 */
  onPageShow(): void {
    this.writeDiag('Index onPageShow');
    // ★ 2026-09-29：回到前台即解除挂起。
    //   必须放在这里而不是 aboutToAppear —— 从播放页返回时只走 onPageShow，
    //   不复位的话封面任务会一直被 aboutToDisappear 立的标志挡住，
    //   表现为"从播放页回来后所有卡片都没有封面"。
    this.pageSuspended = false;
    this.thumbRerunRequested = false;
    // ★ 2026-09-29 自检修正：把底部导航的高亮复位回「首页」。
    //
    //   FloatingNav 的 onClick 会先 `this.activeIndex = index`（@Link 直通本页的
    //   activeNavIndex），再由 onNavSelect 跳去搜索/网络流/设置页。
    //   而跳走之后本页并没有把高亮改回来 —— 从搜索页返回首页时，
    //   底部胶囊里亮着的仍然是「🔍」，可用户眼前明明是首页，
    //   看起来像"导航卡在了另一个页面"。
    //   Index 永远是第 0 项（首页），回到前台就该复位。
    this.activeNavIndex = 0;
    // 播放页的 aboutToDisappear 可能与本次回调几乎同时执行，
    // 而 WatchHistory 有内存缓存，直接读会拿到旧数据。
    // 因此这里先让缓存失效，强制从磁盘重读，保证拿到最终进度。
    // （不再用"延迟 400ms 补读"的做法：那会让焦点位在页面显示后再跳变一次，
    //   用户会感觉"视频变成了另一个"。）
    const repo: WatchHistory | undefined = this.history;
    if (repo !== undefined) {
      repo.invalidateCache();
    }
    this.refreshData();
  }

  /**
   * 离开页面时强制复位刷新状态
   * 防止刷新途中切页面导致标记残留，下次进来动画直接不转
   */
  onPageHide(): void {
    this.clearRefreshTimer();
    this.refreshWorkDone = false;
    this.refreshStateActive = false;
    this.setRefreshing(false, 'onPageHide');
  }

  /** 清掉收尾定时器，避免页面隐藏后回调继续触发 */
  private clearRefreshTimer(): void {
    if (this.refreshFinishTimer !== -1) {
      clearTimeout(this.refreshFinishTimer);
      this.refreshFinishTimer = -1;
    }
  }

  /**
   * 统一设置刷新状态并记录日志
   * 动画不消失这类问题靠看代码定位不了，必须知道每次赋值的时机与来源
   * @param value 目标状态
   * @param from 调用来源，用于日志区分
   */
  private setRefreshing(value: boolean, from: string): void {
    this.writeDiag('setRefreshing ' + value.toString() + ' from=' + from);
    this.refreshing = value;
  }

  /** 写诊断日志（diag 未初始化时静默忽略） */
  private writeDiag(message: string): void {
    const d: DiagLog | undefined = this.diag;
    if (d !== undefined) {
      d.log('Index', message);
    }
  }

  aboutToDisappear(): void {
    // ★ 2026-09-29：先立标志再清定时器。
    //   封面任务可能正卡在一次抽帧上（软解抽帧几百毫秒起步），
    //   用户这时切走，它醒来后仍会继续遍历并写 @State ——
    //   对已销毁组件赋值属于未定义行为。
    //   序号自增让在跑的那一轮在下一个检查点立刻退出。
    this.pageSuspended = true;
    this.thumbJobSeq++;
    this.thumbRerunRequested = false;
    this.clearToastTimer();
    this.clearRefreshTimer();
  }

  /** 清除 Toast 定时器，避免页面销毁后回调仍然触发 */
  private clearToastTimer(): void {
    if (this.toastTimer !== -1) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  /* ============================================================
     数据加载
     ============================================================ */

  /** 重新加载观看记录与文件夹列表，并同步到界面状态 */
  private refreshData(): void {
    this.loadDataSync();
    this.loadFolders();
  }

  /** 只做同步部分：读记录、生成列表数据（封面走异步） */
  private loadDataSync(): void {
    this.loadWatchData();
  }

  /**
   * 下拉刷新的处理
   * 与普通 refreshData 的区别：会等封面提取完成后才结束刷新动画，
   * 这样用户能直接看到"刷完了"的效果，而不是动画先结束、封面再一张张冒出来
   */
  private onPullRefresh(): void {
    // 防抖：0.8 秒内重复下拉直接忽略
    const now: number = Date.now();
    if (now - this.lastRefreshAt < 800) {
      this.writeDiag('onPullRefresh 被防抖拦截');
      this.refreshWorkDone = true;
      this.tryFinishRefresh();
      return;
    }
    this.lastRefreshAt = now;
    this.writeDiag('onPullRefresh 开始同步加载');

    // ---- 同步部分：只做本地读取，非常快 ----
    this.loadWatchData();
    this.loadFolders();

    // ---- 异步部分：后台补封面，不阻塞动画 ----
    this.thumbsPending = true;
    this.attachThumbnailsInBackground(this.loadRecordsForRefresh(), this.currentHeroRecord());

    // ★ 只标记"任务已完成"，是否收起动画交给状态回调判断
    this.refreshWorkDone = true;
    this.tryFinishRefresh();
  }

  /**
   * 尝试收起刷新动画
   *
   * 三个条件都满足才允许收起：
   *   1) 同步刷新任务已完成（refreshWorkDone）
   *   2) 组件确实处于刷新态（refreshStateActive）
   *      —— 不满足会在组件进入 Refresh 态前抢跑，导致动画卡死
   *   3) 动画已展示达到最短时长（MIN_REFRESH_VISIBLE_MS）
   *      —— 不满足则延迟收尾，否则动画一闪而过、用户没有刷新感
   */
  private tryFinishRefresh(): void {
    if (!this.refreshWorkDone || !this.refreshStateActive) {
      this.writeDiag('tryFinishRefresh 暂不收尾 workDone='
        + this.refreshWorkDone.toString()
        + ' stateActive=' + this.refreshStateActive.toString());
      return;
    }
    const elapsed: number = Date.now() - this.refreshShownAt;
    const remain: number = MIN_REFRESH_VISIBLE_MS - elapsed;
    if (remain > 0) {
      // 动画刚点亮，等补足最短展示时长再收尾
      this.writeDiag('tryFinishRefresh 延迟 ' + remain.toString() + 'ms 收尾');
      this.scheduleFinish(remain);
      return;
    }
    this.finishRefreshNow();
  }

  /** 延迟收尾（定时器幂等，重复调用只保留一个） */
  private scheduleFinish(delayMs: number): void {
    if (this.refreshFinishTimer !== -1) {
      return;
    }
    this.refreshFinishTimer = setTimeout(() => {
      this.refreshFinishTimer = -1;
      this.finishRefreshNow();
    }, delayMs);
  }

  /** 立即收尾 */
  private finishRefreshNow(): void {
    if (this.refreshFinishTimer !== -1) {
      clearTimeout(this.refreshFinishTimer);
      this.refreshFinishTimer = -1;
    }
    this.refreshWorkDone = false;
    this.setRefreshing(false, 'work-done-and-state-active');
  }

  /**
   * 后台补封面
   * 任何异常都不外抛，结束时清掉待办标记
   */
  private async attachThumbnailsInBackground(records: WatchRecord[],
    hero: WatchRecord | undefined): Promise<void> {
    try {
      await this.attachThumbnails(records, hero);
    } catch (err) {
      console.error('background thumbnails failed: ' + JSON.stringify(err));
    } finally {
      this.thumbsPending = false;
    }
  }

  /** 读一次记录（供刷新时复用，避免重复读盘） */
  private loadRecordsForRefresh(): WatchRecord[] {
    const repo: WatchHistory | undefined = this.history;
    if (repo === undefined) {
      return [];
    }
    try {
      return repo.list();
    } catch (err) {
      console.error('loadRecordsForRefresh failed: ' + JSON.stringify(err));
      return [];
    }
  }

  /** 取当前焦点位对应的记录，供刷新后补封面使用 */
  private currentHeroRecord(): WatchRecord | undefined {
    const repo: WatchHistory | undefined = this.history;
    if (repo === undefined) {
      return undefined;
    }
    return repo.latestUnfinished();
  }

  /** 把观看记录转换成首页需要的三份数据 */
  private loadWatchData(): void {
    const repo: WatchHistory | undefined = this.history;
    if (repo === undefined) {
      return;
    }
    // 记录文件损坏等情况不应导致首页空白
    let records: WatchRecord[] = [];
    try {
      records = repo.list();
    } catch (err) {
      console.error('list history failed: ' + JSON.stringify(err));
      records = [];
    }
    this.writeDiag('Index loadWatchData count=' + records.length.toString()
      + ' unfinished=' + repo.listUnfinished().length.toString());

    // ---- 最近播放：全部记录 ----
    const items: VideoItem[] = [];
    for (let i = 0; i < records.length; i++) {
      // 保留已有封面：重新构造 item 时 thumb 会丢失，
      // 而封面提取有缓存，如果每次都重新赋值会造成列表无谓重绘
      items.push(this.toVideoItem(records[i]));
    }
    // 诊断：本次构造出来的条目里有多少带了封面，以及缓存命中情况
    let withThumb: number = 0;
    const paths: string[] = [];
    for (let i = 0; i < items.length; i++) {
      paths.push(items[i].path);
      if (items[i].thumbPath.length > 0) {
        withThumb++;
      }
    }
    const changed: boolean = this.assignVideos(items);
    const provider: ThumbnailProvider | undefined = this.thumbs;
    const snap: string = provider === undefined ? 'provider=undefined' : provider.cacheSnapshot(paths);
    this.writeDiag('loadWatchData 带封面=' + withThumb.toString() + '/' + items.length.toString()
      + ' changed=' + changed.toString() + ' | ' + snap);

    // ---- 焦点推荐位 ----
    // 优先展示「最近一条未播完」的记录用于续播；
    // 若全部已看完（或还没有任何记录），退回展示最近一条记录作为「重新观看」入口。
    // 这样焦点位不会因为「都看完了」而退回成空白提示。
    const unfinished: WatchRecord | undefined = repo.latestUnfinished();
    if (unfinished !== undefined) {
      this.hero = this.toHeroItem(unfinished, false);
    } else if (records.length > 0) {
      this.hero = this.toHeroItem(records[0], true);
    } else {
      this.hero = HERO_EMPTY;
    }

    // ---- 异步补上视频内置封面 ----
    // 提取帧是耗时操作，不能阻塞列表渲染，因此先出列表再逐张填充
    this.attachThumbnails(records, unfinished);
  }

  /**
   * 为记录异步提取内置封面
   * 已提取过的路径直接命中缓存，不会重复解码
   *
   * ★ 2026-09-29 自检修正：加了**单飞 + 合并 + 可取消**三件事。
   *   原因见 pageSuspended / thumbJobRunning 那段说明：
   *   一次进入首页本就会触发两轮相同任务，两轮并发会让
   *   ThumbnailProvider 的 inFlight 去重把后一轮判成失败，
   *   日志里刷出一片假的 THUMB FAIL，真正的失败原因被淹没。
   */
  private async attachThumbnails(records: WatchRecord[], hero: WatchRecord | undefined): Promise<void> {
    // ---- 单飞：已经在跑就只登记"跑完再来一轮"，不并发第二轮 ----
    if (this.thumbJobRunning) {
      this.thumbRerunRequested = true;
      this.writeDiag('THUMB 已有任务在跑，本次合并为跑完后重跑一轮');
      return;
    }
    if (this.pageSuspended) {
      this.writeDiag('THUMB 页面不在前台，跳过本轮');
      return;
    }
    this.thumbJobRunning = true;
    // 本轮代号；aboutToDisappear 会自增它来取消本轮
    const token: number = ++this.thumbJobSeq;

    // 整个方法包在 try 里：封面只是锦上添花，
    // 任何异常都不能连带影响已经加载好的列表数据
    try {
      const provider: ThumbnailProvider | undefined = this.thumbs;
      if (provider === undefined) {
        return;
      }
      for (let i = 0; i < records.length; i++) {
        // 每个记录之间检查一次：页面切走/被取消就立刻停手
        if (this.pageSuspended || token !== this.thumbJobSeq) {
          this.writeDiag('THUMB 任务被取消，已处理 ' + i.toString() + ' 条');
          return;
        }
        const record: WatchRecord = records[i];
        const thumbFile: string = await provider.generate(record.path);
        if (this.pageSuspended || token !== this.thumbJobSeq) {
          this.writeDiag('THUMB 任务被取消（抽帧返回后）');
          return;
        }
        if (thumbFile.length === 0) {
          // 抓帧失败必须留下原因，否则界面上只会看到"没有封面"而无从排查
          const st = provider.stats();
          let detail: string = 'no-attempt';
          if (st.lastAttempts.length > 0) {
            const a = st.lastAttempts[0];
            detail = a.mode + '@' + a.timeUs.toString() + ' err=' + a.error
              + ' (尝试' + st.lastAttempts.length.toString() + '次)';
          }
          this.writeDiag('THUMB FAIL ' + record.path + ' :: ' + detail
            + ' | ' + provider.getLastFrameInfo());
          continue;
        }
        this.writeDiag('THUMB OK ' + record.path + ' -> ' + thumbFile);
      }

      // ★ 全部生成完成后，统一从缓存重建一次界面数据。
      //
      // 为什么不在循环里逐个局部刷新：
      //   重建 item 时 thumbPath 来自缓存命中，而缓存写入时机与
      //   loadWatchData 的重建时机存在竞争 —— 局部拼装出来的值
      //   可能被后续一次重建清空，表现为"有的卡片有封面、有的没有"。
      //   统一重建则完全确定：缓存已写好，peek 必然命中。
      this.writeDiag('THUMB 全部生成结束，开始统一重建');
      this.rebuildWithThumbs();
    } catch (err) {
      console.error('attachThumbnails failed: ' + JSON.stringify(err));
    } finally {
      this.thumbJobRunning = false;
      // 执行期间又来过请求：用最新记录再跑一轮，保证不丢更新
      if (this.thumbRerunRequested && !this.pageSuspended) {
        this.thumbRerunRequested = false;
        this.writeDiag('THUMB 执行期间的请求，重跑一轮');
        // 本方法内部已完整 try/catch，不会产生 unhandled rejection；
        // 这里仍显式接住，避免将来改动引入未处理异常
        this.attachThumbnails(this.loadRecordsForRefresh(), this.currentHeroRecord())
          .catch((err: BusinessError) => {
            console.error('thumb rerun failed: ' + JSON.stringify(err));
          });
      } else {
        this.thumbRerunRequested = false;
      }
    }
  }

  /**
   * 用当前缓存里的封面重建列表与焦点位
   * toVideoItem / toHeroItem 内部会通过 thumbPathOf 读到已缓存的文件 URI
   */
  private rebuildWithThumbs(): void {
    // ★ 2026-09-29：页面已切走/销毁就不要再写 @State
    if (this.pageSuspended) {
      this.writeDiag('THUMB 页面不在前台，跳过重建');
      return;
    }
    const provider: ThumbnailProvider | undefined = this.thumbs;
    if (provider === undefined) {
      return;
    }
    const repo: WatchHistory | undefined = this.history;
    if (repo === undefined) {
      return;
    }
    let records: WatchRecord[] = [];
    try {
      records = repo.list();
    } catch (err) {
      this.writeDiag('rebuildWithThumbs 读记录失败');
      return;
    }

    const items: VideoItem[] = [];
    let withThumb: number = 0;
    for (let i = 0; i < records.length; i++) {
      const item: VideoItem = this.toVideoItem(records[i]);
      if (item.thumbPath.length > 0) {
        withThumb++;
      }
      items.push(item);
    }
    const paths: string[] = [];
    for (let i = 0; i < items.length; i++) {
      paths.push(items[i].path);
    }
    // 封面属于"迟到的数据"：即使列表内容看似相同，
    // 只要有条目新拿到了封面，就必须强制重建一次，否则界面不会更新
    const needForce: boolean = withThumb > this.countVideosWithThumb();
    if (needForce) {
      this.forceRebuildVideos(items);
    } else {
      this.assignVideos(items);
    }
    this.writeDiag('THUMB 重建完成 带封面=' + withThumb.toString()
      + '/' + items.length.toString() + ' force=' + needForce.toString()
      + ' | ' + provider.cacheSnapshot(paths));

    // 焦点位同样按缓存重建
    const unfinished: WatchRecord | undefined = repo.latestUnfinished();
    if (unfinished !== undefined) {
      this.hero = this.toHeroItem(unfinished, false);
    } else if (records.length > 0) {
      this.hero = this.toHeroItem(records[0], true);
    }
  }

  /** 当前列表里已有封面路径的条目数 */
  private countVideosWithThumb(): number {
    let n: number = 0;
    for (let i = 0; i < this.videos.length; i++) {
      if (this.videos[i].thumbPath.length > 0) {
        n++;
      }
    }
    return n;
  }

  /** 卡片渲染回报的抽样计数，避免日志刷屏 */
  private renderReportCount: number = 0;

  /**
   * 卡片挂载回报
   * 只记录前 6 条，足够判断封面路径有没有真的传到组件里
   * @param title 卡片标题
   * @param thumbPath 组件收到的封面路径
   */
  private reportCardRendered(title: string, thumbPath: string): void {
    if (this.renderReportCount >= 6) {
      return;
    }
    this.renderReportCount++;
    this.writeDiag('CARD 渲染 title=' + title
      + ' thumbPath=' + (thumbPath.length === 0 ? '(空)' : thumbPath));
  }

  /** 取某视频已缓存的封面文件路径（未提取则为空串） */
  private thumbPathOf(videoPath: string): string {
    const t: ThumbnailProvider | undefined = this.thumbs;
    return t === undefined ? '' : t.peek(videoPath);
  }

  /**
   * 判断两份列表在"会显示出来的字段"上是否完全一致
   * 用于避免无意义的赋值：ArkUI 里只要给 @State 数组重新赋值就会重建整个列表，
   * 即使内容没变。日志里曾出现 THUMB ASSIGN 每秒刷屏几十次，就是反复重建导致的。
   *
   * @param a 旧列表
   * @param b 新列表
   */
  private sameVideoList(a: VideoItem[], b: VideoItem[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i].path !== b[i].path
        || a[i].title !== b[i].title
        || a[i].subtitle !== b[i].subtitle
        || a[i].duration !== b[i].duration
        || Math.abs(a[i].progress - b[i].progress) > 0.0001
        || a[i].thumbPath !== b[i].thumbPath) {
        return false;
      }
    }
    return true;
  }

  /**
   * 受控赋值：内容一致就不赋值，避免触发整列重绘
   * @param next 新列表
   * @returns 是否真的发生了更新
   */
  private assignVideos(next: VideoItem[]): boolean {
    if (this.sameVideoList(this.videos, next)) {
      return false;
    }
    this.videos = next;
    // 列表变了，重置抽样计数以便重新观察卡片收到的值
    this.renderReportCount = 0;
    return true;
  }

  /**
   * 强制重建列表（用于封面补齐后刷新界面）
   *
   * 与 assignVideos 的区别：这里不比较内容，直接用新数组替换。
   * 为什么需要它：实测「数据层已带封面、界面却不更新」——
   * 内容比较为"相同"时跳过赋值，界面就失去了重绘的机会。
   * 封面属于"迟到的数据"，必须强制让列表项重新挂载一次。
   *
   * ★ 2026-09-29 自检修正：删掉了「先 this.videos = [] 再赋新数组」。
   *
   *   原注释说"把数组引用彻底换掉，避免 ArkUI 认为还是同一个数组"，
   *   但 ForEach 的键是 `item.path + '|' + item.thumbPath` ——
   *   thumbPath 变了键就变，ArkUI 本来就会重新挂载对应条目，
   *   不需要把数组清空一次。
   *   而"先清空"的副作用是实打实的：清空的瞬间列表里一行都没有，
   *   紧接着又全部重建 —— 用户看到整列闪一下、滚动位置被顶回顶部，
   *   而这个重建在封面补齐时必然发生一次。
   *
   * @param next 新列表
   */
  private forceRebuildVideos(next: VideoItem[]): void {
    // 直接赋新数组即可：引用已经变了，ForEach 会按 key 差异重新挂载
    this.videos = next;
    this.renderReportCount = 0;
    this.writeDiag('FORCE 重建列表 count=' + next.length.toString());
  }

  /** 观看记录 → 视频卡片数据 */
  private toVideoItem(record: WatchRecord): VideoItem {
    const progress: number = record.duration > 0 ? record.position / record.duration : 0;
    // 统一用 WatchHistory 的判定，保证与「继续观看」口径一致
    const remainMs: number = Math.max(0, record.duration - record.position);
    const subtitle: string = WatchHistory.isUnfinished(record)
      ? ('已看 ' + formatDuration(record.position) + ' · 剩 ' + formatDuration(remainMs))
      : ('已看完 · ' + formatDuration(record.duration));
    return {
      title: record.title,
      duration: formatDuration(record.duration),
      subtitle: subtitle,
      cover: '',
      fallbackColors: this.pickGradient(record.path),
      path: record.path,
      progress: progress,
      // 沿用已提取好的封面路径，避免重建时重复解码
      thumbPath: this.thumbPathOf(record.path)
    };
  }

  /**
   * 观看记录 → 焦点推荐位数据
   * @param record 观看记录
   * @param finished 是否已看完（决定标签是「重新观看」还是「继续观看」）
   */
  private toHeroItem(record: WatchRecord, finished: boolean): HeroItem {
    const progress: number = finished
      ? 0
      : (record.duration > 0 ? record.position / record.duration : 0);
    const remainMs: number = Math.max(0, record.duration - record.position);
    return {
      title: record.title,
      tag: finished ? '重新观看' : '继续观看',
      meta: finished
        ? ('已看完 · ' + formatDuration(record.duration))
        : ('已看 ' + formatDuration(record.position)),
      remain: finished ? '点击从头播放' : ('剩余 ' + formatDuration(remainMs)),
      progress: progress,
      cover: '',
      path: record.path,
      finished: finished,
      thumbPath: this.thumbPathOf(record.path)
    };
  }

  /**
   * 按路径哈希挑一组渐变色
   * 真实记录没有封面图，用稳定的渐变让每张卡片有各自的辨识度
   * @param key 路径
   */
  private pickGradient(key: string): [string, string] {
    const palette: [string, string][] = [
      ['#4A5A6A', '#1C1C1E'],
      ['#C08B4F', '#5A3A1E'],
      ['#7A4FBF', '#E0457B'],
      ['#2C4A6E', '#0E1A26'],
      ['#3F7A5A', '#13301F'],
      ['#8A4A4A', '#2E1414']
    ];
    let hash: number = 0;
    for (let i = 0; i < key.length; i++) {
      hash = (hash * 31 + key.charCodeAt(i)) % 100000;
    }
    return palette[hash % palette.length];
  }

  /**
   * 加载文件夹列表
   * 只包含真实存在的文件夹；「新建文件夹」入口已移到区块标题右侧，
   * 不再作为卡片混在文件夹里（那样容易被误认为是一个空文件夹）
   */
  private loadFolders(): void {
    const repo: FolderRepository | undefined = this.folderRepo;
    if (repo === undefined) {
      return;
    }
    const real: MediaFolder[] = repo.listFolders();
    const items: FolderItem[] = [];
    for (let i = 0; i < real.length; i++) {
      items.push({
        title: real[i].name,
        subtitle: real[i].fileCount.toString() + ' 个文件',
        path: real[i].path
      });
    }
    this.folders = items;
  }

  /* ============================================================
     交互
     ============================================================ */

  /** 跳转到文件搜索页 */
  private openSearch(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SearchPage' }).catch(() => {
      showToast('无法打开搜索页');
    });
  }

  /** 跳转到设置页 */
  private openSettings(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' }).catch(() => {
      showToast('无法打开设置页');
    });
  }

  /**
   * 进入播放页
   * @param path 视频绝对路径；为空时跳搜索页由用户选择
   * @param title 显示标题
   * @param startMs 续播起点（毫秒）
   */
  private openPlayer(path: string, title: string, startMs: number): void {
    if (path.length === 0) {
      this.openSearch();
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/PlayerPage',
      params: { path: path, title: title, startMs: startMs } as PlayerParamsForHome
    }).catch(() => {
      showToast('无法打开播放页');
    });
  }

  /** 点击焦点推荐位 */
  private onHeroClick(): void {
    const path: string = this.hero.path;
    if (path.length === 0) {
      // 还没有观看记录，引导去搜索
      this.openSearch();
      return;
    }
    this.openPlayer(path, this.hero.title, this.resumeMsOf(path));
  }

  /**
   * 取某路径的续播起点（毫秒）
   * 直接问仓库要最新记录再算，避免用界面上可能已过期的 progress
   * @param path 视频绝对路径
   */
  private resumeMsOf(path: string): number {
    const repo: WatchHistory | undefined = this.history;
    if (repo === undefined) {
      return 0;
    }
    const record: WatchRecord | undefined = repo.find(path);
    if (record === undefined) {
      return 0;
    }
    return WatchHistory.resumePosition(record);
  }

  /** 点击视频卡片 */
  private onVideoClick(item: VideoItem): void {
    if (item.path.length === 0) {
      this.openSearch();
      return;
    }
    this.openPlayer(item.path, item.title, this.resumeMsOf(item.path));
  }

  /** 点击文件夹卡片：进入搜索页并限定扫描该目录 */
  private onFolderClick(item: FolderItem): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/SearchPage',
      params: { folderPath: item.path, folderName: item.title } as FolderParams
    }).catch(() => {
      showToast('无法打开文件夹');
    });
  }

  /**
   * 跳转到「新建文件夹」页面
   *
   * 为什么用独立页面：
   *   AlertDialog 在本 SDK 版本不支持文本输入框（无 textField 字段），
   *   CustomDialogController 的 @Builder 引用组件 this 在 ArkTS 里实例化时机不可靠。
   *   独立页面没有这两个问题，输入体验也更好。
   */
  private askCreateFolder(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/FolderCreatePage' }).catch(() => {
      showToast('无法打开新建文件夹页面');
    });
  }

  /** 底部导航点击：首页 / 搜索 / 添加 / 设置 */
  private onNavSelect(index: number, title: string): void {
    if (index === 0) {
      showToast('已在媒体库首页');
      return;
    }
    if (index === 1) {
      this.openSearch();
      return;
    }
    if (index === 2) {
      // 添加视频 / 网络流 → 网络流管理页
      // 说明：底部这个「添加」目前在原型里就是「添加视频/网络流」的入口。
      //   「添加视频」走的是系统文件选择器（SearchPage 的「从手机导入」），
      //   「网络流」则是独立的管理页，所以这里直接进网络流列表，
      //   由列表右上角的「+ 添加」去录地址。
      this.getUIContext().getRouter().pushUrl({ url: 'pages/NetworkStreamPage' }).catch(() => {
        showToast('无法打开网络流页');
      });
      return;
    }
    this.openSettings();
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ================= 页面主体（支持下拉刷新） =================
      // Refresh 是容器组件，只能有一个子组件，因此直接包住原来的 Scroll。
      // refreshing 由 onRefreshing 里的异步任务结束时置回 false，动画收起。
      Refresh({ refreshing: this.refreshing, offset: 64 }) {
          Scroll() {
          Column() {
            // ---------- 顶部导航 (对应 .header) ----------
            Row() {
              Column({ space: 4 }) {
                // ★ 2026-09-29：这里原来是「媒体库」（页面标题的写法）。
                //   应用名已定为「Horizn|视界」，首页是这个软件的门面，
                //   标题跟着用应用名，用户在应用内也能看到自己的软件叫什么。
                //   副标题「发现你的精彩视界」保持不变 —— 它是标语，不是名字。
                Text('Horizn|视界')
                  .fontSize(32)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.TEXT_MAIN)
                  .letterSpacing(-0.5)
                  .textAlign(TextAlign.Start)

                // 点副标题可查看存储诊断（记录条数 / 封面提取情况 / 落盘路径）
                Text('发现你的精彩视界')
                  .fontSize(14)
                  .fontColor(Theme.TEXT_SUB)
                  .textAlign(TextAlign.Start)
                  .onClick(() => {
                    this.showStorageDiag();
                  })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)
            .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, top: 40, bottom: 20 })

            // ---------- 焦点推荐位 (对应 .hero) ----------
            HeroBanner({
              hero: this.hero,
              onPlay: (title: string): void => {
                this.onHeroClick();
              }
            })
              .margin({
                left: Theme.PAGE_PADDING,
                right: Theme.PAGE_PADDING,
                bottom: 32
              })

            // ---------- 横向滑动区域 1：最近播放 ----------
            Column() {
              this.sectionHeader(
                this.videos.length > 0 ? '最近播放' : '还没有播放记录',
                this.videos.length > 0 ? '查看全部 >' : '',
                () => {
                  this.openSearch();
                }
              )

              if (this.videos.length > 0) {
                Scroll() {
                  Row({ space: Theme.CARD_GAP }) {
                    ForEach(this.videos, (item: VideoItem) => {
                      MediaCard({
                        item: item,
                        onPlay: (clicked: VideoItem): void => {
                          this.onVideoClick(clicked);
                        },
                        onRendered: (title: string, thumbPath: string): void => {
                          this.reportCardRendered(title, thumbPath);
                        }
                      })
                    // 键里带上封面路径：封面到位后键变化，
                    // 会强制重建该项组件（与 @Watch 互为双保险）
                    }, (item: VideoItem) => item.path + '|' + item.thumbPath)
                  }
                  .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, top: 4, bottom: 4 })
                }
                .scrollable(ScrollDirection.Horizontal)
                .scrollBar(BarState.Off)
                .edgeEffect(EdgeEffect.Spring)
                .scrollSnap({
                  snapAlign: ScrollSnapAlign.START,
                  snapPagination: Theme.CARD_WIDTH + Theme.CARD_GAP
                })
                .width('100%')
              } else {
                // 空状态：引导用户去搜索页挑一个视频
                Row({ space: 8 }) {
                  Text('🎬')
                    .fontSize(20)
                  Text('去搜索页挑一个视频开始播放，这里会自动记录进度')
                    .fontSize(12)
                    .fontColor(Theme.TEXT_SUB)
                    .layoutWeight(1)
                  Text('去搜索 ›')
                    .fontSize(12)
                    .fontColor(Theme.ACCENT)
                    .onClick(() => {
                      this.openSearch();
                    })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding(16)
                .backgroundColor(Theme.CARD_BG)
                .borderRadius(14)
                .margin({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING })
                .onClick(() => {
                  this.openSearch();
                })
              }
            }
            .margin({ bottom: 32 })

            // ---------- 横向滑动区域 2：我的文件夹 ----------
            Column() {
              // 与「查看全部 >」同款的文字按钮，明确表达这是一个操作
              this.sectionHeader('我的文件夹',
                this.folders.length > 0 ? '新建文件夹 +' : '',
                () => {
                  this.askCreateFolder();
                })

              Scroll() {
                Row({ space: Theme.CARD_GAP }) {
                  ForEach(this.folders, (item: FolderItem) => {
                    FolderCard({
                      item: item,
                      onOpen: (clicked: FolderItem): void => {
                        this.onFolderClick(clicked);
                      }
                    })
                  }, (item: FolderItem) => item.title + '|' + item.path)
                }
                .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, top: 4, bottom: 4 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .edgeEffect(EdgeEffect.Spring)
              .scrollSnap({
                snapAlign: ScrollSnapAlign.START,
                snapPagination: Theme.CARD_WIDTH + Theme.CARD_GAP
              })
              .width('100%')
              .visibility(this.folders.length > 0 ? Visibility.Visible : Visibility.None)

              // 一个文件夹都没有时给出明确入口，而不是留一片空白
              if (this.folders.length === 0) {
                Row({ space: 8 }) {
                  Text('📁')
                    .fontSize(20)
                  Text('还没有文件夹，点右侧「新建文件夹 +」创建一个')
                    .fontSize(12)
                    .fontColor(Theme.TEXT_SUB)
                    .layoutWeight(1)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding(16)
                .backgroundColor(Theme.CARD_BG)
                .borderRadius(14)
                .margin({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING })
                .onClick(() => {
                  this.askCreateFolder();
                })
              }
            }
            .margin({ bottom: 32 })

            // 为底部悬浮导航预留空间 (对应 body padding-bottom)
            Row()
              .height(120)
              .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
          .width('100%')
          .height('100%')
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
      }
      .onRefreshing(() => {
        this.writeDiag('onRefreshing 触发');
        this.refreshWorkDone = false;
        this.onPullRefresh();
      })
      .onStateChange((state: RefreshStatus) => {
        this.writeDiag('onStateChange state=' + state.toString());
        if (state === RefreshStatus.Refresh) {
          // 组件真正进入刷新态：这是权威的"开始刷新"信号，
          // 由它点亮动画，避免与 onRefreshing 的时序竞争
          this.refreshStateActive = true;
          this.refreshShownAt = Date.now();
          this.setRefreshing(true, 'state=Refresh');
          // 若同步任务已经先完成，这里会走最短展示时长的延迟收尾
          this.tryFinishRefresh();
        } else if (state === RefreshStatus.Done || state === RefreshStatus.Inactive) {
          // 组件已回到初始态，标记复位
          this.refreshStateActive = false;
        }
      })

      // ================= 底部悬浮导航 (对应 .floating-nav) =================
      FloatingNav({
        activeIndex: this.activeNavIndex,
        items: this.navItems,
        onSelect: (index: number, title: string): void => {
          this.onNavSelect(index, title);
        }
      })
        .margin({ bottom: 24 })

      // ================= Toast 提示 (对应 .toast) =================
      ToastView({ text: this.toastText })
        .margin({ bottom: TOAST_BOTTOM_OFFSET })
    }
    .width('100%')
    .height('100%')
    // 浅色背景的径向渐变，增加空间感但保持干净 (对应 body background-image)
    .linearGradient({
      angle: 180,
      colors: [[Theme.CARD_BG, 0.0], [Theme.BG, 0.7]]
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 显示存储诊断信息
   * 用于确认观看记录到底写没写进去、封面提取成功几张
   */
  private showStorageDiag(): void {
    const repo: WatchHistory | undefined = this.history;
    if (repo === undefined) {
      showToast('观看记录仓库未初始化');
      return;
    }
    let count: number = 0;
    try {
      count = repo.list().length;
    } catch (err) {
      count = -1;
    }
    const provider: ThumbnailProvider | undefined = this.thumbs;
    const st: ThumbStats = provider === undefined ? EMPTY_THUMB_STATS : provider.stats();
    const d: DiagLog | undefined = this.diag;
    const diagPath: string = d !== undefined ? d.getFilePath() : '(未初始化)';
    // 内存条数 vs 磁盘条数：两者不一致即说明写盘有问题
    // 把首次抓帧的失败原因也带出来，否则只能看到"成功 0 张"这种无用信息
    let attemptInfo: string = '无尝试记录';
    if (st.lastAttempts.length > 0) {
      const a = st.lastAttempts[0];
      attemptInfo = a.mode + '@' + a.timeUs.toString() + ' ' + (a.ok ? 'OK' : a.error);
    }
    const msg: string = '内存:' + count.toString()
      + ' ' + repo.readFromDiskInfo()
      + '\n封面:' + st.success.toString() + '/' + st.tried.toString()
      + '\n抓帧:' + (provider === undefined ? '(未初始化)' : provider.getLastFrameInfo())
      + ' 首试:' + attemptInfo
      + '\n上次写入: ' + repo.getLastPersistResult();
    showToast(msg);
    this.writeDiag('DIAG ' + msg.replace(/\n/g, ' | '));
    console.info('[StorageDiag] ' + msg);
  }

  /**
   * 区块标题行 (对应 .section-header)
   * @param title 区块标题
   * @param more 右侧更多文案，空串表示不显示
   * @param onMore 更多按钮点击回调
   */
  @Builder
  sectionHeader(title: string, more: string, onMore: () => void) {
    Row() {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.TEXT_MAIN)
        .letterSpacing(0.5)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)

      if (more.length > 0) {
        Text(more)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            onMore();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, bottom: 12 })
  }

}

/** 缩略图统计的空值（provider 未初始化时使用） */
const EMPTY_THUMB_STATS: ThumbStats = { tried: 0, success: 0, lastAttempts: [] };

/** 首页传给播放页的参数结构（字段需与 PlayerParams 一致） */
interface PlayerParamsForHome {
  path: string;
  title: string;
  startMs: number;
}

/** 首页传给搜索页的参数结构：限定只扫描某个文件夹 */
interface FolderParams {
  folderPath: string;
  folderName: string;
}
