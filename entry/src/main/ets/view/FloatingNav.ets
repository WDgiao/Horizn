import { Theme } from '../common/Theme';
import { NavItem } from '../common/MediaData';

/**
 * 底部悬浮导航
 * 对应 HTML 中的 .floating-nav：白色半透明毛玻璃胶囊、选中项放大并染成强调色
 */
@Component
export struct FloatingNav {
  /** 当前选中下标 */
  @Link activeIndex: number;
  /** 导航数据 */
  @Prop items: NavItem[];
  /** 点击回调，对应 HTML 中的 onclick="showToast(...)" */
  onSelect?: (index: number, title: string) => void;

  build() {
    Row({ space: 28 }) {
      ForEach(this.items, (item: NavItem, index: number) => {
        Text(item.icon)
          .fontSize(20)
          .padding(4)
          .opacity(this.activeIndex === index ? 1.0 : 0.4)
          .fontColor(this.activeIndex === index ? Theme.ACCENT : Theme.TEXT_MAIN)
          .scale({ x: this.activeIndex === index ? 1.1 : 1.0, y: this.activeIndex === index ? 1.1 : 1.0 })
          .accessibilityText(item.title)
          .onClick(() => {
            this.activeIndex = index;
            this.onSelect?.(index, item.title);
          })
      }, (item: NavItem) => item.title)
    }
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .borderRadius(30)
    // 浅色模式毛玻璃：白色半透明背景
    .backgroundColor('rgba(255,255,255,0.85)')
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
    .border({ width: 1, color: 'rgba(0,0,0,0.05)' })
    .shadow({
      radius: 30,
      color: 'rgba(0,0,0,0.10)',
      offsetX: 0,
      offsetY: 10
    })
  }
}
