import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { MediaFile, formatSize } from '../common/MediaFiles';
import { MediaTier, tierLabel } from '../common/MediaType';
import { VideoRepository, ScanResult, RootProbe } from '../model/VideoRepository';
import { requestScanPermissions, SCAN_PERMISSIONS } from '../common/FilePermission';
import { showToast, initToast, confirmDialog } from '../common/Toast';
import { MediaImporter, ImportResult } from '../model/MediaImporter';
import { MediaFileOps } from '../model/MediaFileOps';
import { FolderRepository, MediaFolder } from '../model/FolderRepository';
import { nativeProbe, nativeBuildInfo } from 'libsoftplayer.so';
/**
 * 文件搜索页
 *
 * 扫描流程：
 *   1) 探测一批候选媒体目录，区分「可读 / 无权限 / 不存在」
 *   2) 只对可读目录做递归遍历，按后缀白名单收集媒体文件
 *   3) 输入框按文件名实时过滤，点击结果进入播放器
 *
 * 「扫描目录」面板会显示每个候选目录的真实状态，
 * 如果没搜到视频，看这个面板就能知道是目录不存在还是缺权限。
 */
@Entry
@Component
struct SearchPage {
  /** 搜索关键词 */
  @State keyword: string = '';
  /** 扫描到的全部媒体文件 */
  @State allFiles: MediaFile[] = [];
  /** 过滤后的结果 */
  @State results: MediaFile[] = [];
  /** 是否正在扫描 */
  @State scanning: boolean = false;
  /** 是否已至少扫描过一次 */
  @State scanned: boolean = false;
  /** 全部候选目录的探测结果 */
  @State probes: RootProbe[] = [];
  /** 是否展开目录诊断面板 */
  @State showDiag: boolean = false;
  /** 公共目录权限是否已授予（扫描结果提示用；未授予时只扫沙箱） */
  @State publicGranted: boolean = false;
  /**
   * 原生模块探针结果
   * 阶段 1 的验收依据：能拿到值就说明
   * C++ 编译 → .so 打包 → NAPI 注册 → ArkTS 调用 这条链路全部打通
   */
  @State nativeProbeText: string = '';
  /** 限定的扫描目录：非空时只扫描该目录（来自首页「打开文件夹」） */
  private limitedDir: string = '';
  /**
   * 上次发起跳转播放页的时间戳（毫秒）
   *
   * 用途：拦住连点。极快地在播放页与搜索页之间来回切会让 ArkUI
   * 反复创建/销毁 XComponent 的 Surface 渲染节点，进而与原生侧写入撞车
   * ——实测崩溃在 RSSurfaceNode 析构里。见 openFile 的说明。
   */
  private lastOpenAt: number = 0;
  /** 限定目录的显示名 */
  @State limitedDirName: string = '';
  /** 仓库实例 */
  private repository: VideoRepository | undefined = undefined;
  /** 导入器实例 */
  private importer: MediaImporter | undefined = undefined;
  /** 是否正在导入（复制大文件耗时，需要禁用按钮并提示） */
  @State importing: boolean = false;
  /** 文件夹仓库，用于「移动文件」的目标目录选择 */
  private folderRepo: FolderRepository | undefined = undefined;
  /** 当前被长按选中的文件（长按菜单需要它作为操作目标） */
  private menuTarget: MediaFile | undefined = undefined;
  /** 移动时展示的目标目录清单 */
  @State moveTargets: string[] = [];
  /** 是否展示移动目录选单 */
  @State showMoveMenu: boolean = false;
  /** 当前被按下的列表项路径（用于按压缩放反馈） */
  @State pressedPath: string = '';

