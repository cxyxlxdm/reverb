/// 主题体系:与 Android `ui/theme/Theme.kt`、macOS `UI/Theme.swift` 对齐。
/// 4 组强调色 × 3 套底色(水墨深色 / 宣纸浅色 / 纯白),底色用强调色低比例 lerp 混色,
/// 使背景随配色微妙变化。ArkTS 无 Compose 的 LocalDensity,字号缩放改为 4 档 token 表。

/// 一组配色方案。primaryDark 用于深色,primaryLight 用于浅色;secondary 为「梁金」。
export interface AccentPalette {
  label: string;
  primaryDark: string;
  primaryLight: string;
  secondary: string;
}

/// 一套完整的界面色板(对齐 Material3 ColorScheme 里本项目实际用到的槽位)。
export interface Scheme {
  primary: string;
  onPrimary: string;
  secondary: string;
  onSecondary: string;
  background: string;
  onBackground: string;
  surface: string;
  onSurface: string;
  surfaceVariant: string;
  onSurfaceVariant: string;
  outline: string;
  /// 危险操作色(清除下载/清空历史的确认按钮)。Android 侧直接用 Material 默认的
  /// `colorScheme.error`,鸿蒙的 Scheme 是自建的,故取 Material 3 同值以保持一致。
  error: string;
  isDark: boolean;
}

const GOLD = '#E9C879';

export const ACCENTS: AccentPalette[] = [
  { label: '青瓷', primaryDark: '#7FD1C0', primaryLight: '#3E8E7E', secondary: GOLD },
  { label: '黛蓝', primaryDark: '#86B9E0', primaryLight: '#2E6E99', secondary: GOLD },
  { label: '绯红', primaryDark: '#E3A0A0', primaryLight: '#B0524F', secondary: GOLD },
  { label: '竹青', primaryDark: '#9FD08A', primaryLight: '#4E8E43', secondary: GOLD }
];

// 深色「水墨」底色
const INK_BG = '#0E1416';
const INK_SURFACE = '#161D20';
const INK_SURFACE_HI = '#1F2A2E';
// 浅色「宣纸」底色
const PAPER_BG = '#F6F2E9';
const PAPER_SURFACE = '#FCFAF4';
const PAPER_SURFACE_HI = '#ECE6D8';

/// #RRGGBB 混色。t=0 取 a,t=1 取 b。用于"底色掺一点强调色"。
export function lerpColor(a: string, b: string, t: number): string {
  const ca = parseHex(a);
  const cb = parseHex(b);
  const r = Math.round(ca[0] + (cb[0] - ca[0]) * t);
  const g = Math.round(ca[1] + (cb[1] - ca[1]) * t);
  const bl = Math.round(ca[2] + (cb[2] - ca[2]) * t);
  return `#${hex2(r)}${hex2(g)}${hex2(bl)}`;
}

function parseHex(s: string): number[] {
  const h = s.startsWith('#') ? s.substring(1) : s;
  const off = h.length === 8 ? 2 : 0;   // 容忍 #AARRGGBB
  return [
    parseInt(h.substring(off, off + 2), 16),
    parseInt(h.substring(off + 2, off + 4), 16),
    parseInt(h.substring(off + 4, off + 6), 16)
  ];
}

function hex2(v: number): string {
  const c = Math.max(0, Math.min(255, v));
  const s = c.toString(16);
  return s.length === 1 ? `0${s}` : s;
}

/// 带透明度的颜色(ArkUI 接受 #AARRGGBB)。alpha 0~1。
export function withAlpha(color: string, alpha: number): string {
  const a = Math.round(Math.max(0, Math.min(1, alpha)) * 255);
  const c = parseHex(color);
  return `#${hex2(a)}${hex2(c[0])}${hex2(c[1])}${hex2(c[2])}`;
}

function darkScheme(a: AccentPalette): Scheme {
  return {
    primary: a.primaryDark,
    onPrimary: '#06201B',
    secondary: a.secondary,
    onSecondary: '#2A2100',
    background: lerpColor(INK_BG, a.primaryDark, 0.05),
    onBackground: '#EAF0EF',
    surface: lerpColor(INK_SURFACE, a.primaryDark, 0.06),
    onSurface: '#EAF0EF',
    surfaceVariant: lerpColor(INK_SURFACE_HI, a.primaryDark, 0.12),
    onSurfaceVariant: '#95A3A0',
    outline: lerpColor('#33413F', a.primaryDark, 0.15),
    error: '#F2B8B5',
    isDark: true
  };
}

