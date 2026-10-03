/**
 * 应用设置（播放 / 字幕）
 *
 * 为什么单独做一个模块：
 *   设置项被两个页面（设置页的两个子页）写、被播放页读，中间隔着页面跳转。
 *   如果各自把值塞在 @State 里，跳一次页面就丢；如果塞在 AppStorage 里，
 *   又要自己处理"没有默认值/类型不对"的情况。这里统一成"一个 JSON 文件 + 内存缓存"，
 *   与工程里 WatchHistory / NetworkStreamStore 的做法一致，行为完全可预期。
 *
 * 存储方式：沙箱 files 目录下一个 JSON 文件，里面是**只有一个元素的数组**。
 *   为什么套一层数组：工程里的原子写/安全读工具（JsonStore）就是按
 *   "JSON 数组"这个约定写的（它有短写保护、损坏留档、逐元素类型过滤），
 *   为了复用这些已经验证过的行为，这里不去另写一套对象读写。
 *
 * 为什么不用 Preferences：见 WatchHistory 里的说明（部分环境下 flush 不落盘）。
 */

import { common } from '@kit.AbilityKit';
import { readJsonArraySafe, writeJsonArrayAtomic, AtomicWriteResult } from './JsonStore';

/** 设置文件名（存在应用沙箱 files 目录） */
const FILE_NAME: string = 'app_settings.json';

/** 解码方式偏好 */
export enum DecodePreference {
  /** 自动：按格式表决定（系统硬解优先，系统不认的后缀直接软解） */
  AUTO = 0,
  /** 优先内置软解：所有格式都先用内置软解，失败再回退系统 */
  PREFER_SOFT = 1
}

/** 默认字幕语言 */
export enum SubtitleLanguage {
  /** 自动：跟随容器标记的默认轨 */
  AUTO = 0,
  CHINESE = 1,
  ENGLISH = 2,
  /** 不自动启用字幕 */
  OFF = 3
}

/** 字幕字号 */
export enum SubtitleFontSize {
  SMALL = 0,
  NORMAL = 1,
  LARGE = 2
}

/** 落盘的数据结构（字段全部是原始类型，便于校验） */
export interface SettingsData {
  /** 解码方式偏好，见 DecodePreference */
  decodePreference: number;
  /** 系统解码失败/无画面时是否自动回退软解 */
  autoFallbackSoft: boolean;
  /** 是否记录播放进度（关掉后不再写观看历史，也就没有续播） */
  rememberProgress: boolean;
  /** 播放页是否允许跟随设备旋转 */
  allowAutoRotate: boolean;
  /** 默认字幕语言，见 SubtitleLanguage */
  subtitleLanguage: number;
  /** 外挂字幕是否优先于内嵌字幕 */
  preferExternalSubtitle: boolean;
  /** 是否自动加载同目录的同名外挂字幕 */
  autoLoadSidecar: boolean;
  /** 字幕字号，见 SubtitleFontSize */
  subtitleFontSize: number;
  /** 字幕是否加半透明底衬 */
  subtitleBackground: boolean;
}

/** 默认值（首次使用、字段缺失、类型不对时都用它） */
export function defaultSettings(): SettingsData {
  return {
    decodePreference: DecodePreference.AUTO,
    autoFallbackSoft: true,
    rememberProgress: true,
    allowAutoRotate: true,
    subtitleLanguage: SubtitleLanguage.AUTO,
    preferExternalSubtitle: true,
    autoLoadSidecar: false,
    subtitleFontSize: SubtitleFontSize.NORMAL,
    subtitleBackground: true
  };
}

/**
 * 局部更新用的补丁
 *
 * 为什么不直接用 Partial<SettingsData> 或 Record<string, Object>：
 *   ArkTS 严格模式（arkts-no-untyped-obj-literals）要求对象字面量必须对应
 *   一个**显式声明的**类或接口，映射类型 / Record 都不行 —— 编译直接报错
 *   "Object literal must correspond to some explicitly declared class or interface"。
 *   所以这里老老实实写一个全字段可选的接口。
 */
export interface SettingsPatch {
  decodePreference?: number;
  autoFallbackSoft?: boolean;
  rememberProgress?: boolean;
  allowAutoRotate?: boolean;
  subtitleLanguage?: number;
  preferExternalSubtitle?: boolean;
  autoLoadSidecar?: boolean;
  subtitleFontSize?: number;
  subtitleBackground?: boolean;
}

