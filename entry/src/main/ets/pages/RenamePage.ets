import { Theme } from '../common/Theme';
import { showToast, initToast } from '../common/Toast';
import { MediaFileOps } from '../model/MediaFileOps';
import { getExtension } from '../common/MediaType';

/** 重命名页路由参数 */
export interface RenameParams {
  /** 文件完整路径 */
  path: string;
  /** 当前文件名 */
  name: string;
}

/**
 * 重命名页
 *
 * 为什么用独立页面而不是对话框：
 *   AlertDialog 在本 SDK 版本不支持文本输入框，
 *   CustomDialogController 的 @Builder 引用组件 this 时机不可靠。
 *   独立页面两个问题都没有，输入体验也更好。
 */
@Entry
@Component
struct RenamePage {
  /** 文件完整路径 */
  @State filePath: string = '';
  /** 原文件名 */
  @State originalName: string = '';
  /** 用户输入的新名称（不含后缀） */
  @State inputName: string = '';
  /** 后缀，显示为固定尾巴 */
  @State extension: string = '';

  aboutToAppear(): void {
    initToast(this.getUIContext());
    const params = this.getUIContext().getRouter().getParams() as RenameParams;
    if (params !== undefined && params !== null) {
      if (params.path !== undefined) {
        this.filePath = params.path;
      }
      if (params.name !== undefined) {
        this.originalName = params.name;
      }
    }
    // 把后缀拆出来单独显示：用户改主名、后缀保持不变，避免误删扩展名
    const ext: string = getExtension(this.originalName);
    this.extension = ext.length > 0 ? ('.' + ext) : '';
    this.inputName = this.baseNameOf(this.originalName);
  }

  /** 去掉后缀的主名 */
  private baseNameOf(name: string): string {
    const dot: number = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /** 校验；返回错误文案，合法则空串 */
  private validate(): string {
    const candidate: string = this.inputName.trim() + this.extension;
    return MediaFileOps.validateName(candidate, this.originalName);
  }

  /** 提交重命名 */
  private submit(): void {
    const error: string = this.validate();
    if (error.length > 0) {
      showToast(error);
      return;
    }
    const newName: string = this.inputName.trim() + this.extension;
    const newPath: string = MediaFileOps.rename(this.filePath, newName);
    if (newPath.length === 0) {
      showToast('重命名失败，可能有同名文件');
      return;
    }
    showToast('已重命名为：' + newName);
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
        Text('重命名')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_MAIN)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 24, top: 20, bottom: 16 })

      // ================= 输入区 =================
      Column({ space: 12 }) {
        Text('原名称：' + this.originalName)
          .fontSize(12)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 主名与后缀分开：后缀固定显示，避免用户误删扩展名
        Row() {
          TextInput({ text: this.inputName, placeholder: '输入新名称' })
            .layoutWeight(1)
            .fontSize(15)
            .height(48)
            .backgroundColor(Theme.CARD_BG)
            .borderRadius({ topLeft: 12, bottomLeft: 12, topRight: 0, bottomRight: 0 })
            .maxLength(80)
            .onChange((value: string) => {
              this.inputName = value;
            })

          if (this.extension.length > 0) {
            Text(this.extension)
              .fontSize(15)
              .fontColor(Theme.TEXT_SUB)
              .height(48)
              .padding({ left: 10, right: 14 })
              .backgroundColor(Theme.THUMB_PLACEHOLDER)
              .borderRadius({ topRight: 12, bottomRight: 12 })
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 实时校验提示
        if (this.inputName.trim().length > 0) {
          if (this.validate().length > 0) {
            Text('⚠️ ' + this.validate())
              .fontSize(12)
              .fontColor(Theme.ACCENT)
              .width('100%')
              .textAlign(TextAlign.Start)
          } else {
            Text('✓ 名称可用')
              .fontSize(12)
              .fontColor('#34C759')
              .width('100%')
              .textAlign(TextAlign.Start)
          }
        }
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

        Button('保存')
          .layoutWeight(1)
          .fontSize(15)
          .height(46)
          .backgroundColor(Theme.ACCENT)
          .enabled(this.validate().length === 0)
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
