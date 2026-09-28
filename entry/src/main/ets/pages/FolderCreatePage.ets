import { common } from '@kit.AbilityKit';
import { Theme } from '../common/Theme';
import { FolderRepository } from '../model/FolderRepository';
import { showToast, initToast } from '../common/Toast';

/**
 * 新建文件夹页
 *
 * 为什么用独立页面而不是对话框：
 *   AlertDialog 在本 SDK 版本（API 26）不支持文本输入框
 *   （没有 textField 字段），CustomDialogController 的 @Builder
 *   引用组件 this 在 ArkTS 里实例化时机不可靠。
 *   独立页面没有这两个问题，且输入空间更大、体验更好。
 */
@Entry
@Component
struct FolderCreatePage {
  /** 用户输入的名称 */
  @State folderName: string = '';
  /** 已存在的文件夹名，用于实时提示重名 */
  @State existingNames: string[] = [];

  private repo: FolderRepository | undefined = undefined;

  aboutToAppear(): void {
    initToast(this.getUIContext());
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.repo = new FolderRepository(ctx);
    this.loadExisting();
  }

  /** 载入已有文件夹名，用于输入时即时校验 */
  private loadExisting(): void {
    const r: FolderRepository | undefined = this.repo;
    if (r === undefined) {
      return;
    }
    const list = r.listFolders();
    const names: string[] = [];
    for (let i = 0; i < list.length; i++) {
      names.push(list[i].name);
    }
    this.existingNames = names;
  }

  /** 校验输入，返回错误文案；合法则返回空串 */
  private validate(): string {
    const name: string = this.folderName.trim();
    if (name.length === 0) {
      return '请输入文件夹名称';
    }
    if (name.indexOf('/') >= 0 || name.indexOf('\\') >= 0) {
      return '名称不能包含斜杠';
    }
    if (name === '.' || name === '..') {
      return '该名称不可用';
    }
    if (this.existingNames.indexOf(name) >= 0) {
      return '已存在同名文件夹';
    }
    return '';
  }

  /**
   * 提交创建
   *
   * ★ 2026-09-29 自检修正：删掉了原先的 `submitting` 状态。
   *
   *   它写着"避免重复点击"，但用法是：
   *     this.submitting = true;
   *     const result = r.createFolder(...);   // 同步调用
   *     this.submitting = false;
   *   整个 true→false 发生在一个同步函数体里，中间没有让出主线程，
   *   所以 `if (this.submitting) return;` **永远不可能命中** ——
   *   第二次点击根本插不进来。而且它也没有接到按钮的 enabled 上，
   *   界面完全看不到它。留着它只会让人以为"这里已经防重复了"，
   *   从而不再考虑真正的异步场景（比如以后把创建改成异步操作）。
   *   createFolder 是同步的，ArkUI 的事件回调也不会重入，
   *   防重复点击在这一层本来就不需要。
   */
  private submit(): void {
    const error: string = this.validate();
    if (error.length > 0) {
      showToast(error);
      return;
    }
    const r: FolderRepository | undefined = this.repo;
    if (r === undefined) {
      showToast('存储不可用');
      return;
    }
    const result: string = r.createFolder(this.folderName);
    if (result.length > 0) {
      showToast(result);
      return;
    }
    showToast('已创建：' + this.folderName.trim());
    this.getUIContext().getRouter().back();
  }

  /** 取消返回 */
  private cancel(): void {
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
            this.cancel();
          })

        Text('新建文件夹')
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
        Text('文件夹名称')
          .fontSize(13)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)

        TextInput({ text: this.folderName, placeholder: '例如：我的电影' })
          .fontSize(15)
          .height(48)
          .backgroundColor(Theme.CARD_BG)
          .borderRadius(12)
          .maxLength(60)
          .onChange((value: string) => {
            this.folderName = value;
          })

        Text('将创建在应用目录中，创建后可在搜索页扫描到')
          .fontSize(12)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)

        // 实时校验提示
        if (this.folderName.trim().length > 0) {
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
            this.cancel();
          })

        Button('创建')
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
