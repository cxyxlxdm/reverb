import { Theme, Scheme, Tracking } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { curves } from '@kit.ArkUI';
import { L } from '../util/L';
import { Glyph, Sym } from './Widgets';

/**
 * 底部 tab 栏 —— **用系统 `Tabs` 自带的栏**,不再自绘。
 *
 * 自绘那版(玻璃透镜 + canvas 折射,`view/GlassTabBar.ets`)整个退役进
 * `harmony/shelved/`,恢复步骤见 `harmony/shelved/README.md`。换掉的直接原因是 2026-10-13
 * 两条用户反馈:
 * ① **栏太矮** —— 自绘版 42vp(为对齐 Android 48dp 按占屏比例 ×0.876 换算来的),
 *   而系统默认档与参考对象都是 56vp;
 * ② **太靠下** —— 自绘版只在手势区里留 0.62 倍(`INSET_KEEP`),栏底几乎贴到小白条。
 *
 * 这一版的全部几何参数是**量出来的**,不是凭观感拍的。取证对象是这台机器(BRA-AL00,
 * 密度 3.25,逻辑宽 374.2vp)预装的华为音乐,`hdc uitest dumpLayout` 落的原始 bounds:
 *
 * | 部位 | 实测 bounds | 换算 |
 * |---|---|---|
 * | TabBar 整条 | `[75,2415][1141,2597]` | 高 **56vp** |
 * | 单个 tab 项图标 | `[173,2443][252,2521]` | **24vp** |
 * | 单个 tab 项文案 | `[180,2527][246,2570]` | 行高 13.2 ⇒ 字号 ~10–11fp |
 * | 栏下沿 → 屏底 | `2688-2597 = 91px` | **28vp = 整个手势避让区** |
 * | 展开态播放条 | `[75,2259][1141,2389]` | 高 40vp,与栏之间留 `2415-2389=26px` = **8vp** |
 * | 收束态左槽 | `[75,2415][257,2597]` | **56×56vp** 方槽(那颗回主页按钮) |
 * | 收束态封面 | `[302,2435][445,2578]` | **44vp** |
 *
 * ⚠️ 与自绘版最大的取舍差别:**不再追求"和 Android 同一占屏比例"**。那套换算(见 H51 补充、
 * `harmony/shelved/GlassTabBar.ets` 的 `BAR_H` 注释)的前提是"两端外壳视觉一致";而这一轮的要求恰恰是"用系统组件、
 * 向鸿蒙自己的手感对齐",系统默认 56vp 就是鸿蒙的口径。Android 侧的 48dp 玻璃栏
 * **不动**,两端底部外壳从"同比例"改成"同语义"(都是各端系统惯例高度),这条漂移要记进文档。
 */

/** 栏高。系统 Tabs 在 CustomBuilder 下的默认值也是 56,这里显式写出来图个确定。 */
export const TAB_BAR_H: number = 56;
/** tab 图标边长(参考片实测 24vp;自绘版是 17)。 */
export const TAB_SYMBOL: number = 24;
/** tab 文案字号(fp)。沿用自绘版定过的 10fp —— 那档是按本机物理尺寸对齐 Android 11sp 来的。 */
export const TAB_LABEL_FP: number = 10;

/**
 * 播放条**展开态**整块高度:2(进度线)+ 8 + 42(封面)+ 8 = 60。
 * 与页面底部让位量同源([barReserve]),改这里必须同时看那一处。
 */
export const MINI_H: number = 60;
/** 展开态播放条与栏之间的留白(参考片实测 26px = 8vp)。 */
export const MINI_GAP: number = 8;
/** 收束态:播放条整块落进栏那 56vp —— 2 + 5 + 44 + 5 = 56,封面比展开态大一档。 */
export const MINI_COVER_WIDE: number = 42;
export const MINI_COVER_NARROW: number = 44;
export const MINI_PAD_WIDE: number = 8;
export const MINI_PAD_NARROW: number = 5;
/** 收束态左侧回主页按钮的槽宽(参考片 56×56 方槽)。 */
export const HOME_SLOT: number = 56;
/**
 * 收束态「槽 → 封面」之间那道缝(参考片实测 `302-257 = 45px` = **13.8vp**,取 14)。
 *
 * **为什么不靠外层 `Row({ space: 10 })` 给**:那条 space 会给**零宽**的它也插一道,
 * 于是展开态整条播放条被白右推 10vp(封面左缘从页面边距 14 变成 24,和列表文字对不齐)。
 * 所以这道缝做进槽自己的宽度里 —— 宽度从 0 一路动画到 `HOME_SLOT + HOME_SLOT_GAP`,
 * 只有这一个量参与测量,展开态就是纯粹的"什么都不占"。
 */
