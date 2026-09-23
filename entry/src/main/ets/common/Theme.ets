/**
 * 浅色主题设计变量
 * 与 HTML 版本 :root 中的 CSS 变量一一对应
 */
export class Theme {
  /** --bg-color 鸿蒙经典浅灰背景 */
  static readonly BG: string = '#F2F2F7';
  /** --card-bg 卡片纯白 */
  static readonly CARD_BG: string = '#FFFFFF';
  /** --accent 强调色 */
  static readonly ACCENT: string = '#007DFF';
  /** --text-main 主文字深黑 */
  static readonly TEXT_MAIN: string = '#1C1C1E';
  /** --text-sub 副文字灰色 */
  static readonly TEXT_SUB: string = '#8E8E93';
  /** 卡片图片未加载时的底色 */
  static readonly THUMB_PLACEHOLDER: string = '#E5E5EA';

  /** 页面左右留白 24vp */
  static readonly PAGE_PADDING: number = 24;
  /** 卡片宽度 160vp */
  static readonly CARD_WIDTH: number = 160;
  /** 封面高度 90vp (16:9) */
  static readonly CARD_HEIGHT: number = 90;
  /** 卡片间距 16vp */
  static readonly CARD_GAP: number = 16;
  /** 大圆角 20vp */
  static readonly RADIUS_LARGE: number = 20;
  /** 中圆角 12vp */
  static readonly RADIUS_MEDIUM: number = 12;
}
