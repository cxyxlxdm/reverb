import hilog from '@ohos.hilog';

/// hilog 领域 ID(0x0000~0xFFFF 自定义区)。日志用 `hdc shell hilog | grep Reverb` 过滤。
const DOMAIN = 0xE0B0;
const PREFIX = 'Reverb';

/// 内存环形缓冲:保留最近若干条,供「导出日志」使用(不落盘,避免无谓 IO)。
const RING_CAP = 600;
const ring: string[] = [];

function remember(level: string, tag: string, msg: string): void {
  const t = new Date().toISOString().substring(11, 23);
  ring.push(`${t} ${level}/${tag}: ${msg}`);
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
