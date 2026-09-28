/**
 * 外挂字幕的加载与管理
 *
 * 三种来源：
 *   ① 同目录同名 —— 视频 xxx.mkv 旁边的 xxx.srt / xxx.ass / xxx.chi.srt …
 *      这是最常见的情况，播放时自动发现，用户不用做任何操作。
 *   ② 手动选文件 —— 通过系统文件选择器挑任意 .srt/.ass/.vtt
 *   ③ 同目录但不同名 —— 例如视频叫 movie.mkv、字幕叫 movie.chs.srt，
 *      靠前缀匹配也能自动找到，列出来让用户选
 *
 * 为什么不把外挂字幕交给原生层统一处理：
 *   外挂字幕是纯文本，用 ArkTS 字符串处理就够了；交给原生反而要
 *   跨 napi 边界传大块文本、还要在原生侧再实现一遍编码探测。
 *   所以分工是：**内嵌字幕走原生，外挂字幕走 ArkTS**。
 */

import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  SubtitleCue, SubtitleLoadResult, decodeSubtitleBytes, parseSubtitleText, findActiveCueIndex
} from './SubtitleParser';

/** 支持的外挂字幕扩展名（小写，不含点） */
export const SUBTITLE_EXTENSIONS: string[] = ['srt', 'ass', 'ssa', 'vtt', 'sub'];

/** 一个候选字幕文件 */
export interface SubtitleCandidate {
  /** 沙箱内的绝对路径 */
  path: string;
  /** 文件名 */
  name: string;
  /** 是否与视频同名（同名的最可能是用户想要的那条） */
  sameName: boolean;
}

/**
 * 当前生效的外挂字幕
 *
 * 界面只需要两个动作：加载它、按时间问"现在显示什么"。
 */
export class ExternalSubtitle {
  /** 已解析的字幕（按 startMs 升序） */
  cues: SubtitleCue[] = [];
  /** 来源路径，空串表示没有外挂字幕 */
  path: string = '';
  /** 显示名（文件名） */
  name: string = '';
  /** 用户设定的时间偏移（毫秒）—— 字幕与画面不同步时手动校正用 */
  offsetMs: number = 0;

  /** 是否已加载 */
  get loaded(): boolean {
    return this.cues.length > 0;
  }

  /**
   * 取当前该显示的字幕文本
   * @param nowMs 播放位置（毫秒）
   * @return 文本；空串表示这一刻没有字幕
   */
  textAt(nowMs: number): string {
    if (this.cues.length === 0) {
      return '';
    }
    // 应用偏移：offsetMs > 0 表示"字幕整体延后显示"
    const idx: number = findActiveCueIndex(this.cues, nowMs - this.offsetMs);
    return idx >= 0 ? this.cues[idx].text : '';
  }

  /** 清空 */
  clear(): void {
    this.cues = [];
    this.path = '';
    this.name = '';
    this.offsetMs = 0;
  }
}

