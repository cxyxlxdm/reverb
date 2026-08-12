import hilog from '@ohos.hilog';

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

function remember(level: string, tag: string, msg: string): void {
  ring.push(`${stamp(new Date())} ${level}/${tag}: ${msg}`);
  if (ring.length > RING_CAP) ring.shift();
}

/// 统一日志(对齐 Android util/Logger 与 macOS Log 的 tag 风格)。
export class Log {
  /// 导出最近日志文本(设置页「导出日志」用)。
  static dump(): string {
    return ring.join('\n');
  }

  static d(tag: string, msg: string): void {
    remember('D', tag, msg);
    hilog.debug(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${msg}`);
  }
  static i(tag: string, msg: string): void {
    remember('I', tag, msg);
    hilog.info(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${msg}`);
  }
  static w(tag: string, msg: string): void {
    remember('W', tag, msg);
    hilog.warn(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${msg}`);
  }
  static e(tag: string, msg: string): void {
    remember('E', tag, msg);
    hilog.error(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${msg}`);
  }
}
