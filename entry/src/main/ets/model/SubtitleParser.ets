/**
 * 外挂字幕解析（纯 ArkTS，不依赖原生层）
 *
 * 为什么外挂字幕不走 FFmpeg：
 *   外挂字幕（.srt / .ass / .vtt）就是一个独立的文本文件，内容是明文。
 *   "解析"它需要的只是字符串处理 —— 为了这个去走一遍
 *   avformat_open_input + 字幕解码器，既慢又多一层依赖。
 *   而且本构建的 FFmpeg 根本没编字幕解码器（CONFIG_SUBRIP_DECODER=0 等），
 *   真走原生反而要先把 FFmpeg 重编一遍。
 *   所以外挂字幕在这里自己解，内嵌字幕才走原生（那边必须依赖解封装器）。
 *
 * 支持的格式：
 *   .srt / .vtt  —— 标准时间行 "00:00:01,000 --> 00:00:04,000"
 *   .ass / .ssa  —— "Dialogue: 0,0:00:01.00,0:00:04.00,..." 形式
 *   纯文本       —— 没有时间行时回退（整段当一条，避免完全读不出东西）
 *
 * 编码：
 *   中文外挂字幕大量是 GBK/GB18030 编码（尤其是老片源和国内字幕组），
 *   按 UTF-8 硬解会得到一片乱码。所以按 BOM → UTF-8 → GBK 的顺序尝试。
 */

import { util } from '@kit.ArkTS';

/** 解码/解析失败时给界面看的结果 */
export interface SubtitleLoadResult {
  /** 解析出的字幕条数 */
  count: number;
  /** 错误描述，空串表示成功 */
  error: string;
  /** 实际使用的编码名（诊断用） */
  encoding: string;
}

/**
 * 用 util.TextDecoder 支持的编码名尝试解码
 *
 * 为什么把编码判断单独拿出来：这个逻辑在"外挂字幕"和"外部导入的
 * 字幕文件"两处都要用，而且它是整个外挂字幕功能里最容易出错的一环
 * （中文乱码），单独放一处便于后面替换实现。
 */
const ENCODING_CANDIDATES: string[] = ['utf-8', 'gbk', 'gb18030', 'big5'];

/** 判断字节流是否是合法 UTF-8（用于在候选编码里挑一个自洽的） */
function isLikelyUtf8(bytes: Uint8Array): boolean {
  let i: number = 0;
  while (i < bytes.length) {
    const b: number = bytes[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    let extra: number = 0;
    if ((b & 0xE0) === 0xC0) {
      extra = 1;
    } else if ((b & 0xF0) === 0xE0) {
      extra = 2;
    } else if ((b & 0xF8) === 0xF0) {
      extra = 3;
    } else {
      return false;
    }
    if (i + extra >= bytes.length) {
      return false;
    }
    for (let k: number = 1; k <= extra; k++) {
      if ((bytes[i + k] & 0xC0) !== 0x80) {
        return false;
      }
    }
    i += extra + 1;
  }
  return true;
}

/** BOM 检测：返回 {编码, 跳过字节数} */
interface BomInfo {
  encoding: string;
  skip: number;
}

function detectBom(bytes: Uint8Array): BomInfo {
  if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
    return { encoding: 'utf-8', skip: 3 };
  }
  if (bytes.length >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
    return { encoding: 'utf-16le', skip: 2 };
  }
  if (bytes.length >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
    return { encoding: 'utf-16be', skip: 2 };
  }
  return { encoding: '', skip: 0 };
}

/**
 * 把字幕文件的字节解码成字符串
 *
 * ★ 编码判断顺序（这一步决定了中文会不会变成乱码）：
 *   ① BOM          —— 最可靠，有就一定对
 *   ② 合法 UTF-8   —— 用结构校验（不是 try/catch），中文 GBK 几乎必然
 *                     在某个字节上违反 UTF-8 的续字节规则，所以能可靠区分
 *   ③ GBK / GB18030 / BIG5 —— 这几个是中文/繁体字幕的常见编码
 *   ④ 兜底 UTF-8（哪怕有坏字节，也总比什么都不显示强）
 *
 * @param bytes 原始字节
 * @return 解码后的文本
 */
