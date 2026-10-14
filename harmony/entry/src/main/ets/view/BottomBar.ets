import { Theme, Scheme, Tracking } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { curves } from '@kit.ArkUI';
import { hdsMaterial, HdsTabsFloatingStyle } from '@kit.UIDesignKit';
import { L } from '../util/L';
import { Glyph, Sym } from './Widgets';

/**
 * 底部 tab 栏 —— **系统 `HdsTabs` 的悬浮样式**(`barFloatingStyle`),不再自绘。
 *
 * ## 为什么换(2026-10-14,路线 A)
 *
 * 需求从头到尾是同一条:"按预装华为音乐那个底部条的样式与交互做" —— 悬浮长椭圆 + 磨砂 +
 * 按下有光晕。自绘这条路人走了三轮(玻璃透镜 → 系统 Tabs → 自绘胶囊),每一轮都在**重新发明
 * 系统已经提供的东西**,而最关键的那层**真材质**始终仿不出来:自绘只能拿 `backgroundEffect`
 * (radius/saturation/tint 三个数)去近似,而音乐那条用的是 `systemMaterialEffect`。
 * 列表从它背后滚过去时,这两者读出来的差别就是"糊"与"糊得不像"。
 *
 * `HdsTabs` 在 UIDesign Kit(`@kit.UIDesignKit`)里,`barFloatingStyle` 一项给出:
 * 悬浮胶囊栏、左右边距、距屏底距离、底部渐变遮罩、**系统材质**、**点光源颜色**,
 * 以及和栏同排/同列的 **mini bar**(音乐里那颗"正在播放"的小栏就是它)。
 *
 * ## 前置条件(这不是风格,是硬门槛)
 *
 * `barFloatingStyle` / `HdsTabsMiniBar` / `hdsMaterial` / `HdsBarStyle` 全部是
 * **`@since 6.1.0(23)`**(只有 `HdsTabs` 本体是 6.0.0(20))。所以本工程的
 * `compatibleSdkVersion`/`targetSdkVersion` 从 **6.0.2(22) 提到 6.1.0(23)**
 * (`harmony/build-profile.json5`,该文件不入库)。
 * ⚠️ **代价:6.0.x 的设备装不上这一版**,商店侧"最低支持版本"口径跟着变 —— 这是路线 A
 * 事先认过的取舍,不是装机后才发现的意外。另外 `HdsTabs` 要求 Stage 模型
 * (声明里全部标 `@stagemodelonly`),本工程已是 Stage,无需改动。
 *
 * ## 得到什么、退回什么(照实记,不要以为换系统组件是全赢)
 *
 * - ✅ 真材质、点光源、悬浮几何(侧边距/距底/渐变遮罩)由组件管,不再逐帧自绘;
 * - ✅ mini bar 通道在 → 播放条的收束下一步可以整个交出去(见 `harmony/shelved/README.md`);
 * - ❌ **「按住某一格横向拖到另一格、松手切换」这一交互没有公开入口**。取证两条:
 *   ① `@hms.hds.hdsBaseComponent.d.ets` 里 `HdsTabsAttribute` 的全部属性(vertical/barPosition/
 *     barMode/barWidth/barHeight/animationDuration/onChange/onAnimationStart/divider/barOverlap/
 *     barBackgroundColor/barBackgroundEffect/barBackgroundBlurStyle/barBackgroundStyle/
 *     onContentWillChange/onTabBarClick/blurStrategy/barFloatingStyle/onSelected/onUnselected/
 *     cachedMaxCount)没有一个与"拖动切格"有关;
 *   ② 预置 `HdsComponent.hsp` 解出的 `modules.abc`(处理量 2 471 012 B / 21 185 条串)里,
 *     tab 相关的手势串只有常规 click/longPress,没有拖动或"光晕跟手"的入口。
 *   ⇒ 这一版交互**退回"点按切换"**,光晕是按下时的点光源,不是自绘版那层 1:1 贴手指横走的晕。
 *     若装机后认定拖动切换不可让步,回到 `harmony/shelved/PillTabBar.ets`(恢复步骤在那份文件头部)。
 *
 * ## 保留下来的几何(全是量出来的,不是观感)
 *
 * 取证对象:本机(BRA-AL00,密度 3.25,逻辑宽 374.2vp)预装华为音乐,`hdc uitest dumpLayout` 原始 bounds:
 *
 * | 部位 | 实测 bounds | 换算 |
 * |---|---|---|
 * | TabBar 整条 | `[75,2415][1141,2597]` | 高 **56vp**、左右各收 **23vp** |
 * | 单个 tab 项图标 | `[173,2443][252,2521]` | **24vp** |
 * | 单个 tab 项文案 | `[180,2527][246,2570]` | 行高 13.2 ⇒ 字号 ~10–11fp |
 * | 栏下沿 → 屏底 | `2688-2597 = 91px` | **28vp = 整个手势避让区** |
 * | 展开态播放条 | `[75,2259][1141,2389]` | 高 40vp,与栏之间留 `2415-2389=26px` = **8vp** |
 * | 收束态左槽 | `[75,2415][257,2597]` | **56×56vp** 方槽(那颗回主页按钮) |
 * | 收束态封面 | `[302,2435][445,2578]` | **44vp** |
 *
 * ⚠️ 与 Android 侧**不再追求"同一占屏比例"**(那套换算见 H51 补充、
 * `harmony/shelved/GlassTabBar.ets` 的 `BAR_H` 注释)。这一轮的要求是"向鸿蒙自己的手感对齐",
 * 56vp 就是鸿蒙的口径;Android 的 48dp 玻璃栏**不动**,两端底部外壳从"同比例"改成"同语义"。
 */

