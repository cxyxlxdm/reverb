import { Scheme, TypeScale, withAlpha } from '../theme/Theme';
import { L } from '../util/L';
import { PlayerController } from '../playback/PlayerController';
import { Artwork, Glyph, Sym } from './Widgets';
import {
  HomeSlot, morphSpring,
  MINI_COVER_NARROW, MINI_COVER_WIDE, MINI_PAD_COLLAPSED,
  MINI_PAD_EXPANDED, MINI_SIDE_MARGIN, MINI_RADIUS, MINI_SYMBOL, MINI_HIT_EXT, MINI_HIT_OFF
} from './BottomBar';

/**
 * 底部常驻迷你播放条:细进度线 + 封面 + 标题/频道 + 播放暂停 + 下一集 + 队列入口。
 * 点信息区打开全屏播放页,点队列符号进队列页(与 macOS 底部条的列表按钮同位次
 * —— 都在最右)。对应 Android `Components.kt` 的 MiniPlayer。
 *
 * 两态的几何(2026-11-09 起**两态同高**,内边距 8/8):
 * - 展开(`collapsed=false`):**长椭圆胶囊**,与悬浮栏同宽(左右各收 23vp),整块 56vp
 *   = 8 + 40(封面)+ 8,坐在 tab 栏**上方** 8vp 处,不透明 surface 底;
 * - 收束(`collapsed=true`):**两个物体,不是一条**,并且**整块与 tab 栏等高**。
 *   左端那颗**小圆球**(盘 52、里面是当前那一格的图标)独立站在栏的左沿,右端是播放条
 *   **自己的胶囊**(封面 + 文字 + 三个按钮,块高 56 = 8 + 40(封面)+ 8 = [MINI_H_COLLAPSED],
 *   不透明 surface 底 + 半高圆角
 *   28),两者之间是 8vp 的**外缝**([HOME_SLOT_GAP])。
 *   三枚按钮 16vp([MINI_SYMBOL],装机复看连降两档),球上那枚图标 24vp([HOME_SYMBOL])。
 *
 * ⚠️ **第五轮把收束态从 44 高抬到 56 高,同时让系统栏那条胶囊淡掉**(`barOpacity: 0`,
 * 见 `BottomBar.barFloating`)。旧口径 44 高的两条后果装机都读得出来:① 我们的胶囊**嵌在**
 * 系统栏的胶囊里,那一行有两层底;② 按钮按 44 那一档配(22/19/20),放进 56 那行比 tab 图标小一圈、
 * 还被半高圆角那道弧削着。参考片收束态只有一层容器 —— 就是播放条自己。
 * ⚠️ 随之而来的一条**是设计不是 bug**:收束态那一行归播放条与那颗球,**三个 tab 点不动**;
 * 要切格先点球展开。
 *
 * ⚠️ **收束态曾经做成"一个物体"**(球嵌在播放条胶囊的左端凹位里、胶囊底色透掉去借系统栏的磨砂),
 * 装机复看读起来就是"胶囊左边鼓出来一颗球",而参考片是"一颗球 + 一条胶囊"。
 * 所以那一轮把球**挪出胶囊**,并让胶囊在收束态**有自己的底**(不再是 alpha 0)。
 *
 * 两态是**同一套节点、只差几个几何量**,不是两个布局 —— 这是"丝滑"的唯一来源:
 * 换布局会让整行内容重挂,而重挂没有中间帧。这里随 `collapsed` 动画的只剩两项:
 * 左槽宽度(0 → 56)与右内距(16 → 8);封面、纵向内距、圆角从 2026-11-09 起两态相同,
 * 不再参与插值。弹簧曲线从 [morphSpring] 取,和 Index 里那层"整块下沉 64vp"(栏高 56 + 缝 8)
 * 用的是同一条。
 * ⚠️ **底色不再是其中一项**(第五轮起两态同为不透明 `surface`):收束态那一行已经没有系统胶囊垫底,
 * 再留半透明就是让列表文字从按钮底下穿上来。
 *
 * ⚠️ 属性动画挂在**自己有属性变化的那个节点**上,不跨组件 —— 早先试过 animateTo 从父级
 * 包一下,子组件里 @Prop 同步带来的变化并不吃这个动画(观感是"一半在动一半瞬移")。
 *
 * ⚠️ **封面两态同 40(2026-11-09),瞬移代价到此为止。** 早先两态不同档(34 / 40),
 * 而封面边长是 `Artwork` **内部**的 width、父层属性动画管不到它,收束时那 6vp 是**瞬移**;
 * 第六轮为"展开更紧凑"付下这条代价,上一版还留着"下一轮装机盯有没有读出来"的待验项。
 * 统一块高之后两态封面都是 56 − 8×2,它不再需要插值 —— **别为了"两态不一样"把窄档再调开**。
 * 见 `BottomBar.MINI_COVER_WIDE`。
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
  /// 关闭播放条(最右那枚 X):停止播放并清掉「正在播」上下文,整条塌陷消失。
  /// 动画不在这里 —— 显隐门是 `player.current`,塌陷/让位的 animateTo 在 Index 那一层。
  onClose: () => void = () => {};
  /// 收束态点左端那颗小圆球:展开回两行共存(它显示的是当前那一格,动作**不是**切 tab)
  onBallTap: () => void = () => {};
  /**
   * 点封面进这一集所属的频道页。**默认关**,由用得到的那一处(Index 的 tab 外壳)显式打开:
   * ArkTS 没有 Android 那个 CompositionLocal,「外壳有没有提供入口」这重门只能由调用方给,
   * 默认开就成了"看着能点、点了没反应"的假封面。
   *
   * ⚠️ **频道详情页那一处必须保持关**(Index 里 `podcast` 分支的 `MiniPlayerBar`):
   * 已经在这档的页面里点头像,等于往栈上再压一份同一个页面。与 Android 的
   * `coverOpensChannel`(`ReverbRoot.kt:507/594`)同一条门。
   */
  @Prop coverOpensChannel: boolean = false;
  onOpenChannel: (feedUrl: string) => void = () => {};

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

  /// 封面边长。两态同 40(见 `BottomBar.MINI_COVER_WIDE`);保留这个出口是因为
  /// `Artwork` 的 `dim` 与点击覆盖层的尺寸都从这里取,将来要再分档也只有这一处。
  private coverDim(): number {
    return this.collapsed ? MINI_COVER_NARROW : MINI_COVER_WIDE;
  }

  /**
   * 封面这一格能不能跳频道页 = **门开着** + **这一集带 feedUrl** + **动作真的传进来了**。
   *
   * 三条一起判的理由与列表行同一条(见 `Components.EpisodeListItem.canJumpChannel`):
   * 只判前两条会画出一点就什么也不发生的假封面。本端 `onOpenChannel` 有默认空实现,
   * 所以判"闭包有没有被传"做不到 —— 真正防住它的是 `coverOpensChannel` **默认 false**
   * (调用方不显式打开就没有这一层),与 Android 那个"外壳没提供入口 ⇒ jump 为 null"同效。
   */
  private canJumpChannel(): boolean {
    const e = this.player.current;
    return this.coverOpensChannel && e !== null && e.feedUrl.length > 0;
  }

  private coverFeedUrl(): string {
    const e = this.player.current;
    return e === null ? '' : e.feedUrl;
  }

  build() {
    /**
     * 外层**只做一件事**:把整块内缩到与悬浮胶囊同宽([MINI_SIDE_MARGIN])。
     * 它不吃底色、不吃圆角 —— 那两样在里面的胶囊本体上,否则圆角会被这道内缩留白切出方角。
     */
    Column() {
      /**
       * 收束态这一行是**两个物体并排**:左端那颗独立的小圆球 + 右端播放条自己的胶囊。
       * 球只在收束态占宽(0 → 56 一路动画过来),展开态零宽 ⇒ 胶囊就是整行,几何与旧口径一致。
       *
       * 外层 `alignItems(Center)`:第五轮起**两个物体同高**(球槽 56、胶囊块高 56 = 栏高),
       * 所以居中与否都不再产生高度差,而**球心、封面心、栏心三者仍同一条线**(装机量的 2506.5 / 2506)。
       */
      Row() {
        // 小圆球:独立于胶囊之外(它右边那道缝是球槽的外边距 `HOME_SLOT_GAP`,不是胶囊的内白)
        HomeSlot({
          scheme: this.scheme,
          collapsed: this.collapsed,
          onTap: () => this.onBallTap()
        })
        /**
         * 胶囊本体。**展开态**是自己的 surface 底 + 半高圆角(它浮在页面内容上,
         * 不是通栏那条板子,所以底和圆角都得给);
         * **收束态用同一层不透明 surface 底** —— 第五轮起这一态**下面已经没有系统胶囊**
         * (整条栏的 `barOpacity` 打到 0),再留半透明就是让列表文字从按钮与标题底下穿上来。
         *
         * ⚠️ 这里连着两次改判,别再往回改:
         * ① 旧版透掉底色去借 `HdsTabs` 那份 `systemMaterialEffect` 的磨砂 ⇒ 球和播放条被同一层
         *    磨砂包成一条,读不出"两个物体"(第四轮否掉);
         * ② 第四轮改成半透明(0.55),前提是系统胶囊还在下面垫着 —— 第五轮把系统胶囊淡掉之后
         *    这个前提就没了,所以回到不透明。
         * 至于"球独立",靠的是**把那道缝挪到胶囊外面**(参考片是外缝 10vp + 内白 5vp;
         * 第四轮第一版把 14vp 全给了胶囊内白,外缝只剩 2vp,两个圆头几乎相切,观感仍是
         * "胶囊左端鼓出一颗球")。见 `BottomBar.HOME_SLOT_GAP`。
         *
         * ⚠️ 圆角跟着块高走:两态同高(56)⇒ 同一个 [MINI_RADIUS](28)。
         * 上一版按态取两份(展开 24 / 收束 28),已并掉 —— 分开写只会漂。
         *
         * 为什么是 `Stack` 而不是原来的 `Column`:进度线从"行内的一格"改成**压在胶囊上沿的
         * 覆盖层**。旧写法那 2vp 参与测量,于是收束态只能靠上下 padding 不等(4/6)把封面找回
         * 正中;移出布局之后两态 padding 都对称。`clip(true)` 是给进度线收口的:那条线宽 '100%',
         * 不裁的话两个方头会戳出圆角。
         */
        Stack({ alignContent: Alignment.TopStart }) {
          Row({ space: 10 }) {
            Row({ space: 10 }) {
              /**
               * 封面 + 一层**只吃封面**的点击覆盖层(点它进频道页,这一行其余地方仍是展开播放页)。
               * 对应 Android `MiniPlayer` 里那个 `matchParentSize` 覆盖层。
               *
               * ⚠️ 覆盖层必须写在**包住 Artwork 的 Stack 里**,不能做成这一行的兄弟节点:
               * Android 第一版那么写过,多占一格 `spacedBy(10dp)` 把胶囊里的排布顶歪
               * (见 `Components.kt` 那段)。本端 Stack 是叠层、不参与行测量,天生没有那一格,
               * 但**尺寸要自己按封面给** —— ArkUI 没有 `matchParentSize`,给 `'100%'` 会跟着
               * Stack 的默认尺寸(= 最大子节点=封面)之外再被行拉宽。
               *
               * ⚠️ **必须 `stopPropagation`**:本工程实测「子节点的 onClick 处理完照样冒泡给
               * 父节点的 onClick」(列表行右侧各图标全靠这条截断)。不截断的话点封面 =
               * 进频道页**并且**展开播放页 —— 两个页面叠着推上去,回去要按两次返回。
               *
               * `backgroundColor(Color.Transparent)` 不是装饰:一块没有任何底色、没有子节点的
               * `Column` 在 ArkUI 里不参与绘制,给它一个显式透明底是保证这层真的在那里接点击。
               */
              Stack() {
                Artwork({
                  scheme: this.scheme,
                  url: this.player.current === null ? '' : this.player.current.artworkUrl,
                  dim: this.coverDim(), corner: 8
                })
                if (this.canJumpChannel()) {
                  Column()
                    .width(this.coverDim()).height(this.coverDim())
                    .borderRadius(8)
                    .backgroundColor(Color.Transparent)
                    .onClick(() => this.onOpenChannel(this.coverFeedUrl()))
                    .onTouch((event: TouchEvent) => event.stopPropagation())
                    .accessibilityText(L.s('a11y_open_channel'))
                }
              }
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

            /**
             * 三枚按钮同为 [MINI_SYMBOL]=16(装机复看连降两档:24 → 20 读不出变化,原因写在
             * 那条常量的改判记录里 —— 实心三角按 bounding box 缩 17% 肉眼几乎不动)。
             * ⚠️ 别把它当成"被裁"的解法往回抬到 24:第五轮那次改判真正修掉的是**块高 44 → 56**
             *    (旧值 22/19/20 配 44 那一档时贴着半高圆角那道弧,装机读出来就是"图标被裁了")。
             * 三枚都要**外扩命中框**到 [MINI_HIT_EXT](偏移 [MINI_HIT_OFF] 与它配套):不外扩会被
             * 左右两个大命中目标夹住点不中,而图标缩到 16 之后节点本身已经小于拇指目标。
             */
            if (this.player.loading || this.player.buffering) {
              LoadingProgress().width(MINI_SYMBOL).height(MINI_SYMBOL).color(this.scheme.primary)
            } else {
              Image(this.player.isPlaying ? $r('sys.media.ohos_ic_public_pause') : $r('sys.media.ohos_ic_public_play'))
                .width(MINI_SYMBOL).height(MINI_SYMBOL)
                .fillColor(this.scheme.onBackground)
                .responseRegion({ x: MINI_HIT_OFF, y: MINI_HIT_OFF, width: MINI_HIT_EXT, height: MINI_HIT_EXT })
                .accessibilityText(L.s(this.player.isPlaying ? 'a11y_pause' : 'a11y_play'))
                .onClick(() => this.player.togglePlayPause())
            }
            Image($r('sys.media.ohos_ic_public_play_next'))
              .width(MINI_SYMBOL).height(MINI_SYMBOL)
              .responseRegion({ x: MINI_HIT_OFF, y: MINI_HIT_OFF, width: MINI_HIT_EXT, height: MINI_HIT_EXT })
              .fillColor(this.player.hasNext ? this.scheme.onBackground : withAlpha(this.scheme.onSurfaceVariant, 0.35))
              .accessibilityText(L.s('a11y_next'))
              .onClick(() => { if (this.player.hasNext) this.player.next(); })
            Glyph({ symbol: Sym.queue, dim: MINI_SYMBOL, color: this.scheme.onBackground })
              .responseRegion({ x: MINI_HIT_OFF, y: MINI_HIT_OFF, width: MINI_HIT_EXT, height: MINI_HIT_EXT })
              .accessibilityText(L.s('queue_title'))
              .onClick(() => this.onOpenQueue())
            /**
             * 关闭(参考视频的位次:X 在播放条最右端,队列入口之外再一枚)。
             * 色阶用 onSurfaceVariant:次要动作,不与播放键的实色争权重(与 Android/macOS 同判)。
             * 命中框外扩与前三枚同款 —— 图标缩到 16 之后节点本身小于拇指目标。
             */
            Glyph({ symbol: Sym.close, dim: MINI_SYMBOL, color: withAlpha(this.scheme.onSurfaceVariant, 0.8) })
              .responseRegion({ x: MINI_HIT_OFF, y: MINI_HIT_OFF, width: MINI_HIT_EXT, height: MINI_HIT_EXT })
              .accessibilityText(L.s('a11y_close_player'))
              .onClick(() => this.onClose())
          }
          .width('100%')
          /**
           * 内边距**整块随两态换**(见 [MINI_PAD_EXPANDED] / [MINI_PAD_COLLAPSED] 里各边的理由),
           * 所以 `.animation()` 就挂在这个节点上。2026-11-09 统一之后只剩**右内距 16 ↔ 8** 在动
           * (左 14 与纵向 8/8 两态相同;"球 → 胶囊"的缝由球槽的外边距给)。
           */
          .padding(this.collapsed ? MINI_PAD_COLLAPSED : MINI_PAD_EXPANDED)
          .alignItems(VerticalAlign.Center)
          .animation({ curve: morphSpring() })

          // 细进度线:覆盖层,永远贴在胶囊上沿(参考片那版在这里画的是封面外圈的一根环,
          // 那要另做一层 Progress 叠在 Artwork 上,本轮不迁就那个形状)
          Row().width('100%').height(2).backgroundColor(withAlpha(this.scheme.onSurfaceVariant, 0.18))
          Row().width(`${this.pct}%`).height(2).backgroundColor(this.scheme.primary)
        }
        .layoutWeight(1)
        .backgroundColor(this.scheme.surface)
        .borderRadius(MINI_RADIUS)
        .clip(true)
        .animation({ curve: morphSpring() })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: MINI_SIDE_MARGIN, right: MINI_SIDE_MARGIN })
  }
}
