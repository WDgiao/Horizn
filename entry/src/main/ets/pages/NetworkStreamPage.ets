import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { showToast, initToast, confirmDialog } from '../common/Toast';
import { NetworkStream, NetworkStreamStore, StreamProtocol } from '../model/NetworkStreamStore';

/**
 * 传给播放页的路由参数
 *
 * 字段名必须与 PlayerPage 的 PlayerParams 完全一致，
 * 否则播放页读不到（那边是按名字取的）。
 */
interface NetworkPlayParams {
  path: string;
  title: string;
  startMs?: number;
}

/**
 * 网络流管理页
 *
 * 当前阶段：**UI 框架**。
 *   列表、空状态、增删改、持久化、协议识别都已可用；
 *   点条目播放尚未接通 —— 会明确提示"播放功能待接通"，
 *   而不是假装能播。
 *
 * 为什么是独立页面而不是设置页里的一个弹窗：
 *   与「重命名」同样的理由（见 RenamePage 的说明）——
 *   AlertDialog 在本 SDK 版本不支持文本输入框，
 *   CustomDialogController 的 @Builder 引用 this 时机不可靠。
 *   独立页面两个问题都没有，输入体验也好得多。
 *
 * 为什么列表要显示协议标签：
 *   用户看一长串 URL 判断不出"这个能不能播"。直接把 HTTP/RTSP/RTMP
 *   标出来，并让目前不可播的那些显示为次要色 + 明确提示，
 *   用户不用点开就知道结果，也不会以为添加成功就能播。
 */
@Entry
@Component
struct NetworkStreamPage {
  /** 全部网络流（界面渲染用） */
  @State streams: NetworkStream[] = [];
  /** 仓库实例 */
  private store: NetworkStreamStore | undefined = undefined;

  aboutToAppear(): void {
    initToast(this.getUIContext());
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.store = new NetworkStreamStore(ctx);
    this.reload();
  }

  /**
   * 从播放页返回后重新加载
   *
   * 与 SearchPage 同样的坑：本页是压栈跳转，返回时走 onPageShow、
   * 不会重新 aboutToAppear，而仓库有内存缓存 —— 不失效就会读到旧数据。
   */
  onPageShow(): void {
    const s: NetworkStreamStore | undefined = this.store;
    if (s !== undefined) {
      s.invalidateCache();
    }
    this.reload();
  }

  /** 重新读取列表 */
  private reload(): void {
    const s: NetworkStreamStore | undefined = this.store;
    if (s === undefined) {
      return;
    }
    this.streams = s.list();
  }