/** 栏高。悬浮样式里仍由 `barHeight` 给,系统默认也是 56,显式写出来图个确定。 */
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
/** 收束态:播放条整块落进栏那 56vp —— 2 + 4 + 44 + 6 = 56,封面比展开态大一档。 */
export const MINI_COVER_WIDE: number = 42;
export const MINI_COVER_NARROW: number = 44;
export const MINI_PAD_WIDE: number = 8;
/**
 * 收束态上下 padding **不对称**(装机量出来的):整块 182px 与栏严格等高、顶对齐,
 * 但里面那条 2vp 进度线(实测 7px)把内容往下推了半格,封面中心落在 2510.5,
 * 而栏中心是 2506 —— 低 1.4vp。参照物华为音乐的收束封面中心 2506.5 是正中的。
 * 上 4 / 下 6 把进度线那 2vp 补回来,封面中心 = 2 + 4 + 22 = 28vp = 栏中心。
 */
export const MINI_PAD_NARROW_TOP: number = 4;
export const MINI_PAD_NARROW_BOTTOM: number = 6;
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
 * 悬浮栏到屏幕左右各收多少(参考片实测 `75px / 3.25 = 23.1vp`)。
 *
 * 悬浮感全靠这两道缝。写在这里而不是散在 Index 里:`barSideMargin` 与页面内容的左右边距
 * 是**两回事**,只有这一处定义"栏缩进多少",装机要调宽度时才只有一个地方可改。
 */
