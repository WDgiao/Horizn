import { SurfacePlaybackTester, SurfaceTestResult } from '../model/SurfacePlaybackTester';
import { Theme } from '../common/Theme';
import { showToast } from '../common/Toast';
import { SoftPlayerController, SoftPlayerSnapshot } from '../model/SoftPlayerController';
import { SoftPlayerState } from '../model/SoftPlayerTypes';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
// 原生模块的导出必须合并到一条 import ——
// 分成两条 from 同一个模块，IDE 的 ArkTSCheck 会报
// "Cannot find module 'libsoftplayer.so'"（它按模块名做解析，
// 重复导入会让解析走到异常分支）。语法上两条也合法，但没必要。
import { nativeSoftDecodeProbe, nativeExtractFrame } from 'libsoftplayer.so';

/** 待完善的设置项 */
interface SettingItem {
  /** 图标 */
  icon: string;
  /** 标题 */
  title: string;
  /** 右侧说明 */
  summary: string;
}

/**
 * 设置页
 *
 * 布局策略（经设备实测宽度后确定）：
 *   1) 滑动区容器统一 padding = PAGE_PADDING(24vp)，所有区块不再各自设横向 margin
 *   2) 开关行不用 layoutWeight：文字自然宽度 + Blank() 撑开剩余空间
 *      —— 因为 Toggle 带默认边距，layoutWeight 的分配结果会溢出容器
 *   3) 区块一律不设 width('100%')，避免与 padding 叠加撑宽
 *
 * 功能状态：按需求「先把窗口做出来」，设置项均为占位，点击只提示待完善。
 * 顶部一张卡片承载两个诊断入口（原生自测 / 播放能力实测），验证完成后可整卡删除。
 */
@Entry
@Component
struct SettingsPage {
  @State items: SettingItem[] = [
    { icon: '▶️', title: '播放设置', summary: '默认解码方式 · 硬件加速' },
    { icon: '🔊', title: '音频设置', summary: '音轨 · 音量增益' },
    { icon: '📂', title: '媒体库目录', summary: '添加与管理扫描路径' },
    { icon: '🔤', title: '字幕设置', summary: '字体 · 编码 · 同步' },
    { icon: '🎛️', title: '手势与快捷键', summary: '亮度 · 音量 · 快进' },
    { icon: '🌐', title: '网络流', summary: 'HTTP / RTSP 地址管理' },
    { icon: '🎨', title: '外观', summary: '浅色 · 深色 · 跟随系统' },
    { icon: 'ℹ️', title: '关于', summary: '版本 1.0.0' }
  ];

  /** 占位开关，仅用于演示控件样式，暂不产生实际效果 */
  @State hardwareDecode: boolean = true;
  @State autoScan: boolean = false;

  /** 原生播放器自测：是否正在运行 */
  @State testRunning: boolean = false;
  /** 原生播放器自测 / 播放能力测试共用：日志文本（多行） */
  @State testLog: string = '';
  /** 原生播放器自测：控制器实例 */
  private testCtl: SoftPlayerController | undefined = undefined;

  /** 播放能力测试：是否正在运行 */
  @State playRunning: boolean = false;
  /** 播放能力测试：通过数 */
  @State playPassed: number = 0;
  /** 跳转压力测试：是否运行中 */
  @State navTesting: boolean = false;

  /**
   * 测试用 surface id
   *
   * 为什么设置页里要放一个 XComponent：
   *   不带 surface 时 AVPlayer 会把视频轨整个关掉（isVideoTrackDisabled_: 1），
   *   播放位置照样推进（推进的是音频时钟），于是"全部格式都能播"是假象。
   *   必须挂上 surface，视频解码器才会被真正创建。
   * 这个 XComponent 在卡片内不显示（尺寸 0），只为了拿到 surfaceId。
   */
  @State testSurfaceId: string = '';

  /** 取 surfaceId 用的 XComponent 控制器 */
  private testSurfaceController: XComponentController = new XComponentController();

  aboutToDisappear(): void {
    // 必须释放：否则原生线程与定时器会残留
    const c: SoftPlayerController | undefined = this.testCtl;
    if (c !== undefined) {
      c.release();
      this.testCtl = undefined;
    }
  }