  aboutToAppear(): void {
    initToast(this.getUIContext());
    this.probeNativeModule();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.repository = new VideoRepository(ctx);
    this.importer = new MediaImporter(ctx);
    this.folderRepo = new FolderRepository(ctx);
    // 若从首页某个文件夹进来，则只扫描该目录
    const params = this.getUIContext().getRouter().getParams() as FolderParamsForSearch;
    if (params !== undefined && params !== null) {
      if (params.folderPath !== undefined && params.folderPath.length > 0) {
        this.limitedDir = params.folderPath;
        this.limitedDirName = params.folderName !== undefined ? params.folderName : '';
      }
    }
    this.startScan();
  }

  aboutToDisappear(): void {
    this.scanning = false;
  }

  /**
   * 从手机导入视频（系统文件选择器）
   *
   * 这是真机上唯一可靠的「访问手机任意位置文件」途径：
   *   HarmonyOS 沙箱不允许应用任意扫描目录，
   *   而公共目录权限（READ_WRITE_DOWNLOAD_DIRECTORY）在真机上实测常常拿不到。
   *   文件选择器由用户主动选择，无需任何权限。
   *
   * 导入后文件被复制到应用沙箱，之后扫描、封面、播放、进度记录全部复用现有流程。
   */
  private async importFromPhone(): Promise<void> {
    const imp: MediaImporter | undefined = this.importer;
    if (imp === undefined) {
      showToast('导入器未就绪');
      return;
    }
    if (this.importing) {
      showToast('正在导入，请稍候');
      return;
    }
    this.importing = true;
    showToast('请选择要导入的视频文件');
    try {
      const result: ImportResult = await imp.pickAndImport();
      if (result.imported > 0) {
        showToast('已导入 ' + result.imported.toString() + ' 个文件'
          + (result.skipped > 0 ? '，' + result.skipped.toString() + ' 个被跳过' : ''));
        // 重新扫描，让导入的文件立刻出现在列表里
        await this.startScan();
      } else if (result.skipped > 0) {
        showToast('导入失败：' + result.skipped.toString() + ' 个文件未能复制');
      } else {
        showToast(result.error.length > 0 ? result.error : '未选择文件');
      }
    } catch (err) {
      console.error('importFromPhone failed: ' + JSON.stringify(err));
      showToast('导入过程出错');
    } finally {
      this.importing = false;
    }
  }

  /* ============================================================
     长按菜单：重命名 / 文件信息 / 移动
     ============================================================ */

  /**
   * 删除（卸载）文件
   * 二次确认后再删，避免误触
   */
  private async removeTarget(): Promise<void> {
    const target: MediaFile | undefined = this.menuTarget;
    if (target === undefined) {
      return;
    }
    const ok: boolean = await confirmDialog('卸载文件',
      '确定要删除「' + target.name + '」吗？\n此操作不可撤销。');
    if (!ok) {
      return;
    }
    const error: string = MediaFileOps.remove(target.path);
    if (error.length > 0) {
      showToast(error);
      return;
    }
    showToast('已卸载：' + target.name);
    this.menuTarget = undefined;
    // 重新扫描，列表立刻移除该项
    this.startScan();
  }

  /**
   * 调用原生模块探针
   * 失败必须留痕：如果 .so 没打进包或 NAPI 注册名不对，
   * import 会直接抛异常，这里捕获后显示在界面上便于定位
   */
  private probeNativeModule(): void {
    try {
      const a: string = nativeProbe();
      const b: string = nativeBuildInfo();
      this.nativeProbeText = a + ' | ' + b;
      console.info('[NativeProbe] ' + this.nativeProbeText);
    } catch (err) {
      this.nativeProbeText = '原生模块调用失败：' + JSON.stringify(err);
      console.error('[NativeProbe] failed: ' + JSON.stringify(err));
    }
  }

  /** 取路径末段作为目录显示名 */
  private dirNameOf(dir: string): string {
    const slash: number = dir.lastIndexOf('/');
    return slash >= 0 ? dir.substring(slash + 1) : dir;
  }

  /** 长按某个文件：记录下来作为后续操作的目标 */
  private onItemLongPress(item: MediaFile): void {
    this.menuTarget = item;
  }

