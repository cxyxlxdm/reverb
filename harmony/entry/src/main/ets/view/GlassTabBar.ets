import { Scheme, TypeScale, Tracking, withAlpha } from '../theme/Theme';
import { curves, RectShape } from '@kit.ArkUI';

/// tab 项规格:图标与文案。数量由父级决定(当前恒为 2)。
export interface TabSpec {
  label: Resource;
  icon: Resource;
}

// —— 玻璃胶囊的光学参数(装机实测值;取舍与坑见 H96/H97)——
/**
 * 拖影三件套。副本的横向拉伸与滞后位移都由 [smear] 这一个 0..1 的量驱动,
 * 而 smear 是**胶囊沿压到内容的程度**(见 edgeOf):
 * 内容整块在镜内、或整块在镜外 → 0(没有拖影);内容中心正好落在胶囊沿上 → 1。
 * 于是"触碰有影、离开影消"是几何事实,不需要额外开关。
 *
 * 位移取**负方向**(副本退、镜片进):取正号时副本跑在镜片前面,观感是
 * "字先走、圈后到",像掉帧而不是折射。只平移不够 —— 要读出"被玻璃拽住",
 * 必须同时把副本横向拉长。
 *
 * SMEAR_LAG 只有 6vp:副本是**整层**平移,而它要被裁进胶囊里 —— 退得越多,留在镜内的
 * 部分越少(取 15 时实测内容整块被推出镜外,镜子里只剩空玻璃)。
 */
const SMEAR_LAG: number = 6;
const SMEAR_STRETCH: number = 0.55;
/**
 * 按下时整条栏的放大倍率 / 胶囊再放大的一档。
 *
 * 两条都是用户指定的口径:①按下时**整条栏**放大,不是只有被按的图标;
 * ②胶囊要比整条栏放得**更多一档,高到超出栏高** —— 所以 PILL_PRESS 必须大于
 * BAR_H/PILL_H = 56/44 ≈ 1.27,低于这个比值胶囊就永远闷在栏里看不出来。
 * 首版取 1.07/1.12,装机截图里完全看不出栏在长大(56 的 7% 只有 4vp)。
 */
const BAR_PRESS: number = 1.10;
const PILL_PRESS: number = 1.42;
/**
 * 镜片底板的浓度**跟着拖影强度走**:静止 [PLATE_GLASS] 就是一块玻璃,拖影期间涨到
 * [PLATE_OPAQUE] 把底下的原文盖住。
 *
 * 为什么可以这么低:静止时副本与底下的内容**逐像素对齐**,透多少都不会重影 ——
 * 副本自己就是那份内容。0.93 那个值是"副本静态放大 1.35 倍"那版留下的包袱,
 * 撤掉静态放大后再留 0.93 就等于在内容上贴一块不透明贴片,尤其按下时长到栏外的
 * 部分会把列表内容整块糊掉(装机实测)。
 *
 * 而拖影期间副本被横向拉开,与底下的原文错开 —— 这时若还透 38%,两层字叠在一起
 * 读作渲染坏了(而不是折射)。所以随 smear 一起变实,影散了自动退回玻璃。
 */
const PLATE_GLASS: number = 0.62;
const PLATE_OPAQUE: number = 0.92;
/**
 * 内容块的半宽(vp):图标 22、文案两字 ≈26,取宽的那个的一半。
 * 只用来判"胶囊沿有没有压到内容",见 [edgeOf]。
 */
const CONTENT_HALF: number = 13;
/** 胶囊几何(静止态;按下按 PILL_PRESS 长大) */
const PILL_W: number = 84;
const PILL_H: number = 44;
const BAR_H: number = 56;

