import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { PlayerController } from '../playback/PlayerController';
import { Artwork, Glyph, Sym } from './Widgets';
import {
  HomeSlot, morphSpring,
  MINI_COVER_NARROW, MINI_COVER_WIDE, MINI_PAD_NARROW_TOP, MINI_PAD_NARROW_BOTTOM, MINI_PAD_WIDE
} from './BottomBar';

/**
 * 底部常驻迷你播放条:细进度线 + 封面 + 标题/频道 + 播放暂停 + 下一集 + 队列入口。
 * 点信息区打开全屏播放页,点队列符号进队列页(与 macOS 底部条的列表按钮同位次
 * —— 都在最右)。对应 Android `Components.kt` 的 MiniPlayer。
 *
 * **两态**(2026-10-13 加,对齐预装华为音乐):
 * - 展开(`collapsed=false`):整块 60vp,坐在 tab 栏**上方** 8vp 处,不透明 surface 底;
 * - 收束(`collapsed=true`):整块 56vp **落进 tab 栏那一条**里,底色透掉(让 `HdsTabs` 那份
 *   `systemMaterialEffect` 的系统磨砂当自己的背景),左端让出 56vp 给 [HomeSlot] 那颗回主页按钮。
 *
 * 两态是**同一套节点、只差几个几何量**,不是两个布局 —— 这是"丝滑"的唯一来源:
 * 换布局会让整行内容重挂,而重挂没有中间帧。这里封面尺寸/上下 padding/左槽宽度/底色
 * 四项都写成随 `collapsed` 取的属性,并在**各自节点**上声明 `.animation()`,
 * 弹簧曲线从 [morphSpring] 取,和 Index 里那层"整块往上抬 68vp"用的是同一条。
 *
 * ⚠️ 属性动画挂在**自己有属性变化的那个节点**上,不跨组件 —— 早先试过 animateTo 从父级
 * 包一下,子组件里 @Prop 同步带来的变化并不吃这个动画(观感是"一半在动一半瞬移")。
 *
 * ⚠️ 封面 42→44 这 2vp **是瞬间跳的**(它是子组件 Artwork 内部的 width,父层动画管不到)。
 * 刻意不为此加"包一层 clip 的壳":2vp 的 snap 叠在整块 68vp 的弹簧位移上读不出来,
 * 而多加的那层壳会在展开态也一直是活的布局节点,反而多一处要维护的几何。
 */
@Component
export struct MiniPlayerBar {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  /// 播放状态变化(播放/暂停/换集…)要重渲;**进度不在其中**,见下面的 pct
  @ObjectLink @Watch('onPlayerChange') player: PlayerController;
  /** 播放条是否已收束进 tab 栏。默认 false:频道详情页那一处下面没有栏,永远展开。 */
  @Prop collapsed: boolean = false;
  onExpand: () => void = () => {};
  onOpenQueue: () => void = () => {};
  /// 收束态点左端回主页:展开回两行共存
  onHome: () => void = () => {};

  /**
   * 进度线的百分比,**取整**。
   *
   * 进度不再由 `@Observed` 推过来(那会让整页每秒重建十次,见 `PlaybackClock`),
   * 改为这里自己 1 秒轮询一次 clock。取整到 1% 是为了「值没变就不赋值」——
   * 一集 30 分钟的话 1% ≈ 18 秒,也就是这条 2px 细线平均 18 秒才重渲一次,
   * 而它的宽度精度本来就只有屏幕宽 /100。
   */
  @State pct: number = 0;
  private timer: number = -1;