  /** 跳到重命名页 */
  private openRename(): void {
    const target: MediaFile | undefined = this.menuTarget;
    if (target === undefined) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/RenamePage',
      params: { path: target.path, name: target.name } as RenameParamsForSearch
    }).catch(() => {
      showToast('无法打开重命名页');
    });
  }

  /** 跳到文件详情页 */
  private openDetail(): void {
    const target: MediaFile | undefined = this.menuTarget;
    if (target === undefined) {
      return;
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/FileDetailPage',
      params: { path: target.path, name: target.name, size: target.size } as FileDetailParamsForSearch
    }).catch(() => {
      showToast('无法打开文件信息页');
    });
  }

  /**
   * 准备「移动文件」的目标目录清单
   * 目标限定为应用沙箱内的文件夹 —— 沙箱外应用无权改动
   */
  private prepareMove(): void {
    const repo: FolderRepository | undefined = this.folderRepo;
    if (repo === undefined) {
      showToast('文件夹仓库未就绪');
      return;
    }
    const target: MediaFile | undefined = this.menuTarget;
    const folders: MediaFolder[] = repo.listFolders();
    const dirs: string[] = [];
    for (let i = 0; i < folders.length; i++) {
      // 排除文件当前所在目录，避免"移到原处"
      if (target !== undefined && folders[i].path === target.folder) {
        continue;
      }
      dirs.push(folders[i].path);
    }
    if (dirs.length === 0) {
      showToast('没有其它可用的文件夹，可先新建一个');
      return;
    }
    this.moveTargets = dirs;
    this.showMoveMenu = true;
  }

  /** 执行移动 */
  private doMove(destDir: string): void {
    this.showMoveMenu = false;
    const target: MediaFile | undefined = this.menuTarget;
    if (target === undefined) {
      return;
    }
    const error: string = MediaFileOps.move(target.path, destDir);
    if (error.length > 0) {
      showToast(error);
      return;
    }
    const slash: number = destDir.lastIndexOf('/');
    const dirName: string = slash >= 0 ? destDir.substring(slash + 1) : destDir;
    showToast('已移动到：' + dirName);
    // 重新扫描，列表立刻反映新位置
    this.startScan();
  }

  /** 申请权限（可重复触发）后开始扫描 */
  private async startScan(): Promise<void> {
    if (this.scanning || this.repository === undefined) {
      return;
    }
    this.scanning = true;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.publicGranted = await requestScanPermissions(ctx);
    } catch (err) {
      this.publicGranted = false;
    }

    // 沙箱目录无需权限，即使被拒也继续扫描
    // 有限定目录时只扫该目录，否则走全量候选扫描
    const result: ScanResult = this.limitedDir.length > 0
      ? this.repository.scanSingleDir(this.limitedDir)
      : this.repository.scan();
    this.allFiles = result.files;
    this.probes = result.probes;
    this.scanned = true;
    this.scanning = false;
    this.applyFilter();

    if (this.allFiles.length === 0) {
      this.showDiag = true;
      showToast('未找到媒体文件，已展开目录诊断');
    } else if (!this.publicGranted) {
      showToast('未授权公共目录，仅扫描到应用内文件');
    } else {
      showToast('扫描完成，共 ' + this.allFiles.length.toString() + ' 个媒体文件');
    }
  }

  /**
   * 仅重新扫描（不重复弹权限框）
   * 用户拒绝后系统不会再弹窗，重复申请只会被直接拒回
   */
  private rescan(): void {
    this.startScan();
  }

  /** 按关键词过滤（不区分大小写的子串匹配） */
  private applyFilter(): void {
    const kw: string = this.keyword.trim().toLowerCase();
    if (kw.length === 0) {
      this.results = this.allFiles;
      return;
    }
    const hit: MediaFile[] = [];
    for (let i = 0; i < this.allFiles.length; i++) {
      const item: MediaFile = this.allFiles[i];
      if (item.name.toLowerCase().indexOf(kw) >= 0) {
        hit.push(item);
      }
    }
    this.results = hit;
  }

  /** 关键词变化 */
  private onKeywordChange(value: string): void {
    this.keyword = value;
    this.applyFilter();
  }

  /** 清空关键词 */
  private clearKeyword(): void {
    this.keyword = '';
    this.applyFilter();
  }

  /** 点击目录条目：无权限的目录可视作「去授权」入口 */
  private onProbeTap(probe: RootProbe): void {
    if (probe.status === 'denied') {
      showToast('该目录需要授权，正在重新申请…');
      this.startScan();
      return;
    }
    if (probe.status === 'missing') {
      showToast('目录不存在：' + probe.path);
      return;
    }
    showToast('可读，命中 ' + probe.count.toString() + ' 个媒体文件');
  }

  /** 点击结果：可播放则进播放器 */
  private openFile(item: MediaFile): void {
    if (!item.playable) {
      showToast('该格式不在可播放白名单内：.' + item.extension);
      return;
    }
    // ★ 防连点：跳转正在途中就忽略后续点击。
    //
    //   为什么必须有这道闸：
    //   实测崩溃现场（cid 02:04）的 Page switch history 显示
    //     PlayerPage → SearchPage → PlayerPage → SearchPage …… 每秒 2~3 次，
    //   随后主线程崩在 ArkUI 的 Surface 渲染节点析构里
    //     （RSSurfaceNode::~RSSurfaceNode → RSNode::ClearAllModifiers）。
    //   也就是说，页面被反复压栈/出栈时，Surface 的创建与销毁会和
    //   原生侧的写入撞车。拦住重复跳转能从源头减少这种重叠。
    //
    //   200ms 是权衡值：快到不影响正常"点一下"的手感，
    //   又足以吃掉人手连点与误触产生的重复请求。
    const now: number = Date.now();
    if (now - this.lastOpenAt < 200) {
      return;
    }
    this.lastOpenAt = now;
    // 注意：NEEDS_SOFT_DECODE 这一类【不再拦截】。
    // 之前拦截是因为内置软解还没接上，点进去必然失败；
    // 现在 FFmpeg 已集成，这类文件改由播放页自动走软解通道，应当允许点开。
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/PlayerPage',
      params: { path: item.path, title: item.name } as PlayerParamsForSearch
    }).catch(() => {
      showToast('无法打开播放页');
    });
  }

  /** 顶部摘要文案 */
  private summaryText(): string {
    if (this.scanning) {
      return '正在扫描…';
    }
    if (!this.scanned) {
      return '尚未扫描';
    }
    return '命中 ' + this.results.length.toString() + ' / 共 ' +
      this.allFiles.length.toString() + ' 个媒体文件';
  }

  /** 可读目录数量 */
  private readableCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.probes.length; i++) {
      if (this.probes[i].status === 'ok') {
        n++;
      }
    }
    return n;
  }

  /** 无权限目录数量 */
  private deniedCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.probes.length; i++) {
      if (this.probes[i].status === 'denied') {
        n++;
      }
    }
    return n;
  }

  /**
   * 长按菜单内容
   * @param item 该列表项对应的文件，作为菜单操作的目标
   */
  @Builder
  itemMenu(item: MediaFile) {
    Column() {
      this.menuRow('✏️', '重命名', () => {
        this.onItemLongPress(item);
        this.openRename();
      })
      Divider().color('rgba(0,0,0,0.06)')
      this.menuRow('ℹ️', '文件信息', () => {
        this.onItemLongPress(item);
        this.openDetail();
      })
      Divider().color('rgba(0,0,0,0.06)')
      this.menuRow('📂', '移动到…', () => {
        this.onItemLongPress(item);
        this.prepareMove();
      })
      Divider().color('rgba(0,0,0,0.06)')
      // 卸载放最后并用醒目色，避免与常规操作混淆造成误触
      this.menuRowDanger('🗑️', '卸载文件', () => {
        this.onItemLongPress(item);
        this.removeTarget();
      })
    }
    .width(180)
    .padding({ top: 6, bottom: 6 })
    .backgroundColor(Theme.CARD_BG)
    .borderRadius(12)
  }

  /** 菜单里的一行 */
  @Builder
  menuRow(icon: string, label: string, onTap: () => void) {
    Row({ space: 10 }) {
      Text(icon)
        .fontSize(16)
      Text(label)
        .fontSize(15)
        .fontColor(Theme.TEXT_MAIN)
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      onTap();
    })
  }

  /** 菜单里的危险操作行（红色，用于卸载） */
  @Builder
  menuRowDanger(icon: string, label: string, onTap: () => void) {
    Row({ space: 10 }) {
      Text(icon)
        .fontSize(16)
      Text(label)
        .fontSize(15)
        .fontColor('#FF3B30')
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      onTap();
    })
  }

  build() {
    Column() {
      // ================= 顶部栏 =================
      Row() {
        Text('‹')
          .fontSize(30)
          .fontColor(Theme.TEXT_MAIN)
          .padding({ left: 8, right: 12 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text(this.limitedDirName.length > 0 ? ('文件夹 · ' + this.limitedDirName) : '文件搜索')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        // 与「重新扫描」同款的小蓝字入口。
        // 真机上「扫描」受限于沙箱权限，「从手机导入」才是能拿到用户文件的途径，
        // 因此并列放在这里，两者视觉权重一致
        Text(this.importing ? '导入中…' : '从手机导入')
          .fontSize(13)
          .fontColor(this.importing ? Theme.TEXT_SUB : Theme.ACCENT)
          .padding(8)
          .onClick(() => {
            if (!this.importing) {
              this.importFromPhone();
            }
          })

        Text('重新扫描')
          .fontSize(13)
          .fontColor(Theme.ACCENT)
          .padding(8)
          .onClick(() => {
            this.rescan();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 16, top: 20, bottom: 12 })

      // ================= 搜索输入 =================
      Row() {
        Text('🔍')
          .fontSize(16)
          .fontColor(Theme.TEXT_SUB)
          .margin({ right: 8 })

        TextInput({ text: this.keyword, placeholder: '按文件名过滤，例如 mp4 / 测试' })
          .layoutWeight(1)
          .fontSize(14)
          .placeholderColor(Theme.TEXT_SUB)
          .backgroundColor(Color.Transparent)
          .padding(0)
          .onChange((value: string) => {
            this.onKeywordChange(value);
          })

        if (this.keyword.length > 0) {
          Text('✕')
            .fontSize(14)
            .fontColor(Theme.TEXT_SUB)
            .padding(8)
            .onClick(() => {
              this.clearKeyword();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 8, top: 10, bottom: 10 })
      .backgroundColor(Theme.CARD_BG)
      .borderRadius(14)
      .shadow({ radius: 12, color: 'rgba(0,0,0,0.05)', offsetX: 0, offsetY: 4 })
      .margin({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING })

      // ================= 状态行 =================
      Row({ space: 10 }) {
        if (this.scanning) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(Theme.ACCENT)
        }
        Text(this.summaryText())
          .fontSize(12)
          .fontColor(Theme.TEXT_SUB)
          .layoutWeight(1)
          .textAlign(TextAlign.Start)

        Text(this.showDiag ? '收起目录' : '扫描目录 ›')
          .fontSize(12)
          .fontColor(Theme.ACCENT)
          .onClick(() => {
            this.showDiag = !this.showDiag;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, top: 12, bottom: 8 })

      // ================= 目录诊断面板 =================
      if (this.showDiag) {
        Column({ space: 8 }) {
          Row() {
            Text('可读 ' + this.readableCount().toString() + ' 个')
              .fontSize(12)
              .fontColor(Theme.TEXT_SUB)
              .layoutWeight(1)
              .textAlign(TextAlign.Start)
            if (this.deniedCount() > 0) {
              Text('无权限 ' + this.deniedCount().toString() + ' 个 · 点击可重新申请')
                .fontSize(12)
                .fontColor(Theme.ACCENT)
            }
          }
          .width('100%')

          List({ space: 6 }) {
            ForEach(this.probes, (probe: RootProbe) => {
              ListItem() {
                Row({ space: 8 }) {
                  Text(probe.status === 'ok' ? '✓' : (probe.status === 'denied' ? '🔒' : '·'))
                    .fontSize(13)
                    .fontColor(probe.status === 'ok' ? '#34C759' : Theme.TEXT_SUB)
                    .width(18)
                    .textAlign(TextAlign.Center)

                  Text(probe.path)
                    .fontSize(11)
                    .fontColor(probe.status === 'ok' ? Theme.TEXT_MAIN : Theme.TEXT_SUB)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .textAlign(TextAlign.Start)

                  Text(probe.status === 'ok'
                    ? (probe.count.toString() + ' 个')
                    : (probe.status === 'denied' ? '无权限' : '不存在'))
                    .fontSize(11)
                    .fontColor(probe.status === 'ok' ? Theme.TEXT_SUB : Theme.ACCENT)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ left: 10, right: 10, top: 8, bottom: 8 })
                .backgroundColor(Theme.CARD_BG)
                .borderRadius(10)
                .onClick(() => {
                  this.onProbeTap(probe);
                })
              }
            }, (probe: RootProbe) => probe.path)
          }
          .height(this.probes.length > 6 ? 200 : (this.probes.length * 40 + 12))
          .width('100%')
          .scrollBar(BarState.Off)

          // ---- 原生模块探针（阶段 1 验收用） ----
        Text('原生模块：' + (this.nativeProbeText.length > 0
          ? this.nativeProbeText : '（未调用）'))
          .fontSize(10)
          .fontColor(this.nativeProbeText.indexOf('失败') >= 0
            ? '#FF3B30' : Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)

        Text('权限：' + SCAN_PERMISSIONS.join(' / '))
            .fontSize(10)
            .fontColor(Theme.TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, bottom: 12 })
      }

      // ================= 移动目标目录选单 =================
      // 用浮层而不是 AlertDialog：AlertDialog 不支持动态列表选择
      if (this.showMoveMenu) {
        Column({ space: 2 }) {
          Text('移动到')
            .fontSize(13)
            .fontColor(Theme.TEXT_SUB)
            .padding({ left: 16, top: 12, bottom: 6 })
            .width('100%')
            .textAlign(TextAlign.Start)

          List({ space: 0 }) {
            ForEach(this.moveTargets, (dir: string) => {
              ListItem() {
                Row({ space: 10 }) {
                  Text('📁')
                    .fontSize(16)
                  Text(this.dirNameOf(dir))
                    .fontSize(14)
                    .fontColor(Theme.TEXT_MAIN)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .textAlign(TextAlign.Start)
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .onClick(() => {
                  this.doMove(dir);
                })
              }
            }, (dir: string) => dir)
          }
          .height(this.moveTargets.length > 5 ? 240 : this.moveTargets.length * 46)
          .width('100%')
          .scrollBar(BarState.Off)

          Text('取消')
            .fontSize(14)
            .fontColor(Theme.TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 12, bottom: 12 })
            .onClick(() => {
              this.showMoveMenu = false;
            })
        }
        .width('78%')
        .padding({ bottom: 6 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(16)
        .shadow({ radius: 30, color: 'rgba(0,0,0,0.18)', offsetX: 0, offsetY: 8 })
        .onClick(() => {
        })
      }

      // ================= 结果列表 =================
      if (this.results.length > 0) {
        List({ space: 8 }) {
          ForEach(this.results, (item: MediaFile) => {
            ListItem() {
              Row({ space: 12 }) {
                Text(item.extension.toUpperCase())
                  .fontSize(10)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .width(44)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .borderRadius(10)
                  .backgroundColor(item.playable ? Theme.ACCENT : Theme.TEXT_SUB)

                Column({ space: 3 }) {
                  Text(item.name)
                    .fontSize(14)
                    .fontColor(Theme.TEXT_MAIN)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)

                  Text(item.folder)
                    .fontSize(11)
                    .fontColor(Theme.TEXT_SUB)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Start)

                  Text(formatSize(item.size) + '  ·  ' + tierLabel(item.tier))
                    .fontSize(11)
                    .fontColor((item.tier === MediaTier.PLAYABLE
                      || item.tier === MediaTier.MAYBE_PLAYABLE) ? Theme.TEXT_SUB : Theme.ACCENT)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding(12)
              .backgroundColor(Theme.CARD_BG)
              .borderRadius(14)
              .shadow({ radius: 10, color: 'rgba(0,0,0,0.05)', offsetX: 0, offsetY: 3 })
              .onClick(() => {
                this.openFile(item);
              })
              // 按压反馈：按下缩小、抬起复原，避免交互生硬
              .scale({
                x: this.pressedPath === item.path ? 0.96 : 1.0,
                y: this.pressedPath === item.path ? 0.96 : 1.0
              })
              .animation({ duration: 120, curve: Curve.EaseOut })
              .onTouch((event: TouchEvent) => {
                if (event.type === TouchType.Down) {
                  this.pressedPath = item.path;
                } else if (event.type === TouchType.Up
                  || event.type === TouchType.Cancel) {
                  this.pressedPath = '';
                }
              })
              // 长按弹出操作菜单：重命名 / 文件信息 / 移动到 / 卸载
              .bindContextMenu(this.itemMenu(item), ResponseType.LongPress)
            }
          }, (item: MediaFile) => item.path)
        }
        // List 显式给宽高（ArkTSCheck 会提示）：
        //   只设 layoutWeight 时宽度是隐式的，配合 scrollBar 会偶发滚动条位置不对。
        //   显式写 100% 宽 + layoutWeight(1) 高度，语义清楚也不会影响布局结果。
        .width('100%')
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, bottom: 24 })
        .scrollBar(BarState.Off)
      } else {
        // ================= 空状态 =================
        Column({ space: 10 }) {
          Text(this.scanning ? '⏳' : '📭')
            .fontSize(40)
          Text(this.scanning ? '正在扫描…' :
            (this.scanned ? '没有匹配的媒体文件' : '点击「重新扫描」开始搜索'))
            .fontSize(13)
            .fontColor(Theme.TEXT_SUB)
            .textAlign(TextAlign.Center)
          if (this.scanned && !this.scanning) {
            // 真机上应用无权扫描手机公共目录（沙箱限制），
            // 所以引导用户走文件选择器，而不是让他去猜路径放文件
            Text('应用无权直接读取手机相册/下载目录，\n点上方「从手机导入」选择视频即可')
              .fontSize(11)
              .fontColor(Theme.TEXT_SUB)
              .textAlign(TextAlign.Center)
              .padding({ left: 32, right: 32 })

            Text('从手机导入')
              .fontSize(13)
              .fontColor(Theme.ACCENT)
              .padding(8)
              .onClick(() => {
                if (!this.importing) {
                  this.importFromPhone();
                }
              })
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .linearGradient({
      angle: 180,
      colors: [[Theme.CARD_BG, 0.0], [Theme.BG, 0.7]]
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

/** 搜索页传给播放页的参数结构（与 PlayerParams 字段一致） */
interface PlayerParamsForSearch {
  path: string;
  title: string;
}

/** 从首页文件夹进入时携带的参数 */
interface FolderParamsForSearch {
  folderPath: string;
  folderName: string;
}

/** 传给重命名页的参数（字段需与 RenameParams 一致） */
interface RenameParamsForSearch {
  path: string;
  name: string;
}

/** 传给文件详情页的参数（字段需与 FileDetailParams 一致） */
interface FileDetailParamsForSearch {
  path: string;
  name: string;
  size: number;
}