  /**
   * 软解引擎骨架探针
   *
   * 验证的是「与 FFmpeg 无关」的那部分：引擎构造、事件回调、surface 绑定、
   * 状态机流转、线程启停、Release 不挂死。
   * FFmpeg 未集成时应当明确报错而不是崩溃 —— 这条路径现在就要确认是对的，
   * 否则等 FFmpeg 编好之后出问题会分不清是骨架错还是解码错。
   */
  private runSoftEngineProbe(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 拿一个真实存在的文件路径，让 Prepare 走到打开文件那一步
    const sample: string = ctx.filesDir + '/codec-test/12_rv10.rm';
    this.testLog = '';
    this.appendLog('软解引擎探针开始（带 surface）');
    try {
      const out: string = nativeSoftDecodeProbe(this.testSurfaceId, sample);
      const lines: string[] = out.split('\n');
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].length > 0) {
          this.appendLog(lines[i]);
        }
      }
    } catch (err) {
      this.appendLog('探针抛出异常：' + JSON.stringify(err));
    }
  }

  /**
   * 软解探针（不上屏）
   *
   * 与上一个的唯一区别是 surfaceId 传空串 —— 引擎会跳过渲染，只跑解码。
   * 这样能把问题分开：
   *   不上屏也不推进 → 解码本身有问题
   *   不上屏能推进、上屏崩 → 问题在渲染/surface 那块
   * 一个探针只能告诉你"失败了"，两个才能告诉你"失败在哪"。
   */
  private runSoftEngineProbeNoSurface(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const sample: string = ctx.filesDir + '/codec-test/12_rv10.rm';
    this.testLog = '';
    this.appendLog('软解引擎探针开始（不上屏，仅解码）');
    try {
      const out: string = nativeSoftDecodeProbe('', sample);
      const lines: string[] = out.split('\n');
      for (let i = 0; i < lines.length; i++) {
        if (lines[i].length > 0) {
          this.appendLog(lines[i]);
        }
      }
    } catch (err) {
      this.appendLog('探针抛出异常：' + JSON.stringify(err));
    }
  }

  /**
   * 把内置测试素材发布到媒体库目录
   *
   * 为什么需要：应用只能写自己的沙箱，hdc shell 无权写入（实测 cp 报 Permission denied），
   * 所以想让「软解素材」出现在搜索页里，只能由应用自己拷。
   * 拷完去搜索页重新扫描就能看到 RV10 / WMV2 / Theora 这几个文件。
   */
  private async publishSamples(): Promise<void> {
    this.testLog = '';
    this.appendLog('发布测试素材到媒体库目录…');
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const list: string[] = await SurfacePlaybackTester.publishSamples(ctx);
      for (let i = 0; i < list.length; i++) {
        this.appendLog('  ' + list[i]);
      }
      this.appendLog('完成。去「文件搜索」页点「重新扫描」即可看到。');
    } catch (err) {
      this.appendLog('发布失败：' + JSON.stringify(err));
    }
  }

  /**
   * 解包高分辨率压力测试素材到沙箱
   *
   * 素材随 HAP 打包在 rawfile/hdtest/ 下（共约 11 MB）。
   * 为什么不能像普通文件那样用 hdc 推进沙箱：见 unpackHdSamples 的说明 ——
   * 沙箱跨 uid，hdc 无法写入，只能由应用自己落盘。
   */
  private async unpackHdSamples(): Promise<void> {
    this.testLog = '';
    this.appendLog('解包高清测试素材（rawfile/hdtest → 沙箱）…');
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const list: string[] = await SurfacePlaybackTester.unpackHdSamples(ctx);
      for (let i = 0; i < list.length; i++) {
        this.appendLog('  ' + list[i]);
      }
      this.appendLog('完成。去「文件搜索」页点「重新扫描」即可看到。');
      this.appendLog('用途：720p 样本判断真实播放负载；24bit/32bit 浮点 WAV 验证新补的 PCM 解码器。');
    } catch (err) {
      this.appendLog('解包失败：' + JSON.stringify(err));
    }
  }

  /**
   * 跳转压力测试：程序化地极高频 push/back 播放页
   *
   * 为什么用程序化跳转而不是模拟点击：
   *   ① 模拟点击依赖坐标，实测很不稳（列表滚动位置、键盘遮挡都会让点击落空），
   *      跑出"全部通过"却其实一次都没打开过
   *   ② 崩溃现场（HiviewFaultLogger 里的 Page switch history）显示的是
   *      PlayerPage/SearchPage 每秒切换 2~3 次 —— 关键在"页面切换频率"，
   *      而不在"手指点在哪"。程序化跳转正好精确复现这一点。
   *
   * 每轮都走完整的 进入播放页 → 退出 流程，且在极短间隔内连续做，
   * 用来暴露 Surface 渲染节点的创建/销毁与原生渲染写入之间的竞态。
   */
  private async runNavStress(): Promise<void> {
    if (this.navTesting) {
      return;
    }
    this.navTesting = true;
    this.testLog = '';
    const rounds: number = 40;
    this.appendLog('跳转压力测试开始：' + rounds.toString() + ' 轮高频 push/back');
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const path: string = await SurfacePlaybackTester.ensureSamplePath(ctx);
      const router = this.getUIContext().getRouter();
      for (let i = 0; i < rounds; i++) {
        router.pushUrl({
          url: 'pages/PlayerPage',
          params: { path: path, title: '12_rv10.rm' }
        }).catch((err: BusinessError) => {
          console.error('pushUrl failed: ' + JSON.stringify(err));
        });
        // 极短间隔：不等待push完成就发下一个动作，
        // 这正是"连点"的时序特征，也是竞态最容易出现的窗口
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, 120);
        });
        router.back();
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, 120);
        });
        if (i % 10 === 9) {
          this.appendLog('  已完成 ' + (i + 1).toString() + ' 轮');
        }
      }
      this.appendLog('✅ 跳转压力测试完成 ' + rounds.toString() + ' 轮，未崩溃');
    } catch (err) {
      this.appendLog('测试异常：' + JSON.stringify(err));
    } finally {
      this.navTesting = false;
    }
  }

  /**
   * 把补充测试素材（rawfile/testset）解包到沙箱
   *
   * 这批素材针对的是已发现的薄弱点，与「出素材」那 12 个格式样本不同：
   *   - 长视频_rv20_10秒.rm   10 秒长片，用来压 seek（原来 2 秒的没跳转空间）
   *   - 无音轨_rv20.rm        没有音频轨，验证是否退回单调时钟且不卡住
   * 解包后去搜索页「重新扫描」就能看到（它们会出现在「测试素材」目录下）。
   */
  private async publishTestset(): Promise<void> {
    this.testLog = '';
    this.appendLog('解包补充测试素材…');
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const list: string[] = await SurfacePlaybackTester.unpackTestset(ctx);
      for (let i = 0; i < list.length; i++) {
        this.appendLog('  ' + list[i]);
      }
      this.appendLog('完成。去「文件搜索」页点「重新扫描」即可看到。');
    } catch (err) {
      this.appendLog('解包失败：' + JSON.stringify(err));
    }
  }

  /**
   * 抽帧自测：对内置的 .rm 素材调用 FFmpeg 抽帧并报告结果
   *
   * 为什么需要一个独立的验证入口：
   *   缩略图的效果只能靠"首页看着有没有图"来判断，成功与失败都靠猜。
   *   这个自测直接报告错误码、输出文件大小、以及回读出来的尺寸，
   *   失败时能立刻分辨是"文件没打开""解不出帧"还是"写不出 JPEG"。
   *   开发环境没有真机，所以把验证手段交给使用者。
   */
  private async runThumbProbe(): Promise<void> {
    this.testLog = '';
    this.appendLog('抽帧自测开始（针对系统不支持的 .rm）');
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const src: string = ctx.filesDir + '/codec-test/12_rv10.rm';
      const dst: string = ctx.cacheDir + '/thumb-probe.jpg';
      this.appendLog('源文件: ' + src);

      // 先确认源文件在不在 —— 否则测的是"文件缺失"而不是抽帧能力
      if (!fileIo.accessSync(src)) {
        this.appendLog('✗ 源文件不存在。请先点「出素材」把测试文件解包出来。');
        return;
      }
      this.appendLog('源文件大小: ' + fileIo.statSync(src).size.toString() + ' 字节');

      const t0: number = Date.now();
      const out: string = nativeExtractFrame(src, dst, 1000, 320);
      const cost: number = Date.now() - t0;
      this.appendLog('nativeExtractFrame -> ' + out + '  (' + cost.toString() + ' ms)');

      // 检查产物：存在、非空
      if (!fileIo.accessSync(dst)) {
        this.appendLog('✗ 输出文件不存在');
        return;
      }
      const size: number = fileIo.statSync(dst).size;
      this.appendLog('输出文件大小: ' + size.toString() + ' 字节');
      if (size <= 0) {
        this.appendLog('✗ 输出文件为空');
        return;
      }

      // 用 ImageKit 读回来验证它确实是一张能用的 JPEG，
      // 而不只是一个"有字节数的文件"
      const file: fileIo.File = fileIo.openSync(dst, fileIo.OpenMode.READ_ONLY);
      try {
        const source: image.ImageSource = image.createImageSource(file.fd);
        const info: image.ImageInfo = await source.getImageInfo();
        this.appendLog('解码验证: ' + info.size.width.toString() + 'x'
          + info.size.height.toString() + '  格式=' + info.mimeType);
        await source.release();
      } finally {
        fileIo.closeSync(file);
      }
      this.appendLog('✅ 抽帧链路完整可用');
    } catch (err) {
      this.appendLog('自测异常：' + JSON.stringify(err));
    }
  }

  /**
   * 带 surface 的播放能力实测
   *
   * 与 runPlaybackTest 的区别（上一轮的结果是假的，这里才作数）：
   *   无 surface → AVPlayer 关闭视频轨 → 位置推进的是音频时钟 → 12/12 全过是假象
   *   有 surface → 视频解码器真被创建 → 画面尺寸非 0 才算真解出来了
   */
  private async runSurfaceTest(): Promise<void> {
    if (this.playRunning || this.testRunning) {
      showToast('测试正在运行');
      return;
    }
    if (this.testSurfaceId.length === 0) {
      showToast('surface 尚未就绪，请稍后重试');
      return;
    }
    this.playRunning = true;
    this.playPassed = 0;
    this.testLog = '';
    this.appendLog('开始带 surface 实测（判据：画面尺寸非 0）');

    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const results: SurfaceTestResult[] = await SurfacePlaybackTester.runAll(ctx, this.testSurfaceId,
        (r: SurfaceTestResult) => {
          const size: string = r.width.toString() + 'x' + r.height.toString();
          if (r.error.length === 0 && r.width > 0) {
            this.playPassed++;
            this.appendLog('✓ ' + r.name + '  ' + size
              + '  ' + r.position.toString() + 'ms');
          } else if (r.width > 0) {
            this.appendLog('△ ' + r.name + '  ' + size + '  ' + r.error);
          } else {
            this.appendLog('✗ ' + r.name + '  ' + r.error);
          }
        });
      this.appendLog('===== 真解码通过 ' + this.playPassed.toString()
        + ' / ' + results.length.toString() + ' =====');
    } catch (err) {
      this.appendLog('测试异常：' + JSON.stringify(err));
    } finally {
      this.playRunning = false;
    }
  }

  /**
   * 原生播放器自测
   *
   * 这一轮验证的是「与解码无关」的全部链路：
   *   创建原生对象 → prepare → start → 事件轮询 → 进度上报 → 播放结束 → 释放
   * 底层当前是 StubEngine（不做真实解码，模拟 12 秒进度），
   * 因此不需要任何媒体文件也能跑完。
   */
  private runNativeSelfTest(): void {
    if (this.testRunning) {
      showToast('自测正在运行中');
      return;
    }
    if (this.playRunning) {
      showToast('播放测试正在运行');
      return;
    }
    this.testRunning = true;
    this.testLog = '';
    this.appendLog('开始自测');

    const c: SoftPlayerController = new SoftPlayerController((snap: SoftPlayerSnapshot) => {
      this.onTestUpdate(snap);
    });
    this.testCtl = c;

    // 自测不需要真实画面，surfaceId 传空串即可
    const attached: boolean = c.attach('');
    this.appendLog('attach: ' + (attached ? '成功' : '失败'));
    if (!attached) {
      this.finishTest();
      return;
    }

    const prepared: boolean = c.prepare('/data/local/tmp/selftest.mp4');
    this.appendLog('prepare 发起: ' + (prepared ? '成功' : '失败'));
    if (!prepared) {
      this.finishTest();
      return;
    }

    // 等 PREPARED 后再 start（原生侧会延时约 120ms）
    setTimeout(() => {
      const ctl: SoftPlayerController | undefined = this.testCtl;
      if (ctl === undefined) {
        return;
      }
      ctl.play();
      this.appendLog('start 已调用');
    }, 400);
  }

  /** 自测状态更新回调 */
  private onTestUpdate(snap: SoftPlayerSnapshot): void {
    if (snap.error.length > 0) {
      this.appendLog('错误: ' + snap.error);
      this.finishTest();
      return;
    }
    const st: string = this.stateName(snap.state);
    this.appendLog('状态=' + st + ' 位置=' + snap.positionMs.toString()
      + '/' + snap.durationMs.toString()
      + ' 画面=' + snap.width.toString() + 'x' + snap.height.toString()
      + (snap.videoCodec.length > 0 ? (' 编码=' + snap.videoCodec) : ''));
    if (snap.state === SoftPlayerState.COMPLETED) {
      this.appendLog('✅ 播放完成，全链路正常');
      this.finishTest();
    }
  }

  /** 状态枚举转可读名 */
  private stateName(st: SoftPlayerState): string {
    if (st === SoftPlayerState.IDLE) { return 'IDLE'; }
    if (st === SoftPlayerState.PREPARING) { return 'PREPARING'; }
    if (st === SoftPlayerState.READY) { return 'READY'; }
    if (st === SoftPlayerState.PLAYING) { return 'PLAYING'; }
    if (st === SoftPlayerState.PAUSED) { return 'PAUSED'; }
    if (st === SoftPlayerState.COMPLETED) { return 'COMPLETED'; }
    if (st === SoftPlayerState.ERROR_STATE) { return 'ERROR'; }
    return 'RELEASED';
  }

  /** 结束自测并释放资源 */
  private finishTest(): void {
    const c: SoftPlayerController | undefined = this.testCtl;
    if (c !== undefined) {
      c.release();
      this.testCtl = undefined;
      this.appendLog('已释放原生播放器');
    }
    this.testRunning = false;
  }

  /**
   * 追加一行日志（保留最近 14 行）
   * 自测与播放测试共用同一块显示区，避免设置页堆积多张测试卡片。
   */
  private appendLog(line: string): void {
    const lines: string[] = this.testLog.length > 0 ? this.testLog.split('\n') : [];
    lines.push(line);
    while (lines.length > 14) {
      lines.shift();
    }
    this.testLog = lines.join('\n');
    console.info('[Diag] ' + line);
  }

  build() {
    Column() {
      // ================= 顶部栏 =================
      Row() {
        Text('‹')
          .fontSize(30)
          .fontColor(Theme.TEXT_MAIN)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_MAIN)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ right: Theme.PAGE_PADDING, top: 20, bottom: 16 })

      // ================= 内容区 =================
      // 统一在这里设置左右留白，内部区块一律不再设横向 margin
      Column() {
        // ---------- 占位提示 ----------
        Row({ space: 12 }) {
          Text('🚧')
            .fontSize(14)
            .width(32)
            .textAlign(TextAlign.Center)
          Text('以下功能尚未实现，仅搭建界面骨架，等待后续完善')
            .fontSize(12)
            .fontColor(Theme.TEXT_SUB)
            .textAlign(TextAlign.Start)
            .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Center)
        .padding(14)
        .backgroundColor('rgba(0,125,255,0.08)')
        .borderRadius(12)
        .margin({ bottom: 16 })

        // ---------- 诊断卡片（验证完成后整卡删除） ----------
        Column() {
          Column({ space: 3 }) {
            Text('解码能力诊断')
              .fontSize(14)
              .fontColor(Theme.TEXT_MAIN)
              .width('100%')
              .textAlign(TextAlign.Start)
            Text('内置 12 个样本，逐个实测本机真实解码范围')
              .fontSize(11)
              .fontColor(Theme.TEXT_SUB)
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 按钮单独占一行并用 Flex 换行：
          //   和标题挤在同一个 Row 里时，6 个按钮放不下会被裁掉 ——
          //   实测「出素材」只剩 47px 可见，等于是个点不到的按钮。
          Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
            Text('真解码')
              .fontSize(12)
              .fontColor((this.playRunning || this.testRunning) ? Theme.TEXT_SUB : Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                if (!this.playRunning && !this.testRunning) {
                  this.runSurfaceTest();
                }
              })

            Text(this.testRunning ? '自测中' : '原生自测')
              .fontSize(12)
              .fontColor((this.playRunning || this.testRunning) ? Theme.TEXT_SUB : Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                if (!this.testRunning && !this.playRunning) {
                  this.runNativeSelfTest();
                }
              })

            Text('软解探针')
              .fontSize(12)
              .fontColor((this.playRunning || this.testRunning) ? Theme.TEXT_SUB : Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                if (!this.testRunning && !this.playRunning) {
                  this.runSoftEngineProbe();
                }
              })

            Text('仅解码')
              .fontSize(12)
              .fontColor((this.playRunning || this.testRunning) ? Theme.TEXT_SUB : Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                if (!this.testRunning && !this.playRunning) {
                  this.runSoftEngineProbeNoSurface();
                }
              })

            Text('出素材')
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                this.publishSamples();
              })

            Text(this.navTesting ? '跳转中' : '跳转压测')
              .fontSize(12)
              .fontColor(this.navTesting ? Theme.TEXT_SUB : Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                if (!this.navTesting) {
                  this.runNavStress();
                }
              })

            Text('抽帧自测')
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                this.runThumbProbe();
              })

            Text('出测试集')
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                this.publishTestset();
              })

            // 高分辨率压力测试素材：rawfile/hdtest 解包到沙箱
            // 用途：内置样本全是 320x240 以下的小文件，判断不了"播放流畅不流畅"
            Text('拉高清')
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .padding(4)
              .onClick(() => {
                this.unpackHdSamples();
              })
          }
          .width('100%')
          .padding({ top: 6, bottom: 6 })

          // 只用于取 surfaceId 的隐藏 XComponent（1x1，几乎不占位）
          XComponent({
            type: XComponentType.SURFACE,
            controller: this.testSurfaceController
          })
            .width(1)
            .height(1)
            .onLoad(() => {
              this.testSurfaceId = this.testSurfaceController.getXComponentSurfaceId();
              console.info('[Diag] surface 就绪: '
                + (this.testSurfaceId.length > 0 ? '是' : '否'));
            })

          if (this.testLog.length > 0) {
            Text(this.testLog)
              .fontSize(10)
              .fontColor(Theme.TEXT_SUB)
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({ top: 4, bottom: 8 })
          }
        }
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 16 })

        // ---------- 演示用开关 ----------
        Column() {
          // 第一行：不用 layoutWeight，用 Blank 撑开中间空隙
          Row() {
            Text('硬件解码')
              .fontSize(14)
              .fontColor(Theme.TEXT_MAIN)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.hardwareDecode })
              .selectedColor(Theme.ACCENT)
              .margin(0)
              .onChange((isOn: boolean) => {
                this.hardwareDecode = isOn;
                showToast('硬件解码：' + (isOn ? '开' : '关') + '（功能待实现）');
              })
          }
          // 必须显式撑满：否则 Row 会缩到内容宽度，
          // Blank() 也就没有可分配的剩余空间，开关会跑到中间
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 6, bottom: 6 })

          Divider().color('rgba(0,0,0,0.06)')

          Row() {
            Text('启动时自动扫描媒体库')
              .fontSize(14)
              .fontColor(Theme.TEXT_MAIN)
            Blank()
            Toggle({ type: ToggleType.Switch, isOn: this.autoScan })
              .selectedColor(Theme.ACCENT)
              .margin(0)
              .onChange((isOn: boolean) => {
                this.autoScan = isOn;
                showToast('自动扫描：' + (isOn ? '开' : '关') + '（功能待实现）');
              })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 6, bottom: 6 })
        }
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 16 })

        // ---------- 设置项列表 ----------
        List({ space: 8 }) {
          ForEach(this.items, (item: SettingItem) => {
            ListItem() {
              Row({ space: 12 }) {
                Text(item.icon)
                  .fontSize(20)
                  .width(32)
                  .textAlign(TextAlign.Center)

                Column({ space: 3 }) {
                  Text(item.title)
                    .fontSize(14)
                    .fontColor(Theme.TEXT_MAIN)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                  Text(item.summary)
                    .fontSize(11)
                    .fontColor(Theme.TEXT_SUB)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('›')
                  .fontSize(20)
                  .fontColor(Theme.TEXT_SUB)
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding(14)
              .backgroundColor(Theme.CARD_BG)
              .borderRadius(14)
              .shadow({ radius: 10, color: 'rgba(0,0,0,0.05)', offsetX: 0, offsetY: 3 })
              .onClick(() => {
                showToast(item.title + '：功能待完善');
              })
            }
          }, (item: SettingItem) => item.title)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING })
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
