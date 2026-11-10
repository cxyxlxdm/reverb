import { describe, it, expect } from '@ohos/hypium';
import { LiveStream } from '../main/ets/net/LiveStream';

/**
 * 直播流入口的廉价预判(不发请求)。真正的判据在 `resolve` 的响应头探测里 ——
 * 那一条要真网络,只能真机验。
 *
 * 与 Android `LiveStreamSourceTest`、macOS `LiveStreamTests` 同一组断言:
 * 只放行 http(s),裸域名与普通文本一律不猜。
 */
export default function liveStreamTest(): void {
  describe('LiveStream', () => {

    it('http / https 放行', 0, () => {
      expect(LiveStream.looksLikeStream('https://example.com/live.mp3')).assertTrue();
      expect(LiveStream.looksLikeStream('http://example.com:8000/stream')).assertTrue();
    });

    it('首尾空白先裁掉', 0, () => {
      expect(LiveStream.looksLikeStream('  https://example.com/live.mp3  ')).assertTrue();
    });

    it('裸域名、文件路径、普通文本都不猜', 0, () => {
      expect(LiveStream.looksLikeStream('example.com/live.mp3')).assertFalse();
      expect(LiveStream.looksLikeStream('/tmp/live.mp3')).assertFalse();
      expect(LiveStream.looksLikeStream('今晚八点直播')).assertFalse();
      expect(LiveStream.looksLikeStream('')).assertFalse();
      // 前缀必须完整:`httpsx://` 不是 http(s)
      expect(LiveStream.looksLikeStream('httpsx://example.com')).assertFalse();
    });
  });
}
