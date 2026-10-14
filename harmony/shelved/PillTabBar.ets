import { Theme, Scheme, Tracking, withAlpha } from '../theme/Theme';
import { SettingsStore } from '../store/SettingsStore';
import { curves } from '@kit.ArkUI';
import { Glyph } from './Widgets';
import {
  TAB_BAR_H, TAB_SYMBOL, TAB_LABEL_FP, TAB_KEY, MORPH_KEY, morphSpring, barFootprint
} from './BottomBar';

/**
 * 悬浮长椭圆**自绘**胶囊栏(2026-10-14 那一版),挂在 `harmony/shelved/`,**不参与编译**。
 *
 * 退役原因不是它做得不像,而是同一天查证到**系统本来就内置这套设计**:
 * `@kit.UIDesignKit` 的 `HdsTabs` + `.barFloatingStyle()`(悬浮胶囊 + 按压光效 `lightColor`
 * + 系统材质 `systemMaterialEffect` + 底部渐隐 `gradientMask` + 可收束的 `miniBar`)。
 * 判据与口径写回 `view/BottomBar.ets` 的表头。
 *
 * 留这一份的意义:它是**唯一一份把"长按拖动切换 + 光晕 1:1 跟手 + 亮核滞后"这三条
 * 全部自己做出来并过编译的实现**。而这三条在 HDS 的 d.ts/d.ets 里**没有任何对应入口**
 * (系统只给 `onTabBarClick` 点击切换与内容横滑翻页)。所以如果复核后要求"必须能拽着切",
 * 复原步骤就是把这一层的 `Core/Glow/Content` 三层再叠回系统栏之上,或者整块换回来。
 *
 * ## 复原步骤
 *
 * 1. 把本文件移回 `entry/src/main/ets/view/`;
 * 2. `pages/Index.ets`:三个 `TabContent` 上的 `.tabBar(this.slotX())` 摘掉,
 *    `HdsTabs` 的 `.barOverlap/.barBackgroundBlurStyle/.barFloatingStyle(...)` 摘掉,
 *    `.barHeight(0)` 装回来,并在 Stack 的悬浮层放回 `PillTabBar({...})`;
 * 3. 父级要重新准备 `tabSpecs: TabSpec[]`(本组件按槽数均分算落点,见 [slotCx]);
 * 4. ⚠️ 宿主 `Column` 的 `.padding({ bottom: bottomInset })` **不能留**:栏要浮在避让区上方,
 *    而内容必须铺到屏底,列表才滚得到胶囊背后(磨砂有东西可糊)。这一版的总高由
 *    [barFootprint] 自己算 = 栏高 + inset;
 * 5. `MiniPlayerBar.ets`:收束态底色保持全透 —— 这一版透的是本文件的 `backgroundEffect`。
 */

/** tab 项规格(静态:文案 + 两枚图标)。会变的量一律由组件自己订阅,不从外面按值传。 */
export interface TabSpec {
  label: Resource;
  icon: Resource;
  iconFill: Resource;
  /// 追更那枚在 symbol 表里没有 `_fill` 变体,选中态只能靠"换色 + 加粗"表达
  hasFill: boolean;
}

/**
 * 悬浮长椭圆栏的一档参数。**几何部分仍是量出来的**(华为音乐,表见 `view/BottomBar.ets` 表头),
 * 光晕那几档是"先给一个能调的起点",装机再校。
 */
/** 栏到屏幕左右:悬浮感全靠这两道缝(参考片实测 75px = 23vp)。 */
const SIDE_PAD: number = 23;
/**
 * 按下时整条栏的放大倍率。口径沿用自绘玻璃版(需求是"按住时整个底部 tab 长大",
 * 不只是被按的那格);倍率比玻璃版小一档,因为这里放大的是一整块磨砂,
 * 倍率大了会把材质自身的像素一起撑开。
 */
