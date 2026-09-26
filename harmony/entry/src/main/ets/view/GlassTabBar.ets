import { Scheme, TypeScale, Tracking, withAlpha } from '../theme/Theme';
import { curves, RectShape } from '@kit.ArkUI';

/// tab 项规格:图标与文案。数量由父级决定(当前恒为 2)。
export interface TabSpec {
  label: Resource;
  icon: Resource;
}

// —— 放大镜光学参数(装机实测值,推导写在各自注释里;整轮取舍见 H96)——
/**
 * 镜片内的内容放大倍率(放大镜本体)。
 *
 * 上限由**内容块的高度**卡死,不是凭观感定的:图标 22 + 间距 2 + 文案 ≈13 = 37vp,
 * 绕栏中心放大后是 37×倍率,超过胶囊高度就会被胶囊沿切掉半个字 —— 实测 1.45 倍
 * 配 44 高的胶囊时「发现」二字下沿被削掉 5vp,读起来像渲染坏了而不是折射。
 * 37 × 1.35 ≈ 50 = 现在的胶囊高,字刚好完整落在镜片里。
 */
const LENS_MAG: number = 1.35;
/**
 * 拖拽时镜片副本的"拽动"三件套:满程 SMEAR_FULL vp,副本相对镜片反向退最多
 * SMEAR_LAG vp,同时横向额外放大 LENS_STRETCH。
 *
 * 位移必须是**负方向**(副本退、镜片进):取正号时副本跑在镜片前面,观感是
 * "字先走、圈后到",像掉帧而不是折射。横向单独加一档,是因为只平移会得到
 * "整块字挪了个位子",而拉伸才会读出"被玻璃拽住"。
 */
const SMEAR_FULL: number = 34;
const SMEAR_LAG: number = 15;
const LENS_STRETCH: number = 0.55;
/**
 * 按下时整条栏的放大倍率 / 胶囊再放大的一档。
 *
 * 首版取 1.07 / 1.12,装机截图里**完全看不出栏在长大**(56vp 的 7% 只有 4vp),
 * 需求要的正是"长按时整个底部 tab 都放大",看不出来等于没做。
 */
const BAR_PRESS: number = 1.10;
const PILL_PRESS: number = 1.15;
/**
 * 镜片底板的表面色不透明度:要盖住胶囊下那一份原尺寸内容(不盖会重影),
 * 又不能实成一块不透明贴片。
 *
 * 首版取 0.82,装机实测**残留重影明显**:放大副本绕中心外扩,原尺寸的图标/文案
 * 仍留在内侧,18% 透出来正好叠在副本的空档上,读作"两层字"。提到 0.93 后 ghost
 * 基本消失,而玻璃感不靠这块底板 —— 靠栏自身的 backgroundEffect 和胶囊外的模糊。
 */
const LENS_PLATE_ALPHA: number = 0.93;
/** 胶囊几何(与 pillXFor 里的 84 同源) */
const PILL_W: number = 84;
const PILL_H: number = 50;
const BAR_H: number = 56;

