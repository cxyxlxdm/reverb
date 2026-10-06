import hilog from '@ohos.hilog';
import util from '@ohos.util';

/// hilog 领域 ID(0x0000~0xFFFF 自定义区)。日志用 `hdc shell hilog | grep Reverb` 过滤。
const DOMAIN = 0xE0B0;
const PREFIX = 'Reverb';

/// 内存环形缓冲:保留最近若干条,供「导出日志」使用(不落盘,避免无谓 IO)。
const RING_CAP = 600;
const ring: string[] = [];

function pad(n: number, w: number): string {
  let s = `${n}`;
  while (s.length < w) s = `0${s}`;
  return s;
}

/// `yyyy-MM-dd HH:mm:ss.SSS`,**本地时区**,与 Android(SimpleDateFormat 默认时区)
/// 及 macOS(显式 TimeZone.current)逐字符对齐。
/// 不要用 `toISOString()`:它固定输出 UTC,导出的日志会比用户手机上的时间差若干小时
/// (东八区差 8 小时),事后按用户描述的时间点去日志里找就对不上;截掉日期部分还会让
/// 跨天的日志无法分辨是哪一天。详见 TROUBLESHOOTING H24。
function stamp(d: Date): string {
  const date = `${d.getFullYear()}-${pad(d.getMonth() + 1, 2)}-${pad(d.getDate(), 2)}`;
  const time = `${pad(d.getHours(), 2)}:${pad(d.getMinutes(), 2)}:${pad(d.getSeconds(), 2)}`;
  return `${date} ${time}.${pad(d.getMilliseconds(), 3)}`;
}

function endpointOf(url: string): string {
  const marker = url.indexOf('://');
  if (marker <= 0) return 'invalid';
  const start = marker + 3;
  let end = url.length;
  const slash = url.indexOf('/', start);
  const query = url.indexOf('?', start);
  const fragment = url.indexOf('#', start);
  if (slash >= 0 && slash < end) end = slash;
  if (query >= 0 && query < end) end = query;
  if (fragment >= 0 && fragment < end) end = fragment;
  let authority = url.substring(start, end);
  const at = authority.lastIndexOf('@');
  if (at >= 0) authority = authority.substring(at + 1);
  if (authority.length === 0) return 'invalid';
  let host = authority;
  if (authority.startsWith('[')) {
    const close = authority.indexOf(']');
    if (close < 0) return 'invalid';
    host = authority.substring(0, close + 1);
  } else {
    const colon = authority.lastIndexOf(':');
    if (colon > 0) host = authority.substring(0, colon);
  }
  return host.length === 0 ? 'invalid' : `${url.substring(0, marker).toLowerCase()}://${host}`;
}

function sanitize(msg: string): string {
  return msg.replace(/https?:\/\/[^\s"'<>]+/gi, (url: string): string => endpointOf(url));
}

function remember(level: string, tag: string, msg: string): void {
  ring.push(`${stamp(new Date())} ${level}/${tag}: ${msg}`);
  if (ring.length > RING_CAP) ring.shift();
}

/// 统一日志(对齐 Android util/Logger 与 macOS Log 的 tag 风格)。
export class Log {
  /// 导出最近日志文本(设置页「分享日志」用)。
  static dump(): string {
    return ring.join('\n');
  }

  /// 日志占用(字节)。鸿蒙侧日志只在内存环形缓冲里,不落盘,所以**按 `dump()` 的实际
  /// UTF-8 字节数算**,与分享/导出出去的那份文件同尺寸(Android、macOS 取的是落盘文件长度,
  /// 两端展示口径因此仍然一致)。
  /// ⚠️ 原先写的是 `每字符 × 3`(中文按 3 字节估),而日志行**绝大多数是 ASCII**
  /// (时间戳 + 英文 tag + 主机名),于是这个数比真实文件大 2.4 倍:实测设置页显示
  /// 「当前日志 9 KB」,同一刻分享出去的文件是 3.73 KB。见 H148。
  static sizeBytes(): number {
    if (ring.length === 0) return 0;
    const enc = new util.TextEncoder();
    let n = ring.length - 1;                     // dump() 用 '\n' 连接,行间的分隔符也要算
    for (let i = 0; i < ring.length; i++) n += enc.encodeInto(ring[i]).byteLength;
    return n;
  }

  static clear(): void {
    ring.length = 0;
    Log.i('Log', '日志已清空');
  }

  static endpoint(url: string): string {
    return endpointOf(url);
  }

  static d(tag: string, msg: string): void {
    const safe = sanitize(msg);
    remember('D', tag, safe);
    hilog.debug(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${safe}`);
  }
  static i(tag: string, msg: string): void {
    const safe = sanitize(msg);
    remember('I', tag, safe);
    hilog.info(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${safe}`);
  }
  static w(tag: string, msg: string): void {
    const safe = sanitize(msg);
    remember('W', tag, safe);
    hilog.warn(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${safe}`);
  }
  static e(tag: string, msg: string): void {
    const safe = sanitize(msg);
    remember('E', tag, safe);
    hilog.error(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${safe}`);
  }
}
