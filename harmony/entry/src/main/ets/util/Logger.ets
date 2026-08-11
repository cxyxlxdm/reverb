import hilog from '@ohos.hilog';

/// hilog 领域 ID(0x0000~0xFFFF 自定义区)。日志用 `hdc shell hilog | grep Reverb` 过滤。
const DOMAIN = 0xE0B0;
const PREFIX = 'Reverb';

/// 统一日志(对齐 Android util/Logger 与 macOS Log 的 tag 风格)。
export class Log {
  static d(tag: string, msg: string): void {
    hilog.debug(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${msg}`);
  }
  static i(tag: string, msg: string): void {
    hilog.info(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${msg}`);
  }
  static w(tag: string, msg: string): void {
    hilog.warn(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${msg}`);
  }
  static e(tag: string, msg: string): void {
    hilog.error(DOMAIN, PREFIX, '%{public}s', `[${tag}] ${msg}`);
  }
}