/**
 * 玻璃底部 tab 栏:悬浮长椭圆 —— 整条玻璃收进左右各 12 的全宽胶囊
 * (radius 28 = 高度一半)+ 一层投影给出 z 轴高度,视觉上浮在底部;
 * 背景实时模糊(backgroundEffect)+ 跟手切换(PanGesture)。
 *
 * **两层放大镜结构**(把"玻璃罩住内容"画成光学现象,而不是贴一个色块):
 * 1. 基础内容层([BaseLayer]):图标+文字,正常尺寸。
 * 2. 镜片层([LensLayer]):胶囊本体裁剪,先铺一块实心玻璃板(LENS_PLATE_ALPHA)垫住
 *    底下的原尺寸内容,再画绕胶囊中心按 LENS_MAG 放大的副本 —— 碰到/离开图标文字时
 *    内容明显变大,像放大镜;拖动时副本再退一档、横向再拉长一档,就是"拖影"。
 *
 * 曾经还有第 3 层「折射带」(比胶囊大一圈的 clipShape,里面放更强的放大副本),
 * 装机实测它并不折射任何东西,而是**整圈提亮成一块浅色光晕** —— 子节点带 clipShape
 * 时会被单独合成,栏的 backgroundEffect 在那一圈被重新算了一遍。删掉后光晕消失,
 * 拖影改由镜片层的「滞后 + 横向拉伸」表达(见 SMEAR_LAG / LENS_STRETCH)。
 *
 * 按下时**整条栏**一起放大(BAR_PRESS,需求所指定的"整个底部 tab 都放大"),胶囊自己
 * 再放大一档(PILL_PRESS)。单个 tab 内容**不再**各自缩放 —— 放大这件事交给镜片层,
 * 两处同时做会过冲。
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
   * 触摸按在栏上期间为 true:整条栏与胶囊放大、染色加深,松手回落。
   * 用 onTouch 而非 isScrollInProgress 之类的程序化信号 —— 只有触摸是只由人产生的
   * (同逐字稿自动滚动的教训,AGENTS 硬规矩 9)。
   */
  @State interacting: boolean = false;
  /** 触摸按下时预选的 tab(-1 = 无):装机社区式「按下胶囊先过去,松手页面才切」。 */
  private previewIdx: number = -1;
  private dragging: boolean = false;
  private startPillX: number = 0;

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

  /// 拽动量 -1..1(满程 SMEAR_FULL vp)。镜片层用它同时驱动滞后位移与横向拉伸。
  private smearAmt(): number {
    if (!this.dragging) return 0;
    const d: number = this.pillX - this.startPillX;
    return Math.max(-1, Math.min(1, d / SMEAR_FULL));
  }

  private lensMagX(): number {
    return LENS_MAG + Math.abs(this.smearAmt()) * LENS_STRETCH;
  }

  /// 父级改了 tab(点击别处、松手提交)→ 药丸动画吸到新位置。
  private syncPill(): void {
    if (this.dragging) return;
    this.animatePill(this.pillXFor(this.tab));
  }

  private animatePill(x: number): void {
    // 弹簧曲线:时长由物理参数(response 越小越快,dampingFraction<1 带轻微回弹)决定,
    // 固定时长的 EaseOut/Friction 收尾是匀减速,没有装机社区那种"落位有惯性"的质感。
    this.getUIContext().animateTo({ curve: curves.springMotion(0.3, 0.75) }, () => {
      this.pillX = x;
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
  /// 镜片层里先铺一块实心玻璃板(LENS_PLATE_ALPHA)垫住底下的原尺寸内容,再画放大副本。
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
   * 第 2 层:镜片本体 —— 底板 + 染色 + 放大副本,三者一起按胶囊裁剪。
   *
   * 按压缩放挂在这一层的**外层**上:裁剪与内容一起长大,才是"镜片变大",
   * 只放大副本会得到"镜片没变、字自己胀大"的塑料感。
   * **`.scale()` 与 `.animation()` 必须写在 `.clipShape()` 之前**:animation 只作用于
   * 链上位于它之前的属性,而 clipShape 跟着 pillX 走 —— 拖动位移不能被弹簧拖慢(同 H88/H91)。
   */
  @Builder
  LensLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 底板:盖住胶囊下那一份原尺寸内容
      Row()
        .width(PILL_W).height(PILL_H)
        .borderRadius(PILL_H / 2)
        .backgroundColor(withAlpha(this.scheme.surface, LENS_PLATE_ALPHA))
        .position({ x: this.pillX, y: (BAR_H - PILL_H) / 2 })
      // 染色 + 发丝描边:静止时半透明衬底,按下加深(对齐装机社区)
      Row()
        .width(PILL_W).height(PILL_H)
        .borderRadius(PILL_H / 2)
        .backgroundColor(withAlpha(this.scheme.primary, this.interacting ? 0.28 : 0.15))
        .border({ width: 0.8, color: withAlpha(this.scheme.primary, 0.18) })
        .position({ x: this.pillX, y: (BAR_H - PILL_H) / 2 })
      Stack({ alignContent: Alignment.TopStart }) {
        this.Items()
      }
      .width('100%')
      .height(BAR_H)
      // 横向单独加一档:拖动时内容被拽长(只平移会得到"整块字挪位子",不像折射)
      .scale({
        x: this.lensMagX(),
        y: LENS_MAG,
        centerX: this.pillCx(),
        centerY: this.pillCy()
      })
      .translate({ x: -this.smearAmt() * SMEAR_LAG })
    }
    .width('100%')
    .height(BAR_H)
    /**
     * 轴心必须写成药丸中心:这一层的节点是**整栏**大小(裁剪要按栏坐标摆),
     * 用默认的节点中心缩放会得到"胶囊变大同时往中间挤"的错位。
     */
    .scale({
      x: this.interacting ? PILL_PRESS : 1.0,
      y: this.interacting ? PILL_PRESS : 1.0,
      centerX: this.pillCx(),
      centerY: this.pillCy()
    })
    .animation({ curve: curves.springMotion(0.22, 0.8) })
    .clipShape(new RectShape({
      width: PILL_W,
      height: PILL_H,
      radius: PILL_H / 2
    }).position({ x: this.pillX, y: (BAR_H - PILL_H) / 2 }))
    .hitTestBehavior(HitTestMode.None)
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        /**
         * 两层内容的宿主:手势(onTouch)挂在这一层,裁剪(clip 到栏的圆角)也在这里。
         * 胶囊本体(衬底 + 描边)已收进 LensLayer:它必须与镜片里的放大副本同步缩放、
         * 同步裁剪,拆成两层会对不齐(按下时"字胀大、圈不动")。
         */
        Stack({ alignContent: Alignment.TopStart }) {
          this.BaseLayer()
          if (this.barW > 0) {
            this.LensLayer()
          }
        }
        .width('100%')
        .height(BAR_H)
        .borderRadius(28)
        .clip(true)
        .onTouch((e: TouchEvent) => {
          if (e.type === TouchType.Down) {
            this.interacting = true;
            // 按下即预选:胶囊先滑到手指所在的 tab,页面等松手再切(对齐装机社区)
            const idx = this.tabAtLocal(e.touches[0].x);
            if (idx !== this.tab) {
              this.previewIdx = idx;
              this.nearIdx = idx;
              this.animatePill(this.pillXFor(idx));
            }
          } else if (e.type === TouchType.Up) {
            this.interacting = false;
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
            this.pillX = Math.max(lo, Math.min(hi, this.startPillX + e.offsetX));
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
