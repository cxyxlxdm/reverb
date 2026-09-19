import { Scheme, TypeScale, Tracking, withAlpha } from '../theme/Theme';
import { curves } from '@kit.ArkUI';

/// tab 项规格:图标与文案。数量由父级决定(当前恒为 2)。
export interface TabSpec {
  label: Resource;
  icon: Resource;
}

/**
 * 玻璃底部 tab 栏:悬浮长椭圆 —— 整条玻璃收进左右各 12 的全宽胶囊
 * (radius 28 = 高度一半)+ 一层投影给出 z 轴高度,视觉上浮在底部;
 * 背景实时模糊(backgroundEffect)+ 跟手切换(PanGesture)。
 *
 * 为什么独立成组件而不留在 Index 的 @Builder:拖动期间药丸位置每帧都在变,
 * 这个状态若挂在 Index 上,ArkUI V1 的观察粒度是"对象",Index.build() 整棵树
 * (含两个 tab 页面)都会跟着每帧重建 —— 同 H64 让整页每秒重建十次的教训。
 * 收进子组件后,拖动帧只重建这一条栏。
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
   * 触摸按在栏上期间为 true:胶囊放大、染色加深,松手回落。
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
    return idx * this.halfW() + (this.halfW() - 84) / 2;
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

  build() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        /**
         * 透明胶囊(对齐装机社区):罩住图标+文字的整枚大胶囊,静止时半透明衬底 +
         * 一圈发丝描边。**按下即放大**(scale 1.2、染色加深),松手回落。
         * 放大/染色的动画走弹簧(curves.springMotion,按下要"弹"起来,收尾有惯性);
         * **`.translate()` 必须写在 `.animation()` 之后**:animation 只作用于链上位于
         * 它之前的属性,拖动时的 1:1 跟手位移不能被弹簧动画拖慢。
         */
        Row()
          .width(84).height(44)
          .borderRadius(22)
          .backgroundColor(withAlpha(this.scheme.primary, this.interacting ? 0.28 : 0.15))
          .border({ width: 0.8, color: withAlpha(this.scheme.primary, 0.18) })
          .scale({ x: this.interacting ? 1.2 : 1.0, y: this.interacting ? 1.2 : 1.0 })
          .animation({ curve: curves.springMotion(0.22, 0.8) })
          .translate({ x: this.pillX })
          .margin({ top: 6 })
          .visibility(this.barW > 0 ? Visibility.Visible : Visibility.None)

        Row() {
          ForEach(this.items, (it: TabSpec, idx: number) => {
            // 图标与文字的间距收得很紧(space 2):间距一大,胶囊要罩住整块内容就得
            // 跟着变高,观感发"胖"(装机社区的胶囊是贴合内容的扁长条)。
            //
            // 装机社区的第二层动效:按下的 tab 整块内容(图标+文字)放大,松手切完缩回。
            // 放大对象用 activeIdx —— 点按时是手指所在 tab,拖动时是途经的 tab,
            // 一个表达式同时覆盖两种手势;scale 走弹簧,与胶囊同参数,手感一致。
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
            .scale({ x: this.interacting && this.activeIdx() === idx ? 1.2 : 1.0,
                     y: this.interacting && this.activeIdx() === idx ? 1.2 : 1.0 })
            .animation({ curve: curves.springMotion(0.22, 0.8) })
            .onClick(() => { if (!this.dragging) this.onSelect(idx); })
          }, (it: TabSpec, idx: number) => idx.toString())
        }
        .width('100%')
        .height(56)
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
      .height(56)
      .borderRadius(28)
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
    .height(56 + this.inset)
    /**
     * 悬浮长椭圆的左右留白(与顶部分类条同款):两侧有可见的缝,胶囊才"浮"得起来;
     * 下沿自然空出 inset(手势条区) —— 胶囊整体悬在手势区上方,不再延伸到屏幕底。
     */
    .padding({ left: 12, right: 12 })
  }
}
