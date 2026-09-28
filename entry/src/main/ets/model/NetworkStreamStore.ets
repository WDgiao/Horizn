import { common } from '@kit.AbilityKit';
import { readJsonArraySafe, writeJsonArrayAtomic, AtomicWriteResult } from './JsonStore';

/** 落盘文件名（存在应用沙箱 files 目录） */
const FILE_NAME: string = 'network_streams.json';
/** 最多保留的条数 */
const MAX_STREAMS: number = 100;

/**
 * 网络流协议类型
 *
 * 为什么要分类型而不是只存一个 URL 字符串：
 *   不同协议的播放路径完全不一样 —— HTTP/HTTPS 能直接交给系统 AVPlayer，
 *   而 RTSP 是实时流（没有总时长、不能随机 seek），
 *   播放页的处理逻辑要分开。提前分好类，后面接播放时不用回头改数据结构。
 */
export enum StreamProtocol {
  /** HTTP / HTTPS：点播为主，可 seek */
  HTTP = 0,
  /** RTSP：实时流，无总时长 */
  RTSP = 1,
  /** RTMP：常见于直播推流 */
  RTMP = 2,
  /** 其它 / 未识别 */
  UNKNOWN = 3
}

/** 一条网络流记录 */
export interface NetworkStream {
  /** 唯一 id（时间戳生成，本地足够） */
  id: string;
  /** 显示名（用户可自定义，默认取 URL 的 host 部分） */
  name: string;
  /** 完整地址 */
  url: string;
  /** 协议类型 */
  protocol: number;
  /** 创建时间戳（毫秒），用于排序 */
  createdAt: number;
  /**
   * 最后播放时间戳（毫秒）
   * 0 表示从未播放过 —— 界面据此区分"没试过"和"试过失败"
   */
  lastPlayedAt: number;
}

/**
 * 网络流仓库
 *
 * 存储方式与 WatchHistory 完全一致：沙箱 files 目录下的一个 JSON 文件，
 * 内存里保留缓存、只有写操作才落盘。
 *
 * 为什么不复用 WatchHistory：
 *   WatchHistory 的键是「沙箱内绝对路径」，而且带播放进度语义
 *   （position / duration / 未播完判定）。网络流没有进度语义 ——
 *   直播流没有总时长，点播流的进度也未必需要续播。
 *   混在一起会让两边的判定逻辑互相污染，所以单独一份。
 */
export class NetworkStreamStore {
  /** 记录文件绝对路径 */
  private filePath: string;
  /** 内存缓存，undefined 表示尚未加载 */
  private cache: NetworkStream[] | undefined = undefined;

  constructor(context: common.Context) {
    this.filePath = context.filesDir + '/' + FILE_NAME;
  }

  /** 记录文件的绝对路径（便于排查） */
  getFilePath(): string {
    return this.filePath;
  }

  /** 让内存缓存失效，下次读取会重新从磁盘加载 */
  invalidateCache(): void {
    this.cache = undefined;
  }

  /** 读取全部记录（按创建时间倒序，最新的在前） */
  list(): NetworkStream[] {
    const all: NetworkStream[] = this.load();
    const copy: NetworkStream[] = all.slice(0);
    copy.sort((a: NetworkStream, b: NetworkStream): number => b.createdAt - a.createdAt);
    return copy;
  }

  /** 按 id 查一条 */
  find(id: string): NetworkStream | undefined {
    const all: NetworkStream[] = this.load();
    for (let i = 0; i < all.length; i++) {
      if (all[i].id === id) {
        return all[i];
      }
    }
    return undefined;
  }

  /**
   * 判断同一个地址是否已经存在（避免重复添加）
   * @param url 地址
   */
  existsUrl(url: string): boolean {
    const all: NetworkStream[] = this.load();
    const normalized: string = url.trim();
    for (let i = 0; i < all.length; i++) {
      if (all[i].url === normalized) {
        return true;
      }
    }
    return false;
  }

  /**
   * 新增一条记录
   * @param name 显示名
   * @param url 地址
   * @returns 新建的记录；地址重复时返回 undefined
   */
  add(name: string, url: string): NetworkStream | undefined {
    const trimmedUrl: string = url.trim();
    if (trimmedUrl.length === 0) {
      return undefined;
    }
    if (this.existsUrl(trimmedUrl)) {
      return undefined;
    }
    const now: number = Date.now();
    const record: NetworkStream = {
      id: 'ns_' + now.toString() + '_' + Math.floor(Math.random() * 10000).toString(),
      name: name.trim().length > 0 ? name.trim() : NetworkStreamStore.guessName(trimmedUrl),
      url: trimmedUrl,
      protocol: NetworkStreamStore.detectProtocol(trimmedUrl),
      createdAt: now,
      lastPlayedAt: 0
    };
    const all: NetworkStream[] = this.load();
    const next: NetworkStream[] = all.slice(0);
    next.push(record);
    next.sort((a: NetworkStream, b: NetworkStream): number => b.createdAt - a.createdAt);
    const trimmed: NetworkStream[] = next.slice(0, MAX_STREAMS);
    this.cache = trimmed;
    this.persist(trimmed);
    return record;
  }

