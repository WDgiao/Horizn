import { Theme } from '../common/Theme';
import { showToast, initToast, infoDialog } from '../common/Toast';

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
 * ---- ★ 2026-10-03 精简（用户要求）★ ----
 *   原来这个页面塞了 9 个条目 + 一张"演示用开关"卡片，其中不少是
 *   **点了只弹一句"功能待完善"** 的东西，甚至同一个功能有两个入口。
 *   现在只保留 6 项：播放设置 / 音频设置 / 字幕设置 / 外观 / 关于 / 开发者模式。
 *
 *   删掉的 3 项以及"为什么可以删"（都不是拍脑袋，逐条查过入口）：
 *     · 媒体库目录 —— 纯占位项，真正的目录管理在首页
 *       （Index.ets 的「新建文件夹」→ FolderCreatePage）和搜索页的
 *       「扫描目录」面板里，设置页这一条只是重复了一个空壳。
 *     · 手势与快捷键 —— 纯占位，且应用里根本没有手势/快捷键体系。
 *     · 网络流 —— 它的独立页面（NetworkStreamPage）仍然可用的前提下，
 *       入口在**首页**（Index.ets 里 pushUrl 到同一页），
 *       设置页这条属于重复入口，删掉不会让功能失去入口。
 *   另外删掉了「硬件解码」「启动时自动扫描媒体库」两个演示开关：
 *   它们的作用就是"演示控件样式"，一拨就弹"（功能待实现）"，
 *   正是用户说的"用不上的东西"。
 *
 *   保留下来的项里，尚未实现的会在行内标出「待实现」（见 pending 字段），
 *   不再用页面顶部那条"以下功能尚未实现"的横幅笼统提示 ——
 *   逐项标注比一句横幅准确，也不会让能用的项被一起误解。
 */

/** 设置项 */
interface SettingItem {
  /** 图标 */
  icon: string;
  /** 标题 */
  title: string;
  /** 右侧说明 */
  summary: string;
  /**
   * 是否尚未实现（行内显示「待实现」标记）
   *
   * 为什么要逐项标出来：这些项点击后只会提示"待完善"，
   * 不标的话用户会以为坏了；标出来一眼就知道是还没做。
   */
  pending: boolean;
}

@Entry
@Component
struct SettingsPage {
  @State items: SettingItem[] = [
    // ★ 2026-10-03：只剩这 6 项（删掉的三项与理由见文件头注释）
    //   「播放设置」「字幕设置」已做成独立子页，不再是占位（pending=false）
    { icon: '▶️', title: '播放设置', summary: '解码方式 · 回退策略 · 续播 · 旋转', pending: false },
    { icon: '🔊', title: '音频设置', summary: '音轨 · 音量增益', pending: true },
    { icon: '🔤', title: '字幕设置', summary: '默认语言 · 外挂优先 · 字号 · 底衬', pending: false },
    { icon: '🎨', title: '外观', summary: '浅色 · 深色 · 跟随系统', pending: true },
    // ★ 2026-09-29：应用名定为「Horizn|视界」，这里原来只有一个版本号，
    //   用户在设置里看不到软件叫什么。补上名字（版本号仍来自 app.json5 的
    //   versionName，目前是 1.0.0；两边改动时要一起改）。
    //   2026-10-03 起这条不再是"点了只提示待完善"的占位：
    //   点击会弹出真正的信息框（版本 / 引擎 / 支持格式范围）。
    { icon: 'ℹ️', title: '关于', summary: 'Horizn|视界 · 版本 1.0.0', pending: false },
    // 开发期自测工具整页搬去了 DeveloperModePage，
    // 这里只留一个入口 —— 设置页不该被开发工具占据显眼位置
    { icon: '🛠️', title: '开发者模式', summary: '解码能力诊断 · 自测工具', pending: false }
  ];

  aboutToAppear(): void {
    // 与其它页面保持一致：本页要弹 toast（设置项未实现时的提示）和
    // 「关于」的信息框，先把 UI 上下文注入进来。
    // 不注入也能work（入口页早已注入过），但页面自成一体更稳。
    initToast(this.getUIContext());
  }

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
        // ★ 2026-10-03：原来这里有一条「🚧 以下功能尚未实现…」的横幅，
        //   还有一张"硬件解码 / 启动时自动扫描"的演示开关卡片，都已删除。
        //   理由：横幅是笼统说法（保留下来的「关于」「开发者模式」其实是能用的），
        //   而演示开关一拨就弹"（功能待实现）"，属于用户说的"用不上的东西"。
        //   现在改为在每个尚未实现的条目上标「待实现」，逐项标注意思更准确。

        // ---------- 诊断卡片已整体搬到「开发者模式」页 ----------
        //  原来这张卡（8 个自测按钮 + 隐藏 XComponent）挂在设置页顶部，
        //  对普通使用者没有意义却占着最显眼的位置，
        //  相关的状态与方法也随之删除。设置页只留「开发者模式」入口。

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
                  Row({ space: 6 }) {
                    Text(item.title)
                      .fontSize(14)
                      .fontColor(Theme.TEXT_MAIN)

                    // 「待实现」标记：这些项点下去只会提示待完善，
                    // 标出来才不会让人以为坏了
                    if (item.pending) {
                      Text('待实现')
                        .fontSize(10)
                        .fontColor(Theme.ACCENT)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(8)
                        .backgroundColor('rgba(0,125,255,0.12)')
                    }
                  }
                  .alignItems(VerticalAlign.Center)

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
                // 「关于」：2026-10-03 起给出真正的信息框，不再是"待完善"提示。
                // 注意必须把**本页的** UIContext 传进去（缓存的那个属于入口页，
                // showDialog 用它弹不出来，实测过）。
                if (item.title === '关于') {
                  infoDialog(this.getUIContext(), 'Horizn|视界',
                    '版本 1.0.0\n'
                      + '内置软解引擎的本地媒体播放器\n\n'
                      + '· 系统硬解（AVPlayer）：MP4 / MKV / MOV / MPEG / 3GP 等\n'
                      + '· 内置软解（FFmpeg）：RMVB / RM / WMV / ASF / OGV / MXF 等\n'
                      + '· 支持内嵌与外挂字幕、多音轨切换');
                  return;
                }
                // 2026-10-03 起「播放设置」「字幕设置」是真正的子页了，
                // 不再是"点了只提示待完善"的占位
                if (item.title === '播放设置') {
                  this.getUIContext().getRouter()
                    .pushUrl({ url: 'pages/PlaybackSettingsPage' })
                    .catch(() => {
                      showToast('无法打开播放设置页');
                    });
                  return;
                }
                if (item.title === '字幕设置') {
                  this.getUIContext().getRouter()
                    .pushUrl({ url: 'pages/SubtitleSettingsPage' })
                    .catch(() => {
                      showToast('无法打开字幕设置页');
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