export const HOME_SLOT_GAP: number = 14;
/** 回主页按钮里的图标大小(与 tab 图标同档)。 */
export const HOME_SYMBOL: number = 24;

/**
 * 滚动累计多少 vp 翻转收束/展开。
 *
 * 40vp ≈ 手指移动 13mm —— 比"碰一下就收"钝,比"划半屏才收"灵。
 * 关键是**累计量**而不是单次量:一帧的 scrollOffset 只有 1–8vp,按单帧判阈值
 * 要么灵敏到乱翻、要么迟钝到不翻。
 */
export const MORPH_SLOPE: number = 40;

/**
 * morph 弹簧的两组参数(response 秒 / 阻尼)。**展开落点与收束落点共用同一档**,
 * 否则播放条自己缩、Index 把它往上托,两条曲线不同步会看出"散架"。
 * 数值取自本项目已装机认可的那档分段条胶囊(Components.springTo 用 0.45/0.95 是"跟页滑动",
 * 这里要的是"就地收放",response 短一档)。
 */
export const MORPH_RESP: number = 0.34;
export const MORPH_DAMP: number = 0.86;

/**
 * 当前 tab 序号在 AppStorage 里的键。
 *
 * 为什么 tab 序号也要走 AppStorage 而不是 @Prop:栏项是 Tabs 用 CustomBuilder 生成的,
 * 父级的 build 重不重跑、builder 重不重跑都不是我们能掌握的;而"点了第二个 tab 第二个
 * 却不亮"这种症状很容易被误当成"动画没生效"。自己订阅就没有这一层不确定性。
 * 装饰器的参数位置能放常量(`Index.ets` 早就是这么写 `@StorageLink(Theme.SYSTEM_DARK_KEY)`),
 * 所以这里不必退成字面量。
 */
export const TAB_KEY: string = 'curTab';
/** 播放条是否收束进 tab 栏。同一个 AppStorage 通道,理由见 [TAB_KEY]。 */
export const MORPH_KEY: string = 'miniCollapsed';

/// morph 曲线。两个宿主(MiniPlayerBar 内部属性 / Index 里整块的落点)必须调同一个式子。
/// **不配 duration** —— springMotion 的时长由 response 与初速度决定,官方文档明确
/// duration 在这条曲线上不生效(AnimateParam 注 5),写了是骗自己。
export function morphSpring(): curves.ICurve {
  return curves.springMotion(MORPH_RESP, MORPH_DAMP);
}

/**
 * 悬浮层从屏底往上占到多高 = 栏 + 它下面那道手势区留白。
 *
 * 自绘版这里要乘 `INSET_KEEP`(栏压在避让区里),这一版栏**整体抬到手势区上方**
 * (Index 给 Tabs 加了 `padding({bottom: inset})`),所以栏底到屏底恰好是完整的避让区,
 * 式子里不再有系数。
 */
export function barFootprint(inset: number): number {
  return TAB_BAR_H + inset;
}

/**
 * 页面滚动内容要让出的底部余量。
 *
 * ⚠️ **播放条那一段按展开态(最高的那一档)算,与当前收没收束无关。**
 * 收束态整块 56vp 已经落进栏里,让位量本可以少 68vp —— 但那意味着每次翻转都要
 * 重排整条列表(千行 List 的 measure 重新跑一遍),而翻转恰好发生在**滚动中**,
 * 每一帧都可能触发。省下的那 68vp 空白换一次滚动掉帧,不值。
 */
export function barReserve(inset: number, playing: boolean): number {
  return barFootprint(inset) + (playing ? MINI_H + MINI_GAP : 0);
}

/**
 * 一个 tab 项:图标 + 文案。
 *
 * **为什么不直接把样式写进 Index 的 @Builder**:Tabs 的 CustomBuilder 什么时候重跑由框架掌握,
 * 而 @Builder 的按值参数本身不做响应式更新。于是"选中态""收束态"这两个会变的量若从父级
 * 按值传进来,就有**点了不亮 / 收了不淡**的风险(这正是 H26/H27 那一类"看着正常只是被别的
 * 状态顺带刷了"的形状)。所以做成 @Component,并让**会变的量全部自己订阅**:
 * - 选中 → `@StorageProp(TAB_KEY)` 读当前 tab 序号,和静态的 `index` 比;
 * - 收束 → `@StorageProp(MORPH_KEY)`;
 * - 配色/字号 → `@ObjectLink settings` + `@StorageProp(Theme.SYSTEM_DARK_KEY)`,自己现算。
 *
 * 静态量(第几项、文案、两枚图标)才用 @Prop。
 */
