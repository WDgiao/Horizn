import { Theme } from '../common/Theme';
import { showToast, initToast } from '../common/Toast';
import { common } from '@kit.AbilityKit';
import { appSettings, AppSettings, DecodePreference, SettingsData, SettingsPatch } from '../model/AppSettings';

/**
 * 播放设置页
 *
 * 为什么做成独立页面而不是弹窗：
 *   与「新建文件夹」「网络流」同样的理由 —— AlertDialog 在本 SDK 版本不支持
 *   内嵌控件（开关/单选），CustomDialogController 的 @Builder 引用组件 this
 *   在 ArkTS 里实例化时机不可靠。独立页面的布局和返回都更好控制。
 *
 * 这里的每一项都**真的有实现**（不是占位）：
 *   · 解码方式      → PlayerPage.createPlayer 的通道选择
 *   · 失败自动回退   → PlayerPage.fallbackToSoft / 看门狗
 *   · 记住播放进度   → PlayerPage.persistProgress 落盘开关
 *   · 跟随设备旋转   → PlayerPage.setupWindow 的屏幕方向
 */

@Entry
@Component
struct PlaybackSettingsPage {
  /** 当前设置快照；每次改动后重新读一次，保证界面与磁盘一致 */
  @State data: SettingsData = {
    decodePreference: DecodePreference.AUTO,
    autoFallbackSoft: true,
    rememberProgress: true,
    allowAutoRotate: true,
    subtitleLanguage: 0,
    preferExternalSubtitle: true,
    autoLoadSidecar: false,
    subtitleFontSize: 1,
    subtitleBackground: true,
    // 色调 / 均衡器不在这里编辑（它们属于播放页的抽屉），
    // 但字段必须给全 —— ArkTS 的对象字面量要求覆盖接口的全部属性
    colorBrightness: 0,
    colorContrast: 0,
    colorSaturation: 0,
    colorHue: 0,
    colorRGain: 0,
    colorGGain: 0,
    colorBGain: 0,
    eqEnabled: false,
    eqPreset: '默认',
    eqBands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  };

  private store: AppSettings | undefined = undefined;

  aboutToAppear(): void {
    initToast(this.getUIContext());
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.store = appSettings(ctx);
      this.data = this.store.get();
    } catch (err) {
      console.error('init settings failed: ' + JSON.stringify(err));
    }
  }

  /** 写入一个字段并刷新界面 */
  private apply(patch: SettingsPatch): void {
    const s: AppSettings | undefined = this.store;
    if (s === undefined) {
      showToast('设置存储不可用');
      return;
    }
    s.update(patch);
    this.data = s.get();
  }

  /** 在若干档位之间循环切换 */
  private cycle(cur: number, max: number): number {
    return cur >= max ? 0 : cur + 1;
  }

  /** 一行开关 */
  @Builder
  SwitchRow(title: string, desc: string, value: boolean, onToggle: (v: boolean) => void) {
    Row() {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontColor(Theme.TEXT_MAIN)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(desc)
          .fontSize(11)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(Theme.ACCENT)
        .margin(0)
        .onChange((isOn: boolean) => {
          onToggle(isOn);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10 })
  }

  /** 一行"点一下换一个档位" */
  @Builder
  ChoiceRow(title: string, desc: string, valueText: string, onTap: () => void) {
    Row() {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(14)
          .fontColor(Theme.TEXT_MAIN)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(desc)
          .fontSize(11)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // ★ 只有这个值标签可点，整行不响应点击。
      //   为什么（2026-10-03 实测踩到的）：整行可点时，任何落在这一行的
      //   误触都会**直接改掉设置**。我自己测试时就因为想点别处而误触了
      //   「解码方式」这一行，把"优先内置软解"循环回了"自动"，
      //   而且当时毫无察觉 —— 设置页不该有这种"看不出被改了"的交互。
      //   值标签本身有明显底色，看上去就是可点的，指向性也更清楚。
      Text(valueText)
        .fontSize(13)
        .fontColor(Theme.ACCENT)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .backgroundColor('rgba(0,125,255,0.10)')
        .borderRadius(10)
        .onClick(() => {
          onTap();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 12, bottom: 12 })
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

        Text('播放设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT_MAIN)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ right: Theme.PAGE_PADDING, top: 20, bottom: 16 })

      // ================= 内容区 =================
      Column() {
        // ---- 解码方式 ----
        Column() {
          this.ChoiceRow('解码方式',
            '优先内置软解时，所有格式都先走软解（字幕与音轨控制最完整，但更耗电）；'
              + '自动则按格式表决定',
            this.decodeText(), () => {
              this.apply({ decodePreference: this.cycle(this.data.decodePreference, 1) });
            })
        }
        .padding({ left: 14, right: 14, top: 2, bottom: 2 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 14 })

        // ---- 回退策略 ----
        Column() {
          this.SwitchRow('系统解码失败时自动回退软解',
            '系统播放器报「不支持该格式」或长时间没有画面时，自动改用内置软解重试',
            this.data.autoFallbackSoft, (v: boolean) => {
              this.apply({ autoFallbackSoft: v });
            })
        }
        .padding({ left: 14, right: 14, top: 2, bottom: 2 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 14 })

        // ---- 续播 ----
        Column() {
          this.SwitchRow('记住播放进度',
            '关掉后不再写入观看历史，首页的「继续观看」也不会再有新记录',
            this.data.rememberProgress, (v: boolean) => {
              this.apply({ rememberProgress: v });
            })
        }
        .padding({ left: 14, right: 14, top: 2, bottom: 2 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 14 })

        // ---- 旋转 ----
        Column() {
          this.SwitchRow('允许跟随设备旋转',
            '关掉后播放页固定竖屏，仍可用右上角的按钮手动全屏',
            this.data.allowAutoRotate, (v: boolean) => {
              this.apply({ allowAutoRotate: v });
            })
        }
        .padding({ left: 14, right: 14, top: 2, bottom: 2 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 14 })

        // ---- 说明 ----
        Text('以上设置立即生效，下次播放时也会沿用。')
          .fontSize(11)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 4 })

        // ---- 恢复默认（播放 + 字幕一起复位）----
        //
        // 为什么放在这里：设置项一多，"我到底改过哪些"就说不清了，
        // 没有一键复位时用户只能靠记忆把每一项拨回去。
        // 复位范围是**全部**设置（播放 + 字幕），所以文案里写清楚，
        // 避免用户以为只重置当前这一页。
        Column() {
          Text('恢复默认设置（播放与字幕全部复位）')
            .fontSize(14)
            .fontColor('#FF3B30')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              const s: AppSettings | undefined = this.store;
              if (s === undefined) {
                showToast('设置存储不可用');
                return;
              }
              s.resetToDefault();
              this.data = s.get();
              showToast('已恢复默认设置');
            })
        }
        .width('100%')
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ top: 6, bottom: 14 })
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

  /** 解码方式当前值的显示文字 */
  private decodeText(): string {
    return this.data.decodePreference === DecodePreference.PREFER_SOFT
      ? '优先内置软解' : '自动（按格式）';
  }
}
