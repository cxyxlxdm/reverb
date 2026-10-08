import i18n from '@ohos.i18n';
import intl from '@ohos.intl';
import { Log } from './Logger';

/**
 * 小数按 locale 分隔符格式化。用于倍速这类要显示小数的地方。
 *
 * **为什么要有这个文件**:Android 侧 `"%.2f".format(x)` 用的是**设备默认 locale**,
 * 而应用内切语言时 `LocaleUtil.wrap()` 会 `Locale.setDefault(locale)`,
 * 于是法/西界面上 1.25 渲染成 `1,25`、整数倍速渲染成 `1,`(那个 dangling 逗号是
 * `trimEnd('0').trimEnd('.')` 没把逗号算进去,已修,见 H160)。**鸿蒙侧原来是裸模板串**,
 * `${1.25}` 永远是点 —— 两端在 fr/es 下同一件事写成两种样子(2026-10-08 真机通读实测)。
 * 这一版把鸿蒙对齐过去,而不是把 Android 改回点:非整数倍速在法/西里本来就该带逗号。
 *
 * **实例必须缓存**:构造 `intl.NumberFormat` 要走 i18n,而调用点在播放页 ——
 * 播放中约 500ms 一次 tick 就会重跑一遍 `build()`(硬规矩 6)。所以按语言 tag 缓存实例,
 * tag 不变就复用;语言在设置页切过之后 tag 变,才重建一次。
 */
// 类型名以本端 SDK 为准:`@ohos.intl.d.ts` 里构造函数收的是 **`NumberOptions`**
// (`NumberFormatOptions` 这个名字在本端不存在,2026-10-08 对着 d.ts 逐行核过)。
const DECIMAL_OPTS: intl.NumberOptions = {
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
  useGrouping: false
};

let cachedTag: string = '';
let cachedFmt: intl.NumberFormat | null = null;

function currentTag(): string {
  // 应用内覆盖优先('' 表示跟随系统),与 L.ets 取串走的是同一套语言口径
  try {
    const pref = i18n.System.getAppPreferredLanguage();
    if (pref.length > 0) return pref;
  } catch (e) {
    Log.w('NumberFmt', `getAppPreferredLanguage 失败,回落系统 locale`);
  }
  try {
    return i18n.System.getSystemLocaleInstance().toString();
  } catch (e) {
    return 'en';
  }
}

function formatter(): intl.NumberFormat | null {
  const tag = currentTag();
  if (cachedFmt !== null && tag === cachedTag) return cachedFmt;
  try {
    // 本端 SDK 的 `@ohos.intl.d.ts` 里 NumberFormat **只有构造函数**,
    // 没有 Android `NumberFormat.getInstance` 那个静态工厂(2026-10-08 对着 d.ts 核过)。
    cachedFmt = new intl.NumberFormat(tag, DECIMAL_OPTS);
    cachedTag = tag;
    return cachedFmt;
  } catch (e) {
    Log.w('NumberFmt', `构造 NumberFormat(${tag}) 失败,本次按原样出串`);
    return null;
  }
}

/**
 * 最多两位小数、整数不带小数点(0.8 → `0,8`;2.0 → `2`)。
 * 与 Android 的 `"%.2f".format(v).trimEnd('0').trimEnd('.', ',')` 同结果。
 * 拿不到格式化器时回落 `${v}` —— 宁可分隔符不对,也不让界面上出现空串。
 */
export function formatDecimal(v: number): string {
  const fmt = formatter();
  if (fmt === null) return `${v}`;
  try {
    return fmt.format(v);
  } catch (e) {
    Log.w('NumberFmt', `format(${v}) 失败,按原样出串`);
    return `${v}`;
  }
}