  aboutToAppear(): void {
    this.sample();
    this.onPlayerChange();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  /// 只在播放中轮询;暂停/无内容时停表,并补采一次(seek 后松手也要更新)
  private onPlayerChange(): void {
    const want = this.player.isPlaying && this.player.current !== null;
    if (want && this.timer < 0) {
      this.timer = setInterval(() => this.sample(), 1000);
    } else if (!want && this.timer >= 0) {
      this.stopTimer();
      this.sample();
    }
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private sample(): void {
    const dur = this.player.durationMs;
    const p = dur <= 0 ? 0 : Math.min(100, Math.max(0, Math.floor(this.player.positionMs / dur * 100)));
    if (p !== this.pct) this.pct = p;
  }

  build() {
    Column() {
      // 细进度线(两态都在最上一行,收束时它落在栏的上沿 —— 参考片那版在这里画的是
      // 封面外圈的一根环,那要另做一层 Progress 叠在 Artwork 上,本轮不迁就那个形状)
      Stack({ alignContent: Alignment.Start }) {
        Row().width('100%').height(2).backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.18))
        Row().width(`${this.pct}%`).height(2).backgroundColor(this.scheme.primary)
      }
      .width('100%').height(2)

      Row() {
        // 回主页:只在收束态占位(宽度 0 → 70 一路动画过来,内含 56 的槽 + 14 的缝, 见 BottomBar.HOME_SLOT_GAP)。
        HomeSlot({
          scheme: this.scheme,
          collapsed: this.collapsed,
          onTap: () => this.onHome()
        })
        Row({ space: 10 }) {
          Row({ space: 10 }) {
            Artwork({
              scheme: this.scheme,
              url: this.player.current === null ? '' : this.player.current.artworkUrl,
              dim: this.collapsed ? MINI_COVER_NARROW : MINI_COVER_WIDE, corner: 8
            })
            Column({ space: 2 }) {
              Text(this.player.current === null ? '' : this.player.current.title)
                .fontSize(TypeScale.label * this.fontScale)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.scheme.onBackground)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.player.current === null ? '' : this.player.current.podcastTitle)
                .fontSize(TypeScale.caption * this.fontScale)
                .fontColor(this.scheme.onSurfaceVariant)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .layoutWeight(1)
          .alignItems(VerticalAlign.Center)
          .onClick(() => this.onExpand())

          if (this.player.loading || this.player.buffering) {
            LoadingProgress().width(22).height(22).color(this.scheme.primary)
          } else {
            Image(this.player.isPlaying ? $r('sys.media.ohos_ic_public_pause') : $r('sys.media.ohos_ic_public_play'))
              .width(22).height(22)
              .fillColor(this.scheme.onBackground)
              .accessibilityText(L.s(this.player.isPlaying ? 'a11y_pause' : 'a11y_play'))
              .onClick(() => this.player.togglePlayPause())
          }
          Image($r('sys.media.ohos_ic_public_play_next'))
            .width(19).height(19)
            .fillColor(this.player.hasNext ? this.scheme.onBackground : withAlpha(this.scheme.onSurfaceVariant, 0.35))
            .accessibilityText(L.s('a11y_next'))
            .onClick(() => { if (this.player.hasNext) this.player.next(); })
          // 队列入口:命中区同样外扩,不外扩会被左右两个大命中目标夹得点不中
          Glyph({ symbol: Sym.queue, dim: 20, color: this.scheme.onBackground })
            .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
            .accessibilityText(L.s('queue_title'))
            .onClick(() => this.onOpenQueue())
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      /**
       * 上下 padding 是这一层唯一随两态变的量(8 ↔ 4/6),所以 `.animation()` 就挂在它所在的
       * 节点上。左右两端**不动**:14/16 是内容页边距口径,跟着 tab 栏走反而会和页面对不齐。
       * 收束态那两值**不相等** —— 差的那 2vp 正好是头顶上那条进度线,理由见常量注释。
       */
      .padding({ left: 14, right: 16,
        top: this.collapsed ? MINI_PAD_NARROW_TOP : MINI_PAD_WIDE,
        bottom: this.collapsed ? MINI_PAD_NARROW_BOTTOM : MINI_PAD_WIDE })
      .alignItems(VerticalAlign.Center)
      .animation({ curve: morphSpring() })
    }
    .width('100%')
    /**
     * 展开态用自己的 surface 底(它压在页面内容上,不给底会透出列表文字);
     * 收束态**全透** —— 这一行此时就在悬浮胶囊那 56vp 里,让 `HdsTabs` 那份
     * `barFloatingStyle.systemMaterialEffect` 的系统磨砂当背景,才和左右两侧的 tab 栏同构。
     * 给个 surface 底就把磨砂盖死了。
     */
    .backgroundColor(this.collapsed ? withAlpha(this.scheme.surface, 0) : this.scheme.surface)
    .animation({ curve: morphSpring() })
  }
}