/** 从路径里取文件名（含扩展名） */
function baseName(path: string): string {
  const slash: number = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/** 去掉扩展名 */
function stripExtension(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot < 0 ? name : name.substring(0, dot);
}

/** 取小写扩展名 */
function extensionOf(name: string): string {
  const dot: number = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/**
 * 读取一个文件并解析成字幕
 *
 * 编码探测与格式解析都在 SubtitleParser 里，这里只负责 I/O。
 */
export async function loadSubtitleFile(path: string): Promise<SubtitleLoadResult> {
  const result: SubtitleLoadResult = { count: 0, error: '', encoding: '' };
  let file: fileIo.File | undefined = undefined;
  try {
    const stat: fileIo.Stat = fileIo.statSync(path);
    // 大小上限：字幕文件正常不会超过几 MB。设上限是因为
    // 用户可能误选一个大视频文件，一次性读进内存会直接 OOM。
    if (stat.size > 8 * 1024 * 1024) {
      result.error = '文件过大（' + Math.round(stat.size / 1024 / 1024).toString()
        + ' MB），看起来不是字幕文件';
      return result;
    }
    file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const buf: ArrayBuffer = new ArrayBuffer(stat.size);
    const read: number = fileIo.readSync(file.fd, buf, { offset: 0, length: stat.size });
    const bytes: Uint8Array = new Uint8Array(buf, 0, read);
    const text: string = decodeSubtitleBytes(bytes);
    const cues: SubtitleCue[] = parseSubtitleText(text, baseName(path));
    if (cues.length === 0) {
      result.error = '没能从文件里解析出字幕内容';
      return result;
    }
    // 缓存到模块级，供 getExternalCue 使用
    current.cues = cues;
    current.path = path;
    current.name = baseName(path);
    result.count = cues.length;
    return result;
  } catch (err) {
    const e = err as BusinessError;
    result.error = '读取字幕失败：' + (e.message !== undefined ? e.message : '未知错误');
    return result;
  } finally {
    if (file !== undefined) {
      try {
        fileIo.closeSync(file);
      } catch (err) {
        // 关闭失败无需上报
      }
    }
  }
}

/**
 * 模块级的"当前外挂字幕"
 *
 * 为什么用模块级单例而不是让调用方持有对象：
 *   播放页可能被反复创建销毁（返回再进入），而"用户选了哪个字幕文件"
 *   这个意图应当跨页面保留 —— 否则每次进播放页都要重选一次。
 *   放在模块级就自然实现了"记住上次的选择"。
 */
export const current: ExternalSubtitle = new ExternalSubtitle();

/**
 * 外挂字幕是否处于"启用"状态
 *
 * 为什么要单独一个标志而不是看 cues 是否非空：
 *   用户点了"关闭外挂字幕"时，cues 会被清空；但"当前有没有选中"这件事
 *   与"解析结果还在不在"是两回事。界面上的按钮文案（字幕 / 字幕·外挂）
 *   依赖的是"选中状态"，所以必须有独立标志。
 *
 * 注意：这个状态必须由调用方在设置/取消字幕时同步维护
 * （见 SubtitleUiState.setExternal / clearExternal）。
 */
let externalActive: boolean = false;

/** 读取外挂字幕启用状态 */
export function isExternalActive(): boolean {
  return externalActive;
}

/**
 * 设置外挂字幕启用状态
 *
 * 为什么要做成函数而不是导出可变变量：
 *   ES 模块导出的 `let` 在导入侧是只读绑定，`import { externalActive }`
 *   之后赋值会报错。用 setter 是最稳妥的形式。
 *
 * @param active true 表示外挂字幕生效
 */
export function setExternalActive(active: boolean): void {
  externalActive = active;
}

/**
 * 重新加载"上次选中的外挂字幕"
 *
 * 用途：播放页每次 aboutToAppear 都调一次。这样"返回搜索页再进来"时，
 * 之前选的外挂字幕会自动恢复 —— 否则用户每进出一次都要重选一遍，
 * 而外挂字幕的选择本来就是"针对这个视频"的长期意图。
 *
 * @return 恢复成功返回条数；没有可恢复的返回 0
 */
export async function restoreExternalSubtitle(): Promise<number> {
  if (current.path.length === 0) {
    return 0;
  }
  const res: SubtitleLoadResult = await loadSubtitleFile(current.path);
  if (res.error.length > 0) {
    // 文件可能被删了：清掉状态，避免每次都白试一遍
    console.info('[Subtitle] 恢复外挂字幕失败: ' + res.error);
    current.clear();
    externalActive = false;
    return 0;
  }
  externalActive = true;
  return res.count;
}

/**
 * 在同一目录里找外挂字幕
 *
 * 策略：
 *   ① 完全同名（video.srt）
 *   ② 同前缀（video.chs.srt / video.chi.ass / video.zh-CN.srt）
 *   两个都收进来，同名的排在前面 —— 同名的几乎肯定是用户想要的那条。
 *
 * @param videoPath 视频文件的绝对路径
 * @return 候选列表（可能为空）
 */
export function findSidecarSubtitles(videoPath: string): SubtitleCandidate[] {
  const out: SubtitleCandidate[] = [];
  const slash: number = videoPath.lastIndexOf('/');
  if (slash < 0) {
    return out;
  }
  const dir: string = videoPath.substring(0, slash);
  const videoName: string = videoPath.substring(slash + 1);
  const videoBase: string = stripExtension(videoName).toLowerCase();

  let names: string[] = [];
  try {
    names = fileIo.listFileSync(dir);
  } catch (err) {
    // 目录读不了（权限/不存在）不是错误，就是没有外挂字幕
    console.info('[Subtitle] 无法列出目录 ' + dir);
    return out;
  }

  for (let i: number = 0; i < names.length; i++) {
    const name: string = names[i];
    const ext: string = extensionOf(name);
    if (SUBTITLE_EXTENSIONS.indexOf(ext) < 0) {
      continue;
    }
    const candidateBase: string = stripExtension(name).toLowerCase();
    let sameName: boolean = false;
    if (candidateBase === videoBase) {
      sameName = true;
    } else if (candidateBase.startsWith(videoBase + '.')
               || candidateBase.startsWith(videoBase + '_')
               || candidateBase.startsWith(videoBase + '-')) {
      // video.chs / video_zh / video-zh-CN
      sameName = false;
    } else {
      continue;   // 前缀完全不搭，不是这个视频的字幕
    }
    out.push({ path: dir + '/' + name, name: name, sameName: sameName });
  }

  // 同名的排前面
  out.sort((a: SubtitleCandidate, b: SubtitleCandidate): number => {
    if (a.sameName === b.sameName) {
      return a.name.localeCompare(b.name);
    }
    return a.sameName ? -1 : 1;
  });
  console.info('[Subtitle] 在 ' + dir + ' 找到 ' + out.length.toString() + ' 个候选字幕');
  return out;
}

/**
 * 弹出系统文件选择器挑一个外挂字幕
 *
 * 注意：选择器返回的是文档 URI，不能直接当路径用。这里先把它
 * 复制进沙箱再解析 —— 因为解析要随机读、还要支持重新加载，
 * 持有 URI 随时可能失效（用户可能在文件管理器里移动/删除原文件）。
 *
 * @param context 应用上下文
 * @param destDir 复制目标目录（一般是应用沙箱 files 目录）
 * @return 加载结果；error 非空表示失败或用户取消
 */
export async function pickSubtitleFile(context: common.UIAbilityContext,
                                       destDir: string): Promise<SubtitleLoadResult> {
  const result: SubtitleLoadResult = { count: 0, error: '', encoding: '' };
  let uris: string[] = [];
  try {
    const documentPicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.srt', '.ass', '.ssa', '.vtt', '.sub'];
    uris = await documentPicker.select(options);
  } catch (err) {
    const e = err as BusinessError;
    result.error = '选择器未返回文件（' + e.code.toString() + '）';
    return result;
  }
  if (uris === undefined || uris === null || uris.length === 0) {
    result.error = '未选择任何文件';
    return result;
  }

  // 复制进沙箱再解析：文档 URI 只保证"当前这次授权内"可用，
  // 而我们需要它长期可读（用户可能反复切换字幕）
  const uri: string = uris[0];
  const targetName: string = 'sub_' + Date.now().toString() + '_' + guessNameFromUri(uri);
  const targetPath: string = destDir + '/' + targetName;
  let src: fileIo.File | undefined = undefined;
  let dst: fileIo.File | undefined = undefined;
  try {
    src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    dst = fileIo.openSync(targetPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    await fileIo.copyFile(src.fd, dst.fd);
  } catch (err) {
    const e = err as BusinessError;
    result.error = '复制字幕文件失败：' + (e.message !== undefined ? e.message : '未知错误');
    return result;
  } finally {
    if (src !== undefined) {
      try { fileIo.closeSync(src); } catch (err) { }
    }
    if (dst !== undefined) {
      try { fileIo.closeSync(dst); } catch (err) { }
    }
  }

  // 复制成功后走普通加载流程（编码探测 + 解析）
  const loadResult: SubtitleLoadResult = await loadSubtitleFile(targetPath);
  // 名字要还原成用户选的那个文件的真名，而不是沙箱里的临时名 ——
  // 界面要显示"xxx.srt"，显示 sub_1234_xxx.srt 会让人困惑
  if (loadResult.error.length === 0) {
    current.name = guessNameFromUri(uri);
  }
  return loadResult;
}

/** 从文档 URI 里猜出文件名（URI 末尾通常是编码过的文件名） */
function guessNameFromUri(uri: string): string {
  const slash: number = uri.lastIndexOf('/');
  let name: string = slash < 0 ? uri : uri.substring(slash + 1);
  if (name.length === 0) {
    name = 'subtitle.srt';
  }
  try {
    name = decodeURIComponent(name);
  } catch (err) {
    // URI 里可能有非法转义，解不开就用原样
  }
  return name;
}
