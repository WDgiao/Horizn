/**
 * JSON 本地存储的公共设施
 *
 * 为什么单独抽一个模块（而不是各仓库各写一份）：
 *   这个项目里 WatchHistory / NetworkStreamStore / FolderRepository 等
 *   都做同一件事 —— 把一个 JSON 数组存到沙箱文件里。原先各自复制了一份
 *   "打开-截断-写入"的实现，于是同一个隐患在三处同时存在问题：
 *
 *   ★ 隐患：先 TRUNC 再写 = 崩在中间就丢光数据
 *     `openSync(WRITE_ONLY|CREATE|TRUNC)` 在**打开的那一刻**就把文件清空了，
 *     之后才 writeSync。如果这两步之间进程被杀/崩溃/断电，文件就变成
 *     空文件或半截 JSON。下次读取时 JSON.parse 失败 → 代码里一句
 *     `catch { return [] }` 就把它当成"没有记录"，功能看起来正常，
 *     但用户的全部断点续播进度已经没了 —— 而且是**静默**没的。
 *
 *   修法两件事，本模块一起提供：
 *     ① writeJsonArrayAtomic —— 先写临时文件，再 rename 原子替换。
 *        rename 在同一文件系统内是原子操作：要么是完整的新文件，
 *        要么还是完整的旧文件，不存在"半截"状态。
 *     ② readJsonArraySafe —— 解析失败时**先把坏文件改名留档**再返回空数组。
 *        绝不在用户还没看到的情况下把可能还能人工抢救的内容覆盖掉。
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

/** 一次原子写的结果，用于诊断 */
export interface AtomicWriteResult {
  /** 是否成功 */
  ok: boolean;
  /** 实际写入的字节数 */
  written: number;
  /** 期望写入的字节数 */
  expected: number;
  /** 失败描述；成功时为空串 */
  error: string;
}

/**
 * 原子写入一个 JSON 数组
 *
 * 流程：写 `<path>.tmp` → 校验字节数 → rename 覆盖 `<path>`
 *
 * @param path 目标文件绝对路径
 * @param value 要序列化的值（通常是数组）
 * @returns 写入结果
 */
export function writeJsonArrayAtomic(path: string, value: Object): AtomicWriteResult {
  const tmpPath: string = path + '.tmp';
  let expected: number = 0;
  let written: number = 0;
  try {
    const text: string = JSON.stringify(value);
    const encoder: util.TextEncoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encodeInto(text);
    expected = bytes.length;

    // 写临时文件（TRUNC 只影响 .tmp，原文件此刻还是完好的）
    const tmp = fileIo.openSync(
      tmpPath,
      fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC
    );
    try {
      // 只写 bytes 实际覆盖的那段，避免把底层 ArrayBuffer 的多余字节也写出去
      written = fileIo.writeSync(tmp.fd, bytes.buffer.slice(0, bytes.length));
      // 落盘：确保数据真的进了存储，而不是只躺在页缓存里 ——
      // 否则"rename 之后仍可能因掉电丢内容"，原子替换就失去意义
      try {
        fileIo.fsyncSync(tmp.fd);
      } catch (e) {
        // 个别平台/实现不支持 fsync：不影响正确性主路径，忽略
      }
    } finally {
      fileIo.closeSync(tmp);
    }

    if (written !== expected) {
      // 短写：宁可保留旧文件，也不要用半截内容去替换它
      return {
        ok: false, written: written, expected: expected,
        error: 'SHORT ' + written.toString() + '/' + expected.toString()
      };
    }

    // 原子替换：这一步要么成功、要么失败，不会留下半截文件
    fileIo.renameSync(tmpPath, path);
    return { ok: true, written: written, expected: expected, error: '' };
  } catch (err) {
    // 收尾：把可能残留的 .tmp 清掉，避免越积越多
    try {
      if (fileIo.accessSync(tmpPath)) {
        fileIo.unlinkSync(tmpPath);
      }
    } catch (e) {
      // 清理失败不影响主流程
    }
    return {
      ok: false, written: written, expected: expected,
      error: JSON.stringify(err)
    };
  }
}

/**
 * 安全读取一个 JSON 数组
 *
 * 与"直接 JSON.parse"的区别（每一条都对应一个真实会发生的场景）：
 *   ① 文件不存在          → 返回空数组（首次使用的正常情况）
 *   ② 解析失败 / 不是数组 → **先把坏文件改名留档**，再返回空数组
 *   ③ 元素不是对象        → 跳过该元素，其余照常返回
 *
 * 第 ② 条是重点：原先的实现是"解析失败就当成空"，用户下次一保存就把
 * 那个可能还能人工修复的文件永久覆盖了。改名留档之后，出问题至少还能捞回来。
 *
 * @param path 文件绝对路径
 * @returns 解析出的对象数组；任何异常情况下都返回数组（不抛）
 */
export function readJsonArraySafe(path: string): Object[] {
  try {
    if (!fileIo.accessSync(path)) {
      return [];
    }
    const stat = fileIo.statSync(path);
    if (stat.size <= 0) {
      return [];
    }
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    let text: string = '';
    try {
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = fileIo.readSync(file.fd, buf, { offset: 0, length: stat.size });
      const bytes: Uint8Array = new Uint8Array(buf, 0, read);
      const decoder: util.TextDecoder = new util.TextDecoder('utf-8');
      text = decoder.decodeToString(bytes);
    } finally {
      fileIo.closeSync(file);
    }

    const parsed: Object | null = JSON.parse(text) as Object | null;
    if (parsed === null || parsed === undefined) {
      quarantineCorruptFile(path, 'parsed-null');
      return [];
    }
    // ★ 必须确认是数组：非数组（例如旧 schema 的 `{}`）能通过判空，
    //   但后续 `.slice()/.length` 会抛 TypeError，异常会一路抛进首页渲染
    if (!Array.isArray(parsed)) {
      quarantineCorruptFile(path, 'not-array');
      return [];
    }
    // 逐条过滤掉不是对象的元素，避免后面按字段取值时炸
    const out: Object[] = [];
    const arr: Object[] = parsed as Object[];
    for (let i = 0; i < arr.length; i++) {
      const e: Object | null = arr[i];
      if (e !== null && e !== undefined && typeof e === 'object') {
        out.push(e);
      }
    }
    if (out.length !== arr.length) {
      console.error('readJsonArraySafe: ' + path + ' 丢弃了 '
        + (arr.length - out.length).toString() + ' 个非对象元素');
    }
    return out;
  } catch (err) {
    // 解析失败 → 留档后再当空
    quarantineCorruptFile(path, 'parse-error');
    console.error('readJsonArraySafe failed: ' + path + ' ' + JSON.stringify(err));
    return [];
  }
}

/**
 * 把损坏的文件改名留档，而不是就地覆盖
 *
 * 命名 `<path>.corrupt.<时间戳>`，用户/开发者还能事后捞出来看看内容。
 * 留档本身失败也不影响主流程（大不了下次还是读不出来）。
 */
function quarantineCorruptFile(path: string, reason: string): void {
  try {
    if (!fileIo.accessSync(path)) {
      return;
    }
    const bak: string = path + '.corrupt.' + Date.now().toString();
    fileIo.renameSync(path, bak);
    console.error('检测到损坏的 JSON（' + reason + '），已留档为 ' + bak);
  } catch (e) {
    console.error('留档损坏文件失败: ' + JSON.stringify(e));
  }
}
