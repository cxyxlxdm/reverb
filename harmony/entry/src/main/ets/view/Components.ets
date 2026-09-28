import { Scheme, TypeScale, Tracking, LineHeight, withAlpha, Metrics } from '../theme/Theme';
import { curves } from '@kit.ArkUI';
import { L } from '../util/L';
import { Podcast, Episode } from '../model/Models';
import { Artwork, SquareArtwork, Glyph, Sym } from './Widgets';
import { formatPubDate } from '../util/DateParse';
import { TapGuard } from '../util/TapGuard';
import { DownloadState } from '../playback/DownloadManager';
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
  /// 「标记已播完 / 未播完」这一项出现在**能承担撤销的地方**:发现页的搜索结果
  /// (与 Android 一致)和音阁 · 历史。后者是必须的 —— 发现页「继续收听」卡上那个
  /// 「标记已播完」改的就是这张列表的 `played`,不在历史页给回程,那一步就撤不回来。
  /// 长按菜单本身**所有单集列表都有**,故不设开关 —— 鸿蒙端此前压根没有长按手势,
  /// 外部反馈的「长按单集不能加入队列」即此。调用方必须接好 onPlayNext / onEnqueue。
  @Prop showPlayedToggle: boolean = false;
  onPlayNext: () => void = () => {};
  onEnqueue: () => void = () => {};
  onTogglePlayed: () => void = () => {};

  /**
   * 行按压态:onTouch 手动驱动,不用 stateStyles —— stateStyles 的 pressed 对
   * 子图标上的触摸同样会亮(真机反馈:点行内「入队」键,整行高亮,看着像点了播放)。
   * 行体亮/灭由这里的事件流控制,右侧各图标以 onTouch stopPropagation 截断冒泡;
   * 高亮只属于「按到行本身」:点行播放、长按菜单的等待期。
   */
  @State pressed: boolean = false;
  /**
   * 长按菜单的显示位 + 按下点在行内的横向位置。
   *
   * `bindContextMenu` 走的是**状态驱动**那个重载(第一参数是 boolean),这样触发时长
   * 才由下面的 `LongPressGesture` 说了算(见 `LIST_MENU_LONG_PRESS_MS`)。代价是它不再
   * "自动在按下点弹出",要用 `pressX` 通过 `offset` 自己挪过去 —— 这一行是整屏宽的,
   * 不挪的话菜单永远贴着屏幕左边弹。
   */
  @State menuShown: boolean = false;
  @State pressX: number = 0;

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
      if (this.showPlayedToggle) {
        MenuItem({ content: this.played ? L.s('mark_unplayed') : L.s('mark_played') })
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

  build() {
    Row({ space: 12 }) {
      // 封面 + 半透明黑蒙层 + 白色播放/暂停图标。
      //
      // **播放入口就叠在封面上**,行右侧不再另放一个圆钮(与 Android 一致)。
      // 原先右侧那个 34 见方的灰圆圈让每行多一个抢眼的重元素,与封面争视线,
      // 而整行本来就可点播放 —— 它并不提供额外能力,只是把行撑宽、把标题挤成两行。
      Stack() {
        Artwork({ scheme: this.scheme, url: this.episode.artworkUrl, dim: 52, corner: 10 })
        Row()
          .width(52).height(52)
          .borderRadius(10)
          .backgroundColor(withAlpha('#000000', this.isCurrent ? 0.42 : 0.28))
        // 裸三角 / 双竖条,不是 `sys.media.ohos_ic_public_play` 那枚**带白色圆底**的:
        // 圆底那枚叠在封面上显得笨重,与 Android 的裸 PlayArrow 观感差一截。
        // 用 Symbol 字体的实心变体(名字已在真机上验过能渲染 —— Symbol 名写错不报错、
        // 直接空白,所以换这类资源必须真机看一眼,见 Widgets 注释)。
        Glyph({
          symbol: this.isCurrent && this.isPlaying ? Sym.pauseFill : Sym.playFill,
          dim: 24,
          color: Color.White
        })
      }
      .width(52).height(52)

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
      if (this.showFavorite) {
        Glyph({
          symbol: this.isFavorite ? Sym.favorite : Sym.favoriteOff,
          dim: 20,
          color: this.isFavorite ? this.scheme.primary : this.scheme.onSurfaceVariant
        })
          // 图标只有 20,命中区外扩到 36 见方,免得点不中(行本身的 onClick 是播放,
          // 命中区重叠会被行吃掉,所以这里必须显式外扩)
          .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
          // 截断触摸冒泡:行的按压高亮只属于「按到行本身」,点图标不该点亮整行
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onClick(() => this.onToggleFavorite())
      }

      // 行内「加入播放列表」(showQueueAdd 打开时):与收藏心形同位置规则、同命中区外扩。
      // 图标用列表+加号(add_songlist)而不是队列符号 —— 它的动作是「入队」,
      // 与「打开队列页」的队列图标同形会误导(真机反馈)。
      if (this.showQueueAdd) {
        Glyph({ symbol: Sym.queueAdd, dim: 20, color: this.scheme.onSurfaceVariant })
          .responseRegion({ x: -8, y: -8, width: 36, height: 36 })
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
      if (this.downloadState === DownloadState.DOWNLOADING || this.downloadState === DownloadState.QUEUED) {
        LoadingProgress().width(20).height(20).color(this.scheme.primary)
      } else if (this.downloadState === DownloadState.COMPLETED) {
        Glyph({ symbol: Sym.downloaded, dim: 20, color: this.scheme.primary })
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onClick(() => this.onDeleteDownload())
      } else if (this.downloadState >= 0) {
        Glyph({ symbol: Sym.download, dim: 20, color: this.scheme.onSurfaceVariant })
          .onTouch((event: TouchEvent) => event.stopPropagation())
          .onClick(() => this.onDownload())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: Metrics.pagePadding, right: Metrics.pagePadding, top: 12, bottom: 12 })
    .onClick(() => this.onPlay())
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
     * 长按菜单。**自己识别长按 + 状态驱动弹出**,不用 `ResponseType.LongPress` 那个重载
     * —— 它的识别时长在框架里,应用改不动(装机反馈「长按触发阈值太长」)。
     *
     * 三个参数都是踩出来的:
     *
     * - `enableArrow` 必须是 **false**。带箭头时 ArkUI 会把菜单**锚到组件**上,而这一行
     *   是整屏宽的 ⇒ 无论按在哪儿,菜单都从屏幕横向正中弹出。Android 那边是同一套做法
     *   (零尺寸锚点放在按下点,见 `Components.kt` 的 pressPoint)。
     * - `offset.x` 取按下点在行内的 x:状态驱动的重载不会自己找按下点(旧重载会),
     *   不挪就永远贴着行左缘。贴右缘时会不会被挤出屏幕**尚未装机验证**(见 ROADMAP)。
     * - `aboutToAppear` / `aboutToDisappear` 升降「误触盾」,吃掉「点外部关菜单」
     *   那一下的穿透点击(ArkUI 会把它同时派发给下面的组件,见 TapGuard)。
     *   `aboutToDisappear` 里还要把 `menuShown` 收回 false:状态驱动的弹出位必须与
     *   菜单的真实生命周期同步,否则下一次置 true 不产生变化,菜单再也不弹。
     */
    .gesture(LongPressGesture({ duration: LIST_MENU_LONG_PRESS_MS })
      .onAction((event: GestureEvent) => {
        const f = event.fingerList.length > 0 ? event.fingerList[0] : null;
        this.pressX = f === null ? 0 : f.localX;
        this.menuShown = true;
      }))
    .bindContextMenu(this.menuShown, this.contextMenu(), {
      enableArrow: false,
      offset: { x: this.pressX, y: 0 },
      aboutToAppear: () => { TapGuard.raise(); this.pressed = false; },
      aboutToDisappear: () => { TapGuard.lowerSoon(); this.menuShown = false; }
    })
  }
}

/// 玻璃分段条(ChipsRow)的高度。页面据此在滚动容器顶部留出同等余量
/// (List 用 contentStartOffset、宫格用占位 GridItem):首项静止时停在条下方,
/// 上滚时内容从条下经过 —— 悬浮玻璃后面得有东西经过,模糊才看得出来。
export const CHIPS_STRIP_H = 44;

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
/// 与底部 GlassTabBar 同一套参数;调用方负责把它悬浮在滚动内容上方。
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
      // 换成通栏 + 占位之后,条不再需要"先量后缩",也就不需要中间那层宿主。
      Row() {
        Scroll(this.scroller) {
          Stack({ alignContent: Alignment.Start }) {
            /**
             * 透明胶囊(与 GlassTabBar 同款语言):罩住选中 chip 的半透明衬底 + 发丝描边。
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
                  // chip 文字取 labelLarge(14),与 Android 的 Material FilterChip 同档
                  .fontSize(TypeScale.labelLarge * this.fontScale)
                  // 选中态的底色交给胶囊,chip 自己只换文字色;未选中保持灰底
                  .fontColor(this.selected === idx ? this.scheme.primary : this.scheme.onSurfaceVariant)
                  .backgroundColor(this.selected === idx ? Color.Transparent : withAlpha(this.scheme.onSurfaceVariant, 0.10))
                  .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                  .borderRadius(16)
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
            .onAreaChange((_o: Area, _n: Area) => {
              // 只负责把选中项滚进视野 —— 见下方 onSelectedChange 的注释:面积变化回调只在
              // 布局真的变了时来,选中项变化不能只靠它兜底。(以前这里还回填 chipsW 重算条宽,
              // 条改成恒通栏之后那笔账没有了。)
              this.revealSelected();
            })
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        // **占位的是 chips 段**:条宽减去按钮段就是它能用的宽,装得下就不滚、装不下才横滚
        // (Android 侧同名组件用的是 `weight(1f)`,同语义)。
        .layoutWeight(1)
        .height(CHIPS_STRIP_H)
        .align(Alignment.Start)

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
      .borderRadius(21)
      // 玻璃本体:参数与 GlassTabBar 一致(见彼处注释),两端观感统一
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
  private sync: ChipsSwipeSync = new ChipsSwipeSync();

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
      .height(34)
      .borderRadius(17)
      // 染色比底部药丸(0.15)深:胶囊滑到两颗 chip 之间的空档时,底下只有玻璃条 +
      // 米色页面,0.15 几乎隐形(实测拖到中途截图基本看不见),加深才能读出"在移动"
      .backgroundColor(withAlpha(this.scheme.primary, 0.26))
      .border({ width: 0.8, color: withAlpha(this.scheme.primary, 0.30) })
      .translate({ x: this.live ? this.ix : this.capX })
      .visibility((this.live || this.capW > 0) ? Visibility.Visible : Visibility.None)
  }
}

/**
 * 列表播放按钮:**一颗按钮两件事** —— 点它 = 从这一列的第一行起播;
 * 正在播这一列时再点 = 切播放模式(顺序 → 循环 → 随机)。
 *
 * 挂在两处:音阁「最新 / 收藏 / 下载」分段条右端(`ChipsRow.endAction`),
 * 以及频道主页「全 N 集」那一行的右端。列身份用 `tag` 区分
 * ("inbox" / "fav" / "dl" / "podcast:<feedUrl>"),所以三段之间、
 * 分段与频道主页之间都不会互相点亮。
 *
 * 与 Android `Components.kt ListPlayButton` 同名同语义,改一处两端一起改。
 *
 * ⚠️ **为什么数组走 `episodes()` 而不是 @Prop**:@Prop 对数组是**深拷贝**,
 * 而这一列可能有几百集;这颗按钮又要 `@ObjectLink player`(模式一变就得重画图标),
 * 重建比一般组件频繁 —— 整列复制一遍是纯浪费。所以只把「有没有内容」这个整数
 * 交给 @Prop 决定显不显示,数组本身按引用现取(Android 传 `List<Episode>` 是
 * 按引用、不复制,这里用 lambda 拿到同等语义)。
 */
@Component
export struct ListPlayButton {
  @Prop scheme: Scheme;
  @ObjectLink player: PlayerController;
  @Prop tag: string = '';
  /// 这一列的集数。为 0 时**整颗按钮不出现** —— 空列表上的"播放"点了什么都不会发生,是假按钮。
  @Prop count: number = 0;
  episodes: () => Episode[] = () => [];

  /// 这颗按钮管的正是当前在播的那一列 ⇒ 点亮,再点切模式。
  /// (写成方法不是 getter:ArkTS 的自定义组件里 getter 支持不稳。)
  private live(): boolean {
    return this.player.activeListTag === this.tag;
  }

  /// 图标。**例外只有一个**:本次会话还没点过任何一颗列表按钮、而这一段又没在播 ⇒ 画暂停。
  /// 理由见 `PlayerController.listPlayUsed`(装机反馈:默认模式是顺序、图标是播放三角,
  /// 首点起播后仍是三角,看着像「没按上」)。暂停只出现在那一段时间里,点过一次就不再出现。
  private symbolOf(): Resource {
    if (!this.live()) {
      return this.player.listPlayUsed ? Sym.playFill : Sym.pauseFill;
    }
    if (this.player.playMode === PlayMode.REPEAT) return Sym.repeat;
    if (this.player.playMode === PlayMode.SHUFFLE) return Sym.shuffle;
    return Sym.playFill;
  }

  /// 无障碍文案 = Android 的 contentDescription。点亮时读的是"当前是什么模式",
  /// 没点亮读的是"点它会起播这一列" —— 与另一端逐字同口径。
  private labelOf(): string {
    if (!this.live()) return L.s('lib_play_this_list');
    if (this.player.playMode === PlayMode.REPEAT) return L.s('play_mode_repeat');
    if (this.player.playMode === PlayMode.SHUFFLE) return L.s('play_mode_shuffle');
    return L.s('play_mode_sequential');
  }

  build() {
    if (this.count > 0) {
      // 与分段条里另外两颗按钮(排列 / 清空)同一套内边距:左右 16 是与横滚 chips 的缝
      // 和条右圆顶的距离,上下 12 把 20 的图标撑到 44 的条里正好垂直居中。
      Glyph({ symbol: this.symbolOf(), dim: 20, color: this.live() ? this.scheme.primary : this.scheme.onSurfaceVariant })
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .accessibilityText(this.labelOf())
        .onClick(() => {
          if (this.live()) this.player.cyclePlayMode();
          else this.player.playQueue(this.episodes(), 0, this.tag);
        })
    }
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