export function decodeSubtitleBytes(bytes: Uint8Array): string {
  const bom: BomInfo = detectBom(bytes);
  const body: Uint8Array = bom.skip > 0 ? bytes.subarray(bom.skip) : bytes;

  const tryDecode = (enc: string): string => {
    try {
      // ignoreBOM=true：BOM 已经手动跳过了，别让解码器再处理一次
      const decoder: util.TextDecoder = new util.TextDecoder(enc, { ignoreBOM: true });
      return decoder.decodeToString(body);
    } catch (err) {
      // 该编码名不被支持时会抛 —— 这是正常的，继续试下一个
      return '';
    }
  };

  if (bom.encoding.length > 0) {
    const s: string = tryDecode(bom.encoding);
    if (s.length > 0) {
      return s;
    }
  }

  // 结构上合法的 UTF-8 就认定是 UTF-8，不再往下试
  // （用结构校验而不是"试解码看有没有乱码"，因为多数解码器遇到坏字节
  //   会替换成 U+FFFD 而不报错，try/catch 根本抓不到）
  if (isLikelyUtf8(body)) {
    const s: string = tryDecode('utf-8');
    if (s.length > 0) {
      return s;
    }
  }

  for (let i: number = 1; i < ENCODING_CANDIDATES.length; i++) {
    const s: string = tryDecode(ENCODING_CANDIDATES[i]);
    // GBK 等编码对任意字节序列几乎都能解出东西，所以这里只能"取第一个成功的"
    if (s.length > 0) {
      return s;
    }
  }

  return tryDecode('utf-8');
}

/** 解析出的一条字幕 */
export interface SubtitleCue {
  startMs: number;
  endMs: number;
  text: string;
}

/**
 * 把 "00:01:23,456" / "0:01:23.45" / "01:23.4" 这类时间串转成毫秒
 *
 * 各格式的写法差异（这就是为什么要写得比较宽容）：
 *   SRT  00:00:01,000   小时:分:秒,毫秒（逗号）
 *   ASS  0:00:01.00     小时:分:秒.厘秒（点，两位）
 *   VTT  00:00:01.000   同 SRT 但用点
 *   有的软件省略小时位，写成 00:01.000
 *
 * @return 毫秒；解析失败返回 -1
 */
export function parseSubtitleTime(raw: string): number {
  const s: string = raw.trim().replace(',', '.');
  if (s.length === 0) {
    return -1;
  }
  const parts: string[] = s.split(':');
  if (parts.length < 2 || parts.length > 3) {
    return -1;
  }

  let hours: number = 0;
  let minutes: number = 0;
  let secPart: string = '';
  if (parts.length === 3) {
    hours = Number.parseInt(parts[0], 10);
    minutes = Number.parseInt(parts[1], 10);
    secPart = parts[2];
  } else {
    minutes = Number.parseInt(parts[0], 10);
    secPart = parts[1];
  }
  if (Number.isNaN(hours) || Number.isNaN(minutes)) {
    return -1;
  }

  const dot: number = secPart.indexOf('.');
  const secStr: string = dot < 0 ? secPart : secPart.substring(0, dot);
  const fracStr: string = dot < 0 ? '' : secPart.substring(dot + 1);
  const seconds: number = Number.parseInt(secStr, 10);
  if (Number.isNaN(seconds)) {
    return -1;
  }

  // 小数部分可能是 2 位（厘秒）或 3 位（毫秒），统一补/截到 3 位
  let millis: number = 0;
  if (fracStr.length > 0) {
    let m: string = fracStr;
    if (m.length > 3) {
      m = m.substring(0, 3);
    }
    while (m.length < 3) {
      m = m + '0';
    }
    millis = Number.parseInt(m, 10);
    if (Number.isNaN(millis)) {
      millis = 0;
    }
  }

  return ((hours * 60 + minutes) * 60 + seconds) * 1000 + millis;
}

/**
 * 清洗字幕文本
 *
 * 与外挂字幕不同，外挂 .srt 里常见 <i> <b> <font color=...> 这些标签，
 * .ass 里是 {\...} 样式覆写。都要去掉，否则会原样显示在屏幕上。
 */
