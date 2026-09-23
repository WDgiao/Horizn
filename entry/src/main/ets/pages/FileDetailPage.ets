import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { initToast } from '../common/Toast';
import { MediaFileDetail, MediaFileOps } from '../model/MediaFileOps';
import { buildMediaFile } from '../common/MediaFiles';
import { formatSize } from '../common/MediaFiles';
import { MediaTier, mediaTierOf } from '../common/MediaType';

/** 详情页路由参数 */
export interface FileDetailParams {
  /** 文件完整路径 */
  path: string;
  /** 文件名 */
  name: string;
  /** 文件大小 */
  size: number;
}

/** 一行「标签 + 值」 */
interface DetailRow {
  label: string;
  value: string;
}

/**
 * 文件详细信息页
 * 展示文件系统信息（大小/时间/路径）与媒体信息（时长/分辨率/MIME）
 */
@Entry
@Component
struct FileDetailPage {
  /** 加载中 */
  @State loading: boolean = true;
  /** 展示用的行数据 */
  @State rows: DetailRow[] = [];
  /** 文件名 */
  @State fileName: string = '';

  aboutToAppear(): void {
    initToast(this.getUIContext());
    const params = this.getUIContext().getRouter().getParams() as FileDetailParams;
    if (params === undefined || params === null || params.path === undefined) {
      this.loading = false;
      return;
    }
    this.fileName = params.name !== undefined ? params.name : '';
    this.loadDetail(params.path, params.size !== undefined ? params.size : 0);
  }

  /** 读取详情并组装成行 */
  private async loadDetail(path: string, size: number): Promise<void> {
    this.loading = true;
    const file = buildMediaFile(path, size);
    const detail: MediaFileDetail = await MediaFileOps.detail(file);

    const list: DetailRow[] = [];
    list.push({ label: '文件名', value: detail.name });
    list.push({ label: '类型', value: detail.extension.length > 0
      ? ('.' + detail.extension) : '未知' });
    list.push({ label: '大小', value: detail.sizeText
      + '（' + detail.size.toString() + ' 字节）' });
    if (detail.resolutionText.length > 0) {
      list.push({ label: '画面尺寸', value: detail.resolutionText });
    }
    if (detail.durationText.length > 0) {
      list.push({ label: '时长', value: detail.durationText });
    }
    if (detail.mimeText.length > 0) {
      list.push({ label: 'MIME', value: detail.mimeText });
    }
    if (detail.modifiedText.length > 0) {
      list.push({ label: '修改时间', value: detail.modifiedText });
    }
    // 用实测分级给出具体原因，而不是笼统的"是否可播放"
    const tier: MediaTier = mediaTierOf(detail.name);
    let tierText: string = '否（格式不在白名单）';
    if (tier === MediaTier.PLAYABLE) {
      tierText = '是（系统解码器直接支持）';
    } else if (tier === MediaTier.MAYBE_PLAYABLE) {
      tierText = '看编码而定（容器可解，内部编码可能不支持）';
    } else if (tier === MediaTier.NEEDS_SOFT_DECODE) {
      tierText = '需内置软解（系统不支持该容器的解封装）';
    }
    list.push({ label: '播放能力', value: tierText });
    list.push({ label: '所在目录', value: detail.folder });
    list.push({ label: '完整路径', value: detail.path });

    this.rows = list;
    this.loading = false;
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
        Text('文件信息')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 24, top: 20, bottom: 12 })

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(Theme.ACCENT)
          Text('正在读取文件信息…')
            .fontSize(13)
            .fontColor(Theme.TEXT_SUB)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.rows, (row: DetailRow) => {
            ListItem() {
              Column({ space: 6 }) {
                Text(row.label)
                  .fontSize(12)
                  .fontColor(Theme.TEXT_SUB)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                Text(row.value)
                  .fontSize(14)
                  .fontColor(Theme.TEXT_MAIN)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  // 路径很长时允许换行，便于复制核对
                  .copyOption(CopyOptions.LocalDevice)
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(14)
              .backgroundColor(Theme.CARD_BG)
              .borderRadius(14)
            }
          }, (row: DetailRow) => row.label)
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: Theme.PAGE_PADDING, right: Theme.PAGE_PADDING, bottom: 24 })
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