/**
 * 玻璃底部 tab 栏:悬浮长椭圆 —— 整条玻璃收进左右各 12 的全宽胶囊
 * (radius 28 = 高度一半)+ 一层投影给出 z 轴高度,视觉上浮在底部;
 * 背景实时模糊(backgroundEffect)+ 跟手切换(PanGesture)。
 *
 * **两层结构**(把"玻璃罩住内容"画成光学现象,而不是贴一个色块):
 * 1. 基础内容层([BaseLayer]):图标+文字,正常尺寸。
 * 2. 镜片层([LensLayer]):一块玻璃胶囊盖在内容上,里面再画一份**同尺寸同坐标**的
 *    内容副本 —— 所以静止时看不出有副本,只有玻璃的染色与描边。副本只在
 *    **胶囊沿压到内容**时被横向拉长并向后拽(拖影),沿一离开内容就归位。
 *
 * 三条口径都是用户指定的,别再改回"放大镜":
 * ① 按下时文字与图标**不变**(副本静止倍率恒为 1,不做静态放大 —— 曾按 1.35 做过,
 *    装机读作"底部变形":胶囊里一个字比外面大一号,像渲染坏了);
 * ② 按下时整条栏放大(BAR_PRESS),胶囊再大一档(PILL_PRESS > BAR_H/PILL_H,高到超出栏);
 * ③ 拖影只在触碰时出现 —— 由几何决定(见 [edgeOf]),不靠开关。
 *
 * 曾经还有第 3 层「折射带」(比胶囊大一圈的 clipShape,里面放更强的放大副本),
 * 装机实测它并不折射任何东西,而是**整圈提亮成一块浅色光晕** —— 子节点带 clipShape
 * 时会被单独合成,栏的 backgroundEffect 在那一圈被重新算了一遍。删掉后光晕消失
 * (见 H96)。
 *
 * 为什么"盖"而不是"挖":本 SDK 的 mask 只剩 `maskShape(shape)` 的"只显示形内"语义
 * (MaskType.Exclude 那套挖孔 API 已不在 CommonMethod 里),挖不成孔。于是镜片层先铺
 * 一块玻璃板(静止 [PLATE_GLASS],拖影期间涨到 [PLATE_OPAQUE])**盖住**底下的原尺寸
 * 内容,再画副本。副本静止时与
 * 底下的内容逐像素对齐,所以盖不盖都看不出;只有拖影期间它是"原文 + 拉伸副本"两层。
 *
 * 胶囊要长到超出栏高,所以两层内容的宿主**不能 clip 到栏的圆角** —— 裁剪只留给
 * 各自层自己(基础层内容本来就在界内,镜片层用 clipShape 裁到胶囊)。
 *
 * 为什么独立成组件而不留在 Index 的 @Builder:拖动期间药丸位置每帧都在变,
 * 这个状态若挂在 Index 上,ArkUI V1 的观察粒度是"对象",Index.build() 整棵树
 * (含两个 tab 页面)都会跟着每帧重建 —— 同 H64 让整页每秒重建十次的教训。
 * 收进子组件后,拖动帧只重建这一条栏。代价是内容要重绘两份(基础 + 镜片),
 * 都是本栏内的小矢量内容,实测逐帧成本仍在"只重建这条栏"这一档。
 *
 * 玻璃能透出内容的前提:内容延伸到栏下(Index.shell 已重排为 Stack 叠层),
 * 且各页面的滚动容器用 bottomPad 留出了底部余量。
 *
 * 手感约定(对齐装机社区):药丸 1:1 跟手;拖动中按接近度提前高亮目标项;
 * 松手按药丸当前位置吸附 —— 要切换时经 onSelect 回父级改 tab,
 * 药丸由 @Watch 统一吸附,不在手势回调里动画,避免两处动画打架。
 */
@Component
export struct GlassTabBar {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /** 当前选中 tab,由父级持有;点击/松手提交后经 onSelect 改回去 */
  @Prop @Watch('syncPill') tab: number;
  /** 底部手势条高度(vp):胶囊悬浮在手势区上方,与屏幕底之间留出这道空隙 */
  @Prop inset: number;
  items: TabSpec[] = [];
  onSelect: (i: number) => void = () => {};