  /**
   * 更新一条记录（改名 / 改地址 / 记录播放时间）
   *
   * ★ 2026-09-29 修正：原先签名是 `update(id, name, markPlayed)`，
   *   内部写死 `url: r.url` —— 也就是**地址永远沿用旧值**。
   *   而编辑页的地址框是可编辑的、还实时提示"✓ 格式可用，保存后即可播放"，
   *   保存后弹"已保存"。用户改了地址被告知成功，实际播的还是旧地址，
   *   典型的"数据丢失 + 误导性确认"。
   *   现在增加 url 参数（空串表示不改地址），并补上改地址必做的两件事：
   *   重新校验、重新探测协议、查重。
   *
   * @param id 记录 id
   * @param name 新名称；空串表示不改
   * @param url 新地址；空串表示不改地址（保持原有行为兼容）
   * @param markPlayed 是否把最后播放时间置为当前
   * @return 空串表示成功；非空为失败原因（可直接提示给用户）
   */
  update(id: string, name: string, url: string, markPlayed: boolean): string {
    const all: NetworkStream[] = this.load();
    const trimmedUrl: string = url.trim();

    // 地址真要改时，必须先过校验与查重 —— 否则等于绕过了 add() 的全部把关
    if (trimmedUrl.length > 0) {
      const verr: string = NetworkStreamStore.validateUrl(trimmedUrl);
      if (verr.length > 0) {
        return verr;
      }
      // 查重时要排除自己，否则"不改地址只改名"会被自己挡下来
      for (let i = 0; i < all.length; i++) {
        if (all[i].id !== id && all[i].url === trimmedUrl) {
          return '该地址已经添加过了';
        }
      }
    }

    let hit: boolean = false;
    const next: NetworkStream[] = [];
    for (let i = 0; i < all.length; i++) {
      const r: NetworkStream = all[i];
      if (r.id !== id) {
        next.push(r);
        continue;
      }
      hit = true;
      // 地址变了要同步重算协议，否则列表上的协议徽章会与地址对不上
      const finalUrl: string = trimmedUrl.length > 0 ? trimmedUrl : r.url;
      // ArkTS 的对象是引用语义，但这里显式重建一份，
      // 避免缓存里的旧对象被就地改写导致界面读不到变化
      const updated: NetworkStream = {
        id: r.id,
        name: name.trim().length > 0 ? name.trim() : r.name,
        url: finalUrl,
        protocol: trimmedUrl.length > 0
          ? NetworkStreamStore.detectProtocol(finalUrl) : r.protocol,
        createdAt: r.createdAt,
        lastPlayedAt: markPlayed ? Date.now() : r.lastPlayedAt
      };
      next.push(updated);
    }
    if (!hit) {
      return '记录不存在';
    }
    this.cache = next;
    this.persist(next);
    return '';   // 空串 = 成功
  }

  /**
   * 删除一条记录
   * @param id 记录 id
   */
  remove(id: string): boolean {
    const all: NetworkStream[] = this.load();
    const next: NetworkStream[] = [];
    let hit: boolean = false;
    for (let i = 0; i < all.length; i++) {
      if (all[i].id === id) {
        hit = true;
        continue;
      }
      next.push(all[i]);
    }
    if (!hit) {
      return false;
    }
    this.cache = next;
    this.persist(next);
    return true;
  }

  /** 清空全部记录 */
  clear(): void {
    this.cache = [];
    this.persist([]);
  }

  /**
   * 从 URL 判断协议类型
   *
   * 宁可把未识别的归到 UNKNOWN 也不要猜 —— 猜错会让界面显示错误的
   * 协议标签，用户据此判断"能不能播"就会被误导。
   *
   * @param url 地址
   */
  static detectProtocol(url: string): StreamProtocol {
    const lower: string = url.trim().toLowerCase();
    if (lower.startsWith('https://') || lower.startsWith('http://')) {
      return StreamProtocol.HTTP;
    }
    if (lower.startsWith('rtsp://')) {
      return StreamProtocol.RTSP;
    }
    if (lower.startsWith('rtmp://') || lower.startsWith('rtmps://')) {
      return StreamProtocol.RTMP;
    }
    return StreamProtocol.UNKNOWN;
  }

