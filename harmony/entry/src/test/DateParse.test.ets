import { describe, it, expect } from '@ohos/hypium';
import { parsePubMillis, formatPubDate, formatCachedAt } from '../main/ets/util/DateParse';

/**
 * RSS 时间解析的三端共享判据。Android 与 macOS 各有同一套断言(`DateParseTest` /
 * `CredentialTests` 旁的日期用例),这里逐条对齐 —— 同一份订阅在四端显示的日期必须一致。
 */
export default function dateParseTest(): void {
  describe('DateParse', () => {

    it('RFC-822 带数字时区', 0, () => {
      // Fri, 21 Aug 2026 12:30:00 +0800 ⇒ UTC 04:30
      const ms = parsePubMillis('Fri, 21 Aug 2026 12:30:00 +0800');
      expect(ms).assertEqual(Date.UTC(2026, 7, 21, 4, 30, 0));
    });

    it('RFC-822 不带星期与秒,缩写时区', 0, () => {
      // 21 Aug 2026 12:30 GMT
      expect(parsePubMillis('21 Aug 2026 12:30 GMT')).assertEqual(Date.UTC(2026, 7, 21, 12, 30, 0));
      // EST = -300 分钟 ⇒ UTC 17:30
      expect(parsePubMillis('21 Aug 2026 12:30 EST')).assertEqual(Date.UTC(2026, 7, 21, 17, 30, 0));
    });

    it('ISO-8601 的 Z 与 ±HH:MM', 0, () => {
      expect(parsePubMillis('2026-08-21T04:30:00Z')).assertEqual(Date.UTC(2026, 7, 21, 4, 30, 0));
      expect(parsePubMillis('2026-08-21T12:30:00+08:00')).assertEqual(Date.UTC(2026, 7, 21, 4, 30, 0));
      // 只有日期时按当天 00:00 UTC
      expect(parsePubMillis('2026-08-21')).assertEqual(Date.UTC(2026, 7, 21, 0, 0, 0));
    });

    it('空串与垃圾输入返回 0(排最后)', 0, () => {
      expect(parsePubMillis('')).assertEqual(0);
      expect(parsePubMillis('   ')).assertEqual(0);
      expect(parsePubMillis('not a date')).assertEqual(0);
    });

    it('展示格式定死英文缩写,不跟语言', 0, () => {
      const s = formatPubDate('Fri, 21 Aug 2026 12:30:00 +0800');
      // 形如 "Fri, 21 Aug 2026";时区依赖本机,所以只断言形状与年月日
      expect(/^[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} 2026$/.test(s)).assertTrue();
      expect(s.indexOf('Aug 2026') > 0).assertTrue();
    });

    it('解析不出时退回原始串前 16 字符', 0, () => {
      const raw = 'yesterday-ish 00:00';
      expect(formatPubDate(raw)).assertEqual(raw.substring(0, 16));
    });

    it('缓存时刻 0 返回空串', 0, () => {
      expect(formatCachedAt(0)).assertEqual('');
      expect(formatCachedAt(-1)).assertEqual('');
    });
  });
}