/**
 * 字幕字号对应的像素值
 *
 * 为什么用固定档位而不是让用户拖一个任意值：
 *   字号要和视频画面高度匹配才有意义，而画面高度横竖屏各不相同；
 *   三档足够覆盖"看不清"和"太大挡画面"两端，也不会出现滑到 8px 这种没用的值。
 */
const FONT_PX: number[] = [15, 18, 24];

/** 取字幕字号的像素值（越界一律回落到标准档） */
export function subtitleFontPx(size: number): number {
  if (size < 0 || size >= FONT_PX.length) {
    return FONT_PX[SubtitleFontSize.NORMAL];
  }
  return FONT_PX[size];
}

/** 各档位的中文名（设置页右侧显示） */
export function decodePreferenceName(v: number): string {
  return v === DecodePreference.PREFER_SOFT ? '优先内置软解' : '自动（按格式）';
}

export function subtitleLanguageName(v: number): string {
  if (v === SubtitleLanguage.CHINESE) {
    return '中文优先';
  }
  if (v === SubtitleLanguage.ENGLISH) {
    return '英文优先';
  }
  if (v === SubtitleLanguage.OFF) {
    return '不自动启用';
  }
  return '跟随文件默认';
}

export function subtitleFontSizeName(v: number): string {
  if (v === SubtitleFontSize.SMALL) {
    return '小';
  }
  if (v === SubtitleFontSize.LARGE) {
    return '大';
  }
  return '标准';
}

/**
 * 判断一条字幕轨的语言标签是否匹配目标语言
 *
 * 为什么要做这个匹配：容器里的语言标签格式五花八门（ISO639-2 的 chi/zho、
 * 639-1 的 zh、带地区的 zh-CN、以及 "Chinese"/"简体" 这类人写的标题）。
 * 只按一种写法定死必然漏，所以这里对常见写法做一个包含式匹配。
 *
 * @param language 轨道语言标签（可能是空串）
 * @param title 轨道标题（很多压制组把语言写在标题里）
 * @param want 目标语言
 */
export function trackMatchesLanguage(language: string, title: string, want: number): boolean {
  if (want !== SubtitleLanguage.CHINESE && want !== SubtitleLanguage.ENGLISH) {
    return false;
  }
  const l: string = (language + ' ' + title).toLowerCase();
  if (want === SubtitleLanguage.CHINESE) {
    return l.indexOf('chi') >= 0 || l.indexOf('zho') >= 0 || l.indexOf('zh') >= 0
      || l.indexOf('中文') >= 0 || l.indexOf('简体') >= 0 || l.indexOf('繁體') >= 0
      || l.indexOf('繁体') >= 0 || l.indexOf('chs') >= 0 || l.indexOf('cht') >= 0;
  }
  return l.indexOf('eng') >= 0 || l.indexOf('en') >= 0 || l.indexOf('english') >= 0
    || l.indexOf('英文') >= 0 || l.indexOf('英语') >= 0;
}

/**
 * 应用设置仓库
 *
 * 读写都在内存缓存上，只有 set 才落盘；落盘用原子写（先 .tmp 再 rename），
 * 避免"写一半崩了 → 设置全丢"。
 */
export class AppSettings {
  private filePath: string;
  private cache: SettingsData | undefined = undefined;
  /** 最近一次落盘结果，供诊断页查看 */
  private lastPersistResult: string = '(尚未写入)';

  constructor(context: common.Context) {
    this.filePath = context.filesDir + '/' + FILE_NAME;
  }

  getFilePath(): string {
    return this.filePath;
  }

  getLastPersistResult(): string {
    return this.lastPersistResult;
  }

  /** 取当前设置（首次访问从磁盘加载） */
  get(): SettingsData {
    const cached: SettingsData | undefined = this.cache;
    if (cached !== undefined) {
      return cached;
    }
    const loaded: SettingsData = this.load();
    this.cache = loaded;
    return loaded;
  }