const BAR_PRESS: number = 1.04;
/** 光晕宽(约一格槽宽 + 两侧溢出)。高度不单独定,恒等于栏高 —— 晕是"横着的一道亮"。 */
const GLOW_W: number = 132;
/** 光晕峰值亮度(中心那一档的白 alpha)。 */
const GLOW_A: number = 0.30;
/** 光晕里那颗跟着走的"实心核":比晕小、比栏扁,带一圈亮边,读作"正在被吸住的这一格"。 */
const CORE_W: number = 78;
const CORE_H: number = 40;
const CORE_A: number = 0.16;
const CORE_RIM: number = 0.42;
/**
 * 核的跟随弹簧(response 秒 / 阻尼)。**故意比晕慢一档**:晕 1:1 贴手指、核拖半拍,
 * 两者之差就是"黏"的读感。参考片里被拖动的正是这一层亮边,而图标一动不动。
 *
 * ⚠️ 这里用 `.animation()` 而不是自绘版那套 JS 弹簧(`GlassSpring`):JS 积分是为了
 * 让 canvas 每一帧知道玻璃"现在多大"。这一版不折射、不截背景,只需要"位置有个滞后",
 * 把逐帧写进带 springMotion 的节点就够了 —— 少一个 postFrameCallback、少一份逐帧重绘。
 */
const RESP_TRAIL: number = 0.5;
const DAMP_TRAIL: number = 0.78;

/**
 * 底部栏:**悬浮长椭圆 + 按住拖动切换 + 光晕跟随**。
 *
 * 形态要求(2026-10-14,对着华为音乐录屏逐帧看定的):
 * ① 栏是**浮在页面上的长椭圆胶囊**,两侧留缝、整块磨砂,列表内容从它背后滚过去;
 * ② **按住某一格 → 横向拖动 → 松手切到拖到的那一格**;纯点按也切(按下不拖就是点);
 * ③ 按住时**光晕跟着手指走**(1:1),拖动过程中**选中色不变**,松手才落到新格;
 * ④ 静止时**没有任何选中底** —— 选中只由"图标/文案换主色"表达。
 *    (自绘玻璃版那颗常驻浅灰药丸不是这个样式,所以这里没有 RestPill 这一层。)
 *
 * **三层 z 序(从下到上):核 → 内容 → 晕。**
 * 晕压在图标**之上**是刻意的:参考片里被光晕盖住的图标确实是被洗白、看不清的;
 * 核压在图标**之下**,所以它是"这一格底下一块亮",不会糊掉图标。
 * 自绘版当年反过来(玻璃在内容之下)是因为它要折射"栏背后那行列表",
 * 而折射会把 16vp 的图标糊成一团 —— 这一版不折射,洗白本身就是要的观感。
 *
 * **拖动实现**:`onTouch` 管按下/松手(给出按下那一下的落点与提交),
 * `PanGesture({direction: Horizontal, distance: 5})` 管拖动位移。
 * 两套并存是自绘版装机验证过的形状:只用 onTouch 会被子节点抢事件,
 * 只用 PanGesture 则"按下那一下"没有起点。提交在两处都做,以 `dragging` 判重,幂等。
 *
 * ⚠️ 与自绘版一致的**性能口径**(硬规矩 7):`glowX/ringX/press` 全是本组件的 @State,
 * 拖动帧只重跑这条栏的 build,不动页面。晕的位置**每帧直接赋值、不挂 `.animation()`**
 * (挂了它就不跟手了);需要滞后的那一层(核)才吃弹簧,所以两者分节点写。
 *
 * ⚠️ 整块 `.clip(true)`:晕比栏窄但中心可以走到栏端,不裁就会露出一截到胶囊外。
 * 裁剪走节点自己的 `borderRadius` + `clip`,**不用 `clipShape`**(H96:带 clipShape 的
 * 子节点会被单独合成,`backgroundEffect` 在那一圈重算,结果不是磨砂而是一圈提亮)。
 */