export function cleanSubtitleText(raw: string): string {
  let s: string = raw;
  // ASS 样式覆写 {\an8}{\pos(320,50)}
  s = s.replace(/\{[^}]*\}/g, '');
  // HTML 风格标签
  s = s.replace(/<[^>]{0,32}>/g, '');
  // ASS 的硬换行 \N \n，以及不换行空格 \h
  s = s.replace(/\\N/g, '\n');
  s = s.replace(/\\n/g, '\n');
  s = s.replace(/\\h/g, ' ');
  return s.trim();
}

/**
 * 解析 SRT / WebVTT 文本
 *
 * 两者结构几乎一样，差别只在：
 *   · SRT 每个块前面有序号行，VTT 没有（但有 "WEBVTT" 头）
 *   · 时间分隔符 SRT 常用逗号、VTT 用点（parseSubtitleTime 两者都认）
 * 所以用同一套逻辑处理，靠 "-->" 定位时间行。
 */
function parseArrowFormat(content: string): SubtitleCue[] {
  const out: SubtitleCue[] = [];
  // 统一换行符，后面就能只按 '\n' 切
  const lines: string[] = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

  let i: number = 0;
  while (i < lines.length) {
    const line: string = lines[i];
    const arrow: number = line.indexOf('-->');
    if (arrow < 0) {
      i++;
      continue;
    }
    const startMs: number = parseSubtitleTime(line.substring(0, arrow));
    // 结束时间后面可能跟 VTT 的定位参数（如 "align:middle"），要截掉
    let endRaw: string = line.substring(arrow + 3).trim();
    const spaceIdx: number = endRaw.search(/\s/);
    if (spaceIdx > 0) {
      endRaw = endRaw.substring(0, spaceIdx);
    }
    const endMs: number = parseSubtitleTime(endRaw);
    if (startMs < 0) {
      i++;
      continue;
    }

    // 收集正文：到下一个空行为止（VTT 还可能遇到下一条时间行，也当作结束）
    const bodyLines: string[] = [];
    i++;
    while (i < lines.length && lines[i].trim().length > 0) {
      if (lines[i].indexOf('-->') >= 0) {
        break;   // 没有空行分隔的畸形文件，靠时间行兜底
      }
      bodyLines.push(lines[i]);
      i++;
    }

    const text: string = cleanSubtitleText(bodyLines.join('\n'));
    if (text.length > 0) {
      out.push({
        startMs: startMs,
        // 结束时间缺失或早于开始时间时给一个兜底时长，
        // 否则这条字幕永远不会过期，会一直挂在屏幕上
        endMs: endMs > startMs ? endMs : startMs + 4000,
        text: text
      });
    }
  }
  return out;
}

/**
 * 解析 ASS / SSA 文本
 *
 * 格式要点：
 *   · 文件分 [Script Info] / [V4+ Styles] / [Events] 等节
 *   · 只有 [Events] 节里的 Dialogue 行是字幕
 *   · Dialogue 的字段数**由 Format: 行决定**，不能写死 ——
 *     标准是 10 个字段（Layer, Start, End, Style, Name, MarginL, MarginR,
 *     MarginV, Effect, Text），但 Text 里含逗号，所以必须按 Format 的顺序
 *     找到 Start/End/Text 的下标，而不是数第几个逗号。
 *     这是 ASS 解析最常见的错误来源。
 */
