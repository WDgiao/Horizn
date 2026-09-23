import { Theme } from '../common/Theme';
import { FolderItem, FOLDER_ICON } from '../common/MediaData';

/**
 * 文件夹卡片（对应「我的文件夹」区域的卡片）
 * item.path 为空时表示这是一个占位/操作项（例如「新建文件夹」）
 */
@Component
export struct FolderCard {
  /** 文件夹数据 */
  @Prop item: FolderItem;
  /** 点击回调 */
  onOpen?: (item: FolderItem) => void;

  build() {
    Column({ space: 8 }) {
      // ---- 封面占位：白到浅灰渐变 + 图标 ----
      Stack({ alignContent: Alignment.Center }) {
        Text(FOLDER_ICON)
          .fontSize(40)
          .fontColor(Theme.TEXT_SUB)
      }
      .width(Theme.CARD_WIDTH)
      .height(Theme.CARD_HEIGHT)
      .borderRadius(Theme.RADIUS_MEDIUM)
      .clip(true)
      .linearGradient({
        angle: 135,
        colors: [[Theme.CARD_BG, 0.0], [Theme.THUMB_PLACEHOLDER, 1.0]]
      })
      .shadow({
        radius: 16,
        color: 'rgba(0,0,0,0.06)',
        offsetX: 0,
        offsetY: 8
      })

      // ---- 文字信息 ----
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
      this.onOpen?.(this.item);
    })
  }
}
