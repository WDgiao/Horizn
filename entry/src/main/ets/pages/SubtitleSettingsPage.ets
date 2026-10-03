import { Theme } from '../common/Theme';
import { showToast, initToast } from '../common/Toast';
import { common } from '@kit.AbilityKit';
import {
  appSettings, AppSettings, SettingsData, SubtitleLanguage, SubtitleFontSize,
  subtitleLanguageName, subtitleFontSizeName, SettingsPatch
} from '../model/AppSettings';

/**
 * 字幕设置页
 *
 * 每一项都真的有实现（对应关系写在下面，方便日后核对）：
 *   · 默认字幕语言   → PlayerPage.applySubtitlePreference（Prepare 就绪后自动选轨）
 *   · 外挂优先        → PlayerPage.refreshSubtitle 的来源优先级
 *   · 自动加载外挂    → PlayerPage.autoLoadSidecarSubtitle
 *   · 字号 / 底衬     → 播放页字幕层的渲染样式
 */

@Entry
@Component
struct SubtitleSettingsPage {
  @State data: SettingsData = {
    decodePreference: 0,
    autoFallbackSoft: true,
    rememberProgress: true,
    allowAutoRotate: true,
    subtitleLanguage: SubtitleLanguage.AUTO,
    preferExternalSubtitle: true,
    autoLoadSidecar: false,
    subtitleFontSize: SubtitleFontSize.NORMAL,
    subtitleBackground: true,
    // 色调 / 均衡器在播放页的抽屉里调，这里只是把字段补全（ArkTS 要求字面量覆盖全部属性）
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

  private apply(patch: SettingsPatch): void {
    const s: AppSettings | undefined = this.store;
    if (s === undefined) {
      showToast('设置存储不可用');
      return;
    }
    s.update(patch);
    this.data = s.get();
  }

  private cycle(cur: number, max: number): number {
    return cur >= max ? 0 : cur + 1;
  }

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

        Text('字幕设置')
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
        // ---- 默认字幕语言 ----
        Column() {
          this.ChoiceRow('默认字幕语言',
            '播放时自动挑一条匹配的内嵌字幕轨；「跟随文件默认」用容器标记的默认轨，'
              + '「不自动启用」则不碰字幕开关',
            subtitleLanguageName(this.data.subtitleLanguage), () => {
              this.apply({ subtitleLanguage: this.cycle(this.data.subtitleLanguage, 3) });
            })
        }
        .padding({ left: 14, right: 14, top: 2, bottom: 2 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 14 })

        // ---- 来源优先级 ----
        Column() {
          this.SwitchRow('外挂字幕优先于内嵌',
            '两者同时存在时显示外挂字幕。关掉则以内嵌字幕为准（外挂仍可手动选择）',
            this.data.preferExternalSubtitle, (v: boolean) => {
              this.apply({ preferExternalSubtitle: v });
            })

          Divider().color('rgba(0,0,0,0.06)')

          this.SwitchRow('自动加载同目录外挂字幕',
            '播放时自动加载与视频同名的 .srt / .ass 等字幕文件（不会覆盖你手动选过的字幕）',
            this.data.autoLoadSidecar, (v: boolean) => {
              this.apply({ autoLoadSidecar: v });
            })
        }
        .padding({ left: 14, right: 14, top: 2, bottom: 2 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 14 })

        // ---- 样式 ----
        Column() {
          this.ChoiceRow('字幕字号', '字幕文字大小（三档）',
            subtitleFontSizeName(this.data.subtitleFontSize), () => {
              this.apply({ subtitleFontSize: this.cycle(this.data.subtitleFontSize, 2) });
            })

          Divider().color('rgba(0,0,0,0.06)')

          this.SwitchRow('字幕底衬', '字幕下加半透明底色，亮画面上更易读',
            this.data.subtitleBackground, (v: boolean) => {
              this.apply({ subtitleBackground: v });
            })
        }
        .padding({ left: 14, right: 14, top: 2, bottom: 2 })
        .backgroundColor(Theme.CARD_BG)
        .borderRadius(14)
        .margin({ bottom: 14 })

        Text('设置立即生效（正在播放的窗口会在下一帧刷新时套用新样式）。')
          .fontSize(11)
          .fontColor(Theme.TEXT_SUB)
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 4 })

        // ---- 恢复默认（播放 + 字幕一起复位）----
        //   与「播放设置」页同一个动作：复位范围是全部设置，
        //   文案里写清楚，避免用户以为只重置当前这一页。
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
}