function lightScheme(a: AccentPalette): Scheme {
  return {
    primary: a.primaryLight,
    onPrimary: '#FFFFFF',
    secondary: '#9A7A2E',
    onSecondary: '#FFFFFF',
    background: lerpColor(PAPER_BG, a.primaryLight, 0.05),
    onBackground: '#221C12',
    surface: lerpColor(PAPER_SURFACE, a.primaryLight, 0.04),
    onSurface: '#221C12',
    surfaceVariant: lerpColor(PAPER_SURFACE_HI, a.primaryLight, 0.12),
    onSurfaceVariant: '#6B6255',
    outline: lerpColor('#CFC6B4', a.primaryLight, 0.2),
    error: '#B3261E',
    isDark: false
  };
}

/// 纯白:白底 + 冷灰中性色,刻意区别于暖调「宣纸」。
function whiteScheme(a: AccentPalette): Scheme {
  return {
    primary: a.primaryLight,
    onPrimary: '#FFFFFF',
    secondary: '#9A7A2E',
    onSecondary: '#FFFFFF',
    background: '#FFFFFF',
    onBackground: '#1A1C1E',
    surface: '#FFFFFF',
    onSurface: '#1A1C1E',
    surfaceVariant: '#EEF1F3',
    onSurfaceVariant: '#5A6169',
    outline: '#D5DADE',
    error: '#B3261E',
    isDark: false
  };
}

/// 字号档:与 Android 的 4 档倍率对齐(0.9 / 1.0 / 1.15 / 1.3)。
export const FONT_SCALES: number[] = [0.9, 1.0, 1.15, 1.3];

/**
 * 排版尺度基准(fp)。实际使用时乘以当前字号倍率。
 *
 * **数值与 Android 侧实际用的 Material 3 尺度逐项对齐。**
 * ⚠️ 但**理由不是**"fp 与 sp 都是 160dpi 归一、同数值即同物理大小" —— 那句是错的,
 * 已撤回(见 H51 的补充与 H122):本机 density 3.25、逻辑宽 374.2vp、面板 ≈70mm,
 * **1vp ≈ 1.18 个标准 dp**,所以同数值在鸿蒙物理上大约 18%。这张表之所以取等值,
 * 是按**占屏比例**量出来的结论(下面那组实测数字就是它),不是单位换算的推论。
 * 原先这张表逐项比 Android 大 1~2fp,叠上鸿蒙这台机器逻辑宽度
 * 更窄(约 364vp,Android 那台 424dp),结果同一行能放的字数少一截 —— 处处换行、行行发胖。
 * 实测过:改之前单集标题字高占屏宽 3.95%,Android 是 3.38%,**大 17%**,
 * 一屏比 Android 少放三四行。改这张表是最省事也最彻底的一处。
 *
 * **另一类东西不在这张表里,而且判据相反**:栏高 / 图标 / 内边距 / 分段条是**外壳**,
 * 要按 374.2/427.6 = **0.876** 换算而不是等值照抄(底部 tab 栏与分类条已按此收小,
 * 换算过程与真机复量见 `GlassTabBar.BAR_H`、`CHIPS_STRIP_H` 与 H122)。
 * 唯一跟着外壳收的字号是 tab 标签(11→10fp),因为它只有两个字、是栏的一部分。
 *
 * 右侧注释是对应的 Material 3 名称,以后两端调字号要一起动。
 */
export class TypeScale {
  static readonly displaySmall = 32;      // displaySmall
  static readonly headlineMedium = 24;    // headlineSmall(两端页头都用这个)
  static readonly titleLarge = 22;        // titleLarge
  static readonly titleMedium = 16;       // titleMedium
  static readonly titleSmall = 14;        // titleSmall
  static readonly body = 14;              // bodyMedium
  /// 比 body 大一号,用于**整页密排长文**(目前只有隐私同意页)。
  /// 与 Android 那边 bodyMedium → bodyLarge 的同一处调整对应:长文用正文号读着费劲。
  /// 列表里的正文不要改用它 —— 那会把行高撑乱。
  static readonly bodyLarge = 16;         // bodyLarge
  /// **溢出菜单项用它**(Android 的 DropdownMenuItem 同取 labelLarge,两端就此对齐)。
  /// ⚠️ 分类 chip 原先也用它,2026-09-29 起改用自己的档
  /// (`Components.CHIP_LABEL_FP` = 12)—— 外壳按占屏比例收小之后,字不能还留在等值那一档。
  static readonly labelLarge = 14;        // labelLarge
  static readonly label = 12;             // labelMedium
  static readonly caption = 11;           // labelSmall
}

