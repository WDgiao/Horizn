/**
 * Toast 轻提示
 * 对应 HTML 中的 .toast：固定在底部 100vp 居中、深色半透明胶囊
 * HTML 版用 JS 定时器控制显隐，这里改为声明式显隐 + 由父组件延时关闭
 */
@Component
export struct ToastView {
  /** 提示文本，空字符串表示隐藏 */
  @Prop text: string;

  build() {
    Text(this.text)
      .fontSize(14)
      .fontColor(Color.White)
      .padding({ left: 20, right: 20, top: 10, bottom: 10 })
      .backgroundColor('rgba(0,0,0,0.80)')
      .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
      .borderRadius(20)
      .opacity(this.text.length > 0 ? 1.0 : 0.0)
      .animation({ duration: 300, curve: Curve.EaseInOut })
      .visibility(this.text.length > 0 ? Visibility.Visible : Visibility.None)
  }
}

/** Toast 胶囊距屏幕底部的距离 */
export const TOAST_BOTTOM_OFFSET: number = 100;