@Component
export struct PillTabBar {
  /** 底部手势避让区(vp)。栏浮在它**上方**,所以组件总高 = 栏高 + inset(见 [barFootprint]) */
  @Prop inset: number;
  /** 三项的静态规格:文案 + 描边/实心两枚图标 + 有没有实心变体 */
  @Prop items: TabSpec[];
  /** 松手/点按提交:由父级改当前 tab,选中色经 [curTab] 自己订阅回来 */
  onSelect: (i: number) => void = () => {};

  /// 外壳的观察对象:配色与字号只能从它现算(@ObjectLink 要求父级以 @State 持有同一个对象)
  @ObjectLink settings: SettingsStore;
  @StorageProp(Theme.SYSTEM_DARK_KEY) systemDark: boolean = false;
  /**
   * 当前 tab 走 AppStorage 而不是 @Prop:和系统栏那版同一个理由(见 [TAB_KEY]),
   * 而现在栏根本不再由 Tabs 生成,但"提交后不亮"这类症状不该靠父级 build 有没有重跑来兜。
   */
  @StorageProp(TAB_KEY) curTab: number = 0;
  /** 播放条收束时三格内容淡没(淡没不等于消失,布局不许塌,否则播放条落点跟着抖) */
  @StorageProp(MORPH_KEY) collapsed: boolean = false;

  /// 栏实测宽度(vp)。`aboutToAppear` 时还是 0,所以光晕/核在量到之前一律不画。
  @State private barW: number = 0;
  /// 光晕中心 x(栏局部坐标)。拖动期间 1:1 跟手指,逐帧赋值。
  @State private glowX: number = 0;
  /// 亮核中心 x。写值和晕同一个数,但这一层吃弹簧 → 视觉上慢半拍。
  @State private ringX: number = 0;
  /// 手指是否按着(= 光晕在不在)。按下为 true,松手/系统取消为 false。
  @State private press: boolean = false;
  /// 按下点,拖动以它为起点算位移(PanGesture 的 offsetX 是相对手势起点的累计量)
  private startGlowX: number = 0;
  private dragging: boolean = false;

  private scheme(): Scheme {
    return Theme.scheme(this.settings.themeMode, this.settings.accentIndex, this.systemDark);
  }

  /** 第 i 格的中心 x:内容行是 layoutWeight 均分的,所以中心就是等分位。 */
  private slotCx(i: number): number {
    const n: number = Math.max(1, this.items.length);
    return this.barW * (i + 0.5) / n;
  }

  /** 最近的一格(提交用)。中线均分,所以取整即最近。 */
  private nearestSlot(x: number): number {
    const n: number = Math.max(1, this.items.length);
    const i: number = Math.floor(x / (this.barW / n));
    return Math.max(0, Math.min(n - 1, i));
  }

  /**
   * 把落点收在**首末两格中心**之间:晕可以溢出栏的两端(会被 clip 掉),
   * 但不会停在"谁都不属于"的位置 —— 参考片里拖到端点就是顶到那颗 tab 上。
   */
  private clampX(x: number): number {
    const n: number = Math.max(1, this.items.length);
    return Math.max(this.slotCx(0), Math.min(this.slotCx(n - 1), x));
  }

  private glowLeft(): number {
    return this.glowX - GLOW_W / 2;
  }

  private ringLeft(): number {
    return this.ringX - CORE_W / 2;
  }

  /**
   * 按下那一下整条栏放大。写成方法而不是配 `.animation()`,是因为**同一个节点上
   * 动画会连 position 一起吃** —— 这一层没有 position,但把量集中在一个弹簧曲线上更好调。
   */
  private barScale(): number {
    return this.press ? BAR_PRESS : 1.0;
  }

  /**
   * 深色模式的"受光量"系数。白晕压在墨底上是**真的会刺眼**(自绘版装机量过:同一档白
   * 在深色下读成一圈硬白线),所以整层光晕按 0.55 收一档,而不是另起一组深色常量。
   */
  private lightK(): number {
    return this.systemDark ? 0.55 : 1.0;
  }

