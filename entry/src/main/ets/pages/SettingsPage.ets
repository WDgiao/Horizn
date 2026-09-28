import { Theme } from '../common/Theme';
import { showToast } from '../common/Toast';

/**
 * 设置页
 *
 * ★ 2026-09-29 自检修正：文件开头原本有**两段**「设置页」文档注释
 *   （第一段讲搬迁历史，第二段讲布局策略），各自描述同一件事的不同侧面，
 *   读起来像是两个不同的人各写了一份。合并成一段。
 *
 * ---- 搬迁历史 ----
 *   解码能力诊断与各种自测工具（真解码 / 原生自测 / 软解探针 / 出素材 /
 *   拉高清 / 跳转压测 / 抽帧自测 …）已整体搬到 pages/DeveloperModePage，
 *   本页只保留一个「开发者模式」入口（列表最后一项）。
 *   这样设置页不再被开发工具占据显眼位置，相关状态与方法也不再常驻于此
 *   —— 原先本页还挂着一个只为取 surfaceId 的隐藏 XComponent，也已一并移走。
 *
 * ---- 布局策略（经设备实测宽度后确定）----
 *   1) 滑动区容器统一 padding = PAGE_PADDING(24vp)，所有区块不再各自设横向 margin
 *   2) 开关行不用 layoutWeight：文字自然宽度 + Blank() 撑开剩余空间
 *      —— 因为 Toggle 带默认边距，layoutWeight 的分配结果会溢出容器
 *   3) 区块一律不设 width('100%')，避免与 padding 叠加撑宽
 *
 * ---- 功能状态 ----
 *   设置项除「网络流」「开发者模式」外均为占位，点击只提示待完善。
 */

/** 待完善的设置项 */
interface SettingItem {
  /** 图标 */
  icon: string;
  /** 标题 */
  title: string;
  /** 右侧说明 */
  summary: string;
}

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
    { icon: 'ℹ️', title: '关于', summary: '版本 1.0.0' },
    // 开发期自测工具整页搬去了 DeveloperModePage，
    // 这里只留一个入口 —— 设置页不该被开发工具占据显眼位置
    { icon: '🛠️', title: '开发者模式', summary: '解码能力诊断 · 自测工具' }
  ];

  /** 占位开关，仅用于演示控件样式，暂不产生实际效果 */
  @State hardwareDecode: boolean = true;
  @State autoScan: boolean = false;

  aboutToDisappear(): void {
    // 本页已不再持有原生播放器（自测逻辑整体搬到 DeveloperModePage），
    // 因此这里不需要释放任何东西。保留空实现是为了以后本页若再加
    // 需要清理的资源时有个明确的落点。
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

        // ---------- 诊断卡片已整体搬到「开发者模式」页 ----------
        //  原来这张卡（8 个自测按钮 + 隐藏 XComponent）挂在设置页顶部，
        //  对普通使用者没有意义却占着最显眼的位置，
        //  相关的状态与方法也随之删除。设置页只留「开发者模式」入口。

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
                // 「网络流」已有独立页面（列表 / 增删改 / 持久化都可用），
                // 它不再属于"功能待完善"那一类
                if (item.title === '网络流') {
                  this.getUIContext().getRouter()
                    .pushUrl({ url: 'pages/NetworkStreamPage' })
                    .catch(() => {
                      showToast('无法打开网络流页');
                    });
                  return;
                }
                // 「开发者模式」：解码能力诊断与各种自测工具都搬到了那一页，
                // 设置页只留入口
                if (item.title === '开发者模式') {
                  this.getUIContext().getRouter()
                    .pushUrl({ url: 'pages/DeveloperModePage' })
                    .catch(() => {
                      showToast('无法打开开发者模式页');
                    });
                  return;
                }
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