/**
 * 字距(letterSpacing,单位 fp)。**这一张表原先根本不存在,是"鸿蒙看起来拥挤"的直接原因。**
 *
 * Material 3 的字号表里每一档都自带 letterSpacing,Compose 用 `MaterialTheme.typography`
 * 时会一并生效 —— 所以 Android 侧的正文天然带 0.25~0.5sp 的字距。
 * ArkUI 的 `Text` 默认字距是 **0**,只搬了字号没搬字距,于是同一句话在鸿蒙上字挨着字,
 * 密排的列表尤其显挤。
 *
 * 数值取 Material 3 各档的原值。用法:`.letterSpacing(Tracking.body)`,
 * **不要乘 fontScale** —— Compose 那边 letterSpacing 用 sp 也随字号倍率缩放,
 * 但字距按比例放大会在大字号档下散架,这里按固定值处理更稳(实测大字号档下观感更好)。
 */
export class Tracking {
  static readonly display = 0;
  static readonly headline = 0;
  static readonly titleLarge = 0;
  static readonly titleMedium = 0.15;
  static readonly titleSmall = 0.1;
  static readonly bodyLarge = 0.5;
  static readonly body = 0.25;
  static readonly label = 0.5;
  static readonly caption = 0.5;
}

/**
 * 行高倍率。Material 3 每档也带 lineHeight(如 bodyLarge 16/24 = 1.5、bodyMedium 14/20 ≈ 1.43),
 * ArkUI 不给就用字体自带的紧凑行距 —— 两行标题挤在一起也是"拥挤"的一部分。
 * 用法:`.lineHeight(TypeScale.body * fontScale * LineHeight.body)`。
 */
export class LineHeight {
  static readonly body = 1.43;
  static readonly bodyLarge = 1.5;
  static readonly label = 1.33;
}

export class Theme {
  /**
   * AppStorage 键:设备此刻是否深色。
   * **写**在 EntryAbility(启动种一次 + `onConfigurationUpdate` 里跟着系统翻),
   * **读**在外壳的 `@StorageLink`(设置选「跟随系统」时主题取它)。
   * 为什么不干脆让外壳自己 `context.config.colorMode` 读一次:那只是**启动快照**。
   * 应用运行期间系统切深浅(手动切或定时日落日出)没人再去读它,于是「跟随系统」
   * 这一档要重进应用才生效 —— 市场审核就是照这条报的,见 TROUBLESHOOTING H126。
   */
  static readonly SYSTEM_DARK_KEY: string = 'systemDark';

  /// mode:0 跟随系统 / 1 浅色(宣纸)/ 2 深色(水墨)/ 3 纯白。
  /// systemDark 由调用方传入(来自设备深色模式)。
  static scheme(mode: number, accentIndex: number, systemDark: boolean): Scheme {
    const a = Theme.accent(accentIndex);
    if (mode === 3) return whiteScheme(a);
    if (mode === 1) return lightScheme(a);
    if (mode === 2) return darkScheme(a);
    return systemDark ? darkScheme(a) : lightScheme(a);
  }

  static accent(index: number): AccentPalette {
    const i = Math.max(0, Math.min(ACCENTS.length - 1, index));
    return ACCENTS[i];
  }

  static fontScale(index: number): number {
    const i = Math.max(0, Math.min(FONT_SCALES.length - 1, index));
    return FONT_SCALES[i];
  }
}

/// 统一的间距 / 版心尺度(对齐 macOS Metrics 与 Android 的 padding 习惯)。
export class Metrics {
  static readonly pagePadding = 16;
  static readonly topPadding = 12;
  static readonly sectionSpacing = 20;
  static readonly rowSpacing = 12;
  static readonly gridSpacing = 12;
  static readonly cardCorner = 14;
}
