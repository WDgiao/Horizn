import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { showToast, initToast } from '../common/Toast';
import { NetworkStream, NetworkStreamStore } from '../model/NetworkStreamStore';

/** 编辑页路由参数：带 id 表示编辑已有条目，不带表示新增 */
export interface StreamEditParams {
  /** 已有条目的 id；不存在则为新增模式 */
  id?: string;
}

/**
 * 网络流添加 / 编辑页
 *
 * 一个页面兼顾两种模式，靠路由参数有无 id 区分 ——
 * 新增与编辑的字段、校验、布局完全一样，拆成两个页面只会让
 * 校验规则要维护两份，容易改漏。
 *
 * 为什么是独立页面而不是弹窗：见 NetworkStreamPage 的说明
 * （本 SDK 版本 AlertDialog 不支持文本输入）。
 */
@Entry
@Component
struct StreamEditPage {
  /** 编辑模式的记录 id；空串表示新增 */
  @State editingId: string = '';
  /** 显示名 */
  @State inputName: string = '';
  /** 播放地址 */
  @State inputUrl: string = '';
  /** 仓库实例 */
  private store: NetworkStreamStore | undefined = undefined;

  aboutToAppear(): void {
    initToast(this.getUIContext());
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new NetworkStreamStore(ctx);

    const params = this.getUIContext().getRouter().getParams() as StreamEditParams;
    if (params !== undefined && params !== null
      && params.id !== undefined && params.id.length > 0) {
      this.editingId = params.id;
      const rec: NetworkStream | undefined = this.store.find(params.id);
      if (rec !== undefined) {
        this.inputName = rec.name;
        this.inputUrl = rec.url;
      } else {
        // 记录可能已被别处删除，退回新增模式而不是留一个空白编辑页
        showToast('该记录已不存在');
        this.editingId = '';
      }
    }
  }

  /** 是否编辑模式 */
  private isEditing(): boolean {
    return this.editingId.length > 0;
  }

  /**
   * 实时校验地址
   * 返回错误文案，合法则空串
   */
  private urlError(): string {
    if (this.inputUrl.trim().length === 0) {
      return '';
    }
    return NetworkStreamStore.validateUrl(this.inputUrl);
  }

  /**
   * 该地址是否属于「现在就能播」的协议
   *
   * 为什么要在新增时就提示：用户看到"保存成功"会默认这东西能播。
   * 如果填的是 RTSP，现在明确告诉他"可以保存但暂不能播"，
   * 比等他点开发现播不了要好。
   */
  private playableNow(): boolean {
    if (this.inputUrl.trim().length === 0 || this.urlError().length > 0) {
      return false;
    }
    return NetworkStreamStore.isPlayable(NetworkStreamStore.detectProtocol(this.inputUrl));
  }

  /** 保存 */
  private submit(): void {
    const s: NetworkStreamStore | undefined = this.store;
    if (s === undefined) {
      showToast('存储不可用');
      return;
    }
    const err: string = NetworkStreamStore.validateUrl(this.inputUrl);
    if (err.length > 0) {
      showToast(err);
      return;
    }
    const url: string = this.inputUrl.trim();

    if (this.isEditing()) {
      if (s.update(this.editingId, this.inputName, false)) {
        showToast('已保存');
        this.getUIContext().getRouter().back();
      } else {
        showToast('保存失败：记录不存在');
      }
      return;
    }

    if (s.existsUrl(url)) {
      showToast('该地址已经添加过了');
      return;
    }
    const created: NetworkStream | undefined = s.add(this.inputName, url);
    if (created === undefined) {
      showToast('添加失败');
      return;
    }
    showToast('已添加：' + created.name);
    this.getUIContext().getRouter().back();
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
        Text(this.isEditing() ? '编辑网络流' : '添加网络流')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_MAIN)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 24, top: 20, bottom: 16 })

      // ================= 输入区 =================
      Column({ space: 14 }) {
        // 播放地址
        Column({ space: 6 }) {
          Text('播放地址')
            .fontSize(12)
            .fontColor(Theme.TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Start)
          TextInput({ text: this.inputUrl, placeholder: 'http://example.com/video.mp4' })
            .width('100%')
            .fontSize(14)
            .height(48)
            .backgroundColor(Theme.CARD_BG)
            .borderRadius(Theme.RADIUS_MEDIUM)
            .maxLength(500)
            .type(InputType.Normal)
            .onChange((value: string) => {
              this.inputUrl = value;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 实时校验反馈
        if (this.inputUrl.trim().length > 0) {
          if (this.urlError().length > 0) {
            Text('⚠️ ' + this.urlError())
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .width('100%')
              .textAlign(TextAlign.Start)
          } else if (this.playableNow()) {
            Text('✓ 格式可用，保存后即可播放')
              .fontSize(12)
              .fontColor('#34C759')
              .width('100%')
              .textAlign(TextAlign.Start)
          } else {
            Text('✓ 格式合法，但该协议暂不支持播放（可以先存着）')
              .fontSize(12)
              .fontColor(Theme.TEXT_SUB)
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }

        // 显示名（选填）
        Column({ space: 6 }) {
          Row() {
            Text('显示名')
              .fontSize(12)
              .fontColor(Theme.TEXT_SUB)
            Text('选填')
              .fontSize(11)
              .fontColor(Theme.TEXT_SUB)
              .margin({ left: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          TextInput({
            text: this.inputName,
            placeholder: '留空则自动取域名'
          })
            .width('100%')
            .fontSize(14)
            .height(48)
            .backgroundColor(Theme.CARD_BG)
            .borderRadius(Theme.RADIUS_MEDIUM)
            .maxLength(60)
            .type(InputType.Normal)
            .onChange((value: string) => {
              this.inputName = value;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 说明
        Column({ space: 4 }) {
          Text('说明')
            .fontSize(12)
            .fontColor(Theme.TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text('· HTTP / HTTPS：点播地址，可直接播放')
            .fontSize(11)
            .fontColor(Theme.TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text('· RTSP / RTMP：实时流，本阶段可保存，播放待后续支持')
            .fontSize(11)
            .fontColor(Theme.TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Start)
          Text('· 添加时不做联网探测，连通性在播放时判定')
            .fontSize(11)
            .fontColor(Theme.TEXT_SUB)
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .padding({ top: 4 })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING })

      // ================= 按钮区 =================
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .fontSize(15)
          .height(46)
          .backgroundColor(Theme.THUMB_PLACEHOLDER)
          .fontColor(Theme.TEXT_MAIN)
          .onClick(() => {
            this.getUIContext().getRouter().back();
          })

        Button(this.isEditing() ? '保存' : '添加')
          .layoutWeight(1)
          .fontSize(15)
          .height(46)
          .backgroundColor(Theme.ACCENT)
          .enabled(NetworkStreamStore.validateUrl(this.inputUrl).length === 0)
          .onClick(() => {
            this.submit();
          })
      }
      .width('100%')
      .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, top: 24 })

      Blank()
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
