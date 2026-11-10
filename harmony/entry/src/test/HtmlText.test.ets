import { describe, it, expect } from '@ohos/hypium';
import { htmlToText, xmlUnescape, parseDurationSec } from '../main/ets/util/HtmlText';

/**
 * HTML 清洗与时长解析。三条东西三端各写了一份,行为必须一致:
 * 同一集的 shownotes 在 Android / 鸿蒙 / iOS 上读到的段落不能不一样。
 */
export default function htmlTextTest(): void {
  describe('HtmlText', () => {

    it('实体反转义:&amp; 最后替换,保住一层转义', 0, () => {
      expect(xmlUnescape('a &lt; b &gt; c')).assertEqual('a < b > c');
      expect(xmlUnescape('&quot;x&quot; &apos;y&apos;')).assertEqual('"x" \'y\'');
      // 双重转义只解一层:`&amp;lt;` → `&lt;`,不能变成 `<`
      expect(xmlUnescape('&amp;lt;')).assertEqual('&lt;');
      // 数字实体(十进制 / 十六进制)
      expect(xmlUnescape('&#38;')).assertEqual('&');
      expect(xmlUnescape('&#x26;')).assertEqual('&');
    });

    it('没有 & 的串原样返回', 0, () => {
      expect(xmlUnescape('plain text')).assertEqual('plain text');
    });

    it('段落、换行与列表项', 0, () => {
      expect(htmlToText('<p>one</p><p>two</p>')).assertEqual('one\n\ntwo');
      expect(htmlToText('a<br>b')).assertEqual('a\nb');
      // `</li>` 只被当普通标签剥掉,不换行 —— 与 Android `RssParser.htmlToText` 逐条一致。
      // 想换行得靠 `<br>` 或 `</p>`,发布方给的列表本来也常这么写。
      expect(htmlToText('<ul><li>x</li><li>y</li></ul>')).assertEqual('· x· y');
    });

    it('剥标签、压空白、收敛多余空行', 0, () => {
      expect(htmlToText('<div>  a   b  </div>')).assertEqual('a b');
      expect(htmlToText('<p>a</p>\n\n\n<p>b</p>')).assertEqual('a\n\nb');
      expect(htmlToText('&nbsp;&nbsp;x')).assertEqual('x');
      expect(htmlToText('a&mdash;b&hellip;')).assertEqual('a—b…');
    });

    it('空输入返回空串', 0, () => {
      expect(htmlToText('')).assertEqual('');
    });

    it('itunes:duration 三种写法', 0, () => {
      expect(parseDurationSec('01:02:03')).assertEqual(3723);
      expect(parseDurationSec('05:30')).assertEqual(330);
      expect(parseDurationSec('42')).assertEqual(42);
      // 小数秒向下取整
      expect(parseDurationSec('12.9')).assertEqual(12);
      expect(parseDurationSec('')).assertEqual(0);
      expect(parseDurationSec('abc')).assertEqual(0);
    });
  });
}
