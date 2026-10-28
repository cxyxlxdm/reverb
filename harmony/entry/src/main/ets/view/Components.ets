import { Scheme, TypeScale, Tracking, LineHeight, withAlpha, Metrics } from '../theme/Theme';
import { curves } from '@kit.ArkUI';
import { L } from '../util/L';
import { Podcast, Episode } from '../model/Models';
import { Artwork, SquareArtwork, Glyph, Sym } from './Widgets';
import { formatPubDate } from '../util/DateParse';
import { TapGuard } from '../util/TapGuard';
import { DownloadState } from '../playback/DownloadManager';
import { BilibiliSource } from '../net/BilibiliSource';
import { PlayMode, PlayerController } from '../playback/PlayerController';

/// 列表/网格通用条目。对应 Android `ui/components/Components.kt`。

/// 时长文本:mm:ss / h:mm:ss。
export function formatTime(ms: number): string {
  if (ms <= 0) return '00:00';
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const p2 = (v: number): string => v < 10 ? `0${v}` : `${v}`;
  return h > 0 ? `${h}:${p2(m)}:${p2(s)}` : `${p2(m)}:${p2(s)}`;
}

/**
 * 单集时长的展示:**时间码**(`39:16` / `1:18:49`),0 返回空串。
 *
 * 原先返回的是「15 分钟」「1 小时 18 分」—— 与下面的 formatListenDuration 几乎同一份实现,
 * 是移植时的偷懒。两端就此分歧:Android 的 formatDurationSec 一直是 `formatTime(sec*1000)`。
 *
 * 按 Android 的分工来:**单集长度用时间码,累计收听用文字**(见 formatListenDuration)。
 * 这个区分是有道理的 —— 单集长度是"这条音频多长",时间码是媒体界的通用读法且更窄
 * (列表副信息那一行本来就挤);累计时长是"你听了多久",用文字更好读。
 */
export function formatDurationSec(sec: number): string {
  if (sec <= 0) return '';
  return formatTime(sec * 1000);
}

/// 人类可读的累计时长("X 小时 Y 分" / "Y 分钟" / "小于 1 分钟")。
export function formatListenDuration(sec: number): string {
  if (sec < 60) return L.s('dur_lt1m');
  const m = Math.floor(sec / 60);
  if (m >= 60) return L.f('dur_hm', Math.floor(m / 60), m % 60);
  return L.f('dur_m', m);
}

/// 频道列表行:封面 + 标题 + 作者 + 付费标记。
@Component
export struct PodcastListItem {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop podcast: Podcast;
  /// 搜索预检专用；默认空串,分类榜与订阅列表完全不受影响。
  @Prop status: string = '';
  @Prop statusError: boolean = false;
  @Prop tapEnabled: boolean = true;
  onTap: () => void = () => {};

  build() {
    Row({ space: 12 }) {
      Artwork({ scheme: this.scheme, url: this.podcast.artworkUrl, dim: 60, corner: 10 })
      Column({ space: 4 }) {
        Text(this.podcast.title)
          .fontSize(TypeScale.titleMedium * this.fontScale)
          .letterSpacing(Tracking.titleMedium)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.scheme.onBackground)
          // **一行**。原先是 2:字号与 Android 同档(titleMedium 16),但长标题在这里
          // 换成两行、Android 省略号截掉,于是同一屏鸿蒙的行比 Android 高一倍 ——
          // 用户读作"鸿蒙字大",实际是行高。对齐 Android 的 `maxLines = 1`。
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.podcast.author.length > 0) {
          Text(this.podcast.author)
            .fontSize(TypeScale.label * this.fontScale)
            .letterSpacing(Tracking.label)
            .fontColor(this.scheme.onSurfaceVariant)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (this.podcast.isPaid) {
          Text(L.s('paid'))
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.scheme.secondary)
        }
        if (this.status.length > 0) {
          Text(this.status)
            .fontSize(TypeScale.caption * this.fontScale)
            .fontColor(this.statusError ? this.scheme.error : this.scheme.primary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .opacity(this.tapEnabled ? 1 : 0.58)
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 10, bottom: 10 })
    .onClick(() => {
      if (this.tapEnabled) this.onTap();
    })
  }
}

/// 频道宫格卡:方封面 + 标题 + 作者(与 macOS PodcastCard 对齐)。
@Component
export struct PodcastGridItem {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop podcast: Podcast;
  onTap: () => void = () => {};