  /** 去添加页 */
  private openAdd(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/StreamEditPage' }).catch(() => {
      showToast('无法打开添加页');
    });
  }

  /** 去编辑页（改名 / 改地址） */
  private openEdit(item: NetworkStream): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/StreamEditPage',
      params: { id: item.id }
    }).catch(() => {
      showToast('无法打开编辑页');
    });
  }

  /**
   * 点击条目：交给播放页
   *
   * 播放页会识别出 http(s):// 并改走 AVPlayer 的 url 通道
   * （见 PlayerPage.createNetworkPlayer）。
   *
   * 不可播的协议不进播放页 —— 让用户进去看一眼再弹错，不如当场说明。
   */
  private onItemClick(item: NetworkStream): void {
    if (!NetworkStreamStore.isPlayable(item.protocol)) {
      showToast(NetworkStreamStore.protocolLabel(item.protocol)
        + ' 暂不支持播放，地址已保存');
      return;
    }
    // 记一次使用时间，列表里能看到"上次使用"
    // 只更新时间戳：name 与 url 都传空串表示不改动
    const s: NetworkStreamStore | undefined = this.store;
    if (s !== undefined) {
      s.update(item.id, '', '', true);
    }
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/PlayerPage',
      params: {
        path: item.url,
        title: item.name,
        // 网络流没有续播起点：一是没有进度记录，
        // 二是实时流没有总时长，seek 行为未定义。
        // 显式传 0，与 PlayerParams.startMs 的可选语义保持一致。
        startMs: 0
      } as NetworkPlayParams
    }).catch(() => {
      showToast('无法打开播放页');
    });
  }

  /** 删除一条（带确认） */
  private async removeOne(item: NetworkStream): Promise<void> {
    const ok: boolean = await confirmDialog('删除网络流', '确定删除「' + item.name + '」？');
    if (!ok) {
      return;
    }
    const s: NetworkStreamStore | undefined = this.store;
    if (s === undefined) {
      return;
    }
    if (s.remove(item.id)) {
      showToast('已删除');
      this.reload();
    } else {
      showToast('删除失败');
    }
  }

  /** 时间戳格式化成 yyyy-MM-dd HH:mm */
  private formatTime(ms: number): string {
    if (ms <= 0) {
      return '';
    }
    const d: Date = new Date(ms);
    const pad = (n: number): string => n < 10 ? ('0' + n.toString()) : n.toString();
    return d.getFullYear().toString() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
      + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
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
        Text('网络流')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_MAIN)
          .layoutWeight(1)
        Text('+ 添加')
          .fontSize(15)
          .fontColor(Theme.ACCENT)
          .padding({ left: 12, right: 4 })
          .onClick(() => {
            this.openAdd();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 20, top: 20, bottom: 12 })

      // ================= 说明区 =================
      Column({ space: 4 }) {
        Text(this.streams.length > 0
          ? ('已保存 ' + this.streams.length.toString() + ' 个地址')
          : '还没有保存任何地址')
          .fontSize(13)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('当前仅 HTTP / HTTPS 可播放；RTSP、RTMP 可先存着等后续支持')
          .fontSize(11)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      // ★ 左右 padding 不能漏：只写 bottom 时文字会顶到屏幕左边缘并溢出换行
      //   （实测第一版就是这样，截图里「支持」两个字被折到了第二行贴边）
      .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, bottom: 12 })

      // ================= 列表 / 空状态 =================
      if (this.streams.length === 0) {
        Column({ space: 10 }) {
          Text('🌐')
            .fontSize(48)
          Text('还没有网络流地址')
            .fontSize(16)
            .fontColor(Theme.TEXT_MAIN)
          Text('点右上角「+ 添加」保存一个 HTTP / HTTPS 地址')
            .fontSize(12)
            .fontColor(Theme.TEXT_SUB)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          ForEach(this.streams, (item: NetworkStream) => {
            ListItem() {
              Row({ space: 12 }) {
                // 协议徽标
                Text(NetworkStreamStore.protocolLabel(item.protocol))
                  .fontSize(11)
                  .fontColor(Color.White)
                  .backgroundColor(NetworkStreamStore.isPlayable(item.protocol)
                    ? Theme.ACCENT : Theme.TEXT_SUB)
                  .borderRadius(6)
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .width(52)
                  .textAlign(TextAlign.Center)

                Column({ space: 4 }) {
                  Text(item.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.TEXT_MAIN)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.url)
                    .fontSize(11)
                    .fontColor(Theme.TEXT_SUB)
                    .width('100%')
                    .textAlign(TextAlign.Start)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (item.lastPlayedAt > 0) {
                    Text('上次使用 ' + this.formatTime(item.lastPlayedAt))
                      .fontSize(10)
                      .fontColor(Theme.TEXT_SUB)
                      .width('100%')
                      .textAlign(TextAlign.Start)
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('✎')
                  .fontSize(16)
                  .fontColor(Theme.ACCENT)
                  .padding(6)
                  .onClick(() => {
                    this.openEdit(item);
                  })

                Text('🗑')
                  .fontSize(16)
                  .fontColor(Theme.TEXT_SUB)
                  .padding(6)
                  .onClick(() => {
                    this.removeOne(item);
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding(14)
              .backgroundColor(Theme.CARD_BG)
              .borderRadius(Theme.RADIUS_MEDIUM)
              .onClick(() => {
                this.onItemClick(item);
              })
            }
          }, (item: NetworkStream) => item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING })
        .scrollBar(BarState.Off)
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