  /** 药丸左上角 x。拖动帧直接赋值(1:1 跟手,无动画);松手后经 animateTo 吸附。 */
  @State pillX: number = 0;
  /** 栏实测宽度;首次测量前药丸先藏着,避免闪现在左上角 */
  @State barW: number = 0;
  /** 拖动中按接近度高亮的项;-1 = 未在拖动(高亮跟 tab 走)。 */
  @State nearIdx: number = -1;
  /**
   * 触摸按在栏上期间为 true:整条栏放大、胶囊染色加深,松手回落。
   * 用 onTouch 而非 isScrollInProgress 之类的程序化信号 —— 只有触摸是只由人产生的
   * (同逐字稿自动滚动的教训,AGENTS 硬规矩 9)。
   */
  @State interacting: boolean = false;
  /**
   * 胶囊当前的放大倍率(1 → PILL_PRESS),用 animateTo 驱动而不是 `.animation()`:
   * 胶囊的**尺寸**与镜片副本的**裁剪窗口**必须同步长大,而裁剪窗口跟着 pillX 逐帧走、
   * 不能被弹簧拖慢(H88/H91)。把倍率做成状态量,两处读同一个值,天然同步。
   */
  @State pillGrowth: number = 1;
  /** 触摸按下时预选的 tab(-1 = 无):装机社区式「按下胶囊先过去,松手页面才切」。 */
  private previewIdx: number = -1;
  private dragging: boolean = false;
  private startPillX: number = 0;
  /** 拖影要往哪边退:胶囊的运动方向(副本反向位移才读作"被玻璃拽住") */
  private smearDir: number = 1;

  aboutToAppear(): void {
    this.pillX = this.pillXFor(this.tab);
  }

  /// 每格宽度。当前恒 2 个 tab;加第三个时改这里即可,其余逻辑不动。
  private halfW(): number {
    return this.barW / 2;
  }

  private pillXFor(idx: number): number {
    return idx * this.halfW() + (this.halfW() - PILL_W) / 2;
  }

  /// 触摸点落在哪个 tab 上。x 是相对组件左上角的本地坐标(common.d.ts TouchObject.x)。
  private tabAtLocal(x: number): number {
    const half = Math.max(this.halfW(), 1);
    return Math.max(0, Math.min(1, Math.floor(x / half)));
  }

  /// 高亮跟随谁:拖动中跟手指(提前预告落点),平时跟选中项。
  private activeIdx(): number {
    return this.nearIdx >= 0 ? this.nearIdx : this.tab;
  }

  /// 镜片光轴(栏坐标):胶囊中心。副本绕它缩放,才与底下的栏内容对得上。
  private pillCx(): number {
    return this.pillX + PILL_W / 2;
  }

  private pillCy(): number {
    return BAR_H / 2;
  }

  /// 放大后的胶囊几何(静止 84×44,按下长到 PILL_PRESS 倍,中心不动)
  private pillW(): number {
    return PILL_W * this.pillGrowth;
  }

  private pillH(): number {
    return PILL_H * this.pillGrowth;
  }

  private pillLeft(): number {
    return this.pillCx() - this.pillW() / 2;
  }

  private pillTop(): number {
    return this.pillCy() - this.pillH() / 2;
  }

  /// 第 idx 项内容块的中心(胶囊静止时就落在这儿)。
  private slotCx(idx: number): number {
    return this.pillXFor(idx) + PILL_W / 2;
  }

  /**
   * 胶囊沿"压到"第 idx 项内容的程度 0..1。
   *
   * 纯几何:内容与胶囊同轴(d=0)→ 0(整块在镜内);胶囊走远到内容完全出沿
   * (d ≥ 半胶囊 + 半内容)→ 0;内容中心正好骑在沿上 → 1。
   * 于是"触碰有影、离开影消"不需要任何开关或计时器,松手回弹途中沿扫过内容
   * 也会顺带来一下影 —— 因为 pillX 本身在被弹簧逐帧驱动。
   */
  private edgeOf(idx: number): number {
    const d: number = Math.abs(this.pillCx() - this.slotCx(idx));
    const inner: number = PILL_W / 2 - CONTENT_HALF;
    const u: number = Math.max(0, Math.min(1, (d - inner) / (CONTENT_HALF * 2)));
    return 1 - Math.abs(2 * u - 1);
  }

  /// 拖影强度 0..1:两项里更被压住的那个。
  private smear(): number {
    return Math.max(this.edgeOf(0), this.edgeOf(1));
  }

  /// 拉长的轴心:正被沿压住的那项内容**自己的**中心(不是胶囊中心,理由见 LensLayer)
  private smearPivot(): number {
    return this.slotCx(this.edgeOf(0) >= this.edgeOf(1) ? 0 : 1);
  }

