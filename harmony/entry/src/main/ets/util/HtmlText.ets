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
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&mdash;/g, '—')
    .replace(/&hellip;/g, '…');
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