  /// 按下/松手/取消。拖动本身走 PanGesture,这里只负责"存在"与纯点按的提交。
  private onTouchEdge(e: TouchEvent): void {
    if (this.collapsed) return;
    if (e.type === TouchType.Down) {
      // 首次量宽之前 barW 还是 0,此时 slotCx/clampX 算不出落点 → 只记按下,晕等 onAreaChange
      this.press = true;
      const x: number = e.touches[0].x;
      this.startGlowX = this.clampX(x);
      this.glowX = this.startGlowX;
      this.ringX = this.startGlowX;
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      this.press = false;
      // 纯点按在这里提交;拖动的提交在 onActionEnd。以 dragging 判重,两处都写不会切两次。
      if (!this.dragging) {
        const idx: number = this.nearestSlot(this.glowX);
        if (idx !== this.curTab) this.onSelect(idx);
      }
    }
  }

  /// 松手吸附:提交目标格(onSelect 之后 curTab 变,选中色自己跟着变,这一层不再动颜色)
  private settle(): void {
    this.dragging = false;
    const idx: number = this.nearestSlot(this.glowX);
    if (idx !== this.curTab) this.onSelect(idx);
  }

  /// 光晕那一道横亮带:中心最亮、两侧平滑到 0。高度恒等于栏高,上下由 clip 收边。
  @Builder
  Glow() {
    Row()
      .width(GLOW_W)
      .height(TAB_BAR_H)
      .linearGradient({
        angle: 90,
        colors: [[withAlpha('#FFFFFF', 0), 0.0],
                 [withAlpha('#FFFFFF', GLOW_A * this.lightK()), 0.5],
                 [withAlpha('#FFFFFF', 0), 1.0]]
      })
      /**
       * 只在**这个**节点上淡入淡出:它没有 position,`.animation()` 管不到跟手的那条边。
       * 位置由外层容器承担(见 build 里那句"位置不吃动画")。
       */
      .opacity(this.press ? 1 : 0)
      .animation({ curve: morphSpring() })
  }