  /// 副本横向倍率:静止 1(与底下的内容逐像素对齐,看不出有副本),触碰时拉长。
  private lensMagX(): number {
    return 1 + this.smear() * SMEAR_STRETCH;
  }

  /** 底板浓度:静止是玻璃,拖影期间随 smear 变实盖住底下的原文(见 PLATE_GLASS 注释) */
  private plateAlpha(): number {
    return PLATE_GLASS + this.smear() * (PLATE_OPAQUE - PLATE_GLASS);
  }

  /**
   * 胶囊染色不透明度:跟着 pillGrowth 走而不是跟着 interacting 跳变 ——
   * 否则弹簧刚起步颜色就"啪"地深一档,和正在长大的胶囊对不上。
   */
  private tintAlpha(): number {
    const p: number = Math.max(0, Math.min(1,
      (this.pillGrowth - 1) / (PILL_PRESS - 1)));
    return 0.15 + p * 0.13;
  }

  /// 父级改了 tab(点击别处、松手提交)→ 药丸动画吸到新位置。
  private syncPill(): void {
    if (this.dragging) return;
    this.animatePill(this.pillXFor(this.tab));
  }

  private animatePill(x: number): void {
    // 弹簧曲线:时长由物理参数(response 越小越快,dampingFraction<1 带轻微回弹)决定,
    // 固定时长的 EaseOut/Friction 收尾是匀减速,没有装机社区那种"落位有惯性"的质感。
    this.smearDir = x >= this.pillX ? 1 : -1;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.3, 0.75) }, () => {
      this.pillX = x;
    });
  }

  /// 胶囊长大 / 缩回。倍率是状态量而不是 `.animation()`:见 pillGrowth 注释。
  private animateGrowth(target: number): void {
    if (this.pillGrowth === target) return;
    this.getUIContext().animateTo({ curve: curves.springMotion(0.22, 0.8) }, () => {
      this.pillGrowth = target;
    });
  }

  /// 松手 / 被系统取消手势:按药丸当前位置吸附最近项。switchable=false(取消)只回弹。
  private settle(switchable: boolean): void {
    if (!this.dragging) return;
    this.dragging = false;
    this.nearIdx = -1;
    this.previewIdx = -1;
    const target = this.pillX < (this.pillXFor(0) + this.pillXFor(1)) / 2 ? 0 : 1;
    if (switchable && target !== this.tab) {
      // 药丸不在这里动:tab 一变 @Watch 会统一吸附
      this.onSelect(target);
    } else {
      this.animatePill(this.pillXFor(this.tab));
    }
  }

  /// tab 内容(图标 + 文案),被两层各调用一次。**不带手势与点击** ——
  /// 命中统一走 layers 容器上的 onTouch(副本压在最上层,子项再挂 onClick 会互相抢)。
  @Builder
  Items() {
    Row() {
      ForEach(this.items, (it: TabSpec, idx: number) => {
        // 图标与文字的间距收得很紧(space 2):间距一大,胶囊要罩住整块内容就得
        // 跟着变高,观感发"胖"(装机社区的胶囊是贴合内容的扁长条)。
        Column({ space: 2 }) {
          Image(it.icon)
            .width(22).height(22)
            .fillColor(this.activeIdx() === idx ? this.scheme.primary : this.scheme.onSurfaceVariant)
          Text(it.label)
            .fontSize(TypeScale.caption * this.fontScale)
            .letterSpacing(Tracking.caption)
            .fontColor(this.activeIdx() === idx ? this.scheme.primary : this.scheme.onSurfaceVariant)
        }
        .layoutWeight(1)
        .height('100%')
        .justifyContent(FlexAlign.Center)
      }, (it: TabSpec, idx: number) => idx.toString())
    }
    .width('100%')
    .height(BAR_H)
  }

  /// 第 1 层:正常尺寸的 tab 内容。
  ///
  /// 本可以像 Android 端那样把胶囊覆盖区**挖掉**(那边一个 `clipPath(Difference)` 就完事),
  /// 但这个 SDK 的 `mask` 只剩 `maskShape(shape)` 的"只显示形内"语义(MaskType.Exclude
  /// 那套挖孔 API 已不在 CommonMethod 里),挖不成。于是改成"盖"而不是"挖":
  /// 镜片层里先铺一块玻璃板垫住底下的原尺寸内容,再画**同尺寸**副本(触碰时才拉长)。
  /// 代价是胶囊比真玻璃略实,换来的是不会有重影。
  @Builder
  BaseLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.Items()
    }
    .width('100%')
    .height(BAR_H)
  }

  /**
   * 第 2 层:镜片本体 —— 玻璃底板 + 染色 + 描边 + 内容副本,四者按同一颗胶囊裁剪。
   *
   * 胶囊的"长大"是**直接改尺寸**(pillW/pillH 读 pillGrowth),不是 `.scale()`:
   * 缩放会把里面的副本一起放大,而需求是"按下时文字图标不变,只有胶囊和容器放大"。
   *
   * **裁剪窗口挂在外层、形变挂在内层副本上,这个分工不能反**:clipShape 与 scale/translate
   * 写在同一个节点时,裁剪窗口会跟着形变一起被变换(实测副本被整块拽到胶囊外面,
   * 镜子里只剩底下透出来的原文 —— 看着像"字变淡了",其实是影跑到了镜外)。
   */
  @Builder
  LensLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 底板:盖住胶囊下那一份原尺寸内容
      Row()
        .width(this.pillW()).height(this.pillH())
        .borderRadius(this.pillH() / 2)
        .backgroundColor(withAlpha(this.scheme.surface, this.plateAlpha()))
        .position({ x: this.pillLeft(), y: this.pillTop() })
      // 染色 + 发丝描边:静止时半透明衬底,按下随胶囊一起加深
      Row()
        .width(this.pillW()).height(this.pillH())
        .borderRadius(this.pillH() / 2)
        .backgroundColor(withAlpha(this.scheme.primary, this.tintAlpha()))
        .border({ width: 0.8, color: withAlpha(this.scheme.primary, 0.18) })
        .position({ x: this.pillLeft(), y: this.pillTop() })
      Stack({ alignContent: Alignment.TopStart }) {
        this.Items()
      }
      .width('100%')
      .height(BAR_H)
      /**
       * 拖影:绕**内容自身中心**横向拉长,再逆着运动方向退一小步。
       * 轴心不能写胶囊中心 —— 副本离轴心越远,缩放给它的**位移**就越大
       * (实测绕胶囊中心拉 1.55 倍,把「发现」整块甩到胶囊外面 49vp 处,镜内什么都不剩)。
       * 绕自身中心拉才是"原地被拽宽",再由胶囊沿把它切成"镜内宽、镜外正常"两道,
       * 那道断口就是折射感。
       */
      .scale({
        x: this.lensMagX(),
        y: 1,
        centerX: this.smearPivot(),
        centerY: this.pillCy()
      })
      .translate({ x: -this.smearDir * this.smear() * SMEAR_LAG })
    }
    .width('100%')
    .height(BAR_H)
    .clipShape(new RectShape({
      width: this.pillW(),
      height: this.pillH(),
      radius: this.pillH() / 2
    }).position({ x: this.pillLeft(), y: this.pillTop() }))
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        /**
         * 两层内容的宿主:手势(onTouch)挂在这一层。
         * **这里不能 `.clip(true)`** —— 胶囊按下要长到超出栏高(需求指定),
         * 一 clip 就被栏的圆角齐着切平。基础层的内容本来就在界内,镜片层自带
         * clipShape,所以去掉宿主裁剪不影响别的。
         */
        Stack({ alignContent: Alignment.TopStart }) {
          this.BaseLayer()
          if (this.barW > 0) {
            this.LensLayer()
          }
        }
        .width('100%')
        .height(BAR_H)
        .onTouch((e: TouchEvent) => {
          if (e.type === TouchType.Down) {
            this.interacting = true;
            this.animateGrowth(PILL_PRESS);
            // 按下即预选:胶囊先滑到手指所在的 tab,页面等松手再切(对齐装机社区)
            const idx = this.tabAtLocal(e.touches[0].x);
            if (idx !== this.tab) {
              this.previewIdx = idx;
              this.nearIdx = idx;
              this.animatePill(this.pillXFor(idx));
            }
          } else if (e.type === TouchType.Up) {
            this.interacting = false;
            this.animateGrowth(1);
            // 纯点按(未演变成拖动)在这里提交;拖动的提交走 PanGesture 的 settle。
            // Up 与 onActionEnd 的先后不定,两边都以 previewIdx/dragging 判重,提交是幂等的。
            if (this.previewIdx >= 0 && !this.dragging) {
              const idx = this.previewIdx;
              this.previewIdx = -1;
              this.nearIdx = -1;
              if (idx !== this.tab) this.onSelect(idx);
            }
          } else if (e.type === TouchType.Cancel) {
            this.interacting = false;
            this.animateGrowth(1);
            this.previewIdx = -1;
            if (!this.dragging) {
              this.nearIdx = -1;
              this.animatePill(this.pillXFor(this.tab));
            }
          }
        })
      }
      .width('100%')
      .height(BAR_H)
      .borderRadius(28)
      /**
       * 按下整条栏放大(需求:长按时**整个底部 tab**都放大,不是只有被按的那个图标)。
       * 缩放的轴心取栏的几何中心,`centerY` 用默认 50% 即可 —— 栏自身就是 56 高,
       * 下面另有的 inset 空隙在父 Column 上,不在这一层。
       * 动画同样走弹簧;写在 scale 之后、其他属性之前,免得把 backgroundEffect 也拖进动画。
       */
      .scale({ x: this.interacting ? BAR_PRESS : 1.0, y: this.interacting ? BAR_PRESS : 1.0 })
      .animation({ curve: curves.springMotion(0.22, 0.8) })
      /**
       * 玻璃本体:实时模糊 + 一层半透明 surface 染色。
       * 半透明度 0.6:太透则浅色文字压在亮内容上读不清,太实则玻璃感全无;
       * radius / saturation 是首版凭观感取值,装机后按实机效果再调。
       * 投影给 z 轴高度:整条栏"浮"在页面之上,而非贴底的一块平面。
       */
      .backgroundEffect({
        radius: 40,
        saturation: 1.3,
        brightness: 1.0,
        color: withAlpha(this.scheme.surface, 0.6)
      })
      .border({ width: 0.8, color: withAlpha(this.scheme.outline, 0.45) })
      .shadow({ radius: 24, color: withAlpha('#000000', 0.16), offsetY: 5 })
      .onAreaChange((_o: Area, n: Area) => {
        const w = Number(n.width);
        if (w !== this.barW) {
          this.barW = w;
          // 首次测量 / 旋屏后按当前 tab 对位(aboutToAppear 时宽度还是 0,算不准)
          if (!this.dragging) this.pillX = this.pillXFor(this.tab);
        }
      })
      .gesture(
        PanGesture({ fingers: 1, direction: PanDirection.Horizontal, distance: 5 })
          .onActionStart((_e: GestureEvent) => {
            this.dragging = true;
            // 从胶囊**当前位置**继续拖(按下预选可能已把它挪到目标 tab),不要回到选中位
            this.startPillX = this.pillX;
          })
          .onActionUpdate((e: GestureEvent) => {
            // offsetX 单位是 vp(gesture.d.ts 明确标注),与布局坐标同单位,直接相加
            const lo = this.pillXFor(0);
            const hi = this.pillXFor(1);
            const next = Math.max(lo, Math.min(hi, this.startPillX + e.offsetX));
            // 拖影后退的方向跟着胶囊**这一帧**的运动方向,不是整段拖拽的净位移 ——
            // 拖到尽头再倒回来时,影也得跟着倒回去
            if (next !== this.pillX) {
              this.smearDir = next > this.pillX ? 1 : -1;
            }
            this.pillX = next;
            this.nearIdx = this.pillX < (lo + hi) / 2 ? 0 : 1;
          })
          .onActionEnd(() => { this.settle(true); })
          .onActionCancel(() => { this.settle(false); })
      )
    }
    .width('100%')
    .height(BAR_H + this.inset)
    /**
     * 悬浮长椭圆的左右留白(与顶部分类条同款):两侧有可见的缝,胶囊才"浮"得起来;
     * 下沿自然空出 inset(手势条区) —— 胶囊整体悬在手势区上方,不再延伸到屏幕底。
     */
    .padding({ left: 12, right: 12 })
  }
}
