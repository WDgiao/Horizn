import { Theme } from '../common/Theme';
import { HeroItem } from '../common/MediaData';

/**
 * 焦点推荐位 (Hero Section)
 * 对应 HTML 中的 .hero 区块：220vp 高、圆角 20、底部深色渐变遮罩、进度条
 */
@Component
export struct HeroBanner {
  /** 推荐位数据 */
  @Prop hero: HeroItem;
  /** 封面图是否加载失败，失败时保留中性渐变底色 */
  @State coverFailed: boolean = false;
  /** 点击回调，对应 HTML 中的 onclick="playVideo(...)" */
  onPlay?: (title: string) => void;

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // ---- 背景图层 (对应 .hero-bg) ----
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 135,
          colors: [[Theme.THUMB_PLACEHOLDER, 0.0], ['#D8DCE6', 1.0]]
        })

      // 优先显示视频内置封面（缓存下来的 JPEG 文件路径）
      if (this.hero.thumbPath.length > 0) {
        Image(this.hero.thumbPath)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else if (this.hero.cover.length > 0 && !this.coverFailed) {
        Image(this.hero.cover)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .onError(() => {
            this.coverFailed = true;
          })
      }

      // ---- 深色渐变遮罩 + 文字内容 (对应 .hero-overlay) ----
      // 图片上方白色文字需要深色底才能看清，因此这里保留深色渐变
      Column() {
        Text(this.hero.tag)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .letterSpacing(1)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(Theme.ACCENT)
          .borderRadius(6)
          .margin({ bottom: 8 })

        Text(this.hero.title)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ bottom: 8 })

        Row() {
          Text(this.hero.meta)
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.70)')
          Text('•')
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.70)')
            .margin({ left: 12, right: 12 })
          Text(this.hero.remain)
            .fontSize(13)
            .fontColor('rgba(255,255,255,0.70)')
        }
        .alignItems(VerticalAlign.Center)

        // ---- 进度条 (对应 .hero-progress) ----
        // alignContent: Start 让填充条从左端起算，不依赖子节点 .align()
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .backgroundColor('rgba(255,255,255,0.30)')
            .borderRadius(2)

          Row()
            .width(`${this.hero.progress * 100}%`)
            .height(3)
            .backgroundColor(Theme.ACCENT)
            .borderRadius(2)
        }
        .width('100%')
        .height(3)
        .margin({ top: 12 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.End)
      .padding(24)
      // angle: 0 表示颜色从底部向顶部渐变，即 CSS 的 linear-gradient(to top, ...)
      // 因此 colors 的 0.0 位置对应底部、1.0 位置对应顶部：
      // 底部最黑（保证白色片名/元信息可读），顶部完全透明（露出封面图）
      .linearGradient({
        angle: 0,
        colors: [
          ['rgba(0,0,0,0.90)', 0.0],
          ['rgba(0,0,0,0.40)', 0.5],
          ['rgba(0,0,0,0.00)', 1.0]
        ]
      })
    }
    .width('100%')
    .height(220)
    .borderRadius(Theme.RADIUS_LARGE)
    .clip(true)
    // 浅色模式下阴影更柔和更淡
    .shadow({
      radius: 40,
      color: 'rgba(0,0,0,0.08)',
      offsetX: 0,
      offsetY: 20
    })
    .onClick(() => {
      this.onPlay?.(this.hero.title);
    })
  }
}