export const BAR_SIDE_MARGIN: number = 23;

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
 * 数值取自本项目已装机认可的那档分段条胶囊(`Components.springTo` 用 0.45/0.95 是"跟页滑动",
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
 * 自绘那版这个式子成立,悬浮样式下同样成立,因为判据本来就是"栏底到屏底 = 整个避让区"
 * (那一截现在由 `barBottomMargin` 给,见 [barFloating])。
 *
 * **两处共用这一条**:播放条的落点([Index.miniBottom])、以及页面滚动内容让出的底部余量
 * ([barReserve])。收小留白时最容易漏后一处,漏了列表末尾多出一条空白(或者末项被栏压住)。
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
 * 悬浮栏的样式对象。
 *
 * **每次 build 现算**:`barBottomMargin` 取的是窗口避让区(`bottomInset`),旋转、进出全面屏
 * 都会变,做成一次性常量就会在某个姿态下贴住小白条。
 *
 * 只给四个量,其余一律留系统默认:
 * - `barSideMargin` / `barBottomMargin` —— 上面那张实测表里的 23vp / 整个避让区;
 * - `barWidth` 三档全给**同一个数值** = 窗口宽 − 2×23vp —— **这条是装机加回来的**:
 *   只给 `barSideMargin` 时栏会**按内容收缩并居中**(本机实测 pill
 *   `TabBar [224,2415][992,2597]`,左右各空出 69vp),而参照物是通栏减 23vp
 *   (`[75,2415][1141,2597]`)。也就是说 `barSideMargin` 只是**最小边距**(内容撑不满时
 *   用它),不是"栏宽 = 屏宽 − 2×它";宽度得自己说。
 *   ⚠️ **但不要给 `'100%'`**(第一版就是这么写的,装机否掉):百分比按**窗口宽**算,
 *   于是节点变成 `[0,2415][1216,2597]` —— 那 23vp 的侧边距被顶没了,胶囊铺到屏幕两侧,
 *   读起来就是"栏出头了"。**宽度是绝对量,侧边距才留白。**
 *   三档都要给:`HdsBarWidthRangeOptions` 按 tabs 宽度分档(小 <440vp / 中 440–600 / 大 >840),
 *   手机吃 `smallWidth`,但折叠屏与平板会落到另两档 —— 漏一档就是那一档上又变回收缩胶囊。
 *   三档同一个值不会错:`windowWidthVp` 本来就是**当前窗口**的宽,不管落在哪一档,
 *   "窗口宽减两侧留白"都是那一档上正确的宽度。
 * - `systemMaterialEffect.materialType` —— 由调用方传进来(见 [pickMaterialType]),
 *   因为**探测要做一次、不能每帧做**,而这一项直接决定栏是"有材质"还是"透明的";
 * - `gradientMask` / `miniBar` / `lightColor` / `adaptToHandedness` / `thermoCtrl`
 *   / `barOpacity` **先不动**。它们都有系统默认值,而默认值就是华为音乐自己那套参数。
 *   装机若读不出悬浮感,**一条一条加** —— 一次全开就不知道是哪一项起了作用。
 */
export function barFloating(inset: number, windowWidthVp: number,
  materialType: hdsMaterial.MaterialType): HdsTabsFloatingStyle {
  const style: HdsTabsFloatingStyle = {
    barSideMargin: BAR_SIDE_MARGIN,
    barBottomMargin: inset,
    systemMaterialEffect: {
      materialType: materialType,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    }
  };
  // 窗口宽和避让区是同一次异步读取带回来的,启动首帧还是 0。这时宁可不给 `barWidth`
  // (退回"按内容收缩"那一档),也不能给 0 或负值 —— 后者在启动那一瞬把栏压成一条线。
  if (windowWidthVp > 2 * BAR_SIDE_MARGIN) {
    const pillWidth = windowWidthVp - 2 * BAR_SIDE_MARGIN;
    style.barWidth = { smallWidth: pillWidth, mediumWidth: pillWidth, largeWidth: pillWidth };
  }
  return style;
}

/**
 * 材质档位必须**运行时探测**,不能照参考设备上的那个值写死。
 *
 * `hdsMaterial.getSystemMaterialTypes()` 返回本机支持的档位。支持 IMMERSIVE 就用它
 * (华为音乐那条就是这一档:材质会随背后内容动,自绘那版最仿不出来的就是这一层);
 * 不支持就退 ADAPTIVE 让系统自己挑。**直接写 IMMERSIVE 的后果不是"效果差一点"而是
 * 整条栏透明** —— 官方示例专门点过这条,而透明栏在浅色列表上读起来像"栏没了"。
 *
 * 这一句在 `Index` 的字段初始化里跑一次(冷启动一次),不在 build 里。
 */
export function pickMaterialType(): hdsMaterial.MaterialType {
  const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
  return types.indexOf(hdsMaterial.MaterialType.IMMERSIVE) >= 0
    ? hdsMaterial.MaterialType.IMMERSIVE
    : hdsMaterial.MaterialType.ADAPTIVE;
}

/**
 * 一个 tab 项:图标 + 文案。
 *
 * **为什么栏形状交给系统、内容却还是我们自己画的这一项**:`HdsTabs` 的默认栏项
 * (`BottomTabBarStyle` + `TabBarSymbol`)用的是**系统主题色**,而本 App 有自绘的强调色选择器
 * (`settings.accentIndex`)和"跟随系统之外"的手动深浅档。用系统项就等于把这两项设置丢掉 ——
 * 所以形状(悬浮胶囊、材质、光晕)交给系统,格子里的颜色与字号仍归我们的 `Scheme`。
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
 *
 * ⚠️ 这一颗**暂时仍是我们自己的**(随播放条叠在系统栏之上,见 Index 的 Stack)。`HdsTabs` 的
 * `miniBar`(`miniBarBuilder` + `applyMiniBarStyle`)正是为它准备的宿主 —— 和栏同一行、
 * 宽度随收束动画自己走。那是换完悬浮栏之后的**下一步**,不在这一轮:一次只换一个变量,
 * 否则装机读不出"抖"来自哪一侧。
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