  /// 亮核:跟着走但慢半拍的那一层。弹簧挂在**有 position 的节点**上,才拖得出滞后。
  @Builder
  Core() {
    Row()
      .width(CORE_W)
      .height(CORE_H)
      .borderRadius(CORE_H / 2)
      .backgroundColor(withAlpha('#FFFFFF', CORE_A * this.lightK()))
      .border({ width: 1, color: withAlpha('#FFFFFF', CORE_RIM * this.lightK()) })
      .position({ x: this.ringLeft(), y: (TAB_BAR_H - CORE_H) / 2 })
      .opacity(this.press ? 1 : 0)
      .animation({ curve: curves.springMotion(RESP_TRAIL, DAMP_TRAIL) })
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 三格内容。**永远静止、永远无形变**(图标不该被拖着走,也不该被放大):
   * 这一条是自绘版三版返工换来的口径,不要再往这个节点上加 translate/scale。
   */
  @Builder
  Content() {
    Row() {
      ForEach(this.items, (it: TabSpec, idx: number) => {
        // 图标与文案之间 2vp:与系统栏那版一致,也让三格的基线与页面内容读起来同高
        Column({ space: 2 }) {
          Glyph({
            symbol: (this.curTab === idx && it.hasFill) ? it.iconFill : it.icon,
            dim: TAB_SYMBOL,
            color: this.curTab === idx ? this.scheme().primary : this.scheme().onSurfaceVariant,
            bold: this.curTab === idx && !it.hasFill
          })
          Text(it.label)
            .fontSize(TAB_LABEL_FP * Theme.fontScale(this.settings.fontIndex))
            .letterSpacing(Tracking.caption)
            .fontColor(this.curTab === idx ? this.scheme().primary : this.scheme().onSurfaceVariant)
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }, (it: TabSpec, idx: number) => idx.toString())
    }
    .width('100%')
    .height(TAB_BAR_H)
    /**
     * 收束时淡没。淡没不等于消失:布局不许塌,否则播放条落进来的位置跟着抖。
     * opacity 不参与测量,所以这条 `.animation()` 不带动任何重排。
     */
    .opacity(this.collapsed ? 0 : 1)
    .animation({ curve: morphSpring() })
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        // 首次量宽之前晕/核的 x 还是 0,会在栏左端闪一颗 → 量到之前只画内容
        if (this.barW > 0) {
          this.Core()
        }
        this.Content()
        if (this.barW > 0) {
          this.Glow()
        }
      }
      .width('100%')
      .height(TAB_BAR_H)
      .borderRadius(TAB_BAR_H / 2)
      /**
       * 裁剪是必需的:晕宽 132 > 半格,中心走到端点那一格时会溢出胶囊,不裁就漏出一截亮。
       * 用 borderRadius + clip,**不用 clipShape**(H96:那会让 backgroundEffect 被单独重合成)。
       */
      .clip(true)
      /**
       * 磨砂本体。参数沿用玻璃版装机定过的那一档(radius 28 / sat 1.35 / tint 0.34):
       * 压得住列表、又还看得见内容在动。
       *
       * ⚠️ **栏的深浅不由这里决定,由 `applyColorMode` 决定**(H174)。`backgroundEffect`
       * 取的是「应用生效深浅态」,不是我们的 `Scheme`;系统栏那版试过用 `barBackgroundColor`
       * 压一层 0.86 的 surface 去盖,盖不住那份材质。这里换回自绘也一样:这一层只负责
       * **压住多少内容透上来**,深色下发白就去 `lightK()` 那一档调,不要改这里的 alpha。
       */
      .backgroundEffect({
        radius: 28,
        saturation: 1.35,
        brightness: 1.0,
        color: withAlpha(this.scheme().surface, 0.34)
      })
      .border({ width: 0.8, color: withAlpha(this.scheme().outline, 0.45) })
      .shadow({ radius: 24, color: withAlpha('#000000', 0.16), offsetY: 5 })
      .scale({ x: this.barScale(), y: this.barScale() })
      .animation({ curve: morphSpring() })
      .onAreaChange((_o: Area, n: Area) => {
        const w: number = Number(n.width);
        if (w !== this.barW) this.barW = w;
      })
      .onTouch((e: TouchEvent) => { this.onTouchEdge(e); })
      /**
       * 收束态**整栏不吃触摸**:那 56vp 此时是播放条的地盘,三格图标已经淡没,
       * 再让栏接触摸就会挡住播放条的按钮(装机踩过同一形状:透明容器吞点击)。
       */
      .hitTestBehavior(this.collapsed ? HitTestMode.None : HitTestMode.Default)
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
          .onActionStart((_e: GestureEvent) => {
            this.dragging = true;
          })
          .onActionUpdate((e: GestureEvent) => {
            // offsetX 单位是 vp(gesture.d.ts 明确标注),与布局坐标同单位,直接相加。
            // 这里**只写位置**:晕 1:1 跟手,不起动画;核吃自己的弹簧,自然滞后。
            this.glowX = this.clampX(this.startGlowX + e.offsetX);
            this.ringX = this.glowX;
          })
          .onActionEnd(() => { this.settle(); })
          .onActionCancel(() => { this.dragging = false; })
      )
    }
    .width('100%')
    .height(barFootprint(this.inset))
    .padding({ left: SIDE_PAD, right: SIDE_PAD })
    /**
     * 容器自身(左右两道 padding + 下面那道手势区)不吞点击,只有胶囊接触摸。
     * 与播放条那层同一个修法:`HitTestMode.None` 只放过容器,子节点照常响应。
     */
    .hitTestBehavior(HitTestMode.None)
  }
}