  build() {
    Column({ space: 8 }) {
      SquareArtwork({ scheme: this.scheme, url: this.podcast.artworkUrl, corner: Metrics.cardCorner })
      Text(this.podcast.title)
        .fontSize(TypeScale.titleSmall * this.fontScale)
        .letterSpacing(Tracking.titleSmall)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.scheme.onBackground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (this.podcast.author.length > 0) {
        Text(this.podcast.author)
          .fontSize(TypeScale.caption * this.fontScale)
          .letterSpacing(Tracking.caption)
          .fontColor(this.scheme.onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .onClick(() => this.onTap())
  }
}

/**
 * 长按菜单的触发阈值(毫秒)。
 *
 * 取 500 不是为了"更快的手感",是为了**与 Android 同值**:Compose 的
 * `combinedClickable(onLongClick=…)` 用 `viewConfiguration.longPressTimeoutMillis`,
 * 默认正是 500ms。鸿蒙这边原先走 `bindContextMenu(builder, ResponseType.LongPress)`,
 * 那个重载的长按识别在框架内部、时长不可配(本文件与 DiscoverPage 原先的注释都写着
 * "系统定值,改不了"),装机反馈就是「长按弹出菜单的触发阈值太长」。
 *
 * 改法:换成 `bindContextMenu(isShown, …)` 这个重载(API 12+),菜单由**自己的**
 * `LongPressGesture` 置位弹出 ⇒ 时长归应用管。代价是要自己把菜单摆回按下点
 * (见 `pressX` / `offset`),以及自己把 `isShown` 收回 false(见 `aboutToDisappear`)。
 */
export const LIST_MENU_LONG_PRESS_MS = 500;

/// 单集行:封面 + 标题 + 元信息(频道名 · 日期 · 时长)+ 圆形播放键。
/// 当前播放态用强调色标注;已播完标题变暗。
@Component
export struct EpisodeListItem {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop episode: Episode;
  @Prop isCurrent: boolean = false;
  @Prop isPlaying: boolean = false;
  @Prop played: boolean = false;
  @Prop showPodcastTitle: boolean = false;
  /// 下载态:-1 不显示下载入口 / 0 排队 / 1 进行中 / 2 已完成 / 3 失败
  @Prop downloadState: number = -1;
  onPlay: () => void = () => {};
  onDownload: () => void = () => {};
  onDeleteDownload: () => void = () => {};
  /// 行内收藏心形。与 Android 一致:**只在「音阁 · 收藏」这类需要就地取消收藏的列表显示**
  /// (Android 是 onToggleFavorite != null 才画,ArkTS 没有可空回调的惯例,用显式开关)。
  @Prop showFavorite: boolean = false;
  @Prop isFavorite: boolean = false;
  onToggleFavorite: () => void = () => {};
  /// 行内「加入播放列表」。只在节目详情页开:浏览选集为主的页面,一步入队比长按菜单顺手
  /// —— 长按再快也要"按住等半秒"(时长已可自定,见 `LIST_MENU_LONG_PRESS_MS`),
  /// 而这个按钮把那一整步绕开。慢的**观感**另靠下面的按压态底色缓解。
  @Prop showQueueAdd: boolean = false;
  /// 「标记已播完 / 未播完」这一项。**2026-10-17 起两端统一:正向那一向在任何单集列表里都不给**,
  /// 只有 `音阁 · 历史` 保留**反向的撤销**(已播完的那些条才给「标记为未播完」,见 `LibraryPage`)。
  /// 摘掉正向的两条理由:
  /// ① **多半是静默空操作** —— `HistoryStore.markPlayed` 对没有历史条目的集直接 return,
  ///    而发现首屏/追更/收藏/下载/搜索结果/频道页里的集大多数根本没播过,按了这一项什么都不会发生;
  /// ② 少数**真生效**的(播过、有历史条目的)反馈只剩标题压暗这一处,而**这一列没有回程** ——
  ///    想撤必须去 `音阁 · 历史` 找同一条。
  /// `played` 的显示(标题压暗 + 打勾)照旧。Android 侧同一条规则写在 `Components.kt` 的
  /// `onTogglePlayed` 上;此前 Android 比本端多给四列(发现首屏/追更/收藏/下载),频道详情页
  /// 上一轮已摘,本轮连同本端的搜索结果一起收口。
  /// 接了这颗的**唯一**调用方是 `音阁 · 历史`,所以菜单项文案写死为 `mark_unplayed`。
  /// 长按菜单本身**所有单集列表都有**,故不设开关 —— 鸿蒙端此前压根没有长按手势,
  /// 外部反馈的「长按单集不能加入队列」即此。调用方必须接好 onPlayNext / onEnqueue。
  @Prop showPlayedToggle: boolean = false;
  onPlayNext: () => void = () => {};
  onEnqueue: () => void = () => {};
  onTogglePlayed: () => void = () => {};

  /**
   * 点封面进这一集所属的频道页。Android 侧那份判据是两重的
   * (`LocalOpenPodcastChannel` 外壳有没有提供入口 + 调用方的 `coverOpensChannel`),
   * ArkTS 没有 composition local,两重**塌成一颗显式开关**:调用方要么「开门 + 给动作」一起传,
   * 要么都不传 —— 只开不给就是「看着能点、点了没反应」的假封面。
   * **频道详情页不开**:已经在这档的页面里再点就是往栈上压一份自己(与 Android 第三条门同值)。
   */
  @Prop showChannelJump: boolean = false;
  onOpenChannel: (feedUrl: string) => void = () => {};
  /**
   * 多选(批量加入待播),与 Android 的 `showBatch / onEnterSelection / selectionMode /
   * selected / onToggleSelect` 一一对应。
   *
   * 已选集合**由调用方(整列)持有,不存在行里**:「全选」要能一次改整列,作用域本来就得是整列 ——
   * 与 Android 同一个理由(那边还多一条"行会被 LazyColumn 回收",本工程的 `List` + `ForEach`
   * 只建可见行,见 `FeedPage` 注释,那条理由在本端不成立)。
   */
  @Prop showBatch: boolean = false;
  onEnterSelection: () => void = () => {};
  @Prop selectionMode: boolean = false;
  @Prop selected: boolean = false;
  onToggleSelect: () => void = () => {};

  /**
   * 行按压态:onTouch 手动驱动,不用 stateStyles —— stateStyles 的 pressed 对
   * 子图标上的触摸同样会亮(真机反馈:点行内「入队」键,整行高亮,看着像点了播放)。
   * 行体亮/灭由这里的事件流控制,右侧各图标以 onTouch stopPropagation 截断冒泡;
   * 高亮只属于「按到行本身」:点行播放、长按菜单的等待期。
   */
  @State pressed: boolean = false;
  /**
   * 长按菜单的显示位 + 按下点在行内的位置(x 与 y 都要)。
   *
   * `bindContextMenu` 走的是**状态驱动**那个重载(第一参数是 boolean),这样触发时长
   * 才由下面的 `LongPressGesture` 说了算(见 `LIST_MENU_LONG_PRESS_MS`)。代价是它不再
   * "自动在按下点弹出",要自己把锚点挪过去 —— 这一行是整屏宽的,横向不挪的话
   * 菜单永远贴着屏幕左边弹。
   *
   * ⚠️ **"自己挪"只能靠锚点节点,不能靠 `options.offset`。** 这个重载的 `offset`
   * 在真机上**完全不生效**(两次不同 x 的长按给出同一个菜单矩形;写死 `{x:30,y:-50}`
   * 也还是那个矩形)。它的 `placement` 默认是 **`Placement.BottomLeft`** —— 菜单顶边
   * 贴在本节点**下沿**,于是永远从行下面弹出来,按在行的哪一格都一样。
   * 装机反馈「菜单太靠下了」即此。修法见 build 里那个 1×1 锚点(与 Android 的
   * `pressPoint` + 零尺寸 `Box` 同一套),坑记录见 H121。
   *
   * ✅ 装机验过(2026-09-29,BRA-AL00):整宽行按 (600,2500) 时菜单放不下,框架**自动翻到上方**
   * (`[600,2136][1091,2474]`),横向**仍然跟着手指** —— 因为跟手的是**节点位置**,
   * 那句"翻转后失效"针对的是 `offset`。按 (1150,·) 贴右缘时菜单右缘落在手指处、不越屏。
   */
  @State menuShown: boolean = false;
  @State pressX: number = 0;
  @State pressY: number = 0;

  /**
   * 封面那一格在**整行坐标系**里的左上角偏移,由封面的 `onAreaChange` 记下来。
   *
   * 用途只有一个:封面自己的长按手势给出的 `localX/localY` 是相对封面的,弹菜单的锚点却挂在
   * 整行上(见上面 `openMenuAt`)。用字段而不是每次现算:`Area.position` 只在布局变化时给,
   * 长按那一瞬间读现成的值是**零成本**,而渲染路径上不解析东西是硬规矩 6。
   * 不做成 @State:它变了不需要重渲,只是下一次长按换算要用。
   */
  private coverOX: number = 0;
  private coverOY: number = 0;

  /// 长按弹出的菜单。项与 Android `EpisodeListItem` 的 DropdownMenu 一一对应。
  @Builder
  contextMenu() {
    Menu() {
      MenuItem({ content: L.s('queue_play_next') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => this.onPlayNext())
      MenuItem({ content: L.s('queue_add') })
        .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
        .onClick(() => {
          this.onEnqueue();
          this.showToast(L.s('queue_added'));
        })
      // 「多选」排在「加入队列」之后、与 Android 同位:这两颗是同一件事的两种规模
      // (逐条 / 一批),而「标记已播完」是另一路的读法,放在最后。
      if (this.showBatch) {
        MenuItem({ content: L.s('batch_select') })
          .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
          .onClick(() => this.onEnterSelection())
      }
      if (this.showPlayedToggle) {
        // 文案**写死反向**,不再按 played 换向:正向那颗自 2026-10-17 起两端任何列表都不给
        // (理由见上面 showPlayedToggle 的注释)。留着换向表达式就是给"下一列顺手接出正向"留通道。
        // 发现页「继续收听」那张卡用的是 DiscoverPage 里自己的菜单,不受这条影响。
        MenuItem({ content: L.s('mark_unplayed') })
          .contentFont(this.menuFont()).contentFontColor(this.scheme.onSurface)
          .onClick(() => this.onTogglePlayed())
      }
    }
    // 面板底色与字号都显式给,理由同 PlayerPage.menuFont —— ArkUI 菜单默认浅色面板、
    // 字号偏大,不跟随 App 主题;全应用的菜单要长一个样。
    .backgroundColor(this.scheme.surface)
    .radius(12)
  }

  /// 菜单项字体:labelLarge(14) 常规体,对齐 Material 的 DropdownMenuItem。
  private menuFont(): Font {
    return { size: TypeScale.labelLarge * this.fontScale, weight: FontWeight.Normal };
  }

  /// 入队确认的 toast。收在行组件而不是各页的 onEnqueue 回调:所有列表
  /// (行内键 + 长按菜单)统一有反馈,调用方不必各自补。写法同 PodcastDetailPage.showToast。
  private showToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /// 频道跳转这一门:开关 + `feedUrl` 非空(与 Android `coverChannelJump` 的②③条同值;
  /// ①「外壳有没有提供入口」在本端塌进 `showChannelJump` 那一颗里,见属性注释)。
  private canJumpChannel(): boolean {
    return this.showChannelJump && this.episode.feedUrl.length > 0;
  }

  /**
   * 封面那一格是否**接管**自己身上的触摸(点 + 长按)。
   *
   * 这是**结构上的分叉判据**(见 build 里那两处调用),不是挂在同一棵树上的一个判断:
   * 接管 ⇒ 走 `coverTaken()`(自带 onClick / LongPressGesture,并在 onTouch 里 `stopPropagation`);
   * 不接管 ⇒ 走 `coverPlain()`(一个 handler 都不挂,触摸原样落到整行)。
   * 判据必须与 `coverTap()` 里的分支**同一处**定义,否则会出现"接了这一下却没人做事"。
   */
  private coverTakesTap(): boolean {
    return this.selectionMode || this.canJumpChannel();
  }

  /**
   * 按在封面上的那一下:选择态 = 勾选,能跳 = 进频道页。
   *
   * ⚠️ **没有"否则起播"这一支,而且只有 `coverTaken()` 那一棵树会调到这里。**
   * ArkUI 的 `onClick` **不跨节点冒泡**:子节点挂了它,那一下就被子节点消费,整行那颗
   * `onClick` 不会再跑(本轮装机数过勾选条读数:多选态按封面,「已选」从 1 变 2 而不是原地不动
   * —— 若两处都执行,同一行会被勾上又取消)。所以接管的时候这里**不需要**也**不该**去做整行的动作。
   * (这里原先写的"子 onClick 照样冒泡给父 onClick"是一条错判据,已按实测改口,见 H187。
   * 会冒泡的是 `onTouch`,那是"按压高亮"另一件事,见 `coverTaken` 的 ②。)
   * 不接管 ⇒ 连这颗 handler 都不挂,那一下原样落到整行
   * (为什么必须"不挂"而不是"挂了提前 return",见 `coverPlain` 头上那段)。
   */
  private coverTap(): void {
    if (this.selectionMode) {
      this.onToggleSelect();
    } else if (this.canJumpChannel()) {
      this.onOpenChannel(this.episode.feedUrl);
    }
  }

  /// 整行的点击。选择模式里「播这一集」换成「勾选 / 取消」(Android `rowModifier` 的 when 分支)。
  private rowTap(): void {
    if (this.selectionMode) this.onToggleSelect(); else this.onPlay();
  }

  /**
   * 长按:采下按下点并把菜单弹出来。
   *
   * @param fromCoverX / @param fromCoverY 触发源是封面时,`localX/localY` 相对的是**封面那一格**,
   *   而锚点摆在整行的 Stack 里,所以要加上封面在行内的偏移(由 `onAreaChange` 记下来)。
   *   Android 侧同一件事是靠「在整行的 Initial 遍里采 pressPoint」做的(见 H185),本端没有
   *   Initial 遍这种钩子,只能换算。
   */
  private openMenuAt(event: GestureEvent, coverX: number, coverY: number): void {
    // 选择模式里整行只剩勾选一个语义,长按不弹菜单(与 Android 同口径)
    if (this.selectionMode) return;
    const f = event.fingerList.length > 0 ? event.fingerList[0] : null;
    this.pressX = (f === null ? 0 : f.localX) + coverX;
    this.pressY = (f === null ? 0 : f.localY) + coverY;
    this.menuShown = true;
  }

  /**
   * 日期 · 时长。**不含节目名** —— 节目名单独一栏靠左、用强调色(见 build)。
   *
   * 原先是「节目名 · 日期 · 时长」串成一条全灰文字,并排看 Android 与鸿蒙的截图时
   * 这条是观感差距最大的一处:三段同色同号挤在左边,读起来是一坨灰糊,还常被截断成
   * 「1 小时 …」。Android 是左右分栏(节目名强调色居左 / 日期时长灰色右对齐),
   * 右缘因时长宽度固定而天然整齐。
   */
  private meta(): string {
    const parts: string[] = [];
    const d = formatPubDate(this.episode.pubDate);
    if (d.length > 0) parts.push(d);
    const dur = formatDurationSec(this.episode.durationSec);
    if (dur.length > 0) parts.push(dur);
    return parts.join('  ·  ');
  }

  /// 靠左那栏的节目名。与 Android 同一口径:超过 10 字取前 9 字加省略号 ——
  /// 长度不设限会把右侧的日期时长挤出去。
  private shortPodcastTitle(): string {
    const name = this.episode.podcastTitle;
    return name.length > 10 ? `${name.substring(0, 9)}…` : name;
  }

  private showsPodcastTitle(): boolean {
    return this.showPodcastTitle && this.episode.podcastTitle.length > 0;
  }

  private titleColor(): string {
    if (this.isCurrent) return this.scheme.primary;
    return this.played ? this.scheme.onSurfaceVariant : this.scheme.onBackground;
  }

  /**
   * 封面本体:图 + 压暗层 + (勾选环 | 播放角标)。
   *
   * ⚠️ **不带任何参数、也不带触摸** —— 触摸在两个调用处分开挂(见 `coverTaken` / `coverPlain`)。
   * 写成无参 @Builder 是有意的:带值参数的 @Builder 只求值一次(见 H29/H145),那样勾选环就永不刷新。
   */
  @Builder
  coverFace() {
    Artwork({ scheme: this.scheme, url: this.episode.artworkUrl, dim: 52, corner: 10 })
    Row()
      .width(52).height(52)
      .borderRadius(10)
      .backgroundColor(withAlpha('#000000', this.isCurrent ? 0.42 : 0.28))
    if (this.selectionMode) {
      /**
       * 勾选态压在封面上(与 Android 同位置:行里再摆一颗 checkbox 会把 52 的封面挤变形,
       * 而「选中」本来就是这一行唯一要说的话)。
       *
       * **形状自己画,不借 Symbol** —— Android 那侧是 `CheckCircle` / `RadioButtonUnchecked`
       * 两枚现成图标,鸿蒙这边没有能在真机上验过的对应符号名,而 Symbol 名写错**不报错、
       * 直接空白**(见 Widgets 的 Glyph 注释),只能拿已经在装机用过的 `checkmark`(Sym.played)
       * 加一个环凑出同一语义:选中 = 实心强调色圆 + 白勾,未选 = 白色描边圆环。
       */
      Column()
        .width(24).height(24)
        .borderRadius(12)
        .border({
          width: 2,
          color: this.selected ? this.scheme.primary : withAlpha('#FFFFFF', 0.9)
        })
        .backgroundColor(this.selected ? this.scheme.primary : Color.Transparent)
        .accessibilityText(L.s(this.selected ? 'a11y_selected' : 'a11y_unselected'))
      if (this.selected) {
        Glyph({ symbol: Sym.played, dim: 16, color: Color.White })
      }
    } else {
      // 裸三角 / 双竖条,不是 `sys.media.ohos_ic_public_play` 那枚**带白色圆底**的:
      // 圆底那枚叠在封面上显得笨重,与 Android 的裸 PlayArrow 观感差一截。
      // 用 Symbol 字体的实心变体(名字已在真机上验过能渲染 —— Symbol 名写错不报错、
      // 直接空白,所以换这类资源必须真机看一眼,见 Widgets 注释)。
      Glyph({
        symbol: this.isCurrent && this.isPlaying ? Sym.pauseFill : Sym.playFill,
        dim: 24,
        color: Color.White
      })
        // 封面已经是「进频道页」的入口时,那颗播放/暂停只是状态显示:读屏不能再念「播放」,
        // 否则标签说的和点出来的不是同一件事(与 Android 的 contentDescription=null 同口径)。
        .accessibilityText(this.canJumpChannel() ? '' :
          (this.isCurrent && this.isPlaying ? L.s('a11y_pause') : L.s('a11y_play')))
    }
  }

  /**
   * 封面**不接管**那一格:一个 handler 都不挂,触摸原样落到整行(点 = 起播,长按 = 弹菜单),
   * 与加这颗开关之前完全一致。
   *
   * ⚠️ 为什么不是"照样挂上 handler、回调里提前 return"(第一版就是这么写的,真机即坏):
   * 封面上**只要挂了 `onClick`,那一下就被封面吃掉、不再交给整行** —— 于是没开跳转门的列表
   * (频道详情页)点封面**什么都不发生**,而它本来是靠这一下起播的。装机实测 2026-10-16:
   * 同一行按标题起播正常、按封面零反应。与 H185 是同一条坑的另一面 ——
   * **手势一挂上就参与仲裁,回调里 return ≠ 没挂**。所以"接不接管"必须是**结构上的两棵树**,
   * 不能是同一棵树上的一个判断。
   */
  @Builder
  coverPlain() {
    Stack() {
      this.coverFace()
    }
    .width(52).height(52)
  }

  /**
   * 封面**接管**那一格(选择态,或这一集能跳频道页)。三条一起看,少一条就是
   * "按在头像上没反应"或"点头像连播都切了":
   *
   * ① `onAreaChange` 记下这格在整行里的偏移,给下面的长按换算锚点用(见 `coverOX`)。
   * ② `onTouch` 截断冒泡:**触摸事件会冒泡到父节点**(右侧那三颗图标全都靠 `stopPropagation`
   *    灭掉整行的按压高亮,见下面那三处)。这里同样截断,是为了让按压态由封面自己驱动
   *    (`this.pressed`),而不是让整行跟着亮 —— 点击语义并不依赖它(`onClick` 不跨节点冒泡,见 H187)。
   * ③ 长按**自带一份**。与 Android 的 H185 同一族坑 —— 这一格既然消费了这串触摸,
   *    父行那颗 `LongPressGesture` 就再也看不见它,按在头像上长按会变成"没反应"。
   *    Android 的解法是封面改用 `combinedClickable` 并把 `onLongClick` 委托给同一个菜单;
   *    本端的等价写法就是这里这颗 `LongPressGesture`(同阈值、同一个 `openMenuAt`)。
   *    Tap 与 LongPress 挂在同一节点上的互斥关系,这一行本来就在用(整行的 onClick +
   *    长按已在真机验过:长按只弹菜单,不会顺带起播)。
   */
  @Builder
  coverTaken() {
    Stack() {
      this.coverFace()
    }
    .width(52).height(52)
    .onAreaChange((_o: Area, n: Area) => {
      this.coverOX = Number(n.position.x);
      this.coverOY = Number(n.position.y);
    })
    .onTouch((event: TouchEvent) => {
      this.pressed = event.type === TouchType.Down;
      event.stopPropagation();
    })
    .gesture(LongPressGesture({ duration: LIST_MENU_LONG_PRESS_MS })
      .onAction((event: GestureEvent) => { this.openMenuAt(event, this.coverOX, this.coverOY); }))
    .onClick(() => this.coverTap())
    .accessibilityText(this.canJumpChannel() ? L.s('a11y_open_channel') : '')
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row({ space: 12 }) {
        // 封面 + 半透明黑蒙层 + 白色播放/暂停图标。
        //
        // **播放入口就叠在封面上**,行右侧不再另放一个圆钮(与 Android 一致)。
        // 原先右侧那个 34 见方的灰圆圈让每行多一个抢眼的重元素,与封面争视线,
        // 而整行本来就可点播放 —— 它并不提供额外能力,只是把行撑宽、把标题挤成两行。
        //
        // 接管与不接管是**两棵树**,判据 `coverTakesTap()` 与理由都写在 `coverPlain` 头上。
        if (this.coverTakesTap()) {
          this.coverTaken()
        } else {
          this.coverPlain()
        }

        Column({ space: 3 }) {
          // 标题 + 已播对勾(与 Android 一致:对勾紧跟标题,16 号,onSurfaceVariant 色)
          Row({ space: 6 }) {
            Text(this.episode.title)
              // 常规字重、正文号(对齐 Android 的 bodyLarge 常规体)。原先是 Medium,
              // 与灰糊的副信息叠在一起显得又粗又胖,一屏比 Android 少放三四行。
              .fontSize(TypeScale.body * this.fontScale)
              // 字距与行高:ArkUI 默认字距 0、行距紧凑,而 Compose 用 Material 字号表时
              // 两者都自带 —— 不补就是"字挨着字、行贴着行",密排列表尤其显挤(见 Tracking 注释)
              .letterSpacing(Tracking.body)
              .lineHeight(TypeScale.body * this.fontScale * LineHeight.body)
              .fontColor(this.titleColor())
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              // 不用 layoutWeight(1):那会让标题撑满、把对勾推到行最右。
              // Android 是 weight(1f, fill = false) —— 文字按内容宽、必要时收缩,对勾紧跟其后。
              .flexShrink(1)
            if (this.played) {
              Glyph({ symbol: Sym.played, dim: 16, color: this.scheme.onSurfaceVariant })
                .accessibilityText(L.s('a11y_played'))
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          // 副信息:节目名(强调色)靠左 + 日期·时长(灰)右对齐。
          // 不显示节目名的场景(频道详情页)退化成日期·时长单独居左,与 Android 同。
          if (this.showsPodcastTitle()) {
            Row() {
              Text(this.shortPodcastTitle())
                .fontSize(TypeScale.caption * this.fontScale)
                .letterSpacing(Tracking.caption)
                .fontColor(this.scheme.primary)
                .maxLines(1)
              Blank()
              if (this.meta().length > 0) {
                Text(this.meta())
                  .fontSize(TypeScale.caption * this.fontScale)
                  .letterSpacing(Tracking.caption)
                  .fontColor(this.scheme.onSurfaceVariant)
                  .maxLines(1)
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          } else if (this.meta().length > 0) {
            Text(this.meta())
              .fontSize(TypeScale.caption * this.fontScale)
              .letterSpacing(Tracking.caption)
              .fontColor(this.scheme.onSurfaceVariant)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 行内收藏心形(与 Android 同位置:元信息之后、下载控件之前)
        // ⚠️ 选择模式里这三类图标**一律不显示**(不是禁灰),与 Android 同一条理由:
        // 它们在行内自己消费点击,留着就是"点行尾那一下取消收藏、点行中间勾选"——
        // 同一行两种语义,用户无从预期。
        if (this.showFavorite && !this.selectionMode) {
          Glyph({
            symbol: this.isFavorite ? Sym.favorite : Sym.favoriteOff,
            dim: 20,
            color: this.isFavorite ? this.scheme.primary : this.scheme.onSurfaceVariant
          })
            // 图标只有 20,命中区外扩到 36 见方,免得点不中(行本身的 onClick 是播放,
            // 命中区重叠会被行吃掉,所以这里必须显式外扩)
            .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
            .accessibilityText(this.isFavorite ? L.s('a11y_unfavorite') : L.s('a11y_favorite'))
            // 截断触摸冒泡:行的按压高亮只属于「按到行本身」,点图标不该点亮整行
            .onTouch((event: TouchEvent) => event.stopPropagation())
            .onClick(() => this.onToggleFavorite())
        }

        // 行内「加入播放列表」(showQueueAdd 打开时):与收藏心形同位置规则、同命中区外扩。
        // 图标用列表+加号(add_songlist)而不是队列符号 —— 它的动作是「入队」,
        // 与「打开队列页」的队列图标同形会误导(真机反馈)。
        if (this.showQueueAdd && !this.selectionMode) {
          Glyph({ symbol: Sym.queueAdd, dim: 20, color: this.scheme.onSurfaceVariant })
            .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
            .accessibilityText(L.s('queue_add'))
            .onTouch((event: TouchEvent) => event.stopPropagation())
            .onClick(() => {
              this.onEnqueue();
              // 入队结果在别页,界面无任何变化,不提示等于没按上
              this.showToast(L.s('queue_added'));
            })
        }

        // 下载三态,与 Android `DownloadControl` 一一对应:
        // 已下载 = DownloadDone(强调色,点击删除)/ 进行中·排队 = 进度圈 / 未下载 = Download
        // 原先用「已存」「下载」文字代替 —— sys.media.* 没有这两个图标,换 Symbol 后有正主。
        // 外面这一层 `!selectionMode` 与上面收藏/入队同一理由(选择模式里不留第二种点击语义)。
        if (!this.selectionMode) {
          if (this.downloadState === DownloadState.DOWNLOADING || this.downloadState === DownloadState.QUEUED) {
            LoadingProgress().width(20).height(20).color(this.scheme.primary)
          } else if (this.downloadState === DownloadState.COMPLETED) {
            Glyph({ symbol: Sym.downloaded, dim: 20, color: this.scheme.primary })
              .accessibilityText(L.s('a11y_downloaded'))
              .onTouch((event: TouchEvent) => event.stopPropagation())
              .onClick(() => this.onDeleteDownload())
          } else if (this.downloadState >= 0) {
            /**
             * 视频源(伪地址)这颗键**置灰但留着**,不是整格消失。
             *
             * 「下载」在别处承诺的是「长期留在盘上、进备份、由清除下载打理」,而视频集的音频
             * 直链带 2 小时 `deadline`,不能当资产存(H 条目:视频源直链时效)。两者语义冲突,
             * 所以不给这个动作;自动缓存(300 MB 预算那一套)仍然保留 —— 那是浏览器缓存同性质
             * 的东西,且撑着现有播放性能设计。
             *
             * 不隐藏的理由:同一列表里各行的键位会错开(用户 2026-10-28 拍的口径是「置灰」)。
             * 判据从**集子自己**的 audioUrl 推,不由调用方传 —— 搜索结果/历史/待播/收藏里都
             * 可能有视频源的单集,逐个调用点传就一定会漏一处。
             *
             * 禁用态**只落在这一支**:已完成/进行中都是真实进度,灰掉反而像按钮坏了;而视频集
             * 永远不会有那两种状态,所以这条限制只有一种读法。38% 是置灰的惯例值。
             */
            if (BilibiliSource.isPseudo(this.episode.audioUrl)) {
              Glyph({ symbol: Sym.download, dim: 20,
                color: withAlpha(this.scheme.onSurfaceVariant, 0.38) })
                .accessibilityText(L.s('a11y_download_disabled'))
            } else {
              Glyph({ symbol: Sym.download, dim: 20, color: this.scheme.onSurfaceVariant })
                .accessibilityText(L.s('action_download'))
                .onTouch((event: TouchEvent) => event.stopPropagation())
                .onClick(() => this.onDownload())
            }
          }
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 12, bottom: 12 })
      .onClick(() => this.rowTap())
      /**
       * 按压态底色。长按要等满 `LIST_MENU_LONG_PRESS_MS` 才出菜单,等待期原本零反馈 ——
       * 手指按住时「不知道按没按上」,观感就是「长按反馈慢」(Android 同样时长但有 ripple 垫着)。
       *
       * 不用 stateStyles:它的 pressed 对子图标上的触摸同样会亮(点「入队」键整行高亮,
       * 看着像点了播放)。改由 onTouch 驱动 @State,配合右侧图标的 stopPropagation,
       * 高亮只属于「按到行本身」。Move 也熄灭 —— 列表滚动都从 Down 开始,
       * 不灭会让被划过的行拖一条亮块;长按期间手指不动,不受影响。
       */
      .backgroundColor(this.pressed ? withAlpha(this.scheme.onSurfaceVariant, 0.10) : Color.Transparent)
      .onTouch((event: TouchEvent) => {
        this.pressed = event.type === TouchType.Down;
      })
      /**
       * 长按。**自己识别长按 + 状态驱动弹出**,不用 `ResponseType.LongPress` 那个重载
       * —— 它的识别时长在框架里,应用改不动(装机反馈「长按触发阈值太长」)。
       *
       * 这里只负责**采下按下点**(`FingerInfo.localX/localY`,相对本行,单位 vp),
       * 菜单本身挂在 build 末尾那个 1×1 锚点上 —— 参数的理由与 offset 失效的证据都写在彼处。
       */
      .gesture(LongPressGesture({ duration: LIST_MENU_LONG_PRESS_MS })
        .onAction((event: GestureEvent) => { this.openMenuAt(event, 0, 0); }))

      /**
       * 菜单锚点:1×1、摆在按下点,`bindContextMenu` 挂在它身上。
       *
       * 为什么不用 `options.offset` 挪:**这个重载根本不读 offset**(真机两次不同 x 的长按
       * 给出同一个菜单矩形;写死 `{x:30,y:-50}` 也还是那个矩形)。而锚点自己的位置应用侧
       * 说了算 —— 菜单相对锚点仍按默认的 `Placement.BottomLeft` 摆(顶边贴锚点**下沿**),
       * 但锚点只有 1×1:摆到手指处,菜单顶边就落在手指下方 29px(≈9vp,框架给弹层留的间距,
       * 真机四档按下点实测同一个常数)。与 Android 的
       * `Box(Modifier.offset { pressPoint })` + `DropdownMenu` 结构等价。
       *
       * `hitTestBehavior(HitTestMode.None)` 是必须的:锚点叠在行上,默认会吃掉这一下触摸,
       * 行就点不动了。给它 1×1 而不是 0 尺寸 —— 纯为留一个可挂弹层的节点,尺寸不参与布局。
       *
       * `enableArrow` 必须是 **false**:带箭头时 ArkUI 把菜单**锚到组件横向正中**,
       * 而这一行是整屏宽的 ⇒ 无论按在哪儿都从屏幕正中弹。
       *
       * `aboutToAppear` / `aboutToDisappear` 升降「误触盾」,吃掉「点外部关菜单」那一下的
       * 穿透点击(ArkUI 会把它同时派发给下面的组件,见 TapGuard)。Disappear 里还要把
       * `menuShown` 收回 false:状态驱动的弹出位必须与菜单真实生命周期同步,否则下一次
       * 置 true 不产生变化,菜单再也不弹。
       */
      Column()
        .width(1).height(1)
        .position({ x: this.pressX, y: this.pressY })
        .hitTestBehavior(HitTestMode.None)
        .bindContextMenu(this.menuShown, this.contextMenu(), {
          enableArrow: false,
          aboutToAppear: () => { TapGuard.raise(); this.pressed = false; },
          aboutToDisappear: () => { TapGuard.lowerSoon(); this.menuShown = false; }
        })
    }
  }
}

/**
 * 多选浮条的高度(不含它与底部栏之间那道缝)。
 *
 * Android 侧那条带实测 44dp,连同 4dp 缝一起以 `SELECTION_BAR_SLOT = 48dp` 让位。
 * 本端按「占屏比例」而不是「数值」对齐(同 `CHIPS_STRIP_H` 44→38 那笔账的算法):
 * 本机逻辑宽 374.2vp / Android 那台 427.6dp ⇒ 44dp ≈ 38.5vp,取整 **38**,
 * 与顶部那条分段条同一档 —— 两端这三条带(分段条 / 播放条 / 批量条)同高才读得出是一套。
 */
export const BATCH_BAR_H = 38;

/**
 * 多选浮条**自己 + 它与下面那颗(播放条 / 栏)的缝**共占的高度:各列表在选择模式里
 * 把它加进滚动容器的 `contentEndOffset`,否则末行正好被这条带压掉半截。
 *
 * 缝取 **4**,对齐 Android 那侧 `EpisodeBatchBar` 上显式写的 `.padding(bottom = 底栏让位 + 4.dp)`
 * —— 真机两侧各量过一次:Android 浮条底边到播放条顶边 ≈12px(= 4dp),鸿蒙是 **≈0**
 * (浮条落点数值上正好等于播放条顶边,两条带贴在一起读不出"两套东西")。
 *
 * ⚠️ 避让量要**同时进两处**才成立:浮条的落点(`bottomPad + BATCH_BAR_GAP` 那条 margin)
 * 和列表的让位(`bottomPad + BATCH_AVOID`)。只进一处 = 要么条压住最后一行,
 * 要么底部多空一截。这条规律在 H184 / H185 各成立过一次,这里是第三次。
 * (2026-10-17 之前这段注释里写的 `BATCH_BAR_GAP` **压根不存在** —— 注释跑在实现前面,
 * 落点那五处一直只写了 `bottomPad`,所以缝一直是 0。)
 */
export const BATCH_BAR_GAP = 4;
export const BATCH_AVOID = BATCH_BAR_H + BATCH_BAR_GAP;

/**
 * 多选状态下浮在列表底部的那条操作条(「已选 N · 全选 · 加入待播 · 退出」)。
 * 与 Android 的 `SelectionBar` + `EpisodeBatchBar` 两层合一:本端没有"各页各抄一遍提示"
 * 的风险,把**结果提示**也收在同一层(见下面的 `batchEnqueueAndToast`)。
 *
 * 为什么浮在**底部**:各列的末项本来就要滚到玻璃栏上方才看得见,底部那条带
 * (`bottomPad` 已经把栏算进去了)是这段列表唯一"空着"的位置;放顶部就要跟标题栏 /
 * 悬浮分段条抢,而分段条右端已经有播放模式与清空那颗(见 `LibraryPage.barActions`)。
 *
 * ⚠️ **本组件不持有任何集合,三个动作全是闭包。** ArkUI V1 里没有装饰器的成员变量
 * 只在建组件时赋值一次:把 `episodes` / `picked: Set` 当普通字段传进来,页面改了集合
 * 这边读到的还是旧的那份 —— 而"全选"按旧集合算会**漏掉后加载进来的那些集**,这种错
 * 只在数据多的时候出现,极难在装机时撞上。计数走 @Prop(会被观察、会刷新),
 * 动作走闭包(每次执行都现读页面的当前值)。同一条规律见 H29 / H145。
 *
 * @param picked  已选条数(页面持有集合,这里只收计数)
 * @param total   这一列当前显示的条数 —— 「全选」按它判"是否已选完"
 * @param onSelectAll / onEnqueue / onExit 由页面实现,闭包内读的是页面的当前集合
 */
@Component
export struct EpisodeBatchBar {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop picked: number = 0;
  @Prop total: number = 0;
  onSelectAll: () => void = () => {};
  onEnqueue: () => void = () => {};
  onExit: () => void = () => {};

  private allSelected(): boolean {
    return this.total > 0 && this.picked >= this.total;
  }

  build() {
    // picked 为 0 时调用方就不摆这一层(与各段"没内容就不摆动作"同一条规矩)。
    Row({ space: 4 }) {
      Text(L.f('batch_selected', this.picked))
        .fontSize(TypeScale.body * this.fontScale)
        .fontColor(this.scheme.onBackground)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 与 Android 的 `weight(1f, fill = false)`:按内容宽,必要时收缩,把省略号留给这一串,
        // 三颗动作永远留在行内(es/fr 的对应串 15~25 字符,不这么写整条会顶出屏外)
        .flexShrink(1)
      Glyph({ symbol: Sym.selectAll, dim: 20, color: this.allSelected()
        ? withAlpha(this.scheme.onSurfaceVariant, 0.3) : this.scheme.onSurfaceVariant })
        // **图标而不是文字**,与 Android 同一条理由(es/fr 三串文字会顶出屏外,见 Widgets 的 Sym.selectAll)
        .padding({ left: 8, right: 8, top: 9, bottom: 9 })
        .accessibilityText(L.s('batch_select_all'))
        // 已选数 == 总数时**这颗自我 disable**:再按一次什么都不会发生,是假按钮。
        // ⚠️ 判据只能这样测(行为),不能去看节点的 clickable 属性 —— ArkUI dump 出来的
        // 属性对这类条件动作并不可靠,Android 侧同一颗在 uiautomator 里也读不出差别(见 H185)。
        .onClick(() => {
          if (this.allSelected()) return;
          this.onSelectAll();
        })
      Text(L.s('batch_enqueue'))
        .fontSize(TypeScale.labelLarge * this.fontScale)
        .fontColor(this.scheme.primary)
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .onClick(() => this.onEnqueue())
      Glyph({ symbol: Sym.close, dim: 18, color: this.scheme.onSurfaceVariant })
        .padding({ left: 6, right: 6, top: 8, bottom: 8 })
        .accessibilityText(L.s('batch_exit'))
        .onClick(() => this.onExit())
    }
    .width('auto')
    .constraintSize({ maxWidth: 300 })
    .height(BATCH_BAR_H)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 12, right: 6 })
    .backgroundColor(this.scheme.surface)
    .borderRadius(BATCH_BAR_H / 2)
    .shadow({ radius: 6, color: withAlpha('#000000', 0.28), offsetY: 2 })
  }
}

/// 批量勾选的**真正新增条数**(提示要说的是这个数,不是勾选数)。
///
/// ⚠️ 这一层只做筛选,**不许自己逐条 `PlayerController.enqueue`**:单条那版每次调用都同步
/// 落一次盘,全选一列(实测 1994 集)会把 UI 线程占到卡死 —— 见 H186。整体走 `enqueueAll`。
export function enqueuePicked(episodes: Episode[], picked: Set<string>): number {
  const fresh: Episode[] = episodes.filter((e: Episode) => picked.has(e.id));
  return PlayerController.get().enqueueAll(fresh);
}

/**
 * 「加入待播」这一颗的完整动作:**入队 → 报结果 → 退出选择态**。
 *
 * 为什么要单独抽出来:入队结果在「待播」那一页,当前列表看不出任何变化,不提示等于没按上;
 * 而**报的必须是新增数而不是勾选数** —— 全选一列再按一次,勾了 200 条、一条都没新增,
 * 说"已加入 200 集"就是说谎(判据 `PlayerController.enqueueAll` 的返回值)。
 * 五列(追更 / 收藏 / 下载 / 历史 / 频道详情页)各抄一遍这句话迟早抄歪,所以收在这里。
 */
export function batchEnqueueAndToast(ui: UIContext, episodes: Episode[], picked: Set<string>): void {
  const added = enqueuePicked(episodes, picked);
  ui.getPromptAction().showToast({
    message: added === 0 ? L.s('batch_added_none') : L.f('batch_added', added)
  });
}

/**
 * 玻璃分段条(ChipsRow)的高度。页面据此在滚动容器顶部留出同等余量
 * (List 用 contentStartOffset、宫格用占位 GridItem):首项静止时停在条下方,
 * 上滚时内容从条下经过 —— 悬浮玻璃后面得有东西经过,模糊才看得出来。
 *
 * **44 → 38(2026-09-29):按占屏比例换算,不是随手收一档。** 装机反馈「顶部也明显偏大」。
 * Android 这条是 44dp、本机原先也是 44vp —— 数值相同,但本机逻辑宽 374.2vp、Android 那台
 * 427.6dp,同值即占屏大 14%。38/374.2 = 10.2% ≈ 44/427.6 = 10.3% ⇒ 这才是"和 Android 一样"。
 * 同一档换算在底部栏(已退役的 `GlassTabBar.BAR_H` 48→42,存档在 `harmony/shelved/`)
 * 与它的留白上一起做的,理由与实测数据写在那处。**这一轮底部栏换成系统 `Tabs` 的 56vp,
 * 不再走 0.876 换算** —— 顶部分段条这条换算本身没被推翻,别拿新栏的高度反过来复核它。
 *
 * ⚠️ **条本身缩了,chip 的"盒子"没跟着缩**:实测 chip 高 29.8vp,而 Android 的 Material
 * FilterChip 是 34dp,鸿蒙本来就比 Android 小(占屏 8.0% vs 7.9%,已经对齐),盒子再缩
 * 就成了字顶着条边。**但 chip 里的字缩了**(14→12fp,见 `CHIP_LABEL_FP`)—— 那是用户
 * 第二次反馈指名的地方,和底部 tab 标签同一档。
 * 圆角也从这里倒推(见下面两处 `CHIPS_STRIP_H / 2`),不要写死 21 —— 那是 44 的一半,
 * 条一改就会露出方角。
 */
export const CHIPS_STRIP_H = 38;

/**
 * 分段条里 chip 的文字字号(fp)。**14 → 12(2026-09-29)**,与底部 tab 标签 11→10 同一档
 * 换算(×0.876,来由见 `shelved/GlassTabBar.ets` 的 `BAR_H` 与 H122)。
 *
 * 原先这里用 `TypeScale.labelLarge`(= Android Material FilterChip 的 14sp),**数值两端相同**
 * —— 但"相同"在这台机器上不等于"一样":本机 1vp ≈ 1.18 个标准 dp,同字号在鸿蒙物理上大 18%、
 * 占屏大 14%。底部栏那一圈按占屏换算收小之后,顶部的字没跟着收,反而读成"字比壳大"。
 *
 * ⚠️ **只动字号,不动盒子的纵向 padding**(仍是 7):chip 高 = 12×1.17 + 14 ≈ 28vp,
 * 与条 38 之间上下各剩 5vp —— 这正是 Android 的比例(chip 34 / 条 44 ⇒ 上下各 5)。
 * 若把竖向 padding 也乘 0.876,盒子会掉到 26vp,chip/条 占比 0.68(Android 0.77),
 * 条里就空得发飘。**"同一把尺子"只适用于外壳,不适用于已经按占比定好的两个量。**
 */
export const CHIP_LABEL_FP = 12;

/**
 * 分段条距屏幕左右的留白。**条宽收口**要拿它从可用宽里减掉,所以和上面那层
 * `.padding({ left: 12, right: 12 })` 必须是同一个数 —— 写两处的话,一处改宽一处
 * 就凭空少/多 12vp(见 [CHIPS_RESERVE_H] 那条"两处读同一个常量"的同类教训)。
 */
export const CHIPS_SIDE_PAD = 12;

/**
 * 页面在滚动容器顶部**该留的余量**。比条本身高 8vp —— 占位若只给 `CHIPS_STRIP_H`,
 * 静止时首项的顶边与条的下描边**重合**(真机实测两者都在 y=681),首项只剩自己的
 * 4vp 内边距撑着,读起来就是"标题贴着分类条"。
 *
 * `+ 8` 不是拍的:Android 侧同一个量写成 `GLASS_CHIPS_TOP_PAD = 52.dp`,注释是
 * 「条 44dp + 与内容的 8dp 间距」(见 `Components.kt`)。**两端同值同义**,
 * 小标题那 4vp 也各自留着(Android 在 `LibraryScreen` 里同样另加 4dp)。踩坑记录见 H102。
 */
export const CHIPS_RESERVE_H = CHIPS_STRIP_H + 8;

/**
 * 分段条右端「还有内容」渐隐带的宽度。**只在内容真的溢出、且还没滚到右端时出现**
 * (判据见 `ChipsRow.refreshOverflow`),不是常驻装饰 —— 装得下三段标签的订阅条上
 * 它根本不存在,常驻会让条看起来永远糊了一角。
 *
 * 36 的来由:chip 右内边距 14 + 一颗被切的 chip 露出的那半截圆角。再窄就还是
 * "硬切"(读不出渐隐),再宽就开始糊到 chip 的可读文字上(chip 文字宽 ≈ 字数×14)。
 */
export const CHIPS_EDGE_FADE_W = 36;

/**
 * 顶部分类条与 Swiper 的手势联动总线:页面在 onGestureSwipe 每帧灌入进度,
 * 胶囊按帧插值绘制(1:1 跟手,与底部栏同手感);松手时行/胶囊各自收尾。
 * 全程不走状态观察 —— 每帧只经回调重建胶囊这一个组件(H64 最小重建面)。
 */
export class ChipsSwipeSync {
  /** 插值两端与进度:胶囊位置 = lerp(chipX[from], chipX[to], progress) */
  from: number = 0;
  to: number = -1;
  progress: number = 0;
  /** 手势帧进行中;end() 先派发结束回调、后清位,收尾方还能读到最后一帧插值 */
  active: boolean = false;
  private frameSink: ((f: number, t: number, p: number) => void) | null = null;
  private endSinks: ((target: number) => void)[] = [];

  onFrame(sink: (f: number, t: number, p: number) => void): void {
    this.frameSink = sink;
  }

  /// 注册顺序即语义:行先注册(先弹簧,钉位依赖 active 仍为 true),胶囊后注册。
  addEndSink(sink: (target: number) => void): void {
    this.endSinks.push(sink);
  }

  report(from: number, to: number, p: number): void {
    this.from = from;
    this.to = to;
    this.progress = p;
    this.active = true;
    this.frameSink?.(from, to, p);
  }

  /// 手势收束(提交或回落)。target = 结束后胶囊应停的选中项。
  end(target: number): void {
    this.endSinks.forEach((fn: (target: number) => void) => fn(target));
    this.active = false;
    this.to = -1;
  }
}

/// 横向分类 chips(与内容分页双向联动)。本体是玻璃条:实时模糊 + 半透明染色,
/// 参数沿用已退役的自绘底部栏那一套(现存档于 `harmony/shelved/GlassTabBar.ets`);
/// 调用方负责把它悬浮在滚动内容上方。
@Component
export struct ChipsRow {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  @Prop labels: string[];
  /// @Watch 的回调参数是**属性名字符串**,不是新值 —— 直接把 springTo 挂上来会收到
  /// "selected",chipX["selected"] 取不到、提前 return,点击切页时胶囊就永远不动
  /// (踩过:拖动走 endSink、量测走 idx,传的都是真数字,唯独点击这条路径坏)。
  @Prop @Watch('onSelectedChange') selected: number;
  /// 与页面的 Swiper 手势联动总线(页面持有并灌帧);不传则无联动,纯弹簧
  sync: ChipsSwipeSync = new ChipsSwipeSync();
  onSelect: (i: number) => void = () => {};
  /**
   * 钉在**条内右端**、不随 chips 横滚的动作位(如「清空」「宫格切换」「播这一整段」)。
   *
   * 由条自己摆在 chips 段**后面**(chips 段 `layoutWeight(1)` 只吃剩下的宽)
   * ⇒ 天然垂直居中、天然占位,一定落在条的右圆顶之内。
   * 之前这些按钮是页面在条**外面**另起一个 Stack 浮上去的:右缘按屏幕留白对齐
   * (比条的右缘还外/内几 vp,和条的圆顶对不上),又各自带一块 `backgroundEffect`
   * —— 玻璃条上再糊一颗玻璃,装机判为「太丑」(见 H104 同轮的装机反馈)。
   * ⚠️ 也不要退回条内的 `Alignment.End` **覆盖层**:不占位 ⇒ 五段标签铺满时压在最后一颗
   * chip 上(装机实测过,见下面「条**恒为通栏**」那段)。
   * **按钮不要再自带背景**,底就是这条玻璃。
   *
   * Android `GlassChipsRow` 有同名同语义的 `endAction` 槽,改一处两端一起改。
   */
  @BuilderParam endAction: () => void = this.emptyEnd;

  @Builder emptyEnd(): void {}

  private scroller: Scroller = new Scroller();
  /// 上一次已滚动到的选中项,避免每次重渲都重复下发滚动指令
  private scrolledTo: number = -1;
  /// 各 chip 的实测位置/宽度(Scroll 内容坐标系,由各 chip 的 onAreaChange 回填),胶囊对位用
  private chipX: number[] = [];
  private chipW: number[] = [];
  /** 透明胶囊当前位置与宽度;首帧没量到选中 chip 之前先藏着 */
  @State capX: number = 0;
  @State capW: number = 0;

  /// chips 视口宽与内容自然宽(两个都由 onAreaChange 量,单位 vp)。
  /// 溢出判定要用**布局框**,不是截屏上看到的尺寸 —— 见 H116:`dumpLayout` 的 bounds
  /// 是裁剪后的可见框,拿它读"被压缩"会得出完全错误的结论。
  private viewW: number = 0;
  private chipsW: number = 0;
  /** 右端还有没滚出来的 chip:画那条渐隐带的唯一开关 */
  @State hasMoreRight: boolean = false;

  /**
   * 「右端还有内容」= **内容比视口宽** 且 **还没滚到右端**。
   *
   * 两个条件都要,因为这两个量各自的失效方向不一样,而且互补短板:
   *   · 只看 `isAtEnd()`:装得下的条(订阅三段)会不会被报告成"不在末端",
   *     从而永久挂上一条渐隐带?这一步我没法在本机证,所以不敢单押;
   *   · 只看 `chipsW > viewW`:滚到底之后内容仍然比视口宽,那就该一直糊着右角。
   * 真出现误判,方向也是**少画而不是多画**:量不到内容宽(横向 Scroll 首帧的测量
   * 口径我改过一次没改对,见 H116 回退的那版)时读成"没溢出",条身干净,
   * 只是少了一个提示 —— 比在装得下的条上留一块永久雾面好。
   *
   * 只在值**翻转**时才 setState:滚动帧里每个事件都会进来读数,但一次横滑最多翻两次,
   * 不会把整条 ChipsRow 拖进逐帧重建(同 H64 的最小重建面)。
   */
  private refreshOverflow(): void {
    if (this.viewW <= 0 || this.chipsW <= 0) return;
    const more = this.chipsW > this.viewW + 2 && !this.scroller.isAtEnd();
    if (more !== this.hasMoreRight) this.hasMoreRight = more;
  }

  /**
   * 条**恒为通栏**,右端动作位靠布局占位而不是浮在 chips 之上。
   *
   * 这里走过一条弯路:先前是「量出 chips 宽 + 动作位宽,再把条收口到刚好包住内容」
   * (旧的 `@State barW` + 三处 onAreaChange 回填)。装机之后两端分头否掉了它:
   *   · **收口本身要的是"右半截空白",而空白的正解是给那一段真的放一个动作** ——
   *     现在每个分段右端都有按钮(订阅=宫格/列表切换、历史=清空、最新/收藏/下载=播放这一整段),
   *     死区不存在了,收口就没有了需求方;
   *   · 每切一段条的右缘就跳一次(有按钮/没按钮两态宽度不同),读起来像条在抖;
   *   · 量了再 setState 必然先出一帧通栏再缩(Android 侧实测 ≈50 ms,H106 记的就是这个)。
   * Android 同名的 `GlassChipsRow` 已按"通栏 + chips 段 `weight(1f)`"定稿(见 H106 之后的
   * 那轮回退),这里同构过来:**chips 段 `layoutWeight(1)` 吃掉「条宽 − 按钮段」**,
   * 装得下就不滚、装不下才横滚。
   *
   * ⚠️ **不要把按钮改回 Stack 的 `Alignment.End` 覆盖层**:那样它不占位,
   * 五段标签(订阅/最新/收藏/下载/历史)在 1216px 的机上正好铺满整条,
   * 按钮就压在最后一颗 chip 的胶囊上(装机实测:按钮 x 1059..1125 与「历史」1081 相交)。
   */

  aboutToAppear(): void {
    // 行先于胶囊(子组件)注册收尾回调:springTo 的钉位依赖 active 仍为 true
    this.sync.addEndSink((t: number) => { this.springTo(t); });
  }

  /**
   * 选中项变化时把它滚进可视区。
   * 发现页有 19 个分类,横滑几页之后选中的 chip 往往已经在屏幕外 ——
   * 高亮变了却看不见,观感上就是"分类没跟着动"。
   */
  private revealSelected(): void {
    if (this.selected === this.scrolledTo) return;
    this.scrolledTo = this.selected;
    // 优先用实测位置;首帧还没量到时退回估算(每 chip ≈ 字数×字号 + 左右 14 内边距 +
    // 8 间距) —— 目的只是把选中项带进视野,不追求精确居中。
    let x = this.chipX[this.selected] ?? -1;
    if (x < 0) {
      x = 0;
      for (let i = 0; i < this.selected && i < this.labels.length; i++) {
        x += this.labels[i].length * TypeScale.label * this.fontScale * 0.6 + 36;
      }
    }
    this.scroller.scrollTo({ xOffset: Math.max(0, x - 80), yOffset: 0, animation: { duration: 260, curve: Curve.EaseOut } });
  }

  /// @Watch 进来的桥:回调时机上 selected 已是新值,读它再进弹簧。
  /// reveal 也必须挂在这里 —— 内层 Row 的 onAreaChange 只在首次布局/面积变化
  /// 时触发,横滑换页只更新 selected、条身没有面积变化,onAreaChange 永远
  /// 不会再触发;只靠它兜底,选中 chip 滑到屏幕外后条身就不滚、高亮不可见
  /// (H93,与 Android 玻璃条换页不同步是同一症状)。reveal 自带 scrolledTo
  /// 幂等阀,重复触发无害。
  private onSelectedChange(): void {
    this.revealSelected();
    this.springTo(this.selected);
  }

  /// 弹簧滑到第 i 个 chip 下(弹簧参数与底部药丸不同,见 animateTo 处注释:
  /// 分类条chip 间距大、又有 Swiper 落位动画作参照,收尾要更从容)。
  /// chip 宽随字数可变,必须用实测值对位;首帧没量到就不动,量到后自然补上。
  ///
  /// 手势联动期间胶囊的绘制值是插值而不是 capX:先无动画把 capX 钉到实际绘制
  /// 位置再弹簧,否则弹簧从旧选中位起跳,视觉上先跳回再弹出去。
  private springTo(i: number): void {
    const tx = this.chipX[i] ?? -1;
    const tw = this.chipW[i] ?? -1;
    if (tx < 0 || tw <= 0) return;
    if (this.sync.active && this.sync.to >= 0) {
      const p = this.sync.progress;
      const fx = this.chipX[this.sync.from] ?? -1;
      const fw = this.chipW[this.sync.from] ?? -1;
      const gx = this.chipX[this.sync.to] ?? -1;
      const gw = this.chipW[this.sync.to] ?? -1;
      if (fx >= 0 && fw > 0 && gx >= 0 && gw > 0) {
        this.capX = fx + (gx - fx) * p;
        this.capW = fw + (gw - fw) * p;
      }
    }
    // 收尾弹簧必须比 Swiper 落位动画(~400ms)更从容:response 0.3 时胶囊
    // 150ms 左右就冲到终点,页面还在路上,观感是「瞬间切过去、很急迫」
    // (用户对照 Android 的 1:1 跟页平移给的反馈)。0.45/0.95 ≈ 450ms 滑行、
    // 几乎无回弹,与落位同时到位,读起来就是「跟着页面滑过去」。
    this.getUIContext().animateTo({ curve: curves.springMotion(0.45, 0.95) }, () => {
      this.capX = tx;
      this.capW = tw;
    });
  }

  build() {
    /**
     * 外层 Row 负责两侧各收进 12:玻璃胶囊必须「浮」起来(两侧有可见的缝 + 发丝描边)
     * 才有玻璃的形 —— 通栏贴边时条与页面背景融为一体,静止时玻璃等于隐形,
     * 看起来就是「没生效」;只有内容滚过条下时才糊得出来。
     * 不能直接给 width('100%') 的 Scroll 加横向 margin:百分比先按父内容宽算出 100%,
     * margin 再往外扩,右缘会溢出(与 searchBar 同款坑,见 DiscoverPage 注释)。
     */
    Row() {
      // 条本体(玻璃画在这一层)。右端动作位是它的**同级**,不是覆盖层 —— 理由见上面
      // 「条**恒为通栏**」那段。
      // 换成通栏 + 占位之后,条不再需要"先量后缩";下面那层 Stack 与这件事无关,
      // 它只为把右端那条渐隐带钉在 **chips 视口**的右缘而存在。
      Row() {
        // chips 段的宿主。为什么多这一层 Stack:右端那条渐隐带要贴在 **chips 视口**的右缘,
        // 而不是玻璃条的右缘 —— 有按钮的分段(订阅/历史/最新…)两者差着一个按钮段宽。
        // 占位仍由这层的 `layoutWeight(1)` 负责,Scroll 在里面按 100% 铺满,语义不变。
        Stack({ alignContent: Alignment.TopEnd }) {
          Scroll(this.scroller) {
            Stack({ alignContent: Alignment.Start }) {
              /**
               * 透明胶囊:罩住选中 chip 的半透明衬底 + 发丝描边。
               * 独立成子组件:Swiper 手势期间每帧只重建这一颗胶囊,不牵动整条 ChipsRow。
               */
              ChipsCapsule({
                scheme: this.scheme,
                capX: this.capX,
                capW: this.capW,
                chipX: this.chipX,
                chipW: this.chipW,
                sync: this.sync
              })

              Row({ space: 8 }) {
                ForEach(this.labels, (label: string, idx: number) => {
                  Text(label)
                    // chip 文字 12fp。**不是** `TypeScale.labelLarge`(14) —— 那个值与 Android 的
                    // FilterChip 同数值,但两台机器的 1 单位不等长,收小理由与"为什么只收字不收盒子"
                    // 全写在上面的 `CHIP_LABEL_FP`。溢出菜单项仍走 labelLarge,两端一致。
                    .fontSize(CHIP_LABEL_FP * this.fontScale)
                    // 选中态的底色交给胶囊,chip 自己只换文字色;未选中保持灰底
                    .fontColor(this.selected === idx ? this.scheme.primary : this.scheme.onSurfaceVariant)
                    .backgroundColor(this.selected === idx ? Color.Transparent : withAlpha(this.scheme.onSurfaceVariant, 0.10))
                    // 横向 padding 跟着字号走(14 → 12),竖向保持 7:见 `CHIP_LABEL_FP` 那段
                    // "只动字号,不动盒子的纵向 padding"。圆角取盒子一半高(28/2),写死 16 会被
                    // ArkUI 夹到一半,数值上看着像"比条还圆"。
                    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                    .borderRadius(14)
                    // 高亮做淡入淡出,不要硬切。原先 backgroundColor/fontColor 是直接按三元赋值,
                    // 状态一变颜色瞬间跳过去,配上页面的滑动动画就显得生硬。
                    .animation({ duration: 200, curve: Curve.EaseOut })
                    .onClick(() => this.onSelect(idx))
                    .onAreaChange((_o: Area, n: Area) => {
                      // Area.position 是相对父组件的局部坐标(d.ts 标注 "local position"):
                      // 内层 Row 在 Stack 原点,胶囊与 chip 共用同一坐标系,x 直接当 translate 用
                      this.chipX[idx] = Number(n.position.x);
                      this.chipW[idx] = Number(n.width);
                      if (idx === this.selected) this.springTo(idx);
                    })
                }, (label: string, idx: number) => `${idx}-${label}`)
              }
              .padding({ left: 8, right: 8 })
              .onAreaChange((_o: Area, n: Area) => {
                // 内容自然宽:这一层在 Scroll 里,主轴不受视口约束,量到的是"全部 chip 排开"的宽
                this.chipsW = Number(n.width);
                // 只负责把选中项滚进视野 —— 见下方 onSelectedChange 的注释:面积变化回调只在
                // 布局真的变了时来,选中项变化不能只靠它兜底。(以前这里还回填 chipsW 重算条宽,
                // 条改成恒通栏之后那笔账没有了;现在回填它是给右端渐隐带判溢出用的。)
                this.revealSelected();
                this.refreshOverflow();
              })
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          // 视口铺满宿主(宿主的宽才是"条宽 − 按钮段",见上面那层注释)
          .width('100%')
          .height(CHIPS_STRIP_H)
          .align(Alignment.Start)
          .onAreaChange((_o: Area, n: Area) => {
            // 视口宽。渐变带要不要出现比的是"内容宽 vs 这一层宽",两者都得量到才敢下结论
            this.viewW = Number(n.width);
            this.refreshOverflow();
          })
          .onDidScroll((_x: number, _y: number, _s: ScrollState) => {
            // 滚到/滚离右端都从这里翻 `hasMoreRight`;该回调只在真有滚动时来,静止不耗
            this.refreshOverflow();
          })

          /**
           * 「右端还有内容」的渐隐带 —— 装机反馈是「历史这颗 chip 被右端按钮盖住了一半」,
           * 而它其实是被视口**裁掉**了(H116:条能横滑,滑过去就完整)。裁掉和盖住在画面上
           * 一模一样,区别只有没有人告诉你"这边还能滑",所以修法是补这个提示,不是改布局。
           * 颜色收口到玻璃条自己的染色(surface α0.6),渐隐到尽头就是"一条干净的条";
           * 若收到不透明色,条身会凭空亮一块。
           * 外缘带圆角:音阁那一段没有按钮(chips 段就是整条),不圆就会从条的右圆顶
           * 外头**方块角**漏出去;有按钮的那几段它的右缘落在按钮段之前,圆角看不出来。
           * `HitTestMode.None`:这一层只是画,手指按在它上面仍要能拖动下面的 chips。
           */
          if (this.hasMoreRight) {
            Row()
              .width(CHIPS_EDGE_FADE_W)
              .height(CHIPS_STRIP_H)
              .borderRadius({ topRight: CHIPS_STRIP_H / 2, bottomRight: CHIPS_STRIP_H / 2 })
              .linearGradient({
                angle: 90,
                colors: [[withAlpha(this.scheme.surface, 0.0), 0.0],
                         [withAlpha(this.scheme.surface, 0.28), 0.45],
                         [withAlpha(this.scheme.surface, 0.60), 1.0]]
              })
              .hitTestBehavior(HitTestMode.None)
              .transition(TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut }))
          }
        }
        // **占位的是 chips 段**:条宽减去按钮段就是它能用的宽,装得下就不滚、装不下才横滚
        // (Android 侧同名组件用的是 `weight(1f)`,同语义)。
        .layoutWeight(1)
        .height(CHIPS_STRIP_H)

        // 右端动作位:底就是这条玻璃,按钮自己不要再带背景。
        // 垂直居中由 Row 的默认对齐(居中)负责,不要手工算 top 偏移 —— 那颗按钮曾经浮在条
        // **外面**按 pagePadding 对齐,与条的右圆顶差几 vp,一端改了另一端就漂(H96 同类)。
        Row() {
          this.endAction()
        }
        .height(CHIPS_STRIP_H)
      }
      .width('100%')
      .height(CHIPS_STRIP_H)
      .borderRadius(CHIPS_STRIP_H / 2)
      // 玻璃本体。**这组参数现在是全项目唯一的一份** —— 原先和自绘底部栏同源
      // (`radius: 40 / saturation: 1.3 / surface 0.6 染色 + outline 0.45 发丝描边`,
      // 那一份已退役到 `harmony/shelved/GlassTabBar.ets`),所以"改这里两端就一致"
      // 不再成立:底部栏改用系统 `Tabs` 的 `barBackgroundBlurStyle`,不归这里管。
      .backgroundEffect({
        radius: 40,
        saturation: 1.3,
        brightness: 1.0,
        color: withAlpha(this.scheme.surface, 0.6)
      })
      .border({ width: 0.8, color: withAlpha(this.scheme.outline, 0.45) })
    }
    .width('100%')
    .height(CHIPS_STRIP_H)
    .padding({ left: CHIPS_SIDE_PAD, right: CHIPS_SIDE_PAD })
  }
}

/**
 * 分类条的透明胶囊渲染器,独立成组件的目的是把 Swiper 手势期间的每帧重建
 * 压到最小面:帧数据经 ChipsSwipeSync 回调推进(@State 仅胶囊自身),
 * 整条 ChipsRow 与所有 chip 不参与。
 *
 * 两种绘制态:手势中(live)按 from→to 插值 1:1 跟手;否则画弹簧静止位
 * capX/capW(由 ChipsRow 的 springTo 驱动,收尾回调先把 live 摘掉再弹簧,
 * 因此弹簧中途切回静止位时画的是动画中的当前值,不跳变)。
 */
@Component
struct ChipsCapsule {
  @Prop scheme: Scheme;
  @Prop capX: number = 0;
  @Prop capW: number = 0;
  /** 手势插值绘制态:live=true 期间画 ix/iw */
  @State live: boolean = false;
  @State ix: number = 0;
  @State iw: number = 0;
  /** 各 chip 实测位置/宽度 —— 与 ChipsRow 共享同一数组引用,读时即最新值 */
  chipX: number[] = [];
  chipW: number[] = [];
  /**
   * 与 ChipsRow **共享同一个驱动实例**(由下面 build 里 `sync: this.sync` 传进来)。
   *
   * ⚠️ 这里原先写的是 `private sync`,于是那一行的传值被 ArkTS 静默丢弃、换成自建实例:
   * 页面级的 `ChipsSwipeSync.report()` 打到的是**行**那份,`frameSink` 永远为 null,
   * `live` 恒 false —— 这颗胶囊自己的逐帧插值路径**从来没跑过**(编译只给一条 WARN,不报错)。
   * 观感上看不出来,因为行会用同一份 sync 算出 capX/capW 喂给 @Prop,两条路算的是同一个 lerp;
   * 少掉的正是把胶囊独立成子组件的全部理由:Swiper 手势期间只重建这一颗,而不是整行。
   * 去掉 `private` 即恢复上面那段注释所描述的设计;顺序不变(行先注册、这里后注册)。
   */
  sync: ChipsSwipeSync = new ChipsSwipeSync();

  private frameSink = (f: number, t: number, p: number): void => {
    const fx = this.chipX[f] ?? -1;
    const tx = this.chipX[t] ?? -1;
    const fw = this.chipW[f] ?? -1;
    const tw = this.chipW[t] ?? -1;
    if (fx < 0 || tx < 0 || fw <= 0 || tw <= 0) return;
    this.ix = fx + (tx - fx) * p;
    this.iw = fw + (tw - fw) * p;
    this.live = true;
  };

  aboutToAppear(): void {
    this.sync.onFrame(this.frameSink);
    // 后于行注册(行的 aboutToAppear 先跑):收尾时行先弹簧、这里再摘插值态
    this.sync.addEndSink((_t: number): void => { this.live = false; });
  }

  build() {
    Row()
      .width(this.live ? this.iw : this.capW)
      // 28 不是新拍的数:它要等于 chip 的实测高(12fp 字 + 上下各 7 的 padding ≈ 28vp),
      // 罩上去才「正好是那一颗 chip」。Android 侧胶囊也取自 chip 自己的高(见其 ChipRow),
      // 两边都是"胶囊 == chip",不是"胶囊比 chip 大一圈"。
      // 为什么从 34 → 30 → 28:条体 44→38 是外壳按 0.876 等比(见 CHIPS_STRIP_H);
      // 34 那版比 chip(29.8)上下各多出 2.1vp,收条之后那点多余变成"罩不住",所以先齐平到 30。
      // 再往下这一档是 chip 的**字号**收了(14→12fp,见 CHIP_LABEL_FP),盒子跟着矮 2vp,
      // 胶囊再一次跟到齐平。圆角始终取自己的一半(全圆)。
      .height(28)
      .borderRadius(14)
      // 染色比底部药丸(0.15)深:胶囊滑到两颗 chip 之间的空档时,底下只有玻璃条 +
      // 米色页面,0.15 几乎隐形(实测拖到中途截图基本看不见),加深才能读出"在移动"
      .backgroundColor(withAlpha(this.scheme.primary, 0.26))
      .border({ width: 0.8, color: withAlpha(this.scheme.primary, 0.30) })
      .translate({ x: this.live ? this.ix : this.capX })
      .visibility((this.live || this.capW > 0) ? Visibility.Visible : Visibility.None)
  }
}

/**
 * 播放模式按钮:**一颗按钮只管模式**,顺序 → 单曲循环 → 随机 → 顺序。
 * 挂在音阁「最新 / 收藏 / 下载」分段条右端与频道主页「全 N 集」那一行右端两处。
 *
 * **模式是每列各一份**(`tag` 就是列身份,见 `PlayerController.playModes`):
 * 按钮显示并修改**它所在那一列自己的**模式,所以最新设了随机、收藏仍读顺序。
 * 曾做过"全局一份"(2026-09-28 同日撤销,见 H119)。
 *
 * **这里没有播放/暂停**:起播的入口是列表里的行 —— 点某一集就播这一整列,不需要再摆一颗
 * "从第一行起播"。2026-09-28 之前这颗按钮是一钮两用(点它 = 起播这一列 + 正在播这列时切模式),
 * 为了它先后加过 `listPlayUsed`(H115)和"点亮/未点亮两套图标"(H118),
 * 还把图标画成过与全 App 相反的口径。根因是一个图标槽位同时扛「状态」和「模式」两个语义 ——
 * 拆开之后两个补丁都不需要了,所以也不再需要 `count`(没内容就没有行可点,按钮本身不是假按钮:
 * 它改的是这一列**以后**怎么播)、需要 `episodes` 数组(它一集都不播)。
 *
 * 与 Android `Components.kt PlayModeButton` 同名同语义,改一处两端一起改。
 */
@Component
export struct PlayModeButton {
  @Prop scheme: Scheme;
  @ObjectLink player: PlayerController;
  @Prop tag: string = '';

  /// 这一列自己的模式;没设过的列读回落值(`''` 那一格)。写成方法不是 getter:
  /// ArkTS 的自定义组件里 getter 支持不稳。
  private mode(): PlayMode {
    const own = this.player.playModes.get(this.tag);
    if (own !== undefined) return own;
    const fb = this.player.playModes.get('');
    return fb === undefined ? PlayMode.SEQUENTIAL : fb;
  }

  /// 图标三态就是模式本身,不表播放状态。
  private symbolOf(): Resource {
    const m = this.mode();
    if (m === PlayMode.REPEAT_ONE) return Sym.repeatOne;
    if (m === PlayMode.SHUFFLE) return Sym.shuffle;
    return Sym.list;
  }

  /// 无障碍文案 = Android 的 contentDescription,读的是"当前是什么模式"(与显示给眼睛的同源)。
  private labelOf(): string {
    const m = this.mode();
    if (m === PlayMode.REPEAT_ONE) return L.s('play_mode_repeat_one');
    if (m === PlayMode.SHUFFLE) return L.s('play_mode_shuffle');
    return L.s('play_mode_sequential');
  }

  build() {
    // 与分段条里另外两颗按钮(排列 / 清空)同一套内边距:左右 16 是与横滚 chips 的缝
    // 和条右圆顶的距离,上下 12 把 20 的图标撑到 44 的条里正好垂直居中。
    // 颜色恒为 onSurfaceVariant:这颗按钮不再"点亮"(点亮是为了区分一颗按钮的两种职责)。
    Glyph({ symbol: this.symbolOf(), dim: 20, color: this.scheme.onSurfaceVariant })
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .accessibilityText(this.labelOf())
      .onClick(() => { this.player.cyclePlayMode(this.tag); })
  }
}

/**
 * 一次「破坏性操作」的二次确认请求(对应 Android 的 `ConfirmDialog`)。
 *
 * 原来是 `SettingsPage` 的私有类。提到这里是因为用得上它的页面变成了三个:
 * 设置页(清缓存 / 清下载 / 清历史 / 清日志)、音阁 · 下载删单集、频道主页删单集 ——
 * 同一句话的确认框在三个地方长得不一样,是最不该出现的漂移,所以框体也一并只留一份。
 */
export class ConfirmSpec {
  title: string = '';
  message: string = '';
  confirmLabel: string = '';
  onConfirm: () => void = () => {};

  constructor(title: string, message: string, confirmLabel: string, onConfirm: () => void) {
    this.title = title;
    this.message = message;
    this.confirmLabel = confirmLabel;
    this.onConfirm = onConfirm;
  }
}

/**
 * 确认框本体:整屏遮罩 + 居中卡片(标题 + 说明 + 危险色确认 + 取消)。
 *
 * 由父页面的 `@State spec: ConfirmSpec | null` 控制显隐 —— **调用方要写在
 * `if (this.pending !== null)` 里**,本组件因此总是在 spec 刚从 null 变成非 null 时
 * 新建,`spec` 走普通成员(不是 @Prop)就够新;反过来若允许 non-null→non-null 直接替换,
 * 这里读到的会是旧值(同 H27 那一族「@Builder 值参数是一次性的」)。
 */
@Component
export struct ConfirmDialog {
  @Prop scheme: Scheme;
  @Prop fontScale: number;
  spec: ConfirmSpec = new ConfirmSpec('', '', '', () => {});
  onDismiss: () => void = () => {};

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(withAlpha('#000000', 0.45))
        .onClick(() => this.onDismiss())
      Column() {
        Text(this.spec.title)
          .fontSize(TypeScale.titleMedium * this.fontScale)
          .fontColor(this.scheme.onBackground)
          .alignSelf(ItemAlign.Start)
          .margin({ bottom: 12 })
        Text(this.spec.message)
          .fontSize(TypeScale.body * this.fontScale)
          .fontColor(this.scheme.onSurfaceVariant)
          .alignSelf(ItemAlign.Start)
        Row({ space: 22 }) {
          Text(L.s('action_cancel'))
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.onSurfaceVariant)
            .onClick(() => this.onDismiss())
          Text(this.spec.confirmLabel)
            .fontSize(TypeScale.label * this.fontScale)
            .fontColor(this.scheme.error)
            .onClick(() => {
              // 先收框再动手:确认后到结果回来之间可能有网络/IO,框还挂着像没反应
              const run = this.spec.onConfirm;
              this.onDismiss();
              run();
            })
        }
        .margin({ top: 22 })
        .alignSelf(ItemAlign.End)
      }
      .width('78%')
      .padding({ left: 22, right: 22, top: 22, bottom: 16 })
      .backgroundColor(this.scheme.surface)
      .borderRadius(18)
    }
    .width('100%')
    .height('100%')
  }
}