function parseAssFormat(content: string): SubtitleCue[] {
  const out: SubtitleCue[] = [];
  const lines: string[] = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

  let inEvents: boolean = false;
  // Format 行给出的字段顺序；用 -1 表示"还不知道"
  let idxStart: number = 1;
  let idxEnd: number = 2;
  let idxText: number = 9;
  let fieldCount: number = 10;

  for (let i: number = 0; i < lines.length; i++) {
    const line: string = lines[i].trim();
    if (line.length === 0) {
      continue;
    }
    if (line.startsWith('[')) {
      inEvents = line.toLowerCase().startsWith('[events]');
      continue;
    }
    if (!inEvents) {
      continue;
    }
    if (line.startsWith('Format:')) {
      const fields: string[] = line.substring(7).split(',');
      fieldCount = fields.length;
      for (let k: number = 0; k < fields.length; k++) {
        const name: string = fields[k].trim().toLowerCase();
        if (name === 'start') {
          idxStart = k;
        } else if (name === 'end') {
          idxEnd = k;
        } else if (name === 'text') {
          idxText = k;
        }
      }
      continue;
    }
    if (!line.startsWith('Dialogue:')) {
      continue;
    }

    // 按字段数切分：前 fieldCount-1 个按逗号切，最后一个（Text）吃掉剩余全部
    const body: string = line.substring(9);
    const parts: string[] = body.split(',');
    if (parts.length < fieldCount) {
      // 字段不够（畸形行），跳过而不是猜
      continue;
    }
    const head: string[] = parts.slice(0, fieldCount - 1);
    // Text 是剩下的部分重新拼回来（它内部本来就有逗号）
    const tail: string = parts.slice(fieldCount - 1).join(',');

    const fields: string[] = head.concat([tail]);
    if (idxStart >= fields.length || idxEnd >= fields.length || idxText >= fields.length) {
      continue;
    }
    const startMs: number = parseSubtitleTime(fields[idxStart]);
    const endMs: number = parseSubtitleTime(fields[idxEnd]);
    if (startMs < 0) {
      continue;
    }
    const text: string = cleanSubtitleText(fields[idxText]);
    if (text.length > 0) {
      out.push({
        startMs: startMs,
        endMs: endMs > startMs ? endMs : startMs + 4000,
        text: text
      });
    }
  }
  return out;
}

/**
 * 兜底：没有任何时间行时，把每个非空段落当成一条顺序排下去
 *
 * 为什么要这个：有些"字幕"其实是纯文本台词稿。直接报"解析失败"
 * 对用户没有帮助；按固定时长顺序铺开至少能看到内容。
 * 这不是常见路径，所以给一个保守的 4 秒/条。
 */
function parsePlainText(content: string): SubtitleCue[] {
  const out: SubtitleCue[] = [];
  const blocks: string[] = content.replace(/\r\n/g, '\n').split(/\n\s*\n/);
  let t: number = 0;
  for (let i: number = 0; i < blocks.length; i++) {
    const text: string = cleanSubtitleText(blocks[i]);
    if (text.length === 0) {
      continue;
    }
    out.push({ startMs: t, endMs: t + 4000, text: text });
    t += 4000;
  }
  return out;
}

/**
 * 主入口：把字幕文本解析成有序的 cue 列表
 *
 * @param content 已解码的文本
 * @param fileName 文件名（用于按扩展名判断格式）
 */
export function parseSubtitleText(content: string, fileName: string): SubtitleCue[] {
  if (content.length === 0) {
    return [];
  }
  const lower: string = fileName.toLowerCase();
  let cues: SubtitleCue[] = [];

  if (lower.endsWith('.ass') || lower.endsWith('.ssa')) {
    cues = parseAssFormat(content);
  }
  // SRT / VTT 都走 "-->" 解析；ASS 解析失败时也试一次
  // （有些文件扩展名是 .ass 但内容其实是 SRT）
  if (cues.length === 0) {
    cues = parseArrowFormat(content);
  }
  if (cues.length === 0) {
    cues = parsePlainText(content);
  }

  // 按开始时间排序：有条幕文件的时间顺序是乱的（合并生成的很常见），
  // 不排序的话按位置查找会得到错误结果
  cues.sort((a: SubtitleCue, b: SubtitleCue): number => a.startMs - b.startMs);
  return cues;
}

/**
 * 在有序 cue 列表里按时间查当前该显示哪一条
 *
 * 二分查找而不是线性扫描：一部影片的字幕可能有几千条，
 * 而这个查询在播放时会被频繁调用（UI 刷新）。
 *
 * @param cues 已按 startMs 升序排好的列表
 * @param nowMs 当前播放位置
 * @return 命中的索引；-1 表示这一刻没有字幕
 */
export function findActiveCueIndex(cues: SubtitleCue[], nowMs: number): number {
  if (cues.length === 0) {
    return -1;
  }
  // 找"最后一个 startMs <= nowMs"的位置
  let lo: number = 0;
  let hi: number = cues.length - 1;
  let found: number = -1;
  while (lo <= hi) {
    const mid: number = (lo + hi) >> 1;
    if (cues[mid].startMs <= nowMs) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (found < 0) {
    return -1;   // 还没到第一条
  }
  // 找到了最晚开始的一条，但还要确认它还没过期
  // （两条字幕之间的空隙里就不该显示任何东西）
  return nowMs <= cues[found].endMs ? found : -1;
}
