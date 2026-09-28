/**
 * 媒体库数据层
 *
 * 首页的「最近播放 / 继续观看 / 我的文件夹」三类内容现在都由真实数据驱动：
 *   - 视频来自 model/WatchHistory（观看记录）
 *   - 文件夹来自 model/FolderRepository（应用沙箱 files 目录下的真实目录）
 * 因此这里只保留「数据结构定义」与「底部导航配置」等纯静态内容。
 *
 * ★ 2026-09-29 自检修正：上一句原先写的是「观看记录持久化在 Preferences」，
 *   这是早期用 @ohos.data.preferences 时的说法。后来为了能原子写、能校验、
 *   损坏可留档，已经改成沙箱内 JSON 文件（见 model/JsonStore.ets），
 *   但注释没跟着改 —— 照着它去 Preferences 里找记录只会一无所获。
 */

/** 视频卡片数据 */
export interface VideoItem {
  /** 影片名称 */
  title: string;
  /** 时长文本，例如 03:00:00 */
  duration: string;
  /** 规格与体积等副标题 */
  subtitle: string;
  /** 封面图地址；真实播放记录没有封面，用空串走渐变兜底 */
  cover: string;
  /** 封面加载失败时的回退渐变色 */
  fallbackColors: [string, string];
  /**
   * 视频绝对路径
   * 有值时点击卡片直接进入播放页；为空则跳到搜索页让用户选择文件
   */
  path: string;
  /** 播放进度 0 ~ 1；接续播放的记录会带上，卡片底部显示一条进度线 */
  progress: number;
  /**
   * 视频内置封面的图片文件路径
   * 用文件路径而不是 PixelMap：PixelMap 是原生对象，
   * 经 @Prop 值拷贝后句柄可能失效导致画不出来；字符串没有这类问题。
   * 空串表示尚未提取或提取失败，卡片会退回渐变色兜底。
   */
  thumbPath: string;
}

/** 文件夹卡片数据 */
export interface FolderItem {
  /** 文件夹名称 */
  title: string;
  /** 数量描述，例如 24 个视频 */
  subtitle: string;
  /** 文件夹绝对路径，空串表示为占位项 */
  path: string;
}

/** 焦点推荐位数据 */
export interface HeroItem {
  /** 推荐标题 */
  title: string;
  /** 左上角标签，例如 继续观看 */
  tag: string;
  /** 画质与状态描述 */
  meta: string;
  /** 剩余时长描述 */
  remain: string;
  /** 播放进度，取值 0 ~ 1 */
  progress: number;
  /** 背景图地址 */
  cover: string;
  /** 视频绝对路径，有值时点击直接续播 */
  path: string;
  /**
   * 视频内置封面的图片文件路径
   * 用文件路径而不是 PixelMap：PixelMap 是原生对象，
   * 经 @Prop 值拷贝后句柄可能失效导致画不出来；字符串没有这类问题。
   * 空串表示尚未提取或提取失败，焦点位会退回渐变色兜底。
   */
  thumbPath: string;
  /**
   * 该记录是否已看完
   * true 时焦点位展示为「重新观看」而不是「继续观看」
   */
  finished: boolean;
}

/** 首页焦点推荐位的默认内容（尚无观看记录时显示） */
export const HERO_EMPTY: HeroItem = {
  title: '还没有观看记录',
  tag: '开始探索',
  meta: '点击搜索',
  remain: '挑一个视频开始播放吧',
  progress: 0,
  cover: '',
  path: '',
  finished: false,
  thumbPath: ''
};

/** 底部悬浮导航项 */
export interface NavItem {
  /** 导航图标（Emoji 字符，无需额外图标资源） */
  icon: string;
  /** 无障碍标题 */
  title: string;
}

/** 底部导航配置：首页 / 搜索 / 添加 / 设置 */
export const NAV_ITEMS: NavItem[] = [
  { icon: '🏠', title: '首页' },
  { icon: '🔍', title: '搜索' },
  { icon: '➕', title: '添加' },
  { icon: '⚙️', title: '设置' }
];

/** 文件夹图标 */
export const FOLDER_ICON: string = '📁';

/** 新建文件夹按钮图标 */
export const NEW_FOLDER_ICON: string = '➕';

/**
 * 把毫秒格式化成 mm:ss 或 hh:mm:ss
 * 首页与播放页共用，避免两处各写一份
 * @param ms 毫秒
 */
export function formatDuration(ms: number): string {
  if (ms <= 0) {
    return '00:00';
  }
  const total: number = Math.floor(ms / 1000);
  const h: number = Math.floor(total / 3600);
  const m: number = Math.floor((total % 3600) / 60);
  const s: number = total % 60;
  const mm: string = m < 10 ? '0' + m.toString() : m.toString();
  const ss: string = s < 10 ? '0' + s.toString() : s.toString();
  if (h > 0) {
    const hh: string = h < 10 ? '0' + h.toString() : h.toString();
    return hh + ':' + mm + ':' + ss;
  }
  return mm + ':' + ss;
}
