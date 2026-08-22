/// RSS pubDate 解析。ArkTS 无 SimpleDateFormat,手写 RFC-822 + ISO-8601 解析器,
/// 覆盖 Android `InboxStore` 的 8 个模板所能处理的形态。解析失败返回 0(排最后)。

const MONTHS: Record<string, number> = {
  'jan': 0, 'feb': 1, 'mar': 2, 'apr': 3, 'may': 4, 'jun': 5,
  'jul': 6, 'aug': 7, 'sep': 8, 'oct': 9, 'nov': 10, 'dec': 11
};

/// 常见时区缩写 → 相对 UTC 的分钟偏移。
const TZ: Record<string, number> = {
  'ut': 0, 'utc': 0, 'gmt': 0, 'z': 0,
  'est': -300, 'edt': -240, 'cst': -360, 'cdt': -300,
  'mst': -420, 'mdt': -360, 'pst': -480, 'pdt': -420,
  'cet': 60, 'cest': 120, 'jst': 540, 'kst': 540
};

/// 解析为毫秒时间戳;失败返回 0。
export function parsePubMillis(raw: string): number {
  const s = raw.trim();
  if (s.length === 0) return 0;
  const rfc = parseRfc822(s);
  if (rfc > 0) return rfc;
  const iso = parseIso8601(s);
  if (iso > 0) return iso;
  return 0;
}

/// RFC-822/1123:`[Ddd, ]D Mmm YYYY HH:MM[:SS] TZ`
/// 覆盖:带/不带星期前缀、带/不带秒、数字时区(+0800)与缩写时区(GMT/EST…)。
function parseRfc822(input: string): number {
  let s = input;
  // 去掉星期前缀
  const comma = s.indexOf(',');
  if (comma >= 0 && comma <= 4) s = s.substring(comma + 1).trim();

  const parts = s.split(/\s+/);
  if (parts.length < 4) return 0;

  const day = parseInt(parts[0], 10);
  const mon = MONTHS[parts[1].toLowerCase().substring(0, 3)];
  let year = parseInt(parts[2], 10);
  if (isNaN(day) || mon === undefined || isNaN(year)) return 0;
  if (year < 100) year += year < 70 ? 2000 : 1900;   // 两位年份

  const hms = parts[3].split(':');
  const hh = parseInt(hms[0], 10);
  const mm = hms.length > 1 ? parseInt(hms[1], 10) : 0;
  const ss = hms.length > 2 ? parseInt(hms[2], 10) : 0;
  if (isNaN(hh) || isNaN(mm) || isNaN(ss)) return 0;

  const offsetMin = parts.length > 4 ? parseOffset(parts[4]) : 0;
  return Date.UTC(year, mon, day, hh, mm, ss) - offsetMin * 60000;
}

/// ISO-8601:`YYYY-MM-DD[THH:MM[:SS][.sss]][Z|±HH:MM]`,也接受仅日期。
function parseIso8601(input: string): number {
  const m = input.match(
    /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?)?/
  );
  if (m === null) return 0;
  const year = parseInt(m[1], 10);
  const mon = parseInt(m[2], 10) - 1;
  const day = parseInt(m[3], 10);
  const hh = m[4] !== undefined ? parseInt(m[4], 10) : 0;
  const mm = m[5] !== undefined ? parseInt(m[5], 10) : 0;
  const ss = m[6] !== undefined ? parseInt(m[6], 10) : 0;
  const offsetMin = m[7] !== undefined ? parseOffset(m[7]) : 0;
  return Date.UTC(year, mon, day, hh, mm, ss) - offsetMin * 60000;
}

/// `+0800` / `+08:00` / `GMT` / `EST` → 相对 UTC 的分钟偏移。
function parseOffset(raw: string): number {
  const s = raw.trim();
  if (s.length === 0) return 0;
  const sign = s.charAt(0);
  if (sign === '+' || sign === '-') {
    const body = s.substring(1).replace(':', '');
    if (body.length < 4) return 0;
    const h = parseInt(body.substring(0, 2), 10);
    const m = parseInt(body.substring(2, 4), 10);
    if (isNaN(h) || isNaN(m)) return 0;
    const v = h * 60 + m;
    return sign === '-' ? -v : v;
  }
  const named = TZ[s.toLowerCase()];
  return named === undefined ? 0 : named;
}

/**
 * 缓存时刻的短格式:`MM-DD HH:mm`(本机时区)。
 *
 * 刻意用纯数字格式而不带"年月日":这串会拼进 5 种语言的「离线内容 · 上次更新 %s」,
 * 数字格式在各语言下都读得通,不必为此再加 5 条本地化。
 * 同理不用 `toISOString()` —— 它固定输出 UTC,显示会比用户手机上的时间差若干小时。
 */
export function formatCachedAt(ms: number): string {
  if (ms <= 0) return '';
  const d = new Date(ms);
  const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/// 与 Android 的展示格式**逐字一致**用的固定英文缩写(见 formatPubDate 注释)。
/// 注:上面那个 `MONTHS` 是「缩写 → 月份序号」的解析用查表,方向相反,故另起一份。
const WEEKDAY_NAMES: string[] = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTH_NAMES: string[] = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/**
 * 单集发布日期的展示形态:`Fri, 21 Aug 2026`。
 *
 * **两端定死英文缩写 + 零填充,不跟随界面语言。** 理由:
 *  - 这是与 Android 侧对齐后的统一格式(那边原先直接把 RSS 的 pubDate 截前 16 字符,
 *    对 RFC-822 的源恰好就得到这个样子,格式沿用、取法改成先解析);
 *  - 定死才能保证两端逐字一致 —— 跟随语言的话,同一集在两台机器上显示不同,
 *    对不了版也不好排查;
 *  - 时区按本机(用 `new Date(ms)` 的本地取值,不用 `toISOString`,那个固定 UTC,见 H24)。
 *
 * 解析不出来时退回原始串截前 16 字符 —— 至少还能看出个大概,比空白好。
 */
export function formatPubDate(raw: string): string {
  const ms = parsePubMillis(raw);
  if (ms === 0) return raw.trim().substring(0, 16);
  const d = new Date(ms);
  const day = d.getDate();
  const dd = day < 10 ? `0${day}` : `${day}`;
  return `${WEEKDAY_NAMES[d.getDay()]}, ${dd} ${MONTH_NAMES[d.getMonth()]} ${d.getFullYear()}`;
}
