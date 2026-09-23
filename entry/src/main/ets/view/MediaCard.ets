import { Theme } from '../common/Theme';
import { VideoItem } from '../common/MediaData';

/**
 * 视频卡片（对应 HTML 中的 .card）
 * 支持两种数据来源：
 *   1) 真实观看记录：item.path 非空，progress 可能有值（显示进度线）
 *   2) 占位数据：item.path 为空，点击后由父组件决定跳搜索页
 */
@Component
export struct MediaCard {
  /**
   * 卡片数据
   *
   * 注意 @Watch：封面是**异步迟到**的数据。
   * ForEach 的键是 item.path，路径不变时 ArkUI 会复用组件实例，
   * 而复用不会重新初始化 @Prop —— 卡片就会一直停留在最初的空封面值上。
   * 因此必须显式监听字段变化，把值搬进 @State 由它驱动重绘。
   */
  @Prop @Watch('onItemChanged') item: VideoItem;
  /** 当前生效的封面路径（由 @State 驱动渲染，保证复用实例也能刷新） */
  @State thumbSrc: string = '';
  /** 当前生效的网络封面地址 */
  @State coverSrc: string = '';
  /** 封面图是否加载失败，失败时使用渐变占位底色 */
  @State coverFailed: boolean = false;
  /** 点击回调，对应 HTML 中的 onclick="playVideo(...)" */
  onPlay?: (item: VideoItem) => void;
  /**
   * 渲染回调：把组件实际拿到的封面路径报给父组件
   * 用于区分"数据没传到"和"传到了但 Image 画不出来"这两类问题
   */
  onRendered?: (title: string, thumbPath: string) => void;

  aboutToAppear(): void {
    this.syncSources();
    // 组件挂载时把实际收到的封面路径回报一次
    this.onRendered?.(this.item.title, this.thumbSrc);
  }

  /** item 变化时（含封面迟到）同步到 @State */
  onItemChanged(): void {
    this.syncSources();
    this.onRendered?.(this.item.title, this.thumbSrc);
  }

  /** 把 item 里的封面字段搬到 @State */
  private syncSources(): void {
    this.thumbSrc = this.item.thumbPath;
    this.coverSrc = this.item.cover;
  }

  build() {
    Column({ space: 8 }) {
      // ---- 封面 (对应 .card-thumb) ----
      // alignContent 必须是 BottomEnd：
      //   时长胶囊要贴右下角，进度线要贴底并横向铺满。
      //   如果只依赖子节点各自的 .align()，子节点会被这里默认的
      //   Alignment.Center 居中 —— 进度条就会变成"从中向外衍生"。
      Stack({ alignContent: Alignment.BottomEnd }) {
        // 图片未加载完成前的底色，以及加载失败时的渐变回退
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 135,
            colors: [[this.item.fallbackColors[0], 0.0], [this.item.fallbackColors[1], 1.0]]
          })

        // 优先显示视频内置封面（缓存下来的 JPEG 文件路径）
        if (this.thumbSrc.length > 0) {
          Image(this.thumbSrc)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            // 显式压过下方那层铺满的渐变 Column，避免被它盖住
            .zIndex(1)
            .onError(() => {
              // 加载失败要能被发现：上报给父组件写日志
              this.onRendered?.(this.item.title, 'LOAD_ERROR:' + this.thumbSrc);
            })
        } else if (this.coverSrc.length === 0) {
          // 没有内置封面也没有网络封面：用播放标识占位，避免空白块
          Column() {
            Text('▶')
              .fontSize(28)
              .fontColor('rgba(255,255,255,0.85)')
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (!this.coverFailed) {
          Image(this.coverSrc)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .onError(() => {
              this.coverFailed = true;
            })
        }

        // ---- 时长胶囊 (对应 .card-duration) ----
        Text(this.item.duration)
          .fontSize(10)
          .fontColor(Color.White)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor('rgba(0,0,0,0.70)')
          .borderRadius(4)
          .margin({ right: 6, bottom: 6 })

        // ---- 续播进度线：只有真实记录且未播完时才画 ----
        // 内层 Stack 用 alignContent: Start 保证填充条从左端起算；
        // 它自身不带 .align()，位置完全由外层 Stack 的 BottomEnd 决定。
        if (this.item.progress > 0.01 && this.item.progress < 0.99) {
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(3)
              .backgroundColor('rgba(255,255,255,0.35)')
            Row()
              .width(`${this.item.progress * 100}%`)
              .height(3)
              .backgroundColor(Theme.ACCENT)
          }
          .width(Theme.CARD_WIDTH)
          .height(3)
        }
      }
      .width(Theme.CARD_WIDTH)
      .height(Theme.CARD_HEIGHT)
      .borderRadius(Theme.RADIUS_MEDIUM)
      .clip(true)
      .shadow({
        radius: 16,
        color: 'rgba(0,0,0,0.06)',
        offsetX: 0,
        offsetY: 8
      })

      // ---- 文字信息 (对应 .card-info) ----
      Column({ space: 2 }) {
        Text(this.item.title)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(this.item.subtitle)
          .fontSize(11)
          .fontColor(Theme.TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width(Theme.CARD_WIDTH)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onPlay?.(this.item);
    })
  }
}
