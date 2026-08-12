/**
 * XML/HTML 实体反转义。Android 与 macOS 的 OPML 走系统 XML 解析器,属性值天然已反转义;
 * 鸿蒙这边是自己抠字符串,必须显式补这一步。
 *
 * `&amp;` **必须放在最后**替换:否则 `&amp;lt;`(转义过的字面量 `&lt;`)会先被
 * 当成 `&lt;` 解成 `<`,再把 `&amp;` 收尾,结果丢掉一层转义。
 */
export function xmlUnescape(s: string): string {
  if (s.indexOf('&') < 0) return s;
  let t = s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'");
  // 数字实体(十进制 / 十六进制),真实 OPML 里 `&#38;` 写法不少见
  t = t.replace(/&#[xX]([0-9a-fA-F]+);/g, (_m: string, hex: string) =>
    String.fromCharCode(parseInt(hex, 16)));
  t = t.replace(/&#(\d+);/g, (_m: string, dec: string) =>
    String.fromCharCode(parseInt(dec, 10)));
  return t.replace(/&amp;/g, '&');
}

/// HTML → 带段落换行的纯文本。移植 Android `RssParser.htmlToText`
/// 与 `ITunesSource` 里近似的那份,合并为一处(三端行为对齐)。
export function htmlToText(input: string): string {
  if (input.length === 0) return '';
  let t = input;
  // 结构性标签先转换行,再剥其余标签(顺序很关键,否则段落会被压成一坨)
  t = t.replace(/<br\s*\/?>/gi, '\n');
  t = t.replace(/<\/p>/gi, '\n\n');
  t = t.replace(/<\/div>/gi, '\n');
  t = t.replace(/<li[^>]*>/gi, '· ');
  t = t.replace(/<[^>]*>/g, '');
  // 常见实体
  t = t.replace(/&nbsp;/g, ' ')
    .replace(/&mdash;/g, '—')
    .replace(/&hellip;/g, '…');
  t = xmlUnescape(t);
  // 行内空白压缩(不动换行);去行首尾空格;多余空行收敛
  t = t.replace(/[ \t]+/g, ' ');
  t = t.replace(/ *\n */g, '\n');
  t = t.replace(/\n{3,}/g, '\n\n');
  return t.trim();
}

/// itunes:duration 解析:HH:MM:SS / MM:SS / SS / 纯小数秒 → 秒。
export function parseDurationSec(raw: string): number {
  const s = raw.trim();
  if (s.length === 0) return 0;
  if (s.indexOf(':') >= 0) {
    const parts = s.split(':');
    const nums: number[] = [];
    for (let i = 0; i < parts.length; i++) {
      const n = parseInt(parts[i].trim(), 10);
      if (isNaN(n)) return 0;
      nums.push(n);
    }
    if (nums.length === 3) return nums[0] * 3600 + nums[1] * 60 + nums[2];
    if (nums.length === 2) return nums[0] * 60 + nums[1];
    return nums[0];
  }
  const f = parseFloat(s);
  return isNaN(f) ? 0 : Math.floor(f);
}