  /** 就地更新若干字段并落盘 */
  update(patch: SettingsPatch): void {
    const cur: SettingsData = this.get();
    const next: SettingsData = {
      decodePreference: pickNumber(patch.decodePreference, cur.decodePreference, 0, 1),
      autoFallbackSoft: pickBool(patch.autoFallbackSoft, cur.autoFallbackSoft),
      rememberProgress: pickBool(patch.rememberProgress, cur.rememberProgress),
      allowAutoRotate: pickBool(patch.allowAutoRotate, cur.allowAutoRotate),
      subtitleLanguage: pickNumber(patch.subtitleLanguage, cur.subtitleLanguage, 0, 3),
      preferExternalSubtitle: pickBool(patch.preferExternalSubtitle, cur.preferExternalSubtitle),
      autoLoadSidecar: pickBool(patch.autoLoadSidecar, cur.autoLoadSidecar),
      subtitleFontSize: pickNumber(patch.subtitleFontSize, cur.subtitleFontSize, 0, 2),
      subtitleBackground: pickBool(patch.subtitleBackground, cur.subtitleBackground)
    };
    this.cache = next;
    this.persist(next);
  }

  /** 恢复默认值 */
  resetToDefault(): void {
    const def: SettingsData = defaultSettings();
    this.cache = def;
    this.persist(def);
  }

  /** 从磁盘加载并逐字段校验 */
  private load(): SettingsData {
    const def: SettingsData = defaultSettings();
    const raw: Object[] = readJsonArraySafe(this.filePath);
    if (raw.length === 0) {
      return def;
    }
    const r = raw[0] as SettingsData;
    // 逐字段校验：文件可能来自旧版本（缺字段）或被人手改过（类型不对）。
    // 任何一个字段不对就单独回落到默认值，而不是整份设置作废。
    return {
      decodePreference: pickNumber(r.decodePreference, def.decodePreference, 0, 1),
      autoFallbackSoft: pickBool(r.autoFallbackSoft, def.autoFallbackSoft),
      rememberProgress: pickBool(r.rememberProgress, def.rememberProgress),
      allowAutoRotate: pickBool(r.allowAutoRotate, def.allowAutoRotate),
      subtitleLanguage: pickNumber(r.subtitleLanguage, def.subtitleLanguage, 0, 3),
      preferExternalSubtitle: pickBool(r.preferExternalSubtitle, def.preferExternalSubtitle),
      autoLoadSidecar: pickBool(r.autoLoadSidecar, def.autoLoadSidecar),
      subtitleFontSize: pickNumber(r.subtitleFontSize, def.subtitleFontSize, 0, 2),
      subtitleBackground: pickBool(r.subtitleBackground, def.subtitleBackground)
    };
  }

  /** 原子写盘 */
  private persist(data: SettingsData): void {
    const r: AtomicWriteResult = writeJsonArrayAtomic(this.filePath, [data]);
    if (!r.ok) {
      this.lastPersistResult = 'error ' + r.error;
      console.error('persist settings failed: ' + r.error);
      return;
    }
    this.lastPersistResult = 'ok ' + r.written.toString() + '/' + r.expected.toString();
  }
}

/** 取数字：类型不对或越界时用兜底值 */
function pickNumber(v: number | undefined, fallback: number, lo: number, hi: number): number {
  if (v === undefined || typeof v !== 'number' || !Number.isFinite(v)) {
    return fallback;
  }
  if (v < lo || v > hi) {
    return fallback;
  }
  return Math.floor(v);
}

/** 取布尔：类型不对时用兜底值 */
function pickBool(v: boolean | undefined, fallback: boolean): boolean {
  if (v === undefined || typeof v !== 'boolean') {
    return fallback;
  }
  return v;
}

/**
 * 模块级单例
 *
 * 为什么需要单例：播放页与两个设置子页都要读写同一份设置，
 * 各自 new 一个的话，A 改了 B 的内存缓存还是旧值（要等下次冷启动才对）。
 * 这里做成进程内单例，任何一页改完，其它页 get() 立刻拿到新值。
 */
let instance: AppSettings | undefined = undefined;

/**
 * 取设置单例（首次调用时用上下文创建）
 * @param context Ability 上下文（页面上用 getUIContext().getHostContext() 取）
 */
export function appSettings(context: common.Context): AppSettings {
  if (instance === undefined) {
    instance = new AppSettings(context);
  }
  return instance;
}

/** 取已经创建好的单例；尚未创建时返回 undefined */
export function peekAppSettings(): AppSettings | undefined {
  return instance;
}