@Component
export struct SystemTabItem {
  /** 这一项代表第几个 tab(静态) */
  @Prop index: number;
  @Prop label: Resource;
  /// 未选中(描边)/ 选中(实心)两枚图标
  @Prop icon: Resource;
  @Prop iconFill: Resource;
  /**
   * 有没有实心变体。**没有**(追更那枚 `dot_radiowaves_left_and_right` 在 symbol 表里
   * 不存在 `_fill` 形式)时选中只换色 + 加粗,不要拿别的形状冒充。
   */
  @Prop hasFill: boolean = true;
  /** 外壳的观察对象:配色与字号只能从它现算(@ObjectLink 要求父级以 @State 持有同一个对象) */
  @ObjectLink settings: SettingsStore;
  @StorageProp(Theme.SYSTEM_DARK_KEY) systemDark: boolean = false;
  @StorageProp(TAB_KEY) curTab: number = 0;
  /**
   * 播放条是否收束进栏。收束时整项淡没 —— 淡没不等于消失,布局不许跟着塌,
   * 否则栏会在翻转变矮,播放条落进来的位置跟着抖。
   */
  @StorageProp(MORPH_KEY) collapsed: boolean = false;

  private scheme(): Scheme {
    return Theme.scheme(this.settings.themeMode, this.settings.accentIndex, this.systemDark);
  }

  build() {
    Column({ space: 2 }) {
      Glyph({
        symbol: (this.curTab === this.index && this.hasFill) ? this.iconFill : this.icon,
        dim: TAB_SYMBOL,
        color: this.curTab === this.index ? this.scheme().primary : this.scheme().onSurfaceVariant,
        // 无实心变体的那一枚靠字重区分选中态(见 hasFill 注释)
        bold: this.curTab === this.index && !this.hasFill
      })
      Text(this.label)
        .fontSize(TAB_LABEL_FP * Theme.fontScale(this.settings.fontIndex))
        .letterSpacing(Tracking.caption)
        .fontColor(this.curTab === this.index ? this.scheme().primary : this.scheme().onSurfaceVariant)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    /**
     * `.animation()` 必须挂在**这个**节点上:它吃的是"同一节点上、写在它之前的属性"的变化。
     * 收束标志从 AppStorage 落到这里时只有 opacity 在变,而 opacity 不参与测量,
     * 所以三项同时淡出/淡入不会带动任何重排。
     */
    .opacity(this.collapsed ? 0 : 1)
    .animation({ curve: morphSpring() })
  }
}

/**
 * 收束态左端那颗「回主页」按钮。
 *
 * 展开态它**也要在布局里占位**(宽度动画到 0),不能用 `if` 摘掉:摘掉会让整行内容
 * 一次性左移,而旁边的封面/文字正按弹簧滑过来 —— 两种运动叠在一起就是"抖"。
 * `.clip(true)` 是必需的:宽度 0 时里面那颗 24vp 图标并不自动被裁掉。
 */
@Component
export struct HomeSlot {
  @Prop scheme: Scheme;
  @Prop collapsed: boolean;
  onTap: () => void = () => {};

  build() {
    Row() {
      // 图标只占左端那 56 宽(槽),右边那道缝归封面 —— 所以内层定宽、外层是「槽 + 缝」的总宽
      Row() {
        Glyph({ symbol: Sym.home, dim: HOME_SYMBOL, color: this.scheme.onBackground })
      }
      .width(HOME_SLOT)
      .height('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width(this.collapsed ? HOME_SLOT + HOME_SLOT_GAP : 0)
    /**
     * 高度**只能等于封面那一档**(56 的方槽会把整行顶到 56,容器就从 56 变成 68 ——
     * 参考片那颗是 56×56,但它的行本来就是按 56 排的)。视觉上只要"图标居中 + 左端留出 56 宽"
     * 两条成立就够了。
     */
    .height(this.collapsed ? MINI_COVER_NARROW : 0)
    .justifyContent(FlexAlign.Center)
    .clip(true)
    .opacity(this.collapsed ? 1 : 0)
    .animation({ curve: morphSpring() })
    .accessibilityText(L.s('a11y_home'))
    .onClick(() => this.onTap())
  }
}