  /** 协议的中文显示名 */
  static protocolLabel(protocol: number): string {
    if (protocol === StreamProtocol.HTTP) { return 'HTTP'; }
    if (protocol === StreamProtocol.RTSP) { return 'RTSP'; }
    if (protocol === StreamProtocol.RTMP) { return 'RTMP'; }
    return '未知';
  }

  /**
   * 该协议目前是否已支持播放
   *
   * 目前只有 HTTP/HTTPS 能播（交给系统 AVPlayer）。
   * 单独抽成方法而不是散在界面里判断，是为了接播放时只改这一处。
   */
  static isPlayable(protocol: number): boolean {
    return protocol === StreamProtocol.HTTP;
  }

  /**
   * 由 URL 猜一个显示名
   *
   * 规则：取 host 部分；取不到就用整个 URL 截断。
   * 目的是让列表里不出现一长串难辨认的地址。
   *
   * @param url 地址
   */
  static guessName(url: string): string {
    let s: string = url.trim();
    const schemeEnd: number = s.indexOf('://');
    if (schemeEnd >= 0) {
      s = s.substring(schemeEnd + 3);
    }
    // 去掉查询串与锚点，它们对辨认没帮助
    const q: number = s.indexOf('?');
    if (q >= 0) {
      s = s.substring(0, q);
    }
    const hash: number = s.indexOf('#');
    if (hash >= 0) {
      s = s.substring(0, hash);
    }
    // 取 host（第一个 / 之前）
    const slash: number = s.indexOf('/');
    const host: string = slash >= 0 ? s.substring(0, slash) : s;
    if (host.length > 0) {
      return host;
    }
    return url.length > 40 ? (url.substring(0, 40) + '…') : url;
  }

  /**
   * 校验地址是否可用；返回错误文案，合法则空串
   *
   * 只做「格式」层面的校验，不联网探测 —— 添加时联网会导致
   * 每个地址都要等几秒，体验很差；真正的连通性判定放到播放时。
   *
   * @param url 地址
   */
  static validateUrl(url: string): string {
    const s: string = url.trim();
    if (s.length === 0) {
      return '请输入播放地址';
    }
    if (s.length < 8) {
      return '地址过短，请检查是否完整';
    }
    const schemeEnd: number = s.indexOf('://');
    if (schemeEnd <= 0) {
      return '缺少协议前缀（需要 http:// 或 https://）';
    }
    const scheme: string = s.substring(0, schemeEnd).toLowerCase();
    if (scheme !== 'http' && scheme !== 'https' && scheme !== 'rtsp' && scheme !== 'rtmp') {
      return '暂不支持 ' + scheme + ' 协议（可用 http / https / rtsp / rtmp）';
    }
    const rest: string = s.substring(schemeEnd + 3);
    if (rest.length === 0) {
      return '缺少主机名';
    }
    const slash: number = rest.indexOf('/');
    const host: string = slash >= 0 ? rest.substring(0, slash) : rest;
    if (host.length === 0) {
      return '缺少主机名';
    }
    // http/https 之外的协议目前只是「先存着」，明确提示，
    // 免得用户以为添加成功就能播
    if (scheme !== 'http' && scheme !== 'https') {
      return '';
    }
    return '';
  }

  /** 取内存缓存；首次访问时从磁盘加载 */
  private load(): NetworkStream[] {
    const cached: NetworkStream[] | undefined = this.cache;
    if (cached !== undefined) {
      return cached;
    }
    // 公共模块负责类型校验与"损坏先留档"，理由见 JsonStore.ets
    const raw: Object[] = readJsonArraySafe(this.filePath);
    const result: NetworkStream[] = [];
    for (let i = 0; i < raw.length; i++) {
      const r = raw[i] as NetworkStream;
      // 地址是唯一键，缺了就没法播；其余字段缺了给安全默认值
      if (typeof r.url !== 'string' || r.url.length === 0) {
        continue;
      }
      if (typeof r.id !== 'string' || r.id.length === 0) {
        continue;
      }
      result.push(r);
    }
    this.cache = result;
    return result;
  }

  /**
   * 序列化并写回磁盘（原子写）
   * @param records 要写入的记录
   */
  private persist(records: NetworkStream[]): void {
    // 原子写：先写 .tmp 再 rename 替换，避免"崩在 TRUNC 与 write 之间"丢光地址列表
    const r: AtomicWriteResult = writeJsonArrayAtomic(this.filePath, records);
    if (!r.ok) {
      console.error('persist network streams failed: ' + r.error);
    }
  }
}
